// 职责: 解析插件清单 settings 声明的配置字段，并在保存前按字段规则校验配置值。
// 关联文件:
//   lib/shared/widgets/settings/plugins/config_surface.dart
//   lib/shared/widgets/settings/plugins/config_form.dart
//   lib/shared/models/plugin/text.dart
import 'text.dart';

/// 清单 `settings` 中字段的 `type`。
enum PluginSettingType {
  string,
  text,
  integer,
  number,
  boolean,
  select,
  secret,
}

/// `select` 字段的一个选项。
class PluginSettingOption {
  const PluginSettingOption({required this.value, required this.label});

  final String value;
  final PluginText label;
}

/// 清单 `settings` 中声明的一个配置字段。
class PluginSettingField {
  const PluginSettingField({
    required this.key,
    required this.type,
    required this.title,
    this.description,
    this.required = false,
    this.defaultValue,
    this.maxLength,
    this.min,
    this.max,
    this.options = const [],
  });

  /// 字段名，即 `context.settings.get` / `context.secrets.get` 使用的 key。
  final String key;
  final PluginSettingType type;
  final PluginText title;
  final PluginText? description;
  final bool required;

  /// 已按字段类型校验过的默认值；`secret` 没有默认值。
  final Object? defaultValue;

  /// `string`、`text` 的最大字符数。
  final int? maxLength;

  /// `integer`、`number` 的取值范围。
  final num? min;
  final num? max;

  /// `select` 的选项。
  final List<PluginSettingOption> options;

  bool get isSecret => type == PluginSettingType.secret;
}

/// 配置值未通过校验的原因。
enum PluginSettingIssue {
  missing,
  too_long,
  not_integer,
  not_number,
  below_min,
  above_max,
  unknown_option,
  wrong_type,
}

final _keyPattern = RegExp(r'^[A-Za-z][A-Za-z0-9_]*$');

/// 解析清单的 `settings` 对象；省略时返回空列表。
/// 已知字段类型错误时抛出 [FormatException]，未知属性忽略。
List<PluginSettingField> parsePluginSettingFields(Object? json) {
  if (json == null) {
    return const [];
  }
  if (json is! Map) {
    throw const FormatException('settings must be an object');
  }
  return [
    for (final MapEntry(:key, :value) in json.entries) _parseField(key, value),
  ];
}

PluginSettingField _parseField(Object? key, Object? json) {
  if (key is! String || !_keyPattern.hasMatch(key)) {
    throw FormatException('Invalid settings key: $key');
  }
  if (json is! Map) {
    throw FormatException('settings.$key must be an object');
  }
  T? optional<T>(String name) {
    final value = json[name];
    if (value == null) {
      return null;
    }
    if (value is! T) {
      throw FormatException('settings.$key.$name has the wrong type');
    }
    return value;
  }

  final type = PluginSettingType.values.asNameMap()[json['type']];
  if (type == null) {
    throw FormatException('settings.$key.type is not supported');
  }
  final title = parsePluginText(json['title'], 'settings.$key.title');
  final numeric =
      type == PluginSettingType.integer || type == PluginSettingType.number;
  final textual =
      type == PluginSettingType.string || type == PluginSettingType.text;
  final min = numeric ? optional<num>('min') : null;
  final max = numeric ? optional<num>('max') : null;
  if (type == PluginSettingType.integer &&
      ((min != null && min is! int) || (max != null && max is! int))) {
    throw FormatException('settings.$key min/max must be integers');
  }
  if (min != null && max != null && min > max) {
    throw FormatException('settings.$key.min is greater than max');
  }
  final maxLength = textual ? optional<int>('maxLength') : null;
  if (maxLength != null && maxLength <= 0) {
    throw FormatException('settings.$key.maxLength must be positive');
  }
  final options = type == PluginSettingType.select
      ? _parseOptions(key, json['options'])
      : const <PluginSettingOption>[];
  final field = PluginSettingField(
    key: key,
    type: type,
    title: title,
    description: parseOptionalPluginText(
      json['description'],
      'settings.$key.description',
    ),
    required:
        type != PluginSettingType.boolean &&
        (optional<bool>('required') ?? false),
    maxLength: maxLength,
    min: min,
    max: max,
    options: options,
  );
  final defaultValue = json['default'];
  if (defaultValue == null) {
    return field;
  }
  if (type == PluginSettingType.secret ||
      validatePluginSettingValue(field, defaultValue) != null) {
    throw FormatException('settings.$key.default is invalid');
  }
  return PluginSettingField(
    key: key,
    type: type,
    title: title,
    description: field.description,
    required: field.required,
    defaultValue: defaultValue,
    maxLength: maxLength,
    min: min,
    max: max,
    options: options,
  );
}

List<PluginSettingOption> _parseOptions(String key, Object? json) {
  if (json is! List || json.isEmpty) {
    throw FormatException('settings.$key.options must be a non-empty list');
  }
  final seen = <String>{};
  return [
    for (final (index, item) in json.indexed)
      if (item is Map &&
          item['value'] is String &&
          seen.add(item['value'] as String))
        PluginSettingOption(
          value: item['value'] as String,
          label: parsePluginText(
            item['label'],
            'settings.$key.options[$index].label',
          ),
        )
      else
        throw FormatException('settings.$key.options has an invalid item'),
  ];
}

/// 校验一个普通配置值；`null` 表示未设置。返回 null 表示通过。
///
/// `secret` 字段的值不经过这里：凭据只校验是否已设置，由调用方判断。
PluginSettingIssue? validatePluginSettingValue(
  PluginSettingField field,
  Object? value,
) {
  if (value == null) {
    return field.required ? PluginSettingIssue.missing : null;
  }
  switch (field.type) {
    case PluginSettingType.string:
    case PluginSettingType.text:
    case PluginSettingType.secret:
      if (value is! String) {
        return PluginSettingIssue.wrong_type;
      }
      if (value.isEmpty) {
        return field.required ? PluginSettingIssue.missing : null;
      }
      final maxLength = field.maxLength;
      if (maxLength != null && value.length > maxLength) {
        return PluginSettingIssue.too_long;
      }
      return null;
    case PluginSettingType.integer:
    case PluginSettingType.number:
      if (value is! num) {
        return PluginSettingIssue.wrong_type;
      }
      if (field.type == PluginSettingType.integer && value is! int) {
        return PluginSettingIssue.not_integer;
      }
      final min = field.min;
      final max = field.max;
      if (min != null && value < min) {
        return PluginSettingIssue.below_min;
      }
      if (max != null && value > max) {
        return PluginSettingIssue.above_max;
      }
      return null;
    case PluginSettingType.boolean:
      return value is bool ? null : PluginSettingIssue.wrong_type;
    case PluginSettingType.select:
      if (value is! String) {
        return PluginSettingIssue.wrong_type;
      }
      return field.options.any((option) => option.value == value)
          ? null
          : PluginSettingIssue.unknown_option;
  }
}

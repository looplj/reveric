// 职责: 解析插件清单与注册定义中可本地化的文案，并按界面语言选出显示文本。
// 关联文件:
//   lib/shared/models/plugin/manifest.dart
//   lib/shared/models/plugin/action.dart
//   lib/shared/models/plugin/setting_field.dart
//   lib/shared/widgets/settings/plugins/config_surface.dart

import 'dart:ui';

/// 插件文案：字符串表示所有语言共用，对象按语言标签给出各语言文本，
/// 如 `{"en": "Verify", "zh-CN": "验证"}`。
class PluginText {
  const PluginText(this.values);

  /// 所有语言共用的文案。
  PluginText.plain(String text) : values = {'': text};

  /// 语言标签到文本，按声明顺序；共用文案的 key 为空字符串。
  final Map<String, String> values;

  /// 依次取当前语言、宿主的回退语言 zh-CN、en，都没有时取第一项。
  String resolve(Locale locale) =>
      values[locale.toLanguageTag()] ??
      values['zh-CN'] ??
      values['en'] ??
      values.values.first;

  /// 还原为声明时的 JSON 形式，供历史记录保存后再解析。
  Object toJson() => values.length == 1 && values.containsKey('')
      ? values['']!
      : Map<String, String>.of(values);
}

/// 解析 [path] 处的文案；缺失、为空、含非字符串语言项或任一语言超过
/// [maxLength] 个字符时抛出 [FormatException]。
PluginText parsePluginText(Object? json, String path, {int? maxLength}) {
  bool tooLong(String value) => maxLength != null && value.length > maxLength;
  if (json is String && json.trim().isNotEmpty) {
    if (tooLong(json)) {
      throw FormatException('$path exceeds $maxLength characters');
    }
    return PluginText.plain(json);
  }
  if (json is Map && json.isNotEmpty) {
    final values = <String, String>{};
    for (final MapEntry(:key, :value) in json.entries) {
      if (key is! String ||
          key.isEmpty ||
          value is! String ||
          value.trim().isEmpty ||
          tooLong(value)) {
        throw FormatException('$path.$key must be a non-empty string');
      }
      values[key] = value;
    }
    return PluginText(Map.unmodifiable(values));
  }
  throw FormatException('$path is required');
}

/// 解析可省略的文案；省略时返回 null。
PluginText? parseOptionalPluginText(Object? json, String path) =>
    json == null ? null : parsePluginText(json, path);

/// 读取历史记录中保存的文案；格式不符时返回 null，不抛出。
PluginText? readPluginText(Object? json) {
  try {
    return json == null ? null : parsePluginText(json, '');
  } on FormatException {
    return null;
  }
}

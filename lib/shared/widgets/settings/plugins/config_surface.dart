// 职责: 把插件清单的配置字段与设置页操作转换为 A2UI 界面消息，并把页面数据读回为待保存的配置与凭据变更。
// 关联文件:
//   lib/shared/models/plugin/setting_field.dart
//   lib/shared/models/plugin/action.dart
//   lib/shared/widgets/settings/plugins/config_form.dart
//   lib/shared/widgets/a2ui/session.dart

import 'dart:convert';
import 'dart:ui';

import '../../../models/plugin/action.dart';
import '../../../models/plugin/setting_field.dart';
import '../../a2ui/session.dart';

/// 配置表单中由宿主提供的已本地化文案。
class PluginConfigStrings {
  const PluginConfigStrings({
    required this.save,
    required this.saved,
    required this.saveFailed,
    required this.clear,
    required this.required,
    required this.secretSavedHint,
    required this.secretClearHint,
    required this.requiredSecretClearHint,
    required this.invalidInteger,
    required this.invalidNumber,
    required this.maxLength,
    required this.range,
    required this.actionSucceeded,
    required this.actionUnauthorized,
    required this.actionNetwork,
    required this.actionTimeout,
    required this.actionFailed,
    required this.actionRequires,
    required this.actionResult,
  });

  final String save;
  final String saved;
  final String saveFailed;
  final String clear;
  final String required;

  /// 凭据已保存时输入框的占位提示。
  final String secretSavedHint;

  /// 点清空后、保存前输入框的占位提示；必填凭据另说明插件会关闭。
  final String secretClearHint;
  final String requiredSecretClearHint;
  final String invalidInteger;
  final String invalidNumber;
  final String Function(int maxLength) maxLength;
  final String Function(num? min, num? max) range;

  /// 设置页操作的结果文案；插件返回的 message 不展示，只按结果码选择。
  final String actionSucceeded;
  final String actionUnauthorized;
  final String actionNetwork;
  final String actionTimeout;
  final String actionFailed;

  /// 操作依赖的字段为空时按钮的禁用原因。
  final String Function(String field) actionRequires;

  /// 结果行的文案：在结果前标明是哪个操作。
  final String Function(String action, String result) actionResult;
}

/// 一次保存提交的内容。
class PluginConfigSubmission {
  const PluginConfigSubmission({required this.settings, required this.secrets});

  /// 全部普通配置；null 表示未设置。
  final Map<String, Object?> settings;

  /// 只包含有变更的凭据：字符串为新值，null 为清除。
  final Map<String, String?> secrets;
}

const saveConfigEvent = 'save';
const clearSecretEvent = 'clear_secret';
const runActionEvent = 'run_action';

String _fieldId(String key) => 'field_$key';
String _rowId(String key) => 'row_$key';
String _clearId(String key) => 'clear_$key';
String _actionId(String name) => 'action_$name';

/// 已保存凭据在 [pluginActionInputs] 中的取值；原文不进入页面数据。
const _savedSecret = '<saved>';

Map<String, Object?> _path(String path) => {'@path': path};

String _valuePath(PluginSettingField field) =>
    field.isSecret ? '/secrets/${field.key}' : '/settings/${field.key}';

/// 字段规则分组；页面数据 `/valid/<字段>/<分组>` 为该组是否通过，
/// 由宿主按 [readPluginConfigSubmission] 的结果计算，规则只在 Dart 侧维护一份。
enum _RuleGroup { required, length, format, range }

_RuleGroup _groupOf(PluginSettingIssue issue) => switch (issue) {
  PluginSettingIssue.missing ||
  PluginSettingIssue.unknown_option => _RuleGroup.required,
  PluginSettingIssue.too_long => _RuleGroup.length,
  PluginSettingIssue.not_integer ||
  PluginSettingIssue.not_number ||
  PluginSettingIssue.wrong_type => _RuleGroup.format,
  PluginSettingIssue.below_min ||
  PluginSettingIssue.above_max => _RuleGroup.range,
};

/// 字段的 check 规则；保存按钮汇总全部规则，未通过时禁用。
List<Map<String, Object?>> _checksOf(
  PluginSettingField field,
  PluginConfigStrings strings,
) {
  final numeric =
      field.type == PluginSettingType.integer ||
      field.type == PluginSettingType.number;
  final maxLength = field.maxLength;
  Map<String, Object?> rule(_RuleGroup group, String message) => {
    'condition': _path('/valid/${field.key}/${group.name}'),
    'message': message,
  };
  return [
    if (field.required && field.type != PluginSettingType.boolean)
      rule(_RuleGroup.required, strings.required),
    if (maxLength != null)
      rule(_RuleGroup.length, strings.maxLength(maxLength)),
    if (field.type == PluginSettingType.integer)
      rule(_RuleGroup.format, strings.invalidInteger),
    if (field.type == PluginSettingType.number)
      rule(_RuleGroup.format, strings.invalidNumber),
    if (numeric && (field.min != null || field.max != null))
      rule(_RuleGroup.range, strings.range(field.min, field.max)),
  ];
}

/// 按当前页面数据计算 `/valid` 的内容。
Map<String, Object?> pluginConfigValidity({
  required List<PluginSettingField> fields,
  required Object? data,
}) {
  final issues = readPluginConfigSubmission(fields: fields, data: data).issues;
  return {
    for (final field in fields)
      field.key: {
        for (final group in _RuleGroup.values)
          group.name:
              issues[field.key] == null ||
              _groupOf(issues[field.key]!) != group,
      },
  };
}

Map<String, Object?> _fieldComponent(
  PluginSettingField field,
  PluginConfigStrings strings,
  Locale locale,
) {
  final id = _fieldId(field.key);
  final checks = _checksOf(field, strings);
  return switch (field.type) {
    PluginSettingType.boolean => {
      'id': id,
      'component': 'Switch',
      'label': field.title.resolve(locale),
      'value': _path(_valuePath(field)),
    },
    PluginSettingType.select => {
      'id': id,
      'component': 'ChoicePicker',
      'label': field.title.resolve(locale),
      'options': [
        for (final option in field.options)
          {'label': option.label.resolve(locale), 'value': option.value},
      ],
      'value': _path(_valuePath(field)),
      'checks': checks,
    },
    _ => {
      'id': id,
      'component': 'TextField',
      'label': field.title.resolve(locale),
      'variant': switch (field.type) {
        PluginSettingType.text => 'longText',
        PluginSettingType.integer || PluginSettingType.number => 'number',
        PluginSettingType.secret => 'obscured',
        _ => 'shortText',
      },
      'value': _path(_valuePath(field)),
      if (field.isSecret)
        'placeholder': _path('/secretHints/${field.key}')
      else if (field.defaultValue != null)
        'placeholder': '${field.defaultValue}',
      'weight': ?(field.isSecret ? 1 : null),
      'checks': checks,
    },
  };
}

/// 凭据输入行：已保存时输入框旁显示「清空」。
Map<String, Object?> pluginSecretRow(String key, {required bool saved}) => {
  'id': _rowId(key),
  'component': 'Row',
  'align': 'end',
  'children': [_fieldId(key), if (saved) _clearId(key)],
};

/// 替换凭据输入行，用于保存或清空后切换「清空」按钮。
Map<String, Object?> pluginSecretRowUpdate(String key, {required bool saved}) =>
    {
      'version': a2uiProtocolVersion,
      'updateComponents': {
        'surfaceId': 'plugin-config',
        'components': [pluginSecretRow(key, saved: saved)],
      },
    };

/// 操作按钮的 check 规则：[PluginAction.requires] 中每个字段都有可用值才能点击。
List<Map<String, Object?>> _actionChecks(
  PluginAction action,
  List<PluginSettingField> fields,
  PluginConfigStrings strings,
  Locale locale,
) => [
  for (final key in action.requires)
    {
      'condition': _path('/actionReady/${action.name}/$key'),
      'message': strings.actionRequires(
        fields
                .where((field) => field.key == key)
                .firstOrNull
                ?.title
                .resolve(locale) ??
            key,
      ),
    },
];

/// 页面上每个配置的实际取值：普通配置为解析后的值；凭据为草稿原文，
/// 已保存且未改动时为占位标记，未设置或待清空时为 null。
Map<String, Object?> _inputsOf(
  List<PluginSettingField> fields,
  Object? data,
  PluginConfigSubmission submission,
) {
  final root = data is Map ? data : const {};
  final saved = root['secretSaved'] is Map
      ? root['secretSaved'] as Map
      : const {};
  return {
    for (final field in fields)
      field.key: !field.isSecret
          ? submission.settings[field.key]
          : (submission.secrets.containsKey(field.key)
                ? submission.secrets[field.key]
                : (saved[field.key] == true ? _savedSecret : null)),
  };
}

/// 按当前页面数据计算 `/actionReady`：依赖的字段有值且通过字段规则才可执行。
Map<String, Object?> pluginActionReadiness({
  required List<PluginSettingField> fields,
  required List<PluginAction> actions,
  required Object? data,
}) {
  final (:submission, :issues) = readPluginConfigSubmission(
    fields: fields,
    data: data,
  );
  final inputs = _inputsOf(fields, data, submission);
  return {
    for (final action in actions)
      action.name: {
        for (final key in action.requires)
          key: inputs[key] != null && issues[key] == null,
      },
  };
}

/// 操作结果对应的输入；与当前页面数据算出的值不同即说明结果已过期。
/// 未声明依赖字段的操作以全部配置为输入。
String pluginActionInputs({
  required List<PluginSettingField> fields,
  required PluginAction action,
  required Object? data,
}) {
  final submission = readPluginConfigSubmission(
    fields: fields,
    data: data,
  ).submission;
  final inputs = _inputsOf(fields, data, submission);
  final keys = action.requires.isEmpty ? inputs.keys : action.requires;
  return jsonEncode({for (final key in keys) key: inputs[key]});
}

/// 把操作结果换成界面文案。
String pluginActionResultText(
  PluginActionResult result,
  PluginConfigStrings strings,
) => result.ok
    ? strings.actionSucceeded
    : switch (result.code) {
        'unauthorized' => strings.actionUnauthorized,
        'network' => strings.actionNetwork,
        'timeout' => strings.actionTimeout,
        _ => strings.actionFailed,
      };

/// 生成配置表单的 A2UI 消息。[values] 为已保存的普通配置，
/// [savedSecrets] 为已保存凭据的字段名；凭据原文不进入页面数据。
/// 清单中可本地化的文案按 [locale] 取值。
/// 保存与 [actions] 的按钮同处字段之后的操作栏；结果由表单在界面下方显示。
List<Map<String, Object?>> buildPluginConfigMessages({
  required List<PluginSettingField> fields,
  required Map<String, Object?> values,
  required Set<String> savedSecrets,
  required PluginConfigStrings strings,
  required Locale locale,
  List<PluginAction> actions = const [],
}) {
  final settings = <String, Object?>{};
  final secrets = <String, Object?>{};
  final secretSaved = <String, Object?>{};
  final secretCleared = <String, Object?>{};
  final secretHints = <String, Object?>{};
  for (final field in fields) {
    final value = values[field.key] ?? field.defaultValue;
    switch (field.type) {
      case PluginSettingType.secret:
        final saved = savedSecrets.contains(field.key);
        secrets[field.key] = '';
        secretSaved[field.key] = saved;
        secretCleared[field.key] = false;
        secretHints[field.key] = saved ? strings.secretSavedHint : '';
      case PluginSettingType.boolean:
        settings[field.key] = value is bool && value;
      case PluginSettingType.select:
        settings[field.key] = [if (value is String) value];
      case _:
        settings[field.key] = value == null ? '' : '$value';
    }
  }

  final components = <Map<String, Object?>>[];
  final groups = <String>[];
  final allChecks = <Map<String, Object?>>[];
  for (final field in fields) {
    final groupId = 'group_${field.key}';
    groups.add(groupId);
    final description = field.description?.resolve(locale);
    components
      ..add({
        'id': groupId,
        'component': 'Column',
        'children': [
          field.isSecret ? _rowId(field.key) : _fieldId(field.key),
          if (description != null && description.isNotEmpty)
            'desc_${field.key}',
        ],
      })
      ..add(_fieldComponent(field, strings, locale));
    if (field.isSecret) {
      components
        ..add(
          pluginSecretRow(field.key, saved: savedSecrets.contains(field.key)),
        )
        ..add({
          'id': _clearId(field.key),
          'component': 'Button',
          'variant': 'borderless',
          'child': '${_clearId(field.key)}_label',
          'action': {
            'event': {
              'name': clearSecretEvent,
              'context': {'key': field.key},
            },
          },
        })
        ..add({
          'id': '${_clearId(field.key)}_label',
          'component': 'Text',
          'text': strings.clear,
        });
    }
    if (description != null && description.isNotEmpty) {
      components.add({
        'id': 'desc_${field.key}',
        'component': 'Text',
        'text': description,
        'variant': 'caption',
      });
    }
    allChecks.addAll(_checksOf(field, strings));
  }

  for (final action in actions) {
    final id = _actionId(action.name);
    components.addAll([
      {
        'id': id,
        'component': 'Button',
        'child': '${id}_label',
        'checks': _actionChecks(action, fields, strings, locale),
        'action': {
          'event': {
            'name': runActionEvent,
            'context': {'action': action.name},
          },
        },
      },
      {
        'id': '${id}_label',
        'component': 'Text',
        'text': action.title.resolve(locale),
      },
    ]);
  }

  components.addAll([
    {
      'id': 'root',
      'component': 'Column',
      'children': [...groups, 'footer'],
    },
    {
      'id': 'footer',
      'component': 'Row',
      'align': 'center',
      'children': [
        'save',
        for (final action in actions) _actionId(action.name),
      ],
    },
    {
      'id': 'save',
      'component': 'Button',
      'variant': 'primary',
      'child': 'save_label',
      'checks': allChecks,
      'action': {
        'event': {'name': saveConfigEvent},
      },
    },
    {'id': 'save_label', 'component': 'Text', 'text': strings.save},
  ]);

  final dataModel = <String, Object?>{
    'settings': settings,
    'secrets': secrets,
    'secretSaved': secretSaved,
    'secretCleared': secretCleared,
    'secretHints': secretHints,
  };
  dataModel['valid'] = pluginConfigValidity(fields: fields, data: dataModel);
  dataModel['actionReady'] = pluginActionReadiness(
    fields: fields,
    actions: actions,
    data: dataModel,
  );
  return [
    {
      'version': a2uiProtocolVersion,
      'createSurface': {
        'surfaceId': 'plugin-config',
        'components': components,
        'dataModel': dataModel,
      },
    },
  ];
}

/// 把页面数据读回为提交内容，并按字段规则校验；凭据按页面中的已保存／待清空状态判断必填，
/// 显式清空的必填凭据允许保存，由保存流程关闭插件。
({PluginConfigSubmission submission, Map<String, PluginSettingIssue> issues})
readPluginConfigSubmission({
  required List<PluginSettingField> fields,
  required Object? data,
}) {
  final root = data is Map ? data : const {};
  Map<Object?, Object?> section(String name) =>
      root[name] is Map ? root[name] as Map : const {};
  final settingsData = section('settings');
  final secretsData = section('secrets');
  final clearedData = section('secretCleared');
  final savedData = section('secretSaved');

  final settings = <String, Object?>{};
  final secrets = <String, String?>{};
  final issues = <String, PluginSettingIssue>{};
  for (final field in fields) {
    if (field.isSecret) {
      final draft = secretsData[field.key];
      if (draft is String && draft.isNotEmpty) {
        secrets[field.key] = draft;
      } else if (clearedData[field.key] == true) {
        secrets[field.key] = null;
      }
      final issue = secrets[field.key] != null
          ? validatePluginSettingValue(field, secrets[field.key])
          : (field.required &&
                    !secrets.containsKey(field.key) &&
                    savedData[field.key] != true
                ? PluginSettingIssue.missing
                : null);
      if (issue != null) {
        issues[field.key] = issue;
      }
      continue;
    }
    final raw = settingsData[field.key];
    Object? value;
    PluginSettingIssue? parseIssue;
    switch (field.type) {
      case PluginSettingType.boolean:
        value = raw is bool ? raw : false;
      case PluginSettingType.select:
        value = raw is List && raw.isNotEmpty ? raw.first : null;
      case PluginSettingType.integer:
        final text = '${raw ?? ''}'.trim();
        value = text.isEmpty ? null : int.tryParse(text);
        if (text.isNotEmpty && value == null) {
          parseIssue = PluginSettingIssue.not_integer;
        }
      case PluginSettingType.number:
        final text = '${raw ?? ''}'.trim();
        value = text.isEmpty ? null : num.tryParse(text);
        if (text.isNotEmpty && value == null) {
          parseIssue = PluginSettingIssue.not_number;
        }
      case _:
        value = raw is String && raw.isNotEmpty ? raw : null;
    }
    settings[field.key] = value;
    final issue = parseIssue ?? validatePluginSettingValue(field, value);
    if (issue != null) {
      issues[field.key] = issue;
    }
  }
  return (
    submission: PluginConfigSubmission(settings: settings, secrets: secrets),
    issues: issues,
  );
}

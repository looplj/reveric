// 职责: 解析插件清单 settings.actions 声明的设置页操作，并校验其依赖的配置字段。
// 关联文件:
//   lib/shared/models/plugin/manifest.dart
//   lib/shared/models/plugin/setting_field.dart
//   lib/shared/models/plugin/text.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/widgets/settings/plugins/config_surface.dart

import 'text.dart';

/// 清单 `settings.actions` 中声明的一个设置页操作，例如验证凭据。
class PluginAction {
  const PluginAction({
    required this.name,
    required this.title,
    this.requires = const [],
  });

  /// 插件用 `setup.settings.registerAction` 注册处理函数时使用的名称。
  final String name;
  final PluginText title;

  /// 执行前必须已有值的配置字段名。
  final List<String> requires;
}

/// 设置页操作的结果；[code] 只在失败时有值，供界面选择提示文案。
typedef PluginActionResult = ({bool ok, String? code});

final _namePattern = RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$');

/// 解析清单的 `settings.actions` 对象；省略时返回空列表。[settingKeys] 为已声明的配置字段名。
List<PluginAction> parsePluginActions(Object? json, Set<String> settingKeys) {
  if (json == null) {
    return const [];
  }
  if (json is! Map) {
    throw const FormatException('actions must be an object');
  }
  return [
    for (final MapEntry(:key, :value) in json.entries)
      _parseAction(key, value, settingKeys),
  ];
}

PluginAction _parseAction(Object? name, Object? json, Set<String> settingKeys) {
  if (name is! String || !_namePattern.hasMatch(name)) {
    throw FormatException('Invalid action name: $name');
  }
  if (json is! Map) {
    throw FormatException('actions.$name must be an object');
  }
  final title = parsePluginText(json['title'], 'actions.$name.title');
  final requires = json['requires'] ?? const <Object?>[];
  if (requires is! List ||
      requires.any((key) => key is! String || !settingKeys.contains(key))) {
    throw FormatException('actions.$name.requires must list declared settings');
  }
  return PluginAction(
    name: name,
    title: title,
    requires: List.unmodifiable(requires.cast<String>()),
  );
}

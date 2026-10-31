// 职责: 校验插件定时任务定义。
// 关联文件:
//   lib/shared/services/plugins/runtime.dart
//   lib/shared/services/plugins/tasks.dart
//   lib/shared/models/plugin/text.dart
import 'text.dart';

class PluginTaskDefinition {
  PluginTaskDefinition({
    required this.pluginId,
    required this.version,
    required Map<String, dynamic> definition,
  }) : definition = Map.unmodifiable(definition),
       title = parsePluginText(
         definition['title'],
         'task.title',
         maxLength: 200,
       ) {
    if (definition['id'] is! String ||
        !RegExp(
          r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$',
        ).hasMatch(definition['id'] as String) ||
        definition['intervalMinutes'] is! int ||
        definition['intervalMinutes'] < 15 ||
        definition['intervalMinutes'] > 10080 ||
        definition.keys.any(
          (k) => !const {'id', 'title', 'intervalMinutes'}.contains(k),
        )) {
      throw const FormatException('Invalid scheduled task definition');
    }
  }
  final String pluginId, version;
  final Map<String, dynamic> definition;
  final PluginText title;
  String get id => definition['id'] as String;
  int get intervalMinutes => definition['intervalMinutes'] as int;
}

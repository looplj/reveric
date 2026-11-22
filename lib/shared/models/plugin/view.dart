// 职责: 校验插件页面的协议、包内入口和声明式事件注册契约。
// 关联文件:
//   lib/shared/models/plugin/manifest.dart
//   lib/shared/services/plugins/runtime.dart
import 'text.dart';

class PluginView {
  PluginView(this.pluginId, Map<String, dynamic> value)
    : definition = Map.unmodifiable(value),
      title = parsePluginText(value['title'], 'view.title') {
    for (final key in ['id', 'location', 'protocol', 'source']) {
      if (value[key] is! String || (value[key] as String).trim().isEmpty) {
        throw FormatException('Invalid view $key');
      }
    }
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$').hasMatch(id) ||
        value['location'] != 'home.plugin' ||
        !['reveric-ui-v1', 'reveric-tsx-v1'].contains(protocol)) {
      throw const FormatException(
        'Invalid view identity, location or protocol',
      );
    }
    if (source.startsWith('/') ||
        source.contains('\\') ||
        source.contains(':') ||
        source.split('/').any((s) => s.isEmpty || s == '.' || s == '..') ||
        !source.endsWith(isTsx ? '.js' : '.json')) {
      throw const FormatException('Invalid view source');
    }
    final actions = value['actions'];
    if (actions != null &&
        (actions is! List ||
            actions.any(
              (a) =>
                  a is! String ||
                  !RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]{0,63}$').hasMatch(a),
            ))) {
      throw const FormatException('Invalid view actions');
    }
    if (actionNames.toSet().length != actionNames.length ||
        (value['onMount'] != null && !actionNames.contains(value['onMount'])) ||
        (isTsx && (actions != null || value.containsKey('onMount')))) {
      throw const FormatException('Invalid view mount/action contract');
    }
  }
  final String pluginId;
  final Map<String, dynamic> definition;
  final PluginText title;
  String get id => definition['id'] as String;
  String get protocol => definition['protocol'] as String;
  String get source => definition['source'] as String;
  bool get isTsx => protocol == 'reveric-tsx-v1';
  List<String> get actionNames =>
      (definition['actions'] as List? ?? const []).cast<String>();
}

/// 插件在 `storage` 中写入页面角标所使用的系统保留前缀。
const pluginPageBadgeStoragePrefix = '__system_internal_page_badge:';

enum PluginPageBadgeTone { accent, warning, danger }

/// 插件页面导航入口角标（数字胶囊或状态点）。
class PluginPageBadge {
  const PluginPageBadge({
    this.count,
    this.dot = false,
    this.tone = PluginPageBadgeTone.accent,
  });

  final int? count;
  final bool dot;
  final PluginPageBadgeTone tone;

  bool get isVisible => (count != null && count! > 0) || dot;

  static PluginPageBadge? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final rawCount = raw['count'];
    int? count;
    if (rawCount is int && rawCount > 0) {
      count = rawCount;
    } else if (rawCount is num &&
        rawCount > 0 &&
        rawCount == rawCount.toInt()) {
      count = rawCount.toInt();
    }
    final dot = raw['dot'] == true;
    if (count == null && !dot) {
      return null;
    }
    final tone = switch (raw['tone']) {
      'warning' => PluginPageBadgeTone.warning,
      'danger' => PluginPageBadgeTone.danger,
      _ => PluginPageBadgeTone.accent,
    };
    return PluginPageBadge(count: count, dot: dot, tone: tone);
  }

  @override
  bool operator ==(Object other) =>
      other is PluginPageBadge &&
      other.count == count &&
      other.dot == dot &&
      other.tone == tone;

  @override
  int get hashCode => Object.hash(count, dot, tone);
}

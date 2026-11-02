// 职责: 将 Agent 的设置导航请求连接到当前应用界面，并合并重复打开请求。
// 关联文件:
//   lib/settings_navigation_host.dart
//   lib/shared/services/ai/chat_turn_runner.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../logger/app_logger.dart';
import '../models/tool_permission.dart';

final _log = AppLogger.forModule('SettingsNavigation');

final settingsNavigationProvider = Provider<SettingsNavigation>((ref) {
  return SettingsNavigation();
});

class SettingsNavigation {
  Future<void> Function(String section)? openSection;
  Future<void>? _pending;
  String? _section;

  void open(String section) {
    final pending = _pending;
    if (pending != null) {
      if (_section != section) {
        throw ToolOperationException(
          'settings_already_open',
          'Settings are already open at $_section. Use the existing page or close it before opening another section.',
        );
      }
      return;
    }
    final open = openSection;
    if (open == null) {
      throw const ToolOperationException(
        'unavailable',
        'The application settings interface is not available.',
      );
    }
    final result = open(section);
    _section = section;
    _pending = result;
    unawaited(
      result.then<void>(
        (_) => _pending = null,
        onError: (Object error, StackTrace stack) {
          _pending = null;
          _log.error('settings route failed', error: error, stackTrace: stack);
        },
      ),
    );
  }
}

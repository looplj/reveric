// 职责: 统一插件页面的草稿检查与关闭契约，供包变更和导航生命周期共用。
// 关联文件:
//   lib/shared/services/plugins/ui_session.dart
//   lib/shared/services/plugins/a2ui_session.dart
//   lib/shared/services/plugins/host.dart
import 'package:flutter/foundation.dart';

abstract interface class PluginPageSession {
  ValueListenable<bool> get dirty;
  bool get closed;
  Future<void> close();
}

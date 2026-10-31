// 职责: 持有插件 A2UI 页面的草稿、消息会话与关闭取消状态。
// 关联文件:
//   lib/shared/widgets/a2ui/session.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/services/plugins/page_session.dart
import 'package:flutter/foundation.dart';
import '../../widgets/a2ui/session.dart';
import 'page_session.dart';

class PluginA2uiSession implements PluginPageSession {
  PluginA2uiSession({required this.onClose});
  final void Function() onClose;
  late final A2uiSurfaceSession surface;
  @override
  final ValueNotifier<bool> dirty = ValueNotifier(false);
  final actionError = ValueNotifier<Object?>(null);
  @override
  bool get closed => _closed;
  bool _closed = false;
  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    surface.cancelActions();
    onClose();
  }

  void dispose() {
    close();
    surface.dispose();
    dirty.dispose();
    actionError.dispose();
  }
}

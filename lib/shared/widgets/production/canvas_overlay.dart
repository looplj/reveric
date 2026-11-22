// 职责: 记录画布作品里剪辑和导演台是否盖住画布，并提供窗口顶栏避让尺寸。
// 关联文件:
//   lib/desktop/features/production/canvas_work.dart
//   lib/desktop/features/production/canvas_work_header.dart
//   lib/shared/widgets/screenplay/director_shell.dart
//   lib/desktop/features/editing/canvas_shell.dart
//   lib/desktop/features/editing/region.dart
// 注意事项:
// 盖住画布后作品顶栏整行卸下，剪辑和导演台自己的顶栏贴到窗口标题栏里。
// 世代号用来丢掉已经关闭的子页迟到注册。

import 'package:flutter/widgets.dart';

/// 画布作品顶栏与剪辑、导演台之间的开关。
///
/// 顶栏只看 [returnsToCanvas]；真正返回时调用最近一次登记的离开动作。
class CanvasWorkOverlayBus extends ChangeNotifier {
  final editingChromeKey = GlobalKey();
  final directorChromeKey = GlobalKey();
  double leadingInset = 0;
  double trailingInset = 0;
  double captionExtent = 0;
  var _disposed = false;
  var _director = false;
  var _editing = false;
  var _directorGeneration = 0;
  var _editingGeneration = 0;
  Future<void> Function()? _directorLeave;
  Future<void> Function()? _editingLeave;

  bool get returnsToCanvas => _director || _editing;

  int get directorGeneration => _directorGeneration;

  int get editingGeneration => _editingGeneration;

  void coverDirector(Future<void> Function() fallback) =>
      _cover(director: true, fallback: fallback);

  void uncoverDirector() => _uncover(director: true);

  void setDirectorLeave(int generation, Future<void> Function() leave) {
    if (_disposed || !_director || generation != _directorGeneration) {
      return;
    }
    _directorLeave = leave;
  }

  void coverEditing(Future<void> Function() fallback) =>
      _cover(director: false, fallback: fallback);

  void uncoverEditing() => _uncover(director: false);

  void setEditingLeave(int generation, Future<void> Function() leave) {
    if (_disposed || !_editing || generation != _editingGeneration) {
      return;
    }
    _editingLeave = leave;
  }

  /// 导演台盖在剪辑上面时，先离开导演台。
  Future<void> popToCanvas() {
    final leave = _director
        ? _directorLeave
        : _editing
        ? _editingLeave
        : null;
    if (_disposed || leave == null) {
      return Future<void>.value();
    }
    return leave();
  }

  void _cover({
    required bool director,
    required Future<void> Function() fallback,
  }) {
    if (_disposed) {
      return;
    }
    if (director) {
      _director = true;
      _directorGeneration++;
      _directorLeave = fallback;
    } else {
      _editing = true;
      _editingGeneration++;
      _editingLeave = fallback;
    }
    notifyListeners();
  }

  void _uncover({required bool director}) {
    if (_disposed) {
      return;
    }
    if (director) {
      if (!_director) {
        return;
      }
      _director = false;
      _directorLeave = null;
      _directorGeneration++;
    } else {
      if (!_editing) {
        return;
      }
      _editing = false;
      _editingLeave = null;
      _editingGeneration++;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class CanvasWorkOverlayScope extends InheritedNotifier<CanvasWorkOverlayBus> {
  const CanvasWorkOverlayScope({
    required CanvasWorkOverlayBus bus,
    required super.child,
  }) : super(notifier: bus);

  static CanvasWorkOverlayBus? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<CanvasWorkOverlayScope>()
        ?.notifier;
  }
}

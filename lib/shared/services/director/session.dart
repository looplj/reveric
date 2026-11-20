// 职责: 管理导演文档的编辑状态，并通过调用方回调请求保存和读取历史。
// 关联文件:
//   lib/shared/services/director/commands.dart
//   lib/shared/services/director/path_edit.dart
//   lib/shared/models/director/persistence.dart
//   lib/shared/models/director/document.dart
//   lib/shared/services/director/frame_validation.dart
import 'dart:async';
import 'path_edit.dart';

import 'package:flutter/foundation.dart';

import 'package:reveric/shared/models/director/document.dart';
import 'package:reveric/shared/services/director/commands.dart';

import '../../models/director/persistence.dart';
import 'frame_validation.dart';

class DirectorSession extends ChangeNotifier {
  final bool readOnly;
  final DirectorSave? onSave;
  final ValueChanged<DirectorDocument>? onChanged;
  final DirectorHistory? versions;
  final Future<List<Json>> Function(String? cameraId)? exportVersions;
  final ValueNotifier<int> exportsRevision = ValueNotifier(0);
  final CommandHistory history;
  late final PathEditSession pathEditor = PathEditSession(
    history,
    () => frame.value,
  );
  final Playhead frame = Playhead();
  String? selected, error;
  Json? poseClipboard;
  bool playing = false;
  // 编辑工具：select = 选择 / 移动，rotate = 旋转环。
  String tool = 'select';
  // 左栏当前分类：objects / actors / cameras / moves。
  String panel = 'objects';
  (int, int)? _range;
  String? _viewCamera, savedRevisionId;
  Future<void>? _saving;
  int _generation = 0;
  late DirectorDocument _lastDocument;
  bool hasPendingInput = false, _applyingForm = false;
  Object? _gestureOwner;
  int? _gesturePointer;
  Timer? _ticker;
  bool _disposed = false;
  DirectorSession(
    DirectorDocument document, {
    this.readOnly = false,
    this.onSave,
    this.onChanged,
    this.versions,
    this.exportVersions,
  }) : history = CommandHistory(document, readOnly: readOnly) {
    _lastDocument = document;
    history.addListener(_changed);
    history.validateEdit = (next) =>
        validateFrameEdit(history.document, next, frame.value);
    history.beforeEdit = () {
      if (readOnly) {
        throw StateError('Director session is read-only');
      }
      if (hasPendingInput && !_applyingForm) {
        throw const DocumentError('input', 'apply_pending');
      }
      pause();
    };
  }
  void _changed() {
    if (frame.value > history.document.durationFrames) {
      frame.value = history.document.durationFrames;
    }
    final document = history.document;
    if (_viewCamera != null &&
        !document.activeCameras.any((c) => c['id'] == _viewCamera)) {
      _viewCamera = null;
    }
    if (!identical(_lastDocument, document)) {
      final changed = _lastDocument.businessContent != document.businessContent;
      _lastDocument = document;
      if (changed) {
        onChanged?.call(document);
      }
    }
    notifyListeners();
  }

  void report(Object e, StackTrace st) {
    debugPrint('director operation error=${e.runtimeType}\n$st');
    error = e is DocumentError ? '${e.path}: ${e.reason}' : 'operation_failed';
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> attempt(FutureOr<void> Function() action) async {
    try {
      error = null;
      await action();
      if (!_disposed) {
        notifyListeners();
      }
    } catch (e, st) {
      report(e, st);
    }
  }

  bool claimEditGesture(Object owner, int pointer) {
    if (readOnly) {
      return false;
    }
    if (_gestureOwner != null) {
      cancelEditGesture();
      return false;
    }
    _gestureOwner = owner;
    _gesturePointer = pointer;
    return true;
  }

  void releaseEditGesture(Object owner, int pointer) {
    if (identical(_gestureOwner, owner) && _gesturePointer == pointer) {
      _gestureOwner = null;
      _gesturePointer = null;
    }
  }

  void cancelEditGesture() {
    _gestureOwner = null;
    _gesturePointer = null;
    history.cancelGesture();
  }

  void refresh() {
    notifyListeners();
  }

  void submitForm(void Function() action) {
    _applyingForm = true;
    try {
      action();
    } finally {
      _applyingForm = false;
    }
  }

  void suspendForUnmount() {
    pathEditor.cancel();
    _ticker?.cancel();
    _ticker = null;
    playing = false;
    history.preview = null;
  }

  void select(String? id) {
    if (hasPendingInput && id != selected) {
      error = 'apply_pending';
      notifyListeners();
      return;
    }
    if (pathEditor.active && pathEditor.visible!['target_id'] != id) {
      pathEditor.cancel();
    }
    selected = id;
    if (history.document.camera(id) != null) {
      _viewCamera = id;
    }
    notifyListeners();
  }

  void setPanel(String value) {
    if (readOnly && value != 'objects') {
      return;
    }
    panel = value;
    notifyListeners();
  }

  void setTool(String value) {
    if (readOnly) {
      return;
    }
    tool = value;
    notifyListeners();
  }

  /// 预设套用的帧选区，默认整段。
  (int, int) get range {
    final d = history.document.durationFrames, r = _range;
    if (r == null || r.$2 > d || r.$1 >= r.$2) {
      return (0, d);
    }
    return r;
  }

  void setRange(int start, int end) {
    if (readOnly) {
      return;
    }
    final d = history.document.durationFrames;
    final a = start.clamp(0, d), b = end.clamp(0, d);
    _range = a == b ? null : (a < b ? (a, b) : (b, a));
    notifyListeners();
  }

  /// 观察模式属于会话，不改写文档与切镜。
  String get cameraMode => _viewCamera == null ? 'sequence' : 'fixed';
  String get viewCameraId {
    final document = history.visible;
    return document.activeCameras.any((c) => c['id'] == _viewCamera)
        ? _viewCamera!
        : document.cameraAt(frame.value);
  }

  void viewCamera(String? id) {
    _viewCamera = id;
    notifyListeners();
  }

  Future<List<DirectorRevision>> historyEntries() => versions!.list();

  /// 恢复历史是一条可撤销命令；文档归属由调用方保持。
  Future<void> restoreHistory(DirectorRevision entry) async {
    if (readOnly) {
      throw StateError('Director session is read-only');
    }
    final generation = _generation;
    final before = history.document;
    final snapshot = await versions!.load(entry.id);
    if (_disposed ||
        generation != _generation ||
        !identical(before, history.document)) {
      throw const DocumentError('history', 'operation_failed');
    }
    restore(snapshot);
  }

  void restore(DirectorDocument snapshot) {
    if (readOnly) {
      throw StateError('Director session is read-only');
    }
    final id = history.document.id;
    history.execute((j) {
      j.clear();
      j.addAll(snapshot.toJson());
      j['id'] = id;
      for (final track in j['tracks'] as List) {
        if (track['target_id'] == snapshot.id &&
            (track['property'] as String).startsWith('lighting.')) {
          track['target_id'] = id;
        }
      }
    }, validate: false);
    selected = null;
    _range = null;
    _viewCamera = null;
    refresh();
  }

  void seek(int value) {
    if (hasPendingInput) {
      error = 'apply_pending';
      notifyListeners();
      return;
    }
    pause();
    frame.value = value.clamp(0, history.document.durationFrames);
  }

  void play() {
    if (hasPendingInput) {
      throw const DocumentError('input', 'apply_pending');
    }
    if (playing) {
      pause();
      return;
    }
    if (frame.value == history.document.durationFrames) {
      frame.value = 0;
    }
    playing = true;
    final watch = Stopwatch()..start(), start = frame.value;
    _ticker = Timer.periodic(const Duration(milliseconds: 33), (_) {
      final next = start + (watch.elapsedMicroseconds * 24 / 1000000).round();
      frame.tick(next.clamp(0, history.document.durationFrames));
      if (next >= history.document.durationFrames) {
        pause();
      }
    });
    notifyListeners();
  }

  void pause() {
    _ticker?.cancel();
    _ticker = null;
    if (playing) {
      playing = false;
      notifyListeners();
    }
  }

  bool get saving => _saving != null;

  Future<void> save() {
    if (readOnly) {
      return Future.error(StateError('Director session is read-only'));
    }
    if (hasPendingInput) {
      return Future.error(const DocumentError('input', 'apply_pending'));
    }
    if (_saving != null) {
      return _saving!;
    }
    final save = onSave;
    if (save == null) {
      return Future.error(StateError('No save callback supplied'));
    }
    final snapshot = history.document;
    final generation = _generation;
    final operation = Future<DirectorRevision?>.sync(() => save(snapshot)).then(
      (revision) {
        if (!_disposed && generation == _generation) {
          savedRevisionId = revision?.id;
          history.markSaved(revision?.savedDocument ?? snapshot);
        }
      },
    );
    _saving = operation.whenComplete(() {
      _saving = null;
      if (!_disposed) {
        notifyListeners();
      }
    });
    notifyListeners();
    return _saving!;
  }

  void replace(DirectorDocument document, {bool saved = false}) {
    pathEditor.cancel();
    pause();
    _generation++;
    savedRevisionId = null;
    _viewCamera = null;
    _lastDocument = document;
    history.replace(document, saved: saved);
    frame.value = 0;
    selected = null;
    _range = null;
  }

  void background() {
    pause();
    cancelEditGesture();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    history.removeListener(_changed);
    pathEditor.dispose();
    history.dispose();
    frame.dispose();
    exportsRevision.dispose();
    super.dispose();
  }
}

class Playhead extends ValueNotifier<int> {
  Playhead() : super(0);
  void tick(int frame) {
    if (value == frame) {
      notifyListeners();
    } else {
      value = frame;
    }
  }
}

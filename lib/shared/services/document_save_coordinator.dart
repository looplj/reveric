// 职责: 串行化文档自动保存 — 合并防抖期间的新快照，并在切换前可靠 flush。
// 关联文件:
//   lib/shared/services/screenplay_service.dart
//   lib/desktop/features/screenplay/script.dart
//   lib/mobile/features/screenplay/script_page.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md

import 'dart:async';

import 'package:flutter/foundation.dart';

class DocumentSaveCoordinator<T> extends ChangeNotifier {
  DocumentSaveCoordinator({
    required this._save,
    this.debounce = const Duration(milliseconds: 600),
  });

  final Future<void> Function(T snapshot) _save;
  final Duration debounce;

  Timer? _timer;
  T? _pending;
  Future<void>? _draining;
  bool _disposed = false;
  int _revision = 0;
  int _savedRevision = 0;
  Object? _lastError;

  bool get isDirty => _pending != null || _savedRevision < _revision;
  bool get isSaving => _draining != null;
  Object? get lastError => _lastError;

  void schedule(T snapshot) {
    _pending = snapshot;
    _revision += 1;
    _lastError = null;
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(_startDrain().onError((_, _) {})));
    notifyListeners();
  }

  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    await _startDrain();
  }

  Future<void> retry() => flush();

  void rebasePending(T snapshot) {
    if (_pending != null) {
      _pending = snapshot;
    }
  }

  void discardPending() {
    if (isSaving) {
      throw StateError('Cannot discard an active save.');
    }
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _savedRevision = _revision;
    _lastError = null;
    notifyListeners();
  }

  Future<void> _startDrain() {
    return _draining ??= _drain().whenComplete(() {
      _draining = null;
      if (!_disposed) {
        notifyListeners();
      }
    });
  }

  Future<void> _drain() async {
    while (_pending != null) {
      final snapshot = _pending as T;
      final savingRevision = _revision;
      _pending = null;
      if (!_disposed) {
        notifyListeners();
      }
      try {
        await _save(snapshot);
        _savedRevision = savingRevision;
        _lastError = null;
      } catch (error) {
        _pending ??= snapshot;
        _lastError = error;
        rethrow;
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

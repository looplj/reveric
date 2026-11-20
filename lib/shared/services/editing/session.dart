// 职责: 持有一次剪辑会话的撤销历史、串行自动保存和失败后保留的内存修改。
// 关联文件:
//   lib/shared/services/editing/commands.dart
//   lib/shared/services/editing/service.dart
//   lib/desktop/features/editing/region.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../models/editing/document.dart';
import 'service.dart';
import '../production/ffmpeg_runner.dart';

class EditingSession extends ChangeNotifier {
  EditingSession(this.projects, this.editingId, {this.readOnly = false});
  final EditingService projects;
  final String editingId;
  final bool readOnly;
  String title = '';
  EditingDocument? document;
  EditingDocument? _saved;
  String _savedTitle = '';
  Future<void>? _loading;
  bool commandBusy = false;
  int _leases = 0;
  void Function() retain() {
    _leases++;
    var released = false;
    return () {
      if (!released) {
        released = true;
        _leases--;
      }
    };
  }

  bool get evictable =>
      _leases == 0 &&
      !hasListeners &&
      !dirty &&
      !saving &&
      !commandBusy &&
      _loading == null;
  Future<void> ensureLoaded() => document != null
      ? Future.value()
      : (_loading ??= load().whenComplete(() => _loading = null));
  int revision = 0;
  String? selectedId;
  Object? error;
  EditingSourceProblem? sourceProblem;
  final _sourceToken = MediaCancellation();
  bool saving = false;
  bool _disposed = false;
  Future<void>? _pending;
  final _past = <(EditingDocument, String)>[];
  final _future = <(EditingDocument, String)>[];
  bool get dirty =>
      !readOnly && (!identical(document, _saved) || title != _savedTitle);
  bool get canUndo => !readOnly && _past.isNotEmpty;
  bool get canRedo => !readOnly && _future.isNotEmpty;
  EditingClip? get selected =>
      document?.clips.where((c) => c.id == selectedId).firstOrNull;
  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> load() async {
    final row = await projects.read(editingId);
    final doc = row.document;
    final rev = row.revision;
    title = _savedTitle = row.title;
    document = _saved = doc;
    revision = rev;
    error = null;
    sourceProblem = null;
    {
      try {
        await projects.verify(doc, _sourceToken);
      } on EditingSourceProblem catch (problem) {
        sourceProblem = problem;
      }
    }
    _notify();
  }

  void select(String? id) {
    selectedId = id;
    _notify();
  }

  void commit(EditingDocument next) {
    if (readOnly) {
      throw StateError('Editing session is read-only');
    }
    if (commandBusy) {
      throw const EditingConflict();
    }
    next.validate();
    if (document != null) {
      _past.add((document!, title));
    }
    if (_past.length > 100) {
      _past.removeAt(0);
    }
    _future.clear();
    if (sourceProblem != null) {
      final remaining = sourceProblem!.ids.where((id) {
        final old = document?.clips.where((c) => c.id == id).firstOrNull;
        final replacement = next.clips.where((c) => c.id == id).firstOrNull;
        return old != null &&
            replacement != null &&
            mapEquals(
              old.media?.source.toJson(),
              replacement.media?.source.toJson(),
            ) &&
            old.media?.sourceInUs == replacement.media?.sourceInUs &&
            old.media?.speed == replacement.media?.speed &&
            old.durationFrames == replacement.durationFrames;
      }).toList();
      sourceProblem = remaining.isEmpty
          ? null
          : EditingSourceProblem(remaining);
    }
    document = next;
    _notify();
    if (error == null) {
      unawaited(flush().catchError((Object _) {}));
    }
  }

  void undo() {
    if (readOnly) {
      return;
    }
    if (commandBusy) {
      throw const EditingConflict();
    }
    if (!canUndo) {
      return;
    }
    _future.add((document!, title));
    final previous = _past.removeLast();
    document = previous.$1;
    title = previous.$2;
    _notify();
    if (error == null) {
      unawaited(flush().catchError((Object _) {}));
    }
  }

  void redo() {
    if (readOnly) {
      return;
    }
    if (commandBusy) {
      throw const EditingConflict();
    }
    if (!canRedo) {
      return;
    }
    _past.add((document!, title));
    final next = _future.removeLast();
    document = next.$1;
    title = next.$2;
    _notify();
    if (error == null) {
      unawaited(flush().catchError((Object _) {}));
    }
  }

  Future<void> flush() {
    if (readOnly) {
      return Future.value();
    }
    if (_pending != null) {
      return _pending!;
    }
    if (!dirty) {
      return Future.value();
    }
    final completer = Completer<void>();
    _pending = completer.future;
    Future<void>(() async {
      saving = true;
      _notify();
      try {
        while (dirty && document != null) {
          final snapshot = document!;
          final name = title;
          revision = await projects.database.editingDao.save(
            editingId,
            document: snapshot,
            title: name,
            expectedRevision: revision,
          );
          _saved = snapshot;
          _savedTitle = name;
        }
        error = null;
        completer.complete();
      } catch (e, stack) {
        error = e;
        completer.completeError(e, stack);
      } finally {
        saving = false;
        _pending = null;
        _notify();
      }
    });
    return completer.future;
  }

  Future<T> transact<T>(
    int expectedRevision,
    Future<({EditingDocument document, String title, T result})> Function(
      EditingDocument,
      String,
    )
    action, {
    String? history,
  }) async {
    if (readOnly) {
      throw StateError('Editing session is read-only');
    }
    await ensureLoaded();
    if (commandBusy) {
      throw const EditingConflict();
    }
    await flush();
    if (revision != expectedRevision || error != null || commandBusy) {
      throw const EditingConflict();
    }
    commandBusy = true;
    _notify();
    try {
      final before = (document!, title);
      final result = await action(document!, title);
      result.document.validate();
      final nextRevision = await projects.database.editingDao.save(
        editingId,
        expectedRevision: expectedRevision,
        document: result.document,
        title: result.title,
      );
      if (history == 'undo') {
        _past.removeLast();
        _future.add(before);
      } else if (history == 'redo') {
        _future.removeLast();
        _past.add(before);
      } else {
        _past.add(before);
        _future.clear();
      }
      if (_past.length > 100) {
        _past.removeAt(0);
      }
      revision = nextRevision;
      document = _saved = result.document;
      title = _savedTitle = result.title;
      error = null;
      return result.result;
    } finally {
      commandBusy = false;
      _notify();
    }
  }

  Future<void> travel(int expected, {required bool redo}) =>
      transact<void>(expected, (doc, name) async {
        final history = redo ? _future : _past;
        if (history.isEmpty) {
          throw StateError('Editing history is unavailable');
        }
        final next = history.last;
        return (document: next.$1, title: next.$2, result: null);
      }, history: redo ? 'redo' : 'undo');

  Future<void> reload() async {
    if (_pending != null) {
      await _pending!.catchError((Object _) {});
    }
    await load();
    _past.clear();
    _future.clear();
    selectedId = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sourceToken.cancel());
    super.dispose();
  }
}

// 职责: 保存制作画布结构操作的局部行快照，并在冲突检查后原子撤销或重做。
// 关联文件:
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/production/group_service.dart
//   lib/shared/services/storyboard/service.dart
//   lib/shared/database/novel_content_daos/canvas_dao.dart
import 'dart:async';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../database/novel_content_database.dart';
import '../storyboard/service.dart';

final _promptCleanupScopeKey = Object();

class _PromptCleanupScope {
  _PromptCleanupScope(this.shots);
  final StoryboardService shots;
  final changes = <String, ({String before, String after})>{};
}

/// 仅文本结构删除可声明提示词恢复字段；普通 prompt 保存不进入这份名单。
void recordCanvasPromptCleanup(
  StoryboardService shots,
  String clipId, {
  required String before,
  required String after,
}) {
  final scope = Zone.current[_promptCleanupScopeKey] as _PromptCleanupScope?;
  if (scope == null || before == after) {
    return;
  }
  if (!identical(scope.shots.database, shots.database)) {
    throw StateError('Canvas prompt cleanup belongs to a different database');
  }
  final previous = scope.changes[clipId];
  if (previous != null && previous.after != before) {
    throw StateError('Unrelated prompt write during canvas text deletion');
  }
  scope.changes[clipId] = (before: previous?.before ?? before, after: after);
}

/// 界面可以将冲突转换成提示；失败步骤已经移出对应栈，其他步骤仍保留。
class CanvasHistoryConflict implements Exception {
  const CanvasHistoryConflict();
}

/// 服务入口显式选择记录；AI 和后台调用不传 history。
Future<T> withCanvasHistory<T>(
  CanvasHistory? history,
  StoryboardService shots,
  String label,
  Iterable<String> nodeIds,
  Future<T> Function() action,
) {
  if (history == null) {
    return action();
  }
  if (!identical(history.shots.database, shots.database)) {
    throw ArgumentError('Canvas history belongs to a different database');
  }
  return history.record(label, nodeIds: nodeIds, action: action);
}

class CanvasHistory extends ChangeNotifier {
  CanvasHistory(this.shots, this.canvasId);
  final StoryboardService shots;
  final String canvasId;
  NovelContentDatabase get _db => shots.database;
  static const limit = 100;
  final _undo = <_CanvasHistoryStep>[];
  final _redo = <_CanvasHistoryStep>[];
  Future<void> _tail = Future<void>.value();
  bool _disposed = false;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get undoCount => _undo.length;
  int get redoCount => _redo.length;

  Future<T> _serial<T>(Future<T> Function() action) {
    // 由此入口拥有最外层事务，否则外层回滚时无法安全提交内存记录。
    if (_db.isInTransaction) {
      throw StateError('Canvas history must own the outer transaction');
    }
    if (_disposed) {
      throw StateError('Canvas history is disposed');
    }
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  /// 新建方法返回节点；其节点、clip 和相关边自动加入 after 的范围。
  /// 组合操作可用此入口包住多个不带 history 的服务调用，返回所有新节点。
  Future<T> record<T>(
    String label, {
    required Iterable<String> nodeIds,
    required Future<T> Function() action,
  }) => _serial(() async {
    late _CanvasHistoryStep step;
    final result = await shots.write('HISTORY_RECORD', canvasId, () async {
      final roots = nodeIds.toSet();
      final before = await _capture(roots);
      final cleanup = _PromptCleanupScope(shots);
      final result = await runZoned(
        action,
        zoneValues: {_promptCleanupScopeKey: cleanup},
      );
      if (result is CanvasNode) {
        roots.add(result.id);
      } else if (result is Iterable<CanvasNode>) {
        roots.addAll(result.map((node) => node.id));
      }
      final after = await _capture(roots, include: before);
      for (final entry in cleanup.changes.entries) {
        if (before.clips[entry.key]?.prompt != entry.value.before ||
            after.clips[entry.key]?.prompt != entry.value.after) {
          throw StateError(
            'Prompt cleanup must be isolated to captured text deletion',
          );
        }
      }
      step = _CanvasHistoryStep(
        label,
        roots,
        before,
        after,
        cleanup.changes.keys.toSet(),
      );
      return result;
    });
    if (!_disposed && !step.before.same(step.after)) {
      _undo.add(step);
      if (_undo.length > limit) {
        _undo.removeAt(0);
      }
      _redo.clear();
      notifyListeners();
    }
    return result;
  });

  Future<void> undo() => _restore(redo: false);
  Future<void> redo() => _restore(redo: true);

  Future<void> _restore({required bool redo}) => _serial(() async {
    final source = redo ? _redo : _undo;
    final destination = redo ? _undo : _redo;
    if (source.isEmpty) {
      return;
    }
    final step = source.last;
    try {
      final restored = await shots.write(
        redo ? 'HISTORY_REDO' : 'HISTORY_UNDO',
        canvasId,
        () async {
          final current = await _capture(step.roots, include: step.expected);
          if (!current.same(step.expected)) {
            throw const CanvasHistoryConflict();
          }
          await _write(
            redo ? step.after : step.before,
            current,
            step.promptClipIds,
          );
          return _capture(step.roots, include: current);
        },
      );
      step.expected = restored;
      source.removeLast();
      destination.add(step);
    } on CanvasHistoryConflict {
      source.removeLast();
      if (!_disposed) {
        notifyListeners();
      }
      rethrow;
    }
    if (!_disposed) {
      notifyListeners();
    }
  });

  Future<_Snapshot> _capture(Set<String> roots, {_Snapshot? include}) async {
    final nodeIds = {...roots, ...?include?.nodes.keys};
    // 只有节点自身的 clip 扩展共享节点；下游快照 clip 不能反向纳入节点。
    final clipIds = <String>{};
    final nodes = <String, CanvasNode>{};
    // 自动闭包只扩展有效关联行；显式根与已有快照仍保留 tombstone。
    // 后一步撤销产生的软删成员不应进入更早的父组快照。
    var previousSize = -1;
    while (previousSize != nodeIds.length) {
      previousSize = nodeIds.length;
      final rows =
          await (_db.select(_db.canvasNodes)..where(
                (t) =>
                    t.id.isIn(nodeIds) |
                    (t.deletedAt.equals(notDeletedSentinel) &
                        (t.parentId.isIn(nodeIds) |
                            (t.refType.equals(canvasNodeRefTypeProductionClip) &
                                t.refId.isIn(clipIds)))),
              ))
              .get();
      for (final node in rows) {
        if (node.canvasId != canvasId) {
          throw ArgumentError('Canvas history cannot span canvases');
        }
        nodes[node.id] = node;
        nodeIds.add(node.id);
        if (node.clipId case final id?) {
          clipIds.add(id);
        }
      }
      // 初次读取根时发现 clip，还需一次查找引用同一 clip 的其他节点。
      if (rows.any((node) => node.clipId != null) &&
          previousSize == nodeIds.length) {
        final shared =
            await (_db.select(_db.canvasNodes)..where(
                  (t) =>
                      t.deletedAt.equals(notDeletedSentinel) &
                      t.refType.equals(canvasNodeRefTypeProductionClip) &
                      t.refId.isIn(clipIds),
                ))
                .get();
        nodeIds.addAll(shared.map((node) => node.id));
      }
    }
    final clips = <String, ProductionClipRow>{};
    // inputs 为 converter 字段；只把真正引用范围内节点的下游行纳入快照。
    for (final clip in await _db.select(_db.productionClips).get()) {
      if (clipIds.contains(clip.id) ||
          (include?.clips.containsKey(clip.id) ?? false) ||
          (clip.deletedAt == notDeletedSentinel &&
              clip.inputs.any(
                (input) => nodeIds.contains(input.sourceNodeId),
              ))) {
        clips[clip.id] = clip;
      }
    }
    final edges =
        await (_db.select(_db.canvasEdges)..where(
              (t) =>
                  t.sourceNodeId.isIn(nodeIds) |
                  t.targetNodeId.isIn(nodeIds) |
                  t.id.isIn(include?.edges.keys ?? const <String>[]),
            ))
            .get();
    final editingIds = {
      ...?include?.editings.keys,
      for (final node in nodes.values)
        if (node.type == canvasNodeTypeEditing && node.editingId != null)
          node.editingId!,
    };
    final editings = await (_db.select(
      _db.videoEditings,
    )..where((t) => t.id.isIn(editingIds))).get();
    return _Snapshot(
      nodes,
      {for (final edge in edges) edge.id: edge},
      clips,
      {for (final row in editings) row.id: row},
    );
  }

  Future<void> _write(
    _Snapshot target,
    _Snapshot current,
    Set<String> promptClipIds,
  ) async {
    final now = DateTime.now();
    for (final row in current.edges.values) {
      if (!target.edges.containsKey(row.id)) {
        await _db.canvasDao.hardDeleteEdge(row.id);
      }
    }
    for (final row in current.nodes.values) {
      await _db.canvasDao.restoreHistoryNode(
        target.nodes[row.id] ?? row.copyWith(deletedAt: now),
      );
    }
    for (final row in target.nodes.values) {
      if (!current.nodes.containsKey(row.id)) {
        await _db.canvasDao.restoreHistoryNode(row);
      }
    }
    for (final row in current.clips.values) {
      final previous = target.clips[row.id];
      await (_db.update(
        _db.productionClips,
      )..where((t) => t.id.equals(row.id))).write(
        ProductionClipsCompanion(
          inputs: Value(previous?.inputs ?? row.inputs),
          prompt: promptClipIds.contains(row.id) && previous != null
              ? Value(previous.prompt)
              : const Value.absent(),
          deletedAt: Value(previous?.deletedAt ?? now),
          updatedAt: Value(previous?.updatedAt ?? row.updatedAt),
        ),
      );
    }
    for (final row in current.editings.values) {
      final previous = target.editings[row.id];
      await (_db.update(
        _db.videoEditings,
      )..where((t) => t.id.equals(row.id))).write(
        VideoEditingsCompanion(
          deletedAt: Value(previous?.deletedAt ?? now),
          updatedAt: Value(previous?.updatedAt ?? row.updatedAt),
        ),
      );
    }
    for (final row in target.edges.values) {
      await _db.canvasDao.restoreHistoryEdge(row);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _undo.clear();
    _redo.clear();
    super.dispose();
  }
}

class _CanvasHistoryStep {
  _CanvasHistoryStep(
    this.label,
    this.roots,
    this.before,
    this.after,
    this.promptClipIds,
  ) : expected = after;
  final String label;
  final Set<String> roots;
  final _Snapshot before, after;
  final Set<String> promptClipIds;
  _Snapshot expected;
}

class _Snapshot {
  _Snapshot(this.nodes, this.edges, this.clips, this.editings);
  final Map<String, CanvasNode> nodes;
  final Map<String, CanvasEdge> edges;
  final Map<String, ProductionClipRow> clips;
  final Map<String, VideoEditingRow> editings;
  bool same(_Snapshot other) => const DeepCollectionEquality().equals(
    [
      nodes.map((id, row) => MapEntry(id, row.toJson())),
      edges.map((id, row) => MapEntry(id, row.toJson())),
      clips.map((id, row) => MapEntry(id, _clipJson(row))),
      editings.map((id, row) => MapEntry(id, _editingJson(row))),
    ],
    [
      other.nodes.map((id, row) => MapEntry(id, row.toJson())),
      other.edges.map((id, row) => MapEntry(id, row.toJson())),
      other.clips.map((id, row) => MapEntry(id, _clipJson(row))),
      other.editings.map((id, row) => MapEntry(id, _editingJson(row))),
    ],
  );
}

Map<String, dynamic> _clipJson(ProductionClipRow row) => {
  ...row.toJson(),
  'inputs': row.inputs.map((input) => input.toJson()).toList(),
};

Map<String, dynamic> _editingJson(VideoEditingRow row) => {
  ...row.toJson(),
  'document': row.document.toJson(),
};

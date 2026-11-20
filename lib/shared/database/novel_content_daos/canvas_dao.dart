// 职责: 画布数据访问对象 — 封装 canvases/canvas_nodes/canvas_edges 的数据库操作与级联
// 关联文件:
//   lib/shared/database/novel_content_database.dart
//   lib/shared/services/canvas_service.dart
//   lib/shared/providers/novel_providers.dart
// 遵循的 Rules:
//   .agents/rules/db-migration.md
//   .agents/rules/db-query-aggregation.md

import 'package:drift/drift.dart';

import '../novel_content_database.dart';

part 'canvas_dao.drift.dart';

@DriftAccessor(tables: [Canvases, CanvasNodes, CanvasEdges])
class CanvasDao extends DatabaseAccessor<NovelContentDatabase>
    with _$CanvasDaoMixin {
  CanvasDao(super.db);

  // ---- Canvas ----

  Future<List<CanvasEntry>> getAllCanvases() {
    return (select(canvases)
          ..where(
            (t) =>
                t.deletedAt.equals(notDeletedSentinel) &
                t.kind.isIn(canvasKinds),
          )
          ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]))
        .get();
  }

  Future<CanvasEntry?> getCanvasById(String id) {
    return (select(canvases)..where(
          (t) => t.id.equals(id) & t.deletedAt.equals(notDeletedSentinel),
        ))
        .getSingleOrNull();
  }

  Stream<List<CanvasEntry>> watchAllCanvases() {
    return (select(canvases)
          ..where(
            (t) =>
                t.deletedAt.equals(notDeletedSentinel) &
                t.kind.isIn(canvasKinds),
          )
          ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]))
        .watch();
  }

  Stream<CanvasEntry?> watchCanvasById(String id) {
    return (select(canvases)..where(
          (t) => t.id.equals(id) & t.deletedAt.equals(notDeletedSentinel),
        ))
        .watchSingleOrNull();
  }

  Future<void> upsertCanvas(CanvasEntry canvas) async {
    await into(
      canvases,
    ).insertOnConflictUpdate(canvas.copyWith(updatedAt: DateTime.now()));
  }

  Future<bool> canvasIdExists(String id) async {
    final row =
        await (selectOnly(canvases)
              ..addColumns([canvases.id])
              ..where(canvases.id.equals(id))
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  Future<void> insertCanvas(CanvasEntry canvas) {
    return into(canvases).insert(canvas);
  }

  Future<void> updateActiveCanvas(CanvasEntry canvas) async {
    final count =
        await (update(canvases)..where(
              (table) =>
                  table.id.equals(canvas.id) &
                  table.deletedAt.equals(notDeletedSentinel),
            ))
            .write(canvas.copyWith(updatedAt: DateTime.now()));
    if (count != 1) {
      throw ArgumentError('Canvas is no longer available: ${canvas.id}');
    }
  }

  /// 元信息局部写入，不让旧名称/描述快照覆盖正在保存的 layout。
  Future<void> updateMetadata(
    String canvasId, {
    String? name,
    String? description,
  }) async {
    final count =
        await (update(canvases)..where(
              (table) =>
                  table.id.equals(canvasId) &
                  table.deletedAt.equals(notDeletedSentinel),
            ))
            .write(
              CanvasesCompanion(
                name: name == null ? const Value.absent() : Value(name),
                description: description == null
                    ? const Value.absent()
                    : Value(description),
                updatedAt: Value(DateTime.now()),
              ),
            );
    if (count != 1) {
      throw ArgumentError('Canvas is no longer available: $canvasId');
    }
  }

  /// 软删画布并级联:节点软删、边硬删。
  Future<int> softDeleteCanvas(String id) async {
    final now = DateTime.now();
    await attachedDatabase.transaction(() async {
      await (update(canvasNodes)
            ..where((t) => t.canvasId.equals(id))
            ..where((t) => t.deletedAt.equals(notDeletedSentinel)))
          .write(
            CanvasNodesCompanion(deletedAt: Value(now), updatedAt: Value(now)),
          );
      await (delete(canvasEdges)..where((t) => t.canvasId.equals(id))).go();
      await (update(canvases)..where((t) => t.id.equals(id))).write(
        CanvasesCompanion(deletedAt: Value(now), updatedAt: Value(now)),
      );
    });
    return 1;
  }

  // ---- CanvasNode ----

  Future<List<CanvasNode>> getNodesByCanvas(String canvasId) {
    return (select(canvasNodes)
          ..where(
            (t) =>
                t.canvasId.equals(canvasId) &
                t.deletedAt.equals(notDeletedSentinel),
          )
          ..orderBy([
            (t) => OrderingTerm(expression: t.sortOrder),
            (t) => OrderingTerm(expression: t.id),
          ]))
        .get();
  }

  Future<CanvasNode?> getNodeById(String id) {
    return (select(canvasNodes)..where(
          (t) => t.id.equals(id) & t.deletedAt.equals(notDeletedSentinel),
        ))
        .getSingleOrNull();
  }

  Stream<List<CanvasNode>> watchNodesByCanvas(String canvasId) {
    return (select(canvasNodes)
          ..where(
            (t) =>
                t.canvasId.equals(canvasId) &
                t.deletedAt.equals(notDeletedSentinel),
          )
          ..orderBy([
            (t) => OrderingTerm(expression: t.sortOrder),
            (t) => OrderingTerm(expression: t.id),
          ]))
        .watch();
  }

  Stream<CanvasNode?> watchNodeById(String id) {
    return (select(canvasNodes)..where(
          (t) => t.id.equals(id) & t.deletedAt.equals(notDeletedSentinel),
        ))
        .watchSingleOrNull();
  }

  Future<void> upsertNode(CanvasNode node) async {
    await into(
      canvasNodes,
    ).insertOnConflictUpdate(node.copyWith(updatedAt: DateTime.now()));
  }

  /// 仅供已完成冲突检查的历史恢复；保留快照时间戳和软删除状态。
  Future<void> restoreHistoryNode(CanvasNode node) =>
      into(canvasNodes).insertOnConflictUpdate(node.toCompanion(false));

  /// 恢复原连线身份；不刷新 updatedAt，连续撤销仍可比对原快照。
  Future<void> restoreHistoryEdge(CanvasEdge edge) =>
      into(canvasEdges).insertOnConflictUpdate(edge.toCompanion(false));

  Future<bool> nodeIdExists(String id) async {
    final row =
        await (selectOnly(canvasNodes)
              ..addColumns([canvasNodes.id])
              ..where(canvasNodes.id.equals(id))
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  Future<void> insertNode(CanvasNode node) {
    return into(canvasNodes).insert(node);
  }

  /// 只写调用方指定字段，避免旧行快照覆盖并发保存的布局或正文。
  Future<void> updateActiveNodeFields(
    String nodeId,
    CanvasNodesCompanion changes,
  ) async {
    final count =
        await (update(canvasNodes)..where(
              (table) =>
                  table.id.equals(nodeId) &
                  table.deletedAt.equals(notDeletedSentinel),
            ))
            .write(changes.copyWith(updatedAt: Value(DateTime.now())));
    if (count != 1) {
      throw ArgumentError('Canvas node is no longer available: $nodeId');
    }
  }

  /// 只写布局字段，保留并发修改的画布名称与描述；调用方负责与坐标同事务提交。
  Future<void> updateLayout(String canvasId, String mode) async {
    final count =
        await (update(canvases)..where(
              (table) =>
                  table.id.equals(canvasId) &
                  table.deletedAt.equals(notDeletedSentinel),
            ))
            .write(
              CanvasesCompanion(
                layout: Value(mode),
                updatedAt: Value(DateTime.now()),
              ),
            );
    if (count != 1) {
      throw ArgumentError('Canvas is no longer available: $canvasId');
    }
  }

  /// 批量改写节点坐标(自动布局重排用)。
  ///
  /// 必须走单个事务:逐条 upsert 会让 `watchNodesByCanvas` 发 N 次,
  /// 画布跟着重载 N 次 —— 一次重排动几十个节点时肉眼可见地闪。
  Future<void> updateNodePositions(
    Map<String, ({double x, double y})> positions,
  ) async {
    if (positions.isEmpty) return;
    final now = DateTime.now();
    await attachedDatabase.transaction(() async {
      for (final entry in positions.entries) {
        await (update(canvasNodes)..where(
              (t) =>
                  t.id.equals(entry.key) &
                  t.deletedAt.equals(notDeletedSentinel),
            ))
            .write(
              CanvasNodesCompanion(
                x: Value(entry.value.x),
                y: Value(entry.value.y),
                updatedAt: Value(now),
              ),
            );
      }
    });
  }

  /// 软删节点并级联硬删以其为端点的边。
  Future<int> softDeleteNode(String id) async {
    final now = DateTime.now();
    await attachedDatabase.transaction(() async {
      await (delete(canvasEdges)..where(
            (t) => t.sourceNodeId.equals(id) | t.targetNodeId.equals(id),
          ))
          .go();
      await (update(canvasNodes)..where((t) => t.id.equals(id))).write(
        CanvasNodesCompanion(deletedAt: Value(now), updatedAt: Value(now)),
      );
    });
    return 1;
  }

  /// 批量刷新引用型节点缓存标题(资源改名后调用)。
  /// 只更新未软删的引用节点。
  Future<int> updateReferenceTitles({
    required String refType,
    required String refId,
    required String title,
  }) {
    return (update(canvasNodes)..where(
          (t) =>
              t.refType.equals(refType) &
              t.refId.equals(refId) &
              t.deletedAt.equals(notDeletedSentinel),
        ))
        .write(
          CanvasNodesCompanion(
            title: Value(title),
            updatedAt: Value(DateTime.now()),
          ),
        );
  }

  // ---- CanvasEdge ----

  Future<List<CanvasEdge>> getEdgesByCanvas(String canvasId) {
    return (select(canvasEdges)
          ..where((t) => t.canvasId.equals(canvasId))
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]))
        .get();
  }

  Future<CanvasEdge?> getEdgeById(String id) {
    return (select(
      canvasEdges,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Stream<List<CanvasEdge>> watchEdgesByCanvas(String canvasId) {
    return (select(canvasEdges)
          ..where((t) => t.canvasId.equals(canvasId))
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]))
        .watch();
  }

  Future<void> upsertEdge(CanvasEdge edge) async {
    await into(
      canvasEdges,
    ).insertOnConflictUpdate(edge.copyWith(updatedAt: DateTime.now()));
  }

  Future<bool> edgeIdExists(String id) async {
    final row =
        await (selectOnly(canvasEdges)
              ..addColumns([canvasEdges.id])
              ..where(canvasEdges.id.equals(id))
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  Future<void> insertEdge(CanvasEdge edge) {
    return into(canvasEdges).insert(edge);
  }

  Future<void> updateEdge(CanvasEdge edge) async {
    final count =
        await (update(canvasEdges)..where((table) => table.id.equals(edge.id)))
            .write(edge.copyWith(updatedAt: DateTime.now()));
    if (count != 1) {
      throw ArgumentError('Canvas edge is no longer available: ${edge.id}');
    }
  }

  Future<int> hardDeleteEdge(String id) {
    return (delete(canvasEdges)..where((t) => t.id.equals(id))).go();
  }
}

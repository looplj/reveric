// 职责: 校验与保存画布内容，并通过编辑边界、一致快照和原子事务提交布局。
// 关联文件:
//   lib/shared/database/novel_content_database.dart
//   lib/shared/database/novel_content_daos/canvas_dao.dart
//   lib/shared/models/canvas_auto_layout.dart
//   lib/shared/models/canvas_tree_layout.dart
//   lib/shared/providers/canvas_providers.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md
//   .agents/rules/service-naming.md
import 'dart:async';
import 'dart:isolate';

import 'package:collection/collection.dart';
import 'dart:ui';

import 'package:drift/drift.dart';

import '../database/novel_content_database.dart';
import '../logger/app_logger.dart';
import '../models/canvas_auto_layout.dart';
import '../models/canvas_layout.dart';
import '../models/canvas_tree_layout.dart';
import '../utils/ai_path_name_check.dart';
import '../utils/short_entity_id.dart';
import '../utils/short_entity_id_allocator.dart';

final _log = AppLogger.forModule('Canvas');

/// 画布服务异常 — 结构化错误,供 AI 工具层向 agent 透出明确错误码。
///
/// errorCode 取值:
/// - `invalid_reference`:引用资源不存在
/// - `missing_required_fields`:必填字段缺失
/// - `invalid_type`:node / edge 的 type 不在白名单内
/// - `invalid_ref_type`:引用型节点的 refType 不在白名单内
/// - `invalid_edge_semantics`:边的端点不属于该画布 / foreshadow_payoff 语义不匹配
/// - `duplicate_edge`:同 (canvas,source,target,type) 的边已存在
/// - `duplicate_name`:同名画布已存在(画布名是 AI 路径 `/canvas/{name}` 的键)
/// - `invalid_name`:画布名为空或含 `/`
/// - `canvas_not_found`:画布不存在
/// - `node_not_found`:节点不存在
/// - `edge_not_found`:边不存在
class CanvasServiceException implements Exception {
  CanvasServiceException({required this.errorCode, required this.message});

  final String errorCode;
  final String message;

  @override
  String toString() => 'CanvasServiceException($errorCode): $message';
}

typedef CanvasLayoutComputer =
    Future<Map<String, Offset>> Function(CanvasLayoutRequest request);

/// 当前画布编辑区提供的操作边界；没有打开编辑区时服务直接执行。
typedef CanvasLayoutBoundary =
    Future<CanvasLayoutSaveResult> Function(
      Future<CanvasLayoutSaveResult> Function() action,
    );

class CanvasService {
  CanvasService(
    this._database, {
    ShortEntityIdBuilder idBuilder = buildShortEntityId,
    this._layoutComputer = _computeCanvasLayout,
  }) : _buildEntityId = idBuilder;

  final NovelContentDatabase _database;
  final ShortEntityIdBuilder _buildEntityId;
  final CanvasLayoutComputer _layoutComputer;

  // 同一内容库可由 UI、AI 或 cross-work 构造不同 Service。仅共享打开中的
  // 画布执行回调；草稿/交互状态仍由 region 持有，DB 弱键不会保活已关闭的库。
  static final _layoutBoundaries = Expando<Map<String, CanvasLayoutBoundary>>();

  void registerLayoutBoundary(String canvasId, CanvasLayoutBoundary boundary) {
    (_layoutBoundaries[_database] ??= {})[canvasId] = boundary;
  }

  void unregisterLayoutBoundary(
    String canvasId,
    CanvasLayoutBoundary boundary,
  ) {
    final boundaries = _layoutBoundaries[_database];
    if (identical(boundaries?[canvasId], boundary)) {
      boundaries!.remove(canvasId);
    }
  }

  // ---- 监听 ----

  Stream<List<CanvasEntry>> watchCanvases() {
    return _database.canvasDao.watchAllCanvases();
  }

  /// 监听画布的节点 + 边。任一变化即重发合并快照。
  ///
  /// 项目无 rxdart/StreamGroup 依赖,这里用手动 [StreamController] 合并两条
  /// drift watch 流;订阅在 `onListen` 时建立、`onCancel` 时取消,避免无监听者
  /// 时 drift 流空转丢事件(单订阅流,适配 StreamProvider 单监听者)。
  Stream<({List<CanvasNode> nodes, List<CanvasEdge> edges})> watchCanvasContent(
    String canvasId,
  ) {
    final controller =
        StreamController<({List<CanvasNode> nodes, List<CanvasEdge> edges})>();

    var nodes = const <CanvasNode>[];
    var edges = const <CanvasEdge>[];
    var hasNodes = false;
    var hasEdges = false;
    var doneCount = 0;
    StreamSubscription<List<CanvasNode>>? nodesSub;
    StreamSubscription<List<CanvasEdge>>? edgesSub;

    void emit() {
      if (hasNodes && hasEdges && !controller.isClosed) {
        controller.add((nodes: nodes, edges: edges));
      }
    }

    void onDone() {
      doneCount += 1;
      if (doneCount == 2 && !controller.isClosed) {
        controller.close();
      }
    }

    controller.onListen = () {
      nodesSub = _database.canvasDao
          .watchNodesByCanvas(canvasId)
          .listen(
            (n) {
              nodes = n;
              hasNodes = true;
              emit();
            },
            onError: controller.addError,
            onDone: onDone,
          );
      edgesSub = _database.canvasDao
          .watchEdgesByCanvas(canvasId)
          .listen(
            (e) {
              edges = e;
              hasEdges = true;
              emit();
            },
            onError: controller.addError,
            onDone: onDone,
          );
    };

    controller.onCancel = () async {
      await nodesSub?.cancel();
      await edgesSub?.cancel();
    };

    return controller.stream;
  }

  // ---- Canvas CRUD ----

  /// 画布名既是用户可见标题，也是 AI 路径 `/canvas/{name}` 的键。
  ///
  /// 禁止 `/`：路径解析把 `/canvas/{name}/nodes/{id}` 按段切分，名字里的斜杠会让
  /// `nodes` 段错位，读到的是另一张画布或另一类子资源。
  /// 禁止 `?`：路径解析把首个 `?` 当查询串起点（tools_support.dart ParsedPath.parse），
  /// 名字里的问号会截断路径，`/canvas/Who?` 实际查找的是 `Who`。返回 trim 后的名字。
  String _normalizeCanvasName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw CanvasServiceException(
        errorCode: 'invalid_name',
        message: 'Canvas name must not be empty',
      );
    }
    if (nameHasAiPathStructuralChars(trimmed)) {
      throw CanvasServiceException(
        errorCode: 'invalid_name',
        message:
            'Canvas name must not contain "/" or "?": $trimmed '
            '(they are path separators in canvas AI paths)',
      );
    }
    return trimmed;
  }

  /// 按名称查画布(软删的不算)。名称唯一,命中多条时说明唯一索引失效。
  Future<CanvasEntry?> getCanvasByName(String name) async {
    final trimmed = name.trim();
    final matched = (await _database.canvasDao.getAllCanvases())
        .where((canvas) => canvas.name.trim() == trimmed)
        .toList(growable: false);
    if (matched.length > 1) {
      throw CanvasServiceException(
        errorCode: 'duplicate_name',
        message:
            'Multiple canvases named "$trimmed" (${matched.length}); '
            'rename them so canvas paths stay unambiguous',
      );
    }
    return matched.isEmpty ? null : matched.first;
  }

  /// 按 id 查画布(软删的不算)。宿主侧（如 current_workspace_context）持有
  /// canvas id，需经此解析出 AI 路径用的 name。
  Future<CanvasEntry?> getCanvasById(String id) {
    return _database.canvasDao.getCanvasById(id);
  }

  Future<void> _ensureNameAvailable(String name, {String? exceptId}) async {
    final existing = await getCanvasByName(name);
    if (existing != null && existing.id != exceptId) {
      throw CanvasServiceException(
        errorCode: 'duplicate_name',
        message: 'Canvas "$name" already exists',
      );
    }
  }

  Future<String> createCanvas({
    required String name,
    String description = '',
    String kind = canvasKindUser,
  }) async {
    final resolvedName = _normalizeCanvasName(name);
    await _ensureNameAvailable(resolvedName);
    final now = DateTime.now();
    final existing = await _database.canvasDao.getAllCanvases();
    final nextSortOrder = existing.isEmpty
        ? 0
        : (existing.map((c) => c.sortOrder).fold<int>(0, _max)) + 1;

    try {
      return await insertWithShortEntityId(
        type: ShortEntityIdType.canvas,
        tableName: 'canvases',
        idExists: _database.canvasDao.canvasIdExists,
        buildId: _buildEntityId,
        insert: (id) => _database.canvasDao.insertCanvas(
          CanvasEntry(
            id: id,
            name: resolvedName,
            description: description,
            kind: kind,
            sortOrder: nextSortOrder,
            createdAt: now,
            updatedAt: now,
            deletedAt: notDeletedSentinel,
          ),
        ),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] INSERT canvases error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> renameCanvas({
    required String canvasId,
    required String name,
  }) async {
    final canvas = await _database.canvasDao.getCanvasById(canvasId);
    if (canvas == null) {
      throw CanvasServiceException(
        errorCode: 'canvas_not_found',
        message: 'Canvas not found: $canvasId',
      );
    }
    final resolvedName = _normalizeCanvasName(name);
    await _ensureNameAvailable(resolvedName, exceptId: canvasId);
    try {
      await _database.canvasDao.updateMetadata(canvasId, name: resolvedName);
    } catch (error, stackTrace) {
      _log.error(
        '[DB] UPDATE canvases id=$canvasId rename error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> updateCanvasDescription({
    required String canvasId,
    required String description,
  }) async {
    final canvas = await _database.canvasDao.getCanvasById(canvasId);
    if (canvas == null) {
      throw CanvasServiceException(
        errorCode: 'canvas_not_found',
        message: 'Canvas not found: $canvasId',
      );
    }
    try {
      await _database.canvasDao.updateMetadata(
        canvasId,
        description: description,
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] UPDATE canvases id=$canvasId description error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> softDeleteCanvas(String canvasId) async {
    try {
      await _database.canvasDao.softDeleteCanvas(canvasId);
    } catch (error, stackTrace) {
      _log.error(
        '[DB] softDelete canvases id=$canvasId error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  // ---- Node ----

  Future<String> addNode({
    required String canvasId,
    required String type,
    String? refType,
    String? refId,
    String? title,
    String? content,
    required double x,
    required double y,
    double? width,
    double? height,
    Map<String, dynamic>? style,
  }) async {
    if (!canvasNodeTypes.contains(type)) {
      throw CanvasServiceException(
        errorCode: 'invalid_type',
        message:
            'Invalid node type: $type. '
            'Allowed values: ${canvasNodeTypes.join(', ')}.',
      );
    }

    String resolvedTitle;
    String nodeContent;
    String? nodeRefType;
    String? nodeRefId;

    if (type == canvasNodeTypeReference) {
      if (refType == null ||
          refType.isEmpty ||
          refId == null ||
          refId.isEmpty) {
        throw CanvasServiceException(
          errorCode: 'missing_required_fields',
          message: 'Reference node requires refType and refId',
        );
      }
      if (!canvasNodeRefTypes.contains(refType)) {
        throw CanvasServiceException(
          errorCode: 'invalid_ref_type',
          message:
              'Invalid refType: $refType. '
              'Allowed values: ${canvasNodeRefTypes.join(', ')}.',
        );
      }
      // 引用型节点 title 是资源标题的缓存(不取 caller 传入的 title),
      // 守「title 是缓存」不变量(参见方案 5.1 title 冗余说明)。
      if (!await _referenceExists(refType, refId)) {
        throw CanvasServiceException(
          errorCode: 'invalid_reference',
          message: 'Referenced $refType not found: $refId',
        );
      }
      resolvedTitle = await _resolveReferenceTitle(refType, refId) ?? '';
      nodeContent = '';
      nodeRefType = refType;
      nodeRefId = refId;
    } else {
      // sticky
      if (content == null) {
        throw CanvasServiceException(
          errorCode: 'missing_required_fields',
          message: 'Sticky node requires content',
        );
      }
      resolvedTitle = title ?? '';
      nodeContent = content;
      nodeRefType = null;
      nodeRefId = null;
    }

    final now = DateTime.now();
    try {
      return await insertWithShortEntityId(
        type: ShortEntityIdType.canvasNode,
        tableName: 'canvas_nodes',
        idExists: _database.canvasDao.nodeIdExists,
        buildId: _buildEntityId,
        insert: (id) => _database.canvasDao.insertNode(
          CanvasNode(
            id: id,
            canvasId: canvasId,
            type: type,
            refType: nodeRefType,
            refId: nodeRefId,
            title: resolvedTitle,
            content: nodeContent,
            x: x,
            y: y,
            width: width,
            height: height,
            style: style,
            zIndex: 0,
            sortOrder: 0,
            createdAt: now,
            updatedAt: now,
            deletedAt: notDeletedSentinel,
          ),
        ),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] INSERT canvas_nodes canvasId=$canvasId error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// 原子更新节点；类型与引用一起校验，转换保留正文、几何及连线。
  Future<void> updateNode({
    required String nodeId,
    String? type,
    Value<String?> refType = const Value.absent(),
    Value<String?> refId = const Value.absent(),
    String? title,
    String? content,
    double? x,
    double? y,
    Map<String, dynamic>? style,
  }) async {
    try {
      await _database.transaction(() async {
        final node = await _database.canvasDao.getNodeById(nodeId);
        if (node == null) {
          throw CanvasServiceException(
            errorCode: 'node_not_found',
            message: 'Node not found: $nodeId',
          );
        }
        final nextType = type ?? node.type;
        if (!canvasNodeTypes.contains(nextType)) {
          throw CanvasServiceException(
            errorCode: 'invalid_type',
            message: 'Invalid node type: $nextType',
          );
        }
        if (nextType == canvasNodeTypeReference &&
            (title != null || content != null)) {
          throw CanvasServiceException(
            errorCode: 'invalid_fields',
            message: 'Only sticky nodes accept title and content writes.',
          );
        }

        var changes = CanvasNodesCompanion(
          title: title == null ? const Value.absent() : Value(title),
          content: content == null ? const Value.absent() : Value(content),
          x: x == null ? const Value.absent() : Value(x),
          y: y == null ? const Value.absent() : Value(y),
          style: style == null ? const Value.absent() : Value(style),
        );
        if (type != null || refType.present || refId.present) {
          String? nextRefType;
          String? nextRefId;
          if (nextType == canvasNodeTypeReference) {
            nextRefType = refType.present ? refType.value : node.refType;
            nextRefId = refId.present ? refId.value : node.refId;
            if (nextRefType == null ||
                nextRefType.isEmpty ||
                nextRefId == null ||
                nextRefId.isEmpty) {
              throw CanvasServiceException(
                errorCode: 'missing_required_fields',
                message: 'Reference node requires ref_type and ref_id.',
              );
            }
            if (!canvasNodeRefTypes.contains(nextRefType)) {
              throw CanvasServiceException(
                errorCode: 'invalid_ref_type',
                message: 'Invalid ref_type: $nextRefType',
              );
            }
            final referenceTitle = await _resolveReferenceTitle(
              nextRefType,
              nextRefId,
            );
            if (referenceTitle == null) {
              throw CanvasServiceException(
                errorCode: 'invalid_reference',
                message: 'Referenced $nextRefType not found: $nextRefId',
              );
            }
            changes = changes.copyWith(title: Value(referenceTitle));
          } else if ((refType.present && refType.value != null) ||
              (refId.present && refId.value != null)) {
            throw CanvasServiceException(
              errorCode: 'invalid_fields',
              message: 'Sticky nodes cannot have ref_type or ref_id.',
            );
          }
          changes = changes.copyWith(
            type: Value(nextType),
            refType: Value(nextRefType),
            refId: Value(nextRefId),
          );
          final nextNode = node.copyWithCompanion(changes);
          final edges = await _database.canvasDao.getEdgesByCanvas(
            node.canvasId,
          );
          for (final edge in edges) {
            if (edge.type != canvasEdgeTypeForeshadowPayoff ||
                (edge.sourceNodeId != nodeId && edge.targetNodeId != nodeId)) {
              continue;
            }
            final source = edge.sourceNodeId == nodeId
                ? nextNode
                : await _database.canvasDao.getNodeById(edge.sourceNodeId);
            final target = edge.targetNodeId == nodeId
                ? nextNode
                : await _database.canvasDao.getNodeById(edge.targetNodeId);
            if (source == null || target == null) {
              throw CanvasServiceException(
                errorCode: 'invalid_edge_semantics',
                message: 'Edge ${edge.id} has a missing endpoint.',
              );
            }
            _assertForeshadowPayoffSemantics(source: source, target: target);
          }
        }
        await _database.canvasDao.updateActiveNodeFields(nodeId, changes);
      });
    } on CanvasServiceException {
      rethrow;
    } catch (error, stackTrace) {
      _log.error(
        '[DB] UPDATE canvas_nodes id=$nodeId fields failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> updateNodePosition({
    required String nodeId,
    required double x,
    required double y,
  }) async {
    final node = await _database.canvasDao.getNodeById(nodeId);
    if (node == null) {
      throw CanvasServiceException(
        errorCode: 'node_not_found',
        message: 'Node not found: $nodeId',
      );
    }
    try {
      await _database.canvasDao.updateActiveNodeFields(
        nodeId,
        CanvasNodesCompanion(x: Value(x), y: Value(y)),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] UPDATE canvas_nodes id=$nodeId position error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> updateNodeContent({
    required String nodeId,
    required String content,
  }) async {
    final node = await _database.canvasDao.getNodeById(nodeId);
    if (node == null) {
      throw CanvasServiceException(
        errorCode: 'node_not_found',
        message: 'Node not found: $nodeId',
      );
    }
    try {
      await _database.canvasDao.updateActiveNodeFields(
        nodeId,
        CanvasNodesCompanion(content: Value(content)),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] UPDATE canvas_nodes id=$nodeId content error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// 更新便签标题。引用型节��的 title 是资源标题缓存,由
  /// [refreshReferenceTitle] 维护,不接受外部改写。
  Future<void> updateNodeTitle({
    required String nodeId,
    required String title,
  }) async {
    final node = await _database.canvasDao.getNodeById(nodeId);
    if (node == null) {
      throw CanvasServiceException(
        errorCode: 'node_not_found',
        message: 'Node not found: $nodeId',
      );
    }
    if (node.type != canvasNodeTypeSticky) {
      throw CanvasServiceException(
        errorCode: 'missing_required_fields',
        message:
            'Only sticky nodes accept title writes; reference titles are a '
            'cache maintained by refreshReferenceTitle (node $nodeId)',
      );
    }
    try {
      await _database.canvasDao.updateActiveNodeFields(
        nodeId,
        CanvasNodesCompanion(title: Value(title)),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] UPDATE canvas_nodes id=$nodeId title error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// 更新节点的纯视觉样式(便签纸色等)。写入 style JSON 列,不承载业务字段。
  Future<void> updateNodeStyle({
    required String nodeId,
    required Map<String, dynamic> style,
  }) async {
    final node = await _database.canvasDao.getNodeById(nodeId);
    if (node == null) {
      throw CanvasServiceException(
        errorCode: 'node_not_found',
        message: 'Node not found: $nodeId',
      );
    }
    try {
      await _database.canvasDao.updateActiveNodeFields(
        nodeId,
        CanvasNodesCompanion(style: Value(style)),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] UPDATE canvas_nodes id=$nodeId style error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// 保存拖拽/缩放的最终几何，只更新几何列，不覆盖正文或样式。
  Future<void> updateNodeGeometry({
    required String nodeId,
    required Offset position,
    required Size size,
  }) async {
    if (!position.dx.isFinite ||
        !position.dy.isFinite ||
        !size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0) {
      throw CanvasServiceException(
        errorCode: 'invalid_geometry',
        message: 'Canvas geometry must be finite and positive.',
      );
    }
    try {
      final count =
          await (_database.update(_database.canvasNodes)..where(
                (n) =>
                    n.id.equals(nodeId) &
                    n.deletedAt.equals(notDeletedSentinel),
              ))
              .write(
                CanvasNodesCompanion(
                  x: Value(position.dx),
                  y: Value(position.dy),
                  width: Value(size.width),
                  height: Value(size.height),
                  updatedAt: Value(DateTime.now()),
                ),
              );
      if (count != 1) {
        throw CanvasServiceException(
          errorCode: 'node_not_found',
          message: 'Node not found: $nodeId',
        );
      }
    } catch (error, stackTrace) {
      _log.error(
        '[DB] UPDATE canvas_nodes id=$nodeId geometry failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// 按连边关系重排画布,返回被移动的节点数。
  ///
  /// 摆位算法([resolveCanvasNodePlacement])在节点落库那一刻只看得到已有矩形,
  /// 而边总是随后才连 —— 它无从知道谁该挨着谁。这里在边齐了之后补一次重排:
  /// 主干层不动,其余层按邻居列重新分列,把横穿画布的长线压短。
  ///
  /// 用户手拖过的节点(坐标不在网格点上)不参与,见 [resolveCanvasAutoLayout]。
  Future<int> autoLayout(String canvasId) async {
    // 保留旧调用对已不存在画布的空操作契约。
    if (await _database.canvasDao.getCanvasById(canvasId) == null) {
      return 0;
    }
    return (await applyLayout(canvasId, canvasLayoutTidy)).moved;
  }

  /// 一致快照 -> 纯值 isolate 计算 -> 同事务冲突检查及布局/坐标提交。
  Future<CanvasLayoutSaveResult> applyLayout(
    String canvasId,
    String mode,
  ) async {
    if (!canvasLayoutModes.contains(mode)) {
      throw CanvasServiceException(
        errorCode: 'invalid_fields',
        message: 'Unknown canvas layout: $mode',
      );
    }
    final boundary = _layoutBoundaries[_database]?[canvasId];
    return boundary == null
        ? _applyLayout(canvasId, mode)
        : boundary(() => _applyLayout(canvasId, mode));
  }

  Future<CanvasLayoutSaveResult> _applyLayout(
    String canvasId,
    String mode,
  ) async {
    Future<
      ({CanvasEntry? canvas, List<CanvasNode> nodes, List<CanvasEdge> edges})
    >
    readSnapshot() async {
      return (
        canvas: await _database.canvasDao.getCanvasById(canvasId),
        nodes: await _database.canvasDao.getNodesByCanvas(canvasId),
        edges: await _database.canvasDao.getEdgesByCanvas(canvasId),
      );
    }

    final before = await _database.transaction(readSnapshot);
    if (before.canvas == null) {
      throw CanvasServiceException(
        errorCode: 'canvas_not_found',
        message: 'Canvas not found: $canvasId',
      );
    }
    // 整理沿用已保存的布局；还没选过布局的画布就是自由画布。
    final saved = before.canvas!.layout;
    final arrange = mode == canvasLayoutTidy
        ? (canvasLayoutSavedModes.contains(saved) ? saved! : canvasLayoutAuto)
        : mode;
    final ids = before.nodes.map((node) => node.id).toSet();
    final hasDirectedEdge = before.edges.any(
      (edge) =>
          isCanvasEdgeDirected(edge.type) &&
          ids.contains(edge.sourceNodeId) &&
          ids.contains(edge.targetNodeId),
    );
    if (before.nodes.length > 1 &&
        (arrange == canvasLayoutTreeLr || arrange == canvasLayoutTreeTb) &&
        !hasDirectedEdge) {
      throw CanvasServiceException(
        errorCode: 'layout_requires_directed_edges',
        message: 'Tree layout requires a directed edge.',
      );
    }
    final request = CanvasLayoutRequest(
      mode: arrange,
      nodes: [
        for (final node in before.nodes)
          CanvasArrangeNode(
            id: node.id,
            sortOrder: node.sortOrder,
            position: Offset(node.x, node.y),
            size: Size(
              node.width ?? _defaultNodeSize(node.type).width,
              node.height ?? _defaultNodeSize(node.type).height,
            ),
          ),
      ],
      edges: [
        for (final edge in before.edges)
          CanvasArrangeEdge(
            sourceNodeId: edge.sourceNodeId,
            targetNodeId: edge.targetNodeId,
            type: edge.type,
          ),
      ],
    );
    final positions = before.nodes.length < 2
        ? const <String, Offset>{}
        : await _layoutComputer(request);
    final moved = <String, ({double x, double y})>{};
    for (final node in before.nodes) {
      final position = positions[node.id];
      if (position != null &&
          (node.x != position.dx || node.y != position.dy)) {
        moved[node.id] = (x: position.dx, y: position.dy);
      }
    }
    final modeChanged = mode != canvasLayoutTidy && saved != mode;
    try {
      await _database.transaction(() async {
        final current = await readSnapshot();
        const equality = DeepCollectionEquality();
        if (current.canvas == null ||
            current.canvas!.layout != before.canvas!.layout ||
            !equality.equals(
              before.nodes.map((n) => n.toJson()).toList(),
              current.nodes.map((n) => n.toJson()).toList(),
            ) ||
            !equality.equals(
              before.edges.map((e) => e.toJson()).toList(),
              current.edges.map((e) => e.toJson()).toList(),
            )) {
          throw CanvasServiceException(
            errorCode: 'layout_conflict',
            message:
                'Canvas changed during layout. Read the graph again before retrying.',
          );
        }
        if (moved.isEmpty && !modeChanged) {
          return;
        }
        await _database.canvasDao.updateNodePositions(moved);
        if (modeChanged) {
          await _database.canvasDao.updateLayout(canvasId, arrange);
        }
      });
    } catch (error, stackTrace) {
      _log.error(
        '[DB] UPDATE canvas_nodes,canvases id=$canvasId layout=$mode failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
    return CanvasLayoutSaveResult(
      moved: moved.length,
      modeChanged: modeChanged,
    );
  }

  Size _defaultNodeSize(String type) {
    return type == canvasNodeTypeSticky
        ? canvasStickyDefaultSize
        : canvasReferenceDefaultSize;
  }

  Future<void> softDeleteNode(String nodeId) async {
    try {
      await _database.canvasDao.softDeleteNode(nodeId);
    } catch (error, stackTrace) {
      _log.error(
        '[DB] softDelete canvas_nodes id=$nodeId error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  // ---- Edge ----

  Future<String> addEdge({
    required String canvasId,
    required String sourceNodeId,
    required String targetNodeId,
    required String type,
    String? label,
  }) async {
    if (!canvasEdgeTypes.contains(type)) {
      throw CanvasServiceException(
        errorCode: 'invalid_type',
        message:
            'Invalid edge type: $type. '
            'Allowed values: ${canvasEdgeTypes.join(', ')}.',
      );
    }

    final source = await _database.canvasDao.getNodeById(sourceNodeId);
    final target = await _database.canvasDao.getNodeById(targetNodeId);
    if (source == null ||
        source.canvasId != canvasId ||
        target == null ||
        target.canvasId != canvasId) {
      throw CanvasServiceException(
        errorCode: 'invalid_edge_semantics',
        message: 'Edge endpoints must belong to canvas $canvasId',
      );
    }

    if (type == canvasEdgeTypeForeshadowPayoff) {
      _assertForeshadowPayoffSemantics(source: source, target: target);
    }

    // 重复同型边检测:unique 约束会兜底,但提前检测给出明确错误码。
    await _assertNoDuplicateEdge(
      canvasId: canvasId,
      sourceNodeId: sourceNodeId,
      targetNodeId: targetNodeId,
      type: type,
    );

    final now = DateTime.now();
    try {
      return await insertWithShortEntityId(
        type: ShortEntityIdType.canvasEdge,
        tableName: 'canvas_edges',
        idExists: _database.canvasDao.edgeIdExists,
        buildId: _buildEntityId,
        insert: (id) => _database.canvasDao.insertEdge(
          CanvasEdge(
            id: id,
            canvasId: canvasId,
            sourceNodeId: sourceNodeId,
            targetNodeId: targetNodeId,
            type: type,
            label: label,
            createdAt: now,
            updatedAt: now,
          ),
        ),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] INSERT canvas_edges canvasId=$canvasId error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// 原地编辑连线:改类型和/或说明文字。两者都为 null 视为调用方 bug。
  ///
  /// 改 type 时复用与 [addEdge] 相同的两条校验(foreshadow_payoff 语义、
  /// 同型边唯一),否则 `(canvas,source,target,type)` 的 unique 约束会在
  /// upsert 时抛出 SQLite 异常。
  Future<void> updateEdge({
    required String edgeId,
    String? type,
    String? label,
  }) async {
    if (type == null && label == null) {
      throw CanvasServiceException(
        errorCode: 'missing_required_fields',
        message: 'updateEdge requires at least one of type or label',
      );
    }

    final edge = await _database.canvasDao.getEdgeById(edgeId);
    if (edge == null) {
      throw CanvasServiceException(
        errorCode: 'edge_not_found',
        message: 'Edge not found: $edgeId',
      );
    }

    if (type != null && type != edge.type) {
      if (!canvasEdgeTypes.contains(type)) {
        throw CanvasServiceException(
          errorCode: 'invalid_type',
          message:
              'Invalid edge type: $type. '
              'Allowed values: ${canvasEdgeTypes.join(', ')}.',
        );
      }
      if (type == canvasEdgeTypeForeshadowPayoff) {
        final source = await _database.canvasDao.getNodeById(edge.sourceNodeId);
        final target = await _database.canvasDao.getNodeById(edge.targetNodeId);
        if (source == null || target == null) {
          throw CanvasServiceException(
            errorCode: 'invalid_edge_semantics',
            message: 'Edge $edgeId has a missing endpoint',
          );
        }
        _assertForeshadowPayoffSemantics(source: source, target: target);
      }
      await _assertNoDuplicateEdge(
        canvasId: edge.canvasId,
        sourceNodeId: edge.sourceNodeId,
        targetNodeId: edge.targetNodeId,
        type: type,
      );
    }

    try {
      await _database.canvasDao.updateEdge(
        edge.copyWith(
          type: type ?? edge.type,
          label: Value(label ?? edge.label),
          updatedAt: DateTime.now(),
        ),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] UPDATE canvas_edges id=$edgeId type=$type error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> hardDeleteEdge(String edgeId) async {
    try {
      await _database.canvasDao.hardDeleteEdge(edgeId);
    } catch (error, stackTrace) {
      _log.error(
        '[DB] DELETE canvas_edges id=$edgeId error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  // ---- 引用标题刷新 ----

  /// 刷新某资源对应的所有未软删引用节点的缓存 title。
  /// 资源已被删除(查不到)时跳过,不报错——失效态由 UI 层渲染时检测。
  Future<void> refreshReferenceTitle({
    required String refType,
    required String refId,
  }) async {
    final title = await _resolveReferenceTitle(refType, refId);
    if (title == null) {
      return;
    }
    try {
      await _database.canvasDao.updateReferenceTitles(
        refType: refType,
        refId: refId,
        title: title,
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] UPDATE canvas_nodes refType=$refType refId=$refId title refresh '
        'error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// 兜底校准:刷新某画布下所有引用节点的缓存 title。
  Future<void> refreshReferenceTitlesForCanvas(String canvasId) async {
    final nodes = await _database.canvasDao.getNodesByCanvas(canvasId);
    for (final node in nodes) {
      if (node.type != canvasNodeTypeReference) {
        continue;
      }
      final refType = node.refType;
      final refId = node.refId;
      if (refType == null || refId == null) {
        continue;
      }
      await refreshReferenceTitle(refType: refType, refId: refId);
    }
  }

  // ---- 私有辅助 ----

  /// foreshadow_payoff 边的语义约束:起点为伏笔,终点为章节。
  /// 由 [addEdge] 与 [updateEdge] 共用,避免两处校验漂移。
  void _assertForeshadowPayoffSemantics({
    required CanvasNode source,
    required CanvasNode target,
  }) {
    if (source.refType != entityTypeForeshadowing ||
        target.refType != entityTypeChapter) {
      throw CanvasServiceException(
        errorCode: 'invalid_edge_semantics',
        message:
            'foreshadow_payoff edge requires source=foreshadowing, '
            'target=chapter',
      );
    }
  }

  /// 同型边唯一约束的前置检测。DB 的 unique 索引会兜底,这里提前拦是为了
  /// 给出明确错误码而非 SQLite 原始异常。由 [addEdge] 与 [updateEdge] 共用。
  Future<void> _assertNoDuplicateEdge({
    required String canvasId,
    required String sourceNodeId,
    required String targetNodeId,
    required String type,
  }) async {
    final existingEdges = await _database.canvasDao.getEdgesByCanvas(canvasId);
    final isDuplicate = existingEdges.any(
      (e) =>
          e.sourceNodeId == sourceNodeId &&
          e.targetNodeId == targetNodeId &&
          e.type == type,
    );
    if (isDuplicate) {
      throw CanvasServiceException(
        errorCode: 'duplicate_edge',
        message:
            'Edge ($sourceNodeId -> $targetNodeId, type=$type) already '
            'exists in canvas $canvasId',
      );
    }
  }

  /// 引用资源是否存在(未软删)。供 UI 层检测失效引用节点(灰态/清理失效)。
  Future<bool> referenceExists(String refType, String refId) async {
    return (await _resolveReferenceTitle(refType, refId)) != null;
  }

  /// 引用资源是否存在(未软删)。未知 refType 抛 invalid_reference。
  Future<bool> _referenceExists(String refType, String refId) async {
    return (await _resolveReferenceTitle(refType, refId)) != null;
  }

  /// 解析引用资源的标题;资源不存在(或已软删)返回 null。
  /// 未知 refType 视为调用方 bug,抛 invalid_reference。
  Future<String?> _resolveReferenceTitle(String refType, String refId) async {
    switch (refType) {
      case entityTypeCharacter:
        final c = await _database.characterProfileDao.getById(refId);
        return c?.name;
      case entityTypeChapter:
        // 直查 chapter_nodes 原表,避开 chapters VIEW 的窗口函数开销。
        final rows = await _database
            .customSelect(
              'SELECT title FROM chapter_nodes WHERE id = ? AND deleted_at = 0 '
              'LIMIT 1',
              variables: [Variable.withString(refId)],
            )
            .get();
        if (rows.isEmpty) {
          return null;
        }
        return (rows.first.data['title'] as String?) ?? '';
      case entityTypeForeshadowing:
        final f = await _database.foreshadowingDao.getById(refId);
        return f?.title;
      case canvasNodeRefTypeOutline:
        final o = await _database.outlineDao.getOutlineRowByDocumentId(refId);
        return o?.title;
      case entityTypeLocation:
        final l = await _database.locationDao.getById(refId);
        return l?.name;
      case entityTypeItem:
      case entityTypeFaction:
      case entityTypeSkill:
      case entityTypeCreature:
        // item/faction/skill/creature 共存于 items 表,type 列区分。
        final item = await _database.itemDao.getById(refId);
        if (item == null || item.type != refType) {
          return null;
        }
        return item.title;
      case canvasNodeRefTypeDocument:
        final d = await _database.documentDao.getById(refId);
        return d?.title;
      case canvasNodeRefTypeScreenplayScene:
        final dao = _database.screenplayDao;
        final scene = await dao.getScene(refId);
        if (scene == null) {
          return null;
        }
        final episode = await dao.getEpisode(scene.episodeId);
        if (episode == null || episode.screenplayId != scene.screenplayId) {
          return null;
        }
        final season = await dao.getSeason(episode.seasonId);
        final root = await dao.getRoot();
        if (season == null ||
            root == null ||
            season.screenplayId != root.id ||
            scene.screenplayId != root.id) {
          return null;
        }
        return scene.title;
      default:
        throw CanvasServiceException(
          errorCode: 'invalid_reference',
          message: 'Unknown refType: $refType',
        );
    }
  }
}

int _max(int a, int b) => a > b ? a : b;

Future<Map<String, Offset>> _computeCanvasLayout(CanvasLayoutRequest request) {
  return Isolate.run(
    () => switch (request.mode) {
      canvasLayoutAuto => resolveCanvasAutoLayout(
        nodes: [
          for (final node in request.nodes)
            (id: node.id, position: node.position, size: node.size),
        ],
        edges: [
          for (final edge in request.edges)
            (sourceNodeId: edge.sourceNodeId, targetNodeId: edge.targetNodeId),
        ],
      ),
      canvasLayoutGrid => resolveCanvasGridLayout(request.nodes),
      canvasLayoutTreeLr || canvasLayoutTreeTb => resolveCanvasTreeLayout(
        nodes: request.nodes,
        edges: request.edges,
        direction: request.mode == canvasLayoutTreeTb
            ? CanvasTreeDirection.top_to_bottom
            : CanvasTreeDirection.left_to_right,
      ),
      _ => throw ArgumentError('Unknown canvas layout mode.'),
    },
  );
}

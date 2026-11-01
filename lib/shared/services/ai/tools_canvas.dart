// 职责: 按公共资源目标与操作契约执行画布、节点和边的读写，复用画布业务服务
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_support.dart
//   lib/shared/services/canvas_service.dart
//   lib/shared/models/canvas_layout.dart
//   lib/shared/models/canvas_ai_activity.dart
part of 'tools.dart';

// 路径、操作权限与输入规范化由公共 harness 完成；执行器只定位业务实体并执行。

const String canvasNodesSegment = 'nodes';
const String canvasEdgesSegment = 'edges';
const String canvasLayoutField = 'layout';
const String canvasOpenField = 'open';

/// 画布页演一步的等待上限。正常一步(镜头 + 揭示)不到 1.3 秒,超过说明 UI 卡住了。
const Duration _canvasPacingTimeout = Duration(milliseconds: 1500);

bool isCanvasPath(ParsedPath parsed) => parsed.collection == 'canvas';

// ---- 路径构造 ----

String _canvasResourcePath(String name) => 'canvas/$name';

String _canvasChildListingPath(String name, String segment) =>
    'canvas/$name/$segment';

String _canvasChildPath(String name, String segment, String id) =>
    'canvas/$name/$segment/$id';

// ---- 响应 path ----

/// 过渡结果适配使用公共匹配器保留的完整目标；业务返回的新路径优先。
Map<String, dynamic>? attachCanvasResourcePath(
  ParsedPath parsed,
  Map<String, dynamic> out,
) => isCanvasPath(parsed) ? _attachResultPath(out, parsed.displayPath) : null;

/// 输入已由 schema 规范化为标准方向；这里只转换为布局模型的枚举。
CanvasPlaceDirection? _canvasPlaceDirection(String? value) =>
    value == null ? null : CanvasPlaceDirection.values.byName(value);

/// 节点在画布上占据的矩形；缺尺寸时按类型回落默认值(与 UI 渲染用的同一份常量)。
Rect _canvasNodeRect(CanvasNode node) {
  final fallback = node.type == canvasNodeTypeSticky
      ? canvasStickyDefaultSize
      : canvasReferenceDefaultSize;
  return Rect.fromLTWH(
    node.x,
    node.y,
    node.width ?? fallback.width,
    node.height ?? fallback.height,
  );
}

/// 自定义色统一存大写 hex，与 UI 取色器写入的格式一致。
String? _canvasColorInput(String? value) =>
    value != null && value.startsWith('#') ? value.toUpperCase() : value;

String? _canvasNodeColor(CanvasNode node) {
  final color = canvasNodeColorValueOf(node.style);
  if (color == null && node.type == canvasNodeTypeSticky) {
    return canvasStickyColorDefault;
  }
  return color;
}

/// [includeContent] 只在单资源读取时为 true：listing 要保持轻量，不带便签正文
/// （与其他集合的 listing 一致）；单个节点则必须给出正文，否则 `/content` 字段
/// 路径也读不到。
Map<String, dynamic> _canvasNodeToJson(
  CanvasNode node, {
  required String path,
  bool includeContent = false,
}) {
  final (col, row) = canvasGridCellOf(Offset(node.x, node.y));
  return {
    'path': path,
    ..._canvasNodeDefinition.readValues({
      'id': node.id,
      'type': node.type,
      'ref_type': node.refType,
      'ref_id': node.refId,
      'title': node.title,
      'content': node.content,
      'color': _canvasNodeColor(node),
      'x': node.x,
      'y': node.y,
      'col': col,
      'row': row,
      'width': node.width,
      'height': node.height,
    }, listing: !includeContent),
  };
}

Map<String, dynamic> _canvasEdgeToJson(
  CanvasEdge edge, {
  required String path,
}) {
  return {
    'id': edge.id,
    'path': path,
    'source_node_id': edge.sourceNodeId,
    'target_node_id': edge.targetNodeId,
    'type': edge.type,
    'label': edge.label ?? '',
  };
}

// ---- Mixin ----

mixin _AiToolManagerCanvasMixin on _AiToolManagerBase {
  /// 广播一次画布操作,供画布 UI 跟随镜头与显示状态条。
  ///
  /// 只在写库成功后调用:失败的操作不该让镜头飞过去。读取(scan)也会上报,画布页
  /// 据此显示「AI 正在看画布」。未打开画布页时 reporter 为 null,静默跳过 ——
  /// 这是纯 UI 通知通道,缺席不影响工具语义。
  ///
  /// 画布页开着时会等它演完这一步再返回:批量处理一瞬间发起几十次调用,画面也能
  /// 一个一个跟上。等待最多 [_canvasPacingTimeout],回合取消立刻放行 —— UI 卡住
  /// 不能拖住 AI 回合。
  Future<void> _reportCanvasActivity(
    String canvasId,
    CanvasAiActivityKind kind, {
    List<String> focusNodeIds = const <String>[],
  }) async {
    final pacing = canvasActivityReporter?.call(
      CanvasAiActivity(
        canvasId: canvasId,
        kind: kind,
        focusNodeIds: focusNodeIds,
      ),
    );
    if (pacing is! Future<void>) {
      return;
    }
    final released = Completer<void>();
    void release() {
      if (!released.isCompleted) {
        released.complete();
      }
    }

    final timer = Timer(_canvasPacingTimeout, release);
    final unsubscribe = _currentToolExecutionContext?.cancellationToken
        ?.onCancel(release);
    // 节奏只是 UI 体验:画布页报错也只放行,不影响工具结果。
    unawaited(pacing.then((_) => release(), onError: (Object _) => release()));
    try {
      await released.future;
    } finally {
      timer.cancel();
      unsubscribe?.call();
    }
  }

  Map<String, dynamic> _canvasError({
    required String path,
    required ToolErrorCode errorCode,
    required String message,
    required String operation,
    String? hint,
    List<String>? missingFields,
    List<String>? requiredFields,
  }) {
    return AiToolManager._structuredWriteError(
      path: path,
      errorCode: errorCode,
      message: message,
      operation: operation,
      hint: hint,
      missingFields: missingFields,
      requiredFields: requiredFields,
    );
  }

  Map<String, dynamic> _canvasNotFound(String name, String operation) {
    return _canvasError(
      path: _canvasResourcePath(name),
      errorCode: ToolErrorCode.not_found,
      message: 'Canvas not found: $name',
      operation: operation,
      hint:
          'Read ${_resourceReferencePath('canvas')} and copy an existing entries[].path.',
    );
  }

  /// 按名称解析画布；重名(唯一索引失效)与不存在都返回结构化错误。
  Future<(CanvasEntry?, Map<String, dynamic>?)> _resolveCanvasByName(
    String name,
    String operation,
  ) async {
    try {
      final canvas = await _contentService.canvasService.getCanvasByName(name);
      if (canvas == null) {
        return (null, _canvasNotFound(name, operation));
      }
      return (canvas, null);
    } on CanvasServiceException catch (e) {
      return (
        null,
        _canvasError(
          path: _canvasResourcePath(name),
          errorCode: _serviceErrorCode(e.errorCode),
          message: e.message,
          operation: operation,
        ),
      );
    }
  }

  Future<({List<CanvasNode> nodes, List<CanvasEdge> edges})> _canvasSnapshot(
    String canvasId,
  ) {
    return _contentService.canvasService.watchCanvasContent(canvasId).first;
  }

  // ---- 执行 ----

  /// 所有入口在公共 gate 和规范化后进入此处，直接使用已匹配的资源及操作。
  /// listing 的过滤和分页继续由 Read 的公共流程处理。
  Future<Map<String, dynamic>> _executeCanvas(
    ParsedPath parsed,
    _ResourceOperation operation, {
    Map<String, dynamic> fields = const {},
    ({String oldText, String newText, bool replaceAll})? edit,
    bool force = false,
  }) async {
    final target = parsed._resource!;
    final tool = operation.tool;
    if (target.schema.segment == 'canvas' &&
        operation.target == _ResourceTargetKind.listing) {
      return switch (tool) {
        _ResourceTool.read => _readCanvasCollection(),
        _ResourceTool.create => _createCanvas(fields),
        _ => throw StateError(
          'Unbound canvas listing operation: ${operation.key}',
        ),
      };
    }

    final (canvas, error) = await _resolveCanvasByName(
      target.ids['name']!,
      tool.name,
    );
    if (error != null) {
      return tool == _ResourceTool.remove &&
              force &&
              error['error_code'] == ToolErrorCode.not_found.name
          ? {'ok': true, 'removed': true, 'missing': true}
          : error;
    }
    final entry = canvas!;
    final id = target.ids[target.schema.itemToken];

    switch ((tool, target.schema.segment, operation.target)) {
      case (_ResourceTool.read, 'canvas', _ResourceTargetKind.resource):
        return _readCanvasResource(entry);
      case (_ResourceTool.read, 'canvas', _ResourceTargetKind.field):
        return operation.field == canvasLayoutField
            ? _readCanvasLayout(entry)
            : _readCanvasField(entry, operation.field!);
      case (
        _ResourceTool.read,
        canvasNodesSegment,
        _ResourceTargetKind.listing,
      ):
        return _readCanvasNodeListing(entry);
      case (
        _ResourceTool.read,
        canvasEdgesSegment,
        _ResourceTargetKind.listing,
      ):
        return _readCanvasEdgeListing(entry);
      case (_ResourceTool.read, canvasNodesSegment, _):
        return _readCanvasNode(entry, id!, operation.field);
      case (_ResourceTool.read, canvasEdgesSegment, _):
        return _readCanvasEdge(entry, id!, operation.field);
      case (
        _ResourceTool.create,
        canvasNodesSegment,
        _ResourceTargetKind.listing,
      ):
        return _createCanvasNode(entry, fields);
      case (
        _ResourceTool.create,
        canvasEdgesSegment,
        _ResourceTargetKind.listing,
      ):
        return _createCanvasEdge(entry, fields);
      case (_ResourceTool.write, 'canvas', _):
        return switch (operation.field) {
          canvasLayoutField => _writeCanvasLayout(
            entry,
            fields[canvasLayoutField] as String,
          ),
          canvasOpenField => _writeCanvasOpen(entry),
          _ => _writeCanvasResource(entry, fields),
        };
      case (_ResourceTool.write, canvasNodesSegment, _):
        return _writeCanvasNode(parsed, entry, id!, fields);
      case (_ResourceTool.edit, canvasNodesSegment, _ResourceTargetKind.field):
        return _editCanvasNode(
          parsed,
          entry,
          id!,
          edit!.oldText,
          edit.newText,
          edit.replaceAll,
        );
      case (_ResourceTool.remove, 'canvas', _ResourceTargetKind.resource):
        await _contentService.canvasService.softDeleteCanvas(entry.id);
        return {
          'ok': true,
          'path': _canvasResourcePath(entry.name),
          'removed': true,
        };
      case (
        _ResourceTool.remove,
        canvasNodesSegment,
        _ResourceTargetKind.resource,
      ):
        return _removeCanvasNode(entry, id!, force: force);
      case (
        _ResourceTool.remove,
        canvasEdgesSegment,
        _ResourceTargetKind.resource,
      ):
        return _removeCanvasEdge(entry, id!, force: force);
      default:
        throw StateError(
          'Unbound canvas operation: ${target.schema.segment} ${operation.key}',
        );
    }
  }

  Future<Map<String, dynamic>> _readCanvasCollection() async {
    final canvases = await _contentService.database.canvasDao.getAllCanvases();
    final entries = <Map<String, dynamic>>[];
    for (final canvas in canvases) {
      final snapshot = await _canvasSnapshot(canvas.id);
      entries.add({
        'id': canvas.id,
        'name': canvas.name,
        'path': _canvasResourcePath(canvas.name),
        'description': canvas.description,
        'node_count': snapshot.nodes.length,
        'edge_count': snapshot.edges.length,
      });
    }
    return {'type': 'listing', 'entries': entries};
  }

  Future<Map<String, dynamic>> _readCanvasResource(CanvasEntry canvas) async {
    final snapshot = await _canvasSnapshot(canvas.id);
    await _reportCanvasActivity(canvas.id, CanvasAiActivityKind.scan);
    return {
      'path': _canvasResourcePath(canvas.name),
      'id': canvas.id,
      'name': canvas.name,
      'description': canvas.description,
      'node_count': snapshot.nodes.length,
      'edge_count': snapshot.edges.length,
    };
  }

  Map<String, dynamic> _readCanvasField(CanvasEntry canvas, String field) => {
    'path': 'canvas/${canvas.name}/$field',
    'value': switch (field) {
      'name' => canvas.name,
      'description' => canvas.description,
      _ => throw StateError('Unbound canvas read field: $field'),
    },
  };

  /// 摆位摘要。`off_grid` 是被用户手拖过、不参与重排的节点数 —— 模型看不到这个
  /// 数字时只能盲调 layout。
  Future<Map<String, dynamic>> _readCanvasLayout(CanvasEntry canvas) async {
    final snapshot = await _canvasSnapshot(canvas.id);
    var offGrid = 0;
    for (final node in snapshot.nodes) {
      final position = Offset(node.x, node.y);
      final (col, row) = canvasGridCellOf(position);
      if (canvasGridOrigin(col, row) != position) {
        offGrid += 1;
      }
    }
    return {
      'path': 'canvas/${canvas.name}/$canvasLayoutField',
      'value': {
        'node_count': snapshot.nodes.length,
        'edge_count': snapshot.edges.length,
        'off_grid': offGrid,
        'mode': canvas.layout,
        'grid_pitch': {'x': canvasGridPitchX, 'y': canvasGridPitchY},
      },
    };
  }

  Future<Map<String, dynamic>> _readCanvasNodeListing(
    CanvasEntry canvas,
  ) async {
    final snapshot = await _canvasSnapshot(canvas.id);
    await _reportCanvasActivity(canvas.id, CanvasAiActivityKind.scan);
    return {
      'type': 'listing',
      'canvas': canvas.name,
      'entries': [
        for (final node in snapshot.nodes)
          _canvasNodeToJson(
            node,
            path: _canvasChildPath(canvas.name, canvasNodesSegment, node.id),
          ),
      ],
    };
  }

  Future<Map<String, dynamic>> _readCanvasEdgeListing(
    CanvasEntry canvas,
  ) async {
    final snapshot = await _canvasSnapshot(canvas.id);
    await _reportCanvasActivity(canvas.id, CanvasAiActivityKind.scan);
    return {
      'type': 'listing',
      'canvas': canvas.name,
      'entries': [
        for (final edge in snapshot.edges)
          _canvasEdgeToJson(
            edge,
            path: _canvasChildPath(canvas.name, canvasEdgesSegment, edge.id),
          ),
      ],
    };
  }

  Future<Map<String, dynamic>> _readCanvasNode(
    CanvasEntry canvas,
    String nodeId,
    String? field,
  ) async {
    final node = await _loadCanvasNode(canvas.id, nodeId);
    if (node == null) {
      return _canvasNodeNotFound(canvas.name, nodeId, 'read');
    }
    final path = _canvasChildPath(canvas.name, canvasNodesSegment, nodeId);
    final json = _canvasNodeToJson(node, path: path, includeContent: true);
    if (field == null) {
      return {'path': path, ...json};
    }
    if (!json.containsKey(field)) {
      return _canvasError(
        path: '$path/$field',
        errorCode: ToolErrorCode.invalid_argument,
        message:
            'Unknown node field: $field. Available: ${json.keys.join(', ')}.',
        operation: 'read',
      );
    }
    return {'path': '$path/$field', 'value': json[field]};
  }

  Future<Map<String, dynamic>> _readCanvasEdge(
    CanvasEntry canvas,
    String edgeId,
    String? field,
  ) async {
    final snapshot = await _canvasSnapshot(canvas.id);
    CanvasEdge? edge;
    for (final candidate in snapshot.edges) {
      if (candidate.id == edgeId) {
        edge = candidate;
        break;
      }
    }
    if (edge == null) {
      return _canvasEdgeNotFound(canvas.name, edgeId, 'read');
    }
    final path = _canvasChildPath(canvas.name, canvasEdgesSegment, edgeId);
    final json = _canvasEdgeToJson(edge, path: path);
    if (field == null) {
      return {'path': path, ...json};
    }
    return {'path': '$path/$field', 'value': json[field]};
  }

  /// 读节点并校验它属于这张画布 —— 光按 id 查会让模型改到另一张画布上的节点。
  Future<CanvasNode?> _loadCanvasNode(String canvasId, String nodeId) async {
    final node = await _contentService.database.canvasDao.getNodeById(nodeId);
    if (node == null || node.canvasId != canvasId) {
      return null;
    }
    return node;
  }

  Map<String, dynamic> _canvasNodeNotFound(
    String canvasName,
    String nodeId,
    String operation,
  ) {
    return _canvasError(
      path: _canvasChildPath(canvasName, canvasNodesSegment, nodeId),
      errorCode: ToolErrorCode.not_found,
      message: 'Node $nodeId not found on canvas "$canvasName"',
      operation: operation,
      hint:
          'Read ${_resourceReferencePath(_canvasChildListingPath(canvasName, canvasNodesSegment))} and '
          'copy an entries[].path.',
    );
  }

  Map<String, dynamic> _canvasEdgeNotFound(
    String canvasName,
    String edgeId,
    String operation,
  ) {
    return _canvasError(
      path: _canvasChildPath(canvasName, canvasEdgesSegment, edgeId),
      errorCode: ToolErrorCode.not_found,
      message: 'Edge $edgeId not found on canvas "$canvasName"',
      operation: operation,
    );
  }

  // ---- Create ----

  Future<Map<String, dynamic>> _createCanvas(
    Map<String, dynamic> fields,
  ) async {
    final name = fields['name'] as String;
    final String canvasId;
    try {
      canvasId = await _contentService.canvasService.createCanvas(
        name: name,
        description: fields['description'] as String? ?? '',
      );
    } on CanvasServiceException catch (e) {
      return _canvasError(
        path: 'canvas',
        errorCode: _serviceErrorCode(e.errorCode),
        message: e.message,
        operation: 'create',
        hint: e.errorCode == 'duplicate_name'
            ? 'Canvas names are unique and act as the path key; pick another '
                  'name or write to the existing canvas/$name.'
            : null,
      );
    }
    // 宿主据此把新画布的详情页推上来 —— 用户刚让 AI 建图，下一秒就该看见它。
    await _reportCanvasActivity(canvasId, CanvasAiActivityKind.create_canvas);
    return {
      'ok': true,
      'path': _canvasResourcePath(name),
      'id': canvasId,
      'name': name,
      'created': true,
    };
  }

  Future<Map<String, dynamic>> _createCanvasNode(
    CanvasEntry canvas,
    Map<String, dynamic> fields,
  ) async {
    final listingPath = _canvasChildListingPath(
      canvas.name,
      canvasNodesSegment,
    );
    final type = fields['type'] as String;
    final color = _canvasColorInput(fields['color'] as String?);
    final direction = _canvasPlaceDirection(fields['direction'] as String?);

    final width = (fields['width'] as num?)?.toDouble();
    final height = (fields['height'] as num?)?.toDouble();

    try {
      final placement = await _resolveCanvasNodePlacementFromFields(
        canvasId: canvas.id,
        type: type,
        width: width,
        height: height,
        fields: fields,
        direction: direction,
      );
      final position = placement.position;
      final nodeId = await _contentService.canvasService.addNode(
        canvasId: canvas.id,
        type: type,
        refType: fields['ref_type'] as String?,
        refId: fields['ref_id'] as String?,
        title: fields['title'] as String?,
        content: fields['content'] as String?,
        x: position.dx,
        y: position.dy,
        width: width,
        height: height,
        style: color != null || type == canvasNodeTypeSticky
            ? canvasStyleWithColor(null, color ?? canvasStickyColorDefault)
            : null,
      );
      final (col, row) = canvasGridCellOf(position);
      await _reportCanvasActivity(
        canvas.id,
        CanvasAiActivityKind.add_node,
        focusNodeIds: [nodeId],
      );
      return {
        'ok': true,
        'created': true,
        'path': _canvasChildPath(canvas.name, canvasNodesSegment, nodeId),
        'id': nodeId,
        'x': position.dx,
        'y': position.dy,
        'col': col,
        'row': row,
        'adjusted': placement.adjusted,
      };
    } on CanvasServiceException catch (e) {
      return _canvasError(
        path: listingPath,
        errorCode: _serviceErrorCode(e.errorCode),
        message: e.message,
        operation: 'create',
      );
    }
  }

  /// 把摆位入参解析成最终坐标。
  ///
  /// 读一次画布快照拿到已有节点矩形，交给 [resolveCanvasNodePlacement] 做确定性
  /// 摆位 —— 模型只需要表达「第几格」或「挨着谁」，重叠与对齐由算法保证。
  Future<CanvasPlacement> _resolveCanvasNodePlacementFromFields({
    required String canvasId,
    required String type,
    required double? width,
    required double? height,
    required Map<String, dynamic> fields,
    required CanvasPlaceDirection? direction,
    String? excludeNodeId,
  }) async {
    final fallback = type == canvasNodeTypeSticky
        ? canvasStickyDefaultSize
        : canvasReferenceDefaultSize;
    final size = Size(width ?? fallback.width, height ?? fallback.height);

    final hasExplicit = fields['x'] != null && fields['y'] != null;
    final explicit = hasExplicit
        ? Offset(
            (fields['x'] as num).toDouble(),
            (fields['y'] as num).toDouble(),
          )
        : null;

    final snapshot = await _canvasSnapshot(canvasId);
    final occupied = [
      for (final node in snapshot.nodes)
        if (node.id != excludeNodeId) _canvasNodeRect(node),
    ];

    final nearId = fields['near'] as String?;
    Rect? anchor;
    if (nearId != null && direction != null) {
      for (final node in snapshot.nodes) {
        if (node.id == nearId) {
          anchor = _canvasNodeRect(node);
          break;
        }
      }
    }

    return resolveCanvasNodePlacement(
      size: size,
      occupied: occupied,
      explicit: explicit,
      anchor: anchor,
      direction: anchor == null ? null : direction,
      col: fields['col'] as int?,
      row: fields['row'] as int?,
    );
  }

  Future<Map<String, dynamic>> _createCanvasEdge(
    CanvasEntry canvas,
    Map<String, dynamic> fields,
  ) async {
    final listingPath = _canvasChildListingPath(
      canvas.name,
      canvasEdgesSegment,
    );
    final sourceNodeId = fields['source_node_id'] as String;
    final targetNodeId = fields['target_node_id'] as String;
    final type = fields['type'] as String;
    final label = fields['label'] as String?;

    try {
      final edgeId = await _contentService.canvasService.addEdge(
        canvasId: canvas.id,
        sourceNodeId: sourceNodeId,
        targetNodeId: targetNodeId,
        type: type,
        // 空标签沿用既有的无标签语义；值的 trim 和类型规范化已由公共层完成。
        label: label == '' ? null : label,
      );
      await _reportCanvasActivity(
        canvas.id,
        CanvasAiActivityKind.add_edge,
        focusNodeIds: [sourceNodeId, targetNodeId],
      );
      return {
        'ok': true,
        'created': true,
        'path': _canvasChildPath(canvas.name, canvasEdgesSegment, edgeId),
        'id': edgeId,
      };
    } on CanvasServiceException catch (e) {
      return _canvasError(
        path: listingPath,
        errorCode: _serviceErrorCode(e.errorCode),
        message: e.message,
        operation: 'create',
      );
    }
  }

  // ---- Write ----

  Future<Map<String, dynamic>> _writeCanvasLayout(
    CanvasEntry canvas,
    String mode,
  ) async {
    final path = 'canvas/${canvas.name}/$canvasLayoutField';
    try {
      final result = await _contentService.canvasService.applyLayout(
        canvas.id,
        mode,
      );
      await _reportCanvasActivity(canvas.id, CanvasAiActivityKind.auto_layout);
      return {
        'ok': true,
        'path': path,
        'updated': result.moved > 0 || result.modeChanged,
      };
    } on CanvasServiceException catch (e) {
      return _canvasError(
        path: path,
        errorCode: _serviceErrorCode(e.errorCode),
        message: e.message,
        operation: 'write',
      );
    }
  }

  /// 让宿主把这张画布打开到用户面前。
  ///
  /// 纯 UI 动作，不写库 —— 宿主没打开画布页时(reporter 为空)静默跳过，工具仍然
  /// 返回 ok:true：模型据此继续往下画，不必为「打不开」重试。
  Map<String, dynamic> _writeCanvasOpen(CanvasEntry canvas) {
    // 打开画布是导航动作，没有要演的内容，不等节奏。
    unawaited(
      _reportCanvasActivity(canvas.id, CanvasAiActivityKind.open_canvas),
    );
    return {'ok': true};
  }

  Future<Map<String, dynamic>> _writeCanvasResource(
    CanvasEntry canvas,
    Map<String, dynamic> fields,
  ) async {
    final hasName = fields.containsKey('name');
    final hasDescription = fields.containsKey('description');
    var resolvedName = canvas.name;
    final updated = <String>[];
    try {
      if (hasName && fields['name'] != canvas.name) {
        final newName = fields['name'] as String;
        await _contentService.canvasService.renameCanvas(
          canvasId: canvas.id,
          name: newName,
        );
        resolvedName = newName;
        updated.add('name');
      }
      if (hasDescription && fields['description'] != canvas.description) {
        await _contentService.canvasService.updateCanvasDescription(
          canvasId: canvas.id,
          description: fields['description'] as String,
        );
        updated.add('description');
      }
    } on CanvasServiceException catch (e) {
      return _canvasError(
        path: _canvasResourcePath(canvas.name),
        errorCode: _serviceErrorCode(e.errorCode),
        message: e.message,
        operation: 'write',
      );
    }

    return {
      'ok': true,
      'path': _canvasResourcePath(resolvedName),
      'updated': updated.isNotEmpty,
      'fields': updated,
      if (resolvedName != canvas.name)
        'hint':
            'Canvas renamed; the old path canvas/${canvas.name} no longer '
            'resolves.',
    };
  }

  Future<Map<String, dynamic>> _writeCanvasNode(
    ParsedPath parsed,
    CanvasEntry canvas,
    String nodeId,
    Map<String, dynamic> fields,
  ) async {
    final path = _canvasChildPath(canvas.name, canvasNodesSegment, nodeId);
    final node = await _loadCanvasNode(canvas.id, nodeId);
    if (node == null) {
      return _canvasNodeNotFound(canvas.name, nodeId, 'write');
    }

    final targetError = _validateTargetRequirements(
      parsed,
      _ResourceTool.write,
      fields,
      {'type': fields['type'] ?? node.type},
    );
    if (targetError != null) {
      return targetError;
    }

    final hasGrid = fields['col'] != null || fields['row'] != null;
    final hasExplicit = fields['x'] != null || fields['y'] != null;
    final hasTitle = fields.containsKey('title');
    final hasContent = fields.containsKey('content');
    final color = _canvasColorInput(fields['color'] as String?);

    final updated = <String>[];
    var movedTo = Offset(node.x, node.y);
    var adjusted = false;
    try {
      if (hasGrid || hasExplicit) {
        final placement = await _resolveCanvasNodePlacementFromFields(
          canvasId: canvas.id,
          type: fields['type'] as String? ?? node.type,
          width: node.width,
          height: node.height,
          fields: {
            ...fields,
            // 只给了一维时补上另一维的当前值，避免节点被挪到 0。
            if (hasExplicit) 'x': fields['x'] ?? node.x,
            if (hasExplicit) 'y': fields['y'] ?? node.y,
          },
          direction: _canvasPlaceDirection(fields['direction'] as String?),
          excludeNodeId: node.id,
        );
        movedTo = placement.position;
        adjusted = placement.adjusted;
        if (movedTo.dx != node.x || movedTo.dy != node.y) {
          updated.add(hasGrid ? 'col/row' : 'x/y');
        }
      }
      await _contentService.canvasService.updateNode(
        nodeId: nodeId,
        type: fields['type'] as String?,
        refType: fields.containsKey('ref_type')
            ? Value(fields['ref_type'] as String?)
            : const Value.absent(),
        refId: fields.containsKey('ref_id')
            ? Value(fields['ref_id'] as String?)
            : const Value.absent(),
        title: hasTitle ? fields['title'] as String : null,
        content: hasContent ? fields['content'] as String : null,
        style: fields.containsKey('color')
            ? canvasStyleWithColor(node.style, color)
            : null,
        x: hasGrid || hasExplicit ? movedTo.dx : null,
        y: hasGrid || hasExplicit ? movedTo.dy : null,
      );
      updated.addAll([
        for (final field in [
          'type',
          'ref_type',
          'ref_id',
          'title',
          'color',
          'content',
        ])
          if (fields.containsKey(field) &&
              switch (field) {
                'type' => fields[field] != node.type,
                'ref_type' => fields[field] != node.refType,
                'ref_id' => fields[field] != node.refId,
                'title' => fields[field] != node.title,
                'content' => fields[field] != node.content,
                'color' =>
                  canvasStyleWithColor(node.style, color) != node.style,
                _ => false,
              })
            field,
      ]);
    } on CanvasServiceException catch (e) {
      return _canvasError(
        path: path,
        errorCode: _serviceErrorCode(e.errorCode),
        message: e.message,
        operation: 'write',
      );
    }

    await _reportCanvasActivity(
      canvas.id,
      CanvasAiActivityKind.update_node,
      focusNodeIds: [nodeId],
    );
    final (col, row) = canvasGridCellOf(movedTo);
    return {
      'ok': true,
      'path': path,
      'updated': updated.isNotEmpty,
      'fields': updated,
      if (hasGrid || hasExplicit) ...{
        'x': movedTo.dx,
        'y': movedTo.dy,
        'col': col,
        'row': row,
        'adjusted': adjusted,
      },
    };
  }

  // ---- Edit ----

  Future<String?> _previewCanvasEditableText(ParsedPath parsed) async {
    final (canvas, error) = await _resolveCanvasByName(
      parsed.locator('name')!,
      'edit',
    );
    if (error != null) {
      return null;
    }
    final node = await _loadCanvasNode(canvas!.id, parsed.locator('node_id')!);
    if (node == null ||
        _validateTargetRequirements(parsed, _ResourceTool.edit, const {}, {
              'type': node.type,
            }) !=
            null) {
      return null;
    }
    return node.content;
  }

  /// 便签正文的精确替换；字段权限由公共操作定义检查，类型由实际节点检查。
  Future<Map<String, dynamic>> _editCanvasNode(
    ParsedPath parsed,
    CanvasEntry entry,
    String nodeId,
    String oldText,
    String newText,
    bool replaceAll,
  ) async {
    final node = await _loadCanvasNode(entry.id, nodeId);
    if (node == null) {
      return _canvasNodeNotFound(entry.name, nodeId, 'edit');
    }
    final path =
        '${_canvasChildPath(entry.name, canvasNodesSegment, nodeId)}'
        '/content';
    final targetError = _validateTargetRequirements(
      parsed,
      _ResourceTool.edit,
      const {},
      {'type': node.type},
    );
    if (targetError != null) {
      return targetError;
    }

    final replaced = AiToolManager._replaceExactText(
      node.content,
      oldText,
      newText,
      path: path,
      replaceAll: replaceAll,
    );
    if (replaced.error != null) {
      return _canvasError(
        path: path,
        errorCode: replaced.errorCode ?? ToolErrorCode.internal,
        message: replaced.error!,
        operation: 'edit',
        hint: replaced.hint,
      );
    }

    try {
      await _contentService.canvasService.updateNodeContent(
        nodeId: nodeId,
        content: replaced.value ?? newText,
      );
    } on CanvasServiceException catch (e) {
      return _canvasError(
        path: path,
        errorCode: _serviceErrorCode(e.errorCode),
        message: e.message,
        operation: 'edit',
      );
    }
    await _reportCanvasActivity(
      entry.id,
      CanvasAiActivityKind.update_node,
      focusNodeIds: [nodeId],
    );
    return {
      'ok': true,
      'path': path,
      'edited': replaced.changed,
      'match_count': replaced.matchCount,
    };
  }

  // ---- Remove ----

  Future<Map<String, dynamic>> _removeCanvasNode(
    CanvasEntry canvas,
    String nodeId, {
    required bool force,
  }) async {
    final path = _canvasChildPath(canvas.name, canvasNodesSegment, nodeId);
    final node = await _loadCanvasNode(canvas.id, nodeId);
    if (node == null) {
      return force
          ? {'ok': true, 'path': path, 'removed': true, 'missing': true}
          : _canvasNodeNotFound(canvas.name, nodeId, 'remove');
    }
    try {
      await _contentService.canvasService.softDeleteNode(nodeId);
    } on CanvasServiceException catch (e) {
      return _canvasError(
        path: path,
        errorCode: _serviceErrorCode(e.errorCode),
        message: e.message,
        operation: 'remove',
      );
    }
    await _reportCanvasActivity(canvas.id, CanvasAiActivityKind.remove_node);
    return {'ok': true, 'path': path, 'removed': true};
  }

  Future<Map<String, dynamic>> _removeCanvasEdge(
    CanvasEntry canvas,
    String edgeId, {
    required bool force,
  }) async {
    final path = _canvasChildPath(canvas.name, canvasEdgesSegment, edgeId);
    final snapshot = await _canvasSnapshot(canvas.id);
    final exists = snapshot.edges.any((edge) => edge.id == edgeId);
    if (!exists) {
      return force
          ? {'ok': true, 'path': path, 'removed': true, 'missing': true}
          : _canvasEdgeNotFound(canvas.name, edgeId, 'remove');
    }
    try {
      await _contentService.canvasService.hardDeleteEdge(edgeId);
    } on CanvasServiceException catch (e) {
      return _canvasError(
        path: path,
        errorCode: _serviceErrorCode(e.errorCode),
        message: e.message,
        operation: 'remove',
      );
    }
    await _reportCanvasActivity(canvas.id, CanvasAiActivityKind.remove_edge);
    return {'ok': true, 'path': path, 'removed': true};
  }
}

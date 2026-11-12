// 职责: 共用制作派生产物的落点和让位算法，为交互坐标与持久画布提供一致布局。
// 关联文件:
//   lib/desktop/features/production/board.dart
//   lib/shared/services/production/grid_orchestrator.dart
//   lib/shared/models/production/group_layout.dart
//   lib/shared/services/production/canvas_service.dart

import 'dart:math' as math;
import 'dart:ui';
import 'canvas_service.dart';
import '../../database/novel_content_database.dart';
import '../../models/production/asset_content.dart';
import '../../theme/theme.dart';

/// 产物与源节点之间的水平间距，留给连线。
const double productionDerivedGap = 120;

/// 同一列里上下两个产物的间距；与场次内片段的间距一致，标题不压上一张卡。
const double _rowGap = RevericSpacing.x4l + productionCardHeaderExtent;

/// 判断挡路时节点之间至少留出的空隙。
const double _clearance = RevericSpacing.x4l;

/// [nodes] 是画布上所有节点当前的卡片矩形（渲染坐标，不含卡片外的标题）；
/// [sceneOf] 把场内片段映射到场次，场次作为一个整体移动；[siblings] 是这个源节点已有的产物。
///
/// 第一个产物放在源节点（所在场次）右侧并与它顶边对齐，之后的产物排在最下面一个产物的下方。
/// 落点那一行里、源节点右侧的节点离得不够远时整体右移；被移动的节点又撞上别的节点时，后者跟着一起移。
ProductionNodePlacement productionDerivedPlacement({
  required String sourceId,
  required Size size,
  required Map<String, Rect> nodes,
  required Map<String, String> sceneOf,
  Map<String, String> groupOf = const {},
  required Iterable<String> siblings,
}) {
  // 移动单位：场次整场一份（按色带算），其余节点各一份（向上带出标题）。
  final members = <String, List<String>>{};
  String unitOf(String id) => groupOf[id] != null
      ? 'group/${groupOf[id]}'
      : sceneOf[id] == null
      ? 'node/$id'
      : 'scene/${sceneOf[id]}';
  for (final id in nodes.keys) {
    (members[unitOf(id)] ??= []).add(id);
  }
  final units = {
    for (final MapEntry(key: unit, value: ids) in members.entries)
      unit: unit.startsWith('scene/')
          ? productionSceneBand(
              ids
                  .map((id) => nodes[id]!)
                  .reduce((a, b) => a.expandToInclude(b)),
            )
          : _withHeader(
              ids
                  .map((id) => nodes[id]!)
                  .reduce((a, b) => a.expandToInclude(b)),
            ),
  };
  final sourceUnit = unitOf(sourceId);
  final source = nodes[sourceId]!;
  final fixed = {sourceUnit, for (final id in siblings) unitOf(id)};

  final lowest = siblings
      .map((id) => nodes[id])
      .nonNulls
      .fold<Rect?>(
        null,
        (lowest, rect) =>
            lowest == null || rect.bottom > lowest.bottom ? rect : lowest,
      );
  var slot = _withHeader(
    lowest == null
        ? Offset(
                math.max(source.right, units[sourceUnit]!.right) +
                    productionDerivedGap,
                source.top,
              ) &
              size
        : Offset(lowest.left, lowest.bottom + _rowGap) & size,
  );

  // 只推源节点右侧的节点；左侧或横跨过来的节点挡住落点时，落点往下让。
  final right = units[sourceUnit]!.right;
  bool pushable(String unit) =>
      !fixed.contains(unit) && units[unit]!.left >= right;
  for (
    var hit = _firstHit(units, slot, (unit) => !pushable(unit));
    hit != null;
    hit = _firstHit(units, slot, (unit) => !pushable(unit))
  ) {
    slot = slot.translate(0, hit.bottom + _rowGap - slot.top);
  }

  final row = [
    for (final MapEntry(key: unit, value: rect) in units.entries)
      if (pushable(unit) && rect.top < slot.bottom && rect.bottom > slot.top)
        unit,
  ];
  final dx = row.isEmpty
      ? 0.0
      : slot.right +
            productionDerivedGap -
            row.map((unit) => units[unit]!.left).reduce(math.min);
  final moving = <String>{};
  if (dx > 0) {
    moving.addAll(row);
    // 连锁：右移后撞上的节点跟着移同样的距离，相对位置不变。
    for (var grew = true; grew;) {
      grew = false;
      for (final MapEntry(key: unit, value: rect) in units.entries) {
        if (moving.contains(unit) || !pushable(unit)) {
          continue;
        }
        if (moving.any(
          (other) => units[other]!
              .translate(dx, 0)
              .inflate(_clearance / 2)
              .overlaps(rect.inflate(_clearance / 2)),
        )) {
          moving.add(unit);
          grew = true;
        }
      }
    }
  }

  return (
    at: (x: slot.left, y: slot.top + productionCardHeaderExtent),
    moves: {
      for (final unit in moving)
        for (final id in members[unit]!)
          id: (x: nodes[id]!.left + dx, y: nodes[id]!.top),
    },
  );
}

Rect _withHeader(Rect card) => Rect.fromLTRB(
  card.left,
  card.top - productionCardHeaderExtent,
  card.right,
  card.bottom,
);

Rect? _firstHit(
  Map<String, Rect> units,
  Rect slot,
  bool Function(String unit) where,
) {
  final hits = [
    for (final MapEntry(key: unit, value: rect) in units.entries)
      if (where(unit) && rect.overlaps(slot)) rect,
  ];
  return hits.isEmpty
      ? null
      : hits.reduce((a, b) => a.bottom > b.bottom ? a : b);
}

/// 场次色带底部「添加分镜」入口的高度。
const double productionSceneAddHeight = 36;

/// 场次色带内最后一张卡片下方的留白：间距 + 添加入口 + 底边距。
const double productionSceneFooterExtent =
    RevericSpacing.x2l + productionSceneAddHeight + RevericSpacing.lg;

/// 场次色带在共享落点与桌面绘制中使用同一范围。
Rect productionSceneBand(Rect nodes) => Rect.fromLTRB(
  nodes.left - 28,
  nodes.top - 40 - productionCardHeaderExtent,
  nodes.right + 28,
  nodes.bottom + productionSceneFooterExtent,
);

/// 场次节点参与布局时的矩形：空场次占一张默认卡片的宽度、高度为 0，色带只剩标题和添加入口；
/// 有片段时不占面积，范围由片段决定。
Rect productionSceneAnchorRect(Offset at, {required bool empty}) =>
    at & (empty ? Size(productionCardSize(16 / 9).width, 0) : Size.zero);

/// 素材入库时记录的宽高是桌面绘制、分组转换和 Agent 落点的共同尺寸来源。
/// 布局不探测媒体文件；无有效尺寸时沿用 [productionNodeSize] 的默认卡片比例。
double? productionMediaAspect(AssetContent? content) {
  final (width, height) = switch (content) {
    ImageAssetContent(:final width, :final height) => (width, height),
    VideoAssetContent(:final width, :final height) => (width, height),
    _ => (null, null),
  };
  return width != null && height != null && width > 0 && height > 0
      ? width / height
      : null;
}

Future<ProductionNodePlacement> defaultProductionDerivedPlacement(
  ProductionCanvasService canvas,
  String sourceId,
  Size size,
) async {
  final source = await canvas.requireNode(sourceId);
  final content = await canvas.content(source.canvasId);
  final clips = {
    for (final n in content.nodes)
      if (n.clipId != null) n.id: await canvas.shots.getShot(n.clipId!),
  };
  final byId = {for (final n in content.nodes) n.id: n};
  final assets = {
    for (final n in content.nodes)
      if (n.mediaAssetId != null)
        n.id: await canvas.library.database.assetDao.getAsset(n.mediaAssetId!),
  };
  Size sizeOf(CanvasNode n) {
    final parent = byId[n.parentId];
    final layout = parent?.type == canvasNodeTypeGroup
        ? ProductionGroupLayout.fromStyle(parent!.style)
        : null;
    return productionNodeSize(
      n,
      groupCellSize: layout is StoryboardGroupLayout ? layout.cellSize : null,
      mediaType: assets[n.id]?.type,
      aspect: n.clipId != null
          ? productionAspect(clips[n.id]?.ratio)
          : productionMediaAspect(assets[n.id]?.content),
    );
  }

  final episodeId = await canvas.episodeForCanvas(source.canvasId);
  final segments = await canvas.shots.episodeShots(episodeId);
  // 已删除场次的场次节点不再占位。
  final liveScenes = episodeId.isEmpty
      ? const <String>{}
      : {
          for (final scene in await canvas.db.screenplayDao.getSceneRows(
            episodeId,
          ))
            scene.id,
        };
  final nodes = [
    for (final n in content.nodes)
      if (n.sceneId == null || liveScenes.contains(n.sceneId)) n,
  ];
  final occupied = {for (final clip in clips.values) ?clip?.sceneId};
  final positions = productionScenePositions(nodes, segments, sizeOf);
  return productionDerivedPlacement(
    sourceId: sourceId,
    size: size,
    nodes: {
      for (final n in nodes)
        n.id: n.sceneId == null
            ? (positions[n.id] ?? Offset(n.x, n.y)) & sizeOf(n)
            : productionSceneAnchorRect(
                positions[n.id] ?? Offset(n.x, n.y),
                empty: !occupied.contains(n.sceneId),
              ),
    },
    sceneOf: {
      for (final entry in clips.entries)
        if (entry.value?.sceneId != null) entry.key: entry.value!.sceneId!,
      for (final n in nodes) n.id: ?n.sceneId,
    },
    groupOf: {
      for (final n in content.nodes)
        if (n.type == canvasNodeTypeGroup)
          n.id: n.id
        else if (byId[n.parentId]?.type == canvasNodeTypeGroup)
          n.id: n.parentId!,
    },
    siblings: [
      for (final edge in content.edges)
        if (edge.type == canvasEdgeTypeDerivedOutput &&
            edge.sourceNodeId == sourceId)
          edge.targetNodeId,
    ],
  );
}

/// 音频节点只有一条波形和时长。
const productionAudioNodeSize = Size(220, 64);

/// 节点在画布上的渲染尺寸：卡片就是画面，按 [aspect]（生成节点取片段比例，素材取入库宽高）算，
/// 普通卡片不读库里的 width / height；分组外框读取持久尺寸，分镜格子使用布局尺寸。
/// 比例未知时图片按 1:1、其余按 16:9。
Size productionNodeSize(
  CanvasNode node, {
  double? aspect,
  String? mediaType,
  Size? groupCellSize,
}) {
  if (groupCellSize != null) {
    return groupCellSize;
  }
  if (node.type == canvasNodeTypeGroup) {
    return Size(node.width!, node.height!);
  }
  if (node.type == canvasNodeTypeAudio ||
      (node.type == canvasNodeTypeMedia && mediaType == 'audio')) {
    return productionAudioNodeSize;
  }
  return productionCardSize(
    (node.type == canvasNodeTypeStaging ? null : aspect) ??
        ({canvasNodeTypeImage, canvasNodeTypeText}.contains(node.type)
            ? 1.0
            : 16 / 9),
  );
}

/// 每场从场次节点的位置起按成片顺序纵向排齐；没有场次节点时取场内节点最左、最上的坐标。
/// [nodes] 里的场次节点只应包含仍存在的场次；空场次也占一列，色带只有标题和添加入口。
/// 竖排后的场次压到别的场时整场顺延到其下方，场与场的色带不叠。返回片段节点和场次节点的位置。
Map<String, Offset> productionScenePositions(
  List<CanvasNode> nodes,
  List<ProductionClipRow> segments,
  Size Function(CanvasNode node) sizeOf,
) {
  final byClip = {for (final node in nodes) node.clipId: node};
  final anchors = {for (final node in nodes) ?node.sceneId: node};
  final scenes = <String, List<CanvasNode>>{};
  for (final segment in segments) {
    final node = byClip[segment.id];
    if (segment.sceneId != null && node != null) {
      (scenes[segment.sceneId!] ??= []).add(node);
    }
  }
  for (final sceneId in anchors.keys) {
    scenes.putIfAbsent(sceneId, () => []);
  }
  const gap = RevericSpacing.x4l + productionCardHeaderExtent;
  final columns = [
    for (final MapEntry(key: sceneId, value: group) in scenes.entries)
      (
        group: group,
        anchor: anchors[sceneId],
        rect: group.isEmpty
            ? productionSceneAnchorRect(
                Offset(anchors[sceneId]!.x, anchors[sceneId]!.y),
                empty: true,
              )
            : Rect.fromLTWH(
                anchors[sceneId]?.x ??
                    group.map((node) => node.x).reduce(math.min),
                anchors[sceneId]?.y ??
                    group.map((node) => node.y).reduce(math.min),
                group.map((node) => sizeOf(node).width).reduce(math.max),
                group
                        .map((node) => sizeOf(node).height)
                        .reduce((a, b) => a + b) +
                    gap * (group.length - 1),
              ),
      ),
  ];
  columns.sort((a, b) {
    final byY = a.rect.top.compareTo(b.rect.top);
    return byY != 0 ? byY : a.rect.left.compareTo(b.rect.left);
  });
  final placed = <Rect>[];
  final positions = <String, Offset>{};
  for (final column in columns) {
    final start = productionSceneBand(column.rect);
    var band = start;
    for (
      var hit = placed.where(band.overlaps).firstOrNull;
      hit != null;
      hit = placed.where(band.overlaps).firstOrNull
    ) {
      band = band.translate(0, hit.bottom + RevericSpacing.x4l - band.top);
    }
    placed.add(band);
    final x = column.rect.left;
    var y = column.rect.top + band.top - start.top;
    if (column.anchor case final anchor?) {
      positions[anchor.id] = Offset(x, y);
    }
    for (final node in column.group) {
      positions[node.id] = Offset(x, y);
      y += sizeOf(node).height + gap;
    }
  }
  return positions;
}

// 职责: 将制作画布离屏渲染为供 AI 视觉检查布局的 JPEG 预览图。
// 关联文件:
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/production/derived_placement.dart
//   lib/shared/services/production/library_service.dart
//   lib/shared/services/ai/media/production.dart
//   lib/desktop/features/production/board.dart

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

import '../../database/app_database.dart' show AssetRow;
import '../../database/novel_content_database.dart';
import '../../logger/app_logger.dart';
import '../../models/production/media.dart';
import '../../models/screenplay.dart' show ScreenplaySceneRecord;
import '../../utils/utf16_safe_text.dart';
import 'canvas_service.dart';
import 'derived_placement.dart';

final _log = AppLogger.forModule('ProductionCanvasPreview');

const int _maxThumbnailNodes = 40;
const int _thumbnailConcurrency = 4;
const int _maxThumbnailDecodeSide = 400;
const int _minOutputLongSide = 640;
const int _maxOutputLongSide = 1600;
const double _clusterDistanceThreshold = 800;
const double _boundsPadding = 120;
const ui.Rect _emptyCanvasBounds = ui.Rect.fromLTWH(-200, -200, 1200, 800);

const ui.Color _bgColor = ui.Color(0xFF0D0F14);
const ui.Color _gridColor = ui.Color(0x14FFFFFF);
const ui.Color _gridMajorColor = ui.Color(0x28FFFFFF);
const ui.Color _gridLabelColor = ui.Color(0xFF7D8596);
const ui.Color _sceneFillColor = ui.Color(0x66192234);
const ui.Color _sceneBorderColor = ui.Color(0xFF3E4E6E);
const ui.Color _groupFillColor = ui.Color(0x4D171B26);
const ui.Color _groupBorderColor = ui.Color(0xFF566078);
const ui.Color _cardFillColor = ui.Color(0xFF171B24);
const ui.Color _headerFillColor = ui.Color(0xE611141C);
const ui.Color _outputEdgeColor = ui.Color(0xFF7AA2F7);
const ui.Color _inputEdgeColor = ui.Color(0xA694A3B8);
const ui.Color _overlapColor = ui.Color(0xFFEF4444);
const ui.Color _textPrimary = ui.Color(0xFFE6EAF2);
const ui.Color _textMuted = ui.Color(0xFF94A3B8);

/// 制作画布离屏预览图渲染结果。
class ProductionCanvasPreviewResult {
  const ProductionCanvasPreviewResult({
    required this.jpeg,
    required this.width,
    required this.height,
    required this.bounds,
  });

  final Uint8List jpeg;
  final int width;
  final int height;
  final ui.Rect bounds;
}

class _PreviewSnapshot {
  const _PreviewSnapshot({
    required this.nodes,
    required this.edges,
    required this.clips,
    required this.assets,
    required this.stagings,
    required this.editings,
    required this.cardRects,
    required this.sceneBands,
    required this.sceneTitles,
    required this.byId,
  });

  final List<CanvasNode> nodes;
  final List<ProductionConnection> edges;
  final Map<String, ProductionClipRow?> clips;
  final Map<String, AssetRow?> assets;
  final Map<String, VideoStagingRow?> stagings;
  final Map<String, VideoEditingRow?> editings;
  final Map<String, ui.Rect> cardRects;
  final Map<String, ui.Rect> sceneBands;
  final Map<String, String> sceneTitles;
  final Map<String, CanvasNode> byId;
}

class _DecodedThumbs {
  const _DecodedThumbs({
    required this.byAssetId,
    required this.missingNodes,
  });

  final Map<String, ui.Image> byAssetId;
  final Set<String> missingNodes;

  void dispose() {
    for (final image in byAssetId.values) {
      image.dispose();
    }
  }
}

/// 将指定制作画布渲染为包含节点缩略图、连线、坐标网格与重叠提示的 JPEG 预览图。
Future<ProductionCanvasPreviewResult> renderProductionCanvasPreview({
  required ProductionCanvasService canvas,
  required String canvasId,
  String scope = 'main',
  List<String>? nodeIds,
  ui.Rect? bounds,
}) async {
  final snapshot = await _loadSnapshot(canvas, canvasId);
  final rawBounds = _resolveBounds(
    snapshot,
    scope: scope,
    nodeIds: nodeIds,
    explicitBounds: bounds,
  );
  final viewBounds = bounds != null ? rawBounds : _normalizeAspect(rawBounds);
  final (pixelWidth, pixelHeight, scale) = _computeOutputDimensions(viewBounds);
  final overlappingIds = _findOverlappingNodeIds(snapshot);
  final visibleNodes = [
    for (final node in snapshot.nodes)
      if (node.sceneId == null &&
          _nodeBoundsWithHeader(node, snapshot.cardRects[node.id]!)
              .overlaps(viewBounds))
        node,
  ];
  final thumbs = await _decodeVisibleThumbnails(
    canvas: canvas,
    snapshot: snapshot,
    visibleNodes: visibleNodes,
    scale: scale,
  );

  ui.Picture? picture;
  ui.Image? rendered;
  try {
    final recorder = ui.PictureRecorder();
    final drawCanvas = ui.Canvas(
      recorder,
      ui.Rect.fromLTWH(0, 0, pixelWidth.toDouble(), pixelHeight.toDouble()),
    );
    _paintPreview(
      drawCanvas: drawCanvas,
      snapshot: snapshot,
      visibleNodes: visibleNodes,
      overlappingIds: overlappingIds,
      thumbs: thumbs,
      bounds: viewBounds,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
    );
    picture = recorder.endRecording();
    rendered = await picture.toImage(pixelWidth, pixelHeight);
    final rawRgba = await rendered.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rawRgba == null) {
      throw StateError('Failed to extract canvas preview RGBA bytes.');
    }
    final rgbaBytes = Uint8List.fromList(
      rawRgba.buffer.asUint8List(rawRgba.offsetInBytes, rawRgba.lengthInBytes),
    );
    final jpeg = await Isolate.run(
      () => _encodeJpegFromRgba(rgbaBytes, pixelWidth, pixelHeight),
    );
    return ProductionCanvasPreviewResult(
      jpeg: jpeg,
      width: pixelWidth,
      height: pixelHeight,
      bounds: viewBounds,
    );
  } finally {
    rendered?.dispose();
    picture?.dispose();
    thumbs.dispose();
  }
}

Uint8List _encodeJpegFromRgba(Uint8List rgba, int width, int height) {
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: 85));
}

Future<_PreviewSnapshot> _loadSnapshot(
  ProductionCanvasService canvas,
  String canvasId,
) async {
  final content = await canvas.content(canvasId);
  final episodeId = await canvas.episodeForCanvas(canvasId);
  final db = canvas.db;
  final segments = episodeId.isEmpty
      ? const <ProductionClipRow>[]
      : await canvas.shots.episodeShots(episodeId);
  final sceneRows = episodeId.isEmpty
      ? const <ScreenplaySceneRecord>[]
      : await db.screenplayDao.getSceneRows(episodeId);
  final liveScenes = {for (final scene in sceneRows) scene.id};
  final sceneTitles = {for (final scene in sceneRows) scene.id: scene.title};

  final clips = <String, ProductionClipRow?>{};
  final assetCache = <String, AssetRow?>{};
  final assets = <String, AssetRow?>{};
  final stagings = <String, VideoStagingRow?>{};
  final editings = <String, VideoEditingRow?>{};

  for (final node in content.nodes) {
    ProductionClipRow? clip;
    if (node.clipId != null) {
      clip = await canvas.shots.getShot(node.clipId!);
      clips[node.id] = clip;
    }
    final assetId = node.mediaAssetId ?? clip?.adoptedAssetId;
    if (assetId != null) {
      if (!assetCache.containsKey(assetId)) {
        assetCache[assetId] =
            await canvas.library.database.assetDao.getAsset(assetId);
      }
      assets[node.id] = assetCache[assetId];
    }
    if (node.stagingId != null) {
      stagings[node.id] = await db.screenplayDao.getStaging(node.stagingId!);
    }
    if (node.editingId != null) {
      editings[node.id] = await db.editingDao.get(node.editingId!);
    }
  }

  final nodes = [
    for (final node in content.nodes)
      if (node.sceneId == null || liveScenes.contains(node.sceneId)) node,
  ];
  final byId = {for (final node in nodes) node.id: node};

  ui.Size sizeOf(CanvasNode node) {
    final parent = byId[node.parentId];
    final layout = parent?.type == canvasNodeTypeGroup
        ? ProductionGroupLayout.fromStyle(parent!.style)
        : null;
    return productionNodeSize(
      node,
      groupCellSize: layout is StoryboardGroupLayout ? layout.cellSize : null,
      mediaType: assets[node.id]?.type,
      aspect: node.clipId != null
          ? productionAspect(clips[node.id]?.ratio)
          : productionMediaAspect(assets[node.id]?.content),
    );
  }

  final positions = productionScenePositions(nodes, segments, sizeOf);
  final cardRects = <String, ui.Rect>{
    for (final node in nodes)
      node.id: node.sceneId == null
          ? (positions[node.id] ?? ui.Offset(node.x, node.y)) & sizeOf(node)
          : productionSceneAnchorRect(
              positions[node.id] ?? ui.Offset(node.x, node.y),
              empty: !clips.values.any((c) => c?.sceneId == node.sceneId),
            ),
  };

  final sceneUnion = <String, ui.Rect>{};
  for (final node in nodes) {
    final sceneId = node.sceneId ?? clips[node.id]?.sceneId;
    if (sceneId == null || !liveScenes.contains(sceneId)) {
      continue;
    }
    final rect = cardRects[node.id];
    if (rect == null) {
      continue;
    }
    final current = sceneUnion[sceneId];
    sceneUnion[sceneId] = current == null ? rect : current.expandToInclude(rect);
  }
  final sceneBands = {
    for (final entry in sceneUnion.entries)
      entry.key: productionSceneBand(entry.value),
  };

  return _PreviewSnapshot(
    nodes: nodes,
    edges: content.edges,
    clips: clips,
    assets: assets,
    stagings: stagings,
    editings: editings,
    cardRects: cardRects,
    sceneBands: sceneBands,
    sceneTitles: sceneTitles,
    byId: byId,
  );
}

ui.Rect _nodeBoundsWithHeader(CanvasNode node, ui.Rect rect) {
  if (node.type == canvasNodeTypeGroup || node.sceneId != null) {
    return rect;
  }
  return ui.Rect.fromLTRB(
    rect.left,
    rect.top - productionCardHeaderExtent,
    rect.right,
    rect.bottom,
  );
}

ui.Rect _resolveBounds(
  _PreviewSnapshot snapshot, {
  required String scope,
  required List<String>? nodeIds,
  required ui.Rect? explicitBounds,
}) {
  if (explicitBounds != null) {
    return explicitBounds;
  }
  if (nodeIds != null && nodeIds.isNotEmpty) {
    ui.Rect? combined;
    for (final id in nodeIds) {
      final node = snapshot.byId[id];
      if (node == null) {
        continue;
      }
      final rect = node.sceneId != null
          ? (snapshot.sceneBands[node.sceneId] ?? snapshot.cardRects[id])
          : _nodeBoundsWithHeader(node, snapshot.cardRects[id]!);
      if (rect != null) {
        combined = combined == null ? rect : combined.expandToInclude(rect);
      }
    }
    if (combined == null) {
      throw const FormatException('No matching nodes found for node_ids.');
    }
    return combined.inflate(_boundsPadding);
  }

  final hasVisibleContent = snapshot.nodes.any((n) => n.sceneId == null) ||
      snapshot.sceneBands.isNotEmpty;
  if (!hasVisibleContent) {
    return _emptyCanvasBounds;
  }

  if (scope == 'all') {
    final all = _unionAllContent(snapshot);
    return (all ?? _emptyCanvasBounds).inflate(_boundsPadding);
  }

  // scope == 'main': cluster nearby nodes so distant outlier nodes do not
  // compress the active production area into tiny illegible pixels.
  final candidates = [
    for (final node in snapshot.nodes)
      if (node.sceneId == null && node.type != canvasNodeTypeGroup) node,
  ];
  if (candidates.isEmpty) {
    final all = _unionAllContent(snapshot);
    return (all ?? _emptyCanvasBounds).inflate(_boundsPadding);
  }

  final parent = <String, String>{for (final n in candidates) n.id: n.id};
  String find(String id) {
    var cur = id;
    while (parent[cur] != cur) {
      parent[cur] = parent[parent[cur]!]!;
      cur = parent[cur]!;
    }
    return cur;
  }

  void union(String a, String b) {
    final ra = find(a);
    final rb = find(b);
    if (ra != rb) {
      parent[rb] = ra;
    }
  }

  for (var i = 0; i < candidates.length; i += 1) {
    final a = candidates[i];
    final rectA = snapshot.cardRects[a.id]!;
    final sceneA = snapshot.clips[a.id]?.sceneId;
    for (var j = i + 1; j < candidates.length; j += 1) {
      final b = candidates[j];
      final rectB = snapshot.cardRects[b.id]!;
      final sceneB = snapshot.clips[b.id]?.sceneId;
      final sameGroup =
          a.parentId != null && a.parentId == b.parentId;
      final sameScene = sceneA != null && sceneA == sceneB;
      if (sameGroup ||
          sameScene ||
          _rectEdgeDistance(rectA, rectB) <= _clusterDistanceThreshold) {
        union(a.id, b.id);
      }
    }
  }

  final clusters = <String, List<CanvasNode>>{};
  for (final node in candidates) {
    (clusters[find(node.id)] ??= []).add(node);
  }
  final mainCluster = clusters.values.reduce((best, current) {
    if (current.length != best.length) {
      return current.length > best.length ? current : best;
    }
    final bestTime = best.fold<int>(
      0,
      (m, n) => math.max(m, n.createdAt.microsecondsSinceEpoch),
    );
    final curTime = current.fold<int>(
      0,
      (m, n) => math.max(m, n.createdAt.microsecondsSinceEpoch),
    );
    return curTime >= bestTime ? current : best;
  });

  ui.Rect? clusterRect;
  final mainParents = <String>{};
  final mainScenes = <String>{};
  for (final node in mainCluster) {
    final rect = _nodeBoundsWithHeader(node, snapshot.cardRects[node.id]!);
    clusterRect = clusterRect == null ? rect : clusterRect.expandToInclude(rect);
    if (node.parentId != null) {
      mainParents.add(node.parentId!);
    }
    final sceneId = snapshot.clips[node.id]?.sceneId;
    if (sceneId != null) {
      mainScenes.add(sceneId);
    }
  }
  for (final groupId in mainParents) {
    final groupRect = snapshot.cardRects[groupId];
    if (groupRect != null) {
      clusterRect = clusterRect!.expandToInclude(groupRect);
    }
  }
  for (final sceneId in mainScenes) {
    final band = snapshot.sceneBands[sceneId];
    if (band != null) {
      clusterRect = clusterRect!.expandToInclude(band);
    }
  }
  return (clusterRect ?? _emptyCanvasBounds).inflate(_boundsPadding);
}

ui.Rect? _unionAllContent(_PreviewSnapshot snapshot) {
  ui.Rect? combined;
  for (final node in snapshot.nodes) {
    if (node.sceneId != null) {
      continue;
    }
    final rect = _nodeBoundsWithHeader(node, snapshot.cardRects[node.id]!);
    combined = combined == null ? rect : combined.expandToInclude(rect);
  }
  for (final band in snapshot.sceneBands.values) {
    combined = combined == null ? band : combined.expandToInclude(band);
  }
  return combined;
}

double _rectEdgeDistance(ui.Rect a, ui.Rect b) {
  final dx = math.max(0.0, math.max(a.left - b.right, b.left - a.right));
  final dy = math.max(0.0, math.max(a.top - b.bottom, b.top - a.bottom));
  return math.sqrt(dx * dx + dy * dy);
}

ui.Rect _normalizeAspect(ui.Rect rect) {
  var width = math.max(rect.width, 640.0);
  var height = math.max(rect.height, 420.0);
  const maxAspect = 4.0;
  if (width / height > maxAspect) {
    height = width / maxAspect;
  } else if (height / width > maxAspect) {
    width = height / maxAspect;
  }
  return ui.Rect.fromCenter(
    center: rect.center,
    width: width,
    height: height,
  );
}

(int, int, double) _computeOutputDimensions(ui.Rect bounds) {
  final safeWidth = math.max(1.0, bounds.width);
  final safeHeight = math.max(1.0, bounds.height);
  final longWorld = math.max(safeWidth, safeHeight);
  final targetLongSide = longWorld.clamp(
    _minOutputLongSide.toDouble(),
    _maxOutputLongSide.toDouble(),
  );
  final scale = targetLongSide / longWorld;
  final pixelWidth = math.max(1, math.min(2048, (safeWidth * scale).round()));
  final pixelHeight = math.max(1, math.min(2048, (safeHeight * scale).round()));
  return (pixelWidth, pixelHeight, scale);
}

Set<String> _findOverlappingNodeIds(_PreviewSnapshot snapshot) {
  final checkNodes = [
    for (final node in snapshot.nodes)
      if (node.sceneId == null && node.type != canvasNodeTypeGroup) node,
  ];
  final hitRects = {
    for (final node in checkNodes)
      node.id: _nodeBoundsWithHeader(node, snapshot.cardRects[node.id]!)
          .deflate(1.0),
  };
  final overlapping = <String>{};
  for (var i = 0; i < checkNodes.length; i += 1) {
    final a = checkNodes[i];
    final rectA = hitRects[a.id]!;
    if (rectA.isEmpty) {
      continue;
    }
    for (var j = i + 1; j < checkNodes.length; j += 1) {
      final b = checkNodes[j];
      final rectB = hitRects[b.id]!;
      if (rectB.isEmpty) {
        continue;
      }
      if (rectA.overlaps(rectB)) {
        overlapping.add(a.id);
        overlapping.add(b.id);
      }
    }
  }
  return overlapping;
}

Future<_DecodedThumbs> _decodeVisibleThumbnails({
  required ProductionCanvasService canvas,
  required _PreviewSnapshot snapshot,
  required List<CanvasNode> visibleNodes,
  required double scale,
}) async {
  final jobs = <(String nodeId, AssetRow asset, int decodeW, int decodeH)>[];
  final missingNodes = <String>{};
  for (final node in visibleNodes) {
    final asset = snapshot.assets[node.id];
    final assetPath = asset?.path;
    if (asset == null || assetPath == null) {
      continue;
    }
    final kind = productionMediaFormat(assetPath)?.$1;
    if (kind != 'image' && kind != 'video') {
      continue;
    }
    final cardRect = snapshot.cardRects[node.id]!;
    final decodeW = (cardRect.width * scale * 1.4)
        .round()
        .clamp(64, _maxThumbnailDecodeSide);
    final decodeH = (cardRect.height * scale * 1.4)
        .round()
        .clamp(64, _maxThumbnailDecodeSide);
    jobs.add((node.id, asset, decodeW, decodeH));
  }

  if (jobs.length > _maxThumbnailNodes) {
    return _DecodedThumbs(byAssetId: const {}, missingNodes: missingNodes);
  }

  final byAssetId = <String, ui.Image>{};
  final uniqueAssets = <String, (AssetRow asset, int decodeW, int decodeH)>{};
  final assetToNodeIds = <String, List<String>>{};
  for (final (nodeId, asset, w, h) in jobs) {
    (assetToNodeIds[asset.id] ??= []).add(nodeId);
    final existing = uniqueAssets[asset.id];
    if (existing == null) {
      uniqueAssets[asset.id] = (asset, w, h);
    } else {
      uniqueAssets[asset.id] = (
        asset,
        math.max(existing.$2, w),
        math.max(existing.$3, h),
      );
    }
  }

  final entries = uniqueAssets.entries.toList();
  for (var i = 0; i < entries.length; i += _thumbnailConcurrency) {
    final batch = entries.skip(i).take(_thumbnailConcurrency);
    await Future.wait([
      for (final entry in batch)
        _decodeAssetThumb(
          canvas: canvas,
          asset: entry.value.$1,
          targetWidth: entry.value.$2,
          targetHeight: entry.value.$3,
        ).then((result) {
          if (result.image != null) {
            byAssetId[entry.key] = result.image!;
          } else if (result.missing) {
            missingNodes.addAll(assetToNodeIds[entry.key] ?? const []);
          }
        }),
    ]);
  }
  return _DecodedThumbs(byAssetId: byAssetId, missingNodes: missingNodes);
}

Future<({ui.Image? image, bool missing})> _decodeAssetThumb({
  required ProductionCanvasService canvas,
  required AssetRow asset,
  required int targetWidth,
  required int targetHeight,
}) async {
  final assetPath = asset.path;
  if (assetPath == null) {
    return (image: null, missing: false);
  }
  final kind = productionMediaFormat(assetPath)?.$1;
  File? sourceFile;
  try {
    if (kind == 'image') {
      final resolved = File(canvas.library.resolvePath(assetPath));
      if (!await resolved.exists()) {
        return (image: null, missing: true);
      }
      sourceFile = resolved;
    } else if (kind == 'video') {
      final resolved = File(canvas.library.resolvePath(assetPath));
      if (!await resolved.exists()) {
        return (image: null, missing: true);
      }
      sourceFile = await canvas.library.cachedVideoThumbnail(assetPath);
    }
  } on MediaException catch (error) {
    _log.warning('invalid asset path skipped asset=${asset.id}: $error');
    return (image: null, missing: true);
  }

  if (sourceFile == null) {
    return (image: null, missing: false);
  }

  ui.Codec? codec;
  try {
    final bytes = await sourceFile.readAsBytes();
    if (bytes.isEmpty) {
      return (image: null, missing: false);
    }
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    final frame = await codec.getNextFrame();
    return (image: frame.image, missing: false);
  } catch (error) {
    _log.warning('thumbnail decode skipped asset=${asset.id}: $error');
    return (image: null, missing: false);
  } finally {
    codec?.dispose();
  }
}

void _paintPreview({
  required ui.Canvas drawCanvas,
  required _PreviewSnapshot snapshot,
  required List<CanvasNode> visibleNodes,
  required Set<String> overlappingIds,
  required _DecodedThumbs thumbs,
  required ui.Rect bounds,
  required int pixelWidth,
  required int pixelHeight,
  required double scale,
}) {
  final bgPaint = ui.Paint()..color = _bgColor;
  drawCanvas.drawRect(
    ui.Rect.fromLTWH(0, 0, pixelWidth.toDouble(), pixelHeight.toDouble()),
    bgPaint,
  );

  drawCanvas.save();
  drawCanvas.scale(scale, scale);
  drawCanvas.translate(-bounds.left, -bounds.top);

  _paintGrid(drawCanvas, bounds, scale);
  _paintSceneBands(drawCanvas, snapshot, bounds, scale);
  _paintGroupFrames(drawCanvas, snapshot, bounds, scale);
  _paintEdges(drawCanvas, snapshot, bounds, scale);
  _paintCards(
    drawCanvas,
    snapshot,
    visibleNodes,
    overlappingIds,
    thumbs,
    scale,
  );

  drawCanvas.restore();
}

void _paintGrid(ui.Canvas drawCanvas, ui.Rect bounds, double scale) {
  final maxSpan = math.max(bounds.width, bounds.height);
  final step = maxSpan > 4800 ? 800.0 : (maxSpan > 2400 ? 400.0 : 200.0);
  final majorStep = step * 2;
  final minorPaint = ui.Paint()
    ..color = _gridColor
    ..strokeWidth = 1.0 / scale;
  final majorPaint = ui.Paint()
    ..color = _gridMajorColor
    ..strokeWidth = 1.25 / scale;

  final startX = (bounds.left / step).floor() * step;
  for (var x = startX; x <= bounds.right; x += step) {
    final major = (x % majorStep).abs() < 0.01;
    drawCanvas.drawLine(
      ui.Offset(x, bounds.top),
      ui.Offset(x, bounds.bottom),
      major ? majorPaint : minorPaint,
    );
    if (major) {
      _drawText(
        drawCanvas,
        '${x.round()}',
        offset: ui.Offset(x + 4 / scale, bounds.top + 4 / scale),
        maxWidth: 100 / scale,
        fontSize: 11 / scale,
        color: _gridLabelColor,
      );
    }
  }

  final startY = (bounds.top / step).floor() * step;
  for (var y = startY; y <= bounds.bottom; y += step) {
    final major = (y % majorStep).abs() < 0.01;
    drawCanvas.drawLine(
      ui.Offset(bounds.left, y),
      ui.Offset(bounds.right, y),
      major ? majorPaint : minorPaint,
    );
    if (major) {
      _drawText(
        drawCanvas,
        '${y.round()}',
        offset: ui.Offset(bounds.left + 4 / scale, y + 4 / scale),
        maxWidth: 100 / scale,
        fontSize: 11 / scale,
        color: _gridLabelColor,
      );
    }
  }
}

void _paintSceneBands(
  ui.Canvas drawCanvas,
  _PreviewSnapshot snapshot,
  ui.Rect bounds,
  double scale,
) {
  final fill = ui.Paint()..color = _sceneFillColor;
  final stroke = ui.Paint()
    ..color = _sceneBorderColor
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.5 / scale;
  for (final entry in snapshot.sceneBands.entries) {
    final rect = entry.value;
    if (!rect.overlaps(bounds)) {
      continue;
    }
    final rrect = ui.RRect.fromRectAndRadius(rect, const ui.Radius.circular(14));
    drawCanvas.drawRRect(rrect, fill);
    drawCanvas.drawRRect(rrect, stroke);
    final title = snapshot.sceneTitles[entry.key] ?? entry.key;
    _drawText(
      drawCanvas,
      'SCENE · $title',
      offset: ui.Offset(rect.left + 12, rect.top + 10),
      maxWidth: math.max(120, rect.width - 24),
      fontSize: (13 / scale).clamp(12.0, 26.0),
      color: _textPrimary,
      weight: ui.FontWeight.w600,
    );
  }
}

void _paintGroupFrames(
  ui.Canvas drawCanvas,
  _PreviewSnapshot snapshot,
  ui.Rect bounds,
  double scale,
) {
  final fill = ui.Paint()..color = _groupFillColor;
  final stroke = ui.Paint()
    ..color = _groupBorderColor
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.5 / scale;
  for (final node in snapshot.nodes) {
    if (node.type != canvasNodeTypeGroup) {
      continue;
    }
    final rect = snapshot.cardRects[node.id]!;
    if (!rect.overlaps(bounds)) {
      continue;
    }
    final rrect = ui.RRect.fromRectAndRadius(rect, const ui.Radius.circular(12));
    drawCanvas.drawRRect(rrect, fill);
    drawCanvas.drawRRect(rrect, stroke);
    final label = _nodeHeaderLabel(node, snapshot);
    _drawText(
      drawCanvas,
      label,
      offset: ui.Offset(rect.left + 10, rect.top - (18 / scale).clamp(16.0, 28.0)),
      maxWidth: math.max(160, rect.width),
      fontSize: (11.5 / scale).clamp(11.0, 24.0),
      color: _textMuted,
      weight: ui.FontWeight.w600,
    );
  }
}

void _paintEdges(
  ui.Canvas drawCanvas,
  _PreviewSnapshot snapshot,
  ui.Rect bounds,
  double scale,
) {
  final solidPaint = ui.Paint()
    ..color = _outputEdgeColor
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2.0 / scale;
  final dashedPaint = ui.Paint()
    ..color = _inputEdgeColor
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.6 / scale;
  final arrowFillSolid = ui.Paint()..color = _outputEdgeColor;
  final arrowFillDashed = ui.Paint()..color = _inputEdgeColor;

  for (final edge in snapshot.edges) {
    final source = snapshot.cardRects[edge.sourceNodeId];
    final target = snapshot.cardRects[edge.targetNodeId];
    if (source == null || target == null) {
      continue;
    }
    final edgeBounds = ui.Rect.fromPoints(source.center, target.center).inflate(120);
    if (!edgeBounds.overlaps(bounds)) {
      continue;
    }
    final start = ui.Offset(source.right, source.center.dy);
    final end = ui.Offset(target.left, target.center.dy);
    final dx = math.max(56.0, (end.dx - start.dx).abs() * 0.45);
    final path = ui.Path()
      ..moveTo(start.dx, start.dy)
      ..cubicTo(
        start.dx + dx,
        start.dy,
        end.dx - dx,
        end.dy,
        end.dx,
        end.dy,
      );
    final isSolid = edge.type == canvasEdgeTypeDerivedOutput ||
        edge.type == canvasEdgeTypeStagingOutput;
    if (isSolid) {
      drawCanvas.drawPath(path, solidPaint);
      _drawArrowTip(
        drawCanvas,
        ui.Offset(end.dx - dx * 0.15, end.dy),
        end,
        6.5 / scale,
        arrowFillSolid,
      );
    } else {
      _drawDashedPath(drawCanvas, path, dashedPaint, 9 / scale, 6 / scale);
      _drawArrowTip(
        drawCanvas,
        ui.Offset(end.dx - dx * 0.15, end.dy),
        end,
        5.5 / scale,
        arrowFillDashed,
      );
    }
  }
}

void _drawDashedPath(
  ui.Canvas drawCanvas,
  ui.Path path,
  ui.Paint paint,
  double dash,
  double gap,
) {
  for (final metric in path.computeMetrics()) {
    var distance = 0.0;
    while (distance < metric.length) {
      final next = math.min(metric.length, distance + dash);
      drawCanvas.drawPath(metric.extractPath(distance, next), paint);
      distance += dash + gap;
    }
  }
}

void _drawArrowTip(
  ui.Canvas drawCanvas,
  ui.Offset from,
  ui.Offset tip,
  double size,
  ui.Paint paint,
) {
  final angle = math.atan2(tip.dy - from.dy, tip.dx - from.dx);
  final p1 = ui.Offset(
    tip.dx - size * 1.4 * math.cos(angle - 0.45),
    tip.dy - size * 1.4 * math.sin(angle - 0.45),
  );
  final p2 = ui.Offset(
    tip.dx - size * 1.4 * math.cos(angle + 0.45),
    tip.dy - size * 1.4 * math.sin(angle + 0.45),
  );
  final arrow = ui.Path()
    ..moveTo(tip.dx, tip.dy)
    ..lineTo(p1.dx, p1.dy)
    ..lineTo(p2.dx, p2.dy)
    ..close();
  drawCanvas.drawPath(arrow, paint);
}

void _paintCards(
  ui.Canvas drawCanvas,
  _PreviewSnapshot snapshot,
  List<CanvasNode> visibleNodes,
  Set<String> overlappingIds,
  _DecodedThumbs thumbs,
  double scale,
) {
  for (final node in visibleNodes) {
    if (node.type == canvasNodeTypeGroup || node.sceneId != null) {
      continue;
    }
    final rect = snapshot.cardRects[node.id]!;
    final accent = _accentForNode(node, snapshot.assets[node.id]);
    final rrect = ui.RRect.fromRectAndRadius(rect, const ui.Radius.circular(10));

    drawCanvas.drawRRect(rrect, ui.Paint()..color = _cardFillColor);

    final asset = snapshot.assets[node.id];
    final image = asset == null ? null : thumbs.byAssetId[asset.id];
    if (image != null) {
      drawCanvas.save();
      drawCanvas.clipRRect(rrect);
      _drawCoverImage(drawCanvas, image, rect);
      drawCanvas.restore();
    } else {
      _paintCardPlaceholder(
        drawCanvas,
        node,
        snapshot,
        rect,
        accent,
        scale,
        missing: thumbs.missingNodes.contains(node.id),
      );
    }

    final isOverlap = overlappingIds.contains(node.id);
    drawCanvas.drawRRect(
      rrect,
      ui.Paint()
        ..color = isOverlap ? _overlapColor : accent.withValues(alpha: 0.72)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = (isOverlap ? 3.0 : 1.5) / scale,
    );

    _paintCardHeader(
      drawCanvas,
      node,
      snapshot,
      rect,
      accent,
      scale,
      isOverlap: isOverlap,
    );
  }
}

void _drawCoverImage(ui.Canvas drawCanvas, ui.Image image, ui.Rect dst) {
  final srcW = image.width.toDouble();
  final srcH = image.height.toDouble();
  if (srcW <= 0 || srcH <= 0 || dst.width <= 0 || dst.height <= 0) {
    return;
  }
  final srcAspect = srcW / srcH;
  final dstAspect = dst.width / dst.height;
  ui.Rect src;
  if (srcAspect > dstAspect) {
    final cropW = srcH * dstAspect;
    src = ui.Rect.fromLTWH((srcW - cropW) * 0.5, 0, cropW, srcH);
  } else {
    final cropH = srcW / dstAspect;
    src = ui.Rect.fromLTWH(0, (srcH - cropH) * 0.5, srcW, cropH);
  }
  drawCanvas.drawImageRect(
    image,
    src,
    dst,
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
}

void _paintCardPlaceholder(
  ui.Canvas drawCanvas,
  CanvasNode node,
  _PreviewSnapshot snapshot,
  ui.Rect rect,
  ui.Color accent,
  double scale, {
  required bool missing,
}) {
  final inner = rect.deflate(12);
  if (inner.width <= 12 || inner.height <= 12) {
    return;
  }
  final bodyFont = (11.5 / scale).clamp(10.0, 22.0);
  if (missing) {
    _drawText(
      drawCanvas,
      'MISSING MEDIA',
      offset: ui.Offset(inner.left, rect.center.dy - bodyFont * 0.6),
      maxWidth: inner.width,
      fontSize: bodyFont,
      color: _overlapColor,
      weight: ui.FontWeight.w700,
    );
    return;
  }
  if (node.type == canvasNodeTypeText) {
    final raw = node.content.trim();
    final excerpt = raw.isEmpty
        ? '(empty text)'
        : truncateUtf16Safe(raw.replaceAll('\n', ' '), 120);
    _drawText(
      drawCanvas,
      excerpt,
      offset: inner.topLeft,
      maxWidth: inner.width,
      fontSize: bodyFont,
      color: _textPrimary.withValues(alpha: 0.88),
      maxLines: 5,
    );
    return;
  }
  if (node.type == canvasNodeTypeAudio ||
      (node.type == canvasNodeTypeMedia &&
          snapshot.assets[node.id]?.type == 'audio')) {
    final barPaint = ui.Paint()..color = accent.withValues(alpha: 0.65);
    const barCount = 12;
    final step = inner.width / barCount;
    for (var i = 0; i < barCount; i += 1) {
      final ratio = 0.25 + 0.65 * ((i * 7 + 3) % 5) / 4.0;
      final barH = inner.height * 0.7 * ratio;
      drawCanvas.drawRRect(
        ui.RRect.fromRectAndRadius(
          ui.Rect.fromCenter(
            center: ui.Offset(inner.left + step * (i + 0.5), rect.center.dy),
            width: math.max(2.0, step * 0.45),
            height: barH,
          ),
          const ui.Radius.circular(2),
        ),
        barPaint,
      );
    }
    return;
  }

  final badge = switch (node.type) {
    canvasNodeTypeEditing => 'EDIT TIMELINE',
    canvasNodeTypeStaging => 'STAGING',
    canvasNodeTypeVideo => 'VIDEO',
    canvasNodeTypeImage => 'IMAGE',
    _ => node.type.toUpperCase(),
  };
  _drawText(
    drawCanvas,
    badge,
    offset: ui.Offset(inner.left, inner.top),
    maxWidth: inner.width,
    fontSize: bodyFont,
    color: accent,
    weight: ui.FontWeight.w700,
  );
  final subtitle = snapshot.stagings[node.id]?.title ??
      snapshot.editings[node.id]?.title ??
      snapshot.clips[node.id]?.title ??
      node.title;
  if (subtitle.trim().isNotEmpty) {
    _drawText(
      drawCanvas,
      truncateUtf16Safe(subtitle.trim(), 48),
      offset: ui.Offset(inner.left, inner.top + bodyFont * 1.5),
      maxWidth: inner.width,
      fontSize: bodyFont * 0.9,
      color: _textMuted,
      maxLines: 2,
    );
  }
}

void _paintCardHeader(
  ui.Canvas drawCanvas,
  CanvasNode node,
  _PreviewSnapshot snapshot,
  ui.Rect rect,
  ui.Color accent,
  double scale, {
  required bool isOverlap,
}) {
  final fontSize = (11.0 / scale).clamp(10.5, 24.0);
  final pillHeight = fontSize * 1.45;
  final top = rect.top - pillHeight - 4 / scale;
  final label = _nodeHeaderLabel(node, snapshot);
  final pillRect = ui.Rect.fromLTWH(
    rect.left,
    top,
    math.max(rect.width, 160 / scale),
    pillHeight,
  );
  final pillRRect = ui.RRect.fromRectAndRadius(
    pillRect,
    ui.Radius.circular(4 / scale),
  );
  drawCanvas.drawRRect(pillRRect, ui.Paint()..color = _headerFillColor);
  drawCanvas.drawRRect(
    pillRRect,
    ui.Paint()
      ..color = isOverlap ? _overlapColor : accent.withValues(alpha: 0.65)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1.0 / scale,
  );
  _drawText(
    drawCanvas,
    label,
    offset: ui.Offset(pillRect.left + 5 / scale, pillRect.top + 2 / scale),
    maxWidth: math.max(20, pillRect.width - 10 / scale),
    fontSize: fontSize,
    color: isOverlap ? _overlapColor : _textPrimary,
    weight: ui.FontWeight.w600,
    maxLines: 1,
  );
}

String _nodeHeaderLabel(CanvasNode node, _PreviewSnapshot snapshot) {
  final kind = switch (node.type) {
    canvasNodeTypeText => 'TXT',
    canvasNodeTypeImage => 'IMG',
    canvasNodeTypeVideo => 'VID',
    canvasNodeTypeAudio => 'AUD',
    canvasNodeTypeEditing => 'EDIT',
    canvasNodeTypeStaging => 'STG',
    canvasNodeTypeGroup => 'GRP',
    canvasNodeTypeMedia => switch (snapshot.assets[node.id]?.type) {
      'image' => 'IMG',
      'video' => 'VID',
      'audio' => 'AUD',
      _ => 'MED',
    },
    _ => node.type.toUpperCase(),
  };
  final rawTitle = (snapshot.editings[node.id]?.title ??
          snapshot.stagings[node.id]?.title ??
          snapshot.clips[node.id]?.title ??
          node.title)
      .trim()
      .replaceAll('\n', ' ');
  if (rawTitle.isEmpty) {
    return '[$kind] ${node.id}';
  }
  return '[$kind] ${node.id} · ${truncateUtf16Safe(rawTitle, 22)}';
}

ui.Color _accentForNode(CanvasNode node, AssetRow? asset) => switch (node.type) {
  canvasNodeTypeText => const ui.Color(0xFFF59E0B),
  canvasNodeTypeImage => const ui.Color(0xFF10B981),
  canvasNodeTypeVideo => const ui.Color(0xFF3B82F6),
  canvasNodeTypeAudio => const ui.Color(0xFFA855F7),
  canvasNodeTypeEditing => const ui.Color(0xFFEC4899),
  canvasNodeTypeStaging => const ui.Color(0xFF6366F1),
  canvasNodeTypeMedia => switch (asset?.type) {
    'image' => const ui.Color(0xFF06B6D4),
    'video' => const ui.Color(0xFF38BDF8),
    'audio' => const ui.Color(0xFFA855F7),
    _ => const ui.Color(0xFF64748B),
  },
  _ => const ui.Color(0xFF64748B),
};

void _drawText(
  ui.Canvas drawCanvas,
  String text, {
  required ui.Offset offset,
  required double maxWidth,
  required double fontSize,
  required ui.Color color,
  ui.FontWeight weight = ui.FontWeight.w400,
  int maxLines = 1,
}) {
  final builder = ui.ParagraphBuilder(
    ui.ParagraphStyle(
      fontSize: fontSize,
      fontWeight: weight,
      maxLines: maxLines,
      ellipsis: '…',
    ),
  )
    ..pushStyle(
      ui.TextStyle(
        color: color,
        fontSize: fontSize,
        fontWeight: weight,
      ),
    )
    ..addText(_sanitizeUtf16(text));
  final paragraph = builder.build();
  try {
    paragraph.layout(ui.ParagraphConstraints(width: math.max(10.0, maxWidth)));
    drawCanvas.drawParagraph(paragraph, offset);
  } finally {
    paragraph.dispose();
  }
}

String _sanitizeUtf16(String text) {
  final units = text.codeUnits;
  StringBuffer? buffer;
  for (var i = 0; i < units.length; i += 1) {
    final unit = units[i];
    final isHigh = unit >= 0xD800 && unit <= 0xDBFF;
    final isLow = unit >= 0xDC00 && unit <= 0xDFFF;
    if (!isHigh && !isLow) {
      buffer?.writeCharCode(unit);
      continue;
    }
    if (isHigh && i + 1 < units.length) {
      final next = units[i + 1];
      if (next >= 0xDC00 && next <= 0xDFFF) {
        buffer?.writeCharCode(unit);
        buffer?.writeCharCode(next);
        i += 1;
        continue;
      }
    }
    buffer ??= StringBuffer()..write(text.substring(0, i));
    buffer.write('\uFFFD');
  }
  return buffer?.toString() ?? text;
}

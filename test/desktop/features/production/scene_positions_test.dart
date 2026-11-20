// 职责: 验证制作画布按场竖排片段时，场与场的色带不会互相压住。
// 关联文件:
//   lib/desktop/features/production/board.dart
//   lib/desktop/features/production/node_card.dart
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/production/board.dart';
import 'package:reveric/desktop/features/production/node_card.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/production/derived_placement.dart'
    show productionSceneAnchorRect, productionSceneFooterExtent;

void main() {
  final at = DateTime(2026);
  const size = Size(260, 146);

  CanvasNode node(String clipId, double x, double y) => CanvasNode(
    id: 'node_$clipId',
    canvasId: 'canvas',
    type: canvasNodeTypeVideo,
    refType: canvasNodeRefTypeProductionClip,
    refId: clipId,
    title: clipId,
    content: '',
    x: x,
    y: y,
    zIndex: 0,
    sortOrder: 0,
    createdAt: at,
    updatedAt: at,
    deletedAt: at,
  );

  ProductionClipRow clip(String id, String sceneId) => ProductionClipRow(
    inputs: const [],
    id: id,
    episodeId: 'episode',
    kind: canvasNodeTypeVideo,
    sceneId: sceneId,
    title: id,
    prompt: '',
    errorDismissed: false,
    referenceMode: '',
    ratio: '16:9',
    resolution: '',
    createdAt: at,
    updatedAt: at,
    deletedAt: at,
  );

  test('long scene pushes the scene below it down instead of overlapping', () {
    // 库里按「每场一行」存：第 1 场 5 段横排，第 2 场在下方 620 处。
    final nodes = [
      for (var i = 0; i < 5; i++) node('a$i', 700 + i * 340.0, 0),
      for (var i = 0; i < 2; i++) node('b$i', 700 + i * 340.0, 620),
    ];
    final segments = [
      for (var i = 0; i < 5; i++) clip('a$i', 'scene_a'),
      for (var i = 0; i < 2; i++) clip('b$i', 'scene_b'),
    ];

    final positions = productionScenePositions(nodes, segments, (_) => size);

    const step = 146 + 24 + productionNodeHeaderExtent;
    for (var i = 0; i < 5; i++) {
      expect(positions['node_a$i'], Offset(700, i * step));
    }
    final lastA = positions['node_a4']!.dy + size.height;
    final firstB = positions['node_b0']!;
    expect(firstB.dx, 700);
    // 上一场色带底边 + 间距 + 下一场色带顶部留白。
    expect(
      firstB.dy,
      lastA +
          productionSceneFooterExtent +
          24 +
          40 +
          productionNodeHeaderExtent,
    );
    expect(positions['node_b1'], Offset(700, firstB.dy + step));
  });

  test('scenes that do not overlap keep their stored corner', () {
    final nodes = [node('a0', 0, 0), node('b0', 600, 0)];
    final segments = [clip('a0', 'scene_a'), clip('b0', 'scene_b')];

    final positions = productionScenePositions(nodes, segments, (_) => size);

    expect(positions['node_a0'], Offset.zero);
    expect(positions['node_b0'], const Offset(600, 0));
  });

  CanvasNode sceneNode(String sceneId, double x, double y) => CanvasNode(
    id: 'scene_node_$sceneId',
    canvasId: 'canvas',
    type: canvasNodeTypeScene,
    refType: canvasNodeRefTypeScreenplayScene,
    refId: sceneId,
    title: '',
    content: '',
    x: x,
    y: y,
    zIndex: 0,
    sortOrder: 0,
    createdAt: at,
    updatedAt: at,
    deletedAt: at,
  );

  test('scene node is the origin of its column', () {
    // 片段库里的坐标是旧的，场次节点已移到 (500, 300)。
    final nodes = [
      node('a0', 0, 0),
      node('a1', 0, 400),
      sceneNode('scene_a', 500, 300),
    ];
    final segments = [clip('a0', 'scene_a'), clip('a1', 'scene_a')];

    final positions = productionScenePositions(nodes, segments, (_) => size);

    const step = 146 + 24 + productionNodeHeaderExtent;
    expect(positions['scene_node_scene_a'], const Offset(500, 300));
    expect(positions['node_a0'], const Offset(500, 300));
    expect(positions['node_a1'], const Offset(500, 300 + step));
  });

  test(
    'empty scene keeps a column and is pushed below an overlapping scene',
    () {
      final nodes = [
        node('a0', 0, 0),
        sceneNode('scene_a', 0, 0),
        sceneNode('scene_b', 0, 100),
      ];
      final segments = [clip('a0', 'scene_a')];

      final positions = productionScenePositions(nodes, segments, (_) => size);

      final bandA = productionSceneBand(const Offset(0, 0) & size);
      final empty = positions['scene_node_scene_b']!;
      expect(empty.dx, 0);
      expect(
        productionSceneBand(productionSceneAnchorRect(empty, empty: true)).top,
        bandA.bottom + 24,
      );
    },
  );
}

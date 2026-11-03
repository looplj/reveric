// 职责: 从真实 AI 资源树发现所有可读身份，要求每个身份注册短 ID 类型。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/utils/short_entity_id.dart
import 'package:reveric/shared/app_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/utils/short_entity_id.dart';

void main() {
  test('every readable resource identity has a registered business prefix', () {
    const registrations = <String, Set<ShortEntityIdType>>{
      'chapters.id': {ShortEntityIdType.chapter, ShortEntityIdType.extra},
      'volumes.id': {ShortEntityIdType.volume},
      'characters.id': {ShortEntityIdType.character},
      'chapters.relations[].id': {ShortEntityIdType.relation},
      'foreshadowing.id': {ShortEntityIdType.foreshadowing},
      'locations.id': {ShortEntityIdType.location},
      'skills.id': {ShortEntityIdType.skill},
      'items.id': {ShortEntityIdType.item},
      'factions.id': {ShortEntityIdType.faction},
      'creatures.id': {ShortEntityIdType.creature},
      'relations.id': {ShortEntityIdType.relation},
      'relations/change_logs.id': {ShortEntityIdType.relationChange},
      'lore.id': {ShortEntityIdType.loreDocument, ShortEntityIdType.loreFolder},
      'materials.id': {
        ShortEntityIdType.materialsDocument,
        ShortEntityIdType.materialsFolder,
      },
      'outlines.id': {ShortEntityIdType.outline},
      'outlines.beats[].id': {ShortEntityIdType.outlineBeat},
      'outlines/beats.id': {ShortEntityIdType.outlineBeat},
      if (ideationCanvasEnabled) 'canvas.id': {ShortEntityIdType.canvas},
      if (ideationCanvasEnabled)
        'canvas/nodes.id': {ShortEntityIdType.canvasNode},
      if (ideationCanvasEnabled)
        'canvas/edges.id': {ShortEntityIdType.canvasEdge},
      'works.entries[].id': {
        ShortEntityIdType.novel,
        ShortEntityIdType.screenplay,
      },
      'screenplay.id': {ShortEntityIdType.screenplay},
      'seasons.id': {ShortEntityIdType.screenplaySeason},
      'episodes.id': {ShortEntityIdType.screenplayEpisode},
      'episodes/production.id': {ShortEntityIdType.screenplayEpisode},
      'episodes/production/canvas.id': {ShortEntityIdType.canvas},
      'episodes/production/canvas/nodes.id': {ShortEntityIdType.canvasNode},
      'episodes/production/canvas/edges.id': {ShortEntityIdType.canvasEdge},
      'clips.id': {ShortEntityIdType.productionClip},
      'clips.inputs[].id': {ShortEntityIdType.productionInput},
      'clips/generations.id': {ShortEntityIdType.generationTask},
      'scenes.id': {ShortEntityIdType.screenplayScene},
      'scenes/elements.id': {ShortEntityIdType.screenplayElement},
    };
    final actualPaths = readableResourceIdPathsForTesting();
    expect(actualPaths, unorderedEquals(registrations.keys));
    expect(
      registrations.values.expand((types) => types).toSet(),
      unorderedEquals(
        ShortEntityIdType.values.where(
          (type) => type != ShortEntityIdType.screenplayBeat,
        ),
      ),
    );
    for (final type in registrations.values.expand((types) => types)) {
      expect(shortEntityIdPrefixes[type], matches(r'^[a-z]+$'));
    }
  });
}

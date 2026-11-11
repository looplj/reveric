// 职责: 验证作品业务实体短 ID 的完整前缀契约、格式与可控随机序列。
// 关联文件:
//   lib/shared/utils/short_entity_id.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/utils/short_entity_id.dart';

void main() {
  test('prefix registry covers every entity once with unique prefixes', () {
    expect(
      shortEntityIdPrefixes.keys.toSet(),
      ShortEntityIdType.values.toSet(),
    );
    expect(
      shortEntityIdPrefixes.values.toSet(),
      hasLength(shortEntityIdPrefixes.length),
    );
    expect(shortEntityIdPrefixes, {
      ShortEntityIdType.character: 'cha',
      ShortEntityIdType.chapter: 'chp',
      ShortEntityIdType.extra: 'ext',
      ShortEntityIdType.volume: 'vol',
      ShortEntityIdType.foreshadowing: 'fsh',
      ShortEntityIdType.location: 'loc',
      ShortEntityIdType.skill: 'ski',
      ShortEntityIdType.item: 'itm',
      ShortEntityIdType.faction: 'fac',
      ShortEntityIdType.creature: 'cre',
      ShortEntityIdType.relation: 'rel',
      ShortEntityIdType.relationChange: 'rch',
      ShortEntityIdType.loreDocument: 'lrd',
      ShortEntityIdType.loreFolder: 'lrf',
      ShortEntityIdType.materialsDocument: 'mtd',
      ShortEntityIdType.materialsFolder: 'mtf',
      ShortEntityIdType.outline: 'out',
      ShortEntityIdType.outlineBeat: 'obt',
      ShortEntityIdType.canvas: 'can',
      ShortEntityIdType.canvasNode: 'cnd',
      ShortEntityIdType.canvasEdge: 'ced',
      ShortEntityIdType.novel: 'nov',
      ShortEntityIdType.screenplay: 'scr',
      ShortEntityIdType.canvas_work: 'cnv',
      ShortEntityIdType.screenplaySeason: 'sea',
      ShortEntityIdType.screenplayEpisode: 'epi',
      ShortEntityIdType.screenplayBeat: 'sbt',
      ShortEntityIdType.screenplayScene: 'scn',
      ShortEntityIdType.screenplayElement: 'elm',
      ShortEntityIdType.productionClip: 'clip',
      ShortEntityIdType.productionInput: 'inp',
      ShortEntityIdType.generationTask: 'gen',
    });
  });

  test(
    'controlled source covers letters, digits, and a numeric first suffix',
    () {
      final indexes = [26, 0, 25, 35, 27, 34];
      var cursor = 0;

      final id = buildShortEntityId(
        ShortEntityIdType.character,
        nextInt: (upperBound) {
          expect(upperBound, 36);
          return indexes[cursor++];
        },
      );

      expect(id, 'cha_0AZ918');
      expect(id, matches(RegExp(r'^[a-z]{3}_[A-Z0-9]{6}$')));
      expect(id, hasLength(10));
    },
  );

  test('rejects an invalid controlled random index', () {
    expect(
      () => buildShortEntityId(ShortEntityIdType.chapter, nextInt: (_) => 36),
      throwsRangeError,
    );
  });
}

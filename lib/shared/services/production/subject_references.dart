// 职责: 在共享实体删除入口保护仍被图片片段绑定的人物、地点与图鉴条目。
// 关联文件:
//   lib/shared/services/novel_content.dart
//   lib/shared/services/maps_service.dart
//   lib/shared/database/novel_content_database.dart
import 'package:drift/drift.dart';
import '../../database/novel_content_database.dart';
import '../../models/screenplay.dart';

Future<void> requireUnusedProductionSubject(
  NovelContentDatabase db, {
  String? characterId,
  String? locationId,
  String? itemId,
}) async {
  if ([characterId, locationId, itemId].nonNulls.length != 1) {
    throw ArgumentError('Exactly one subject is required');
  }
  final clips = db.productionClips;
  final episodes = db.screenplayEpisodes;
  final seasons = db.screenplaySeasons;
  final roots = db.screenplays;
  final query =
      db.select(clips).join([
        leftOuterJoin(episodes, episodes.id.equalsExp(clips.episodeId)),
        leftOuterJoin(seasons, seasons.id.equalsExp(episodes.seasonId)),
        leftOuterJoin(
          roots,
          roots.id.equalsExp(episodes.screenplayId) &
              roots.id.equalsExp(seasons.screenplayId),
        ),
      ])..where(
        clips.deletedAt.equals(notDeletedSentinel) &
            (clips.episodeId.equals('') |
                (episodes.deletedAt.equals(notDeletedSentinel) &
                    seasons.deletedAt.equals(notDeletedSentinel) &
                    roots.deletedAt.equals(notDeletedSentinel))) &
            (characterId != null
                ? clips.characterId.equals(characterId)
                : locationId != null
                ? clips.locationId.equals(locationId)
                : clips.itemId.equals(itemId!)),
      );
  final references = (await query.get())
      .map((row) => row.readTable(clips))
      .toList();
  if (references.isNotEmpty) {
    throw ScreenplayServiceException(
      'entity_in_use',
      'The subject is still referenced by production image clips.',
      details: references.map((clip) => clip.id).toList(),
    );
  }
}

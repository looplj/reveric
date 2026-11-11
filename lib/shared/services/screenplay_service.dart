// 职责: 剧本结构与正文的业务校验、事务、连续编号、软删除和统计同步。
// 关联文件:
//   lib/shared/database/novel_content_database.dart
//   lib/shared/database/novel_content_daos/screenplay_dao.dart
//   lib/shared/models/screenplay.dart
//   lib/shared/models/screenplay_element.dart
//   lib/shared/services/screenplay_metrics.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/error-handling.md
//   .agents/rules/db-query-aggregation.md

import 'dart:convert';
import 'package:drift/drift.dart';

import '../database/novel_content_database.dart';
import '../logger/app_logger.dart';
import '../models/screenplay.dart';
import '../models/production/style.dart';
import '../models/screenplay_element.dart';
import '../models/screenplay_document.dart';
import 'package:collection/collection.dart';
import '../utils/random_id.dart';
import '../utils/short_entity_id.dart';
import '../utils/short_entity_id_allocator.dart';
import 'entity_relations_service.dart';
import 'novel_actions.dart';
import 'screenplay_metrics.dart';
import 'production/editing_orchestrator.dart';

final _log = AppLogger.forModule('ScreenplayService');

class ScreenplayElementWriteResult {
  const ScreenplayElementWriteResult({
    required this.elements,
    required this.metrics,
    required this.warnings,
  });

  final List<ScreenplayElement> elements;
  final ScreenplayMetrics metrics;
  final List<ScreenplayElementWarning> warnings;
}

class ScreenplayService {
  ScreenplayService(
    this._database, {
    this.novelActionsService,
    this.novelId,
    this._idBuilder = buildShortEntityId,
  });

  final NovelContentDatabase _database;
  late final EntityRelationsService _relations = EntityRelationsService(
    _database,
  );
  final NovelActionsService? novelActionsService;
  final String? novelId;
  final ShortEntityIdBuilder _idBuilder;

  Future<String> _insertNew(
    ShortEntityIdType type,
    String table,
    Future<void> Function(String id) insert, {
    String? candidate,
    Set<String>? reservedIds,
  }) {
    var first = true;
    return insertWithShortEntityId(
      type: type,
      tableName: table,
      reservedIds: reservedIds,
      buildId: (type) {
        if (first && candidate != null) {
          first = false;
          return candidate;
        }
        first = false;
        return _idBuilder(type);
      },
      idExists: (id) async =>
          (await _database
                  .customSelect(
                    'SELECT 1 FROM $table WHERE id = ? LIMIT 1',
                    variables: [Variable.withString(id)],
                  )
                  .get())
              .isNotEmpty,
      insert: insert,
    );
  }

  /// 画布作品只初始化制作默认设置和一张画布，不生成隐藏的季、集或场次。
  Future<void> createCanvasStructure({
    ProductionStylePreset? style,
  }) => _write('screenplays,canvases', 'CREATE_CANVAS_WORK', 'new', () async {
    await _database.transaction(() async {
      if (await _database.screenplayDao.getRoot() != null) {
        throw const ScreenplayServiceException(
          'screenplay_already_exists',
          'This content database already has production settings.',
        );
      }
      await _insertNew(ShortEntityIdType.screenplay, 'screenplays', (id) async {
        await _database
            .into(_database.screenplays)
            .insert(
              ScreenplaysCompanion.insert(
                id: id,
                styleId: Value(
                  style == null ? null : PresetProductionStyle(style.id).stored,
                ),
              ),
            );
      });
      await _insertNew(ShortEntityIdType.canvas, 'canvases', (id) async {
        await _database
            .into(_database.canvases)
            .insert(
              CanvasesCompanion.insert(
                id: id,
                name: 'production',
                kind: const Value(canvasKindProduction),
              ),
            );
      });
    });
  });

  Future<CreatedSeason> createInitialStructure({
    int? plannedEpisodeCount,
    ProductionStylePreset? style,
  }) {
    _validatePlannedEpisodeCount(plannedEpisodeCount);
    return _write('screenplays', 'CREATE_INITIAL', 'new', () async {
      return _database.transaction(() async {
        if (await _database.screenplayDao.getRoot() != null) {
          throw const ScreenplayServiceException(
            'screenplay_already_exists',
            'This content database already has a screenplay.',
          );
        }
        final now = DateTime.now();
        final screenplayId = await _insertNew(
          ShortEntityIdType.screenplay,
          'screenplays',
          (screenplayId) async => _database
              .into(_database.screenplays)
              .insert(
                ScreenplaysCompanion.insert(
                  id: screenplayId,
                  styleId: Value(
                    style == null
                        ? null
                        : PresetProductionStyle(style.id).stored,
                  ),
                  createdAt: Value(now),
                  updatedAt: Value(now),
                ),
              ),
        );
        final seasonId = await _insertNew(
          ShortEntityIdType.screenplaySeason,
          'screenplay_seasons',
          (seasonId) async => _database
              .into(_database.screenplaySeasons)
              .insert(
                ScreenplaySeasonsCompanion.insert(
                  id: seasonId,
                  screenplayId: screenplayId,
                  seasonNumber: 1,
                  plannedEpisodeCount: Value(plannedEpisodeCount),
                  createdAt: Value(now),
                  updatedAt: Value(now),
                ),
              ),
        );
        final episodeId = await _insertNew(
          ShortEntityIdType.screenplayEpisode,
          'screenplay_episodes',
          (episodeId) async => _database
              .into(_database.screenplayEpisodes)
              .insert(
                ScreenplayEpisodesCompanion.insert(
                  id: episodeId,
                  screenplayId: screenplayId,
                  seasonId: seasonId,
                  episodeNumber: 1,
                  createdAt: Value(now),
                  updatedAt: Value(now),
                ),
              ),
        );
        await EpisodeEditingOrchestrator().ensureEpisodeEditing(
          _database,
          episodeId,
        );
        return CreatedSeason(seasonId: seasonId, episodeId: episodeId);
      });
    });
  }

  Future<CreatedSeason> createSeason({
    required String screenplayId,
    String title = '',
    int? plannedEpisodeCount,
  }) {
    _validatePlannedEpisodeCount(plannedEpisodeCount);
    return _write('screenplay_seasons', 'INSERT', screenplayId, () async {
      return _database.transaction(() async {
        await _requireScreenplay(screenplayId);
        final seasonNumber =
            await _maxInt(
              table: 'screenplay_seasons',
              column: 'season_number',
              where: 'screenplay_id = ? AND deleted_at = 0',
              variables: [Variable.withString(screenplayId)],
            ) +
            1;
        final now = DateTime.now();
        final seasonId = await _insertNew(
          ShortEntityIdType.screenplaySeason,
          'screenplay_seasons',
          (seasonId) async => _database
              .into(_database.screenplaySeasons)
              .insert(
                ScreenplaySeasonsCompanion.insert(
                  id: seasonId,
                  screenplayId: screenplayId,
                  seasonNumber: seasonNumber,
                  title: Value(title.trim()),
                  plannedEpisodeCount: Value(plannedEpisodeCount),
                  createdAt: Value(now),
                  updatedAt: Value(now),
                ),
              ),
        );
        final episodeId = await _insertNew(
          ShortEntityIdType.screenplayEpisode,
          'screenplay_episodes',
          (episodeId) async => _database
              .into(_database.screenplayEpisodes)
              .insert(
                ScreenplayEpisodesCompanion.insert(
                  id: episodeId,
                  screenplayId: screenplayId,
                  seasonId: seasonId,
                  episodeNumber: 1,
                  createdAt: Value(now),
                  updatedAt: Value(now),
                ),
              ),
        );
        await EpisodeEditingOrchestrator().ensureEpisodeEditing(
          _database,
          episodeId,
        );
        return CreatedSeason(seasonId: seasonId, episodeId: episodeId);
      });
    });
  }

  Future<void> updateSeason({
    required String seasonId,
    String? title,
    Value<int?> plannedEpisodeCount = const Value.absent(),
  }) {
    if (plannedEpisodeCount.present) {
      _validatePlannedEpisodeCount(plannedEpisodeCount.value);
    }
    return _write('screenplay_seasons', 'UPDATE', seasonId, () async {
      await _requireSeason(seasonId);
      await (_database.update(
        _database.screenplaySeasons,
      )..where((table) => table.id.equals(seasonId))).write(
        ScreenplaySeasonsCompanion(
          title: title == null ? const Value.absent() : Value(title.trim()),
          plannedEpisodeCount: plannedEpisodeCount,
          updatedAt: Value(DateTime.now()),
        ),
      );
    });
  }

  Future<void> moveSeason(String seasonId, int seasonNumber) {
    return _write('screenplay_seasons', 'REORDER', seasonId, () async {
      await _database.transaction(() async {
        final season = await _requireSeason(seasonId);
        final seasons = await _database.screenplayDao.getSeasons(
          season.screenplayId,
        );
        if (seasonNumber < 1 || seasonNumber > seasons.length) {
          throw const ScreenplayServiceException(
            'invalid_season_number',
            'Season number is outside the valid range.',
          );
        }
        final ordered = [...seasons]..removeWhere((row) => row.id == seasonId);
        ordered.insert(seasonNumber - 1, season);
        await _renumberSeasons(ordered);
      });
    });
  }

  Future<void> deleteSeason(String seasonId) {
    return _write('screenplay_seasons', 'SOFT_DELETE', seasonId, () async {
      await _database.transaction(() async {
        final season = await _requireSeason(seasonId);
        final seasons = await _database.screenplayDao.getSeasons(
          season.screenplayId,
        );
        if (seasons.length == 1) {
          throw const ScreenplayServiceException(
            'last_season_required',
            'A screenplay must retain at least one season.',
          );
        }
        final episodes = await _database.screenplayDao.getEpisodes(seasonId);
        for (final episode in episodes) {
          await _softDeleteEpisodeTree(episode.id);
        }
        final now = DateTime.now();
        await (_database.update(
          _database.screenplaySeasons,
        )..where((table) => table.id.equals(seasonId))).write(
          ScreenplaySeasonsCompanion(
            deletedAt: Value(now),
            updatedAt: Value(now),
          ),
        );
        await _renumberSeasons(
          seasons.where((row) => row.id != seasonId).toList(),
        );
      });
      await syncNovelWordCount();
    });
  }

  Future<String> createEpisode({required String seasonId, String title = ''}) {
    return _write('screenplay_episodes', 'INSERT', seasonId, () async {
      return _database.transaction(() async {
        final season = await _requireSeason(seasonId);
        final episodeNumber =
            await _maxInt(
              table: 'screenplay_episodes',
              column: 'episode_number',
              where: 'season_id = ? AND deleted_at = 0',
              variables: [Variable.withString(seasonId)],
            ) +
            1;
        final now = DateTime.now();
        final id = await _insertNew(
          ShortEntityIdType.screenplayEpisode,
          'screenplay_episodes',
          (id) async => _database
              .into(_database.screenplayEpisodes)
              .insert(
                ScreenplayEpisodesCompanion.insert(
                  id: id,
                  screenplayId: season.screenplayId,
                  seasonId: seasonId,
                  episodeNumber: episodeNumber,
                  title: Value(title.trim()),
                  createdAt: Value(now),
                  updatedAt: Value(now),
                ),
              ),
        );
        await EpisodeEditingOrchestrator().ensureEpisodeEditing(_database, id);
        return id;
      });
    });
  }

  Future<void> updateEpisode({
    required String episodeId,
    String? title,
    int? episodeNumber,
    String? targetSeasonId,
  }) {
    return _write('screenplay_episodes', 'UPDATE', episodeId, () async {
      await _database.transaction(() async {
        final episode = await _requireEpisode(episodeId);
        final destinationSeasonId = targetSeasonId ?? episode.seasonId;
        final destinationSeason = await _requireSeason(destinationSeasonId);
        if (destinationSeason.screenplayId != episode.screenplayId) {
          throw const ScreenplayServiceException(
            'invalid_season_ref',
            'Target season belongs to another screenplay.',
          );
        }
        if (destinationSeasonId == episode.seasonId) {
          final siblings = await _database.screenplayDao.getEpisodes(
            episode.seasonId,
          );
          final target = episodeNumber ?? episode.episodeNumber;
          if (target < 1 || target > siblings.length) {
            throw const ScreenplayServiceException(
              'invalid_episode_number',
              'Episode number is outside the valid range.',
            );
          }
          final ordered = [...siblings]
            ..removeWhere((row) => row.id == episodeId)
            ..insert(target - 1, episode);
          await _renumberEpisodes(ordered, episode.seasonId);
        } else {
          final source = await _database.screenplayDao.getEpisodes(
            episode.seasonId,
          );
          if (source.length == 1) {
            throw const ScreenplayServiceException(
              'last_episode_required',
              'A season must retain at least one episode.',
            );
          }
          final destination = await _database.screenplayDao.getEpisodes(
            destinationSeasonId,
          );
          final target = episodeNumber ?? destination.length + 1;
          if (target < 1 || target > destination.length + 1) {
            throw const ScreenplayServiceException(
              'invalid_episode_number',
              'Episode number is outside the valid range.',
            );
          }
          await (_database.update(
            _database.screenplayEpisodes,
          )..where((table) => table.id.equals(episodeId))).write(
            ScreenplayEpisodesCompanion(
              seasonId: Value(destinationSeasonId),
              episodeNumber: const Value(2000000),
              updatedAt: Value(DateTime.now()),
            ),
          );
          await _renumberEpisodes(
            source.where((row) => row.id != episodeId).toList(),
            episode.seasonId,
          );
          final moved = episode.copyWith(seasonId: destinationSeasonId);
          final ordered = [...destination]..insert(target - 1, moved);
          await _renumberEpisodes(ordered, destinationSeasonId);
        }
        await (_database.update(
          _database.screenplayEpisodes,
        )..where((table) => table.id.equals(episodeId))).write(
          ScreenplayEpisodesCompanion(
            title: title == null ? const Value.absent() : Value(title.trim()),
            updatedAt: Value(DateTime.now()),
          ),
        );
      });
    });
  }

  /// 每集大纲正文整段覆盖 —— 编辑器 debounce 后整段写回，不做部分合并。
  Future<void> updateEpisodeOutline({
    required String episodeId,
    required String outline,
  }) {
    return _write('screenplay_episodes', 'UPDATE', episodeId, () async {
      await (_database.update(
        _database.screenplayEpisodes,
      )..where((table) => table.id.equals(episodeId))).write(
        ScreenplayEpisodesCompanion(
          outline: Value(outline),
          updatedAt: Value(DateTime.now()),
        ),
      );
    });
  }

  Future<void> deleteEpisode(String episodeId) {
    return _write('screenplay_episodes', 'SOFT_DELETE', episodeId, () async {
      await _database.transaction(() async {
        final episode = await _requireEpisode(episodeId);
        final siblings = await _database.screenplayDao.getEpisodes(
          episode.seasonId,
        );
        if (siblings.length == 1) {
          throw const ScreenplayServiceException(
            'last_episode_required',
            'A season must retain at least one episode.',
          );
        }
        await _softDeleteEpisodeTree(episodeId);
        await _renumberEpisodes(
          siblings.where((row) => row.id != episodeId).toList(),
          episode.seasonId,
        );
      });
      await syncNovelWordCount();
    });
  }

  /// 校验完整创建输入，不创建场次、场头或任何关联记录。
  Future<void> validateSceneCreate({
    required String screenplayId,
    required String episodeId,
    String? beatId,
    String? locationId,
    String? interiorExterior,
    required String stage,
    List<String>? characterIds,
    List<ScreenplayElement>? elements,
  }) async {
    await _validateSceneReferences(
      screenplayId: screenplayId,
      episodeId: episodeId,
      beatId: beatId,
      locationId: locationId,
    );
    _validateSceneFields(interiorExterior: interiorExterior, stage: stage);
    if (characterIds != null) {
      await _validateCastReferences(characterIds);
    }
    if (elements != null) {
      await _validateElementSequence(
        elements.map((element) => element.normalized()).toList(),
      );
    }
  }

  Future<List<String>> _validateCastReferences(
    List<String> characterIds,
  ) async {
    final normalized = characterIds.map((id) => id.trim()).toList();
    if (normalized.any((id) => id.isEmpty) ||
        normalized.toSet().length != normalized.length) {
      throw const ScreenplayServiceException(
        'invalid_character_ref',
        'Cast character ids must be non-empty and unique.',
      );
    }
    for (final characterId in normalized) {
      await _requireCharacter(characterId);
    }
    return normalized;
  }

  Future<String> createScene({
    required String screenplayId,
    required String episodeId,
    String? beatId,
    String? interiorExterior,
    String? locationId,
    String timeLabel = '',
    String synopsis = '',
    String title = '',
    List<String>? emotion,
    List<Map<String, dynamic>>? events,
    String stage = screenplayStageDraft,
  }) {
    return _write('screenplay_scenes', 'INSERT', episodeId, () async {
      return _database.transaction(() async {
        await _validateSceneReferences(
          screenplayId: screenplayId,
          episodeId: episodeId,
          beatId: beatId,
          locationId: locationId,
        );
        _validateSceneFields(interiorExterior: interiorExterior, stage: stage);
        validateSceneAnalysis(emotion: emotion, events: events);
        final order =
            await _maxInt(
              table: 'screenplay_scene_elements',
              column: 'sort_order',
              where: 'episode_id = ? AND deleted_at = 0',
              variables: [Variable.withString(episodeId)],
              emptyValue: -1,
            ) +
            1;
        final now = DateTime.now();
        final id = await _insertNew(
          ShortEntityIdType.screenplayScene,
          'screenplay_scenes',
          (id) async => _database
              .into(_database.screenplayScenes)
              .insert(
                ScreenplayScenesCompanion.insert(
                  id: id,
                  screenplayId: screenplayId,
                  episodeId: episodeId,
                  beatId: Value(beatId),
                  synopsis: Value(synopsis.trim()),
                  title: Value(title.trim()),
                  emotion: Value(emotion),
                  events: Value(events),
                  stage: Value(stage),
                  createdAt: Value(now),
                  updatedAt: Value(now),
                ),
              ),
        );
        await _insertNew(
          ShortEntityIdType.screenplayElement,
          'screenplay_scene_elements',
          (elementId) async => _database
              .into(_database.screenplaySceneElements)
              .insert(
                ScreenplaySceneElementsCompanion.insert(
                  id: elementId,
                  episodeId: episodeId,
                  sceneId: id,
                  sortOrder: order,
                  type: 'scene_heading',
                  interiorExterior: Value(interiorExterior),
                  locationId: Value(locationId),
                  timeLabel: Value(timeLabel.trim()),
                  createdAt: Value(now),
                  updatedAt: Value(now),
                ),
              ),
        );
        return id;
      });
    });
  }

  Future<void> updateScene({
    required String sceneId,
    Value<String?> beatId = const Value.absent(),
    Value<String?> interiorExterior = const Value.absent(),
    Value<String?> locationId = const Value.absent(),
    String? timeLabel,
    String? synopsis,
    String? title,
    Value<List<String>?> emotion = const Value.absent(),
    Value<List<Map<String, dynamic>>?> events = const Value.absent(),
    String? stage,
    bool restoreHistory = false,
  }) {
    return _write('screenplay_scenes', 'UPDATE', sceneId, () async {
      await _database.transaction(() async {
        final scene = await _requireScene(sceneId);
        validateSceneAnalysis(
          emotion: emotion.present ? emotion.value : null,
          events: events.present ? events.value : null,
        );
        _validateSceneFields(
          interiorExterior: interiorExterior.present
              ? interiorExterior.value
              : scene.interiorExterior,
          stage: stage ?? scene.stage,
        );
        await _validateSceneReferences(
          screenplayId: scene.screenplayId,
          episodeId: scene.episodeId,
          beatId: beatId.present ? beatId.value : scene.beatId,
          locationId: locationId.present ? locationId.value : scene.locationId,
          allowMissingLocation:
              restoreHistory ||
              !locationId.present ||
              locationId.value == scene.locationId,
        );
        if (interiorExterior.present ||
            locationId.present ||
            timeLabel != null) {
          await (_database.update(
            _database.screenplaySceneElements,
          )..where((table) => table.id.equals(scene.heading.id))).write(
            ScreenplaySceneElementsCompanion(
              interiorExterior: interiorExterior,
              locationId: locationId,
              timeLabel: timeLabel == null
                  ? const Value.absent()
                  : Value(timeLabel.trim()),
              updatedAt: Value(DateTime.now()),
            ),
          );
        }
        await (_database.update(
          _database.screenplayScenes,
        )..where((table) => table.id.equals(sceneId))).write(
          ScreenplayScenesCompanion(
            beatId: beatId,
            title: title == null ? const Value.absent() : Value(title.trim()),
            emotion: emotion,
            events: events,
            synopsis: synopsis == null
                ? const Value.absent()
                : Value(synopsis.trim()),
            stage: stage == null ? const Value.absent() : Value(stage),
            updatedAt: Value(DateTime.now()),
          ),
        );
      });
    });
  }

  Future<void> moveSceneBefore(String sceneId, String anchorSceneId) {
    return _moveScene(sceneId, anchorSceneId, before: true);
  }

  Future<void> moveSceneAfter(String sceneId, String anchorSceneId) {
    return _moveScene(sceneId, anchorSceneId, before: false);
  }

  Future<void> moveSceneToEpisodeEnd(String sceneId, String episodeId) {
    return _write('screenplay_scenes', 'MOVE_TO_END', sceneId, () async {
      await _database.transaction(() async {
        final scene = await _requireScene(sceneId);
        final target = await _requireEpisode(episodeId);
        if (target.screenplayId != scene.screenplayId) {
          throw const ScreenplayServiceException(
            'invalid_episode_ref',
            'Target episode belongs to another screenplay.',
          );
        }
        await _moveSceneRows(scene, episodeId, null, before: false);
      });
    });
  }

  Future<void> deleteScene(String sceneId) {
    return _write('screenplay_scenes', 'SOFT_DELETE', sceneId, () async {
      await _database.transaction(() async {
        final scene = await _requireScene(sceneId);
        await _softDeleteSceneTree(sceneId);
        await _renumberScenes(
          (await _database.screenplayDao.getSceneRows(
            scene.episodeId,
          )).where((row) => row.id != sceneId).toList(),
          scene.episodeId,
        );
      });
      await syncNovelWordCount();
    });
  }

  Future<String> createBeat({
    required String screenplayId,
    required String episodeId,
    required int actNumber,
    String title = '',
    String description = '',
    String? beforeBeatId,
    String? afterBeatId,
  }) {
    _validateActNumber(actNumber);
    return _write('screenplay_beats', 'INSERT', episodeId, () async {
      return _database.transaction(() async {
        if (beforeBeatId != null && afterBeatId != null) {
          throw const ScreenplayServiceException(
            'invalid_beat_anchor',
            'Specify only one beat anchor.',
          );
        }
        final episode = await _requireEpisode(episodeId);
        if (episode.screenplayId != screenplayId) {
          throw const ScreenplayServiceException(
            'invalid_episode_ref',
            'Episode belongs to another screenplay.',
          );
        }
        final anchorId = beforeBeatId ?? afterBeatId;
        final anchor = anchorId == null ? null : await _requireBeat(anchorId);
        if (anchor != null && anchor.episodeId != episodeId) {
          throw const ScreenplayServiceException(
            'beat_anchor_outside_episode',
            'Beat anchors must stay in the same episode.',
          );
        }
        // act_number 是必填项，锚点不能反过来悄悄改写它，否则调用方以为建在
        // 自己指定的幕里，实际落在别处且返回值里看不出来。
        if (anchor != null && anchor.actNumber != actNumber) {
          throw const ScreenplayServiceException(
            'beat_anchor_outside_act',
            'Beat anchors must stay in the act given by act_number.',
          );
        }
        final order =
            await _maxInt(
              table: 'screenplay_beats',
              column: 'sort_order',
              where: 'episode_id = ? AND act_number = ? AND deleted_at = 0',
              variables: [
                Variable.withString(episodeId),
                Variable.withInt(actNumber),
              ],
              emptyValue: -1,
            ) +
            1;
        final now = DateTime.now();
        final id = await _insertNew(
          ShortEntityIdType.screenplayBeat,
          'screenplay_beats',
          (id) async => _database
              .into(_database.screenplayBeats)
              .insert(
                ScreenplayBeatsCompanion.insert(
                  id: id,
                  screenplayId: screenplayId,
                  episodeId: episodeId,
                  actNumber: actNumber,
                  title: Value(title.trim()),
                  description: Value(description.trim()),
                  sortOrder: order,
                  createdAt: Value(now),
                  updatedAt: Value(now),
                ),
              ),
        );
        if (anchor != null) {
          await _moveBeatRows(
            await _requireBeat(id),
            actNumber,
            anchor,
            before: beforeBeatId != null,
          );
        }
        return id;
      });
    });
  }

  Future<void> updateBeat({
    required String beatId,
    String? title,
    String? description,
  }) {
    return _write('screenplay_beats', 'UPDATE', beatId, () async {
      await _requireBeat(beatId);
      await (_database.update(
        _database.screenplayBeats,
      )..where((table) => table.id.equals(beatId))).write(
        ScreenplayBeatsCompanion(
          title: title == null ? const Value.absent() : Value(title.trim()),
          description: description == null
              ? const Value.absent()
              : Value(description.trim()),
          updatedAt: Value(DateTime.now()),
        ),
      );
    });
  }

  Future<void> moveBeatBefore(String beatId, String anchorBeatId) {
    return _moveBeat(beatId, anchorBeatId, before: true);
  }

  Future<void> moveBeatAfter(String beatId, String anchorBeatId) {
    return _moveBeat(beatId, anchorBeatId, before: false);
  }

  Future<void> moveBeatToActEnd(String beatId, int actNumber) {
    _validateActNumber(actNumber);
    return _write('screenplay_beats', 'MOVE_TO_ACT_END', beatId, () async {
      await _database.transaction(() async {
        final beat = await _requireBeat(beatId);
        await _moveBeatRows(beat, actNumber, null, before: false);
      });
    });
  }

  Future<void> deleteBeat(String beatId) {
    return _write('screenplay_beats', 'SOFT_DELETE', beatId, () async {
      await _database.transaction(() async {
        final beat = await _requireBeat(beatId);
        final now = DateTime.now();
        await (_database.update(_database.screenplayScenes)..where(
              (table) =>
                  table.beatId.equals(beatId) &
                  table.deletedAt.equals(notDeletedSentinel),
            ))
            .write(
              ScreenplayScenesCompanion(
                beatId: const Value(null),
                updatedAt: Value(now),
              ),
            );
        await (_database.update(
          _database.screenplayBeats,
        )..where((table) => table.id.equals(beatId))).write(
          ScreenplayBeatsCompanion(
            deletedAt: Value(now),
            updatedAt: Value(now),
          ),
        );
        final rows = (await _database.screenplayDao.getBeatRows(beat.episodeId))
            .where((row) => row.id != beatId && row.actNumber == beat.actNumber)
            .toList();
        await _renumberBeats(rows, beat.episodeId, beat.actNumber);
      });
    });
  }

  Future<ScreenplayElementWriteResult> writeElements({
    required String sceneId,
    required List<ScreenplayElement> elements,
    bool restoreHistory = false,
  }) async {
    final result = await writeElementsInTransaction(
      sceneId: sceneId,
      elements: elements,
      restoreHistory: restoreHistory,
    );
    await syncNovelWordCount();
    return result;
  }

  Future<ScreenplayElementWriteResult> writeElementsInTransaction({
    required String sceneId,
    required List<ScreenplayElement> elements,
    bool restoreHistory = false,
  }) {
    return _write('screenplay_scene_elements', 'RECONCILE', sceneId, () async {
      for (final element in elements) {
        element.validateShape();
      }
      final normalized = elements.map((value) => value.normalized()).toList();
      final warnings = await _validateElementSequence(
        normalized,
        allowedMissingCharacters: restoreHistory
            ? normalized
                  .map((element) => element.characterId)
                  .whereType<String>()
                  .toSet()
            : const {},
      );
      final metrics = ScreenplayMetrics.calculate(normalized);
      final saved = await _database.transaction(() async {
        await _requireScene(sceneId);
        final reconciled = await _database.screenplayDao.reconcileElements(
          sceneId: sceneId,
          elements: normalized,
          idBuilder: _idBuilder,
        );
        await _ensureCastContainsElementCharacters(sceneId, reconciled);
        await (_database.update(
          _database.screenplayScenes,
        )..where((table) => table.id.equals(sceneId))).write(
          ScreenplayScenesCompanion(
            pageEighths: Value(metrics.pageEighths),
            dialogueLineCount: Value(metrics.dialogueLineCount),
            wordCount: Value(metrics.wordCount),
            updatedAt: Value(DateTime.now()),
          ),
        );
        return reconciled;
      });
      return ScreenplayElementWriteResult(
        elements: saved,
        metrics: metrics,
        warnings: warnings,
      );
    });
  }

  Stream<ScreenplayDocument> watchDocument(
    String episodeId, {
    Set<String>? sceneIds,
  }) => _database
      .customSelect(
        'SELECT 1',
        readsFrom: {
          _database.screenplayScenes,
          _database.screenplaySceneElements,
          _database.screenplaySceneCharacters,
          _database.entityRelations,
        },
      )
      .watch()
      .asyncMap((_) => readDocument(episodeId, sceneIds: sceneIds));

  Future<ScreenplayDocument> readDocument(
    String episodeId, {
    Set<String>? sceneIds,
    Set<String> evidenceIds = const {},
    String? previousSceneId,
    String? nextSceneId,
  }) async {
    final episode = await _requireEpisode(episodeId);
    final rows = await _database.screenplayDao.getSceneRows(episodeId);
    final selected = rows
        .where((row) => sceneIds == null || sceneIds.contains(row.id))
        .toList();
    final ids = selected.map((row) => row.id).toSet();
    final cast =
        await (_database.select(_database.screenplaySceneCharacters)..where(
              (table) =>
                  table.sceneId.isIn(ids) &
                  table.deletedAt.equals(notDeletedSentinel),
            ))
            .get();
    final relations = await _relations.queryRelationSummaries(
      sceneIds: ids.toList(),
      relationIds: evidenceIds.toList(),
    );
    final allElements = await _database.screenplayDao.getDocumentElements(
      episodeId,
    );
    return ScreenplayDocument(
      episodeId: episodeId,
      screenplayId: episode.screenplayId,
      fullEpisode: sceneIds == null,
      previousSceneId: sceneIds == null
          ? null
          : selected.isEmpty
          ? previousSceneId
          : rows.indexOf(selected.first) > 0
          ? rows[rows.indexOf(selected.first) - 1].id
          : null,
      nextSceneId: sceneIds == null
          ? null
          : selected.isEmpty
          ? nextSceneId
          : rows.indexOf(selected.last) + 1 < rows.length
          ? rows[rows.indexOf(selected.last) + 1].id
          : null,
      elements: allElements.where((e) => ids.contains(e.sceneId)),
      reservedIds:
          (await _database
                  .customSelect(
                    'SELECT id FROM screenplay_scenes UNION SELECT id FROM screenplay_scene_elements',
                  )
                  .get())
              .map((row) => row.read<String>('id'))
              .toSet(),
      scenes: {
        for (final row in selected)
          row.id: ScreenplayDocumentScene(
            id: row.id,
            beatId: row.beatId,
            synopsis: row.synopsis,
            title: row.title,
            emotion: row.emotion,
            events: row.events,
            stage: row.stage,
            cast: cast
                .where((c) => c.sceneId == row.id)
                .map((c) => c.characterId)
                .toSet(),
          ),
      },
      evidence: {for (final row in relations) row.id: row.sceneId},
      evidenceVersions: {
        for (final row in relations)
          row.id: jsonEncode(
            row.toJson()
              ..remove('sceneId')
              ..remove('updatedAt'),
          ),
      },
    );
  }

  /// 返回真正修改的场次；结构改动另外验证排序和关系基线。
  Future<Set<String>> validateDocumentBaseline(
    ScreenplayDocument baseline,
    ScreenplayDocument target,
  ) async {
    if (baseline.episodeId != target.episodeId ||
        baseline.screenplayId != target.screenplayId) {
      throw const ScreenplayServiceException(
        'invalid_screenplay_document',
        'Document scope cannot change during a save.',
      );
    }
    target.validate();
    final ids = {...baseline.scenes.keys, ...target.scenes.keys};
    final dirty = <String>{
      for (final id in ids)
        if (!(baseline.scenes[id]?.sameAs(target.scenes[id]) ??
                !target.scenes.containsKey(id)) ||
            !sameScreenplayElements(
              baseline.sceneElements(id),
              target.sceneElements(id),
            ))
          id,
    };
    final oldOrder = baseline.sceneOrder;
    final newOrder = target.sceneOrder;
    final targetOwners = {
      for (final element in target.elements) element.id: element.sceneId,
    };
    final structural =
        !const ListEquality<String>().equals(oldOrder, newOrder) ||
        baseline.elements.any(
          (e) =>
              targetOwners.containsKey(e.id) && targetOwners[e.id] != e.sceneId,
        );
    if (!const ListEquality<String>().equals(oldOrder, newOrder)) {
      // 最长公共子序列以外的场才是被移动的场，插入不接管后续所有场次。
      final lengths = List.generate(
        oldOrder.length + 1,
        (_) => List.filled(newOrder.length + 1, 0),
      );
      for (var i = oldOrder.length - 1; i >= 0; i--) {
        for (var j = newOrder.length - 1; j >= 0; j--) {
          lengths[i][j] = oldOrder[i] == newOrder[j]
              ? lengths[i + 1][j + 1] + 1
              : (lengths[i + 1][j] > lengths[i][j + 1]
                    ? lengths[i + 1][j]
                    : lengths[i][j + 1]);
        }
      }
      final stable = <String>{};
      var i = 0;
      var j = 0;
      while (i < oldOrder.length && j < newOrder.length) {
        if (oldOrder[i] == newOrder[j]) {
          stable.add(oldOrder[i]);
          i++;
          j++;
        } else if (lengths[i + 1][j] >= lengths[i][j + 1]) {
          i++;
        } else {
          j++;
        }
      }
      dirty.addAll(ids.difference(stable));
    }
    final current = await readDocument(
      baseline.episodeId,
      evidenceIds: {...baseline.evidence.keys, ...target.evidence.keys},
    );
    void stale() => throw const ScreenplayServiceException(
      'stale_screenplay_edit',
      'The edited screenplay has changed. Keep the local draft or reload explicitly.',
    );
    for (final id in dirty) {
      if (target.newSceneIds.contains(id)) {
        continue;
      }
      final expected = baseline.scenes[id];
      final actual = current.scenes[id];
      if ((expected == null ? actual != null : !expected.sameAs(actual)) ||
          !sameScreenplayElements(
            baseline.sceneElements(id),
            current.sceneElements(id),
          )) {
        stale();
      }
    }
    if (structural) {
      final baselineIds = baseline.scenes.keys.toSet();
      final allOrder = current.sceneOrder;
      final positions = [
        for (var i = 0; i < allOrder.length; i++)
          if (baselineIds.contains(allOrder[i])) i,
      ];
      final actualOrder = baseline.fullEpisode
          ? allOrder
          : positions.isEmpty
          ? <String>[]
          : allOrder.sublist(positions.first, positions.last + 1);
      if (!const ListEquality<String>().equals(actualOrder, oldOrder)) {
        stale();
      }
      if (!baseline.fullEpisode) {
        final before = baseline.previousSceneId;
        final after = baseline.nextSceneId;
        final beforeIndex = before == null ? -1 : allOrder.indexOf(before);
        final afterIndex = after == null
            ? allOrder.length
            : allOrder.indexOf(after);
        if ((before != null && beforeIndex < 0) ||
            (after != null && afterIndex < 0) ||
            !const ListEquality<String>().equals(
              allOrder.sublist(
                beforeIndex + 1,
                afterIndex < beforeIndex + 1 ? beforeIndex + 1 : afterIndex,
              ),
              oldOrder,
            )) {
          stale();
        }
      }
      for (final entry in current.evidence.entries) {
        if ((dirty.contains(entry.value) ||
                baseline.evidence.containsKey(entry.key)) &&
            (baseline.evidence[entry.key] != entry.value ||
                baseline.evidenceVersions[entry.key] !=
                    current.evidenceVersions[entry.key])) {
          stale();
        }
      }
      for (final entry in baseline.evidence.entries) {
        if (dirty.contains(entry.value) &&
            (!current.evidence.containsKey(entry.key) ||
                current.evidence[entry.key] != entry.value)) {
          stale();
        }
      }
    }
    // 新 ID 可以尚未落库，但不得借此挪用范围外元素或另一集的归档元素。
    final requested = target.elements
        .map((e) => e.id!)
        .toSet()
        .difference(target.newElementIds);
    final stored = await (_database.select(
      _database.screenplaySceneElements,
    )..where((table) => table.id.isIn(requested))).get();
    for (final row in stored) {
      if (row.episodeId != baseline.episodeId || !ids.contains(row.sceneId)) {
        throw const ScreenplayServiceException(
          'invalid_element_ref',
          'Element ID is outside the document scope.',
        );
      }
    }
    return dirty;
  }

  Future<
    ({
      ScreenplayDocument document,
      Map<String, String> sceneIds,
      Map<String, String> elementIds,
    })
  >
  applyDocument(
    ScreenplayDocument baseline,
    ScreenplayDocument target,
    Set<String> dirty,
  ) => _write(
    'screenplay_scenes,screenplay_scene_elements',
    'SAVE_DOCUMENT',
    target.episodeId,
    () async {
      final retainedCharacters = {
        for (final scene in baseline.scenes.values) ...scene.cast,
        ...baseline.elements.map((e) => e.characterId).whereType<String>(),
      };
      final retainedLocations = baseline.elements
          .map((e) => e.locationId)
          .whereType<String>()
          .toSet();
      final now = DateTime.now();
      final sceneIds = <String, String>{};
      final reserved = target.scenes.keys.toSet();
      for (final id in dirty) {
        final scene = target.scenes[id];
        if (scene == null) {
          continue;
        }
        validateSceneAnalysis(emotion: scene.emotion, events: scene.events);
        final heading = target.sceneElements(id).first;
        await _validateSceneReferences(
          screenplayId: target.screenplayId,
          episodeId: target.episodeId,
          beatId: scene.beatId,
          locationId: heading.locationId,
          allowMissingLocation: retainedLocations.contains(heading.locationId),
        );
        _validateSceneFields(
          interiorExterior: heading.interiorExterior,
          stage: scene.stage,
        );
        await _validateElementSequence(
          target.sceneElements(id).where((e) => !e.isHeading).toList(),
          allowedMissingCharacters: retainedCharacters,
        );
        for (final character in scene.cast) {
          if (!retainedCharacters.contains(character)) {
            await _requireCharacter(character);
          }
        }
        final previousSpeakers = baseline
            .sceneElements(id)
            .map((e) => e.characterId)
            .whereType<String>()
            .toSet();
        final currentSpeakers = target
            .sceneElements(id)
            .map((e) => e.characterId)
            .whereType<String>()
            .toSet();
        final repairedCast = {...scene.cast};
        for (final removed in previousSpeakers.difference(currentSpeakers)) {
          if (await _database.characterProfileDao.getById(removed) == null) {
            repairedCast.remove(removed);
          }
        }
        if (repairedCast.length != scene.cast.length) {
          target = target.copyWith(
            scenes: {...target.scenes, id: scene.withCast(repairedCast)},
          );
        }
        final existing = await (_database.select(
          _database.screenplayScenes,
        )..where((table) => table.id.equals(id))).getSingleOrNull();
        final isNew = target.newSceneIds.contains(id);
        if (!isNew && existing == null) {
          throw const ScreenplayServiceException(
            'invalid_scene_ref',
            'Retained scene was not found.',
          );
        }
        if (!isNew &&
            existing != null &&
            (existing.episodeId != target.episodeId ||
                existing.screenplayId != target.screenplayId)) {
          throw const ScreenplayServiceException(
            'invalid_scene_ref',
            'Scene belongs to another document.',
          );
        }
        final companion = ScreenplayScenesCompanion.insert(
          id: id,
          screenplayId: target.screenplayId,
          episodeId: target.episodeId,
          beatId: Value(scene.beatId),
          synopsis: Value(scene.synopsis),
          title: Value(scene.title),
          emotion: Value(scene.emotion),
          events: Value(scene.events),
          stage: Value(scene.stage),
          deletedAt: Value(notDeletedSentinel),
          createdAt: Value(isNew ? now : existing!.createdAt),
          updatedAt: Value(now),
        );
        if (isNew) {
          reserved.remove(id);
          sceneIds[id] = await _insertNew(
            ShortEntityIdType.screenplayScene,
            'screenplay_scenes',
            (newId) async => _database
                .into(_database.screenplayScenes)
                .insert(companion.copyWith(id: Value(newId))),
            candidate: id,
            reservedIds: reserved,
          );
        } else if (!scene.sameAs(baseline.scenes[id]) ||
            existing!.deletedAt != notDeletedSentinel) {
          await (_database.update(
            _database.screenplayScenes,
          )..where((table) => table.id.equals(id))).write(companion);
        }
      }
      // 已知低概率碰撞边界（2026-09-17 决定暂不处理）：已保存 B 被撤销但
      // 尚未落库，新场次候选又恰好为 B 时，B → C 会同时改写 dirty，遗漏
      // 旧 B 的删除；正文 heading 校验随后失败，由保存编排事务回滚。
      target = target.remapIdentities(sceneIds, const {});
      dirty = {for (final id in dirty) sceneIds[id] ?? id};
      // 先退出场次有效集合，但正文随后由批量 reconcile 移走，禁止级联删除。
      final removed = dirty
          .where((id) => !target.scenes.containsKey(id))
          .toSet();
      await (_database.update(
        _database.screenplayScenes,
      )..where((table) => table.id.isIn(removed))).write(
        ScreenplayScenesCompanion(deletedAt: Value(now), updatedAt: Value(now)),
      );
      final current = await _database.screenplayDao.getDocumentElements(
        target.episodeId,
      );
      final scope = {...baseline.scenes.keys, ...target.scenes.keys};
      final first = current.indexWhere((e) => scope.contains(e.sceneId));
      final after = current.indexWhere(
        (e) => e.sceneId == baseline.nextSceneId,
      );
      final before = current.lastIndexWhere(
        (e) => e.sceneId == baseline.previousSceneId,
      );
      final insertion = first >= 0
          ? first
          : after >= 0
          ? after
          : before >= 0
          ? before + 1
          : current.length;
      final outside = current.where((e) => !scope.contains(e.sceneId)).toList();
      final preserved = <String, List<ScreenplayElement>>{};
      for (final e in current.where((e) => !dirty.contains(e.sceneId))) {
        preserved.putIfAbsent(e.sceneId!, () => []).add(e);
      }
      final reordered = !const ListEquality<String>().equals(
        baseline.sceneOrder,
        target.sceneOrder,
      );
      List<ScreenplayElement> next;
      if (reordered) {
        final desired = [
          for (final id in target.sceneOrder)
            ...(dirty.contains(id) ? target.sceneElements(id) : preserved[id]!),
        ];
        outside.insertAll(insertion.clamp(0, outside.length), desired);
        next = outside;
      } else {
        next = [];
        for (final element in current) {
          if (!dirty.contains(element.sceneId)) {
            next.add(element);
          } else if (element.isHeading) {
            next.addAll(target.sceneElements(element.sceneId!));
          }
        }
      }
      final elementIds = await _database.screenplayDao.reconcileDocuments(
        {target.episodeId: next},
        newElementIds: target.newElementIds,
        idBuilder: _idBuilder,
      );
      target = target.remapIdentities(const {}, elementIds);
      for (final id in dirty) {
        final scene = target.scenes[id];
        final allCast = await (_database.select(
          _database.screenplaySceneCharacters,
        )..where((table) => table.sceneId.equals(id))).get();
        final wanted = scene?.cast ?? const <String>{};
        final byCharacter = <String, ScreenplaySceneCharacterRow>{};
        for (final row in allCast) {
          final previous = byCharacter[row.characterId];
          if (previous == null || row.deletedAt == notDeletedSentinel) {
            byCharacter[row.characterId] = row;
          }
        }
        await (_database.update(_database.screenplaySceneCharacters)..where(
              (table) =>
                  table.sceneId.equals(id) &
                  table.deletedAt.equals(notDeletedSentinel) &
                  table.characterId.isNotIn(wanted),
            ))
            .write(
              ScreenplaySceneCharactersCompanion(
                deletedAt: Value(now),
                updatedAt: Value(now),
              ),
            );
        var index = 0;
        for (final character in wanted) {
          final old = byCharacter[character];
          if (old == null) {
            await _database
                .into(_database.screenplaySceneCharacters)
                .insert(
                  ScreenplaySceneCharactersCompanion.insert(
                    id: buildRandomId('scene_character'),
                    sceneId: id,
                    characterId: character,
                    sortOrder: index,
                    createdAt: Value(now),
                    updatedAt: Value(now),
                  ),
                );
          } else if (old.deletedAt != notDeletedSentinel ||
              old.sortOrder != index) {
            await (_database.update(
              _database.screenplaySceneCharacters,
            )..where((table) => table.id.equals(old.id))).write(
              ScreenplaySceneCharactersCompanion(
                sortOrder: Value(index),
                deletedAt: Value(notDeletedSentinel),
                updatedAt: Value(now),
              ),
            );
          }
          index++;
        }
        if (scene != null &&
            (baseline.scenes[id] == null ||
                !sameScreenplayElements(
                  baseline
                      .sceneElements(id)
                      .where((e) => !e.isHeading)
                      .toList(),
                  target.sceneElements(id).where((e) => !e.isHeading).toList(),
                ))) {
          final metrics = ScreenplayMetrics.calculate(target.sceneElements(id));
          await (_database.update(
            _database.screenplayScenes,
          )..where((table) => table.id.equals(id))).write(
            ScreenplayScenesCompanion(
              pageEighths: Value(metrics.pageEighths),
              wordCount: Value(metrics.wordCount),
              dialogueLineCount: Value(metrics.dialogueLineCount),
            ),
          );
        }
      }
      for (final id in {...baseline.evidence.keys, ...target.evidence.keys}) {
        if (baseline.evidence[id] != target.evidence[id]) {
          await _relations.maintainSceneReference(
            id: id,
            sceneId: target.evidence[id],
          );
        }
      }
      return (document: target, sceneIds: sceneIds, elementIds: elementIds);
    },
  );

  Future<void> deleteElement({
    required String sceneId,
    required String elementId,
  }) async {
    final elements = (await _database.screenplayDao.getElementRows(sceneId))
        .map(
          (row) => ScreenplayElement(
            id: row.id,
            type: screenplayElementTypeFromName(row.type),
            text: row.textContent,
            characterId: row.characterId,
            extension: row.extension,
          ),
        )
        .toList();
    final index = elements.indexWhere((element) => element.id == elementId);
    if (index < 0) {
      throw const ScreenplayServiceException(
        'invalid_element_ref',
        'Element was not found in the scene.',
      );
    }
    if (elements[index].type == ScreenplayElementType.character) {
      final next = index + 1;
      if (next < elements.length) {
        final type = elements[next].type;
        if (type == ScreenplayElementType.parenthetical ||
            type == ScreenplayElementType.dialogue) {
          throw const ScreenplayServiceException(
            'dependent_elements_exist',
            'Remove or reassign the dialogue block before deleting its character.',
          );
        }
      }
    }
    elements.removeAt(index);
    await writeElements(sceneId: sceneId, elements: elements);
  }

  Future<void> replaceCast({
    required String sceneId,
    required List<String> characterIds,
  }) {
    return _write(
      'screenplay_scene_characters',
      'RECONCILE',
      sceneId,
      () async {
        await _database.transaction(() async {
          await _requireScene(sceneId);
          final normalized = await _validateCastReferences(characterIds);
          final elementRows = await _database.screenplayDao.getElementRows(
            sceneId,
          );
          final requiredIds = elementRows
              .where((row) => row.type == ScreenplayElementType.character.name)
              .map((row) => row.characterId)
              .whereType<String>()
              .toSet();
          final missing = requiredIds.difference(normalized.toSet());
          if (missing.isNotEmpty) {
            throw ScreenplayServiceException(
              'dependent_elements_exist',
              'Cast members referenced by dialogue cannot be removed.',
              details: missing.toList(),
            );
          }
          final existing = await _database.screenplayDao.getSceneCharacters(
            sceneId,
          );
          final byCharacter = {
            for (final row in existing) row.characterId: row,
          };
          final now = DateTime.now();
          for (var index = 0; index < existing.length; index++) {
            await (_database.update(
              _database.screenplaySceneCharacters,
            )..where((table) => table.id.equals(existing[index].id))).write(
              ScreenplaySceneCharactersCompanion(
                sortOrder: Value(1000000 + index),
                updatedAt: Value(now),
              ),
            );
          }
          for (var index = 0; index < normalized.length; index++) {
            final characterId = normalized[index];
            final row = byCharacter[characterId];
            if (row == null) {
              await _database
                  .into(_database.screenplaySceneCharacters)
                  .insert(
                    ScreenplaySceneCharactersCompanion.insert(
                      id: buildRandomId('scene_character'),
                      sceneId: sceneId,
                      characterId: characterId,
                      sortOrder: index,
                      createdAt: Value(now),
                      updatedAt: Value(now),
                    ),
                  );
            } else {
              await (_database.update(
                _database.screenplaySceneCharacters,
              )..where((table) => table.id.equals(row.id))).write(
                ScreenplaySceneCharactersCompanion(
                  sortOrder: Value(index),
                  deletedAt: Value(notDeletedSentinel),
                  updatedAt: Value(now),
                ),
              );
            }
          }
          final retained = normalized.toSet();
          for (final row in existing) {
            if (!retained.contains(row.characterId)) {
              await (_database.update(
                _database.screenplaySceneCharacters,
              )..where((table) => table.id.equals(row.id))).write(
                ScreenplaySceneCharactersCompanion(
                  deletedAt: Value(now),
                  updatedAt: Value(now),
                ),
              );
            }
          }
        });
      },
    );
  }

  Future<void> _moveScene(
    String sceneId,
    String anchorSceneId, {
    required bool before,
  }) {
    return _write('screenplay_scenes', 'REORDER', sceneId, () async {
      if (sceneId == anchorSceneId) {
        throw const ScreenplayServiceException(
          'invalid_scene_anchor',
          'A scene cannot be anchored to itself.',
        );
      }
      await _database.transaction(() async {
        final scene = await _requireScene(sceneId);
        final anchor = await _requireScene(anchorSceneId);
        if (scene.screenplayId != anchor.screenplayId) {
          throw const ScreenplayServiceException(
            'invalid_scene_ref',
            'Scene anchor belongs to another screenplay.',
          );
        }
        await _moveSceneRows(scene, anchor.episodeId, anchor, before: before);
      });
    });
  }

  Future<void> _moveSceneRows(
    ScreenplaySceneRecord scene,
    String targetEpisodeId,
    ScreenplaySceneRecord? anchor, {
    required bool before,
  }) async {
    final source = await _database.screenplayDao.getDocumentElements(
      scene.episodeId,
    );
    final target = targetEpisodeId == scene.episodeId
        ? source
        : await _database.screenplayDao.getDocumentElements(targetEpisodeId);
    final remaining = target
        .where((element) => element.sceneId != scene.id)
        .toList();
    var index = remaining.length;
    if (anchor != null) {
      index = remaining.indexWhere((element) => element.sceneId == anchor.id);
      if (index < 0) {
        throw const ScreenplayServiceException(
          'invalid_scene_anchor',
          'Scene anchor was not found.',
        );
      }
      if (!before) {
        while (index < remaining.length &&
            remaining[index].sceneId == anchor.id) {
          index++;
        }
      }
    }
    final moved = source
        .where((element) => element.sceneId == scene.id)
        .map((element) => element.copyWith(episodeId: targetEpisodeId))
        .toList();
    remaining.insertAll(index, moved);
    await (_database.update(
      _database.screenplayScenes,
    )..where((table) => table.id.equals(scene.id))).write(
      ScreenplayScenesCompanion(
        episodeId: Value(targetEpisodeId),
        beatId: targetEpisodeId == scene.episodeId
            ? const Value.absent()
            : const Value(null),
        updatedAt: Value(DateTime.now()),
      ),
    );
    await _database.screenplayDao.reconcileDocuments({
      if (targetEpisodeId != scene.episodeId)
        scene.episodeId: source
            .where((element) => element.sceneId != scene.id)
            .toList(),
      targetEpisodeId: remaining,
    });
  }

  Future<void> _moveBeat(
    String beatId,
    String anchorBeatId, {
    required bool before,
  }) {
    return _write('screenplay_beats', 'REORDER', beatId, () async {
      if (beatId == anchorBeatId) {
        throw const ScreenplayServiceException(
          'invalid_beat_anchor',
          'A beat cannot be anchored to itself.',
        );
      }
      await _database.transaction(() async {
        final beat = await _requireBeat(beatId);
        final anchor = await _requireBeat(anchorBeatId);
        if (beat.episodeId != anchor.episodeId) {
          throw const ScreenplayServiceException(
            'beat_anchor_outside_episode',
            'Beat anchors must stay in the same episode.',
          );
        }
        await _moveBeatRows(beat, anchor.actNumber, anchor, before: before);
      });
    });
  }

  Future<void> _moveBeatRows(
    ScreenplayBeatRow beat,
    int targetActNumber,
    ScreenplayBeatRow? anchor, {
    required bool before,
  }) async {
    final all = await _database.screenplayDao.getBeatRows(beat.episodeId);
    final source = all
        .where((row) => row.actNumber == beat.actNumber && row.id != beat.id)
        .toList();
    final target = all
        .where((row) => row.actNumber == targetActNumber && row.id != beat.id)
        .toList();
    var index = target.length;
    if (anchor != null) {
      index = target.indexWhere((row) => row.id == anchor.id);
      if (index < 0) {
        throw const ScreenplayServiceException(
          'invalid_beat_anchor',
          'Beat anchor was not found.',
        );
      }
      if (!before) {
        index += 1;
      }
    }
    await (_database.update(
      _database.screenplayBeats,
    )..where((table) => table.id.equals(beat.id))).write(
      ScreenplayBeatsCompanion(
        actNumber: Value(targetActNumber),
        sortOrder: const Value(2000000),
        updatedAt: Value(DateTime.now()),
      ),
    );
    if (targetActNumber != beat.actNumber) {
      await _renumberBeats(source, beat.episodeId, beat.actNumber);
    }
    target.insert(index, beat.copyWith(actNumber: targetActNumber));
    await _renumberBeats(target, beat.episodeId, targetActNumber);
  }

  Future<List<ScreenplayElementWarning>> _validateElementSequence(
    List<ScreenplayElement> elements, {
    Set<String> allowedMissingCharacters = const {},
  }) async {
    final warnings = <ScreenplayElementWarning>[];
    var hasActiveCharacter = false;
    var activeCharacterIndex = -1;
    var activeCharacterHasChild = false;
    for (var index = 0; index < elements.length; index++) {
      final element = elements[index];
      element.validateShape();
      switch (element.type) {
        case ScreenplayElementType.scene_heading:
          throw const ScreenplayServiceException(
            'invalid_element_type',
            'Single scene body cannot contain scene headings.',
          );
        case ScreenplayElementType.character:
          if (hasActiveCharacter && !activeCharacterHasChild) {
            warnings.add(_unfinishedCharacterWarning(activeCharacterIndex));
          }
          if (!allowedMissingCharacters.contains(element.characterId)) {
            await _requireCharacter(element.characterId!);
          }
          hasActiveCharacter = true;
          activeCharacterIndex = index;
          activeCharacterHasChild = false;
        case ScreenplayElementType.parenthetical:
        case ScreenplayElementType.dialogue:
          if (!hasActiveCharacter) {
            throw ScreenplayServiceException(
              'dialogue_character_required',
              'Dialogue and parenthetical elements require a preceding character.',
              details: index,
            );
          }
          activeCharacterHasChild = true;
        case ScreenplayElementType.action:
        case ScreenplayElementType.transition:
        case ScreenplayElementType.note:
        case ScreenplayElementType.subtitle:
          if (hasActiveCharacter && !activeCharacterHasChild) {
            warnings.add(_unfinishedCharacterWarning(activeCharacterIndex));
          }
          hasActiveCharacter = false;
          activeCharacterIndex = -1;
          activeCharacterHasChild = false;
      }
    }
    if (hasActiveCharacter && !activeCharacterHasChild) {
      warnings.add(_unfinishedCharacterWarning(activeCharacterIndex));
    }
    return warnings;
  }

  ScreenplayElementWarning _unfinishedCharacterWarning(int index) {
    return ScreenplayElementWarning(
      code: 'unfinished_character_block',
      elementIndex: index,
      message: 'Character cue has no dialogue or parenthetical.',
    );
  }

  Future<void> _ensureCastContainsElementCharacters(
    String sceneId,
    List<ScreenplayElement> elements,
  ) async {
    final existing = await _database.screenplayDao.getSceneCharacters(sceneId);
    final existingIds = existing.map((row) => row.characterId).toSet();
    final orderedMissing = <String>[];
    for (final element in elements) {
      final characterId = element.characterId;
      if (element.type == ScreenplayElementType.character &&
          characterId != null &&
          existingIds.add(characterId)) {
        orderedMissing.add(characterId);
      }
    }
    if (orderedMissing.isEmpty) {
      return;
    }
    final now = DateTime.now();
    for (var index = 0; index < orderedMissing.length; index++) {
      await _database
          .into(_database.screenplaySceneCharacters)
          .insert(
            ScreenplaySceneCharactersCompanion.insert(
              id: buildRandomId('scene_character'),
              sceneId: sceneId,
              characterId: orderedMissing[index],
              sortOrder: existing.length + index,
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );
    }
  }

  Future<void> _softDeleteEpisodeTree(String episodeId) async {
    final scenes = await _database.screenplayDao.getSceneRows(episodeId);
    for (final scene in scenes) {
      await _softDeleteSceneTree(scene.id);
    }
    final now = DateTime.now();
    await (_database.update(_database.screenplayBeats)..where(
          (table) =>
              table.episodeId.equals(episodeId) &
              table.deletedAt.equals(notDeletedSentinel),
        ))
        .write(
          ScreenplayBeatsCompanion(
            deletedAt: Value(now),
            updatedAt: Value(now),
          ),
        );
    await (_database.update(
      _database.screenplayEpisodes,
    )..where((table) => table.id.equals(episodeId))).write(
      ScreenplayEpisodesCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  Future<void> _softDeleteSceneTree(String sceneId) async {
    final now = DateTime.now();
    await _relations.clearSceneReferences(sceneId);
    await (_database.update(_database.screenplaySceneElements)..where(
          (table) =>
              table.sceneId.equals(sceneId) &
              table.deletedAt.equals(notDeletedSentinel),
        ))
        .write(
          ScreenplaySceneElementsCompanion(
            deletedAt: Value(now),
            updatedAt: Value(now),
          ),
        );
    await (_database.update(_database.screenplaySceneCharacters)..where(
          (table) =>
              table.sceneId.equals(sceneId) &
              table.deletedAt.equals(notDeletedSentinel),
        ))
        .write(
          ScreenplaySceneCharactersCompanion(
            deletedAt: Value(now),
            updatedAt: Value(now),
          ),
        );
    await (_database.update(
      _database.screenplayScenes,
    )..where((table) => table.id.equals(sceneId))).write(
      ScreenplayScenesCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  Future<void> _renumberSeasons(List<ScreenplaySeasonRow> rows) async {
    final now = DateTime.now();
    for (var index = 0; index < rows.length; index++) {
      await (_database.update(
        _database.screenplaySeasons,
      )..where((table) => table.id.equals(rows[index].id))).write(
        ScreenplaySeasonsCompanion(
          seasonNumber: Value(1000000 + index),
          updatedAt: Value(now),
        ),
      );
    }
    for (var index = 0; index < rows.length; index++) {
      await (_database.update(_database.screenplaySeasons)
            ..where((table) => table.id.equals(rows[index].id)))
          .write(ScreenplaySeasonsCompanion(seasonNumber: Value(index + 1)));
    }
  }

  Future<void> _renumberEpisodes(
    List<ScreenplayEpisodeRow> rows,
    String seasonId,
  ) async {
    final now = DateTime.now();
    for (var index = 0; index < rows.length; index++) {
      await (_database.update(
        _database.screenplayEpisodes,
      )..where((table) => table.id.equals(rows[index].id))).write(
        ScreenplayEpisodesCompanion(
          seasonId: Value(seasonId),
          episodeNumber: Value(1000000 + index),
          updatedAt: Value(now),
        ),
      );
    }
    for (var index = 0; index < rows.length; index++) {
      await (_database.update(_database.screenplayEpisodes)
            ..where((table) => table.id.equals(rows[index].id)))
          .write(ScreenplayEpisodesCompanion(episodeNumber: Value(index + 1)));
    }
  }

  Future<void> _renumberScenes(
    List<ScreenplaySceneRecord> rows,
    String episodeId,
  ) async {
    final elements = await _database.screenplayDao.getDocumentElements(
      episodeId,
    );
    final blocks = <String, List<ScreenplayElement>>{};
    for (final element in elements) {
      blocks.putIfAbsent(element.sceneId!, () => []).add(element);
    }
    await _database.screenplayDao.reconcileDocuments({
      episodeId: [for (final row in rows) ...blocks[row.id]!],
    });
  }

  Future<void> _renumberBeats(
    List<ScreenplayBeatRow> rows,
    String episodeId,
    int actNumber,
  ) async {
    final now = DateTime.now();
    for (var index = 0; index < rows.length; index++) {
      await (_database.update(
        _database.screenplayBeats,
      )..where((table) => table.id.equals(rows[index].id))).write(
        ScreenplayBeatsCompanion(
          episodeId: Value(episodeId),
          actNumber: Value(actNumber),
          sortOrder: Value(1000000 + index),
          updatedAt: Value(now),
        ),
      );
    }
    for (var index = 0; index < rows.length; index++) {
      await (_database.update(_database.screenplayBeats)
            ..where((table) => table.id.equals(rows[index].id)))
          .write(ScreenplayBeatsCompanion(sortOrder: Value(index)));
    }
  }

  Future<ScreenplayRow> _requireScreenplay(String id) async {
    final row =
        await (_database.select(_database.screenplays)..where(
              (table) =>
                  table.id.equals(id) &
                  table.deletedAt.equals(notDeletedSentinel),
            ))
            .getSingleOrNull();
    if (row == null) {
      throw const ScreenplayServiceException(
        'invalid_screenplay_ref',
        'Screenplay was not found.',
      );
    }
    return row;
  }

  Future<ScreenplaySeasonRow> _requireSeason(String id) async {
    final row = await _database.screenplayDao.getSeason(id);
    if (row == null) {
      throw const ScreenplayServiceException(
        'invalid_season_ref',
        'Season was not found.',
      );
    }
    return row;
  }

  Future<ScreenplayEpisodeRow> _requireEpisode(String id) async {
    final row = await _database.screenplayDao.getEpisode(id);
    if (row == null) {
      throw const ScreenplayServiceException(
        'invalid_episode_ref',
        'Episode was not found.',
      );
    }
    return row;
  }

  Future<ScreenplaySceneRecord> _requireScene(String id) async {
    final row = await _database.screenplayDao.getScene(id);
    if (row == null) {
      throw const ScreenplayServiceException(
        'invalid_scene_ref',
        'Scene was not found.',
      );
    }
    return row;
  }

  Future<ScreenplayBeatRow> _requireBeat(String id) async {
    final row = await _database.screenplayDao.getBeat(id);
    if (row == null) {
      throw const ScreenplayServiceException(
        'invalid_beat_ref',
        'Beat was not found.',
      );
    }
    return row;
  }

  Future<void> _requireCharacter(String id) async {
    final row =
        await (_database.select(_database.characterProfiles)..where(
              (table) =>
                  table.id.equals(id) &
                  table.deletedAt.equals(notDeletedSentinel),
            ))
            .getSingleOrNull();
    if (row == null) {
      throw const ScreenplayServiceException(
        'invalid_character_ref',
        'Character was not found in this work.',
      );
    }
  }

  Future<void> _validateSceneReferences({
    required String screenplayId,
    required String episodeId,
    required String? beatId,
    required String? locationId,
    bool allowMissingLocation = false,
  }) async {
    final episode = await _requireEpisode(episodeId);
    if (episode.screenplayId != screenplayId) {
      throw const ScreenplayServiceException(
        'invalid_episode_ref',
        'Episode belongs to another screenplay.',
      );
    }
    if (beatId != null) {
      final beat = await _requireBeat(beatId);
      if (beat.screenplayId != screenplayId || beat.episodeId != episodeId) {
        throw const ScreenplayServiceException(
          'invalid_beat_ref',
          'Beat must belong to the scene episode.',
        );
      }
    }
    if (locationId != null) {
      final location =
          await (_database.select(_database.locations)..where(
                (table) =>
                    table.id.equals(locationId) &
                    table.deletedAt.equals(notDeletedSentinel),
              ))
              .getSingleOrNull();
      if (location == null && !allowMissingLocation) {
        throw const ScreenplayServiceException(
          'invalid_location_ref',
          'Location was not found in this work.',
        );
      }
    }
  }

  static void validateSceneAnalysis({
    List<String>? emotion,
    List<Map<String, dynamic>>? events,
  }) {
    if (emotion != null &&
        (emotion.any((tag) => tag.trim().isEmpty) ||
            emotion.map((tag) => tag.trim()).toSet().length !=
                emotion.length)) {
      throw const ScreenplayServiceException(
        'invalid_scene_emotion',
        'Emotion tags must be non-empty and unique.',
      );
    }
    if (events != null) {
      for (final event in events) {
        if (event['title'] is! String ||
            (event['title'] as String).trim().isEmpty ||
            event['summary'] is! String ||
            (event['summary'] as String).trim().isEmpty ||
            (event['state_change'] != null &&
                event['state_change'] is! String) ||
            event.keys.any(
              (key) => !{'title', 'summary', 'state_change'}.contains(key),
            )) {
          throw const ScreenplayServiceException(
            'invalid_scene_event',
            'Events require title and summary, with an optional state_change.',
          );
        }
      }
    }
  }

  void _validateSceneFields({
    required String? interiorExterior,
    required String stage,
  }) {
    if (interiorExterior != null &&
        !screenplayInteriorExteriorValues.contains(interiorExterior)) {
      throw const ScreenplayServiceException(
        'invalid_interior_exterior',
        'interior_exterior must be interior, exterior, interior_exterior, or null.',
      );
    }
    if (!screenplayStages.contains(stage)) {
      throw const ScreenplayServiceException(
        'invalid_scene_stage',
        'Scene stage must be draft or final.',
      );
    }
  }

  void _validatePlannedEpisodeCount(int? value) {
    if (value != null && value <= 0) {
      throw const ScreenplayServiceException(
        'invalid_planned_episode_count',
        'Planned episode count must be positive.',
      );
    }
  }

  void _validateActNumber(int value) {
    if (value <= 0) {
      throw const ScreenplayServiceException(
        'invalid_act_number',
        'Act number must be positive.',
      );
    }
  }

  Future<int> _maxInt({
    required String table,
    required String column,
    required String where,
    required List<Variable<Object>> variables,
    int emptyValue = 0,
  }) async {
    final row = await _database
        .customSelect(
          'SELECT MAX($column) AS value FROM $table WHERE $where',
          variables: variables,
        )
        .getSingle();
    return row.readNullable<int>('value') ?? emptyValue;
  }

  Future<void> syncNovelWordCount() async {
    final actions = novelActionsService;
    if (actions == null) {
      return;
    }
    // AI 和历史变更按内容库操作；与小说正文使用同一所属作品查询。
    final workId =
        novelId ??
        (await actions.getNovelByContentDatabasePath(_database.filePath))?.id;
    if (workId == null) {
      return;
    }
    final row = await _database
        .customSelect(
          'SELECT COALESCE(SUM(word_count), 0) AS total '
          'FROM screenplay_scenes WHERE deleted_at = 0',
          readsFrom: {_database.screenplayScenes},
        )
        .getSingle();
    await actions.updateNovelWordCount(
      novelId: workId,
      wordCount: row.read<int>('total'),
    );
  }

  Future<T> _write<T>(
    String table,
    String operation,
    String id,
    Future<T> Function() action,
  ) async {
    try {
      final result = await action();
      await novelActionsService?.markContentEdited(_database.filePath);
      return result;
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=$table operation=$operation id=$id failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }
}

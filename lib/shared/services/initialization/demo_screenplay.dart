// 职责: 创建或复用内置 demo 剧本 — 初始化作品元数据、内容库及其完整示例素材
// 关联文件:
//   lib/shared/services/initialization/demo_screenplay_data.dart
//   lib/shared/database/app_database.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/services/screenplay_service.dart
//   lib/shared/utils/storage_paths.dart

import 'package:drift/drift.dart';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'package:flutter/services.dart';

import '../../database/app_database.dart';
import '../../database/novel_content_database.dart';
import '../../logger/app_logger.dart';
import '../../models/content_kind.dart';
import '../../models/novel_type.dart';
import '../../models/production/default_style.dart';
import '../../models/screenplay_element.dart';
import '../novel_content.dart';
import '../screenplay_service.dart';
import '../../utils/short_entity_id.dart';
import 'demo_screenplay_data.dart';
import '../image_library_service.dart';

final _log = AppLogger.forModule('DemoScreenplay');

Future<void> seedDemoScreenplay(AppDatabase database) async {
  final existing = await database.novelDao.getShelfByTitle(demoScreenplayTitle);
  if (existing != null) {
    _log.info('skip seed: shelf title exists id=${existing.id}');
    return;
  }
  await createDemoScreenplay(database);
}

Future<String> createDemoScreenplay(
  AppDatabase database, {
  ShortEntityIdBuilder idBuilder = buildShortEntityId,
}) async {
  final screenplayId = idBuilder(ShortEntityIdType.screenplay);
  // 先建内容库再登记作品：失败只需删掉刚建的库文件，不会留下残缺作品。
  final contentDatabasePath = await buildNovelContentDatabasePath(screenplayId);
  try {
    final contentDatabase = NovelContentDatabase(contentDatabasePath);
    try {
      await _seedDemoContent(contentDatabase, idBuilder: idBuilder);
    } finally {
      await contentDatabase.close();
    }
    final coverAssetId = await _prepareDemoScreenplayCover(
      database,
      screenplayId,
    );
    await database.novelDao.create(
      id: screenplayId,
      title: demoScreenplayTitle,
      description: demoScreenplayDescription,
      coverAssetId: coverAssetId,
      contentDatabasePath: contentDatabasePath,
      tags: demoScreenplayTags,
      category: demoScreenplayCategory,
      contentKind: contentKindScreenplay,
      type: novelTypeOriginal,
    );
  } catch (error, stackTrace) {
    await NovelContentDatabase.deleteFiles(contentDatabasePath);
    Error.throwWithStackTrace(error, stackTrace);
  }
  return screenplayId;
}

Future<String?> _prepareDemoScreenplayCover(
  AppDatabase database,
  String screenplayId,
) async {
  try {
    final data = await rootBundle.load(
      'assets/images/demo/screenplay_cover.webp',
    );
    return (await buildImageLibraryService(database).importBytes(
      data.buffer.asUint8List(),
      name: 'screenplay_cover.webp',
      novelId: screenplayId,
      purpose: AssetPurpose.cover,
    )).id;
  } catch (error, stackTrace) {
    _log.error(
      '[FILE][demo_screenplay][COVER] failed to prepare demo cover',
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
}

Future<void> _seedDemoContent(
  NovelContentDatabase database, {
  required ShortEntityIdBuilder idBuilder,
}) async {
  final contentService = NovelContentService(database, idBuilder: idBuilder);
  final screenplayService = ScreenplayService(database, idBuilder: idBuilder);
  final structure = await screenplayService.createInitialStructure(
    plannedEpisodeCount: demoScreenplayEpisodes.length,
    style: initialProductionStyle(
      category: demoScreenplayCategory,
      tags: demoScreenplayTags,
    ),
  );
  await screenplayService.updateSeason(
    seasonId: structure.seasonId,
    title: demoScreenplaySeasonTitle,
    plannedEpisodeCount: Value<int?>(demoScreenplayEpisodes.length),
  );

  final episodeIds = <int, String>{1: structure.episodeId};
  for (final episode in demoScreenplayEpisodes) {
    final episodeId = episode.number == 1
        ? structure.episodeId
        : await screenplayService.createEpisode(
            seasonId: structure.seasonId,
            title: episode.title,
          );
    episodeIds[episode.number] = episodeId;
    await screenplayService.updateEpisode(
      episodeId: episodeId,
      title: episode.title,
    );
    await screenplayService.updateEpisodeOutline(
      episodeId: episodeId,
      outline: episode.outline,
    );
  }

  final characterIds = <String, String>{};
  for (final character in demoScreenplayCharacters) {
    final id = await contentService.createCharacterProfile(
      name: character.name,
      role: character.role,
      gender: character.gender,
      aliases: character.aliases,
      tags: character.tags,
      biography: character.summary,
      appearance: character.appearance,
      description: character.description,
      currentState: character.currentState,
      identity: character.identity,
      age: character.age,
      motivation: character.motivation,
      arc: character.arc,
      personality: character.personality,
      behaviorTags: [
        for (final tag in character.behaviorTags)
          CharacterBehaviorTag(tag: tag.tag, context: tag.context),
      ],
    );
    characterIds[character.key] = id;
  }

  final locationIds = <String, String>{};
  for (final location in demoScreenplayLocations) {
    final parentId = location.parentKey == null
        ? null
        : locationIds[location.parentKey];
    final id = await contentService.locationsService.createLocation(
      name: location.name,
      description: location.description,
      type: location.type,
      parentId: parentId,
      tags: location.tags.isEmpty
          ? const []
          : location.tags.split(',').map((tag) => tag.trim()).toList(),
    );
    locationIds[location.key] = id;
  }

  for (final document in demoScreenplayDocuments) {
    await contentService.documentsService.createDocument(
      type: document.type,
      title: document.title,
      content: document.content,
      tags: document.tags,
      category: document.category,
      status: document.status,
    );
  }

  final root = await database.screenplayDao.getRoot();
  if (root == null) {
    throw StateError('Demo screenplay root was not created.');
  }
  final beatIds = <String, String>{};
  for (final beat in demoScreenplayBeats) {
    final episodeId = episodeIds[beat.episodeNumber];
    if (episodeId == null) {
      throw StateError(
        'Demo screenplay beat has no episode: ${beat.episodeNumber}',
      );
    }
    beatIds[beat.key] = await screenplayService.createBeat(
      screenplayId: root.id,
      episodeId: episodeId,
      actNumber: beat.actNumber,
      title: beat.title,
      description: beat.description,
    );
  }

  for (final scene in demoScreenplayScenes) {
    final episodeId = episodeIds[scene.episodeNumber];
    if (episodeId == null) {
      throw StateError(
        'Demo screenplay scene has no episode: ${scene.episodeNumber}',
      );
    }
    final heading = scene.elements.firstWhere(
      (element) => element.type == ScreenplayElementType.scene_heading.name,
    );
    final sceneId = await screenplayService.createScene(
      screenplayId: root.id,
      episodeId: episodeId,
      beatId: scene.beatKey == null ? null : beatIds[scene.beatKey],
      interiorExterior: heading.interiorExterior,
      locationId: heading.locationKey == null
          ? null
          : locationIds[heading.locationKey],
      timeLabel: heading.timeLabel ?? '',
      synopsis: scene.synopsis,
      title: scene.title,
      emotion: scene.emotion,
      events: [
        for (final event in scene.events) Map<String, dynamic>.from(event),
      ],
      stage: scene.stage,
    );
    await screenplayService.writeElements(
      sceneId: sceneId,
      elements: [
        for (final element in scene.elements)
          if (element.type != ScreenplayElementType.scene_heading.name)
            ScreenplayElement(
              type: screenplayElementTypeFromName(element.type),
              text: element.text,
              characterId: element.characterKey == null
                  ? null
                  : characterIds[element.characterKey],
              extension: element.extension,
              interiorExterior: element.interiorExterior,
              locationId: element.locationKey == null
                  ? null
                  : locationIds[element.locationKey],
              timeLabel: element.timeLabel,
            ),
      ],
    );
  }
}

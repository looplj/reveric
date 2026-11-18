// 职责: 验证示例剧本的完整关联及小说、剧本合并初始化的去重行为。
// 关联文件:
//   lib/shared/services/initialization/demo_screenplay.dart
//   lib/shared/services/initialization/demo_screenplay_data.dart
//   lib/shared/services/demo_novel.dart
//   lib/shared/services/app_initialization.dart
//   lib/shared/database/novel_content_database.dart

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/services/initialization/demo_screenplay.dart';
import 'package:reveric/shared/services/app_initialization.dart';
import 'package:reveric/shared/services/demo_novel.dart';
import 'package:reveric/shared/services/initialization/demo_screenplay_data.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late AppDatabase appDatabase;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('demo_screenplay_');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(channel, (_) async => root.path);
    await RevericPaths.initialize();
    appDatabase = AppDatabase.forTest(NativeDatabase.memory());
  });

  tearDown(() async {
    await NovelContentDatabase.closeAllCached();
    await appDatabase.close();
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  test('seeds the debug screenplay as a complete demo work', () async {
    final id = await createDemoScreenplay(appDatabase);
    final novel = await appDatabase.novelDao.get(id);

    expect(novel, isNotNull);
    expect(novel!.title, demoScreenplayTitle);
    expect(novel.contentKind, contentKindScreenplay);
    expect(novel.tags, contains('demo'));
    expect(novel.contentDatabasePath, isNotNull);
    expect(novel.coverAssetId, isNotNull);
    final cover = (await appDatabase.assetDao.getAsset(novel.coverAssetId!))!;
    expect(cover.purpose, 'cover');
    expect(cover.novelId, id);
    expect(cover.path, startsWith('file_workspaces/$id/images/'));
    expect(await Directory('${root.path}/novel_covers').exists(), false);
    final resolvedCoverPath = RevericPaths.resolveStored(cover.path);
    expect(resolvedCoverPath, isNotNull);
    expect(await File(resolvedCoverPath!).exists(), isTrue);

    final contentDatabase = NovelContentDatabase(novel.contentDatabasePath!);
    addTearDown(contentDatabase.close);
    expect(
      await contentDatabase.select(contentDatabase.screenplays).get(),
      hasLength(1),
    );
    final seasons = await contentDatabase
        .select(contentDatabase.screenplaySeasons)
        .get();
    expect(seasons, hasLength(1));
    expect(seasons.single.title, demoScreenplaySeasonTitle);
    expect(seasons.single.plannedEpisodeCount, 6);
    final episodes = await contentDatabase
        .select(contentDatabase.screenplayEpisodes)
        .get();
    final beats = await contentDatabase
        .select(contentDatabase.screenplayBeats)
        .get();
    final scenes = await contentDatabase
        .select(contentDatabase.screenplayScenes)
        .get();
    final elements = await contentDatabase
        .select(contentDatabase.screenplaySceneElements)
        .get();
    final characters = await contentDatabase
        .select(contentDatabase.characterProfiles)
        .get();
    final locations = await contentDatabase
        .select(contentDatabase.locations)
        .get();
    expect(episodes, hasLength(6));
    expect(beats, isEmpty);
    expect(scenes, hasLength(18));
    expect(characters, hasLength(4));
    expect(locations, hasLength(7));
    final characterIds = characters.map((row) => row.id).toSet();
    final locationIds = locations.map((row) => row.id).toSet();
    for (final episode in episodes) {
      expect(episode.outline, isNotEmpty);
      final episodeScenes = scenes.where(
        (scene) => scene.episodeId == episode.id,
      );
      expect(episodeScenes, hasLength(3));
      expect(episodeScenes.map((scene) => scene.beatId), everyElement(isNull));
      for (final scene in episodeScenes) {
        final sceneElements = elements.where(
          (element) => element.sceneId == scene.id,
        );
        final heading = sceneElements.singleWhere(
          (element) => element.type == 'scene_heading',
        );
        expect(locationIds, contains(heading.locationId));
        expect(heading.timeLabel, isNotEmpty);
        expect(
          sceneElements.where((element) => element.type == 'action'),
          isNotEmpty,
        );
        expect(
          sceneElements.where((element) => element.type == 'dialogue'),
          isNotEmpty,
        );
        for (final element in sceneElements.where(
          (element) => element.type == 'character',
        )) {
          expect(characterIds, contains(element.characterId));
        }
      }
    }
    final documents = await contentDatabase
        .select(contentDatabase.documents)
        .get();
    expect(documents, hasLength(4));
    expect(documents.map((row) => row.title).toSet(), hasLength(4));

    expect((await contentDatabase.screenplayDao.getRoot())!.styleId, isNull);
    final episode = (await contentDatabase.screenplayDao.getEpisodes(
      (await contentDatabase.screenplayDao.getSeasons(
        (await contentDatabase.screenplayDao.getRoot())!.id,
      )).single.id,
    )).first;
    expect(episode.title, '磨掉的编号');
    expect(episode.outline, contains('水泵铭牌'));
  });

  test('seed reuses the existing shelf demo instead of duplicating', () async {
    final id = await createDemoScreenplay(appDatabase);
    await seedDemoScreenplay(appDatabase);

    final novels = await appDatabase.novelDao.getAll();
    expect(novels.map((novel) => novel.id), [id]);
  });
  for (final novelAlreadyExists in [false, true]) {
    test(
      'combined demo task seeds both works once (novel exists: $novelAlreadyExists)',
      () async {
        final existingNovelId = novelAlreadyExists
            ? await createDemoNovel(appDatabase)
            : null;
        final tasks = defaultAppInitializationTasks()
            .where((task) => task.id.startsWith('demo_'))
            .toList();
        expect(tasks, hasLength(1));
        expect(tasks.single.id, 'demo_works_v1');
        await ensureAppInitializationTasks(database: appDatabase, tasks: tasks);
        var works = await appDatabase.novelDao.getAll();
        expect(works, hasLength(2));
        expect(works.map((work) => work.title).toSet(), {
          '潮汐邮局',
          demoScreenplayTitle,
        });
        if (existingNovelId != null) {
          expect(
            works.singleWhere((work) => work.title == '潮汐邮局').id,
            existingNovelId,
          );
        }
        expect(
          await appDatabase.appStateDao.get('app_initialization.demo_works_v1'),
          isNotEmpty,
        );
        for (final work in works) {
          final content = NovelContentDatabase(work.contentDatabasePath!);
          expect(await content.select(content.canvases).get(), isEmpty);
          await content.close();
        }
        // Replay the task as well as the runner to cover title deduplication and completion skipping.
        await tasks.single.run(appDatabase);
        await ensureAppInitializationTasks(database: appDatabase, tasks: tasks);
        works = await appDatabase.novelDao.getAll();
        expect(works, hasLength(2));
      },
    );
  }
}

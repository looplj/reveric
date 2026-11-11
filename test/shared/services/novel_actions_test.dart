// 职责: 测试 NovelActionsService — 作品创建、标题冲突、移入回收站与恢复、封面文件保留行为。
// 关联文件:
//   lib/shared/services/novel_actions.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/providers/anonymous_reporting_providers.dart
//   lib/shared/database/app_database.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/database/novel_content_daos/novel_state_dao.dart
//   lib/shared/services/anonymous_outbox_service.dart
//   lib/shared/services/device_id_service.dart
//   lib/shared/utils/storage_paths.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/providers/video_tasks.dart';
import 'package:reveric/shared/providers/production_media.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/novel_type.dart';
import 'package:reveric/shared/services/image_library_service.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase appDb;

  setUp(() {
    appDb = AppDatabase.forTest(NativeDatabase.memory());
  });

  tearDown(() async {
    await NovelContentDatabase.closeAllCached();
    await appDb.close();
  });

  group('NovelActionsService', () {
    test(
      'canvas creation has one root and board, no story hierarchy or onboarding',
      () async {
        await _configureTemporaryStorage('canvas_create');
        final service = NovelActionsService(appDb);
        await appDb.novelDao.create(
          id: 'existing',
          title: '未命名画布',
          description: '',
        );
        final ids = await Future.wait([
          service.createCanvas(defaultTitle: '未命名画布'),
          service.createCanvas(defaultTitle: '未命名画布'),
        ]);
        final works = [for (final id in ids) (await appDb.novelDao.get(id))!];
        expect(works.map((work) => work.title).toSet(), {'未命名画布 2', '未命名画布 3'});
        for (final work in works) {
          expect(work.id, matches(RegExp(r'^cnv_[A-Z0-9]{6}$')));
          expect(work.contentKind, contentKindCanvas);
          final content = NovelContentDatabase(work.contentDatabasePath!);
          expect(await content.select(content.screenplays).get(), hasLength(1));
          expect((await content.screenplayDao.getRoot())!.styleId, isNotNull);
          final canvases = await content.select(content.canvases).get();
          expect(canvases, hasLength(1));
          expect(canvases.single.kind, canvasKindProduction);
          expect(canvases.single.id, startsWith('can_'));
          expect(
            await content.select(content.screenplaySeasons).get(),
            isEmpty,
          );
          expect(
            await content.select(content.screenplayEpisodes).get(),
            isEmpty,
          );
          expect(await content.select(content.screenplayScenes).get(), isEmpty);
          expect(await content.select(content.chapters).get(), isEmpty);
          expect(await content.novelStateDao.get('novel_onboarding'), isNull);
          final clip = await StoryboardService(
            content,
            contentKind: work.contentKind,
          ).createImage('');
          final providers = ProviderContainer.test(
            overrides: [
              appDatabaseProvider.overrideWithValue(appDb),
              mediaLibraryServiceProvider.overrideWithValue(
                MediaLibraryService(
                  appDb,
                  MediaService(FfmpegRunner()),
                  Directory.systemTemp,
                ),
              ),
            ],
          );
          try {
            await providers
                .read(productionResultServiceProvider)
                .beforeCreate(work.id, 'production_clip', clip.id);
          } finally {
            providers.dispose();
          }

          await content.close();
          await service.ensureNovelContentDatabasePath(work);
          final reopened = NovelContentDatabase(work.contentDatabasePath!);
          expect(await reopened.select(reopened.chapters).get(), isEmpty);
          expect(await reopened.select(reopened.canvases).get(), hasLength(1));
          await reopened.close();
        }
      },
    );

    test(
      'canvas initialization failure removes only its unregistered database',
      () async {
        final temporary = await _configureTemporaryStorage('canvas_failed');
        await expectLater(
          NovelActionsService(appDb).createNovel(
            title: 'Failed canvas',
            description: '',
            contentKind: contentKindCanvas,
            populateContent: (_) async =>
                throw StateError('failure after initialization'),
          ),
          throwsStateError,
        );
        await _expectUnregisteredCreation(appDb, 'Failed canvas', temporary);
      },
    );

    test(
      'creates and deletes works without enqueuing conversion events',
      () async {
        await _configureTemporaryStorage('novel_content_kind');
        final service = NovelActionsService(
          appDb,

          seedNovelWorkspace: (_) async {},
          seedScreenplayWorkspace: (_, _) async {},
        );

        final novelId = await service.createNovel(
          title: 'Novel',
          description: '',
        );
        final screenplayId = await service.createNovel(
          title: 'Screenplay',
          description: '',
          contentKind: contentKindScreenplay,
        );
        final screenplay = await appDb.novelDao.get(screenplayId);
        await service.deleteNovel(screenplay!);

        expect(
          (await appDb.novelDao.get(novelId))?.contentKind,
          contentKindNovel,
        );
        expect(screenplay.contentKind, contentKindScreenplay);
        expect(await appDb.novelDao.get(screenplayId), isNull);
        expect(await appDb.select(appDb.anonymousOutboxEvents).get(), isEmpty);
      },
    );

    test(
      'createImportedScreenplay stores the source as a material and dedupes the title',
      () async {
        await _configureTemporaryStorage('imported_screenplay');
        await appDb.novelDao.create(
          id: 'existing',
          title: '原著',
          description: '',
        );
        final service = NovelActionsService(
          appDb,
          seedScreenplayWorkspace: (_, _) async {},
        );

        final id = await service.createImportedScreenplay(
          title: '原著',
          sourceContent: '第一行\n第二行',
        );

        final screenplay = await appDb.novelDao.get(id);
        expect(screenplay?.title, '原著 (2)');
        expect(screenplay?.contentKind, contentKindScreenplay);
        final contentDb = NovelContentDatabase(
          screenplay!.contentDatabasePath!,
        );
        addTearDown(contentDb.close);
        final materials = await (contentDb.select(
          contentDb.documents,
        )..where((row) => row.type.equals(documentTypeMaterial))).get();
        expect(materials, hasLength(1));
        expect(materials.single.title, '原著');
        expect(materials.single.content, '第一行\n第二行');
      },
    );

    test(
      'keeps a duplicate-title draft out of the shelf when publishing conflicts',
      () async {
        await appDb.novelDao.create(
          id: 'shelf_novel',
          title: '同名作品',
          description: '',
        );
        await appDb.novelDao.create(
          id: 'draft_novel',
          title: '同名作品',
          description: '',
          draft: true,
        );
        final service = NovelActionsService(appDb);

        await expectLater(
          service.clearNovelDraft('draft_novel'),
          throwsA(
            isA<NovelTitleConflictException>().having(
              (error) => error.title,
              'title',
              '同名作品',
            ),
          ),
        );

        final draft = await appDb.novelDao.get('draft_novel');
        expect(draft?.draft, isTrue);
      },
    );

    test(
      'source novel supports adaptation, sequel, fanfic, and derivative',
      () async {
        await appDb.novelDao.create(
          id: 'source_work',
          title: '来源小说',
          description: '',
        );

        for (final type in sourceLinkedNovelTypes) {
          final id = 'target_$type';
          await appDb.novelDao.create(
            id: id,
            title: type,
            description: '',
            type: type,
            sourceNovelId: 'source_work',
          );
          expect((await appDb.novelDao.get(id))?.sourceNovelId, 'source_work');
        }
      },
    );

    test(
      'source novel rejects independent, self, and cyclic relationships',
      () async {
        await appDb.novelDao.create(
          id: 'source_a',
          title: 'A',
          description: '',
        );
        await appDb.novelDao.create(
          id: 'source_b',
          title: 'B',
          description: '',
          type: novelTypeSequel,
          sourceNovelId: 'source_a',
        );

        await expectLater(
          appDb.novelDao.create(
            id: 'independent',
            title: '独立作品',
            description: '',
            sourceNovelId: 'source_a',
          ),
          throwsArgumentError,
        );
        await expectLater(
          appDb.novelDao.create(
            id: 'self_source',
            title: '自引用',
            description: '',
            type: novelTypeSequel,
            sourceNovelId: 'self_source',
          ),
          throwsArgumentError,
        );

        final sourceA = (await appDb.novelDao.get('source_a'))!;
        final service = NovelActionsService(appDb);
        await expectLater(
          service.updateNovel(
            novel: sourceA,
            title: sourceA.title,
            description: sourceA.description,
            type: novelTypeSequel,
            updateSourceNovel: true,
            sourceNovelId: 'source_b',
            coverSourcePath: null,
            removeCover: false,
          ),
          throwsArgumentError,
        );
        final unchanged = await appDb.novelDao.get('source_a');
        expect(unchanged?.type, novelTypeOriginal);
        expect(unchanged?.sourceNovelId, isNull);
      },
    );

    test(
      'createNovel initializes workspace without a default chapter',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'reveric_novel_create_test_',
        );
        addTearDown(() async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('plugins.flutter.io/path_provider'),
                null,
              );
          await NovelContentDatabase.closeAllCached();
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async {
                if (call.method == 'getApplicationSupportDirectory') {
                  return tempDir.path;
                }
                return null;
              },
            );
        // 内容库路径现以相对路径存储，工厂打开时需 resolve 相对当前根 —
        // 生产环境由 main() 初始化，测试里在 mock path_provider 后手动初始化。
        await RevericPaths.initialize();

        final service = NovelActionsService(appDb);
        final novelId = await service.createNovel(
          title: 'Create Test',
          authorName: 'Test Author',
          description: '',
        );
        expect(novelId, matches(RegExp(r'^nov_[A-Z0-9]{6}$')));
        expect(novelId, hasLength(10));
        final novel = await appDb.novelDao.get(novelId);
        expect(novel, isNotNull);
        expect(novel!.authorName, 'Test Author');
        expect(novel.contentDatabasePath, isNotEmpty);

        await service.updateNovel(
          novel: novel,
          title: novel.title,
          authorName: 'Updated Test Author',
          description: novel.description,
          coverSourcePath: null,
          removeCover: false,
        );
        final updatedNovel = await appDb.novelDao.get(novelId);
        expect(updatedNovel?.authorName, 'Updated Test Author');

        final contentDb = NovelContentDatabase(novel.contentDatabasePath!);
        addTearDown(contentDb.close);

        expect(await contentDb.chapterDao.getAll(), isEmpty);
        expect(await contentDb.select(contentDb.outlines).get(), isEmpty);
      },
    );

    test(
      'createNovel atomically initializes a screenplay season and episode',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'reveric_screenplay_create_test_',
        );
        addTearDown(() async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('plugins.flutter.io/path_provider'),
                null,
              );
          await NovelContentDatabase.closeAllCached();
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async => call.method == 'getApplicationSupportDirectory'
                  ? tempDir.path
                  : null,
            );
        await RevericPaths.initialize();
        await appDb.novelDao.create(
          id: 'source_novel',
          title: 'Source Novel',
          description: '',
        );
        final service = NovelActionsService(appDb);

        final id = await service.createNovel(
          title: 'Screenplay Create',
          description: '',
          type: novelTypeAdaptation,
          contentKind: contentKindScreenplay,
          sourceNovelId: 'source_novel',
          plannedEpisodeCount: 12,
        );
        expect(id, startsWith('scr_'));
        expect(id, matches(RegExp(r'^scr_[A-Z0-9]{6}$')));
        expect(id, hasLength(10));

        final novel = await appDb.novelDao.get(id);
        expect(novel, isNotNull);
        expect(novel!.contentKind, contentKindScreenplay);
        expect(novel.type, novelTypeAdaptation);
        expect(novel.sourceNovelId, 'source_novel');
        expect(novel.draft, isFalse);
        expect(novel.contentDatabasePath, isNotEmpty);

        final contentDb = NovelContentDatabase(novel.contentDatabasePath!);
        addTearDown(contentDb.close);
        final root = await contentDb.screenplayDao.getRoot();
        expect(root, isNotNull);
        expect(root!.styleId, 'preset:premium-costume-drama');
        final seasons = await contentDb.screenplayDao.getSeasons(root.id);
        expect(seasons, hasLength(1));
        expect(seasons.single.seasonNumber, 1);
        expect(seasons.single.plannedEpisodeCount, 12);
        final episodes = await contentDb.screenplayDao.getEpisodes(
          seasons.single.id,
        );
        expect(episodes, hasLength(1));
        expect(episodes.single.episodeNumber, 1);

        final draftId = await service.createNovel(
          title: 'Draft Screenplay',
          description: '',
          contentKind: contentKindScreenplay,
          draft: true,
        );
        expect((await appDb.novelDao.get(draftId))?.draft, isTrue);
      },
    );

    test(
      'screenplay creation persists one style and metadata edits preserve user choice',
      () async {
        await _configureTemporaryStorage('screenplay_default_style');
        final service = NovelActionsService(appDb);
        for (final entry in [
          (category: '都市', tags: <String>[], expected: 'cn-urban-realism'),
          (category: '都市', tags: ['武侠'], expected: 'eastern-wuxia-poetic'),
          (category: '都市', tags: ['武侠', '3D'], expected: 'semi-real-cg'),
          (category: '未知分类', tags: ['穿越'], expected: 'premium-costume-drama'),
        ]) {
          final id = await service.createNovel(
            title: 'Style ${entry.expected}',
            description: '',
            contentKind: contentKindScreenplay,
            category: entry.category,
            tags: entry.tags,
          );
          final novel = (await appDb.novelDao.get(id))!;
          final db = NovelContentDatabase(novel.contentDatabasePath!);
          try {
            final root = (await db.screenplayDao.getRoot())!;
            expect(root.styleId, 'preset:${entry.expected}');
            await (db.update(
              db.screenplays,
            )..where((row) => row.id.equals(root.id))).write(
              const ScreenplaysCompanion(styleId: Value('preset:pixel-art')),
            );
            await service.updateNovelMetadata(
              novelId: id,
              category: '宫斗',
              tags: ['水墨'],
            );
            expect(
              (await db.screenplayDao.getRoot())!.styleId,
              'preset:pixel-art',
            );
            await (db.update(db.screenplays)
                  ..where((row) => row.id.equals(root.id)))
                .write(const ScreenplaysCompanion(styleId: Value(null)));
            await service.updateNovelMetadata(novelId: id, tags: ['3D']);
            expect((await db.screenplayDao.getRoot())!.styleId, isNull);
          } finally {
            await db.close();
          }
        }
      },
    );

    test(
      'createNovel registers the work only after its content database exists',
      () async {
        final tempDir = await _configureTemporaryStorage('create_order');
        final service = NovelActionsService(appDb);

        final novelId = await service.createNovel(
          title: 'Ordered Screenplay',
          description: '',
          contentKind: contentKindScreenplay,
        );

        final novel = await appDb.novelDao.get(novelId);
        expect(novel, isNotNull);
        expect(novel!.draft, isFalse);
        expect(novel.contentDatabasePath, 'novel_workspaces/$novelId.sqlite');
        expect(
          await File(
            p.join(tempDir.path, 'novel_workspaces', '$novelId.sqlite'),
          ).exists(),
          isTrue,
        );
      },
    );

    test(
      'createNovel removes the content database when registering the work fails',
      () async {
        final tempDir = await _configureTemporaryStorage('register_failure');
        await appDb.customStatement('''
CREATE TRIGGER fail_screenplay_insert
BEFORE INSERT ON novels
WHEN NEW.content_kind = 'screenplay'
BEGIN
  SELECT RAISE(ABORT, 'forced screenplay insert failure');
END;
''');
        final service = NovelActionsService(appDb);

        await expectLater(
          service.createNovel(
            title: 'Failed Screenplay',
            description: '',
            contentKind: contentKindScreenplay,
          ),
          throwsA(isA<Exception>()),
        );

        await _expectUnregisteredCreation(appDb, 'Failed Screenplay', tempDir);
      },
    );

    test(
      'createNovel leaves nothing behind when opening the content database fails',
      () async {
        final tempDir = await _configureTemporaryStorage(
          'screenplay_open_failure',
        );
        final original = StateError('forced content database open failure');
        final service = NovelActionsService(
          appDb,

          contentDatabaseFactory: (_) => throw original,
        );

        await expectLater(
          service.createNovel(
            title: 'Open Failure',
            description: '',
            contentKind: contentKindScreenplay,
          ),
          throwsA(same(original)),
        );

        await _expectUnregisteredCreation(appDb, 'Open Failure', tempDir);
      },
    );

    test(
      'createNovel leaves nothing behind when seeding a novel fails',
      () async {
        final tempDir = await _configureTemporaryStorage('novel_seed_failure');
        final original = StateError('forced novel seed failure');
        var closeCount = 0;
        final service = NovelActionsService(
          appDb,

          seedNovelWorkspace: (_) => throw original,
          closeContentDatabase: (database) async {
            closeCount += 1;
            await database.close();
          },
        );

        await expectLater(
          service.createNovel(title: 'Seed Failure', description: ''),
          throwsA(same(original)),
        );

        expect(closeCount, 1);
        await _expectUnregisteredCreation(appDb, 'Seed Failure', tempDir);
      },
    );

    test(
      'createNovel leaves nothing behind when populating content fails',
      () async {
        final tempDir = await _configureTemporaryStorage('populate_failure');
        final original = StateError('forced populate failure');
        final service = NovelActionsService(appDb);

        await expectLater(
          service.createNovel(
            title: 'Populate Failure',
            description: '',
            populateContent: (_) => throw original,
          ),
          throwsA(same(original)),
        );

        await _expectUnregisteredCreation(appDb, 'Populate Failure', tempDir);
      },
    );

    test(
      'createNovel leaves nothing behind when the screenplay root transaction fails',
      () async {
        final tempDir = await _configureTemporaryStorage(
          'screenplay_root_failure',
        );
        final original = StateError('forced screenplay root failure');
        var closeCount = 0;
        final service = NovelActionsService(
          appDb,

          seedScreenplayWorkspace: (_, _) => throw original,
          closeContentDatabase: (database) async {
            closeCount += 1;
            await database.close();
          },
        );

        await expectLater(
          service.createNovel(
            title: 'Root Failure',
            description: '',
            contentKind: contentKindScreenplay,
          ),
          throwsA(same(original)),
        );

        expect(closeCount, 1);
        await _expectUnregisteredCreation(appDb, 'Root Failure', tempDir);
      },
    );

    test(
      'createNovel leaves nothing behind when closing the content database fails',
      () async {
        final tempDir = await _configureTemporaryStorage(
          'screenplay_close_failure',
        );
        final original = StateError('forced content database close failure');
        var closeCount = 0;
        final service = NovelActionsService(
          appDb,

          closeContentDatabase: (_) {
            closeCount += 1;
            throw original;
          },
        );

        await expectLater(
          service.createNovel(
            title: 'Close Failure',
            description: '',
            contentKind: contentKindScreenplay,
          ),
          throwsA(same(original)),
        );

        expect(closeCount, 1);
        await _expectUnregisteredCreation(appDb, 'Close Failure', tempDir);
      },
    );

    test(
      'keeps sibling metadata when AI updates title and tags concurrently',
      () async {
        await appDb.novelDao.create(
          id: 'novel_metadata_race',
          title: '未命名作品',
          description: '简介',
          category: '游戏',
          tags: const ['旧标签'],
        );
        final service = NovelActionsService(appDb);

        await Future.wait([
          service.updateNovelMetadata(
            novelId: 'novel_metadata_race',
            title: '重生开服：从零杀回巅峰',
          ),
          service.updateNovelMetadata(
            novelId: 'novel_metadata_race',
            tags: const ['爽文', '热血'],
          ),
        ]);

        final updated = await appDb.novelDao.get('novel_metadata_race');
        expect(updated?.title, '重生开服：从零杀回巅峰');
        expect(updated?.tags, const ['爽文', '热血']);
      },
    );

    test(
      'does not match database paths from a previous support root',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'reveric_legacy_workspace_path_test_',
        );
        addTearDown(() async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('plugins.flutter.io/path_provider'),
                null,
              );
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async {
                if (call.method == 'getApplicationSupportDirectory') {
                  return tempDir.path;
                }
                return null;
              },
            );
        await RevericPaths.initialize();

        final relativePath =
            'novel_workspaces${Platform.pathSeparator}legacy.sqlite';
        final currentPath =
            '${tempDir.path}${Platform.pathSeparator}$relativePath';
        await File(currentPath).parent.create(recursive: true);
        await File(currentPath).create();
        const legacyStoredPath =
            '/previous-container/novel_workspaces/legacy.sqlite';
        await appDb.novelDao.create(
          id: 'legacy_workspace_novel',
          title: 'Legacy workspace',
          description: '',
          contentDatabasePath: legacyStoredPath,
        );

        final service = NovelActionsService(appDb);

        final novel = await service.getNovelByContentDatabasePath(currentPath);

        expect(novel, isNull);
      },
    );

    test(
      'deleteNovel closes cached content database but keeps files',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'reveric_novel_delete_test_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final databasePath =
            '${tempDir.path}${Platform.pathSeparator}novel.sqlite';
        final coverPath = '${tempDir.path}${Platform.pathSeparator}cover.png';
        await File(coverPath).writeAsBytes(const [1, 2, 3]);
        final contentDb = NovelContentDatabase(databasePath);
        await contentDb.seedDefaultWorkspace();
        expect(NovelContentDatabase.isCachedForTesting(databasePath), isTrue);
        expect(await File(databasePath).exists(), isTrue);
        expect(await File(coverPath).exists(), isTrue);

        await appDb.novelDao.create(
          id: 'novel_delete_test',
          title: 'Delete Test',
          description: '',
          coverAssetId: coverPath,
          contentDatabasePath: databasePath,
        );
        final novel = await appDb.novelDao.get('novel_delete_test');
        expect(novel, isNotNull);

        final service = NovelActionsService(appDb);
        await service.deleteNovel(novel!);

        expect(NovelContentDatabase.isCachedForTesting(databasePath), isFalse);
        expect(await File(databasePath).exists(), isTrue);
        expect(await File(coverPath).exists(), isTrue);
        expect(await appDb.novelDao.get('novel_delete_test'), isNull);
      },
    );

    test(
      'deleteNovel uses work ID to stop chat even when stored and supplied paths differ',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'reveric_delete_running_',
        );
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(appDb),

            aiSettingsProvider.overrideWithValue(AiSettings.defaults()),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await NovelContentDatabase.closeAllCached();
          await temp.delete(recursive: true);
        });
        final path = p.join(temp.path, 'content.sqlite');
        final content = container.read(novelContentDatabaseProvider(path));
        await content.seedDefaultWorkspace();
        await appDb.novelDao.create(
          id: 'work',
          title: 'Fixture',
          description: '',
          contentDatabasePath: p.join(temp.path, 'stored-content.sqlite'),
        );
        await appDb.aiChatSessionDao.upsert(
          id: 'running',
          novelId: 'work',
          title: 'Fixture',
        );
        final provider = aiChatRuntimeProvider('running');
        final runtime = container.read(provider.notifier);
        final request = runtime.startRequest();
        final other = container.read(aiChatRuntimeProvider('other').notifier);
        final otherRequest = other.startRequest();
        final stopped = Completer<void>();
        final subscription = container.listen(provider, (_, next) {
          if (!next.isRequestInFlight && !stopped.isCompleted) {
            stopped.complete();
          }
        });
        addTearDown(subscription.close);
        var deleted = false;
        final deletion = container
            .read(novelActionsProvider)
            .deleteNovel(
              (await appDb.novelDao.get(
                'work',
              ))!.copyWith(contentDatabasePath: Value(path)),
            )
            .then((_) => deleted = true);
        await Future.any([
          stopped.future,
          deletion.then(
            (_) => throw StateError('Deleted before cancelling active chat'),
          ),
        ]).timeout(const Duration(seconds: 3));
        expect(deleted, isFalse);
        expect(await appDb.novelDao.get('work'), isNotNull);
        expect(
          (await content.customSelect('SELECT 1 AS n').getSingle()).read<int>(
            'n',
          ),
          1,
        );
        expect(
          container.read(aiChatRuntimeProvider('other')).isRequestInFlight,
          isTrue,
        );
        runtime.markRequestIdle(request, notifyOnComplete: false);
        await deletion;
        expect(await appDb.novelDao.get('work'), isNull);
        expect(NovelContentDatabase.isCachedForTesting(path), isFalse);
        other.markRequestIdle(otherRequest, notifyOnComplete: false);
      },
    );

    for (final withOverlay in [false, true]) {
      test(
        'deleteNovel through provider closes initialized '
        '${withOverlay ? 'overlay' : 'content'} dependencies and keeps files',
        () async {
          final tempDir = await Directory.systemTemp.createTemp(
            'reveric_novel_provider_delete_test_',
          );
          final container = ProviderContainer(
            overrides: [appDatabaseProvider.overrideWithValue(appDb)],
          );
          addTearDown(() async {
            container.dispose();
            await NovelContentDatabase.closeAllCached();
            await tempDir.delete(recursive: true);
          });

          final databasePath = p.join(tempDir.path, 'novel.sqlite');
          final otherPath = p.join(tempDir.path, 'other.sqlite');
          await container
              .read(novelContentDatabaseProvider(databasePath))
              .seedDefaultWorkspace();
          final otherDatabase = container.read(
            novelContentDatabaseProvider(otherPath),
          );
          await otherDatabase.seedDefaultWorkspace();
          await appDb.novelDao.create(
            id: 'provider_delete_test',
            title: 'Provider Delete Test',
            description: '',
            contentDatabasePath: databasePath,
          );
          final novel = (await appDb.novelDao.get('provider_delete_test'))!;

          // 保留真实依赖图，在 autoDispose 回收之前发起删除。
          container.read(novelContentServiceProvider(databasePath));
          if (withOverlay) {
            container.read(workingOverlayServiceProvider(databasePath));
          }
          expect(NovelContentDatabase.isCachedForTesting(databasePath), isTrue);
          await container.read(novelActionsProvider).deleteNovel(novel);

          expect(await appDb.novelDao.get(novel.id), isNull);
          expect(
            NovelContentDatabase.isCachedForTesting(databasePath),
            isFalse,
          );
          expect(
            container.exists(novelContentServiceProvider(databasePath)),
            isFalse,
          );
          expect(
            container.exists(workingOverlayServiceProvider(databasePath)),
            isFalse,
          );
          expect(await File(databasePath).exists(), isTrue);
          expect(NovelContentDatabase.isCachedForTesting(otherPath), isTrue);
          expect(
            await otherDatabase.customSelect('SELECT 1').getSingle(),
            isNotNull,
          );
        },
      );
    }

    test(
      'updateNovel keeps image library assets when database update fails',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'reveric_novel_cover_update_failure_test_',
        );
        addTearDown(() async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('plugins.flutter.io/path_provider'),
                null,
              );
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async {
                if (call.method == 'getApplicationSupportDirectory') {
                  return tempDir.path;
                }
                return null;
              },
            );
        await RevericPaths.initialize();

        final oldCoverDir = Directory(p.join(tempDir.path, 'novel_covers'));
        await oldCoverDir.create(recursive: true);
        final oldCover = File(p.join(oldCoverDir.path, 'old.png'));
        final imagesDir = Directory(
          p.join(
            tempDir.path,
            'file_workspaces',
            'novel_cover_failure',
            'images',
          ),
        );
        final sourceCover = File(p.join(tempDir.path, 'source.png'));
        await oldCover.writeAsBytes(const [1, 2, 3]);
        await sourceCover.writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
        );

        await appDb.novelDao.create(
          id: 'novel_cover_failure',
          title: 'Cover Failure',
          description: '',
          coverAssetId: 'novel_covers/old.png',
        );
        await appDb.customStatement('''
CREATE TRIGGER fail_novel_cover_update
BEFORE UPDATE ON novels
BEGIN
  SELECT RAISE(ABORT, 'forced update failure');
END;
''');
        final novel = await appDb.novelDao.get('novel_cover_failure');
        final service = NovelActionsService(
          appDb,
          imageLibraryService: buildImageLibraryService(appDb),
        );

        await expectLater(
          service.updateNovel(
            novel: novel!,
            title: novel.title,
            description: novel.description,
            coverSourcePath: sourceCover.path,
            removeCover: false,
          ),
          throwsA(isA<Exception>()),
        );

        expect(await oldCover.exists(), isTrue);
        final storedCoverNames = await imagesDir
            .list()
            .where((entity) => entity is File)
            .map((entity) => p.basename(entity.path))
            .toSet();
        expect(storedCoverNames.length, 1);
        expect(
          (await appDb.novelDao.get(novel.id))?.coverAssetId,
          'novel_covers/old.png',
        );
        expect(await sourceCover.exists(), isTrue);
      },
    );

    test(
      'deleteNovel moves the work to the trash and keeps its sessions and resources for restore',
      () async {
        await appDb.novelDao.create(
          id: 'novel_delete_resources',
          title: 'Delete Resources',
          description: '',
        );
        await appDb.novelDao.create(
          id: 'novel_keep_resources',
          title: 'Keep Resources',
          description: '',
        );

        await appDb.aiChatSessionDao.upsert(
          id: 'session_delete',
          novelId: 'novel_delete_resources',
          title: 'Delete session',
        );
        await appDb.aiChatSessionDao.upsert(
          id: 'child_session_delete',
          novelId: 'novel_delete_resources',
          title: 'Child session',
          parentId: 'session_delete',
        );
        await appDb.aiChatSessionDao.upsert(
          id: 'session_keep',
          novelId: 'novel_keep_resources',
          title: 'Keep session',
        );

        await appDb.globalAgentDao.upsert(
          GlobalAgent(
            id: 'agent_delete',
            scope: agentScopeNovel,
            novelId: 'novel_delete_resources',
            slug: 'delete-agent',
            name: 'Delete Agent',
            description: '',
            prompt: '',
            category: '',
            mode: 'chat',
            enabled: true,
            useCustomPrompt: false,
            sortOrder: 0,
            allowedToolNames: const [],
            ignoredSkillNames: const [],
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            deletedAt: notDeletedSentinel,
          ),
        );
        await appDb.globalAgentDao.upsert(
          GlobalAgent(
            id: 'agent_global',
            scope: agentScopeGlobal,
            novelId: '',
            slug: 'global-agent',
            name: 'Global Agent',
            description: '',
            prompt: '',
            category: '',
            mode: 'chat',
            enabled: true,
            useCustomPrompt: false,
            sortOrder: 0,
            allowedToolNames: const [],
            ignoredSkillNames: const [],
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            deletedAt: notDeletedSentinel,
          ),
        );

        // NovelAgentSkill 现为应用级全局技能（无 novelId 字段），删除任意小说都
        // 不应影响全局技能，见下方 deleteNovel 后的 getAll() 断言。
        await appDb.novelAgentSkillDao.upsert(
          NovelAgentSkillsCompanion.insert(
            id: 'skill_global_a',
            sourceKind: agentSkillSourceKindNovelLocal,
            name: 'global-skill-a',
            description: '',
            prompt: '',
            createdAt: Value(DateTime.now()),
            updatedAt: Value(DateTime.now()),
          ),
        );
        await appDb.novelAgentSkillDao.upsert(
          NovelAgentSkillsCompanion.insert(
            id: 'skill_global_b',
            sourceKind: agentSkillSourceKindNovelLocal,
            name: 'global-skill-b',
            description: '',
            prompt: '',
            createdAt: Value(DateTime.now()),
            updatedAt: Value(DateTime.now()),
          ),
        );

        await appDb
            .into(appDb.aiUsages)
            .insert(
              AiUsagesCompanion.insert(
                id: 'usage_delete_by_novel',
                providerId: 'provider',
                model: 'model',

                novelId: const Value('novel_delete_resources'),
              ),
            );
        await appDb
            .into(appDb.aiUsages)
            .insert(
              AiUsagesCompanion.insert(
                id: 'usage_delete_by_session',
                providerId: 'provider',
                model: 'model',

                sessionId: const Value('session_delete'),
              ),
            );
        await appDb
            .into(appDb.aiUsages)
            .insert(
              AiUsagesCompanion.insert(
                id: 'usage_keep',
                providerId: 'provider',
                model: 'model',

                novelId: const Value('novel_keep_resources'),
                sessionId: const Value('session_keep'),
              ),
            );
        await appDb
            .into(appDb.todos)
            .insert(
              TodosCompanion.insert(
                id: 'todo_delete',
                content: 'delete',
                sessionId: 'session_delete',
              ),
            );
        await appDb
            .into(appDb.todos)
            .insert(
              TodosCompanion.insert(
                id: 'todo_keep',
                content: 'keep',
                sessionId: 'session_keep',
              ),
            );

        final novel = await appDb.novelDao.get('novel_delete_resources');
        expect(novel, isNotNull);

        final service = NovelActionsService(appDb);
        await service.deleteNovel(novel!);

        expect(await appDb.novelDao.get('novel_delete_resources'), isNull);
        expect(
          await appDb.novelDao.getDeleted('novel_delete_resources'),
          isNotNull,
        );
        for (final id in ['session_delete', 'child_session_delete']) {
          expect(await appDb.aiChatSessionDao.getById(id), isNotNull);
        }
        expect(
          await appDb.globalAgentDao.getByScope(agentScopeNovel),
          hasLength(1),
        );
        expect(await appDb.novelAgentSkillDao.getAll(), hasLength(2));
        expect(await appDb.select(appDb.aiUsages).get(), hasLength(3));
        expect(await appDb.select(appDb.todos).get(), hasLength(2));
        expect(
          (await appDb.aiChatSessionDao.watchRecent(limit: 10).first).map(
            (s) => s.novelId,
          ),
          everyElement('novel_keep_resources'),
        );

        await service.restoreNovel('novel_delete_resources');
        expect(await appDb.novelDao.get('novel_delete_resources'), isNotNull);
        expect(
          await appDb.novelDao.getDeleted('novel_delete_resources'),
          isNull,
        );
        expect(
          (await appDb.aiChatSessionDao.watchRecent(limit: 10).first).map(
            (s) => s.id,
          ),
          contains('session_delete'),
        );
      },
    );

    test(
      'restoreNovel rejects a shelf title already taken and keeps the work in the trash',
      () async {
        await appDb.novelDao.create(id: 'old', title: '同名', description: '');
        final service = NovelActionsService(appDb);
        await service.deleteNovel((await appDb.novelDao.get('old'))!);
        await appDb.novelDao.create(id: 'new', title: '同名', description: '');

        await expectLater(
          service.restoreNovel('old'),
          throwsA(isA<NovelTitleConflictException>()),
        );
        expect(await appDb.novelDao.getDeleted('old'), isNotNull);

        await appDb.novelDao.updateMetadata(id: 'new', title: '新名');
        await service.restoreNovel('old');
        expect(await appDb.novelDao.get('old'), isNotNull);
      },
    );

    test(
      'createNovel writes novel_onboarding=eligible by default for new novels',
      () async {
        // 意图：正常新建小说路径必须写入 novel_onboarding=eligible，
        // setup_phase 引导依赖此状态判断是否展示。
        final tempDir = await Directory.systemTemp.createTemp(
          'reveric_novel_onboarding_default_',
        );
        addTearDown(() async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('plugins.flutter.io/path_provider'),
                null,
              );
          await NovelContentDatabase.closeAllCached();
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async {
                if (call.method == 'getApplicationSupportDirectory') {
                  return tempDir.path;
                }
                return null;
              },
            );
        await RevericPaths.initialize();

        final service = NovelActionsService(appDb);
        final novelId = await service.createNovel(
          title: 'Onboarding Default',
          description: '',
        );
        final novel = await appDb.novelDao.get(novelId);
        expect(novel, isNotNull);

        final contentDb = NovelContentDatabase(novel!.contentDatabasePath!);
        addTearDown(contentDb.close);

        final state = await contentDb.novelStateDao.get('novel_onboarding');
        expect(state, isNotNull, reason: '正常新建小说必须写入 novel_onboarding 状态');
        expect(state!.status, 'eligible');
      },
    );

    test(
      'createNovel(setNovelOnboardingEligible: false) skips novel_onboarding state for imported novels',
      () async {
        // 意图：导入路径不应写入 novel_onboarding 状态，避免 setup_phase 引导打扰导入用户。
        final tempDir = await Directory.systemTemp.createTemp(
          'reveric_novel_onboarding_import_',
        );
        addTearDown(() async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('plugins.flutter.io/path_provider'),
                null,
              );
          await NovelContentDatabase.closeAllCached();
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async {
                if (call.method == 'getApplicationSupportDirectory') {
                  return tempDir.path;
                }
                return null;
              },
            );
        await RevericPaths.initialize();

        final service = NovelActionsService(appDb);
        final novelId = await service.createNovel(
          title: 'Onboarding Import Skip',
          description: '',
          setNovelOnboardingEligible: false,
        );
        final novel = await appDb.novelDao.get(novelId);
        expect(novel, isNotNull);

        final contentDb = NovelContentDatabase(novel!.contentDatabasePath!);
        addTearDown(contentDb.close);

        final state = await contentDb.novelStateDao.get('novel_onboarding');
        expect(state, isNull, reason: '导入路径不应写入 novel_onboarding 状态');
      },
    );
  });
}

Future<Directory> _configureTemporaryStorage(String prefix) async {
  final tempDir = await Directory.systemTemp.createTemp('reveric_${prefix}_');
  addTearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await NovelContentDatabase.closeAllCached();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => call.method == 'getApplicationSupportDirectory'
            ? tempDir.path
            : null,
      );
  await RevericPaths.initialize();
  return tempDir;
}

/// 创建失败后：作品没有登记（也不在回收站），刚建的内容库文件已删除。
Future<void> _expectUnregisteredCreation(
  AppDatabase database,
  String title,
  Directory tempDir,
) async {
  final rows = await (database.select(
    database.novels,
  )..where((table) => table.title.equals(title))).get();
  expect(rows, isEmpty);
  final workspaces = Directory(p.join(tempDir.path, 'novel_workspaces'));
  if (await workspaces.exists()) {
    expect(await workspaces.list().toList(), isEmpty);
  }
}

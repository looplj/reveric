// 职责: 测试 NovelActionsService — 作品创建、标题冲突、删除级联和封面文件保留行为。
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
      'createNovel soft-deletes screenplay metadata when finalization fails',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'reveric_screenplay_create_failure_test_',
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
        await appDb.customStatement('''
CREATE TRIGGER fail_screenplay_finalize
BEFORE UPDATE OF content_database_path ON novels
WHEN NEW.content_kind = 'screenplay'
BEGIN
  SELECT RAISE(ABORT, 'forced screenplay finalization failure');
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

        expect(await appDb.novelDao.getAll(), isEmpty);
        final rows = await (appDb.select(
          appDb.novels,
        )..where((table) => table.title.equals('Failed Screenplay'))).get();
        expect(rows, hasLength(1));
        expect(rows.single.deletedAt, isNot(notDeletedSentinel));
        expect(rows.single.contentDatabasePath, isNull);
        expect(rows.single.draft, isTrue);
      },
    );

    test(
      'createNovel compensates when opening the content database fails',
      () async {
        await _configureTemporaryStorage('screenplay_open_failure');
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

        await _expectSoftDeletedCreation(appDb, 'Open Failure');
      },
    );

    test('createNovel compensates when seeding a novel fails', () async {
      await _configureTemporaryStorage('novel_seed_failure');
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
      await _expectSoftDeletedCreation(appDb, 'Seed Failure');
    });

    test(
      'createNovel compensates when the screenplay root transaction fails',
      () async {
        await _configureTemporaryStorage('screenplay_root_failure');
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
        await _expectSoftDeletedCreation(appDb, 'Root Failure');
      },
    );

    test(
      'creation compensation does not replace the original failure',
      () async {
        await _configureTemporaryStorage('screenplay_compensation_failure');
        await appDb.customStatement('''
CREATE TRIGGER fail_creation_compensation
BEFORE UPDATE OF deleted_at ON novels
BEGIN
  SELECT RAISE(ABORT, 'forced compensation failure');
END;
''');
        final original = StateError('forced screenplay finalization failure');
        final service = NovelActionsService(
          appDb,

          finalizeScreenplayCreation:
              ({
                required id,
                required contentDatabasePath,
                required requestedDraft,
              }) => throw original,
        );

        await expectLater(
          service.createNovel(
            title: 'Compensation Failure',
            description: '',
            contentKind: contentKindScreenplay,
          ),
          throwsA(same(original)),
        );
      },
    );

    test(
      'createNovel compensates when closing the content database fails',
      () async {
        await _configureTemporaryStorage('screenplay_close_failure');
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
        await _expectSoftDeletedCreation(appDb, 'Close Failure');
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
      'deleteNovel removes AI chat sessions and novel-scoped resources but keeps usage history',
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
        expect(await appDb.aiChatSessionDao.getById('session_delete'), isNull);
        expect(
          await appDb.aiChatSessionDao.getById('child_session_delete'),
          isNull,
        );
        expect(await appDb.aiChatSessionDao.getById('session_keep'), isNotNull);
        expect(await appDb.globalAgentDao.getByScope(agentScopeNovel), isEmpty);
        expect(
          await appDb.globalAgentDao.getByScope(agentScopeGlobal),
          hasLength(1),
        );
        // NovelAgentSkill 应用全局，novel 删除不做级联清理。
        expect(await appDb.novelAgentSkillDao.getAll(), hasLength(2));
        expect(
          await (appDb.select(appDb.aiUsages)..where(
                (table) => table.id.isIn([
                  'usage_delete_by_novel',
                  'usage_delete_by_session',
                  'usage_keep',
                ]),
              ))
              .get(),
          hasLength(3),
        );
        expect(
          await (appDb.select(
            appDb.todos,
          )..where((table) => table.id.equals('todo_delete'))).get(),
          isEmpty,
        );
        expect(
          await (appDb.select(
            appDb.todos,
          )..where((table) => table.id.equals('todo_keep'))).get(),
          hasLength(1),
        );
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

Future<void> _expectSoftDeletedCreation(
  AppDatabase database,
  String title,
) async {
  expect(await database.novelDao.getAll(), isEmpty);
  final rows = await (database.select(
    database.novels,
  )..where((table) => table.title.equals(title))).get();
  expect(rows, hasLength(1));
  expect(rows.single.deletedAt, isNot(notDeletedSentinel));
}

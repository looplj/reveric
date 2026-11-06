// 职责: 测试 TXT 作品导入 — 卷章解析、内容库写入与 Novel type 持久化。
// 关联文件:
//   lib/shared/services/novel_import.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/database/app_database.dart
//   lib/shared/database/novel_content_database.dart

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/novel_type.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/novel_import.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NovelImportService', () {
    late AppDatabase appDb;
    late NovelImportService service;

    setUp(() {
      appDb = AppDatabase.forTest(NativeDatabase.memory());
      service = NovelImportService(actions: NovelActionsService(appDb));
    });

    tearDown(() async {
      await appDb.close();
    });

    test('parses txt into volumes and chapters', () {
      final parsed = service.parseTxt('''
第一卷 风起

第一章 初见
少年走入山门。

第二章 夜雨
灯火未眠。

第二卷 云涌
第三章 归途
旧友重逢。
''', fallbackTitle: '长风');

      expect(parsed.suggestedTitle, '长风');
      expect(parsed.volumeCount, 2);
      expect(parsed.chapters, hasLength(3));
      expect(parsed.chapters[0].volumeTitle, '第一卷 风起');
      expect(parsed.chapters[0].title, '初见');
      expect(parsed.chapters[0].content, contains('少年走入山门'));
      expect(parsed.chapters[2].volumeTitle, '第二卷 云涌');
      expect(parsed.chapters[2].title, '归途');
    });

    test('returns no chapters when txt has no chapter headings', () {
      final parsed = service.parseTxt('只有正文，没有章节标题。', fallbackTitle: '资料');

      expect(parsed.volumeCount, 0);
      expect(parsed.chapters, isEmpty);
      expect(parsed.wordCount, 0);
    });

    test('strips the chapter number from the stored title', () {
      final parsed = service.parseTxt('''
第六章 炼药师
萧炎开始学习炼药。
''', fallbackTitle: '斗破苍穹');

      expect(parsed.chapters, hasLength(1));
      expect(parsed.chapters.single.title, '炼药师');
    });

    test('normalizes chapter titles by stripping 【】 annotations', () {
      final parsed = service.parseTxt('''
第一章 初见【第二更！】
少年走入山门。

第二章 夜雨
灯火未眠。
''', fallbackTitle: '测试');

      expect(parsed.chapters, hasLength(2));
      expect(parsed.chapters[0].title, '初见');
      expect(parsed.chapters[0].content, contains('少年走入山门'));
      expect(parsed.chapters[1].title, '夜雨');
    });

    test('deduplicates consecutive same-normalized-title chapter headings', () {
      final parsed = service.parseTxt('''
第四百六十九章 药帮韩闲【第二更！】

    第四百六十九章 药帮韩闲
萧炎踏入药帮大门。

第二百章 新篇
故事继续。
''', fallbackTitle: '测试');

      // Only 2 chapters: the duplicate 469 is folded into one.
      expect(parsed.chapters, hasLength(2));
      expect(parsed.chapters[0].title, '药帮韩闲');
      expect(parsed.chapters[1].title, '新篇');
    });

    test('skips empty-content chapters', () {
      final parsed = service.parseTxt('''
第一章 序
有内容。

第二章 空

第三章 终
有内容。
''', fallbackTitle: '测试');

      // Chapter 2 has no content between headings → skipped.
      expect(parsed.chapters, hasLength(2));
      expect(parsed.chapters[0].title, '序');
      expect(parsed.chapters[1].title, '终');
    });

    test('collapses multiple spaces in chapter titles', () {
      final parsed = service.parseTxt('''
第五百五十六章  分离【第三更！】

    第五百五十六章 分离

    第五百五十六章  分离
翎泉闭嘴。

第二百章 新篇
故事继续。
''', fallbackTitle: '测试');

      // The three identical 556 headings collapse into one.
      expect(parsed.chapters, hasLength(2));
      expect(parsed.chapters[0].title, '分离');
      expect(parsed.chapters[0].content, contains('翎泉闭嘴'));
      expect(parsed.chapters[1].title, '新篇');
    });

    test('does not merge non-consecutive chapters with same number', () {
      // Different content under the same chapter number should remain separate
      // when they are not consecutive duplicates.
      final parsed = service.parseTxt('''
第一章 场景一
内容A。

第二章 场景二
内容B。

第一章 场景一不同版本
内容C。
''', fallbackTitle: '测试');

      // The third chapter has a different normalized title, so it's kept.
      expect(parsed.chapters, hasLength(3));
      expect(parsed.chapters[2].title, '场景一不同版本');
    });
  });

  group('Novel import persistence', () {
    test(
      'replaces default chapter tree with imported volumes and chapters',
      () async {
        final db = NovelContentDatabase.forTest(NativeDatabase.memory());
        final contentService = NovelContentService(db);
        addTearDown(db.close);

        await db.seedDefaultWorkspace(includeInitialChapter: true);
        await contentService.replaceChaptersForImport(const [
          ImportedChapterNode(
            volumeTitle: '第一卷 风起',
            title: '第一章 初见',
            content: '少年走入山门。',
          ),
          ImportedChapterNode(
            volumeTitle: '第一卷 风起',
            title: '第二章 夜雨',
            content: '灯火未眠。',
          ),
          ImportedChapterNode(title: '番外 云外', content: '后来。'),
        ]);

        final nodes = await contentService.getChapters();
        expect(nodes.map((node) => node.type), [
          nodeTypeVolume,
          nodeTypeChapter,
          nodeTypeChapter,
          nodeTypeChapter,
        ]);
        expect(nodes[0].title, '第一卷 风起');
        expect(nodes[1].parentId, nodes[0].id);
        expect(nodes[2].parentId, nodes[0].id);
        expect(nodes[3].parentId, isNull);
        expect(nodes[1].content, '少年走入山门。');
      },
    );

    test('persists novel type on the app database', () async {
      final appDb = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(appDb.close);

      await appDb.novelDao.create(
        id: 'novel_1',
        title: '旧梦续',
        description: '',
        type: novelTypeSequel,
      );

      final novel = await appDb.novelDao.get('novel_1');
      expect(novel, isNotNull);
      expect(novel!.type, novelTypeSequel);
    });

    test('imports txt into created novel content database', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'reveric_import_success_test_',
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

      final appDb = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(appDb.close);

      final txtFile = File('${tempDir.path}${Platform.pathSeparator}novel.txt');
      await txtFile.writeAsString('''
第一章 初见
少年走入山门。

第二章 夜雨
灯火未眠。
''');

      final service = NovelImportService(actions: NovelActionsService(appDb));
      final result = await service.importTxt(
        filePath: txtFile.path,
        title: '成功导入',
        description: '',
        category: '',
        type: novelTypeOriginal,
        tags: const [],
      );

      final novel = await appDb.novelDao.get(result.novelId);
      expect(novel, isNotNull);
      expect(novel!.contentDatabasePath, isNotEmpty);

      final contentDb = NovelContentDatabase(novel.contentDatabasePath!);
      addTearDown(contentDb.close);
      final contentService = NovelContentService(contentDb);
      final chapters = await contentService.getChapters();

      expect(chapters, hasLength(2));
      expect(chapters.map((chapter) => chapter.title), ['初见', '夜雨']);
      expect(chapters.first.content, contains('少年走入山门'));
      expect(chapters.every((chapter) => chapter.wordCount > 0), isTrue);
      expect(
        novel.wordCount,
        chapters.fold<int>(0, (sum, chapter) => sum + chapter.wordCount),
      );
    });

    test('rolls back created novel when chapter import fails', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'reveric_import_rollback_test_',
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

      final appDb = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(appDb.close);

      final txtFile = File('${tempDir.path}${Platform.pathSeparator}novel.txt');
      await txtFile.writeAsString('第一章 初见\n少年走入山门。');

      final service = NovelImportService(
        actions: NovelActionsService(appDb),
        chapterImporter: (_, _) async {
          throw StateError('simulated import failure');
        },
      );

      await expectLater(
        service.importTxt(
          filePath: txtFile.path,
          title: '失败导入',
          description: '',
          category: '',
          type: novelTypeOriginal,
          tags: const [],
        ),
        throwsA(isA<StateError>()),
      );

      final novels = await appDb.select(appDb.novels).get();
      expect(novels, isEmpty);
    });
  });
}

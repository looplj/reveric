// 职责: 验证 Grep / Glob 能覆盖构思画布与制作画布中的文本内容和节点路径。
// 关联文件:
//   lib/shared/services/ai/tools_grep.dart
//   lib/shared/services/ai/tools_glob.dart
//   lib/shared/services/ai/tools_resource_search_support.dart
//   lib/shared/services/ai/tools_production_schema.dart

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/app_config.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/services/ai/media/production.dart';
import 'package:reveric/shared/services/ai/tool_operations.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/editing/sessions.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/production/audio_service.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/image_service.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/result_service.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/services/working_overlay.dart';

void main() {
  group('ideation canvas search', () {
    late NovelContentDatabase db;
    late AppDatabase appDb;
    late NovelContentService contentService;
    late AiToolManager tools;

    setUp(() {
      db = NovelContentDatabase.forTest(NativeDatabase.memory());
      appDb = AppDatabase.forTest(NativeDatabase.memory());
      contentService = NovelContentService(db);
      tools = AiToolManager(
        contentService,
        workingOverlayService: WorkingOverlayService(
          db,
          contentService,
          novelActionsService: NovelActionsService(appDb),
        ),
      )..registerAllTools();
    });

    tearDown(() async {
      await db.close();
      await appDb.close();
    });

    Future<Map<String, dynamic>> exec(
      String name,
      Map<String, dynamic> input,
    ) async {
      final result = await tools.executeTool(name: name, input: input);
      jsonEncode(result);
      return result;
    }

    Future<({String sticky, String reference})> seed() async {
      await contentService.canvasService.createCanvas(name: '灵感板');
      final characterId = await contentService.createCharacterProfile(
        defaultName: '林默',
      );
      final sticky = await exec('Create', {
        'path': 'canvas/灵感板/nodes',
        'fields': {
          'type': 'sticky',
          'title': '第三幕',
          'content': '开场\n林默在雨夜回到旧宅。',
        },
      });
      expect(sticky['ok'], isTrue, reason: '$sticky');
      final reference = await exec('Create', {
        'path': 'canvas/灵感板/nodes',
        'fields': {
          'type': 'reference',
          'ref_type': 'character',
          'ref_id': characterId,
        },
      });
      expect(reference['ok'], isTrue, reason: '$reference');
      return (
        sticky: sticky['id'] as String,
        reference: reference['id'] as String,
      );
    }

    test('Grep finds sticky note content and title on a canvas', () async {
      final ids = await seed();

      final byContent = await exec('Grep', {
        'pattern': '林默',
        'path': '/canvas',
      });
      expect(byContent['ok'], isTrue, reason: '$byContent');
      expect(
        byContent['text'],
        contains('canvas/灵感板/nodes/${ids.sticky}/content:2:林默在雨夜回到旧宅。'),
      );
      expect(byContent['hint'], isNull);

      final byTitle = await exec('Grep', {
        'pattern': '第三幕',
        'path': 'canvas/灵感板/nodes',
      });
      expect(
        byTitle['text'],
        contains('canvas/灵感板/nodes/${ids.sticky}/title:1:第三幕'),
      );
    });

    test('Grep skips content on reference nodes instead of failing', () async {
      final ids = await seed();

      final result = await exec('Grep', {
        'pattern': '不存在的词',
        'path': 'canvas/灵感板/nodes/${ids.reference}',
      });
      expect(result['ok'], isTrue, reason: '$result');
      expect(result['error'], isNull);
      expect(result['text'], 'No results found.');
    });

    test('Glob lists ideation canvas nodes relative to path', () async {
      final ids = await seed();

      final result = await exec('Glob', {
        'path': 'canvas/灵感板/nodes',
        'pattern': '*',
      });
      expect(
        result['matches'],
        unorderedEquals([
          'canvas/灵感板/nodes/${ids.sticky}',
          'canvas/灵感板/nodes/${ids.reference}',
        ]),
      );
      expect(result['hint'], isNull);
    });
  }, skip: !ideationCanvasEnabled);

  group('production canvas search', () {
    late Directory root;
    late NovelContentDatabase db;
    late AppDatabase app;
    late AiToolManager tools;
    late EditingSessions sessions;
    late ToolOperationManager operations;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('canvas_search_test_');
      db = NovelContentDatabase.forTest(NativeDatabase.memory());
      app = AppDatabase.forTest(NativeDatabase.memory());
      await ScreenplayService(db).createCanvasStructure();
      await app.novelDao.create(
        id: 'work',
        title: 'Canvas',
        description: '',
        contentKind: contentKindCanvas,
        contentDatabasePath: db.filePath,
      );
      final canvas = ProductionCanvasService(
        StoryboardService(db, contentKind: contentKindCanvas),
        MediaLibraryService(app, MediaService(FfmpegRunner()), root),
        'work',
      );
      final content = NovelContentService(db);
      sessions = EditingSessions();
      operations = ToolOperationManager(
        ownerSessionId: 'session',
        registry: ToolOperationRegistry(),
        gate: () => throw StateError('No external permission gate expected'),
        onChanged: (_) {},
        onRecord: (_) {},
      );
      final host = ProductionToolHost(
        canvas: canvas,
        images: _Images(),
        audio: _Audio(),
        video: () => throw StateError('No video provider expected'),
        results: _Results(),
        editingSessions: sessions,
      );
      tools = AiToolManager(
        content,
        workingOverlayService: WorkingOverlayService(
          db,
          content,
          novelActionsService: NovelActionsService(app),
        ),
        novelReader: () async => {
          'title': 'Canvas',
          'author_name': 'Tester',
          'description': '',
          'category': '',
          'status': 'in_progress',
          'tags': <String>[],
        },
        contentKind: contentKindCanvas,
        workId: 'work',
        sessionId: 'session',
        operationHost: ToolOperationHost(
          operations,
          production: () async => host,
        ),
        productionStyleServiceBuilder: () async => canvas,
      )..registerAllTools();
    });

    tearDown(() async {
      tools.dispose();
      operations.dispose();
      sessions.dispose();
      await db.close();
      await app.close();
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    Future<Map<String, dynamic>> exec(
      String name,
      Map<String, dynamic> input,
    ) async {
      final result = await tools.executeTool(
        name: name,
        input: input,
        context: ToolExecutionContext(
          sessionId: 'session',
          sourceSessionId: 'session',
          sourceTurnId: 'turn',
        ),
      );
      jsonEncode(result);
      return result;
    }

    Future<({String text, String video, String clip})> seed() async {
      final text = await exec('Create', {
        'path': 'production/canvas/nodes',
        'fields': {'type': 'text', 'title': '人物设定', 'content': '开场\n林默推开旧宅的门。'},
      });
      expect(text['ok'], isTrue, reason: '$text');
      final video = await exec('Create', {
        'path': 'production/canvas/nodes',
        'fields': {'type': 'video', 'title': '主镜头'},
      });
      expect(video['ok'], isTrue, reason: '$video');
      final clip = video['ref_id'] as String;
      final written = await exec('Write', {
        'path': 'production/clips/$clip',
        'fields': {'title': '雨夜追逐', 'prompt': '镜头跟随林默穿过雨巷。'},
      });
      expect(written['ok'], isTrue, reason: '$written');
      return (
        text: text['id'] as String,
        video: video['id'] as String,
        clip: clip,
      );
    }

    test('Grep finds text node content under production/canvas', () async {
      final ids = await seed();

      final result = await exec('Grep', {
        'pattern': '林默',
        'path': 'production/canvas',
      });
      expect(result['ok'], isTrue, reason: '$result');
      expect(
        result['text'],
        contains('production/canvas/nodes/${ids.text}/content:2:林默推开旧宅的门。'),
      );
      expect(result['searched_files'], greaterThan(0));

      // Clip nodes show the clip title, so the clip rename replaces the
      // node's original title.
      final byTitle = await exec('Grep', {
        'pattern': '雨夜追逐',
        'path': 'production/canvas/nodes',
      });
      expect(
        byTitle['text'],
        contains('production/canvas/nodes/${ids.video}/title:1:雨夜追逐'),
      );
    });

    test('Grep finds clip title and prompt under production', () async {
      final ids = await seed();

      final title = await exec('Grep', {
        'pattern': '雨夜追逐',
        'path': 'production',
      });
      expect(
        title['text'],
        contains('production/clips/${ids.clip}/title:1:雨夜追逐'),
      );

      final prompt = await exec('Grep', {
        'pattern': '雨巷',
        'path': 'production/clips',
      });
      expect(
        prompt['text'],
        contains('production/clips/${ids.clip}/prompt:1:镜头跟随林默穿过雨巷。'),
      );
    });

    test('Glob lists production canvas nodes relative to path', () async {
      final ids = await seed();

      final result = await exec('Glob', {
        'path': 'production/canvas/nodes',
        'pattern': '*',
      });
      expect(
        result['matches'],
        unorderedEquals([
          'production/canvas/nodes/${ids.text}',
          'production/canvas/nodes/${ids.video}',
        ]),
      );
      expect(result['total'], 2);
    });

    test('Grep without searchable fields returns a Read hint', () async {
      await seed();

      final result = await exec('Grep', {
        'pattern': '林默',
        'path': 'production/settings',
      });
      expect(result['ok'], isTrue, reason: '$result');
      expect(result['text'], 'No results found.');
      expect(result['searched_files'], 0);
      expect(result['hint'], contains('Read production/settings'));
    });

    test(
      'Grep distinguishes a glob that excludes existing text fields',
      () async {
        await seed();
        final result = await exec('Grep', {
          'path': 'production/clips',
          'glob': '*/unknown_field',
          'pattern': '雨巷',
        });
        expect(result['searched_files'], 0);
        expect(result['hint'], contains('Broaden or remove the glob'));
        final retry = await exec('Grep', {
          'path': 'production/clips',
          'pattern': '雨巷',
        });
        expect(retry['text'], contains('雨巷'));
      },
    );

    test('Glob on a path without listable children returns a hint', () async {
      await seed();

      final result = await exec('Glob', {
        'path': 'production/settings/ratio',
        'pattern': '*',
      });
      expect(result['ok'], isTrue, reason: '$result');
      expect(result['matches'], isEmpty);
      expect(result['hint'], contains('Read production/settings/ratio'));
    });
  });
}

class _Images implements ImageTaskService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Audio implements AudioTaskService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Results implements ProductionResultService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

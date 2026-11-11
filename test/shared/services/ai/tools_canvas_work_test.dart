// 职责: 验证画布作品的 AI 资源隔离、文本输入、剪辑节点与 Run 契约。
// 关联文件:
//   lib/shared/services/ai/tools_production.dart
//   lib/shared/services/ai/tools_production_schema.dart
//   lib/shared/services/ai/media/editing.dart
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/ai/media/production.dart';
import 'package:reveric/shared/services/ai/tool_operations.dart';
import 'package:reveric/shared/services/editing/sessions.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/services/production/audio_service.dart';
import 'package:reveric/shared/services/production/image_service.dart';
import 'package:reveric/shared/services/production/result_service.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NovelContentDatabase db;
  late AppDatabase app;
  late AiToolManager tools;
  late ProductionCanvasService canvas;
  late EditingSessions sessions;
  late ToolOperationManager operations;
  Future<Map<String, dynamic>> call(
    String tool,
    String path, [
    Map<String, dynamic>? fields,
  ]) async {
    final result = await tools.executeTool(
      name: tool,
      input: {'path': path, 'fields': ?fields},
      context: ToolExecutionContext(
        sessionId: 'session',
        sourceSessionId: 'session',
        sourceTurnId: 'turn',
      ),
    );
    jsonEncode(result);
    return result;
  }

  Future<Map<String, dynamic>> run(
    String command,
    String action,
    Map<String, dynamic> options,
  ) async {
    final result = await tools.executeTool(
      name: 'Run',
      input: {'command': command, 'subcommand': action, 'options': options},
      context: ToolExecutionContext(
        sessionId: 'session',
        sourceSessionId: 'session',
        sourceTurnId: 'turn',
      ),
    );
    jsonEncode(result);
    return result;
  }

  setUp(() async {
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
    canvas = ProductionCanvasService(
      StoryboardService(db, contentKind: contentKindCanvas),
      MediaLibraryService(
        app,
        MediaService(FfmpegRunner()),
        Directory.systemTemp,
      ),
      'work',
    );
    final content = NovelContentService(db);
    final overlay = WorkingOverlayService(
      db,
      content,
      novelActionsService: NovelActionsService(app),
    );
    sessions = EditingSessions();
    operations = ToolOperationManager(
      ownerSessionId: 'session',
      registry: ToolOperationRegistry(),
      gate: () => throw StateError('No model or file access expected'),
      onChanged: (_) {},
      onRecord: (_) {},
    );
    final host = ProductionToolHost(
      canvas: canvas,
      images: _Images(),
      audio: _Audio(),
      video: () => throw StateError('No model calls'),
      results: _Results(),
      editingSessions: sessions,
    );
    tools = AiToolManager(
      content,
      workingOverlayService: overlay,
      novelReader: () async => {
        'title': 'Canvas',
        'author_name': 'Ada',
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
  });

  test(
    'text Remove and remove_types clean only their downstream prompt references',
    () async {
      final path = 'production/canvas';
      final a = await call('Create', '$path/nodes', {
        'type': 'text',
        'content': 'A',
      });
      final b = await call('Create', '$path/nodes', {
        'type': 'text',
        'content': 'B',
      });
      final target = await call('Create', '$path/nodes', {
        'type': 'image',
        'title': 'Kept',
      });
      expect(a['ok'], true, reason: '$a');
      expect(b['ok'], true, reason: '$b');
      expect(target['ok'], true, reason: '$target');
      final clipId = target['ref_id'] as String;
      const aTag = '<ref input_id="a" label="A" />';
      const bTag = '<ref input_id="b" label="B" />';
      final configured = await call('Write', 'production/clips/$clipId', {
        'prompt': 'Start $aTag/$bTag/$aTag end',
        'inputs': [
          {'id': 'a', 'ref_type': 'node', 'ref_id': a['id'], 'role': 'prompt'},
          {'id': 'b', 'ref_type': 'node', 'ref_id': b['id'], 'role': 'prompt'},
        ],
      });
      expect(configured['ok'], true, reason: '$configured');
      final removed = await call('Remove', '$path/nodes/${a['id']}');
      expect(removed['ok'], true, reason: '$removed');
      final shots = StoryboardService(db, contentKind: contentKindCanvas);
      var clip = (await shots.getShot(clipId))!;
      expect(clip.prompt, 'Start /$bTag/ end');
      expect(clip.inputs.map((input) => input.id), ['b']);
      final batched = await call('Write', path, {
        'remove_types': ['text'],
      });
      expect(batched['ok'], true, reason: '$batched');
      jsonEncode(batched);
      clip = (await shots.getShot(clipId))!;
      expect(clip.prompt, 'Start // end');
      expect(clip.inputs, isEmpty);
      expect(clip.title, 'Kept');
      expect(await db.canvasDao.getNodeById(target['id'] as String), isNotNull);
      expect(await db.canvasDao.getNodeById(b['id'] as String), isNull);
    },
  );

  test(
    'root paths expose profile and production, and reject other shared collections',
    () async {
      final root = await call('Read', '/works/work');
      expect((root['entries'] as List).map((entry) => entry['path']), [
        '/works/work/production',
        '/works/work/profile',
      ]);
      final profile = await call('Read', 'profile');
      expect(profile['title'], 'Canvas');
      expect(profile['author_name'], 'Ada');
      expect(profile.containsKey('word_count'), isFalse);
      for (final path in [
        'story_state',
        'foreshadowing',
        'skills',
        'factions',
        'creatures',
        'lore',
        'materials',
        'relations',
        'characters',
        'locations',
        'items',
        'canvas',
        'chapters',
        'volumes',
        'outlines',
        'screenplay',
        'episodes',
        'seasons',
        'scenes',
        'clips',
      ]) {
        expect((await call('Read', path))['error'], isNotNull, reason: path);
      }
      expect(
        pathSchemaFieldNotes(kind: contentKindCanvas),
        contains('profile'),
      );
      expect(
        pathSchemaFieldNotes(kind: contentKindCanvas),
        isNot(contains('story_state')),
      );
      final schema = await call('Read', '/_schema/production');
      final encoded = jsonEncode(schema);
      for (final field in [
        'episode_id',
        'scene_id',
        'sort_order',
        'is_storyboard',
        'character_id',
        'location_id',
        'item_id',
      ]) {
        expect(encoded, isNot(contains('"$field"')), reason: field);
      }
      expect(encoded, contains('prompt'));
      expect(encoded, contains('editing'));
      expect(
        (await call('Read', '/_schema/groups/canvas'))['contracts'],
        isNotEmpty,
      );
      final guide = pathSchema(kind: contentKindCanvas);
      expect(guide, contains('production/clips/{clip_id}'));
      expect(guide, isNot(contains('chapters/{chapter_id}')));
    },
  );

  test(
    'settings, text and clips use canvas paths and retain prompt inputs',
    () async {
      expect(
        (await call('Write', 'production/settings', {'ratio': '9:16'}))['ok'],
        true,
      );
      expect(
        (await call('Read', 'production/settings/ratio'))['value'],
        '9:16',
      );
      final text = await call('Create', 'production/canvas/nodes', {
        'type': 'text',
        'title': 'Notes',
        'content': 'Shared prompt',
      });
      expect(text['ok'], true, reason: '$text');
      final textId = text['id'] as String;
      expect(
        (await call(
          'Read',
          'production/canvas/nodes/$textId/content',
        ))['value'],
        'Shared prompt',
      );
      final created = await call('Create', 'production/clips', {
        'title': 'Shot',
        'prompt': 'Action',
        'inputs': [
          {
            'id': 'prompt1',
            'ref_type': 'node',
            'ref_id': textId,
            'role': 'prompt',
          },
        ],
      });
      expect(created['ok'], true, reason: '$created');
      expect(created['path'], 'production/clips/${created['id']}');
      expect(created.containsKey('episode_id'), false);
      final clip = await canvas.shots.getShot(created['id'] as String);
      expect(clip!.episodeId, '');
      expect(clip.inputs.single.isPrompt, true);
      final listing = await call('Read', 'production/clips?kind=video');
      expect((listing['entries'] as List).single['id'], clip.id);
      expect(
        (await call(
          'Read',
          'production/clips/${clip.id}/generations',
        ))['entries'],
        isEmpty,
      );
      expect(
        (await call('Create', 'production/clips', {
          'episode_id': 'fake',
        }))['ignored_fields'],
        contains('episode_id'),
      );
      expect(
        (await call('Read', 'production/clips?episode_id=fake'))['error'],
        isNotNull,
      );
      expect(
        (await db.screenplayDao.getSeasons(
          (await db.screenplayDao.getRoot())!.id,
        )),
        isEmpty,
      );
    },
  );

  test(
    'editing resource and Run create projects with nodes and removal cascades',
    () async {
      final created = await call('Create', 'production/canvas/nodes', {
        'type': 'editing',
        'title': 'Version',
      });
      expect(created['ok'], true, reason: '$created');
      expect(
        (await db.editingDao.get(created['ref_id'] as String))!.title,
        'Version',
      );
      final renamed = await run('editing', 'apply', {
        'editing_id': created['ref_id'],
        'expected_revision': 0,
        'commands': [
          {'op': 'rename', 'title': 'Renamed project'},
        ],
      });
      expect(renamed['ok'], true, reason: '$renamed');
      expect(
        (await call(
          'Read',
          'production/canvas/nodes/${created['id']}',
        ))['title'],
        'Renamed project',
      );
      final result = await run('editing', 'create', {
        'title': 'Second',
        'ratio': '1:1',
      });
      expect(result['ok'], true, reason: '$result');
      final encoded = jsonEncode(result);
      expect(encoded, contains('node_id'));
      final nodes = await db.canvasDao.getNodesByCanvas(
        (await canvas.ensureCanvas('')).id,
      );
      expect(
        nodes.where((node) => node.type == canvasNodeTypeEditing),
        hasLength(2),
      );
      expect(
        (await call('Write', 'production/canvas', {
          'remove_types': ['editing'],
        }))['ok'],
        true,
      );
      expect(await db.editingDao.get(created['ref_id'] as String), isNull);
    },
  );

  test(
    'canvas Run help and invalid subcommands route to the canvas skill',
    () async {
      for (final command in ['production', 'styles', 'stagings']) {
        for (final result in [
          await run('help', command, {}),
          await run(command, '', {}),
          await run(command, 'unknown', {}),
        ]) {
          expect(result['output'], contains('画布作品工具'));
          expect(result['output'], isNot(contains('剧本工具使用规范')));
        }
      }
      expect((await run('help', '', {}))['output'], contains('画布作品工具'));
      expect((await run('help', 'editing', {}))['output'], contains('媒体处理与剪辑'));
    },
  );

  test(
    'staging commands are available, subject generation is rejected',
    () async {
      final unknown = await run('stagings', 'not-a-staging-action', {});
      expect(unknown['output'], contains('unknown stagings command'));
      expect(unknown['output'], contains('画布作品工具'));
      expect(unknown['output'], isNot(contains('剧本工具使用规范')));
      expect((await run('stagings', 'list', {}))['ok'], true);
      expect(
        (await run('character', 'generate-avatar', {
          'character': 'fake',
          'prompt': 'portrait',
        }))['ok'],
        false,
      );
    },
  );
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

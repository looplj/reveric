// 职责: 验证画布作品的 AI 资源隔离、文本输入、剪辑节点与 Run 契约。
// 关联文件:
//   lib/shared/services/ai/tools_production.dart
//   lib/shared/services/ai/tools_production_schema.dart
//   lib/shared/services/ai/media/editing.dart
import 'dart:convert';
import 'dart:io';
import 'package:reveric/shared/services/image_library_service.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/production/image_request.dart';
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

import '../../../helpers/resource_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
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

  test(
    'text node Edit replaces exact content without changing layout',
    () async {
      final created = await call('Create', 'production/canvas/nodes', {
        'type': 'text',
        'title': 'Script',
        'content': '开场\n角色回家。\n尾声',
        'x': 1400,
        'y': 320,
      });
      expect(created['ok'], true, reason: '$created');
      final id = created['id'] as String;
      final path = 'production/canvas/nodes/$id/content';
      final before = await canvas.requireNode(id);
      Future<Map<String, dynamic>> edit(
        String oldText,
        String newText, {
        bool all = false,
        String? target,
      }) async {
        final result = await tools.executeTool(
          name: 'Edit',
          input: {
            'path': target ?? path,
            'old_text': oldText,
            'new_text': newText,
            'all': all,
          },
        );
        jsonEncode(result);
        return result;
      }

      final changed = await edit('角色回家。', '角色出门。');
      expect(changed['ok'], true, reason: '$changed');
      expect(changed['edited'], true);
      expect(changed['match_count'], 1);
      final after = await canvas.requireNode(id);
      expect(after.content, '开场\n角色出门。\n尾声');
      expect(after.title, before.title);
      expect(
        (after.x, after.y, after.width, after.height, after.parentId),
        (before.x, before.y, before.width, before.height, before.parentId),
      );
      expect((await call('Read', path))['value'], after.content);

      final missing = await edit('不存在', '新内容');
      expect(missing['error_code'], 'failed_precondition');
      expect((await canvas.requireNode(id)).content, after.content);
      final unchanged = await edit('角色出门。', '角色出门。');
      expect(unchanged['edited'], false);

      expect((await edit('角色出门。', '雨声，雨声'))['ok'], true);
      expect((await edit('雨声', '风声'))['error_code'], 'invalid_argument');
      expect((await canvas.requireNode(id)).content, '开场\n雨声，雨声\n尾声');
      final multiple = await edit('雨声', '风声', all: true);
      expect(multiple['ok'], true, reason: '$multiple');
      expect(multiple['match_count'], 2);
      expect((await canvas.requireNode(id)).content, '开场\n风声，风声\n尾声');

      final empty = await call('Create', 'production/canvas/nodes', {
        'type': 'text',
      });
      final initialized = await edit(
        '',
        '正文',
        target: 'production/canvas/nodes/${empty['id']}/content',
      );
      expect(initialized['ok'], true, reason: '$initialized');
      expect((await canvas.requireNode(empty['id'] as String)).content, '正文');
      final video = await call('Create', 'production/canvas/nodes', {
        'type': 'video',
      });
      final rejected = await edit(
        '',
        '正文',
        target: 'production/canvas/nodes/${video['id']}/content',
      );
      expect(rejected['ok'], false);
      expect(
        (await canvas.requireNode(video['id'] as String)).content,
        isEmpty,
      );
    },
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp("canvas-tools-");
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
      MediaLibraryService(app, MediaService(FfmpegRunner()), root),
      'work',
    );
    final content = NovelContentService(
      db,
      imageLibraryService: ImageLibraryService(app, () => canvas.library),
    );
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
    await root.delete(recursive: true);
  });

  test(
    'clip summary is opt-in and keeps filtering, paging and full prompts',
    () async {
      final prompt = List.filled(3000, 'Saved prompt.').join();
      for (var i = 0; i < 3; i++) {
        await call('Create', 'production/clips', {
          'kind': 'image',
          'title': 'Target $i',
          'prompt': prompt,
        });
      }
      await call('Create', 'production/clips', {
        'kind': 'video',
        'title': 'Other',
        'prompt': 'Other prompt',
      });
      final full = await call('Read', 'production/clips?kind=image');
      expect(await call('Read', 'production/clips?kind=image&view=full'), full);
      final first = await tools.executeTool(
        name: 'Read',
        input: {'path': 'production/clips?kind=image&view=summary', 'limit': 2},
      );
      expect(first['ok'], true, reason: '$first');
      expect(first['total'], 3);
      expect(first['has_more'], true);
      for (final entry in first['entries'] as List) {
        expect(entry, isNot(contains('prompt')));
        expect(entry['kind'], 'image');
        final detail = await call('Read', entry['path'] as String);
        expect(detail['prompt'], prompt);
      }
      expect(jsonEncode(first).length, lessThan(jsonEncode(full).length ~/ 10));
      final last = await tools.executeTool(
        name: 'Read',
        input: {
          'path': 'production/clips?kind=image&view=summary',
          'offset': first['next_offset'],
          'limit': 2,
        },
      );
      expect(last['has_more'], false);
      expect(last['entries'], hasLength(1));
      expect(
        [
          ...first['entries'] as List,
          ...last['entries'] as List,
        ].map((entry) => entry['id']),
        (full['entries'] as List).map((entry) => entry['id']),
      );
      expect(
        (await call('Read', 'production/clips?view=unknown'))['error_code'],
        'invalid_argument',
      );
      expect(
        (await call('Read', 'production/clips?view='))['error_code'],
        'invalid_argument',
      );
    },
  );

  test(
    'generation pages omit snapshots while details preserve frozen inputs',
    () async {
      final clip = await call('Create', 'production/clips', {
        'kind': 'image',
        'title': 'History',
        'prompt': 'Current prompt',
      });
      final clipId = clip['id'] as String;
      final historyPath = 'production/clips/$clipId/generations';
      final frozen = ImageGenerationRequest(
        ProductionImageRequest(
          providerId: 'provider',
          modelId: 'model',
          originalPrompt: 'Saved prompt',
          prompt: List.filled(6000, 'Frozen input.').join(),
          ratio: '1:1',
          resolution: '1k',
          size: null,
          references: [
            const ProductionImageReference(
              assetId: 'saved-asset',
              inputId: 'reference',
            ),
          ],
        ),
      );
      final createdAt = DateTime(2026, 11, 15, 20);
      for (var i = 0; i < 3; i++) {
        await app
            .into(app.generationTasks)
            .insert(
              GenerationTasksCompanion.insert(
                id: 'history-$i',
                createdAt: Value(createdAt),
                novelId: 'work',
                sourceType: 'production_clip',
                sourceId: clipId,
                providerId: 'provider',
                providerType: 'openai',
                modelId: 'model',
                status: GenerationTaskStatus.completed,
                kind: GenerationKind.image,
                requestJson: frozen,
              ),
            );
      }
      final first = await tools.executeTool(
        name: 'Read',
        input: {'path': historyPath, 'limit': 2},
      );
      expect(first['ok'], isTrue);
      expect(first['total'], 3);
      expect(first['has_more'], isTrue);
      final entries = (first['entries'] as List).cast<Map>();
      expect(entries, hasLength(2));
      for (final entry in entries) {
        expect(entry, isNot(contains('request')));
        expect(entry['model_id'], 'model');
        expect(entry['created_at'], endsWith('Z'));
        expect(
          DateTime.parse(entry['created_at'] as String),
          createdAt.toUtc(),
        );
      }
      expect(jsonEncode(first).length, lessThan(8000));
      final second = await tools.executeTool(
        name: 'Read',
        input: {
          'path': historyPath,
          'limit': 2,
          'offset': first['next_offset'],
        },
      );
      expect(second['has_more'], isFalse);
      final last = (second['entries'] as List).single as Map;
      expect({
        ...entries.map((entry) => entry['id']),
        last['id'],
      }, hasLength(3));

      await call('Write', 'production/clips/$clipId', {
        'prompt': 'Changed afterwards',
      });
      final detail = await call('Read', entries.first['path'] as String);
      expect(detail['id'], entries.first['id']);
      expect(detail['request'], frozen.toJson());
      expect(
        (await call('Read', '${entries.first['path']}/request'))['value'],
        frozen.toJson(),
      );
      final missing = await call('Read', '$historyPath/missing');
      expect(missing['error_code'], 'not_found');
      final other = await call('Create', 'production/clips', {
        'kind': 'image',
        'title': 'Other',
      });
      expect(
        (await call(
          'Read',
          'production/clips/${other['id']}/generations/${entries.first['id']}',
        ))['error_code'],
        'not_found',
      );

      final contract = resourceContractTreeForTesting(
        '/_schema/production/clips/generations',
      );
      expect(contract['fields']['request']['listing'], isFalse);
      expect(contract['fields']['request']['detail'], isTrue);
      expect(contract['fields']['request']['read_path'], isTrue);
    },
  );

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
    'root paths expose characters, profile and production, and reject unrelated collections',
    () async {
      final root = await call('Read', '/works/work');
      expect((root['entries'] as List).map((entry) => entry['path']), [
        '/works/work/production',
        '/works/work/profile',
        '/works/work/characters',
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
      final schema = resourceContractTreeForTesting('/_schema/production');
      final encoded = jsonEncode(schema);
      for (final field in [
        'episode_id',
        'scene_id',
        'sort_order',
        'is_storyboard',
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

  test('canvas characters bind image nodes and voice inputs', () async {
    final temp = await Directory(
      '${root.path}/file_workspaces/work',
    ).create(recursive: true);
    try {
      for (final type in ['image', 'audio']) {
        final file = File(
          '${temp.path}/$type.${type == 'image' ? 'png' : 'wav'}',
        );
        await file.writeAsBytes([1, 2, 3]);
        await app.assetDao.insertAsset(
          AssetsCompanion.insert(
            id: type,
            type: type,
            name: Value(type),
            path: Value(file.path.substring(root.path.length + 1)),
            purpose: 'production_output',
            content: Value(
              type == 'image'
                  ? const ImageAssetContent(mimeType: 'image/png')
                  : const AudioAssetContent(mimeType: 'audio/wav'),
            ),
          ),
        );
      }
      final character = await call('Create', 'characters', {'name': 'Ada'});
      expect(character['ok'], true, reason: '$character');
      final id = character['id'] as String;
      final voices = [
        {'asset_id': 'audio', 'name': 'Ada voice'},
      ];
      final updated = await call('Write', 'characters/$id', {
        'voices': voices,
        'photos': [
          {'asset_id': 'image', 'name': 'Ada image'},
        ],
      });
      expect(updated['ok'], true, reason: '$updated');
      expect((await call('Read', 'characters/$id/voices'))['value'], voices);
      final image = await call('Create', 'production/clips', {
        'kind': 'image',
        'character_id': id,
      });
      expect(image['ok'], true, reason: '$image');
      expect(image['character_id'], id);
      final node = await call('Create', 'production/canvas/nodes', {
        'type': 'image',
        'ref_id': image['id'],
      });
      expect(node['ok'], true, reason: '$node');
      final adopted = await call('Write', 'production/clips/${image['id']}', {
        'adopted_asset_id': 'image',
      });
      expect(adopted['ok'], true, reason: '$adopted');
      final video = await call('Create', 'production/clips', {
        'kind': 'video',
        'inputs': [
          {
            'id': 'person',
            'ref_type': 'node',
            'ref_id': node['id'],
            'role': 'reference_image',
            'voice_asset_id': 'audio',
          },
        ],
      });
      expect(video['ok'], true, reason: '$video');
      final detail = await call('Read', 'production/clips/${video['id']}');
      expect((detail['inputs'] as List).single['voice_asset_id'], 'audio');
      final invalid = await call('Write', 'characters/$id', {
        'voices': [
          {'asset_id': 'image', 'name': 'Wrong type'},
        ],
      });
      expect(invalid['ok'], false);
      expect((await call('Read', 'characters/$id/voices'))['value'], voices);
      final nodeDetail = await call(
        'Read',
        'production/canvas/nodes/${node['id']}',
      );
      expect(nodeDetail['ref_id'], image['id']);
      for (final invalidVoices in [
        [
          ...voices,
          {'asset_id': 'audio', 'name': 'Conflicting name'},
        ],
        [
          {'asset_id': '', 'name': 'Empty'},
        ],
      ]) {
        expect(
          (await call('Write', 'characters/$id', {
            'voices': invalidVoices,
          }))['ok'],
          false,
        );
      }
      await File('${temp.path}/audio.wav').rename('${temp.path}/moved.wav');
      final unavailable = await call('Write', 'characters/$id', {
        'voices': [
          {'asset_id': 'audio', 'name': 'Renamed'},
        ],
      });
      expect(unavailable['error_code'], 'failed_precondition');
      expect((await call('Read', 'characters/$id/voices'))['value'], voices);
      final missing = await call('Create', 'production/clips', {
        'kind': 'image',
        'character_id': 'missing',
      });
      expect(missing['ok'], false);
    } finally {
      await temp.delete(recursive: true);
    }
  });

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

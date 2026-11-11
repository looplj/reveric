// 职责: 验证制片与导演工具的发现、路径、原子编辑、回合快照和 UI 同步边界。
// 关联文件:
//   lib/shared/services/ai/tools_production.dart
//   lib/shared/services/ai/stagings_run_command_handler.dart
//   lib/shared/services/screenplay/staging.dart
//   lib/shared/services/director/preview.dart
import 'dart:async';
import 'package:reveric/shared/app_config.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/agent/tool_result.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:reveric/shared/models/director/pose.dart';
import 'package:reveric/shared/models/director/presets.dart';
import 'package:reveric/shared/models/director/sampling.dart';
import 'package:reveric/shared/services/director/commands.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/director/document.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/ai/media/production.dart';
import 'package:reveric/shared/services/ai/tool_operations.dart';
import 'package:reveric/shared/services/director/preview.dart';
import 'package:reveric/shared/services/director/storage.dart';
import 'package:reveric/shared/services/director/renderer.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/screenplay/staging.dart';
import 'package:reveric/shared/services/screenplay/staging_edit.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/working_overlay.dart';

class PreviewContentService extends NovelContentService {
  PreviewContentService(super.database, this._staging);
  final StagingEditService _staging;
  @override
  StagingEditService get stagingEditService => _staging;
}

class PreviewRenderer implements FrameRenderer {
  PreviewRenderer({this.wait, this.fail = false, this.bytes});
  final Future<void>? wait;
  final bool fail;
  final Uint8List? bytes;
  final frames = <int>[];
  DirectorDocument? captured;
  int? frame;
  String? camera;
  bool disposed = false;
  final started = Completer<void>();
  @override
  Future<Uint8List> capture(
    DirectorDocument document,
    int frame,
    String cameraId,
  ) async {
    captured = document;
    this.frame = frame;
    frames.add(frame);
    camera = cameraId;
    if (!started.isCompleted) {
      started.complete();
    }
    await wait;
    if (fail) {
      throw StateError('capture failed');
    }
    return bytes ?? Uint8List.fromList([1, 2, 3]);
  }

  @override
  void dispose() => disposed = true;
}

void main() {
  late NovelContentDatabase db;
  late AppDatabase app;
  late AiToolManager tools;
  late String episode;
  late String canvasPath;
  var turnId = 'turn';
  late Directory previewDirectory;
  late StagingEditService stagingService;
  late PreviewRenderer Function() createRenderer;
  final renderers = <PreviewRenderer>[];
  Future<DirectorStorage> previewWorkspace(String id) async {
    final directory = Directory('${previewDirectory.path}/$id');
    await directory.create(recursive: true);
    return DirectorStorage(directory, previewDirectory);
  }

  setUp(() async {
    turnId = 'turn';
    renderers.clear();
    createRenderer = () => PreviewRenderer();
    previewDirectory = await Directory.systemTemp.createTemp(
      'staging-tool-preview-',
    );
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    app = AppDatabase.forTest(NativeDatabase.memory());
    episode = (await ScreenplayService(db).createInitialStructure()).episodeId;
    canvasPath = 'episodes/$episode/production/canvas';
    stagingService = StagingEditService(
      db,
      previewWorkspace: (id, {required novelId}) {
        expect(novelId, 'work');
        return previewWorkspace(id);
      },
      previewRenderer: () {
        final renderer = createRenderer();
        renderers.add(renderer);
        return renderer;
      },
    );
    final content = PreviewContentService(db, stagingService);
    final overlay = WorkingOverlayService(
      db,
      content,
      novelActionsService: NovelActionsService(app),
    );
    final operations = ToolOperationManager(
      ownerSessionId: 'session',
      registry: ToolOperationRegistry(),
      gate: () => throw StateError('No permission check expected'),
      onChanged: (_) {},
      onRecord: (_) {},
    );
    addTearDown(operations.dispose);
    tools = AiToolManager(
      content,
      workingOverlayService: overlay,
      contentKind: 'screenplay',
      sessionId: 'session',
      workId: 'work',
      operationHost: ToolOperationHost(operations),
      productionStyleServiceBuilder: () async => ProductionCanvasService(
        StoryboardService(db),
        MediaLibraryService(
          app,
          MediaService(FfmpegRunner()),
          previewDirectory,
        ),
        'work',
      ),
    )..registerAllTools();
  });
  tearDown(() async {
    await db.close();
    await app.close();
    await previewDirectory.delete(recursive: true);
  });
  Future<Map<String, dynamic>> call(
    String tool,
    String path, [
    Map<String, dynamic>? fields,
  ]) => tools.executeTool(
    name: tool,
    input: {'path': path, 'fields': ?fields},
    context: ToolExecutionContext(sourceTurnId: turnId),
  );
  Future<Map<String, dynamic>> director(
    String action,
    Map<String, dynamic> options,
  ) => tools.executeTool(
    name: 'Run',
    input: {'command': 'stagings', 'subcommand': action, 'options': options},
    context: ToolExecutionContext(sourceTurnId: turnId),
  );
  Future<Map<String, dynamic>> applyEdit(
    String stagingId,
    String collection,
    String op,
    Map<String, dynamic> fields,
  ) async {
    final result = await director('apply', {
      'staging_id': stagingId,
      'edits': [
        {'op': op, 'collection': collection, ...fields},
      ],
    });
    if (result['ok'] != true) {
      return result;
    }
    return {...result, 'id': (result['results'] as List).single['id']};
  }

  void ok(Map value) => expect(value['error_code'], isNull, reason: '$value');
  Map<String, dynamic> actor() => {
    'kind': 'actor',
    'name': 'Actor',
    'geometry_key': 'actor.male.v1',
    'position': [0, 0, 0],
    'rotation': [0, 0, 0, 1],
    'scale': [1, 1, 1],
    'pose': ActorPose.standing().toJson(),
    'visible': true,
    'color': '#B7A48B',
  };

  test(
    'text Remove and remove_types clean only their downstream prompt references',
    () async {
      final path = canvasPath;
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
      // This fixture has no media host; seed inputs before exercising AI deletion.
      final shots = StoryboardService(db);
      await shots.restoreInputs(clipId, [
        {'id': 'a', 'ref_type': 'node', 'ref_id': a['id'], 'role': 'prompt'},
        {'id': 'b', 'ref_type': 'node', 'ref_id': b['id'], 'role': 'prompt'},
      ]);
      await (db.update(
        db.productionClips,
      )..where((t) => t.id.equals(clipId))).write(
        const ProductionClipsCompanion(
          prompt: Value('Start $aTag/$bTag/$aTag end'),
        ),
      );
      final removed = await call('Remove', '$path/nodes/${a['id']}');
      expect(removed['ok'], true, reason: '$removed');
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
    'stagings normalizes plural IDs without advertising the alias',
    () async {
      final created = await director('create', {'title': 'Original'});
      ok(created);
      final id = created['id'];
      for (final includeCanonical in [false, true]) {
        final options = <String, dynamic>{
          'stagings_id': id,
          if (includeCanonical) 'staging_id': id,
          'commands': [
            {'op': 'set_title', 'title': 'Updated $includeCanonical'},
          ],
        };
        final originalOptions = jsonEncode(options);
        final updated = await director('apply', options);
        ok(updated);
        expect(updated['title'], 'Updated $includeCanonical');
        expect(jsonEncode(options), originalOptions);
        final read = await director('read', {'stagings_id': id});
        ok(read);
        expect(read['id'], id);
        expect(read['version'], updated['version']);
      }
      final help = await tools.executeTool(
        name: 'Run',
        input: {'command': 'help', 'subcommand': 'stagings'},
      );
      expect(help['output'], contains('剧本工具使用规范'));
      expect(help['output'], isNot(contains('stagings_id')));
    },
  );

  test(
    'stagings rejects conflicting IDs before editing either document',
    () async {
      final first = await director('create', {'title': 'First'});
      final second = await director('create', {'title': 'Second'});
      final result = await director('apply', {
        'staging_id': first['id'],
        'stagings_id': second['id'],
        'commands': [
          {'op': 'set_title', 'title': 'Must not be saved'},
        ],
      });
      expect(result['error_code'], 'invalid_argument');
      expect(
        result['error'],
        contains('staging_id and stagings_id must match'),
      );
      for (final before in [first, second]) {
        final after = await director('read', {'staging_id': before['id']});
        expect(after['document'], before['document']);
        expect(after['version'], before['version']);
      }
    },
  );

  test(
    'stagings keeps ID validation and reports unsupported options',
    () async {
      for (final value in [null, '', 42]) {
        final result = await director('read', {'stagings_id': value});
        expect(result['error_code'], 'invalid_argument');
        expect(result['error'], contains('staging_id is required'));
      }
      final result = await director('read', {'unexpected': true});
      expect(result['error_code'], 'invalid_argument');
      expect(result['error'], contains('Unknown command options: unexpected.'));
      expect(
        result['error'],
        contains('Allowed: staging_id, collection, id, frame.'),
      );
      final list = await director('list', {'stagings_id': 'unused'});
      expect(list['error_code'], 'invalid_argument');
      expect(list['error'], contains('Allowed: none.'));
    },
  );

  test(
    'Run discovers stagings commands while removed roots and commands fail',
    () async {
      final help = await tools.executeTool(
        name: 'Run',
        input: {'command': 'help', 'subcommand': 'stagings'},
      );
      expect(help['output'], contains('剧本工具使用规范'));
      expect(help['output'], isNot(contains('stagings apply:')));
      final oldCommand = await tools.executeTool(
        name: 'Run',
        input: {'command': 'director', 'subcommand': 'list'},
      );
      expect(oldCommand['error_code'], 'invalid_argument');
      for (final path in [
        '/assets',
        '/stagings',
        '/_schema/assets',
        '/_schema/stagings',
      ]) {
        final result = await call('Read', path);
        expect(result['error_code'], isNotNull, reason: '$path: $result');
      }
      final created = await director('create', {'title': 'Independent'});
      ok(created);
      expect(created, isNot(contains('path')));
      expect((await director('list', {}))['entries'], [
        {
          'id': created['id'],
          'title': 'Independent',
          'version': created['version'],
        },
      ]);
      final missing = await director('read', {'staging_id': 'missing'});
      expect(missing['error_code'], 'not_found');
      for (final options in [
        {'staging_id': created['id'], 'id': 'orphan'},
        {'staging_id': created['id'], 'collection': 'objects', 'frame': 0},
        {'staging_id': created['id'], 'collection': 'unknown'},
      ]) {
        expect(
          (await director('read', options))['error_code'],
          'invalid_argument',
        );
      }
      expect(
        (await director('restore', {
          'staging_id': created['id'],
          'version': -1,
        }))['error_code'],
        'invalid_argument',
      );
      final removed = await director('remove', {'staging_id': created['id']});
      ok(removed);
      expect((await director('list', {}))['entries'], isEmpty);
      expect(
        (await director('read', {'staging_id': created['id']}))['error_code'],
        'not_found',
      );
      final retained = await (db.select(
        db.videoStagings,
      )..where((t) => t.id.equals(created['id'] as String))).getSingle();
      expect(retained.deletedAt, isNot(notDeletedSentinel));
    },
  );

  test(
    'director rejects non-screenplay work and referenced document removal',
    () async {
      final node = await call('Create', '$canvasPath/nodes', {
        'type': 'staging',
      });
      ok(node);
      expect(
        (await director('remove', {
          'staging_id': node['ref_id'],
        }))['error_code'],
        'invalid_argument',
      );
      expect(
        await db.screenplayDao.getStaging(node['ref_id'] as String),
        isNotNull,
      );
      final novelTools = AiToolManager(
        PreviewContentService(db, stagingService),
        workingOverlayService: tools.workingOverlayService,
        contentKind: 'novel',
        operationHost: tools.operationHost,
      )..registerAllTools();
      addTearDown(novelTools.dispose);
      final result = await novelTools.executeTool(
        name: 'Run',
        input: {'command': 'stagings', 'subcommand': 'list'},
      );
      expect(result['error_code'], 'unavailable');
    },
  );

  test('preview uses explicit work ID without a database file path', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => previewDirectory.path,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await RevericPaths.initialize();
    final renderer = PreviewRenderer();
    final service = StagingEditService(db, previewRenderer: () => renderer);
    final staging = await service.create('Explicit owner');
    expect(db.filePath, ':memory:');

    await service.preview(staging.id, novelId: 'explicit-work');

    final file = File(
      p.join(
        previewDirectory.path,
        'file_workspaces',
        'explicit-work',
        'files',
        'director',
        'workspaces',
        staging.id,
        'preview.png',
      ),
    );
    expect(await file.readAsBytes(), [1, 2, 3]);
    expect(renderer.disposed, isTrue);
  });

  test(
    'explicit preview writes PNG for closed staging without modifying document, history, or overlay',
    () async {
      final staging = await director('create', {'title': 'Preview'});
      final id = staging['id'] as String;
      final before = (await db.screenplayDao.getStaging(id))!;
      final result = await tools.executeTool(
        name: 'Run',
        input: {
          'command': 'stagings',
          'subcommand': 'preview',
          'options': {'staging_id': id},
        },
      );
      ok(result);
      expect(result['updated'], isTrue);
      expect(result['id'], id);
      expect(await DirectorPreview(await previewWorkspace(id)).read(), [
        1,
        2,
        3,
      ]);
      expect(renderers.single.frame, 0);
      expect(renderers.single.camera, before.document!['cameras'][0]['id']);
      expect(renderers.single.disposed, isTrue);
      final after = (await db.screenplayDao.getStaging(id))!;
      expect(after.document, before.document);
      expect(after.version, before.version);
      expect(after.updatedAt, before.updatedAt);
      expect(await db.select(db.revisions).get(), isEmpty);
      expect(await db.select(db.workingChanges).get(), isEmpty);
      final invalid = await tools.executeTool(
        name: 'Run',
        input: {
          'command': 'stagings',
          'subcommand': 'preview',
          'options': {'staging_id': id, 'preview': false},
        },
      );
      expect(invalid['error_code'], isNotNull, reason: '$invalid');
      final rootWrite = await tools.executeTool(
        name: 'Run',
        input: {
          'command': 'stagings',
          'subcommand': 'apply',
          'options': {'staging_id': id, 'preview': true},
        },
      );
      expect(rootWrite['error_code'], 'invalid_argument', reason: '$rootWrite');
      expect(renderers, hasLength(1));
    },
  );

  test(
    'explicit preview reads after queued local saves and does not lock edits while rendering',
    () async {
      final row = await stagingService.create('Original');
      final binding = VideoStagingBinding(db.screenplayDao, row.id);
      final session = await binding.load(camera: 'Camera');
      addTearDown(() {
        binding.dispose();
        session.dispose();
      });
      final blockWrites = Completer<void>();
      final blocked = db.screenplayDao.serializeStaging(
        row.id,
        () => blockWrites.future,
      );
      session.history.execute((json) => json['title'] = 'Latest');
      final releaseRender = Completer<void>();
      final renderer = PreviewRenderer(wait: releaseRender.future);
      createRenderer = () => renderer;
      var completed = false;
      final operation = tools
          .executeTool(
            name: 'Run',
            input: {
              'command': 'stagings',
              'subcommand': 'preview',
              'options': {'staging_id': row.id},
            },
          )
          .then((result) {
            completed = true;
            return result;
          });
      blockWrites.complete();
      await blocked;
      await renderer.started.future;
      expect(renderer.captured!.title, 'Latest');
      expect(completed, isFalse);
      await stagingService.save(
        row.id,
        turnId: 'during-preview',
        title: 'Later',
      );
      expect((await stagingService.require(row.id)).title, 'Later');
      releaseRender.complete();
      ok(await operation);
      expect(await DirectorPreview(await previewWorkspace(row.id)).read(), [
        1,
        2,
        3,
      ]);
    },
  );

  test(
    'failed explicit preview reports failure, keeps last image, and disposes renderer',
    () async {
      final row = await stagingService.create('Preview');
      final cache = DirectorPreview(await previewWorkspace(row.id));
      await cache.write(Uint8List.fromList([8]));
      createRenderer = () => PreviewRenderer(fail: true);
      final result = await tools.executeTool(
        name: 'Run',
        input: {
          'command': 'stagings',
          'subcommand': 'preview',
          'options': {'staging_id': row.id},
        },
      );
      expect(result['error_code'], isNotNull);
      expect(result['updated'], isNot(true));
      expect(await cache.read(), [8]);
      expect(renderers.single.disposed, isTrue);
      expect(await db.select(db.revisions).get(), isEmpty);
    },
  );

  test('staging nodes persist unified types and reject old types', () async {
    ok(await call('Create', canvasPath));
    for (final fields in [
      {'type': 'director'},
      {'type': 'staging', 'ref_type': 'screenplay_staging'},
      {'type': 'staging', 'ref_type': 'video_staging'},
    ]) {
      final old = await call('Create', '$canvasPath/nodes', fields);
      expect(old['error_code'], 'invalid_argument');
    }
    expect(await db.select(db.videoStagings).get(), isEmpty);
    final created = await call('Create', '$canvasPath/nodes', {
      'type': 'staging',
      'ref_type': 'staging',
    });
    ok(created);
    expect(created['type'], 'staging');
    expect(created['ref_type'], 'staging');
    final stored = (await db.canvasDao.getNodeById(created['id'] as String))!;
    expect(stored.type, 'staging');
    expect(stored.refType, 'staging');
    expect(stored.stagingId, created['ref_id']);
    ok(await director('read', {'staging_id': stored.stagingId}));
    ok(
      await call('Write', canvasPath, {
        'remove_types': ['staging'],
      }),
    );
    expect(await db.canvasDao.getNodesByCanvas(stored.canvasId), isEmpty);
    ok(await director('read', {'staging_id': stored.stagingId}));
  });

  test('screenplay adds text content while rejecting editing nodes', () async {
    final existingProjects = (await db.editingDao.list())
        .map((row) => row.id)
        .toList();
    final text = await call('Create', '$canvasPath/nodes', {
      'type': 'text',
      'title': 'Notes',
      'content': 'Shared text',
    });
    ok(text);
    expect(
      (await call('Read', '$canvasPath/nodes/${text['id']}/content'))['value'],
      'Shared text',
    );
    ok(
      await call('Write', '$canvasPath/nodes/${text['id']}', {
        'content': 'Updated',
      }),
    );
    expect(
      (await db.canvasDao.getNodeById(text['id'] as String))!.content,
      'Updated',
    );
    expect(
      (await call('Create', '$canvasPath/nodes', {'type': 'editing'}))['error'],
      isNotNull,
    );
    expect((await db.editingDao.list()).map((row) => row.id), existingProjects);
  });

  test(
    'explicit production paths work without discovering hidden resources',
    () async {
      final created = await call('Create', canvasPath);
      ok(created);
      expect(created['updated'], isTrue);
      expect(created['id'], isNotNull);
      final video = await call('Create', '$canvasPath/nodes', {
        'type': 'video',
      });
      ok(video);
      expect(video['created'], isTrue);
      final directorNode = await call('Create', '$canvasPath/nodes', {
        'type': 'staging',
        'title': 'Set',
      });
      ok(directorNode);
      expect(video['ref_type'], canvasNodeRefTypeProductionClip);
      expect(directorNode['ref_type'], canvasNodeRefTypeStaging);
      expect(directorNode.containsKey('staging_id'), isFalse);
      final all = await call('Read', canvasPath);
      ok(all);
      expect(all['nodes'], hasLength(2));
      expect(all['edges'], isEmpty);
      final ideation = await call('Read', 'canvas');
      if (ideationCanvasEnabled) {
        expect(ideation['entries'], isEmpty);
      } else {
        expect(ideation['error'], isNotNull);
      }
      final glob = await tools.executeTool(
        name: 'Glob',
        input: {'pattern': 'episodes/**'},
      );
      ok(glob);
      expect(glob.toString(), isNot(contains('/production')));
      final root = await call('Read', '/works/work');
      ok(root);
      expect(root.toString(), isNot(contains('stagings')));
      final explicit = await director('read', {
        'staging_id': directorNode['ref_id'],
      });
      ok(explicit);
      expect(explicit['document']['output']['width'], 1280);
      final directory = await call('Read', 'episodes/$episode/production');
      ok(directory);
      expect(directory['id'], episode);
      expect(directory['canvas_path'], canvasPath);
      final productionId = await call(
        'Read',
        'episodes/$episode/production/id',
      );
      ok(productionId);
      expect(productionId['value'], episode);
      expect(productionId.containsKey('canvas_path'), isFalse);
    },
  );

  test('layout and removals roll back together on an invalid node', () async {
    final video = await call('Create', '$canvasPath/nodes', {'type': 'video'});
    ok(video);
    final nodeId = video['id'] as String;
    final before = (await db.canvasDao.getNodeById(nodeId))!;
    final invalid = await call('Write', canvasPath, {
      'positions': [
        {'id': nodeId, 'x': 100, 'y': 200},
        {'id': 'missing', 'x': 1, 'y': 2},
      ],
      'remove_types': ['video'],
    });
    expect(invalid['error_code'], isNotNull);
    expect((await db.canvasDao.getNodeById(nodeId))!.x, before.x);
    expect(
      await StoryboardService(db).getShot(video['ref_id'] as String),
      isNotNull,
    );
    final success = await call('Write', canvasPath, {
      'positions': [
        {'id': nodeId, 'x': 100, 'y': 200},
      ],
    });
    ok(success);
    expect(success['updated'], isTrue);
    expect((await db.canvasDao.getNodeById(nodeId))!.x, 100);
    final moved = await call('Write', '$canvasPath/nodes/$nodeId', {
      'x': 120,
      'y': 240,
    });
    ok(moved);
    expect(moved['updated'], isTrue);
    expect((await db.canvasDao.getNodeById(nodeId))!.x, 120);
    ok(
      await call('Write', canvasPath, {
        'remove_types': ['video'],
      }),
    );
    expect(await db.canvasDao.getNodeById(nodeId), isNull);
    expect(
      await StoryboardService(db).getShot(video['ref_id'] as String),
      isNull,
    );
  });

  test('canvas tools keep storyboard groups whole', () async {
    final cells = [
      for (var i = 0; i < 2; i++)
        await call('Create', '$canvasPath/nodes', {'type': 'image'}),
    ];
    cells.forEach(ok);
    final canvasId = (await db.canvasDao.getNodeById(
      cells.first['id'] as String,
    ))!.canvasId;
    final group = await ProductionGroupService(StoryboardService(db))
        .createStoryboard(
          canvasId,
          layout: const StoryboardGroupLayout(cols: 2, rows: 1),
          origin: const Offset(10, 20),
          memberIds: [for (final cell in cells) cell['id'] as String],
        );
    final member = await call('Read', '$canvasPath/nodes/${cells.last['id']}');
    ok(member);
    expect(member['parent_id'], group.id);
    final stuck = await call('Write', '$canvasPath/nodes/${cells.last['id']}', {
      'x': 999,
    });
    expect(stuck['error_code'], isNotNull);
    expect(stuck.toString(), contains('invalid_config'));
    ok(
      await call('Write', '$canvasPath/nodes/${group.id}', {'x': 110, 'y': 20}),
    );
    final moved = await db.canvasDao.getNodeById(cells.first['id'] as String);
    expect((moved!.x, moved.y), (110.0, 20.0));
    ok(await call('Remove', '$canvasPath/nodes/${group.id}'));
    for (final cell in cells) {
      expect(await db.canvasDao.getNodeById(cell['id'] as String), isNull);
      expect(
        await StoryboardService(db).getShot(cell['ref_id'] as String),
        isNull,
      );
    }
    final again = await ProductionGroupService(StoryboardService(db))
        .createStoryboard(
          canvasId,
          layout: const StoryboardGroupLayout(cols: 1, rows: 1),
          origin: Offset.zero,
          memberIds: [
            (await call('Create', '$canvasPath/nodes', {'type': 'image'}))['id']
                as String,
          ],
        );
    ok(
      await call('Write', canvasPath, {
        'remove_types': ['image'],
      }),
    );
    // 按类型删成员只留下空分组。
    expect((await db.canvasDao.getNodesByCanvas(canvasId)).map((n) => n.id), [
      again.id,
    ]);
  });

  test(
    'director elements and keyframes save atomically against latest content',
    () async {
      final staging = await director('create', {'title': 'Scene'});
      ok(staging);
      final base = staging['id'] as String;
      final object = await applyEdit(base, 'objects', 'create', {
        'data': actor(),
      });
      ok(object);
      final id = object['id'];
      ok(
        await applyEdit(base, 'objects', 'write', {
          'id': id,
          'data': {
            'position': [2, 0, 0],
          },
        }),
      );
      final invalid = await director('apply', {
        'staging_id': base,
        'edits': [
          {
            'op': 'write',
            'collection': 'objects',
            'id': id,
            'data': {
              'position': [3, 0, 0],
            },
          },
          {
            'op': 'write',
            'collection': 'cameras',
            'id': 'missing',
            'data': {'name': 'X'},
          },
        ],
      });
      expect(invalid['error_code'], isNotNull);
      final current = await director('read', {
        'staging_id': base,
        'collection': 'objects',
        'id': id,
      });
      ok(current);
      expect(current['data']['position'], [2, 0, 0]);
      expect((await director('read', {'staging_id': base}))['version'], 3);
      final track = await applyEdit(base, 'tracks', 'create', {
        'data': {
          'target_id': id,
          'property': 'position',
          'keys': [
            {
              'frame': 0,
              'value': [2, 0, 0],
              'easing': 'linear',
            },
            {
              'frame': 120,
              'value': [4, 0, 0],
              'easing': 'linear',
            },
          ],
        },
      });
      ok(track);
      final trackId = track['id'];
      ok(
        await applyEdit(base, 'tracks', 'create', {
          'id': trackId,
          'frame': 60,
          'data': {
            'value': [3, 0, 0],
            'easing': 'smoothstep',
          },
        }),
      );
      expect(
        (await director('read', {
          'staging_id': base,
          'collection': 'tracks',
          'id': trackId,
        }))['data']['keys'],
        hasLength(3),
      );
      ok(
        await applyEdit(base, 'tracks', 'remove', {'id': trackId, 'frame': 60}),
      );
      expect(
        (await director('read', {
          'staging_id': base,
          'collection': 'tracks',
          'id': trackId,
        }))['data']['keys'],
        hasLength(2),
      );
      final badRef = await applyEdit(base, 'tracks', 'create', {
        'data': {
          'target_id': 'missing',
          'property': 'pose',
          'keys': [
            {
              'frame': 24,
              'value': ActorPose.standing().toJson(),
              'easing': 'linear',
            },
          ],
        },
      });
      expect(badRef['error_code'], isNotNull);
      final removedAction = await applyEdit(base, 'action_clips', 'create', {
        'data': {},
      });
      expect(removedAction['error_code'], 'invalid_argument');
      expect((await director('read', {'staging_id': base}))['version'], 6);
      expect(await db.select(db.workingChanges).get(), isEmpty);
    },
  );

  test('staging edits accept nested and repeated resource IDs', () async {
    final created = await director('create', {'title': 'Resource identities'});
    ok(created);
    final base = created['id'] as String;
    const firstId = '11111111-1111-4111-8111-000000000001';
    const secondId = '11111111-1111-4111-8111-000000000002';
    final nestedData = {...actor(), 'id': firstId};
    final result = await director('apply', {
      'staging_id': base,
      'edits': [
        {'op': 'create', 'collection': 'objects', 'data': nestedData},
        {
          'op': 'create',
          'collection': 'objects',
          'id': secondId,
          'data': {...actor(), 'id': secondId},
        },
        {
          'op': 'write',
          'collection': 'objects',
          'data': {'id': firstId, 'name': 'Renamed'},
        },
      ],
    });
    ok(result);
    expect(result['results'].map((r) => r['id']), [firstId, secondId, firstId]);
    expect(result['document']['objects'][0]['name'], 'Renamed');
    expect(nestedData['id'], firstId);

    final camera = Map<String, dynamic>.from(created['document']['cameras'][0]);
    final cameraId = camera['id'];
    camera['name'] = 'Updated camera';
    ok(
      await applyEdit(base, 'cameras', 'write', {
        'id': cameraId,
        'data': camera,
      }),
    );
    final read = await director('read', {
      'staging_id': base,
      'collection': 'cameras',
      'id': cameraId,
    });
    expect(read['data']['id'], cameraId);
    expect(read['data']['name'], 'Updated camera');
    final missing = await applyEdit(base, 'cameras', 'write', {
      'data': {...camera, 'id': '33333333-3333-4333-8333-000000000001'},
    });
    expect(missing['error_code'], 'not_found');
  });

  test(
    'conflicting staging IDs reject the batch without saving earlier edits',
    () async {
      final created = await director('create', {
        'title': 'Conflicting identities',
      });
      ok(created);
      final base = created['id'] as String;
      final cameraId = created['document']['cameras'][0]['id'];
      for (final op in ['create', 'write', 'remove']) {
        final result = await director('apply', {
          'staging_id': base,
          'edits': [
            {
              'op': 'write',
              'collection': 'cameras',
              'id': cameraId,
              'data': {'name': 'Must not persist'},
            },
            {
              'op': op,
              'collection': 'objects',
              'id': '11111111-1111-4111-8111-000000000001',
              'data': {
                ...actor(),
                'id': '11111111-1111-4111-8111-000000000002',
              },
            },
          ],
        });
        expect(result['error_code'], 'invalid_argument');
        expect(result['error'], contains('id and data.id must match'));
        final current = await stagingService.require(base);
        expect(current.document, created['document']);
        expect(current.version, created['version']);
      }
    },
  );

  test(
    'apply preserves omitted collections and write requires a complete replacement',
    () async {
      final created = await director('create', {'title': 'Scene'});
      ok(created);
      final id = created['id'] as String;
      final added = await applyEdit(id, 'objects', 'create', {'data': actor()});
      ok(added);
      final animated = await director('apply', {
        'staging_id': id,
        'commands': [
          {
            'op': 'upsert_path',
            'data': {
              'target_id': added['id'],
              'kind': 'line',
              'start_frame': 0,
              'end_frame': 48,
              'easing': 'linear',
              'orient_to_path': false,
              'geometry': {
                'start': [0, 0, 0],
                'end': [2, 0, 0],
              },
            },
          },
          {
            'op': 'upsert_move',
            'data': {
              'camera_id': created['document']['default_camera_id'],
              'kind': 'dolly_in',
              'start_frame': 0,
              'end_frame': 48,
            },
          },
        ],
      });
      ok(animated);
      final output = {'width': 1280, 'height': 720, 'background': '#112233'};
      final updated = await director('apply', {
        'staging_id': id,
        'commands': [
          {'op': 'set_title', 'title': 'Updated'},
          {'op': 'set_duration', 'duration_frames': 240},
          {'op': 'set_output', 'output': output},
        ],
      });
      ok(updated);
      expect(updated['title'], 'Updated');
      expect(updated['document']['duration_frames'], 240);
      expect(updated['document']['output'], output);
      expect(updated['version'], animated['version'] + 1);
      for (final collection in ['objects', 'motion_paths', 'camera_moves']) {
        expect(
          updated['document'][collection],
          animated['document'][collection],
        );
      }
      final whole = cloneJson(updated['document']);
      final wrongApply = await director('apply', {
        'staging_id': id,
        'document': whole,
      });
      expect(wrongApply['error_code'], 'invalid_argument');
      expect(wrongApply['error'], contains('stagings write'));
      final oldTitle = await director('apply', {
        'staging_id': id,
        'title': 'Old',
      });
      expect(oldTitle['error_code'], 'invalid_argument');
      expect(oldTitle['error'], contains('set_title'));
      for (final options in <Json>[
        {'staging_id': id},
        {'staging_id': id, 'document': null},
        {'staging_id': id, 'document': <String, dynamic>{}},
        {
          'staging_id': id,
          'document': cloneJson(whole)..remove('motion_paths'),
        },
        {
          'staging_id': id,
          'document': cloneJson(whole)..remove('camera_moves'),
        },
        {
          'staging_id': id,
          'document': {...whole, 'id': created['id']},
        },
        {'staging_id': id, 'document': whole, 'edits': []},
        {'staging_id': id, 'document': whole, 'commands': []},
        {'staging_id': id, 'document': whole, 'title': 'Other'},
        {'document': whole},
      ]) {
        expect(
          (await director('write', options))['error_code'],
          'invalid_argument',
        );
      }
      final unchanged = await director('read', {'staging_id': id});
      expect(unchanged['document'], whole);
      expect(unchanged['version'], updated['version']);
      final replaced = await director('write', {
        'staging_id': id,
        'document': {
          ...whole,
          'title': 'Replacement',
          'motion_paths': [],
          'camera_moves': [],
        },
      });
      ok(replaced);
      expect(replaced['title'], 'Replacement');
      expect(replaced['document']['motion_paths'], isEmpty);
      expect(replaced['document']['camera_moves'], isEmpty);
      expect(replaced['document']['objects'], whole['objects']);
      expect(replaced['version'], updated['version'] + 1);
    },
  );

  test('invalid document settings roll back the whole apply batch', () async {
    final created = await director('create', {'title': 'Original'});
    final id = created['id'] as String;
    final added = await applyEdit(id, 'objects', 'create', {'data': actor()});
    ok(added);
    final keyed = await director('apply', {
      'staging_id': id,
      'commands': [
        {
          'op': 'set_key',
          'target_id': added['id'],
          'property': 'position',
          'frame': 100,
          'value': [2, 0, 0],
        },
      ],
    });
    ok(keyed);
    for (final invalid in <Json>[
      {'op': 'set_duration', 'duration_frames': 48},
      {'op': 'set_duration', 'duration_frames': 721},
      {'op': 'set_duration', 'duration_frames': 120.5},
      {'op': 'set_title', 'title': ''},
      {
        'op': 'set_output',
        'output': {'background': '#000000'},
      },
      {'op': 'set_output', 'output': null},
    ]) {
      final result = await director('apply', {
        'staging_id': id,
        'commands': [
          {'op': 'set_title', 'title': 'Must roll back'},
          invalid,
        ],
      });
      expect(result['error_code'], 'invalid_argument');
      final after = await director('read', {'staging_id': id});
      expect(after['document'], keyed['document']);
      expect(after['version'], keyed['version']);
    }
    for (final options in <Json>[
      {'staging_id': id},
      {'staging_id': id, 'edits': []},
      {'staging_id': id, 'commands': []},
      {
        'commands': [
          {'op': 'set_title', 'title': 'Missing ID'},
        ],
      },
    ]) {
      expect(
        (await director('apply', options))['error_code'],
        'invalid_argument',
      );
    }
  });

  test(
    'prop base and key scales enforce bounds and visibility uses hold keys',
    () async {
      final created = await director('create', {'title': 'Scale'});
      final id = created['id'] as String;
      final prop = {
        ...actor(),
        'kind': 'prop',
        'geometry_key': 'prop.cube.v1',
        'pose': 'none',
      };
      for (final scale in [0.01, 10.01]) {
        final result = await applyEdit(id, 'objects', 'create', {
          'data': {
            ...prop,
            'scale': [scale, 1, 1],
          },
        });
        expect(result['error_code'], 'invalid_argument');
      }
      expect(
        (await director('read', {'staging_id': id}))['version'],
        created['version'],
      );
      final added = await applyEdit(id, 'objects', 'create', {
        'data': {
          ...prop,
          'scale': [0.1, 1, 10],
        },
      });
      ok(added);
      final propId = added['id'];
      for (final scale in [0.01, 10.01]) {
        final result = await director('apply', {
          'staging_id': id,
          'commands': [
            {
              'op': 'set_key',
              'target_id': propId,
              'property': 'scale',
              'frame': 24,
              'value': [scale, 1, 1],
            },
          ],
        });
        expect(result['error_code'], 'invalid_argument');
      }
      final valid = await director('apply', {
        'staging_id': id,
        'commands': [
          {
            'op': 'set_key',
            'target_id': propId,
            'property': 'scale',
            'frame': 24,
            'value': [10, 1, 0.1],
          },
          {
            'op': 'set_key',
            'target_id': propId,
            'property': 'visible',
            'frame': 0,
            'value': false,
            'easing': 'hold',
          },
          {
            'op': 'set_key',
            'target_id': propId,
            'property': 'visible',
            'frame': 24,
            'value': true,
            'easing': 'hold',
          },
        ],
      });
      ok(valid);
      final document = DirectorDocument.fromJson(valid['document']);
      expect(sampleDocument(document, 0).objects.single['visible'], isFalse);
      expect(sampleDocument(document, 24).objects.single['visible'], isTrue);
      expect(sampleDocument(document, 24).objects.single['scale'], [
        10,
        1,
        0.1,
      ]);
    },
  );

  test(
    'director discovers schema, ID catalogs and selected model-specific details',
    () async {
      final schema = await director('schema', {});
      ok(schema);
      expect(schema['commands']['set_title']['required'], ['title']);
      expect(schema['commands']['set_duration']['required'], [
        'duration_frames',
      ]);
      expect(schema['commands']['set_output']['required'], ['output']);
      expect(schema['commands']['apply_pose'], {
        'required': ['target_id', 'preset'],
        'optional': ['frame'],
      });
      expect(schema['pose']['required'], hasLength(26));
      expect(schema['pose']['properties']['root_offset_y']['minimum'], -50);
      expect(schema['properties_by_target']['actor'], contains('pose'));
      expect(schema['limits']['shared_units'], 2048);
      expect(schema['path']['properties']['kind']['enum'], hasLength(5));
      expect(
        schema['commands']['set_key']['required'],
        containsAll(['target_id', 'property', 'frame', 'value']),
      );
      final presets = await director('presets', {});
      ok(presets);
      expect(presets['poses'], [
        for (final id in poseIds) {'id': id},
      ]);
      final selected = await director('presets', {
        'catalog': 'poses',
        'ids': ['squat'],
      });
      ok(selected);
      expect(selected.containsKey('props'), isFalse);
      expect(selected['poses'], hasLength(1));
      expect(selected['poses'][0]['id'], 'squat');
      final variants = selected['poses'][0]['variants'] as List;
      for (final geometry in actorGeometries) {
        expect(
          variants.singleWhere((v) => v['geometry_key'] == geometry)['pose'],
          posePreset('squat', geometry).toJson(),
        );
      }
      expect((presets['moves'] as List).map((m) => m['id']), moveKinds);
      expect(schema.containsKey('action_clips'), isFalse);
      expect(presets.containsKey('actions'), isFalse);
      expect(presets.containsKey('view'), isFalse);
      expect(presets.containsKey('pose_semantics'), isFalse);
    },
  );

  test(
    'preset options reject invalid filters and partial ID matches',
    () async {
      for (final options in <Json>[
        {'catalog': 'unknown'},
        {'catalog': null},
        {
          'ids': ['sit'],
        },
        {'catalog': 'poses', 'ids': []},
        {'catalog': 'poses', 'ids': 'sit'},
        {
          'catalog': 'poses',
          'ids': ['sit', 'unknown'],
        },
        {
          'catalog': 'poses',
          'ids': ['sit'],
          'geometry_key': 'actor.male.v1',
        },
      ]) {
        final result = await director('presets', options);
        expect(result['ok'], isFalse, reason: '$options: $result');
        expect(result['error_code'], 'invalid_argument');
        expect(result.containsKey('poses'), isFalse);
      }
      final filtered = await director('presets', {'catalog': 'cameras'});
      ok(filtered);
      expect(filtered['cameras'], [
        for (final id in cameraPresets) {'id': id},
      ]);
      expect(filtered.containsKey('props'), isFalse);
    },
  );

  test(
    'apply_pose resolves models and rolls back invalid command batches',
    () async {
      final created = await director('create', {});
      ok(created);
      final stagingId = created['id'] as String;
      final actors = <String>[];
      for (final geometry in actorGeometries) {
        final added = await applyEdit(stagingId, 'objects', 'create', {
          'data': {
            ...actor(),
            'geometry_key': geometry,
            'scale': [2, 2, 2],
          },
        });
        ok(added);
        actors.add(added['id']);
      }
      final prop = await applyEdit(stagingId, 'objects', 'create', {
        'data': {
          ...actor(),
          'kind': 'prop',
          'geometry_key': 'prop.chair.v1',
          'pose': 'none',
        },
      });
      ok(prop);
      final base = await director('apply', {
        'staging_id': stagingId,
        'commands': [
          for (final id in actors)
            {'op': 'apply_pose', 'target_id': id, 'preset': 'sit'},
        ],
      });
      ok(base);
      expect((base['command_results'] as List).map((r) => r['id']), actors);
      final keyed = await director('apply', {
        'staging_id': stagingId,
        'commands': [
          for (final id in actors)
            {
              'op': 'apply_pose',
              'target_id': id,
              'preset': 'kneel',
              'frame': 24,
            },
        ],
      });
      ok(keyed);
      final document = DirectorDocument.fromJson(keyed['document']);
      for (final frame in [0, 24]) {
        final sampled = sampleDocument(document, frame);
        for (final id in actors) {
          final person = sampled.objects.singleWhere((o) => o['id'] == id);
          expect(
            person['pose'],
            posePreset(
              frame == 0 ? 'sit' : 'kneel',
              person['geometry_key'],
            ).toJson(),
          );
          expect(person['scale'], [2, 2, 2]);
        }
      }
      final before = await stagingService.require(stagingId);
      final valid = <String, dynamic>{
        'op': 'apply_pose',
        'target_id': actors.first,
        'preset': 'squat',
        'frame': 12,
      };
      for (final bad in <Json>[
        {...valid, 'target_id': 'missing'},
        {...valid, 'target_id': prop['id']},
        {...valid, 'preset': 'unknown'},
        {...valid, 'frame': -1},
        {...valid, 'frame': document.durationFrames + 1},
        {...valid, 'frame': 1.5},
        {...valid, 'frame': null},
        {'op': 'apply_pose', 'target_id': actors.first, 'preset': 'sit'},
      ]) {
        turnId = 'invalid-pose';
        final failed = await director('apply', {
          'staging_id': stagingId,
          'commands': [valid, bad],
        });
        expect(failed['ok'], isFalse, reason: '$bad: $failed');
        expect(failed['error_code'], 'invalid_argument');
        final after = await stagingService.require(stagingId);
        expect(after.document, before.document);
        expect(after.version, before.version);
      }
    },
  );

  test(
    'director shared commands upsert keys and commit one atomic editor update',
    () async {
      final created = await director('create', {'title': 'Commands'});
      final stagingId = created['id'] as String;
      final object = await applyEdit(stagingId, 'objects', 'create', {
        'data': actor(),
      });
      final actorId = object['id'];
      final before = await stagingService.require(stagingId);
      final binding = VideoStagingBinding(db.screenplayDao, stagingId);
      final session = await binding.load(camera: 'A');
      addTearDown(() {
        binding.dispose();
        session.dispose();
      });
      final ui = CommandHistory(DirectorDocument.fromJson(before.document!));
      addTearDown(ui.dispose);
      final pose = posePreset('squat', 'actor.male.v1').toJson();
      ui.upsertKey(actorId, 'pose', 24, pose, easing: 'hold');
      final result = await director('apply', {
        'staging_id': stagingId,
        'commands': [
          {
            'op': 'set_key',
            'target_id': actorId,
            'property': 'pose',
            'frame': 24,
            'value': pose,
            'easing': 'hold',
          },
          {
            'op': 'set_key',
            'target_id': actorId,
            'property': 'pose',
            'frame': 24,
            'value': pose,
          },
          {
            'op': 'set_cut',
            'frame': 48,
            'camera_id': before.document!['default_camera_id'],
          },
        ],
      });
      ok(result);
      expect(result['version'], before.version + 1);
      expect(
        result['command_results'][0]['id'],
        result['command_results'][1]['id'],
      );
      final saved = DirectorDocument.fromJson(result['document']);
      expect(saved.tracks.single['keys'], ui.document.tracks.single['keys']);
      expect(sampleDocument(saved, 24).objects.single['pose'], pose);
      expect(session.history.document.businessContent, saved.businessContent);
      final failed = await director('apply', {
        'staging_id': stagingId,
        'commands': [
          {
            'op': 'set_key',
            'target_id': actorId,
            'property': 'pose',
            'frame': 48,
            'value': pose,
          },
          {
            'op': 'set_camera_mode',
            'camera_id': 'missing',
            'mode': 'free',
            'frame': 0,
          },
        ],
      });
      expect(failed['error_code'], 'invalid_argument');
      expect(
        (await stagingService.require(stagingId)).document,
        saved.toJson(),
      );
      expect(session.history.document.businessContent, saved.businessContent);
      ok(
        await director('apply', {
          'staging_id': stagingId,
          'commands': [
            {
              'op': 'remove_key',
              'target_id': actorId,
              'property': 'pose',
              'frame': 24,
            },
          ],
        }),
      );
      expect(
        (await stagingService.require(stagingId)).document!['tracks'],
        isEmpty,
      );
    },
  );

  test('director samples bounded frames without writes', () async {
    final created = await director('create', {'title': 'Audit'});
    final stagingId = created['id'] as String;
    final camera = created['document']['cameras'][0];
    ok(
      await director('apply', {
        'staging_id': stagingId,
        'commands': [
          {
            'op': 'set_key',
            'target_id': camera['id'],
            'property': 'camera_target',
            'frame': 120,
            'value': {'type': 'point', 'position': camera['position']},
          },
        ],
      }),
    );
    final before = await stagingService.require(stagingId);
    final sampled = await director('sample', {
      'staging_id': stagingId,
      'frames': [0, 119, 120],
    });
    ok(sampled);
    expect(sampled['samples'][0]['effective_camera_id'], camera['id']);
    expect(sampled['samples'][1]['diagnostics'], isEmpty);
    expect(sampled['samples'][2]['diagnostics'], isNotEmpty);
    for (final frames in [
      [],
      List.filled(13, 0),
      [0.5],
      [-1],
      [121],
    ]) {
      expect(
        (await director('sample', {
          'staging_id': stagingId,
          'frames': frames,
        }))['error_code'],
        'invalid_argument',
      );
    }
    expect((await stagingService.require(stagingId)).document, before.document);
    expect((await stagingService.require(stagingId)).version, before.version);
  });

  test(
    'director frames returns a labeled contact sheet as model image content',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final root = await Directory.systemTemp.createTemp('staging-frames-');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(channel, (_) async => root.path);
      await RevericPaths.initialize();
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        await root.delete(recursive: true);
      });
      createRenderer = () => PreviewRenderer(
        bytes: img.encodePng(img.Image(width: 64, height: 36)),
      );
      final created = await director('create', {'title': 'Frames'});
      final stagingId = created['id'] as String;
      final camera = created['document']['cameras'][0];
      final before = await stagingService.require(stagingId);
      final result = await director('frames', {
        'staging_id': stagingId,
        'frames': [0, 60, 120],
      });
      ok(result);
      expect([for (final c in result['cells']) c['frame']], [0, 60, 120]);
      expect(result['cells'][0]['camera_id'], camera['id']);
      expect(result['cells'][0]['camera_name'], camera['name']);
      expect(result['cells'][0]['label'], 'F0 C1');
      expect(renderers.single.frames, [0, 60, 120]);
      expect(renderers.single.disposed, isTrue);
      final image = (result as StructuredToolResult).content
          .whereType<ImageBlock>()
          .single;
      expect(image.mimeType, 'image/jpeg');
      final sheet = img.decodeJpg(base64Decode(image.data))!;
      expect([sheet.width, sheet.height], [result['width'], result['height']]);
      expect(result['file_path'], startsWith('sessions/'));
      expect(
        File(p.join(root.path, result['snapshot_path'] as String)).existsSync(),
        isTrue,
      );
      final fixed = await director('frames', {
        'staging_id': stagingId,
        'frames': [30],
        'camera_mode': 'fixed',
        'camera_id': camera['id'],
      });
      ok(fixed);
      expect(fixed['cells'].single['camera_id'], camera['id']);
      for (final options in [
        {'frames': []},
        {'frames': List.filled(13, 0)},
        {
          'frames': [121],
        },
        {
          'frames': [0],
          'camera_mode': 'fixed',
        },
        {
          'frames': [0],
          'camera_id': camera['id'],
        },
      ]) {
        expect(
          (await director('frames', {
            'staging_id': stagingId,
            ...options,
          }))['error_code'],
          'invalid_argument',
        );
      }
      final missing = await director('frames', {
        'frames': [0],
      });
      expect(missing['error_code'], 'invalid_argument');
      expect(missing['error'], contains('staging_id is required'));
      final unknown = await director('frames', {
        'staging_id': 'staging_missing',
        'frames': [0],
      });
      expect(unknown['error_code'], 'not_found');
      expect(unknown['error'], contains('Run stagings list'));
      final unknownAction = await director('not-a-staging-action', {});
      expect(unknownAction['output'], contains('unknown stagings command'));
      expect(unknownAction['output'], contains('剧本工具使用规范'));
      expect(unknownAction['output'], isNot(contains('画布作品工具')));
      expect((await stagingService.require(stagingId)).version, before.version);
    },
  );

  test(
    'open editor accepts AI edits with pending input and gesture preview',
    () async {
      final service = StagingEditService(db);
      final row = await service.create('Original');
      final binding = VideoStagingBinding(db.screenplayDao, row.id);
      final session = await binding.load(camera: 'A');
      addTearDown(() {
        binding.dispose();
        session.dispose();
      });
      session.hasPendingInput = true;
      session.history.previewEdit((j) => j['title'] = 'Preview');
      ok(
        await director('apply', {
          'staging_id': row.id,
          'commands': [
            {'op': 'set_title', 'title': 'Remote'},
          ],
        }),
      );
      expect(session.history.document.title, 'Remote');
      expect(session.history.preview, isNull);
      expect(session.history.dirty, isFalse);
      expect((await service.require(row.id)).title, 'Remote');
    },
  );
  test(
    'unbound actors accept null catalog IDs and reject invalid bindings',
    () async {
      final schema = await director('schema', {});
      expect(schema['object']['properties']['catalog_id']['type'], [
        'string',
        'null',
      ]);
      final created = await director('create', {'title': 'Unbound actors'});
      ok(created);
      final base = created['id'] as String;
      for (var i = 0; i < 2; i++) {
        ok(
          await applyEdit(base, 'objects', 'create', {
            'data': {...actor(), 'catalog_id': null},
          }),
        );
      }
      final saved = await stagingService.require(base);
      final document = DirectorDocument.parse(jsonEncode(saved.document));
      expect(document.objects, hasLength(2));
      expect(document.objects.every((o) => o['catalog_id'] == null), isTrue);
      final actorId = document.objects.first['id'];
      ok(
        await applyEdit(base, 'objects', 'write', {
          'id': actorId,
          'data': {'name': 'Renamed', 'catalog_id': null},
        }),
      );
      final beforeInvalid = await stagingService.require(base);
      for (final invalidId in ['', 42, 'missing']) {
        final result = await applyEdit(base, 'objects', 'write', {
          'id': actorId,
          'data': {'catalog_id': invalidId},
        });
        expect(result['error_code'], 'invalid_argument');
        expect(
          (await stagingService.require(base)).document,
          beforeInvalid.document,
        );
      }
    },
  );
  test(
    'camera and pose editing, whole replacement and revision restore preserve consistency',
    () async {
      final created = await director('create', {'title': 'Set'});
      ok(created);
      final base = created['id'] as String;
      final actorResult = await applyEdit(base, 'objects', 'create', {
        'data': actor(),
      });
      ok(actorResult);
      final actorId = actorResult['id'];
      final first = created['document']['cameras'][0] as Map;
      final cameraData = Map<String, dynamic>.from(first)..remove('id');
      cameraData['name'] = 'B';
      final camera = await applyEdit(base, 'cameras', 'create', {
        'data': cameraData,
      });
      ok(camera);
      final action = await applyEdit(base, 'tracks', 'create', {
        'data': {
          'target_id': actorId,
          'property': 'pose',
          'keys': [
            {
              'frame': 24,
              'value': ActorPose.standing().toJson(),
              'easing': 'linear',
            },
          ],
        },
      });
      ok(action);
      final move = await applyEdit(base, 'camera_moves', 'create', {
        'data': {
          'camera_id': camera['id'],
          'kind': 'dolly_in',
          'start_frame': 0,
          'end_frame': 24,
        },
      });
      ok(move);
      final edited = await applyEdit(base, 'tracks', 'write', {
        'id': action['id'],
        'data': {
          'keys': [
            {
              'frame': 48,
              'value': ActorPose.standing().withValues({
                'head_yaw': 45,
              }).toJson(),
              'easing': 'linear',
            },
          ],
        },
      });
      ok(edited);
      final malformed = await director('apply', {
        'staging_id': base,
        'edits': [
          {'op': 'write', 'collection': 'objects', 'id': actorId, 'data': 42},
        ],
      });
      expect(malformed['error_code'], 'invalid_argument');
      final badActor = await applyEdit(base, 'objects', 'create', {
        'data': {...actor(), 'catalog_id': 'missing'},
      });
      expect(badActor['error_code'], 'invalid_argument');
      turnId = 'second-turn';
      ok(await applyEdit(base, 'objects', 'remove', {'id': actorId}));
      final removedDocument = (await director('read', {
        'staging_id': base,
      }))['document'];
      expect(removedDocument['objects'], isEmpty);
      expect(removedDocument['tracks'], isEmpty);
      expect(
        (await director('read', {
          'staging_id': base,
          'collection': 'tracks',
        }))['entries'],
        isEmpty,
      );
      final whole = Map<String, dynamic>.from(
        (await director('read', {'staging_id': base}))['document'] as Map,
      )..['title'] = 'Whole';
      ok(await director('write', {'staging_id': base, 'document': whole}));
      ok(await director('restore', {'staging_id': base, 'version': 6}));
      final restored = await director('read', {'staging_id': base});
      ok(restored);
      expect(restored['title'], 'Set');
      expect(restored['version'], 9);
      expect(
        (await director('read', {
          'staging_id': base,
          'collection': 'objects',
        }))['entries'],
        hasLength(1),
      );
      expect(
        DirectorDocument.fromJson(
          restored['document'] as Map<String, dynamic>,
        ).activeCameras,
        hasLength(2),
      );
    },
  );
  test(
    'batch remove rolls back an earlier deletion when a later reference is invalid',
    () async {
      final video = await call('Create', '$canvasPath/nodes', {
        'type': 'video',
      });
      ok(video);
      final id = video['id'] as String;
      final node = (await db.canvasDao.getNodeById(id))!;
      await db
          .into(db.canvasNodes)
          .insert(
            CanvasNodesCompanion.insert(
              id: 'broken',
              canvasId: node.canvasId,
              type: const Value(canvasNodeTypeVideo),
              refType: const Value(canvasNodeRefTypeProductionClip),
              refId: const Value('missing'),
              sortOrder: const Value(100),
            ),
          );
      final result = await call('Write', canvasPath, {
        'remove_types': ['video'],
      });
      expect(result['error_code'], isNotNull);
      expect(await db.canvasDao.getNodeById(id), isNotNull);
      expect(
        await StoryboardService(db).getShot(video['ref_id'] as String),
        isNotNull,
      );
    },
  );
  test(
    'staging edits keep the last preview until an explicit image update',
    () async {
      final created = await director('create', {'title': 'Preview'});
      ok(created);
      final id = created['id'] as String;
      final row = (await db.screenplayDao.getStaging(id))!;
      expect(VideoStagingBinding.openFor(db.screenplayDao, id), isNull);
      final directory = await Directory.systemTemp.createTemp(
        'director-preview-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final preview = DirectorPreview(DirectorStorage(directory, directory));
      final originalBytes = Uint8List.fromList([1, 2, 3]);
      await preview.image.writeAsBytes(originalBytes);
      expect(await preview.read(), originalBytes);
      await preview.write(originalBytes);
      expect(await preview.read(), originalBytes);
      final camera = (row.document!['cameras'] as List).first as Map;
      ok(
        await applyEdit(id, 'cameras', 'write', {
          'id': camera['id'],
          'data': {'focal_length_mm': 50},
        }),
      );
      final changed = (await db.screenplayDao.getStaging(id))!;
      expect(changed.version, row.version + 1);
      expect(await preview.read(), originalBytes);
      expect(await preview.image.readAsBytes(), originalBytes);
      final currentBytes = Uint8List.fromList([4, 5, 6]);
      await preview.write(currentBytes);
      expect(await preview.read(), currentBytes);
      await preview.image.writeAsBytes([7, 8, 9]);
      expect(await preview.read(), [7, 8, 9]);
    },
  );
}

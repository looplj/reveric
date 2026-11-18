// 职责: 验证 Agent 剪辑命令的整组原子修订、共享撤销、锁定、预览清理范围和精确参数边界。
// 关联文件:
//   lib/shared/services/ai/media/editing.dart
//   lib/shared/services/editing/agent_commands.dart
//   lib/shared/services/editing/sessions.dart
import 'dart:async';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'commands_test.dart' show fixture, mainLayout, videoSource;
import 'dart:convert';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/services/ai/files/attachments.dart';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/editing/document.dart';
import 'package:reveric/shared/models/director/document.dart';
import 'package:reveric/shared/services/director/renderer.dart';
import 'package:reveric/shared/services/screenplay/staging_edit.dart';
import 'package:flutter/services.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:reveric/shared/models/tool_permission.dart';
import 'package:reveric/shared/services/ai/media/editing.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/ai/media/production.dart';
import 'package:reveric/shared/services/ai/tool_operations.dart';
import 'package:reveric/shared/services/editing/agent_commands.dart';
import 'package:reveric/shared/services/editing/commands.dart';
import 'package:reveric/shared/services/editing/service.dart';
import 'package:reveric/shared/services/editing/sessions.dart';
import 'package:reveric/shared/services/production/audio_service.dart';
import 'package:reveric/shared/services/production/image_service.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/result_service.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/storyboard/service.dart';

class _FrameRunner extends FfmpegRunner {
  bool unsupported = false;
  bool withAudio = false;
  int width = 854;
  int height = 480;
  int frameCount = 1;
  @override
  Future<String> execute(
    List<String> args, {
    required bool probe,
    required MediaCancellation cancellation,
  }) async {
    if (unsupported) {
      throw UnsupportedError('platform');
    }
    if (probe) {
      return jsonEncode({
        'streams': [
          if (withAudio) {'codec_type': 'audio', 'codec_name': 'aac'},
          {
            'codec_type': 'video',
            'codec_name': 'h264',
            'width': width,
            'height': height,
            'avg_frame_rate': '24/1',
            'nb_frames': '$frameCount',
            'time_base': '1/24000',
            'pix_fmt': 'yuv420p',
          },
        ],
        'format': {'duration': '${frameCount / 24}', 'format_name': 'mp4'},
      });
    }
    if (args.last == '-') {
      return '';
    }
    if (args.last.endsWith('/limited.f32')) {
      await File(args[args.indexOf('-i') + 1]).copy(args.last);
      return '';
    }
    if (args.last.endsWith('.f32')) {
      final samples = int.parse(
        args
            .firstWhere((arg) => arg.startsWith('atrim=end_sample='))
            .split('=')
            .last,
      );
      await File(args.last).writeAsBytes(Uint8List(samples * 8));
      return '';
    }
    await File(args.last).writeAsBytes(
      args.last.endsWith('.png')
          ? img.encodePng(img.Image(width: 640, height: 360))
          : [1],
    );
    return '';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NovelContentDatabase db;
  late AppDatabase app;
  late Directory root;
  late EditingSessions sessions;
  late EditingService service;
  late EditingToolHost host;
  late _FrameRunner runner;
  late ToolOperationManager operations;
  late ToolOperationRegistry registry;
  final context = ToolExecutionContext(
    sessionId: 'session',
    sourceSessionId: 'session',
    sourceTurnId: 'turn',
  );
  Future<Map<String, dynamic>> run(
    String action,
    Map<String, dynamic> options,
  ) => host.run(action, options, context, operations, 'call');
  setUp(() async {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    app = AppDatabase.forTest(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('editing-agent-');
    runner = _FrameRunner();
    final library = MediaLibraryService(app, MediaService(runner), root);
    service = EditingService(db, library);
    sessions = EditingSessions();
    registry = ToolOperationRegistry();
    operations = ToolOperationManager(
      ownerSessionId: 'session',
      registry: registry,
      gate: () => throw StateError('No file access expected'),
      onChanged: (_) {},
      onRecord: (_) {},
    );
    host = EditingToolHost(
      ProductionToolHost(
        canvas: ProductionCanvasService(StoryboardService(db), library, 'work'),
        images: _Images(),
        audio: _Audio(),
        video: () => throw StateError('No video generation'),
        results: _Results(),
        editingSessions: sessions,
      ),
      runner: runner,
    );
  });
  tearDown(() async {
    operations.dispose();
    registry.dispose();
    sessions.dispose();
    await db.close();
    await app.close();
    await root.delete(recursive: true);
  });
  Future<String> recordPreview(
    List<Map<String, dynamic>> files, {
    String kind = 'editing.preview',
    String workId = 'work',
    bool ok = true,
  }) async {
    final receipt = await operations.start(
      context: context,
      callId: 'preview',
      workId: workId,
      kind: kind,
      targetPath: '/editings/preview-project',
      toolName: 'Run',
      background: false,
      input: const {},
      verifyTarget: () async {},
      execute: (_) async => {'ok': ok, 'files': files},
    );
    return receipt['run_id'] as String;
  }

  Future<File> outputFile(String path) async {
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsString('preview');
    return file;
  }

  Map<String, dynamic> output(String path, [String? snapshot]) => {
    'delivered': true,
    'file_path': path.replaceFirst('file_workspaces/work/', ''),
    'snapshot_path': snapshot ?? path,
  };

  test(
    'frames delivers model image content without changing revision and reports unsupported runtimes',
    () async {
      final created = await run('create', {'title': 'Frames', 'ratio': '16:9'});
      final id = created['id'] as String;
      await run('apply', {
        'editing_id': id,
        'expected_revision': 0,
        'commands': [
          {
            'op': 'add_text',
            'track_id': 'T1',
            'start_frame': 0,
            'text': 'Caption',
          },
        ],
      });
      final options = {
        'editing_id': id,
        'expected_revision': 1,
        'frames': [0, 71],
      };
      final receipt = await run('frames', options);
      expect(receipt['status'], 'completed', reason: '$receipt');
      final result = receipt['result'] as Map;
      expect(result['revision'], 1);
      expect(result['file_path'], startsWith('sessions/session/'));
      expect(
        result['snapshot_path'],
        startsWith('file_workspaces/work/sessions/session/'),
      );
      expect((result['cells'] as List).map((c) => c['frame']), [0, 71]);
      final content = await assembleToolResultContent(receipt, root: root.path);
      expect(content.whereType<ImageBlock>(), hasLength(1));
      expect((await db.editingDao.get(id))!.revision, 1);
      runner.unsupported = true;
      final unsupported = await run('frames', options);
      expect(unsupported['error_code'], 'unsupported');
    },
  );

  test(
    'inspect_audio delivers the requested revision and leaves the timeline unchanged',
    () async {
      final created = await run('create', {'title': 'Audio', 'ratio': '16:9'});
      final id = created['id'] as String;
      await run('apply', {
        'editing_id': id,
        'expected_revision': 0,
        'commands': [
          {
            'op': 'add_text',
            'track_id': 'T1',
            'start_frame': 0,
            'text': 'Caption',
          },
        ],
      });
      final options = {
        'editing_id': id,
        'expected_revision': 1,
        'start_frame': 10,
        'end_frame': 12,
      };
      await expectLater(
        run('inspect_audio', {...options, 'expected_revision': 0}),
        throwsA(
          isA<ToolOperationException>().having(
            (e) => e.code,
            'code',
            'conflict',
          ),
        ),
      );
      final response = await run('inspect_audio', options);
      expect(response['ok'], true, reason: '$response');
      final result = response['result'];
      expect(result['mix']['silence_ranges'], [
        {'start_frame': 10, 'end_frame': 12},
      ]);
      expect(result['clips'], isEmpty);
      expect(resultFilePaths(response), isEmpty);
      expect(result.containsKey('files'), isFalse);
      expect(
        await root
            .list(recursive: true)
            .where((e) => e.path.endsWith('.wav'))
            .isEmpty,
        isTrue,
      );
      expect((await db.editingDao.get(id))!.revision, 1);
    },
  );

  test(
    'frames rejects stale revisions, empty timelines and invalid positions before rendering',
    () async {
      final created = await run('create', {'title': 'Frames', 'ratio': '16:9'});
      final id = created['id'] as String;
      await expectLater(
        run('frames', {
          'editing_id': id,
          'expected_revision': 1,
          'frames': [0],
        }),
        throwsA(
          isA<ToolOperationException>().having(
            (e) => e.code,
            'code',
            'conflict',
          ),
        ),
      );
      await expectLater(
        run('frames', {
          'editing_id': id,
          'expected_revision': 0,
          'frames': [0],
        }),
        throwsFormatException,
      );
      await run('apply', {
        'editing_id': id,
        'expected_revision': 0,
        'commands': [
          {
            'op': 'add_text',
            'track_id': 'T1',
            'start_frame': 0,
            'text': 'Caption',
          },
        ],
      });
      for (final positions in [
        [],
        [-1],
        [72],
        [0.5],
        List.filled(17, 0),
      ]) {
        await expectLater(
          run('frames', {
            'editing_id': id,
            'expected_revision': 1,
            'frames': positions,
          }),
          throwsFormatException,
        );
      }
      expect((await db.editingDao.get(id))!.revision, 1);
    },
  );

  test(
    'editing export rejects file destinations and preview requires the latest revision',
    () async {
      final created = await run('create', {
        'title': 'Preview',
        'ratio': '16:9',
      });
      final id = created['id'] as String;
      await expectLater(
        run('export', {
          'editing_id': id,
          'expected_revision': 0,
          'output_path': 'export.mp4',
          'request_id': 'export',
        }),
        throwsFormatException,
      );
      await expectLater(
        run('preview', {'editing_id': id}),
        throwsFormatException,
      );
      await run('apply', {
        'editing_id': id,
        'expected_revision': 0,
        'commands': [
          {'op': 'rename', 'title': 'Changed'},
        ],
      });
      await expectLater(
        run('preview', {'editing_id': id, 'expected_revision': 0}),
        throwsA(
          isA<ToolOperationException>().having(
            (e) => e.code,
            'code',
            'conflict',
          ),
        ),
      );
      expect(registry.records, isEmpty);
    },
  );

  test(
    'Run exports both saved projects as linked, reusable video nodes',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      const directorStorage = MethodChannel('ai.reveric.director/storage');
      messenger.setMockMethodCallHandler(paths, (_) async => root.path);
      messenger.setMockMethodCallHandler(directorStorage, (_) async => 1 << 40);
      addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
      addTearDown(
        () => messenger.setMockMethodCallHandler(directorStorage, null),
      );
      await RevericPaths.initialize();
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
        host.production.canvas.library,
        'work',
      );
      final production = ProductionToolHost(
        canvas: canvas,
        images: _Images(),
        audio: _Audio(),
        video: () => throw StateError('No video generation'),
        results: _Results(),
        editingSessions: sessions,
      );
      // Give the real Run dispatcher a frame renderer with no GPU dependency.
      final content = _StagingContent(db);
      final manager = AiToolManager(
        content,
        workingOverlayService: WorkingOverlayService(
          db,
          content,
          novelActionsService: NovelActionsService(app),
        ),
        contentKind: contentKindCanvas,
        workId: 'work',
        sessionId: 'session',
        operationHost: ToolOperationHost(
          operations,
          production: () async => production,
        ),
      )..registerAllTools();
      Future<Map<String, dynamic>> dispatch(
        String command,
        Map<String, dynamic> options,
      ) => manager.executeTool(
        name: 'Run',
        input: {'command': command, 'subcommand': 'export', 'options': options},
        context: context,
        callId: 'export-$command',
      );
      Future<void> expectOutput(
        Future<Map<String, dynamic>> request,
        CanvasNode source,
        String edgeType,
      ) async {
        final started = await request;
        expect(started['run_id'], isA<String>(), reason: '$started');
        final finished = await operations.wait(
          started['run_id'] as String,
          context,
        );
        expect(finished['status'], 'completed', reason: '$finished');
        final output = finished['result']['output'] as Map;
        final id = output['node_id'] as String;
        expect(output['node_path'], '/production/canvas/nodes/$id');
        final node = await canvas.requireNode(id);
        expect(node.canvasId, source.canvasId);
        final asset = await canvas.videoSource(id);
        expect(output['asset_id'], asset.id);
        expect(await File(canvas.library.resolve(asset)).exists(), isTrue);
        final edges = await db.canvasDao.getEdgesByCanvas(source.canvasId);
        expect(
          edges
              .where(
                (edge) =>
                    edge.sourceNodeId == source.id && edge.targetNodeId == id,
              )
              .single
              .type,
          edgeType,
        );
      }

      final board = await canvas.ensureCanvas('');
      final director = await canvas.addDirector(board.id, 'Director');
      final row = (await db.screenplayDao.getStaging(director.stagingId!))!;
      final document = DirectorDocument.fromJson(row.document!);
      runner
        ..width = document.width
        ..height = document.height
        ..frameCount = document.durationFrames;
      final stale = await dispatch('stagings', {
        'staging_id': row.id,
        'expected_version': row.version + 1,
      });
      expect(stale['error_code'], 'conflict', reason: '$stale');
      await expectOutput(
        dispatch('stagings', {
          'staging_id': row.id,
          'expected_version': row.version,
        }),
        director,
        canvasEdgeTypeStagingOutput,
      );

      host = EditingToolHost(production, runner: runner);
      final created = await run('create', {'title': 'Cut', 'ratio': '16:9'});
      final id = created['editing_id'] as String;
      final changed = await run('apply', {
        'editing_id': id,
        'expected_revision': 0,
        'commands': [
          {
            'op': 'add_text',
            'track_id': 'T1',
            'start_frame': 0,
            'text': 'Title',
          },
        ],
      });
      final editing = await canvas.requireNode(created['node_id'] as String);
      final staleEditing = await dispatch('editing', {
        'editing_id': id,
        'expected_revision': 0,
      });
      expect(staleEditing['error_code'], 'conflict', reason: '$staleEditing');
      runner
        ..width = 1280
        ..height = 720
        ..frameCount = changed['total_frames'] as int
        ..withAudio = true;
      await expectOutput(
        run('export', {
          'editing_id': id,
          'expected_revision': changed['revision'],
        }),
        editing,
        canvasEdgeTypeDerivedOutput,
      );
    },
  );

  test(
    'cleanup removes preview copies only and repeated cleanup is safe',
    () async {
      const path = 'file_workspaces/work/sessions/session/preview.mp4';
      const snapshot = 'file_workspaces/work/sessions/session/snapshot.mp4';
      final preview = await outputFile(path);
      final copy = await outputFile(snapshot);
      final original = await outputFile('file_workspaces/work/original.mp4');
      final other = await outputFile(
        'file_workspaces/work/sessions/session/other.mp4',
      );
      final created = await run('create', {'title': 'Keep', 'ratio': '16:9'});
      final runId = await recordPreview([output(path), output(snapshot)]);
      final cleaned = await run('cleanup', {'run_id': runId});
      expect(
        cleaned['removed'],
        unorderedEquals([
          'sessions/session/preview.mp4',
          'sessions/session/snapshot.mp4',
        ]),
      );
      expect(cleaned['missing'], isEmpty);
      expect(await preview.exists(), isFalse);
      expect(await copy.exists(), isFalse);
      expect(await original.exists(), isTrue);
      expect(await other.exists(), isTrue);
      expect((await db.editingDao.get(created['id'] as String))!.revision, 0);
      final repeated = await run('cleanup', {'run_id': runId});
      expect(repeated['removed'], isEmpty);
      expect(
        repeated['missing'],
        unorderedEquals([
          'sessions/session/preview.mp4',
          'sessions/session/snapshot.mp4',
        ]),
      );
    },
  );

  test(
    'cleanup deduplicates paths and handles saved output from failed delivery',
    () async {
      const path = 'file_workspaces/work/sessions/session/preview.mp4';
      final file = await outputFile(path);
      final runId = await recordPreview([output(path)], ok: false);
      expect((await run('cleanup', {'run_id': runId}))['removed'], [
        'sessions/session/preview.mp4',
      ]);
      expect(await file.exists(), isFalse);
    },
  );

  test('cleanup refuses other sessions, works and non-preview tasks', () async {
    const path = 'file_workspaces/work/sessions/session/preview.mp4';
    final file = await outputFile(path);
    final runId = await recordPreview([output(path)]);
    await expectLater(
      host.run(
        'cleanup',
        {'run_id': runId},
        ToolExecutionContext(
          sessionId: 'other',
          operationOwnerSessionId: 'session',
        ),
        operations,
        'other-call',
      ),
      throwsA(isA<ToolPermissionException>()),
    );
    for (final forbidden in [
      await recordPreview([output(path)], kind: 'editing.export'),
      await recordPreview([output(path)], workId: 'another-work'),
    ]) {
      await expectLater(
        run('cleanup', {'run_id': forbidden}),
        throwsA(
          isA<ToolOperationException>().having(
            (e) => e.code,
            'code',
            'failed_precondition',
          ),
        ),
      );
    }
    await expectLater(
      run('cleanup', {'run_id': runId, 'path': path}),
      throwsFormatException,
    );
    expect(await file.exists(), isTrue);
  });

  test('cleanup refuses a running preview until it finishes', () async {
    final done = Completer<Map<String, dynamic>>();
    final receipt = await operations.start(
      context: context,
      callId: 'running-preview',
      workId: 'work',
      kind: 'editing.preview',
      targetPath: '/editings/preview-project',
      toolName: 'Run',
      background: true,
      input: const {},
      verifyTarget: () async {},
      execute: (_) => done.future,
    );
    final runId = receipt['run_id'] as String;
    try {
      await expectLater(
        run('cleanup', {'run_id': runId}),
        throwsA(
          isA<ToolOperationException>().having(
            (e) => e.code,
            'code',
            'failed_precondition',
          ),
        ),
      );
    } finally {
      done.complete({'ok': true});
      await operations.wait(runId, context);
    }
  });

  test(
    'cleanup validates every recorded path before deleting any output',
    () async {
      const path = 'file_workspaces/work/sessions/session/preview.mp4';
      final file = await outputFile(path);
      for (final forbidden in [
        'file_workspaces/work/source.mp4',
        'file_workspaces/work/sessions/other/source.mp4',
        'file_workspaces/other/sessions/session/source.mp4',
        'file_workspaces/work/sessions/session/../source.mp4',
        '${root.path}/file_workspaces/work/sessions/session/preview.mp4',
        'file_workspaces/work/sessions/session/frame.png',
      ]) {
        final runId = await recordPreview([output(path, forbidden)]);
        await expectLater(
          run('cleanup', {'run_id': runId}),
          throwsFormatException,
        );
        expect(await file.exists(), isTrue);
      }
    },
  );

  test(
    'cleanup refuses symlinks without removing any recorded output',
    () async {
      const path = 'file_workspaces/work/sessions/session/preview.mp4';
      const linked = 'file_workspaces/work/sessions/session/linked.mp4';
      final file = await outputFile(path);
      final source = await outputFile('file_workspaces/work/source.mp4');
      await Link('${root.path}/$linked').create(source.path);
      final runId = await recordPreview([output(path), output(linked)]);
      await expectLater(
        run('cleanup', {'run_id': runId}),
        throwsFormatException,
      );
      expect(await file.exists(), isTrue);
      expect(await source.exists(), isTrue);
    },
    skip: Platform.isWindows
        ? 'Creating symlinks requires Windows privileges.'
        : false,
  );

  for (final kind in ['image', 'video', 'audio']) {
    test(
      'production $kind accepts clip_id alone and rejects request_id',
      () async {
        final spec = RunCommandSpec(
          'production',
          'generate-$kind',
          RunPermission.required('generation.$kind'),
        );
        await expectLater(
          host.production.run(
            spec,
            {'clip_id': 'missing-clip'},
            context,
            operations,
            'generate',
          ),
          throwsA(
            isA<ToolOperationException>().having(
              (error) => error.code,
              'code',
              'not_found',
            ),
          ),
        );
        await expectLater(
          host.production.run(
            spec,
            {'clip_id': 'missing-clip', 'request_id': 'old-request'},
            context,
            operations,
            'generate',
          ),
          throwsFormatException,
        );
      },
    );
  }

  test(
    'episode editing is read and renamed through Run without a UI listener',
    () async {
      final content = NovelContentService(db);
      final overlay = WorkingOverlayService(
        db,
        content,
        novelActionsService: NovelActionsService(app),
      );
      final tools = AiToolManager(
        content,
        workingOverlayService: overlay,
        contentKind: 'screenplay',
        workId: 'work',
        sessionId: 'session',
        operationHost: ToolOperationHost(
          operations,
          production: () async => host.production,
        ),
      );
      tools.registerAllTools();
      addTearDown(tools.dispose);
      final initial = await ScreenplayService(db).createInitialStructure();
      final episode = await tools.executeTool(
        name: 'Read',
        context: context,
        input: {'path': '/episodes/${initial.episodeId}'},
      );
      final editingId = episode['editing_id'] as String;
      final read = await tools.executeTool(
        name: 'Run',
        callId: 'editing-read',
        context: context,
        input: {
          'command': 'editing',
          'subcommand': 'read',
          'options': {'editing_id': editingId},
        },
      );
      expect(read['ok'], true, reason: '$read');
      expect(read['id'], editingId);
      expect(read['revision'], 0);
      expect(read['clips'], isEmpty);
      final applied = await tools.executeTool(
        name: 'Run',
        callId: 'editing-apply',
        context: context,
        input: {
          'command': 'editing',
          'subcommand': 'apply',
          'options': {
            'editing_id': editingId,
            'expected_revision': 0,
            'commands': [
              {'op': 'rename', 'title': 'Saved'},
            ],
          },
        },
      );
      expect(applied['revision'], 1, reason: '$applied');
      expect((await db.editingDao.get(editingId))!.title, 'Saved');
      expect(await db.editingDao.list(), hasLength(1));
      final removedPath = '/episodes/${initial.episodeId}/editing';
      for (final tool in ['Read', 'Create', 'Write', 'Edit']) {
        final rejected = await tools.executeTool(
          name: tool,
          context: context,
          input: {
            'path': tool == 'Edit' ? '$removedPath/title' : removedPath,
            if (tool == 'Write' || tool == 'Create')
              'fields': {'title': 'Rejected'},
            if (tool == 'Edit') 'old_text': 'Saved',
            if (tool == 'Edit') 'new_text': 'Rejected',
          },
        );
        expect(rejected['ok'], false, reason: '$tool: $rejected');
      }
      expect((await db.editingDao.get(editingId))!.title, 'Saved');
    },
  );
  test(
    'canvas Run editing imports an adopted clip with empty episode',
    () async {
      await ScreenplayService(db).createCanvasStructure();
      await app.novelDao.create(
        id: 'work',
        title: 'Canvas',
        description: '',
        contentKind: contentKindCanvas,
        contentDatabasePath: db.filePath,
      );
      final library = host.production.canvas.library;
      final canvas = ProductionCanvasService(
        StoryboardService(db, contentKind: contentKindCanvas),
        library,
        'work',
      );
      host = EditingToolHost(
        ProductionToolHost(
          canvas: canvas,
          images: _Images(),
          audio: _Audio(),
          video: () => throw StateError('No generation'),
          results: _Results(),
          editingSessions: sessions,
        ),
        runner: runner,
      );
      final source = await outputFile('source.mp4');
      final asset = await library.importFile(
        source,
        name: 'Source.mp4',
        novelId: 'work',
        purpose: AssetPurpose.production_output,
        cancellation: MediaCancellation(),
      );
      final clip = await canvas.shots.createVideo(
        '',
        values: {'title': 'Shot'},
      );
      await (db.update(db.productionClips)..where((t) => t.id.equals(clip.id)))
          .write(ProductionClipsCompanion(adoptedAssetId: Value(asset.id)));
      final created = await run('create', {'title': 'Cut', 'ratio': '16:9'});
      expect(created['node_id'], isNotNull);
      expect(created['revision'], 0);
      final result = await run('apply', {
        'editing_id': created['id'],
        'expected_revision': 0,
        'commands': [
          {
            'op': 'add_media',
            'track_id': 'V1',
            'index': 0,
            'production_clip_id': clip.id,
          },
        ],
      });
      expect(result['revision'], 1);
      final saved = await db.editingDao.get(created['id'] as String);
      expect(saved!.document.mainClips.single.media!.source.assetId, asset.id);
      expect(clip.episodeId, '');
    },
  );

  test(
    'headless create/list/read and atomic batch share UI undo and rename history',
    () async {
      final created = await run('create', {'title': 'First', 'ratio': '16:9'});
      final id = created['id'] as String;
      final ui = sessions.get(service, id);
      await ui.ensureLoaded();
      final result = await run('apply', {
        'editing_id': id,
        'expected_revision': 0,
        'commands': [
          {
            'op': 'add_text',
            'id': 'caption',
            'track_id': 'T1',
            'start_frame': 0,
            'text': 'Line',
          },
          {'op': 'split_clip', 'clip_id': 'caption', 'frame': 24},
          {'op': 'rename', 'title': 'Edited'},
          {'op': 'set_ratio', 'ratio': '9:16'},
        ],
      });
      expect(result['revision'], 1);
      expect(ui.title, 'Edited');
      expect(ui.document!.clips, hasLength(2));
      expect(result['results'], hasLength(4));
      final filtered = await run('read', {
        'editing_id': id,
        'start_frame': 24,
        'end_frame': 72,
      });
      expect((filtered['clips'] as List).single['start_frame'], 24);
      final listing = await run('list', {'limit': 1});
      expect((listing['entries'] as List).single['ratio'], '9:16');
      ui.undo();
      await ui.flush();
      expect(ui.title, 'First');
      expect(ui.document!.clips, isEmpty);
      expect(ui.revision, 2);
      await run('redo', {'editing_id': id, 'expected_revision': 2});
      expect(ui.document!.clips, hasLength(2));
      expect(ui.title, 'Edited');
      expect(ui.revision, 3);
      ui.commit(EditingCommands.remove(ui.document!, 'caption'));
      await ui.flush();
      await run('undo', {'editing_id': id, 'expected_revision': 4});
      expect(ui.document!.clips, hasLength(2));
    },
  );
  test(
    'failed second command leaves document revision and undo untouched',
    () async {
      final id =
          (await run('create', {'title': 'A', 'ratio': '16:9'}))['id']
              as String;
      await expectLater(
        run('apply', {
          'editing_id': id,
          'expected_revision': 0,
          'commands': [
            {'op': 'rename', 'title': 'Must roll back'},
            {'op': 'add_text', 'track_id': 'T1', 'start_frame': 0, 'text': 'A'},
            {
              'op': 'add_text',
              'track_id': 'T1',
              'start_frame': 12,
              'text': 'Overlapping',
            },
          ],
        }),
        throwsA(
          isA<ToolOperationException>().having(
            (e) => e.message,
            'message',
            matches(
              RegExp(
                r'^commands\[2\] \(add_text\): Occupied: track T1 already has '
                r'clip \S+ at frames 0-\d+\.$',
              ),
            ),
          ),
        ),
      );
      final row = (await db.editingDao.get(id))!;
      expect(row.revision, 0);
      expect(row.title, 'A');
      expect(row.document.clips, isEmpty);
      expect(sessions.get(service, id).canUndo, false);
      await expectLater(
        run('undo', {'editing_id': id, 'expected_revision': 0}),
        throwsA(isA<ToolOperationException>()),
      );
    },
  );
  test(
    'lock cannot be bypassed by grouped unlock and stale revision cannot overwrite',
    () async {
      final id =
          (await run('create', {'title': 'A', 'ratio': '16:9'}))['id']
              as String;
      await run('apply', {
        'editing_id': id,
        'expected_revision': 0,
        'commands': [
          {
            'op': 'update_track',
            'track_id': 'T1',
            'fields': {'locked': true},
          },
        ],
      });
      await expectLater(
        run('apply', {
          'editing_id': id,
          'expected_revision': 1,
          'commands': [
            {
              'op': 'update_track',
              'track_id': 'T1',
              'fields': {'locked': false},
            },
            {
              'op': 'add_text',
              'track_id': 'T1',
              'start_frame': 0,
              'text': 'No',
            },
          ],
        }),
        throwsA(isA<ToolOperationException>()),
      );
      await expectLater(
        run('apply', {
          'editing_id': id,
          'expected_revision': 0,
          'commands': [
            {'op': 'rename', 'title': 'Stale'},
          ],
        }),
        throwsA(
          isA<ToolOperationException>().having(
            (e) => e.code,
            'code',
            'conflict',
          ),
        ),
      );
      final result = await run('apply', {
        'editing_id': id,
        'expected_revision': 1,
        'commands': [
          {
            'op': 'update_track',
            'track_id': 'T1',
            'fields': {'locked': false},
          },
        ],
      });
      expect(result['revision'], 2);
    },
  );
  test(
    'unknown fields and invalid read intervals fail without editing',
    () async {
      final id =
          (await run('create', {'title': 'A', 'ratio': '16:9'}))['id']
              as String;
      await expectLater(
        run('read', {'editing_id': id, 'start_frame': 1}),
        throwsFormatException,
      );
      await expectLater(
        run('read', {
          'editing_id': id,
          'track_id': 'T1',
          'start_frame': 0,
          'end_frame': 1,
        }),
        throwsFormatException,
      );
      await expectLater(
        run('apply', {
          'editing_id': id,
          'expected_revision': 0,
          'commands': [
            {'op': 'rename', 'title': 'B', 'typo': true},
          ],
        }),
        throwsFormatException,
      );
      expect((await db.editingDao.get(id))!.revision, 0);
    },
  );
  test(
    'add_media and replace_source import the path input into timeline assets',
    () async {
      final directory = await Directory(
        '${root.path}/file_workspaces/work/sessions/session',
      ).create(recursive: true);
      await File('${directory.path}/first.mp4').writeAsBytes([1]);
      await File('${directory.path}/second.mp4').writeAsBytes([2]);
      final created = await run('create', {'title': 'Paths', 'ratio': '16:9'});
      final id = created['id'] as String;
      final added = await run('apply', {
        'editing_id': id,
        'expected_revision': 0,
        'commands': [
          {
            'op': 'add_media',
            'id': 'clip',
            'track_id': 'V1',
            'path': 'sessions/session/first.mp4',
            'index': 0,
          },
        ],
      });
      expect(added['revision'], 1);
      final first = (await db.editingDao.get(
        id,
      ))!.document.clips.single.media!.source.assetId;
      final replaced = await run('apply', {
        'editing_id': id,
        'expected_revision': 1,
        'commands': [
          {
            'op': 'replace_source',
            'clip_id': 'clip',
            'path': 'sessions/session/second.mp4',
          },
        ],
      });
      expect(replaced['revision'], 2);
      final second = (await db.editingDao.get(
        id,
      ))!.document.clips.single.media!.source.assetId;
      expect(second, isNot(first));
      expect(await app.assetDao.getAsset(first), isNotNull);
      expect(await app.assetDao.getAsset(second), isNotNull);
    },
  );

  test(
    'source commands preserve actual trim and split intervals and shorten replacement',
    () async {
      final engine = EditingAgentCommands(
        (_) async => const EditingSource(
          assetId: 'file_workspaces/work/a.mp4',
          mediaType: 'video',
          durationUs: 1000000,
        ),
      );
      final initial = EditingDocument.empty('16:9');
      final built = await engine.apply(initial, 'A', [
        {
          'op': 'add_media',
          'id': 'main',
          'track_id': 'V1',
          'path': 'file_workspaces/work/a.mp4',
          'index': 0,
        },
        {'op': 'duplicate_clip', 'clip_id': 'main', 'id': 'copy', 'index': 1},
        {
          'op': 'trim_clip',
          'clip_id': 'main',
          'start_frame': 6,
          'end_frame': 24,
        },
        {'op': 'reorder_clip', 'clip_id': 'copy', 'index': 0},
        {'op': 'split_clip', 'clip_id': 'copy', 'frame': 12},
        {
          'op': 'update_clip',
          'clip_id': 'main',
          'fields': {'gain_db': -6},
        },
        {'op': 'add_audio_track', 'id': 'voice'},
        {
          'op': 'update_track',
          'track_id': 'voice',
          'fields': {'muted': true},
        },
        {'op': 'remove_track', 'track_id': 'voice'},
      ]);
      expect(built.document.mainClips, hasLength(3));
      expect(built.document.mainClips.last.media!.sourceInUs, 250000);
      expect(built.document.mainClips.last.media!.gainDb, -6);
      expect(built.result[4]['created_clip_ids'], hasLength(1));
      await expectLater(
        engine.apply(built.document, 'A', [
          {
            'op': 'trim_clip',
            'clip_id': 'main',
            'start_frame': 24,
            'end_frame': 1000,
          },
        ]),
        throwsFormatException,
      );
    },
  );
  test(
    'detach batch is atomic and shared undo restores automatic track creation',
    () async {
      runner.withAudio = true;
      await outputFile('file_workspaces/work/clip.mp4');
      await app.assetDao.insertAsset(
        AssetsCompanion.insert(
          id: 'clip',
          type: 'video',
          purpose: 'general',
          path: const Value('file_workspaces/work/clip.mp4'),
          content: const Value(VideoAssetContent(mimeType: 'video/mp4')),
        ),
      );
      final initial = EditingCommands.removeTrack(
        EditingDocument.empty('16:9').copyWith(
          clips: const [
            EditingClip(
              id: 'm2',
              trackId: 'V1',
              startFrame: 0,
              durationFrames: 1,
              content: EditingVideoContent(
                source: EditingSource(
                  assetId: 'clip',
                  mediaType: 'video',
                  durationUs: 41667,
                  hasAudio: true,
                ),
              ),
            ),
          ],
        ),
        'A1',
      );
      await db.editingDao.create('detach', 'Detach', initial);
      final ui = sessions.get(service, 'detach');
      await ui.ensureLoaded();
      await expectLater(
        run('apply', {
          'editing_id': 'detach',
          'expected_revision': 0,
          'commands': [
            {'op': 'extract_audio', 'clip_id': 'm2'},
            {
              'op': 'update_clip',
              'clip_id': 'm2',
              'fields': {'scale': 2},
            },
          ],
        }),
        throwsFormatException,
      );
      expect(ui.document!.toJson(), initial.toJson());
      expect((await db.editingDao.get('detach'))!.revision, 0);
      final applied = await run('apply', {
        'editing_id': 'detach',
        'expected_revision': 0,
        'commands': [
          {'op': 'extract_audio', 'clip_id': 'm2'},
        ],
      });
      final result = (applied['results'] as List).single as Map;
      expect(result['created_clip_ids'], hasLength(1));
      expect(result['created_track_ids'], hasLength(1));
      expect(result['changes'], hasLength(2));
      await expectLater(
        run('apply', {
          'editing_id': 'detach',
          'expected_revision': 1,
          'commands': [
            {'op': 'extract_audio', 'clip_id': 'm2'},
          ],
        }),
        throwsA(
          isA<ToolOperationException>()
              .having((e) => e.code, 'code', 'failed_precondition')
              .having(
                (e) => e.message,
                'message',
                'commands[0] (extract_audio): Audio already detached',
              ),
        ),
      );
      final detached = ui.document!.toJson();
      expect(
        (ui.document!.mainClips.single.content as EditingVideoContent)
            .audioDetached,
        true,
      );
      ui.undo();
      await ui.flush();
      expect(ui.document!.toJson(), initial.toJson());
      expect(ui.canUndo, false);
      await run('redo', {'editing_id': 'detach', 'expected_revision': 2});
      expect(ui.document!.toJson(), detached);
      expect((await db.editingDao.get('detach'))!.document.toJson(), detached);
    },
  );

  test(
    'source provenance and typed update fields survive detach and replacement',
    () async {
      final engine = EditingAgentCommands((_) async => videoSource);
      final built = await engine.apply(EditingDocument.empty('16:9'), 'A', [
        {
          'op': 'add_media',
          'id': 'main',
          'track_id': 'V1',
          'index': 0,
          'production_clip_id': 'shot-one',
        },
        {
          'op': 'update_clip',
          'clip_id': 'main',
          'fields': {
            'scale': .4,
            'opacity': .6,
            'gain_db': -6,
            'fade_in_frames': 6,
            'fade_out_frames': 12,
          },
        },
        {'op': 'extract_audio', 'clip_id': 'main', 'track_id': 'A2'},
        {
          'op': 'add_text',
          'id': 'text',
          'track_id': 'T1',
          'start_frame': 0,
          'text': 'Before',
        },
        {
          'op': 'update_clip',
          'clip_id': 'text',
          'fields': {
            'text': 'After',
            'text_style': 'title',
            'scale': 1.5,
            'opacity': .8,
            'x': .96,
            'y': .04,
            'anchor_x': 1,
            'anchor_y': 0,
          },
        },
        {'op': 'add_text_track', 'id': 'marks'},
        {
          'op': 'add_text',
          'id': 'mark',
          'track_id': 'marks',
          'start_frame': 0,
          'text': 'LOGO',
        },
      ]);
      final video = built.document.mainClips.single;
      expect(video.origin!.id, 'shot-one');
      final content = video.content as EditingVideoContent;
      expect(
        content.transform.toJson(),
        EditingCommands.autoPlacement(.4).toJson(),
      );
      expect(content.opacity, .6);
      final audio = built.document.clips.singleWhere(
        (c) => c.content is EditingAudioContent,
      );
      expect(audio.trackId, 'A2');
      expect(audio.origin!.id, 'shot-one');
      expect(
        (
          audio.media!.gainDb,
          audio.media!.fadeInFrames,
          audio.media!.fadeOutFrames,
        ),
        (-6, 6, 12),
      );
      expect(
        built.document.clips
            .singleWhere((c) => c.id == 'text')
            .content
            .toJson(),
        {
          'kind': 'text',
          'text': 'After',
          'style': 'title',
          'transform': {
            'scale': 1.5,
            'x': .96,
            'y': .04,
            'anchor_x': 1.0,
            'anchor_y': 0.0,
          },
          'opacity': .8,
        },
      );
      final marks = built.document.track('marks');
      expect((marks.kind, marks.role, marks.order), ('text', 'text', 1));
      expect(
        built.document.clips.singleWhere((c) => c.id == 'mark').trackId,
        'marks',
      );
      final moved = await engine.apply(built.document, 'A', [
        {
          'op': 'update_clip',
          'clip_id': 'main',
          'fields': {'x': .1, 'anchor_x': 0},
        },
      ]);
      expect(
        (moved.document.mainClips.single.content as EditingVideoContent)
            .transform
            .toJson(),
        EditingCommands.autoPlacement(.4).copyWith(x: .1, anchorX: 0).toJson(),
      );
      final replaced = await engine.apply(built.document, 'A', [
        {
          'op': 'replace_source',
          'clip_id': 'main',
          'production_clip_id': 'shot-two',
        },
      ]);
      expect(replaced.document.mainClips.single.origin!.id, 'shot-two');
      expect(
        (replaced.document.mainClips.single.content as EditingVideoContent)
            .audioDetached,
        true,
      );
      final ordinary = await engine.apply(replaced.document, 'A', [
        {'op': 'replace_source', 'clip_id': 'main', 'path': 'replacement.mp4'},
      ]);
      expect(ordinary.document.mainClips.single.origin, isNull);
      expect(
        ordinary.document.clips.singleWhere((c) => c.id == audio.id),
        same(audio),
      );
      for (final command in [
        {
          'op': 'update_clip',
          'clip_id': 'text',
          'fields': {'anchor_x': 1.5},
        },
        {
          'op': 'update_clip',
          'clip_id': 'text',
          'fields': {'scale': 3},
        },
        {
          'op': 'update_clip',
          'clip_id': audio.id,
          'fields': {'x': .5},
        },
      ]) {
        await expectLater(
          engine.apply(built.document, 'A', [command]),
          throwsFormatException,
        );
      }
      await expectLater(
        engine.apply(built.document, 'A', [
          {
            'op': 'update_clip',
            'clip_id': 'text',
            'fields': {'text_position': 'center'},
          },
        ]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('text_position'),
              contains('anchor_x'),
              contains('text_style'),
            ),
          ),
        ),
      );
    },
  );

  test(
    'agent track and ratio updates enforce document product rules',
    () async {
      final original = fixture();
      final gapped = original.copyWith(
        clips: [
          for (final c in original.clips)
            c.id == 'm1' ? c.copyWith(durationFrames: 90) : c,
        ],
      );
      final engine = EditingAgentCommands((_) async => videoSource);
      for (final command in [
        {'op': 'set_ratio', 'ratio': '9:16'},
        {
          'op': 'update_track',
          'track_id': 'A1',
          'fields': {'name': 'Voice'},
        },
      ]) {
        await expectLater(
          engine.apply(gapped, 'A', [command]),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'duplicate clones timeline tracks and clips independently and checks expected_revision',
    () async {
      runner.withAudio = true;
      final created = await run('create', {
        'title': 'Master Cut',
        'ratio': '16:9',
      });
      final sourceId = created['id'] as String;
      final sourceFile = File('${root.path}/file_workspaces/work/clip.mp4');
      await sourceFile.parent.create(recursive: true);
      await sourceFile.writeAsBytes([1, 2, 3]);
      final applied = await run('apply', {
        'editing_id': sourceId,
        'expected_revision': created['revision'],
        'commands': [
          {
            'op': 'add_media',
            'id': 'v1',
            'track_id': 'V1',
            'index': 0,
            'path': 'clip.mp4',
          },
          {'op': 'add_text_track', 'id': 'T2'},
          {
            'op': 'add_text',
            'id': 'txt1',
            'track_id': 'T2',
            'start_frame': 0,
            'text': 'Watermark',
          },
          {
            'op': 'add_text',
            'id': 'sub1',
            'track_id': 'T1',
            'start_frame': 0,
            'text': 'Subtitle line',
          },
          {'op': 'extract_audio', 'clip_id': 'v1', 'track_id': 'A2'},
        ],
      });
      expect(applied['ok'], true, reason: '$applied');
      final rev = applied['revision'] as int;

      await expectLater(
        run('duplicate', {
          'editing_id': sourceId,
          'expected_revision': rev - 1,
        }),
        throwsA(
          isA<ToolOperationException>().having(
            (e) => e.code,
            'code',
            'conflict',
          ),
        ),
      );

      final defaultCopy = await run('duplicate', {'editing_id': sourceId});
      expect(defaultCopy['ok'], true, reason: '$defaultCopy');
      expect(defaultCopy['id'], isNot(sourceId));
      expect(defaultCopy['editing_id'], defaultCopy['id']);
      expect(defaultCopy['source_editing_id'], sourceId);
      expect(defaultCopy['title'], 'Master Cut Copy');
      expect(defaultCopy['ratio'], '16:9');
      expect(defaultCopy['revision'], 0);

      final customCopy = await run('duplicate', {
        'editing_id': sourceId,
        'title': 'Experiment Cut',
        'expected_revision': rev,
      });
      expect(customCopy['ok'], true, reason: '$customCopy');
      final cloneId = customCopy['id'] as String;
      expect(customCopy['title'], 'Experiment Cut');

      final sourceRead = await run('read', {'editing_id': sourceId});
      final cloneRead = await run('read', {'editing_id': cloneId});
      expect(cloneRead['tracks'], sourceRead['tracks']);
      expect(cloneRead['clips'], sourceRead['clips']);
      expect(cloneRead['total_frames'], sourceRead['total_frames']);

      final mutated = await run('apply', {
        'editing_id': cloneId,
        'expected_revision': customCopy['revision'],
        'commands': [
          {'op': 'rename', 'title': 'Mutated Experiment'},
          {'op': 'remove_clip', 'clip_id': 'txt1'},
        ],
      });
      expect(mutated['ok'], true, reason: '$mutated');

      final sourceAfter = await run('read', {'editing_id': sourceId});
      final cloneAfter = await run('read', {'editing_id': cloneId});
      expect(sourceAfter['title'], 'Master Cut');
      expect(
        (sourceAfter['clips'] as List).map((c) => c['id']),
        contains('txt1'),
      );
      expect(cloneAfter['title'], 'Mutated Experiment');
      expect(
        (cloneAfter['clips'] as List).map((c) => c['id']),
        isNot(contains('txt1')),
      );
    },
  );

  test(
    'update_clip speed retimes before fades and reports the new range',
    () async {
      final engine = EditingAgentCommands((_) async => videoSource);
      final result = await engine.apply(fixture(), 'A', [
        {
          'op': 'update_clip',
          'clip_id': 'm2',
          'fields': {'speed': 2, 'fade_out_frames': 30},
        },
      ]);
      expect(mainLayout(result.document), [
        ('m1', 0, 96),
        ('m2', 96, 60),
        ('m3', 156, 120),
      ]);
      final m2 = result.document.clips.singleWhere((c) => c.id == 'm2');
      expect((m2.media!.speed, m2.media!.fadeOutFrames), (2.0, 30));
      final change = (result.result.single['changes'] as List).singleWhere(
        (c) => c['clip_id'] == 'm2',
      );
      expect(change['after']['speed'], 2.0);
      expect(change['after']['duration_frames'], 60);
      for (final command in [
        {
          'op': 'update_clip',
          'clip_id': 'm2',
          'fields': {'speed': 5},
        },
        {
          'op': 'update_clip',
          'clip_id': 'sub',
          'fields': {'speed': 2},
        },
      ]) {
        await expectLater(
          engine.apply(fixture(), 'A', [command]),
          throwsFormatException,
        );
      }
    },
  );
}

class _StagingContent extends NovelContentService {
  _StagingContent(super.db);

  late final _staging = StagingEditService(
    database,
    previewRenderer: _DirectorFrames.new,
  );

  @override
  StagingEditService get stagingEditService => _staging;
}

class _DirectorFrames implements FrameRenderer {
  @override
  Future<Uint8List> capture(
    DirectorDocument document,
    int frame,
    String cameraId,
  ) async => Uint8List.fromList([137, 80, 78, 71]);

  @override
  void dispose() {}
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

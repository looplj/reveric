// 职责: 验证 Agent 剪辑命令的整组原子修订、共享撤销、锁定、预览清理范围和精确参数边界。
// 关联文件:
//   lib/shared/services/ai/media/editing.dart
//   lib/shared/services/editing/agent_commands.dart
//   lib/shared/services/editing/sessions.dart
import 'dart:async';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'commands_test.dart' show fixture, videoSource;
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
            'width': 854,
            'height': 480,
            'avg_frame_rate': '24/1',
            'nb_frames': '1',
            'time_base': '1/24000',
            'pix_fmt': 'yuv420p',
          },
        ],
        'format': {'duration': '0.041667', 'format_name': 'mp4'},
      });
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
        List.filled(13, 0),
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
    'export is unavailable and preview still requires the latest revision',
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
        throwsA(
          isA<ToolOperationException>().having(
            (e) => e.code,
            'code',
            'unsupported',
          ),
        ),
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
        throwsA(isA<ToolOperationException>()),
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
              .having((e) => e.message, 'message', 'Audio already detached'),
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
            'text_position': 'center',
          },
        },
      ]);
      final video = built.document.mainClips.single;
      expect(video.origin!.id, 'shot-one');
      final content = video.content as EditingVideoContent;
      expect(content.transform.scale, .4);
      expect(content.transform.x, closeTo(.74, 1e-9));
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
      expect(built.document.clips.last.content.toJson(), {
        'kind': 'text',
        'text': 'After',
        'style': 'title',
        'position': 'center',
      });
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
          'fields': {'opacity': .5},
        },
        {
          'op': 'update_clip',
          'clip_id': 'main',
          'fields': {'x': .5},
        },
      ]) {
        await expectLater(
          engine.apply(built.document, 'A', [command]),
          throwsFormatException,
        );
      }
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

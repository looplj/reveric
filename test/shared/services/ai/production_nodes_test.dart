// 职责: 验证视频节点命令的当前素材解析、无需文件审批、派生产物及取消边界。
// 关联文件:
//   lib/shared/services/ai/media/nodes.dart
//   lib/shared/services/production/video_tool_orchestrator.dart
//   lib/shared/services/ai/tools_run.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/agent/tool_approval.dart';
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/models/tool_permission.dart';
import 'package:reveric/shared/services/ai/media/production.dart';
import 'package:reveric/shared/services/ai/tool_operations.dart';
import 'package:reveric/shared/services/ai/tools.dart';
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
import 'package:reveric/shared/services/tool_permission_gate.dart';
import 'package:reveric/shared/services/tool_permissions.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NovelContentDatabase db;
  late app.AppDatabase appDb;
  late Directory root;
  late _Canvas canvas;
  late CanvasNode node;
  late String episode;
  late _Runner runner;
  late ToolOperationManager operations;
  late ToolOperationRegistry registry;
  late ToolPermissionService permissions;
  late AiToolApprovalController approvals;
  late AiToolManager tools;
  final context = ToolExecutionContext(
    sessionId: 'owner',
    sourceTurnId: 'turn',
  );

  Future<void> asset(String id, {String work = 'work'}) async {
    final path = 'file_workspaces/$work/videos/$id.mp4';
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsString(id);
    await appDb.assetDao.insertAsset(
      app.AssetsCompanion.insert(
        id: id,
        type: 'video',
        name: Value(id),
        path: Value(path),
        novelId: Value(work),
        purpose: 'general',
        content: const Value(VideoAssetContent(mimeType: 'video/mp4')),
      ),
    );
  }

  /// 除截帧外的媒体处理固定后台执行；默认等待同一 run 结束，[wait] 为 false 时返回提交回执。
  Future<Map<String, dynamic>> run(
    String action, [
    Map<String, dynamic> options = const {},
    bool wait = true,
  ]) async {
    final response = await tools.executeTool(
      name: 'Run',
      callId: 'call-$action',
      context: context,
      input: {
        'command': 'production',
        'subcommand': action,
        'options': {'node_id': node.id, ...options},
      },
    );
    final runId = response['run_id'];
    if (!wait || runId is! String || response['background'] != true) {
      return response;
    }
    return operations.wait(runId, context);
  }

  Future<Map<String, dynamic>> createMedia(String path, {String? content}) =>
      tools.executeTool(
        name: 'Create',
        callId: 'call-import-media',
        context: context,
        input: {
          'path': 'episodes/$episode/production/canvas/nodes',
          'fields': {'type': 'media', 'path': path, 'content': ?content},
        },
      );

  setUp(() async {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    appDb = app.AppDatabase.forTest(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('production-nodes-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => root.path);
    await RevericPaths.initialize();
    episode = (await ScreenplayService(db).createInitialStructure()).episodeId;
    runner = _Runner();
    canvas = _Canvas(
      StoryboardService(db),
      MediaLibraryService(appDb, MediaService(runner), root),
      'work',
    );
    await asset('source');
    final entry = await canvas.ensureCanvas(episode);
    node = await canvas.addMedia(entry.id, 'source');
    await appDb
        .into(appDb.novels)
        .insert(
          app.NovelsCompanion.insert(
            id: 'work',
            title: 'Work',
            description: '',
          ),
        );
    await appDb
        .into(appDb.aiChatSessions)
        .insert(
          app.AiChatSessionsCompanion.insert(id: 'owner', novelId: 'work'),
        );
    permissions = ToolPermissionService(
      appDb,
      episodeExists: (work, id) async =>
          work == 'work' && await db.screenplayDao.getEpisode(id) != null,
    );
    await permissions.setRule(
      'files.read',
      const ToolPermissionScope.global(),
      ToolPermissionDecision.allow,
    );
    approvals = AiToolApprovalController();
    registry = ToolOperationRegistry();
    operations = ToolOperationManager(
      ownerSessionId: 'owner',
      registry: registry,
      gate: () => ToolPermissionGate(permissions, approvals, enabled: true),
      onChanged: (_) {},
      onRecord: (_) {},
    );
    final content = NovelContentService(db);
    tools = AiToolManager(
      content,
      workingOverlayService: WorkingOverlayService(
        db,
        content,
        novelActionsService: NovelActionsService(appDb),
      ),
      contentKind: 'screenplay',
      sessionId: 'owner',
      workId: 'work',
      operationHost: ToolOperationHost(
        operations,
        production: () async => ProductionToolHost(
          canvas: canvas,
          images: _Images(),
          audio: _Audio(),
          video: () => throw StateError('No remote generation'),
          results: ProductionResultService(appDb, (_) async => canvas),
        ),
      ),
    )..registerAllTools();
  });

  tearDown(() async {
    tools.dispose();
    operations.dispose();
    registry.dispose();
    approvals.dispose();
    await db.close();
    await appDb.close();
    await root.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
  });

  test(
    'canvas edits can commit while an external media import awaits approval',
    () async {
      await permissions.setRule(
        'files.read',
        const ToolPermissionScope.global(),
        ToolPermissionDecision.ask,
      );
      final file = File.fromUri(root.uri.resolve('external.mp4'));
      await file.writeAsString('external video');
      final waiting = approvals.stream
          .firstWhere((pending) => pending.isNotEmpty)
          .timeout(const Duration(seconds: 5));
      final importing = createMedia(file.path);
      final approval = (await waiting).single;
      final editing = canvas.addText(
        node.canvasId,
        title: 'While approval is pending',
      );
      try {
        final text = await editing.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('Canvas edit is blocked by file approval'),
        );
        expect(await db.canvasDao.getNodeById(text.id), isNotNull);
        expect(approvals.pending, [approval]);
      } finally {
        await approvals.resolve(approval, allow: true);
        await importing;
        await editing;
      }
      final result = await importing;
      expect(result['ok'], true, reason: '$result');
      final media = await canvas.requireNode(result['id'] as String);
      expect(media.canvasId, node.canvasId);
      final imported = await canvas.requireAsset(media.mediaAssetId!);
      expect(
        await File(canvas.library.resolve(imported)).readAsString(),
        'external video',
      );
    },
  );

  test(
    'invalid media node fields are rejected before reading the file',
    () async {
      final result = await createMedia(
        'file_workspaces/work/videos/source.mp4',
        content: 'Only text nodes accept content',
      );
      expect(result['ok'], false, reason: '$result');
      expect(runner.probes, 0);
      expect(await db.canvasDao.getNodesByCanvas(node.canvasId), hasLength(1));
    },
  );

  test(
    'four video commands create persistent nodes and real derived edges without changing the source',
    () async {
      for (final entry in [
        ('capture-frame', {'position': 'first'}),
        ('capture-frame', {'position': 'last'}),
        ('capture-frame', {'position': 'at', 'at_ms': 1499}),
        ('separate-audio', <String, dynamic>{}),
        ('mute-video', <String, dynamic>{}),
        ('trim-video', {'start_ms': 0, 'end_ms': 1500}),
      ]) {
        final response = await run(entry.$1, entry.$2);
        expect(response['ok'], true, reason: '$response');
        final result = response['result'] as Map;
        expect(result['source_asset_id'], 'source');
        expect(result['source_node_id'], node.id);
        final output = (result['outputs'] as List).single as Map;
        expect(
          output['node_path'],
          '/episodes/$episode/production/canvas/nodes/${output['node_id']}',
        );
        final saved = await canvas.requireNode(output['node_id'] as String);
        expect(saved.canvasId, node.canvasId);
        expect(saved.mediaAssetId, output['asset_id']);
        expect(
          await File('${root.path}/${output['file_path']}').exists(),
          true,
        );
        final edges = await db.select(db.canvasEdges).get();
        expect(
          edges.where(
            (e) =>
                e.sourceNodeId == node.id &&
                e.targetNodeId == saved.id &&
                e.type == 'derived_output',
          ),
          hasLength(1),
        );
        expect((await canvas.requireNode(node.id)).mediaAssetId, 'source');
      }
      expect(
        await File(
          '${root.path}/file_workspaces/work/videos/source.mp4',
        ).readAsString(),
        'source',
      );
    },
  );

  test(
    'rejects invalid options and measured boundaries without processing',
    () async {
      for (final entry in [
        ('capture-frame', {'position': 'first', 'at_ms': 0}),
        ('capture-frame', {'position': 'at', 'at_ms': 0.5}),
        ('capture-frame', {'position': 'at', 'at_ms': 1500}),
        ('capture-frame', {'position': 'at', 'at_ms': -1}),
        ('capture-frame', {'position': 'first', 'clip_id': 'fake'}),
        ('trim-video', {'start_ms': 100, 'end_ms': 100}),
        ('trim-video', {'start_ms': 0, 'end_ms': 1501}),
      ]) {
        final response = await run(entry.$1, entry.$2);
        expect(response['error_code'], 'invalid_argument', reason: '$response');
      }
      expect(runner.encodes, 0);
      runner.audio = false;
      for (final action in ['mute-video', 'separate-audio']) {
        expect((await run(action))['error_code'], 'no_audio');
      }
      expect(runner.encodes, 0);
    },
  );

  test('measured video boundaries retain actionable error messages', () async {
    for (final (action, options, message) in [
      (
        'capture-frame',
        {'position': 'at', 'at_ms': 1500},
        'at_ms must be strictly before the measured video duration',
      ),
      (
        'trim-video',
        {'start_ms': 0, 'end_ms': 1501},
        'end_ms exceeds the measured video duration',
      ),
    ]) {
      final response = await run(action, options);
      final diagnostic = 'invalid_argument: $message';
      expect(response['error_code'], 'invalid_argument');
      expect(response['error'], diagnostic);
      expect(response['result']['failures'][0]['error'], diagnostic);
    }
    expect(runner.encodes, 0);
  });

  test('missing video node retains the original business error code', () async {
    final response = await run('mute-video', {'node_id': 'missing-node'});
    expect(response['error_code'], 'not_found');
    expect(
      response['error'],
      'StoryboardException(source_missing: Canvas node missing-node was not found.)',
    );
    expect(runner.probes, 0);
  });

  test('video processing retains business failure diagnostics', () async {
    runner.encode = (_, _) async =>
        throw const StoryboardException('request_conflict');
    final response = await run('mute-video');
    expect(response['error_code'], 'failed_precondition');
    expect(response['error'], 'StoryboardException(request_conflict)');
    expect(response['result']['failures'][0]['stage'], 'process');
    expect(
      response['result']['failures'][0]['error'],
      'StoryboardException(request_conflict)',
    );
  });

  test(
    'generation nodes use their currently adopted video without file approval',
    () async {
      node = await canvas.addFree(
        node.canvasId,
        overlay: tools.workingOverlayService,
      );
      await canvas.adopt(node.id, 'source');
      expect((await run('capture-frame', {'position': 'first'}))['ok'], true);
      expect(
        (await canvas.shots.getShot(node.clipId!))!.adoptedAssetId,
        'source',
      );
      await permissions.setRule(
        'files.read',
        const ToolPermissionScope.global(),
        ToolPermissionDecision.deny,
      );
      await asset('next');
      await canvas.adopt(node.id, 'next');
      final response = await run('mute-video');
      expect(response['ok'], true, reason: '$response');
      expect(response['result']['source_asset_id'], 'next');
      expect(approvals.pending, isEmpty);
    },
  );

  test('late cancellation retains the committed output and source', () async {
    canvas.onDerived = () {
      final active = operations.state.runs.singleWhere((r) => !r.terminal);
      operations.cancel(active.runId, context);
    };
    final response = await run('mute-video');
    expect(response['status'], 'cancelled');
    final output = (response['result']['outputs'] as List).single;
    expect(
      (await canvas.requireNode(output['node_id'] as String)).mediaAssetId,
      output['asset_id'],
    );
    expect((await canvas.requireNode(node.id)).mediaAssetId, 'source');
  });

  test(
    'source changes during processing do not discard the completed derived output',
    () async {
      await asset('replacement');
      runner.encode = (args, token) async {
        await db.canvasDao.updateActiveNodeFields(
          node.id,
          const CanvasNodesCompanion(refId: Value('replacement')),
        );
        await File(args.last).writeAsString('processed original');
        return '';
      };
      final response = await run('mute-video');
      expect(response['ok'], true, reason: '$response');
      expect(response['result']['source_asset_id'], 'source');
      final output = (response['result']['outputs'] as List).single;
      expect(
        await File('${root.path}/${output['file_path']}').readAsString(),
        'processed original',
      );
      expect((await canvas.requireNode(node.id)).mediaAssetId, 'replacement');
      expect(await db.select(db.canvasEdges).get(), hasLength(1));
    },
  );

  test(
    'local video node commands ignore external file permission rules',
    () async {
      await permissions.setRule(
        'files.read',
        const ToolPermissionScope.global(),
        ToolPermissionDecision.deny,
      );
      for (final (action, options) in [
        ('capture-frame', {'position': 'first'}),
        ('separate-audio', <String, dynamic>{}),
        ('mute-video', <String, dynamic>{}),
        ('trim-video', {'start_ms': 0, 'end_ms': 1000}),
      ]) {
        expect((await run(action, options))['ok'], true);
      }
      expect(runner.encodes, 4);
      expect(approvals.pending, isEmpty);
    },
  );

  for (final change in ['asset', 'file', 'node', 'invalid-path']) {
    test(
      'video commands resolve current $change state without approval',
      () async {
        await permissions.setRule(
          'files.read',
          const ToolPermissionScope.global(),
          ToolPermissionDecision.ask,
        );
        if (change == 'asset') {
          await asset('replacement');
          await db.canvasDao.updateActiveNodeFields(
            node.id,
            const CanvasNodesCompanion(refId: Value('replacement')),
          );
        } else if (change == 'file') {
          await File(
            '${root.path}/file_workspaces/work/videos/source.mp4',
          ).writeAsString('changed bytes');
        } else if (change == 'invalid-path') {
          await (appDb.update(appDb.assets)
                ..where((t) => t.id.equals('source')))
              .write(const app.AssetsCompanion(path: Value('invalid-source')));
        } else {
          await db.canvasDao.updateActiveNodeFields(
            node.id,
            CanvasNodesCompanion(deletedAt: Value(DateTime.now())),
          );
        }
        final response = await run(
          'mute-video',
        ).timeout(const Duration(seconds: 5));
        expect(
          response['ok'],
          change == 'asset' || change == 'file',
          reason: '$response',
        );
        expect(approvals.pending, isEmpty);
        if (change == 'asset') {
          expect(response['result']['source_asset_id'], 'replacement');
        }
        if (change == 'node' || change == 'invalid-path') {
          expect(runner.probes, 0);
        }
      },
    );
  }

  test(
    'foreign work assets and nodes from invalid canvases cannot be processed',
    () async {
      await asset('foreign', work: 'other');
      await db.canvasDao.updateActiveNodeFields(
        node.id,
        const CanvasNodesCompanion(refId: Value('foreign')),
      );
      expect((await run('mute-video'))['ok'], false);
      await db.canvasDao.updateActiveNodeFields(
        node.id,
        const CanvasNodesCompanion(
          refId: Value('source'),
          canvasId: Value('other'),
        ),
      );
      expect((await run('mute-video'))['ok'], false);
      expect(runner.probes, 0);
    },
  );

  test(
    'probe timeout keeps operation running until native completion and reports timeout',
    () async {
      final stopped = Completer<void>();
      final native = Completer<String>();
      runner.probing = (args, token) async {
        await token.bind(() async {
          stopped.complete();
        });
        return native.future;
      };
      final started = await runZoned(
        () => run('mute-video', const {}, false),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) =>
              parent.createTimer(
                zone,
                duration == const Duration(seconds: 30)
                    ? const Duration(milliseconds: 1)
                    : duration,
                callback,
              ),
        ),
      );
      final id = started['run_id'] as String;
      await stopped.future;
      await Future<void>.delayed(Duration.zero);
      final beforeNative = operations.read(id, context)['status'];
      native.completeError(const MediaException(MediaFailure.cancelled));
      final done = await operations.wait(id, context);
      expect(beforeNative, 'running');
      expect(done['status'], 'failed');
      expect(done['error_code'], 'timeout');
      expect(done['result']['cancelled'], isNull);
      expect(done['result']['outputs'], isEmpty);
    },
  );

  test(
    'cancel waits for native callback and preserves native diagnostics',
    () async {
      final started = Completer<void>();
      final native = Completer<String>();
      var cancellationRequested = false;
      runner.encode = (args, token) async {
        await token.bind(() async {
          cancellationRequested = true;
        });
        started.complete();
        return native.future;
      };
      final response = await run('mute-video', const {}, false);
      final id = response['run_id'] as String;
      await started.future;
      operations.cancel(id, context);
      expect(cancellationRequested, true);
      expect(operations.read(id, context)['status'], 'cancelling');
      native.completeError(const MediaException(MediaFailure.cancelled));
      final done = await operations.wait(id, context);
      expect(done['status'], 'cancelled');
      expect(done['result']['outputs'], isEmpty);
      expect(await db.select(db.canvasNodes).get(), hasLength(1));
      runner.encode = (_, _) async => throw const MediaException(
        MediaFailure.encoding_failed,
        nativeSessionId: 42,
        nativeExitCode: 7,
        nativeLog: 'encoder diagnostic',
        message: 'encoder refused',
      );
      final failed = await run('mute-video');
      expect(failed['error_code'], 'encoding_failed');
      expect(failed['result']['log'], 'encoder diagnostic');
      expect(failed['result']['exit_code'], 7);
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

class _Runner extends FfmpegRunner {
  int probes = 0, encodes = 0;
  bool audio = true;
  Future<String> Function(List<String>, MediaCancellation)? probing;
  Future<String> Function(List<String>, MediaCancellation)? encode;
  @override
  Future<String> execute(
    List<String> args, {
    required bool probe,
    required MediaCancellation cancellation,
  }) async {
    if (cancellation.cancelled) {
      throw const MediaException(MediaFailure.cancelled);
    }
    if (probe) {
      probes++;
      if (probing != null) {
        return probing!(args, cancellation);
      }
      final audioOnly = args.last.endsWith('.m4a');
      return jsonEncode({
        'format': {'duration': '1.5', 'format_name': 'mov,mp4,m4a'},
        'streams': [
          if (!audioOnly)
            {
              'codec_type': 'video',
              'codec_name': 'h264',
              'width': 2,
              'height': 2,
              'avg_frame_rate': '24/1',
            },
          if (audio) {'codec_type': 'audio', 'codec_name': 'aac'},
        ],
      });
    }
    encodes++;
    if (encode != null) {
      return encode!(args, cancellation);
    }
    final file = File(args.last);
    await file.writeAsBytes(
      args.last.endsWith('.png')
          ? img.encodePng(img.Image(width: 2, height: 2))
          : utf8.encode('encoded $encodes'),
    );
    return '';
  }
}

class _Canvas extends ProductionCanvasService {
  _Canvas(super.shots, super.library, super.novelId);
  void Function()? onDerived;
  @override
  Future<CanvasNode> addDerivedOutput(
    String sourceNodeId,
    String assetId, {
    ProductionNodePlacement? placement,
    String? title,
  }) async {
    final node = await super.addDerivedOutput(
      sourceNodeId,
      assetId,
      placement: placement,
      title: title,
    );
    onDerived?.call();
    return node;
  }
}

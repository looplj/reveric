// 职责: 验证 Agent 草稿生成、能力发现、高清授权和任务回读的完整工具链。
// 关联文件:
//   lib/shared/services/ai/media/production.dart
//   lib/shared/services/ai/provider_resources.dart
//   lib/shared/services/ai/video/task_service.dart
//   lib/shared/services/ai/tools_production.dart
import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/agent/tool_approval.dart';
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/models/tool_permission.dart';
import 'package:reveric/shared/services/ai/media/production.dart';
import 'package:reveric/shared/services/ai/tool_operations.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/ai/video/task_service.dart';
import 'package:reveric/shared/services/ai/video/reference_storage_service.dart';
import 'package:reveric/shared/services/object_storage/service.dart';
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
  late ProductionCanvasService canvas;
  late ProductionClipRow clip;
  late AiToolManager tools;
  late VideoTaskService video;
  late ToolOperationManager operations;
  late ToolOperationRegistry registry;
  late ToolPermissionService permissions;
  late AiToolApprovalController approvals;
  late AiProvider provider;
  late DateTime now;
  var call = 0;
  var loseReceipt = false;
  final bodies = <Map<String, dynamic>>[];
  final context = ToolExecutionContext(
    sessionId: 'owner',
    sourceTurnId: 'turn',
  );
  const model = 'bytedance/seedance-2.5';

  setUp(() async {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    appDb = app.AppDatabase.forTest(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('agent-video-draft-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await RevericPaths.initialize();
    now = DateTime(2026, 10, 20);
    bodies.clear();
    loseReceipt = false;
    call = 0;
    canvas = ProductionCanvasService(
      StoryboardService(db),
      MediaLibraryService(appDb, MediaService(FfmpegRunner()), root),
      'work',
    );
    final episode = (await ScreenplayService(
      db,
    ).createInitialStructure()).episodeId;
    clip = await canvas.shots.createVideo(
      episode,
      values: {
        'provider_id': 'atlas',
        'model_id': model,
        'prompt': 'original scene',
        'ratio': '16:9',
        'resolution': '720p',
        'duration_ms': 5000,
      },
    );
    await canvas.ensureShotNode(clip.id);
    provider = aiProviderBuiltinById('openai')!.copyWith(
      id: 'atlas',
      type: 'atlascloud',
      enabled: true,
      apiKey: 'test-key',
      videoModels: [model, 'bytedance/seedance-2.0', 'unknown-model'],
    );
    await appDb.aiProviderDao.upsert(provider);
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
      'generation.video',
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
    final results = ProductionResultService(appDb, (_) async => canvas);
    video = VideoTaskService(
      database: appDb,
      rootDirectory: root,

      now: () => now,
      beforeCreate: results.beforeCreate,
      beforeSubmit: results.beforeSubmit,
      recoverSources: results.recover,
      probeResult: (_) async => const MediaInfo(
        duration: Duration(seconds: 5),
        hasVideo: true,
        hasAudio: true,
        width: 1920,
        height: 1080,
      ),
      references: ReferenceStorageService(
        database: appDb,
        storage: ObjectStorageService(database: appDb),
        probe: (_) => throw StateError('No reference upload expected'),
      ),
      providerTransport: (_) => MockClient((request) async {
        if (request.method == 'POST') {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          if (loseReceipt) {
            throw const SocketException('Receipt lost');
          }
          return http.Response(
            jsonEncode({
              'code': 200,
              'data': {'id': 'remote-${bodies.length}'},
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'code': 200,
            'data': {
              'status': 'completed',
              'outputs': [
                'https://result.test/${request.url.pathSegments.last}.mp4',
              ],
            },
          }),
          200,
        );
      }),
      downloadTransport: (_) =>
          MockClient((_) async => http.Response.bytes([1, 2, 3], 200)),
    );
    final host = ProductionToolHost(
      canvas: canvas,
      images: _Images(),
      audio: _Audio(),
      video: () async => video,
      results: results,
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
      providerReader: () async => [provider],

      operationHost: ToolOperationHost(
        operations,
        production: () async => host,
      ),
    )..registerAllTools();
  });
  tearDown(() async {
    await video.shutdown();
    tools.dispose();
    operations.dispose();
    registry.dispose();
    approvals.dispose();
    await db.close();
    await appDb.close();
    await root.delete(recursive: true);
  });

  Future<Map<String, dynamic>> generate(
    Map<String, dynamic> options, {
    String kind = 'video',
  }) => tools.executeTool(
    name: 'Run',
    callId: 'call-${++call}',
    context: context,
    input: {
      'command': 'production',
      'subcommand': 'generate-$kind',
      'options': {'clip_id': clip.id, ...options},
    },
  );
  Future<app.GenerationTask> running(Map<String, dynamic> receipt) async {
    expect(receipt['run_id'], isA<String>(), reason: '$receipt');
    final task = await appDb.generationTaskDao
        .watchSource(
          novelId: 'work',
          sourceType: 'production_clip',
          sourceId: clip.id,
        )
        .map(
          (rows) => rows
              .where((task) => task.status == app.GenerationTaskStatus.running)
              .firstOrNull,
        )
        .firstWhere((task) => task != null)
        .timeout(const Duration(seconds: 10));
    await video.submit(
      task!.id,
    ); // Wait for the original POST owner to release the task.
    return task;
  }

  Future<Map<String, dynamic>> finish(Map<String, dynamic> receipt) async {
    final task = await running(receipt);
    await video.refresh(task.id);
    final done = await operations
        .wait(receipt['run_id'] as String, context)
        .timeout(const Duration(seconds: 10));
    expect(done['ok'], true, reason: '$done');
    return (done['result'] as Map).cast<String, dynamic>();
  }

  Future<Map<String, dynamic>> readTask(String id) => tools.executeTool(
    name: 'Read',
    context: context,
    input: {'path': '/clips/${clip.id}/generations/$id'},
  );

  test(
    'Agent discovers supported drafts, generates one, and reads its completion eligibility',
    () async {
      final schema = jsonEncode(
        tools.allToolDefs().map((def) => def.inputSchema).toList(),
      );
      final listing = await tools.executeTool(
        name: 'Run',
        context: context,
        input: {
          'command': 'providers',
          'subcommand': 'models',
          'options': {'provider_id': 'atlas', 'kind': 'video'},
        },
      );
      final entries = listing['entries'] as List;
      expect(entries[0]['capabilities']['supports_draft'], true);
      expect(entries[0]['capabilities']['draft'], {
        'resolution': '480p',
        'completion_resolution': '1080p',
        'validity_days': 7,
        'output_formats': ['mp4'],
      });
      expect(entries[1]['capabilities']['supports_draft'], false);
      expect(entries[2]['capabilities'], isNull);
      final result = await finish(await generate({'draft': true}));
      expect(bodies.single['draft'], true);
      expect(bodies.single['resolution'], '480p');
      expect(result['draft'], true);
      expect(result['draft_task_id'], isNull);
      expect(result['result_applied'], true);
      expect(result['can_complete_draft'], true);
      expect(
        DateTime.parse(result['draft_expires_at'] as String),
        now.add(const Duration(days: 7)),
      );
      final record = await readTask(result['task_id'] as String);
      expect(record['draft'], true, reason: '$record');
      expect(record['can_complete_draft'], true);
      expect((await canvas.shots.getShot(clip.id))!.resolution, '720p');
      final normal = await finish(await generate({}));
      expect(normal['draft'], false);
      expect(bodies.last.containsKey('draft'), false);
      expect(bodies.last['resolution'], '720p');
      expect(
        jsonEncode(tools.allToolDefs().map((def) => def.inputSchema).toList()),
        schema,
      );
    },
  );

  test(
    'HD approval uses the original draft after node edits, preserves history and blocks duplicates',
    () async {
      final draft = await finish(await generate({'draft': true}));
      final draftId = draft['task_id'] as String;
      await permissions.setRule(
        'generation.video',
        const ToolPermissionScope.global(),
        ToolPermissionDecision.ask,
      );
      final waiting = approvals.stream.firstWhere((items) => items.isNotEmpty);
      final receipt = await generate({'draft_task_id': draftId});
      final approval = (await waiting).single;
      expect(approval.action, 'generation.video');
      expect(approval.arguments['resolution'], '1080p');
      expect(approval.arguments['prompt'], 'original scene');
      expect(bodies, hasLength(1));
      await (db.update(
        db.productionClips,
      )..where((row) => row.id.equals(clip.id))).write(
        const ProductionClipsCompanion(
          prompt: Value('new prompt'),
          modelId: Value('invalid-current-model'),
        ),
      );
      await approvals.resolve(approval, allow: true);
      final task = await running(receipt);
      expect((await readTask(draftId))['can_complete_draft'], false);
      final duplicate = await generate({'draft_task_id': draftId});
      expect(
        duplicate['error_code'],
        'draft_active_task',
        reason: '$duplicate',
      );
      expect(
        (await canvas.shots.getShot(clip.id))!.adoptedAssetId,
        draft['result_asset_id'],
      );
      await video.refresh(task.id);
      final done = await operations.wait(receipt['run_id'] as String, context);
      final result = done['result'] as Map;
      expect(result['draft'], false);
      expect(result['draft_task_id'], draftId);
      expect(result['result_applied'], true);
      expect(bodies.last, {
        'model': '$model/draft-complete',
        'draft_id': 'remote-1',
        'output_format': 'mp4',
      });
      expect((await readTask(draftId))['can_complete_draft'], true);
      final node = await canvas.ensureShotNode(clip.id);
      await canvas.adoptGenerated(node.id, draftId);
      expect(
        (await canvas.shots.getShot(clip.id))!.adoptedAssetId,
        draft['result_asset_id'],
      );
    },
  );

  test(
    'invalid draft options and unrelated drafts never create a task',
    () async {
      for (final options in [
        {'draft': 'true'},
        {'draft': null},
        {'draft_task_id': ''},
        {'draft_task_id': 3},
        {'draft': true, 'draft_task_id': 'gen_AAAAAA'},
      ]) {
        final result = await generate(options);
        expect(result['error_code'], 'invalid_argument', reason: '$result');
      }
      expect(
        (await generate({'draft': true}, kind: 'image'))['error_code'],
        'invalid_argument',
      );
      expect(
        (await generate({
          'draft_task_id': 'gen_AAAAAA',
        }, kind: 'audio'))['error_code'],
        'invalid_argument',
      );
      expect(
        (await generate({'draft_task_id': 'gen_AAAAAA'}))['error_code'],
        'not_found',
      );
      expect(await appDb.select(appDb.generationTasks).get(), isEmpty);
      await (db.update(
        db.productionClips,
      )..where((row) => row.id.equals(clip.id))).write(
        const ProductionClipsCompanion(
          modelId: Value('bytedance/seedance-2.0'),
        ),
      );
      expect((await generate({'draft': true}))['error_code'], 'draft');
      expect(bodies, isEmpty);
      await (db.update(db.productionClips)
            ..where((row) => row.id.equals(clip.id)))
          .write(const ProductionClipsCompanion(modelId: Value(model)));
      final draft = await finish(await generate({'draft': true}));
      final other = await canvas.shots.createVideo(clip.episodeId);
      await canvas.ensureShotNode(other.id);
      final rejected = await generate({
        'clip_id': other.id,
        'draft_task_id': draft['task_id'],
      });
      expect(rejected['error_code'], 'not_found');
      final source = (await appDb.generationTaskDao.getById(
        draft['task_id'] as String,
      ))!;
      await appDb
          .into(appDb.generationTasks)
          .insert(
            source
                .copyWith(id: 'foreign', novelId: 'another-work')
                .toCompanion(true),
          );
      expect(
        (await generate({'draft_task_id': 'foreign'}))['error_code'],
        'not_found',
      );
      expect(bodies, hasLength(1));
    },
  );

  test('expiry during approval is rechecked without a paid request', () async {
    final draft = await finish(await generate({'draft': true}));
    final id = draft['task_id'] as String;
    await permissions.setRule(
      'generation.video',
      const ToolPermissionScope.global(),
      ToolPermissionDecision.ask,
    );
    final waiting = approvals.stream.firstWhere((items) => items.isNotEmpty);
    final receipt = await generate({'draft_task_id': id});
    final approval = (await waiting).single;
    now = now.add(const Duration(days: 7));
    final read = await readTask(id);
    expect(read['can_complete_draft'], false);
    expect(read['draft_completion_blocked_reason'], 'draft_expired');
    await approvals.resolve(approval, allow: true);
    final done = await operations.wait(receipt['run_id'] as String, context);
    expect(done['result']['error_code'], 'draft_expired', reason: '$done');
    expect(
      (await generate({'draft_task_id': id}))['error_code'],
      'draft_expired',
    );
    expect(bodies, hasLength(1));
    expect(
      (await canvas.shots.getShot(clip.id))!.adoptedAssetId,
      draft['result_asset_id'],
    );
  });

  test('denied and cancelled approvals never submit a draft', () async {
    await permissions.setRule(
      'generation.video',
      const ToolPermissionScope.global(),
      ToolPermissionDecision.deny,
    );
    final deniedReceipt = await generate({'draft': true});
    final denied = await operations.wait(
      deniedReceipt['run_id'] as String,
      context,
    );
    expect(denied['ok'], false, reason: '$denied');
    expect(bodies, isEmpty);
    await permissions.setRule(
      'generation.video',
      const ToolPermissionScope.global(),
      ToolPermissionDecision.ask,
    );
    final waiting = approvals.stream.firstWhere((items) => items.isNotEmpty);
    final receipt = await generate({'draft': true});
    await waiting;
    operations.cancel(receipt['run_id'] as String, context);
    final cancelled = await operations.wait(
      receipt['run_id'] as String,
      context,
    );
    expect(cancelled['result']['cancelled'], true);
    expect(bodies, isEmpty);
    expect(await appDb.select(appDb.generationTasks).get(), isEmpty);
  });

  test('cancelling an active HD run preserves the adopted draft', () async {
    final draft = await finish(await generate({'draft': true}));
    final receipt = await generate({'draft_task_id': draft['task_id']});
    final hd = await running(receipt);
    operations.cancel(receipt['run_id'] as String, context);
    final cancelled = await operations.wait(
      receipt['run_id'] as String,
      context,
    );
    expect(cancelled['result']['cancelled'], true);
    expect(
      (await appDb.generationTaskDao.getById(hd.id))!.cancelRequestedAt,
      isNotNull,
    );
    await video.refresh(hd.id);
    expect(
      (await canvas.shots.getShot(clip.id))!.adoptedAssetId,
      draft['result_asset_id'],
    );
    expect(
      (await appDb.generationTaskDao.getById(
        draft['task_id'] as String,
      ))!.cancelRequestedAt,
      isNull,
    );
    expect(bodies, hasLength(2));
  });

  test(
    'unknown HD submission exposes diagnostics and prevents a second paid attempt',
    () async {
      final draft = await finish(await generate({'draft': true}));
      loseReceipt = true;
      final receipt = await generate({'draft_task_id': draft['task_id']});
      final done = await operations
          .wait(receipt['run_id'] as String, context)
          .timeout(const Duration(seconds: 10));
      expect(done['result']['error_code'], 'submission_unknown');
      expect(
        done['result']['error'],
        contains('VideoException(submission_unknown'),
      );
      expect(done['result']['task_id'], isNotNull);
      expect(
        (await generate({'draft_task_id': draft['task_id']}))['error_code'],
        'draft_active_task',
      );
      expect(bodies, hasLength(2));
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

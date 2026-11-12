// 职责: 验证图片节点命令的草稿、生成授权、当前来源、真实生成结果及宫格部分失败和取消。
// 关联文件:
//   lib/shared/services/ai/media/image_nodes.dart
//   lib/shared/services/production/grid_orchestrator.dart
//   lib/shared/services/production/view_derive_orchestrator.dart
//   lib/shared/services/production/derived_placement.dart
//   lib/desktop/features/production/grid/group_bar.dart
import 'dart:async';
import 'dart:io';
import 'package:reveric/shared/services/production/derived_placement.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/desktop/features/production/grid/group_bar.dart';
import 'package:reveric/shared/agent/tool_approval.dart';
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/models/tool_permission.dart';
import 'package:reveric/shared/models/production/view_presets.dart';
import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/services/ai/image.dart';
import 'package:reveric/shared/services/ai/media/production.dart';
import 'package:reveric/shared/services/ai/tool_operations.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/image_library_service.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/production/audio_service.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/image_generate_orchestrator.dart';
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
  late CanvasNode node;
  late String episode, sourceAsset;
  late ToolOperationManager operations;
  late ToolOperationRegistry registry;
  late ToolPermissionService permissions;
  late AiToolApprovalController approvals;
  late AiToolManager tools;
  late ImageTaskService jobs;
  late ProductionImageInvoke invoke;
  late Future<void> Function(String, String, String) beforeCreate;
  late List<ProductionImageRequest> requests;
  final context = ToolExecutionContext(
    sessionId: 'owner',
    sourceTurnId: 'turn',
  );
  const model = {'provider_id': 'images', 'model_id': 'gpt-image-2'};

  /// 生成类命令固定后台执行；默认等待同一 run 结束，[wait] 为 false 时返回提交回执。
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
    if (!wait || runId is! String) {
      return response;
    }
    return operations.wait(runId, context);
  }

  setUp(() async {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    appDb = app.AppDatabase.forTest(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('image-node-tools-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await RevericPaths.initialize();
    episode = (await ScreenplayService(db).createInitialStructure()).episodeId;
    canvas = ProductionCanvasService(
      StoryboardService(db),
      MediaLibraryService(appDb, MediaService(FfmpegRunner()), root),
      'work',
    );
    final file = await File(
      '${root.path}/source.png',
    ).writeAsBytes(img.encodePng(img.Image(width: 12, height: 6)));
    final asset = await canvas.library.importFile(
      file,
      name: 'Source.png',
      novelId: 'work',
      purpose: AssetPurpose.production_upload,
      cancellation: MediaCancellation(),
    );
    sourceAsset = asset.id;
    node = await canvas.addImage((await canvas.ensureCanvas(episode)).id);
    await canvas.adopt(node.id, sourceAsset);
    final clip = (await canvas.shots.getShot(node.clipId!))!;
    await canvas.shots.apply(clip.id, {
      ...canvas.shots.snapshot(clip),
      'ratio': '1:1',
      'resolution': '2K',
    });
    await appDb
        .into(appDb.aiProviders)
        .insert(
          app.AiProvidersCompanion.insert(
            id: 'images',
            name: 'Images',
            type: 'openai',
            enabled: const Value(true),
            apiKey: const Value('test'),
            imageModels: const Value(['gpt-image-2']),
          ),
        );
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
    for (final capability in ['files.read', 'generation.image']) {
      await permissions.setRule(
        capability,
        const ToolPermissionScope.global(),
        ToolPermissionDecision.allow,
      );
    }
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
    requests = [];
    var generatedFiles = 0;
    invoke = (_, request, _, _) async {
      final index = ++generatedFiles;
      final output = await File('${root.path}/generated-$index.png')
          .writeAsBytes(
            img.encodePng(
              img.Image(width: 8, height: 8)..setPixelRgb(0, 0, index, 50, 90),
            ),
          );
      return AiImageGenerationResult(localFilePath: output.path);
    };
    beforeCreate = results.beforeCreate;
    jobs = ImageTaskService(
      database: appDb,
      images: buildImageLibraryService(appDb),
      invoke: (provider, request, onSubmitted, onOutputs) {
        requests.add(request);
        return invoke(provider, request, onSubmitted, onOutputs);
      },

      beforeCreate: (novelId, sourceType, sourceId) =>
          beforeCreate(novelId, sourceType, sourceId),
      beforeSubmit: results.beforeSubmit,
      recoverSources: results.recover,
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
          images: jobs,
          audio: _Audio(),
          video: () => throw StateError('No video generation'),
          results: results,
        ),
      ),
    )..registerAllTools();
  });

  tearDown(() async {
    await jobs.shutdown();
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
    'every image preset creates a connected editable draft without generation',
    () async {
      for (final method in ImageGenerationMethod.values.where(
        (m) => m != ImageGenerationMethod.free,
      )) {
        final response = await run('image-preset', {'method': method.name});
        expect(response['ok'], true, reason: '$response');
        final output = (response['outputs'] as List).single;
        expect(output['generated'], false);
        expect(output.containsKey('asset_id'), false);
        final created = await canvas.requireNode(output['node_id'] as String);
        expect(ImageGenerationPreset.fromStyle(created.style).method, method);
        final input = (await canvas.draftInputs(created.id)).single;
        expect(input.sourceNodeId, node.id);
        if (method == ImageGenerationMethod.panorama) {
          expect((await canvas.shots.getShot(created.clipId!))!.ratio, '2:1');
        }
        final read = await tools.executeTool(
          name: 'Read',
          input: {'path': output['node_path']},
        );
        expect(read['image_method'], method.name);
      }
      expect(requests, isEmpty);
      expect(await appDb.select(appDb.generationTasks).get(), isEmpty);
      expect(operations.state.runs, isEmpty);
    },
  );

  test(
    'derive view waits for a real generated and adopted asset, preserving source',
    () async {
      for (final preset in ['camera', 'light']) {
        final response = await run('derive-view', {...model, 'preset': preset});
        expect(response['ok'], true, reason: '$response');
        final output = (response['result']['outputs'] as List).single;
        expect(output['generated'], true);
        expect(output['task_id'], isNotNull);
        expect(output['asset_id'], isNotNull);
        expect(output['result_applied'], true);
        expect(requests.last.references.single.assetId, sourceAsset);
        expect(
          (await canvas.shots.getShot(node.clipId!))!.adoptedAssetId,
          sourceAsset,
        );
      }
      expect(requests[0].prompt, contains('相机位于主体正面'));
      expect(requests[1].prompt, contains('只重新布光'));
    },
  );

  test(
    'shared generation rejects an unknown preview before submission',
    () async {
      final host = ProductionToolHost(
        canvas: canvas,
        images: jobs,
        audio: _Audio(),
        video: () => throw StateError('No video generation'),
        results: ProductionResultService(appDb, (_) async => canvas),
      );
      final cancellation = AgentCancellationController();
      final operation = ToolOperationContext(
        cancellation.token,
        ({taskId, progress}) => fail('Unknown previews must not report a task'),
        const {},
      );
      await expectLater(
        host.generate(Object(), node.clipId!, operation),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Unknown generation preview',
          ),
        ),
      );
      expect(await appDb.select(appDb.generationTasks).get(), isEmpty);
      expect(requests, isEmpty);
    },
  );

  test(
    'saved generate-image continues to use the shared generation execution',
    () async {
      final clip = (await canvas.shots.getShot(node.clipId!))!;
      await canvas.shots.apply(clip.id, {
        ...canvas.shots.snapshot(clip),
        ...model,
        'prompt': 'Existing image request',
      });
      final response = await tools
          .executeTool(
            name: 'Run',
            callId: 'saved',
            context: context,
            input: {
              'command': 'production',
              'subcommand': 'generate-image',
              'options': {'clip_id': node.clipId},
            },
          )
          .then((r) => operations.wait(r['run_id'] as String, context));
      expect(response['ok'], true, reason: '$response');
      expect(response['result']['task_id'], isNotNull);
      expect(response['result']['result_applied'], true);
      expect(requests.single.prompt, contains('Existing image request'));
    },
  );

  test(
    'invalid fields are rejected before draft, crop, or task creation',
    () async {
      for (final entry in [
        ('image-preset', {'method': 'free'}),
        ('image-preset', {'method': 'panorama', 'background': true}),
        (
          'derive-view',
          {
            ...model,
            'preset': 'camera',
            'args': {'direction': 'front'},
          },
        ),
        (
          'derive-view',
          {
            ...model,
            'preset': 'camera',
            'args': {'yaw': 1},
          },
        ),
        ('split-grid', {'rows': 1, 'cols': 1}),
        (
          'split-grid',
          {
            'rows': 1,
            'cols': 2,
            'cells': [0, 0],
          },
        ),
        (
          'split-grid',
          {
            'rows': 1,
            'cols': 2,
            'cells': [2],
          },
        ),
        ('split-grid', {'rows': 1, 'cols': 2, 'upscale': 2, ...model}),
        (
          'split-grid',
          {
            'rows': 1,
            'cols': 2,
            'cells': [0],
            'upscale': 3,
            ...model,
          },
        ),
      ]) {
        expect(
          (await run(entry.$1, entry.$2))['error_code'],
          'invalid_argument',
        );
      }
      expect(await db.select(db.canvasNodes).get(), hasLength(1));
      expect(requests, isEmpty);
    },
  );

  for (final multiplier in [2, 4]) {
    test(
      'unsupported ${multiplier}x grid upscale fails before approval',
      () async {
        await (appDb.update(
          appDb.aiProviders,
        )..where((p) => p.id.equals('images'))).write(
          const app.AiProvidersCompanion(imageModels: Value(['gpt-image-1'])),
        );
        for (final capability in ['files.read', 'generation.image']) {
          await permissions.setRule(
            capability,
            const ToolPermissionScope.global(),
            ToolPermissionDecision.ask,
          );
        }
        final assetsBefore = await appDb.select(appDb.assets).get();
        final response = await run('split-grid', {
          'rows': 1,
          'cols': 2,
          'cells': [0],
          'upscale': multiplier,
          'provider_id': 'images',
          'model_id': 'gpt-image-1',
        }, false);
        expect(
          response['error_code'],
          'failed_precondition',
          reason: '$response',
        );
        expect(response['error'], contains('${multiplier}x grid upscale'));
        expect(response['error'], contains('Supported multipliers: none'));
        expect(response.containsKey('run_id'), false);
        expect(approvals.pending, isEmpty);
        expect(operations.state.runs, isEmpty);
        expect(await db.select(db.canvasNodes).get(), hasLength(1));
        expect(
          (await appDb.select(appDb.assets).get()).map((asset) => asset.id),
          assetsBefore.map((asset) => asset.id),
        );
        expect(await appDb.select(appDb.generationTasks).get(), isEmpty);
        expect(requests, isEmpty);
      },
    );
  }

  test('missing image node retains the original business error code', () async {
    final response = await run('image-preset', {
      'node_id': 'missing-node',
      'method': 'panorama',
    });
    expect(response['error_code'], 'failed_precondition');
    expect(response['error'], 'StoryboardException(source_missing)');
    expect(requests, isEmpty);
  });

  test(
    'missing production style retains business failure diagnostics',
    () async {
      await db
          .update(db.screenplays)
          .write(const ScreenplaysCompanion(styleId: Value('missing-style')));
      final response = await run('derive-view', {...model, 'preset': 'camera'});
      expect(response['error_code'], 'failed_precondition');
      expect(response['error'], 'StoryboardException(style_missing)');
      expect(response['result']['failures'][0]['stage'], 'create');
      expect(
        response['result']['failures'][0]['error'],
        'StoryboardException(style_missing)',
      );
      expect(requests, isEmpty);
    },
  );

  test('generation denial still prevents derived drafts and tasks', () async {
    await permissions.setRule(
      'generation.image',
      const ToolPermissionScope.global(),
      ToolPermissionDecision.deny,
    );
    final response = await run('derive-view', {...model, 'preset': 'camera'});
    expect(response['error_code'], 'permission_denied');
    expect(await db.select(db.canvasNodes).get(), hasLength(1));
    expect(requests, isEmpty);
  });

  test(
    'local image node operations ignore file and generation permissions',
    () async {
      for (final capability in ['files.read', 'generation.image']) {
        await permissions.setRule(
          capability,
          const ToolPermissionScope.global(),
          ToolPermissionDecision.deny,
        );
      }
      expect((await run('image-preset', {'method': 'panorama'}))['ok'], true);
      expect((await run('split-grid', {'rows': 1, 'cols': 2}))['ok'], true);
      expect(approvals.pending, isEmpty);
      expect(requests, isEmpty);
    },
  );

  for (final action in ['derive-view', 'split-grid']) {
    test(
      '$action uses source and settings updated during generation approval',
      () async {
        await permissions.setRule(
          'files.read',
          const ToolPermissionScope.global(),
          ToolPermissionDecision.deny,
        );
        await permissions.setRule(
          'generation.image',
          const ToolPermissionScope.global(),
          ToolPermissionDecision.ask,
        );
        final waiting = approvals.stream.firstWhere(
          (items) => items.isNotEmpty,
        );
        final response = await run(action, {
          ...model,
          if (action == 'derive-view') 'preset': 'light',
          if (action == 'split-grid') ...{
            'rows': 1,
            'cols': 2,
            'cells': [0],
            'upscale': 2,
          },
        }, false);
        final approval = (await waiting).single;
        expect(approval.action, 'generation.image');
        expect(requests, isEmpty);
        final replacementFile = await File('${root.path}/replacement.png')
            .writeAsBytes(
              img.encodePng(
                img.Image(width: 12, height: 6)..setPixelRgb(0, 0, 123, 45, 67),
              ),
            );
        final replacement = await canvas.library.importFile(
          replacementFile,
          name: 'Replacement.png',
          novelId: 'work',
          purpose: AssetPurpose.production_upload,
          cancellation: MediaCancellation(),
        );
        await canvas.adopt(node.id, replacement.id);
        final clip = (await canvas.shots.getShot(node.clipId!))!;
        await canvas.shots.apply(clip.id, {
          ...canvas.shots.snapshot(clip),
          'ratio': '16:9',
          'resolution': '4K',
        });
        await approvals.resolve(approval, allow: true);
        final done = await operations.wait(
          response['run_id'] as String,
          context,
        );
        expect(done['ok'], true, reason: '$done');
        expect(done['result']['source_asset_id'], replacement.id);
        final tasks = await appDb
            .select(appDb.generationTasks)
            .watch()
            .firstWhere(
              (rows) =>
                  rows.isNotEmpty && rows.every((row) => row.status.isTerminal),
            );
        expect(tasks, hasLength(1));
        expect(requests, hasLength(1));
        if (action == 'derive-view') {
          expect(requests.single.references.single.assetId, replacement.id);
          expect(requests.single.ratio, '16:9');
          expect(requests.single.resolution, '4K');
        } else {
          final crop = (await appDb.assetDao.getAsset(
            requests.single.references.single.assetId,
          ))!;
          final pixel = img
              .decodeImage(
                await File(canvas.library.resolve(crop)).readAsBytes(),
              )!
              .getPixel(0, 0);
          expect([pixel.r, pixel.g, pixel.b], [123, 45, 67]);
        }
        expect(approvals.pending, isEmpty);
      },
    );
  }

  test(
    'generation still rejects a source without an image after approval',
    () async {
      await permissions.setRule(
        'generation.image',
        const ToolPermissionScope.global(),
        ToolPermissionDecision.ask,
      );
      final waiting = approvals.stream.firstWhere((items) => items.isNotEmpty);
      final response = await run('derive-view', {
        ...model,
        'preset': 'light',
      }, false);
      final approval = (await waiting).single;
      await canvas.unadopt(node.id);
      await approvals.resolve(approval, allow: true);
      final done = await operations.wait(response['run_id'] as String, context);
      expect(done['error_code'], 'failed_precondition');
      expect(done['error'], contains('invalid_reference'));
      expect(requests, isEmpty);
      expect(await db.select(db.canvasNodes).get(), hasLength(1));
    },
  );

  test(
    'local grid sorts original indices, creates group and leaves source unchanged',
    () async {
      final response = await run('split-grid', {
        'rows': 2,
        'cols': 3,
        'cells': [5, 0, 3],
      });
      expect(response['ok'], true, reason: '$response');
      final result = response['result'];
      expect((result['outputs'] as List).map((e) => e['cell']), [0, 3, 5]);
      final group = await canvas.requireNode(result['group_node_id'] as String);
      expect(await canvas.groups.members(group.id), hasLength(3));
      for (final output in result['outputs']) {
        expect(output['asset_id'], isNotNull);
        expect(output['width'], 4);
        expect(output['height'], 3);
      }
      expect(requests, isEmpty);
      expect(
        (await canvas.shots.getShot(node.clipId!))!.adoptedAssetId,
        sourceAsset,
      );
    },
  );

  test(
    'grid upscale submits every cell before generation completes and isolates late failures',
    () async {
      final release = Completer<void>();
      final original = invoke;
      invoke = (provider, request, onSubmitted, onOutputs) async {
        final index = requests.length;
        await release.future;
        if (index == 2) {
          throw const AiImageGenerationException('simulated cell failure');
        }
        return original(provider, request, onSubmitted, onOutputs);
      };
      late List outputs;
      try {
        final response = await run('split-grid', {
          'rows': 1,
          'cols': 3,
          'cells': [2, 0, 1],
          'upscale': 2,
          ...model,
        }).timeout(const Duration(seconds: 5));
        expect(response['ok'], true, reason: '$response');
        expect(response['status'], 'completed');
        final result = response['result'];
        outputs = result['outputs'] as List;
        expect(outputs.map((e) => e['cell']), [0, 1, 2]);
        expect(outputs.map((e) => e['generated']), [false, false, false]);
        expect(outputs.map((e) => e['submitted']), [true, true, true]);
        expect(outputs.every((e) => e['task_id'] is String), true);
        expect(outputs.every((e) => e['asset_id'] == null), true);
        expect(result['failures'], isNull);
        await (appDb.select(appDb.generationTasks))
            .watch()
            .firstWhere(
              (tasks) =>
                  tasks.length == 3 &&
                  tasks.every((task) => task.submittedAt != null),
            )
            .timeout(const Duration(seconds: 5));
        expect(requests, hasLength(3));
      } finally {
        release.complete();
      }
      final tasks = await appDb
          .select(appDb.generationTasks)
          .watch()
          .firstWhere(
            (tasks) =>
                tasks.length == 3 &&
                tasks.every((task) => task.status.isTerminal),
          );
      expect(
        outputs.map(
          (output) =>
              tasks.singleWhere((task) => task.id == output['task_id']).status,
        ),
        [
          app.GenerationTaskStatus.completed,
          app.GenerationTaskStatus.failed,
          app.GenerationTaskStatus.completed,
        ],
      );
      expect(
        tasks
            .singleWhere(
              (task) => task.status == app.GenerationTaskStatus.failed,
            )
            .errorMessage,
        'simulated cell failure',
      );
      expect(requests, hasLength(3));
    },
  );

  for (final changed in ['provider', 'inputs']) {
    test(
      'grid keeps prepared requests when $changed changes during execution',
      () async {
        final firstStarted = Completer<void>();
        final first = Completer<void>();
        final original = beforeCreate;
        var preparations = 0;
        beforeCreate = (novelId, sourceType, sourceId) async {
          if (++preparations == 1) {
            firstStarted.complete();
            await first.future;
          }
          await original(novelId, sourceType, sourceId);
        };
        final pending = run('split-grid', {
          'rows': 1,
          'cols': 2,
          'cells': [0, 1],
          'upscale': 2,
          ...model,
        });
        await firstStarted.future;
        final cells =
            (await db.select(db.canvasNodes).get())
                .where((n) => n.parentId != null)
                .toList()
              ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
        final second = cells[1];
        if (changed == 'provider') {
          await appDb
              .into(appDb.aiProviders)
              .insert(
                app.AiProvidersCompanion.insert(
                  id: 'other',
                  name: 'Other',
                  type: 'openai',
                  enabled: const Value(true),
                  apiKey: const Value('other-key'),
                  imageModels: const Value(['gpt-image-2']),
                ),
              );
          final clip = (await canvas.shots.getShot(second.clipId!))!;
          await canvas.shots.apply(clip.id, {
            ...canvas.shots.snapshot(clip),
            'provider_id': 'other',
          });
        } else {
          await canvas.shots.restoreInputs(second.clipId!, [
            ProductionInput.asset(
              sourceAsset,
              VideoInputRole.reference_image,
            ).toJson(),
          ]);
        }
        first.complete();
        final response = await pending;
        expect(response['ok'], true, reason: '$response');
        expect(
          (response['result']['outputs'] as List).every(
            (output) => output['submitted'] == true,
          ),
          true,
        );
        expect(response['result']['failures'], isNull);
        final tasks = await appDb
            .select(appDb.generationTasks)
            .watch()
            .firstWhere(
              (rows) =>
                  rows.length == 2 &&
                  rows.every((row) => row.status.isTerminal),
            );
        expect(tasks.every((task) => task.providerId == 'images'), true);
        expect(requests, hasLength(2));
        expect(
          requests.every(
            (request) => request.references.single.assetId != sourceAsset,
          ),
          true,
        );
      },
    );
  }

  test(
    'Agent receives redacted upstream diagnostics while task UI keeps its user message',
    () async {
      await (appDb.update(
        appDb.aiProviders,
      )..where((p) => p.id.equals('images'))).write(
        const app.AiProvidersCompanion(apiKey: Value('credential-12345')),
      );
      invoke = (_, _, _, _) async => throw const AiImageGenerationException(
        'Please try later.',
        code: AiImageErrorCode.rate_limit,
        debugMessage:
            'HTTP 429 quota exceeded; key=credential-12345; Bearer private-token; https://host.test/signed?secret=value',
      );
      final response = await run('derive-view', {...model, 'preset': 'camera'});
      expect(response['error_code'], 'rate_limit');
      expect(response['error'], contains('HTTP 429 quota exceeded'));
      expect(response['error'], isNot(contains('credential-12345')));
      expect(response['error'], isNot(contains('private-token')));
      expect(
        (await appDb.select(appDb.generationTasks).get()).single.errorMessage,
        'Please try later.',
      );
    },
  );

  test(
    'default placement uses rendered image size and the full vertically arranged scene',
    () async {
      await db.canvasDao.updateActiveNodeFields(
        node.id,
        const CanvasNodesCompanion(
          x: Value(0),
          y: Value(500),
          width: Value(1),
          height: Value(1),
        ),
      );
      final screenplay = ScreenplayService(db);
      final scene = await screenplay.createScene(
        screenplayId: (await db.screenplayDao.getRoot())!.id,
        episodeId: episode,
        title: 'Scene',
      );
      final sceneNodes = <CanvasNode>[];
      for (var i = 0; i < 5; i++) {
        final clip = await canvas.shots.create(
          scene,
          values: {'title': 'Shot $i'},
        );
        final n = await canvas.ensureShotNode(clip.id);
        await db.canvasDao.updateActiveNodeFields(
          n.id,
          const CanvasNodesCompanion(x: Value(400), y: Value(0)),
        );
        sceneNodes.add(n);
      }
      final placement = await defaultProductionDerivedPlacement(
        canvas,
        node.id,
        const Size(440, 220),
      );
      expect(placement.at.x, 340); // 220px square image + 120px connection gap.
      for (final n in sceneNodes) {
        expect(placement.moves[n.id]?.x, greaterThan(400));
      }
    },
  );

  test(
    'default placement uses media aspect and storyboard cell dimensions',
    () async {
      final media = await canvas.addMedia(node.canvasId, sourceAsset);
      await db.canvasDao.updateActiveNodeFields(
        media.id,
        const CanvasNodesCompanion(
          x: Value(0),
          y: Value(1000),
          width: Value(1),
          height: Value(1),
        ),
      );
      final placement = await defaultProductionDerivedPlacement(
        canvas,
        media.id,
        const Size(440, 220),
      );
      expect(
        placement.at.x,
        380,
      ); // 2:1 media renders 260px wide, independent of its stored width.
      final layout = StoryboardGroupLayout(rows: 1, cols: 2, ratio: '9:16');
      final other = await canvas.addImage(node.canvasId);
      final group = await canvas.createStoryboardGroup(
        node.canvasId,
        layout: layout,
        origin: const Offset(1000, 1000),
        memberIds: [node.id, other.id],
      );
      final member = (await canvas.groups.members(group.id)).first;
      expect(
        productionNodeSize(member, aspect: 1, groupCellSize: layout.cellSize),
        layout.cellSize,
      );
    },
  );

  for (final parentKind in ['missing', 'non-group']) {
    test(
      'placement ignores a $parentKind parent when computing group bounds',
      () async {
        final parentId = parentKind == 'missing' ? 'missing-parent' : node.id;
        final source = await canvas.addImage(node.canvasId);
        final other = await canvas.addImage(node.canvasId);
        await canvas.moveNodes(node.canvasId, {
          node.id: (x: -1000, y: 1000),
          source.id: (x: 0, y: 0),
          other.id: (x: 1000, y: 0),
        });
        for (final id in [source.id, other.id]) {
          await db.canvasDao.updateActiveNodeFields(
            id,
            CanvasNodesCompanion(parentId: Value(parentId)),
          );
        }
        final placement = await defaultProductionDerivedPlacement(
          canvas,
          source.id,
          const Size(220, 220),
        );
        expect(placement.at, (x: 340.0, y: 0.0));
        expect(placement.moves, isEmpty);
      },
    );
  }

  test(
    'group conversion and shared placement use stored media size without probing',
    () async {
      final runner = _NoLayoutProbe();
      canvas = ProductionCanvasService(
        canvas.shots,
        MediaLibraryService(appDb, MediaService(runner), root),
        'work',
      );
      await (appDb.update(
        appDb.assets,
      )..where((asset) => asset.id.equals(sourceAsset))).write(
        const app.AssetsCompanion(
          content: Value(ImageAssetContent(width: 900, height: 1600)),
        ),
      );
      final media = await canvas.addMedia(node.canvasId, sourceAsset);
      await canvas.moveNodes(node.canvasId, {media.id: (x: 0, y: 1000)});
      final placement = await defaultProductionDerivedPlacement(
        canvas,
        media.id,
        const Size(220, 220),
      );
      expect(placement.at, (x: 266.25, y: 1000.0));
      final group = await canvas.createStoryboardGroup(
        node.canvasId,
        layout: const StoryboardGroupLayout(rows: 1, cols: 2, ratio: '16:9'),
        origin: const Offset(0, 1000),
        memberIds: [media.id],
      );
      final rects = await productionGroupMemberRects(canvas, group.id);
      expect(rects[media.id]!.size, const Size(146.25, 260));
      expect(runner.calls, 0);
    },
  );

  test(
    'cancelling grid submission leaves accepted tasks running and skips later cells',
    () async {
      final release = Completer<void>();
      final originalInvoke = invoke;
      invoke = (provider, request, onSubmitted, onOutputs) async {
        await release.future;
        return originalInvoke(provider, request, onSubmitted, onOutputs);
      };
      final originalCreate = beforeCreate;
      var preparations = 0;
      beforeCreate = (novelId, sourceType, sourceId) async {
        if (++preparations == 2) {
          operations.cancel(operations.state.runs.single.runId, context);
        }
        await originalCreate(novelId, sourceType, sourceId);
      };
      late List outputs;
      try {
        final response = await run('split-grid', {
          'rows': 1,
          'cols': 3,
          'cells': [0, 1, 2],
          'upscale': 2,
          ...model,
        }).timeout(const Duration(seconds: 5));
        expect(response['status'], 'cancelled');
        final result = response['result'];
        expect(result['upstream_may_continue'], true);
        outputs = result['outputs'] as List;
        expect(outputs.map((output) => output['submitted']), [
          true,
          false,
          false,
        ]);
        final tasks = await appDb.select(appDb.generationTasks).get();
        expect(tasks, hasLength(2));
        expect(
          tasks
              .singleWhere((task) => task.id == outputs[0]['task_id'])
              .cancelRequestedAt,
          isNull,
        );
        final cancelled = tasks.singleWhere(
          (task) => task.sourceId == outputs[1]['clip_id'],
        );
        expect(cancelled.status, app.GenerationTaskStatus.cancelled);
        expect(
          tasks.any((task) => task.sourceId == outputs[2]['clip_id']),
          false,
        );
        final failures = result['failures'] as List;
        expect(failures.map((failure) => failure['error_code']), [
          'cancelled',
          'cancelled',
        ]);
        expect(failures.first['task_id'], cancelled.id);
        expect(failures.last['task_id'], isNull);
      } finally {
        release.complete();
      }
      await appDb
          .select(appDb.generationTasks)
          .watch()
          .firstWhere(
            (tasks) =>
                tasks.length == 2 &&
                tasks.every((task) => task.status.isTerminal),
          );
      await ProductionResultService(appDb, (_) async => canvas).recover();
      expect(
        (await canvas.shots.getShot(
          outputs[0]['clip_id'] as String,
        ))!.adoptedAssetId,
        isNotNull,
      );
      expect(requests, hasLength(1));
    },
  );

  test(
    'submitted grid tasks can be cancelled individually after the batch returns',
    () async {
      final release = Completer<void>();
      final original = invoke;
      invoke = (provider, request, onSubmitted, onOutputs) async {
        await release.future;
        return original(provider, request, onSubmitted, onOutputs);
      };
      late List outputs;
      try {
        final response = await run('split-grid', {
          'rows': 1,
          'cols': 3,
          'cells': [0, 1, 2],
          'upscale': 2,
          ...model,
        }, false);
        final done = await operations
            .wait(response['run_id'] as String, context)
            .timeout(const Duration(seconds: 5));
        expect(done['status'], 'completed');
        outputs = done['result']['outputs'] as List;
        expect(outputs.map((e) => e['submitted']), [true, true, true]);
        final cancelled = await tools.executeTool(
          name: 'Run',
          callId: 'cancel-grid-cell',
          context: context,
          input: {
            'command': 'operations',
            'subcommand': 'cancel',
            'options': {'task_id': outputs[1]['task_id']},
          },
        );
        expect(cancelled['accepted'], true);
      } finally {
        release.complete();
      }
      await appDb
          .select(appDb.generationTasks)
          .watch()
          .firstWhere(
            (tasks) =>
                tasks.length == 3 &&
                tasks.every((task) => task.status.isTerminal),
          );
      await ProductionResultService(appDb, (_) async => canvas).recover();
      final cancelled = await canvas.requireNode(
        outputs[1]['node_id'] as String,
      );
      expect(
        (await canvas.shots.getShot(cancelled.clipId!))!.adoptedAssetId,
        isNull,
      );
      for (final index in [0, 2]) {
        final successful = await canvas.requireNode(
          outputs[index]['node_id'] as String,
        );
        expect(
          (await canvas.shots.getShot(successful.clipId!))!.adoptedAssetId,
          isNotNull,
        );
      }
    },
  );

  test(
    'cancelled derived generation returns draft and task, rejects late adoption',
    () async {
      final started = Completer<void>();
      final late = Completer<AiImageGenerationResult>();
      final original = invoke;
      invoke = (_, _, _, _) {
        started.complete();
        return late.future;
      };
      final response = await run('derive-view', {
        ...model,
        'preset': 'camera',
      }, false);
      await started.future;
      final id = response['run_id'] as String;
      operations.cancel(id, context);
      final done = await operations.wait(id, context);
      expect(done['status'], 'cancelled');
      final output = (done['result']['outputs'] as List).single;
      expect(output['task_id'], isNotNull);
      expect(output['generated'], false);
      late.complete(
        await original(
          (await appDb.aiProviderDao.getById('images'))!,
          requests.single,
          (_) async {},
          (_) async {},
        ),
      );
      await jobs.shutdown();
      final draft = await canvas.requireNode(output['node_id'] as String);
      expect(
        (await canvas.shots.getShot(draft.clipId!))!.adoptedAssetId,
        isNull,
      );
    },
  );
}

class _Audio implements AudioTaskService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoLayoutProbe extends FfmpegRunner {
  int calls = 0;
  @override
  Future<String> execute(
    List<String> arguments, {
    required bool probe,
    required MediaCancellation cancellation,
  }) async {
    calls++;
    throw StateError(
      'Layout must use stored dimensions without native probing',
    );
  }
}

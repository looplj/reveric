// 职责: 验证图片节点历史、采用、取消、重启恢复与冻结引用，不发起真实 AI 请求。
// 关联文件:
//   lib/shared/services/production/image_service.dart
//   lib/shared/services/production/image_generate_orchestrator.dart
//   lib/shared/providers/production_images.dart
import 'package:reveric/shared/models/generation/task.dart';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'dart:async';
import 'package:flutter/material.dart' show SizedBox, ValueKey;
import 'package:reveric/desktop/features/production/image_candidates.dart';
import '../../desktop/director/harness.dart';
import 'dart:convert';
import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/services/production/grid_orchestrator.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/production/view_presets.dart';
import 'package:reveric/shared/models/production/panorama.dart';
import 'package:reveric/shared/services/production/view_derive_orchestrator.dart';
import 'package:reveric/shared/models/production/style.dart';
import 'package:reveric/shared/models/storyboard/prompt.dart';
import 'package:reveric/shared/providers/production_images.dart';
import 'package:reveric/shared/providers/video_tasks.dart';
import 'package:reveric/shared/services/production/result_service.dart';
import 'package:reveric/shared/database/app_database.dart'
    show GenerationTaskRequest;
import 'package:reveric/shared/providers/production_media.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/ai/image.dart';
import 'package:reveric/shared/services/image_library_service.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/image_generate_orchestrator.dart';
import 'package:reveric/shared/services/production/image_service.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeDirectorTest);
  setUp(() => rootBundle.clear());
  late Directory root;
  late app.AppDatabase appDb;
  late NovelContentDatabase db;
  late ProductionCanvasService canvas;
  late CanvasNode node;
  late File output;
  late String oldAsset;
  ProductionResultService results() =>
      ProductionResultService(appDb, (_) async => canvas);
  ImageTaskService jobs(
    ProductionImageInvoke invoke, {
    Future<AiImageGenerationResult> Function(AiProvider, app.GenerationTask)?
    fetch,
  }) {
    final result = results();
    return ImageTaskService(
      database: appDb,
      images: buildImageLibraryService(appDb),
      invoke: invoke,

      beforeCreate: result.beforeCreate,
      beforeSubmit: result.beforeSubmit,
      recoverSources: result.recover,
      fetchResult: fetch ?? (_, _) => throw StateError('Must not fetch'),
    );
  }

  Future<String> submit(
    ImageTaskService service,
    ProductionImagePreview preview,
  ) => service.submit(
    novelId: preview.novelId,
    sourceType: preview.sourceType,
    sourceId: preview.sourceId,
    request: preview.request,
  );

  Future<app.GenerationTask> running() async {
    for (var i = 0; i < 100; i++) {
      final rows = await appDb.select(appDb.generationTasks).get();
      if (rows.isNotEmpty && rows.last.status == GenerationTaskStatus.running) {
        return rows.last;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    throw StateError('No run');
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('production-image-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await RevericPaths.initialize();
    appDb = app.AppDatabase.forTest(NativeDatabase.memory());
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    await appDb
        .into(appDb.aiProviders)
        .insert(
          app.AiProvidersCompanion.insert(
            id: 'image',
            name: 'Images',
            type: 'openai',
            enabled: const Value(true),
            apiKey: const Value('test'),
            imageModels: const Value(['gpt-image-2']),
          ),
        );
    final episode = (await ScreenplayService(
      db,
    ).createInitialStructure()).episodeId;
    canvas = ProductionCanvasService(
      StoryboardService(db),
      MediaLibraryService(appDb, MediaService(FfmpegRunner()), root),
      'work',
    );
    node = await canvas.addImage((await canvas.ensureCanvas(episode)).id);
    final clip = (await canvas.shots.getShot(node.clipId!))!;
    await canvas.shots.apply(clip.id, {
      ...canvas.shots.snapshot(clip),
      'prompt': 'Body',
      'provider_id': 'image',
      'model_id': 'gpt-image-2',
      'ratio': '1:1',
      'resolution': '2K',
    });
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    final old = await File('${root.path}/old.png').writeAsBytes(png);
    oldAsset = (await buildImageLibraryService(appDb).importFile(
      old.path,
      novelId: canvas.novelId,
      purpose: AssetPurpose.production_upload,
    )).id;
    await canvas.adopt(node.id, oldAsset);
    output = await File('${root.path}/new.png').writeAsBytes([...png, 1]);
  });
  tearDown(() async {
    await db.close();
    await appDb.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await root.delete(recursive: true);
  });

  testWidgets(
    'candidate grid shows all four and selects the third without generation',
    (tester) async {
      late app.GenerationTask task;
      await tester.runAsync(() async {
        final service = jobs(
          (_, _, _, _) async => AiImageGenerationResult.group([
            for (var i = 0; i < 4; i++)
              AiImageGenerationResult(
                localFilePath:
                    (await File('${root.path}/grid-$i.png').writeAsBytes(
                      img.encodePng(
                        img.Image(width: 8, height: 8)
                          ..setPixelRgb(0, 0, i * 60, 20, 30),
                      ),
                    )).path,
              ),
          ]),
        );
        final preview = await ProductionImageGenerateOrchestrator().preview(
          canvas,
          node.id,
        );
        final id = await submit(service, preview);
        await service.shutdown();
        task = (await appDb.generationTaskDao.getById(id))!;
      });
      String? selected;
      await tester.pumpWidget(
        directorTestApp(
          SizedBox(
            width: 340,
            child: ProductionImageCandidates(
              service: canvas,
              task: task,
              selected: task.resultAssetId,
              onAdopt: (id) async {
                selected = id;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ProductionImageCandidates), findsOneWidget);
      expect(
        find.byKey(const ValueKey('image-candidate-adopt-4')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('image-candidate-adopt-3')));
      await tester.pumpAndSettle();
      expect(selected, task.resultAssetIds[2]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'download receipt survives failure and retries all candidates without another submission',
    () async {
      final urls = [
        for (var i = 0; i < 4; i++) 'https://images.example/$i.png',
      ];
      var generations = 0;
      final service = jobs(
        (_, _, _, onOutputs) async {
          generations++;
          await onOutputs(urls);
          throw AiImageFetchException('download failed', urls: urls);
        },
        fetch: (_, task) async {
          expect(task.imageOutputs!.items.map((item) => item.url), urls);
          return AiImageGenerationResult.group([
            for (var i = 0; i < 4; i++)
              AiImageGenerationResult(
                localFilePath:
                    (await File('${root.path}/retry-$i.png').writeAsBytes(
                      img.encodePng(
                        img.Image(width: 8, height: 8)
                          ..setPixelRgb(0, 0, i * 60, 20, 30),
                      ),
                    )).path,
              ),
          ]);
        },
      );
      final preview = await ProductionImageGenerateOrchestrator().preview(
        canvas,
        node.id,
      );
      final id = await submit(service, preview);
      expect(
        (await service.requireRun(id)).status,
        GenerationTaskStatus.action_required,
      );
      await service.retrySaveOutput(id);
      final task = await service.requireRun(id);
      expect(task.status, GenerationTaskStatus.completed);
      expect(task.resultAssetIds, hasLength(4));
      expect(generations, 1);
      service.dispose();
    },
  );

  test(
    'one generation preserves four candidates and adopts any member',
    () async {
      final files = <File>[];
      for (var i = 0; i < 4; i++) {
        files.add(
          await File('${root.path}/candidate-$i.png').writeAsBytes(
            img.encodePng(
              img.Image(width: 8, height: 8)..setPixelRgb(0, 0, i * 60, 20, 30),
            ),
          ),
        );
      }
      final service = jobs(
        (_, _, _, _) async => AiImageGenerationResult.group([
          for (final file in files)
            AiImageGenerationResult(localFilePath: file.path),
        ]),
      );
      final preview = await ProductionImageGenerateOrchestrator().preview(
        canvas,
        node.id,
      );
      final id = await submit(service, preview);
      await service.shutdown();
      final task = (await appDb.generationTaskDao.getById(id))!;
      expect(task.status, GenerationTaskStatus.completed);
      expect(task.resultAssetIds, hasLength(4));
      expect(task.resultAssetId, task.resultAssetIds.first);
      for (final item in task.imageOutputs!.items) {
        expect(item.path, isNull);
        expect(item.hash, isNull);
        expect(item.url, isNull);
        final asset = (await appDb.assetDao.getAsset(item.assetId!))!;
        expect(
          File(RevericPaths.resolveStored(asset.path)!).existsSync(),
          isTrue,
        );
      }
      await canvas.adoptGenerated(node.id, id, assetId: task.resultAssetIds[2]);
      expect(
        (await canvas.shots.getShot(node.clipId!))!.adoptedAssetId,
        task.resultAssetIds[2],
      );
      await expectLater(
        canvas.adoptGenerated(node.id, id, assetId: oldAsset),
        throwsA(isA<Exception>()),
      );
      expect(await appDb.select(appDb.generationTasks).get(), hasLength(1));
    },
  );

  test(
    'submitted image task freezes expanded text inputs without media references',
    () async {
      final text = await canvas.addText(
        node.canvasId,
        content: 'Shared description',
      );
      await canvas.shots.restoreInputs(node.clipId!, [
        ProductionInput.text(text.id).toJson(),
      ]);
      final prepared = await ProductionImageGenerateOrchestrator().preview(
        canvas,
        node.id,
      );
      expect(prepared.request.prompt, 'Shared description\nBody');
      await canvas.updateText(
        text.id,
        title: '',
        content: 'Changed after preview',
      );
      final service = jobs((_, request, _, _) async {
        expect(request.prompt, prepared.request.prompt);
        expect(request.references, isEmpty);
        return AiImageGenerationResult(localFilePath: output.path);
      });
      try {
        final task = await service.requireRun(await submit(service, prepared));
        expect(task.status, GenerationTaskStatus.completed);
        expect(task.imageRequest.prompt, prepared.request.prompt);
        expect(task.imageRequest.references, isEmpty);
      } finally {
        await service.shutdown();
      }
    },
  );

  test(
    'derived requests retain their prepared values after later draft edits',
    () async {
      late ProductionImagePreview frozen;
      final created = await ViewDeriveOrchestrator().create(
        service: canvas,
        sourceNodeId: node.id,
        preset: ViewPreset.camera,
        args: const ViewPresetArgs(),
        model: const AiModelOption(
          providerId: 'image',
          providerDisplayName: 'Images',
          model: 'gpt-image-2',
          kind: AiModelKind.image,
        ),
        title: 'Derived',
        onPreview: (preview) {
          frozen = preview;
        },
      );
      expect(frozen.nodeId, created.id);
      expect(frozen.request.providerId, 'image');
      final original = frozen.request.originalPrompt;
      final clip = (await canvas.shots.getShot(created.clipId!))!;
      await canvas.shots.apply(clip.id, {
        ...canvas.shots.snapshot(clip),
        'prompt': 'Changed after draft creation',
      });
      expect(frozen.request.originalPrompt, original);
      expect(frozen.request.references.single.assetId, oldAsset);
      expect(await appDb.select(appDb.generationTasks).get(), isEmpty);
    },
  );

  test(
    'image task consumes media part and retains the actual image extension',
    () async {
      final part = File(
        '${root.path}/file_workspaces/reveric_image_result_task.png.part',
      );
      await part.parent.create(recursive: true);
      await output.copy(part.path);
      final service = jobs(
        (_, _, _, _) async => AiImageGenerationResult(localFilePath: part.path),
      );
      try {
        final preview = await ProductionImageGenerateOrchestrator().preview(
          canvas,
          node.id,
        );
        final task = await service.requireRun(await submit(service, preview));
        expect(task.status, GenerationTaskStatus.completed);
        expect(task.path, startsWith('file_workspaces/work/images/'));
        expect(task.path, endsWith('.png'));
        final asset = (await appDb.assetDao.getAsset(task.resultAssetId!))!;
        expect(asset.id, matches(r'^ast_[A-Za-z0-9]{16}$'));
        expect(asset.path, task.path);
        expect(
          await File('${root.path}/${asset.path}').readAsBytes(),
          await output.readAsBytes(),
        );
        expect(await part.exists(), false);
        expect(await appDb.select(appDb.assets).get(), hasLength(2));
      } finally {
        await service.shutdown();
      }
    },
  );

  test(
    'rejected submission never changes another active task for the same source',
    () async {
      final pending = Completer<AiImageGenerationResult>();
      final service = jobs((_, _, _, _) => pending.future);
      final preview = await ProductionImageGenerateOrchestrator().preview(
        canvas,
        node.id,
      );
      final original = submit(service, preview);
      try {
        final active = await running();
        await expectLater(
          service.submit(
            novelId: preview.novelId,
            sourceType: preview.sourceType,
            sourceId: preview.sourceId,
            request: preview.request,
            taskId: 'rejected',
          ),
          throwsA(isA<Exception>()),
        );
        await expectLater(
          service.recordSubmissionFailure(
            preview,
            'openai',
            StateError('duplicate'),
            StackTrace.current,
            taskId: 'rejected',
          ),
          throwsA(isA<Exception>()),
        );
        final unchanged = await service.requireRun(active.id);
        expect(unchanged.status, GenerationTaskStatus.running);
        expect(unchanged.requestJson.toJson(), active.requestJson.toJson());
        expect(unchanged.resultAssetId, active.resultAssetId);
        expect(await appDb.generationTaskDao.getById('rejected'), isNull);
        pending.complete(AiImageGenerationResult(localFilePath: output.path));
        await original;
        final completed = await service.requireRun(active.id);
        expect(completed.status, GenerationTaskStatus.completed);
        expect(completed.resultAssetId, isNotNull);
        expect(
          (await canvas.shots.getShot(node.clipId!))!.adoptedAssetId,
          completed.resultAssetId,
        );
      } finally {
        if (!pending.isCompleted) {
          pending.complete(AiImageGenerationResult(localFilePath: output.path));
        }
        await original;
        await service.shutdown();
      }
    },
  );

  for (final failRecording in [false, true]) {
    test(
      'one grid submission failure is visible and later cells continue even when recording fails=$failRecording',
      () async {
        final source = img.Image(width: 8, height: 4);
        for (var y = 0; y < 4; y++) {
          for (var x = 0; x < 8; x++) {
            source.setPixelRgb(x, y, x * 25, y * 60, 80);
          }
        }
        final file = await File(
          '${root.path}/grid.png',
        ).writeAsBytes(img.encodePng(source));
        final asset = await canvas.library.importFile(
          file,
          name: 'Grid.png',
          novelId: canvas.novelId,
          purpose: AssetPurpose.production_output,
          cancellation: MediaCancellation(),
        );
        await canvas.adopt(node.id, asset.id);
        final resultService = results();
        var preparations = 0;
        final service = _RecordFailJobs(
          database: appDb,
          images: buildImageLibraryService(appDb),
          invoke: (_, _, _, _) async =>
              AiImageGenerationResult(localFilePath: output.path),

          beforeCreate: (novelId, type, sourceId) async {
            if (++preparations == 2) {
              throw const StoryboardException('invalid_reference');
            }
            await resultService.beforeCreate(novelId, type, sourceId);
          },
          beforeSubmit: resultService.beforeSubmit,
          recoverSources: resultService.recover,
        )..rejectRecording = failRecording;
        try {
          final outcome = await GridOrchestrator().upscale(
            canvas: canvas,
            jobs: service,
            sourceNodeId: node.id,
            rows: 2,
            cols: 2,
            selected: {0, 1, 3},
            model: const AiModelOption(
              providerId: 'image',
              providerDisplayName: 'Images',
              model: 'gpt-image-2',
              kind: AiModelKind.image,
            ),
            multiplier: 2,
            place: (_) => (at: (x: 600, y: 100), moves: {}),
          );
          final members = await canvas.groups.members(outcome.group.id);
          for (var wait = 0; wait < 200; wait++) {
            final rows = await appDb.select(appDb.generationTasks).get();
            if (rows.every((task) => task.status.isTerminal)) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          expect(outcome.failures.keys, [members[1].id]);
          expect(
            outcome.failures.values.single.stage,
            GridUpscaleStage.submission,
          );
          expect(outcome.failures.values.single.recorded, !failRecording);
          expect(outcome.failures.values.single.title, isNotEmpty);
          final tasks = await appDb.select(appDb.generationTasks).get();
          expect(tasks, hasLength(failRecording ? 2 : 3));
          expect(
            tasks
                .where((task) => task.status == GenerationTaskStatus.completed)
                .map((task) => task.sourceId),
            unorderedEquals([members.first.clipId, members.last.clipId]),
          );
          if (!failRecording) {
            expect(
              tasks
                  .singleWhere((task) => task.sourceId == members[1].clipId)
                  .status,
              GenerationTaskStatus.failed,
            );
          }
        } finally {
          await service.shutdown();
        }
      },
    );
  }

  for (final factor in [2, 4]) {
    test(
      'grid upscale $factor creates every task and isolates a rejected submission',
      () async {
        final sourceImage = img.Image(width: 8, height: 4);
        for (var y = 0; y < 4; y++) {
          for (var x = 0; x < 8; x++) {
            sourceImage.setPixelRgb(x, y, x * 30, y * 60, 80);
          }
        }
        final file = await File(
          '${root.path}/grid.png',
        ).writeAsBytes(img.encodePng(sourceImage));
        final asset = await canvas.library.importFile(
          file,
          name: 'Grid.png',
          novelId: canvas.novelId,
          purpose: AssetPurpose.production_output,
          cancellation: MediaCancellation(),
        );
        await canvas.adopt(node.id, asset.id);
        final resultService = results();
        final requests = <ProductionImageRequest>[];
        var attempts = 0;
        final service = ImageTaskService(
          database: appDb,
          images: buildImageLibraryService(appDb),
          invoke: (_, request, _, _) async {
            requests.add(request);
            return AiImageGenerationResult(localFilePath: output.path);
          },

          beforeCreate: (novel, type, id) async {
            if (++attempts == 2) {
              throw StateError('single submission rejected');
            }
            await resultService.beforeCreate(novel, type, id);
          },
          beforeSubmit: resultService.beforeSubmit,
          recoverSources: resultService.recover,
        );
        try {
          const model = AiModelOption(
            providerId: 'image',
            providerDisplayName: 'Images',
            model: 'gpt-image-2',
            kind: AiModelKind.image,
          );
          final outcome = await GridOrchestrator().upscale(
            canvas: canvas,
            jobs: service,
            sourceNodeId: node.id,
            rows: 2,
            cols: 2,
            selected: {3, 0, 1},
            model: model,
            multiplier: factor,
            place: (_) => (at: (x: 600, y: 100), moves: {}),
          );
          final group = outcome.group;
          expect(outcome.failures.values.single.recorded, isTrue);
          final members = await canvas.groups.members(group.id);
          expect(members, hasLength(3));
          for (final member in members) {
            final clip = (await canvas.shots.getShot(member.clipId!))!;
            expect(clip.resolution, '${factor}K');
            expect(clip.ratio, '16:9');
            expect(
              ImageGenerationPreset.fromStyle(member.style).method,
              ImageGenerationMethod.upscale,
            );
            final inputs = await canvas.inputs(member.id);
            expect(inputs, hasLength(1));
            expect(inputs.single.sourceNodeId, isNull);
            expect(inputs.single.role, VideoInputRole.reference_image);
            expect(inputs.single.refId, isNot(asset.id));
          }
          final tasks = await appDb.select(appDb.generationTasks).get();
          expect(tasks, hasLength(3));
          final rejected = tasks.singleWhere(
            (task) => task.sourceId == members[1].clipId,
          );
          expect(rejected.status, GenerationTaskStatus.failed);
          for (var wait = 0; wait < 200; wait++) {
            final current = await appDb.select(appDb.generationTasks).get();
            if (current.every((task) => task.status.isTerminal)) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          expect(requests, hasLength(2));
          for (final request in requests) {
            expect(request.references, hasLength(1));
            expect(request.references.single.assetId, isNot(asset.id));
            expect(request.resolution, '${factor}K');
            expect(request.prompt, contains('不添加新元素'));
          }
          expect(
            (await appDb.select(appDb.generationTasks).get()).where(
              (task) => task.status == GenerationTaskStatus.completed,
            ),
            hasLength(2),
          );
          final provider = (await appDb.aiProviderDao.getById('image'))!;
          expect(
            gridUpscaleMultipliers(
              ProductionImageCapabilities(provider, 'gpt-image-2'),
            ),
            {2, 4},
          );
          expect(
            gridUpscaleMultipliers(
              ProductionImageCapabilities(provider, 'unknown'),
            ),
            isEmpty,
          );
        } finally {
          await service.shutdown();
        }
      },
    );
  }

  test(
    'panorama view persists independently and preserves node colors',
    () async {
      await db.canvasDao.updateActiveNodeFields(
        node.id,
        const CanvasNodesCompanion(
          style: Value({'color': 'blue', 'custom': 1}),
        ),
      );
      await canvas.setPanoramaView(
        node.id,
        const PanoramaView(yaw: 450, pitch: -30, fov: 60),
      );
      final stored = (await canvas.requireNode(node.id)).style!;
      expect(stored['color'], 'blue');
      expect(stored['custom'], 1);
      expect(
        PanoramaView.fromStyle(stored),
        const PanoramaView(yaw: 450, pitch: -30, fov: 60),
      );
      final media = await canvas.addMedia(node.canvasId, oldAsset);
      await canvas.setPanoramaView(media.id, const PanoramaView());
      expect(
        PanoramaView.fromStyle((await canvas.requireNode(media.id)).style),
        const PanoramaView(),
      );
      await canvas.setPanoramaView(node.id, null);
      await canvas.setPanoramaView(
        node.id,
        const PanoramaView(yaw: 90),
        onlyIfActive: true,
      );
      expect((await canvas.requireNode(node.id)).style, {
        'color': 'blue',
        'custom': 1,
      });
      expect(
        PanoramaView.fromStyle((await canvas.requireNode(media.id)).style),
        isNotNull,
      );
      final audio = await canvas.addAudio(node.canvasId);
      await expectLater(
        canvas.setPanoramaView(audio.id, const PanoramaView()),
        throwsA(isA<StoryboardException>()),
      );
      await db
          .into(db.canvases)
          .insert(CanvasesCompanion.insert(id: 'other', name: 'Other'));
      await db
          .into(db.canvasNodes)
          .insert(node.copyWith(id: 'foreign', canvasId: 'other'));
      await expectLater(
        canvas.setPanoramaView('foreign', const PanoramaView()),
        throwsA(isA<StoryboardException>()),
      );
      await canvas.removeNode(media.id);
      await expectLater(
        canvas.setPanoramaView(media.id, const PanoramaView()),
        throwsA(isA<StoryboardException>()),
      );
    },
  );

  const imageModel = AiModelOption(
    providerId: 'image',
    providerDisplayName: 'Images',
    model: 'gpt-image-2',
    kind: AiModelKind.image,
  );
  test(
    'panorama entry creates an editable draft without selecting or invoking a model',
    () async {
      final original = (await canvas.shots.getShot(node.clipId!))!;
      final created = await ViewDeriveOrchestrator().createDraft(
        service: canvas,
        sourceNodeId: node.id,
        method: ImageGenerationMethod.panorama,
        title: 'Panorama',
      );
      final clip = (await canvas.shots.getShot(created.clipId!))!;
      expect(clip.prompt, isEmpty);
      expect(clip.providerId, isNull);
      expect(clip.modelId ?? '', isEmpty);
      expect(clip.ratio, '2:1');
      expect(clip.inputs.single.sourceNodeId, node.id);
      expect(
        ImageGenerationPreset.fromStyle(created.style).method,
        ImageGenerationMethod.panorama,
      );
      expect(await appDb.select(appDb.generationTasks).get(), isEmpty);
      final source = (await canvas.shots.getShot(node.clipId!))!;
      expect(canvas.shots.snapshot(source), canvas.shots.snapshot(original));
      expect(source.adoptedAssetId, original.adoptedAssetId);
    },
  );

  test(
    'generation combines preset and user prompt only when previewing submission',
    () async {
      final created = await ViewDeriveOrchestrator().createDraft(
        service: canvas,
        sourceNodeId: node.id,
        method: ImageGenerationMethod.after_3s,
        title: 'After',
      );
      final initial = (await canvas.shots.getShot(created.clipId!))!;
      const user = '保持红色屏风，增加薄雾。';
      await canvas.shots.apply(initial.id, {
        ...canvas.shots.snapshot(initial),
        'prompt': user,
        'provider_id': 'image',
        'model_id': 'gpt-image-2',
        'ratio': '1:1',
        'resolution': '2K',
      });
      final preview = await ProductionImageGenerateOrchestrator().preview(
        canvas,
        created.id,
      );
      expect(preview.request.originalPrompt, contains('<ref'));
      expect(
        preview.request.prompt,
        allOf(contains('以图片1为当前画面'), contains(user)),
      );
      expect((await canvas.shots.getShot(initial.id))!.prompt, user);
      expect(await appDb.select(appDb.generationTasks).get(), isEmpty);
      await canvas.shots.restoreInputs(initial.id, []);
      await expectLater(
        ProductionImageGenerateOrchestrator().preview(canvas, created.id),
        throwsFormatException,
      );
    },
  );

  test('material ratio and panorama use selected model capabilities', () async {
    const option = AiModelOption(
      providerId: 'atlas',
      providerDisplayName: 'Atlas',
      model: 'tencent/hy-image-v3.5-preview',
      kind: AiModelKind.image,
    );
    await appDb
        .into(appDb.aiProviders)
        .insert(
          app.AiProvidersCompanion.insert(
            id: option.providerId,
            name: 'Atlas',
            type: 'openrouter',
            enabled: const Value(true),
            apiKey: const Value('test'),
            imageModels: Value([option.model, 'future-image']),
          ),
        );
    final source = await canvas.addMedia(node.canvasId, oldAsset);
    final ordinary = await ViewDeriveOrchestrator().create(
      service: canvas,
      sourceNodeId: source.id,
      preset: ViewPreset.light,
      args: const ViewPresetArgs(),
      model: option,
      title: 'Light',
    );
    final ordinaryClip = (await canvas.shots.getShot(ordinary.clipId!))!;
    expect(ordinaryClip.ratio, '1:1');
    expect(ordinaryClip.resolution, '1K');
    final panorama = await ViewDeriveOrchestrator().create(
      service: canvas,
      sourceNodeId: source.id,
      preset: ViewPreset.panorama,
      args: const ViewPresetArgs(),
      model: option,
      title: 'Panorama',
    );
    final clip = (await canvas.shots.getShot(panorama.clipId!))!;
    expect(clip.ratio, '2:1');
    expect(clip.resolution, '4K');
    expect(panorama.style?['panorama'], {'yaw': 0, 'pitch': 0, 'fov': 75});
    expect(clip.providerId, 'atlas');
    final unlisted = await ViewDeriveOrchestrator().create(
      service: canvas,
      sourceNodeId: source.id,
      preset: ViewPreset.panorama,
      args: const ViewPresetArgs(),
      model: const AiModelOption(
        providerId: 'atlas',
        providerDisplayName: 'Atlas',
        model: 'future-image',
        kind: AiModelKind.image,
      ),
      title: 'Panorama',
    );
    final unlistedClip = (await canvas.shots.getShot(unlisted.clipId!))!;
    expect(unlistedClip.ratio, '2:1');
    expect(unlistedClip.resolution, 'auto');
  });

  test(
    'failure inserting the reference rolls back new clip and node',
    () async {
      await expectLater(
        canvas.addDerivedImage(
          sourceNodeId: node.id,
          input: ProductionInput(
            id: '',
            refType: ProductionInputType.node,
            refId: node.id,
            role: VideoInputRole.reference_image,
          ),
          draft: const ProductionImageDraft(
            prompt: 'Draft',
            modelId: 'gpt-image-2',
            providerId: 'image',
            ratio: '1:1',
            resolution: '2K',
          ),
        ),
        throwsFormatException,
      );
      expect((await canvas.content(node.canvasId)).nodes, hasLength(1));
      expect(await db.select(db.productionClips).get(), hasLength(1));
    },
  );
  test(
    'derived image writes draft, reference and node without touching source',
    () async {
      final original = (await canvas.shots.getShot(node.clipId!))!;
      await canvas.setScreenplayStyle('preset:eastern-ink-decorative');
      final derived = await ViewDeriveOrchestrator().create(
        service: canvas,
        sourceNodeId: node.id,
        preset: ViewPreset.camera,
        args: const ViewPresetArgs(yaw: 45, framing: CameraFraming.close),
        model: imageModel,
        title: 'Camera',
      );
      final clip = (await canvas.shots.getShot(derived.clipId!))!;
      expect(clip.prompt, contains('右前侧 45°'));
      expect(clip.sceneId, isNull);
      expect(clip.sortOrder, isNull);
      expect(clip.ratio, original.ratio);
      expect(clip.resolution, original.resolution);
      expect(derived.x, greaterThan(node.x));
      expect(clip.inputs.single.sourceNodeId, node.id);
      expect(
        (await canvas.content(node.canvasId)).edges.single.targetNodeId,
        derived.id,
      );
      final preview = await ProductionImageGenerateOrchestrator().preview(
        canvas,
        derived.id,
      );
      expect(preview.request.prompt, contains('以图片1为准'));
      expect(
        preview.request.prompt,
        startsWith(
          productionStylePreset('eastern-ink-decorative')!.prompt.before,
        ),
      );
      expect(
        (await canvas.shots.getShot(node.clipId!))!.prompt,
        original.prompt,
      );
      expect(
        (await canvas.shots.getShot(node.clipId!))!.adoptedAssetId,
        original.adoptedAssetId,
      );
      await canvas.shots.restoreInputs(clip.id, []);
      await expectLater(
        ProductionImageGenerateOrchestrator().preview(canvas, derived.id),
        throwsA(isA<StoryboardException>()),
      );
    },
  );

  test(
    'invalid model, unsupported panorama and missing source create nothing',
    () async {
      final orchestrator = ViewDeriveOrchestrator();
      Future<CanvasNode> create(AiModelOption? model, ViewPreset preset) =>
          orchestrator.create(
            service: canvas,
            sourceNodeId: node.id,
            preset: preset,
            args: const ViewPresetArgs(),
            model: model,
            title: 'Derived',
          );
      await expectLater(
        create(null, ViewPreset.camera),
        throwsA(isA<StoryboardException>()),
      );
      await expectLater(
        create(imageModel, ViewPreset.panorama),
        throwsA(isA<StoryboardException>()),
      );
      await (db.update(db.productionClips)
            ..where((t) => t.id.equals(node.clipId!)))
          .write(const ProductionClipsCompanion(adoptedAssetId: Value(null)));
      await expectLater(
        create(imageModel, ViewPreset.light),
        throwsA(isA<StoryboardException>()),
      );
      expect((await canvas.content(node.canvasId)).nodes, hasLength(1));
    },
  );

  test('panel generation returns once the task exists', () async {
    final release = Completer<void>();
    final service = jobs((_, _, _, _) async {
      await release.future;
      throw StateError('released');
    });
    final derived = await ViewDeriveOrchestrator().run(
      service: canvas,
      jobs: service,
      sourceNodeId: node.id,
      preset: ViewPreset.light,
      model: imageModel,
      title: 'Light',
    );
    final task = (await appDb.select(appDb.generationTasks).get()).single;
    expect(task.sourceId, derived.clipId);
    expect(task.status, isNot(GenerationTaskStatus.failed));
    await running();
    release.complete();
    for (var i = 0; i < 100; i++) {
      final row = (await appDb.select(appDb.generationTasks).get()).single;
      if (row.status == GenerationTaskStatus.failed) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    fail('task never finished');
  });

  test('a failed task leaves the complete derived draft for retry', () async {
    final service = jobs(
      (_, _, _, _) async => throw StateError('fake network failure'),
    );
    final derived = await ViewDeriveOrchestrator().run(
      service: canvas,
      jobs: service,
      sourceNodeId: node.id,
      preset: ViewPreset.light,
      model: imageModel,
      title: 'Light',
    );
    // run 在任务建好后就返回，不等生成结束。
    final tasks = await appDb.select(appDb.generationTasks).get();
    expect(tasks.single.sourceId, derived.clipId);
    final clip = (await canvas.shots.getShot(derived.clipId!))!;
    expect(clip.prompt, contains('重新布光'));
    expect(clip.inputs.single.sourceNodeId, node.id);
    for (var i = 0; i < 100; i++) {
      final row = (await appDb.select(appDb.generationTasks).get()).single;
      if (row.status == GenerationTaskStatus.failed) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(
      (await appDb.select(appDb.generationTasks).get()).single.status,
      GenerationTaskStatus.failed,
    );
  });

  test(
    'image previews freeze the screenplay style while drafts stay unchanged',
    () async {
      final ink = productionStylePreset('eastern-ink-decorative')!;
      await canvas.setScreenplayStyle('preset:${ink.id}');
      final generate = ProductionImageGenerateOrchestrator();
      final frozen = await generate.preview(canvas, node.id);
      expect(frozen.request.prompt, ink.prompt.assemble('Body'));
      expect(frozen.request.originalPrompt, 'Body');
      await canvas.setScreenplayStyle(null);
      expect((await generate.preview(canvas, node.id)).request.prompt, 'Body');
      expect(frozen.request.prompt, ink.prompt.assemble('Body'));
      expect((await canvas.shots.getShot(node.clipId!))!.prompt, 'Body');
    },
  );

  for (final type in ['character', 'location', ...compendiumEntityTypes]) {
    final character = type == 'character';
    final location = type == 'location';
    test(
      'generated $type photo inherits title, recovers once and preserves names',
      () async {
        if (character) {
          await db
              .into(db.characterProfiles)
              .insert(
                CharacterProfilesCompanion.insert(
                  id: 'subject',
                  name: 'Subject',
                  photos: Value([
                    SubjectPhoto(assetId: oldAsset, name: 'Original'),
                  ]),
                ),
              );
        } else if (location) {
          await db
              .into(db.locations)
              .insert(
                LocationsCompanion.insert(
                  id: 'subject',
                  name: 'Subject',
                  photos: Value([
                    SubjectPhoto(assetId: oldAsset, name: 'Original'),
                  ]),
                ),
              );
        }
        if (!character && !location) {
          await db
              .into(db.items)
              .insert(
                ItemsCompanion.insert(
                  id: 'subject',
                  type: type,
                  title: 'Subject',
                  photos: Value([
                    SubjectPhoto(assetId: oldAsset, name: 'Original'),
                  ]),
                ),
              );
        }
        Future<CanvasNode> add() => canvas.addSubject(
          node.canvasId,
          characterId: character ? 'subject' : null,
          locationId: location ? 'subject' : null,
          itemId: !character && !location ? 'subject' : null,
        );
        final origin = await add();
        final other = await add();
        final originClip = (await canvas.shots.getShot(origin.clipId!))!;
        await canvas.shots.apply(originClip.id, {
          ...canvas.shots.snapshot(originClip),
          'title': '  Subject｜三视图  ',
          'prompt': 'Portrait',
          'provider_id': 'image',
          'model_id': 'gpt-image-2',
          'resolution': '2K',
        });
        final service = jobs(
          (_, _, _, _) async =>
              AiImageGenerationResult(localFilePath: output.path),
        );
        final preview = await ProductionImageGenerateOrchestrator().preview(
          canvas,
          origin.id,
        );
        final run = await service.requireRun(await submit(service, preview));
        expect(run.status, GenerationTaskStatus.completed);
        expect(run.resultAssetId, isNotNull);
        expect(await appDb.assetDao.getAsset(run.resultAssetId!), isNotNull);
        final clip = (await canvas.shots.getShot(origin.clipId!))!;
        expect(clip.adoptedAssetId, run.resultAssetId);
        expect(await canvas.subjectPhotos(clip), [
          SubjectPhoto(assetId: oldAsset, name: 'Original'),
          SubjectPhoto(assetId: run.resultAssetId!, name: 'Subject｜三视图'),
        ]);
        expect(
          (await canvas.shots.getShot(other.clipId!))!.adoptedAssetId,
          oldAsset,
        );
        await results().recover();
        expect(await canvas.subjectPhotos(clip), [
          SubjectPhoto(assetId: oldAsset, name: 'Original'),
          SubjectPhoto(assetId: run.resultAssetId!, name: 'Subject｜三视图'),
        ]);
        await canvas.adopt(origin.id, oldAsset);
        await results().recover();
        expect(
          (await canvas.shots.getShot(origin.clipId!))!.adoptedAssetId,
          oldAsset,
        );
        expect(await canvas.subjectPhotos(clip), [
          SubjectPhoto(assetId: oldAsset, name: 'Original'),
          SubjectPhoto(assetId: run.resultAssetId!, name: 'Subject｜三视图'),
        ]);

        await canvas.renameSubjectPhoto(clip, run.resultAssetId!, '用户命名');
        await canvas.shots.apply(clip.id, {
          ...canvas.shots.snapshot(clip),
          'title': 'Subject｜冬装',
        });
        await canvas.adoptGenerated(origin.id, run.id);
        await results().recover();
        expect(await canvas.subjectPhotos(clip), [
          SubjectPhoto(assetId: oldAsset, name: 'Original'),
          SubjectPhoto(assetId: run.resultAssetId!, name: '用户命名'),
        ]);

        final manualFile = await File(
          '${root.path}/manual.png',
        ).writeAsBytes([...await output.readAsBytes(), 2]);
        final manualAsset = await buildImageLibraryService(appDb).importFile(
          manualFile.path,
          novelId: canvas.novelId,
          purpose: AssetPurpose.production_upload,
        );
        await canvas.adopt(origin.id, manualAsset.id);
        expect(await canvas.subjectPhotos(clip), [
          SubjectPhoto(assetId: oldAsset, name: 'Original'),
          SubjectPhoto(assetId: run.resultAssetId!, name: '用户命名'),
          SubjectPhoto(assetId: manualAsset.id, name: 'Subject｜冬装'),
        ]);
      },
    );
  }
  test(
    'success registers once and adopts, failure preserves previous result and draft',
    () async {
      final preview = await ProductionImageGenerateOrchestrator().preview(
        canvas,
        node.id,
      );
      final service = jobs(
        (_, request, _, _) async =>
            AiImageGenerationResult(localFilePath: output.path),
      );
      final id = await submit(service, preview);
      final result = await service.requireRun(id);
      expect(result.status.name, 'completed');
      expect(
        result.outputHash,
        sha256.convert(await output.readAsBytes()).toString(),
      );
      expect(
        (await canvas.shots.getShot(node.clipId!))!.adoptedAssetId,
        result.resultAssetId,
      );
      expect(await appDb.select(appDb.assets).get(), hasLength(2));
      final failure = jobs(
        (_, request, _, _) async => throw StateError('provider failed'),
      );
      final failed = await failure.requireRun(await submit(failure, preview));
      expect(failed.status.name, 'failed');
      final clip = (await canvas.shots.getShot(node.clipId!))!;
      expect(clip.adoptedAssetId, result.resultAssetId);
      expect(clip.prompt, 'Body');
    },
  );

  test(
    'new image generation resets dismissal; repeated failure does not',
    () async {
      await canvas.shots.setErrorDismissed(node.clipId!, true);
      final service = jobs((_, _, _, _) async {
        expect(
          (await canvas.shots.getShot(node.clipId!))!.errorDismissed,
          isFalse,
        );
        throw const AiImageGenerationException(
          'Reference image rejected.',
          debugMessage: 'private upstream response',
        );
      });
      final preview = await ProductionImageGenerateOrchestrator().preview(
        canvas,
        node.id,
      );
      final id = await submit(service, preview);
      expect((await service.requireRun(id)).status.name, 'failed');
      expect(
        (await service.requireRun(id)).errorMessage,
        'Reference image rejected.',
      );
      await canvas.shots.setErrorDismissed(node.clipId!, true);
      await service.recordFailure(
        id,
        StateError('same failure'),
        StackTrace.current,
      );
      expect(
        (await canvas.shots.getShot(node.clipId!))!.errorDismissed,
        isTrue,
      );
      expect(
        (await canvas.shots.getShot(node.clipId!))!.adoptedAssetId,
        oldAsset,
      );
    },
  );

  test(
    'explicit image save retry resets dismissal without running AI again',
    () async {
      final preview = await ProductionImageGenerateOrchestrator().preview(
        canvas,
        node.id,
      );
      await appDb
          .into(appDb.generationTasks)
          .insert(
            app.GenerationTasksCompanion.insert(
              id: 'save-failed',
              status: GenerationTaskStatus.values.byName('action_required'),
              errorCode: const Value('result_save_failed'),
              kind: GenerationKind.image,
              novelId: 'work',
              sourceType: 'production_clip',
              sourceId: node.clipId!,
              requestJson: ImageGenerationRequest(preview.request),
              providerId: 'image',
              providerType: 'openai',
              modelId: 'gpt-image-2',
            ),
          );
      await canvas.shots.setErrorDismissed(node.clipId!, true);
      final service = jobs(
        (_, _, _, _) async => throw StateError('Must not generate'),
      );
      await expectLater(
        service.retrySaveOutput('save-failed'),
        throwsA(isA<StoryboardException>()),
      );
      expect(
        (await canvas.shots.getShot(node.clipId!))!.errorDismissed,
        isFalse,
      );
      expect(
        (await service.requireRun('save-failed')).status.name,
        'action_required',
      );
    },
  );

  test(
    'download failure keeps the remote URL and retry downloads without generating again',
    () async {
      const url = 'https://cdn.example.com/result.png';
      var generations = 0;
      final downloads = <String>[];
      var downloadFails = true;
      final service = jobs(
        (_, _, _, _) async {
          generations++;
          throw const AiImageFetchException('download failed', url: url);
        },
        fetch: (_, task) async {
          downloads.add(task.outputUrl!);
          if (downloadFails) {
            throw const AiImageFetchException(
              'download failed again',
              url: url,
            );
          }
          return AiImageGenerationResult(localFilePath: output.path);
        },
      );
      try {
        final preview = await ProductionImageGenerateOrchestrator().preview(
          canvas,
          node.id,
        );
        final id = await submit(service, preview);
        var task = await service.requireRun(id);
        expect(task.status, GenerationTaskStatus.action_required);
        expect(task.errorCode, 'download_failed');
        expect(task.outputUrl, url);
        expect(task.path, isNull);

        // 启动恢复不能把待重新下载的任务改成生成失败。
        final restarted = jobs((_, _, _, _) async => throw StateError('No AI'));
        await restarted.recover();
        restarted.dispose();
        task = await service.requireRun(id);
        expect(task.status, GenerationTaskStatus.action_required);
        expect(task.errorCode, 'download_failed');

        await expectLater(
          service.retrySaveOutput(id),
          throwsA(isA<AiImageFetchException>()),
        );
        task = await service.requireRun(id);
        expect(task.status, GenerationTaskStatus.action_required);
        expect(task.errorCode, 'download_failed');
        expect(task.outputUrl, url);

        downloadFails = false;
        await service.retrySaveOutput(id);
        task = await service.requireRun(id);
        expect(task.status, GenerationTaskStatus.completed);
        expect(task.resultAssetId, isNotNull);
        expect(
          await File('${root.path}/${task.path}').readAsBytes(),
          await output.readAsBytes(),
        );
        expect(generations, 1);
        expect(downloads, [url, url]);
      } finally {
        await service.shutdown();
      }
    },
  );

  test(
    'provider task ID is stored on submission and survives a restart',
    () async {
      final preview = await ProductionImageGenerateOrchestrator().preview(
        canvas,
        node.id,
      );
      final pending = Completer<AiImageGenerationResult>();
      final submitted = Completer<void>();
      final service = jobs((_, _, onSubmitted, _) async {
        await onSubmitted('prediction-1');
        submitted.complete();
        return pending.future;
      });
      final completion = submit(service, preview);
      await submitted.future;
      final task = await running();
      expect(task.providerTaskId, 'prediction-1');

      // 模拟进程在轮询中退出：同一行留在 running，重启后可重新获取。
      final restarted = jobs((_, _, _, _) async => throw StateError('No AI'));
      await restarted.recover();
      restarted.dispose();
      final recovered = await service.requireRun(task.id);
      expect(recovered.status, GenerationTaskStatus.action_required);
      expect(recovered.errorCode, 'result_fetch_failed');
      expect(recovered.providerTaskId, 'prediction-1');

      pending.complete(AiImageGenerationResult(localFilePath: output.path));
      await completion;
      service.dispose();
    },
  );

  test(
    'poll failure keeps the provider task ID and retry resumes it',
    () async {
      const url = 'https://cdn.example.com/result.png';
      var generations = 0;
      final fetched = <app.GenerationTask>[];
      final service = jobs(
        (_, _, _, _) async {
          generations++;
          throw const AiImageFetchException(
            'poll failed',
            providerTaskId: 'prediction-1',
          );
        },
        fetch: (_, task) async {
          fetched.add(task);
          if (fetched.length == 1) {
            throw const AiImageFetchException('download failed', url: url);
          }
          return AiImageGenerationResult(localFilePath: output.path);
        },
      );
      try {
        final preview = await ProductionImageGenerateOrchestrator().preview(
          canvas,
          node.id,
        );
        final id = await submit(service, preview);
        var task = await service.requireRun(id);
        expect(task.status, GenerationTaskStatus.action_required);
        expect(task.errorCode, 'result_fetch_failed');
        expect(task.providerTaskId, 'prediction-1');
        expect(task.outputUrl, isNull);

        final restarted = jobs((_, _, _, _) async => throw StateError('No AI'));
        await restarted.recover();
        restarted.dispose();
        expect((await service.requireRun(id)).errorCode, 'result_fetch_failed');

        // 查询到结果但下载失败：转为按地址重新下载。
        await expectLater(
          service.retrySaveOutput(id),
          throwsA(isA<AiImageFetchException>()),
        );
        task = await service.requireRun(id);
        expect(task.errorCode, 'download_failed');
        expect(task.outputUrl, url);
        expect(task.providerTaskId, 'prediction-1');

        await service.retrySaveOutput(id);
        task = await service.requireRun(id);
        expect(task.status, GenerationTaskStatus.completed);
        expect(task.resultAssetId, isNotNull);
        expect(generations, 1);
        expect(fetched.first.outputUrl, isNull);
        expect(fetched.first.providerTaskId, 'prediction-1');
        expect(fetched.last.outputUrl, url);
      } finally {
        await service.shutdown();
      }
    },
  );

  test(
    'durable cancellation retains a late asset without adopting after restart',
    () async {
      final pending = Completer<AiImageGenerationResult>();
      final service = jobs((_, _, _, _) => pending.future);
      final preview = await ProductionImageGenerateOrchestrator().preview(
        canvas,
        node.id,
      );
      final completion = submit(service, preview);
      final task = await running();
      final decision = await results().requestCancellation(task.id);
      expect(decision.accepted, true);
      expect((await service.requireRun(task.id)).cancelRequestedAt, isNotNull);
      pending.complete(AiImageGenerationResult(localFilePath: output.path));
      await completion;
      final saved = await service.requireRun(task.id);
      expect(saved.status, GenerationTaskStatus.completed);
      expect(saved.resultAssetId, isNotNull);
      await results().recover();
      expect(
        (await canvas.shots.getShot(node.clipId!))!.adoptedAssetId,
        oldAsset,
      );
      service.dispose();
    },
  );
  test(
    'a stable image request ID does not invoke twice and rejects a different request',
    () async {
      var calls = 0;
      final service = jobs((_, _, _, _) async {
        calls++;
        return AiImageGenerationResult(localFilePath: output.path);
      });
      final preview = await ProductionImageGenerateOrchestrator().preview(
        canvas,
        node.id,
      );
      Future<String> send(ProductionImageRequest request) => service.submit(
        novelId: preview.novelId,
        sourceType: preview.sourceType,
        sourceId: preview.sourceId,
        request: request,
        taskId: 'stable',
      );
      expect(await send(preview.request), 'stable');
      expect(await send(preview.request), 'stable');
      expect(calls, 1);
      await expectLater(
        send(
          ProductionImageRequest.fromJson({
            ...preview.request.toJson(),
            'prompt': 'changed',
          }),
        ),
        throwsA(isA<StoryboardException>()),
      );
      expect(calls, 1);
      service.dispose();
    },
  );

  test('cancelled late result never replaces adopted asset', () async {
    final pending = Completer<AiImageGenerationResult>();
    final service = jobs((_, request, _, _) => pending.future);
    final preview = await ProductionImageGenerateOrchestrator().preview(
      canvas,
      node.id,
    );
    final future = submit(service, preview);
    final run = await running();
    await service.cancel(run.id);
    pending.complete(AiImageGenerationResult(localFilePath: output.path));
    await future;
    expect((await service.requireRun(run.id)).status.name, 'cancelled');
    expect(
      (await canvas.shots.getShot(node.clipId!))!.adoptedAssetId,
      oldAsset,
    );
    expect(await appDb.select(appDb.assets).get(), hasLength(1));
  });

  test('a deleted node stays deleted when its result arrives', () async {
    final pending = Completer<AiImageGenerationResult>();
    final service = jobs((_, request, _, _) => pending.future);
    final future = submit(
      service,
      await ProductionImageGenerateOrchestrator().preview(canvas, node.id),
    );
    await running();
    await canvas.removeNode(node.id);
    pending.complete(AiImageGenerationResult(localFilePath: output.path));
    final run = await service.requireRun(await future);
    expect(run.status.name, 'completed');
    expect(run.resultAssetId, isNotNull);
    expect(await canvas.shots.getShot(node.clipId!), isNull);
    expect(await db.canvasDao.getNodeById(node.id), isNull);
  });

  test(
    'restart fails interrupted generation and resumes downloaded output without AI',
    () async {
      final request = (await ProductionImageGenerateOrchestrator().preview(
        canvas,
        node.id,
      )).request;
      await appDb
          .into(appDb.generationTasks)
          .insert(
            app.GenerationTasksCompanion.insert(
              id: 'interrupted',
              status: GenerationTaskStatus.values.byName('running'),
              kind: GenerationKind.image,
              novelId: 'work',
              sourceType: 'production_clip',
              sourceId: node.clipId!,
              requestJson: ImageGenerationRequest(request),
              providerId: 'image',
              providerType: 'openai',
              modelId: 'gpt-image-2',
            ),
          );
      await appDb
          .into(appDb.generationTasks)
          .insert(
            app.GenerationTasksCompanion.insert(
              id: 'downloaded',
              status: GenerationTaskStatus.values.byName('saving'),
              outputHash: Value(
                sha256.convert(await output.readAsBytes()).toString(),
              ),
              kind: GenerationKind.image,
              novelId: 'work',
              sourceType: 'production_clip',
              sourceId: node.clipId!,
              requestJson: ImageGenerationRequest(request),
              providerId: 'image',
              providerType: 'openai',
              modelId: 'gpt-image-2',
              path: Value(output.path),
            ),
          );
      final service = jobs(
        (_, _, _, _) async => throw StateError('Recovery must never generate'),
      );
      await service.recover();
      expect(
        (await service.requireRun('interrupted')).errorCode,
        'interrupted',
      );
      final saved = await service.requireRun('downloaded');
      expect(saved.status.name, 'completed');
      expect(
        (await canvas.shots.getShot(node.clipId!))!.adoptedAssetId,
        saved.resultAssetId,
      );
      await service.recover();
      expect(await appDb.select(appDb.assets).get(), hasLength(2));
    },
  );

  test(
    'upstream adopted assets resolve at preview and remain frozen for submission',
    () async {
      final source = await canvas.addImage(node.canvasId);
      await canvas.adopt(source.id, oldAsset);
      await canvas.shots.restoreInputs(node.clipId!, [
        ProductionInput(
          id: source.clipId!,
          refType: ProductionInputType.node,
          refId: source.id,
          role: VideoInputRole.reference_image,
        ).toJson(),
      ]);
      final clip = (await canvas.shots.getShot(node.clipId!))!;
      await canvas.shots.apply(clip.id, {
        ...canvas.shots.snapshot(clip),
        'prompt': StoryboardPrompt.reference(source.clipId!, 'Source'),
      });
      final frozen = await ProductionImageGenerateOrchestrator().preview(
        canvas,
        node.id,
      );
      expect(frozen.request.references.single.assetId, oldAsset);
      expect(frozen.request.prompt, '图片1');
      final next = await buildImageLibraryService(appDb).importFile(
        output.path,
        novelId: canvas.novelId,
        purpose: AssetPurpose.production_upload,
      );
      await canvas.adopt(source.id, next.id);
      final current = await ProductionImageGenerateOrchestrator().preview(
        canvas,
        node.id,
      );
      expect(current.request.references.single.assetId, next.id);
      expect(frozen.request.references.single.assetId, oldAsset);
      await expectLater(
        canvas.requireAcyclic(node.id, source.id, node.canvasId),
        throwsA(isA<StoryboardException>()),
      );
      final service = jobs((_, request, _, _) async {
        expect(request.references.single.assetId, oldAsset);
        return AiImageGenerationResult(localFilePath: output.path);
      });
      final run = await service.requireRun(await submit(service, frozen));
      expect(run.imageRequest.references.single.assetId, oldAsset);
      expect(run.status.name, 'completed');
    },
  );

  test(
    'uploaded result uses hash dedup and adopts without generation history',
    () async {
      final library = buildImageLibraryService(appDb);
      final one = await library.importFile(
        output.path,
        novelId: canvas.novelId,
        purpose: AssetPurpose.production_upload,
      );
      final two = await library.importFile(
        output.path,
        novelId: canvas.novelId,
        purpose: AssetPurpose.production_upload,
      );
      expect(one.id, two.id);
      await canvas.adopt(node.id, two.id);
      expect(
        (await canvas.shots.getShot(node.clipId!))!.adoptedAssetId,
        one.id,
      );
      expect(await appDb.select(appDb.generationTasks).get(), isEmpty);
      expect(await appDb.select(appDb.generationTasks).get(), isEmpty);
    },
  );

  test(
    'history orders rapid requests by actual insertion rather than random IDs',
    () async {
      final request = (await ProductionImageGenerateOrchestrator().preview(
        canvas,
        node.id,
      )).request;
      final time = DateTime(2026);
      for (final id in ['zz-first', 'aa-last']) {
        await appDb
            .into(appDb.generationTasks)
            .insert(
              app.GenerationTasksCompanion.insert(
                id: id,
                status: GenerationTaskStatus.values.byName('failed'),
                createdAt: Value(time),
                kind: GenerationKind.image,
                novelId: 'work',
                sourceType: 'production_clip',
                sourceId: node.clipId!,
                requestJson: ImageGenerationRequest(request),
                providerId: 'image',
                providerType: 'openai',
                modelId: 'gpt-image-2',
              ),
            );
      }
      expect(
        (await jobs((_, _, _, _) async => throw StateError('not called'))
                .watchSource(
                  novelId: 'work',
                  sourceType: 'production_clip',
                  sourceId: node.clipId!,
                )
                .first)
            .map((r) => r.id),
        ['aa-last', 'zz-first'],
      );
    },
  );

  test(
    'late saved history cannot replace the newest result or a manual adoption',
    () async {
      final resultService = results();
      final service = ImageTaskService(
        database: appDb,
        images: buildImageLibraryService(appDb),
        invoke: (_, _, _, _) async =>
            AiImageGenerationResult(localFilePath: output.path),

        beforeCreate: resultService.beforeCreate,
        beforeSubmit: resultService.beforeSubmit,
        recoverSources: resultService.recover,
      );
      await service.recover();
      final preview = await ProductionImageGenerateOrchestrator().preview(
        canvas,
        node.id,
      );
      final oldFile = File('${root.path}/old.png');
      await appDb.generationTaskDao.create(
        app.GenerationTasksCompanion.insert(
          id: 'older',
          kind: GenerationKind.image,
          novelId: 'work',
          sourceType: 'production_clip',
          sourceId: node.clipId!,
          providerId: 'image',
          providerType: 'openai',
          modelId: preview.request.modelId,
          status: GenerationTaskStatus.action_required,
          requestJson: ImageGenerationRequest(preview.request),
          path: Value(oldFile.path),
          outputHash: Value(
            sha256.convert(await oldFile.readAsBytes()).toString(),
          ),
        ),
      );
      final latest = await service.requireRun(await submit(service, preview));
      await service.retrySaveOutput('older');
      expect(
        (await service.requireRun('older')).status,
        GenerationTaskStatus.completed,
      );
      expect(
        (await canvas.shots.getShot(node.clipId!))!.adoptedAssetId,
        latest.resultAssetId,
      );
      await canvas.adopt(node.id, oldAsset);
      await resultService.recover();
      expect(
        (await canvas.shots.getShot(node.clipId!))!.adoptedAssetId,
        oldAsset,
      );
    },
  );

  test(
    'shutdown waits for in-flight image requests and rejects further submissions',
    () async {
      final pending = Completer<AiImageGenerationResult>();
      final service = jobs((_, _, _, _) => pending.future);
      final preview = await ProductionImageGenerateOrchestrator().preview(
        canvas,
        node.id,
      );
      final operation = submit(service, preview);
      final task = await running();
      var stopped = false;
      final shutdown = service.shutdown().then((_) {
        stopped = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(stopped, false);
      expect(() => submit(service, preview), throwsStateError);
      pending.complete(AiImageGenerationResult(localFilePath: output.path));
      await operation;
      await shutdown;
      expect(stopped, true);
      expect((await service.requireRun(task.id)).resultAssetId, isNull);
      final restarted = jobs(
        (_, _, _, _) async => throw StateError('Must not regenerate'),
      );
      await restarted.recover();
      expect((await restarted.requireRun(task.id)).errorCode, 'interrupted');
    },
  );

  test(
    'every GPT Image 2 specification fits the image output limits',
    () async {
      final provider = (await appDb.aiProviderDao.getById('image'))!;
      final capabilities = ProductionImageCapabilities(provider, 'gpt-image-2');
      for (final resolution in capabilities.resolutions) {
        for (final ratio in capabilities.ratios) {
          final size = capabilities.size(ratio, resolution)!;
          final sides = size.split('x').map(int.parse).toList();
          for (final side in sides) {
            expect(side % 16, 0, reason: size);
            expect(side, lessThanOrEqualTo(3840), reason: size);
          }
          expect(
            sides.first * sides.last,
            inInclusiveRange(655360, 8294400),
            reason: '$ratio $resolution: $size',
          );
        }
      }
    },
  );

  test('unsupported providers and reference limits are explicit', () async {
    final provider = (await appDb.aiProviderDao.getById('image'))!;
    expect(
      ProductionImageCapabilities.supports(provider.copyWith(type: 'qwen')),
      true,
    );
    final gemini = ProductionImageCapabilities(
      provider.copyWith(type: 'gemini'),
      'gemini-2.5-flash-image',
    );
    expect(gemini.ratios, contains('16:9'));
    expect(gemini.maxReferences, 3);
    expect(
      () => gemini.validate(
        prompt: 'Body',
        ratio: '16:9',
        resolution: 'auto',
        references: 4,
      ),
      throwsFormatException,
    );
  });

  test(
    'read-only provider command keeps dependencies alive through generation',
    () async {
      final pending = Completer<AiImageGenerationResult>();
      final container = ProviderContainer.test(
        overrides: [
          appDatabaseProvider.overrideWithValue(appDb),
          productionResultServiceProvider.overrideWithValue(results()),
          mediaLibraryServiceProvider.overrideWithValue(canvas.library),

          productionImageInvokeProvider.overrideWithValue(
            (_, _, _, _) => pending.future,
          ),
        ],
      );
      final service = container.read(imageTaskServiceProvider);
      final future = submit(
        service,
        await ProductionImageGenerateOrchestrator().preview(canvas, node.id),
      );
      await running();
      await container.pump();
      pending.complete(AiImageGenerationResult(localFilePath: output.path));
      final id = await future;
      expect((await service.requireRun(id)).status.name, 'completed');
      await container.pump();
      expect(container.exists(imageTaskServiceProvider), true);
    },
  );
}

class _RecordFailJobs extends ImageTaskService {
  _RecordFailJobs({
    required super.database,
    required super.images,
    required super.invoke,
    required super.beforeCreate,
    required super.beforeSubmit,
    required super.recoverSources,
  });
  bool rejectRecording = false;
  @override
  Future<void> recordSubmissionFailure(
    ProductionImagePreview preview,
    String providerType,
    Object error,
    StackTrace stack, {
    required String taskId,
  }) async {
    if (rejectRecording) {
      rejectRecording = false;
      throw StateError('one failure record rejected');
    }
    await super.recordSubmissionFailure(
      preview,
      providerType,
      error,
      stack,
      taskId: taskId,
    );
  }
}

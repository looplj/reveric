// 职责: 验证独立画布的真实类型校验、生成请求、采用与派生链路。
// 关联文件:
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/storyboard/service.dart
//   lib/shared/providers/storyboard.dart
import 'dart:io';
import 'dart:ui';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/storyboard.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/services/storyboard/edit_orchestrator.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/derived_placement.dart';
import 'package:reveric/shared/services/production/node_source.dart';
import 'package:reveric/shared/services/production/result_service.dart';
import 'package:reveric/shared/services/production/generate_orchestrator.dart';
import 'package:reveric/shared/services/production/image_generate_orchestrator.dart';
import 'package:reveric/shared/services/production/audio_generate_orchestrator.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';

void main() {
  late NovelContentDatabase db;
  late app.AppDatabase main;
  late Directory root;
  late ProductionCanvasService canvas;
  late WorkingOverlayService overlay;
  late CanvasEntry board;
  setUp(() async {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    main = app.AppDatabase.forTest(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('canvas-work-');
    await ScreenplayService(db).createCanvasStructure();
    await main.novelDao.create(
      id: 'work',
      title: 'Canvas',
      description: '',
      contentKind: contentKindCanvas,
      contentDatabasePath: db.filePath,
    );
    canvas = ProductionCanvasService(
      StoryboardService(db, contentKind: contentKindCanvas),
      MediaLibraryService(main, MediaService(FfmpegRunner()), root),
      'work',
    );
    overlay = WorkingOverlayService(
      db,
      NovelContentService(db),
      novelActionsService: NovelActionsService(main),
    );
    board = await canvas.ensureCanvas('');
  });
  tearDown(() async {
    await db.close();
    await main.close();
    await root.delete(recursive: true);
  });

  test('canvas root and board initialization roll back together', () async {
    final empty = NovelContentDatabase.forTest(NativeDatabase.memory());
    try {
      await expectLater(
        empty.runWithInterceptor(
          () => ScreenplayService(empty).createCanvasStructure(),
          interceptor: _RejectCanvasInsert(),
        ),
        throwsStateError,
      );
      expect(await empty.select(empty.screenplays).get(), isEmpty);
      expect(await empty.select(empty.canvases).get(), isEmpty);
    } finally {
      await empty.close();
    }
  });

  test(
    'canvas clip edits can roll back through the shared working overlay',
    () async {
      final node = await canvas.addImage(board.id);
      await StoryboardEditOrchestrator().save(
        service: canvas.shots,
        overlay: overlay,
        shotId: node.clipId!,
        values: {'title': 'Edited canvas image'},
      );
      final item = (await db.select(db.changeCommitItems).get()).singleWhere(
        (item) =>
            item.resourceId == node.clipId &&
            item.newText!.contains('Edited canvas image'),
      );
      expect(
        await overlay.rollbackCommit(
          commitId: item.commitId,
          resourceId: node.clipId!,
        ),
        RestoreResourceResult.restored,
      );
      expect((await canvas.shots.getShot(node.clipId!))!.title, '');
    },
  );

  test(
    'provider resolves registered kind and rejects empty episode for other works',
    () async {
      final container = ProviderContainer.test(
        overrides: [
          novelContentDatabaseProvider(db.filePath).overrideWithValue(db),
          novelActionsProvider.overrideWith((ref) => NovelActionsService(main)),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        storyboardServiceProvider(db.filePath),
        (_, _) {},
      );
      addTearDown(subscription.close);
      await subscription.read().requireEpisode('');
      final clip = await subscription.read().createImage('');
      expect(clip.episodeId, '');
      await expectLater(
        StoryboardService(db).requireEpisode(''),
        throwsA(isA<StoryboardException>()),
      );
      await main.novelDao.softDelete('work');
      await expectLater(
        subscription.read().requireEpisode(''),
        throwsStateError,
      );
    },
  );

  test(
    'concurrent work canvas resolution does not duplicate the board',
    () async {
      await db.canvasDao.softDeleteCanvas(board.id);
      final boards = await Future.wait([
        for (var i = 0; i < 4; i++) canvas.ensureCanvas(''),
      ]);
      expect(boards.map((b) => b.id).toSet(), hasLength(1));
      expect(boards.first.id, isNot(board.id));
      expect(
        await (db.select(
          db.canvases,
        )..where((t) => t.deletedAt.equals(notDeletedSentinel))).get(),
        hasLength(1),
      );
      expect(await db.select(db.screenplayEpisodes).get(), isEmpty);
    },
  );

  test(
    'video image and audio save requests and adopted results without episodes',
    () async {
      for (final p in [
        ('video', 'doubao', 'doubao-seedance-2-0-260128'),
        ('image', 'openai', 'gpt-image-2'),
        ('audio', 'volcengine', 'seed-audio-1.0'),
      ]) {
        await main
            .into(main.aiProviders)
            .insert(
              app.AiProvidersCompanion.insert(
                id: p.$1,
                name: p.$1,
                type: p.$2,
                apiKey: const Value('test'),
                enabled: const Value(true),
                videoModels: Value(p.$1 == 'video' ? [p.$3] : const []),
                imageModels: Value(p.$1 == 'image' ? [p.$3] : const []),
                audioModels: Value(p.$1 == 'audio' ? [p.$3] : const []),
              ),
            );
      }
      final video = await canvas.addFree(board.id, overlay: overlay);
      final image = await canvas.addImage(board.id);
      final audio = await canvas.addAudio(board.id);
      for (final node in [video, image, audio]) {
        final clip = (await canvas.shots.getShot(node.clipId!))!;
        final model = switch (node.type) {
          'video' => 'doubao-seedance-2-0-260128',
          'image' => 'gpt-image-2',
          _ => 'seed-audio-1.0',
        };
        await canvas.shots.apply(clip.id, {
          ...canvas.shots.snapshot(clip),
          'provider_id': node.type,
          'model_id': model,
          'prompt': 'Test prompt',
          if (node.type == 'image') 'resolution': '2K',
        });
        expect(clip.episodeId, '');
        expect(clip.sceneId, isNull);
        expect(clip.sortOrder, isNull);
        await ProductionResultService(
          main,
          (_) async => canvas,
        ).beforeCreate('work', 'production_clip', clip.id);
        final relative = 'file_workspaces/work/${node.id}.bin';
        final file = File('${root.path}/$relative');
        await file.parent.create(recursive: true);
        await file.writeAsBytes([1, 2, 3]);
        await main.assetDao.insertAsset(
          app.AssetsCompanion.insert(
            id: node.id,
            type: node.type,
            name: Value(node.type),
            path: Value(relative),
            purpose: 'production_output',
            content: Value(switch (node.type) {
              'video' => const VideoAssetContent(mimeType: 'video/mp4'),
              'image' => const ImageAssetContent(mimeType: 'image/png'),
              _ => const AudioAssetContent(mimeType: 'audio/wav'),
            }),
          ),
        );
        await canvas.adopt(node.id, node.id);
        expect((await canvas.shots.getShot(clip.id))!.adoptedAssetId, node.id);
      }
      expect(
        (await ProductionGenerateOrchestrator().preview(
          canvas,
          video.id,
        )).request.prompt,
        contains('Test prompt'),
      );
      expect(
        (await ProductionImageGenerateOrchestrator().preview(
          canvas,
          image.id,
        )).request.prompt,
        contains('Test prompt'),
      );
      expect(
        (await ProductionAudioGenerateOrchestrator().preview(
          canvas,
          audio.id,
        )).request.prompt,
        contains('Test prompt'),
      );
      expect(
        (await ProductionNodeSource.image(canvas, image.id)).episodeId,
        '',
      );
      final placement = await defaultProductionDerivedPlacement(
        canvas,
        image.id,
        const Size(300, 220),
      );
      expect(placement.at.x.isFinite, isTrue);
      final derived = await canvas.addDerivedImage(
        sourceNodeId: image.id,
        draft: const ProductionImageDraft(
          prompt: 'Derived',
          providerId: 'image',
          modelId: 'gpt-image-2',
          ratio: '1:1',
          resolution: '1K',
        ),
        input: ProductionInput.node(image.id, VideoInputRole.reference_image),
      );
      expect((await canvas.shots.getShot(derived.clipId!))!.episodeId, '');
      expect(await db.select(db.screenplayEpisodes).get(), isEmpty);
    },
  );
}

class _RejectCanvasInsert extends QueryInterceptor {
  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.contains('INTO "canvases"')) {
      throw StateError('canvas insert failed');
    }
    return executor.runInsert(statement, args);
  }
}

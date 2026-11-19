// 职责: 验证独立画布的真实类型校验、生成请求、采用与派生链路。
// 关联文件:
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/storyboard/service.dart
//   lib/shared/providers/storyboard.dart
import 'dart:io';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
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
import 'package:reveric/shared/utils/storage_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('character picker selection creates a character image node', () async {
    await db
        .into(db.characterProfiles)
        .insert(CharacterProfilesCompanion.insert(id: 'hero', name: 'Hero'));
    final node = await canvas.addSubject(board.id, characterId: 'hero');
    final clip = (await canvas.shots.getShot(node.clipId!))!;
    expect(node.canvasId, board.id);
    expect(node.type, 'image');
    expect(clip.characterId, 'hero');
    expect(clip.episodeId, isEmpty);
    expect(clip.title, 'Hero');
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
        overlay: overlay.forNovel(canvas.novelId),
        shotId: node.clipId!,
        values: {'title': 'Edited canvas image'},
      );
      final item = (await db.select(db.changeCommitItems).get()).singleWhere(
        (item) =>
            item.resourceId == node.clipId &&
            item.newText!.contains('Edited canvas image'),
      );
      expect(
        await overlay
            .forNovel(canvas.novelId)
            .rollbackCommit(commitId: item.commitId, resourceId: node.clipId!),
        RestoreResourceResult.restored,
      );
      expect((await canvas.shots.getShot(node.clipId!))!.title, '');
    },
  );

  test(
    'draft saves use the known work ID when a path matches multiple registrations',
    () async {
      await main.novelDao.create(
        id: 'other',
        title: 'Other work',
        description: '',
        contentDatabasePath: db.contentDatabasePath,
      );
      final before = DateTime.utc(2020);
      await main
          .update(main.novels)
          .write(app.NovelsCompanion(updatedAt: Value(before)));
      final node = await canvas.addImage(board.id);

      await canvas.saveImage(
        nodeId: node.id,
        draft: const ProductionImageDraft(
          prompt: 'Save on this work',
          modelId: '',
          ratio: '1:1',
          resolution: '1K',
        ),
        inputs: [],
        overlay: overlay,
      );

      expect(
        (await canvas.shots.getShot(node.clipId!))!.prompt,
        'Save on this work',
      );
      expect(
        (await main.novelDao.get('work'))!.updatedAt.isAfter(before),
        isTrue,
      );
      expect(
        (await main.novelDao.get('other'))!.updatedAt.isAtSameMomentAs(before),
        isTrue,
      );
    },
  );

  test(
    'image drafts save and roll back when the registered path differs from the SQLite path',
    () async {
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(pathProvider, (_) async => root.path);
      addTearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));
      await RevericPaths.initialize();
      await Directory('${root.path}/novel_workspaces').create();
      const registeredPath = r'novel_workspaces\canvas.sqlite';
      final content = NovelContentDatabase(registeredPath);
      addTearDown(content.close);
      expect(content.filePath, isNot(registeredPath));
      await main.novelDao.create(
        id: 'path-work',
        title: 'Canvas with a registered path',
        description: '',
        contentKind: contentKindCanvas,
        contentDatabasePath: registeredPath,
      );
      await ScreenplayService(content).createCanvasStructure();
      final service = ProductionCanvasService(
        StoryboardService(content, contentKind: contentKindCanvas),
        canvas.library,
        'path-work',
      );
      final history = WorkingOverlayService(
        content,
        NovelContentService(content),
        novelActionsService: NovelActionsService(main),
      );
      final node = await service.addImage((await service.ensureCanvas('')).id);
      final clipId = node.clipId!;
      await service.saveImage(
        nodeId: node.id,
        draft: const ProductionImageDraft(
          prompt: '生成一个古典庭院',
          modelId: '',
          ratio: '1:1',
          resolution: '1K',
        ),
        inputs: [],
        overlay: history,
      );
      expect((await service.shots.getShot(clipId))!.prompt, '生成一个古典庭院');
      final commit = (await history.getChangeCommits()).single;
      expect(
        await history
            .forNovel(service.novelId)
            .rollbackCommit(commitId: commit.id, resourceId: clipId),
        RestoreResourceResult.restored,
      );
      expect((await service.shots.getShot(clipId))!.prompt, isEmpty);
    },
  );

  test(
    'provider resolves kind by work ID even when two registrations share a path',
    () async {
      await main.novelDao.create(
        id: 'another-work',
        title: 'Another work',
        description: '',
        contentDatabasePath: db.filePath,
      );
      final container = ProviderContainer.test(
        overrides: [
          novelContentDatabaseProvider(db.filePath).overrideWithValue(db),
          novelActionsProvider.overrideWith((ref) => NovelActionsService(main)),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        storyboardServiceProvider(db.filePath, novelId: canvas.novelId),
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

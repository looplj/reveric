// 职责: 验证制作图事务、固定素材身份、结果去重与缺件导出边界。
// 关联文件:
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/production/result_service.dart
import 'package:reveric/shared/models/generation/task.dart';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/models/production/style.dart';
import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/models/production/view_presets.dart';
import 'package:reveric/shared/services/production/style_service.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/ai/media/production.dart';
import 'package:reveric/shared/services/ai/files/session_files.dart';
import 'package:reveric/shared/services/ai/tool_operations.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/services/production/image_service.dart';
import 'package:reveric/shared/services/production/audio_service.dart';
import 'dart:convert';
import 'package:reveric/shared/models/audio/request.dart';
import 'package:reveric/shared/services/production/audio_generate_orchestrator.dart';
import 'package:reveric/shared/services/production/voices.dart';
import 'dart:io';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/provider_asset.dart';
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/storyboard/prompt.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/capabilities.dart';
import 'package:reveric/shared/models/video/channels.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/maps_service.dart';
import 'package:reveric/shared/models/screenplay.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/services/storyboard/edit_orchestrator.dart';
import 'package:reveric/shared/services/subjects.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/result_service.dart';
import 'package:reveric/shared/services/production/generate_orchestrator.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import '../../helpers/media_provider_types.dart';

VideoRequest compileForTest(
  String provider,
  VideoRequest request,
  List<ProductionInput> inputs,
) => compileProductionPrompt(
  provider,
  request,
  inputs.map((input) => ResolvedProductionInput(input, input.refId)).toList(),
);

void main() {
  late NovelContentDatabase db;
  late app.AppDatabase appDb;
  late Directory root;
  late ProductionCanvasService service;
  late ProductionResultService results;
  late WorkingOverlayService overlay;
  late String episode;
  late String scene;
  late ProductionClipRow shot;
  VideoRequest request(String prompt) => VideoRequest(
    modelId: 'model',
    prompt: prompt,
    mode: VideoMode.reference,
    resolution: '720p',
    ratio: '9:16',
  );
  Future<void> asset(String id, {String type = 'image'}) async {
    final extension = switch (type) {
      'image' => 'png',
      'audio' => 'mp3',
      _ => 'mp4',
    };
    final relative = 'file_workspaces/work/$id.$extension';
    final file = File('${root.path}/$relative');
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
    await appDb.assetDao.insertAsset(
      app.AssetsCompanion.insert(
        id: id,
        type: type,
        name: Value(id),
        path: Value(relative),
        content: Value(switch (type) {
          'image' => const ImageAssetContent(mimeType: 'image/png'),
          'audio' => const AudioAssetContent(mimeType: 'audio/mpeg'),
          _ => const VideoAssetContent(mimeType: 'video/mp4'),
        }),
        purpose: type == 'image' ? 'upload' : 'general',
        source: const Value('upload'),
      ),
    );
  }

  Future<app.GenerationTask> task(String id, String assetId) async {
    await appDb
        .into(appDb.generationTasks)
        .insert(
          app.GenerationTasksCompanion.insert(
            id: id,
            novelId: 'work',
            sourceType: 'production_clip',
            sourceId: shot.id,
            providerId: 'provider',
            providerType: 'doubao',
            modelId: 'model',
            status: GenerationTaskStatus.completed,
            requestJson: VideoGenerationRequest(request('saved'), inputs: []),
            resultAssetId: Value(assetId),
            path: Value('file_workspaces/work/$assetId.mp4'),
            kind: GenerationKind.video,
          ),
        );
    return (await appDb.generationTaskDao.getById(id))!;
  }

  setUp(() async {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    appDb = app.AppDatabase.forTest(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('production-test-');
    final screenplay = ScreenplayService(db);
    final initial = await screenplay.createInitialStructure();
    episode = initial.episodeId;
    scene = await screenplay.createScene(
      screenplayId: (await db.screenplayDao.getRoot())!.id,
      episodeId: episode,
      title: '夜雨',
    );
    final shots = StoryboardService(db);
    service = ProductionCanvasService(
      shots,
      MediaLibraryService(appDb, MediaService(FfmpegRunner()), root),
      'work',
    );
    overlay = WorkingOverlayService(
      db,
      NovelContentService(db),
      novelActionsService: NovelActionsService(appDb),
    );
    results = ProductionResultService(
      appDb,
      (id) async => id == 'work' ? service : null,
    );
    shot = await shots.create(scene, values: {'title': '雨夜 / 镜头'});
  });
  tearDown(() async {
    await db.close();
    await appDb.close();
    await root.delete(recursive: true);
  });
  test(
    'video audio choice survives save, copy and request compilation',
    () async {
      await appDb
          .into(appDb.aiProviders)
          .insert(
            app.AiProvidersCompanion.insert(
              id: 'video',
              name: 'Video',
              type: 'doubao',
              enabled: const Value(true),
              apiKey: const Value('test'),
              videoModels: const Value(['doubao-seedance-2-0-260128']),
            ),
          );
      final node = await service.ensureShotNode(shot.id);
      final generate = ProductionGenerateOrchestrator();
      for (final audio in [null, false, true]) {
        await service.save(
          nodeId: node.id,
          providerId: 'video',
          overlay: overlay,
          inputs: [],
          request: VideoRequest(
            modelId: 'doubao-seedance-2-0-260128',
            prompt: 'Rain at night',
            mode: VideoMode.reference,
            resolution: '720p',
            ratio: '9:16',
            audio: audio,
          ),
        );
        final restored = (await service.shots.getShot(shot.id))!;
        expect(shotVideoRequest(restored).audio, audio);
        final preview = await generate.preview(service, node.id);
        expect(preview.request.audio, audio ?? true);
        expect(
          VideoRequest.fromJson(preview.request.toJson()).audio,
          audio ?? true,
        );
        final copy = await service.copyVideo(node.id, overlay: overlay);
        expect(
          (await service.shots.getShot(copy.clipId!))!.generateAudio,
          audio,
        );
        expect(
          (await generate.preview(service, copy.id)).request.audio,
          audio ?? true,
        );
      }
    },
  );

  test(
    'image method saves independently, preserves colors and survives copying',
    () async {
      final canvas = await service.ensureCanvas(episode);
      final node = await service.addImage(canvas.id);
      await db.canvasDao.updateActiveNodeFields(
        node.id,
        const CanvasNodesCompanion(style: Value({'color': 'blue'})),
      );
      const user = '自定义描述保持不变';
      for (final method in [
        ImageGenerationMethod.panorama,
        ImageGenerationMethod.cinematic_light,
        ImageGenerationMethod.free,
      ]) {
        final preset = ImageGenerationPreset(method: method);
        await service.saveImage(
          nodeId: node.id,
          overlay: overlay,
          inputs: [],
          draft: ProductionImageDraft(
            prompt: user,
            modelId: '',
            ratio: '2:1',
            resolution: '2K',
            preset: preset,
          ),
        );
        final stored = await service.requireNode(node.id);
        expect((await service.shots.getShot(node.clipId!))!.prompt, user);
        expect(stored.style!['color'], 'blue');
        final restored = ImageGenerationPreset.fromStyle(stored.style);
        expect(restored.method, method);
        expect(
          stored.style!['panorama'] != null,
          method == ImageGenerationMethod.panorama,
        );
        final copy = await service.copyVideo(node.id, overlay: overlay);
        expect(ImageGenerationPreset.fromStyle(copy.style).method, method);
        expect((await service.shots.getShot(copy.clipId!))!.prompt, user);
        expect(copy.style?['panorama'], isNull);
      }
      expect(await appDb.select(appDb.generationTasks).get(), isEmpty);
    },
  );

  test(
    'speech voice and delivery persist, copy and freeze in the generated request',
    () async {
      const model = 'google/gemini-3.8-flash-tts';
      await appDb
          .into(appDb.aiProviders)
          .insert(
            app.AiProvidersCompanion.insert(
              id: 'speech',
              name: 'Speech',
              type: 'openrouter',
              enabled: const Value(true),
              audioModels: const Value([model]),
            ),
          );
      final board = await service.ensureCanvas(episode);
      final node = await service.addAudio(board.id);
      await service.saveAudio(
        nodeId: node.id,
        prompt: '我们出发吧。',
        providerId: 'speech',
        modelId: model,
        inputs: [],
        overlay: overlay,
        parameters: const AudioRequestDefaults(
          voice: ConfigValue('Kore'),
          instructions: ConfigValue('温柔'),
        ),
      );
      final preview = await ProductionAudioGenerateOrchestrator().preview(
        service,
        node.id,
      );
      expect(preview.request.parameters.voice, 'Kore');
      expect(preview.request.parameters.instructions, '温柔');
      expect(preview.request.prompt, '我们出发吧。');
      final copy = await service.copyVideo(node.id, overlay: overlay);
      final copied = await ProductionAudioGenerateOrchestrator().preview(
        service,
        copy.id,
      );
      expect(
        copied.request.parameters.toJson(),
        preview.request.parameters.toJson(),
      );
      await service.saveAudio(
        nodeId: node.id,
        prompt: '新台词',
        providerId: 'speech',
        modelId: model,
        inputs: [],
        overlay: overlay,
        parameters: const AudioRequestDefaults(
          voice: ConfigValue('Puck'),
          instructions: ConfigValue('平静'),
        ),
      );
      expect(preview.request.parameters.voice, 'Kore');
      expect(
        (await ProductionAudioGenerateOrchestrator().preview(
          service,
          node.id,
        )).request.parameters.voice,
        'Puck',
      );
    },
  );

  test(
    'character voices share across canvases and survive unrelated character edits',
    () async {
      final content = NovelContentService(db);
      final characterId = await content.createCharacterProfile(name: 'Actor');
      await asset('normal', type: 'audio');
      await asset('young', type: 'audio');
      await asset('picture');
      await service.addCharacterVoice(characterId, 'normal');
      await service.addCharacterVoice(characterId, 'normal');
      await service.addCharacterVoice(characterId, 'young');
      await service.renameCharacterVoice(
        characterId,
        'normal',
        '  Normal voice  ',
      );
      await content.updateCharacterProfile(
        entryId: characterId,
        name: 'Actor renamed',
        role: 'supporting',
        gender: 'unknown',
        biography: '',
        description: '',
      );
      expect((await db.characterProfileDao.getById(characterId))!.voices, [
        const CharacterVoice(assetId: 'normal', name: 'Normal voice'),
        const CharacterVoice(assetId: 'young', name: 'young'),
      ]);
      final firstCanvas = await service.shots.ensureCanvas(episode);
      final secondEpisode = await ScreenplayService(db).createEpisode(
        seasonId: (await db.screenplayDao.getEpisode(episode))!.seasonId,
        title: 'Second',
      );
      final secondCanvas = await service.shots.ensureCanvas(secondEpisode);
      for (final board in [firstCanvas, secondCanvas]) {
        final node = await service.addSubject(
          board.id,
          characterId: characterId,
        );
        final input = ProductionInput.node(
          node.id,
          VideoInputRole.reference_image,
        ).withVoice('normal');
        expect((await service.inputCharacter(input))!.voices!.length, 2);
        final bare = ProductionInput.node(
          node.id,
          VideoInputRole.reference_image,
        );
        expect((await service.withDefaultVoice(bare)).voiceAssetId, 'normal');
        expect(
          (await service.withDefaultVoice(
            bare.withVoice('young'),
          )).voiceAssetId,
          'young',
        );
        await service.requireInputVoice(input, requireBinding: true);
        expect(ProductionInput.fromJson(input.toJson()).voiceAssetId, 'normal');
        if (board.id == firstCanvas.id) {
          final target = await service.ensureShotNode(shot.id);
          await service.save(
            nodeId: target.id,
            request: request('A line'),
            providerId: null,
            inputs: [input],
            overlay: overlay,
          );
          expect(
            (await service.inputs(target.id)).single.voiceAssetId,
            'normal',
          );
          final names = await service.audioInputNames([
            input,
            ProductionInput.asset('young', VideoInputRole.reference_audio),
          ]);
          expect(names.audio, ['young']);
          expect(names.voices, ['Actor renamed · Normal voice']);
          final copy = await service.copyVideo(target.id, overlay: overlay);
          expect((await service.inputs(copy.id)).single.voiceAssetId, 'normal');
          await expectLater(
            service.save(
              nodeId: target.id,
              request: request('A line'),
              providerId: null,
              inputs: [input.withVoice('picture')],
              overlay: overlay,
            ),
            throwsA(isA<StoryboardException>()),
          );
          expect(
            (await service.inputs(target.id)).single.voiceAssetId,
            'normal',
          );
        }
      }
      await expectLater(
        service.addCharacterVoice(characterId, 'picture'),
        throwsA(isA<StoryboardException>()),
      );
      await service.removeCharacterVoice(characterId, 'normal');
      expect(
        (await db.characterProfileDao.getById(
          characterId,
        ))!.voices!.single.assetId,
        'young',
      );
      expect(await appDb.assetDao.getAsset('normal'), isNotNull);
      await service.removeCharacterVoice(characterId, 'young');
      expect(
        (await db.characterProfileDao.getById(characterId))!.voices,
        isEmpty,
      );
      final silent = await service.addSubject(
        firstCanvas.id,
        characterId: characterId,
      );
      expect(
        (await service.withDefaultVoice(
          ProductionInput.node(silent.id, VideoInputRole.reference_image),
        )).voiceAssetId,
        isNull,
      );
    },
  );

  test('Agent image creation preserves subjects and adopted photos', () async {
    final content = NovelContentService(db);
    final tools = AiToolManager(
      content,
      workingOverlayService: overlay,
      contentKind: 'screenplay',
      sessionId: 'test',
    )..registerAllTools();
    addTearDown(tools.dispose);
    final subjects = {
      'character_id': await content.createCharacterProfile(name: 'Actor'),
      'location_id': await content.locationsService.createLocation(name: 'Set'),
      'item_id': await content.createItem(type: 'item', title: 'Prop'),
    };
    for (final subject in subjects.entries) {
      final created = await tools.executeTool(
        name: 'Create',
        input: {
          'path': 'clips',
          'fields': {
            'episode_id': episode,
            'kind': 'image',
            'title': 'Reference',
            subject.key: subject.value,
          },
        },
      );
      expect(created['ok'], isTrue, reason: '$created');
      expect(created[subject.key], subject.value);
      expect(created['ignored_fields'], isNull);
      final clip = (await service.shots.getShot(created['id'] as String))!;
      expect(clip.subjectId, subject.value);
      final node = await service.shots.ensureClipNode(clip.id);
      final assetId = 'photo-${subject.key}';
      await asset(assetId);
      await service.adopt(node.id, assetId);
      await service.adopt(node.id, assetId);
      expect(await service.subjectPhotos(clip), [
        SubjectPhoto(assetId: assetId, name: 'Reference'),
      ]);
    }
  });

  test(
    'Agent image creation rejects invalid subject bindings atomically',
    () async {
      final content = NovelContentService(db);
      final tools = AiToolManager(
        content,
        workingOverlayService: overlay,
        contentKind: 'screenplay',
        sessionId: 'test',
      )..registerAllTools();
      addTearDown(tools.dispose);
      final character = await content.createCharacterProfile(name: 'Actor');
      final location = await content.locationsService.createLocation(
        name: 'Set',
      );
      final item = await content.createItem(type: 'item', title: 'Prop');
      Future<List<Map<String, dynamic>>> storedClips() async => [
        for (final row
            in await db.customSelect('SELECT * FROM production_clips').get())
          row.data,
      ];
      final before = await storedClips();
      for (final fields in [
        {'character_id': 'missing'},
        {'location_id': 'missing'},
        {'item_id': 'missing'},
        {'character_id': character, 'location_id': location},
        {'character_id': character, 'item_id': item},
        {'location_id': location, 'item_id': item},
        {'kind': 'video', 'character_id': character},
        {'kind': 'audio', 'location_id': location},
      ]) {
        final result = await tools.executeTool(
          name: 'Create',
          input: {
            'path': 'clips',
            'fields': {'episode_id': episode, 'kind': 'image', ...fields},
          },
        );
        expect(result['error_code'], isNotNull, reason: '$fields: $result');
        expect(await storedClips(), before);
      }
    },
  );

  test(
    'opening production adds episode subjects once and preserves edits',
    () async {
      final screenplay = ScreenplayService(db);
      final rootId = (await db.screenplayDao.getRoot())!.id;
      final content = NovelContentService(db);
      final character = await content.createCharacterProfile(name: 'Cast');
      final location = await content.locationsService.createLocation(
        name: 'Set',
      );
      await content.locationsService.updateLocation(
        id: location,
        photos: [SubjectPhoto(assetId: 'set')],
      );
      await screenplay.updateScene(sceneId: scene, locationId: Value(location));
      await screenplay.replaceCast(sceneId: scene, characterIds: [character]);
      final second = await screenplay.createScene(
        screenplayId: rootId,
        episodeId: episode,
        locationId: location,
      );
      await screenplay.replaceCast(sceneId: second, characterIds: [character]);

      // A manually added subject already on the board must be reused.
      final canvas = await service.shots.ensureCanvas(episode);
      final manual = await service.addSubject(
        canvas.id,
        characterId: character,
      );
      await service.move(manual.id, -400, -200);
      await service.shots.apply(manual.clipId!, {
        ...service.shots.snapshot(
          (await service.shots.getShot(manual.clipId!))!,
        ),
        'prompt': 'Keep my prompt',
      });
      final canvases = await Future.wait([
        service.ensureCanvas(episode),
        service.ensureCanvas(episode),
      ]);
      expect(canvases.map((row) => row.id).toSet(), {canvas.id});
      final subjects = (await service.shots.episodeClips(
        episode,
      )).where((clip) => clip.kind == 'image').toList();
      expect(subjects, hasLength(2));
      expect(
        subjects.singleWhere((clip) => clip.characterId == character).id,
        manual.clipId,
      );
      final place = subjects.singleWhere((clip) => clip.locationId == location);
      expect(place.adoptedAssetId, 'set');
      final all = await db.canvasDao.getNodesByCanvas(canvas.id);
      // 每个场次各有一个场次节点。
      expect(all.map((node) => node.sceneId).nonNulls.toSet(), {scene, second});
      final nodes = all.where((node) => node.sceneId == null).toList();
      expect(nodes, hasLength(3));
      expect(
        nodes.singleWhere((node) => node.clipId == place.id).type,
        canvasNodeTypeImage,
      );
      expect((await service.requireNode(manual.id)).x, -400);
      expect((await service.requireNode(manual.id)).y, -200);
      expect(
        (await service.shots.getShot(manual.clipId!))!.prompt,
        'Keep my prompt',
      );

      // Newly linked subjects are added when reopening an existing board.
      final added = await content.createCharacterProfile(name: 'New cast');
      await screenplay.replaceCast(
        sceneId: second,
        characterIds: [character, added],
      );
      await service.ensureCanvas(episode);
      await service.ensureCanvas(episode);
      expect(
        (await service.shots.episodeClips(
          episode,
        )).where((clip) => clip.characterId == added),
        hasLength(1),
      );
      expect(
        (await db.canvasDao.getNodesByCanvas(
          canvas.id,
        )).where((node) => node.sceneId == null),
        hasLength(4),
      );

      // Manual removal remains removed, including after recreating the canvas.
      final placeNode = nodes.singleWhere((node) => node.clipId == place.id);
      await service.removeNode(manual.id);
      await service.removeNode(placeNode.id);
      await service.ensureCanvas(episode);
      expect(
        (await db.canvasDao.getNodesByCanvas(
          canvas.id,
        )).where((node) => node.sceneId == null),
        hasLength(2),
      );
      await service.removeCanvas(canvas.id);
      final rebuilt = await service.ensureCanvas(episode);
      expect(
        (await db.canvasDao.getNodesByCanvas(
          rebuilt.id,
        )).where((node) => node.sceneId == null),
        hasLength(2),
      );
      final retained = await service.shots.episodeClips(episode);
      expect(retained.where((clip) => clip.characterId == character), isEmpty);
      expect(retained.where((clip) => clip.locationId == location), isEmpty);
    },
  );

  test(
    'reopening production adopts later subject photos only for empty live nodes',
    () async {
      final content = NovelContentService(db);
      final screenplay = ScreenplayService(db);
      final character = await content.createCharacterProfile(name: 'Cast');
      final removed = await content.createCharacterProfile(name: 'Removed');
      final location = await content.locationsService.createLocation(
        name: 'Set',
      );
      await screenplay.replaceCast(
        sceneId: scene,
        characterIds: [character, removed],
      );
      await screenplay.updateScene(sceneId: scene, locationId: Value(location));
      final canvas = await service.ensureCanvas(episode);
      final before = await service.shots.episodeClips(episode);
      final person = before.singleWhere(
        (clip) => clip.characterId == character,
      );
      final place = before.singleWhere((clip) => clip.locationId == location);
      final removedClip = before.singleWhere(
        (clip) => clip.characterId == removed,
      );
      final nodes = await db.canvasDao.getNodesByCanvas(canvas.id);
      final personNode = nodes.singleWhere((node) => node.clipId == person.id);
      await service.move(personNode.id, -400, -200);
      await service.shots.apply(person.id, {
        ...service.shots.snapshot(person),
        'prompt': 'Keep prompt',
      });
      await service.removeNode(
        nodes.singleWhere((node) => node.clipId == removedClip.id).id,
      );
      expect(person.adoptedAssetId, isNull);
      expect(place.adoptedAssetId, isNull);
      for (final id in ['first', 'second', 'set']) {
        await asset(id);
      }
      for (final id in [character, removed]) {
        await (db.update(
          db.characterProfiles,
        )..where((t) => t.id.equals(id))).write(
          CharacterProfilesCompanion(
            photos: Value([
              SubjectPhoto(assetId: 'first'),
              SubjectPhoto(assetId: 'second'),
            ]),
          ),
        );
      }
      await content.locationsService.updateLocation(
        id: location,
        photos: [SubjectPhoto(assetId: 'set')],
      );
      await service.ensureCanvas(episode);
      expect((await service.shots.getShot(person.id))!.adoptedAssetId, 'first');
      expect((await service.shots.getShot(place.id))!.adoptedAssetId, 'set');
      expect((await service.shots.getShot(person.id))!.prompt, 'Keep prompt');
      expect((await service.requireNode(personNode.id)).x, -400);
      final deleted = await (db.select(
        db.productionClips,
      )..where((t) => t.id.equals(removedClip.id))).getSingle();
      expect(deleted.adoptedAssetId, isNull);
      expect(deleted.deletedAt, isNot(notDeletedSentinel));
      await service.adopt(personNode.id, 'second');
      await service.ensureCanvas(episode);
      await service.ensureCanvas(episode);
      expect(
        (await service.shots.getShot(person.id))!.adoptedAssetId,
        'second',
      );
      expect(
        await db.canvasDao.getNodesByCanvas(canvas.id),
        hasLength(nodes.length - 1),
      );
    },
  );

  test(
    'new production canvas includes only live scenes in its episode',
    () async {
      final screenplay = ScreenplayService(db);
      final rootId = (await db.screenplayDao.getRoot())!.id;
      final seasonId = (await db.screenplayDao.getEpisode(episode))!.seasonId;
      final otherEpisode = await screenplay.createEpisode(seasonId: seasonId);
      final content = NovelContentService(db);
      final wanted = await content.createCharacterProfile(name: 'Wanted');
      final excluded = await content.createCharacterProfile(name: 'Excluded');
      final location = await content.locationsService.createLocation(
        name: 'Set',
      );
      final liveScene = await screenplay.createScene(
        screenplayId: rootId,
        episodeId: otherEpisode,
        locationId: location,
      );
      await screenplay.replaceCast(sceneId: liveScene, characterIds: [wanted]);
      final deletedScene = await screenplay.createScene(
        screenplayId: rootId,
        episodeId: otherEpisode,
      );
      await screenplay.replaceCast(
        sceneId: deletedScene,
        characterIds: [excluded],
      );
      await screenplay.deleteScene(deletedScene);
      await screenplay.replaceCast(sceneId: scene, characterIds: [excluded]);

      final canvas = await service.ensureCanvas(otherEpisode);
      final clips = await service.shots.episodeClips(otherEpisode);
      expect(clips, hasLength(2));
      expect(clips.map((clip) => clip.characterId).whereType<String>(), [
        wanted,
      ]);
      expect(clips.map((clip) => clip.locationId).whereType<String>(), [
        location,
      ]);
      expect(clips.every((clip) => clip.adoptedAssetId == null), isTrue);
      final nodes = await db.canvasDao.getNodesByCanvas(canvas.id);
      expect(nodes.where((node) => node.sceneId == null), hasLength(2));
      // 只给仍存在的场次建场次节点。
      expect(nodes.map((node) => node.sceneId).nonNulls, [liveScene]);
    },
  );

  test('scene nodes own the scene position and stay in sync', () async {
    final screenplay = ScreenplayService(db);
    final shotNode = await service.ensureShotNode(shot.id);
    final empty = await screenplay.createScene(
      screenplayId: (await db.screenplayDao.getRoot())!.id,
      episodeId: episode,
    );
    final canvas = await service.ensureCanvas(episode);
    CanvasNode anchorOf(List<CanvasNode> nodes, String sceneId) =>
        nodes.singleWhere((n) => n.sceneId == sceneId);
    var nodes = await db.canvasDao.getNodesByCanvas(canvas.id);
    // 有片段的场次取片段位置；空场次也有场次节点，且不能删除。
    expect(anchorOf(nodes, scene).x, shotNode.x);
    expect(anchorOf(nodes, scene).y, shotNode.y);
    final emptyAnchor = anchorOf(nodes, empty);
    await expectLater(
      service.removeNode(emptyAnchor.id),
      throwsA(isA<StoryboardException>()),
    );

    // 空场次的第一段落在场次节点原位。
    final first = await service.ensureShotNode(
      (await service.shots.create(empty, values: {'title': 'first'})).id,
    );
    expect((first.x, first.y), (emptyAnchor.x, emptyAnchor.y));

    // 只移动场次节点：场内片段一起平移。
    await service.moveNodes(canvas.id, {
      emptyAnchor.id: (x: emptyAnchor.x + 100, y: emptyAnchor.y + 50),
    });
    final moved = await service.requireNode(first.id);
    expect((moved.x, moved.y), (first.x + 100, first.y + 50));

    // 只移动片段：场次节点跟到片段最左、最上的位置。
    await service.moveNodes(canvas.id, {shotNode.id: (x: -300, y: -200)});
    nodes = await db.canvasDao.getNodesByCanvas(canvas.id);
    expect(anchorOf(nodes, scene).x, -300);
    expect(anchorOf(nodes, scene).y, -200);
  });

  test(
    'deleted assets invalidate media references even while their files remain',
    () async {
      await asset('path-only');
      final node = await service.addMedia(
        (await service.ensureCanvas(episode)).id,
        'path-only',
      );
      await appDb.assetDao.softDeleteAsset('path-only');
      await expectLater(
        service.requireAsset(node.mediaAssetId!),
        throwsA(isA<StoryboardException>()),
      );
      await expectLater(
        service.resolveInput(
          ProductionInput.node(node.id, VideoInputRole.reference_image),
        ),
        throwsA(isA<StoryboardException>()),
      );
      expect(
        (await service.requireFile(r'file_workspaces\work\path-only.png')).path,
        'file_workspaces/work/path-only.png',
      );
      for (final path in [
        '../file_workspaces/work/path-only.png',
        'file_workspaces/work/../path-only.png',
        '/tmp/outside.png',
        'file_workspaces/work/missing.png',
      ]) {
        await expectLater(service.requireFile(path), throwsA(anything));
      }
    },
  );
  for (final type in ['character', 'location', ...compendiumEntityTypes]) {
    final character = type == 'character';
    final location = type == 'location';
    final compendium = !character && !location;
    test('$type photos default once and selections remain independent', () async {
      await asset('first-photo');
      await asset('second-photo');
      const first = 'first-photo';
      const second = 'second-photo';
      final content = NovelContentService(db);
      final locations = LocationsService(db);
      final id = character
          ? await content.createCharacterProfile(name: 'Subject')
          : location
          ? await locations.createLocation(name: 'Subject')
          : await content.createItem(type: type, title: 'Subject');
      Future<void> photos(List<String> paths) async {
        final values = paths
            .map((path) => SubjectPhoto(assetId: path))
            .toList();
        if (character) {
          await (db.update(db.characterProfiles)..where((t) => t.id.equals(id)))
              .write(CharacterProfilesCompanion(photos: Value(values)));
        } else if (location) {
          await locations.updateLocation(id: id, photos: values);
        } else {
          await db.itemDao.updatePhotos(id, values);
        }
      }

      Future<void> remove() => character
          ? content.deleteCharacterProfile(id)
          : location
          ? locations.deleteLocation(id)
          : content.deleteItem(id);
      final canvas = await service.ensureCanvas(episode);
      Future<CanvasNode> add() => service.addSubject(
        canvas.id,
        characterId: character ? id : null,
        locationId: location ? id : null,
        itemId: compendium ? id : null,
      );
      final empty = await add();
      expect(
        (await service.shots.getShot(empty.clipId!))!.adoptedAssetId,
        isNull,
      );
      await photos(['missing-first', second]);
      final missing = await add();
      expect(
        (await service.shots.getShot(missing.clipId!))!.adoptedAssetId,
        'missing-first',
      );
      await expectLater(
        service.requireFile('file_workspaces/work/missing-first.png'),
        throwsA(
          isA<StoryboardException>().having(
            (error) => error.code,
            'code',
            'media_missing',
          ),
        ),
      );
      await service.removeNode(missing.id);
      await photos([first, second]);
      final one = await add();
      final two = await add();
      expect(one.type, canvasNodeTypeImage);
      expect(one.refType, canvasNodeRefTypeProductionClip);
      final bound = (await service.shots.getShot(one.clipId!))!;
      await expectLater(
        service.shots.apply(bound.id, {
          ...service.shots.snapshot(bound),
          'character_id': null,
          'location_id': null,
          'item_id': null,
        }),
        throwsA(isA<StoryboardException>()),
      );
      expect((await service.shots.getShot(one.clipId!))!.adoptedAssetId, first);
      await service.adopt(one.id, second);
      await service.renameSubjectPhoto(bound, first, '正面');
      await service.renameSubjectPhoto(bound, second, '冬装');
      // Re-adopting an existing photo must preserve its name and list position.
      await service.adopt(one.id, second);
      expect(await service.subjectPhotos(bound), const [
        SubjectPhoto(assetId: first, name: '正面'),
        SubjectPhoto(assetId: second, name: '冬装'),
      ]);
      final copied = await service.copyVideo(one.id, overlay: overlay);
      final copiedClip = (await service.shots.getShot(copied.clipId!))!;
      expect(copiedClip.subjectKind, bound.subjectKind);
      expect(copiedClip.itemId, bound.itemId);
      expect(copiedClip.adoptedAssetId, second);
      await service.removeNode(copied.id);
      await photos([second, first]);
      expect(
        (await service.shots.getShot(one.clipId!))!.adoptedAssetId,
        second,
      );
      expect((await service.shots.getShot(two.clipId!))!.adoptedAssetId, first);
      await service.removeSubjectPhoto(bound, first);
      expect(await service.subjectPhotos(bound), const [
        SubjectPhoto(assetId: second),
      ]);
      expect(await appDb.assetDao.getAsset(first), isNotNull);
      expect(
        (await service.requireAsset(
          (await service.shots.getShot(two.clipId!))!.adoptedAssetId!,
        )).id,
        first,
      );
      await expectLater(remove(), throwsA(isA<ScreenplayServiceException>()));
      await service.removeNode(one.id);
      expect(
        await service.subjectPhotos(
          (await service.shots.getShot(two.clipId!))!,
        ),
        [SubjectPhoto(assetId: second)],
      );
      expect(await appDb.assetDao.getAsset('second-photo'), isNotNull);
      await expectLater(remove(), throwsA(isA<ScreenplayServiceException>()));
      await service.removeNode(two.id);
      await service.removeNode(empty.id);
      await remove();
    });
  }
  test('subject relation rejects mixed subjects and video clips', () async {
    await db
        .into(db.characterProfiles)
        .insert(
          CharacterProfilesCompanion.insert(id: 'character', name: 'Character'),
        );
    await db
        .into(db.locations)
        .insert(LocationsCompanion.insert(id: 'location', name: 'Location'));
    final canvas = await service.ensureCanvas(episode);
    await expectLater(
      service.addSubject(
        canvas.id,
        characterId: 'character',
        locationId: 'location',
      ),
      throwsA(isA<StoryboardException>()),
    );
    await expectLater(
      service.shots.apply(shot.id, {
        ...service.shots.snapshot(shot),
        'character_id': 'character',
      }),
      throwsA(isA<StoryboardException>()),
    );
  });
  test(
    'compendium binds only live entries and rejects mixed or non-image subjects',
    () async {
      final content = NovelContentService(db);
      final canvas = await service.ensureCanvas(episode);
      final ids = <String>[];
      for (final type in compendiumEntityTypes) {
        ids.add(await content.createItem(type: type, title: type));
      }
      final hidden = await content.createItem(type: 'item', title: 'Hidden');
      await db.itemDao.softDelete(hidden);
      await db
          .into(db.items)
          .insert(
            ItemsCompanion.insert(
              id: 'unsupported',
              type: 'unknown',
              title: 'Unknown',
            ),
          );
      expect(
        (await loadSubjects(
          service.db,
          SubjectKind.compendium,
        )).map((s) => s.id),
        unorderedEquals(ids),
      );
      for (final id in [hidden, 'missing', 'unsupported']) {
        await expectLater(
          service.addSubject(canvas.id, itemId: id),
          throwsA(isA<StoryboardException>()),
        );
      }
      final character = await content.createCharacterProfile(name: 'Actor');
      final location = await content.locationsService.createLocation(
        name: 'Set',
      );
      for (final values in [
        {'item_id': ids.first, 'character_id': character},
        {'item_id': ids.first, 'location_id': location},
      ]) {
        await expectLater(
          service.shots.createImage(episode, values: values),
          throwsA(isA<StoryboardException>()),
        );
      }
      await expectLater(
        service.shots.create(scene, values: {'item_id': ids.first}),
        throwsA(isA<StoryboardException>()),
      );
      await expectLater(
        service.shots.createAudio(episode, values: {'item_id': ids.first}),
        throwsA(isA<StoryboardException>()),
      );
      await expectLater(
        service.addSubject(
          canvas.id,
          characterId: character,
          itemId: ids.first,
        ),
        throwsA(isA<StoryboardException>()),
      );
      final node = await service.addSubject(canvas.id, itemId: ids.first);
      final clip = (await service.shots.getShot(node.clipId!))!;
      await expectLater(
        service.shots.apply(clip.id, {
          ...service.shots.snapshot(clip),
          'item_id': ids.last,
        }),
        throwsA(isA<StoryboardException>()),
      );
      await content.addItemPhotos(ids.first, ['one', 'one', 'two']);
      await content.renameItemPhoto(ids.first, 'one', ' Front ');
      await content.addItemPhotos(ids.first, ['one', 'three']);
      await content.removeItemPhoto(ids.first, 'two');
      expect(
        (await watchSubjectProfile(
          service.db,
          SubjectKind.compendium,
          ids.first,
        ).first).photos,
        const [
          SubjectPhoto(assetId: 'one', name: 'Front'),
          SubjectPhoto(assetId: 'three'),
        ],
      );
    },
  );
  test(
    'generated adoption rejects intermediate, cancelled and unregistered outputs',
    () async {
      await asset('validated', type: 'video');
      final node = await service.ensureShotNode(shot.id);
      final complete = await task('result-gate', 'validated');
      for (final status in [
        GenerationTaskStatus.saving,
        GenerationTaskStatus.action_required,
        GenerationTaskStatus.cancelled,
        GenerationTaskStatus.failed,
      ]) {
        await (appDb.update(appDb.generationTasks)
              ..where((t) => t.id.equals(complete.id)))
            .write(app.GenerationTasksCompanion(status: Value(status)));
        expect(
          canAdoptProductionTask(
            (await appDb.generationTaskDao.getById(complete.id))!,
          ),
          isFalse,
        );
        final summary = await ProductionToolHost(
          canvas: service,
          images: _UnusedImages(),
          audio: _UnusedAudio(),
          video: () => throw StateError('No submission'),
          results: results,
        ).summary((await appDb.generationTaskDao.getById(complete.id))!);
        expect(summary['result_file_path'], 'validated.mp4');
        expect(
          summary['cancelled'] == true,
          status == GenerationTaskStatus.cancelled,
        );
        await expectLater(
          service.adoptGenerated(node.id, complete.id),
          throwsA(isA<StoryboardException>()),
        );
        expect((await service.shots.getShot(shot.id))!.adoptedAssetId, isNull);
      }
      await (appDb.update(
        appDb.generationTasks,
      )..where((t) => t.id.equals(complete.id))).write(
        const app.GenerationTasksCompanion(
          status: Value(GenerationTaskStatus.completed),
          resultAssetId: Value(null),
        ),
      );
      await expectLater(
        service.adoptGenerated(node.id, complete.id),
        throwsA(isA<StoryboardException>()),
      );
      await (appDb.update(
        appDb.generationTasks,
      )..where((t) => t.id.equals(complete.id))).write(
        const app.GenerationTasksCompanion(resultAssetId: Value('validated')),
      );
      await service.adoptGenerated(node.id, complete.id);
      expect(
        (await service.shots.getShot(shot.id))!.adoptedAssetId,
        'validated',
      );
    },
  );
  for (final owner in ['episode', 'season', 'root']) {
    test(
      'retained subject clips under deleted $owner do not block entity deletion',
      () async {
        final screenplay = ScreenplayService(db);
        final root = (await db.screenplayDao.getRoot())!;
        final owningEpisode = (await db.screenplayDao.getEpisode(episode))!;
        await screenplay.createSeason(screenplayId: root.id);
        if (owner == 'episode') {
          await screenplay.createEpisode(seasonId: owningEpisode.seasonId);
        }
        final content = NovelContentService(db);
        final character = await content.createCharacterProfile(
          name: 'Owner guard',
        );
        final location = await content.locationsService.createLocation(
          name: 'Owner guard',
        );
        final canvas = await service.ensureCanvas(episode);
        final item = await content.createItem(type: 'faction', title: 'Guild');
        final nodes = [
          await service.addSubject(canvas.id, itemId: item),
          await service.addSubject(canvas.id, characterId: character),
          await service.addSubject(canvas.id, locationId: location),
        ];
        await expectLater(
          content.deleteCharacterProfile(character),
          throwsA(isA<ScreenplayServiceException>()),
        );
        await expectLater(
          content.locationsService.deleteLocation(location),
          throwsA(isA<ScreenplayServiceException>()),
        );
        await expectLater(
          content.deleteItem(item),
          throwsA(isA<ScreenplayServiceException>()),
        );
        if (owner == 'episode') {
          await screenplay.deleteEpisode(episode);
        } else if (owner == 'season') {
          await screenplay.deleteSeason(owningEpisode.seasonId);
        } else {
          await (db.update(db.screenplays)..where((t) => t.id.equals(root.id)))
              .write(ScreenplaysCompanion(deletedAt: Value(DateTime.now())));
        }
        await expectLater(
          service.shots.requireEpisode(episode),
          throwsA(isA<StoryboardException>()),
        );
        await content.deleteItem(item);
        await content.deleteCharacterProfile(character);
        await content.locationsService.deleteLocation(location);
        for (final node in nodes) {
          expect(await service.shots.getShot(node.clipId!), isNotNull);
        }
      },
    );
  }
  test(
    'styles inherit, override or disable without changing drafts; previews freeze the assembled prompt',
    () async {
      final styles = ProductionStyleService(appDb);
      final a = await styles.save(
        name: 'A',
        prompt: ProductionStylePrompt(before: 'Before A', after: 'After A'),
      );
      final b = await styles.save(
        name: 'B',
        prompt: ProductionStylePrompt(before: 'Before B', after: 'After B'),
      );
      await appDb
          .into(appDb.aiProviders)
          .insert(
            app.AiProvidersCompanion.insert(
              id: 'video',
              name: 'Video',
              type: 'doubao',
              enabled: const Value(true),
              apiKey: const Value('test'),
              videoModels: const Value(['doubao-seedance-2-0-260128']),
            ),
          );
      await service.shots.apply(shot.id, {
        ...service.shots.snapshot(shot),
        'prompt': 'Body',
        'provider_id': 'video',
        'model_id': 'doubao-seedance-2-0-260128',
        'duration_ms': 5000,
      });
      final node = await service.ensureShotNode(shot.id);
      final generate = ProductionGenerateOrchestrator();
      expect((await generate.preview(service, node.id)).request.prompt, 'Body');
      await service.setScreenplayStyle(a.id);
      final frozen = await generate.preview(service, node.id);
      expect(frozen.request.prompt, 'Before A\nBody\nAfter A');
      expect(frozen.request.originalPrompt, 'Body');
      await service.setClipStyle(shot.id, CustomProductionStyle(b.id));
      await service.setScreenplayStyle(null);
      expect(
        (await generate.preview(service, node.id)).request.prompt,
        'Before B\nBody\nAfter B',
      );
      final current = (await service.shots.getShot(shot.id))!;
      final legacyEdit = service.shots.snapshot(current)
        ..remove('style_selection');
      await service.shots.apply(shot.id, {
        ...legacyEdit,
        'title': 'Legacy edit',
      });
      expect((await service.shots.getShot(shot.id))!.styleSelection, b.id);
      await styles.save(
        id: b.id,
        name: 'B',
        prompt: ProductionStylePrompt(before: 'New B', after: 'End B'),
      );
      expect(
        (await generate.preview(service, node.id)).request.prompt,
        'New B\nBody\nEnd B',
      );
      expect(frozen.request.prompt, 'Before A\nBody\nAfter A');
      await service.setClipStyle(shot.id, const NoProductionStyle());
      await service.setScreenplayStyle(a.id);
      expect((await generate.preview(service, node.id)).request.prompt, 'Body');
      await service.setClipStyle(shot.id, const InheritedProductionStyle());
      expect(
        (await generate.preview(service, node.id)).request.prompt,
        'Before A\nBody\nAfter A',
      );
      await styles.delete(a.id);
      await expectLater(
        generate.preview(service, node.id),
        throwsA(
          isA<StoryboardException>().having(
            (e) => e.code,
            'code',
            'style_missing',
          ),
        ),
      );
      expect((await service.shots.getShot(shot.id))!.prompt, 'Body');
      expect(frozen.request.prompt, 'Before A\nBody\nAfter A');
    },
  );

  test(
    'screenplay style is shared across seasons and newly created nodes',
    () async {
      final screenplay = ScreenplayService(db);
      final rootId = (await db.screenplayDao.getRoot())!.id;
      final next = await screenplay.createSeason(screenplayId: rootId);
      final nextCanvas = await service.ensureCanvas(next.episodeId);
      final image = await service.addImage(nextCanvas.id);
      final imageClip = (await service.shots.getShot(image.clipId!))!;
      final ink = productionStylePreset('eastern-ink-decorative')!;
      final pixel = productionStylePreset('pixel-art')!;

      await service.setScreenplayStyle('preset:${ink.id}');
      expect(
        (await service.effectiveStyle(shot))!.assemble('Body'),
        ink.prompt.assemble('Body'),
      );
      expect(
        (await service.effectiveStyle(imageClip))!.assemble('Body'),
        ink.prompt.assemble('Body'),
      );

      final laterEpisode = await screenplay.createEpisode(
        seasonId: next.seasonId,
      );
      final laterImage = await service.addImage(
        (await service.ensureCanvas(laterEpisode)).id,
      );
      final laterClip = (await service.shots.getShot(laterImage.clipId!))!;
      expect(
        (await service.effectiveStyle(laterClip))!.assemble('Body'),
        ink.prompt.assemble('Body'),
      );

      await service.setClipStyle(imageClip.id, const NoProductionStyle());
      await service.setClipStyle(laterClip.id, PresetProductionStyle(ink.id));
      await service.setScreenplayStyle('preset:${pixel.id}');
      expect(
        (await service.effectiveStyle(shot))!.assemble('Body'),
        pixel.prompt.assemble('Body'),
      );
      expect(
        await service.effectiveStyle(
          (await service.shots.getShot(imageClip.id))!,
        ),
        isNull,
      );
      expect(
        (await service.effectiveStyle(
          (await service.shots.getShot(laterClip.id))!,
        ))!.assemble('Body'),
        ink.prompt.assemble('Body'),
      );

      await expectLater(
        service.setScreenplayStyle('preset:missing'),
        throwsA(isA<StoryboardException>()),
      );
      expect((await db.screenplayDao.getRoot())!.styleId, 'preset:${pixel.id}');
      await service.setScreenplayStyle(null);
      expect(await service.effectiveStyle(shot), isNull);
      expect(
        (await service.effectiveStyle(
          (await service.shots.getShot(laterClip.id))!,
        ))!.assemble('Body'),
        ink.prompt.assemble('Body'),
      );
    },
  );

  test(
    'preset styles resolve from the built-in catalog through the existing style columns',
    () async {
      final ids = builtinProductionStyles.map((p) => p.id).toList();
      expect(ids, hasLength(42));
      expect(ids.toSet(), hasLength(ids.length));
      expect(
        ids.every((id) => RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$').hasMatch(id)),
        isTrue,
      );
      expect(builtinProductionStyles.map((p) => p.category).toSet(), {
        ProductionStyleCategory.live_action,
        ProductionStyleCategory.two_d,
        ProductionStyleCategory.three_d,
      });
      final preset = productionStylePreset('chinese-supernatural-film')!;
      expect(preset.name, '中式志怪电影感');
      await appDb
          .into(appDb.aiProviders)
          .insert(
            app.AiProvidersCompanion.insert(
              id: 'video',
              name: 'Video',
              type: 'doubao',
              enabled: const Value(true),
              apiKey: const Value('test'),
              videoModels: const Value(['doubao-seedance-2-0-260128']),
            ),
          );
      await service.shots.apply(shot.id, {
        ...service.shots.snapshot(shot),
        'prompt': 'Body',
        'provider_id': 'video',
        'model_id': 'doubao-seedance-2-0-260128',
        'duration_ms': 5000,
      });
      final node = await service.ensureShotNode(shot.id);
      final generate = ProductionGenerateOrchestrator();
      await service.setScreenplayStyle('preset:${preset.id}');
      expect(
        (await db.screenplayDao.getRoot())!.styleId,
        'preset:chinese-supernatural-film',
      );
      expect(
        (await generate.preview(service, node.id)).request.prompt,
        preset.prompt.assemble('Body'),
      );
      final other = builtinProductionStyles.last;
      await service.setClipStyle(shot.id, PresetProductionStyle(other.id));
      final clip = (await service.shots.getShot(shot.id))!;
      expect(clip.styleSelection, 'preset:${other.id}');
      expect(
        ProductionStyleChoice.fromStored(clip.styleSelection),
        isA<PresetProductionStyle>(),
      );
      expect(
        (await generate.preview(service, node.id)).request.prompt,
        other.prompt.assemble('Body'),
      );
      await expectLater(
        service.setClipStyle(shot.id, PresetProductionStyle('gone')),
        throwsA(
          isA<StoryboardException>().having(
            (e) => e.code,
            'code',
            'style_missing',
          ),
        ),
      );
      expect(
        (await service.shots.getShot(shot.id))!.styleSelection,
        'preset:${other.id}',
      );
    },
  );

  test(
    'asset inputs stay inline while node inputs follow adopted images',
    () async {
      await asset('image-input');
      final canvas = await service.ensureCanvas(episode);
      final image = await service.addImage(canvas.id);
      await service.save(
        nodeId: image.id,
        request: request('Image body'),
        providerId: null,
        inputs: const [
          ProductionInput(
            id: 'file_workspaces/work/image-input.png',
            refType: ProductionInputType.asset,
            refId: 'image-input',
            role: VideoInputRole.reference_image,
          ),
        ],
        overlay: overlay,
      );
      final first = await service.draftInputs(image.id);
      await service.save(
        nodeId: image.id,
        request: request('Edited body'),
        providerId: null,
        inputs: const [
          ProductionInput(
            id: 'file_workspaces/work/image-input.png',
            refType: ProductionInputType.asset,
            refId: 'image-input',
            role: VideoInputRole.reference_image,
          ),
        ],
        overlay: overlay,
      );
      expect(
        (await service.draftInputs(image.id)).single.sourceNodeId,
        first.single.sourceNodeId,
      );
      expect(
        (await db.canvasDao.getNodesByCanvas(
          canvas.id,
        )).where((n) => n.mediaAssetId == 'image-input'),
        isEmpty,
      );
      expect((await service.shots.getShot(image.clipId!))!.durationMs, isNull);
      await service.adopt(image.id, 'image-input');
      final target = await service.ensureShotNode(shot.id);
      await service.save(
        nodeId: target.id,
        request: request('Reference image'),
        providerId: null,
        inputs: [
          ProductionInput(
            id: image.clipId!,
            refType: ProductionInputType.node,
            refId: image.id,
            role: VideoInputRole.reference_image,
          ),
        ],
        overlay: overlay,
      );
      expect(
        (await service.resolveInput(
          (await service.draftInputs(target.id)).single,
        )).path,
        'file_workspaces/work/image-input.png',
      );
      await expectLater(
        service.save(
          nodeId: image.id,
          request: request('Cycle'),
          providerId: null,
          inputs: [
            ProductionInput(
              id: image.clipId!,
              refType: ProductionInputType.node,
              refId: image.id,
              role: VideoInputRole.reference_image,
            ),
          ],
          overlay: overlay,
        ),
        throwsA(isA<StoryboardException>()),
      );
    },
  );

  test(
    'scene positions save together and roll back if any node is invalid',
    () async {
      final first = await service.ensureShotNode(shot.id);
      final nextShot = await service.shots.create(
        scene,
        values: {'title': 'Next'},
      );
      final next = await service.ensureShotNode(nextShot.id);
      await service.moveNodes(first.canvasId, {
        first.id: (x: first.x + 80, y: first.y + 40),
        next.id: (x: next.x + 80, y: next.y + 40),
      });
      expect((await service.requireNode(first.id)).x, first.x + 80);
      expect((await service.requireNode(next.id)).y, next.y + 40);
      await expectLater(
        service.moveNodes(first.canvasId, {
          first.id: (x: 999, y: 999),
          'missing': (x: 999, y: 999),
        }),
        throwsA(isA<StoryboardException>()),
      );
      expect((await service.requireNode(first.id)).x, first.x + 80);
      expect((await service.requireNode(next.id)).y, next.y + 40);
    },
  );
  test(
    'new scene clips follow the moved scene instead of its default origin',
    () async {
      final first = await service.ensureShotNode(shot.id);
      await service.move(first.id, 1500, 900);
      final nextShot = await service.shots.create(
        scene,
        values: {'title': 'Next'},
      );
      final next = await service.ensureShotNode(nextShot.id);
      expect(next.x, 1500);
      expect(next.y, greaterThan(900));
      expect((await service.requireNode(first.id)).x, 1500);
      expect((await service.requireNode(first.id)).y, 900);
    },
  );
  test(
    'video tools read the adopted or media video and hang outputs to its right',
    () async {
      final clip = await service.ensureShotNode(shot.id);
      await expectLater(
        service.videoSource(clip.id),
        throwsA(isA<StoryboardException>()),
      );
      await asset('clip-video', type: 'video');
      await service.adopt(clip.id, 'clip-video');
      expect((await service.videoSource(clip.id)).id, 'clip-video');
      final media = await service.addMedia(clip.canvasId, 'clip-video');
      expect((await service.videoSource(media.id)).id, 'clip-video');
      await asset('frame');
      await expectLater(
        service.videoSource(
          (await service.addMedia(clip.canvasId, 'frame')).id,
        ),
        throwsA(isA<StoryboardException>()),
      );

      final first = await service.addDerivedOutput(clip.id, 'frame');
      final second = await service.addDerivedOutput(clip.id, 'frame');
      expect(first.mediaAssetId, 'frame');
      expect(first.x, greaterThan(clip.x + (clip.width ?? 0)));
      expect(second.id, isNot(first.id));
      expect(second.y, greaterThan(first.y));
      final edges = (await db.canvasDao.getEdgesByCanvas(
        clip.canvasId,
      )).where((e) => e.type == canvasEdgeTypeDerivedOutput);
      expect(edges.map((e) => (e.sourceNodeId, e.targetNodeId)), [
        (clip.id, first.id),
        (clip.id, second.id),
      ]);

      // 画布给出落点时原样落下，并在同一次写入里移走让位的节点。
      final placed = await service.addDerivedOutput(
        clip.id,
        'frame',
        placement: (
          at: (x: 700.0, y: 40.0),
          moves: {first.id: (x: 1200.0, y: first.y)},
        ),
      );
      expect((placed.x, placed.y), (700, 40));
      expect((await service.requireNode(first.id)).x, 1200);
    },
  );
  test(
    'director node owns a new staging; each export lands once to its right and can feed a video node',
    () async {
      final canvasId = (await service.ensureShotNode(shot.id)).canvasId;
      final director = await service.addDirector(canvasId, 'Director 1');
      expect(director.type, canvasNodeTypeStaging);
      expect(director.refType, canvasNodeRefTypeStaging);
      final staging = (await db.screenplayDao.getStaging(director.stagingId!))!;
      expect(staging.title, 'Director 1');
      expect(staging.document!['output']['width'], 1280);
      expect(staging.document!['output']['height'], 720);

      await asset('still');
      final outputs = await Future.wait([
        service.addStagingOutput(director.id, 'still'),
        service.addStagingOutput(director.id, 'still'),
      ]);
      expect(outputs.map((n) => n.id).toSet(), hasLength(1));
      final output = outputs.first;
      expect(output.type, canvasNodeTypeMedia);
      expect(output.mediaAssetId, 'still');
      expect(output.x, greaterThan(director.x + (director.width ?? 0)));
      final edges = (await db.canvasDao.getEdgesByCanvas(
        canvasId,
      )).where((e) => e.type == canvasEdgeTypeStagingOutput).toList();
      expect(edges.map((e) => (e.sourceNodeId, e.targetNodeId)), [
        (director.id, output.id),
      ]);
      expect((await service.stagingOutputs(director.id)).map((n) => n.id), [
        output.id,
      ]);

      final target = await service.ensureShotNode(shot.id);
      await service.save(
        nodeId: target.id,
        request: request('参考导演构图'),
        providerId: null,
        inputs: [
          ProductionInput(
            id: output.id,
            refType: ProductionInputType.node,
            refId: output.id,
            role: VideoInputRole.reference_image,
          ),
        ],
        overlay: overlay,
      );
      expect((await service.inputs(target.id)).single.sourceNodeId, output.id);

      await service.removeNode(director.id);
      expect(await db.screenplayDao.getStaging(staging.id), isNotNull);
      expect(await db.canvasDao.getNodeById(output.id), isNotNull);
    },
  );
  test(
    'concurrent navigation creates one canvas and one shot node, hidden from ideation',
    () async {
      final nodes = await Future.wait([
        service.ensureShotNode(shot.id),
        service.ensureShotNode(shot.id),
      ]);
      expect(nodes.map((n) => n.id).toSet(), hasLength(1));
      expect(await db.canvasDao.getAllCanvases(), isEmpty);
      expect(
        (await db.screenplayDao.getEpisode(episode))!.canvasId,
        nodes.first.canvasId,
      );
      expect((await db.select(db.canvases).get()), hasLength(1));
    },
  );
  test(
    'adopting a session result copies it to permanent media before session cleanup',
    () async {
      final canvas = ProductionCanvasService(
        service.shots,
        MediaLibraryService(appDb, _ImageMedia(), root),
        'work',
      );
      final node = await canvas.addImage(
        (await canvas.ensureCanvas(episode)).id,
      );
      final files = SessionFiles(root: root.path, novelId: 'work');
      final source = await files.allocate('adopt', '.png');
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      await source.writeAsBytes(png);
      final host = ProductionToolHost(
        canvas: canvas,
        images: _UnusedImages(),
        audio: _UnusedAudio(),
        video: () => throw StateError('No video'),
        results: results,
      );
      final imported = await canvas.library.importFile(
        source,
        name: 'result.png',
        novelId: canvas.novelId,
        purpose: AssetPurpose.production_output,
        cancellation: MediaCancellation(),
      );
      await host.adopt(node.clipId!, imported.id);
      final stored = (await canvas.shots.getShot(
        node.clipId!,
      ))!.adoptedAssetId!;
      expect(stored, imported.id);
      await (await files.directory('adopt')).delete(recursive: true);
      expect(
        await File(
          canvas.library.resolve((await canvas.requireAsset(stored))),
        ).readAsBytes(),
        png,
      );
    },
  );

  test(
    'Agent media node imports fields.path without confusing its resource path',
    () async {
      final canvas = ProductionCanvasService(
        service.shots,
        MediaLibraryService(appDb, _ImageMedia(), root),
        'work',
      );
      final files = SessionFiles(root: root.path, novelId: 'work');
      final source = await files.allocate('test', '.png');
      await source.writeAsBytes(img.encodePng(img.Image(width: 2, height: 2)));
      final registry = ToolOperationRegistry();
      final operations = ToolOperationManager(
        ownerSessionId: 'test',
        registry: registry,
        gate: () => throw StateError('Session file needs no external import'),
        onChanged: (_) {},
        onRecord: (_) {},
      );
      addTearDown(() {
        operations.dispose();
        registry.dispose();
      });
      final tools = AiToolManager(
        NovelContentService(db),
        workingOverlayService: overlay,
        contentKind: 'screenplay',
        sessionId: 'test',
        workId: 'work',
        operationHost: ToolOperationHost(
          operations,
          production: () async => ProductionToolHost(
            canvas: canvas,
            images: _UnusedImages(),
            audio: _UnusedAudio(),
            video: () => throw StateError('No video call expected'),
            results: results,
          ),
        ),
      )..registerAllTools();
      addTearDown(tools.dispose);
      final created = await tools.executeTool(
        name: 'Create',
        context: ToolExecutionContext(sessionId: 'test', sourceTurnId: 'turn'),
        input: {
          'path': '/episodes/$episode/production/canvas/nodes',
          'fields': {
            'type': 'media',
            'path': 'sessions/test/${p.basename(source.path)}',
          },
        },
      );
      expect(created['ok'], true, reason: '$created');
      final node = await db.canvasDao.getNodeById(created['id'] as String);
      final imported = await appDb.assetDao.getAsset(node!.mediaAssetId!);
      expect(imported, isNotNull);
      expect(imported!.path, startsWith('file_workspaces/work/images/'));
      expect(await File('${root.path}/${imported.path}').exists(), true);
    },
  );

  test(
    'production file imports cannot escape the work through relative paths',
    () async {
      final host = ProductionToolHost(
        canvas: service,
        images: _UnusedImages(),
        audio: _UnusedAudio(),
        video: () => throw StateError('No video call expected'),
        results: results,
      );
      final other = File(
        '${root.path}/file_workspaces/other/images/source.png',
      );
      await other.parent.create(recursive: true);
      await other.writeAsBytes(img.encodePng(img.Image(width: 2, height: 2)));
      final linked = Link('${root.path}/file_workspaces/work/linked');
      await linked.parent.create(recursive: true);
      await linked.create(other.parent.path);
      for (final path in [
        '../other/images/source.png',
        r'..\other\images\source.png',
        'linked/source.png',
        other.path,
        r'C:\outside\source.png',
        r'\\server\share\source.png',
      ]) {
        await expectLater(host.permanentAsset(path), throwsA(anything));
      }
      expect(await other.exists(), true);
      expect(
        await appDb.assetDao.findByPath(
          'file_workspaces/other/images/source.png',
        ),
        isNull,
      );
    },
  );

  test(
    'Agent production routes expose media nodes and task history without generating',
    () async {
      final operations = ToolOperationManager(
        ownerSessionId: 'test',
        registry: ToolOperationRegistry(),
        gate: () => throw StateError('No permission check expected'),
        onChanged: (_) {},
        onRecord: (_) {},
      );
      addTearDown(operations.dispose);
      final tools = AiToolManager(
        NovelContentService(db),
        workingOverlayService: overlay,
        contentKind: 'screenplay',
        sessionId: 'test',
        workId: 'work',
        operationHost: ToolOperationHost(
          operations,
          production: () async => ProductionToolHost(
            canvas: service,
            images: _UnusedImages(),
            audio: _UnusedAudio(),
            video: () => throw StateError('No video call expected'),
            results: results,
          ),
        ),
      );
      tools.registerAllTools();
      for (final kind in ['image', 'audio']) {
        final created = await tools.executeTool(
          name: 'Create',
          input: {
            'path': '/episodes/$episode/production/canvas/nodes',
            'fields': {'type': kind, 'title': kind},
          },
        );
        expect(created['ok'], true, reason: '$created');
        final node = await db.canvasDao.getNodeById(created['id'] as String);
        expect((await service.shots.getShot(node!.clipId!))!.kind, kind);
      }
      await asset('tool-image');
      final media = await tools.executeTool(
        name: 'Create',
        input: {
          'path': '/episodes/$episode/production/canvas/nodes',
          'fields': {'type': 'media', 'asset_id': 'tool-image'},
        },
      );
      expect(media['ok'], true, reason: '$media');
      expect(media['ref_id'], 'tool-image');
      expect(media.containsKey('media_path'), isFalse);
      final video = await tools.executeTool(
        name: 'Create',
        input: {
          'path': '/episodes/$episode/production/canvas/nodes',
          'fields': {'type': 'video'},
        },
      );
      expect(video['created'], isTrue, reason: '$video');
      final bound = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'clips/${video['ref_id']}',
          'fields': {
            'inputs': [
              {
                'id': 'ref-image',
                'ref_type': 'asset',
                'ref_id': 'tool-image',
                'role': 'reference_image',
              },
            ],
            'prompt': 'Rain <ref input_id="ref-image" label="Image" />',
          },
        },
      );
      expect(bound['updated'], isTrue, reason: '$bound');
      expect(bound['inputs'], hasLength(1));
      final listing = await tools.executeTool(
        name: 'Run',
        input: {
          'command': 'assets',
          'subcommand': 'list',
          'options': {'type': 'image', 'search': 'tool'},
        },
      );
      expect((listing['entries'] as List).single['id'], 'tool-image');
      Future<Map<String, dynamic>> run(
        String command,
        String action,
        Map<String, dynamic> options,
      ) => tools.executeTool(
        name: 'Run',
        callId: 'run-test',
        context: ToolExecutionContext(sessionId: 'test', sourceTurnId: 'turn'),
        input: {'command': command, 'subcommand': action, 'options': options},
      );
      final detail = await run('assets', 'read', {'id': 'tool-image'});
      expect(detail['ok'], isTrue, reason: '$detail');
      expect(detail['id'], 'tool-image');
      expect(detail['file_path'], 'tool-image.png');
      expect(detail, isNot(contains('path')));
      expect(detail['specifications'], contains('mime_type'));
      expect(detail['certifications'], isEmpty);
      final certified = await appDb.providerAssetDao.start(
        'tool-image',
        'volc',
      );
      await appDb.providerAssetDao.write(
        certified.id,
        const app.ProviderAssetsCompanion(
          status: Value(ProviderAssetStatus.failed),
          errorCode: Value('QuotaExceeded'),
        ),
      );
      expect(
        (await run('assets', 'read', {'id': 'tool-image'}))['certifications'],
        [
          {
            'provider_id': 'volc',
            'status': 'failed',
            'error_code': 'QuotaExceeded',
          },
        ],
      );
      // 测试宿主不提供认证服务：明确报 unavailable，而不是静默成功。
      expect(
        (await run('assets', 'certify', {
          'id': 'tool-image',
          'provider_id': 'volc',
        }))['error_code'],
        'unavailable',
      );
      expect(
        (await run('assets', 'certify', {'id': 'tool-image'}))['error_code'],
        'invalid_argument',
      );
      expect(
        (await run('assets', 'read', {'id': 'missing'}))['error_code'],
        'not_found',
      );
      await asset('shared');
      expect((await run('assets', 'read', {'id': 'shared'}))['ok'], isTrue);
      await asset('other-work');
      await (appDb.update(appDb.assets)
            ..where((t) => t.id.equals('other-work')))
          .write(const app.AssetsCompanion(novelId: Value('other-work')));
      expect(
        (await run('assets', 'read', {'id': 'other-work'}))['error_code'],
        'not_found',
      );
      expect(
        (await run('assets', 'read', {'id': 1}))['error_code'],
        'invalid_argument',
      );
      for (final action in ['read', 'view-image']) {
        expect(
          (await run('assets', action, {
            'asset_id': 'tool-image',
          }))['error_code'],
          'invalid_argument',
        );
      }
      final assetHelp = await tools.executeTool(
        name: 'Run',
        input: const {'command': 'help', 'subcommand': 'assets'},
      );
      expect(assetHelp.toString(), contains('assets read: id required'));
      expect(
        assetHelp.toString(),
        contains('assets certify: id and provider_id required'),
      );
      expect(assetHelp.toString(), isNot(contains('asset_id required')));
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => root.path,
          );
      await RevericPaths.initialize();
      await File(
        '${root.path}/file_workspaces/work/tool-image.png',
      ).writeAsBytes(img.encodePng(img.Image(width: 2, height: 2)));
      for (final type in ['audio', 'video']) {
        await asset('tool-$type', type: type);
        final metadata = await run('assets', 'read', {'id': 'tool-$type'});
        expect(metadata['ok'], true);
        expect(metadata['specifications'], contains('mime_type'));
        expect(
          (await run('assets', 'view-image', {
            'id': 'tool-$type',
          }))['error_code'],
          'invalid_argument',
        );
      }
      final view = await run('assets', 'view-image', {'id': 'tool-image'});
      expect(view['ok'], isTrue, reason: '$view');
      expect(view['id'], 'tool-image');
      expect(view['file_path'], 'tool-image.png');
      expect(
        (view['content'] as List).map((item) => (item as Map)['type']),
        contains('image'),
      );
      expect(
        (await run('assets', 'view-image', {'id': 'missing'}))['error_code'],
        'not_found',
      );
      expect(
        (await run('assets', 'list', {'type': 1}))['error_code'],
        'invalid_argument',
      );
      expect(
        (await run('assets', 'list', {'search': 'absent'}))['entries'],
        isEmpty,
      );
      expect(
        (await run('assets', 'list', {'path': '/other'}))['error_code'],
        'invalid_argument',
      );
      final generation = await task('history', 'result');
      final history = await tools.executeTool(
        name: 'Read',
        input: {'path': '/clips/${shot.id}/generations'},
      );
      expect((history['entries'] as List).single['id'], generation.id);
      expect((history['entries'] as List).single['result_applied'], false);
    },
  );

  group('Agent clip creation with inputs', () {
    late AiToolManager tools;

    setUp(() {
      final operations = ToolOperationManager(
        ownerSessionId: 'test',
        registry: ToolOperationRegistry(),
        gate: () => throw StateError('No permission check expected'),
        onChanged: (_) {},
        onRecord: (_) {},
      );
      addTearDown(operations.dispose);
      tools = AiToolManager(
        NovelContentService(db),
        workingOverlayService: overlay,
        contentKind: 'screenplay',
        sessionId: 'test',
        workId: 'work',
        operationHost: ToolOperationHost(
          operations,
          production: () async => ProductionToolHost(
            canvas: service,
            images: _UnusedImages(),
            audio: _UnusedAudio(),
            video: () => throw StateError('No video call expected'),
            results: results,
          ),
        ),
      )..registerAllTools();
    });

    Future<Map<String, dynamic>> create(Map<String, dynamic> fields) =>
        tools.executeTool(
          name: 'Create',
          input: {'path': 'clips', 'fields': fields},
        );

    Future<Map<String, Object>> snapshot() async => {
      for (final table in [
        'production_clips',
        'canvas_nodes',
        'canvas_edges',
        'canvases',
        'screenplay_episodes',
        'working_changes',
        'change_commit_items',
      ])
        table:
            (await db.customSelect('SELECT * FROM $table ORDER BY rowid').get())
                .map((row) => row.data)
                .toList(),
    };

    test(
      'creates referenced clips and allows prompt reference changes',
      () async {
        await asset('create-image');
        final canvas = await service.ensureCanvas(episode);
        final source = await service.addMedia(canvas.id, 'create-image');
        final bindings = [
          {
            'id': 'node-ref',
            'ref_type': 'node',
            'ref_id': source.id,
            'role': 'reference_image',
          },
          {
            'id': 'asset-ref',
            'ref_type': 'asset',
            'ref_id': 'create-image',
            'role': 'reference_image',
          },
        ];
        const prompt =
            'Use <ref input_id="node-ref" label="Scene" /> and '
            '<ref input_id="asset-ref" label="Person" />.';
        final schema = await tools.executeTool(
          name: 'Read',
          input: {'path': '/_schema/clips'},
        );
        expect((schema['fields'] as Map)['inputs']['create'], isTrue);
        for (final kind in ['video', 'image', 'audio']) {
          final created = await create({
            'kind': kind,
            if (kind == 'video') 'scene_id': scene else 'episode_id': episode,
            'prompt': prompt,
            'inputs': bindings,
          });
          expect(created['created'], isTrue, reason: '$created');
          expect(created['ignored_fields'], isNull);
          expect(created['prompt'], prompt);
          expect(created['inputs'], bindings);
          final id = created['id'] as String;
          final creation = (await overlay.getWorkingChanges())
              .where((change) => change.resourceId == id)
              .single;
          expect(creation.changeType, 'create');
          expect((jsonDecode(creation.newText!) as Map)['prompt'], prompt);
          final detail = await tools.executeTool(
            name: 'Read',
            input: {'path': 'clips/$id'},
          );
          expect(detail['prompt'], prompt);
          expect(detail['inputs'], bindings);
          final node = await service.shots.ensureClipNode(id);
          final graph = await service.content(canvas.id);
          expect(
            graph.edges
                .where((edge) => edge.targetNodeId == node.id)
                .single
                .sourceNodeId,
            source.id,
          );
          final changed = await tools.executeTool(
            name: 'Write',
            input: {
              'path': 'clips/$id',
              'fields': {'prompt': '$prompt Rain.'},
            },
          );
          expect(changed['updated'], isTrue, reason: '$changed');
          for (final next in [
            '<ref input_id="node-ref" label="Renamed" />',
            '<ref input_id="asset-ref" label="Replacement" />',
            '$prompt $prompt',
            'Removed all references',
          ]) {
            final changed = await tools.executeTool(
              name: 'Write',
              input: {'path': 'clips/$id/prompt', 'value': next},
            );
            expect(changed['updated'], isTrue, reason: '$changed');
            expect((await service.shots.getShot(id))!.prompt, next);
          }
          for (final invalid in [
            '<ref input_id="missing" label="Unknown" />',
            '<ref input_id="asset-ref" />',
          ]) {
            final before = await snapshot();
            final rejected = await tools.executeTool(
              name: 'Write',
              input: {
                'path': 'clips/$id',
                'fields': {'title': 'Must not apply', 'prompt': invalid},
              },
            );
            expect(rejected['error_code'], 'invalid_argument');
            expect(await snapshot(), before);
          }
          final edited = await tools.executeTool(
            name: 'Edit',
            input: {
              'path': 'clips/$id/prompt',
              'old_text': 'Removed all references',
              'new_text': prompt,
            },
          );
          expect(edited['edited'], isTrue, reason: '$edited');
          expect(await service.shots.inputSnapshot(id), bindings);
          final changes = (await overlay.getWorkingChanges())
              .where((change) => change.resourceId == id)
              .toList();
          for (final change in changes.reversed) {
            await overlay.rejectWorkingChange(change.id);
          }
          expect(await service.shots.getShot(id), isNull);
          expect(await db.canvasDao.getNodeById(node.id), isNull);
          expect(await db.canvasDao.getNodeById(source.id), isNotNull);
        }
      },
    );

    test(
      'prompt edits reject missing assets in existing inputs atomically',
      () async {
        await asset('stale-image');
        const prompt = '<ref input_id="ref" label="Image" />';
        final created = await create({
          'episode_id': episode,
          'prompt': prompt,
          'inputs': [
            {
              'id': 'ref',
              'ref_type': 'asset',
              'ref_id': 'stale-image',
              'role': 'reference_image',
            },
          ],
        });
        expect(created['created'], isTrue, reason: '$created');
        final id = created['id'] as String;
        await appDb.assetDao.softDeleteAsset('stale-image');
        final before = await snapshot();
        final rejected = await tools.executeTool(
          name: 'Write',
          input: {
            'path': 'clips/$id',
            'fields': {'title': 'Must not apply', 'prompt': '$prompt Again.'},
          },
        );
        expect(rejected['error_code'], 'invalid_argument', reason: '$rejected');
        expect(await snapshot(), before);
      },
    );

    test(
      'invalid references leave no clips, nodes, canvases or history',
      () async {
        await asset('create-image');
        await asset('other-image');
        final otherCanvas = await service.ensureCanvas(episode);
        final foreignNode = await service.addMedia(
          otherCanvas.id,
          'create-image',
        );
        const input = {
          'id': 'ref',
          'ref_type': 'asset',
          'ref_id': 'create-image',
          'role': 'reference_image',
        };
        const prompt = '<ref input_id="ref" label="Image" />';
        // A fresh episode also verifies rollback of the lazily created canvas link.
        final screenplay = ScreenplayService(db);
        final episodeRow = (await db.screenplayDao.getEpisode(episode))!;
        final freshEpisode = await screenplay.createEpisode(
          seasonId: episodeRow.seasonId,
          title: 'Create rollback',
        );
        final before = await snapshot();
        for (final fields in [
          {'prompt': prompt},
          {'prompt': prompt, 'inputs': <Object>[]},
          {
            'prompt': prompt,
            'inputs': [
              input,
              {...input, 'ref_id': 'other-image'},
            ],
          },
          {
            'prompt': prompt,
            'inputs': [
              input,
              {...input, 'id': 'other-ref'},
            ],
          },
          {
            'prompt': prompt,
            'inputs': [
              {...input, 'ref_id': 'missing'},
            ],
          },
          {
            'prompt': prompt,
            'inputs': [
              {...input, 'ref_type': 'node', 'ref_id': foreignNode.id},
            ],
          },
          {
            'prompt': prompt,
            'inputs': [
              {...input, 'role': 'reference_video'},
            ],
          },
          {
            'prompt': '<ref input_id="missing" label="Image" />',
            'inputs': [input],
          },
        ]) {
          final result = await create({'episode_id': freshEpisode, ...fields});
          expect(
            result['error_code'],
            'invalid_argument',
            reason: '$fields => $result',
          );
          expect(await snapshot(), before, reason: '$fields');
        }
      },
    );

    test(
      'empty inputs create plain text clips without the media host',
      () async {
        final withoutHost = AiToolManager(
          NovelContentService(db),
          workingOverlayService: overlay,
          contentKind: 'screenplay',
          sessionId: 'test',
          workId: 'work',
        )..registerAllTools();
        final result = await withoutHost.executeTool(
          name: 'Create',
          input: {
            'path': 'clips',
            'fields': {
              'episode_id': episode,
              'prompt': 'Plain',
              'inputs': <Object>[],
            },
          },
        );
        expect(result['created'], isTrue, reason: '$result');
        expect(result['prompt'], 'Plain');
        final id = result['id'] as String;
        expect(await service.shots.inputSnapshot(id), isEmpty);
        expect(
          (await overlay.getWorkingChanges())
              .where((change) => change.resourceId == id)
              .single
              .changeType,
          'create',
        );
      },
    );

    test('references without the media host fail before writing', () async {
      await asset('create-image');
      final withoutHost = AiToolManager(
        NovelContentService(db),
        workingOverlayService: overlay,
        contentKind: 'screenplay',
        sessionId: 'test',
        workId: 'work',
      )..registerAllTools();
      final before = await snapshot();
      final failed = await withoutHost.executeTool(
        name: 'Create',
        input: {
          'path': 'clips',
          'fields': {
            'episode_id': episode,
            'prompt': '<ref input_id="ref" label="Image" />',
            'inputs': [
              {
                'id': 'ref',
                'ref_type': 'asset',
                'ref_id': 'create-image',
                'role': 'reference_image',
              },
            ],
          },
        },
      );
      expect(failed['error_code'], 'unavailable');
      expect(await snapshot(), before);
    });
  });

  test(
    'Agent prompt and input history roll back together and invalid inputs leave neither changed',
    () async {
      await asset('image');
      final node = await service.ensureShotNode(shot.id);
      final source = await service.addMedia(node.canvasId, 'image');
      final before = (await service.shots.getShot(shot.id))!;
      final prompt = StoryboardPrompt.reference(source.id, 'Image');
      Future<void> save(List<ProductionInput> inputs) => service.saveDraft(
        nodeId: node.id,
        values: {...service.shots.snapshot(before), 'prompt': prompt},
        inputs: inputs,
        overlay: overlay,
        origin: const ShotEditOrigin.agent(
          sessionId: 'test',
          turnId: 'turn',
          tool: 'Write',
        ),
      );
      await expectLater(save([]), throwsFormatException);
      expect((await service.shots.getShot(shot.id))!.prompt, before.prompt);
      expect(await service.inputs(node.id), isEmpty);
      await save([
        ProductionInput(
          id: source.id,
          refType: ProductionInputType.node,
          refId: source.id,
          role: VideoInputRole.reference_image,
        ),
      ]);
      expect(await service.inputs(node.id), hasLength(1));
      final changes = (await overlay.getWorkingChanges())
          .where(
            (c) =>
                c.status == workingChangeStatusActive &&
                c.sourceTurnId == 'turn',
          )
          .toList();
      expect(changes.map((c) => c.field).toSet(), {'inputs', 'document'});
      for (final change in changes.reversed) {
        await overlay.rejectWorkingChange(change.id);
      }
      expect((await service.shots.getShot(shot.id))!.prompt, before.prompt);
      expect(await service.inputs(node.id), isEmpty);
      expect(await service.requireAsset('image'), isNotNull);
    },
  );

  test(
    'manual input replacement takes over Agent history and commits its own relation change',
    () async {
      await asset('input-manual');
      final node = await service.ensureShotNode(shot.id);
      final source = await service.addMedia(node.canvasId, 'input-manual');
      final input = ProductionInput(
        id: source.id,
        refType: ProductionInputType.node,
        refId: source.id,
        role: VideoInputRole.reference_image,
      );
      final initial = service.shots.snapshot(
        (await service.shots.getShot(shot.id))!,
      );
      await service.saveDraft(
        nodeId: node.id,
        values: {
          ...initial,
          'prompt': StoryboardPrompt.reference(input.id, 'Ref'),
        },
        inputs: [input],
        overlay: overlay,
        origin: const ShotEditOrigin.agent(sessionId: 'test', tool: 'Write'),
      );
      await service.saveDraft(
        nodeId: node.id,
        values: {...initial, 'prompt': 'Manual'},
        inputs: [],
        overlay: overlay,
      );
      expect(await service.inputs(node.id), isEmpty);
      expect((await service.shots.getShot(shot.id))!.prompt, 'Manual');
      expect(
        (await overlay.getWorkingChanges()).where(
          (c) => c.status == workingChangeStatusActive,
        ),
        isEmpty,
      );
      expect(
        (await overlay.getWorkingChanges()).where(
          (c) => c.field == 'inputs' && c.source == workingChangeSourceManual,
        ),
        isNotEmpty,
      );
    },
  );

  test(
    'inline references save atomically without creating nodes or edges',
    () async {
      await asset('image');
      final node = await service.ensureShotNode(shot.id);
      final prompt =
          '参考 ${StoryboardPrompt.reference('file_workspaces/work/image.png', '同名')}';
      Future<void> save() => service.save(
        nodeId: node.id,
        request: request(prompt),
        providerId: 'p',
        inputs: [
          ProductionInput(
            id: 'file_workspaces/work/image.png',
            refType: ProductionInputType.asset,
            refId: 'image',
            role: VideoInputRole.reference_image,
          ),
        ],
        overlay: overlay,
      );
      await Future.wait([save(), save()]);
      final inputs = await service.inputs(node.id);
      expect(inputs, hasLength(1));
      expect(inputs.single.refId, 'image');
      expect(inputs.single.sourceNodeId, isNull);
      expect((await service.shots.getShot(shot.id))!.prompt, prompt);
      expect(
        (await db.canvasDao.getNodesByCanvas(
          node.canvasId,
        )).where((n) => n.sceneId == null),
        hasLength(1),
      );
      await expectLater(
        service.save(
          nodeId: node.id,
          request: request('changed'),
          providerId: 'p',
          inputs: [
            ProductionInput(
              id: 'file_workspaces/work/image.png',
              refType: ProductionInputType.asset,
              refId: 'image',
              role: VideoInputRole.reference_image,
            ),
            ProductionInput(
              id: 'file_workspaces/work/missing.png',
              refType: ProductionInputType.asset,
              refId: 'missing',
              role: VideoInputRole.reference_image,
            ),
          ],
          overlay: overlay,
        ),
        throwsA(anything),
      );
      expect((await service.shots.getShot(shot.id))!.prompt, prompt);
      expect((await service.inputs(node.id)).single.id, inputs.single.id);
      // Disconnecting does not erase the prompt, source node, or media file.
      await service.save(
        nodeId: node.id,
        request: request(prompt),
        providerId: 'p',
        inputs: [],
        overlay: overlay,
      );
      expect(await service.inputs(node.id), isEmpty);
      expect(await service.requireAsset('image'), isNotNull);
      expect(await service.requireAsset('image'), isNotNull);
      expect(
        () => compileForTest(
          videoProviderType(VideoProtocol.wan_video),
          request(prompt),
          [],
        ),
        throwsA(anything),
      );
    },
  );
  test(
    'canvas images list image media and adopted image results once',
    () async {
      await asset('photo');
      await asset('generated');
      await asset('clip', type: 'video');
      final node = await service.ensureShotNode(shot.id);
      await service.addMedia(node.canvasId, 'photo');
      await service.addMedia(node.canvasId, 'photo');
      await service.addMedia(node.canvasId, 'clip');
      await service.addImage(node.canvasId);
      final adopted = await service.addImage(node.canvasId);
      await service.adopt(adopted.id, 'generated');
      expect(
        (await service.canvasImages(node.canvasId)).map((a) => a.id),
        unorderedEquals(['photo', 'generated']),
      );
    },
  );
  test('inline asset picker does not attach existing canvas nodes', () async {
    await asset('image');
    final node = await service.ensureShotNode(shot.id);
    final far = await service.addMedia(node.canvasId, 'image');
    final near = await service.addMedia(node.canvasId, 'image');
    await service.move(far.id, 3000, 3000);
    await service.move(near.id, node.x - 400, node.y);
    await service.save(
      nodeId: node.id,
      request: request('p'),
      providerId: 'p',
      inputs: [
        ProductionInput(
          id: 'file_workspaces/work/image.png',
          refType: ProductionInputType.asset,
          refId: 'image',
          role: VideoInputRole.reference_image,
        ),
      ],
      overlay: overlay,
    );
    expect((await service.inputs(node.id)).single.sourceNodeId, isNull);
    expect((await db.canvasDao.getNodeById(near.id))!.x, node.x - 400);
  });
  test(
    'latest result applies once; manual history selection and newer result survive late callbacks',
    () async {
      await asset('v1', type: 'video');
      await asset('v2', type: 'video');
      final node = await service.ensureShotNode(shot.id);
      final first = await task('z-first', 'v1');
      await results.apply(first, service);
      expect((await service.shots.getShot(shot.id))!.adoptedAssetId, 'v1');
      final second = await task('a-second', 'v2');
      await results.apply(second, service);
      expect((await service.shots.getShot(shot.id))!.adoptedAssetId, 'v2');
      await service.adopt(node.id, 'v1');
      await results.recover();
      await results.apply(first, service);
      final current = (await service.shots.getShot(shot.id))!;
      expect(current.adoptedAssetId, 'v1');
      expect(current.lastAppliedGenerationTaskId, 'a-second');
      await service.shots.softDelete(shot.id);
      await results.apply(second, service);
      expect(await service.shots.getShot(shot.id), isNull);
    },
  );
  test(
    'missing result file blocks a new generation until application succeeds',
    () async {
      final pending = await task('pending', 'missing');
      await expectLater(
        results.beforeCreate('work', 'production_clip', shot.id),
        throwsA(anything),
      );
      await asset('missing', type: 'video');
      await results.recover();
      expect(
        (await service.shots.getShot(shot.id))!.lastAppliedGenerationTaskId,
        pending.id,
      );
    },
  );

  test(
    'video compilation applies channel defaults while preserving explicit false',
    () {
      for (final chosen in [null, false]) {
        final compiled = compileForTest(
          videoProviderType(VideoProtocol.wan_video),
          VideoRequest(
            modelId: 'wan3.0-video',
            prompt: 'A scene',
            mode: VideoMode.text,
            resolution: '720p',
            ratio: '16:9',
            audio: chosen,
            promptExtend: chosen,
          ),
          [],
        );
        expect(compiled.audio, chosen ?? true);
        expect(compiled.promptExtend, chosen ?? true);
        final restored = VideoRequest.fromJson(compiled.toJson());
        expect(restored.audio, compiled.audio);
        expect(restored.promptExtend, compiled.promptExtend);
      }
    },
  );

  test(
    'compilation preserves placement, repeated IDs and per-kind media slots',
    () {
      final prompt =
          '${StoryboardPrompt.reference('file_workspaces/work/b.png', 'same')} moves past ${StoryboardPrompt.reference('file_workspaces/work/a.png', 'same')}. ${StoryboardPrompt.reference('file_workspaces/work/b.png', 'same')}';
      final compiled = compileForTest(
        videoProviderType(VideoProtocol.wan_video),
        request(prompt),
        [
          ProductionInput(
            id: 'file_workspaces/work/a.png',
            refType: ProductionInputType.asset,
            refId: 'a',
            role: VideoInputRole.reference_image,
          ),
          ProductionInput(
            id: 'file_workspaces/work/video.mp4',
            refType: ProductionInputType.asset,
            refId: 'video',
            role: VideoInputRole.reference_video,
          ),
          ProductionInput(
            id: 'file_workspaces/work/b.png',
            refType: ProductionInputType.asset,
            refId: 'b',
            role: VideoInputRole.reference_image,
          ),
        ],
      );
      expect(compiled.prompt, '图片2 moves past 图片1. 图片2');
      expect(compiled.originalPrompt, prompt);
      final atlas = compileForTest(
        videoProviderType(VideoProtocol.atlascloud_video),
        VideoRequest(
          modelId: 'bytedance/seedance-2.5',
          prompt: prompt,
          mode: VideoMode.reference,
          resolution: '720p',
          ratio: '16:9',
        ),
        [
          ProductionInput(
            id: 'file_workspaces/work/a.png',
            refType: ProductionInputType.asset,
            refId: 'a',
            role: VideoInputRole.reference_image,
          ),
          ProductionInput(
            id: 'file_workspaces/work/video.mp4',
            refType: ProductionInputType.asset,
            refId: 'video',
            role: VideoInputRole.reference_video,
          ),
          ProductionInput(
            id: 'file_workspaces/work/b.png',
            refType: ProductionInputType.asset,
            refId: 'b',
            role: VideoInputRole.reference_image,
          ),
          ProductionInput(
            id: 'file_workspaces/work/audio.mp3',
            refType: ProductionInputType.asset,
            refId: 'audio',
            role: VideoInputRole.reference_audio,
          ),
        ],
      );
      expect(atlas.prompt, '@Image2 moves past @Image1. @Image2');
      expect(atlas.referenceSlots.map((slot) => slot.slot), [
        '@Image1',
        '@Video1',
        '@Image2',
        '@Audio1',
      ]);
      expect(atlas.audio, true);
      final agnes = compileForTest(
        videoProviderType(VideoProtocol.agnes_video),
        const VideoRequest(
          modelId: 'agnes-video-2.5',
          prompt: 'use references',
          mode: VideoMode.reference,
          resolution: '720P',
          ratio: '16:9',
        ),
        [
          ProductionInput(
            id: 'file_workspaces/work/a.png',
            refType: ProductionInputType.asset,
            refId: 'a',
            role: VideoInputRole.reference_image,
          ),
          ProductionInput(
            id: 'file_workspaces/work/v.mp4',
            refType: ProductionInputType.asset,
            refId: 'v',
            role: VideoInputRole.reference_video,
          ),
          ProductionInput(
            id: 'file_workspaces/work/b.png',
            refType: ProductionInputType.asset,
            refId: 'b',
            role: VideoInputRole.reference_image,
          ),
          ProductionInput(
            id: 'file_workspaces/work/a.wav',
            refType: ProductionInputType.asset,
            refId: 'a',
            role: VideoInputRole.reference_audio,
          ),
        ],
      );
      expect(agnes.referenceSlots.map((s) => s.slot), [
        '<Picture 1>',
        '<Video 1>',
        '<Picture 2>',
        '<Audio 1>',
      ]);
      expect(agnes.audio, isNull);
      expect(agnes.promptExtend, isNull);
      expect(
        VideoRequest.fromJson(
          compiled.toJson(),
        ).referenceSlots.map((s) => s.slot),
        ['图片1', '视频1', '图片2'],
      );
      expect(
        compileForTest(
          videoProviderType(VideoProtocol.minimax_video_v2),
          request(prompt),
          [
            ProductionInput(
              id: 'file_workspaces/work/b.png',
              refType: ProductionInputType.asset,
              refId: 'b',
              role: VideoInputRole.reference_image,
            ),
            ProductionInput(
              id: 'file_workspaces/work/a.png',
              refType: ProductionInputType.asset,
              refId: 'a',
              role: VideoInputRole.reference_image,
            ),
          ],
        ).prompt,
        'reference image 1 moves past reference image 2. reference image 1',
      );
    },
  );
  test(
    'video source follows adopted result, freezes clip mapping, and rejects cycles',
    () async {
      final target = await service.ensureShotNode(shot.id);
      final source = await service.addFree(target.canvasId, overlay: overlay);
      final input = ProductionInput(
        id: source.clipId!,
        refType: ProductionInputType.node,
        refId: source.id,
        role: VideoInputRole.reference_video,
      );
      final prompt = StoryboardPrompt.reference(source.clipId!, 'Experiment');
      // Saving a connection before its first result is allowed.
      await service.save(
        nodeId: target.id,
        request: request(prompt),
        providerId: 'p',
        inputs: [input],
        overlay: overlay,
      );
      expect(
        (await service.inputs(target.id)).single.refType,
        ProductionInputType.node,
      );
      await expectLater(
        service.resolveInput(input),
        throwsA(isA<StoryboardException>()),
      );
      await asset('first', type: 'video');
      await asset('second', type: 'video');
      await service.adopt(source.id, 'first');
      final frozen = compileProductionPrompt(
        videoProviderType(VideoProtocol.wan_video),
        request(prompt),
        [ResolvedProductionInput(input, 'first')],
      );
      await service.adopt(source.id, 'second');
      expect(
        (await service.resolveInput(input)).path,
        'file_workspaces/work/second.mp4',
      );
      expect(frozen.referenceSlots.single.assetId, 'first');
      expect(
        VideoRequest.fromJson(frozen.toJson()).referenceSlots.single.inputId,
        input.id,
      );
      expect(frozen.prompt, '视频1');
      await expectLater(
        service.save(
          nodeId: source.id,
          request: request('cycle'),
          providerId: 'p',
          inputs: [
            ProductionInput(
              id: target.clipId!,
              refType: ProductionInputType.node,
              refId: target.id,
              role: VideoInputRole.reference_video,
            ),
          ],
          overlay: overlay,
        ),
        throwsA(isA<StoryboardException>()),
      );
      expect(await service.inputs(source.id), isEmpty);
      await expectLater(
        service.save(
          nodeId: source.id,
          request: request('self'),
          providerId: 'p',
          inputs: [
            ProductionInput(
              id: source.clipId!,
              refType: ProductionInputType.node,
              refId: source.id,
              role: VideoInputRole.reference_video,
            ),
          ],
          overlay: overlay,
        ),
        throwsA(isA<StoryboardException>()),
      );
    },
  );

  test(
    'clip and fixed references with the same adopted asset remain distinct',
    () {
      final prompt =
          '${StoryboardPrompt.reference('file_workspaces/work/asset.mp4', 'Fixed')} ${StoryboardPrompt.reference('clip', 'Following')}';
      final compiled = compileForTest(
        videoProviderType(VideoProtocol.wan_video),
        request(prompt),
        [
          ProductionInput(
            id: 'file_workspaces/work/asset.mp4',
            refType: ProductionInputType.asset,
            refId: 'asset',
            role: VideoInputRole.reference_video,
          ),
          ProductionInput(
            id: 'clip',
            refType: ProductionInputType.node,
            refId: 'node',
            role: VideoInputRole.reference_video,
          ),
        ],
      );
      expect(compiled.prompt, '视频1 视频2');
      expect(compiled.referenceSlots.map((s) => s.inputId), [
        'file_workspaces/work/asset.mp4',
        'clip',
      ]);
    },
  );

  test(
    'choosing a generated asset from library remains fixed after its source adopts another result',
    () async {
      await asset('v1', type: 'video');
      await asset('v2', type: 'video');
      final target = await service.ensureShotNode(shot.id);
      final source = await service.addFree(target.canvasId, overlay: overlay);
      await service.adopt(source.id, 'v1');
      await service.save(
        nodeId: target.id,
        request: request('fixed'),
        providerId: 'p',
        inputs: [
          ProductionInput(
            id: 'file_workspaces/work/v1.mp4',
            refType: ProductionInputType.asset,
            refId: 'v1',
            role: VideoInputRole.reference_video,
          ),
        ],
        overlay: overlay,
      );
      final edge = (await service.inputs(target.id)).single;
      expect(edge.sourceNodeId, isNot(source.id));
      await service.adopt(source.id, 'v2');
      expect(
        (await service.inputs(target.id)).single.refType,
        ProductionInputType.asset,
      );
      expect(
        (await service.resolveInput(
          (await service.draftInputs(target.id)).single,
        )).path,
        'file_workspaces/work/v1.mp4',
      );
    },
  );
  test('video nodes share clip persistence and cannot change kind', () async {
    await service.shots.saveSettings({'ratio': '16:9'});
    final canvas = await service.ensureCanvas(episode);
    final node = await service.addFree(canvas.id, overlay: overlay);
    final clip = (await service.shots.getShot(node.clipId!))!;
    expect(clip.kind, 'video');
    expect(clip.sceneId, isNull);
    expect(clip.errorDismissed, isFalse);
    expect(clip.ratio, '16:9');
    await service.save(
      nodeId: node.id,
      request: request('node prompt'),
      providerId: 'p',
      inputs: [],
      overlay: overlay,
    );
    expect((await service.shots.getShot(clip.id))!.prompt, 'node prompt');
    expect(
      (await service.shots.getShot(shot.id))!.prompt,
      isNot('node prompt'),
    );
    await expectLater(
      service.shots.apply(clip.id, {
        ...service.shots.snapshot(clip),
        'kind': 'image',
        'scene_id': shot.sceneId,
        'sort_order': 0,
      }),
      throwsA(isA<StoryboardException>()),
    );
    expect((await service.shots.getShot(clip.id))!.kind, 'video');
    final copy = await service.copyVideo(node.id, overlay: overlay);
    final copyRow = (await service.shots.getShot(copy.clipId!))!;
    expect(copyRow.id, isNot(clip.id));
    expect(copyRow.kind, 'video');
    expect(copyRow.prompt, 'node prompt');
    expect(copyRow.adoptedAssetId, isNull);
  });
  test(
    'deleted scene preserves clip editing, node and result application',
    () async {
      final node = await service.ensureShotNode(shot.id);
      await ScreenplayService(db).deleteScene(scene);
      expect((await service.shots.episodeShots(episode)).single.id, shot.id);
      await StoryboardEditOrchestrator().save(
        service: service.shots,
        overlay: overlay,
        shotId: shot.id,
        values: {'title': 'Detached'},
      );
      await asset('kept', type: 'video');
      await results.apply(await task('detached-task', 'kept'), service);
      expect((await service.requireNode(node.id)).clipId, shot.id);
      expect((await service.shots.getShot(shot.id))!.adoptedAssetId, 'kept');
    },
  );

  test('new segment has exactly one node before opening production', () async {
    final nodes =
        await (db.select(db.canvasNodes)..where(
              (n) =>
                  n.refType.equals(canvasNodeRefTypeProductionClip) &
                  n.refId.equals(shot.id),
            ))
            .get();
    expect(nodes, hasLength(1));
    final again = await service.ensureShotNode(shot.id);
    expect(again.id, nodes.single.id);
  });

  test(
    'a draft shot can save prompt before selecting a model or duration',
    () async {
      final node = await service.ensureShotNode(shot.id);
      await service.save(
        nodeId: node.id,
        request: const VideoRequest(
          modelId: '',
          prompt: 'draft',
          mode: VideoMode.reference,
          resolution: '720p',
          ratio: '9:16',
          durationSeconds: 0,
        ),
        providerId: null,
        inputs: [],
        overlay: overlay,
      );
      final saved = (await service.shots.getShot(shot.id))!;
      expect(saved.prompt, 'draft');
      expect(saved.durationMs, isNull);
      expect(saved.providerId, isNull);
    },
  );

  test(
    'frame references follow image order and preserve the editable prompt',
    () {
      final image = ProductionInput.asset(
        'image',
        VideoInputRole.reference_image,
      );
      final video = ProductionInput.asset(
        'video',
        VideoInputRole.reference_video,
      );
      final first = ProductionInput.asset('first', VideoInputRole.first_frame);
      final last = ProductionInput.asset('last', VideoInputRole.last_frame);
      final raw = request(
        'Move from ${StoryboardPrompt.reference(first.id, 'Start')}',
      );
      final provider = videoProviderType(VideoProtocol.atlascloud_video);
      final compiled = compileForTest(provider, raw, [
        image,
        video,
        first,
        last,
      ]);
      expect(
        compiled.prompt,
        'Move from @Image2\n'
        '以 @Image2 作为视频起始画面，延续其构图、人物姿态和场景状态。\n'
        '视频结束画面应呈现 @Image3 所示的构图、人物姿态和场景状态。',
      );
      expect(compiled.originalPrompt, raw.prompt);
      expect(first.role, VideoInputRole.first_frame);
      expect(compiled.referenceSlots.map((s) => s.role), [
        VideoInputRole.reference_image,
        VideoInputRole.reference_video,
        VideoInputRole.reference_image,
        VideoInputRole.reference_image,
      ]);
      expect(
        compileForTest(provider, raw, [image, video, first, last]).prompt,
        compiled.prompt,
      );
      final reordered = compileForTest(provider, raw, [
        last,
        video,
        first,
        image,
      ]);
      expect(reordered.prompt, contains('视频结束画面应呈现 @Image1'));
      expect(reordered.prompt, contains('以 @Image2 作为视频起始画面'));
      final removed = compileForTest(provider, raw, [video, first]);
      expect(removed.prompt, startsWith('Move from @Image1\n以 @Image1'));
      expect(removed.prompt, isNot(contains('视频结束画面')));
      final changed = compileForTest(provider, raw, [
        first.withRole(VideoInputRole.last_frame),
      ]);
      expect(changed.prompt, contains('视频结束画面应呈现 @Image1'));
      expect(changed.prompt, isNot(contains('作为视频起始画面')));
      expect(
        () => compileForTest(provider, raw, [last]),
        throwsA(isA<StoryboardException>()),
      );

      for (final mode in [VideoMode.first_frame, VideoMode.first_last_frame]) {
        final frames = compileForTest(
          provider,
          VideoRequest(
            modelId: raw.modelId,
            prompt: raw.prompt,
            mode: mode,
            resolution: raw.resolution,
            ratio: raw.ratio,
          ),
          [first, if (mode == VideoMode.first_last_frame) last],
        );
        expect(frames.prompt, 'Move from first frame');
        expect(frames.referenceSlots.first.role, VideoInputRole.first_frame);
      }
      expect(
        compileForTest(provider, raw, [image, video, first, last]).prompt,
        compiled.prompt,
      );
      final ark = compileForTest('doubao', raw, [image, first]);
      expect(ark.prompt, contains('以 图片2 作为视频起始画面'));
      final agnes = compileForTest(
        videoProviderType(VideoProtocol.agnes_video),
        raw,
        [first],
      );
      expect(agnes.prompt, contains('以 <Picture 1> 作为视频起始画面'));
    },
  );

  test(
    'preview sends frame references and restores dedicated frame parameters',
    () async {
      service = ProductionCanvasService(
        service.shots,
        MediaLibraryService(appDb, _ImageMedia(size: 512), root),
        'work',
      );
      await appDb
          .into(appDb.aiProviders)
          .insert(
            app.AiProvidersCompanion.insert(
              id: 'video',
              name: 'Video',
              type: 'atlascloud',
              enabled: const Value(true),
              apiKey: const Value('test'),
              videoModels: const Value(['bytedance/seedance-2.5']),
            ),
          );
      for (final id in ['image', 'first', 'last']) {
        await asset(id);
      }
      final node = await service.ensureShotNode(shot.id);
      final inputs = [
        ProductionInput.asset('image', VideoInputRole.reference_image),
        ProductionInput.asset('first', VideoInputRole.first_frame),
        ProductionInput.asset('last', VideoInputRole.last_frame),
      ];
      Future<void> save(VideoMode mode) => service.save(
        nodeId: node.id,
        providerId: 'video',
        overlay: overlay,
        inputs: inputs,
        request: VideoRequest(
          modelId: 'bytedance/seedance-2.5',
          prompt: 'Move',
          mode: mode,
          resolution: '720p',
          ratio: '16:9',
        ),
      );
      final operation = ProductionGenerateOrchestrator();
      await save(VideoMode.reference);
      final reference = await operation.preview(service, node.id);
      expect(reference.inputs.map((i) => i.assetId), [
        'image',
        'first',
        'last',
      ]);
      expect(
        reference.inputs.map((i) => i.role),
        everyElement(VideoInputRole.reference_image),
      );
      expect(reference.request.prompt, contains('以 @Image2 作为视频起始画面'));
      expect((await service.shots.getShot(shot.id))!.prompt, 'Move');
      expect(
        (await service.inputs(node.id)).map((i) => i.role),
        inputs.map((i) => i.role),
      );
      await save(VideoMode.first_last_frame);
      final frames = await operation.preview(service, node.id);
      expect(frames.inputs.map((i) => i.assetId), ['first', 'last']);
      expect(frames.inputs.map((i) => i.role), [
        VideoInputRole.first_frame,
        VideoInputRole.last_frame,
      ]);
      expect(frames.request.prompt, 'Move');
      await save(VideoMode.reference);
      expect(
        (await operation.preview(service, node.id)).request.prompt,
        reference.request.prompt,
      );

      final limit = lookupVideoChannelModel(
        'atlascloud',
        reference.request.modelId,
      )!.capabilities.references[VideoMediaKind.image]!.maxCount;
      final roles = List.filled(
        limit + 1,
        VideoInputRole.first_frame,
      ).map((role) => productionSubmitRole(VideoMode.reference, role)).toList();
      expect(
        () => VideoCapabilities(
          'atlascloud',
        ).validateParameters(reference.request, roles),
        throwsA(
          isA<VideoException>().having((e) => e.field, 'field', 'image_count'),
        ),
      );
    },
  );

  test(
    'Kling middle frames retain identities and order across save, reorder and preview',
    () async {
      service = ProductionCanvasService(
        service.shots,
        MediaLibraryService(appDb, _ImageMedia(size: 720), root),
        'work',
      );
      await appDb
          .into(appDb.aiProviders)
          .insert(
            app.AiProvidersCompanion.insert(
              id: 'kling',
              name: 'Kling',
              type: 'atlascloud',
              enabled: const Value(true),
              apiKey: const Value('test'),
              videoModels: const Value([
                'kwaivgi/kling-v4.0',
                'bytedance/seedance-2.5',
              ]),
            ),
          );
      for (final id in ['first', 'a', 'b', 'last']) {
        await asset(id);
      }
      final target = await service.ensureShotNode(shot.id);
      final aNode = await service.addMedia(target.canvasId, 'a');
      final bNode = await service.addMedia(target.canvasId, 'b');
      final first = ProductionInput.asset('first', VideoInputRole.first_frame);
      final a = ProductionInput.node(aNode.id, VideoInputRole.middle_frame);
      final b = ProductionInput.node(bNode.id, VideoInputRole.middle_frame);
      final last = ProductionInput.asset('last', VideoInputRole.last_frame);
      final prompt = [
        first,
        a,
        b,
        last,
      ].map((i) => StoryboardPrompt.reference(i.id, i.refId)).join(' ');
      Future<void> save(
        List<ProductionInput> inputs, {
        String model = 'kwaivgi/kling-v4.0',
        VideoMode mode = VideoMode.first_last_frame,
      }) => service.save(
        nodeId: target.id,
        providerId: 'kling',
        overlay: overlay,
        inputs: inputs,
        request: VideoRequest(
          modelId: model,
          prompt: prompt,
          mode: mode,
          resolution: '720p',
          ratio: mode == VideoMode.reference ? '16:9' : 'adaptive',
        ),
      );
      await save([last, b, first, a]);
      expect((await service.inputs(target.id)).map((i) => i.id), [
        last.id,
        b.id,
        first.id,
        a.id,
      ]);
      final operation = ProductionGenerateOrchestrator();
      final preview = await operation.preview(service, target.id);
      expect(preview.request.prompt, '@image_1 @image_3 @image_2 @image_4');
      expect(
        preview.inputs
            .where((i) => i.role == VideoInputRole.middle_frame)
            .map((i) => i.assetId),
        ['b', 'a'],
      );
      final restored = VideoRequest.fromJson(preview.request.toJson());
      expect(
        restored.referenceSlots.singleWhere((s) => s.inputId == a.id).slot,
        '@image_3',
      );
      final edges = (await service.content(target.canvasId)).edges;
      expect(edges.singleWhere((e) => e.inputId == a.id).middleFrameIndex, 2);
      expect(edges.singleWhere((e) => e.inputId == b.id).middleFrameIndex, 1);
      await save([first, a, b, last]);
      expect(
        (await operation.preview(service, target.id)).request.prompt,
        '@image_1 @image_2 @image_3 @image_4',
      );
      expect((await service.shots.getShot(shot.id))!.prompt, prompt);
      await save([first, a, b, last], model: 'bytedance/seedance-2.5');
      await expectLater(
        operation.preview(service, target.id),
        throwsA(isA<VideoException>()),
      );
      expect(
        (await service.inputs(
          target.id,
        )).where((i) => i.role == VideoInputRole.middle_frame),
        hasLength(2),
      );
      for (final model in ['kwaivgi/kling-v4.0', 'bytedance/seedance-2.5']) {
        await save(
          [last, b, first, a],
          model: model,
          mode: VideoMode.reference,
        );
        final reference = await operation.preview(service, target.id);
        expect(
          reference.inputs.map((i) => i.role),
          everyElement(VideoInputRole.reference_image),
        );
        expect(reference.inputs.map((i) => i.assetId), [
          'last',
          'b',
          'first',
          'a',
        ]);
        final token = model == 'kwaivgi/kling-v4.0' ? '@image_' : '@Image';
        expect(
          reference.request.prompt,
          startsWith('${token}3 ${token}4 ${token}2 ${token}1'),
        );
        expect(
          reference.request.prompt,
          contains('以 ${token}2 作为第 1 个中间过程的画面参考。'),
        );
        expect(
          reference.request.prompt,
          contains('以 ${token}4 作为第 2 个中间过程的画面参考。'),
        );
        expect((await service.inputs(target.id)).map((i) => i.role), [
          VideoInputRole.last_frame,
          VideoInputRole.middle_frame,
          VideoInputRole.first_frame,
          VideoInputRole.middle_frame,
        ]);
      }
      await save([last, b, first, a]);
      expect(
        (await operation.preview(service, target.id)).request.prompt,
        '@image_1 @image_3 @image_2 @image_4',
      );
      expect(
        productionSubmitMode(VideoMode.first_last_frame, [
          VideoInputRole.first_frame,
          VideoInputRole.middle_frame,
        ]),
        VideoMode.first_last_frame,
      );
    },
  );

  test('middle frames become ordinary references across video protocols', () {
    final middle = ProductionInput.asset('middle', VideoInputRole.middle_frame);
    for (final (protocol, model) in [
      (VideoProtocol.ark_video, 'doubao-seedance-2-0-260128'),
      (VideoProtocol.minimax_video_v2, 'MiniMax-H3'),
      (VideoProtocol.atlascloud_video, 'bytedance/seedance-2.5'),
    ]) {
      final provider = videoProviderType(protocol);
      final channel = lookupVideoChannelModel(provider, model)!;
      final raw = VideoRequest(
        modelId: model,
        prompt: StoryboardPrompt.reference(middle.id, 'Middle'),
        mode: VideoMode.reference,
        resolution: channel.resolutions.first,
        ratio: '16:9',
        durationSeconds: channel.durations.first,
        audio: channel.requestDefaults.audio,
        promptExtend: channel.requestDefaults.promptExtend,
      );
      final compiled = compileForTest(provider, raw, [middle]);
      final role = productionSubmitRole(raw.mode, middle.role);
      expect(role, VideoInputRole.reference_image);
      expect(compiled.referenceSlots.single.role, role);
      expect(compiled.referenceSlots.single.inputId, middle.id);
      VideoCapabilities(provider).validateParameters(compiled, [role]);
      final limit =
          channel.capabilities.references[VideoMediaKind.image]!.maxCount;
      expect(
        () => VideoCapabilities(
          provider,
        ).validateParameters(compiled, List.filled(limit + 1, role)),
        throwsA(
          isA<VideoException>().having((e) => e.field, 'field', 'image_count'),
        ),
      );
      expect(
        productionSubmitRole(VideoMode.first_last_frame, middle.role),
        VideoInputRole.middle_frame,
      );
      expect(productionSubmitRole(VideoMode.text, middle.role), role);
    }
  });

  test('submit mode follows the chosen group and the inputs actually sent', () {
    const first = VideoInputRole.first_frame;
    const last = VideoInputRole.last_frame;
    const image = VideoInputRole.reference_image;
    expect(productionSubmitMode(VideoMode.reference, []), VideoMode.text);
    expect(
      productionSubmitMode(VideoMode.reference, [image]),
      VideoMode.reference,
    );
    expect(
      productionSubmitMode(VideoMode.first_last_frame, [first]),
      VideoMode.first_frame,
    );
    expect(
      productionSubmitMode(VideoMode.first_last_frame, [first, last]),
      VideoMode.first_last_frame,
    );
    expect(productionRoles(VideoMode.first_last_frame), [
      first,
      VideoInputRole.middle_frame,
      last,
    ]);
    expect(productionRoles(VideoMode.reference), containsAll([first, last]));
  });
  test(
    'inline and node references share ordered storage without persisted input edges',
    () async {
      await asset('same');
      final target = await service.ensureShotNode(shot.id);
      final source = await service.addMedia(target.canvasId, 'same');
      final direct = ProductionInput.asset(
        'same',
        VideoInputRole.reference_image,
      );
      final linked = ProductionInput.node(
        source.id,
        VideoInputRole.reference_image,
      );
      final prompt =
          '${StoryboardPrompt.reference(direct.id, 'Direct')} then ${StoryboardPrompt.reference(linked.id, 'Following')}';
      Future<void> save(List<ProductionInput> inputs) => service.save(
        nodeId: target.id,
        request: request(prompt),
        providerId: null,
        inputs: inputs,
        overlay: overlay,
      );
      await save([direct, linked]);
      expect(
        (await service.content(
          target.canvasId,
        )).nodes.where((n) => n.sceneId == null),
        hasLength(2),
      );
      expect((await db.select(db.canvasEdges).get()), isEmpty);
      final edge = (await service.content(target.canvasId)).edges.single;
      expect(edge.id, '${target.id}:${linked.id}');
      expect(edge.inputId, linked.id);
      await save([linked, direct]);
      expect((await service.inputs(target.id)).map((i) => i.id), [
        linked.id,
        direct.id,
      ]);
      final copy = await service.copyVideo(target.id, overlay: overlay);
      final copied = await service.inputs(copy.id);
      expect(copied.map((i) => i.refId), [source.id, 'same']);
      expect(
        copied.map((i) => i.id).toSet().intersection({linked.id, direct.id}),
        isEmpty,
      );
      expect(
        StoryboardPrompt.parse(
          (await service.shots.getShot(copy.clipId!))!.prompt,
        ).references.map((p) => p.inputId),
        [copied[1].id, copied[0].id],
      );
      // 输入 id 只在片段内唯一：两个片段用同名输入接同一来源，连线各自独立。
      await service.save(
        nodeId: copy.id,
        request: request(prompt),
        providerId: null,
        inputs: [linked, direct],
        overlay: overlay,
      );
      expect(
        (await service.content(
          target.canvasId,
        )).edges.map((e) => (e.id, e.targetNodeId)),
        unorderedEquals([
          ('${target.id}:${linked.id}', target.id),
          ('${copy.id}:${linked.id}', copy.id),
        ]),
      );
      await service.removeNode(source.id);
      expect(await service.inputs(target.id), hasLength(2));
      await expectLater(
        service.resolveInput(linked),
        throwsA(isA<StoryboardException>()),
      );
      expect(
        (await service.resolveInput(direct)).path,
        'file_workspaces/work/same.png',
      );
    },
  );

  test(
    'restoring old inputs refuses a cycle created by later upstream edits',
    () async {
      final target = await service.ensureShotNode(shot.id);
      final source = await service.addFree(target.canvasId, overlay: overlay);
      final historical = ProductionInput.node(
        source.id,
        VideoInputRole.reference_video,
      );
      await service.shots.restoreInputs(source.clipId!, [
        ProductionInput.node(
          target.id,
          VideoInputRole.reference_video,
        ).toJson(),
      ]);
      await expectLater(
        service.shots.restoreInputs(target.clipId!, [historical.toJson()]),
        throwsA(isA<StoryboardException>()),
      );
      expect(await service.inputs(target.id), isEmpty);
      expect(await service.inputs(source.id), hasLength(1));
    },
  );

  test(
    'one asset may fill first and last frame with distinct stable input IDs',
    () async {
      await asset('frame');
      final target = await service.ensureShotNode(shot.id);
      final first = ProductionInput.asset('frame', VideoInputRole.first_frame);
      final last = ProductionInput.asset('frame', VideoInputRole.last_frame);
      await service.save(
        nodeId: target.id,
        request: request('Still loop'),
        providerId: null,
        inputs: [first, last],
        overlay: overlay,
      );
      expect((await service.inputs(target.id)).map((i) => i.id), [
        first.id,
        last.id,
      ]);
      expect((await service.content(target.canvasId)).edges, isEmpty);
      await expectLater(
        service.save(
          nodeId: target.id,
          request: request('Duplicate'),
          providerId: null,
          inputs: [
            first,
            ProductionInput.asset('frame', VideoInputRole.first_frame),
          ],
          overlay: overlay,
        ),
        throwsFormatException,
      );
      expect((await service.inputs(target.id)), hasLength(2));
    },
  );
}

class _UnusedImages implements ImageTaskService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedAudio implements AudioTaskService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageMedia extends MediaService {
  _ImageMedia({this.size = 1}) : super(FfmpegRunner());
  final int size;
  @override
  Future<MediaInfo> probe(
    String path, {
    MediaCancellation? cancellation,
  }) async => MediaInfo(
    duration: Duration.zero,
    hasAudio: false,
    hasVideo: true,
    width: size,
    height: size,
    videoCodec: 'png',
  );
}

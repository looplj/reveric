// 职责: 验证独立画布作品的导入导出只新建画布，不改来源，也不接受剧本制作画布。
// 关联文件:
//   lib/shared/services/production/canvas_package.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/novel_actions.dart

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/models/production/panorama.dart';
import 'package:reveric/shared/models/production/style.dart';
import 'package:reveric/shared/models/production/view_presets.dart';
import 'package:reveric/shared/models/storyboard/prompt.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/production/canvas_package.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/style_service.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late app.AppDatabase appDb;
  late NovelContentDatabase sourceDb;
  late NovelActionsService actions;
  late MediaLibraryService library;
  late ProductionCanvasService source;
  late String canvasId;
  final opened = <NovelContentDatabase>[];

  setUp(() async {
    support = await Directory.systemTemp.createTemp('canvas-package-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? support.path
              : null,
        );
    await RevericPaths.initialize(fileWorkspaceParent: support.path);
    appDb = app.AppDatabase.forTest(NativeDatabase.memory());
    sourceDb = NovelContentDatabase.forTest(NativeDatabase.memory());
    await ScreenplayService(sourceDb).createCanvasStructure();
    await appDb.novelDao.create(
      id: 'source',
      title: 'Source',
      description: '',
      contentKind: contentKindCanvas,
      contentDatabasePath: 'source.sqlite',
    );
    actions = NovelActionsService(appDb);
    library = MediaLibraryService(appDb, _ImageMedia(), support);
    source = ProductionCanvasService(
      StoryboardService(sourceDb, contentKind: contentKindCanvas),
      library,
      'source',
    );
    canvasId = (await sourceDb.select(sourceDb.canvases).get()).single.id;
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    for (final database in opened) {
      await database.close();
    }
    opened.clear();
    await sourceDb.close();
    await NovelContentDatabase.closeAllCached();
    await appDb.close();
    if (await support.exists()) {
      await support.delete(recursive: true);
    }
  });

  test(
    'imports a canvas work as a new canvas and leaves the source alone',
    () async {
      await source.shots.saveSettings({'ratio': '9:16', 'resolution': '1080p'});
      final text = await source.addText(
        canvasId,
        title: 'Note',
        content: 'hello',
      );
      final png = await _pngAsset(library);
      final media = await source.addMedia(canvasId, png.id);
      await source.move(media.id, 120, 240);
      final image = await source.addImage(canvasId);
      await (sourceDb.update(sourceDb.productionClips)
            ..where((row) => row.id.equals(image.clipId!)))
          .write(const ProductionClipsCompanion(characterId: Value('ghost')));
      final videoClip = await source.shots.createVideo('');
      await source.shots.ensureClipNode(videoClip.id);
      final promptInput = ProductionInput.text(text.id);
      final mediaInput = ProductionInput.node(
        media.id,
        VideoInputRole.reference_image,
      );
      await source.shots.apply(videoClip.id, {
        ...source.shots.snapshot(videoClip),
        'title': 'Shot',
        'prompt': 'See ${StoryboardPrompt.reference(promptInput.id, 'Note')}',
        'duration_ms': 4000,
      });
      await source.shots.restoreInputs(videoClip.id, [
        promptInput.toJson(),
        mediaInput.toJson(),
      ]);
      final storyboard = await source.groups.createStoryboard(
        canvasId,
        layout: const StoryboardGroupLayout(cols: 1, rows: 2, ratio: '1:1'),
        origin: const Offset(40, 80),
        memberIds: const [],
        title: 'Grid',
      );
      await source.groups.attachToSlot(storyboard.id, image.id, 1);
      await source.groups.createFree(
        canvasId,
        frame: const Rect.fromLTWH(100, 200, 400, 300),
        memberIds: [media.id],
        title: 'Loose',
      );
      await source.addEditing(canvasId, title: 'Cut');
      await source.addDirector(canvasId, 'Stage');
      final sourceIds = (await source.content(
        canvasId,
      )).nodes.map((node) => node.id).toSet();

      final overview = await inspectProductionCanvasPublication(
        canvas: source,
        canvasId: canvasId,
      );
      expect(overview.nodeCount, sourceIds.length);
      expect(overview.assetCount, 1);
      expect(overview.sourceBytes, await File(library.resolve(png)).length());
      expect(overview.preview.jpeg, isNotEmpty);
      final packaged = await const ProductionCanvasPackageOrchestrator()
          .exportToFile(canvas: source, canvasId: canvasId, title: 'Board');
      try {
        final manifest = await _manifest(packaged.file);
        expect(manifest['format'], 'production.canvas');
        expect(manifest['version'], 1);
        final packagedNodes = (manifest['nodes'] as List).cast<Map>();
        expect(
          packagedNodes.singleWhere(
            (n) => n['type'] == 'staging',
          )['staging']['format'],
          'director',
        );
        expect(
          packagedNodes.singleWhere(
            (n) => n['type'] == 'editing',
          )['editing']['format'],
          'editing',
        );
        expect(manifest.containsKey('source_work_id'), isFalse);
        expect(jsonEncode(manifest).contains('character_id'), isFalse);
        expect(jsonEncode(manifest).contains('scene_id'), isFalse);

        final first = await _import(packaged.file, actions, library);
        final second = await _import(packaged.file, actions, library);
        final firstNovel = (await appDb.novelDao.get(first.novelId))!;
        final secondNovel = (await appDb.novelDao.get(second.novelId))!;
        expect(firstNovel.contentKind, contentKindCanvas);
        expect(firstNovel.sourceNovelId, isNull);
        expect(firstNovel.title, 'Board');
        expect(secondNovel.title, 'Board (2)');
        expect(secondNovel.id, isNot(firstNovel.id));
        expect((await appDb.novelDao.get('source'))!.title, 'Source');
        expect(
          (await source.content(canvasId)).nodes.map((node) => node.id).toSet(),
          sourceIds,
        );
        expect(
          (await source.shots.getShot(image.clipId!))!.characterId,
          'ghost',
        );

        final content = NovelContentDatabase(firstNovel.contentDatabasePath!);
        opened.add(content);
        final imported = ProductionCanvasService(
          StoryboardService(content, contentKind: contentKindCanvas),
          library,
          first.novelId,
        );
        final importedCanvas =
            (await content.select(content.canvases).get()).single;
        final nodes = (await imported.content(importedCanvas.id)).nodes;
        expect(
          nodes.map((node) => node.id).toSet().intersection(sourceIds),
          isEmpty,
        );
        final note = nodes.singleWhere(
          (node) => node.type == canvasNodeTypeText,
        );
        final shot = nodes.singleWhere(
          (node) => node.type == canvasNodeTypeVideo,
        );
        final picture = nodes.singleWhere(
          (node) => node.type == canvasNodeTypeMedia,
        );
        final still = nodes.singleWhere(
          (node) => node.type == canvasNodeTypeImage,
        );
        final grid = nodes.singleWhere((node) => node.title == 'Grid');
        final loose = nodes.singleWhere((node) => node.title == 'Loose');
        expect(note.content, 'hello');
        expect(picture.x, 120);
        expect(picture.y, 240);
        expect(picture.parentId, loose.id);
        expect(still.parentId, grid.id);
        expect(still.sortOrder, 1);
        final clip = (await imported.shots.getShot(shot.clipId!))!;
        final stillClip = (await imported.shots.getShot(still.clipId!))!;
        expect(clip.episodeId, '');
        expect(clip.durationMs, 4000);
        expect(stillClip.characterId, isNull);
        expect(stillClip.sceneId, isNull);
        expect(stillClip.episodeId, '');
        final prompt = clip.inputs.singleWhere((input) => input.isPrompt);
        expect(prompt.refId, note.id);
        expect(clip.prompt, contains(prompt.id));
        expect(clip.prompt, isNot(contains(promptInput.id)));
        expect(
          clip.inputs.singleWhere((input) => !input.isPrompt).refId,
          picture.id,
        );
        final copied = await library.database.assetDao.getAsset(
          picture.mediaAssetId!,
        );
        expect(
          await File(library.resolve(copied!)).readAsBytes(),
          base64Decode(_png),
        );
        expect(await content.select(content.screenplayEpisodes).get(), isEmpty);
        expect(await content.select(content.characterProfiles).get(), isEmpty);
        final root = (await content.screenplayDao.getRoot())!;
        expect(root.ratio, '9:16');
        expect(root.resolution, '1080p');
        expect(
          nodes.where((node) => node.type == canvasNodeTypeEditing),
          hasLength(1),
        );
        expect(
          nodes.where((node) => node.type == canvasNodeTypeStaging),
          hasLength(1),
        );
        expect(first.droppedStyles, 0);
      } finally {
        await packaged.delete();
      }
    },
  );

  test('round-trips a media name that has no extension', () async {
    final png = await _pngAsset(library);
    await (appDb.update(appDb.assets)..where((row) => row.id.equals(png.id)))
        .write(const app.AssetsCompanion(name: Value('gen_EGKM0Q')));
    await source.addMedia(canvasId, png.id);
    final packaged = await const ProductionCanvasPackageOrchestrator()
        .exportToFile(canvas: source, canvasId: canvasId, title: 'Board');
    try {
      final manifest = await _manifest(packaged.file);
      final listed = (manifest['assets'] as List).single as Map;
      expect(listed['name'], 'gen_EGKM0Q.png');
      expect(listed['file'], 'media/0001.png');

      final imported = await _import(packaged.file, actions, library);
      final copied = await (appDb.select(
        appDb.assets,
      )..where((row) => row.novelId.equals(imported.novelId))).getSingle();
      expect(copied.name, 'gen_EGKM0Q.png');
      expect(copied.type, 'image');

      final archive = ZipDecoder().decodeBytes(
        await packaged.file.readAsBytes(),
      );
      final rebuilt = Archive();
      for (final file in archive) {
        if (!file.isFile) {
          continue;
        }
        final raw = file.readBytes()!;
        final bytes = file.name == 'manifest.json'
            ? utf8.encode(
                jsonEncode({
                  ...jsonDecode(utf8.decode(raw)) as Map<String, dynamic>,
                  'assets': [
                    {
                      ...(manifest['assets'] as List).single
                          as Map<String, dynamic>,
                      'name': 'gen_EGKM0Q',
                    },
                  ],
                }),
              )
            : raw;
        rebuilt.add(ArchiveFile.bytes(file.name, bytes));
      }
      final previous = File(p.join(support.path, 'bare-name.zip'));
      await previous.writeAsBytes(ZipEncoder().encode(rebuilt));
      final again = await _import(previous, actions, library);
      final restored = await (appDb.select(
        appDb.assets,
      )..where((row) => row.novelId.equals(again.novelId))).getSingle();
      expect(restored.name, 'gen_EGKM0Q.png');
      expect(restored.type, 'image');
    } finally {
      await packaged.delete();
    }
  });

  test('exports and imports matching titles after a clip rename', () async {
    final image = await source.addImage(canvasId);
    final clip = (await source.shots.getShot(image.clipId!))!;
    await source.shots.apply(clip.id, {
      ...source.shots.snapshot(clip),
      'title': 'Renamed',
    });
    final packaged = await const ProductionCanvasPackageOrchestrator()
        .exportToFile(canvas: source, canvasId: canvasId, title: 'Board');
    try {
      final manifest = await _manifest(packaged.file);
      final node = (manifest['nodes'] as List).cast<Map>().singleWhere(
        (n) => n['type'] == canvasNodeTypeImage,
      );
      expect(node['title'], 'Renamed');
      expect(node['clip']['title'], 'Renamed');

      final imported = await _import(packaged.file, actions, library);
      final novel = (await appDb.novelDao.get(imported.novelId))!;
      final content = NovelContentDatabase(novel.contentDatabasePath!);
      opened.add(content);
      final still = await (content.select(
        content.canvasNodes,
      )..where((row) => row.type.equals(canvasNodeTypeImage))).getSingle();
      expect(still.title, 'Renamed');
    } finally {
      await packaged.delete();
    }
  });

  test('ignores extra V1 fields and safe unreferenced ZIP entries', () async {
    await source.addText(canvasId, title: 'Note', content: 'hello');
    final packaged = await const ProductionCanvasPackageOrchestrator()
        .exportToFile(canvas: source, canvasId: canvasId, title: 'Board');
    try {
      final archive = ZipDecoder().decodeBytes(
        await packaged.file.readAsBytes(),
      );
      final rebuilt = Archive();
      for (final file in archive) {
        if (!file.isFile) {
          continue;
        }
        final bytes = file.name == 'manifest.json'
            ? utf8.encode(
                jsonEncode({
                  ...jsonDecode(utf8.decode(file.readBytes()!))
                      as Map<String, dynamic>,
                  'source_work_id': 'source',
                }),
              )
            : file.readBytes()!;
        rebuilt.add(ArchiveFile.bytes(file.name, bytes));
      }
      rebuilt.add(ArchiveFile.bytes('extra/notes.json', const [123, 125]));
      final zip = File(p.join(support.path, 'extended.zip'));
      await zip.writeAsBytes(ZipEncoder().encode(rebuilt));
      final imported = await _import(zip, actions, library);
      final work = (await appDb.novelDao.get(imported.novelId))!;
      expect(work.sourceNovelId, isNull);

      final futureManifest = utf8.encode(
        jsonEncode({...await _manifest(packaged.file), 'version': 2}),
      );
      final futureZip = File(p.join(support.path, 'future.zip'));
      await futureZip.writeAsBytes(
        ZipEncoder().encode(
          Archive()..add(ArchiveFile.bytes('manifest.json', futureManifest)),
        ),
      );
      await _expectCode(
        () => _import(futureZip, actions, library),
        'unsupported',
      );
      expect(await appDb.novelDao.getAll(), hasLength(2));
    } finally {
      await packaged.delete();
    }
  });

  test('round-trips a custom style and public clip defaults', () async {
    final styles = ProductionStyleService(appDb);
    final original = await styles.save(
      name: 'Portable',
      prompt: ProductionStylePrompt(before: 'Prefix', after: 'Suffix'),
    );
    await source.setScreenplayStyle(original.id);
    final node = await source.addImage(canvasId);
    final clip = (await source.shots.getShot(node.clipId!))!;
    await source.shots.apply(clip.id, {
      ...source.shots.snapshot(clip),
      'provider_id': 'private-provider',
      'model_id': 'model-for-preview',
      'style_selection': original.id,
      'resolution': '2K',
    });

    final packaged = await const ProductionCanvasPackageOrchestrator()
        .exportToFile(
          canvas: source,
          canvasId: canvasId,
          title: 'Public',
          publicGallery: true,
        );
    addTearDown(packaged.delete);
    final cover = await packaged.cover!.readAsBytes();
    expect(cover.take(2), [0xff, 0xd8]);
    expect(cover.length, lessThanOrEqualTo(2 * 1024 * 1024));

    final manifest = await _manifest(packaged.file);
    expect(jsonEncode(manifest), isNot(contains('private-provider')));
    final preview = await readProductionCanvasPackagePreview(packaged.file);
    addTearDown(preview.delete);
    expect(preview.generations.single.model, 'model-for-preview');
    expect(preview.generations.single.parameters['resolution'], '2K');

    final imported = await _import(packaged.file, actions, library);
    final work = (await appDb.novelDao.get(imported.novelId))!;
    final importedDb = NovelContentDatabase(work.contentDatabasePath!);
    opened.add(importedDb);
    final importedClip =
        (await importedDb.select(importedDb.productionClips).get()).single;
    final root = (await importedDb.screenplayDao.getRoot())!;
    expect(importedClip.providerId, isNull);
    expect(importedClip.modelId, isNull);
    expect(importedClip.resolution, '1K');
    expect(importedClip.styleSelection, root.styleId);
    expect(root.styleId, isNot(original.id));
    final restoredStyle = (await appDb.productionStyleDao.getStyle(
      root.styleId!,
    ))!;
    expect(restoredStyle.before, 'Prefix');
    expect(restoredStyle.after, 'Suffix');
  });

  test('restores panorama view and image preset on ordinary nodes', () async {
    final png = await _pngAsset(library);
    final media = await source.addMedia(canvasId, png.id);
    const mediaView = PanoramaView(yaw: 20, pitch: -10, fov: 80);
    await source.setPanoramaView(media.id, mediaView);
    final image = await source.addImage(canvasId);
    const imageView = PanoramaView(yaw: 5, pitch: 6, fov: 70);
    const preset = ImageGenerationPreset(
      method: ImageGenerationMethod.panorama,
      complexity: 'detailed',
    );
    await source.write(image.id, () async {
      await source.db.canvasDao.updateActiveNodeFields(
        image.id,
        CanvasNodesCompanion(
          style: Value({
            'imageGeneration': preset.toJson(),
            'panorama': imageView.toJson(),
          }),
        ),
      );
    });

    final packaged = await const ProductionCanvasPackageOrchestrator()
        .exportToFile(canvas: source, canvasId: canvasId, title: 'Views');
    addTearDown(packaged.delete);
    final imported = await _import(packaged.file, actions, library);
    final work = (await appDb.novelDao.get(imported.novelId))!;
    final importedDb = NovelContentDatabase(work.contentDatabasePath!);
    opened.add(importedDb);
    final nodes = await importedDb.canvasDao.getNodesByCanvas(
      (await importedDb.select(importedDb.canvases).get()).single.id,
    );
    final importedMedia = nodes.singleWhere(
      (node) => node.type == canvasNodeTypeMedia,
    );
    final importedImage = nodes.singleWhere(
      (node) => node.type == canvasNodeTypeImage,
    );
    expect(PanoramaView.fromStyle(importedMedia.style), mediaView);
    expect(
      ImageGenerationPreset.fromStyle(importedImage.style).method,
      preset.method,
    );
    expect(
      ImageGenerationPreset.fromStyle(importedImage.style).complexity,
      preset.complexity,
    );
    expect(PanoramaView.fromStyle(importedImage.style), imageView);
  });

  test('refuses a screenplay production canvas', () async {
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    opened.add(db);
    await ScreenplayService(db).createInitialStructure();
    final episode = (await db.select(db.screenplayEpisodes).get()).first;
    final shots = StoryboardService(db);
    final canvas = await shots.ensureCanvas(episode.id);
    await _expectCode(
      () => const ProductionCanvasPackageOrchestrator().exportToFile(
        canvas: ProductionCanvasService(shots, library, 'play'),
        canvasId: canvas.id,
        title: 'Episode',
      ),
      'canvas_only',
    );
    expect(await appDb.novelDao.getAll(), hasLength(1));
  });

  test('refuses an empty canvas', () async {
    await _expectCode(
      () => const ProductionCanvasPackageOrchestrator().exportToFile(
        canvas: source,
        canvasId: canvasId,
        title: 'Board',
      ),
      'empty',
    );
  });

  test('rejects a zip that escapes its directory', () async {
    final archive = Archive()
      ..add(
        ArchiveFile.bytes(
          'manifest.json',
          utf8.encode('{"format":"production.canvas"}'),
        ),
      )
      ..add(ArchiveFile.bytes('../evil.json', const [1]));
    final zip = File(p.join(support.path, 'slip.zip'));
    await zip.writeAsBytes(ZipEncoder().encode(archive));
    await _expectCode(() => _import(zip, actions, library), 'invalid_package');
    expect(await appDb.novelDao.getAll(), hasLength(1));
    expect(await File(p.join(support.path, 'evil.json')).exists(), isFalse);
  });

  test(
    'publish preview keeps a sibling cover file when capture fails',
    () async {
      final media = _ThrowingThumbnailMedia();
      final videoLibrary = MediaLibraryService(appDb, media, support);
      final videoCanvas = ProductionCanvasService(
        StoryboardService(sourceDb, contentKind: contentKindCanvas),
        videoLibrary,
        'source',
      );
      final video = await _videoAsset(videoLibrary);
      await videoCanvas.addMedia(canvasId, video.id);
      final stored = File(videoLibrary.resolve(video));
      final sibling = File('${stored.path}.cover.png');
      await sibling.writeAsBytes(const [1, 2, 3, 4]);

      final overview = await inspectProductionCanvasPublication(
        canvas: videoCanvas,
        canvasId: canvasId,
      );

      expect(await sibling.readAsBytes(), const [1, 2, 3, 4]);
      expect(media.outputs, hasLength(1));
      expect(media.outputs.single, isNot(sibling.path));
      expect(media.outputs.single, contains('reveric_canvas_cover_'));
      expect(
        await Directory(p.dirname(media.outputs.single)).exists(),
        isFalse,
      );
      expect(overview.preview.jpeg, isNotEmpty);
    },
  );

  test('offers placed and adopted images as gallery covers', () async {
    final placed = await _pngAsset(library);
    await source.addMedia(canvasId, placed.id);
    final adopted = await _pngAsset(
      library,
      bytes: base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      ),
    );
    final image = await source.addImage(canvasId);
    await source.adopt(image.id, adopted.id);
    await source.addText(canvasId, title: 'Note', content: 'hello');

    final choices = await listProductionCanvasCoverImages(
      canvas: source,
      canvasId: canvasId,
    );

    expect(choices.map((item) => item.id), [placed.id, adopted.id]);
  });

  test('cancels export when a node file is missing', () async {
    final png = await _pngAsset(library);
    await source.addMedia(canvasId, png.id);
    await File(library.resolve(png)).delete();
    await _expectCode(
      () => const ProductionCanvasPackageOrchestrator().exportToFile(
        canvas: source,
        canvasId: canvasId,
        title: 'Board',
      ),
      'missing_media',
    );
  });
}

Future<ProductionCanvasPackageImport> _import(
  File zip,
  NovelActionsService actions,
  MediaLibraryService library,
) => const ProductionCanvasPackageOrchestrator().importFile(
  zip: zip,
  actions: actions,
  library: library,
  fallbackTitle: 'Canvas',
  openContent: NovelContentDatabase.new,
  releaseContent: (database) => database.close(),
);

Future<void> _expectCode(Future<Object?> Function() action, String code) async {
  try {
    await action();
    fail('expected $code');
  } on ProductionCanvasPackageException catch (error) {
    expect(error.code, code);
  }
}

Future<Map<String, dynamic>> _manifest(File zip) async {
  final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
  return jsonDecode(
        utf8.decode(archive.findFile('manifest.json')!.readBytes()!),
      )
      as Map<String, dynamic>;
}

Future<app.AssetRow> _pngAsset(
  MediaLibraryService library, {
  List<int>? bytes,
}) async {
  final file = File(
    p.join(
      Directory.systemTemp.path,
      'canvas-package-${DateTime.now().microsecondsSinceEpoch}.png',
    ),
  );
  await file.writeAsBytes(bytes ?? base64Decode(_png));
  try {
    return await library.importFile(
      file,
      name: 'dot.png',
      novelId: 'source',
      purpose: AssetPurpose.production_upload,
      cancellation: MediaCancellation(),
    );
  } finally {
    if (await file.exists()) {
      await file.delete();
    }
  }
}

Future<app.AssetRow> _videoAsset(MediaLibraryService library) async {
  final file = File(
    p.join(
      Directory.systemTemp.path,
      'canvas-package-${DateTime.now().microsecondsSinceEpoch}.mp4',
    ),
  );
  await file.writeAsBytes(const [0, 0, 0, 24]);
  try {
    return await library.importFile(
      file,
      name: 'clip.mp4',
      novelId: 'source',
      purpose: AssetPurpose.production_upload,
      cancellation: MediaCancellation(),
    );
  } finally {
    if (await file.exists()) {
      await file.delete();
    }
  }
}

class _ThrowingThumbnailMedia extends _ImageMedia {
  final outputs = <String>[];

  @override
  Future<MediaInfo> probe(
    String path, {
    MediaCancellation? cancellation,
  }) async => const MediaInfo(
    duration: Duration(seconds: 1),
    hasAudio: false,
    hasVideo: true,
    width: 2,
    height: 2,
    videoCodec: 'h264',
    formatName: 'mov,mp4,m4a',
  );

  @override
  Future<void> captureThumbnail(
    String input,
    File output, {
    MediaCancellation? cancellation,
  }) async {
    outputs.add(output.path);
    throw const MediaException(MediaFailure.invalid_media);
  }
}

class _ImageMedia extends MediaService {
  _ImageMedia() : super(FfmpegRunner());

  @override
  Future<MediaInfo> probe(
    String path, {
    MediaCancellation? cancellation,
  }) async => const MediaInfo(
    duration: Duration.zero,
    hasAudio: false,
    hasVideo: true,
    width: 1,
    height: 1,
    videoCodec: 'png',
  );
}

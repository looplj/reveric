// 职责: 验证图片库入库 — 文件按作品去重并记录业务场景，地图出图分类、元数据与同图多次留存。
// 关联文件:
//   lib/shared/services/image_library_service.dart
//   lib/shared/database/app_database.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'dart:convert';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/models/asset_purpose.dart';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/services/image_library_service.dart';
import 'package:reveric/shared/services/ai/image.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory supportDir;
  late AppDatabase database;

  setUp(() async {
    supportDir = await Directory.systemTemp.createTemp('reveric_map_assets_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? supportDir.path
              : null,
        );
    await RevericPaths.initialize();
    database = AppDatabase.forTest(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (await supportDir.exists()) await supportDir.delete(recursive: true);
  });

  test(
    'single-selection callers still preserve every candidate in the library',
    () async {
      final outputs = <AiImageGenerationResult>[];
      for (var i = 0; i < 4; i++) {
        final file = await File('${supportDir.path}/candidate-$i.png')
            .writeAsBytes(
              img.encodePng(
                img.Image(width: 8, height: 8)
                  ..setPixelRgb(0, 0, i * 60, 20, 30),
              ),
            );
        outputs.add(AiImageGenerationResult(localFilePath: file.path));
      }
      final first = await buildImageLibraryService(database).importGenerated(
        AiImageGenerationResult.group(outputs),
        novelId: 'work',
        purpose: AssetPurpose.ai_chat_generated,
      );
      final assets = await database.select(database.assets).get();
      expect(assets, hasLength(4));
      expect(assets.map((asset) => asset.id), contains(first.id));
    },
  );

  test(
    'generated media part commits once without a second temporary copy',
    () async {
      final part = File(
        '${supportDir.path}/file_workspaces/reveric_image_result_1.png.part',
      );
      await part.parent.create(recursive: true);
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      await part.writeAsBytes(bytes);
      final asset = await IOOverrides.runZoned(
        () => buildImageLibraryService(database).importGenerated(
          AiImageGenerationResult(localFilePath: part.path),
          novelId: 'work',
          purpose: AssetPurpose.ai_chat_generated,
        ),
        getSystemTempDirectory: () =>
            throw StateError('Unexpected temporary copy'),
      );
      expect(asset.path, startsWith('file_workspaces/work/images/'));
      expect(asset.path, endsWith('.png'));
      expect(
        await File('${supportDir.path}/${asset.path}').readAsBytes(),
        bytes,
      );
      expect(await part.exists(), false);
      expect(await database.select(database.assets).get(), hasLength(1));
      await AiImageGenerationResult(
        localFilePath: '${supportDir.path}/${asset.path}',
      ).disposeTemporary();
      expect(await File('${supportDir.path}/${asset.path}').exists(), true);
    },
  );

  test(
    'generated image and map files use the selected whole workspace directory',
    () async {
      final external = await Directory.systemTemp.createTemp('external-media-');
      addTearDown(() => external.delete(recursive: true));
      await RevericPaths.initialize(fileWorkspaceParent: external.path);
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      final part = File(
        '${external.path}/file_workspaces/reveric_image_result_external.png.part',
      );
      await part.parent.create(recursive: true);
      await part.writeAsBytes(bytes);
      final library = buildImageLibraryService(database);
      final image = await library.importGenerated(
        AiImageGenerationResult(localFilePath: part.path),
        novelId: 'work',
        purpose: AssetPurpose.ai_chat_generated,
      );
      final map = await library.importMapImage(bytes, novelId: 'work');
      for (final asset in [image, map]) {
        expect(asset.path, startsWith('file_workspaces/work/images/'));
        expect(
          await File('${external.path}/${asset.path}').readAsBytes(),
          bytes,
        );
        expect(
          RevericPaths.resolveStored(asset.path),
          '${external.path}/${asset.path}',
        );
        expect(await File('${supportDir.path}/${asset.path}').exists(), false);
      }
      expect(await part.exists(), false);
    },
  );

  test('identical generated maps remain separate map assets', () async {
    final service = buildImageLibraryService(database);
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    final metadata = <String, dynamic>{
      'schema_version': 1,
      'source_map_name': '长梦大陆',
      'style_id': 'parchment',
    };

    final first = await service.importMapImage(
      bytes,
      novelId: 'novel_1',
      prompt: '绘制长梦大陆地图',
      metadata: metadata,
    );
    final second = await service.importMapImage(
      bytes,
      novelId: 'novel_1',
      prompt: '绘制长梦大陆地图',
      metadata: metadata,
    );

    expect(second.id, isNot(first.id));
    expect(first.id, matches(r'^ast_[A-Za-z0-9]{16}$'));
    expect(second.id, matches(r'^ast_[A-Za-z0-9]{16}$'));
    // Existing releases stored ordinary JSON text in this same SQLite column.
    await database.customStatement(
      'UPDATE assets SET metadata_json = ? WHERE id = ?',
      [jsonEncode(metadata), first.id],
    );
    final assets = await database.imageAssetDao
        .watchAssets(novelId: 'novel_1', purpose: AssetPurpose.map.value)
        .first;
    expect(assets, hasLength(2));
    expect(assets, everyElement(isA<AssetRow>()));
    expect(
      assets,
      everyElement(
        predicate<AssetRow>((row) {
          final decoded = row.metadataJson!;
          return row.purpose == AssetPurpose.map.value &&
              decoded['source_map_name'] == '长梦大陆';
        }),
      ),
    );
  });

  test('unreadable recognition snapshot is treated as not recognized', () async {
    final library = buildImageLibraryService(database);
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    final asset = await library.importMapImage(
      bytes,
      novelId: 'novel_1',
      metadata: {'style_id': 'parchment'},
    );
    for (final snapshot in <Object>[
      'broken',
      <String, dynamic>{'places': 'not a list'},
      <String, dynamic>{'places': <Object>[], 'matches': <Object>[]},
    ]) {
      await database.imageAssetDao.updateMetadata(asset.id, {
        'style_id': 'parchment',
        'recognition': snapshot,
      });
      expect(await library.mapRecognition(asset.id), isNull);
    }
  });

  test('malformed legacy metadata does not break the map history list', () async {
    final library = buildImageLibraryService(database);
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    final valid = await library.importMapImage(
      bytes,
      novelId: 'novel_1',
      metadata: {'source_map_name': '有效地图'},
    );
    final legacy = await library.importMapImage(bytes, novelId: 'novel_1');

    for (final raw in ['', '{"broken":', 'not json']) {
      await database.customStatement(
        'UPDATE assets SET metadata_json = ? WHERE id = ?',
        [raw, legacy.id],
      );
      final assets = await database.imageAssetDao
          .watchAssets(purpose: AssetPurpose.map.value)
          .first;
      expect(assets, hasLength(2));
      expect(
        assets.singleWhere((row) => row.id == legacy.id).metadataJson,
        isEmpty,
      );
      expect(assets.singleWhere((row) => row.id == valid.id).metadataJson, {
        'source_map_name': '有效地图',
      });
      expect(await library.mapRecognition(legacy.id), isNull);
    }
  });

  test(
    'file imports dedupe per work and purpose, sharing the file within a work',
    () async {
      final library = buildImageLibraryService(database);
      final source = File('${supportDir.path}/picked.png');
      await source.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );

      final first = await library.importFile(
        source.path,
        novelId: 'novel_a',
        purpose: AssetPurpose.reference,
      );
      final again = await library.importFile(
        source.path,
        novelId: 'novel_a',
        purpose: AssetPurpose.reference,
      );
      final other = await library.importFile(
        source.path,
        novelId: 'novel_b',
        purpose: AssetPurpose.photo,
      );

      final otherPurpose = await library.importFile(
        source.path,
        novelId: 'novel_a',
        purpose: AssetPurpose.cover,
      );

      expect(again.id, first.id);
      for (final asset in [first, other, otherPurpose]) {
        expect(asset.id, matches(r'^ast_[A-Za-z0-9]{16}$'));
      }
      expect(other.id, isNot(first.id));
      // 同作品换场景：另起一条记录，但复用已登记的文件。
      expect(otherPurpose.id, isNot(first.id));
      expect(otherPurpose.purpose, AssetPurpose.cover.value);
      expect(otherPurpose.path, first.path);
      expect(
        Directory(
          '${supportDir.path}/file_workspaces',
        ).listSync(recursive: true).whereType<File>().toList(),
        hasLength(2),
      );
      expect(first.novelId, 'novel_a');
      expect(first.purpose, AssetPurpose.reference.value);
      expect(other.novelId, 'novel_b');
      expect(other.purpose, AssetPurpose.photo.value);
      expect((await database.assetDao.getAsset(first.id))!.novelId, 'novel_a');
    },
  );

  test(
    'files in the current work and type directory are registered in place',
    () async {
      final library = buildImageLibraryService(database);
      final images = await Directory(
        '${supportDir.path}/file_workspaces/novel_a/images',
      ).create(recursive: true);
      final generated = File('${images.path}/generated.png');
      await generated.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );

      final asset = await library.importFile(
        generated.path,
        novelId: 'novel_a',
        purpose: AssetPurpose.production_generated,
        source: 'generated',
      );

      expect(asset.path, 'file_workspaces/novel_a/images/generated.png');
      expect(images.listSync(), hasLength(1));
    },
  );
}

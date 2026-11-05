// 职责: 验证地图生成自动采用、历史恢复与空世界生成门禁。
// 关联文件:
//   lib/shared/providers/map_studio_controller.dart
//   lib/shared/services/image_library_service.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
import 'dart:io';
import 'package:reveric/shared/models/asset_purpose.dart';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/generate_map_orchestrator.dart';
import 'package:reveric/shared/providers/map_studio_controller.dart';
import 'package:reveric/shared/models/map_studio_models.dart';
import 'package:reveric/shared/providers/map_studio_providers.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/ai/image.dart';
import 'package:reveric/shared/services/image_library_service.dart';
import 'package:reveric/shared/services/maps_service.dart';
import 'package:reveric/shared/services/map_place_name_reader.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'generation applies automatically and previous images remain restorable',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'map_auto_apply_',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => directory.path,
      );
      await RevericPaths.initialize();
      final database = NovelContentDatabase.forTest(NativeDatabase.memory());
      final appDatabase = AppDatabase.forTest(NativeDatabase.memory());
      final library = buildImageLibraryService(appDatabase);
      var imageCalls = 0;
      final reader = _PlaceReader();
      final container = ProviderContainer(
        overrides: [
          novelContentDatabaseProvider('test-map').overrideWithValue(database),
          imageLibraryServiceProvider.overrideWithValue(library),
          mapStudioImageModelSelectionProvider.overrideWithValue(null),
          mapPlaceNameReaderProvider.overrideWithValue(reader),
          mapImageEditCallbackProvider.overrideWithValue(null),
          mapImageGenerateCallbackProvider.overrideWithValue((
            prompt, {
            model,
            size,
            quality,
            complexity,
          }) async {
            imageCalls++;
            return const AiImageGenerationResult(
              imageBase64:
                  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
            );
          }),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
        await appDatabase.close();
        messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        await directory.delete(recursive: true);
      });
      final locations = LocationsService(database);
      final world = await locations.createLocation(
        name: 'World',
        type: locationTypeWorld,
      );
      final otherWorld = await locations.createLocation(
        name: 'Other',
        type: locationTypeWorld,
      );
      await locations.createLocation(name: 'Other city', parentId: otherWorld);
      final maps = MapsService(database);
      final mapId = await maps.createMap(name: 'Map', locationId: world);
      final provider = mapStudioControllerProvider('test-map', mapId);
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      final controller = container.read(provider.notifier);
      Future<void> generate() => controller.generate(
        const MapGenerationRequest(
          styleId: 'parchment',
          resolutionId: '1k',
          includeLocations: true,
        ),
        novelId: 'novel-test',
        sourceMapName: 'Map',
      );

      await generate();
      expect(
        imageCalls,
        0,
        reason: 'Other worlds do not satisfy the location requirement',
      );
      expect(container.read(provider).errorMessage, isNotNull);

      final cityId = await locations.createLocation(
        name: 'City',
        parentId: world,
      );
      await generate();
      expect(imageCalls, 1);
      expect(reader.calls, 1);
      expect(container.read(provider).phase, MapStudioPhase.viewing);
      expect(container.read(provider).errorMessage, isNull);
      final first = MapStudioSettings.fromMap(
        (await maps.getMapById(mapId))!.settings,
      );
      expect(first.hasImage, isTrue);
      expect(first.version, 1);

      await generate();
      final second = MapStudioSettings.fromMap(
        (await maps.getMapById(mapId))!.settings,
      );
      expect(second.version, 2);
      expect(second.image, isNot(first.image));
      final assets = await appDatabase.imageAssetDao
          .watchAssets(novelId: 'novel-test', purpose: AssetPurpose.map.value)
          .first;
      expect(assets, hasLength(2));
      expect(reader.calls, 2);
      final oldAsset = assets.singleWhere((asset) => asset.path == first.image);
      await controller.previewAsset(
        oldAsset,
        novelId: 'novel-test',
        sourceMapName: 'Map',
      );
      expect(container.read(provider).phase, MapStudioPhase.review);
      expect(
        MapStudioSettings.fromMap(
          (await maps.getMapById(mapId))!.settings,
        ).image,
        second.image,
      );
      await controller.adopt();
      expect(
        MapStudioSettings.fromMap(
          (await maps.getMapById(mapId))!.settings,
        ).image,
        first.image,
      );
      expect(container.read(provider).phase, MapStudioPhase.viewing);
      expect(mapGenerationActivityCounter.value, 0);
      expect(
        reader.calls,
        2,
        reason: 'Adopting history must reuse the paid result',
      );
      final positions = await MapLocationsService(
        database,
      ).getMapLocations(mapId);
      expect(positions.single.locationId, cityId);
      expect(positions.single.x, 0.25);
      expect(positions.single.y, 0.75);

      // Destroy the controller, then restore from the database using a stale list row.
      container.invalidate(provider);
      final restored = container.read(provider.notifier);
      await restored.previewAsset(
        oldAsset,
        novelId: 'novel-test',
        sourceMapName: 'Map',
      );
      expect(container.read(provider).requiresPlaceRecognition, isFalse);
      await restored.adopt();
      expect(reader.calls, 2);

      // Rename after preview: adoption must recheck, not trust the preview's cache.
      await restored.previewAsset(
        oldAsset,
        novelId: 'novel-test',
        sourceMapName: 'Map',
      );
      await locations.updateLocation(id: cityId, name: 'New city');
      await restored.adopt();
      expect(reader.calls, 3);
      final saved = await library.mapRecognition(oldAsset.id);
      expect(saved!.places.single.name, 'New city');
      expect(
        (await appDatabase.imageAssetDao.getAsset(
          oldAsset.id,
        ))!.metadataJson!['style_id'],
        'parchment',
      );
      await restored.previewAsset(
        oldAsset,
        novelId: 'novel-test',
        sourceMapName: 'Map',
      );
      await restored.adopt();
      expect(reader.calls, 3, reason: 'Updated results must also be persisted');

      final legacy = await library.importMapImage(
        await File(library.resolve(oldAsset.path)!).readAsBytes(),
        novelId: 'novel-test',
      );
      reader.fail = true;
      await restored.previewAsset(
        legacy,
        novelId: 'novel-test',
        sourceMapName: 'Map',
      );
      expect(container.read(provider).requiresPlaceRecognition, isTrue);
      await restored.adopt();
      expect(reader.calls, 4);
      expect(
        await library.mapRecognition(legacy.id),
        isNull,
        reason: 'A failed request must not become a reusable empty result',
      );
      reader.fail = false;
      reader.noMatches = true;
      await restored.previewAsset(
        legacy,
        novelId: 'novel-test',
        sourceMapName: 'Map',
      );
      await restored.adopt();
      expect(reader.calls, 5);
      expect((await library.mapRecognition(legacy.id))!.result.unresolved, [
        'New city',
      ]);
      await restored.previewAsset(
        legacy,
        novelId: 'novel-test',
        sourceMapName: 'Map',
      );
      await restored.adopt();
      expect(
        reader.calls,
        5,
        reason: 'A successful no-match result must not be charged again',
      );
    },
  );
}

class _PlaceReader extends Fake implements MapPlaceNameReader {
  int calls = 0;
  bool fail = false;
  bool noMatches = false;

  @override
  bool get isConfigured => true;

  @override
  Future<MapPlaceReadResult> readPlacePositions({
    required Uint8List imageBytes,
    required String mimeSubtype,
    required int imageWidth,
    required int imageHeight,
    required List<MapPlaceNameCandidate> candidates,
  }) async {
    calls++;
    if (fail) {
      throw const MapVisionRequestException('test failure');
    }
    return MapPlaceReadResult(
      matches: noMatches
          ? []
          : [
              for (final candidate in candidates)
                MapPlaceMatch(
                  locationId: candidate.locationId,
                  requestedName: candidate.name,
                  matchedName: candidate.name,
                  x: 0.25,
                  y: 0.75,
                ),
            ],
      unresolved: noMatches ? candidates.map((c) => c.name).toList() : [],
    );
  }
}

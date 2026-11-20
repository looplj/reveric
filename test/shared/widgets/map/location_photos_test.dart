// 职责: 验证地点照片条的导入（单张失败不影响其余）、移除与名称展示。
// 关联文件:
//   lib/shared/widgets/map/location_photos.dart
//   lib/shared/services/maps_service.dart
//   lib/shared/services/image_library_service.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
import 'dart:io';
import 'package:reveric/shared/models/asset_purpose.dart';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/maps_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/image_library_service.dart';
import 'package:reveric/shared/services/maps_service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:reveric/shared/widgets/map/location_photos.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _path = 'location-photos-test';

class _Library extends ImageLibraryService {
  _Library(AppDatabase database)
    : super(database, () => throw StateError('Media import is stubbed.'));

  @override
  Future<AssetRow> importFile(
    String sourcePath, {
    required String novelId,
    required AssetPurpose purpose,
    String? prompt,
    String? model,
    String? batchId,
    String? name,
    String source = 'uploaded',
  }) async {
    if (sourcePath.contains('broken')) {
      throw StateError('unreadable');
    }
    final file = sourcePath.split('/').last;
    return AssetRow(
      id: file,
      type: 'image',
      name: name ?? file,
      path: 'images/$file',
      purpose: purpose.value,
      source: source,
      favorite: false,
      inLibrary: false,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      deletedAt: notDeletedSentinel,
    );
  }
}

void main() {
  late NovelContentDatabase db;
  late AppDatabase appDb;
  late LocationsService service;
  late String id;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    final directory = await Directory.systemTemp.createTemp('location_photos');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => directory.path,
        );
    await RevericPaths.initialize();
  });
  setUp(() async {
    rootBundle.clear();
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    appDb = AppDatabase.forTest(NativeDatabase.memory());
    service = LocationsService(db);
    id = await service.createLocation(name: 'Harbor');
    await service.updateLocation(
      id: id,
      photos: const [
        SubjectPhoto(assetId: 'a.png', name: 'Night'),
        SubjectPhoto(assetId: 'b.png'),
      ],
    );
  });
  tearDown(() async {
    await db.close();
    await appDb.close();
  });

  testWidgets('imports picked photos, keeps going past a failure, removes', (
    tester,
  ) async {
    final location = (await tester.runAsync(
      () => service.getLocationById(id),
    ))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          novelContentDatabaseProvider(_path).overrideWithValue(db),
          locationsServiceProvider(_path).overrideWithValue(service),
          imageLibraryServiceProvider.overrideWithValue(_Library(appDb)),
        ],
        child: EasyLocalization(
          supportedLocales: const [Locale('en')],
          path: 'assets/translations',
          assetLoader: const MergingAssetLoader(),
          fallbackLocale: const Locale('en'),
          startLocale: const Locale('en'),
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              theme: RevericThemeData.reveric.toThemeData(),
              home: RevericTheme(
                data: RevericThemeData.reveric,
                child: Scaffold(
                  body: LocationPhotos(
                    novelId: 'novel_test',
                    databasePath: _path,
                    location: location,
                    pickImages: () async => [
                      '/picked/c.png',
                      '/picked/broken.png',
                      '/picked/a.png',
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Night'), findsOneWidget);
    expect(find.text('Untitled'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('location_photo_add')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(
      (await tester.runAsync(() => service.getLocationById(id)))!.photos,
      const [
        SubjectPhoto(assetId: 'a.png', name: 'Night'),
        SubjectPhoto(assetId: 'b.png'),
        SubjectPhoto(assetId: 'c.png'),
      ],
    );

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Remove').first);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(
      (await tester.runAsync(() => service.getLocationById(id)))!.photos,
      const [SubjectPhoto(assetId: 'b.png'), SubjectPhoto(assetId: 'c.png')],
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

// 职责: Patrol Mobile Maps E2E — 验证移动端地图分区：新建世界、改名，进入地图工作台后在地点抽屉里添加子地点、左滑删除地点。
// 关联文件:
//   lib/mobile/widgets/maps_panel.dart
//   lib/mobile/features/map/studio_page.dart
//   lib/mobile/features/map/places_sheet.dart
//   lib/mobile/features/map/location_tree.dart
//   lib/mobile/widgets/section_scaffold.dart
//   lib/mobile/pages/location_editor_page.dart
//   lib/shared/providers/maps_providers.dart
//   lib/shared/services/maps_service.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/map_editor.json
//   assets/translations/zh-CN/map_editor.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md

import 'dart:io';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/mobile/pages/location_editor_page.dart';
import 'package:reveric/mobile/widgets/maps_panel.dart';
import 'package:reveric/shared/components/reveric_button.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/maps_service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:reveric/shared/widgets/confirm_dialog.dart';
import 'package:patrol/patrol.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _testDatabasePath = ':memory:test_maps';

void main() {
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory support;

  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    support = await Directory.systemTemp.createTemp('reveric_patrol_support_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getApplicationSupportDirectory' ||
              call.method == 'getTemporaryDirectory') {
            return support.path;
          }
          return null;
        });
    await RevericPaths.initialize();
  });

  tearDownAll(() async {
    await AppDatabase.closeCached();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await support.delete(recursive: true);
  });

  patrolTest('creates a world, renames it, and adds a sub-location', ($) async {
    // ignore: invalid_use_of_visible_for_testing_member
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    addTearDown(db.close);
    final service = LocationsService(db);

    _setMobileSurface($, const Size(400, 900));
    await $.pumpWidgetAndSettle(_MobileMapsHarness(db: db));

    // Empty state — create world button visible.
    expect($(#mobile_maps_empty_create_button), findsOneWidget);

    // Tap create world → editor page opens.
    await $(#mobile_maps_empty_create_button).tap();
    await $.pumpAndSettle();
    expect($(#mobile_location_name_field), findsOneWidget);

    // Rename the world.
    await $(#mobile_location_name_field).enterText('Azeroth');
    // Let the 800ms autosave timer fire before leaving.
    await $.tester.pump(const Duration(milliseconds: 900));
    await $.pumpAndSettle();

    // Go back to the list.
    await $(#mobile_location_back_button).tap();
    await $.pumpAndSettle();

    // List shows the world.
    expect($('Azeroth'), findsOneWidget);
    final locations = await service.getLocations();
    expect(locations, hasLength(1));
    expect(locations.single.name, 'Azeroth');
    expect(locations.single.type, locationTypeWorld);

    // World card opens the map studio; locations are managed in its places sheet.
    await $('Azeroth').tap();
    await $.pumpAndSettle();
    expect($(#mobile_map_empty_canvas), findsOneWidget);
    await $(#mobile_map_places).tap();
    await $.pumpAndSettle();

    // "+" creates a sub-location under the current map (the world) and opens its editor.
    await $(#mobile_map_places_create).tap();
    await $.pumpAndSettle();
    expect($(#mobile_location_name_field), findsOneWidget);

    await $(#mobile_location_name_field).enterText('Eastern Kingdoms');
    await $.tester.pump(const Duration(milliseconds: 900));
    await $.pumpAndSettle();

    // Back to the places sheet — the world row is expanded and shows the sub-location.
    await $(#mobile_location_back_button).tap();
    await $.pumpAndSettle();
    expect($('Eastern Kingdoms'), findsOneWidget);
    expect(
      find.byWidgetPredicate((widget) {
        if (widget is! Text) return false;
        return widget.data?.contains('sub-locations') == true;
      }),
      findsOneWidget,
    );

    // Two locations persisted.
    final allLocations = await service.getLocations();
    expect(allLocations, hasLength(2));
    final child = allLocations.firstWhere((l) => l.name == 'Eastern Kingdoms');
    expect(child.parentId, locations.single.id);
    expect(child.type, locationTypeRegion);
  });

  patrolTest('deletes a sub-location by swiping the tree row', ($) async {
    // ignore: invalid_use_of_visible_for_testing_member
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    addTearDown(db.close);
    final service = LocationsService(db);

    // Seed a world and a child location.
    final worldId = await service.createLocation(
      name: 'Azeroth',
      type: locationTypeWorld,
      parentId: null,
    );
    final childId = await service.createLocation(
      name: 'Eastern Kingdoms',
      type: locationTypeRegion,
      parentId: worldId,
    );

    _setMobileSurface($, const Size(400, 900));
    await $.pumpWidgetAndSettle(_MobileMapsHarness(db: db));

    // Open the world's map studio, then its places sheet (world row starts expanded).
    await $(ValueKey('mobile_maps_world_$worldId')).tap();
    await $.pumpAndSettle();
    await $(#mobile_map_places).tap();
    await $.pumpAndSettle();
    expect($('Eastern Kingdoms'), findsOneWidget);

    // Swipe the child row left to reveal the delete action, then tap it.
    await $.tester.drag(
      $(ValueKey('mobile_maps_tree_item_$childId')).finder,
      const Offset(-300, 0),
    );
    await $.pumpAndSettle();
    await $(find.widgetWithText(CustomSlidableAction, 'Delete')).tap();
    await $.pumpAndSettle();

    await $(
      find.descendant(
        of: find.byType(ConfirmDialog),
        matching: find.widgetWithText(RevericButton, 'Delete'),
      ),
    ).tap();
    await $.tester.pump(const Duration(milliseconds: 200));
    await $.pumpAndSettle();

    // Back in the places sheet — child is gone, world remains.
    expect($('Eastern Kingdoms'), findsNothing);
    expect($('Azeroth'), findsWidgets);

    final remaining = await service.getLocations();
    expect(remaining, hasLength(1));
    expect(remaining.single.id, worldId);
  });
}

void _setMobileSurface(PatrolIntegrationTester $, Size size) {
  $.tester.view.devicePixelRatio = 1.0;
  $.tester.view.physicalSize = size;
  addTearDown(() {
    $.tester.view.resetPhysicalSize();
    $.tester.view.resetDevicePixelRatio();
  });
}

class _MobileMapsHarness extends StatefulWidget {
  const _MobileMapsHarness({required this.db});

  final NovelContentDatabase db;

  @override
  State<_MobileMapsHarness> createState() => _MobileMapsHarnessState();
}

class _MobileMapsHarnessState extends State<_MobileMapsHarness> {
  // 用 navigatorKey 而非 build 时的 context 来 push —— onCreate 复刻
  // novel_editor_page 的 createWorld，必须用 MaterialApp 之下的 Navigator，
  // 否则 Navigator.of(buildContext) 找不到 Navigator（buildContext 在 MaterialApp 之上）。
  final _navigatorKey = GlobalKey<NavigatorState>();

  Future<void> _onCreate() async {
    final service = LocationsService(widget.db);
    final id = await service.createLocation(
      name: 'New world',
      type: locationTypeWorld,
      parentId: null,
    );
    final created = await service.getLocationById(id);
    final navigator = _navigatorKey.currentState;
    if (navigator == null || created == null) {
      return;
    }
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => MobileLocationEditorPage(
          novelId: 'novel-test',
          databasePath: _testDatabasePath,
          locationId: created.id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'assets/translations',
      assetLoader: const MergingAssetLoader(),
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      child: ProviderScope(
        overrides: [
          novelContentDatabaseProvider(
            _testDatabasePath,
          ).overrideWithValue(widget.db),
          editorFontFamilyProvider.overrideWithValue('Georgia'),
          editorFontSizeProvider.overrideWithValue(16),
          editorLetterSpacingProvider.overrideWithValue(0.0),
          editorLineHeightProvider.overrideWithValue(1.8),
        ],
        child: Builder(
          builder: (context) {
            return MaterialApp(
              navigatorKey: _navigatorKey,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              theme: RevericThemeData.reveric.toThemeData(),
              // 经 builder 提供 RevericTheme，让 push 出来的子页面（地点编辑页）
              // 也能拿到 theme —— 真实 app（main.dart）即用 MaterialApp.builder 注入；
              // 放 home 里会让 Navigator 之上的 pushed route 取不到 RevericTheme 触发 assert。
              builder: (context, child) =>
                  RevericTheme(data: RevericThemeData.reveric, child: child!),
              home: Scaffold(
                body: MobileMapsPanel(
                  novelId: 'novel-test',
                  databasePath: _testDatabasePath,
                  onCreate: _onCreate,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

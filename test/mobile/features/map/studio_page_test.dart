// 职责: 验证移动端地图工作台 — 待生成空画布、制图师抽屉、地点抽屉选中与进入子地图、
//       返回键逐层退回、Agent 草案到达自动拉起制图师抽屉、出图中换成进度条并拦截返回。
// 关联文件:
//   lib/mobile/features/map/studio_page.dart
//   lib/mobile/features/map/bottom_bar.dart
//   lib/mobile/features/map/place_card.dart
//   lib/mobile/features/map/designer_sheet.dart
//   lib/mobile/features/map/places_sheet.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/map_editor.json
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/i18n.md
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/mobile/features/map/studio_page.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/map_agent.dart';
import 'package:reveric/shared/providers/map_agent_providers.dart';
import 'package:reveric/shared/providers/map_studio_controller.dart';
import 'package:reveric/shared/providers/map_studio_providers.dart'
    show MapStudioImageModelSelection, mapStudioImageModelSelectionProvider;
import 'package:reveric/shared/providers/maps_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/map/map_generate_fields.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _db = 'mobile-map';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  // 同一文件里第二个 testWidgets 重包 EasyLocalization 会拿到空子树，全部状态放在一个用例里连续 pump。
  testWidgets('pending canvas, sheets, sub-map navigation and generating', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final maps = StreamController<List<NovelMap>>.broadcast();
    final locations = StreamController<List<Location>>.broadcast();
    addTearDown(maps.close);
    addTearDown(locations.close);
    final container = ProviderContainer(
      overrides: [
        aiSettingsProvider.overrideWithValue(AiSettings(providers: const [])),
        mapStudioImageModelSelectionProvider.overrideWithValue(
          MapStudioImageModelSelection(
            config: _imageProvider,
            model: 'image-model',
          ),
        ),
        mapsProvider(_db).overrideWith((ref) => maps.stream),
        locationsProvider(_db).overrideWith((ref) => locations.stream),
        mapLocationsProvider(
          databasePath: _db,
          mapId: 'map_world',
        ).overrideWith((ref) => Stream.value(const <MapLocation>[])),
        mapStudioControllerProvider(_db, 'map_world').overrideWithValue(
          const MapStudioState(
            phase: MapStudioPhase.generating,
            stageIndex: 1,
            totalImageCalls: 1,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final world = _location(id: 'world', name: 'Jiangnan');
    final suzhou = _location(
      id: 'suzhou',
      name: 'Suzhou',
      type: locationTypeCity,
      parentId: 'world',
    );
    final gate = _location(
      id: 'gate',
      name: 'Changmen',
      type: locationTypeLandmark,
      parentId: 'suzhou',
    );

    await tester.pumpWidget(
      _wrap(
        container: container,
        child: Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const ValueKey('open_studio'),
              onPressed: () => openMobileMapStudioPage(
                context,
                novelId: 'novel',
                databasePath: _db,
                worldId: 'world',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open_studio')));
    await tester.pump();
    maps.add(const <NovelMap>[]);
    locations.add([world]);
    await tester.pumpAndSettle();

    // 世界还没有子地点：抽屉里的生成被拦下。抽屉开着时地点到位（如 Agent 刚建完），
    // 门禁要立刻放行 —— 抽屉不随页面重建，不能拿打开时的快照判断。
    const needsLocations = 'Add locations to this world before creating a map.';
    await tester.tap(find.byKey(const ValueKey('mobile_map_open_designer')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text(needsLocations),
      ),
      findsOneWidget,
    );
    locations.add([world, suzhou, gate]);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text(needsLocations),
      ),
      findsNothing,
    );
    await tester.tapAt(const Offset(195, 20));
    await tester.pumpAndSettle();

    // 待生成：空画布 + 制图师入口，没有历史、导出不可用。
    expect(
      find.byKey(const ValueKey('mobile_map_empty_canvas')),
      findsOneWidget,
    );
    expect(find.text('Jiangnan'), findsWidgets);
    expect(find.byKey(const ValueKey('mobile_map_history')), findsNothing);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('mobile_map_export')))
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);

    // 制图师抽屉：共享参数字段，触屏布局。
    await tester.tap(find.byKey(const ValueKey('mobile_map_open_designer')));
    await tester.pumpAndSettle();
    final fields = tester.widget<MapGenerateFields>(
      find.byType(MapGenerateFields),
    );
    expect(fields.touchTargets, isTrue);
    expect(fields.showTarget, isFalse);
    expect(
      find.byKey(const ValueKey('map_studio_prompt_field')),
      findsOneWidget,
    );
    // 改一下画风，关掉抽屉再打开，选中态还在（参数归页面所有）。
    await tester.tap(find.byKey(const ValueKey('map_studio_style_inkmap')));
    await tester.pump();
    await tester.tapAt(const Offset(195, 20));
    await tester.pumpAndSettle();
    expect(find.byType(MapGenerateFields), findsNothing);
    await tester.tap(find.byKey(const ValueKey('mobile_map_open_designer')));
    await tester.pumpAndSettle();
    final inkmapText = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('map_studio_style_inkmap')),
        matching: find.byType(Text),
      ),
    );
    expect(inkmapText.style?.color, RevericThemeData.reveric.colors.accent);
    await tester.tapAt(const Offset(195, 20));
    await tester.pumpAndSettle();

    // 地点抽屉：点 Suzhou → 关抽屉、画布出浮卡，Suzhou 有下级但还没地图 →「New map」。
    await tester.tap(find.byKey(const ValueKey('mobile_map_places')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Suzhou'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile_map_place_card')), findsOneWidget);
    expect(find.text('New map'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mobile_map_place_enter')));
    await tester.pumpAndSettle();
    // 面包屑：上层 Jiangnan 可点回，当前是 Suzhou。
    expect(
      find.byKey(const ValueKey('mobile_map_trail_world')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('mobile_map_place_card')), findsNothing);

    // 返回键先退回上层地图，页面不关。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile_map_trail_world')), findsNothing);
    expect(
      find.byKey(const ValueKey('mobile_map_empty_canvas')),
      findsOneWidget,
    );

    // 「让 Agent 设计」在制图师抽屉的提示词标题行里。
    await tester.tap(find.byKey(const ValueKey('mobile_map_open_designer')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('map_ask_agent')), findsOneWidget);
    await tester.tapAt(const Offset(195, 20));
    await tester.pumpAndSettle();

    // 停在工作台上时 Agent 草案一到，制图师抽屉自动拉起，草案卡在最上面；应用后回填提示词。
    container
        .read(mapDesignDraftsProvider.notifier)
        .submit(
          databasePath: _db,
          draft: const MapDesignDraft(
            worldId: 'world',
            prompt: 'Agent-authored map prompt',
          ),
        );
    await tester.pumpAndSettle();
    expect(find.byType(MapGenerateFields), findsOneWidget);
    expect(find.byKey(const ValueKey('map_agent_draft_card')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('map_agent_draft_apply')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('map_agent_draft_card')), findsNothing);
    expect(find.text('Agent-authored map prompt'), findsOneWidget);
    await tester.tapAt(const Offset(195, 20));
    await tester.pumpAndSettle();

    // world 有了 Map 记录且 controller 在出图：底栏换成四段进度，返回被拦下。
    maps.add([_map(id: 'map_world', locationId: 'world')]);
    mapGenerationActivityCounter.value++;
    addTearDown(() => mapGenerationActivityCounter.value = 0);
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('mobile_map_generating_progress')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('mobile_map_generating_canvas')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('mobile_map_open_designer')),
      findsNothing,
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump();
    expect(find.byType(MobileMapStudioPage), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);

    mapGenerationActivityCounter.value = 0;
    // 进度条是无限动画，收尾前先把页面换掉，免得残留 ticker。
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

final _imageProvider = AiProvider(
  audioModels: const [],
  videoModels: const [],
  id: 'external',
  name: 'External image provider',
  builtin: false,
  type: 'openai',
  enabled: true,
  apiKey: 'test-api-key',
  baseUrl: 'https://example.invalid/v1',
  models: const [],
  imageModels: const ['image-model'],
  embeddingModels: const [],
  temperature: 0.7,
  maxTurns: 8,
  proxyUrl: '',
  proxyUsername: '',
  proxyPassword: '',
  updatedAt: DateTime(2026, 1, 1),
  deletedAt: notDeletedSentinel,
);

Location _location({
  required String id,
  required String name,
  String type = locationTypeWorld,
  String? parentId,
}) {
  final now = DateTime(2026);
  return Location(
    id: id,
    name: name,
    description: '',
    type: type,
    parentId: parentId,
    tags: '',
    status: locationStatusActive,
    sortOrder: 0,
    createdAt: now,
    updatedAt: now,
    deletedAt: notDeletedSentinel,
  );
}

NovelMap _map({required String id, required String locationId}) {
  final now = DateTime(2026);
  return NovelMap(
    id: id,
    name: 'World map',
    description: '',
    type: mapTypeWorld,
    locationId: locationId,
    width: 1280,
    height: 720,
    sortOrder: 0,
    createdAt: now,
    updatedAt: now,
    deletedAt: notDeletedSentinel,
  );
}

Widget _wrap({required ProviderContainer container, required Widget child}) {
  return UncontrolledProviderScope(
    container: container,
    child: EasyLocalization(
      key: UniqueKey(),
      supportedLocales: const [Locale('en')],
      path: 'assets/translations',
      assetLoader: const MergingAssetLoader(),
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      child: Builder(
        builder: (context) {
          return MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData(),
            builder: (context, child) => RevericTheme(
              data: RevericThemeData.reveric,
              child: child ?? const SizedBox.shrink(),
            ),
            home: Scaffold(body: child),
          );
        },
      ),
    ),
  );
}

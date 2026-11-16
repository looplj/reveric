// 职责: 验证桌面制图师生成选项、AI 提议门禁与本地化展示。
// 关联文件:
//   lib/desktop/features/map/map_cartographer_panel.dart
//   lib/shared/models/map_studio_models.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/map_editor.json
//   assets/translations/zh-CN/map_editor.json
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/i18n.md

import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/map/map_cartographer_panel.dart';
import 'package:reveric/shared/models/map_studio_models.dart';
import 'package:reveric/shared/providers/map_studio_providers.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/map_agent.dart';
import 'package:reveric/shared/providers/map_agent_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('AI proposal blocks generation until applied or dismissed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_wrap(const _CartographerFixture()));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MapCartographerPanel)),
    );
    final drafts = container.read(mapDesignDraftsProvider.notifier);
    final button = find.widgetWithText(FilledButton, 'Start creating');
    const hint = 'Apply or dismiss the AI proposal before creating a map.';

    drafts.submit(
      databasePath: 'map-test',
      draft: const MapDesignDraft(worldId: 'other-world', prompt: 'Other map'),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);

    for (final action in ['apply', 'dismiss']) {
      drafts.submit(
        databasePath: 'map-test',
        draft: const MapDesignDraft(worldId: 'world-1', prompt: 'AI map plan'),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(find.text(hint), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('map_agent_draft_$action')));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      expect(find.text(hint), findsNothing);
      expect(
        container.read(
          mapDesignDraftProvider(databasePath: 'map-test', worldId: 'world-1'),
        ),
        isNull,
      );
    }
  });

  testWidgets('empty world blocks generation and explains on hover', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _wrap(const _CartographerFixture(hasChildren: false)),
    );
    await tester.pumpAndSettle();
    final button = find.widgetWithText(FilledButton, 'Start creating');
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(button));
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.text('Add locations to this world before creating a map.'),
      findsOneWidget,
    );
    await mouse.removePointer();
  });

  testWidgets('generation options start safe and use localized labels', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_wrap(const _CartographerFixture()));
    await tester.pumpAndSettle();

    final toggle = find.byKey(
      const ValueKey('map_studio_reference_current_image_toggle'),
    );
    expect(toggle, findsOneWidget);
    expect(
      find.descendant(of: toggle, matching: find.byType(RevericIcon)),
      findsNothing,
    );
    expect(find.text('Hand-drawn parchment'), findsOneWidget);
    expect(find.text('Ink map'), findsOneWidget);
    expect(find.text('Watercolor storybook'), findsOneWidget);
    expect(find.text('Clean atlas'), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);
    expect(find.text('手绘羊皮纸'), findsNothing);
    final cartographerScrollable = find
        .descendant(
          of: find.byType(MapCartographerPanel),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('map_studio_prompt_field')),
      200,
      scrollable: cartographerScrollable,
    );
    final promptEditor = find.descendant(
      of: find.byKey(const ValueKey('map_studio_prompt_field')),
      matching: find.byType(EditableText),
    );
    expect(
      tester.widget<EditableText>(promptEditor).controller.text,
      startsWith('绘制一张地图。'),
    );
    expect(
      tester.widget<EditableText>(promptEditor).controller.text,
      isNot(contains('手绘羊皮纸')),
    );

    await tester.drag(cartographerScrollable, const Offset(0, 1000));
    await tester.pumpAndSettle();
    final parchmentStyle = find.byKey(
      const ValueKey('map_studio_style_parchment'),
    );
    await tester.tap(parchmentStyle.hitTestable());
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('map_studio_prompt_field')),
      200,
      scrollable: cartographerScrollable,
    );
    expect(
      tester.widget<EditableText>(promptEditor).controller.text,
      startsWith('绘制一张地图。'),
    );
    expect(
      tester.widget<EditableText>(promptEditor).controller.text,
      isNot(contains('手绘羊皮纸')),
    );

    await tester.drag(cartographerScrollable, const Offset(0, 1000));
    await tester.pumpAndSettle();
    await tester.tap(toggle.hitTestable());
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: toggle, matching: find.byType(RevericIcon)),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('map_studio_prompt_field')),
      200,
      scrollable: cartographerScrollable,
    );
    expect(
      tester.widget<EditableText>(promptEditor).controller.text,
      contains('image 1'),
    );

    await tester.drag(cartographerScrollable, const Offset(0, 1000));
    await tester.pumpAndSettle();
    await tester.tap(toggle.hitTestable());
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: toggle, matching: find.byType(RevericIcon)),
      findsNothing,
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('map_studio_prompt_field')),
      200,
      scrollable: cartographerScrollable,
    );
    expect(
      tester.widget<EditableText>(promptEditor).controller.text,
      isNot(contains('image 1')),
    );

    await tester.enterText(promptEditor, '用户修改后的地图要求');
    await tester.drag(cartographerScrollable, const Offset(0, 1000));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('map_studio_style_inkmap')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('map_studio_style_inkmap')).hitTestable(),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('map_studio_prompt_field')),
      200,
      scrollable: cartographerScrollable,
    );
    expect(
      tester.widget<EditableText>(promptEditor).controller.text,
      '用户修改后的地图要求',
    );

    await tester.drag(cartographerScrollable, const Offset(0, 1000));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('map_studio_style_custom')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('map_studio_style_custom')).hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('map_studio_custom_style_field')),
      findsOneWidget,
    );
    await tester.tap(find.text('Start creating'));
    await tester.pump();
    expect(find.text('Describe a custom map style first'), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('map_studio_custom_style_field')),
        matching: find.byType(EditableText),
      ),
      '低多边形复古航海图',
    );
    await tester.pump();
    expect(find.text('Describe a custom map style first'), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('map_studio_prompt_field')),
      200,
      scrollable: cartographerScrollable,
    );
    expect(
      tester.widget<EditableText>(promptEditor).controller.text,
      '用户修改后的地图要求',
    );
  });
}

class _CartographerFixture extends StatelessWidget {
  const _CartographerFixture({this.hasChildren = true});

  final bool hasChildren;

  @override
  Widget build(BuildContext context) {
    final now = DateTime(2026);
    return SizedBox(
      width: 300,
      height: 800,
      child: MapCartographerPanel(
        novelId: 'novel-test',
        databasePath: 'map-test',
        map: NovelMap(
          id: 'map-1',
          name: 'World map',
          description: '',
          type: mapTypeWorld,
          locationId: 'world-1',
          width: 1280,
          height: 720,
          sortOrder: 0,
          createdAt: now,
          updatedAt: now,
          deletedAt: notDeletedSentinel,
        ),
        settings: const MapStudioSettings(image: 'images/maps/map-1.webp'),
        locations: [
          if (hasChildren)
            Location(
              id: 'city-1',
              name: 'City',
              description: '',
              type: locationTypeCity,
              parentId: 'world-1',
              tags: '',
              status: locationStatusActive,
              sortOrder: 0,
              createdAt: now,
              updatedAt: now,
              deletedAt: notDeletedSentinel,
            ),
          Location(
            id: 'world-1',
            name: 'World',
            description: '',
            type: locationTypeWorld,
            tags: '',
            status: locationStatusActive,
            sortOrder: 0,
            createdAt: now,
            updatedAt: now,
            deletedAt: notDeletedSentinel,
          ),
        ],
        selectedLocationId: null,
        mappedLocationIds: const {'world-1'},
        onSelectionChanged: (_) {},
        onEnterMap: (_) {},
        onClose: () {},
      ),
    );
  }
}

Widget _wrap(Widget child) {
  return ProviderScope(
    overrides: [
      aiSettingsProvider.overrideWithValue(AiSettings(providers: const [])),
      mapStudioImageModelSelectionProvider.overrideWithValue(
        MapStudioImageModelSelection(
          config: aiProviderBuiltinById(
            'openai',
          )!.copyWith(apiKey: 'test-key', enabled: true),
          model: 'gpt-image-2',
        ),
      ),
    ],
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
            home: RevericTheme(
              data: RevericThemeData.reveric,
              child: Scaffold(body: child),
            ),
          );
        },
      ),
    ),
  );
}

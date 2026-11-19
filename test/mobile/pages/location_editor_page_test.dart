// 职责: 验证移动地点编辑失败时保留草稿并拦截退出，成功后冲刷并返回。
// 关联文件:
//   lib/mobile/pages/location_editor_page.dart
//   lib/shared/services/maps_service.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/map_editor.json
//   assets/translations/zh-CN/map_editor.json
// 遵循的 Rules:
//   .agents/rules/testing.md
import 'dart:async';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/mobile/pages/location_editor_page.dart';
import 'package:reveric/mobile/pages/location_editor_save.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/maps_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/maps_service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/md/reveric_markdown_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _path = 'mobile-location-edit-test';
void main() {
  late NovelContentDatabase db;
  late LocationsService service;
  late String id;
  final nav = GlobalKey<NavigatorState>();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() async {
    rootBundle.clear();
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    service = LocationsService(db);
    await service.createLocation(name: 'Taken', type: locationTypeWorld);
    id = await service.createLocation(
      name: 'Draft',
      description: 'Original',
      type: locationTypeWorld,
    );
  });
  tearDown(() => db.close());

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          novelContentDatabaseProvider(_path).overrideWithValue(db),
          locationsServiceProvider(_path).overrideWithValue(service),
          editorFontFamilyProvider.overrideWithValue('Georgia'),
          editorFontSizeProvider.overrideWithValue(16),
          editorLetterSpacingProvider.overrideWithValue(0),
          editorLineHeightProvider.overrideWithValue(1.8),
        ],
        child: EasyLocalization(
          supportedLocales: const [Locale('en')],
          path: 'assets/translations',
          assetLoader: const MergingAssetLoader(),
          fallbackLocale: const Locale('en'),
          startLocale: const Locale('en'),
          child: Builder(
            builder: (context) => MaterialApp(
              navigatorKey: nav,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              theme: RevericThemeData.reveric.toThemeData(),
              builder: (_, child) =>
                  RevericTheme(data: RevericThemeData.reveric, child: child!),
              home: const Scaffold(body: Text('Home')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => MobileLocationEditorPage(
          databasePath: _path,
          novelId: 'work',
          locationId: id,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder nameField() => find.descendant(
    of: find.byKey(const ValueKey('mobile_location_name_field')),
    matching: find.byType(TextField),
  );

  test(
    'flush saves the latest draft after an older pending rename fails',
    () async {
      final saver = LocationEditorSaveController(
        service: service,
        locationId: id,
        initialValues: (
          name: 'Draft',
          description: 'Original',
          type: locationTypeWorld,
          parentId: null,
        ),
        savedAt: null,
      );
      addTearDown(saver.dispose);
      final entered = Completer<void>();
      final release = Completer<void>();
      final heldTransaction = db.transaction(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      saver.update((
        name: 'Taken',
        description: 'Older draft',
        type: locationTypeWorld,
        parentId: null,
      ));
      final saving = saver.flush();
      saver.update((
        name: 'Latest',
        description: 'Latest draft',
        type: locationTypeWorld,
        parentId: null,
      ));
      release.complete();
      await heldTransaction;
      expect(await saving, isTrue);
      final saved = (await service.getLocationById(id))!;
      expect(saved.name, 'Latest');
      expect(saved.description, 'Latest draft');
      expect(saver.isDirty, isFalse);
      expect(saver.failure, isNull);
    },
  );

  testWidgets('duplicate draft blocks header and system back until corrected', (
    tester,
  ) async {
    await mount(tester);
    await tester.enterText(nameField(), 'Taken');
    tester
            .widget<RevericMarkdownEditor>(find.byType(RevericMarkdownEditor))
            .controller
            .text =
        'Unsaved description';
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();
    expect(
      find.text('A location with this name already exists.'),
      findsOneWidget,
    );
    expect((await service.getLocationById(id))!.description, 'Original');
    await tester.tap(find.byKey(const ValueKey('mobile_location_back_button')));
    await tester.pumpAndSettle();
    expect(find.byType(MobileLocationEditorPage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(MobileLocationEditorPage), findsOneWidget);
    expect(tester.widget<TextField>(nameField()).controller!.text, 'Taken');
    await tester.enterText(nameField(), 'Unique');
    await tester.tap(find.byKey(const ValueKey('mobile_location_back_button')));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    final saved = (await service.getLocationById(id))!;
    expect(saved.name, 'Unique');
    expect(saved.description, 'Unsaved description');
    expect(tester.takeException(), isNull);
  });
}

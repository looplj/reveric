// 职责: 验证双端场次属性表单的保存、校验、输入法和布局。
// 关联文件:
//   lib/shared/widgets/screenplay/scene_properties_form.dart
//   lib/shared/widgets/screenplay/document_session.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'dart:io';
import 'dart:ui' as ui;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/screenplay/document_session.dart';
import 'package:reveric/shared/widgets/screenplay/scene_properties_form.dart';
import 'package:reveric/shared/widgets/screenplay/time_field.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    if (Platform.environment['SCENE_SCREENSHOTS'] != null) {
      for (final family in ['Roboto', 'Georgia', 'Menlo', 'Ahem']) {
        final font = FontLoader(family)
          ..addFont(rootBundle.load('assets/fonts/LXGWWenKai-Regular.ttf'));
        await font.load();
      }
    }
  });
  testWidgets('scene properties save on desktop and remain editable at 375px', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 980);
    addTearDown(tester.view.reset);
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    final app = AppDatabase.forTest(NativeDatabase.memory());
    final service = ScreenplayService(db);
    final initial = await service.createInitialStructure();
    final root = (await db.screenplayDao.getRoot())!;
    final legacyBeat = await service.createBeat(
      screenplayId: root.id,
      episodeId: initial.episodeId,
      actNumber: 1,
      title: 'Legacy beat',
    );
    final id = await service.createScene(
      screenplayId: root.id,
      episodeId: initial.episodeId,
      beatId: legacyBeat,
      title: 'A chase through the gate',
      emotion: ['Tense', 'Alert', 'Urgent'],
      events: [
        {'title': 'An ambush', 'summary': 'A stranger blocks the gate.'},
      ],
    );
    final session = ScreenplayDocumentSession(
      await service.readDocument(initial.episodeId),
      database: db,
      service: service,
      overlay: WorkingOverlayService(
        db,
        NovelContentService(db),
        novelActionsService: NovelActionsService(app),
      ),
    );
    final boundary = GlobalKey();
    final home = Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => Dialog(
                insetPadding: const EdgeInsets.all(12),
                child: RepaintBoundary(
                  key: boundary,
                  child: SizedBox(
                    width: 640,
                    child: ScenePropertiesForm(
                      databasePath: 'scene-test',
                      sceneId: id,
                      session: session,
                    ),
                  ),
                ),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          novelContentDatabaseProvider('scene-test').overrideWithValue(db),
        ],
        child: EasyLocalization(
          supportedLocales: const [Locale('en')],
          path: 'assets/translations',
          assetLoader: const MergingAssetLoader(),
          startLocale: const Locale('en'),
          fallbackLocale: const Locale('en'),
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              theme: RevericThemeData.reveric.toThemeData(fontFamily: 'Roboto'),
              builder: (context, child) =>
                  RevericTheme(data: RevericThemeData.reveric, child: child!),
              home: home,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    // 标签已从 InputDecoration.labelText 移到字段上方的 section header，
    // 输入框本体只剩 hintText，所以按 HookedTextFormField.fieldKey 定位。
    Finder input(String key) => key == 'Time'
        ? find.descendant(
            of: find.byType(ScreenplayTimeField),
            matching: find.byType(TextField),
          )
        : find.byKey(ValueKey(key));
    await tester.enterText(input('scene_title_field'), 'The gate closes');
    await tester.tap(find.widgetWithText(ChoiceChip, 'INT./EXT.'));
    await tester.pumpAndSettle();
    await tester.tap(input('Time'));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '早',
        composing: TextRange(start: 0, end: 1),
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pump();
    expect(tester.widget<TextField>(input('Time')).focusNode!.hasFocus, true);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '早晨',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    expect(tester.widget<TextField>(input('Time')).focusNode!.hasFocus, true);
    tester.testTextInput.hide();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    if (Platform.environment['SCENE_SCREENSHOTS'] != null) {
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '/tmp/scene-properties-desktop.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    tester.view.physicalSize = const Size(375, 844);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (Platform.environment['SCENE_SCREENSHOTS'] != null) {
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '/tmp/scene-properties-mobile.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final saved = (await db.screenplayDao.getScene(id))!;
    expect(saved.beatId, legacyBeat);
    expect(await db.screenplayDao.getBeat(legacyBeat), isNotNull);
    expect(saved.title, 'The gate closes');
    expect(saved.interiorExterior, 'interior_exterior');
    expect(saved.timeLabel, '早晨');
    expect(saved.emotion, ['Tense', 'Alert', 'Urgent']);
    expect(saved.events!.single['title'], 'An ambush');
    expect(find.text('Open'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    session.dispose();
    await db.close();
    await app.close();
  });
}

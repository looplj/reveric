// 职责: 验证分镜表单完整滚动、未保存关闭保护与持久化，并输出界面截图。
// 关联文件:
//   lib/desktop/features/storyboard/edit_form.dart
//   lib/shared/services/storyboard/service.dart
import 'dart:io';
import 'dart:ui' as ui;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/storyboard/edit_form.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/storyboard.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    for (final family in ['Roboto', 'Georgia', 'Menlo', 'Ahem']) {
      await (FontLoader(family)
            ..addFont(rootBundle.load('assets/fonts/LXGWWenKai-Regular.ttf')))
          .load();
    }
  });
  testWidgets('form saves after scrolling and protects unsaved edits', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 900);
    addTearDown(tester.view.reset);
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    final app = AppDatabase.forTest(NativeDatabase.memory());
    final initial = await ScreenplayService(db).createInitialStructure();
    final scene = await ScreenplayService(db).createScene(
      screenplayId: (await db.screenplayDao.getRoot())!.id,
      episodeId: initial.episodeId,
    );
    final service = StoryboardService(db);
    final shot = await service.create(
      scene,
      values: {'title': '雨夜归人', 'prompt': '夜雨落在青石阶上，女子停在门口。缓慢推进，保持人物正面中景。'},
    );
    final overlay = WorkingOverlayService(
      db,
      NovelContentService(db),
      novelActionsService: NovelActionsService(app),
    );
    final boundary = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(app),
          storyboardServiceProvider(
            'test',
            novelId: 'work',
          ).overrideWithValue(service),
          workingOverlayServiceProvider('test').overrideWithValue(overlay),
        ],
        child: EasyLocalization(
          supportedLocales: const [Locale('en')],
          path: 'assets/translations',
          assetLoader: const MergingAssetLoader(),
          startLocale: const Locale('en'),
          fallbackLocale: const Locale('en'),
          child: Builder(
            builder: (context) => RevericTheme(
              data: RevericThemeData.reveric,
              child: MaterialApp(
                theme: RevericThemeData.reveric.toThemeData(
                  fontFamily: 'Roboto',
                ),
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                home: Scaffold(
                  body: Builder(
                    builder: (ctx) => TextButton(
                      onPressed: () => showDialog<void>(
                        context: ctx,
                        barrierDismissible: false,
                        builder: (_) => RepaintBoundary(
                          key: boundary,
                          child: ShotEditForm(
                            novelId: 'work',
                            path: 'test',
                            sceneId: scene,
                            shot: shot,
                          ),
                        ),
                      ),
                      child: const Text('Open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final title = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Title',
    );
    // Labels live outside the input in RevericTextField; the first input is the title.
    final titleInput = title.evaluate().isEmpty
        ? find.byType(TextField).first
        : title;
    await tester.enterText(titleInput, '门口的灯');
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final image =
          await (boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '/tmp/reveric-storyboard-form.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Save changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -1500),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsNWidgets(5));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect((await service.getShot(shot.id))!.title, '门口的灯');
    expect(find.text('Open'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await db.close();
    await app.close();
  }, timeout: const Timeout(Duration(minutes: 2)));
}

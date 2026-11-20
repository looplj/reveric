// 职责: 验证风格库弹层的边界适配、分类、搜索、选择与新建，以及风格 chip 的宽度与写回。
// 关联文件:
//   lib/desktop/features/production/style_picker.dart
//   lib/desktop/features/production/style_button.dart
//   lib/shared/models/production/style.dart
//   lib/shared/services/production/canvas_service.dart
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/production/popover.dart';
import 'package:reveric/desktop/features/production/style_button.dart';
import 'package:reveric/desktop/features/production/style_editor.dart';
import 'package:reveric/desktop/features/production/style_picker.dart';
import 'package:reveric/desktop/features/production/style_thumb.dart';
import 'package:reveric/shared/components/reveric_popover.dart';
import 'package:reveric/shared/components/reveric_search_field.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/production/style.dart';
import 'package:reveric/shared/providers/production_media.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/style_service.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/theme/theme.dart';
import '../../director/harness.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(initializeDirectorTest);

  late AppDatabase app;
  late NovelContentDatabase db;
  late ProductionStyleService styles;
  late MediaLibraryService library;
  late ProductionCanvasService service;

  Future<void> setUpServices(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    app = AppDatabase.forTest(NativeDatabase.memory());
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    addTearDown(app.close);
    addTearDown(db.close);
    styles = ProductionStyleService(app);
    library = MediaLibraryService(
      app,
      MediaService(FfmpegRunner()),
      Directory.systemTemp,
    );
    service = ProductionCanvasService(StoryboardService(db), library, 'work');
  }

  Widget wrap(Widget child) => ProviderScope(
    overrides: [
      productionStyleServiceProvider.overrideWithValue(styles),
      mediaLibraryServiceProvider.overrideWithValue(library),
    ],
    child: directorTestApp(child),
  );

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(
      find.descendant(
        of: find.byType(RevericSearchField),
        matching: find.byType(EditableText),
      ),
      query,
    );
    // First render starts the debounce; advance time after that frame.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'screenplay style chip hugs its content and writes presets and custom styles',
    (tester) async {
      await setUpServices(tester);
      await tester.runAsync(
        () => ScreenplayService(db).createInitialStructure(),
      );
      await tester.runAsync(
        () => styles.save(
          name: 'Warm film',
          prompt: ProductionStylePrompt(before: 'Warm', after: 'Film'),
        ),
      );
      Future<String?> stored() async =>
          (await tester.runAsync(() => db.screenplayDao.getRoot()))!.styleId;
      await tester.pumpWidget(
        wrap(
          Row(
            children: [
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Flexible(
                      child: ProductionScreenplayStyle(service: service),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 放进 Flexible 的 chip 只占内容宽度，不能被撑满整行。
      expect(tester.getSize(find.byType(ProductionPill)).width, lessThan(200));

      await tester.tap(find.text('No style'));
      await tester.pumpAndSettle();
      expect(find.byType(ProductionStylePicker), findsOneWidget);
      expect(find.text('Search styles'), findsOneWidget);
      expect(find.textContaining('Follow screenplay'), findsNothing);
      for (final label in ['All', 'Live action', '2D', '3D', 'Custom']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Custom style prompt'), findsOneWidget);
      await tester.tap(find.text('3D'));
      await tester.pumpAndSettle();
      expect(find.text('三维卡通动画'), findsOneWidget);
      expect(find.text('中式志怪电影感'), findsNothing);
      expect(find.text('Warm film'), findsNothing);
      expect(find.text('Custom style prompt'), findsNothing);
      // 无风格只在「全部」里出现。
      expect(
        find.descendant(
          of: find.byType(ProductionStylePicker),
          matching: find.text('No style'),
        ),
        findsNothing,
      );

      await tester.tap(find.text('2D'));
      await tester.pumpAndSettle();
      expect(find.text('黑白水墨动画'), findsOneWidget);
      expect(find.text('Warm film'), findsNothing);
      expect(find.text('Custom style prompt'), findsNothing);

      await tester.tap(find.text('Live action'));
      await tester.pumpAndSettle();
      expect(find.text('Warm film'), findsNothing);
      expect(find.text('Custom style prompt'), findsNothing);
      await tester.ensureVisible(find.text('中式志怪电影感'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('中式志怪电影感'));
      await tester.pumpAndSettle();
      expect(find.byType(ProductionStylePicker), findsNothing);
      expect(await stored(), 'preset:chinese-supernatural-film');
      expect(find.text('中式志怪电影感'), findsOneWidget);
      expect(
        tester
            .widget<ProductionStyleThumb>(find.byType(ProductionStyleThumb))
            .kind,
        ProductionStyleThumbKind.preset,
      );

      await tester.tap(find.text('中式志怪电影感'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(ProductionStylePicker),
          matching: find.text('No style'),
        ),
      );
      await tester.pumpAndSettle();
      expect(await stored(), isNull);
      expect(find.byTooltip('Clear screenplay style'), findsNothing);

      await tester.tap(find.text('No style'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();
      expect(find.text('Warm film'), findsOneWidget);
      expect(find.text('中式志怪电影感'), findsNothing);
      expect(find.text('Custom style prompt'), findsOneWidget);

      // 自定义风格悬停时出现编辑入口，打开的编辑器带着原有提示词。
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('Warm film')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      expect(find.byType(ProductionStyleEditor), findsOneWidget);
      expect(find.text('Warm'), findsOneWidget);
      // 编辑态独占弹层：分类栏和搜索框都不在。
      expect(
        find.descendant(
          of: find.byType(ProductionStyleEditor),
          matching: find.text('Edit'),
        ),
        findsOneWidget,
      );
      expect(find.text('All'), findsNothing);
      expect(find.byType(RevericSearchField), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // 有改动时返回要先确认放弃。
      await tester.tap(find.text('Custom style prompt'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(ProductionStyleEditor),
          matching: find.text('New'),
        ),
        findsOneWidget,
      );
      await tester.enterText(
        find
            .descendant(
              of: find.byType(ProductionStyleEditor),
              matching: find.byType(EditableText),
            )
            .first,
        'Draft',
      );
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Discard unsaved changes?'), findsOneWidget);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.byType(ProductionStyleEditor), findsNothing);

      await tester.tap(find.text('Custom style prompt'));
      await tester.pumpAndSettle();
      final inputs = find.descendant(
        of: find.byType(ProductionStyleEditor),
        matching: find.byType(EditableText),
      );
      await tester.enterText(inputs.at(0), 'My style');
      await tester.enterText(inputs.at(1), 'Before');
      await tester.enterText(inputs.at(2), 'After');
      await tester.tap(find.text('Save'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ProductionStyleEditor), findsNothing);
      final row = (await tester.runAsync(
        () => app.select(app.productionStyles).get(),
      ))!.singleWhere((row) => row.name == 'My style');
      expect(row.before, 'Before');
      expect(row.after, 'After');

      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      await search(tester, '志怪');
      expect(find.text('中式志怪电影感'), findsOneWidget);
      expect(find.text('My style'), findsNothing);
      await search(tester, 'My style');
      expect(find.text('中式志怪电影感'), findsNothing);
      await tester.tap(
        find.descendant(of: find.byType(Wrap), matching: find.text('My style')),
      );
      await tester.pumpAndSettle();
      expect(await stored(), row.id);
      expect(find.text('My style'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'style popover stays inside the window at edges and follows its anchor',
    (tester) async {
      await setUpServices(tester);
      final anchor = ValueNotifier(const Offset(1080, 760));
      addTearDown(anchor.dispose);
      await tester.pumpWidget(
        wrap(
          ValueListenableBuilder<Offset>(
            valueListenable: anchor,
            builder: (context, position, _) => Stack(
              children: [
                Positioned(
                  left: position.dx,
                  top: position.dy,
                  child: RevericPopover(
                    up: true,
                    trigger: (_, open, toggle) => TextButton(
                      onPressed: toggle,
                      child: const Text('Style'),
                    ),
                    panel: (_, close) => ProductionStylePicker(
                      service: service,
                      value: const NoProductionStyle(),
                      onPick: (_) => close(),
                      onClose: close,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Style'));
      await tester.pumpAndSettle();

      Rect panelRect() => tester.getRect(find.byType(ProductionPopoverPanel));
      void expectInside(Size window) {
        final rect = panelRect();
        expect(rect.left, greaterThanOrEqualTo(RevericSpacing.sm));
        expect(rect.top, greaterThanOrEqualTo(RevericSpacing.sm));
        expect(rect.right, lessThanOrEqualTo(window.width - RevericSpacing.sm));
        expect(
          rect.bottom,
          lessThanOrEqualTo(window.height - RevericSpacing.sm),
        );
        expect(tester.takeException(), isNull);
      }

      expectInside(const Size(1200, 900));
      expect(panelRect().width, RevericSizes.productionStylePickerWidth);
      expect(panelRect().bottom, lessThan(anchor.value.dy));
      // 上方不足时翻到下方；打开期间移动锚点无需重新开关。
      anchor.value = const Offset(20, 20);
      await tester.pumpAndSettle();
      expectInside(const Size(1200, 900));
      expect(
        panelRect().top,
        greaterThan(tester.getRect(find.byType(TextButton)).bottom),
      );
      // 上下都放不下时移回窗口，窄窗口同时约束面板宽度与网格列数。
      tester.view.physicalSize = const Size(560, 400);
      anchor.value = const Offset(450, 180);
      await tester.pumpAndSettle();
      expectInside(const Size(560, 400));
      expect(
        panelRect().width,
        lessThan(RevericSizes.productionStylePickerWidth),
      );
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(ProductionStylePicker), findsNothing);
      await tester.tap(find.text('Style'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(find.byType(ProductionStylePicker), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'node picker leads with follow-episode and marks the current choice',
    (tester) async {
      await setUpServices(tester);
      final preset = productionStylePreset('premium-costume-drama')!;
      final picked = <ProductionStyleChoice>[];
      await tester.pumpWidget(
        wrap(
          Align(
            alignment: Alignment.topLeft,
            child: ProductionStylePicker(
              service: service,
              value: PresetProductionStyle(preset.id),
              screenplay: (
                label: 'Screenplay look',
                kind: ProductionStyleThumbKind.none,
                seed: '',
              ),
              onPick: picked.add,
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('古装偶像剧'), findsOneWidget);
      expect(find.text('古偶唯美柔光'), findsNothing);
      expect(find.text('3D光泽乳胶渲染风格'), findsNothing);
      expect(
        find.text('Follow screenplay · Screenplay look', findRichText: true),
        findsOneWidget,
      );
      final checks = find.byWidgetPredicate(
        (w) => w is RevericIcon && w.assetPath == RevericIcons.check,
      );
      expect(checks, findsOneWidget);
      // 对勾落在当前选中的预设卡片上。
      final card = find
          .ancestor(
            of: find.text(preset.name),
            matching: find.byType(GestureDetector),
          )
          .first;
      expect(find.descendant(of: card, matching: checks), findsOneWidget);
      await tester.tap(
        find.text('Follow screenplay · Screenplay look', findRichText: true),
      );
      await tester.tap(find.text('No style'));
      await tester.tap(find.text(builtinProductionStyles[1].name));
      await tester.pumpAndSettle();
      expect(picked, [
        isA<InheritedProductionStyle>(),
        isA<NoProductionStyle>(),
        isA<PresetProductionStyle>().having(
          (p) => p.presetId,
          'presetId',
          builtinProductionStyles[1].id,
        ),
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

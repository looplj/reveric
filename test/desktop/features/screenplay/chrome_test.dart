// 职责: 验证浮动工具条在窄面板下保留导航、展开工具并保持内容起点。
// 关联文件:
//   lib/desktop/features/screenplay/chrome.dart
//   lib/shared/components/reveric_popover.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
import 'dart:io';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/screenplay/chrome.dart';
import 'package:reveric/shared/components/reveric_icon_button.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/app_background.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    for (final family in ['Roboto', 'Georgia', 'Ahem']) {
      await (FontLoader(family)
            ..addFont(rootBundle.load('assets/fonts/LXGWWenKai-Regular.ttf')))
          .load();
    }
  });
  testWidgets(
    'narrow floating tools remain reachable without moving content',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 600);
      addTearDown(tester.view.reset);
      final width = ValueNotifier<double>(417);
      addTearDown(width.dispose);
      var exports = 0;
      final boundary = GlobalKey();
      const contentKey = ValueKey('content');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appBackgroundActiveProvider.overrideWithValue(false)],
          child: EasyLocalization(
            supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
            path: 'assets/translations',
            assetLoader: const MergingAssetLoader(),
            fallbackLocale: const Locale('en'),
            startLocale: const Locale('en'),
            child: Builder(
              builder: (context) => MaterialApp(
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                theme: RevericThemeData.reveric.toThemeData(
                  fontFamily: 'Roboto',
                ),
                home: RevericTheme(
                  data: RevericThemeData.reveric,
                  child: Scaffold(
                    body: ValueListenableBuilder<double>(
                      valueListenable: width,
                      builder: (context, value, _) => RepaintBoundary(
                        key: boundary,
                        child: SizedBox(
                          width: value,
                          child: Column(
                            children: [
                              ScreenplayRegionToolbar(
                                floating: true,
                                leading: const SizedBox(
                                  width: 220,
                                  child: Text('Storyboard  Canvas  List'),
                                ),
                                trailing: [
                                  const Flexible(
                                    child: Text(
                                      'Long screenplay style name',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(
                                    width: 150,
                                    child: Text('16:9 · 480P'),
                                  ),
                                  RevericIconButton(
                                    icon: RevericIcons.download,
                                    tooltip: 'Export',
                                    onPressed: () => exports++,
                                  ),
                                  RevericIconButton(
                                    icon: RevericIcons.scissors_outlined,
                                    tooltip: 'Editing',
                                    onPressed: () {},
                                  ),
                                ],
                              ),
                              const SizedBox(key: contentKey, height: 100),
                            ],
                          ),
                        ),
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
      expect(tester.takeException(), isNull);
      final contentTop = tester.getTopLeft(find.byKey(contentKey)).dy;
      expect(contentTop, ScreenplayRegionToolbar.floatingExtent);
      expect(find.text('Storyboard  Canvas  List'), findsOneWidget);
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('16:9 · 480P'), findsOneWidget);
      await tester.tap(find.byTooltip('Export'));
      await tester.pumpAndSettle();
      expect(exports, 1);
      await tester.tapAt(const Offset(900, 500));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Export'), findsNothing);
      for (final next in [360.0, 620.0, 900.0, 417.0]) {
        width.value = next;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getTopLeft(find.byKey(contentKey)).dy, contentTop);
      }
      // 弹层也必须遵守窗口宽度，不能仅在窄面板、宽窗口下成立。
      tester.view.physicalSize = const Size(417, 600);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Export').hitTestable(), findsOneWidget);
      await tester.tapAt(const Offset(10, 500));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(1000, 600);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '/tmp/reveric-toolbar-narrow.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      width.value = 900;
      await tester.pumpAndSettle();
      expect(find.byTooltip('More actions'), findsNothing);
      await tester.tap(find.byTooltip('Export'));
      expect(exports, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    timeout: const Timeout(Duration(minutes: 2)),
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    }),
  );
}

// 职责: 验证桌面页面标题不随 Windows 操作区避让下移，并保持按钮可点击。
// 关联文件:
//   lib/desktop/features/canvas/widgets/canvas_toolbar.dart
//   lib/desktop/widgets/desktop_window_frame.dart
//   lib/desktop/widgets/agent_management/home_management_cards.dart
//   lib/desktop/widgets/home/greeting_header.dart
// 遵循的 Rules:
//   .agents/rules/desktop-window-frame.md
import 'dart:io';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/desktop/features/canvas/widgets/canvas_toolbar.dart';
import 'package:reveric/desktop/widgets/agent_management/home_management_cards.dart';
import 'package:reveric/desktop/widgets/desktop_window_frame.dart';
import 'package:reveric/desktop/widgets/home/greeting_header.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/app_background.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _captureKey = GlobalKey();

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    if (const bool.fromEnvironment('HEADER_CAPTURE')) {
      final font = await rootBundle.load('assets/fonts/LXGWWenKai-Regular.ttf');
      for (final family in [
        'HeaderTest',
        'Georgia',
        'Menlo',
        'Ahem',
        'Roboto',
        '.SF UI Text',
        '.SF UI Display',
      ]) {
        await (FontLoader(family)..addFont(Future.value(font))).load();
      }
    }
  });

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    for (final kind in ['management', 'greeting']) {
      testWidgets(
        'Home $kind clears window buttons on ${platform.name}',
        (tester) async {
          addTearDown(() => tester.binding.setSurfaceSize(null));
          var taps = 0;
          final headerKey = GlobalKey();
          for (final width in [1100.0, 560.0]) {
            await tester.binding.setSurfaceSize(Size(width, 300));
            final header = switch (kind) {
              'management' => SizedBox(
                height: 200,
                child: HomeManagementScaffold(
                  headerGestureExclusionKey: headerKey,
                  headerTrailingInset: DesktopWindowFrame.trailingInset,
                  icon: RevericIcons.groups_outlined,
                  titleKey: LocaleKeys.commonSave,
                  createLabelKey: LocaleKeys.commonCreate,
                  onCreate: () => taps++,
                  child: const SizedBox(key: ValueKey('management_body')),
                ),
              ),
              _ => Padding(
                padding: const EdgeInsets.fromLTRB(40, 24, 40, 24),
                child: GreetingHeader(
                  onQuickStart: () {},
                  onCreateNovel: () => taps++,
                  createLabel: 'New Novel',
                  onImport: () {},
                  importLabel: 'Import TXT',
                  username: 'Writer',
                  featuredTitle: 'A very long novel title that keeps on going',
                  headerGestureExclusionKey: headerKey,
                ),
              ),
            };
            await tester.pumpWidget(_wrap(header));
            await tester.pumpAndSettle();
            final title = kind == 'management'
                ? find.text('Save')
                : find
                      .descendant(
                        of: find.byType(GreetingHeader),
                        matching: find.byType(Text),
                      )
                      .first;
            final action = kind == 'greeting'
                ? find
                      .byWidgetPredicate((widget) => widget is OutlinedButton)
                      .last
                : find.byWidgetPredicate((widget) => widget is FilledButton);
            if (kind == 'management') {
              expect(tester.getCenter(title).dy, closeTo(24, 1));
              expect(
                tester
                    .getTopLeft(find.byKey(const ValueKey('management_body')))
                    .dy,
                DesktopWindowFrame.titleBarHeight +
                    RevericSizes.dividerThickness,
              );
            } else {
              expect(tester.getTopLeft(title).dy, closeTo(24, 1));
              expect(tester.getRect(action).top, greaterThanOrEqualTo(48));
            }
            expect(tester.getRect(action).left, greaterThanOrEqualTo(0));
            expect(tester.getRect(action).right, lessThanOrEqualTo(width));
            if (platform != TargetPlatform.macOS) {
              final captionButtons = Rect.fromLTWH(
                width - DesktopWindowFrame.windowsCaptionButtonsWidth,
                0,
                DesktopWindowFrame.windowsCaptionButtonsWidth,
                DesktopWindowFrame.titleBarHeight,
              );
              expect(tester.getRect(action).overlaps(captionButtons), isFalse);
              expect(tester.getRect(title).overlaps(captionButtons), isFalse);
            }
            if (kind != 'management') {
              expect(
                tester.getTopLeft(find.byKey(const ValueKey('body'))).dy,
                greaterThanOrEqualTo(tester.getRect(action).bottom),
              );
            }
            await tester.tap(action);
            await tester.pumpAndSettle();
            expect(taps, width == 1100 ? 1 : 2);
            expect(tester.takeException(), isNull);
          }
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
    for (final kind in ['canvas']) {
      testWidgets(
        '$kind keeps its title at the top on ${platform.name}',
        (tester) async {
          addTearDown(() => tester.binding.setSurfaceSize(null));
          var taps = 0;
          void onTap() => taps++;
          final header = switch (kind) {
            _ => CanvasToolbar(
              canvasName: 'Canvas title',
              onClose: () {},
              onSave: onTap,
            ),
          };
          final title = find.text(switch (kind) {
            _ => 'Canvas title',
          });
          final action = kind == 'canvas'
              ? find.byKey(const ValueKey('canvas_toolbar_save_button'))
              : find.byTooltip('Refresh');
          for (final width in [1100.0, 560.0]) {
            await tester.binding.setSurfaceSize(Size(width, 300));
            await tester.pumpWidget(_wrap(header));
            await tester.pumpAndSettle();
            const titleCenter = DesktopWindowFrame.titleBarHeight / 2;
            final actionCenter =
                titleCenter +
                (platform == TargetPlatform.windows
                    ? DesktopWindowFrame.titleBarHeight
                    : 0);
            expect(tester.getCenter(title).dy, closeTo(titleCenter, 1));
            expect(tester.getCenter(action).dy, closeTo(actionCenter, 1));
            final headerBottom = actionCenter + titleCenter;
            expect(
              tester.getTopLeft(find.byKey(const ValueKey('body'))).dy,
              headerBottom,
            );
            if (platform == TargetPlatform.windows) {
              expect(
                tester.getRect(action).top,
                greaterThanOrEqualTo(DesktopWindowFrame.titleBarHeight),
              );
            }
            await tester.tap(action);
            await tester.pumpAndSettle();
            expect(taps, width == 1100 ? 1 : 2);
            expect(tester.takeException(), isNull);
            if (const bool.fromEnvironment('HEADER_CAPTURE')) {
              await tester.runAsync(() async {
                final boundary =
                    _captureKey.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary;
                final image = await boundary.toImage();
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await File(
                  '/tmp/header-$kind-${platform.name}-${width.toInt()}.png',
                ).writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }
          }
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
  }
}

Widget _wrap(Widget header) => ProviderScope(
  overrides: [appBackgroundActiveProvider.overrideWithValue(false)],
  child: EasyLocalization(
    supportedLocales: const [Locale('en')],
    startLocale: const Locale('en'),
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    child: Builder(
      builder: (context) => MaterialApp(
        localizationsDelegates: context.localizationDelegates,
        supportedLocales: context.supportedLocales,
        locale: context.locale,
        theme: RevericThemeData.reveric.toThemeData(
          fontFamily: const bool.fromEnvironment('HEADER_CAPTURE')
              ? 'HeaderTest'
              : null,
        ),
        home: RevericTheme(
          data: RevericThemeData.reveric,
          child: RepaintBoundary(
            key: _captureKey,
            child: Scaffold(
              body: Column(
                children: [
                  header,
                  const SizedBox(key: ValueKey('body'), height: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

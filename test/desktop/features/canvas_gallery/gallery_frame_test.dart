// 职责: 验证 GalleryFrame 在 macOS / Windows / Linux 下标题基线、窗口按钮避让与操作点击。
// 关联文件:
//   lib/desktop/features/canvas_gallery/gallery_frame.dart
//   lib/desktop/widgets/desktop_window_frame.dart
// 遵循的 Rules:
//   .agents/rules/desktop-window-frame.md
//   .agents/rules/testing.md

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/desktop/features/canvas_gallery/gallery_frame.dart';
import 'package:reveric/desktop/widgets/desktop_window_frame.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/app_background.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());

  for (final platform in const [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets(
      'keeps title on top baseline and clears caption buttons on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        tester.view.physicalSize = const Size(1100, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        try {
          var actionTapped = 0;
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                appBackgroundActiveProvider.overrideWithValue(false),
                appSettingsProvider.overrideWith(_StaticSettingsNotifier.new),
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
                      child: GalleryFrame(
                        title: 'Gallery Sample',
                        action: TextButton(
                          key: const ValueKey('gallery-action'),
                          onPressed: () => actionTapped++,
                          child: const Text('Refresh'),
                        ),
                        body: const Align(
                          alignment: Alignment.topLeft,
                          child: Text(
                            'Body Content',
                            key: ValueKey('gallery-body'),
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

          final titleRect = tester.getRect(find.text('Gallery Sample'));
          final actionRect = tester.getRect(
            find.byKey(const ValueKey('gallery-action')),
          );
          final bodyRect = tester.getRect(
            find.byKey(const ValueKey('gallery-body')),
          );

          // 页面标题始终留在顶部 titleBarHeight 内垂直居中，不被 Windows captionSafeTopInset 下推。
          expect(
            titleRect.center.dy,
            closeTo(DesktopWindowFrame.titleBarHeight / 2, 2.0),
          );

          if (platform == TargetPlatform.windows) {
            expect(
              actionRect.top,
              greaterThanOrEqualTo(DesktopWindowFrame.titleBarHeight),
            );
            expect(bodyRect.top, greaterThanOrEqualTo(actionRect.bottom));
          } else {
            expect(
              actionRect.center.dy,
              closeTo(DesktopWindowFrame.titleBarHeight / 2, 2.0),
            );
            expect(
              bodyRect.top,
              greaterThanOrEqualTo(DesktopWindowFrame.titleBarHeight),
            );
          }

          if (platform == TargetPlatform.linux) {
            expect(
              actionRect.right,
              lessThanOrEqualTo(
                1100 - DesktopWindowFrame.windowsCaptionButtonsWidth,
              ),
            );
          }

          await tester.tap(find.byKey(const ValueKey('gallery-action')));
          await tester.pumpAndSettle();
          expect(actionTapped, 1);

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
}

class _StaticSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => AppSettings(
    theme: AppTheme.reveric,
    themeMode: AppThemeMode.light,
    language: 'en',
    aiSettings: AiSettings.defaults(),
  );
}

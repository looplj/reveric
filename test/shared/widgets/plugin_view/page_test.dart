// 职责: 验证插件页面桌面标题基线、返回入口、窗口按钮避让和 Android 导航外壳。
// 关联文件:
//   lib/shared/widgets/plugin_view/page.dart
//   lib/desktop/widgets/desktop_window_frame.dart
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/desktop/widgets/desktop_window_frame.dart';
import 'package:reveric/shared/components/reveric_placeholder.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/models/plugin/view.dart';
import 'package:reveric/shared/providers/plugin_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/widgets/plugin_view/page.dart';
import 'input_test.dart' show wrap;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.android,
  ]) {
    for (final width in [360.0, 900.0]) {
      testWidgets(
        'plugin page frame ${platform.name} width $width',
        (tester) async {
          tester.view.resetPhysicalSize();
          tester.view.physicalSize = Size(width, 700);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final database = AppDatabase.forTest(NativeDatabase.memory());
          final host = PluginHostService(
            dao: database.pluginDao,
            registry: PluginRegistry(hostToolNames: {}),
            packages: () async => [],
          );
          addTearDown(() async {
            await host.dispose();
            await database.close();
          });
          final view = PluginView(
            PluginManifest.fromJson({
              'id': 'test.page',
              'name': 'Page',
              'version': '1.0.0',
              'pluginApiVersion': '^1',
              'main': 'index.js',
            }).id,
            {
              'id': 'page',
              'title': 'Plugin title',
              'location': 'home.plugin',
              'protocol': 'reveric-tsx-v1',
              'source': 'page.js',
            },
          );
          await tester.pumpWidget(
            wrap(
              ProviderScope(
                overrides: [
                  pluginHostServiceProvider.overrideWithValue(host),
                  appBackgroundImagePathProvider.overrideWithValue(''),
                  appBackgroundFitProvider.overrideWithValue(
                    AppBackgroundFit.cover,
                  ),
                  appBackgroundThemeProvider.overrideWithValue(null),
                ],
                child: PluginPage(view: view),
              ),
              platform: platform,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Plugin title'), findsOneWidget);
          if (platform == TargetPlatform.android) {
            expect(find.byType(AppBar), findsOneWidget);
          } else {
            final origin = tester.getTopLeft(find.byType(PluginPage));
            expect(
              tester.getCenter(find.text('Plugin title')).dy - origin.dy,
              closeTo(24, 1),
            );
            // 返回入口与标题同在左侧标题栏内，Windows 也不需要下移。
            final button = find.byTooltip('Back');
            expect(tester.getCenter(button).dy - origin.dy, closeTo(24, 1));
            expect(
              tester.getCenter(button).dx,
              lessThan(tester.getCenter(find.text('Plugin title')).dx),
            );
            if (platform != TargetPlatform.macOS) {
              expect(
                tester.getTopRight(find.text('Plugin title')).dx,
                lessThanOrEqualTo(
                  width - DesktopWindowFrame.windowsCaptionButtonsWidth,
                ),
              );
            }
            final content = tester.getTopLeft(find.byType(RevericPlaceholder));
            expect(content.dy - origin.dy, greaterThan(48));
            await tester.tap(button);
            await tester.pump();
          }
          expect(tester.takeException(), null);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
  }

  testWidgets(
    'embedded plugin page leaves when its view is unregistered',
    (tester) async {
      final database = AppDatabase.forTest(NativeDatabase.memory());
      final host = PluginHostService(
        dao: database.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        packages: () async => [],
      );
      addTearDown(() async {
        await host.dispose();
        await database.close();
      });
      final view = PluginView(
        PluginManifest.fromJson({
          'id': 'test.page',
          'name': 'Page',
          'version': '1.0.0',
          'pluginApiVersion': '^1',
          'main': 'index.js',
        }).id,
        {
          'id': 'page',
          'title': 'Plugin title',
          'location': 'home.plugin',
          'protocol': 'reveric-tsx-v1',
          'source': 'page.js',
        },
      );
      var unavailable = 0;
      await tester.pumpWidget(
        wrap(
          ProviderScope(
            overrides: [
              pluginHostServiceProvider.overrideWithValue(host),
              appBackgroundImagePathProvider.overrideWithValue(''),
              appBackgroundFitProvider.overrideWithValue(
                AppBackgroundFit.cover,
              ),
              appBackgroundThemeProvider.overrideWithValue(null),
            ],
            child: PluginPageRegion(
              view: view,
              onOpenView: (_) {},
              onUnavailable: () => unavailable++,
              onRegisterHasChanges: (_) {},
            ),
          ),
          platform: TargetPlatform.macOS,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Plugin title'), findsOneWidget);
      expect(find.byTooltip('Back'), findsNothing);
      expect(unavailable, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );
}

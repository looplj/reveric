// 职责: 验证通用设置中的隐私开关在桌面与移动端对齐右侧、可整行点击并持久化。
// 关联文件:
//   lib/shared/widgets/settings/general_settings_section.dart
//   lib/shared/providers/anonymous_reporting_providers.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/i18n.md

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/components/reveric_switch.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_provider.dart' show AiSettings;
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/settings/general_settings_section.dart';
import 'package:reveric/shared/widgets/settings/settings_section_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => AppSettings(
    theme: AppTheme.reveric,
    themeMode: AppThemeMode.light,
    language: 'en',
    aiSettings: AiSettings(providers: []),
  );
}

void main() {
  setUp(() {
    rootBundle.clear();
    SharedPreferences.setMockInitialValues({});
  });

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.android,
  ]) {
    testWidgets(
      '$platform renders trailing privacy switch and toggles on row tap',
      (tester) async {
        final mobile = platform == TargetPlatform.android;
        tester.view.physicalSize = Size(mobile ? 360 : 800, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(_wrap(const GeneralSettingsSection()));
        await tester.pumpAndSettle();

        final labelFinder = find.text('Share anonymous diagnostics');
        final switchFinder = find.byType(RevericSwitch);
        expect(labelFinder, findsOneWidget);
        expect(switchFinder, findsOneWidget);

        // 隐私开关所在的 SettingsCard 应把开关放在右侧，而非 2:3 居中偏左。
        final privacyCardFinder = find.ancestor(
          of: switchFinder,
          matching: find.byType(SettingsCard),
        );
        final cardRect = tester.getRect(privacyCardFinder);
        final labelRect = tester.getRect(labelFinder);
        final switchRect = tester.getRect(switchFinder);

        expect(switchRect.left, greaterThan(cardRect.center.dx));
        expect(
          cardRect.right - switchRect.right,
          lessThan(labelRect.right - cardRect.left),
        );

        expect(tester.widget<RevericSwitch>(switchFinder).value, isTrue);

        await tester.ensureVisible(labelFinder);
        await tester.tap(labelFinder);
        await tester.pumpAndSettle();
        expect(tester.widget<RevericSwitch>(switchFinder).value, isFalse);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('anonymous_reporting_consent'), isFalse);

        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant({platform}),
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }
}

Widget _wrap(Widget child) => ProviderScope(
  overrides: [appSettingsProvider.overrideWith(_Settings.new)],
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
          child: Scaffold(body: child),
        ),
      ),
    ),
  ),
);

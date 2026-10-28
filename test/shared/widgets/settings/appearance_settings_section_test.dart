// 职责: 验证外观设置区的界面文字大小档位切换即时写入设置状态。
// 关联文件:
//   lib/shared/widgets/settings/appearance_settings_section.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/testing.md
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart' show AppDatabase;
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/settings/appearance_settings_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());

  testWidgets('appearance section switches ui text scale presets immediately', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = AppDatabase.forTest(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appSettingsDatabaseProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    await tester.runAsync(() => container.read(appSettingsProvider.future));
    final themeData = container
        .read(appSettingsProvider)
        .requireValue
        .themeData;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
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
              home: RevericTheme(
                data: themeData,
                child: const Scaffold(body: AppearanceSettingsSection()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(container.read(appSettingsProvider).requireValue.uiTextScale, 1.0);
    await tester.ensureVisible(find.text('Large'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Large'));
    await tester.pumpAndSettle();
    expect(container.read(appSettingsProvider).requireValue.uiTextScale, 1.15);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

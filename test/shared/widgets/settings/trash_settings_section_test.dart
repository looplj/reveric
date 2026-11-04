// 职责: 验证回收站设置区列出已删除作品、显示剩余保留天数，并能恢复到书架。
// 关联文件:
//   lib/shared/widgets/settings/trash_settings_section.dart
//   lib/shared/services/novel_actions.dart
//   lib/shared/database/daos/novel_dao.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/settings/trash_settings_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('lists deleted works and restores them to the shelf', (
    tester,
  ) async {
    final db = AppDatabase.forTest(NativeDatabase.memory());
    addTearDown(db.close);
    await db.novelDao.create(id: 'a', title: 'Deleted A', description: '');
    await db.novelDao.create(id: 'b', title: 'Shelf B', description: '');
    await db.novelDao.softDelete('a');

    await tester.pumpWidget(_wrap(db, const TrashSettingsSection()));
    await tester.pumpAndSettle();

    expect(find.text('Deleted A'), findsOneWidget);
    expect(find.text('Shelf B'), findsNothing);
    expect(
      find.textContaining('Permanently deleted in 30 days'),
      findsOneWidget,
    );

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    expect(find.text('Deleted A'), findsNothing);
    expect(find.text('Trash is empty'), findsOneWidget);
    expect(await db.novelDao.get('a'), isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

Widget _wrap(AppDatabase db, Widget child) => ProviderScope(
  overrides: [
    appDatabaseProvider.overrideWithValue(db),
    changeRecordRetentionDaysProvider.overrideWithValue(30),
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
        theme: RevericThemeData.reveric.toThemeData(),
        home: RevericTheme(
          data: RevericThemeData.reveric,
          child: Scaffold(body: child),
        ),
      ),
    ),
  ),
);

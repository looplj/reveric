// 职责: 验证移动端图鉴在窄屏下的分组、筛选、防抖搜索与类型选择。
// 关联文件:
//   lib/mobile/widgets/compendium_panel.dart
//   lib/mobile/pages/entry_editor_page.dart
//   lib/shared/providers/novel_providers.dart
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/mobile/pages/entry_editor_page.dart';
import 'package:reveric/mobile/widgets/compendium_panel.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());

  testWidgets('375px groups, filters, searches and clears without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();
    expect(find.text('势力'), findsOneWidget);
    expect(find.text('entry-faction'), findsNothing);
    await tester.tap(find.text('势力'));
    await tester.pumpAndSettle();
    expect(find.text('entry-faction'), findsOneWidget);
    await tester.tap(find.text('生物 1'));
    await tester.pumpAndSettle();
    expect(find.text('entry-creature'), findsOneWidget);
    expect(find.text('entry-faction'), findsNothing);
    await tester.tap(find.text('全部 4'));
    await tester.enterText(find.byType(TextField), 'entry-skill');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == 'entry-skill',
      ),
      findsOneWidget,
    );
    expect(find.text('势力'), findsNothing);
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == 'entry-skill',
      ),
      findsNothing,
    );
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(find.text('势力'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

Widget _wrap() {
  final now = DateTime.utc(2026);
  return ProviderScope(
    overrides: [
      for (final type in ['faction', 'creature', 'item', 'skill'])
        itemsProvider(path: 'test', type: type).overrideWith(
          (ref) => Stream.value([
            Item(
              id: type,
              type: type,
              title: 'entry-$type',
              content: 'Long preview text ' * 15,
              status: '',
              category: 'Long category ' * 10,
              sortOrder: 0,
              createdAt: now,
              updatedAt: now,
              deletedAt: now,
            ),
          ]),
        ),
    ],
    child: EasyLocalization(
      supportedLocales: const [Locale('zh', 'CN')],
      path: 'assets/translations',
      assetLoader: const MergingAssetLoader(),
      fallbackLocale: const Locale('zh', 'CN'),
      startLocale: const Locale('zh', 'CN'),
      child: Builder(
        builder: (context) => MaterialApp(
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          theme: RevericThemeData.reveric.toThemeData(),
          home: RevericTheme(
            data: RevericThemeData.reveric,
            child: Scaffold(
              body: MobileCompendiumPanel(
                novelId: 'work',
                databasePath: 'test',
                onCreate: (MobileEditorSection section) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

// 职责: 验证移动新建页以入口类型开场、可在页内切换小说 / 剧本；横幅随类型换内容且下方字段不重建。
// 关联文件:
//   lib/mobile/pages/novel_create_page.dart
//   lib/shared/providers/dictionary_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/form.md

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/components/reveric_segmented_control.dart';
import 'package:reveric/mobile/pages/novel_create_page.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/providers/dictionary_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('work kind starts from the entry and can be switched in place', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Widget app(Widget page) => ProviderScope(
      overrides: [
        novelCategoriesProvider.overrideWith((ref) async => const <String>[]),
        novelTagsProvider.overrideWith((ref) async => const <String>[]),
        novelsProvider.overrideWith((ref) => Stream.value(const <Novel>[])),
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
            home: RevericTheme(data: RevericThemeData.reveric, child: page),
          ),
        ),
      ),
    );

    Finder kindTab(String label) => find.descendant(
      of: find.byType(RevericSegmentedControl<String>),
      matching: find.text(label),
    );

    // 剧本入口：落在剧本，有计划集数，横幅槽位是从小说改编。
    await tester.pumpWidget(
      app(
        const MobileNovelCreatePage(
          key: ValueKey('screenplay'),
          contentKind: contentKindScreenplay,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Planned episodes'), findsOneWidget);
    expect(find.text('Quick Start'), findsNothing);
    expect(find.text('Adapt a novel'), findsOneWidget);
    final titleElement = tester.element(find.text('Work name'));

    // 页内切到小说：横幅换成快速开书，剧本专属字段收起。改编横幅内嵌了原著选择，
    // 窄屏比快速开书高，下方表单会上移，但字段不能被重建。
    await tester.tap(kindTab('Novel'));
    await tester.pumpAndSettle();
    expect(find.text('Planned episodes'), findsNothing);
    expect(find.text('Quick Start'), findsOneWidget);
    expect(tester.element(find.text('Work name')), same(titleElement));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

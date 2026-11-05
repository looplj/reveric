// 职责: 验证移动新建页按入口锁定小说 / 剧本，横幅和专属字段随类型呈现。
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

  testWidgets('work kind is locked to the entry', (tester) async {
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
    expect(find.text('New Screenplay'), findsOneWidget);
    expect(find.text('Novel'), findsNothing);

    // 小说入口：横幅是快速开书，没有剧本专属字段，也不能切到剧本。
    await tester.pumpWidget(
      app(
        const MobileNovelCreatePage(
          key: ValueKey('novel'),
          contentKind: contentKindNovel,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Planned episodes'), findsNothing);
    expect(find.text('Quick Start'), findsOneWidget);
    expect(find.text('New Novel'), findsOneWidget);
    expect(find.text('Screenplay'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

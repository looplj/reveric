// 职责: 验证桌面新建表单切换小说 / 剧本时横幅换成对应入口、对话框不变形，改编横幅选原著后按原著预填。
// 关联文件:
//   lib/desktop/widgets/novel_form_dialog.dart
//   lib/shared/providers/dictionary_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/components/dialog_feedback.dart';
import 'package:reveric/shared/components/reveric_segmented_control.dart';
import 'package:reveric/shared/components/reveric_select.dart';
import 'package:reveric/desktop/widgets/novel_form_dialog.dart';
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
  setUp(() => rootBundle.clear());

  testWidgets('switching work kind swaps the banner without resizing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pumpDialog(tester, contentKindNovel);
    expect(find.text('Quick Start'), findsOneWidget);
    expect(find.text('Planned episodes'), findsNothing);
    final dialogRect = tester.getRect(find.byType(Dialog));

    // 快速开书只建小说；剧本同一槽位换成从小说改编，作者行并入计划集数，尺寸不变。
    await tester.tap(kindTab('Screenplay'));
    await tester.pumpAndSettle();
    expect(find.text('Quick Start'), findsNothing);
    expect(find.text('Adapt a novel'), findsOneWidget);
    expect(find.text('Planned episodes'), findsOneWidget);
    expect(tester.getRect(find.byType(Dialog)), dialogRect);

    // 书架上没有小说时，横幅里的原著下拉提示空书架。
    expect(find.text('No novels on your shelf yet'), findsOneWidget);

    await tester.tap(kindTab('Novel'));
    await tester.pumpAndSettle();
    expect(find.text('Quick Start'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('picking a source in the adapt banner prefills the form', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pumpDialog(
      tester,
      contentKindScreenplay,
      novels: [_novel('a', '南渡记'), _novel('b', '北归记')],
    );

    Future<void> pickSource(String title) async {
      await tester.tap(find.byType(RevericSelect<String?>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(title).last);
      await tester.pumpAndSettle();
    }

    await pickSource('南渡记');
    expect(find.text('南渡记 (Screenplay)'), findsOneWidget);
    expect(find.text('南渡记的简介'), findsOneWidget);
    // 原著只在横幅里选，左栏不再重复一个「改编自小说」。
    expect(find.text('Adapted from'), findsNothing);

    // 换原著：上一本带入、用户没动过的字段跟着换。
    await pickSource('北归记');
    expect(find.text('北归记 (Screenplay)'), findsOneWidget);
    expect(find.text('北归记的简介'), findsOneWidget);

    // 用户改过的标题不被覆盖。
    await tester.enterText(find.text('北归记 (Screenplay)'), 'My title');
    await tester.pumpAndSettle();
    await pickSource('南渡记');
    expect(find.text('My title'), findsOneWidget);
    expect(find.text('南渡记的简介'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

Finder kindTab(String label) => find.descendant(
  of: find.byType(RevericSegmentedControl<String>),
  matching: find.text(label),
);

Future<void> _pumpDialog(
  WidgetTester tester,
  String contentKind, {
  List<Novel> novels = const <Novel>[],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        novelCategoriesProvider.overrideWith((ref) async => const <String>[]),
        novelTagsProvider.overrideWith((ref) async => const <String>[]),
        novelsProvider.overrideWith((ref) => Stream.value(novels)),
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
              child: DialogFeedback.scope(
                builder: (_) => NovelFormDialog.create(
                  initialContentKind: contentKind,
                  onQuickStart: () {},
                  onSubmit:
                      ({
                        required title,
                        required authorName,
                        required description,
                        required category,
                        required type,
                        required contentKind,
                        required plannedEpisodeCount,
                        required sourceNovelId,
                        required coverSourcePath,
                        required removeCover,
                        required tags,
                      }) async => true,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Novel _novel(String id, String title) => Novel(
  id: id,
  title: title,
  authorName: '',
  description: '$title的简介',
  draft: false,
  category: '',
  tags: const <String>[],
  status: '',
  type: '',
  contentKind: contentKindNovel,
  wordCount: 0,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  deletedAt: notDeletedSentinel,
);

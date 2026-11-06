// 职责: 验证移动作品表单在小屏键盘与滚动场景下保留编辑值，并校验离屏必填字段。
// 关联文件:
//   lib/mobile/pages/novel_create_page.dart
//   lib/mobile/pages/novel_import_page.dart
//   lib/shared/providers/dictionary_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/form.md

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reveric/shared/form/form.dart';
import 'package:reveric/mobile/pages/novel_import_page.dart';
import 'package:reveric/shared/services/novel_import.dart';
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
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  for (final importing in [false, true]) {
    testWidgets(
      '${importing ? 'import' : 'create'} retains fields and validates offscreen title',
      (tester) async {
        tester.view.physicalSize = const Size(320, 711);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              novelCategoriesProvider.overrideWith(
                (ref) async => const <String>[],
              ),
              novelTagsProvider.overrideWith((ref) async => const <String>[]),
              novelsProvider.overrideWith(
                (ref) => Stream.value(const <Novel>[]),
              ),
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
                    child: importing
                        ? MobileNovelImportPage(
                            filePath: '/tmp/form-regression.txt',
                            parsed: const ParsedNovelImport(
                              suggestedTitle: 'File title',
                              chapters: [],
                              volumeCount: 0,
                              wordCount: 0,
                            ),
                            onSubmit:
                                ({
                                  required title,
                                  required description,
                                  required category,
                                  required type,
                                  required tags,
                                }) async => throw StateError('Must not submit'),
                          )
                        : const MobileNovelCreatePage(
                            contentKind: contentKindNovel,
                          ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final form = tester
            .widget<HookedForm>(
              find.byWidgetPredicate((widget) => widget is HookedForm),
            )
            .form;
        final titleWidget = tester.widget<HookedTextFormField>(
          find.byWidgetPredicate(
            (widget) =>
                widget is HookedTextFormField &&
                widget.fieldHook.name == 'title',
          ),
        );
        final titleField = titleWidget.fieldHook;
        final titleKey = form.fieldKey(titleField);
        final title = find.descendant(
          of: find.byKey(titleKey),
          matching: find.byType(TextField),
        );
        await tester.ensureVisible(title);
        await tester.enterText(title, 'Entered title');
        await tester.pumpAndSettle();
        final before = titleKey.currentState;
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        final scrollable = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(identical(before, titleKey.currentState), isTrue);
        expect(form.getValue<String>(titleField), 'Entered title');
        // At the bottom, an empty title must still participate in validation.
        form.updateValue(titleField, '');
        expect(form.validate(), isFalse);
        await tester.pumpAndSettle();
        scrollable.position.jumpTo(0);
        await tester.pumpAndSettle();
        await tester.ensureVisible(title);
        await tester.enterText(title, 'Corrected title');
        await tester.pumpAndSettle();
        expect(form.validate(), isTrue);
        expect(form.getValue<String>(titleField), 'Corrected title');
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}

// 职责: 验证两端 TXT 导入表单不再提供导入后改编选项，并按原有字段提交。
// 关联文件:
//   lib/mobile/pages/novel_import_page.dart
//   lib/desktop/widgets/novel_import_dialog.dart
//   lib/shared/services/novel_import.dart
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
import 'package:reveric/desktop/widgets/novel_import_dialog.dart';
import 'package:reveric/mobile/pages/novel_import_page.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/dictionary_providers.dart';
import 'package:reveric/shared/services/novel_import.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());

  for (final mobile in [false, true]) {
    for (final platform
        in mobile
            ? [TargetPlatform.android]
            : [TargetPlatform.windows, TargetPlatform.macOS]) {
      testWidgets('import platform=$platform', (tester) async {
        tester.view.physicalSize = mobile
            ? const Size(390, 844)
            : const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final submittedTitles = <String>[];
        NovelImportResult? outcome;
        Future<NovelImportResult> submit({
          required String title,
          required String description,
          required String category,
          required String type,
          required List<String> tags,
        }) async {
          submittedTitles.add(title);
          return const NovelImportResult(
            novelId: 'novel_imported',
            chapterCount: 1,
            volumeCount: 0,
            wordCount: 10,
          );
        }

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              novelCategoriesProvider.overrideWith(
                (ref) async => const <String>[],
              ),
              novelTagsProvider.overrideWith((ref) async => const <String>[]),
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
                  theme: RevericThemeData.reveric.toThemeData().copyWith(
                    platform: platform,
                  ),
                  // 对话框路由不在 home 子树里，主题要包在 Navigator 外层。
                  builder: (context, child) => RevericTheme(
                    data: RevericThemeData.reveric,
                    child: child!,
                  ),
                  home: Builder(
                    builder: (context) => Scaffold(
                      body: TextButton(
                        onPressed: () async {
                          outcome = await showDialog<NovelImportResult>(
                            context: context,
                            builder: (_) => mobile
                                ? MobileNovelImportPage(
                                    filePath: '/tmp/import.txt',
                                    parsed: const ParsedNovelImport(
                                      suggestedTitle: 'File title',
                                      chapters: [],
                                      volumeCount: 0,
                                      wordCount: 0,
                                    ),
                                    onSubmit: submit,
                                  )
                                : NovelImportDialog(
                                    filePath: '/tmp/import.txt',
                                    parsed: const ParsedNovelImport(
                                      suggestedTitle: 'File title',
                                      chapters: [],
                                      volumeCount: 0,
                                      wordCount: 0,
                                    ),
                                    onSubmit: submit,
                                  ),
                          );
                        },
                        child: const Text('open'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expect(find.text('Adapt into a screenplay after import'), findsNothing);
        expect(find.text('Planned episodes'), findsNothing);
        expect(find.byType(Checkbox), findsNothing);
        await tester.tap(find.text('Start Import'));
        await tester.pumpAndSettle();

        expect(submittedTitles, ['File title']);
        expect(outcome?.novelId, 'novel_imported');
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }
}

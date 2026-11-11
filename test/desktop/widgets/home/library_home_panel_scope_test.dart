// 职责: 验证桌面书架「草稿箱 / 书架」是最外层范围 — 分类筛选、计数都在当前范围内生效，且只看本库的作品类型。
// 关联文件:
//   lib/desktop/widgets/home/library_home_panel.dart
//   lib/desktop/widgets/home/all_works_header.dart
//   lib/shared/models/novel.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'package:drift/native.dart';
import 'package:reveric/shared/services/initialization/collection_seeds.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/desktop/widgets/home/library_home_panel.dart';
import 'package:reveric/desktop/widgets/novel_list.dart';
import 'package:reveric/shared/database/app_database.dart'
    show AppDatabase, Novel, notDeletedSentinel;
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/content_status.dart';
import 'package:reveric/shared/models/novel_type.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Novel _novel(String id, String category, {bool draft = false}) {
  final now = DateTime(2026);
  return Novel(
    id: id,
    title: id,
    authorName: '',
    description: '',
    status: contentStatusInProgress,
    type: novelTypeOriginal,
    contentKind: contentKindScreenplay,
    wordCount: 0,
    draft: draft,
    category: category,
    tags: const [],
    createdAt: now,
    updatedAt: now,
    deletedAt: notDeletedSentinel,
  );
}

// 书架标题栏会读用户名，替身避免打开真实数据库。
class _TestAppSettings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => AppSettings(
    theme: AppTheme.reveric,
    themeMode: AppThemeMode.light,
    language: 'en',
    aiSettings: AiSettings.defaults(),
  );
}

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets(
    'canvas library lists only canvas works and has direct create without novel shortcuts',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = AppDatabase.forTest(NativeDatabase.memory());
      final works = [
        _novel('Canvas example', '').copyWith(contentKind: contentKindCanvas),
        _novel('Screenplay example', ''),
      ];
      for (final work in works) {
        await db.into(db.novels).insert(work.toCompanion(true));
      }
      await seedCollections(
        db,
        names: {
          'all': 'All',
          'in_progress': 'In progress',
          'finished': 'Finished',
        },
      );
      var creates = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            appSettingsProvider.overrideWith(_TestAppSettings.new),
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
                builder: (context, child) =>
                    RevericTheme(data: RevericThemeData.reveric, child: child!),
                home: Scaffold(
                  body: HomeLibraryPanel(
                    contentKind: contentKindCanvas,
                    novelsAsync: AsyncData(works),
                    headerGestureExclusionKey: GlobalKey(),
                    onQuickStart: () {},
                    onCreateNovel: () => creates++,
                    onImportNovel: () {},
                    onImportScreenplay: () {},
                    onCreateDemoNovel: () {},
                    onDeleteNovel: (_) {},
                    onAdaptNovel: (_) {},
                    onEditNovel: (_) {},
                    onOpenNovel: (_) {},
                    onReadNovel: (_) {},
                    onUpdateStatus: (_, _) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Canvas example'), findsWidgets);
      expect(find.text('Screenplay example'), findsNothing);
      expect(find.text('Import TXT'), findsNothing);
      expect(find.text('Quick start'), findsNothing);
      await tester.tap(find.text('New canvas').first);
      expect(creates, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await db.close();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('category menu and filtering follow the drafts/shelf scope', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final novels = [
      _novel('Shelf fantasy', '玄幻'),
      _novel('Shelf urban', '都市'),
      _novel('Draft fantasy', '玄幻', draft: true),
      _novel('Draft sci-fi', '科幻', draft: true),
      _novel('Draft plain', '', draft: true),
    ];
    final db = AppDatabase.forTest(NativeDatabase.memory());
    addTearDown(db.close);
    await seedCollections(
      db,
      names: {
        'all': 'All',
        'in_progress': 'In progress',
        'finished': 'Finished',
      },
    );
    for (final novel in novels) {
      await db.into(db.novels).insert(novel.toCompanion(true));
    }
    Future<void> pumpPanel(String contentKind) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsProvider.overrideWith(_TestAppSettings.new),
            appDatabaseProvider.overrideWithValue(db),
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
                builder: (context, child) =>
                    RevericTheme(data: RevericThemeData.reveric, child: child!),
                home: Scaffold(
                  body: HomeLibraryPanel(
                    key: ValueKey(contentKind),
                    contentKind: contentKind,
                    novelsAsync: AsyncData(novels),
                    headerGestureExclusionKey: GlobalKey(),
                    onQuickStart: () {},
                    onCreateNovel: () {},
                    onImportNovel: () {},
                    onImportScreenplay: () {},
                    onCreateDemoNovel: () {},
                    onDeleteNovel: (_) {},
                    onAdaptNovel: (_) {},
                    onEditNovel: (_) {},
                    onOpenNovel: (_) {},
                    onReadNovel: (_) {},
                    onUpdateStatus: (_, _) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pumpPanel(contentKindScreenplay);

    // 继续写区也会列出作品，断言只看作品网格。
    Finder inGrid(String title) => find.descendant(
      of: find.byType(NovelLibrarySliver),
      matching: find.text(title),
    );

    Future<void> pickCategory(String from, String to) async {
      await tester.tap(find.text(from));
      await tester.pumpAndSettle();
      await tester.tap(find.text(to).last);
      await tester.pumpAndSettle();
    }

    // 书架范围：只有书架的两类，草稿不出现。
    await pickCategory('All categories', '玄幻');
    expect(inGrid('Shelf fantasy'), findsWidgets);
    expect(inGrid('Shelf urban'), findsNothing);
    expect(inGrid('Draft fantasy'), findsNothing);

    // 切到草稿箱：沿用仍存在的分类，只筛草稿。
    await tester.tap(find.byTooltip('Drafts'));
    await tester.pumpAndSettle();
    expect(inGrid('Draft fantasy'), findsWidgets);
    expect(inGrid('Draft sci-fi'), findsNothing);
    expect(inGrid('Shelf fantasy'), findsNothing);

    // 草稿箱的分类菜单按草稿计数，含书架没有的「科幻」「未分类」，不含「都市」。
    await tester.tap(find.text('玄幻'));
    await tester.pumpAndSettle();
    expect(find.text('科幻'), findsOneWidget);
    expect(find.text('Uncategorized'), findsOneWidget);
    expect(find.text('都市'), findsNothing);
    await tester.tap(find.text('科幻'));
    await tester.pumpAndSettle();
    expect(inGrid('Draft sci-fi'), findsWidgets);
    expect(inGrid('Draft fantasy'), findsNothing);

    // 草稿临时分类仍保留，零结果不自动放宽范围；可显式清除。
    await tester.tap(find.byTooltip('Drafts'));
    await tester.pumpAndSettle();
    await pickCategory('科幻', 'All categories');
    expect(find.text('All categories'), findsOneWidget);
    expect(inGrid('Shelf fantasy'), findsWidgets);
    expect(inGrid('Shelf urban'), findsWidgets);

    // 这些都是剧本：小说库里既没有作品也没有它们的草稿。
    await pumpPanel(contentKindNovel);
    expect(find.text('Shelf fantasy'), findsNothing);
    expect(find.text('Shelf urban'), findsNothing);
    expect(find.byTooltip('Drafts'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

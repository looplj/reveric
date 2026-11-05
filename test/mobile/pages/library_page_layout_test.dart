// 职责: 测试移动端作品操作 sheet、阅读页顶部栏与四项底部导航在紧凑视口下不会溢出。
// 关联文件:
//   lib/mobile/pages/library_page.dart
//   lib/mobile/features/reading/reading_page.dart
//   lib/mobile/widgets/tab_bar.dart
//   lib/shared/models/chapter.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/home.json
//   assets/translations/zh-CN/home.json
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
//   assets/translations/en/reading.json
//   assets/translations/zh-CN/reading.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md

import 'package:drift/native.dart';
import 'package:reveric/shared/services/initialization/collection_seeds.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/mobile/features/reading/reading_page.dart';
import 'package:reveric/mobile/pages/library_page.dart';
import 'package:reveric/mobile/widgets/novel_cover.dart';
import 'package:reveric/mobile/widgets/tab_bar.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/chapter.dart';
import 'package:reveric/shared/models/content_status.dart';
import 'package:reveric/shared/models/novel_type.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/novel_collection_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets(
    'action sheet scrolls instead of overflowing on compact heights',
    (tester) async {
      tester.view.physicalSize = const Size(390, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final db = await _libraryDatabase(_novel());
      addTearDown(db.close);
      await tester.pumpWidget(
        _wrap(
          ProviderScope(
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              novelsProvider.overrideWith((ref) => Stream.value([_novel()])),
            ],
            child: const MobileLibraryPage(contentKind: contentKindNovel),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Compact test novel').last);
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Compact test novel').last);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(ListView), findsWidgets);

      await tester.dragUntilVisible(
        find.text('Delete'),
        find.byType(ListView).last,
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Delete'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('library formats novel word count with its localized unit', (
    tester,
  ) async {
    final db = await _libraryDatabase(_novel(wordCount: 37000));
    addTearDown(db.close);
    await tester.pumpWidget(
      _wrap(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            novelsProvider.overrideWith(
              (ref) => Stream.value([_novel(wordCount: 37000)]),
            ),
          ],
          child: const MobileLibraryPage(contentKind: contentKindNovel),
        ),
        locale: const Locale('zh', 'CN'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('3.7 万字'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('library keeps two works side by side across compact widths', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = await _libraryDatabase(_novel());
    addTearDown(db.close);
    await db
        .into(db.novels)
        .insert(
          _novel(
            id: 'second_novel',
            title: 'Second compact test novel',
          ).toCompanion(true),
        );
    await tester.pumpWidget(
      _wrap(
        ProviderScope(
          overrides: [appDatabaseProvider.overrideWithValue(db)],
          child: const MobileLibraryPage(contentKind: contentKindNovel),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final width in [320.0, 339.0, 340.0, 390.0]) {
      tester.view.physicalSize = Size(width, 700);
      await tester.pumpAndSettle();
      // 继续写和最近也有封面，这里只看作品网格。
      final covers = find.descendant(
        of: find.byType(SliverGrid),
        matching: find.byType(MobileNovelCover),
      );
      expect(covers, findsNWidgets(2));
      final first = tester.getRect(covers.at(0));
      final second = tester.getRect(covers.at(1));
      expect(
        first.top,
        closeTo(second.top, 0.1),
        reason: 'Both works must share a row at width $width',
      );
      expect(first.right, lessThan(second.left));
      expect(first.width, closeTo(second.width, 0.1));
      expect(second.right, lessThanOrEqualTo(width));
      expect(find.byTooltip('Filter & sort').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('tabs fit within a narrow viewport', (tester) async {
    tester.view.physicalSize = const Size(200, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _wrap(ProviderScope(child: MobileTabBar(currentIndex: 0, onTap: (_) {}))),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('reader builds within a narrow available width', (tester) async {
    tester.view.physicalSize = const Size(178, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _wrap(
        ProviderScope(
          overrides: [
            novelCollectionsProvider.overrideWith((ref) => Stream.value([])),
            chapterTreeProvider(
              'reading_test_db',
            ).overrideWith((ref) => Stream.value([_chapter()])),
            chapterContentByIdProvider(
              path: 'reading_test_db',
              chapterId: 'chapter_test',
            ).overrideWith((ref) => Stream.value(_chapter())),
          ],
          child: const MobileReadingPage(
            novelId: 'reading_test_novel',
            novelTitle: 'A long work title',
            databasePath: 'reading_test_db',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}

Novel _novel({
  int wordCount = 0,
  String id = 'novel_test',
  String title = 'Compact test novel',
}) {
  final now = DateTime(2026);
  return Novel(
    id: id,
    title: title,
    authorName: '',
    description: '',
    status: contentStatusInProgress,
    type: novelTypeOriginal,
    contentKind: contentKindNovel,
    wordCount: wordCount,
    draft: false,
    category: '',
    tags: const [],
    createdAt: now,
    updatedAt: now,
    deletedAt: notDeletedSentinel,
  );
}

Chapter _chapter() {
  final now = DateTime(2026);
  return Chapter(
    id: 'chapter_test',
    type: nodeTypeChapter,
    siblingOrder: 0,
    title: 'Chapter one',
    content: 'Reader content',
    createdAt: now,
    updatedAt: now,
    deletedAt: notDeletedSentinel,
  );
}

Widget _wrap(Widget child, {Locale locale = const Locale('en')}) {
  return EasyLocalization(
    supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('en'),
    startLocale: locale,
    child: Builder(
      builder: (context) {
        return RevericTheme(
          data: RevericThemeData.reveric,
          child: MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData(),
            home: Scaffold(body: child),
          ),
        );
      },
    ),
  );
}

Future<AppDatabase> _libraryDatabase(Novel novel) async {
  final db = AppDatabase.forTest(NativeDatabase.memory());
  await seedCollections(
    db,
    names: {'all': 'All', 'in_progress': 'In progress', 'finished': 'Finished'},
  );
  await db.into(db.novels).insert(novel.toCompanion(true));
  return db;
}

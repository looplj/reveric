// 职责: 验证桌面书架作品区工具行 — 集合标签与工具同行、排序与分类下拉的回调和选中态、分类不足时隐藏、窄宽度下搜索收成图标。
// 关联文件:
//   lib/desktop/widgets/home/all_works_header.dart
//   lib/shared/widgets/collections/shelf.dart
//   lib/shared/widgets/novel/library_shelf_labels.dart
//   lib/shared/models/novel.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/desktop/widgets/home/all_works_header.dart';
import 'package:reveric/shared/database/app_database.dart'
    show NovelCollection, notDeletedSentinel;
import 'package:reveric/shared/models/novel_collection.dart';
import 'package:reveric/shared/widgets/collections/location.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/novel.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _wrap(Widget child) {
  return EasyLocalization(
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
          body: Padding(
            padding: const EdgeInsets.all(RevericSpacing.x2l),
            child: child,
          ),
        ),
      ),
    ),
  );
}

LibraryCollection _collection(String id, String name, {bool builtin = false}) =>
    LibraryCollection(
      NovelCollection(
        id: id,
        name: name,
        builtin: builtin,
        filterMode: builtin ? 'rule' : 'manual',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        deletedAt: notDeletedSentinel,
      ),
    );

final _all = _collection('all', 'All', builtin: true);

CollectionLocation _location() => CollectionLocation(
  contentKind: 'novel',
  mobile: false,
  collections: AsyncData([_all, _collection('series', 'Series')]),
  current: _all,
  works: const AsyncData([]),
  counts: const AsyncData({'all': 3, 'series': 1}),
  onOpen: (_) {},
  onBack: () {},
);

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('sort and category menus report picks; category hides below '
      'two options', (tester) async {
    tester.view.physicalSize = const Size(900, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var sort = LibrarySortOrder.updated;
    String? category;
    var counts = {'玄幻': 3, '': 1};
    late StateSetter setState;
    final search = TextEditingController();
    addTearDown(search.dispose);

    await tester.pumpWidget(
      _wrap(
        StatefulBuilder(
          builder: (context, set) {
            setState = set;
            return AllWorksHeader(
              location: _location(),
              searchController: search,
              searchHint: 'Search works',
              contentKind: 'novel',
              hasDrafts: false,
              showDrafts: false,
              onToggleDrafts: () {},
              categoryCounts: counts,
              selectedCategory: category,
              onSelectCategory: (v) => set(() => category = v),
              sortOrder: sort,
              onSortChanged: (v) => set(() => sort = v),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 集合标签与工具在同一行；窄宽度下搜索先收成图标，点开才是输入框。
    expect(find.text('Series'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byTooltip('Search works'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.tap(find.text('Recently edited'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Most words'));
    await tester.pumpAndSettle();
    expect(sort, LibrarySortOrder.wordCount);
    expect(find.text('Most words'), findsOneWidget);

    await tester.tap(find.text('All categories'));
    await tester.pumpAndSettle();
    expect(find.text('Uncategorized'), findsOneWidget);
    await tester.tap(find.text('玄幻'));
    await tester.pumpAndSettle();
    expect(category, '玄幻');
    expect(find.text('玄幻'), findsOneWidget);

    setState(() => counts = {'玄幻': 4});
    await tester.pumpAndSettle();
    expect(find.text('玄幻'), findsOneWidget);
    await tester.tap(find.text('玄幻'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All categories'));
    await tester.pumpAndSettle();
    expect(find.text('玄幻'), findsNothing);
    expect(find.text('All categories'), findsNothing);
  });

  testWidgets('tabs that do not fit collapse into More, keeping the current '
      'one visible', (tester) async {
    tester.view.physicalSize = const Size(700, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final search = TextEditingController();
    addTearDown(search.dispose);
    final collections = [
      _all,
      for (var i = 1; i <= 8; i++) _collection('c$i', 'Collection $i'),
    ];
    final opened = <String>[];

    await tester.pumpWidget(
      _wrap(
        AllWorksHeader(
          location: CollectionLocation(
            contentKind: 'novel',
            mobile: false,
            collections: AsyncData(collections),
            current: collections.last,
            works: const AsyncData([]),
            counts: const AsyncData({}),
            onOpen: opened.add,
            onBack: () {},
          ),
          searchController: search,
          searchHint: 'Search works',
          contentKind: 'novel',
          hasDrafts: false,
          showDrafts: false,
          onToggleDrafts: () {},
          categoryCounts: const {},
          selectedCategory: null,
          onSelectCategory: (_) {},
          sortOrder: LibrarySortOrder.updated,
          onSortChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Collection 8'), findsOneWidget);
    expect(find.text('Collection 7'), findsNothing);
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Collection 7'));
    await tester.pumpAndSettle();
    expect(opened, ['c7']);
  });
}

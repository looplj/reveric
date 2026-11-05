// 职责: 验证两端真实书架的集合就地切换、右键 / 长按集合菜单（重命名、左右移、删除）、空集合添加作品与三态归属流程。
// 关联文件:
//   lib/desktop/widgets/home/library_home_panel.dart
//   lib/mobile/pages/library_page.dart
//   lib/shared/widgets/collections/membership_picker.dart
//   lib/shared/widgets/collections/shelf.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
import 'dart:convert';
import 'dart:io';
import '../../database/collection_test_helpers.dart';
import 'dart:ui' as ui;
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:reveric/shared/widgets/collections/location.dart';
import 'package:reveric/shared/widgets/collections/empty.dart';
import 'package:reveric/shared/widgets/collections/shelf.dart';
import 'package:reveric/shared/services/initialization/collection_seeds.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/desktop/widgets/home/library_home_panel.dart';
import 'package:reveric/desktop/widgets/novel_list.dart';
import 'package:reveric/shared/components/reveric_dialog.dart';
import 'package:reveric/mobile/pages/library_page.dart';
import 'package:reveric/shared/components/reveric_checkbox.dart';
import 'package:reveric/shared/database/app_database.dart' hide AppSettings;
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/providers/novel_collection_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/collections/membership_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends AppSettingsNotifier {
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
    if (Platform.environment['COLLECTION_SCREENSHOT_DIR'] != null) {
      for (final (family, asset) in [
        ('Roboto', 'LXGWWenKai-Regular.ttf'),
        ('.SF UI Text', 'LXGWWenKai-Regular.ttf'),
        ('Georgia', 'Literata-Regular.ttf'),
      ]) {
        await (FontLoader(
          family,
        )..addFont(rootBundle.load('assets/fonts/$asset'))).load();
      }
    }
  });

  testWidgets(
    'desktop switches collection in place, adds works to an empty one, renames and deletes via right click',
    (tester) async {
      final db = await _database();
      addTearDown(db.close);
      final id = await db.novelCollectionDao.create(
        name: 'Screen series',
        contentKind: contentKindScreenplay,
        workIds: [],
      );
      final works = await db.novelDao.getAll();
      _size(tester, const Size(1600, 1400));
      await tester.pumpWidget(
        _wrap(
          db,
          Scaffold(
            body: HomeLibraryPanel(
              contentKind: contentKindScreenplay,
              novelsAsync: AsyncData(works),
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
      );
      await tester.pumpAndSettle();
      await _capture(tester, 'desktop-shelf');
      final tab = find.byKey(ValueKey('collection-$id'));
      await tester.tap(tab);
      await tester.pumpAndSettle();
      // 就地切换：没有返回按钮，标题区保持不变。
      expect(find.byTooltip('Back'), findsNothing);
      expect(find.byType(CollectionEmpty), findsOneWidget);
      await tester.tap(find.text('Add works'));
      await tester.pumpAndSettle();
      // 集合不分类型，但剧本库里添加作品只列剧本。
      Finder inPicker(String title) => find.descendant(
        of: find.byType(RevericDialog),
        matching: find.text(title),
      );
      expect(inPicker('Novel A'), findsNothing);
      expect(inPicker('Script A'), findsOneWidget);
      await tester.tap(inPicker('Script B'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add').last);
      await tester.pumpAndSettle();
      // 继续写区也会列出作品，断言只看作品网格。
      Finder inGrid(String title) => find.descendant(
        of: find.byType(NovelLibrarySliver),
        matching: find.text(title),
      );
      expect(inGrid('Script B'), findsOneWidget);
      expect(inGrid('Script A'), findsNothing);
      await _capture(tester, 'desktop-collection');

      // 全部不响应右键。
      await _rightClick(
        tester,
        find.byKey(const ValueKey('collection-collection:all')),
      );
      expect(find.text('Rename'), findsNothing);

      await _rightClick(tester, tab);
      await _capture(tester, 'desktop-collection-menu');
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Renamed series');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Renamed series'), findsWidgets);
      await _rightClick(tester, tab);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();
      expect(tab, findsNothing);
      expect(inGrid('Script A'), findsWidgets);
      expect(find.text('This collection has been deleted'), findsNothing);
      expect((await db.novelDao.getAll()).length, 4);
      expect((await tester.runAsync(() => manualSnapshots(db)))!, isEmpty);
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    },
  );

  testWidgets(
    'mobile switches collection in place and removes works via long press',
    (tester) async {
      final db = await _database();
      addTearDown(db.close);
      final id = await db.novelCollectionDao.create(
        name: 'Novel series',
        contentKind: contentKindNovel,
        workIds: ['a', 'b'],
      );
      _size(tester, const Size(375, 812));
      await tester.pumpWidget(
        _wrap(
          db,
          const MobileLibraryPage(contentKind: contentKindNovel),
          mobile: true,
        ),
      );
      await tester.pumpAndSettle();
      await _capture(tester, 'mobile-shelf');
      await _openMobileCollection(tester, 'collection-$id');
      expect(find.byType(MobileLibraryPage), findsOneWidget);
      await _capture(tester, 'mobile-collection');
      for (final title in ['Novel A', 'Novel B']) {
        await tester.longPress(find.text(title).last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Remove from collection'));
        await tester.tap(find.text('Remove from collection'));
        await tester.pumpAndSettle();
      }
      expect(find.byType(CollectionEmpty), findsOneWidget);
      expect(
        ((await tester.runAsync(() => manualSnapshots(db)))!).single.works,
        isEmpty,
      );
      await _openMobileCollection(tester, 'collection-collection:all');
      expect(find.text('Novel A'), findsWidgets);
      expect((await db.novelDao.getAll()).length, 4);
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    },
  );

  for (final mobile in [false, true]) {
    testWidgets('mixed membership toggles and creates on mobile=$mobile', (
      tester,
    ) async {
      final db = await _database();
      addTearDown(db.close);
      await db.novelCollectionDao.create(
        name: 'Mixed',
        contentKind: contentKindNovel,
        workIds: ['a'],
      );
      _size(tester, mobile ? const Size(375, 812) : const Size(1200, 800));
      await tester.pumpWidget(
        _wrap(
          db,
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showCollectionMembership(
                  context,
                  mobile: mobile,
                  workIds: {'a', 'b'},
                  contentKind: contentKindNovel,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
          mobile: mobile,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<RevericCheckbox>(find.byType(RevericCheckbox))
            .indeterminate,
        isTrue,
      );
      await _capture(
        tester,
        mobile ? 'mobile-membership' : 'desktop-membership',
      );
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();
      expect(
        ((await tester.runAsync(() => manualSnapshots(db)))!).single.workIds,
        {'a', 'b'},
      );
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();
      expect(
        ((await tester.runAsync(() => manualSnapshots(db)))!).single.works,
        isEmpty,
      );
      await tester.tap(find.text('New'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'New series');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final created = ((await tester.runAsync(
        () => manualSnapshots(db),
      ))!).singleWhere((c) => c.name == 'New series');
      expect(created.workIds, {'a', 'b'});
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    });
  }
  testWidgets(
    'desktop tabs protect all, move collections via the menu and fall back to all after deleting the current one',
    (tester) async {
      final db = await _database();
      addTearDown(db.close);
      _size(tester, const Size(1000, 700));
      await tester.pumpWidget(
        _wrap(
          db,
          Scaffold(
            body: LibraryCollectionRegion(
              contentKind: contentKindNovel,
              builder: (context, location) => Column(
                children: [
                  CollectionTabs(location: location),
                  Text('selected:${location.current?.id}'),
                  Text('results:${location.works.value?.length ?? -1}'),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      const finished = ValueKey('collection-collection:finished');
      await tester.tap(find.byKey(finished));
      await tester.pumpAndSettle();
      expect(find.text('selected:collection:finished'), findsOneWidget);
      expect(find.text('results:0'), findsOneWidget);
      expect(find.text('Add works'), findsNothing);
      await tester.runAsync(
        () => (db.update(db.novels)..where((t) => t.id.equals('a'))).write(
          const NovelsCompanion(status: Value('finished')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('results:1'), findsOneWidget);
      await _rightClick(tester, find.byKey(finished));
      await tester.tap(find.text('Move left'));
      await tester.pumpAndSettle();
      final order = await tester.runAsync(
        () => db.appSettingsDao.get('library.collection_order'),
      );
      expect(
        order,
        '["collection:all","collection:finished","collection:in_progress"]',
      );
      // 已在全部之后的第一位，不能再左移。
      await _rightClick(tester, find.byKey(finished));
      await tester.tap(find.text('Move left'));
      await tester.pumpAndSettle();
      expect(
        await tester.runAsync(
          () => db.appSettingsDao.get('library.collection_order'),
        ),
        order,
      );
      await tester.tapAt(const Offset(900, 600));
      await tester.pumpAndSettle();
      await _rightClick(tester, find.byKey(finished));
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();
      expect(find.text('selected:collection:all'), findsOneWidget);
      expect(find.byKey(finished), findsNothing);
      await _dispose(tester);
    },
  );

  testWidgets(
    'missing all shows initialization failure without fabricating records',
    (tester) async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      await tester.pumpWidget(
        _wrap(
          db,
          Scaffold(
            body: LibraryCollectionRegion(
              contentKind: contentKindNovel,
              builder: (_, _) => const Text('unexpected library'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Collections could not be initialized. Restart the app to retry.',
        ),
        findsOneWidget,
      );
      expect(find.text('unexpected library'), findsNothing);
      expect(
        await tester.runAsync(() => db.select(db.novelCollections).get()),
        isEmpty,
      );
      await _dispose(tester);
    },
  );

  testWidgets('production seed entrypoint saves loaded localized names', (
    tester,
  ) async {
    final db = AppDatabase.forTest(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(_wrap(db, const Scaffold(body: Text('loaded'))));
    await tester.pumpAndSettle();
    await tester.runAsync(() => seedDefaultCollections(db));
    final rows = await tester.runAsync(
      () => db.novelCollectionDao.getDefinitions(),
    );
    expect(
      rows!.map((c) => c.name),
      containsAll(['All', 'In Progress', 'Finished']),
    );
    await _dispose(tester);
  });

  testWidgets(
    'mobile keeps search across collections; word sort is novel-only',
    (tester) async {
      final db = await _database();
      addTearDown(db.close);
      _size(tester, const Size(375, 812));
      await tester.pumpWidget(
        _wrap(
          db,
          const MobileLibraryPage(contentKind: contentKindNovel),
          mobile: true,
        ),
      );
      await tester.pumpAndSettle();
      Finder inGrid(String title) => find.descendant(
        of: find.byType(SliverGrid),
        matching: find.text(title),
      );
      await tester.enterText(find.byType(TextField), 'Novel B');
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(inGrid('Novel A'), findsNothing);
      await tester.tap(find.byTooltip('Filter & sort'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Most words'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await _openMobileCollection(tester, 'collection-collection:in_progress');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Novel B',
      );
      expect(inGrid('Novel B'), findsWidgets);
      expect(inGrid('Novel A'), findsNothing);
      await tester.tap(find.byTooltip('Filter & sort'));
      await tester.pumpAndSettle();
      final sorted = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('Most words'),
          matching: find.byType(ListTile),
        ),
      );
      expect(sorted.trailing, isNotNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      // 剧本页是另一个库：只有剧本，字数排序只对小说成立，不提供。
      await tester.pumpWidget(
        _wrap(
          db,
          // 应用里两个 Tab 是两个实例；这里加 key 免得复用小说页的搜索状态。
          const MobileLibraryPage(
            key: ValueKey('screenplays'),
            contentKind: contentKindScreenplay,
          ),
          mobile: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(inGrid('Script A'), findsWidgets);
      expect(find.text('Novel A'), findsNothing);
      expect(find.text('Novel B'), findsNothing);
      await tester.tap(find.byTooltip('Filter & sort'));
      await tester.pumpAndSettle();
      expect(find.text('Most words'), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('This collection has been deleted'), findsNothing);
      await _dispose(tester);
    },
  );

  testWidgets(
    'each library lists shared and own-kind collections; reordering keeps the other library in place',
    (tester) async {
      final db = await _database();
      addTearDown(db.close);
      final dao = db.novelCollectionDao;
      final novelShelf = await dao.create(
        name: 'Novel shelf',
        contentKind: contentKindNovel,
        workIds: ['a'],
      );
      final scriptA = await dao.create(
        name: 'Script shelf A',
        contentKind: contentKindScreenplay,
        workIds: ['s1'],
      );
      final scriptB = await dao.create(
        name: 'Script shelf B',
        contentKind: contentKindScreenplay,
        workIds: ['s2'],
      );
      // 同一秒创建的集合按随机 ID 排，先存一份确定的顺序。
      await saveCollectionOrder(db, [
        'collection:all',
        'collection:in_progress',
        'collection:finished',
        scriptA,
        novelShelf,
        scriptB,
      ]);
      _size(tester, const Size(375, 812));
      await tester.pumpWidget(
        _wrap(
          db,
          const MobileLibraryPage(contentKind: contentKindScreenplay),
          mobile: true,
        ),
      );
      await tester.pumpAndSettle();
      // 默认集合两个库共用；小说集合不出现在剧本库。
      for (final id in ['collection:in_progress', scriptA, scriptB]) {
        expect(find.byKey(ValueKey('collection-$id')), findsOneWidget);
      }
      expect(find.byKey(ValueKey('collection-$novelShelf')), findsNothing);

      await tester.ensureVisible(find.byKey(ValueKey('collection-$scriptB')));
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(ValueKey('collection-$scriptB')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move left'));
      await tester.pumpAndSettle();
      // 只在剧本集合的位置里重排，小说集合留在原位。
      expect(
        await tester.runAsync(
          () => db.appSettingsDao.get('library.collection_order'),
        ),
        jsonEncode([
          'collection:all',
          'collection:in_progress',
          'collection:finished',
          scriptB,
          novelShelf,
          scriptA,
        ]),
      );
      await _dispose(tester);
    },
  );

  testWidgets(
    'mobile long press moves and deletes a collection; legacy route lands on the shelf',
    (tester) async {
      final db = await _database();
      addTearDown(db.close);
      _size(tester, const Size(375, 812));
      await tester.pumpWidget(
        _wrap(
          db,
          const MobileLibraryPage(
            contentKind: contentKindNovel,
            collectionId: 'collection:finished',
          ),
          mobile: true,
        ),
      );
      await tester.pumpAndSettle();
      Finder inGrid(String title) => find.descendant(
        of: find.byType(SliverGrid),
        matching: find.text(title),
      );
      Future<void> longPressTab(String key) async {
        await tester.ensureVisible(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
        await tester.longPress(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
      }

      // 旧的集合路由落到作品页并选中该集合：标题栏和搜索都在。
      expect(find.byType(TextField), findsOneWidget);
      expect(inGrid('Novel A'), findsNothing);
      await longPressTab('collection-collection:all');
      expect(find.text('Move left'), findsNothing);
      await longPressTab('collection-collection:finished');
      await _capture(tester, 'mobile-collection-menu');
      await tester.tap(find.text('Move left'));
      await tester.pumpAndSettle();
      expect(
        await tester.runAsync(
          () => db.appSettingsDao.get('library.collection_order'),
        ),
        '["collection:all","collection:finished","collection:in_progress"]',
      );
      await longPressTab('collection-collection:finished');
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('collection-collection:finished')),
        findsNothing,
      );
      expect(inGrid('Novel A'), findsWidgets);
      await _dispose(tester);
    },
  );
}

Future<AppDatabase> _database() async {
  final db = AppDatabase.forTest(NativeDatabase.memory());
  for (final (id, title, kind) in [
    ('a', 'Novel A', contentKindNovel),
    ('b', 'Novel B', contentKindNovel),
    ('s1', 'Script A', contentKindScreenplay),
    ('s2', 'Script B', contentKindScreenplay),
  ]) {
    await db.novelDao.create(
      id: id,
      title: title,
      description: 'A story in progress',
      contentKind: kind,
    );
  }
  await seedCollections(
    db,
    names: {'all': 'All', 'in_progress': 'In progress', 'finished': 'Finished'},
  );
  return db;
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _wrap(AppDatabase db, Widget child, {bool mobile = false}) =>
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(_Settings.new),
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
            theme: RevericThemeData.reveric.toThemeData().copyWith(
              platform: mobile ? TargetPlatform.iOS : TargetPlatform.macOS,
            ),
            builder: (context, child) => RevericTheme(
              data: RevericThemeData.reveric,
              child: RepaintBoundary(
                key: const ValueKey('collection-capture'),
                child: child!,
              ),
            ),
            home: child,
          ),
        ),
      ),
    );
Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['COLLECTION_SCREENSHOT_DIR'];
  if (directory == null) {
    return;
  }
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('collection-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File(
      '$directory/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _openMobileCollection(WidgetTester tester, String key) async {
  final tab = find.byKey(ValueKey(key));
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  await tester.tap(
    finder,
    buttons: kSecondaryMouseButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pumpAndSettle();
}

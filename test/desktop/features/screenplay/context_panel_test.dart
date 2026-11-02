// 职责: 验证桌面季管理独立弹窗中的编辑、排序、切换与多季侧栏布局。
// 关联文件:
//   lib/desktop/features/screenplay/context_panel.dart
//   lib/shared/providers/screenplay_providers.dart
//   lib/shared/providers/screenplay_workspace_state_provider.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/i18n.md

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/screenplay/context_panel.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/content_status.dart';
import 'package:reveric/shared/models/novel_type.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/screenplay/season_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('hides season controls until a second season exists', (
    tester,
  ) async {
    final appDb = AppDatabase.forTest(NativeDatabase.memory());
    final contentDb = NovelContentDatabase.forTest(NativeDatabase.memory());
    final service = ScreenplayService(contentDb, novelId: 'screenplay_1');
    await service.createInitialStructure();
    final root = (await contentDb.screenplayDao.getRoot())!;
    const databasePath = 'memory:desktop_screenplay';
    final novel = _screenplay(databasePath);
    addTearDown(() async {
      await contentDb.close();
      await appDb.close();
    });

    await tester.pumpWidget(
      _wrap(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(appDb),
            novelContentDatabaseProvider(
              databasePath,
            ).overrideWithValue(contentDb),
          ],
          child: Scaffold(
            body: SizedBox(
              width: 292,
              child: ScreenplayContextPanel(
                novelId: novel.id,
                databasePath: databasePath,
                screenplayId: root.id,
                onFlush: () async => true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Season 1'), findsNothing);
    expect(find.text('Manage seasons'), findsNothing);
    expect(find.text('Add season'), findsOneWidget);

    // 单季时分集标题上的集数直接进本季设置，保存后关闭弹窗。
    await tester.tap(find.byTooltip('Season settings'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '6');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('1/6 eps'), findsOneWidget);
    expect(find.text('Season 1'), findsNothing);

    await service.createSeason(screenplayId: root.id);
    await tester.pumpAndSettle();

    // 多季时顶部出现季选择器；管理季在展开区里，折叠时不占位。
    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text('Manage seasons'), findsNothing);

    await tester.tap(find.text('Season 1'));
    await tester.pumpAndSettle();

    expect(find.text('Manage seasons'), findsOneWidget);
    await tester.tap(find.text('Manage seasons'));
    await tester.pumpAndSettle();
    final manager = find.byType(ScreenplaySeasonManager);
    expect(find.byType(Dialog), findsOneWidget);
    expect(tester.getSize(manager).width, greaterThan(500));
    expect(
      find.descendant(
        of: find.byType(ScreenplayContextPanel),
        matching: manager,
      ),
      findsNothing,
    );

    // 编辑季收在「…」菜单里，与删除并列。
    await tester.tap(find.byTooltip('More actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Season settings').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Arrival');
    await tester.enterText(find.byType(TextField).last, '12');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Season 1 · Arrival'), findsWidgets);
    expect(
      find.descendant(of: manager, matching: find.text('1/12 eps')),
      findsOneWidget,
    );

    final firstSeasonId = (await contentDb.screenplayDao.getSeasons(
      root.id,
    )).first.id;
    await tester.tap(find.byTooltip('Move down').first);
    await tester.pumpAndSettle();
    expect(
      (await contentDb.screenplayDao.getSeasons(root.id)).last.id,
      firstSeasonId,
    );
    expect(find.text('Season 2 · Arrival'), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.tap(
      find.descendant(of: manager, matching: find.text('Season 2 · Arrival')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Season 2 · Arrival'), findsOneWidget);
    for (var index = 0; index < 8; index += 1) {
      await service.createSeason(screenplayId: root.id);
    }
    await tester.pumpAndSettle();
    await tester.tap(find.text('Season 2 · Arrival'));
    await tester.pumpAndSettle();
    expect(find.text('Manage seasons').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('shows delete in the context menu for a single-season episode', (
    tester,
  ) async {
    final appDb = AppDatabase.forTest(NativeDatabase.memory());
    final contentDb = NovelContentDatabase.forTest(NativeDatabase.memory());
    final service = ScreenplayService(contentDb, novelId: 'screenplay_1');
    await service.createInitialStructure();
    final root = (await contentDb.screenplayDao.getRoot())!;
    final season = (await contentDb.screenplayDao.getSeasons(root.id)).single;
    await service.createEpisode(seasonId: season.id);
    const databasePath = 'memory:desktop_screenplay_context_menu';
    final novel = _screenplay(databasePath);
    addTearDown(() async {
      await contentDb.close();
      await appDb.close();
    });

    await tester.pumpWidget(
      _wrap(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(appDb),
            novelContentDatabaseProvider(
              databasePath,
            ).overrideWithValue(contentDb),
          ],
          child: Scaffold(
            body: SizedBox(
              width: 292,
              child: ScreenplayContextPanel(
                novelId: novel.id,
                databasePath: databasePath,
                screenplayId: root.id,
                onFlush: () async => true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final episode = find.text('Episode 2');
    expect(episode, findsOneWidget);
    await tester.tapAt(
      tester.getCenter(episode),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();

    expect(await contentDb.screenplayDao.getEpisodes(season.id), hasLength(1));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('deletes a scene from its context menu', (tester) async {
    final appDb = AppDatabase.forTest(NativeDatabase.memory());
    final contentDb = NovelContentDatabase.forTest(NativeDatabase.memory());
    final service = ScreenplayService(contentDb, novelId: 'screenplay_1');
    final initial = await service.createInitialStructure();
    final root = (await contentDb.screenplayDao.getRoot())!;
    final sceneId = await service.createScene(
      screenplayId: root.id,
      episodeId: initial.episodeId,
      title: 'Removable scene',
    );
    const databasePath = 'memory:desktop_screenplay_scene_context_menu';
    final novel = _screenplay(databasePath);
    addTearDown(() async {
      await contentDb.close();
      await appDb.close();
    });

    await tester.pumpWidget(
      _wrap(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(appDb),
            novelContentDatabaseProvider(
              databasePath,
            ).overrideWithValue(contentDb),
          ],
          child: Scaffold(
            body: SizedBox(
              width: 292,
              child: ScreenplayContextPanel(
                novelId: novel.id,
                databasePath: databasePath,
                screenplayId: root.id,
                onFlush: () async => true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scene = find.text('Removable scene');
    expect(scene, findsOneWidget);
    await tester.tapAt(
      tester.getCenter(scene),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();

    expect(await contentDb.screenplayDao.getScene(sceneId), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

Novel _screenplay(String databasePath) {
  final now = DateTime(2026);
  return Novel(
    id: 'screenplay_1',
    title: 'Screenplay Test',
    authorName: '',
    description: '',
    status: contentStatusInProgress,
    type: novelTypeOriginal,
    contentKind: contentKindScreenplay,
    contentDatabasePath: databasePath,
    wordCount: 0,
    draft: false,
    category: '',
    tags: const [],
    createdAt: now,
    updatedAt: now,
    deletedAt: notDeletedSentinel,
  );
}

Widget _wrap(Widget child) {
  if (child is ProviderScope) {
    return ProviderScope(overrides: child.overrides, child: _wrap(child.child));
  }
  return EasyLocalization(
    supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('en'),
    startLocale: const Locale('en'),
    child: Builder(
      builder: (context) => RevericTheme(
        data: RevericThemeData.reveric,
        child: MaterialApp(
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          theme: RevericThemeData.reveric.toThemeData(),
          home: child,
        ),
      ),
    ),
  );
}

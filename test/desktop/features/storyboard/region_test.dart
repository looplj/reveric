// 职责: 验证分镜列表窄宽度布局、外部刷新、菜单删除确认和软删除。
// 关联文件:
//   lib/desktop/features/storyboard/region.dart
//   lib/shared/providers/storyboard.dart
import 'dart:io';
import 'dart:ui' as ui;
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:reveric/shared/components/reveric_button.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/storyboard/region.dart';
import 'package:reveric/desktop/features/production/edit_session.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/storyboard.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    for (final family in ['Roboto', 'Georgia', 'Menlo', 'Ahem']) {
      await (FontLoader(family)
            ..addFont(rootBundle.load('assets/fonts/LXGWWenKai-Regular.ttf')))
          .load();
    }
  });
  testWidgets(
    'grouped shots update from external writes without reopening',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1100, 800);
      addTearDown(tester.view.reset);
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final app = AppDatabase.forTest(NativeDatabase.memory());
      final screenplay = ScreenplayService(db);
      final initial = await screenplay.createInitialStructure();
      final root = (await db.screenplayDao.getRoot())!.id;
      final first = await screenplay.createScene(
        screenplayId: root,
        episodeId: initial.episodeId,
        title: '旧宅门外 · 雨夜',
        timeLabel: '第一天清晨，暴雨停歇后，所有人抵达之前',
        interiorExterior: 'interior',
      );
      final second = await screenplay.createScene(
        screenplayId: root,
        episodeId: initial.episodeId,
        title: '客厅 · 深夜',
      );
      final service = StoryboardService(db);
      final shot = await service.create(
        first,
        values: {
          'title': '门口的灯',
          'prompt': '夜雨落在青石阶上，女子停在门口。缓慢推进，保持人物正面中景。',
          'duration_ms': 5000,
        },
      );
      await service.create(
        first,
        values: {
          'title': '回望',
          'prompt':
              '参考 <ref input_id="media/portrait.png" label="白衣女子" /> 的形象。她转身望向街道，雨水从伞沿滴落。',
          'duration_ms': 4000,
        },
      );
      await service.create(
        second,
        values: {
          'title': '来信',
          'prompt': '镜头从桌上的信封抬起，男子在昏暗灯光下低声说：“你终于回来了。”',
          'duration_ms': 6000,
        },
      );
      final overlay = WorkingOverlayService(
        db,
        NovelContentService(db),
        novelActionsService: NovelActionsService(app),
      );
      final now = DateTime(2026);
      final novel = Novel(
        id: 'work',
        title: '雨夜归人',
        authorName: '',
        description: '',
        status: 'in_progress',
        type: 'original',
        contentKind: 'screenplay',
        contentDatabasePath: 'test',
        wordCount: 0,
        draft: false,
        category: '',
        tags: const [],
        createdAt: now,
        updatedAt: now,
        deletedAt: notDeletedSentinel,
      );
      final boundary = GlobalKey();
      String? splitPrompt;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(app),
            novelContentDatabaseProvider('test').overrideWithValue(db),
            storyboardServiceProvider('test').overrideWithValue(service),
            workingOverlayServiceProvider('test').overrideWithValue(overlay),
          ],
          child: EasyLocalization(
            supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
            path: 'assets/translations',
            assetLoader: const MergingAssetLoader(),
            startLocale: const Locale('en'),
            fallbackLocale: const Locale('en'),
            child: Builder(
              builder: (context) => RevericTheme(
                data: RevericThemeData.reveric,
                child: MaterialApp(
                  theme: RevericThemeData.reveric.toThemeData(
                    fontFamily: 'Roboto',
                  ),
                  localizationsDelegates: context.localizationDelegates,
                  supportedLocales: context.supportedLocales,
                  locale: context.locale,
                  home: Scaffold(
                    body: RepaintBoundary(
                      key: boundary,
                      child: ColoredBox(
                        color: RevericThemeData.reveric.colors.canvas,
                        child: StoryboardRegion(
                          novel: novel,
                          sceneActions: ProductionSceneActions(
                            ask: (prompt) => splitPrompt = prompt,
                            openDirector: (_, {canvas}) async {},
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('门口的灯'), findsOneWidget);
      await service.apply(shot.id, {
        ...service.snapshot(shot),
        'title': '雨中的门灯',
      });
      await tester.pumpAndSettle();
      expect(find.text('雨中的门灯'), findsOneWidget);
      expect(find.text('门口的灯'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '/tmp/reveric-storyboard-region.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      tester.view.physicalSize = const Size(417, 800);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      const splitLabel = 'Split with AI';
      // 图标操作保留完整提示与原有回调。
      final splitButton = find.byTooltip(splitLabel);
      expect(splitButton, findsWidgets);
      await tester.tap(splitButton.first);
      expect(splitPrompt, contains(first));
      final regionContext = tester.element(find.byType(StoryboardRegion));
      await regionContext.setLocale(const Locale('zh', 'CN'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('AI 拆分镜'), findsWidgets);
      expect(find.byTooltip('查看原文'), findsWidgets);
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '/tmp/reveric-storyboard-narrow.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await regionContext.setLocale(const Locale('en'));
      await tester.pumpAndSettle();
      await (db.update(
        db.productionClips,
      )..where((t) => t.id.equals(shot.id))).write(
        const ProductionClipsCompanion(
          adoptedAssetId: Value('media/retained.mp4'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Media files and generation history will be kept.'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(RevericButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(await service.getShot(shot.id), isNotNull);
      expect(find.text('雨中的门灯'), findsOneWidget);

      await tester.tap(find.byTooltip('More actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(RevericButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('雨中的门灯'), findsNothing);
      expect(find.text('回望'), findsOneWidget);
      expect(await service.getShot(shot.id), isNull);
      final deleted = await (db.select(
        db.productionClips,
      )..where((t) => t.id.equals(shot.id))).getSingle();
      expect(deleted.deletedAt, isNot(notDeletedSentinel));
      expect(deleted.adoptedAssetId, 'media/retained.mp4');
      final nodes = await (db.select(
        db.canvasNodes,
      )..where((t) => t.refId.equals(shot.id))).get();
      expect(nodes, isNotEmpty);
      expect(
        nodes.every((node) => node.deletedAt != notDeletedSentinel),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await db.close();
      await app.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    }),
  );
}

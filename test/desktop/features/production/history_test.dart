// 职责: 验证制作画布撤销按钮、跨桌面快捷键与输入焦点的隔离。
// 关联文件:
//   lib/desktop/features/production/history_actions.dart
//   lib/desktop/features/production/history_region.dart
//   lib/desktop/features/production/canvas_controls.dart
import 'dart:io';
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reveric/shared/providers/storyboard.dart';
import 'package:reveric/shared/providers/production_media.dart';
import 'package:reveric/desktop/features/production/history_region.dart';
import 'package:reveric/desktop/features/production/history_actions.dart';
import 'package:reveric/desktop/features/production/canvas_controls.dart';
import 'package:reveric/desktop/features/canvas/widgets/floating_cluster.dart';
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  for (final canvasWork in [false, true]) {
    testWidgets(
      'Text is available in the ${canvasWork ? 'canvas work' : 'screenplay'} add menu',
      (tester) async {
        ProductionAddKind? selected;
        await tester.pumpWidget(
          _wrap(
            Align(
              alignment: Alignment.bottomCenter,
              child: ProductionAddDock(
                canvasWork: canvasWork,
                enabled: (_) => true,
                onAdd: (kind) => selected = kind,
                onImport: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Add node'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Text'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Text'));
        await tester.pumpAndSettle();
        expect(selected, ProductionAddKind.text);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
  for (final scenario in ['shortcuts', 'text focus', 'conflict']) {
    testWidgets('canvas history $scenario', (tester) async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final main = app.AppDatabase.forTest(NativeDatabase.memory());
      final shots = StoryboardService(db);
      final episode = (await ScreenplayService(
        db,
      ).createInitialStructure()).episodeId;
      final service = ProductionCanvasService(
        shots,
        MediaLibraryService(
          main,
          MediaService(FfmpegRunner()),
          Directory.systemTemp,
        ),
        'work',
      );
      final canvas = await service.ensureCanvas(episode);
      final row = await service.addImage(canvas.id);
      final history = CanvasHistory(shots, canvas.id);
      final controller = TextEditingController();
      var preparations = 0;
      try {
        await tester.pumpWidget(
          _wrap(
            ProductionHistoryScope(
              service: service,
              canvas: canvas,
              history: history,
              child: ProductionHistoryActions(
                history: history,
                beforeRestore: () async {
                  preparations++;
                  return true;
                },
                onRestored: () async {},
                child: Column(
                  children: [
                    const ProductionCanvasTools(onAssets: null, onImport: null),
                    TextField(controller: controller),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        CanvasFloatingButton button(String tooltip) =>
            tester.widget<CanvasFloatingButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is CanvasFloatingButton && widget.tooltip == tooltip,
              ),
            );
        expect(button('Undo').onTap, isNull);
        await service.move(row.id, 100, 200, history: history);
        await tester.pumpAndSettle();
        expect(button('Undo').onTap, isNotNull);
        if (scenario == 'shortcuts') {
          await tester.tap(find.byTooltip('Undo'));
          await tester.pumpAndSettle();
          expect((await service.requireNode(row.id)).x, row.x);
          expect(button('Redo').onTap, isNotNull);
          await _key(
            tester,
            LogicalKeyboardKey.controlLeft,
            LogicalKeyboardKey.keyY,
          );
          expect((await service.requireNode(row.id)).x, 100);
          await _key(
            tester,
            LogicalKeyboardKey.metaLeft,
            LogicalKeyboardKey.keyZ,
          );
          expect((await service.requireNode(row.id)).x, row.x);
          await _key(
            tester,
            LogicalKeyboardKey.metaLeft,
            LogicalKeyboardKey.keyZ,
            shift: true,
          );
          expect((await service.requireNode(row.id)).x, 100);
          expect(preparations, 4);
        } else if (scenario == 'text focus') {
          await tester.tap(find.byType(TextField));
          await tester.enterText(find.byType(TextField), 'prompt draft');
          await tester.pump(const Duration(milliseconds: 600));
          await _key(
            tester,
            LogicalKeyboardKey.metaLeft,
            LogicalKeyboardKey.keyZ,
          );
          await _key(
            tester,
            LogicalKeyboardKey.controlLeft,
            LogicalKeyboardKey.keyZ,
          );
          expect(preparations, 0);
          expect(history.undoCount, 1);
          expect((await service.requireNode(row.id)).x, 100);
        } else {
          await service.move(row.id, 300, 400);
          await tester.tap(find.byTooltip('Undo'));
          await tester.pumpAndSettle();
          expect(
            find.text(
              'This content has changed. This step can no longer be undone or redone.',
            ),
            findsOneWidget,
          );
          expect((await service.requireNode(row.id)).x, 300);
          expect(history.canUndo, isFalse);
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        history.dispose();
        controller.dispose();
        await db.close();
        await main.close();
      }
    });
  }
  testWidgets('history is discarded on page unmount and fresh on reopen', (
    tester,
  ) async {
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    final main = app.AppDatabase.forTest(NativeDatabase.memory());
    final shots = StoryboardService(db);
    final episode = (await ScreenplayService(
      db,
    ).createInitialStructure()).episodeId;
    final library = MediaLibraryService(
      main,
      MediaService(FfmpegRunner()),
      Directory.systemTemp,
    );
    final now = DateTime(2026);
    final novel = app.Novel(
      id: 'work',
      title: 'Screenplay',
      authorName: '',
      description: '',
      status: 'in_progress',
      type: 'original',
      contentKind: 'screenplay',
      contentDatabasePath: 'history-test',
      wordCount: 0,
      draft: false,
      category: '',
      tags: const [],
      createdAt: now,
      updatedAt: now,
      deletedAt: notDeletedSentinel,
    );
    late ProductionHistoryScope scope;
    Widget page() => ProviderScope(
      overrides: [
        storyboardServiceProvider('history-test').overrideWith((ref) => shots),
        mediaLibraryServiceProvider.overrideWithValue(library),
      ],
      child: _wrap(
        ProductionHistoryRegion(
          novel: novel,
          episodeId: episode,
          child: Builder(
            builder: (context) {
              scope = ProductionHistoryScope.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    try {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      final previous = scope.history;
      await scope.service.addImage(scope.canvas.id, history: previous);
      expect(previous.canUndo, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(() => previous.undo(), throwsStateError);
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(identical(scope.history, previous), isFalse);
      expect(scope.history.canUndo, isFalse);
      expect(
        await db.canvasDao.getNodesByCanvas(scope.canvas.id),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await db.close();
      await main.close();
    }
  });
}

Future<void> _key(
  WidgetTester tester,
  LogicalKeyboardKey modifier,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(modifier);
  if (shift) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyEvent(key);
  if (shift) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyUpEvent(modifier);
  await tester.pumpAndSettle();
}

Widget _wrap(Widget child) => EasyLocalization(
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
        child: Scaffold(body: child),
      ),
    ),
  ),
);

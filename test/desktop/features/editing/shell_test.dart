// 职责: 验证制片工作区打开时补建空剪辑，并在关联失效时显示加载失败。
// 关联文件:
//   lib/desktop/features/editing/shell.dart
//   lib/shared/services/production/editing_orchestrator.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/editing/shell.dart';
import 'package:reveric/desktop/features/editing/canvas_shell.dart';
import 'package:reveric/desktop/features/editing/region.dart';
import 'package:reveric/desktop/features/editing/timeline.dart';
import 'package:reveric/desktop/features/production/history_region.dart';
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/providers/production_media.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/widgets/app_background.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/theme/theme.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  testWidgets(
    'canvas editing IDs keep independent projects and show canvas adopted videos',
    (tester) async {
      tester.view.physicalSize = const Size(1500, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final main = app.AppDatabase.forTest(NativeDatabase.memory());
      await ScreenplayService(db).createCanvasStructure();
      await main.novelDao.create(
        id: 'work',
        title: 'Canvas',
        description: '',
        contentKind: contentKindCanvas,
        contentDatabasePath: db.filePath,
      );
      final novel = (await main.novelDao.get('work'))!;
      final library = MediaLibraryService(
        main,
        MediaService(FfmpegRunner()),
        Directory.systemTemp,
      );
      final service = ProductionCanvasService(
        StoryboardService(db, contentKind: contentKindCanvas),
        library,
        'work',
      );
      final canvas = await service.ensureCanvas('');
      final first = await service.addEditing(canvas.id, title: 'Version A');
      final second = await service.addEditing(canvas.id, title: 'Version B');
      final video = await service.shots.createVideo(
        '',
        values: {'title': 'Adopted video'},
      );
      await service.shots.ensureClipNode(video.id);
      final pending = await service.shots.createVideo(
        '',
        values: {'title': 'Pending video'},
      );
      await service.shots.ensureClipNode(pending.id);
      await main.assetDao.insertAsset(
        app.AssetsCompanion.insert(
          id: 'adopted',
          type: 'video',
          name: const Value('Result'),
          path: const Value('file_workspaces/work/result.mp4'),
          purpose: 'production_output',
          content: const Value(VideoAssetContent(mimeType: 'video/mp4')),
        ),
      );
      await (db.update(
        db.productionClips,
      )..where((t) => t.id.equals(video.id))).write(
        const ProductionClipsCompanion(adoptedAssetId: Value('adopted')),
      );
      final history = CanvasHistory(service.shots, canvas.id);
      late Future<void> Function(String) open;
      Future<void> Function()? flush;
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appDatabaseProvider.overrideWithValue(main),
              novelContentDatabaseProvider(db.filePath).overrideWithValue(db),
              mediaLibraryServiceProvider.overrideWithValue(library),
              appBackgroundActiveProvider.overrideWithValue(false),
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
                  home: RevericTheme(
                    data: RevericThemeData.reveric,
                    child: Scaffold(
                      body: ProductionHistoryScope(
                        service: service,
                        canvas: canvas,
                        history: history,
                        child: CanvasEditingShell(
                          novel: novel,
                          registerFlush: (value) => flush = value,
                          builder: (register) => Builder(
                            builder: (context) {
                              open = CanvasEditingScope.maybeOf(context)!.open;
                              register(() async {});
                              return const Text('Canvas ready');
                            },
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
        expect(find.text('Canvas ready'), findsOneWidget);
        await open(first.id);
        await tester.pumpAndSettle();
        expect(
          tester.widget<EditingRegion>(find.byType(EditingRegion)).editingId,
          first.editingId,
        );
        expect(find.text('Adopted video'), findsOneWidget);
        expect(find.text('Pending video'), findsOneWidget);
        expect(find.text('Not adopted'), findsOneWidget);
        final a = tester
            .widget<EditingTimeline>(find.byType(EditingTimeline))
            .controller
            .session;
        a.commit(a.document!.copyWith(ratio: '1:1'));
        final saved = flush!();
        await tester.pumpAndSettle();
        await saved;
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Back to canvas'));
        await tester.pumpAndSettle();
        expect(find.text('Canvas ready'), findsOneWidget);
        await open(second.id);
        await tester.pumpAndSettle();
        final b = tester
            .widget<EditingTimeline>(find.byType(EditingTimeline))
            .controller
            .session;
        expect(b.editingId, second.editingId);
        expect(identical(a, b), isFalse);
        expect(b.document!.ratio, '16:9');
        expect(b.canUndo, isFalse);
        await tester.tap(find.byTooltip('Back to canvas'));
        await tester.pumpAndSettle();
        await db.editingDao.softDelete(second.editingId!);
        await expectLater(open(second.id), throwsA(isA<StoryboardException>()));
        expect(find.byType(EditingRegion), findsNothing);
        await open(first.id);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<EditingTimeline>(find.byType(EditingTimeline))
              .controller
              .doc
              .ratio,
          '1:1',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        history.dispose();
        await db.close();
        await main.close();
      }
    },
  );

  testWidgets(
    'production open initializes an empty editing and refuses a deleted link',
    (tester) async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final first = await ScreenplayService(db).createInitialStructure();
      await (db.update(db.screenplayEpisodes)
            ..where((t) => t.id.equals(first.episodeId)))
          .write(const ScreenplayEpisodesCompanion(editingId: Value(null)));
      Widget screen(int revision) => ProviderScope(
        overrides: [novelContentDatabaseProvider('test').overrideWithValue(db)],
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
              home: RevericTheme(
                data: RevericThemeData.reveric,
                child: Scaffold(
                  body: EditingShell(
                    novelId: 'work',
                    key: ValueKey(revision),
                    identity: (path: 'test', episodeId: first.episodeId),
                    registerFlush: (_) {},
                    builder: (_, _) => const Text('Production ready'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      try {
        await tester.pumpWidget(screen(0));
        await tester.pumpAndSettle();
        expect(find.text('Production ready'), findsOneWidget);
        final episode = (await db.screenplayDao.getEpisode(first.episodeId))!;
        final editing = (await db.editingDao.get(episode.editingId!))!;
        expect(editing.document.clips, isEmpty);
        expect(editing.revision, 0);
        await db.editingDao.softDelete(editing.id);
        await tester.pumpWidget(screen(1));
        await tester.pumpAndSettle();
        expect(find.text('Production ready'), findsNothing);
        expect(find.text('Failed to load'), findsOneWidget);
        expect(
          (await db.screenplayDao.getEpisode(first.episodeId))!.editingId,
          editing.id,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await db.close();
      }
    },
  );
}

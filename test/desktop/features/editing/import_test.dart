// 职责: 验证采用片段导入不会覆盖并发编辑、离页状态或现有轨道配置。
// 关联文件:
//   lib/desktop/features/editing/region.dart
//   lib/desktop/features/editing/controller.dart
//   lib/shared/services/editing/service.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/editing/region.dart';
import 'package:reveric/desktop/features/editing/timeline.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/editing/document.dart';
import 'package:reveric/shared/providers/editing.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/editing/commands.dart';
import 'package:reveric/shared/services/editing/service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/app_background.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../shared/production/editing/commands_test.dart' show fixture;

class DeferredImport extends EditingService {
  DeferredImport(super.database, super.library);
  final pending = Completer<(EditingDocument, List<String>)>();
  int calls = 0;
  @override
  Future<void> verify(EditingDocument doc, MediaCancellation token) async {}
  @override
  Future<(EditingDocument, List<String>)> fromAdopted(
    String episodeId,
    String ratio,
  ) {
    calls++;
    return pending.future;
  }

  void complete() => pending.complete((
    fixture().copyWith(clips: fixture().mainClips),
    <String>[],
  ));
}

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  late NovelContentDatabase db;
  late AppDatabase app;
  late DeferredImport projects;
  Future<void> mount(WidgetTester tester, EditingDocument document) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1500, 900);
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    app = AppDatabase.forTest(NativeDatabase.memory());
    projects = DeferredImport(
      db,
      MediaLibraryService(
        app,
        MediaService(FfmpegRunner()),
        Directory.systemTemp,
      ),
    );
    await db.editingDao.create('editing', 'Independent', document);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(app),
          appBackgroundActiveProvider.overrideWithValue(false),
          novelContentDatabaseProvider('test').overrideWithValue(db),
          editingServiceProvider((
            path: 'test',
            novelId: 'work',
          )).overrideWithValue(projects),
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
              home: RevericTheme(
                data: RevericThemeData.reveric,
                child: Scaffold(
                  body: EditingRegion(
                    novelId: 'work',
                    identity: (path: 'test', episodeId: 'episode'),
                    editingId: 'editing',
                    onClose: () {},
                    registerFlush: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await db.close();
      await app.close();
      tester.view.reset();
    });
  }

  Future<void> start(WidgetTester tester) async {
    await tester.tap(find.text('Import adopted clips'));
    await tester.pump();
  }

  testWidgets('delayed import preserves intervening manual edits', (
    tester,
  ) async {
    await mount(tester, EditingDocument.empty('16:9'));
    final session = tester
        .widget<EditingTimeline>(find.byType(EditingTimeline))
        .controller
        .session;
    await start(tester);
    session.commit(
      EditingCommands.addText(session.document!, 'T1', 0, 'Keep me'),
    );
    await tester.pumpAndSettle();
    await session.flush();
    final expected = session.document!.toJson();
    final revision = session.revision;
    projects.complete();
    await tester.pumpAndSettle();
    expect(session.document!.toJson(), expected);
    expect((await db.editingDao.get('editing'))!.revision, revision);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  testWidgets('leaving during import prevents late persistence', (
    tester,
  ) async {
    await mount(tester, EditingDocument.empty('16:9'));
    await start(tester);
    expect(projects.calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    projects.complete();
    await tester.pumpAndSettle();
    final saved = (await db.editingDao.get('editing'))!;
    expect(saved.revision, 0);
    expect(saved.document.clips, isEmpty);
  });

  testWidgets(
    'single import retains track identities and settings and undoes once',
    (tester) async {
      var empty = EditingCommands.addAudioTrack(EditingDocument.empty('9:16'));
      empty = empty.copyWith(
        tracks: [
          for (final track in empty.tracks)
            if (track.main)
              EditingTrack(
                id: 'custom-main',
                kind: track.kind,
                role: track.role,
                order: track.order,
                name: 'My main',
              )
            else
              track.copyWith(
                muted: track.kind == 'audio',
                hidden: track.kind == 'video',
                name: 'Custom ${track.id}',
              ),
        ],
      );
      await mount(tester, empty);
      final timeline = find.byType(EditingTimeline);
      final controller = tester.widget<EditingTimeline>(timeline).controller;
      final session = controller.session;
      await start(tester);
      // Also exercise the action guard directly, independent of the disabled button.
      await controller.importAdopted(tester.element(timeline), 'episode');
      expect(projects.calls, 1);
      expect(controller.importing, isTrue);
      projects.complete();
      await tester.pumpAndSettle();
      expect(controller.importing, isFalse);
      expect(
        session.document!.tracks.map((t) => t.toJson()),
        empty.tracks.map((t) => t.toJson()),
      );
      expect(session.document!.ratio, '9:16');
      expect(session.document!.mainClips, hasLength(3));
      expect(session.document!.clips.map((c) => c.trackId).toSet(), {
        'custom-main',
      });
      expect((await db.editingDao.get('editing'))!.revision, 1);
      session.undo();
      await tester.pumpAndSettle();
      expect(session.document!.toJson(), empty.toJson());
      expect(session.canUndo, isFalse);
      expect(
        (await db.editingDao.get('editing'))!.document.toJson(),
        empty.toJson(),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('locked main rejects adopted import before media work', (
    tester,
  ) async {
    final empty = EditingDocument.empty('16:9');
    final locked = empty.copyWith(
      tracks: [
        for (final track in empty.tracks)
          track.main ? track.copyWith(locked: true) : track,
      ],
    );
    await mount(tester, locked);
    final session = tester
        .widget<EditingTimeline>(find.byType(EditingTimeline))
        .controller
        .session;
    await start(tester);
    await tester.pumpAndSettle();
    expect(projects.calls, 0);
    expect(session.document!.toJson(), locked.toJson());
    expect(session.canUndo, isFalse);
    expect((await db.editingDao.get('editing'))!.revision, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

// 职责: 验证剪辑区域在桌面各平台的布局、主轨磁吸拖动、自由轨拖动、撤销与保存保护。
// 关联文件:
//   lib/desktop/features/editing/region.dart
//   lib/shared/providers/editing.dart
import 'dart:io';
import 'dart:ui' as ui;
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/editing/region.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/editing.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/production_view.dart';
import 'package:reveric/shared/services/editing/service.dart';
import 'package:reveric/shared/models/editing/document.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/services/editing/render_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/app_background.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../shared/production/editing/commands_test.dart' show fixture;

class UiProjects extends EditingService {
  UiProjects(super.database, super.library);
  @override
  Future<void> verify(EditingDocument doc, MediaCancellation token) async {}
}

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    for (final name in ['Roboto', 'Georgia', 'Menlo', 'Ahem']) {
      await (FontLoader(name)
            ..addFont(rootBundle.load('assets/fonts/LXGWWenKai-Regular.ttf')))
          .load();
    }
  });
  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets(
      '$platform editing layout, magnetic reorder, free drag, undo and narrow viewport',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1200, 800);
        addTearDown(() {
          debugDefaultTargetPlatformOverride = null;
          tester.view.reset();
        });
        final db = NovelContentDatabase.forTest(NativeDatabase.memory());
        final app = AppDatabase.forTest(NativeDatabase.memory());
        final projects = UiProjects(
          db,
          MediaLibraryService(
            app,
            MediaService(FfmpegRunner()),
            Directory.systemTemp,
          ),
        );
        final renderer = EditingRenderService(projects, FfmpegRunner());
        await db.customStatement(
          "INSERT INTO screenplay_episodes(id,screenplay_id,season_id,episode_number,title,created_at,updated_at) VALUES('episode','script','season',1,'First Dawn',100,200)",
        );
        final initialDoc = fixture();
        await db.editingDao.create(
          'editing',
          'Independent',
          initialDoc.copyWith(
            clips: [
              ...initialDoc.clips,
              const EditingClip(
                id: 'short_v',
                trackId: 'V2',
                startFrame: 0,
                durationFrames: 8,
                content: EditingVideoContent(
                  source: EditingSource(
                    assetId: 'media/video.mp4',
                    mediaType: 'video',
                    durationUs: 10000000,
                    hasAudio: true,
                  ),
                  opacity: 0.5,
                ),
              ),
              const EditingClip(
                id: 'still_img',
                trackId: 'V2',
                startFrame: 24,
                durationFrames: 30,
                content: EditingVideoContent(
                  source: EditingSource(
                    assetId: 'media/still.png',
                    mediaType: 'image',
                    durationUs: 0,
                  ),
                ),
              ),
              const EditingClip(
                id: 'short_title',
                trackId: 'T1',
                startFrame: 0,
                durationFrames: 8,
                content: EditingTextContent(text: '标题', style: 'title'),
              ),
            ],
          ),
        );
        Future<void> Function()? flush;
        final boundary = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appDatabaseProvider.overrideWithValue(app),
              appBackgroundActiveProvider.overrideWithValue(false),
              novelContentDatabaseProvider('test').overrideWithValue(db),
              editingServiceProvider('test').overrideWithValue(projects),
              editingRenderServiceProvider('test').overrideWithValue(renderer),
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
                  theme: RevericThemeData.reveric.toThemeData(
                    fontFamily: 'Roboto',
                  ),
                  home: RevericTheme(
                    data: RevericThemeData.reveric,
                    child: Scaffold(
                      backgroundColor: RevericThemeData.reveric.colors.canvas,
                      body: RepaintBoundary(
                        key: boundary,
                        child: EditingRegion(
                          novelId: 'work',
                          identity: (path: 'test', episodeId: 'episode'),
                          editingId: 'editing',
                          onClose: () {},
                          registerFlush: (f) => flush = f,
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
        expect(tester.takeException(), isNull);
        expect(find.byTooltip('Close'), findsOneWidget);
        final titleTop = tester.getTopLeft(find.byTooltip('Close')).dy;
        // 剪辑名不在页内顶栏重复，交给工作区面包屑显示。
        expect(
          ProviderScope.containerOf(
            tester.element(find.byType(EditingRegion)),
          ).read(productionSubpageProvider('test')),
          (label: 'Editing · Independent', stagingId: null),
        );
        // 资产在页面打开后登记或软删除，时间线名称应随共享资产流刷新。
        final sourceId = fixture().mainClips.first.media!.source.assetId;
        await app.assetDao.insertAsset(
          AssetsCompanion.insert(
            id: sourceId,
            type: 'video',
            purpose: 'general',
            path: const Value('file_workspaces/work/current.mp4'),
            content: const Value(VideoAssetContent(mimeType: 'video/mp4')),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('current.mp4'), findsWidgets);
        await app.assetDao.softDeleteAsset(sourceId);
        await tester.pumpAndSettle();
        expect(find.text('current.mp4'), findsNothing);
        // 内容库路径是 test，主库没有可反查的作品记录；筛选必须使用显式作品 ID。
        for (final owner in <String?>['work', 'other', null]) {
          final name = 'library-${owner ?? 'shared'}';
          await app.assetDao.insertAsset(
            AssetsCompanion.insert(
              id: name,
              type: 'video',
              purpose: 'editing_upload',
              novelId: Value(owner),
              name: Value(name),
              path: Value(
                'file_workspaces/${owner ?? 'shared'}/videos/$name.mp4',
              ),
              inLibrary: const Value(true),
              content: const Value(VideoAssetContent(mimeType: 'video/mp4')),
            ),
          );
        }
        await tester.tap(find.text('Media'));
        await tester.pumpAndSettle();
        expect(find.text('library-work'), findsOneWidget);
        expect(find.text('library-shared'), findsOneWidget);
        expect(find.text('library-other'), findsNothing);
        await tester.tap(find.text('Properties'));
        await tester.pumpAndSettle();
        Future<EditingDocument> saved() async {
          await flush!();
          return (await projects.load('editing')).$1;
        }

        // 锁定后静音/隐藏不可操作，解锁后同一按钮恢复可用。
        for (final (id, label, index, row) in [
          ('T1', 'Hide', 0, 0),
          ('V2', 'Hide', 1, 1),
          ('V1', 'Hide', 2, 2),
          ('A1', 'Mute', 0, 3),
          ('A2', 'Mute', 1, 4),
          ('A3', 'Mute', 2, 5),
        ]) {
          await tester.tap(find.byTooltip('Lock').at(row));
          await tester.pumpAndSettle();
          final locked = (await db.editingDao.get('editing'))!;
          expect(locked.document.track(id).locked, isTrue);
          final toggle = find.byTooltip(label).at(index);
          final button = find.descendant(
            of: toggle,
            matching: find.byType(InkWell),
          );
          expect(tester.widget<InkWell>(button).onTap, isNull);
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(find.byType(SnackBar), findsNothing);
          final unchanged = (await db.editingDao.get('editing'))!;
          expect(unchanged.revision, locked.revision);
          expect(unchanged.document.toJson(), locked.document.toJson());
          await tester.tap(find.byTooltip('Unlock'));
          await tester.pumpAndSettle();
          expect(tester.widget<InkWell>(button).onTap, isNotNull);
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          final changed = (await saved()).track(id);
          expect(label == 'Mute' ? changed.muted : changed.hidden, isTrue);
          await tester.tap(find.byTooltip(label == 'Mute' ? 'Unmute' : 'Show'));
          await tester.pumpAndSettle();
          final restored = (await saved()).track(id);
          expect(label == 'Mute' ? restored.muted : restored.hidden, isFalse);
        }

        // 主轨：把第一段拖到最后，后面的片段前移补齐。
        await tester.drag(
          find.byKey(const ValueKey('m1')),
          const Offset(900, 0),
        );
        await tester.pumpAndSettle();
        expect((await saved()).mainClips.map((c) => c.id), ['m2', 'm3', 'm1']);
        expect((await saved()).mainClips.last.startFrame, 240);
        await tester.tap(find.byTooltip('Undo'));
        await tester.pumpAndSettle();
        expect((await saved()).mainClips.map((c) => c.id), ['m1', 'm2', 'm3']);
        // 自由轨：字幕片段平移，主轨不受影响。
        await tester.drag(
          find.byKey(const ValueKey('sub')),
          const Offset(60, 0),
        );
        await tester.pumpAndSettle();
        final moved = (await saved()).clips.singleWhere((c) => c.id == 'sub');
        expect(moved.startFrame, greaterThan(48));
        expect(moved.trackId, 'T1');
        expect((await saved()).mainClips.first.startFrame, 0);
        await tester.tap(find.byTooltip('Undo'));
        await tester.pumpAndSettle();
        expect(
          (await saved()).clips.singleWhere((c) => c.id == 'sub').startFrame,
          48,
        );
        // 选中字幕，属性里能看到它的文字。
        await tester.tap(find.byKey(const ValueKey('sub')));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextField, '开船了'), findsOneWidget);
        if (platform == TargetPlatform.macOS) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '/tmp/reveric-editing-workspace.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        tester.view.physicalSize = const Size(700, 600);
        await app.assetDao.insertAsset(
          AssetsCompanion.insert(
            id: 'media/still.png',
            type: 'image',
            purpose: 'general',
            path: const Value('file_workspaces/work/still.png'),
            content: const Value(ImageAssetContent(mimeType: 'image/png')),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getTopLeft(find.byTooltip('Close')).dy, titleTop);
        await tester.tap(find.text('Export'));
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(TextField, 'Episode 1 First Dawn'),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Close').last);
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await renderer.dispose();
        await db.close();
        await app.close();
        debugDefaultTargetPlatformOverride = null;
      },
      timeout: const Timeout(Duration(seconds: 45)),
    );
  }
}

// 职责: 验证 GalleryEditingHost 只读剪辑宿主的隔离访问、只读界面裁剪、写操作拦截与画廊节点打开入口。
// 关联文件:
//   lib/desktop/features/editing/host.dart
//   lib/desktop/features/editing/region.dart
//   lib/desktop/features/canvas_gallery/detail_panel.dart
//   lib/shared/services/editing/session.dart

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/canvas_gallery/detail_panel.dart';
import 'package:reveric/desktop/features/editing/canvas_shell.dart';
import 'package:reveric/desktop/features/editing/host.dart';
import 'package:reveric/desktop/features/editing/region.dart';
import 'package:reveric/desktop/features/editing/timeline.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/editing/document.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/services/editing/commands.dart';
import 'package:reveric/shared/services/editing/service.dart';
import 'package:reveric/shared/services/editing/session.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/app_background.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../shared/production/editing/commands_test.dart' show fixture;

class _NoVerifyEditingService extends EditingService {
  _NoVerifyEditingService(super.database, super.library, {super.novelId});

  @override
  Future<void> verify(EditingDocument doc, MediaCancellation token) async {}
}

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets(
    'GalleryEditingHost opens sandbox timeline without novels row and blocks all writes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 820);
      addTearDown(tester.view.reset);

      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final app = AppDatabase.forTest(NativeDatabase.memory());
      await ScreenplayService(db).createCanvasStructure();
      final library = MediaLibraryService(
        app,
        MediaService(FfmpegRunner()),
        Directory.systemTemp,
      );
      final canvasService = ProductionCanvasService(
        StoryboardService(db, contentKind: contentKindCanvas),
        library,
        'gallery_sandbox_work',
      );
      final canvas = await canvasService.ensureCanvas('');
      final node = await canvasService.addEditing(
        canvas.id,
        title: 'Trailer Cut',
      );
      final editingId = node.editingId!;
      final initialDoc = fixture();
      await db.editingDao.save(
        editingId,
        document: initialDoc,
        title: 'Trailer Cut',
        expectedRevision: 0,
      );
      final savedBefore = (await db.editingDao.get(editingId))!;

      final sourceId = initialDoc.mainClips.first.media!.source.assetId;
      await app.assetDao.insertAsset(
        AssetsCompanion.insert(
          id: sourceId,
          type: 'video',
          purpose: 'general',
          path: const Value('file_workspaces/gallery/clip1.mp4'),
          content: const Value(VideoAssetContent(mimeType: 'video/mp4')),
        ),
      );

      final host = GalleryEditingHost(
        canvasService,
        projects: _NoVerifyEditingService(
          db,
          library,
          novelId: canvasService.novelId,
        ),
      );
      var closed = false;

      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [appBackgroundActiveProvider.overrideWithValue(false)],
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
                      body: EditingRegion.hosted(
                        host: host,
                        editingId: editingId,
                        onClose: () => closed = true,
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

        // 标题、只读徽标与源文件名正常展示，不依赖 novels 登记表。
        expect(find.text('Trailer Cut'), findsOneWidget);
        expect(find.text('Read Only'), findsOneWidget);
        expect(find.text('clip1.mp4'), findsWidgets);

        // 写控件与素材库切换被隐藏。
        expect(find.text('Export'), findsNothing);
        expect(find.text('Media'), findsNothing);
        expect(find.byTooltip('Undo'), findsNothing);
        expect(find.byTooltip('Redo'), findsNothing);
        expect(find.byTooltip('Lock'), findsNothing);
        expect(find.text('Split'), findsNothing);
        expect(find.text('Delete'), findsNothing);

        // 拖动片段与删除快捷键均不改变文档。
        await tester.drag(
          find.byKey(const ValueKey('m1')),
          const Offset(400, 0),
        );
        await tester.pumpAndSettle();

        // 可以点选字幕片段查看内容，但不可编辑且无替换/分离按钮。
        await tester.tap(find.byKey(const ValueKey('sub')));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextField, '开船了'), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.widgetWithText(TextField, '开船了'))
              .enabled,
          isFalse,
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('m1')));
        await tester.pumpAndSettle();
        expect(find.text('Replace'), findsNothing);
        expect(
          find.byKey(const ValueKey('editing-detach-audio')),
          findsNothing,
        );

        // 控制器与会话写入口硬拦截。
        final controller = tester
            .widget<EditingTimeline>(find.byType(EditingTimeline))
            .controller;
        expect(controller.readOnly, isTrue);
        controller.toggleSnap();
        controller.showAssets(true);
        expect(controller.assets, isFalse);
        expect(
          () => controller.session.commit(
            EditingCommands.addText(controller.doc, 'T1', 0, 'Nope'),
          ),
          throwsStateError,
        );
        await expectLater(
          controller.session.transact<void>(
            savedBefore.revision,
            (doc, title) async => (document: doc, title: title, result: null),
          ),
          throwsStateError,
        );

        // 数据库保持原样未写入。
        final savedAfter = (await db.editingDao.get(editingId))!;
        expect(savedAfter.revision, savedBefore.revision);
        expect(savedAfter.document.toJson(), savedBefore.document.toJson());

        // 返回画布按钮正常触发 onClose。
        await tester.tap(find.byTooltip('Back to canvas'));
        await tester.pumpAndSettle();
        expect(closed, isTrue);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await host.dispose();
        await db.close();
        await app.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  test(
    'GalleryEditingHost.verifyAccess rejects missing editing node and EditingSession(readOnly) ignores flush',
    () async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final app = AppDatabase.forTest(NativeDatabase.memory());
      await ScreenplayService(db).createCanvasStructure();
      final library = MediaLibraryService(
        app,
        MediaService(FfmpegRunner()),
        Directory.systemTemp,
      );
      final canvasService = ProductionCanvasService(
        StoryboardService(db, contentKind: contentKindCanvas),
        library,
        'gallery_sandbox_work',
      );
      final host = GalleryEditingHost(
        canvasService,
        projects: _NoVerifyEditingService(db, library),
      );
      try {
        await expectLater(host.verifyAccess('missing_id'), throwsStateError);
        final session = EditingSession(
          host.projects,
          'missing_id',
          readOnly: true,
        );
        await session.flush();
        session.undo();
        session.redo();
        expect(session.canUndo, isFalse);
        expect(session.canRedo, isFalse);
        session.dispose();
      } finally {
        await host.dispose();
        await db.close();
        await app.close();
      }
    },
  );

  testWidgets(
    'GallerySelectedNodeBar shows Open and Preview for editing node inside CanvasEditingScope',
    (tester) async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final app = AppDatabase.forTest(NativeDatabase.memory());
      await ScreenplayService(db).createCanvasStructure();
      final library = MediaLibraryService(
        app,
        MediaService(FfmpegRunner()),
        Directory.systemTemp,
      );
      final canvasService = ProductionCanvasService(
        StoryboardService(db, contentKind: contentKindCanvas),
        library,
        'gallery_sandbox_work',
      );
      final canvas = await canvasService.ensureCanvas('');
      final node = await canvasService.addEditing(
        canvas.id,
        title: 'Final Cut',
      );
      String? openedNodeId;

      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [appBackgroundActiveProvider.overrideWithValue(false)],
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
                      body: CanvasEditingScope(
                        open: (nodeId) async => openedNodeId = nodeId,
                        child: GallerySelectedNodeBar(
                          service: canvasService,
                          node: node,
                          clip: null,
                          onPreviewText: (_) {},
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

        expect(find.text('Open'), findsOneWidget);
        expect(find.text('Preview'), findsOneWidget);

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(openedNodeId, node.id);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await db.close();
        await app.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}

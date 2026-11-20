// 职责: 验证只读 3D 导演台宿主、只读会话防线、界面裁剪、沙箱缓存预览与画廊节点操作条。
// 关联文件:
//   lib/shared/services/director/session.dart
//   lib/shared/services/director/file_output.dart
//   lib/shared/widgets/screenplay/director_workspace_host.dart
//   lib/shared/widgets/screenplay/director_host.dart
//   lib/desktop/features/canvas_gallery/detail_panel.dart

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reveric/desktop/features/canvas_gallery/detail_panel.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/director/document.dart';
import 'package:reveric/shared/services/director/file_output.dart';
import 'package:reveric/shared/services/director/renderer.dart';
import 'package:reveric/shared/services/director/session.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/widgets/director/inspector/controls.dart';
import 'package:reveric/shared/widgets/screenplay/director_workspace.dart';
import 'package:reveric/shared/widgets/screenplay/director_workspace_host.dart';

import '../../fixtures/director/animated.dart';
import 'harness.dart';

class _CountingRenderer implements FrameRenderer {
  _CountingRenderer(this.bytes);

  final List<int> bytes;
  int calls = 0;
  bool disposed = false;

  @override
  Future<Uint8List> capture(
    DirectorDocument document,
    int frame,
    String cameraId,
  ) async {
    calls++;
    return Uint8List.fromList(bytes);
  }

  @override
  void dispose() => disposed = true;
}

void main() {
  setUpAll(initializeDirectorTest);
  setUp(() => rootBundle.clear());

  test(
    'read-only DirectorSession blocks mutations while allowing observation',
    () {
      final doc = animatedDirectorDocument();
      final session = DirectorSession(doc, readOnly: true);
      addTearDown(session.dispose);

      expect(session.readOnly, isTrue);
      expect(session.history.dirty, isFalse);
      expect(session.history.canUndo, isFalse);
      expect(session.history.canRedo, isFalse);
      expect(session.claimEditGesture(Object(), 1), isFalse);

      // 写命令全部抛出 StateError。
      expect(
        () => session.history.execute((j) => j['title'] = 'Mutated'),
        throwsStateError,
      );
      expect(
        () => session.history.previewEdit((j) => j['title'] = 'Preview'),
        throwsStateError,
      );
      expect(session.history.undo, throwsStateError);
      expect(session.history.redo, throwsStateError);
      expect(
        () => session.restore(DirectorDocument.blank('X')),
        throwsStateError,
      );
      expect(session.save(), throwsStateError);

      final actorId = doc.objects.first['id'] as String;
      expect(
        () => session.pathEditor.begin(actorId, 'line', (0, 24), 0),
        throwsStateError,
      );

      // 工具、面板、选区写操作均被锁定。
      session.setTool('rotate');
      expect(session.tool, 'select');
      session.setPanel('actors');
      expect(session.panel, 'objects');
      session.setRange(5, 20);
      expect(session.range, (0, doc.durationFrames));

      // 纯观察操作保持正常。
      session.select(actorId);
      expect(session.selected, actorId);
      session.seek(12);
      expect(session.frame.value, 12);
      final camId = doc.activeCameras.first['id'] as String;
      session.viewCamera(camId);
      expect(session.viewCameraId, camId);
      final storedFrame = (
        session.history.document.width,
        session.history.document.height,
      );
      session.history.updateViewportSize(1280, 720);
      expect(session.history.dirty, isFalse);
      expect((
        session.history.document.width,
        session.history.document.height,
      ), storedFrame);
    },
  );

  test(
    'DirectorFileOutput.readPreview does not create directories and cached preview renders once in sandbox',
    () async {
      final sandboxRoot = await Directory.systemTemp.createTemp(
        'director-gallery-preview-',
      );
      addTearDown(() async {
        if (await sandboxRoot.exists()) {
          await sandboxRoot.delete(recursive: true);
        }
      });

      // 纯读缺失目录不创建任何空文件夹。
      final missing = await DirectorFileOutput.readPreview(
        'staging-missing',
        novelId: 'gallery_preview',
        root: sandboxRoot,
      );
      expect(missing, isNull);
      expect(
        await Directory(p.join(sandboxRoot.path, 'file_workspaces')).exists(),
        isFalse,
      );

      // 按需渲染落盘到沙箱 cache/director_preview/<scope>/preview.png，二次命中不再渲染。
      final renderer = _CountingRenderer([137, 80, 78, 71]);
      final doc = animatedDirectorDocument();
      final first = await DirectorFileOutput.readOrRenderCachedPreview(
        root: sandboxRoot,
        scope: 'stg-1',
        loadDocument: () async => doc,
        renderer: renderer,
      );
      expect(first, [137, 80, 78, 71]);
      expect(renderer.calls, 1);
      expect(renderer.disposed, isTrue);
      expect(
        await File(
          p.join(
            sandboxRoot.path,
            'cache',
            'director_preview',
            'stg-1',
            'preview.png',
          ),
        ).exists(),
        isTrue,
      );

      final secondRenderer = _CountingRenderer([9, 9, 9]);
      final second = await DirectorFileOutput.readOrRenderCachedPreview(
        root: sandboxRoot,
        scope: 'stg-1',
        loadDocument: () async => doc,
        renderer: secondRenderer,
      );
      expect(second, [137, 80, 78, 71]);
      expect(secondRenderer.calls, 0);
      expect(
        await Directory(p.join(sandboxRoot.path, 'file_workspaces')).exists(),
        isFalse,
      );
    },
  );

  testWidgets(
    'GalleryDirectorWorkspaceHost opens read-only director workspace, trims write UI, and isolates storage',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.reset);

      final sandboxRoot = Directory.systemTemp.createTempSync(
        'director-gallery-host-',
      );
      addTearDown(() {
        if (sandboxRoot.existsSync()) {
          sandboxRoot.deleteSync(recursive: true);
        }
      });

      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final app = AppDatabase.forTest(NativeDatabase.memory());

      await ScreenplayService(db).createCanvasStructure();
      final library = MediaLibraryService(
        app,
        MediaService(FfmpegRunner()),
        sandboxRoot,
      );
      final canvasService = ProductionCanvasService(
        StoryboardService(db, contentKind: contentKindCanvas),
        library,
        'gallery_preview',
      );
      final canvas = await canvasService.ensureCanvas('');
      final node = await canvasService.addDirector(canvas.id, 'Rooftop Chase');
      final stagingId = node.stagingId!;
      final doc = animatedDirectorDocument().mutate(
        (j) => j['title'] = 'Rooftop Chase',
      );
      await db.screenplayDao.saveStaging(
        stagingId,
        doc.toJson(),
        title: 'Rooftop Chase',
        savedAt: DateTime(2026, 11, 20),
        checkpointId: 'cp-1',
      );

      final host = GalleryDirectorWorkspaceHost(
        canvas: canvasService,
        stagingId: stagingId,
      );
      final loaded = await host.load(
        defaultCameraName: 'Camera 1',
        initializeRenderer: false,
      );
      var closed = false;

      try {
        await tester.pumpWidget(
          ProviderScope(
            child: directorTestApp(
              ScreenplayDirectorWorkspace.hosted(
                host: host,
                session: loaded.session,
                actorCatalog: loaded.actorCatalog,
                onClose: () => closed = true,
                viewportBuilder: (_, _) => const SizedBox.expand(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 顶栏显示标题与 Read Only 徽标，隐藏保存状态；画幅按钮禁用。
        expect(find.text('Rooftop Chase'), findsOneWidget);
        expect(find.text('Read Only'), findsOneWidget);
        expect(find.text('Saved'), findsNothing);
        expect(
          find.byKey(const ValueKey('director-view-mode')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('director-aspect-button')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('director-aspect:16:9')),
          findsNothing,
        );

        // 左栏隐藏新增分类 rail 与 AI 识图，直接展示场景对象列表。
        expect(find.byKey(const ValueKey('director-tab:actors')), findsNothing);
        expect(find.byKey(const ValueKey('director-tab:props')), findsNothing);
        expect(
          find.byKey(const ValueKey('director-tab:cameras')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('director-tab:moves')), findsNothing);
        expect(
          find.byKey(const ValueKey('director-recognize-image')),
          findsNothing,
        );
        final actorId = doc.objects.first['id'] as String;
        expect(
          find.byKey(ValueKey('director-object:$actorId')),
          findsOneWidget,
        );

        // 舞台隐藏撤销/重做/工具 dock。
        expect(find.byKey(const ValueKey('director-undo')), findsNothing);
        expect(find.byKey(const ValueKey('director-redo')), findsNothing);
        expect(
          find.byKey(const ValueKey('director-tool:select')),
          findsNothing,
        );

        // 展开时间轴：隐藏自动关键帧开关与行头打帧按钮。
        await tester.tap(find.byKey(const ValueKey('director-show-timeline')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('director-auto-key')), findsNothing);
        expect(find.byType(KeyButton), findsNothing);

        // 未选中时切镜面板不显示「新增切镜」。
        expect(find.byKey(const ValueKey('director-add-cut')), findsNothing);

        // 点选角色后，属性输入框为只读禁用，且不显示关键帧按钮。
        await tester.tap(find.byKey(ValueKey('director-object:$actorId')));
        await tester.pumpAndSettle();
        final nameField = tester.widget<TextField>(
          find.byKey(const ValueKey('director-field:name')),
        );
        expect(nameField.enabled, isFalse);
        expect(find.byType(KeyButton), findsNothing);

        // 沙箱内不创建 file_workspaces 目录。
        expect(
          Directory(p.join(sandboxRoot.path, 'file_workspaces')).existsSync(),
          isFalse,
        );

        // 点击返回按钮关闭只读导演台。
        await tester.tap(find.byTooltip('Back to canvas'));
        await tester.pumpAndSettle();
        expect(closed, isTrue);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        loaded.session.dispose();
        await host.dispose();
        await db.close();
        await app.close();
      }
    },
  );

  test('GalleryDirectorWorkspaceHost rejects missing staging node', () async {
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    final app = AppDatabase.forTest(NativeDatabase.memory());
    addTearDown(() async {
      await db.close();
      await app.close();
    });
    await ScreenplayService(db).createCanvasStructure();
    final library = MediaLibraryService(
      app,
      MediaService(FfmpegRunner()),
      Directory.systemTemp,
    );
    final canvasService = ProductionCanvasService(
      StoryboardService(db, contentKind: contentKindCanvas),
      library,
      'gallery_preview',
    );
    await canvasService.ensureCanvas('');

    final host = GalleryDirectorWorkspaceHost(
      canvas: canvasService,
      stagingId: 'missing-staging',
    );
    await expectLater(
      host.load(defaultCameraName: 'Camera 1', initializeRenderer: false),
      throwsA(isA<DocumentError>()),
    );
  });

  testWidgets(
    'GallerySelectedNodeBar shows Open director for staging node and invokes callback',
    (tester) async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final app = AppDatabase.forTest(NativeDatabase.memory());
      try {
        await ScreenplayService(db).createCanvasStructure();
        final library = MediaLibraryService(
          app,
          MediaService(FfmpegRunner()),
          Directory.systemTemp,
        );
        final canvasService = ProductionCanvasService(
          StoryboardService(db, contentKind: contentKindCanvas),
          library,
          'gallery_preview',
        );
        final canvas = await canvasService.ensureCanvas('');
        final node = await canvasService.addDirector(canvas.id, 'Scene 1');
        CanvasNode? opened;

        await tester.pumpWidget(
          directorTestApp(
            Center(
              child: GallerySelectedNodeBar(
                service: canvasService,
                node: node,
                clip: null,
                onPreviewText: (_) {},
                onOpenDirector: (target) => opened = target,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Open director'), findsOneWidget);
        await tester.tap(find.text('Open director'));
        await tester.pumpAndSettle();
        expect(opened?.id, node.id);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await db.close();
        await app.close();
      }
    },
  );
}

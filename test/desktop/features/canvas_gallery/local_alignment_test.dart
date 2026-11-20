// 职责: 验证画廊画布对齐本地画布的只读能力：全景只读观察与禁写、顶栏默认画风与规格、文本节点双击预览。
// 关联文件:
//   lib/shared/providers/production_panorama.dart
//   lib/desktop/features/production/view/panorama_actions.dart
//   lib/desktop/features/production/style_button.dart
//   lib/desktop/features/production/spec_panel.dart
//   lib/desktop/features/production/text_node.dart
//   lib/desktop/features/canvas_gallery/detail_panel.dart
//   lib/desktop/features/canvas_gallery/gallery_frame.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/code-style.md

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:reveric/desktop/features/canvas_gallery/detail_panel.dart';
import 'package:reveric/desktop/features/canvas_gallery/gallery_frame.dart';
import 'package:reveric/desktop/features/production/popover.dart';
import 'package:reveric/desktop/features/production/spec_panel.dart';
import 'package:reveric/desktop/features/production/style_button.dart';
import 'package:reveric/desktop/features/production/style_picker.dart';
import 'package:reveric/desktop/features/production/text_node.dart';
import 'package:reveric/desktop/features/production/view/panorama_actions.dart';
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/models/production/panorama.dart';
import 'package:reveric/shared/providers/production_panorama.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/app_background.dart';
import 'package:reveric/shared/widgets/md/reveric_markdown_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StaticSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => AppSettings(
    theme: AppTheme.reveric,
    themeMode: AppThemeMode.light,
    language: 'en',
    aiSettings: AiSettings.defaults(),
  );
}

Widget _wrap(Widget child) => ProviderScope(
  overrides: [
    appBackgroundActiveProvider.overrideWithValue(false),
    appSettingsProvider.overrideWith(_StaticSettingsNotifier.new),
  ],
  child: EasyLocalization(
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
        home: RevericTheme(data: RevericThemeData.reveric, child: child),
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());

  Future<
    ({
      app.AppDatabase mainDb,
      NovelContentDatabase contentDb,
      ProductionCanvasService service,
      String canvasId,
      Directory tempDir,
    })
  >
  createSandbox() async {
    final tempDir = Directory.systemTemp.createTempSync(
      'gallery-local-alignment-',
    );
    final mainDb = app.AppDatabase.forTest(NativeDatabase.memory());
    final contentDb = NovelContentDatabase.forTest(NativeDatabase.memory());
    final episodeId = (await ScreenplayService(
      contentDb,
    ).createInitialStructure()).episodeId;
    final service = ProductionCanvasService(
      StoryboardService(contentDb),
      MediaLibraryService(mainDb, MediaService(FfmpegRunner()), tempDir),
      'gallery-work',
    );
    final canvas = await service.ensureCanvas(episodeId);
    return (
      mainDb: mainDb,
      contentDb: contentDb,
      service: service,
      canvasId: canvas.id,
      tempDir: tempDir,
    );
  }

  void deleteSandboxDir(Directory dir) {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  }

  String writeAssetFile(Directory root, String relativePath) {
    final file = File(p.join(root.path, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync([1, 2, 3, 4]);
    return relativePath;
  }

  test(
    'read-only panorama controller never persists view updates to DB',
    () async {
      final env = await createSandbox();
      try {
        const assetId = 'pano-asset-1';
        final relPath = writeAssetFile(
          env.tempDir,
          'file_workspaces/gallery-work/pano.png',
        );
        await env.mainDb.assetDao.insertAsset(
          app.AssetsCompanion.insert(
            id: assetId,
            novelId: const Value('gallery-work'),
            name: const Value('pano.png'),
            type: 'image',
            purpose: 'production_upload',
            path: Value(relPath),
            content: const Value(ImageAssetContent(mimeType: 'image/png')),
          ),
        );
        final node = await env.service.addMedia(env.canvasId, assetId);
        const initialView = PanoramaView(yaw: 45, pitch: 10, fov: 60);
        await env.service.setPanoramaView(node.id, initialView);

        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = container.read(
          productionPanoramaProvider((
            service: env.service,
            nodeId: node.id,
            readOnly: true,
          )),
        );
        controller.restore(initialView);
        controller.set(const PanoramaView(yaw: 120, pitch: -20, fov: 85));
        await controller.flush();
        controller.reset();
        await controller.flush();

        final stored = await env.contentDb.canvasDao.getNodeById(node.id);
        expect(PanoramaView.fromStyle(stored!.style), initialView);
      } finally {
        await env.contentDb.close();
        await env.mainDb.close();
        deleteSandboxDir(env.tempDir);
      }
    },
  );

  testWidgets(
    'GallerySelectedNodeBar shows read-only panorama controls without write actions',
    (tester) async {
      final env = await createSandbox();
      try {
        const assetId = 'pano-asset-2';
        final relPath = writeAssetFile(
          env.tempDir,
          'file_workspaces/gallery-work/pano.png',
        );
        await env.mainDb.assetDao.insertAsset(
          app.AssetsCompanion.insert(
            id: assetId,
            novelId: const Value('gallery-work'),
            name: const Value('pano.png'),
            type: 'image',
            purpose: 'production_upload',
            path: Value(relPath),
            content: const Value(ImageAssetContent(mimeType: 'image/png')),
          ),
        );
        // 添加媒体会打开文件做校验；testWidgets 的假异步等不到这次真实 IO。
        final node = (await tester.runAsync(() async {
          final created = await env.service.addMedia(env.canvasId, assetId);
          await env.service.setPanoramaView(created.id, const PanoramaView());
          return (await env.contentDb.canvasDao.getNodeById(created.id))!;
        }))!;

        await tester.pumpWidget(
          _wrap(
            Scaffold(
              body: Center(
                child: GallerySelectedNodeBar(
                  service: env.service,
                  node: node,
                  clip: null,
                  onPreviewText: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(ProductionPanoramaActions), findsOneWidget);
        expect(find.byTooltip('Reset view'), findsOneWidget);
        expect(find.byTooltip('Rule of thirds'), findsOneWidget);
        expect(find.byTooltip('Fullscreen'), findsOneWidget);
        expect(find.text('Copy'), findsOneWidget);

        expect(find.byTooltip('Capture current view'), findsNothing);
        expect(find.byTooltip('Capture four views'), findsNothing);
        expect(find.byTooltip('Exit panorama'), findsNothing);
        expect(find.text('View'), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      } finally {
        await env.contentDb.close();
        await env.mainDb.close();
        deleteSandboxDir(env.tempDir);
      }
    },
  );

  testWidgets(
    'GalleryFrame header shows read-only default style and spec without opening popovers',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final env = await createSandbox();
      try {
        await env.service.setScreenplayStyle(
          'preset:chinese-supernatural-film',
        );
        await StoryboardService(
          env.contentDb,
        ).saveSettings({'ratio': '16:9', 'resolution': '1080p'});

        await tester.pumpWidget(
          _wrap(
            GalleryFrame(
              title: 'Sample Canvas',
              action: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ProductionScreenplayStyle(
                    service: env.service,
                    readOnly: true,
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  ProductionReadOnlySpecChip(service: env.service),
                ],
              ),
              body: const SizedBox.shrink(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('中式志怪电影感'), findsOneWidget);
        expect(find.text('16:9 · 1080P'), findsOneWidget);
        expect(find.byType(ProductionCaret), findsNothing);

        await tester.tap(find.text('中式志怪电影感'));
        await tester.pumpAndSettle();
        expect(find.byType(ProductionStylePicker), findsNothing);

        await tester.tap(find.text('16:9 · 1080P'));
        await tester.pumpAndSettle();
        expect(find.byType(ProductionSpecPanel), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      } finally {
        await env.contentDb.close();
        await env.mainDb.close();
        deleteSandboxDir(env.tempDir);
      }
    },
  );

  testWidgets('read-only empty ProductionTextNode does not invite writing', (
    tester,
  ) async {
    final env = await createSandbox();
    try {
      final node = await env.service.addText(env.canvasId, title: 'Blank');
      await tester.pumpWidget(
        _wrap(
          Scaffold(
            body: SizedBox(
              width: 240,
              height: 200,
              child: ProductionTextNode(
                service: env.service,
                node: node,
                selected: false,
                readOnly: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Text), findsNothing);
      expect(find.byType(RevericIcon), findsOneWidget);
      expect(find.byType(RevericMarkdownEditor), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    } finally {
      await env.contentDb.close();
      await env.mainDb.close();
      deleteSandboxDir(env.tempDir);
    }
  });

  testWidgets(
    'read-only ProductionTextNode opens preview on double-tap without entering editor',
    (tester) async {
      final env = await createSandbox();
      try {
        final node = await env.service.addText(
          env.canvasId,
          title: 'Story Note',
          content: 'Double tap to preview in gallery',
        );
        var previewCalls = 0;

        await tester.pumpWidget(
          _wrap(
            Scaffold(
              body: Center(
                child: SizedBox(
                  width: 240,
                  height: 200,
                  child: ProductionTextNode(
                    service: env.service,
                    node: node,
                    selected: false,
                    readOnly: true,
                    onPreview: () => previewCalls++,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final center = tester.getCenter(find.byType(ProductionTextNode));
        await tester.tapAt(center, kind: PointerDeviceKind.mouse);
        await tester.pump(kDoubleTapMinTime);
        await tester.tapAt(center, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();

        expect(previewCalls, 1);
        expect(find.byType(RevericMarkdownEditor), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      } finally {
        await env.contentDb.close();
        await env.mainDb.close();
        deleteSandboxDir(env.tempDir);
      }
    },
  );
}

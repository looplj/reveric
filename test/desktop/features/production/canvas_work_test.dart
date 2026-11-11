// 职责: 验证画布作品的真实页面入口、空起点、节点创建和桌面标题布局。
// 关联文件:
//   lib/desktop/features/production/canvas_work.dart
//   lib/desktop/features/production/region.dart
//   lib/desktop/features/editing/canvas_shell.dart
import 'dart:io';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:reveric/desktop/pages/workspace_editor_page.dart';
import 'package:reveric/desktop/features/production/editing_node.dart';
import 'package:reveric/desktop/features/production/spec_panel.dart';
import 'package:reveric/desktop/widgets/desktop_window_frame.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/desktop/features/production/canvas_work.dart';
import 'package:reveric/desktop/features/production/text_composer.dart';
import 'package:reveric/shared/components/reveric_dialog.dart';
import 'package:reveric/desktop/features/production/node_title.dart';
import 'package:reveric/shared/widgets/md/reveric_markdown_editor.dart';
import 'package:reveric/desktop/widgets/ai/chat/panel.dart';
import 'package:reveric/shared/widgets/ai/chat/attachment_input.dart';
import 'package:reveric/shared/widgets/ai/chat/composer_controller.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/services/ai/prompt_template.dart';
import 'package:reveric/desktop/features/production/canvas_empty.dart';
import 'package:reveric/desktop/features/production/board.dart';
import 'package:reveric/desktop/features/production/prompt_field.dart';
import 'package:reveric/desktop/features/editing/region.dart';
import 'package:reveric/desktop/features/editing/export_dialog.dart';
import 'package:reveric/shared/components/reveric_button.dart';
import 'package:reveric/shared/models/editing/document.dart';
import 'package:reveric/shared/providers/editing.dart';
import 'package:reveric/shared/widgets/director/header.dart';
import 'package:reveric/shared/widgets/screenplay/director_workspace.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import '../../director/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUpAll(() async {
    await initializeDirectorTest();
    await PromptTemplateService.loadAll();
    temp = await Directory.systemTemp.createTemp('reveric-canvas-page-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => temp.path,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => false,
        );
    await RevericPaths.initialize();
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
    await temp.delete(recursive: true);
  });
  setUp(() => rootBundle.clear());
  testWidgets('empty canvas opens without episodes and adds editable video', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppDatabase.forTest(NativeDatabase.memory());
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    await ScreenplayService(db).createCanvasStructure();
    await app.novelDao.create(
      id: 'canvas',
      title: 'Canvas work',
      description: '',
      contentKind: contentKindCanvas,
      contentDatabasePath: db.filePath,
    );
    final novel = (await app.novelDao.get('canvas'))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(app),
          appSettingsDatabaseProvider.overrideWithValue(app),
          novelContentDatabaseProvider(db.filePath).overrideWithValue(db),
        ],
        child: directorTestApp(WorkspaceEditorPage(novelId: novel.id)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CanvasEmptyStart), findsOneWidget);
    expect(find.byType(ProductionBoard), findsOneWidget);
    expect(find.text('Canvas work'), findsOneWidget);
    expect(find.byTooltip('Edit video'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('canvas-write-prompt')));
    await tester.pumpAndSettle();
    expect(find.byType(CanvasEmptyStart), findsNothing);
    expect(find.byType(ProductionPromptField), findsOneWidget);
    final clips = await db.select(db.productionClips).get();
    expect(clips, hasLength(1));
    expect(clips.single.episodeId, '');
    expect(FocusManager.instance.primaryFocus?.hasFocus, true);
    expect(await db.select(db.screenplayEpisodes).get(), isEmpty);
    expect(tester.takeException(), isNull);
    final boardElement = tester.element(find.byType(ProductionBoard));
    await tester.enterText(
      find.descendant(
        of: find.byType(ProductionPromptField),
        matching: find.byType(TextField),
      ),
      'Saved before editing',
    );
    await tester.tap(find.byTooltip('Add node'));
    await tester.pumpAndSettle();
    expect(find.text('Character'), findsNothing);
    expect(find.text('Text'), findsOneWidget);
    await tester.tap(find.text('Text'));
    await tester.pumpAndSettle();
    expect(
      (await db.select(db.canvasNodes).get()).where(
        (node) => node.type == canvasNodeTypeText,
      ),
      hasLength(1),
    );
    await tester.tap(find.byTooltip('Add node'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Editing').last);
    await tester.pumpAndSettle();
    expect(
      (await db.select(db.productionClips).get()).single.prompt,
      'Saved before editing',
    );
    expect(await db.editingDao.list(), hasLength(1));
    await tester.tap(find.byType(ProductionEditingNode));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(ProductionEditingNode));
    await tester.pumpAndSettle();
    expect(find.byType(EditingRegion), findsOneWidget);
    await tester.tap(find.byTooltip('Back to canvas'));
    await tester.pumpAndSettle();
    expect(find.byType(EditingRegion), findsNothing);
    expect(tester.element(find.byType(ProductionBoard)), same(boardElement));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await db.close();
    await app.close();
  });
  testWidgets('text node composer sends the request to chat on submit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppDatabase.forTest(NativeDatabase.memory());
    // Configure a local test endpoint so the real composer is available; never submit.
    await app
        .into(app.aiProviders)
        .insert(
          AiProvidersCompanion.insert(
            id: 'test',
            name: 'Test',
            type: 'openai',
            enabled: const Value(true),
            apiKey: const Value('test-only'),
            baseUrl: const Value('http://127.0.0.1:9'),
            models: const Value(['test-model']),
          ),
        );
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    await ScreenplayService(db).createCanvasStructure();
    await app.novelDao.create(
      id: 'canvas',
      title: 'Canvas',
      description: '',
      contentKind: contentKindCanvas,
      contentDatabasePath: db.filePath,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(app),
          appSettingsDatabaseProvider.overrideWithValue(app),
          novelContentDatabaseProvider(db.filePath).overrideWithValue(db),
        ],
        child: directorTestApp(const WorkspaceEditorPage(novelId: 'canvas')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add node'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Text'));
    await tester.pumpAndSettle();
    final node = (await db.select(db.canvasNodes).get()).singleWhere(
      (node) => node.type == canvasNodeTypeText,
    );
    expect(find.text('Write it yourself'), findsOneWidget);
    expect(find.byType(AiChatPanel), findsNothing);
    // 起点只填进节点下方的输入框，不打开聊天。
    await tester.tap(find.text('Draft a storyboard script'));
    await tester.pumpAndSettle();
    expect(find.byType(AiChatPanel), findsNothing);
    final input = find.descendant(
      of: find.byType(ProductionTextComposer),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(input).controller!.text, contains('分镜脚本'));
    // 输入框自带模型选择，默认落在可用的聊天模型上。
    expect(
      find.descendant(
        of: find.byType(ProductionTextComposer),
        matching: find.text('test-model'),
      ),
      findsOneWidget,
    );
    await tester.enterText(input, '写一份分镜脚本。故事梗概是：门口交接钥匙');
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byType(ProductionTextComposer),
        matching: find.byTooltip('Send'),
      ),
    );
    await tester.pump();
    // 发送后才打开聊天；面板首帧拿到的是带节点 id、用选中模型新开对话并直接提交的草稿。
    final draft = tester
        .widget<AiChatPanel>(find.byType(AiChatPanel))
        .handoffDraft!;
    expect(draft.autoSend, isTrue);
    expect(draft.providerId, 'test');
    expect(draft.model, 'test-model');
    expect(draft.initialText, contains(node.id));
    expect(draft.initialText, contains('门口交接钥匙'));
    // 测试环境不会真正发出请求，只把发送流程推进完。
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    await tester.tap(find.text('Write it yourself'));
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();
    expect(find.text('Write it yourself'), findsNothing);
    // 编辑时标题在卡片外原位输入：点它不会被画布当成点空白而退出编辑。
    final titleInput = find.descendant(
      of: find.byType(ProductionNodeTitleField),
      matching: find.byType(TextField),
    );
    await tester.tap(titleInput);
    await tester.pumpAndSettle();
    expect(find.byType(RevericMarkdownEditor), findsOneWidget);
    await tester.enterText(titleInput, 'Scene notes');
    // 焦点离开标题和正文即保存。
    FocusManager.instance.primaryFocus!.unfocus();
    await tester.pumpAndSettle();
    expect(find.byType(RevericMarkdownEditor), findsNothing);
    expect(
      (await db.select(db.canvasNodes).get())
          .singleWhere((row) => row.id == node.id)
          .title,
      'Scene notes',
    );
    // 非编辑态点卡片外的标题直接进入编辑，焦点落在标题上。
    await tester.tap(find.byType(ProductionNodeTitleField));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(titleInput).focusNode!.hasFocus, isTrue);
    tester
            .widget<RevericMarkdownEditor>(find.byType(RevericMarkdownEditor))
            .controller
            .text =
        'Shared look';
    FocusManager.instance.primaryFocus!.unfocus();
    await tester.pumpAndSettle();
    // 工具条的「查看」在弹窗里放大正文。
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(RevericDialog),
        matching: find.byType(RevericMarkdownPreview),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    // 未选中的节点：点卡片外的标题即选中并进入标题编辑。
    await tester.tap(find.byTooltip('Add node'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Text').last);
    await tester.pumpAndSettle();
    // 新节点落在同一位置并被选中；挪开它，露出第一个节点的标题。
    await (db.update(db.canvasNodes)
          ..where((row) => row.id.isNotValue(node.id)))
        .write(CanvasNodesCompanion(x: Value(node.x + 600)));
    await tester.pumpAndSettle();
    expect(find.byType(RevericMarkdownEditor), findsNothing);
    await tester.tap(find.byKey(ValueKey('node-title/${node.id}')));
    await tester.pumpAndSettle();
    expect(find.byType(RevericMarkdownEditor), findsOneWidget);
    final renamed = tester.widget<TextField>(titleInput);
    expect(renamed.controller!.text, 'Scene notes');
    expect(renamed.focusNode!.hasFocus, isTrue);
    FocusManager.instance.primaryFocus!.unfocus();
    await tester.pumpAndSettle();
    // 其他节点同样在卡片外标题原位改名，写到标题的来源（这里是片段）。
    await tester.tap(find.byTooltip('Add node'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Images').last);
    await tester.pumpAndSettle();
    final image = (await db.select(db.canvasNodes).get()).singleWhere(
      (row) => row.type == canvasNodeTypeImage,
    );
    await tester.tap(find.byType(ProductionNodeTitleField));
    await tester.pumpAndSettle();
    await tester.enterText(titleInput, 'Poster');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(titleInput, findsNothing);
    expect(
      (await (db.select(
        db.productionClips,
      )..where((row) => row.id.equals(image.clipId!))).getSingle()).title,
      'Poster',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await db.close();
    await app.close();
  });
  testWidgets(
    'upload script fills an editable attachment draft without starting a model request',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final script = File('${temp.path}/script.md');
      script.writeAsStringSync('两人在门口交接钥匙。');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/file_selector'),
            (call) async => [script.path],
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/file_selector'),
              null,
            ),
      );
      final app = AppDatabase.forTest(NativeDatabase.memory());
      // Configure a local test endpoint so the real composer is available; never submit.
      await app
          .into(app.aiProviders)
          .insert(
            AiProvidersCompanion.insert(
              id: 'test',
              name: 'Test',
              type: 'openai',
              enabled: const Value(true),
              apiKey: const Value('test-only'),
              baseUrl: const Value('http://127.0.0.1:9'),
              models: const Value(['test-model']),
            ),
          );

      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      await ScreenplayService(db).createCanvasStructure();
      await app.novelDao.create(
        id: 'canvas',
        title: 'Canvas',
        description: '',
        contentKind: contentKindCanvas,
        contentDatabasePath: db.filePath,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(app),
            appSettingsDatabaseProvider.overrideWithValue(app),
            novelContentDatabaseProvider(db.filePath).overrideWithValue(db),
          ],
          child: directorTestApp(const WorkspaceEditorPage(novelId: 'canvas')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AiChatPanel), findsNothing);
      await tester.tap(find.byKey(const ValueKey('canvas-upload-script')));
      await tester.pumpAndSettle();
      final panel = tester.widget<AiChatPanel>(find.byType(AiChatPanel));
      final controller =
          tester
                  .widget<ChatAttachmentInput>(find.byType(ChatAttachmentInput))
                  .controller
              as ChatComposerController;
      expect(controller.snapshot().attachments.values.single.name, 'script.md');
      expect(controller.text, contains('暂不生成媒体'));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CanvasWorkPage)),
      );
      expect(
        container
            .read(aiChatRuntimeProvider(panel.activeSessionId))
            .isRequestInFlight,
        false,
      );
      expect(
        container.read(aiChatSessionProvider(panel.activeSessionId)).messages,
        isEmpty,
      );
      final input = find.byWidgetPredicate(
        (widget) => widget is TextField && widget.controller == controller,
      );
      await tester.enterText(input, '${controller.text} 请先核对顺序。');
      expect(controller.snapshot().attachments, hasLength(1));
      expect(controller.text, contains('请先核对顺序'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await db.close();
      await app.close();
    },
  );

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets(
      '$platform editing and director keep window-safe return/export controls',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final app = AppDatabase.forTest(NativeDatabase.memory());
        final db = NovelContentDatabase.forTest(NativeDatabase.memory());
        await ScreenplayService(db).createCanvasStructure();
        await app.novelDao.create(
          id: 'canvas',
          title: 'Window-safe work',
          description: '',
          contentKind: contentKindCanvas,
          contentDatabasePath: db.filePath,
        );
        final novel = (await app.novelDao.get('canvas'))!;
        final blocked = platform == TargetPlatform.windows
            ? Rect.fromLTWH(
                1280 - DesktopWindowFrame.trailingInset,
                0,
                DesktopWindowFrame.trailingInset,
                DesktopWindowFrame.titleBarHeight,
              )
            : const Rect.fromLTWH(
                0,
                0,
                DesktopWindowFrame.macosTrafficLightWidth,
                DesktopWindowFrame.titleBarHeight,
              );
        void safe(Finder control) {
          expect(tester.getRect(control).overlaps(blocked), false);
          expect(
            tester.getRect(control).top,
            greaterThanOrEqualTo(DesktopWindowFrame.titleBarHeight),
          );
        }

        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                appDatabaseProvider.overrideWithValue(app),
                appSettingsDatabaseProvider.overrideWithValue(app),
                novelContentDatabaseProvider(db.filePath).overrideWithValue(db),
              ],
              child: directorTestApp(
                CanvasWorkPage(
                  novel: novel,
                  directorViewportBuilder: (_, _) => const SizedBox.expand(),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Add node'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Editing').last);
          await tester.pumpAndSettle();
          await tester.tap(find.byType(ProductionEditingNode));
          await tester.pump(const Duration(milliseconds: 100));
          await tester.tap(find.byType(ProductionEditingNode));
          await tester.pumpAndSettle();
          final region = tester.widget<EditingRegion>(
            find.byType(EditingRegion),
          );
          final container = ProviderScope.containerOf(
            tester.element(find.byType(CanvasWorkPage)),
          );
          final session = container
              .read(editingSessionsProvider)
              .get(
                container.read(editingServiceProvider(db.filePath)),
                region.editingId,
              );
          session.commit(
            session.document!.copyWith(
              clips: const [
                EditingClip(
                  id: 'text',
                  trackId: 'T1',
                  startFrame: 0,
                  durationFrames: 24,
                  content: EditingTextContent(text: 'Title'),
                ),
              ],
            ),
          );
          await tester.pumpAndSettle();
          final editingBack = find.byTooltip('Back to canvas');
          final editingExport = find.descendant(
            of: find.byType(EditingRegion),
            matching: find.widgetWithText(RevericButton, 'Export'),
          );
          safe(editingBack);
          safe(editingExport);
          expect(
            find.byKey(const ValueKey('canvas-work-title-label')),
            findsOneWidget,
          );
          await tester.tap(editingExport);
          await tester.pumpAndSettle();
          expect(find.byType(EditingExportDialog), findsOneWidget);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          // Return to an empty timeline so this chrome test does not request a poster render.
          session.undo();
          await tester.pumpAndSettle();
          await tester.tap(editingBack);
          await tester.pumpAndSettle();
          expect(find.byType(EditingRegion), findsNothing);
          await tester.tap(find.byTooltip('Add node'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('3D Director').last);
          // Only filesystem initialization runs here; the supplied viewport owns no GPU resources.
          for (
            var i = 0;
            i < 20 && find.byType(DirectorHeader).evaluate().isEmpty;
            i++
          ) {
            await tester.runAsync(
              () async =>
                  Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump();
          }
          await tester.pumpAndSettle();
          expect(find.byType(ScreenplayDirectorWorkspace), findsOneWidget);
          final directorBack = find.descendant(
            of: find.byType(DirectorHeader),
            matching: find.byTooltip('Back'),
          );
          final directorExport = find.byKey(const ValueKey('director-export'));
          safe(directorBack);
          safe(directorExport);
          expect(
            find.byKey(const ValueKey('canvas-work-title-label')),
            findsOneWidget,
          );
          await tester.tap(directorExport);
          await tester.pumpAndSettle();
          expect(find.text('Screenshot'), findsOneWidget);
          expect(find.text('Video'), findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          await tester.tap(directorBack);
          await tester.pumpAndSettle();
          expect(find.byType(DirectorHeader), findsNothing);
          expect(find.byType(ProductionBoard), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await db.close();
          await app.close();
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    for (final width in [640.0, 1280.0]) {
      testWidgets(
        '$platform canvas header at width $width keeps title baseline and commits rename',
        (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          tester.view.physicalSize = Size(width, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final app = AppDatabase.forTest(NativeDatabase.memory());
          final db = NovelContentDatabase.forTest(NativeDatabase.memory());
          await ScreenplayService(db).createCanvasStructure();
          await app.novelDao.create(
            id: 'canvas',
            title: 'Canvas title',
            description: '',
            contentKind: contentKindCanvas,
            contentDatabasePath: db.filePath,
          );
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                appDatabaseProvider.overrideWithValue(app),
                appSettingsDatabaseProvider.overrideWithValue(app),
                novelContentDatabaseProvider(db.filePath).overrideWithValue(db),
              ],
              child: directorTestApp(
                const WorkspaceEditorPage(novelId: 'canvas'),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(CanvasWorkPage), findsOneWidget);
          final title = tester.getRect(
            find.byKey(const ValueKey('canvas-work-title-label')),
          );
          expect(
            title.center.dy,
            closeTo(DesktopWindowFrame.titleBarHeight / 2, 1),
          );
          final specs = tester.getRect(find.byType(ProductionSpecChip));
          expect(
            specs.top,
            greaterThanOrEqualTo(
              platform == TargetPlatform.windows
                  ? DesktopWindowFrame.titleBarHeight
                  : 0,
            ),
          );
          await app.novelDao.create(
            id: 'taken',
            title: 'Taken',
            description: '',
          );
          await tester.tap(find.byTooltip('Rename'));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('canvas-work-title')),
            'Taken',
          );
          await tester.tap(find.byTooltip('Save'));
          await tester.pumpAndSettle();
          expect((await app.novelDao.get('canvas'))!.title, 'Canvas title');
          expect(
            find.byKey(const ValueKey('canvas-work-title')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await tester.tap(find.byKey(const ValueKey('canvas-work-title')));
          tester.testTextInput.updateEditingValue(
            const TextEditingValue(
              text: '画布新标题',
              selection: TextSelection.collapsed(offset: 5),
              composing: TextRange(start: 0, end: 5),
            ),
          );
          await tester.pump();
          expect(FocusManager.instance.primaryFocus?.hasFocus, true);
          tester.testTextInput.updateEditingValue(
            const TextEditingValue(
              text: '画布新标题',
              selection: TextSelection.collapsed(offset: 5),
            ),
          );
          await tester.pump();
          expect(FocusManager.instance.primaryFocus?.hasFocus, true);
          await tester.tap(find.byTooltip('Save'));
          await tester.pumpAndSettle();
          expect((await app.novelDao.get('canvas'))!.title, '画布新标题');
          expect(find.text('画布新标题'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await db.close();
          await app.close();
          debugDefaultTargetPlatformOverride = null;
        },
      );
    }
  }
}

// 职责: 测试章节正文编辑器的自动缩进、Tab 输入、minimap、行线、实体缓存、查找与选区工具条交互。
// 关联文件:
//   lib/desktop/widgets/workspace/chapter_editor.dart
//   lib/desktop/widgets/workspace/chapter_editor_minimap.dart
//   lib/desktop/widgets/workspace/chapter_outline_window.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/widgets/editor_line_numbers.dart
//   lib/shared/utils/chapter_entity_recognition.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/widgets/workspace/chapter_editor.dart';
import 'package:reveric/desktop/widgets/workspace/chapter_editor_minimap.dart';
import 'package:reveric/desktop/widgets/workspace/chapter_outline_window.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/utils/chapter_entity_recognition.dart';
import 'package:reveric/shared/widgets/editor_line_numbers.dart';
import 'package:reveric/shared/utils/text_input_formatters.dart';
import 'package:reveric/desktop/widgets/workspace/editor_focus_lines_layer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  setUp(() => rootBundle.clear());

  test('fills the minimap track when the editor document is scrollable', () {
    const contentHeight = 920.0;
    const sampledLineCount = 40;
    final stretchedPitch = chapterEditorMinimapRowPitch(
      sampledLineCount: sampledLineCount,
      contentHeight: contentHeight,
      stretchToTrack: true,
    );
    final naturalPitch = chapterEditorMinimapRowPitch(
      sampledLineCount: sampledLineCount,
      contentHeight: contentHeight,
      stretchToTrack: false,
    );

    expect(
      stretchedPitch * (sampledLineCount - 1),
      closeTo(contentHeight, 0.001),
    );
    expect(naturalPitch, 2.2);
  });

  test('inherits the previous line indentation when pressing enter', () {
    final formatter = ChapterParagraphIndentFormatter();
    TextEditingValue pressEnter(String oldText, int cursor) {
      final newText =
          '${oldText.substring(0, cursor)}\n${oldText.substring(cursor)}';
      return formatter.formatEditUpdate(
        TextEditingValue(
          text: oldText,
          selection: TextSelection.collapsed(offset: cursor),
        ),
        TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: cursor + 1),
        ),
      );
    }

    expect(
      pressEnter('\u3000\u3000第一行', '\u3000\u3000第一行'.length).text,
      '\u3000\u3000第一行\n\u3000\u3000',
    );
    expect(pressEnter(' \t第一行', ' \t第一行'.length).text, ' \t第一行\n \t');
    expect(pressEnter('第一行', '第一行'.length).text, '第一行\n');
    expect(
      pressEnter(
        '\u3000\u3000第一行\u3000\u3000第二行',
        '\u3000\u3000第一行'.length,
      ).text,
      '\u3000\u3000第一行\n\u3000\u3000第二行',
    );
  });

  testWidgets('indents an empty chapter after the final IME segment commits', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _wrapEditor(_editor(content: '', contentController: controller)),
    );
    await tester.pumpAndSettle();
    await tester.showKeyboard(
      find.byKey(const ValueKey('chapter-content-selection-listener')),
    );

    const composingUpdates = [
      TextEditingValue(
        text: 'nihao',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
      TextEditingValue(
        text: '你hao',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 1, end: 4),
      ),
    ];
    for (final value in composingUpdates) {
      tester.testTextInput.updateEditingValue(value);
      await tester.pump();
      expect(controller.value, value);
    }
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '你好',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    expect(controller.text, '\u3000\u3000你好');
    expect(controller.selection.baseOffset, 4);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('hovering a recognized character shows its entity card', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      _wrapEditor(
        _editor(content: '陈屿盯着那个字。', characterProfiles: [_character('陈屿')]),
        lineNumbersEnabled: true,
      ),
    );
    await tester.pumpAndSettle();
    // 实体匹配防抖 200ms，pumpAndSettle 不会等没有排帧的计时器。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    final content = find.byWidgetPredicate(
      (widget) =>
          widget is EditableText && widget.controller.text.startsWith('陈屿'),
    );
    final editable = tester.renderObject<RenderEditable>(
      find.descendant(
        of: content,
        matching: find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_Editable',
        ),
      ),
    );
    final caret = editable.getLocalRectForCaret(const TextPosition(offset: 1));
    final target = editable.localToGlobal(caret.centerLeft);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await tester.pump();
    await mouse.moveTo(target);
    await tester.pumpAndSettle();

    expect(find.text('大学生，记得梦里的水声。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'navigates by minimap and positions the find toolbar after a triple click',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final contentController = TextEditingController();
      String? addedExcerpt;
      String? narratedExcerpt;
      await tester.pumpWidget(
        _wrapEditor(
          _editor(
            content: '',
            contentController: contentController,
            onAddSelectionToChat: (text) => addedExcerpt = text,
            onNarrateSelection: (text) => narratedExcerpt = text,
          ),
          minimapEnabled: true,
          lineNumbersEnabled: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(EditorLineNumbers), findsOneWidget);
      final minimap = find.byKey(const ValueKey('chapter-editor-minimap'));
      expect(minimap, findsOneWidget);
      final scrollView = tester.widget<SingleChildScrollView>(
        find.byKey(const ValueKey('chapter-editor-scroll-view')),
      );
      final position = scrollView.controller!.position;
      expect(position.maxScrollExtent, greaterThan(0));
      final minimapRect = tester.getRect(minimap);
      await tester.tapAt(Offset(minimapRect.center.dx, minimapRect.bottom - 4));
      await tester.pump();
      expect(position.pixels, greaterThan(position.maxScrollExtent * 0.75));
      position.jumpTo(0);
      await tester.pumpAndSettle();

      expect(_focusLineBottoms(tester), isEmpty);
      final idleSelectionListener = tester.widget<Listener>(
        find.byKey(const ValueKey('chapter-content-selection-listener')),
      );
      expect(tester.binding.hasScheduledFrame, isFalse);
      idleSelectionListener.onPointerDown!(
        const PointerDownEvent(buttons: kPrimaryButton),
      );
      idleSelectionListener.onPointerUp!(const PointerUpEvent());
      expect(
        tester.binding.hasScheduledFrame,
        isTrue,
        reason: '抬键后必须主动请求一帧，不能等待鼠标移动才处理工具栏。',
      );
      await tester.pump();

      contentController.text = 'alpha beta alpha';
      await tester.pumpAndSettle();

      final bodyFieldFinder = find.byWidgetPredicate(
        (widget) => widget is TextField && widget.minLines == 30,
      );
      final bodyField = tester.widget<TextField>(bodyFieldFinder);
      expect(bodyField.style?.color, const Color(0xFF175CD3));
      bodyField.focusNode!.requestFocus();
      contentController.selection = TextSelection.collapsed(
        offset: contentController.text.length,
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(bodyField.controller!.text, 'alpha beta alpha\t');
      contentController.text = 'alpha beta alpha';
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pumpAndSettle();

      final queryField = find.byWidgetPredicate(
        (widget) => widget is TextField && widget.decoration?.hintText == '查找',
      );
      await tester.enterText(queryField, 'alpha');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.text('1/2'), findsOneWidget);
      expect(
        bodyField.controller!.selection,
        const TextSelection(baseOffset: 0, extentOffset: 5),
      );
      expect(tester.widget<TextField>(queryField).focusNode!.hasFocus, isTrue);

      final editableState = tester.state<EditableTextState>(
        find.descendant(
          of: bodyFieldFinder,
          matching: find.byType(EditableText),
        ),
      );
      bodyField.focusNode!.requestFocus();
      bodyField.controller!.selection = const TextSelection(
        baseOffset: 6,
        extentOffset: 10,
      );
      await tester.pumpAndSettle();

      expect(bodyField.focusNode!.hasFocus, isTrue);
      expect(
        bodyField.controller!.selection.textInside(bodyField.controller!.text),
        'beta',
      );
      expect(
        editableState.renderEditable.selectionColor?.a,
        greaterThan(0),
        reason: '搜索栏显示时，正文重新获得焦点后仍必须绘制鼠标选区。',
      );

      // macOS 在正文失焦后可能折叠原生选区；查找层必须仍保留首个匹配。
      bodyField.controller!.selection = const TextSelection.collapsed(
        offset: 16,
      );
      await tester.pumpAndSettle();
      expect(find.text('1/2'), findsOneWidget);

      final renderedSpan =
          (bodyField.controller! as ChapterContentStyleController)
              .buildTextSpan(
                context: tester.element(bodyFieldFinder),
                style: bodyField.style,
                withComposing: true,
              );
      final highlightedMatches = renderedSpan.children!
          .whereType<TextSpan>()
          .where((span) => span.text == 'alpha')
          .toList();
      expect(highlightedMatches, isNotEmpty);
      expect(
        highlightedMatches.first.style!.backgroundColor!.a,
        greaterThanOrEqualTo(0.35),
        reason: '搜索框保持焦点时，当前匹配仍需独立绘制高亮',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      const content = '林默端着咖啡走回服务器前面的时候，风扇还在转。';
      contentController.value = const TextEditingValue(
        text: content,
        selection: TextSelection.collapsed(offset: content.length),
      );
      await tester.pumpAndSettle();
      final currentBodyField = tester.widget<TextField>(bodyFieldFinder);
      currentBodyField.focusNode!.requestFocus();
      await tester.pump();

      editableState.renderEditable.selectWordsInRange(
        from: const Offset(12, 12),
        cause: SelectionChangedCause.tap,
      );
      await tester.pump();
      final selectedText = currentBodyField.controller!.selection.textInside(
        content,
      );
      expect(selectedText, isNotEmpty);

      final listener = tester.widget<Listener>(
        find.byKey(const ValueKey('chapter-content-selection-listener')),
      );
      listener.onPointerDown!(const PointerDownEvent(buttons: kPrimaryButton));
      listener.onPointerUp!(const PointerUpEvent());
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('chapter-selection-toolbar-row')),
        findsOneWidget,
      );
      expect(find.text('加入对话'), findsOneWidget);

      await tester.tap(find.text('加入对话'));
      await tester.pumpAndSettle();
      expect(addedExcerpt, selectedText);

      const firstParagraph = '第一段用于留下之前的右键位置。';
      const secondParagraph = '第二段用于验证三击选段后，工具栏跟随当前选区。';
      const paragraphContent = '$firstParagraph\n\n\n$secondParagraph';
      contentController.value = const TextEditingValue(
        text: paragraphContent,
        selection: TextSelection.collapsed(offset: paragraphContent.length),
      );
      await tester.pumpAndSettle();

      final renderEditable = editableState.renderEditable;
      Offset globalPositionForOffset(int offset) {
        final caretRect = renderEditable.getLocalRectForCaret(
          TextPosition(offset: offset),
        );
        return renderEditable.localToGlobal(caretRect.center);
      }

      final previousContextMenuPosition = globalPositionForOffset(3);
      await tester.tapAt(
        previousContextMenuPosition,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(
        renderEditable.lastSecondaryTapDownPosition,
        previousContextMenuPosition,
      );

      await tester.pump(kDoubleTapTimeout);
      final secondParagraphOffset =
          paragraphContent.indexOf(secondParagraph) + 5;
      final tripleClickPosition = globalPositionForOffset(
        secondParagraphOffset,
      );
      final primaryGesture = await tester.startGesture(
        tripleClickPosition,
        pointer: 8,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await primaryGesture.up();
      await tester.pump();
      for (var click = 0; click < 2; click++) {
        await primaryGesture.down(tripleClickPosition);
        await tester.pump();
        await primaryGesture.up();
        await tester.pump();
      }
      await tester.pumpAndSettle(kDoubleTapTimeout);

      final paragraphSelection = contentController.selection;
      expect(
        paragraphSelection.textInside(paragraphContent),
        contains(secondParagraph),
      );
      expect(
        find.byKey(const ValueKey('chapter-selection-toolbar-row')),
        findsOneWidget,
      );

      final glyphHeights = editableState.getGlyphHeights();
      final selectionAnchors = TextSelectionToolbarAnchors.fromSelection(
        renderBox: renderEditable,
        startGlyphHeight: glyphHeights.startGlyphHeight,
        endGlyphHeight: glyphHeights.endGlyphHeight,
        selectionEndpoints: renderEditable.getEndpointsForSelection(
          paragraphSelection,
        ),
      );
      final toolbarRect = tester.getRect(
        find.byKey(const ValueKey('chapter-selection-toolbar-row')),
      );
      expect(
        (toolbarRect.bottom - selectionAnchors.primaryAnchor.dy).abs(),
        lessThanOrEqualTo(24),
        reason:
            '三击后的工具栏必须贴近当前段落，不能停留在之前的右键位置。'
            ' toolbar=$toolbarRect anchors=$selectionAnchors',
      );
      expect(
        (toolbarRect.center.dx - selectionAnchors.primaryAnchor.dx).abs(),
        lessThanOrEqualTo(24),
        reason: '三击后的工具栏必须水平居中于当前段落选区。',
      );
      await tester.tap(find.text('朗读选中内容'));
      await tester.pumpAndSettle();
      expect(narratedExcerpt, paragraphSelection.textInside(paragraphContent));

      const entity = ChapterEntityMention(
        entityType: entityTypeCharacter,
        id: 'character_1',
        label: '张三',
      );
      final recognitionController = ChapterContentStyleController(text: '张三')
        ..updateStyleConfig(
          catalog: const [entity],
          baseStyle: const TextStyle(),
          entityStyle: const TextStyle(fontStyle: FontStyle.italic),
          activeFindMatch: null,
          findHighlightColor: Colors.yellow,
        );
      recognitionController.buildTextSpan(
        context: tester.element(bodyFieldFinder),
        style: const TextStyle(),
        withComposing: true,
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(recognitionController.currentMatchesForText('张三'), hasLength(1));

      recognitionController.updateStyleConfig(
        catalog: const [],
        baseStyle: const TextStyle(),
        entityStyle: const TextStyle(fontStyle: FontStyle.italic),
        activeFindMatch: null,
        findHighlightColor: Colors.yellow,
      );
      expect(
        recognitionController.currentMatchesForText('张三'),
        isEmpty,
        reason: '关闭实体识别后必须立即清掉旧匹配，不能等防抖结束才消失。',
      );
      recognitionController.dispose();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      contentController.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}

Widget _editor({
  required String content,
  TextEditingController? contentController,
  ValueChanged<String>? onAddSelectionToChat,
  ValueChanged<String>? onNarrateSelection,
  List<CharacterProfile> characterProfiles = const [],
}) {
  final titleController = TextEditingController(text: '2.0版本开发');
  final outlineController = TextEditingController();
  return ChapterEditor(
    chapters: [_chapter(content: content)],
    characterProfiles: characterProfiles,
    locations: const [],
    skillEntries: const [],
    items: const [],
    creatureEntries: const [],
    factionEntries: const [],
    selectedChapter: _chapter(content: content),
    titleController: titleController,
    outlineController: outlineController,
    outlineWindowSession: ChapterOutlineWindowSession(
      titleController: titleController,
      outlineController: outlineController,
    ),
    contentController:
        contentController ?? TextEditingController(text: content),
    titleUndoController: UndoHistoryController(),
    outlineUndoController: UndoHistoryController(),
    contentUndoController: UndoHistoryController(),
    titleFocusNode: FocusNode(),
    outlineFocusNode: FocusNode(),
    contentFocusNode: FocusNode(),
    onCreateChapter: () async {},
    onAddSelectionToChat: onAddSelectionToChat,
    onNarrateSelection: onNarrateSelection,
  );
}

Widget _wrapEditor(
  Widget child, {
  bool minimapEnabled = false,
  bool lineNumbersEnabled = false,
}) {
  return EasyLocalization(
    key: UniqueKey(),
    supportedLocales: const [Locale('zh', 'CN')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('zh', 'CN'),
    startLocale: const Locale('zh', 'CN'),
    child: Builder(
      builder: (context) {
        return ProviderScope(
          overrides: [
            editorFontFamilyProvider.overrideWithValue('Georgia'),
            editorFontSizeProvider.overrideWithValue(24),
            editorFontColorProvider.overrideWithValue(const Color(0xFF175CD3)),
            editorLetterSpacingProvider.overrideWithValue(0),
            editorLineHeightProvider.overrideWithValue(1.8),
            editorMinimapEnabledProvider.overrideWithValue(minimapEnabled),
            editorLineNumbersEnabledProvider.overrideWithValue(
              lineNumbersEnabled,
            ),
            editorLineEnabledProvider.overrideWithValue(true),
            editorLineStyleProvider.overrideWithValue(
              EditorLineStyle.sparseDashed,
            ),
            editorLineColorHexProvider.overrideWithValue('#D8A15D'),
            editorEntityRecognitionEnabledProvider.overrideWithValue(true),
            editorEntityItalicProvider.overrideWithValue(true),
            editorEntityHighlightProvider.overrideWithValue(false),
            editorEntityHighlightColorHexProvider.overrideWithValue(
              '#33FFD54F',
            ),
            editorEntityUnderlineProvider.overrideWithValue(false),
            editorEntityBoldProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData(),
            // 主题挂在 builder 上，Overlay 里的实体悬浮卡也能读到。
            builder: (context, app) =>
                RevericTheme(data: RevericThemeData.reveric, child: app!),
            home: Scaffold(body: SizedBox(width: 1200, child: child)),
          ),
        );
      },
    ),
  );
}

List<double> _focusLineBottoms(WidgetTester tester) {
  final paints = tester.widgetList<CustomPaint>(find.byType(CustomPaint));
  List<double>? lineBottoms;
  for (final paint in paints) {
    final painter = paint.painter;
    if (painter == null || painter is! EditorFocusLinePainter) {
      continue;
    }
    lineBottoms = List<double>.from(painter.lineBottoms);
  }
  return lineBottoms ?? const <double>[];
}

CharacterProfile _character(String name) => CharacterProfile(
  id: 'character_1',
  name: name,
  role: 'protagonist',
  gender: 'unknown',
  aliases: const [],
  tags: const [],
  biography: '大学生，记得梦里的水声。',
  appearance: '',
  description: '',
  currentState: '',
  identity: '',
  age: '',
  motivation: '',
  arc: '',
  personality: '',
  behaviorTags: const [],
  sortOrder: 0,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  deletedAt: notDeletedSentinel,
);

Chapter _chapter({required String content}) {
  final now = DateTime(2026);
  return Chapter(
    id: 'chapter_1',
    type: nodeTypeChapter,
    siblingOrder: 0,
    title: '2.0版本开发',
    content: content,
    createdAt: now,
    updatedAt: now,
    deletedAt: notDeletedSentinel,
    chapterNum: 12,
  );
}

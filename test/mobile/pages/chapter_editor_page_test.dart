// 职责: 验证移动端章节编辑器的回车缩进、Tab 输入与 AI 外部写入并发契约 — 自己落盘的回流不回灌、
//       AI 写入按字段回灌、用户正在编辑的字段不被覆盖。
// 关联文件:
//   lib/mobile/pages/chapter_editor_page.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/services/working_overlay.dart
//   lib/shared/utils/text_input_formatters.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/text-input-ime.md

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/mobile/pages/chapter_editor_page.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/content_status.dart';
import 'package:reveric/shared/models/novel_type.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/utils/text_input_formatters.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _databasePath = 'mobile_chapter_editor_test';
// 编辑器防抖 800ms，用例统一多等一点覆盖它。
const _pastAutoSaveDebounce = Duration(milliseconds: 900);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  late NovelContentDatabase contentDatabase;
  late AppDatabase appDatabase;
  late NovelContentService contentService;
  late WorkingOverlayService overlayService;
  late String chapterId;

  setUp(() async {
    rootBundle.clear();
    contentDatabase = NovelContentDatabase.forTest(NativeDatabase.memory());
    appDatabase = AppDatabase.forTest(NativeDatabase.memory());
    contentService = NovelContentService(contentDatabase);
    overlayService = WorkingOverlayService(
      contentDatabase,
      contentService,
      novelActionsService: NovelActionsService(appDatabase),
    );
    chapterId = await contentService.createChapter(
      siblingOrder: 1,
      title: '原标题',
    );
    await contentService.updateChapterContent(
      chapterId: chapterId,
      title: '原标题',
      outline: '',
      content: '旧正文',
    );
  });

  tearDown(() async {
    await contentDatabase.close();
    await appDatabase.close();
  });

  /// 返回 (标题 controller, 正文 controller)。编辑器只有这两个 TextField，
  /// 顺序即标题在前、正文在后。
  Future<(TextEditingController, TextEditingController)> pumpEditor(
    WidgetTester tester, {
    required Color Function() highlightBackground,
  }) async {
    await tester.pumpWidget(
      _wrap(
        ProviderScope(
          overrides: [
            novelContentDatabaseProvider(
              _databasePath,
            ).overrideWithValue(contentDatabase),
            novelContentServiceProvider(
              _databasePath,
            ).overrideWithValue(contentService),
            workingOverlayServiceProvider(
              _databasePath,
            ).overrideWithValue(overlayService),
            editorFontFamilyProvider.overrideWithValue('Georgia'),
            editorFontSizeProvider.overrideWithValue(16),
            editorFontColorProvider.overrideWithValue(const Color(0xFF175CD3)),
            editorLetterSpacingProvider.overrideWithValue(0),
            editorLineHeightProvider.overrideWithValue(1.8),
            editorLineNumbersEnabledProvider.overrideWithValue(false),
            editorDialogueHighlightEnabledProvider.overrideWithValue(true),
            editorHighlightColorProvider.overrideWith(
              (ref) => highlightBackground(),
            ),
            editorLineEnabledProvider.overrideWithValue(false),
            editorLineStyleProvider.overrideWithValue(
              EditorLineStyle.sparseDashed,
            ),
            editorLineColorHexProvider.overrideWithValue('#D8A15D'),
            editorEntityRecognitionEnabledProvider.overrideWithValue(true),
            editorEntityItalicProvider.overrideWithValue(false),
            editorEntityHighlightProvider.overrideWithValue(false),
            editorEntityHighlightColorHexProvider.overrideWithValue(
              '#33FFD54F',
            ),
            editorEntityUnderlineProvider.overrideWithValue(false),
            editorEntityBoldProvider.overrideWithValue(false),
          ],
          child: MobileChapterEditorPage(
            novel: _novel(_databasePath),
            databasePath: _databasePath,
            initialChapterId: chapterId,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (
      tester.widget<TextField>(find.byType(TextField).at(0)).controller!,
      tester.widget<TextField>(find.byType(TextField).at(1)).controller!,
    );
  }

  // 三段场景写在同一个 testWidgets 里：同文件第二个 testWidgets 挂载时
  // EasyLocalization 不再构建 MaterialApp.home，页面起不来（AGENTS.md
  // 「Widget 测试隔离规则」：隔离成本过高时不要靠加补丁迁就测试）。
  // 它们本就是同一份并发编辑契约的连续演进，顺序走一遍也更贴近真实使用。
  testWidgets('编辑器与 AI 外部写入的并发编辑契约', (tester) async {
    var highlightBackground = const Color(0x6642A5F5);
    final (title, body) = await pumpEditor(
      tester,
      highlightBackground: () => highlightBackground,
    );
    expect(title.text, '原标题');
    expect(body.text, '旧正文');
    expect(
      tester
          .widget<TextField>(find.byType(TextField).at(1))
          .inputFormatters
          ?.whereType<PasteSizeLimitTextInputFormatter>(),
      hasLength(1),
      reason: '章节正文仍须保留单次大段粘贴限制',
    );
    expect(
      tester
          .widget<TextField>(find.byType(TextField).at(1))
          .inputFormatters
          ?.whereType<ChapterParagraphIndentFormatter>(),
      hasLength(1),
      reason: '移动端章节正文回车须继承上一行的行首缩进',
    );
    final bodyField = find.byType(TextField).at(1);
    expect(
      tester.widget<TextField>(bodyField).style?.color,
      const Color(0xFF175CD3),
    );
    final bodyFocusNode = tester
        .widget<EditableText>(
          find.descendant(of: bodyField, matching: find.byType(EditableText)),
        )
        .focusNode;
    bodyFocusNode.requestFocus();
    body.selection = TextSelection.collapsed(offset: body.text.length);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(body.text, '旧正文\t', reason: 'Tab 键应写入正文，而不是移动焦点');
    await tester.pump(_pastAutoSaveDebounce);
    await tester.pumpAndSettle();
    expect(
      (await contentService.getChapterById(chapterId))?.content,
      '旧正文\t',
      reason: 'Tab 输入必须触发与普通正文输入相同的自动保存链路',
    );

    // 1. 自己落盘后的 DB 回流是回声，不能拿它覆盖正在输入的正文。
    await tester.enterText(find.byType(TextField).at(1), '旧正文\n\n');
    await tester.pump(_pastAutoSaveDebounce);
    await tester.pumpAndSettle();

    expect(body.text, '旧正文\n\n', reason: '写入侧归一化后的回流若被当成外部改写回灌，会吃掉刚敲的段末空行');
    expect(
      body.selection.baseOffset,
      '旧正文\n\n'.length,
      reason: '回声不回灌，光标不该被弹到别处',
    );
    expect(
      (await contentService.getChapterById(chapterId))?.content,
      '旧正文\n\n',
      reason: '写入侧不再 trim，段末空行原样落盘',
    );

    // 2. AI 落盘的新正文要回灌，且按原偏移保留光标。
    const aiContent = '她说：“你好。”然后离开。“未写完';
    body.selection = const TextSelection.collapsed(offset: 1);
    await contentService.updateChapterContentPartial(
      chapterId: chapterId,
      content: aiContent,
    );
    await tester.pumpAndSettle();

    expect(body.text, aiContent, reason: '外部写入必须回灌，否则编辑器下一次保存会把它盖掉');
    expect(body.selection.baseOffset, 1, reason: '外部回灌按原偏移 clamp，不是一律跳到文末');
    final editableState = tester.state<EditableTextState>(
      find.descendant(of: bodyField, matching: find.byType(EditableText)),
    );
    final span = editableState.renderEditable.text! as TextSpan;
    expect(span.toPlainText(), aiContent);
    expect(
      span.children!
          .whereType<TextSpan>()
          .where((child) => child.style?.backgroundColor != null)
          .map((child) => child.text),
      ['“你好。”'],
    );
    final adoptedValue = body.value;
    body.value = adoptedValue.copyWith(
      selection: const TextSelection.collapsed(offset: 6),
      composing: const TextRange(start: 3, end: 6),
    );
    await tester.pump();
    final composingSpan = editableState.renderEditable.text! as TextSpan;
    final composingDialogue = composingSpan.children!
        .whereType<TextSpan>()
        .singleWhere((child) => child.text == '“你好');
    expect(composingDialogue.style?.backgroundColor, highlightBackground);
    expect(composingDialogue.style?.decoration, TextDecoration.underline);
    expect(bodyFocusNode.hasFocus, isTrue);
    body.value = adoptedValue;

    // 3. 用户正在改标题时 AI 又改正文：两个字段都不能丢。
    await tester.enterText(find.byType(TextField).at(0), '用户改的标题');
    await tester.pump(const Duration(milliseconds: 100));
    await contentService.updateChapterContentPartial(
      chapterId: chapterId,
      content: 'AI 第二次改写',
    );
    await tester.pumpAndSettle();

    expect(body.text, 'AI 第二次改写', reason: '正文没有本地编辑，应接受 AI 版本');
    expect(title.text, '用户改的标题', reason: '标题正在被编辑，不能被回流覆盖');

    await tester.pump(_pastAutoSaveDebounce);
    await tester.pumpAndSettle();

    final stored = await contentService.getChapterById(chapterId);
    expect(stored?.title, '用户改的标题');
    expect(
      stored?.content,
      'AI 第二次改写',
      reason: '标题的自动保存不能把回灌前的旧正文写回去，覆盖 AI 已落盘的正文',
    );

    // 直接标记刚写入的选区，无需等自动保存防抖。
    const highlightedBody = '刚写的标记。';
    await tester.enterText(bodyField, highlightedBody);
    const markSelection = TextSelection(baseOffset: 3, extentOffset: 5);
    void showMarkMenu([TextSelection selection = markSelection]) {
      body.selection = TextSelection.collapsed(offset: selection.start);
      editableState.userUpdateTextEditingValue(
        body.value.copyWith(selection: selection),
        SelectionChangedCause.longPress,
      );
      expect(editableState.showToolbar(), isTrue);
    }

    showMarkMenu();
    await tester.pumpAndSettle();
    expect(find.text('Remove Highlight'), findsOneWidget);
    await tester.tap(find.text('Highlight'));
    await tester.pumpAndSettle();
    final savedMark =
        (await contentDatabase.select(contentDatabase.chapterHighlights).get())
            .single;
    expect(savedMark.quote, '标记');
    expect(savedMark.colorArgb, isNull);
    expect(
      (await contentService.getChapterById(chapterId))?.content,
      highlightedBody,
    );
    Color? markedBackground([String text = '标记']) {
      final markedSpan = editableState.renderEditable.text! as TextSpan;
      return markedSpan.children!
          .whereType<TextSpan>()
          .where((span) => span.text == text)
          .firstOrNull
          ?.style
          ?.backgroundColor;
    }

    expect(markedBackground(), highlightBackground);

    showMarkMenu();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change Color'));
    await tester.pumpAndSettle();
    final picker = find.byType(AlertDialog);
    final colorField = find.descendant(
      of: picker,
      matching: find.byType(TextField),
    );
    await tester.enterText(colorField, '88EE9944');
    await tester.pump();
    await tester.tap(find.descendant(of: picker, matching: find.text('Save')));
    await tester.pumpAndSettle();
    const customColor = Color(0x88EE9944);
    expect(markedBackground(), customColor);

    highlightBackground = const Color(0x5533AA55);
    ProviderScope.containerOf(
      editableState.context,
      listen: false,
    ).invalidate(editorHighlightColorProvider);
    await tester.pumpAndSettle();
    expect(markedBackground(), customColor);

    await tester.showKeyboard(bodyField);
    showMarkMenu();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use Default Color'));
    await tester.pumpAndSettle();
    expect(markedBackground(), highlightBackground);
    await contentService.setChapterHighlightColor(
      chapterId: chapterId,
      highlightId: savedMark.id,
      colorArgb: customColor.toARGB32(),
    );
    await tester.pumpAndSettle();

    const widerSelection = (start: 1, end: 6);
    const widerText = '写的标记。';
    await contentService.writeChapterHighlight(
      chapterId: chapterId,
      expectedContent: highlightedBody,
      selection: widerSelection,
    );
    await tester.pumpAndSettle();
    expect(markedBackground(widerText), highlightBackground);
    final overwrittenMark =
        (await contentDatabase.select(contentDatabase.chapterHighlights).get())
            .singleWhere((mark) => mark.id == savedMark.id);
    expect(overwrittenMark.deletedAt, isNot(notDeletedSentinel));

    showMarkMenu();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove Highlight'));
    await tester.pumpAndSettle();
    expect(markedBackground(), isNull);
    expect(markedBackground('写的'), highlightBackground);
    expect(markedBackground('。'), highlightBackground);

    List<ChapterHighlight> activeMarks(List<ChapterHighlight> records) =>
        records.where((mark) => mark.deletedAt == notDeletedSentinel).toList();
    final marksTable = contentDatabase.select(
      contentDatabase.chapterHighlights,
    );
    expect(
      activeMarks(await marksTable.get()).map((mark) => mark.quote),
      unorderedEquals(['写的', '。']),
    );

    showMarkMenu(
      TextSelection(baseOffset: 0, extentOffset: highlightedBody.length),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove Highlight'));
    await tester.pumpAndSettle();
    expect(activeMarks(await marksTable.get()), isEmpty);

    final countAfterRemoval = (await marksTable.get()).length;
    showMarkMenu();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove Highlight'));
    await tester.pumpAndSettle();
    expect((await marksTable.get()).length, countAfterRemoval);

    // 先卸载 widget 树释放 ProviderScope 持有的 Drift 订阅，再由 tearDown 关库。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
  });
}

Novel _novel(String databasePath) {
  final now = DateTime(2026);
  return Novel(
    id: 'novel_test',
    title: '测试作品',
    authorName: '',
    description: '',
    status: contentStatusInProgress,
    type: novelTypeOriginal,
    contentKind: contentKindNovel,
    contentDatabasePath: databasePath,
    wordCount: 0,
    draft: false,
    category: '',
    tags: const [],
    createdAt: now,
    updatedAt: now,
    deletedAt: notDeletedSentinel,
  );
}

Widget _wrap(Widget child) {
  return EasyLocalization(
    supportedLocales: const [Locale('en')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('en'),
    startLocale: const Locale('en'),
    child: Builder(
      builder: (context) {
        return RevericTheme(
          data: RevericThemeData.reveric,
          child: MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData(),
            home: child,
          ),
        );
      },
    ),
  );
}

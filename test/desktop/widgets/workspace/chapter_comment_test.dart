// 职责: 测试章节正文批注 — 痕迹叠加、选区工具条入口、气泡新建与落库。
// 关联文件:
//   lib/desktop/widgets/workspace/chapter_editor.dart
//   lib/desktop/widgets/workspace/chapter_comment_highlight.dart
//   lib/desktop/widgets/workspace/chapter_comment_popover.dart
//   lib/shared/models/chapter_comment.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/zh-CN/comment.json
//   assets/translations/en/comment.json
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/i18n.md

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/widgets/workspace/chapter_comment_highlight.dart';
import 'package:reveric/desktop/widgets/workspace/chapter_comment_popover.dart';
import 'package:reveric/desktop/widgets/workspace/chapter_editor.dart';
import 'package:reveric/desktop/widgets/workspace/chapter_outline_window.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/chapter_comment.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/utils/chapter_comment_anchor.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _databasePath = 'desktop_chapter_comment_test';
const _body = '船家的灯笼挂在桅杆上，照见雨水沿着甲板的纹路缓缓淌下去。';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  group('applyChapterCommentHighlight', () {
    final colors = RevericColors.classic;

    test('未解决的批注画实线下划线，已解决的画虚线', () {
      const spans = [TextSpan(text: 'abcdef')];
      final highlighted = applyChapterCommentHighlight(
        spans: spans,
        ranges: const [
          ChapterCommentHighlightRange(
            start: 1,
            end: 3,
            resolved: false,
            active: false,
          ),
          ChapterCommentHighlightRange(
            start: 4,
            end: 5,
            resolved: true,
            active: false,
          ),
        ],
        colors: colors,
      );

      expect(highlighted.map((span) => span.text).join(), 'abcdef');
      final open = highlighted.firstWhere((span) => span.text == 'bc');
      expect(open.style?.decoration, TextDecoration.underline);
      expect(open.style?.decorationStyle, TextDecorationStyle.solid);
      expect(open.style?.decorationColor, colors.accentWarm);

      final resolved = highlighted.firstWhere((span) => span.text == 'e');
      expect(resolved.style?.decorationStyle, TextDecorationStyle.dashed);
      expect(resolved.style?.decorationColor, colors.textSubtle);
    });

    test('保留下层实体样式，只叠 decoration', () {
      const spans = [
        TextSpan(
          text: 'ab',
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
        TextSpan(text: 'cd'),
      ];
      final highlighted = applyChapterCommentHighlight(
        spans: spans,
        ranges: const [
          ChapterCommentHighlightRange(
            start: 0,
            end: 3,
            resolved: false,
            active: false,
          ),
        ],
        colors: colors,
      );

      final entitySegment = highlighted.firstWhere((span) => span.text == 'ab');
      expect(entitySegment.style?.fontStyle, FontStyle.italic);
      expect(entitySegment.style?.decoration, TextDecoration.underline);
    });

    test('锚点越界时整条跳过，不抛异常', () {
      const spans = [TextSpan(text: 'abc')];
      final highlighted = applyChapterCommentHighlight(
        spans: spans,
        ranges: const [
          ChapterCommentHighlightRange(
            start: 2,
            end: 99,
            resolved: false,
            active: false,
          ),
        ],
        colors: colors,
      );

      expect(highlighted, same(spans));
    });

    test('失锚的批注不产生痕迹区间', () {
      final resolved = resolveChapterComments(
        content: _body,
        comments: [
          _comment(id: 'gone', start: 0, end: 4, quote: '这句已经不在了'),
          _comment(id: 'kept', start: 0, end: 2, quote: '船家'),
        ],
      );

      final ranges = chapterCommentHighlightRanges(comments: resolved);
      expect(ranges, hasLength(1));
      expect(ranges.single.start, 0);
      expect(ranges.single.end, 2);
    });
  });

  group('章节编辑器批注链路', () {
    late NovelContentDatabase database;
    late NovelContentService service;
    late String chapterId;

    setUp(() async {
      database = NovelContentDatabase.forTest(NativeDatabase.memory());
      service = NovelContentService(database);
      chapterId = await service.createChapter(siblingOrder: 1, title: '三舱客');
      await service.updateChapterContent(
        chapterId: chapterId,
        title: '三舱客',
        outline: '',
        content: _body,
      );
    });

    tearDown(() async {
      await database.close();
    });

    // 两段场景必须挤在同一个 testWidgets 里：同一文件的第二个 testWidgets 重新
    // 包 EasyLocalization 会拿到空子树（见 .agents/rules/testing.md 同款坑）。
    testWidgets('选区批注全链路：新建落库 → 计数 chip → 展开标记已解决', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final contentController = TextEditingController(text: _body);
      addTearDown(contentController.dispose);
      var chapter = await service.getChapterById(chapterId);

      await tester.pumpWidget(
        _wrap(
          database: database,
          service: service,
          child: _editor(
            chapter: chapter!,
            contentController: contentController,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 还没有批注时不显示计数 chip。
      expect(find.textContaining('批注 '), findsNothing);

      // 选中「灯笼」并抬起指针 → 选区工具条出现，且带「批注」入口。
      final bodyField = tester.widget<TextField>(
        find.byWidgetPredicate(
          (widget) => widget is TextField && widget.minLines == 30,
        ),
      );
      bodyField.focusNode!.requestFocus();
      await tester.pump();
      final start = _body.indexOf('灯笼');
      bodyField.controller!.selection = TextSelection(
        baseOffset: start,
        extentOffset: start + 2,
      );
      await tester.pump();

      final listener = tester.widget<Listener>(
        find.byKey(const ValueKey('chapter-content-selection-listener')),
      );
      listener.onPointerDown!(const PointerDownEvent(buttons: kPrimaryButton));
      listener.onPointerUp!(const PointerUpEvent());
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextButton, '取消高亮'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '高亮'));
      await tester.pumpAndSettle();
      expect(
        (await database.select(database.chapterHighlights).get()).single.quote,
        '灯笼',
      );

      bodyField.controller!.selection = TextSelection(
        baseOffset: start,
        extentOffset: start + 2,
      );
      listener.onPointerDown!(const PointerDownEvent(buttons: kPrimaryButton));
      listener.onPointerUp!(const PointerUpEvent());
      await tester.pumpAndSettle();
      final commentAction = find.widgetWithText(TextButton, '批注');
      expect(commentAction, findsOneWidget);
      expect(find.widgetWithText(TextButton, '更改颜色'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '取消高亮'), findsOneWidget);

      await tester.tap(commentAction);
      await tester.pumpAndSettle();

      // 气泡打开，引文是刚才的选区。
      expect(find.byType(ChapterCommentPopover), findsOneWidget);
      expect(find.text('灯笼'), findsOneWidget);

      await tester.enterText(
        find.descendant(
          of: find.byType(ChapterCommentPopover),
          matching: find.byType(TextField),
        ),
        '这里的灯笼要和第七章呼应。',
      );
      await tester.pumpAndSettle();

      // 保存快捷键已移除；点出气泡时应自动保存当前有效草稿。
      expect(find.textContaining('⌘↩'), findsNothing);
      expect(find.textContaining('Ctrl+↩'), findsNothing);
      await tester.tapAt(const Offset(1300, 900));
      await tester.pumpAndSettle();

      // 落库：一条未解决的批注，引文与内容都对得上。
      chapter = await service.getChapterById(chapterId);
      final stored = chapter!.comments ?? const <ChapterComment>[];
      expect(stored, hasLength(1));
      expect(stored.single.quote, '灯笼');
      expect(stored.single.content, '这里的灯笼要和第七章呼应。');
      expect(stored.single.status, chapterCommentStatusOpen);
      expect(stored.single.deletedAt, isNull);

      // ---- 场景二：重开编辑器，计数 chip 出现，展开后可标记为已解决 ----
      final reloaded = await service.getChapterById(chapterId);
      final secondController = TextEditingController(text: _body);
      addTearDown(secondController.dispose);

      await tester.pumpWidget(
        _wrap(
          database: database,
          service: service,
          child: _editor(
            chapter: reloaded!,
            contentController: secondController,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final badge = find.text('批注 1');
      expect(badge, findsOneWidget);

      await tester.tap(badge);
      await tester.pumpAndSettle();

      expect(find.byType(ChapterCommentPopover), findsOneWidget);
      expect(find.text('这里的灯笼要和第七章呼应。'), findsOneWidget);

      // 悬停出 tooltip：气泡里的 IconButton tooltip 自己也走 OverlayPortal，
      // 它在 layout 阶段回溯到 Overlay 的变换。气泡若用
      // CompositedTransformFollower 定位，中间的 RenderFollowerLayer 会让这一步
      // 命中 framework 断言「paint transform cannot be reliably computed」。
      final resolveButton = find.byTooltip('标记为已解决');
      expect(resolveButton, findsOneWidget);
      final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await hover.addPointer(location: Offset.zero);
      addTearDown(hover.removePointer);
      await hover.moveTo(tester.getCenter(resolveButton));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('标记为已解决'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(resolveButton);
      await tester.pumpAndSettle();

      final afterResolve = (await service.getChapterById(chapterId))!.comments!;
      expect(afterResolve.single.status, chapterCommentStatusResolved);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  });
}

ChapterComment _comment({
  required String id,
  required int start,
  required int end,
  required String quote,
}) {
  final now = DateTime(2026, 8, 17);
  return ChapterComment(
    id: id,
    start: start,
    end: end,
    quote: quote,
    content: '批注内容',
    createdAt: now,
    updatedAt: now,
  );
}

Widget _editor({
  required Chapter chapter,
  required TextEditingController contentController,
}) {
  final titleController = TextEditingController(text: chapter.title ?? '');
  final outlineController = TextEditingController();
  return ChapterEditor(
    chapters: [chapter],
    characterProfiles: const [],
    locations: const [],
    skillEntries: const [],
    items: const [],
    creatureEntries: const [],
    factionEntries: const [],
    selectedChapter: chapter,
    titleController: titleController,
    outlineController: outlineController,
    outlineWindowSession: ChapterOutlineWindowSession(
      titleController: titleController,
      outlineController: outlineController,
    ),
    contentController: contentController,
    titleUndoController: UndoHistoryController(),
    outlineUndoController: UndoHistoryController(),
    contentUndoController: UndoHistoryController(),
    titleFocusNode: FocusNode(),
    outlineFocusNode: FocusNode(),
    contentFocusNode: FocusNode(),
    onCreateChapter: () async {},
    databasePath: _databasePath,
    onFlushForHighlight: () async => true,
  );
}

Widget _wrap({
  required NovelContentDatabase database,
  required NovelContentService service,
  required Widget child,
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
            novelContentDatabaseProvider(
              _databasePath,
            ).overrideWithValue(database),
            novelContentServiceProvider(
              _databasePath,
            ).overrideWithValue(service),
            editorFontFamilyProvider.overrideWithValue('Georgia'),
            editorFontSizeProvider.overrideWithValue(18),
            editorLetterSpacingProvider.overrideWithValue(0),
            editorLineHeightProvider.overrideWithValue(1.8),
            editorMinimapEnabledProvider.overrideWithValue(false),
            editorLineNumbersEnabledProvider.overrideWithValue(false),
            editorLineEnabledProvider.overrideWithValue(false),
            editorEntityRecognitionEnabledProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData(),
            home: RevericTheme(
              data: RevericThemeData.reveric,
              child: Scaffold(body: SizedBox(width: 1200, child: child)),
            ),
          ),
        );
      },
    ),
  );
}

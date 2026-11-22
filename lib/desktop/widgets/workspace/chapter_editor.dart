// 职责: 桌面端章节正文编辑器 — 章节标题、大纲与正文输入展示，承载选区操作，并只读呈现编年史者回填的紧张度、情绪与章内事件。
// 关联文件:
//   lib/desktop/widgets/workspace/novel_workspace_panel.dart
//   lib/desktop/widgets/workspace/chapter_comment_session.dart
//   lib/desktop/widgets/workspace/chapter_comment_popover.dart
//   lib/desktop/widgets/workspace/chapter_outline_window.dart
//   lib/desktop/widgets/ai/chat/chat_onboarding_bubble.dart
//   lib/shared/utils/chapter_entity_recognition.dart
//   lib/shared/models/character_profile.dart
//   lib/shared/widgets/entity_card.dart
//   lib/shared/widgets/editor_line_numbers.dart
//   lib/desktop/widgets/workspace/editor_focus_lines_layer.dart
//   lib/desktop/widgets/workspace/chapter_editor_minimap.dart
//   lib/shared/widgets/md/reveric_markdown_editor.dart
//   lib/shared/widgets/text_find_replace_scope.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/comment.json
//   assets/translations/zh-CN/comment.json
// 遵循的 Rules:
//   .agents/rules/hooks.md

import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/dialog_feedback.dart';
import '../../../shared/components/horizontal_wheel_scroll.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/settings_providers.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/utils/chapter_entity_recognition.dart';
import '../../../shared/utils/text_input_composing.dart';
import '../../../shared/utils/text_input_formatters.dart';
import '../../../shared/widgets/entity_card.dart';
import '../../../shared/widgets/editor_line_numbers.dart';
import '../../../shared/widgets/frame_safe_text_editing_value_builder.dart';
import '../../../shared/widgets/md/reveric_markdown_editor.dart';
import '../../../shared/widgets/text_find_replace_scope.dart';
import 'editor_focus_lines_layer.dart';
import 'chapter_comment_highlight.dart';
import 'chapter_comment_popover.dart';
import 'chapter_comment_session.dart';
import 'chapter_outline_window.dart';
import 'chapter_editor_minimap.dart';
import '../../../shared/models/chapter_comment.dart';
import '../../../shared/utils/chapter_comment_anchor.dart';

/// 章节正文编辑器（桌面端）。
///
/// 不持有状态：标题/大纲/正文 controller 与 focus node 均由父级注入，
/// 与父级现有的 auto-save / 历史记录链路保持一致。
///
/// 当 [selectedChapter] 为 `null` 时显示空状态（提示新建/选择章节）。
class ChapterEditor extends HookConsumerWidget {
  const ChapterEditor({
    super.key,
    required this.chapters,
    required this.characterProfiles,
    required this.locations,
    required this.skillEntries,
    required this.items,
    required this.creatureEntries,
    required this.factionEntries,
    required this.selectedChapter,
    this.chapterNumber,
    required this.titleController,
    required this.outlineController,
    required this.outlineWindowSession,
    required this.contentController,
    required this.titleUndoController,
    required this.outlineUndoController,
    required this.contentUndoController,
    required this.titleFocusNode,
    required this.outlineFocusNode,
    required this.contentFocusNode,
    required this.onCreateChapter,
    this.databasePath,
    this.onAddSelectionToChat,
    this.onNarrateSelection,
  });

  final List<Chapter> chapters;
  final List<CharacterProfile> characterProfiles;
  final List<Location> locations;
  final List<Item> skillEntries;
  final List<Item> items;
  final List<Item> creatureEntries;
  final List<Item> factionEntries;
  final Chapter? selectedChapter;
  final int? chapterNumber;
  final TextEditingController titleController;
  final TextEditingController outlineController;
  final ChapterOutlineWindowSession outlineWindowSession;
  final TextEditingController contentController;
  final UndoHistoryController titleUndoController;
  final UndoHistoryController outlineUndoController;
  final UndoHistoryController contentUndoController;
  final FocusNode titleFocusNode;
  final FocusNode outlineFocusNode;
  final FocusNode contentFocusNode;
  final Future<void> Function() onCreateChapter;

  /// 当前小说内容库路径。为 null 时正文批注整体不启用。
  final String? databasePath;

  /// 把正文选区作为快照引用加入当前 AI 对话。
  final ValueChanged<String>? onAddSelectionToChat;
  final ValueChanged<String>? onNarrateSelection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chapter = selectedChapter;
    // hooks 必须在空章节早返回之前调用，顺序才稳定。
    final commentSession = useChapterCommentSession(
      ref: ref,
      databasePath: databasePath,
      chapterId: chapter?.id,
      stored: chapter?.comments,
    );

    if (chapter == null) {
      return _EmptyChapterState(
        chaptersIsEmpty: chapters.isEmpty,
        onCreateChapter: onCreateChapter,
      );
    }

    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final editorFontFamily = ref.watch(editorFontFamilyProvider);
    final editorFontSize = ref.watch(editorFontSizeProvider);
    final editorFontColor = ref.watch(editorFontColorProvider);
    final editorLetterSpacing = ref.watch(editorLetterSpacingProvider);
    final editorLineHeight = ref.watch(editorLineHeightProvider);
    final minimapEnabled = ref.watch(editorMinimapEnabledProvider);
    final lineNumbersEnabled = ref.watch(editorLineNumbersEnabledProvider);
    final lineEnabled = ref.watch(editorLineEnabledProvider);
    final lineStyle = ref.watch(editorLineStyleProvider);
    final lineColorHex = ref.watch(editorLineColorHexProvider);
    final entityRecognitionEnabled = ref.watch(
      editorEntityRecognitionEnabledProvider,
    );
    final entityItalic = ref.watch(editorEntityItalicProvider);
    final entityHighlight = ref.watch(editorEntityHighlightProvider);
    final entityHighlightColorHex = ref.watch(
      editorEntityHighlightColorHexProvider,
    );
    final entityTextColorHex = ref.watch(editorEntityTextColorHexProvider);
    final entityUnderline = ref.watch(editorEntityUnderlineProvider);
    final entityBold = ref.watch(editorEntityBoldProvider);
    final settings = ref.watch(appSettingsNotifierProvider).asData?.value;
    final outlineWindowAppearance = ChapterOutlineWindowAppearance(
      customBaseTheme: settings?.customTheme?.baseTheme,
      lightOverrides: settings?.customTheme?.lightOverrides ?? const {},
      darkOverrides: settings?.customTheme?.darkOverrides ?? const {},
      theme: settings?.theme ?? AppTheme.classic,
      themeMode: settings?.themeMode ?? AppThemeMode.light,
      fontFamily: editorFontFamily,
      fontSize: editorFontSize,
      letterSpacing: editorLetterSpacing,
      lineHeight: editorLineHeight,
    );

    final entityCatalog = buildChapterEntityCatalog(
      enabled: entityRecognitionEnabled,
      characters: characterProfiles,
      locations: locations,
      skills: skillEntries,
      items: items,
      creatures: creatureEntries,
      factions: factionEntries,
    );

    // 查找栏必须挂在滚动视口外：挂在正文 Stack 内时，跳到屏外匹配会把
    // 搜索框一起滚出视口，表现为「搜索框消失」。
    final editor = TextFindReplaceScope(
      controller: contentController,
      editorFocusNode: contentFocusNode,
      child: ChapterEditorScrollRegion(
        textController: contentController,
        minimapEnabled: minimapEnabled,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.x6l,
            RevericSpacing.x4l,
            RevericSpacing.x6l,
            RevericSpacing.x6l,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: RevericSpacing.lg,
                runSpacing: RevericSpacing.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    chapter.isExtra
                        ? context.t(LocaleKeys.workspaceExtra)
                        : context.t(
                            LocaleKeys.commonChapterNumber,
                            namedArgs: {
                              'number':
                                  '${chapter.chapterNum ?? chapterNumber ?? "?"}',
                            },
                          ),
                    style: typo.uiSemibold.copyWith(color: colors.textMuted),
                  ),
                  _ChapterStatBadge(stat: chapter.stat),
                  // 以下三项由 chronicler 在发布后回填，旧章节为 null 时整块不渲染。
                  if (chapter.tension != null)
                    _ChapterTensionBadge(tension: chapter.tension!),
                  for (final tag in chapter.emotion ?? const <String>[])
                    _ChapterEmotionChip(label: tag),
                  if (!commentSession.isEmpty)
                    _ChapterCommentBadge(session: commentSession),
                ],
              ),
              const SizedBox(height: RevericSpacing.sm),
              _ChapterTitleField(
                controller: titleController,
                undoController: titleUndoController,
                focusNode: titleFocusNode,
                fontFamily: editorFontFamily,
              ),
              const SizedBox(height: RevericSpacing.x2l),
              ChapterOutlineField(
                windowSession: outlineWindowSession,
                windowAppearance: outlineWindowAppearance,
                controller: outlineController,
                undoController: outlineUndoController,
                focusNode: outlineFocusNode,
                fontFamily: editorFontFamily,
                fontSize: editorFontSize,
                letterSpacing: editorLetterSpacing,
                lineHeight: editorLineHeight,
              ),
              ChapterEventsCard(events: chapter.events),
              _ChapterContentField(
                controller: contentController,
                undoController: contentUndoController,
                focusNode: contentFocusNode,
                entityCatalog: entityCatalog,
                fontFamily: editorFontFamily,
                fontSize: editorFontSize,
                fontColor: editorFontColor,
                letterSpacing: editorLetterSpacing,
                lineHeight: editorLineHeight,
                lineEnabled: lineEnabled,
                lineNumbersEnabled: lineNumbersEnabled,
                lineStyle: lineStyle,
                lineColorHex: lineColorHex,
                entityItalic: entityItalic,
                entityHighlight: entityHighlight,
                entityHighlightColorHex: entityHighlightColorHex,
                entityTextColorHex: entityTextColorHex,
                entityUnderline: entityUnderline,
                entityBold: entityBold,
                onAddSelectionToChat: onAddSelectionToChat,
                onNarrateSelection: onNarrateSelection,
                commentSession: commentSession,
              ),
            ],
          ),
        ),
      ),
    );

    return editor;
  }
}

/// 章节标题输入框：focus 时底部出现 1px accent 下划线，松开 focus 淡出。
///
/// 设计上不用 InputDecorator 自带的 underline，以免和 `isDense / contentPadding` 互相
/// 影响布局；下划线用一根独立 [AnimatedContainer] 渲染，TextField 仍保持 borderless。
class _ChapterTitleField extends StatefulWidget {
  const _ChapterTitleField({
    required this.controller,
    required this.undoController,
    required this.focusNode,
    required this.fontFamily,
  });

  final TextEditingController controller;
  final UndoHistoryController undoController;
  final FocusNode focusNode;
  final String fontFamily;

  @override
  State<_ChapterTitleField> createState() => _ChapterTitleFieldState();
}

class _ChapterTitleFieldState extends State<_ChapterTitleField> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _ChapterTitleField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_handleFocusChanged);
      widget.focusNode.addListener(_handleFocusChanged);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_handleFocusChanged);
    super.dispose();
  }

  void _handleFocusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final hasFocus = widget.focusNode.hasFocus;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: widget.controller,
          undoController: widget.undoController,
          focusNode: widget.focusNode,
          style: typo.display.copyWith(
            color: colors.textPrimary,
            fontWeight: FontWeight.w600,
            fontFamily: widget.fontFamily,
          ),
          decoration: InputDecoration(
            hintText: context.t(LocaleKeys.workspaceChapterTitle),
            hintStyle: typo.display.copyWith(
              color: colors.textSubtle,
              fontFamily: widget.fontFamily,
            ),
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero,
            isDense: true,
          ),
        ),
        const SizedBox(height: RevericSpacing.xs),
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          height: 1,
          color: hasFocus
              ? colors.accent.withValues(alpha: 0.55)
              : colors.borderSubtle.withValues(alpha: 0),
        ),
      ],
    );
  }
}

class _ChapterContentField extends StatefulWidget {
  const _ChapterContentField({
    required this.controller,
    required this.undoController,
    required this.focusNode,
    required this.entityCatalog,
    required this.fontFamily,
    required this.fontSize,
    this.fontColor,
    required this.letterSpacing,
    required this.lineHeight,
    this.lineEnabled = false,
    this.lineNumbersEnabled = false,
    this.lineStyle = EditorLineStyle.solid,
    this.lineColorHex = '#FFFF0000',
    this.entityItalic = false,
    this.entityHighlight = false,
    this.entityHighlightColorHex = '#33FFD54F',
    this.entityTextColorHex = '',
    this.entityUnderline = false,
    this.entityBold = false,
    this.onAddSelectionToChat,
    this.onNarrateSelection,
    required this.commentSession,
  });

  final TextEditingController controller;
  final UndoHistoryController undoController;
  final FocusNode focusNode;
  final List<ChapterEntityMention> entityCatalog;
  final String fontFamily;
  final int fontSize;
  final Color? fontColor;
  final double letterSpacing;
  final double lineHeight;
  final bool lineEnabled;
  final bool lineNumbersEnabled;
  final EditorLineStyle lineStyle;
  final String lineColorHex;
  final bool entityItalic;
  final bool entityHighlight;
  final String entityHighlightColorHex;
  final String entityTextColorHex;
  final bool entityUnderline;
  final bool entityBold;
  final ValueChanged<String>? onAddSelectionToChat;
  final ValueChanged<String>? onNarrateSelection;

  /// 批注的状态与行为门面；整簇批注能力都从这一个对象进出。
  final ChapterCommentSession commentSession;

  @override
  State<_ChapterContentField> createState() => _ChapterContentFieldState();
}

/// 章节正文样式控制器：在同一个 [EditableText] 内（重写 [buildTextSpan]）渲染实体高亮，
/// 取代「透明字 TextField + Text.rich overlay」双层 —— 按键时只做一遍全文 layout。
///
/// 实体匹配 [findChapterEntityMatches] 是 O(文本长度 × 实体数) 全文扫描，直接放在每次
/// 按键的同步路径上（正文几千字 × 数十实体）会卡。沿用防抖 + 复用策略：文本/目录变化时
/// 先用上次结果里位置仍吻合的子集（[_stillValidMatches]，纯文本即时渲染、字照常显示），
/// 防抖 200ms 后全量重算并 notifyListeners 重排，高亮在停顿后浮现。
class ChapterContentStyleController extends TextEditingController {
  ChapterContentStyleController({super.text});

  List<ChapterEntityMention> _catalog = const [];
  TextStyle _baseStyle = const TextStyle();
  TextStyle _entityStyle = const TextStyle();
  TextRange? _activeFindMatch;
  Color? _findHighlightColor;
  List<ChapterCommentHighlightRange> _commentRanges = const [];
  RevericColors? _commentColors;

  String? _matchedText;
  int? _matchedCatalogSig;
  List<ChapterEntityMatch>? _matchedResult;
  Timer? _entityMatchDebounce;

  /// 由 [_ChapterContentFieldState] 的 build 每帧纯赋值更新。样式/目录变化靠 widget
  /// rebuild 驱动 [EditableText] 重排，这里不调 notifyListeners（build 期非法）。
  void updateStyleConfig({
    required List<ChapterEntityMention> catalog,
    required TextStyle baseStyle,
    required TextStyle entityStyle,
    required TextRange? activeFindMatch,
    required Color findHighlightColor,
    List<ChapterCommentHighlightRange> commentRanges = const [],
    RevericColors? commentColors,
  }) {
    if (catalog.isEmpty) {
      _entityMatchDebounce?.cancel();
      _entityMatchDebounce = null;
      _matchedText = null;
      _matchedCatalogSig = null;
      _matchedResult = null;
    }
    _catalog = catalog;
    _baseStyle = baseStyle;
    _entityStyle = entityStyle;
    _activeFindMatch = activeFindMatch;
    _findHighlightColor = findHighlightColor;
    _commentRanges = commentRanges;
    _commentColors = commentColors;
  }

  /// 最近一次完整匹配结果中仍适用于 [text] 的部分，供外部测量层安全复用。
  List<ChapterEntityMatch> currentMatchesForText(String text) {
    final cached = _matchedResult;
    if (cached == null) {
      return const <ChapterEntityMatch>[];
    }
    if (text == _matchedText) {
      return cached;
    }
    return _stillValidMatches(cached, text);
  }

  List<ChapterEntityMatch> _entityMatchesFor(String text) {
    final catalog = _catalog;
    final sig = Object.hashAll(catalog.map((entity) => entity.label));
    final cached = _matchedResult;
    if (cached != null && text == _matchedText && sig == _matchedCatalogSig) {
      return cached;
    }
    _entityMatchDebounce?.cancel();
    _entityMatchDebounce = Timer(const Duration(milliseconds: 200), () {
      final latestSig = Object.hashAll(_catalog.map((entity) => entity.label));
      if (value.text != text || latestSig != sig) {
        return;
      }
      final result = findChapterEntityMatches(text, catalog);
      if (value.text != text || latestSig != sig) {
        return;
      }
      _matchedResult = result;
      _matchedText = text;
      _matchedCatalogSig = sig;
      notifyListeners();
    });
    if (cached != null && sig == _matchedCatalogSig) {
      return _stillValidMatches(cached, text);
    }
    return const <ChapterEntityMatch>[];
  }

  /// 仅保留在 [text] 中位置与 label 仍然吻合的旧匹配（O(匹配数)，不全文重扫）。
  List<ChapterEntityMatch> _stillValidMatches(
    List<ChapterEntityMatch> previous,
    String text,
  ) {
    if (previous.isEmpty) {
      return previous;
    }
    final length = text.length;
    final kept = <ChapterEntityMatch>[];
    for (final match in previous) {
      if (match.end <= length &&
          text.substring(match.start, match.end) == match.entity.label) {
        kept.add(match);
      }
    }
    return kept;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = value.text;
    if (text.isEmpty) {
      return TextSpan(style: style);
    }
    // withComposing 忽略：正文不画 IME 组合下划线（与旧双层透明字行为一致）。
    final matches = _entityMatchesFor(text);
    final spans = buildChapterEntityHighlightSpans(
      text: text,
      matches: matches,
      baseStyle: _baseStyle,
      entityStyle: _entityStyle,
    );
    final withFindMatch = applyChapterFindMatchHighlight(
      spans: spans,
      activeMatch: _activeFindMatch,
      highlightColor: _findHighlightColor,
    );
    final commentColors = _commentColors;
    return TextSpan(
      style: style,
      // 批注痕迹叠在最外层：它只动 decoration，不会盖掉实体/查找的背景色。
      children: commentColors == null
          ? withFindMatch
          : applyChapterCommentHighlight(
              spans: withFindMatch,
              ranges: _commentRanges,
              colors: commentColors,
            ),
    );
  }

  @override
  void dispose() {
    _entityMatchDebounce?.cancel();
    super.dispose();
  }
}

@visibleForTesting
List<TextSpan> applyChapterFindMatchHighlight({
  required List<TextSpan> spans,
  required TextRange? activeMatch,
  required Color? highlightColor,
}) {
  if (activeMatch == null ||
      highlightColor == null ||
      !activeMatch.isValid ||
      activeMatch.isCollapsed) {
    return spans;
  }

  var textLength = 0;
  for (final span in spans) {
    textLength += span.text?.length ?? 0;
  }
  if (activeMatch.end > textLength) {
    return spans;
  }

  final highlighted = <TextSpan>[];
  var offset = 0;
  for (final span in spans) {
    final segment = span.text ?? '';
    final segmentStart = offset;
    final segmentEnd = segmentStart + segment.length;
    offset = segmentEnd;

    final overlapStart = activeMatch.start > segmentStart
        ? activeMatch.start
        : segmentStart;
    final overlapEnd = activeMatch.end < segmentEnd
        ? activeMatch.end
        : segmentEnd;
    if (overlapStart >= overlapEnd) {
      highlighted.add(span);
      continue;
    }

    final localStart = overlapStart - segmentStart;
    final localEnd = overlapEnd - segmentStart;
    if (localStart > 0) {
      highlighted.add(
        TextSpan(text: segment.substring(0, localStart), style: span.style),
      );
    }
    highlighted.add(
      TextSpan(
        text: segment.substring(localStart, localEnd),
        style: (span.style ?? const TextStyle()).copyWith(
          backgroundColor: highlightColor,
        ),
      ),
    );
    if (localEnd < segment.length) {
      highlighted.add(
        TextSpan(text: segment.substring(localEnd), style: span.style),
      );
    }
  }
  return highlighted;
}

class _ChapterContentFieldState extends State<_ChapterContentField> {
  // 内部样式控制器：负责在同一 EditableText 内渲染高亮。外部注入的 widget.controller
  // 仍是 auto-save / history / AI / 字数 / 格式化 / 查找替换的唯一数据源，两者双向镜像。
  late final ChapterContentStyleController _styleController;
  var _paragraphIndentFormatter = ChapterParagraphIndentFormatter();
  bool _syncing = false;
  bool _primaryPointerIsDown = false;
  bool _useSelectionAnchorsForToolbar = false;

  // ---- 批注 ----------------------------------------------------------
  final OverlayPortalController _commentOverlay = OverlayPortalController();
  Offset? _pointerDownPosition;

  /// 批注气泡的锚点矩形，量在正文字段自己的坐标系里。
  ///
  /// 不存 global 值：气泡改由 [OverlayChildLayoutInfo.childPaintTransform] 在
  /// layout 阶段换算到 overlay 坐标，那份变换每帧重算，滚动时自动跟随。
  Rect? _commentLocalRect;

  /// 命中测试要用的排版参数，由 build 每帧刷新（指针回调里拿不到 build 局部量）。
  TextStyle? _hitBaseStyle;
  TextStyle? _hitEntityStyle;
  StrutStyle? _hitStrutStyle;
  double? _hitMaxWidth;
  double _hitLeftPadding = 0;

  /// 批注锚点解析结果缓存，避免每帧重扫全文。
  String? _resolvedForText;
  List<ChapterComment>? _resolvedForSource;
  List<ResolvedChapterComment> _resolvedComments = const [];

  OverlayEntry? _hoverOverlay;
  ChapterEntityMention? _hoveredEntity;
  Timer? _hideHoverTimer;
  TextPainter? _hoverPainter;
  String? _hoverPainterText;
  List<ChapterEntityMatch>? _hoverPainterMatches;
  TextStyle? _hoverPainterBaseStyle;
  TextStyle? _hoverPainterEntityStyle;
  StrutStyle? _hoverPainterStrutStyle;
  TextDirection? _hoverPainterTextDirection;
  double? _hoverPainterMaxWidth;

  @override
  void initState() {
    super.initState();
    _styleController = ChapterContentStyleController(
      text: widget.controller.text,
    );
    final selection = widget.controller.selection;
    if (selection.isValid && selection.end <= widget.controller.text.length) {
      _styleController.selection = selection;
    }
    widget.controller.addListener(_externalToInternal);
    _styleController.addListener(_internalToExternal);
  }

  @override
  void didUpdateWidget(covariant _ChapterContentField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entityCatalog.isNotEmpty && widget.entityCatalog.isEmpty) {
      _removeHoverOverlay();
    }
    if (oldWidget.controller != widget.controller) {
      _paragraphIndentFormatter = ChapterParagraphIndentFormatter();
      oldWidget.controller.removeListener(_externalToInternal);
      widget.controller.addListener(_externalToInternal);
      _syncing = true;
      _styleController.value = widget.controller.value;
      _syncing = false;
    }
  }

  // 双向镜像（与 reveric_markdown_editor 同款 _syncing 守卫，防回环）。
  void _externalToInternal() {
    if (_syncing) {
      return;
    }
    _syncing = true;
    _styleController.value = widget.controller.value;
    _syncing = false;
  }

  void _internalToExternal() {
    if (_syncing) {
      return;
    }
    _syncing = true;
    widget.controller.value = _styleController.value;
    _syncing = false;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_externalToInternal);
    _styleController.removeListener(_internalToExternal);
    _styleController.dispose();
    _hoverPainter?.dispose();
    _hideHoverTimer?.cancel();
    _removeHoverOverlay();
    super.dispose();
  }

  void _cancelHideHoverTimer() {
    _hideHoverTimer?.cancel();
    _hideHoverTimer = null;
  }

  void _scheduleHideHoverOverlay() {
    _cancelHideHoverTimer();
    _hideHoverTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) {
        return;
      }
      _removeHoverOverlay();
    });
  }

  void _removeHoverOverlay() {
    _cancelHideHoverTimer();
    _hoverOverlay?.remove();
    _hoverOverlay = null;
    _hoveredEntity = null;
  }

  void _updateHoverOverlay({
    required BuildContext context,
    required Offset globalPosition,
    required ChapterEntityMention entity,
  }) {
    if (_hoveredEntity?.id == entity.id &&
        _hoveredEntity?.entityType == entity.entityType &&
        _hoverOverlay != null) {
      return;
    }

    _removeHoverOverlay();
    _hoveredEntity = entity;

    final overlay = Overlay.of(context);
    _hoverOverlay = OverlayEntry(
      builder: (overlayContext) {
        final screenSize = MediaQuery.sizeOf(overlayContext);
        const cardWidth = 280.0;
        const verticalGap = 12.0;
        var left = globalPosition.dx;
        var top = globalPosition.dy + verticalGap;
        if (left + cardWidth > screenSize.width - RevericSpacing.lg) {
          left = screenSize.width - cardWidth - RevericSpacing.lg;
        }
        if (left < RevericSpacing.lg) {
          left = RevericSpacing.lg;
        }
        if (top > screenSize.height - 200) {
          top = globalPosition.dy - 200 - verticalGap;
        }

        return Positioned(
          left: left,
          top: top,
          width: cardWidth,
          child: MouseRegion(
            onEnter: (_) => _cancelHideHoverTimer(),
            onExit: (_) => _scheduleHideHoverOverlay(),
            child: EntityCard(
              entity: entity,
              surface: EntityCardSurface.floating,
            ),
          ),
        );
      },
    );
    overlay.insert(_hoverOverlay!);
  }

  void _handleHover({
    required BuildContext context,
    required Offset localPosition,
    required String text,
    required TextStyle baseStyle,
    required TextStyle entityStyle,
    required List<ChapterEntityMatch> matches,
    required StrutStyle strutStyle,
    required double maxWidth,
  }) {
    if (matches.isEmpty) {
      _removeHoverOverlay();
      return;
    }

    final textDirection = Directionality.of(context);
    final painter = _hoverTextPainter(
      text: text,
      matches: matches,
      baseStyle: baseStyle,
      entityStyle: entityStyle,
      strutStyle: strutStyle,
      textDirection: textDirection,
      maxWidth: maxWidth,
    );

    // 开行号时正文被 contentPadding 右推，命中坐标要减回去（与批注命中一致）。
    final textPosition = painter.getPositionForOffset(
      localPosition.translate(-_hitLeftPadding, 0),
    );
    final entity = chapterEntityAtTextOffset(
      offset: textPosition.offset,
      matches: matches,
    );
    if (entity == null) {
      _scheduleHideHoverOverlay();
      return;
    }

    _cancelHideHoverTimer();
    _updateHoverOverlay(
      context: context,
      globalPosition:
          (context.findRenderObject() as RenderBox?)?.localToGlobal(
            localPosition,
          ) ??
          Offset.zero,
      entity: entity,
    );
  }

  TextPainter _hoverTextPainter({
    required String text,
    required List<ChapterEntityMatch> matches,
    required TextStyle baseStyle,
    required TextStyle entityStyle,
    required StrutStyle strutStyle,
    required TextDirection textDirection,
    required double maxWidth,
  }) {
    final cached = _hoverPainter;
    if (cached != null &&
        _hoverPainterText == text &&
        _hoverPainterMatches == matches &&
        _hoverPainterBaseStyle == baseStyle &&
        _hoverPainterEntityStyle == entityStyle &&
        _hoverPainterStrutStyle == strutStyle &&
        _hoverPainterTextDirection == textDirection &&
        _hoverPainterMaxWidth == maxWidth) {
      return cached;
    }

    final highlightSpans = buildChapterEntityHighlightSpans(
      text: text,
      matches: matches,
      baseStyle: baseStyle,
      entityStyle: entityStyle,
    );
    // 用与 EditableText 等效的宽度 + 同一 strut 测量，保证命中点与可见字形一致。
    final next = TextPainter(
      text: TextSpan(style: baseStyle, children: highlightSpans),
      textDirection: textDirection,
      strutStyle: strutStyle,
      maxLines: null,
    )..layout(maxWidth: maxWidth);

    _hoverPainter?.dispose();
    _hoverPainter = next;
    _hoverPainterText = text;
    _hoverPainterMatches = matches;
    _hoverPainterBaseStyle = baseStyle;
    _hoverPainterEntityStyle = entityStyle;
    _hoverPainterStrutStyle = strutStyle;
    _hoverPainterTextDirection = textDirection;
    _hoverPainterMaxWidth = maxWidth;
    return next;
  }

  void _handleSelectionPointerDown(PointerDownEvent event) {
    _primaryPointerIsDown = event.buttons & kPrimaryButton != 0;
    _pointerDownPosition = event.localPosition;
    if (!_primaryPointerIsDown) {
      _useSelectionAnchorsForToolbar = false;
    }
  }

  void _handleSelectionPointerCancel(PointerCancelEvent _) {
    _primaryPointerIsDown = false;
    _pointerDownPosition = null;
  }

  /// 本章批注按当前正文校准后的结果（带缓存）。
  List<ResolvedChapterComment> _resolveComments(String text) {
    final source = widget.commentSession.comments;
    if (_resolvedForText == text && identical(_resolvedForSource, source)) {
      return _resolvedComments;
    }
    _resolvedComments = resolveChapterComments(content: text, comments: source);
    _resolvedForText = text;
    _resolvedForSource = source;
    return _resolvedComments;
  }

  /// 单击（非拖选）落在批注痕迹上时打开对应气泡。
  ///
  /// 走 [Listener] 而不是 `TextSpan.recognizer`：后者会在手势竞技场里抢在
  /// TextField 的选区手势之前，点批注文字就没法把光标放进去，且每帧重建 span
  /// 意味着 recognizer 的生命周期没法收敛。
  bool _openCommentAtPointer(Offset localPosition) {
    final session = widget.commentSession;
    final down = _pointerDownPosition;
    if (!session.enabled || session.comments.isEmpty) {
      return false;
    }
    if (down != null && (localPosition - down).distance > kTouchSlop) {
      return false;
    }
    final baseStyle = _hitBaseStyle;
    final entityStyle = _hitEntityStyle;
    final strutStyle = _hitStrutStyle;
    final maxWidth = _hitMaxWidth;
    if (baseStyle == null ||
        entityStyle == null ||
        strutStyle == null ||
        maxWidth == null) {
      return false;
    }

    final text = _styleController.text;
    final resolved = _resolveComments(text);
    if (resolved.isEmpty) {
      return false;
    }

    final painter = _hoverTextPainter(
      text: text,
      matches: _styleController.currentMatchesForText(text),
      baseStyle: baseStyle,
      entityStyle: entityStyle,
      strutStyle: strutStyle,
      textDirection: Directionality.of(context),
      maxWidth: maxWidth,
    );
    // 开行号时正文被 contentPadding 右推，命中坐标要减回去。
    final textPosition = painter.getPositionForOffset(
      localPosition.translate(-_hitLeftPadding, 0),
    );
    final hit = chapterCommentAtTextOffset(
      offset: textPosition.offset,
      comments: resolved,
    );
    if (hit == null) {
      return false;
    }
    session.openThread(hit.comment.id);
    return true;
  }

  void _showToolbarForPointerSelection(PointerUpEvent event) {
    if (!_primaryPointerIsDown) {
      // 右键抬起走系统上下文菜单，不抢去开批注气泡。
      return;
    }
    if (_openCommentAtPointer(event.localPosition)) {
      _primaryPointerIsDown = false;
      return;
    }
    _primaryPointerIsDown = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final selection = _styleController.selection;
      if (!selection.isValid || selection.isCollapsed) {
        return;
      }
      final selectedText = selection.textInside(_styleController.text);
      if (selectedText.trim().isEmpty) {
        return;
      }
      final editableState = _editableTextState();
      if (editableState == null) {
        return;
      }
      _useSelectionAnchorsForToolbar = true;
      // 二击的工具栏在三击按下时会被 Flutter 隐藏；若平台仍保留旧 overlay，
      // 先移除再显示，确保 contextMenuBuilder 用最新段落选区重新计算位置。
      editableState.hideToolbar(false);
      editableState.showToolbar();
    });
    // addPostFrameCallback 不会自行请求新帧；主动排帧，避免回调等到鼠标移动才执行。
    WidgetsBinding.instance.scheduleFrame();
  }

  /// 当前气泡对应的正文区间：新建用选区，查看既有批注用校准后的锚点。
  ChapterCommentAnchor? _activeCommentAnchor() {
    final session = widget.commentSession;
    final draftAnchor = session.draftAnchor;
    if (draftAnchor != null) {
      return draftAnchor;
    }
    final activeId = session.activeId;
    if (activeId == null) {
      return null;
    }
    for (final resolved in _resolveComments(_styleController.text)) {
      if (resolved.comment.id == activeId) {
        return resolved.anchor;
      }
    }
    return null;
  }

  /// 把批注区间的位置量出来，供气泡定位。
  ///
  /// 用 `getBoxesForSelection` 而不是缓存指针坐标：正文滚动或改字后区间会移动，
  /// 每帧按锚点重量一次才不会错位。量出来的是本 widget 局部坐标，换算到 overlay
  /// 坐标那一步交给 [OverlayChildLayoutInfo.childPaintTransform]。
  void _syncCommentAnchorRect() {
    if (!mounted) {
      return;
    }
    final session = widget.commentSession;
    if (!session.hasPopover) {
      if (_commentLocalRect != null || _commentOverlay.isShowing) {
        setState(() {
          _commentLocalRect = null;
        });
        if (_commentOverlay.isShowing) {
          _commentOverlay.hide();
        }
      }
      return;
    }

    final anchor = _activeCommentAnchor();
    final renderEditable = _editableTextState()?.renderEditable;
    final box = context.findRenderObject();
    if (anchor == null || renderEditable == null || box is! RenderBox) {
      return;
    }

    final boxes = renderEditable.getBoxesForSelection(
      TextSelection(baseOffset: anchor.start, extentOffset: anchor.end),
    );
    final editableRect = boxes.isEmpty
        ? renderEditable.getLocalRectForCaret(
            TextPosition(offset: anchor.start),
          )
        : boxes
              .map((textBox) => textBox.toRect())
              .reduce((a, b) => a.expandToInclude(b));

    final globalTopLeft = renderEditable.localToGlobal(editableRect.topLeft);
    final localRect = box.globalToLocal(globalTopLeft) & editableRect.size;

    if (_commentLocalRect == localRect) {
      if (!_commentOverlay.isShowing) {
        _commentOverlay.show();
      }
      return;
    }
    setState(() {
      _commentLocalRect = localRect;
    });
    if (!_commentOverlay.isShowing) {
      _commentOverlay.show();
    }
  }

  EditableTextState? _editableTextState() {
    final focusContext = widget.focusNode.context;
    if (focusContext == null) {
      return null;
    }
    final ancestor = focusContext.findAncestorStateOfType<EditableTextState>();
    if (ancestor != null) {
      return ancestor;
    }

    EditableTextState? found;
    void visit(Element element) {
      if (found != null) {
        return;
      }
      if (element is StatefulElement && element.state is EditableTextState) {
        found = element.state as EditableTextState;
        return;
      }
      element.visitChildren(visit);
    }

    focusContext.visitChildElements(visit);
    return found;
  }

  /// 正文选区菜单：保留系统文本动作，并把章节工具收进横向工具条。
  Widget _buildContextMenu(
    BuildContext context,
    EditableTextState editableState,
  ) {
    final buttonItems = [...editableState.contextMenuButtonItems];
    final onAddSelectionToChat = widget.onAddSelectionToChat;
    final onNarrateSelection = widget.onNarrateSelection;
    final session = widget.commentSession;
    final selection = _styleController.selection;
    ContextMenuButtonItem? emphasizedItem;
    if (selection.isValid && !selection.isCollapsed) {
      final selectedText = selection.textInside(_styleController.text);
      // 章节工具按「批注 / 加入对话 / 朗读」的顺序排在系统文本动作之前；
      // 逆序插入 0 号位，最后一个插入的排最前。
      if (onNarrateSelection != null &&
          selectedText.trim().isNotEmpty &&
          !isTextInputComposing(_styleController)) {
        buttonItems.insert(
          0,
          ContextMenuButtonItem(
            label: context.t(LocaleKeys.workspaceChapterNarrateSelection),
            onPressed: () {
              final value = _styleController.value;
              ContextMenuController.removeAny();
              if (!isTextInputComposing(_styleController) &&
                  value.selection == selection &&
                  selection.end <= value.text.length &&
                  selection.textInside(value.text) == selectedText) {
                onNarrateSelection(selectedText);
              }
            },
          ),
        );
      }
      if (onAddSelectionToChat != null && selectedText.trim().isNotEmpty) {
        buttonItems.insert(
          0,
          ContextMenuButtonItem(
            label: context.t(LocaleKeys.aiAddSelectionToChat),
            onPressed: () {
              ContextMenuController.removeAny();
              onAddSelectionToChat(selectedText);
            },
          ),
        );
      }
      if (session.enabled && selectedText.trim().isNotEmpty) {
        emphasizedItem = ContextMenuButtonItem(
          label: context.t(LocaleKeys.commentAction),
          onPressed: () {
            ContextMenuController.removeAny();
            session.openDraft(
              start: selection.start,
              end: selection.end,
              quote: selectedText,
            );
          },
        );
        buttonItems.insert(0, emphasizedItem);
      }
    }
    return _ChapterSelectionToolbar(
      anchors: _contextMenuAnchors(editableState),
      buttonItems: buttonItems,
      emphasizedItem: emphasizedItem,
      colors: RevericTheme.colorsOf(editableState.context),
      typo: RevericTheme.typographyOf(editableState.context),
    );
  }

  TextSelectionToolbarAnchors _contextMenuAnchors(
    EditableTextState editableState,
  ) {
    final selection = editableState.textEditingValue.selection;
    if (!_useSelectionAnchorsForToolbar ||
        !selection.isValid ||
        selection.isCollapsed) {
      return editableState.contextMenuAnchors;
    }
    final glyphHeights = editableState.getGlyphHeights();
    return TextSelectionToolbarAnchors.fromSelection(
      renderBox: editableState.renderEditable,
      startGlyphHeight: glyphHeights.startGlyphHeight,
      endGlyphHeight: glyphHeights.endGlyphHeight,
      selectionEndpoints: editableState.renderEditable.getEndpointsForSelection(
        selection,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final activeFindMatch = TextFindReplaceScope.activeMatchOf(context);
    final strutStyle = StrutStyle(
      fontSize: widget.fontSize.toDouble(),
      height: widget.lineHeight,
      fontFamily: widget.fontFamily,
      leadingDistribution: TextLeadingDistribution.even,
      forceStrutHeight: true,
    );
    const textHeightBehavior = TextHeightBehavior(
      applyHeightToFirstAscent: true,
      applyHeightToLastDescent: true,
    );
    final baseStyle = typo.body.copyWith(
      color: widget.fontColor ?? colors.textPrimary,
      height: widget.lineHeight,
      fontFamily: widget.fontFamily,
      fontSize: widget.fontSize.toDouble(),
      letterSpacing: widget.letterSpacing,
    );
    final entityStyle = baseStyle.copyWith(
      color: _parseHexColorOrNull(widget.entityTextColorHex),
      backgroundColor: widget.entityHighlight
          ? _parseHexColorOrNull(widget.entityHighlightColorHex)
          : null,
      decoration: widget.entityUnderline
          ? TextDecoration.underline
          : TextDecoration.none,
      decorationColor: colors.accent,
      fontStyle: widget.entityItalic ? FontStyle.italic : FontStyle.normal,
      shadows: widget.entityBold
          ? [
              Shadow(
                color:
                    _parseHexColorOrNull(widget.entityTextColorHex) ??
                    baseStyle.color!,
                offset: const Offset(0.35, 0),
              ),
            ]
          : null,
    );

    final leftPadding = widget.lineNumbersEnabled
        ? editorLineNumbersGutterWidth
        : 0.0;

    // 批注痕迹：按当前正文校准锚点，正在新建的选区也先画上，写的时候不丢焦点感。
    final session = widget.commentSession;
    final resolvedComments = _resolveComments(_styleController.text);
    final commentRanges = [
      ...chapterCommentHighlightRanges(
        comments: resolvedComments,
        activeId: session.activeId,
      ),
      if (session.draftAnchor case final draftAnchor?)
        ChapterCommentHighlightRange(
          start: draftAnchor.start,
          end: draftAnchor.end,
          resolved: false,
          active: true,
        ),
    ];

    // 样式/目录注入内部控制器，其 buildTextSpan 据此在同一 EditableText 内渲染高亮。
    _styleController.updateStyleConfig(
      catalog: widget.entityCatalog,
      baseStyle: baseStyle,
      entityStyle: entityStyle,
      activeFindMatch: activeFindMatch,
      findHighlightColor: colors.accent.withValues(alpha: 0.38),
      commentRanges: commentRanges,
      commentColors: colors,
    );

    // 指针回调里拿不到 build 局部量，命中测试要用的排版参数每帧存一份。
    _hitBaseStyle = baseStyle;
    _hitEntityStyle = entityStyle;
    _hitStrutStyle = strutStyle;
    _hitLeftPadding = leftPadding;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncCommentAnchorRect();
    });

    return LayoutBuilder(
      builder: (context, constraints) {
        // EditableText 内部会预留 _caretMargin；hover 命中与下划线层都按扣减后的
        // 宽度测量，保证换行点与 TextField 内部 RenderEditable 一致。
        final effectiveWidth = constraints.maxWidth - kEditableCaretMargin;
        _hitMaxWidth = effectiveWidth - leftPadding;
        return FrameSafeTextEditingValueBuilder(
          controller: _styleController,
          builder: (context, value, _) {
            final text = value.text;
            final isComposing = value.isComposingRangeValid;
            final selection = value.selection;
            final selectionIsActiveFindMatch =
                activeFindMatch != null &&
                selection.isValid &&
                !selection.isCollapsed &&
                selection.start == activeFindMatch.start &&
                selection.end == activeFindMatch.end;
            final currentMatches = _styleController.currentMatchesForText(text);
            // 下划线层用的 span：复用控制器最近一次完整匹配（缺省退化为纯文本）。
            final fallbackSpan = TextSpan(
              children: buildChapterEntityHighlightSpans(
                text: text,
                matches: currentMatches,
                baseStyle: baseStyle,
                entityStyle: entityStyle,
              ),
            );

            return OverlayPortal.overlayChildLayoutBuilder(
              controller: _commentOverlay,
              overlayChildBuilder: _buildCommentOverlay,
              child: Theme(
                data: Theme.of(context).copyWith(
                  textSelectionTheme: TextSelectionThemeData(
                    selectionColor: colors.accent.withValues(
                      // 当前搜索命中已由 buildTextSpan 单独高亮，只隐藏它自身的
                      // 原生选区；用户在正文里拖出的其他选区仍需保持可见。
                      alpha: selectionIsActiveFindMatch ? 0 : 0.38,
                    ),
                    cursorColor: colors.textPrimary,
                  ),
                ),
                child: MouseRegion(
                  onEnter: (_) => _cancelHideHoverTimer(),
                  onExit: (_) => _scheduleHideHoverOverlay(),
                  onHover: isComposing
                      ? null
                      : (event) {
                          _handleHover(
                            context: context,
                            localPosition: event.localPosition,
                            text: text,
                            baseStyle: baseStyle,
                            entityStyle: entityStyle,
                            matches: currentMatches,
                            strutStyle: strutStyle,
                            maxWidth: effectiveWidth - leftPadding,
                          );
                        },
                  child: Stack(
                    children: [
                      // 单层：实体高亮由 _styleController.buildTextSpan 在 EditableText
                      // 内部直接渲染，不再叠 Text.rich overlay（每键只做一遍 layout）。
                      Listener(
                        key: const ValueKey(
                          'chapter-content-selection-listener',
                        ),
                        onPointerDown: _handleSelectionPointerDown,
                        onPointerUp: _showToolbarForPointerSelection,
                        onPointerCancel: _handleSelectionPointerCancel,
                        child: Focus(
                          skipTraversal: true,
                          canRequestFocus: false,
                          onKeyEvent: (node, event) => handleChapterTabKeyEvent(
                            controller: _styleController,
                            event: event,
                          ),
                          child: TextField(
                            controller: _styleController,
                            undoController: widget.undoController,
                            focusNode: widget.focusNode,
                            contextMenuBuilder: _buildContextMenu,
                            minLines: 30,
                            maxLines: null,
                            keyboardType: TextInputType.multiline,
                            cursorColor: colors.textPrimary,
                            autocorrect: false,
                            enableSuggestions: false,
                            spellCheckConfiguration:
                                const SpellCheckConfiguration.disabled(),
                            strutStyle: strutStyle,
                            style: baseStyle,
                            decoration: InputDecoration(
                              filled: false,
                              border: InputBorder.none,
                              isCollapsed: true,
                              contentPadding: widget.lineNumbersEnabled
                                  ? const EdgeInsets.only(
                                      left: editorLineNumbersGutterWidth,
                                    )
                                  : EdgeInsets.zero,
                              hintText: context.t(
                                LocaleKeys.workspaceChapterBodyHint,
                              ),
                              hintStyle: baseStyle.copyWith(
                                color: colors.textSubtle,
                              ),
                            ),
                            inputFormatters: [
                              _paragraphIndentFormatter,
                              PasteSizeLimitTextInputFormatter(
                                onRejected: (int chars) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        context.t(
                                          LocaleKeys.editorPasteTooLarge,
                                          namedArgs: {'chars': '$chars'},
                                        ),
                                      ),
                                      duration: const Duration(seconds: 3),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (widget.lineEnabled)
                        EditorFocusLinesLayer(
                          lineStyle: widget.lineStyle,
                          lineColor: parseEditorLineColorHex(
                            widget.lineColorHex,
                          ),
                          fallbackSpan: fallbackSpan,
                          maxWidth: effectiveWidth,
                          textDirection: Directionality.of(context),
                          strutStyle: strutStyle,
                          textHeightBehavior: textHeightBehavior,
                          fontSize: widget.fontSize.toDouble(),
                          textScaler: MediaQuery.textScalerOf(context),
                        ),
                      if (widget.lineNumbersEnabled)
                        Positioned.fill(
                          child: Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: SizedBox(
                              width: editorLineNumbersGutterWidth,
                              child: EditorLineNumbers(
                                controller: widget.controller,
                                contentStyle: baseStyle,
                                numberStyle: typo.uiTiny.copyWith(
                                  color: colors.textSubtle,
                                ),
                                lineHeight: widget.lineHeight,
                                width: editorLineNumbersGutterWidth,
                                contentWidth:
                                    effectiveWidth -
                                    editorLineNumbersGutterWidth,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 批注气泡浮层：全屏透明层负责点外面关闭，气泡本体按锚点矩形摆位。
  ///
  /// 定位不用 [CompositedTransformFollower]：它只在合成阶段才建立 paint transform，
  /// 而气泡内部的 Tooltip 也走 OverlayPortal，构建自己的浮层时要在 layout 阶段回溯
  /// 到 Overlay 的变换 —— 中间夹着 RenderFollowerLayer 就会命中 framework 断言
  /// 「paint transform cannot be reliably computed」。改用
  /// [OverlayPortal.overlayChildLayoutBuilder]：`childPaintTransform` 在 layout
  /// 阶段就把正文字段的坐标换算好，每帧重算，滚动依旧跟随。
  Widget _buildCommentOverlay(
    BuildContext overlayContext,
    OverlayChildLayoutInfo info,
  ) {
    final session = widget.commentSession;
    final localRect = _commentLocalRect;
    if (!session.hasPopover || localRect == null) {
      return const SizedBox.shrink();
    }

    // 锚点矩形从正文字段坐标换算到 overlay 坐标。
    final anchorRect = MatrixUtils.transformRect(
      info.childPaintTransform,
      localRect,
    );
    final overlaySize = info.overlaySize;
    const gap = RevericSpacing.sm;
    // 高度按内容估个上限用于翻转判断；估高了只会更早翻到上方，不会错位。
    const estimatedHeight = 280.0;
    final showBelow =
        anchorRect.bottom + gap + estimatedHeight <= overlaySize.height - gap;
    final overflowRight =
        anchorRect.left + chapterCommentPopoverWidth + gap - overlaySize.width;
    final left = anchorRect.left - (overflowRight > 0 ? overflowRight : 0.0);

    final activeComment = session.activeComment;
    final orphaned =
        activeComment != null &&
        _resolveComments(_styleController.text)
                .where((r) => r.comment.id == activeComment.id)
                .firstOrNull
                ?.anchor ==
            null;

    final popover = ChapterCommentPopover(
      key: ValueKey(activeComment?.id ?? 'chapter-comment-draft'),
      comment: activeComment,
      quote: session.activeQuote,
      orphaned: orphaned,
      onSubmit: (content) {
        unawaited(session.submit(content));
      },
      onContentChanged: session.updateContent,
      onClose: () {
        unawaited(session.dismiss());
      },
      onCancel: session.cancel,
      onToggleResolved: activeComment == null
          ? null
          : () => unawaited(session.toggleResolved()),
      onDelete: activeComment == null
          ? null
          : () => unawaited(session.delete()),
    );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              unawaited(session.dismiss());
            },
            child: const SizedBox.expand(),
          ),
        ),
        // 翻转到上方时用 bottom 定位，让气泡的下边缘贴住锚点上沿；气泡高度随内容
        // 变化，用 top 定位会要求先知道高度。
        if (showBelow)
          Positioned(left: left, top: anchorRect.bottom + gap, child: popover)
        else
          Positioned(
            left: left,
            bottom: overlaySize.height - anchorRect.top + gap,
            child: popover,
          ),
      ],
    );
  }
}

class _ChapterSelectionToolbar extends StatelessWidget {
  const _ChapterSelectionToolbar({
    required this.anchors,
    required this.buttonItems,
    required this.emphasizedItem,
    required this.colors,
    required this.typo,
  });

  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> buttonItems;
  final ContextMenuButtonItem? emphasizedItem;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    if (buttonItems.isEmpty) {
      return const SizedBox.shrink();
    }
    final paddingAbove = MediaQuery.paddingOf(context).top + RevericSpacing.sm;
    final localAdjustment = Offset(RevericSpacing.sm, paddingAbove);
    final anchorBelow = anchors.secondaryAnchor ?? anchors.primaryAnchor;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        RevericSpacing.sm,
        paddingAbove,
        RevericSpacing.sm,
        RevericSpacing.sm,
      ),
      child: CustomSingleChildLayout(
        delegate: TextSelectionToolbarLayoutDelegate(
          anchorAbove:
              anchors.primaryAnchor -
              localAdjustment -
              const Offset(0, RevericSpacing.sm),
          anchorBelow:
              anchorBelow -
              localAdjustment +
              const Offset(0, RevericSpacing.sm),
        ),
        child: Material(
          color: colors.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(RevericRadius.large),
            side: BorderSide(color: colors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: HorizontalWheelScroll(
            builder: (context, controller) => SingleChildScrollView(
              controller: controller,
              scrollDirection: Axis.horizontal,
              child: Row(
                key: const ValueKey('chapter-selection-toolbar-row'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var index = 0; index < buttonItems.length; index++) ...[
                    if (index > 0)
                      SizedBox(
                        width: RevericSizes.dividerThickness,
                        height:
                            RevericSizes.buttonHeightSm - RevericSpacing.x2l,
                        child: ColoredBox(color: colors.borderSubtle),
                      ),
                    TextButton(
                      onPressed: buttonItems[index].onPressed,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, RevericSizes.buttonHeightSm),
                        padding: const EdgeInsets.symmetric(
                          horizontal: RevericSpacing.lg,
                        ),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        foregroundColor:
                            identical(buttonItems[index], emphasizedItem)
                            ? colors.accent
                            : colors.textSecondary,
                        textStyle: typo.uiSmall,
                        shape: const RoundedRectangleBorder(),
                      ),
                      child: Text(
                        AdaptiveTextSelectionToolbar.getButtonLabel(
                          context,
                          buttonItems[index],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Color? _parseHexColorOrNull(String hex) {
  final normalized = hex.replaceFirst('#', '');
  final argb = normalized.length == 6 ? 'FF$normalized' : normalized;
  if (argb.length != 8) {
    return null;
  }
  final value = int.tryParse(argb, radix: 16);
  if (value == null) {
    return null;
  }
  return Color(value);
}

class ChapterOutlineField extends StatefulWidget {
  const ChapterOutlineField({
    super.key,
    required this.windowSession,
    required this.windowAppearance,
    required this.controller,
    required this.undoController,
    required this.focusNode,
    required this.fontFamily,
    required this.fontSize,
    required this.letterSpacing,
    required this.lineHeight,
  });

  final ChapterOutlineWindowSession windowSession;
  final ChapterOutlineWindowAppearance windowAppearance;
  final TextEditingController controller;
  final UndoHistoryController undoController;
  final FocusNode focusNode;
  final String fontFamily;
  final int fontSize;
  final double letterSpacing;
  final double lineHeight;

  @override
  State<ChapterOutlineField> createState() => _ChapterOutlineFieldState();
}

class _ChapterOutlineFieldState extends State<ChapterOutlineField> {
  bool _expanded = false;

  void _toggleExpanded() {
    setState(() {
      _expanded = !_expanded;
    });
  }

  Future<void> _openDetachedOutline() => widget.windowSession.open(
    widget.windowAppearance,
    fallbackTitle: context.t(LocaleKeys.workspaceChapterOutline),
  );

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: RevericSpacing.x3l),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(RevericRadius.xl),
        border: Border.all(color: colors.borderSubtle),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header 整行可点击折叠/展开，按钮自身的 onTap 会优先吃掉事件，
          // 不影响里面 IconButton（"独立窗口"）的独立交互。
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _toggleExpanded,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  RevericSpacing.x2l,
                  RevericSpacing.md,
                  RevericSpacing.lg,
                  RevericSpacing.md,
                ),
                child: Row(
                  children: [
                    RevericIcon(
                      RevericIcons.timeline_outlined,
                      size: 16,
                      color: colors.textMuted,
                    ),
                    const SizedBox(width: RevericSpacing.sm),
                    Text(
                      context.t(LocaleKeys.workspaceChapterOutline),
                      style: typo.uiSemibold.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: context.t(LocaleKeys.workspaceOpenOutlineWindow),
                      onPressed: _openDetachedOutline,
                      iconSize: 16,
                      padding: const EdgeInsets.all(RevericSpacing.xs),
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      icon: RevericIcon(
                        RevericIcons.open_in_full_rounded,
                        size: 16,
                        color: colors.textMuted,
                      ),
                    ),
                    const SizedBox(width: RevericSpacing.xs),
                    // 用 AnimatedRotation 让 chevron 旋转 180°，
                    // 与下方 body 的高度动画共享同一节奏。
                    AnimatedRotation(
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.easeInOutCubic,
                      turns: _expanded ? 0.5 : 0,
                      child: RevericIcon(
                        RevericIcons.expand_more_rounded,
                        size: 16,
                        color: colors.textMuted,
                      ),
                    ),
                    const SizedBox(width: RevericSpacing.xs),
                  ],
                ),
              ),
            ),
          ),
          // 单一 AnimatedSize 驱动 divider+body 的整体收起/展开，
          // 避免 AnimatedSwitcher 的 fade 与 size 互相争抢节奏。
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Divider(
                        height: 1,
                        thickness: 1,
                        color: colors.borderSubtle,
                      ),
                      SizedBox(
                        height: 220,
                        child: Padding(
                          padding: const EdgeInsets.all(RevericSpacing.lg),
                          child: RevericMarkdownEditor(
                            controller: widget.controller,
                            undoController: widget.undoController,
                            focusNode: widget.focusNode,
                            hintText: context.t(
                              LocaleKeys.workspaceOutlineContentHint,
                            ),
                            fontFamily: widget.fontFamily,
                            fontSize: widget.fontSize,
                            letterSpacing: widget.letterSpacing,
                            lineHeight: widget.lineHeight,
                          ),
                        ),
                      ),
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

class _ChapterOutlineExpandedDialog extends StatefulWidget {
  const _ChapterOutlineExpandedDialog({
    required this.controller,
    required this.undoController,
    required this.fontFamily,
    required this.fontSize,
    required this.letterSpacing,
    required this.lineHeight,
  });

  final TextEditingController controller;
  final UndoHistoryController undoController;
  final String fontFamily;
  final int fontSize;
  final double letterSpacing;
  final double lineHeight;

  @override
  State<_ChapterOutlineExpandedDialog> createState() =>
      _ChapterOutlineExpandedDialogState();
}

class _ChapterOutlineExpandedDialogState
    extends State<_ChapterOutlineExpandedDialog> {
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final screenSize = MediaQuery.sizeOf(context);
    final dialogWidth = screenSize.width.clamp(720.0, 1120.0);
    final dialogHeight = (screenSize.height * 0.82).clamp(520.0, 820.0);

    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RevericRadius.x2l),
        side: BorderSide(color: colors.borderSubtle),
      ),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: DialogFeedback(
          builder: (context) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  RevericSpacing.x4l,
                  RevericSpacing.x3l,
                  RevericSpacing.x2l,
                  RevericSpacing.x2l,
                ),
                child: Row(
                  children: [
                    RevericIcon(
                      RevericIcons.timeline_outlined,
                      size: 18,
                      color: colors.textMuted,
                    ),
                    const SizedBox(width: RevericSpacing.sm),
                    Expanded(
                      child: Text(
                        context.t(LocaleKeys.workspaceChapterOutline),
                        style: typo.heading2.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: context.t(LocaleKeys.commonClose),
                      onPressed: () => Navigator.of(context).pop(),
                      icon: RevericIcon(
                        RevericIcons.close_rounded,
                        size: 18,
                        color: colors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, thickness: 1, color: colors.borderSubtle),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(RevericSpacing.x3l),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(RevericRadius.xl),
                      border: Border.all(color: colors.borderSubtle),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(RevericSpacing.lg),
                      child: RevericMarkdownEditor(
                        controller: widget.controller,
                        undoController: widget.undoController,
                        focusNode: _focusNode,
                        hintText: context.t(
                          LocaleKeys.workspaceOutlineContentHint,
                        ),
                        fontFamily: widget.fontFamily,
                        fontSize: widget.fontSize,
                        letterSpacing: widget.letterSpacing,
                        lineHeight: widget.lineHeight,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChapterStatBadge extends StatelessWidget {
  const _ChapterStatBadge({required this.stat});

  final String stat;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final isPublished = stat == chapterStatPublished;
    final statusColor = isPublished ? colors.additionBorder : colors.accentWarm;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.sm,
        vertical: RevericSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: isPublished
            ? colors.additionBorder.withValues(alpha: 0.08)
            : colors.accentWarm.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(RevericRadius.full),
        border: Border.all(
          color: isPublished
              ? colors.additionBorder.withValues(alpha: 0.32)
              : colors.accentWarm.withValues(alpha: 0.32),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RevericIcon(
            isPublished
                ? RevericIcons.check_circle
                : RevericIcons.edit_outlined,
            size: 14,
            color: statusColor,
          ),
          const SizedBox(width: RevericSpacing.xs),
          Text(
            isPublished
                ? context.t(LocaleKeys.chapterStatPublished)
                : context.t(LocaleKeys.chapterStatDraft),
            style: typo.uiSmallSemibold.copyWith(color: statusColor),
          ),
        ],
      ),
    );
  }
}

/// 紧张度徽章（1-10）。低分走中性色，高分走暖色/警示色，让张力在一屏内可辨。
class _ChapterTensionBadge extends StatelessWidget {
  const _ChapterTensionBadge({required this.tension});

  final int tension;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final accent = switch (tension) {
      <= 3 => colors.textMuted,
      <= 6 => colors.accentAmber,
      <= 8 => colors.accentWarm,
      _ => colors.error,
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.sm,
        vertical: RevericSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(RevericRadius.full),
        border: Border.all(color: accent.withValues(alpha: 0.32)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RevericIcon(RevericIcons.timeline_outlined, size: 14, color: accent),
          const SizedBox(width: RevericSpacing.xs),
          Text(
            context.t(
              LocaleKeys.workspaceChapterTension,
              namedArgs: {'value': '$tension'},
            ),
            style: typo.uiSmallSemibold.copyWith(color: accent),
          ),
        ],
      ),
    );
  }
}

/// 本章批注计数 chip。点击打开第一条未解决的批注（都解决了就打开最后一条）。
///
/// 放在章节元信息行而不是底部状态栏：状态栏归 NovelWorkspacePanel 管，
/// 把批注塞过去要把 session 一路传上去，反而破坏了这一簇的边界。
class _ChapterCommentBadge extends StatelessWidget {
  const _ChapterCommentBadge({required this.session});

  final ChapterCommentSession session;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final unresolved = session.unresolvedCount;
    final accent = unresolved > 0 ? colors.accentWarm : colors.textMuted;

    return Tooltip(
      message: context.t(LocaleKeys.commentJumpUnresolved),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(RevericRadius.full),
        child: InkWell(
          borderRadius: BorderRadius.circular(RevericRadius.full),
          onTap: () {
            final target = session.comments.firstWhere(
              (comment) => !comment.isResolved,
              orElse: () => session.comments.last,
            );
            session.openThread(target.id);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.sm,
              vertical: RevericSpacing.xxs,
            ),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(RevericRadius.full),
              border: Border.all(color: accent.withValues(alpha: 0.32)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                RevericIcon(
                  RevericIcons.chat_outlined,
                  size: 14,
                  color: accent,
                ),
                const SizedBox(width: RevericSpacing.xs),
                Text(
                  '${context.t(LocaleKeys.commentStatusLabel)} '
                  '${unresolved > 0 ? unresolved : session.comments.length}',
                  style: typo.uiSmallSemibold.copyWith(color: accent),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 情绪标签 chip。纯展示，不参与交互。
class _ChapterEmotionChip extends StatelessWidget {
  const _ChapterEmotionChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.sm,
        vertical: RevericSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(RevericRadius.full),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Text(
        label,
        style: typo.uiSmall.copyWith(color: colors.textSecondary),
      ),
    );
  }
}

/// 「本章事件」只读卡片 —— 展示 chronicler 提取的章内事件序列。
///
/// [events] 为空时整卡片不渲染：绝大多数旧章节没有 events，留一个空卡片会让
/// 编辑器到处是占位坑。视觉沿用 [ChapterOutlineField] 的折叠卡片。
class ChapterEventsCard extends StatefulWidget {
  const ChapterEventsCard({super.key, required this.events});

  final List<Map<String, dynamic>>? events;

  @override
  State<ChapterEventsCard> createState() => _ChapterEventsCardState();
}

class _ChapterEventsCardState extends State<ChapterEventsCard> {
  bool _expanded = false;

  void _toggleExpanded() {
    setState(() {
      _expanded = !_expanded;
    });
  }

  @override
  Widget build(BuildContext context) {
    final events = widget.events ?? const <Map<String, dynamic>>[];
    if (events.isEmpty) {
      return const SizedBox.shrink();
    }

    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: RevericSpacing.x3l),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(RevericRadius.xl),
        border: Border.all(color: colors.borderSubtle),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _toggleExpanded,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  RevericSpacing.x2l,
                  RevericSpacing.md,
                  RevericSpacing.lg,
                  RevericSpacing.md,
                ),
                child: Row(
                  children: [
                    RevericIcon(
                      RevericIcons.format_list_numbered,
                      size: 16,
                      color: colors.textMuted,
                    ),
                    const SizedBox(width: RevericSpacing.sm),
                    Text(
                      context.t(LocaleKeys.workspaceChapterEvents),
                      style: typo.uiSemibold.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: RevericSpacing.sm),
                    Text(
                      '${events.length}',
                      style: typo.uiSmall.copyWith(color: colors.textSubtle),
                    ),
                    const Spacer(),
                    AnimatedRotation(
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.easeInOutCubic,
                      turns: _expanded ? 0.5 : 0,
                      child: RevericIcon(
                        RevericIcons.expand_more_rounded,
                        size: 16,
                        color: colors.textMuted,
                      ),
                    ),
                    const SizedBox(width: RevericSpacing.xs),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Divider(
                        height: 1,
                        thickness: 1,
                        color: colors.borderSubtle,
                      ),
                      Padding(
                        padding: const EdgeInsets.all(RevericSpacing.lg),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (
                              var index = 0;
                              index < events.length;
                              index++
                            ) ...[
                              if (index > 0)
                                const SizedBox(height: RevericSpacing.lg),
                              _ChapterEventRow(
                                index: index + 1,
                                event: events[index],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

class _ChapterEventRow extends StatelessWidget {
  const _ChapterEventRow({required this.index, required this.event});

  final int index;
  final Map<String, dynamic> event;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final title = event['title']?.toString().trim() ?? '';
    final summary = event['summary']?.toString().trim() ?? '';
    final stateChange = event['state_change']?.toString().trim() ?? '';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: RevericSpacing.xxs),
          child: SizedBox(
            width: 20,
            child: Text(
              '$index',
              style: typo.uiTiny.copyWith(color: colors.textSubtle),
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title.isNotEmpty)
                Text(
                  title,
                  style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                ),
              if (summary.isNotEmpty) ...[
                if (title.isNotEmpty)
                  const SizedBox(height: RevericSpacing.xxs),
                Text(
                  summary,
                  style: typo.uiSmall.copyWith(
                    color: colors.textSecondary,
                    height: 1.5,
                  ),
                ),
              ],
              if (stateChange.isNotEmpty) ...[
                const SizedBox(height: RevericSpacing.xs),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${context.t(LocaleKeys.workspaceChapterEventStateChange)}：',
                      style: typo.uiTiny.copyWith(color: colors.textMuted),
                    ),
                    Expanded(
                      child: Text(
                        stateChange,
                        style: typo.uiTiny.copyWith(
                          color: colors.textMuted,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyChapterState extends StatelessWidget {
  const _EmptyChapterState({
    required this.chaptersIsEmpty,
    required this.onCreateChapter,
  });

  final bool chaptersIsEmpty;
  final Future<void> Function() onCreateChapter;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(RevericSpacing.x6l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.surfaceContainerHigh,
                border: Border.all(color: colors.borderSubtle),
              ),
              child: Center(
                child: RevericIcon(
                  RevericIcons.menu_book_outlined,
                  color: colors.textMuted,
                  size: 30,
                ),
              ),
            ),
            const SizedBox(height: RevericSpacing.x2l),
            Text(
              context.t(LocaleKeys.workspaceNoChapterSelected),
              style: typo.heading2.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: RevericSpacing.sm),
            Text(
              context.t(
                chaptersIsEmpty
                    ? LocaleKeys.workspaceCreateFirstChapter
                    : LocaleKeys.workspaceSelectChapterToWrite,
              ),
              style: typo.ui.copyWith(color: colors.textMuted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: RevericSpacing.x3l),
            FilledButton.icon(
              onPressed: onCreateChapter,
              icon: const RevericIcon(RevericIcons.add_rounded, size: 18),
              label: Text(context.t(LocaleKeys.workspaceNewChapter)),
            ),
          ],
        ),
      ),
    );
  }
}

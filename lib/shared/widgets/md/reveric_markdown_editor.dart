// 职责: Markdown 编辑器与只读预览 — 提供带实时样式预览、工具栏、一键复制全文、编辑器排版设置的正文输入，以及复用同一套语法的 Markdown 预览。移动端窄屏下工具栏置于底部并可横向滚动、标题级别走底部弹窗、图标命中区域加大。`autoHeight` 为短文字段提供随内容自增高模式（关闭 block 虚拟化，禁止用于章节正文）。
// 关联文件:
//   lib/shared/providers/settings_providers.dart
//   lib/shared/widgets/md/block/markdown_block_controller.dart
//   lib/shared/widgets/md/block/markdown_block_list_view.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/performance.md
//   .agents/rules/text-input-ime.md
//   .agents/rules/design-system.md

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../components/reveric_context_menu.dart';
import '../../components/reveric_icon_button.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/settings_providers.dart';
import '../../utils/text_input_formatters.dart';
import '../../../shared/theme/theme.dart';
import '../text_find_replace_scope.dart';
import 'block/markdown_block_controller.dart';
import 'block/markdown_block_list_view.dart';
import 'block/markdown_block_style.dart';
import 'markdown_span_builder.dart';

/// 窄屏断点：可用宽度 < 600 视为移动端紧凑布局（工具栏横向滚动、底部弹窗、加大命中区域）。
bool _isCompact(double width) => width < 600;

/// A live-preview markdown editor (Obsidian-style).
///
/// - Lines without cursor: syntax markers hidden, content rendered
///   with formatting (bold, heading size, etc.).
/// - Line with cursor: syntax markers shown in a subtle colour so
///   the user can edit the raw markdown.
class RevericMarkdownEditor extends ConsumerStatefulWidget {
  const RevericMarkdownEditor({
    super.key,
    required this.controller,
    required this.focusNode,
    this.hintText = '',
    this.disabled = false,
    this.errorText,
    this.fontFamily,
    this.fontSize,
    this.letterSpacing,
    this.lineHeight,
    this.undoController,
    this.limitPasteSize = false,
    this.autoHeight = false,
    this.showToolbar = true,
    this.minHeight,
    this.borderless = false,
  });

  /// 工具栏「复制全文」按钮，供测试定位。
  static const copyButtonKey = ValueKey<String>('revericMarkdownCopy');

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final bool disabled;
  final String? errorText;
  final String? fontFamily;
  final int? fontSize;
  final double? letterSpacing;
  final double? lineHeight;

  /// 共享的 undo/redo 控制器；多字段同页时传入同一实例，按钮可作用于当前焦点字段。
  final UndoHistoryController? undoController;

  /// 是否限制单次粘贴或批量插入的大小；默认关闭，chapter editor 显式启用。
  final bool limitPasteSize;

  /// 随内容自增高，由外层滚动容器承载滚动；用于人物档案这类平铺在长页面里的短文
  /// 字段。开启后关闭 block 虚拟化，**禁止用于章节正文**。
  final bool autoHeight;

  /// 是否显示格式工具栏；同一页面平铺多个短文字段时关掉，避免一屏出现多条工具栏。
  final bool showToolbar;

  /// [autoHeight] 下的最小高度，避免空字段塌成一行。
  final double? minHeight;

  /// 不画底色和边框，由宿主容器（如画布文本节点的卡片）充当输入框外观。
  final bool borderless;

  @override
  ConsumerState<RevericMarkdownEditor> createState() =>
      _RevericMarkdownEditorState();
}

class _RevericMarkdownEditorState extends ConsumerState<RevericMarkdownEditor> {
  late MarkdownBlockController _blockController;
  final GlobalKey<MarkdownBlockListViewState> _blockListKey = GlobalKey();
  bool _postFrameRebuildScheduled = false;

  /// 常驻实例：避免每次 build 重建 formatter 列表触发 TextField 重新配置。
  late final List<TextInputFormatter> _pasteLimitFormatters = [
    PasteSizeLimitTextInputFormatter(onRejected: _handlePasteRejected),
  ];
  static const List<TextInputFormatter> _noFormatters = <TextInputFormatter>[];

  @override
  void initState() {
    super.initState();
    _blockController = _createBlockController();
  }

  @override
  void didUpdateWidget(covariant RevericMarkdownEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.focusNode != widget.focusNode ||
        oldWidget.undoController != widget.undoController) {
      _blockController.removeListener(_handleBlockControllerChanged);
      _blockController.dispose();
      _blockController = _createBlockController();
    }
  }

  @override
  void dispose() {
    _blockController.removeListener(_handleBlockControllerChanged);
    _blockController.dispose();
    super.dispose();
  }

  MarkdownBlockController _createBlockController() {
    final controller = MarkdownBlockController(
      externalController: widget.controller,
      focusNode: widget.focusNode,
      undoController: widget.undoController,
    );
    controller.addListener(_handleBlockControllerChanged);
    return controller;
  }

  void _handleBlockControllerChanged() {
    if (!mounted) {
      return;
    }
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_postFrameRebuildScheduled) {
        return;
      }
      _postFrameRebuildScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _postFrameRebuildScheduled = false;
        if (mounted) {
          setState(() {});
        }
      });
      return;
    }
    setState(() {});
  }

  void _handlePasteRejected(int chars) {
    if (!mounted) {
      return;
    }
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
  }

  void _insertMarkdown(String prefix, String suffix) {
    final text = widget.controller.text;
    final sel = widget.controller.selection;

    if (!sel.isValid) {
      _blockController.replaceRange(
        text.length,
        text.length,
        '$prefix$suffix',
        selectionAfter: text.length + prefix.length,
      );
    } else {
      final selected = sel.textInside(text);
      final replacement = '$prefix$selected$suffix';
      _blockController.replaceRange(
        sel.start,
        sel.end,
        replacement,
        selectionAfter: sel.start + prefix.length + selected.length,
      );
    }
    _activateExternalSelection();
  }

  void _insertHeading(int level) {
    final prefix = '${'#' * level} ';
    final text = widget.controller.text;
    final sel = widget.controller.selection;

    if (!sel.isValid || sel.isCollapsed) {
      final caret = sel.isValid ? sel.extentOffset.clamp(0, text.length) : 0;
      final lineStart = caret == 0 ? 0 : text.lastIndexOf('\n', caret - 1) + 1;
      _blockController.replaceRange(
        lineStart,
        lineStart,
        prefix,
        selectionAfter: lineStart + prefix.length,
      );
    } else {
      final selected = sel.textInside(text);
      _blockController.replaceRange(
        sel.start,
        sel.end,
        '$prefix$selected',
        selectionAfter: sel.start + prefix.length + selected.length,
      );
    }
    _activateExternalSelection();
  }

  void _activateExternalSelection() {
    final selection = widget.controller.selection;
    final range = selection.isValid
        ? TextRange(start: selection.start, end: selection.end)
        : TextRange.collapsed(widget.controller.text.length);
    _blockController.activateRange(range);
  }

  void _copyAll() {
    final text = widget.controller.text;
    if (text.trim().isEmpty) {
      return;
    }
    Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.t(LocaleKeys.commonCopied))));
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final hasError = widget.errorText != null;
    final String fontFamily =
        widget.fontFamily ?? ref.watch(editorFontFamilyProvider);
    final int fontSize = widget.fontSize ?? ref.watch(editorFontSizeProvider);
    final double letterSpacing =
        widget.letterSpacing ?? ref.watch(editorLetterSpacingProvider);
    final double lineHeight =
        widget.lineHeight ?? ref.watch(editorLineHeightProvider);
    final fillColor = widget.disabled
        ? colors.surfaceContainerHigh.withValues(alpha: 0.5)
        : colors.surfaceContainerHigh;
    final fontColor = ref.watch(editorFontColorProvider);
    final textStyle = typo.body.copyWith(
      color: widget.disabled
          ? colors.textMuted
          : fontColor ?? colors.textPrimary,
      height: lineHeight,
      fontFamily: fontFamily,
      fontSize: fontSize.toDouble(),
      letterSpacing: letterSpacing,
    );
    final blockStyle = MarkdownBlockStyle(
      textStyle: textStyle,
      hintStyle: textStyle.copyWith(
        color: widget.disabled
            ? colors.textSubtle.withValues(alpha: 0.5)
            : colors.textSubtle,
      ),
      strutStyle: StrutStyle(
        fontSize: fontSize.toDouble(),
        height: lineHeight,
        fontFamily: fontFamily,
        leadingDistribution: TextLeadingDistribution.even,
      ),
      textHeightBehavior:
          DefaultTextHeightBehavior.maybeOf(context) ??
          const TextHeightBehavior(),
    );

    final error = hasError
        ? <Widget>[
            const SizedBox(height: RevericSpacing.xs),
            Text(
              widget.errorText!,
              style: typo.uiSmall.copyWith(color: colors.deletionBorder),
            ),
          ]
        : const <Widget>[];

    final Widget editorBox = TextFindReplaceScope(
      controller: widget.controller,
      editorFocusNode: widget.focusNode,
      enabled: !widget.disabled,
      ensureRangeVisible: (range, {required focusEditor}) {
        if (focusEditor) {
          _blockController.activateRange(range);
        }
        _blockListKey.currentState?.ensureRangeVisible(range);
      },
      child: Container(
        // 底高加在带边框的容器上，空字段的输入框本身就有高度，
        // 而不是让外面留一块空白。
        constraints: widget.autoHeight && widget.minHeight != null
            ? BoxConstraints(minHeight: widget.minHeight!)
            : null,
        decoration: widget.borderless
            ? null
            : BoxDecoration(
                color: fillColor,
                borderRadius: BorderRadius.circular(RevericRadius.xl),
                border: Border.all(
                  color: hasError
                      ? colors.deletionBorder
                      : widget.disabled
                      ? colors.borderSubtle
                      : colors.borderInput,
                ),
              ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(RevericRadius.xl),
          child: MarkdownBlockListView(
            key: _blockListKey,
            controller: _blockController,
            style: blockStyle,
            enabled: !widget.disabled,
            inputFormatters: widget.limitPasteSize
                ? _pasteLimitFormatters
                : _noFormatters,
            hintText: widget.hintText,
            autoHeight: widget.autoHeight,
          ),
        ),
      ),
    );
    // 自增高时高度由内容决定，外层不能再用 Expanded 抢占剩余空间。
    final editor = widget.autoHeight ? editorBox : Expanded(child: editorBox);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = _isCompact(constraints.maxWidth);
        if (!widget.showToolbar) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: widget.autoHeight
                ? MainAxisSize.min
                : MainAxisSize.max,
            children: [editor, ...error],
          );
        }
        final toolbar = _ToolbarRow(
          colors: colors,
          disabled: widget.disabled,
          isCompact: isCompact,
          canCopy: widget.controller.text.trim().isNotEmpty,
          onBold: () => _insertMarkdown('**', '**'),
          onItalic: () => _insertMarkdown('*', '*'),
          onStrikethrough: () => _insertMarkdown('~~', '~~'),
          onHeadingLevel: _insertHeading,
          onBulletList: () => _insertMarkdown('- ', ''),
          onNumberedList: () => _insertMarkdown('1. ', ''),
          onBlockquote: () => _insertMarkdown('> ', ''),
          onCopy: _copyAll,
        );

        final mainAxisSize = widget.autoHeight
            ? MainAxisSize.min
            : MainAxisSize.max;

        if (isCompact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: mainAxisSize,
            children: [
              editor,
              ...error,
              const SizedBox(height: RevericSpacing.sm),
              toolbar,
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: mainAxisSize,
          children: [
            toolbar,
            const SizedBox(height: RevericSpacing.sm),
            editor,
            ...error,
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Markdown preview (read-only)
// ---------------------------------------------------------------------------

/// Read-only markdown preview using the same syntax rules as [RevericMarkdownEditor].
class RevericMarkdownPreview extends StatelessWidget {
  const RevericMarkdownPreview({
    super.key,
    required this.data,
    this.style,
    this.maxLines,
    this.overflow = TextOverflow.clip,
    this.selectable = true,
    this.showCopyButton = false,
  });

  final String data;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow overflow;

  /// 是否允许用户选择并复制预览文本。
  final bool selectable;

  /// 是否在预览右上角显示复制原始 Markdown 的按钮。
  final bool showCopyButton;

  /// 限定行数时不必解析全文。按每行 2000 字符的宽松上限截断，真实布局不可能在
  /// 一行内排下这么多字符，因此可见内容与省略号表现不变；复制按钮仍用原始 [data]。
  String _visibleSource(String text) {
    final lines = maxLines;
    if (lines == null) {
      return text;
    }
    final limit = lines * 2000;
    return text.length <= limit ? text : text.substring(0, limit);
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final baseStyle =
        style ?? typo.uiSmall.copyWith(color: colors.textSecondary);
    final text = _visibleSource(data.trim());
    if (text.isEmpty) {
      return const SizedBox.shrink();
    }

    final preview = RichText(
      maxLines: maxLines,
      overflow: overflow,
      text: RevericMarkdownSpanBuilder.build(
        context: context,
        text: text,
        style: baseStyle,
      ),
    );
    final selectablePreview = selectable
        ? SelectionArea(child: preview)
        : preview;
    if (!showCopyButton) {
      return selectablePreview;
    }

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(
            end: RevericSizes.iconButtonSize,
          ),
          child: selectablePreview,
        ),
        PositionedDirectional(
          top: 0,
          end: 0,
          child: IconButton(
            tooltip: context.t(LocaleKeys.commonCopy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: data));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(context.t(LocaleKeys.commonCopied))),
              );
            },
            icon: RevericIcon(
              RevericIcons.copy,
              size: 16,
              color: colors.textMuted,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Toolbar
// ---------------------------------------------------------------------------

class _ToolbarRow extends StatelessWidget {
  const _ToolbarRow({
    required this.colors,
    required this.disabled,
    required this.isCompact,
    required this.canCopy,
    required this.onBold,
    required this.onItalic,
    required this.onStrikethrough,
    required this.onHeadingLevel,
    required this.onBulletList,
    required this.onNumberedList,
    required this.onBlockquote,
    required this.onCopy,
  });

  final RevericColors colors;
  final bool disabled;
  final bool isCompact;
  final bool canCopy;
  final VoidCallback onBold;
  final VoidCallback onItalic;
  final VoidCallback onStrikethrough;
  final ValueChanged<int> onHeadingLevel;
  final VoidCallback onBulletList;
  final VoidCallback onNumberedList;
  final VoidCallback onBlockquote;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final iconColor = disabled
        ? colors.textSubtle.withValues(alpha: 0.3)
        : colors.textSecondary;
    // 移动端加大命中区域到 44px，桌面端保持 28px。
    final double hitSize = isCompact ? 44 : 28;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.sm,
        vertical: RevericSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: disabled
            ? colors.surfaceContainerHigh.withValues(alpha: 0.5)
            : colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isCompact) ...[_copyBtn(context, hitSize), _divider()],
            _iconBtn(RevericIcons.format_bold, onBold, iconColor, hitSize),
            _iconBtn(RevericIcons.format_italic, onItalic, iconColor, hitSize),
            _iconBtn(
              RevericIcons.format_strikethrough,
              onStrikethrough,
              iconColor,
              hitSize,
            ),
            _divider(),
            if (isCompact)
              _headingBtnMobile(context, iconColor, hitSize)
            else
              _headingBtn(hitSize),
            _iconBtn(
              RevericIcons.format_list_bulleted,
              onBulletList,
              iconColor,
              hitSize,
            ),
            _iconBtn(
              RevericIcons.format_list_numbered,
              onNumberedList,
              iconColor,
              hitSize,
            ),
            _iconBtn(
              RevericIcons.format_quote,
              onBlockquote,
              iconColor,
              hitSize,
            ),
            if (!isCompact) ...[_divider(), _copyBtn(context, hitSize)],
          ],
        ),
      ),
    );
  }

  Widget _iconBtn(
    String icon,
    VoidCallback onPressed,
    Color color,
    double size, {
    Key? key,
    String? tooltip,
    bool? enabled,
  }) {
    final isEnabled = enabled ?? !disabled;
    return SizedBox(
      width: size,
      height: size,
      child: IconButton(
        key: key,
        onPressed: isEnabled ? onPressed : null,
        tooltip: tooltip,
        icon: RevericIcon(icon, size: 16, color: color),
        padding: EdgeInsets.zero,
        constraints: BoxConstraints(minWidth: size, minHeight: size),
        splashRadius: size / 2,
      ),
    );
  }

  /// 复制全文不改内容，只读态仍可点；空正文时禁用。
  Widget _copyBtn(BuildContext context, double size) {
    final copyColor = canCopy
        ? colors.textSecondary
        : colors.textSubtle.withValues(alpha: 0.3);
    return _iconBtn(
      RevericIcons.copy,
      onCopy,
      copyColor,
      size,
      key: RevericMarkdownEditor.copyButtonKey,
      tooltip: MaterialLocalizations.of(context).copyButtonLabel,
      enabled: canCopy,
    );
  }

  /// 桌面端：通过统一操作菜单为当前文本应用标题级别。
  Widget _headingBtn(double size) {
    return SizedBox(
      width: size,
      height: size,
      child: Builder(
        builder: (context) => RevericIconButton(
          icon: RevericIcons.format_heading,
          tooltip: context.t(LocaleKeys.editorHeadingLevelTitle),
          onPressed: disabled
              ? null
              : () {
                  final box = context.findRenderObject()! as RenderBox;
                  showRevericContextMenu(
                    context: context,
                    position: box.localToGlobal(Offset(0, box.size.height)),
                    entries: [
                      for (var level = 1; level <= 6; level++)
                        RevericMenuItem(
                          label: 'H$level',
                          onTap: () => onHeadingLevel(level),
                        ),
                    ],
                  );
                },
        ),
      ),
    );
  }

  /// 移动端：点击后弹出底部弹窗选择标题级别。
  Widget _headingBtnMobile(BuildContext context, Color iconColor, double size) {
    return SizedBox(
      width: size,
      height: size,
      child: IconButton(
        onPressed: disabled ? null : () => _showHeadingSheet(context),
        icon: RevericIcon(
          RevericIcons.format_heading,
          size: 16,
          color: iconColor,
        ),
        padding: EdgeInsets.zero,
        constraints: BoxConstraints(minWidth: size, minHeight: size),
        splashRadius: size / 2,
      ),
    );
  }

  Future<void> _showHeadingSheet(BuildContext context) async {
    final level = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: colors.canvas,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => const _HeadingLevelSheet(),
    );
    if (level != null) {
      onHeadingLevel(level);
    }
  }

  Widget _divider() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.xxs),
      child: SizedBox(
        width: RevericSizes.dividerThickness,
        height: 16,
        child: ColoredBox(color: colors.borderSubtle),
      ),
    );
  }
}

/// 移动端标题级别选择底部弹窗：H1..H6。
class _HeadingLevelSheet extends StatelessWidget {
  const _HeadingLevelSheet();

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 抓手
          Padding(
            padding: const EdgeInsets.only(
              top: RevericSpacing.lg,
              bottom: RevericSpacing.sm,
            ),
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: colors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.x3l,
              RevericSpacing.xs,
              RevericSpacing.x3l,
              RevericSpacing.lg,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                context.t(LocaleKeys.editorHeadingLevelTitle),
                style: typo.heading2.copyWith(color: colors.textPrimary),
              ),
            ),
          ),
          Divider(height: 1, color: colors.borderSubtle),
          for (int i = 1; i <= 6; i++)
            ListTile(
              title: Text(
                'H$i',
                style: typo.ui.copyWith(color: colors.textPrimary),
              ),
              onTap: () => Navigator.of(context).pop(i),
            ),
          const SizedBox(height: RevericSpacing.x3l),
        ],
      ),
    );
  }
}

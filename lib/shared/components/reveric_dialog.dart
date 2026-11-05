// 职责: 统一弹窗的宽度、标题层级、滚动正文和自适应操作区。
// 关联文件:
//   lib/shared/widgets/confirm_dialog.dart
//   lib/shared/theme/theme.dart
//   lib/shared/theme/reveric_spacing.dart
// 遵循的 Rules:
//   .agents/rules/design-system.md

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'reveric_button.dart';

/// 将页面的 Reveric 主题带入弹窗路由，保留调用方的返回值和关闭策略。
Future<T?> showRevericDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
}) {
  final theme = RevericTheme.of(context);
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    builder: (_) => RevericTheme(
      data: theme,
      child: Builder(builder: builder),
    ),
  );
}

/// 通用弹窗外观；路由、文案、操作状态由调用方管理。
class RevericDialog extends StatelessWidget {
  const RevericDialog({
    super.key,
    required this.title,
    this.content,
    this.leading,
    this.actions = const [],
    this.width = RevericSizes.dialogWidth,
  }) : _header = null,
       _scrollable = true;

  /// 内容自带高度或滚动容器时，保留其布局约束，避免嵌套无界滚动。
  const RevericDialog.panel({
    super.key,
    required Widget title,
    required this.content,
    this.actions = const [],
    this.width = RevericSizes.dialogWidth,
    this._scrollable = false,
  }) : title = null,
       leading = null,
       _header = title;

  final String? title;
  final Widget? content;
  final Widget? leading;
  final List<Widget> actions;
  final double width;
  final Widget? _header;
  final bool _scrollable;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final availableWidth = MediaQuery.sizeOf(context).width;
    // 窄屏收紧内边距、按钮平分整行，避免弹窗贴边且正文与操作区之间留白过大。
    final compact = availableWidth < RevericSizes.dialogWidth;
    const inset = RevericSpacing.x4l;
    final side = compact ? RevericSpacing.x3l : RevericSpacing.x4l;
    final dialogWidth = math.min(
      width,
      math.max(0.0, availableWidth - inset * 2),
    );

    return AlertDialog(
      backgroundColor: colors.surface,
      surfaceTintColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RevericRadius.card),
        side: BorderSide(color: revericCardBorder(colors)),
      ),
      constraints: BoxConstraints.tightFor(width: dialogWidth),
      insetPadding: const EdgeInsets.all(inset),
      scrollable: _scrollable,
      titleTextStyle: typo.uiSemibold.copyWith(
        fontSize: typo.body.fontSize,
        color: colors.textPrimary,
      ),
      contentTextStyle: typo.ui.copyWith(
        color: colors.textSecondary,
        height: typo.bodySmall.height,
      ),
      titlePadding: EdgeInsets.fromLTRB(side, side, side, 0),
      contentPadding: EdgeInsets.fromLTRB(
        side,
        RevericSpacing.lg,
        side,
        RevericSpacing.x2l,
      ),
      actionsPadding: EdgeInsets.fromLTRB(
        side,
        compact ? 0 : RevericSpacing.sm,
        side,
        side,
      ),
      actionsAlignment: MainAxisAlignment.end,
      actionsOverflowButtonSpacing: RevericSpacing.sm,
      buttonPadding: const EdgeInsetsDirectional.only(start: RevericSpacing.sm),
      title:
          _header ??
          Row(
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: RevericSpacing.lg),
              ],
              Expanded(
                child: Text(
                  title!,
                  style: typo.uiSemibold.copyWith(
                    fontSize: typo.body.fontSize,
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
      content: content,
      // 空列表也会让 AlertDialog 渲染 actions 区并叠加 actionsPadding，
      // 自己在 content 里画按钮的面板底部会多出一截空白。
      actions: actions.isEmpty
          ? null
          : compact &&
                actions.length > 1 &&
                actions.every((action) => action is RevericButton)
          ? [
              Row(
                children: [
                  for (final (index, action) in actions.indexed) ...[
                    if (index > 0) const SizedBox(width: RevericSpacing.sm),
                    Expanded(child: action),
                  ],
                ],
              ),
            ]
          : actions,
    );
  }
}

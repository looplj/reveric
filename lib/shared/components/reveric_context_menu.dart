// 职责: Reveric 通用右键上下文菜单 — 在指定位置弹出带阴影圆角卡片菜单，对齐 RevericSelect 浮层视觉
// 关联文件:
//   lib/shared/components/reveric_select.dart
//   lib/shared/theme/theme.dart
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md

import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// 上下文菜单条目基类。具体为 [RevericMenuItem] 或 [RevericMenuDivider]。
sealed class RevericMenuEntry {
  const RevericMenuEntry();
}

/// 单个可点击菜单项。
///
/// 视觉对齐 [RevericSelect] 的浮层选项：可选前置图标 + 标题，hover 高亮。
class RevericMenuItem extends RevericMenuEntry {
  const RevericMenuItem({
    required this.label,
    this.onTap,
    this.icon,
    this.leading,
    this.iconColor,
    this.labelColor,
    this.trailing,
    this.tooltip,
    this.description,
    this.enabled = true,
  });

  /// 菜单项标题。
  final String label;

  /// 点击回调。菜单先关闭再触发。为空表示不可点击（与 [enabled] 共同决定）。
  final VoidCallback? onTap;

  /// 前置图标资源路径（[RevericIcons] 常量）。与 [leading] 二选一。
  final String? icon;

  /// 自定义前置 widget（例如访问权限图标）。优先级高于 [icon]。
  final Widget? leading;

  /// 图标颜色。为空则使用 [RevericColors.textSecondary]。
  final Color? iconColor;

  /// 标题颜色。为空则使用 [RevericColors.textPrimary]。
  final Color? labelColor;

  /// 尾部 widget（例如选中态勾选）。
  final Widget? trailing;

  /// hover 提示文案。为空则不显示 tooltip。
  final String? tooltip;

  /// 标题下方的一行小字说明，可换行。
  final String? description;

  final bool enabled;
}

/// 菜单分隔线。
class RevericMenuDivider extends RevericMenuEntry {
  const RevericMenuDivider();
}

/// 在 [position]（全局坐标）处弹出 Reveric 风格上下文菜单。
///
/// 通常在 `GestureDetector.onSecondaryTapDown` 中调用，传入
/// `details.globalPosition`。点击菜单项或点击空白处关闭。
///
/// [anchor] 指定 [position] 对应菜单的哪个点，默认左上角；
/// 例如从底部按钮向上弹出时传 [Alignment.bottomCenter]。
Future<void> showRevericContextMenu({
  required BuildContext context,
  required Offset position,
  required List<RevericMenuEntry> entries,
  double minWidth = 180,
  double maxWidth = 300,
  Alignment anchor = Alignment.topLeft,
  ValueChanged<Route<void>>? onRouteCreated,
}) {
  final colors = RevericTheme.colorsOf(context);
  final typo = RevericTheme.typographyOf(context);
  final navigator = Navigator.of(context, rootNavigator: true);

  final route = _RevericContextMenuRoute(
    position: position,
    entries: entries,
    colors: colors,
    typo: typo,
    minWidth: minWidth,
    maxWidth: maxWidth,
    anchor: anchor,
  );
  onRouteCreated?.call(route);
  return navigator.push(route);
}

class _RevericContextMenuRoute extends PopupRoute<void> {
  _RevericContextMenuRoute({
    required this.position,
    required this.entries,
    required this.colors,
    required this.typo,
    required this.minWidth,
    required this.maxWidth,
    required this.anchor,
  });

  final Offset position;
  final List<RevericMenuEntry> entries;
  final RevericColors colors;
  final RevericTypography typo;
  final double minWidth;
  final double maxWidth;
  final Alignment anchor;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 180);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final media = MediaQuery.of(context);
    return CustomSingleChildLayout(
      delegate: _ContextMenuLayout(
        position: position,
        padding: media.padding,
        anchor: anchor,
      ),
      child: _RevericContextMenu(
        entries: entries,
        colors: colors,
        typo: typo,
        minWidth: minWidth,
        maxWidth: maxWidth,
        onSelected: () => Navigator.of(context).pop(),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOut);
    return FadeTransition(
      opacity: curved,
      child: AnimatedBuilder(
        animation: curved,
        builder: (context, child) {
          return Transform.translate(
            offset: Offset(0, (1 - curved.value) * 4),
            child: child,
          );
        },
        child: child,
      ),
    );
  }
}

/// 将菜单定位到 [position]，并保证不超出屏幕可视区域。
class _ContextMenuLayout extends SingleChildLayoutDelegate {
  _ContextMenuLayout({
    required this.position,
    required this.padding,
    this.anchor = Alignment.topLeft,
  });

  final Offset position;
  final EdgeInsets padding;
  final Alignment anchor;

  static const double _margin = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.loose(constraints.biggest).deflate(
      EdgeInsets.symmetric(horizontal: _margin, vertical: _margin) + padding,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double x = position.dx - childSize.width * (anchor.x + 1) / 2;
    double y = position.dy - childSize.height * (anchor.y + 1) / 2;
    final maxX = size.width - padding.right - _margin - childSize.width;
    final maxY = size.height - padding.bottom - _margin - childSize.height;
    if (x > maxX) {
      x = maxX;
    }
    if (y > maxY) {
      y = maxY;
    }
    final minX = padding.left + _margin;
    final minY = padding.top + _margin;
    return Offset(x < minX ? minX : x, y < minY ? minY : y);
  }

  @override
  bool shouldRelayout(_ContextMenuLayout oldDelegate) {
    return position != oldDelegate.position ||
        padding != oldDelegate.padding ||
        anchor != oldDelegate.anchor;
  }
}

class _RevericContextMenu extends StatefulWidget {
  const _RevericContextMenu({
    required this.entries,
    required this.colors,
    required this.typo,
    required this.minWidth,
    required this.maxWidth,
    required this.onSelected,
  });

  final List<RevericMenuEntry> entries;
  final RevericColors colors;
  final RevericTypography typo;
  final double minWidth;
  final double maxWidth;
  final VoidCallback onSelected;

  @override
  State<_RevericContextMenu> createState() => _RevericContextMenuState();
}

class _RevericContextMenuState extends State<_RevericContextMenu> {
  // 在菜单层维护唯一悬停项，避免相邻项快速移动时多个项同时高亮。
  int? _hoveredIndex;

  void _handleTap(RevericMenuItem item) {
    widget.onSelected();
    final onTap = item.onTap;
    if (onTap != null) {
      // 与原 showMenu 行为一致：先关闭菜单再触发，避免操作打开的 Dialog
      // 被本路由的关闭动画影响。
      Future.microtask(onTap);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        constraints: BoxConstraints(
          minWidth: widget.minWidth,
          maxWidth: widget.maxWidth,
        ),
        padding: const EdgeInsets.all(RevericSpacing.xs),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(RevericRadius.large),
          border: Border.all(color: colors.border),
          boxShadow: [
            BoxShadow(
              color: colors.textPrimary.withValues(alpha: 0.16),
              blurRadius: 40,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: IntrinsicWidth(
          child: SingleChildScrollView(
            primary: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, entry) in widget.entries.indexed)
                  switch (entry) {
                    RevericMenuDivider() => Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: RevericSpacing.xs,
                      ),
                      child: Divider(
                        height: 1,
                        thickness: 1,
                        color: colors.border,
                      ),
                    ),
                    RevericMenuItem() => _RevericMenuOption(
                      item: entry,
                      hovered: _hoveredIndex == index,
                      colors: colors,
                      typo: widget.typo,
                      onHoverChanged: (hovering) {
                        setState(() {
                          if (hovering) {
                            _hoveredIndex = index;
                          } else if (_hoveredIndex == index) {
                            _hoveredIndex = null;
                          }
                        });
                      },
                      onTap: () => _handleTap(entry),
                    ),
                  },
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RevericMenuOption extends StatelessWidget {
  const _RevericMenuOption({
    required this.item,
    required this.hovered,
    required this.colors,
    required this.typo,
    required this.onHoverChanged,
    required this.onTap,
  });

  final RevericMenuItem item;
  final bool hovered;
  final RevericColors colors;
  final RevericTypography typo;
  final ValueChanged<bool> onHoverChanged;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = item.enabled && item.onTap != null;
    final background = hovered && enabled
        ? colors.hover
        : colors.surface.withValues(alpha: 0);
    final iconColor = item.iconColor ?? colors.textSecondary;
    final labelColor = item.labelColor ?? colors.textPrimary;

    final Widget? leading =
        item.leading ??
        (item.icon != null
            ? RevericIcon(item.icon!, size: 16, color: iconColor)
            : null);

    final option = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => onHoverChanged(true),
      onExit: (_) => onHoverChanged(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.sm,
            vertical: RevericSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(RevericRadius.medium),
          ),
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            child: Row(
              children: [
                if (leading != null) ...[
                  leading,
                  const SizedBox(width: RevericSpacing.md),
                ],
                Expanded(
                  child: item.description == null
                      ? Text(
                          item.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: typo.ui.copyWith(color: labelColor),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: typo.uiSemibold.copyWith(
                                color: labelColor,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              item.description!,
                              style: typo.uiTiny.copyWith(
                                color: colors.textMuted,
                              ),
                            ),
                          ],
                        ),
                ),
                if (item.trailing != null) ...[
                  const SizedBox(width: RevericSpacing.sm),
                  item.trailing!,
                ],
              ],
            ),
          ),
        ),
      ),
    );

    if (item.tooltip != null) {
      return Tooltip(message: item.tooltip!, child: option);
    }
    return option;
  }
}

// 职责: Reveric 通用下拉选择 — 自定义触发器 + 浮层菜单，支持图标/标题/副标题富选项，长列表可搜索过滤。
// 关联文件:
//   lib/shared/theme/theme.dart
//   lib/shared/components/reveric_dropdowns.dart
//   lib/shared/components/reveric_search_field.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/search-debounce.md

import 'package:flutter/material.dart';

import '../localization/app_localization.dart';
import '../localization/locale_keys.dart';
import '../theme/theme.dart';
import 'reveric_search_field.dart';

/// 单个下拉选项。
///
/// 可选前置图标（绘制在 accent 浅底方块中）+ 标题 + 可选副标题描述，
/// 选中项右侧显示 check-circle。
class RevericSelectItem<T> {
  const RevericSelectItem({
    required this.value,
    required this.label,
    this.subtitle,
    this.enabled = true,
    this.icon,
    this.color,
    this.badges,
    this.notice,
  });

  /// 选项值。
  final T value;

  /// 禁用项保留在列表中，subtitle 可解释不可选的原因。
  final bool enabled;

  /// 选项主标题。
  final String label;

  /// 选项副标题描述。为空则只显示标题。
  final String? subtitle;

  /// 选项前置图标资源路径（[RevericIcons] 常量）。为空则不显示图标方块。
  final String? icon;

  /// 选项前置状态色点。为空则不显示色点。
  final Color? color;

  /// 副标题行右侧的徽标（如卖点），只在菜单中显示，不挤占标题宽度。
  final Widget? badges;

  /// 选项提示（如计费说明图标），在菜单和选中后的触发器中都紧跟标题显示。
  final Widget? notice;
}

/// 通用下拉选择控件。
///
/// 相比原生 [DropdownButton]，支持富选项与自定义浮层：
/// 触发器聚焦/展开时边框变 accent、尾部 caret 旋转，浮层菜单为带阴影的
/// 圆角卡片，选项支持图标方块、标题、副标题与选中态 check-circle。
class RevericSelect<T> extends StatefulWidget {
  const RevericSelect({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.label,
    this.placeholder,
    this.leadingIcon,
    this.enabled = true,
    this.height = RevericSizes.fieldHeight,
    this.maxMenuHeight = 288,
    this.menuWidth,
    this.compact = false,
    this.textStyle,
    this.alignEnd = false,
    this.dropUp = false,
    this.searchable = false,
    this.onEmptyTap,
    this.footerAction,
  });

  /// 当前选中值。为空表示未选择。
  final T? value;

  /// 选项列表。
  final List<RevericSelectItem<T>> items;

  /// 选择回调。
  final ValueChanged<T> onChanged;

  /// 字段上方标签。为空则不渲染标签。
  final String? label;

  /// 未选择时的占位文案。
  final String? placeholder;

  /// 触发器前置图标资源路径（[RevericIcons] 常量）。
  final String? leadingIcon;

  final bool enabled;

  /// 触发器固定高度。
  final double height;

  /// 浮层菜单最大高度，超出滚动。
  final double maxMenuHeight;

  /// 浮层菜单宽度。为空时与触发器同宽。
  final double? menuWidth;

  /// 使用无边框、紧凑字号的轻量触发器，适用于卡片内的行内选择。
  final bool compact;

  /// 覆盖触发器文字样式（颜色仍按展开/选中状态决定）。
  final TextStyle? textStyle;

  /// 内容靠右（前导图标/色点随文字一起靠右），用于「左标签 + 右值」的设置行。
  final bool alignEnd;

  /// 菜单向上展开（触发器贴近屏幕底部时，如画布上的生成输入框底栏）。
  final bool dropUp;

  /// 菜单顶部显示搜索框，按标题和副标题过滤。长列表（如模型）才打开。
  final bool searchable;

  /// 没有任何选项时点触发器的去处（如打开设置去配置）；为空时空列表下触发器不可点。
  final VoidCallback? onEmptyTap;

  /// 菜单底部的固定操作（如「添加模型」），点击后先关闭菜单再回调。
  final ({String label, VoidCallback onTap})? footerAction;

  @override
  State<RevericSelect<T>> createState() => _RevericSelectState<T>();
}

class _RevericSelectState<T> extends State<RevericSelect<T>> {
  final OverlayPortalController _controller = OverlayPortalController();

  bool _open = false;

  RevericSelectItem<T>? get _selected {
    for (final item in widget.items) {
      if (item.value == widget.value) {
        return item;
      }
    }
    return null;
  }

  void _toggle() {
    if (_open) {
      _close();
    } else {
      _show();
    }
  }

  void _show() {
    setState(() => _open = true);
    _controller.show();
  }

  void _close() {
    if (!_open) {
      return;
    }
    setState(() => _open = false);
    _controller.hide();
  }

  void _pick(RevericSelectItem<T> item) {
    _close();
    if (!item.enabled) {
      return;
    }
    widget.onChanged(item.value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    // 菜单内选项会挂 Tooltip，Tooltip 需要在 layout 阶段算出绝对位置；
    // CompositedTransformFollower 要到合成阶段才有变换，因此按触发器矩形自行定位。
    final trigger = OverlayPortal.overlayChildLayoutBuilder(
      controller: _controller,
      overlayChildBuilder: _buildOverlay,
      child: _buildTrigger(colors, typo),
    );

    if (widget.label == null) {
      return trigger;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label!,
          style: typo.uiSmallSemibold.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: RevericSpacing.xs),
        trigger,
      ],
    );
  }

  Widget _buildTrigger(RevericColors colors, RevericTypography typo) {
    final selected = _selected;
    final hasValue = selected != null;
    final emptyTap = widget.items.isEmpty ? widget.onEmptyTap : null;
    final enabled =
        widget.enabled && (widget.items.isNotEmpty || emptyTap != null);
    final compact = widget.compact;

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? emptyTap ?? _toggle : null,
        child: Container(
          height: widget.height,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 0 : RevericSpacing.lg,
          ),
          decoration: compact
              ? null
              : BoxDecoration(
                  color: colors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(RevericRadius.large),
                  border: Border.all(
                    color: _open ? colors.accent : colors.borderInput,
                  ),
                ),
          child: Row(
            mainAxisAlignment: widget.alignEnd
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            children: [
              if (widget.leadingIcon != null) ...[
                RevericIcon(
                  widget.leadingIcon!,
                  size: 15,
                  color: colors.accent,
                ),
                const SizedBox(width: RevericSpacing.sm),
              ] else if (selected?.color != null) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: selected!.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: RevericSpacing.sm),
              ],
              Flexible(
                fit: widget.alignEnd ? FlexFit.loose : FlexFit.tight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: widget.alignEnd
                      ? MainAxisAlignment.end
                      : MainAxisAlignment.start,
                  children: [
                    Flexible(
                      child: Text(
                        hasValue ? selected.label : (widget.placeholder ?? ''),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            (widget.textStyle ??
                                    (compact ? typo.uiTiny : typo.ui))
                                .copyWith(
                                  color: _open
                                      ? colors.accent
                                      : hasValue
                                      ? colors.textPrimary
                                      : colors.textSubtle,
                                ),
                      ),
                    ),
                    if (selected?.notice case final notice?) ...[
                      const SizedBox(width: RevericSpacing.xs),
                      notice,
                    ],
                  ],
                ),
              ),
              SizedBox(width: compact ? RevericSpacing.xxs : RevericSpacing.sm),
              AnimatedRotation(
                turns: _open ? 0.5 : 0,
                duration: const Duration(milliseconds: 140),
                child: RevericIcon(
                  RevericIcons.expand_more,
                  size: compact ? 11 : 13,
                  color: colors.textSubtle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOverlay(BuildContext context, OverlayChildLayoutInfo info) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _close,
          ),
        ),
        CustomSingleChildLayout(
          delegate: _RevericSelectMenuLayout(
            anchor: MatrixUtils.transformRect(
              info.childPaintTransform,
              Offset.zero & info.childSize,
            ),
            dropUp: widget.dropUp,
          ),
          child: _RevericSelectMenu<T>(
            width: widget.menuWidth ?? info.childSize.width,
            maxHeight: widget.maxMenuHeight,
            items: widget.items,
            value: widget.value,
            colors: colors,
            typo: typo,
            onPick: _pick,
            searchable: widget.searchable,
            footerAction: widget.footerAction == null
                ? null
                : (
                    label: widget.footerAction!.label,
                    onTap: () {
                      _close();
                      widget.footerAction!.onTap();
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

/// 菜单左缘对齐触发器，按 [dropUp] 贴在触发器上方或下方。
class _RevericSelectMenuLayout extends SingleChildLayoutDelegate {
  const _RevericSelectMenuLayout({required this.anchor, required this.dropUp});

  final Rect anchor;
  final bool dropUp;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    anchor.left,
    dropUp
        ? anchor.top - RevericSpacing.xs - childSize.height
        : anchor.bottom + RevericSpacing.xs,
  );

  @override
  bool shouldRelayout(_RevericSelectMenuLayout oldDelegate) =>
      anchor != oldDelegate.anchor || dropUp != oldDelegate.dropUp;
}

class _RevericSelectMenu<T> extends StatefulWidget {
  const _RevericSelectMenu({
    required this.width,
    required this.maxHeight,
    required this.items,
    required this.value,
    required this.colors,
    required this.typo,
    required this.onPick,
    this.searchable = false,
    this.footerAction,
  });

  final double width;
  final double maxHeight;
  final List<RevericSelectItem<T>> items;
  final T? value;
  final RevericColors colors;
  final RevericTypography typo;
  final ValueChanged<RevericSelectItem<T>> onPick;
  final bool searchable;
  final ({String label, VoidCallback onTap})? footerAction;

  @override
  State<_RevericSelectMenu<T>> createState() => _RevericSelectMenuState<T>();
}

class _RevericSelectMenuState<T> extends State<_RevericSelectMenu<T>> {
  // 在菜单层维护唯一悬停项，避免相邻项之间快速移动时多个项同时高亮。
  int? _hoveredIndex;
  String _query = '';

  /// 选中项可能落在长列表（如 0–59 分钟）的靠后位置，打开时先滚到它，
  /// 否则用户每次都得从头翻。
  final GlobalKey _selectedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final selectedContext = _selectedKey.currentContext;
      if (selectedContext == null) {
        return;
      }
      Scrollable.ensureVisible(
        selectedContext,
        alignment: 0.5,
        duration: Duration.zero,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width;
    final maxHeight = widget.maxHeight;
    final colors = widget.colors;
    final visible = [
      for (final item in widget.items)
        if (_matches(item)) item,
    ];
    return Material(
      type: MaterialType.transparency,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        builder: (context, t, child) {
          return Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 4),
              child: child,
            ),
          );
        },
        child: Container(
          width: width,
          constraints: BoxConstraints(maxHeight: maxHeight),
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.searchable) ...[
                RevericDebouncedSearchField(
                  hint: context.t(LocaleKeys.commonSearch),
                  autofocus: true,
                  height: RevericSizes.fieldHeightSm,
                  onDebouncedChanged: (query) {
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      _query = query;
                      _hoveredIndex = null;
                    });
                  },
                ),
                const SizedBox(height: RevericSpacing.xs),
              ],
              Flexible(
                child: visible.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: RevericSpacing.md,
                        ),
                        child: Center(
                          child: Text(
                            context.t(LocaleKeys.commonNoResults),
                            style: widget.typo.uiSmall.copyWith(
                              color: colors.textMuted,
                            ),
                          ),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        clipBehavior: Clip.antiAlias,
                        children: [
                          for (final (index, item) in visible.indexed)
                            Padding(
                              key: item.value == widget.value
                                  ? _selectedKey
                                  : null,
                              padding: EdgeInsets.only(
                                bottom: index == visible.length - 1
                                    ? 0
                                    : RevericSpacing.xxs,
                              ),
                              child: _RevericSelectOption<T>(
                                item: item,
                                selected: item.value == widget.value,
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
                                onPick: () => widget.onPick(item),
                              ),
                            ),
                        ],
                      ),
              ),
              if (widget.footerAction case final action?) ...[
                Divider(height: RevericSpacing.sm, color: colors.border),
                _RevericSelectFooter(
                  label: action.label,
                  colors: colors,
                  typo: widget.typo,
                  onTap: action.onTap,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  bool _matches(RevericSelectItem<T> item) {
    final query = _query;
    if (!widget.searchable || query.isEmpty) {
      return true;
    }
    if (item.label.toLowerCase().contains(query)) {
      return true;
    }
    final subtitle = item.subtitle;
    return subtitle != null && subtitle.toLowerCase().contains(query);
  }
}

class _RevericSelectOption<T> extends StatelessWidget {
  const _RevericSelectOption({
    required this.item,
    required this.selected,
    required this.hovered,
    required this.colors,
    required this.typo,
    required this.onHoverChanged,
    required this.onPick,
  });

  final RevericSelectItem<T> item;
  final bool selected;
  final bool hovered;
  final RevericColors colors;
  final RevericTypography typo;
  final ValueChanged<bool> onHoverChanged;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final background = selected
        ? colors.selected
        : hovered
        ? colors.hover
        : colors.surface.withValues(alpha: 0);

    return MouseRegion(
      cursor: item.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => onHoverChanged(item.enabled),
      onExit: (_) => onHoverChanged(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: item.enabled ? onPick : null,
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
          child: Row(
            children: [
              if (item.icon != null) ...[
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.accent.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(RevericRadius.medium),
                  ),
                  child: RevericIcon(
                    item.icon!,
                    size: 15,
                    color: colors.accent,
                  ),
                ),
                const SizedBox(width: RevericSpacing.md),
              ] else if (item.color != null) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: item.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: RevericSpacing.sm),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: typo.uiSmallSemibold.copyWith(
                              color: item.enabled
                                  ? colors.textPrimary
                                  : colors.textMuted,
                            ),
                          ),
                        ),
                        if (item.notice case final notice?) ...[
                          const SizedBox(width: RevericSpacing.xs),
                          notice,
                        ],
                      ],
                    ),
                    if (item.subtitle != null || item.badges != null) ...[
                      const SizedBox(height: 1),
                      Wrap(
                        spacing: RevericSpacing.sm,
                        runSpacing: RevericSpacing.xxs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (item.subtitle case final subtitle?)
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: typo.uiTiny.copyWith(
                                color: colors.textMuted,
                              ),
                            ),
                          ?item.badges,
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (selected) ...[
                const SizedBox(width: RevericSpacing.sm),
                RevericIcon(
                  RevericIcons.check_circle,
                  size: 15,
                  color: colors.accent,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RevericSelectFooter extends StatelessWidget {
  const _RevericSelectFooter({
    required this.label,
    required this.colors,
    required this.typo,
    required this.onTap,
  });

  final String label;
  final RevericColors colors;
  final RevericTypography typo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: RevericSpacing.sm),
          child: Center(
            child: Text(
              label,
              style: typo.uiSmall.copyWith(color: colors.textMuted),
            ),
          ),
        ),
      ),
    );
  }
}

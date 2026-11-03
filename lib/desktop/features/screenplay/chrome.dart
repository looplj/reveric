// 职责: 剧本主区外壳 — 分区工具条、底栏统计项、内容卡与空态。
// 关联文件:
//   lib/desktop/widgets/workspace/novel_workspace_panel.dart
//   lib/desktop/features/screenplay/script.dart
//   lib/shared/widgets/app_background.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/components/reveric_popover.dart';
import '../../../shared/components/reveric_surfaces.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/app_background.dart';
import '../canvas/widgets/glass.dart';

/// `.sp-top` —— 46 高的分区工具条：左侧统计文案或控件 + 右侧动作。
///
/// 分区名由工作区面包屑（`作品 > 场次`）给出，这里不再重复标题和图标；
/// 只有真的带动作的分区才铺这一条，其余分区让正文直接顶到面包屑下。
///
/// 它是主区的 chrome（分区壳，不是内容卡），启用全局背景时要透出背景，
/// 所以底色走 `appChromeBackgroundColor`。
class ScreenplayRegionToolbar extends ConsumerWidget {
  const ScreenplayRegionToolbar({
    super.key,
    this.status,
    this.leading,
    this.trailing = const [],
    this.floating = false,
  });

  final String? status;

  /// 左侧控件（如视图切换）；给了它就不再显示 [status]。
  final Widget? leading;
  final List<Widget> trailing;

  /// 胶囊样式：不铺底、不画分割线，左右两组各自是一枚毛玻璃胶囊，空白处点击落到下层。
  /// 制作页的画布、分镜、列表三个视图都用它；只用于 [leading] 布局。
  final bool floating;

  /// 浮动时胶囊和上方面包屑分割线之间多留的距离。
  static const double floatingTopGap = RevericSpacing.xxs;

  /// 浮动工具条占住的高度，画布上的贴边浮层要让开这一段。
  static const double floatingExtent =
      RevericSizes.screenplayTopBarHeight + floatingTopGap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final backgroundActive = ref.watch(appBackgroundActiveProvider);
    Widget group(Widget child) => floating
        ? CanvasGlass(
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.xxs,
              vertical: RevericSpacing.xxs,
            ),
            child: child,
          )
        : child;
    final actions = Row(
      mainAxisSize: floating ? MainAxisSize.min : MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        for (var i = 0; i < trailing.length; i++) ...[
          if (i > 0) const SizedBox(width: RevericSpacing.md),
          trailing[i],
        ],
      ],
    );
    return Container(
      height: floating ? floatingExtent : RevericSizes.screenplayTopBarHeight,
      // 浮动时外边距收窄，抵掉两枚胶囊自身的内边距，窄窗口下可用宽度与铺底时相同。
      padding: floating
          ? const EdgeInsets.only(
              left: RevericSpacing.lg,
              right: RevericSpacing.lg,
              top: floatingTopGap,
            )
          : const EdgeInsets.symmetric(horizontal: RevericSpacing.x3l),
      decoration: floating
          ? null
          : BoxDecoration(
              color: appChromeBackgroundColor(
                colors,
                backgroundActive,
                colors.surfaceContainer,
              ),
              border: Border(bottom: BorderSide(color: colors.borderSubtle)),
            ),
      child: leading != null
          ? LayoutBuilder(
              builder: (context, constraints) {
                final compact =
                    floating &&
                    constraints.maxWidth <
                        RevericSizes.screenplayToolbarCompactWidth *
                            MediaQuery.textScalerOf(context).scale(1);
                return Row(
                  children: [
                    if (compact)
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: group(leading!),
                        ),
                      )
                    else
                      group(leading!),
                    const SizedBox(width: RevericSpacing.md),
                    if (compact) ...[
                      group(
                        RevericPopover(
                          alignEnd: true,
                          trigger: (context, open, toggle) => RevericIconButton(
                            icon: RevericIcons.more_horiz,
                            tooltip: context.t(LocaleKeys.commonMoreActions),
                            onPressed: toggle,
                          ),
                          panel: (context, close) => Material(
                            type: MaterialType.transparency,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxWidth:
                                    RevericSizes.screenplayToolbarPanelWidth,
                              ),
                              child: RevericElevatedCard(
                                fallback: colors.surface,
                                padding: const EdgeInsets.all(
                                  RevericSpacing.sm,
                                ),
                                child: actions,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ] else
                      Expanded(
                        child: floating
                            ? Align(
                                alignment: Alignment.centerRight,
                                child: group(actions),
                              )
                            : actions,
                      ),
                  ],
                );
              },
            )
          : Row(
              children: [
                if (status case final status?)
                  Expanded(
                    child: Tooltip(
                      message: status,
                      child: Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.uiSmall.copyWith(color: colors.textMuted),
                      ),
                    ),
                  )
                else
                  const Spacer(),
                for (final widget in trailing) ...[
                  const SizedBox(width: RevericSpacing.md),
                  widget,
                ],
              ],
            ),
    );
  }
}

/// `.sp-status` 里的一项：小图标 + 一句话。
///
/// 底栏本身归 `NovelWorkspacePanel`，分区不自备一条；这些项由
/// `script.dart` 的 `ScreenplayScriptStatusItems` 交给它。
class ScreenplayStatusItem extends StatelessWidget {
  const ScreenplayStatusItem({
    super.key,
    required this.icon,
    required this.label,
  });

  final String icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        RevericIcon(icon, size: 12, color: colors.textMuted),
        const SizedBox(width: RevericSpacing.xxs),
        Text(label, style: typo.uiTiny.copyWith(color: colors.textMuted)),
      ],
    );
  }
}

/// `.sp-card` —— 概览与人物关系里的内容卡。
class ScreenplayCard extends StatelessWidget {
  const ScreenplayCard({
    super.key,
    required this.child,
    this.icon,
    this.title,
    this.hint,
  });

  final Widget child;
  final String? icon;
  final String? title;
  final Widget? hint;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      padding: const EdgeInsets.all(RevericSpacing.x3l),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        border: Border.all(color: colors.borderInput),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title case final title?) ...[
            Row(
              children: [
                if (icon case final icon?) ...[
                  RevericIcon(icon, size: 14, color: colors.textPrimary),
                  const SizedBox(width: RevericSpacing.sm),
                ],
                Expanded(
                  child: Text(
                    title,
                    style: typo.bodySmall.copyWith(
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                // ignore: use_null_aware_elements
                if (hint != null) hint!,
              ],
            ),
            const SizedBox(height: RevericSpacing.lg),
          ],
          child,
        ],
      ),
    );
  }
}

/// `.sp-empty` —— 标题 + 说明 + 可选动作的三段式空态。
class ScreenplayEmptyState extends StatelessWidget {
  const ScreenplayEmptyState({
    super.key,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.x4l,
          vertical: 64,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: typo.body.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.4,
                color: colors.textSecondary,
              ),
            ),
            if (message case final message?) ...[
              const SizedBox(height: RevericSpacing.sm),
              Text(
                message,
                textAlign: TextAlign.center,
                style: typo.ui.copyWith(height: 1.7, color: colors.textMuted),
              ),
            ],
            if (actionLabel case final actionLabel?) ...[
              const SizedBox(height: RevericSpacing.x2l),
              OutlinedButton.icon(
                onPressed: onAction,
                icon: const RevericIcon(RevericIcons.add, size: 14),
                label: Text(actionLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

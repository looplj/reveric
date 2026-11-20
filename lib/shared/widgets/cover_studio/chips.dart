// 职责: 封面工作台的小件 — 区块标题、选择 chip、色卡与提示条。
// 关联文件:
//   lib/shared/widgets/cover_studio/sections.dart
//   lib/desktop/features/cover_studio/designer.dart
//   lib/mobile/features/cover_studio/designer_sheet.dart
//   lib/shared/theme/theme.dart
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md

import 'package:flutter/material.dart';

import '../../theme/theme.dart';

/// 设计师面板里每个小节的标题行。
class CoverSectionHead extends StatelessWidget {
  const CoverSectionHead({
    super.key,
    required this.icon,
    required this.label,
    this.trailing,
  });

  final String icon;
  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: RevericSpacing.sm),
      child: Row(
        children: [
          RevericIcon(icon, size: 14, color: colors.accent),
          const SizedBox(width: RevericSpacing.xs),
          Expanded(
            child: Text(
              label,
              style: typo.uiSemibold.copyWith(color: colors.textSecondary),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class CoverChip extends StatelessWidget {
  const CoverChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final String? icon;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final foreground = selected ? colors.accent : colors.textSecondary;
    return Material(
      color: selected ? colors.accent.withValues(alpha: 0.14) : colors.surface,
      borderRadius: BorderRadius.circular(RevericRadius.small),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(RevericRadius.small),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.md,
            vertical: RevericSpacing.xs,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(RevericRadius.small),
            border: Border.all(color: selected ? colors.accent : colors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                RevericIcon(icon!, size: 12, color: foreground),
                const SizedBox(width: RevericSpacing.xxs),
              ],
              Flexible(
                child: Text(
                  label,
                  style: typo.uiTiny.copyWith(color: foreground),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一格色卡。渐变两端来自配方目录，选中时描边换成 accent。
class CoverSwatch extends StatelessWidget {
  const CoverSwatch({
    super.key,
    required this.label,
    required this.startColor,
    required this.endColor,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color startColor;
  final Color endColor;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(RevericRadius.small),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 28,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [startColor, endColor],
                ),
                borderRadius: BorderRadius.circular(RevericRadius.small),
                border: Border.all(
                  color: selected ? colors.accent : colors.border,
                  width: selected ? 2 : 1,
                ),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: typo.uiTiny.copyWith(
                color: selected ? colors.accent : colors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 需要作者注意但不阻断操作的一条提示，如参考图超上限、档案过时。
class CoverAlert extends StatelessWidget {
  const CoverAlert(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.md,
        vertical: RevericSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.warningBg,
        border: Border.all(color: colors.warningText.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(RevericRadius.medium),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RevericIcon(
            RevericIcons.warning,
            size: 13,
            color: colors.warningText,
          ),
          const SizedBox(width: RevericSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: typo.uiTiny.copyWith(color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

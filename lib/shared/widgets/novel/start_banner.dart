// 职责: 新建小说表单顶部的快速开书横幅 — 与剧本的改编横幅共用同一槽位，两端共用。
// 关联文件:
//   lib/desktop/widgets/novel_form_dialog.dart
//   lib/mobile/pages/novel_create_page.dart
//   lib/shared/theme/theme.dart

import 'package:flutter/material.dart';

import '../../theme/theme.dart';

class NovelStartBanner extends StatelessWidget {
  const NovelStartBanner({
    super.key,
    required this.icon,
    required this.title,
    required this.hint,
    required this.onTap,
  });

  final String icon;
  final String title;
  final String hint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Material(
      color: colors.selected,
      borderRadius: BorderRadius.circular(RevericRadius.large),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        child: Padding(
          padding: const EdgeInsets.all(RevericSpacing.lg),
          child: Row(
            children: [
              RevericIcon(icon, size: 20, color: colors.accent),
              const SizedBox(width: RevericSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSemibold.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: RevericSpacing.xxs),
                    Text(
                      hint,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSmall.copyWith(color: colors.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: RevericSpacing.sm),
              RevericIcon(
                RevericIcons.chevron_right,
                size: 20,
                color: colors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

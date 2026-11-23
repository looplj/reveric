// 职责: 展示移动端作品编辑页共享标题栏 — 返回按钮、居中标题/副标题（可选点击展开）与右侧图标操作。
// 关联文件:
//   lib/mobile/pages/novel_editor_page.dart
//   lib/mobile/features/screenplay/editor_page.dart
//   lib/shared/components/reveric_icon_button.dart
//   lib/shared/theme/theme.dart
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md

import 'package:flutter/material.dart';

import '../../shared/components/reveric_icon_button.dart';
import '../../shared/theme/theme.dart';

class MobileWorkspaceHeader extends StatelessWidget {
  const MobileWorkspaceHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onBack,
    this.onTitleTap,
    this.actions = const <Widget>[],
  });

  final String title;
  final String subtitle;
  final VoidCallback onBack;
  final VoidCallback? onTitleTap;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    final titleContent = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: typo.uiSemibold.copyWith(color: colors.textPrimary),
        ),
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.uiTiny.copyWith(color: colors.textMuted),
                ),
              ),
              if (onTitleTap != null)
                RevericIcon(
                  RevericIcons.caret_down,
                  size: 14,
                  color: colors.textMuted,
                ),
            ],
          ),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.xs,
        RevericSpacing.sm,
        RevericSpacing.xs,
        RevericSpacing.sm,
      ),
      child: Row(
        children: [
          RevericIconButton(
            icon: RevericIcons.arrow_back,
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: onBack,
          ),
          Expanded(
            child: onTitleTap == null
                ? titleContent
                : InkWell(
                    borderRadius: BorderRadius.circular(RevericRadius.small),
                    onTap: onTitleTap,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: RevericSpacing.xs,
                      ),
                      child: titleContent,
                    ),
                  ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

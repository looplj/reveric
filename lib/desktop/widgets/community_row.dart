// 职责: 桌面首页侧栏底部的社区入口 — 打开或复制 QQ 交流群，打开 GitHub 仓库。
// 关联文件:
//   lib/shared/widgets/community_links.dart
//   lib/shared/components/reveric_icon_button.dart
//   lib/desktop/pages/home.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md

import 'package:flutter/material.dart';

import '../../shared/components/reveric_icon_button.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/community_links.dart';

/// QQ 群带文字作为主入口，群号只提供复制；GitHub 退为图标按钮。
class CommunityRow extends StatelessWidget {
  const CommunityRow({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final radius = BorderRadius.circular(RevericRadius.iconButton);

    return Row(
      children: [
        Expanded(
          child: Material(
            color: colors.canvas,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: BorderSide(color: colors.borderSubtle),
            ),
            child: SizedBox(
              height: RevericSizes.iconButtonSize,
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => openQqGroup(context),
                      hoverColor: colors.hover,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: RevericSpacing.sm,
                        ),
                        child: Row(
                          children: [
                            _QqMark(colors: colors),
                            const SizedBox(width: RevericSpacing.sm),
                            Expanded(
                              child: Text(
                                context.t(LocaleKeys.settingsAboutJoinQqGroup),
                                style: typo.uiSmall.copyWith(
                                  color: colors.textPrimary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: colors.borderSubtle,
                  ),
                  Tooltip(
                    message: context.t(LocaleKeys.commonCopy),
                    child: InkWell(
                      onTap: () => copyQqGroupNumber(context),
                      hoverColor: colors.hover,
                      child: SizedBox(
                        width: RevericSizes.iconButtonSize,
                        height: RevericSizes.iconButtonSize,
                        child: Center(
                          child: RevericIcon(
                            RevericIcons.copy,
                            size: 14,
                            color: colors.textMuted,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: RevericSpacing.xxs),
        RevericIconButton(
          icon: RevericIcons.github_logo,
          tooltip: context.t(LocaleKeys.settingsAboutGithubRepository),
          onPressed: () => openGitHubRepo(context),
        ),
      ],
    );
  }
}

class _QqMark extends StatelessWidget {
  const _QqMark({required this.colors});

  final RevericColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colors.accentAmber.withValues(alpha: 0.14),
      ),
      alignment: Alignment.center,
      child: RevericIcon(
        RevericIcons.qq_logo,
        size: 13,
        color: colors.accentAmber,
      ),
    );
  }
}

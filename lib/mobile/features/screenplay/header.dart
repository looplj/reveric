// 职责: 展示剧本作品标题、季集上下文和工作台返回及聊天入口。
// 关联文件:
//   lib/mobile/features/screenplay/editor_page.dart
//   lib/mobile/features/screenplay/episode_picker_sheet.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/design-system.md

import 'package:flutter/material.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/theme/theme.dart';

class MobileScreenplayHeader extends StatelessWidget {
  const MobileScreenplayHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onBack,
    required this.onAi,
    this.onEpisode,
  });
  final String title;
  final String subtitle;
  final VoidCallback onBack;
  final VoidCallback onAi;
  final VoidCallback? onEpisode;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.xs),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const RevericIcon(RevericIcons.arrow_back, size: 20),
          ),
          Expanded(
            child: InkWell(
              onTap: onEpisode,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 64),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.body.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: typo.uiTiny.copyWith(
                              color: colors.textMuted,
                            ),
                          ),
                        ),
                        if (onEpisode != null)
                          const RevericIcon(RevericIcons.caret_down, size: 14),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: context.t(LocaleKeys.aiSessionModeChat),
            onPressed: onAi,
            icon: const RevericIcon(RevericIcons.auto_awesome, size: 20),
          ),
        ],
      ),
    );
  }
}

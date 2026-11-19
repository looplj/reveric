// 职责: 下一步建议条 — 有建议时左对齐撑满渲染可换行的 chip 组，无建议时不占空间
// 关联文件:
//   lib/shared/heuristic/chat_next_action.dart
//   lib/desktop/widgets/ai/chat/panel.dart
//   lib/mobile/pages/novel_chat_page.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/heuristic.json
//   assets/translations/zh-CN/heuristic.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
import 'package:flutter/material.dart';

import '../../../heuristic/chat_next_action.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../models/feature_id.dart';
import '../../../theme/theme.dart';

/// 建议条渲染在输入框正上方。
///
/// 建议来自模型的 `SuggestNextAction` 工具调用，不是客户端规则 —— 所以模型没挂
/// 建议时整条不渲染，不占高度、不留占位。刻意不做本地兜底：空着比凑一条模板
/// 建议好，只有当建议真的出现时它才是有效信号。
class NextActionBar extends StatelessWidget {
  const NextActionBar({super.key, required this.actions, required this.onPick});

  final List<ChatNextAction> actions;
  final ValueChanged<ChatNextAction> onPick;

  @override
  Widget build(BuildContext context) {
    // 验收硬要求：在最外层就返回，外面不能再包 Padding，否则会留下莫名空白。
    if (actions.isEmpty) {
      return const SizedBox.shrink();
    }

    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    // 宽度必须撑满：本条常被放进默认 CrossAxisAlignment.center 的 Column
    // （desktop panel 的根 Column 就是），只按内容宽度会被父级居中，与 mockup
    // 的左对齐不符。
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          RevericSpacing.lg,
          0,
          RevericSpacing.lg,
          RevericSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                RevericIcon(
                  RevericIcons.lightbulb_outline,
                  size: 11,
                  color: colors.textSubtle,
                ),
                const SizedBox(width: RevericSpacing.xs),
                Text(
                  context.t(LocaleKeys.heuristicNextActionTitle),
                  style: typo.uiTiny.copyWith(color: colors.textSubtle),
                ),
              ],
            ),
            const SizedBox(height: RevericSpacing.xs),
            // 换行而非横向滚动（对齐 mockup 的 `.m-nextact__row { flex-wrap: wrap }`）：
            // 面板窄时横向滚动会把后面的 chip 藏在视野外，用户根本不知道还有建议。
            // 最多 3 条，撑高有上界。
            Wrap(
              spacing: RevericSpacing.xs,
              runSpacing: RevericSpacing.xs,
              children: [
                for (final action in actions)
                  _NextActionChip(action: action, onTap: () => onPick(action)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NextActionChip extends StatelessWidget {
  const _NextActionChip({required this.action, required this.onTap});

  final ChatNextAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final isGoto = action.target is! PromptActionTarget;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(RevericRadius.pill),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.md,
              vertical: 5,
            ),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(RevericRadius.pill),
              border: Border.all(color: colors.borderInput),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                RevericIcon(
                  nextActionIconAsset(action),
                  size: 13,
                  color: isGoto ? colors.accent : colors.textMuted,
                ),
                const SizedBox(width: RevericSpacing.xs),
                Flexible(
                  child: Text(
                    action.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.uiMedium.copyWith(color: colors.textSecondary),
                  ),
                ),
                // 跳转类补一个箭头，提示「会离开当前对话」。
                if (isGoto) ...[
                  const SizedBox(width: RevericSpacing.xs),
                  RevericIcon(
                    RevericIcons.arrow_forward_rounded,
                    size: 11,
                    color: colors.textSubtle,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 建议图标：跳转类按目标功能取图，提示词类统一用灯泡。
String nextActionIconAsset(ChatNextAction action) {
  return switch (action.feature) {
    FeatureId.ai_council => RevericIcons.groups_rounded,
    FeatureId.ai_theater => RevericIcons.theater_comedy_rounded,
    FeatureId.ai_roleplay => RevericIcons.mask_happy_rounded,
    FeatureId.ai_cover_studio => RevericIcons.image,
    _ => RevericIcons.lightbulb_outline,
  };
}

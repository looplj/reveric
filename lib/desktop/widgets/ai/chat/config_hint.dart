// 职责: AI 聊天面板配置提示组件 — 当 AI 未配置时显示提示，并提供打开 AI 供应商设置的入口
// 关联文件:
//   lib/desktop/widgets/ai/chat/panel.dart
//   lib/desktop/widgets/agent_management/ai_providers_page.dart
//   lib/shared/localization/locale_keys.dart
import 'package:flutter/material.dart';

import '../../../../shared/components/reveric_button.dart';
import '../../../../shared/localization/app_localization.dart';
import '../../../../shared/localization/locale_keys.dart';
import '../../../../shared/theme/theme.dart';
import '../../agent_management/ai_providers_page.dart';

class ChatConfigHint extends StatelessWidget {
  const ChatConfigHint({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Expanded(
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            RevericIcon(
              RevericIcons.psychology_outlined,
              size: 48,
              color: colors.textMuted,
            ),
            const SizedBox(height: RevericSpacing.x2l),
            Text(
              context.t(LocaleKeys.aiNotConfigured),
              style: typo.uiSemibold.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: RevericSpacing.sm),
            Text(
              context.t(LocaleKeys.aiPleaseConfigure),
              style: typo.uiSmall.copyWith(color: colors.textMuted),
            ),
            const SizedBox(height: RevericSpacing.x2l),
            RevericButton.primary(
              label: context.t(LocaleKeys.aiConfigureProvider),
              icon: RevericIcons.settings_outlined,
              onPressed: () => showAiProviderSettingsDialog(context),
            ),
          ],
        ),
      ),
    );
  }
}

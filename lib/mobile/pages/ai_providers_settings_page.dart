// 职责: 移动端 AI Provider 设置页 — 从模型选择弹窗「添加模型」或 AI 未配置提示进入，复用 shared AiProvidersSection。
// 关联文件:
//   lib/shared/widgets/settings/ai_providers_section.dart
//   lib/mobile/widgets/model_effort_sheet.dart
//   lib/shared/localization/locale_keys.dart
//   lib/shared/theme/theme.dart
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/provider.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
import 'package:flutter/material.dart';

import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/settings/ai_providers_section.dart';

Future<void> openMobileAiProvidersSettingsPage(BuildContext context) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => const MobileAiProvidersSettingsPage()),
  );
}

/// AI Provider 设置页（全屏）：从模型选择弹窗的「添加模型」进入。
class MobileAiProvidersSettingsPage extends StatelessWidget {
  const MobileAiProvidersSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.surfaceDim,
        elevation: 0,
        foregroundColor: colors.textPrimary,
        title: Text(
          context.t(LocaleKeys.providerTitle),
          style: typo.heading2.copyWith(color: colors.textPrimary),
        ),
        leading: IconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          icon: RevericIcon(RevericIcons.arrow_back, color: colors.textPrimary),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: const AiProvidersSection(),
    );
  }
}

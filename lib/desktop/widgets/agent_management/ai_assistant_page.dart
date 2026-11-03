// 职责: 首页「AI 助手」管理页 — 以首页页头承载共享 AI 助手设置区，并提供独立弹窗入口。
// 关联文件:
//   lib/desktop/pages/home.dart
//   lib/desktop/widgets/agent_management/home_management_cards.dart
//   lib/desktop/widgets/agent_management/page_dialog.dart
//   lib/shared/widgets/settings/ai_agents_settings_section.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
import 'package:flutter/widgets.dart';

import '../../../shared/localization/locale_keys.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/settings/ai_agents_settings_section.dart';
import 'home_management_cards.dart';
import 'page_dialog.dart';

Future<void> showAiAssistantSettingsDialog(BuildContext context) {
  return showManagementPageDialog(
    context,
    builder: (headerKey, closeButton) => AiAssistantPage(
      headerGestureExclusionKey: headerKey,
      headerAction: closeButton,
    ),
  );
}

class AiAssistantPage extends StatelessWidget {
  const AiAssistantPage({
    super.key,
    required this.headerGestureExclusionKey,
    this.headerTrailingInset = 0,
    this.headerAction,
  });

  final GlobalKey headerGestureExclusionKey;
  final double headerTrailingInset;
  final Widget? headerAction;

  @override
  Widget build(BuildContext context) {
    return HomeManagementScaffold(
      headerGestureExclusionKey: headerGestureExclusionKey,
      headerTrailingInset: headerTrailingInset,
      secondaryAction: headerAction,
      icon: RevericIcons.smart_toy_outlined,
      titleKey: LocaleKeys.settingsAiAgents,
      child: const AiAgentsSettingsSection(),
    );
  }
}

// 职责: 首页「AI 供应商」管理页 — 以首页页头承载共享供应商设置区，并提供独立弹窗入口。
// 关联文件:
//   lib/desktop/pages/home.dart
//   lib/desktop/widgets/agent_management/home_management_cards.dart
//   lib/desktop/widgets/agent_management/page_dialog.dart
//   lib/shared/widgets/settings/ai_providers_section.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
import 'package:flutter/widgets.dart';

import '../../../shared/localization/locale_keys.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/settings/ai_providers_section.dart';
import 'home_management_cards.dart';
import 'page_dialog.dart';

/// 没有可用模型时的配置入口：就地弹出供应商管理页。
Future<void> showAiProviderSettingsDialog(BuildContext context) {
  return showManagementPageDialog(
    context,
    builder: (headerKey, closeButton) => AiProvidersPage(
      headerGestureExclusionKey: headerKey,
      headerAction: closeButton,
    ),
  );
}

class AiProvidersPage extends StatelessWidget {
  const AiProvidersPage({
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
      icon: RevericIcons.hub_outlined,
      titleKey: LocaleKeys.settingsProviders,
      child: const AiProvidersSection(),
    );
  }
}

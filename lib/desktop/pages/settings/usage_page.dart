// 职责: 桌面端用量统计页 — 为首页和直达弹窗提供页头，委托共享 UsageView 渲染统计。
// 关联文件:
//   lib/desktop/pages/home.dart
//   lib/desktop/widgets/agent_management/home_management_cards.dart
//   lib/desktop/widgets/agent_management/page_dialog.dart
//   lib/shared/widgets/settings/usage_view.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/home.json
//   assets/translations/zh-CN/home.json
// 遵循的 Rules:
//   .agents/rules/design-system.md

import 'package:flutter/material.dart';

import '../../../shared/localization/locale_keys.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/settings/usage_view.dart';
import '../../widgets/agent_management/home_management_cards.dart';
import '../../widgets/agent_management/page_dialog.dart';

Future<void> showUsageSettingsDialog(BuildContext context) {
  return showManagementPageDialog(
    context,
    builder: (headerKey, closeButton) => UsagePage(
      headerGestureExclusionKey: headerKey,
      headerAction: closeButton,
    ),
  );
}

class UsagePage extends StatelessWidget {
  const UsagePage({
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
      icon: RevericIcons.bar_chart_outlined,
      titleKey: LocaleKeys.homeUsage,
      child: const UsageView(showHeader: false),
    );
  }
}

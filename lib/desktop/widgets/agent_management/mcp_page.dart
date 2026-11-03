// 职责: 首页「MCP」管理页 — 在页内就地切换 MCP 服务列表与编辑表单，并提供独立弹窗入口。
// 关联文件:
//   lib/desktop/pages/home.dart
//   lib/desktop/widgets/agent_management/home_management_cards.dart
//   lib/desktop/widgets/agent_management/page_dialog.dart
//   lib/shared/widgets/settings/mcp/section.dart
//   lib/shared/widgets/settings/mcp/server_editor.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/mcp/config.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/settings/mcp/section.dart';
import '../../../shared/widgets/settings/mcp/server_editor.dart';
import 'home_management_cards.dart';
import 'page_dialog.dart';

Future<void> showMcpSettingsDialog(BuildContext context) {
  return showManagementPageDialog(
    context,
    builder: (headerKey, closeButton) => McpPage(
      headerGestureExclusionKey: headerKey,
      headerAction: closeButton,
    ),
  );
}

class McpPage extends StatelessWidget {
  const McpPage({
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
      titleKey: LocaleKeys.settingsMcp,
      child: const McpServersRegion(),
    );
  }
}

/// MCP 服务列表与编辑表单的就地切换区。
class McpServersRegion extends HookWidget {
  const McpServersRegion({super.key});

  @override
  Widget build(BuildContext context) {
    // 外层为空表示在看列表；内层 config 为空表示新建。
    final editing = useState<({McpServerConfig? config})?>(null);
    final target = editing.value;
    if (target == null) {
      return McpSettingsSection(
        onEdit: (config) => editing.value = (config: config),
      );
    }
    return McpServerEditor(
      key: ValueKey(target.config?.name),
      config: target.config,
      onClose: () => editing.value = null,
    );
  }
}

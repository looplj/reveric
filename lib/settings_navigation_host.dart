// 职责: 按平台打开已有设置分区，排除隐藏分区和调试入口，不等待用户配置。
// 关联文件:
//   lib/main.dart
//   lib/shared/providers/settings_navigation.dart
//   lib/mobile/pages/settings_page.dart
//   lib/desktop/widgets/settings/settings_dialog.dart
//   lib/desktop/widgets/agent_management/page_dialog.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'desktop/widgets/agent_management/ai_assistant_page.dart';
import 'desktop/widgets/agent_management/ai_providers_page.dart';
import 'desktop/widgets/agent_management/mcp_page.dart';
import 'desktop/widgets/agent_management/plugins_page.dart';
import 'desktop/widgets/settings/settings_dialog.dart';
import 'mobile/pages/settings_page.dart';
import 'shared/providers/settings_navigation.dart';
import 'shared/models/tool_permission.dart';

class SettingsNavigationHost extends HookConsumerWidget {
  const SettingsNavigationHost({
    super.key,
    required this.navigatorKey,
    required this.mobile,
  });
  final GlobalKey<NavigatorState> navigatorKey;
  final bool mobile;

  /// 桌面端已移到首页的 AI 管理页，沿用原分区 ID，以独立弹窗打开。
  static final Map<String, Future<void> Function(BuildContext)>
  _desktopPageDialogs = {
    'ai_agents': showAiAssistantSettingsDialog,
    'providers': showAiProviderSettingsDialog,
    'mcp': showMcpSettingsDialog,
    'plugins': showPluginsSettingsDialog,
  };

  static Set<String> get desktopNavigableSections => {
    ...SettingsDialog.navigableSections,
    ..._desktopPageDialogs.keys,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final navigation = ref.watch(settingsNavigationProvider);
    useEffect(() {
      Future<void> open(String section) {
        final supported = mobile
            ? SettingsPage.navigableSections
            : desktopNavigableSections;
        if (!supported.contains(section)) {
          throw ToolOperationException(
            'unsupported_section',
            'Settings section "$section" is unavailable on this platform. Available sections: ${supported.join(', ')}.',
          );
        }
        final navigator = navigatorKey.currentState;
        if (navigator == null || !navigator.mounted) {
          throw const ToolOperationException(
            'unavailable',
            'The application navigator is not available.',
          );
        }
        if (mobile) {
          return showMobileSettingsPage(navigator.context, section);
        }
        if (_desktopPageDialogs[section] case final show?) {
          return show(navigator.context);
        }
        return showDialog<void>(
          context: navigator.context,
          builder: (_) => SettingsDialog(initialNavId: section),
        );
      }

      navigation.openSection = open;
      return () {
        if (identical(navigation.openSection, open)) {
          navigation.openSection = null;
        }
      };
    }, [navigation, navigatorKey, mobile]);
    return const SizedBox.shrink();
  }
}

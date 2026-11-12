// 职责: 首页「插件」管理页 — 在页内就地切换插件列表、插件详情与安装预览，并提供独立弹窗入口。
// 关联文件:
//   lib/desktop/pages/home.dart
//   lib/desktop/widgets/agent_management/home_management_cards.dart
//   lib/desktop/widgets/agent_management/page_dialog.dart
//   lib/shared/widgets/settings/plugins/section.dart
//   lib/shared/widgets/settings/plugins/navigation.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../../shared/localization/locale_keys.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/settings/plugins/detail_page.dart';
import '../../../shared/widgets/settings/plugins/navigation.dart';
import '../../../shared/widgets/settings/plugins/preview_page.dart';
import '../../../shared/widgets/settings/plugins/section.dart';
import 'home_management_cards.dart';
import 'page_dialog.dart';

Future<void> showPluginsSettingsDialog(BuildContext context) {
  return showManagementPageDialog(
    context,
    builder: (headerKey, closeButton) => PluginsPage(
      headerGestureExclusionKey: headerKey,
      headerAction: closeButton,
    ),
  );
}

class PluginsPage extends StatelessWidget {
  const PluginsPage({
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
      icon: RevericIcons.layers_outlined,
      titleKey: LocaleKeys.settingsPlugins,
      child: const PluginsRegion(),
    );
  }
}

/// 插件列表、详情与安装预览的就地切换区。
class PluginsRegion extends HookWidget {
  const PluginsRegion({super.key});

  @override
  Widget build(BuildContext context) {
    // 为空表示在看列表。
    final target = useState<PluginSettingsTarget?>(null);
    void close() => target.value = null;
    return switch (target.value) {
      null => PluginsSettingsSection(onOpen: (next) => target.value = next),
      PluginDetailTarget(:final pluginId) => PluginDetailPage(
        key: ValueKey('plugin-detail-$pluginId'),
        pluginId: pluginId,
        mobile: false,
        onClose: close,
      ),
      PluginPreviewTarget(:final archive) => PluginPreviewPage(
        key: ObjectKey(archive),
        archive: archive,
        mobile: false,
        onClose: close,
        onInstalled: (pluginId) => target.value = PluginDetailTarget(pluginId),
      ),
    };
  }
}

// 职责: 在桌面设置内容区就地切换插件列表、插件详情与安装预览。
// 关联文件:
//   lib/desktop/widgets/settings/settings_dialog.dart
//   lib/shared/widgets/settings/plugins/section.dart
//   lib/shared/widgets/settings/plugins/navigation.dart
//   lib/shared/widgets/settings/plugins/detail_page.dart
//   lib/shared/widgets/settings/plugins/preview_page.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/widgets/settings/plugins/detail_page.dart';
import '../../../shared/widgets/settings/plugins/navigation.dart';
import '../../../shared/widgets/settings/plugins/preview_page.dart';
import '../../../shared/widgets/settings/plugins/section.dart';

class PluginsDesktopSettingsSection extends HookWidget {
  const PluginsDesktopSettingsSection({super.key});
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

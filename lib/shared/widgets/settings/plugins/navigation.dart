// 职责: 定义插件设置的子页面目标，并在移动端以全屏路由打开详情与安装预览。
// 关联文件:
//   lib/shared/widgets/settings/plugins/section.dart
//   lib/shared/widgets/settings/plugins/detail_page.dart
//   lib/shared/widgets/settings/plugins/preview_page.dart
//   lib/desktop/widgets/agent_management/plugins_page.dart
import 'package:flutter/material.dart';
import '../../../services/plugins/package_archive.dart';
import '../../../theme/theme.dart';
import 'detail_page.dart';
import 'preview_page.dart';

/// 插件设置在列表之外打开的子页面。
sealed class PluginSettingsTarget {
  const PluginSettingsTarget();
}

class PluginDetailTarget extends PluginSettingsTarget {
  const PluginDetailTarget(this.pluginId);
  final String pluginId;
}

class PluginPreviewTarget extends PluginSettingsTarget {
  const PluginPreviewTarget(this.archive);
  final PluginPackageArchive archive;
}

/// 移动端推入全屏子页面；桌面端由设置内容区就地替换列表，不经过此入口。
Future<void> pushPluginSettingsPage(
  BuildContext context,
  PluginSettingsTarget target,
) {
  final theme = RevericTheme.of(context);
  Route<void> route(PluginSettingsTarget target) => MaterialPageRoute<void>(
    builder: (routeContext) => RevericTheme(
      data: theme,
      child: switch (target) {
        PluginDetailTarget(:final pluginId) => PluginDetailPage(
          pluginId: pluginId,
          mobile: true,
          onClose: () => Navigator.of(routeContext).pop(),
        ),
        PluginPreviewTarget(:final archive) => PluginPreviewPage(
          archive: archive,
          mobile: true,
          onClose: () => Navigator.of(routeContext).pop(),
          // 安装完成后以详情页替换预览，返回时回到列表。
          onInstalled: (pluginId) => Navigator.of(
            routeContext,
          ).pushReplacement(route(PluginDetailTarget(pluginId))),
        ),
      },
    ),
  );
  return Navigator.of(context).push(route(target));
}

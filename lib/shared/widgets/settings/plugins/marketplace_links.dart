// 职责: 提供插件市场条目的安全外链打开能力与仓库/发布页跳转按钮组，供市场卡片与安装预览页复用。
// 关联文件:
//   lib/shared/models/plugin/marketplace_plugin.dart
//   lib/shared/widgets/settings/plugins/marketplace_card.dart
//   lib/shared/widgets/settings/plugins/preview_page.dart
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../components/reveric_button.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../models/plugin/marketplace_plugin.dart';
import '../../../theme/theme.dart';

/// 校验并打开插件市场 HTTPS 外部链接，失败时通过 SnackBar 提示。
Future<void> openPluginMarketplaceUrl(
  BuildContext context,
  String rawUrl, {
  Future<bool> Function(Uri uri)? launcher,
}) async {
  final normalized = normalizeMarketplaceHttpsUrl(rawUrl);
  if (normalized == null) {
    return;
  }
  final uri = Uri.parse(normalized);
  try {
    final opened = launcher != null
        ? await launcher(uri)
        : await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.t(LocaleKeys.commonOpenLinkFailed))),
      );
    }
  } on Object {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.t(LocaleKeys.commonOpenLinkFailed))),
      );
    }
  }
}

/// 展示项目仓库与发布详情的外链按钮组。
class PluginMarketplaceLinks extends StatelessWidget {
  const PluginMarketplaceLinks({
    super.key,
    this.repository,
    this.releaseUrl,
    this.onOpenUrl,
  });

  final String? repository;
  final String? releaseUrl;
  final Future<void> Function(BuildContext context, String url)? onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final open = onOpenUrl ?? openPluginMarketplaceUrl;
    final hasRepository = normalizeMarketplaceHttpsUrl(repository) != null;
    final hasRelease = normalizeMarketplaceHttpsUrl(releaseUrl) != null;
    if (!hasRepository && !hasRelease) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: RevericSpacing.xs,
      runSpacing: RevericSpacing.xs,
      children: [
        if (hasRepository)
          RevericButton.text(
            label: context.t(LocaleKeys.pluginMarketplaceRepository),
            icon: RevericIcons.arrow_square_out,
            size: RevericButtonSize.compact,
            onPressed: () => open(context, repository!),
          ),
        if (hasRelease)
          RevericButton.text(
            label: context.t(LocaleKeys.pluginMarketplaceReleaseNotes),
            icon: RevericIcons.arrow_square_out,
            size: RevericButtonSize.compact,
            onPressed: () => open(context, releaseUrl!),
          ),
      ],
    );
  }
}

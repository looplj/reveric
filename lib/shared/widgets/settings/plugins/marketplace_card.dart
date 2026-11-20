// 职责: 展示插件市场中的单个插件卡片、版本兼容/已安装状态，并触发下载与安装预览。
// 关联文件:
//   lib/shared/models/plugin/marketplace_plugin.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/widgets/settings/plugins/marketplace_links.dart
//   lib/shared/widgets/settings/plugins/overview.dart
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
//   .agents/rules/widget-decomposition.md

import 'package:flutter/material.dart';
import 'package:pub_semver/pub_semver.dart';

import '../../../components/reveric_badge.dart';
import '../../../components/reveric_button.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../models/plugin/marketplace_plugin.dart';
import '../../../services/plugins/host.dart';
import '../../../theme/theme.dart';
import '../settings_section_widgets.dart';
import 'marketplace_links.dart';
import 'overview.dart';

enum _PluginMarketplaceRelation {
  available,
  updateAvailable,
  installedUpToDate,
  bundled,
  unsupported,
}

_PluginMarketplaceRelation _resolveRelation({
  required MarketplacePluginVersion? compatibleVersion,
  required PluginStatus? installed,
}) {
  if (installed?.source == 'bundled') {
    return _PluginMarketplaceRelation.bundled;
  }
  if (compatibleVersion == null) {
    return _PluginMarketplaceRelation.unsupported;
  }
  if (installed == null) {
    return _PluginMarketplaceRelation.available;
  }
  final installedVersion = installed.manifest?.version;
  if (installedVersion == null) {
    return _PluginMarketplaceRelation.updateAvailable;
  }
  try {
    final parsedInstalled = Version.parse(installedVersion);
    return compatibleVersion.parsedVersion > parsedInstalled
        ? _PluginMarketplaceRelation.updateAvailable
        : _PluginMarketplaceRelation.installedUpToDate;
  } on FormatException {
    return _PluginMarketplaceRelation.updateAvailable;
  }
}

/// 单个插件市场条目卡片。
class PluginMarketplaceCard extends StatelessWidget {
  const PluginMarketplaceCard({
    super.key,
    required this.entry,
    required this.platform,
    required this.installed,
    required this.downloading,
    required this.busy,
    this.downloadError,
    required this.onInstall,
    this.onOpenUrl,
  });

  final MarketplacePluginEntry entry;
  final String platform;
  final PluginStatus? installed;
  final bool downloading;
  final bool busy;
  final String? downloadError;
  final ValueChanged<MarketplacePluginVersion> onInstall;
  final Future<void> Function(BuildContext context, String url)? onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final locale = Localizations.localeOf(context);
    final compatibleVersion = entry.resolveCompatibleVersion(
      platform: platform,
    );
    final displayVersion = compatibleVersion ?? entry.latestVersion;
    final relation = _resolveRelation(
      compatibleVersion: compatibleVersion,
      installed: installed,
    );

    final metaParts = <String>[
      entry.id,
      'v${displayVersion.version}',
      if (entry.author != null && entry.author!.isNotEmpty)
        context.t(
          LocaleKeys.pluginAuthor,
          namedArgs: {'author': entry.author!},
        ),
    ];

    final badge = switch (relation) {
      _PluginMarketplaceRelation.bundled => RevericBadge(
        label: context.t(LocaleKeys.pluginBundled),
        color: colors.textMuted,
      ),
      _PluginMarketplaceRelation.installedUpToDate => RevericBadge(
        label: context.t(
          LocaleKeys.pluginMarketplaceInstalledVersion,
          namedArgs: {
            'version': installed?.manifest?.version ?? displayVersion.version,
          },
        ),
        color: colors.success,
      ),
      _PluginMarketplaceRelation.updateAvailable => RevericBadge(
        label: context.t(
          LocaleKeys.pluginMarketplaceUpdateVersion,
          namedArgs: {'version': compatibleVersion!.version},
        ),
        color: colors.accent,
      ),
      _PluginMarketplaceRelation.unsupported => RevericBadge(
        label: context.t(LocaleKeys.pluginMarketplaceUnsupported),
        color: colors.warningText,
      ),
      _PluginMarketplaceRelation.available => null,
    };

    final actionButton = switch (relation) {
      _PluginMarketplaceRelation.available => RevericButton.primary(
        label: downloading
            ? context.t(LocaleKeys.pluginMarketplaceDownloading)
            : context.t(LocaleKeys.commonInstall),
        icon: RevericIcons.download_simple,
        size: RevericButtonSize.compact,
        loading: downloading,
        onPressed: !busy && compatibleVersion != null
            ? () => onInstall(compatibleVersion)
            : null,
      ),
      _PluginMarketplaceRelation.updateAvailable => RevericButton.secondary(
        label: downloading
            ? context.t(LocaleKeys.pluginMarketplaceDownloading)
            : context.t(LocaleKeys.pluginMarketplaceUpdate),
        icon: RevericIcons.download_simple,
        size: RevericButtonSize.compact,
        loading: downloading,
        onPressed: !busy && compatibleVersion != null
            ? () => onInstall(compatibleVersion)
            : null,
      ),
      _PluginMarketplaceRelation.installedUpToDate => RevericButton.secondary(
        label: context.t(LocaleKeys.pluginMarketplaceInstalled),
        icon: RevericIcons.check_circle,
        size: RevericButtonSize.compact,
        onPressed: null,
      ),
      _PluginMarketplaceRelation.bundled => RevericButton.secondary(
        label: context.t(LocaleKeys.pluginBundled),
        size: RevericButtonSize.compact,
        onPressed: null,
      ),
      _PluginMarketplaceRelation.unsupported => RevericButton.secondary(
        label: context.t(LocaleKeys.pluginMarketplaceUnsupported),
        size: RevericButtonSize.compact,
        onPressed: null,
      ),
    };

    final description = entry.description?.resolve(locale);

    return SettingsCard(
      children: [
        Wrap(
          spacing: RevericSpacing.sm,
          runSpacing: RevericSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              entry.name.resolve(locale),
              style: typo.uiSemibold.copyWith(color: colors.textPrimary),
            ),
            ?badge,
          ],
        ),
        const SizedBox(height: RevericSpacing.xxs),
        Text(
          metaParts.join(' · '),
          style: typo.uiSmall.copyWith(color: colors.textMuted),
        ),
        if (description != null && description.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.sm),
          Text(
            description,
            style: typo.uiSmall.copyWith(color: colors.textSecondary),
          ),
        ],
        if (downloadError != null) ...[
          const SizedBox(height: RevericSpacing.sm),
          PluginNotice(message: downloadError!),
        ],
        const SizedBox(height: RevericSpacing.md),
        SizedBox(
          width: double.infinity,
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: RevericSpacing.sm,
            runSpacing: RevericSpacing.sm,
            children: [
              PluginMarketplaceLinks(
                repository: entry.repository,
                releaseUrl: displayVersion.releaseUrl,
                onOpenUrl: onOpenUrl,
              ),
              actionButton,
            ],
          ),
        ),
      ],
    );
  }
}

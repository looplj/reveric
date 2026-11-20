// 职责: 展示官方插件市场页签内容：搜索、刷新、缓存回退提示、安装包下载并打开权限预览。
// 关联文件:
//   lib/shared/providers/plugin_marketplace_providers.dart
//   lib/shared/providers/plugin_providers.dart
//   lib/shared/services/plugins/marketplace_service.dart
//   lib/shared/widgets/settings/plugins/marketplace_card.dart
//   lib/shared/widgets/settings/plugins/navigation.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/search-debounce.md
//   .agents/rules/error-handling.md

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../components/reveric_button.dart';
import '../../../components/reveric_placeholder.dart';
import '../../../components/reveric_search_field.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../models/plugin/marketplace_plugin.dart';
import '../../../providers/plugin_marketplace_providers.dart';
import '../../../providers/plugin_providers.dart';
import '../../../services/plugins/host.dart';
import '../../../services/plugins/marketplace_service.dart';
import '../../../theme/theme.dart';
import 'marketplace_card.dart';
import 'navigation.dart';
import 'overview.dart';

String _downloadErrorKey(PluginMarketplaceErrorKind kind) => switch (kind) {
  PluginMarketplaceErrorKind.integrityMismatch ||
  PluginMarketplaceErrorKind.packageTooLarge ||
  PluginMarketplaceErrorKind.invalidPackage =>
    LocaleKeys.pluginMarketplaceIntegrityFailed,
  _ => LocaleKeys.pluginMarketplaceDownloadFailed,
};

/// 插件市场浏览与一键下载安装入口（桌面端与移动端共用）。
class PluginMarketplaceTab extends HookConsumerWidget {
  const PluginMarketplaceTab({super.key, required this.onOpen, this.onOpenUrl});

  final ValueChanged<PluginSettingsTarget> onOpen;
  final Future<void> Function(BuildContext context, String url)? onOpenUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final search = useDebouncedSearch();
    final downloadingId = useState<String?>(null);
    final downloadErrors = useState<Map<String, String>>({});
    final cancelTokenRef = useRef<CancelToken?>(null);

    useEffect(() {
      return () {
        cancelTokenRef.value?.cancel();
      };
    }, const []);

    final catalog = ref.watch(pluginMarketplaceProvider);
    final catalogNotifier = ref.read(pluginMarketplaceProvider.notifier);
    final host = ref.watch(pluginHostServiceProvider);
    final installedStatuses =
        ref.watch(pluginStatusesProvider).asData?.value ?? host.statuses;
    final installedById = <String, PluginStatus>{
      for (final status in installedStatuses) status.id: status,
    };

    Future<void> installPlugin(
      MarketplacePluginEntry entry,
      MarketplacePluginVersion version,
    ) async {
      if (downloadingId.value != null) {
        return;
      }
      cancelTokenRef.value?.cancel();
      final token = CancelToken();
      cancelTokenRef.value = token;
      downloadingId.value = entry.id;
      downloadErrors.value = {...downloadErrors.value}..remove(entry.id);

      try {
        final archive = await ref
            .read(pluginMarketplaceServiceProvider)
            .downloadPackage(
              pluginId: entry.id,
              version: version,
              cancelToken: token,
            );
        if (!context.mounted) {
          return;
        }
        downloadingId.value = null;
        onOpen(
          PluginPreviewTarget(
            archive,
            marketplace: PluginMarketplaceOrigin(
              repository: entry.repository,
              releaseUrl: version.releaseUrl,
            ),
          ),
        );
      } on DioException catch (error) {
        if (CancelToken.isCancel(error)) {
          if (context.mounted) {
            downloadingId.value = null;
          }
          return;
        }
        if (context.mounted) {
          downloadingId.value = null;
          downloadErrors.value = {
            ...downloadErrors.value,
            entry.id: context.t(LocaleKeys.pluginMarketplaceDownloadFailed),
          };
        }
      } on PluginMarketplaceException catch (error) {
        if (context.mounted) {
          downloadingId.value = null;
          downloadErrors.value = {
            ...downloadErrors.value,
            entry.id: context.t(_downloadErrorKey(error.kind)),
          };
        }
      } on Object {
        if (context.mounted) {
          downloadingId.value = null;
          downloadErrors.value = {
            ...downloadErrors.value,
            entry.id: context.t(LocaleKeys.pluginMarketplaceDownloadFailed),
          };
        }
      } finally {
        if (identical(cancelTokenRef.value, token)) {
          cancelTokenRef.value = null;
        }
      }
    }

    final locale = Localizations.localeOf(context);
    final filtered = search.active
        ? catalog.plugins
              .where((entry) => entry.matches(search.query, locale))
              .toList(growable: false)
        : catalog.plugins;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: RevericSearchField(
                controller: search.controller,
                hint: context.t(LocaleKeys.pluginMarketplaceSearchHint),
                highlightWhenFilled: true,
              ),
            ),
            const SizedBox(width: RevericSpacing.sm),
            RevericButton.secondary(
              label: context.t(LocaleKeys.commonRefresh),
              icon: RevericIcons.arrow_clockwise,
              loading: catalog.refreshing,
              onPressed: catalog.loading || catalog.refreshing
                  ? null
                  : catalogNotifier.refresh,
            ),
          ],
        ),
        if (catalog.errorKind != null && catalog.hasData) ...[
          const SizedBox(height: RevericSpacing.md),
          PluginNotice(
            message: context.t(LocaleKeys.pluginMarketplaceCachedWarning),
          ),
        ],
        const SizedBox(height: RevericSpacing.lg),
        if (catalog.loading && !catalog.hasData)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: RevericSpacing.x4l),
            child: Center(child: CircularProgressIndicator.adaptive()),
          )
        else if (catalog.errorKind != null && !catalog.hasData)
          Center(
            child: RevericPlaceholder.error(
              title: context.t(LocaleKeys.pluginMarketplaceLoadFailed),
              description: context.t(
                LocaleKeys.pluginMarketplaceLoadFailedDescription,
              ),
              action: RevericButton.secondary(
                label: context.t(LocaleKeys.commonRetry),
                icon: RevericIcons.arrow_clockwise,
                onPressed: catalogNotifier.refresh,
              ),
            ),
          )
        else if (catalog.plugins.isEmpty)
          Center(
            child: RevericPlaceholder.empty(
              icon: RevericIcons.storefront,
              title: context.t(LocaleKeys.pluginMarketplaceEmpty),
              description: context.t(
                LocaleKeys.pluginMarketplaceEmptyDescription,
              ),
            ),
          )
        else if (filtered.isEmpty)
          Center(
            child: RevericPlaceholder.empty(
              icon: RevericIcons.search,
              title: context.t(LocaleKeys.pluginMarketplaceSearchEmpty),
            ),
          )
        else
          for (final (index, entry) in filtered.indexed) ...[
            if (index > 0) const SizedBox(height: RevericSpacing.sm),
            PluginMarketplaceCard(
              key: ValueKey('marketplace-${entry.id}'),
              entry: entry,
              platform: host.platform,
              installed: installedById[entry.id],
              downloading: downloadingId.value == entry.id,
              busy: downloadingId.value != null,
              downloadError: downloadErrors.value[entry.id],
              onInstall: (version) => installPlugin(entry, version),
              onOpenUrl: onOpenUrl,
            ),
          ],
      ],
    );
  }
}

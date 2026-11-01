// 职责: 展示移动端供应商分组列表，支持详情导航和左滑确认删除。
// 关联文件:
//   lib/shared/widgets/settings/ai_providers_section.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/widgets/settings/provider_actions.dart
//   lib/shared/components/reveric_slidable_delete.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md
//   .agents/rules/state-management.md
//   .agents/rules/hooks.md

import 'package:flutter/material.dart';
import '../../components/reveric_search_field.dart';
import '../../components/reveric_icon_button.dart';
import 'provider_logo.dart';
import 'provider_overview.dart';
import 'providers/registry.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../components/reveric_badge.dart';
import '../../components/reveric_slidable_delete.dart';
import '../../localization/ai_provider_localization.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/ai_provider.dart';
import '../../providers/settings_providers.dart';
import '../../theme/theme.dart';
import 'ai_providers_section.dart';
import 'provider_actions.dart';

/// 移动端供应商列表：全宽分组卡片，每行下钻到配置页。
/// 与 `lib/mobile/pages/settings_page.dart` 主设置列表保持一致的视觉规范。
class MobileProviderList extends HookConsumerWidget {
  final List<AiProvider> configs;

  final String? selectedId;

  final ValueChanged<String> onSelect;
  final VoidCallback onAddCustom;

  const MobileProviderList({
    super.key,
    required this.configs,

    required this.selectedId,

    required this.onSelect,
    required this.onAddCustom,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final search = useDebouncedSearch();
    final filtered = configs
        .where(
          (config) =>
              '${localizedAiProviderName(context, config)} ${config.type} ${config.videoModels.join(' ')}'
                  .toLowerCase()
                  .contains(search.query),
        )
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.x3l,
        RevericSpacing.lg,
        RevericSpacing.x3l,
        RevericSpacing.x4l,
      ),
      children: [
        Row(
          children: [
            Expanded(
              child: RevericSearchField(
                controller: search.controller,
                hint: context.t(LocaleKeys.settingsProviderSearchHint),
              ),
            ),
            const SizedBox(width: RevericSpacing.sm),
            RevericIconButton(
              icon: RevericIcons.add,
              tooltip: context.t(LocaleKeys.commonAdd),
              onPressed: onAddCustom,
            ),
          ],
        ),
        const SizedBox(height: RevericSpacing.lg),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.all(RevericSpacing.x4l),
            child: Text(context.t(LocaleKeys.commonNoResults), style: typo.ui),
          ),
        if (filtered.isNotEmpty)
          Container(
            clipBehavior: Clip.hardEdge,
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(RevericRadius.x2l),
              border: Border.all(color: colors.borderSubtle),
            ),
            child: Column(
              children: [
                for (var i = 0; i < filtered.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: colors.borderSubtle,
                    ),
                  if (filtered[i].canDelete)
                    RevericSlidableDelete(
                      key: ValueKey(filtered[i].id),
                      borderRadius: BorderRadius.zero,
                      deleteLabel: context.t(LocaleKeys.commonDelete),
                      onDelete: () async {
                        final notifier = ref.read(appSettingsProvider.notifier);
                        await confirmDeleteProvider(
                          context,
                          config: filtered[i],
                          onDelete: () =>
                              notifier.removeProvider(filtered[i].id),
                        );
                      },
                      childBuilder: (context, _) => Material(
                        color: colors.surface,
                        child: _MobileProviderRow(
                          config: filtered[i],

                          locked: false,
                          onTap: () => onSelect(filtered[i].id),
                        ),
                      ),
                    )
                  else
                    _MobileProviderRow(
                      key: ValueKey(filtered[i].id),
                      config: filtered[i],

                      locked: false,
                      onTap: () => onSelect(filtered[i].id),
                    ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _MobileProviderRow extends StatelessWidget {
  final AiProvider config;

  final bool locked;
  final VoidCallback onTap;

  const _MobileProviderRow({
    super.key,
    required this.config,

    this.locked = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final providerName = localizedAiProviderName(context, config);
    final showcase = providerShowcases[config.type];

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.xl,
          vertical: RevericSpacing.lg,
        ),
        child: Row(
          children: [
            ProviderLogo(type: config.type),
            const SizedBox(width: RevericSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          providerName,
                          style: typo.ui.copyWith(color: colors.textPrimary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (!config.isTypeSupported || !config.isBuiltin) ...[
                        const SizedBox(width: RevericSpacing.sm),
                        Flexible(
                          child: RevericBadge(
                            label: !config.isTypeSupported
                                ? context.t(
                                    LocaleKeys.settingsProviderUnsupportedBadge,
                                  )
                                : context.t(LocaleKeys.settingsCustomBadge),
                            color: !config.isTypeSupported
                                ? colors.warningText
                                : colors.accentWarm,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (config.isTypeSupported) ...[
                    const SizedBox(height: RevericSpacing.xxs),
                    Text(
                      showcase?.listTagline?.call(context) ??
                          providerCapabilitySummary(context, config),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSmall.copyWith(color: colors.textMuted),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: RevericSpacing.sm),
            ProviderStatusDot(
              active: config.isValid,
              size: RevericSizes.statusDotSizeMobile,
            ),
            const SizedBox(width: RevericSpacing.sm),
            RevericIcon(
              RevericIcons.keyboard_arrow_right,
              size: 18,
              color: colors.textSubtle,
            ),
          ],
        ),
      ),
    );
  }
}

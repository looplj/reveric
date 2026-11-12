// 职责: 展示 无限星河 的聊天模型、接入说明与赞助渠道入口。
// 关联文件:
//   lib/shared/widgets/settings/providers/registry.dart
//   lib/shared/widgets/settings/provider_overview.dart
//   lib/shared/models/provider_brand.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/provider.json

import 'package:flutter/material.dart';

import '../../../components/reveric_badge.dart';
import '../../../components/reveric_button.dart';
import '../../../components/reveric_surfaces.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../models/provider_brand.dart';
import '../../../theme/theme.dart';
import '../provider_overview.dart';
import 'registry.dart';

const infistarShowcase = ProviderShowcase(
  card: _buildCard,
  listTagline: _listTagline,
);

Widget _buildCard(BuildContext context) => const _InfistarCard();

String _listTagline(BuildContext context) =>
    context.t(LocaleKeys.providerInfistarListTagline);

class _InfistarCard extends StatelessWidget {
  const _InfistarCard();

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final divider = Padding(
      padding: const EdgeInsets.symmetric(vertical: RevericSpacing.x3l),
      child: Divider(
        height: RevericSizes.dividerThickness,
        color: colors.borderSubtle,
      ),
    );
    return RevericElevatedCard(
      fallback: colors.surface,
      padding: const EdgeInsets.all(RevericSpacing.x4l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  context.t(LocaleKeys.providerInfistarCategory),
                  style: typo.uiTiny.copyWith(color: colors.textMuted),
                ),
              ),
              RevericBadge(
                label: context.t(LocaleKeys.providerSponsoredBadge),
                color: colors.textMuted,
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.lg),
          Text(
            context.t(LocaleKeys.providerInfistarTitle),
            style: typo.heading2.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: RevericSpacing.sm),
          Text(
            context.t(LocaleKeys.providerInfistarSummary),
            style: typo.uiSmall.copyWith(color: colors.textSecondary),
          ),
          divider,
          Text(
            'Claude · GPT · Gemini',
            style: typo.uiSemibold.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: RevericSpacing.sm),
          Text(
            context.t(LocaleKeys.providerInfistarModels),
            style: typo.uiSmall.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: RevericSpacing.lg),
          Text(
            'DeepSeek · Kimi · GLM · Grok · MiniMax · Qwen',
            style: typo.uiSmall.copyWith(color: colors.textSecondary),
          ),
          divider,
          Text(
            context.t(LocaleKeys.providerInfistarSetupTitle),
            style: typo.uiSemibold.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: RevericSpacing.sm),
          Text(
            context.t(LocaleKeys.providerInfistarSetup),
            style: typo.uiSmall.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: RevericSpacing.x3l),
          Wrap(
            spacing: RevericSpacing.lg,
            runSpacing: RevericSpacing.sm,
            children: [
              RevericButton.primary(
                label: context.t(LocaleKeys.providerInfistarLink),
                icon: RevericIcons.arrow_square_out,
                onPressed: () => openProviderChannelUrl(
                  context,
                  providerChannelUrls['infistar']!,
                ),
              ),
              RevericButton.secondary(
                label: context.t(LocaleKeys.providerInfistarPricingLink),
                onPressed: () => openProviderChannelUrl(
                  context,
                  'https://infistar.cc/pricing?aff=FQHYXMMS&ref_source=link',
                ),
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.lg),
          Text(
            context.t(LocaleKeys.providerInfistarNote),
            style: typo.uiTiny.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

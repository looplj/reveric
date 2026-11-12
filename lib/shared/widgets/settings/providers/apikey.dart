// 职责: 展示 APIKEY.FAN 的聊天模型、接入说明与赞助渠道入口。
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

const apikeyShowcase = ProviderShowcase(
  card: _buildCard,
  listTagline: _listTagline,
);

Widget _buildCard(BuildContext context) => const _ApikeyCard();

String _listTagline(BuildContext context) =>
    context.t(LocaleKeys.providerApikeyListTagline);

class _ApikeyCard extends StatelessWidget {
  const _ApikeyCard();

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
                  context.t(LocaleKeys.providerApikeyCategory),
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
            context.t(LocaleKeys.providerApikeyTitle),
            style: typo.heading2.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: RevericSpacing.sm),
          Text(
            context.t(LocaleKeys.providerApikeySummary),
            style: typo.uiSmall.copyWith(color: colors.textSecondary),
          ),
          divider,
          Text(
            'Claude · GPT · Gemini',
            style: typo.uiSemibold.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: RevericSpacing.sm),
          Text(
            context.t(LocaleKeys.providerApikeyModels),
            style: typo.uiSmall.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: RevericSpacing.lg),
          Text(
            'DeepSeek · Kimi · GLM · Grok · MiniMax · Qwen · MiMo',
            style: typo.uiSmall.copyWith(color: colors.textSecondary),
          ),
          divider,
          Text(
            context.t(LocaleKeys.providerApikeySetupTitle),
            style: typo.uiSemibold.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: RevericSpacing.sm),
          Text(
            context.t(LocaleKeys.providerApikeySetup),
            style: typo.uiSmall.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: RevericSpacing.x3l),
          Wrap(
            spacing: RevericSpacing.lg,
            runSpacing: RevericSpacing.sm,
            children: [
              RevericButton.primary(
                label: context.t(LocaleKeys.providerApikeyLink),
                icon: RevericIcons.arrow_square_out,
                onPressed: () => openProviderChannelUrl(
                  context,
                  providerChannelUrls['apikey']!,
                ),
              ),
              RevericButton.secondary(
                label: context.t(LocaleKeys.providerApikeyPricingLink),
                onPressed: () => openProviderChannelUrl(
                  context,
                  'https://apikey.fun/pricing?aff=axonhub',
                ),
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.lg),
          Text(
            context.t(LocaleKeys.providerApikeyNote),
            style: typo.uiTiny.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

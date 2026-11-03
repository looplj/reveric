// 职责: 展示 88API 的多模态模型、价格示例与渠道入口。
// 关联文件:
//   lib/shared/widgets/settings/providers/registry.dart
//   lib/shared/widgets/settings/provider_overview.dart
//   lib/shared/models/provider_brand.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md

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

// 标准价（元），DeepSeek 为官方价五折后的输入 / 输出价，以 88API 官网为准。
const _imagePrice = '¥0.15';
const _videoPrice = '¥0.27';
const _deepseekPrice = '¥0.50 / ¥2';
const _pricingUrl = 'https://88api.ai/pricing';

const api88Showcase = ProviderShowcase(
  card: _buildCard,
  listTagline: _listTagline,
);

Widget _buildCard(BuildContext context) => const _Api88Card();

String _listTagline(BuildContext context) =>
    context.t(LocaleKeys.settingsProviderApi88ListTagline);

class _Api88Card extends StatelessWidget {
  const _Api88Card();

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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 420;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.t(LocaleKeys.settingsProviderApi88Category),
                      style: typo.uiTiny.copyWith(color: colors.textMuted),
                    ),
                  ),
                  RevericBadge(
                    label: context.t(LocaleKeys.settingsProviderSponsoredBadge),
                    color: colors.textMuted,
                  ),
                ],
              ),
              const SizedBox(height: RevericSpacing.lg),
              Text(
                context.t(LocaleKeys.settingsProviderApi88Title),
                style: typo.heading2.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: RevericSpacing.sm),
              Text(
                context.t(LocaleKeys.settingsProviderApi88Summary),
                style: typo.uiSmall.copyWith(color: colors.textSecondary),
              ),
              divider,
              _ModelPrice(
                wide: wide,
                name: 'Nano Banana 2',
                description: context.t(
                  LocaleKeys.settingsProviderApi88ImageDetail,
                ),
                price: _imagePrice,
                unit: context.t(LocaleKeys.settingsProviderApi88ImageUnit),
              ),
              const SizedBox(height: RevericSpacing.x3l),
              _ModelPrice(
                wide: wide,
                name: 'Seedance 2.0 Fast',
                description: context.t(
                  LocaleKeys.settingsProviderApi88VideoDetail,
                ),
                price: _videoPrice,
                unit: context.t(LocaleKeys.settingsProviderApi88VideoUnit),
              ),
              const SizedBox(height: RevericSpacing.x3l),
              _ModelPrice(
                wide: wide,
                name: 'DeepSeek V4.1 Flash',
                badge: context.t(
                  LocaleKeys.settingsProviderApi88DeepseekDiscount,
                ),
                description: context.t(
                  LocaleKeys.settingsProviderApi88DeepseekDetail,
                ),
                price: _deepseekPrice,
                unit: context.t(LocaleKeys.settingsProviderApi88TokensUnit),
              ),
              divider,
              _pair(
                wide: wide,
                first: _Capability(
                  icon: RevericIcons.pencil_simple,
                  title: context.t(LocaleKeys.settingsProviderApi88ChatModels),
                  models: 'GPT · Claude · Gemini · DeepSeek',
                ),
                second: _Capability(
                  icon: RevericIcons.microphone,
                  title: context.t(LocaleKeys.settingsProviderApi88VoiceModels),
                  models: 'Gemini TTS · Grok TTS',
                ),
              ),
              divider,
              Wrap(
                spacing: RevericSpacing.lg,
                runSpacing: RevericSpacing.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  RevericButton.primary(
                    label: context.t(LocaleKeys.settingsProviderApi88Link),
                    icon: RevericIcons.arrow_square_out,
                    onPressed: () => openProviderChannelUrl(
                      context,
                      providerChannelUrls['api88']!,
                    ),
                  ),
                  RevericButton.text(
                    label: context.t(
                      LocaleKeys.settingsProviderApi88PricingLink,
                    ),
                    onPressed: () =>
                        openProviderChannelUrl(context, _pricingUrl),
                  ),
                ],
              ),
              const SizedBox(height: RevericSpacing.lg),
              Text(
                context.t(LocaleKeys.settingsProviderApi88PricingNote),
                style: typo.uiTiny.copyWith(color: colors.textMuted),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 宽屏左右并排，窄屏上下堆叠。
  Widget _pair({
    required bool wide,
    required Widget first,
    required Widget second,
  }) {
    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          first,
          const SizedBox(height: RevericSpacing.x3l),
          second,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: first),
        const SizedBox(width: RevericSpacing.x4l),
        Expanded(child: second),
      ],
    );
  }
}

class _ModelPrice extends StatelessWidget {
  const _ModelPrice({
    required this.wide,
    required this.name,
    required this.description,
    required this.price,
    required this.unit,
    this.badge,
  });

  final bool wide;
  final String name;
  final String description;
  final String price;
  final String unit;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final badge = this.badge;
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                name,
                style: typo.uiSemibold.copyWith(color: colors.textPrimary),
              ),
            ),
            if (badge != null) ...[
              const SizedBox(width: RevericSpacing.sm),
              RevericBadge(label: badge, color: colors.success),
            ],
          ],
        ),
        const SizedBox(height: RevericSpacing.xxs),
        Text(
          description,
          style: typo.uiTiny.copyWith(color: colors.textSecondary),
        ),
      ],
    );
    final figure = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(price, style: typo.heading2.copyWith(color: colors.textPrimary)),
        const SizedBox(width: RevericSpacing.xs),
        Flexible(
          child: Text(
            unit,
            style: typo.uiTiny.copyWith(color: colors.textMuted),
          ),
        ),
      ],
    );
    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          details,
          const SizedBox(height: RevericSpacing.sm),
          figure,
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: details),
        const SizedBox(width: RevericSpacing.x3l),
        figure,
      ],
    );
  }
}

class _Capability extends StatelessWidget {
  const _Capability({
    required this.icon,
    required this.title,
    required this.models,
  });

  final String icon;
  final String title;
  final String models;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RevericIcon(icon, size: 18, color: colors.textSecondary),
        const SizedBox(width: RevericSpacing.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: typo.uiSmallSemibold.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: RevericSpacing.xxs),
              Text(
                models,
                style: typo.uiTiny.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// 职责: 展示秘塔科技 MiniMax H3 的介绍卡片、价格要点和渠道入口。
// 关联文件:
//   lib/shared/widgets/settings/providers/registry.dart
//   lib/shared/widgets/settings/provider_overview.dart
//   lib/shared/models/provider_brand.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/provider.json
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

// 标准通道 15 秒及以内的单价（元/秒），以秘塔官网为准。
const _hdPrice = '0.09';
const _twoKPrice = '0.15';

const metasoShowcase = ProviderShowcase(
  card: _buildCard,
  listTagline: _listTagline,
);

Widget _buildCard(BuildContext context) => const _MetasoCard();

String _listTagline(BuildContext context) => context.t(
  LocaleKeys.providerMetasoListTagline,
  namedArgs: {'price': _hdPrice},
);

class _MetasoCard extends StatelessWidget {
  const _MetasoCard();

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
          final wide = constraints.maxWidth >= 380;
          // 按钮与说明并排需要更宽的空间，单独判断。
          final footerWide = constraints.maxWidth >= 520;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.t(LocaleKeys.providerMetasoCategory),
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
              _pair(
                wide: wide,
                flexible: false,
                first: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.t(LocaleKeys.providerMetasoTagline),
                      style: typo.uiSmall.copyWith(color: colors.textSecondary),
                    ),
                    const SizedBox(height: RevericSpacing.xs),
                    Text.rich(
                      TextSpan(
                        text: 'MiniMax',
                        children: [
                          TextSpan(
                            text: ' H3',
                            style: typo.display.copyWith(
                              color: colors.textMuted,
                            ),
                          ),
                        ],
                      ),
                      style: typo.display.copyWith(color: colors.textPrimary),
                    ),
                    const SizedBox(height: RevericSpacing.sm),
                    Text(
                      context.t(LocaleKeys.providerMetasoSummary),
                      style: typo.uiSmall.copyWith(color: colors.textSecondary),
                    ),
                  ],
                ),
                second: Column(
                  crossAxisAlignment: wide
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      context.t(LocaleKeys.providerMetasoMaxDuration),
                      style: typo.uiTiny.copyWith(color: colors.textMuted),
                    ),
                    const SizedBox(height: RevericSpacing.xxs),
                    _Figure(
                      value: '30',
                      unit: context.t(LocaleKeys.providerMetasoSeconds),
                    ),
                    const SizedBox(height: RevericSpacing.xxs),
                    Text(
                      '480P / 768P',
                      style: typo.uiTiny.copyWith(color: colors.textMuted),
                    ),
                  ],
                ),
              ),
              divider,
              _pair(
                wide: wide,
                first: _Price(
                  resolution: '768P',
                  label: context.t(LocaleKeys.providerMetasoHd),
                  price: _hdPrice,
                ),
                second: _Price(
                  resolution: '2K',
                  label: context.t(LocaleKeys.providerMetasoNative2k),
                  price: _twoKPrice,
                ),
              ),
              divider,
              _pair(
                wide: wide,
                divided: false,
                first: _Feature(
                  icon: RevericIcons.film_slate,
                  title: context.t(LocaleKeys.providerMetasoResolutionTitle),
                  description: context.t(
                    LocaleKeys.providerMetasoResolutionDescription,
                  ),
                ),
                second: _Feature(
                  icon: RevericIcons.waveform,
                  title: context.t(LocaleKeys.providerMetasoAudioTitle),
                  description: context.t(
                    LocaleKeys.providerMetasoAudioDescription,
                  ),
                ),
              ),
              divider,
              Flex(
                direction: footerWide ? Axis.horizontal : Axis.vertical,
                crossAxisAlignment: footerWide
                    ? CrossAxisAlignment.center
                    : CrossAxisAlignment.stretch,
                children: [
                  _flexible(
                    wide: footerWide,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: RevericSpacing.lg,
                          runSpacing: RevericSpacing.xxs,
                          children: [
                            for (final label in [
                              context.t(
                                LocaleKeys.providerMetasoOpenaiCompatible,
                              ),
                              'ComfyUI',
                              context.t(LocaleKeys.providerMetasoCanvas),
                            ])
                              Text(
                                label,
                                style: typo.uiSmallSemibold.copyWith(
                                  color: colors.textPrimary,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: RevericSpacing.xxs),
                        Text(
                          context.t(LocaleKeys.providerMetasoNoGpu),
                          style: typo.uiTiny.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(
                    width: RevericSpacing.x4l,
                    height: RevericSpacing.lg,
                  ),
                  RevericButton.primary(
                    label: context.t(LocaleKeys.providerMetasoLink),
                    icon: RevericIcons.arrow_square_out,
                    onPressed: () => openProviderChannelUrl(
                      context,
                      providerChannelUrls['metaso']!,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: RevericSpacing.x3l),
              Text(
                context.t(LocaleKeys.providerMetasoPricingNote),
                style: typo.uiTiny.copyWith(color: colors.textMuted),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 宽屏左右并排（可选竖分隔线），窄屏上下堆叠。
  Widget _pair({
    required bool wide,
    required Widget first,
    required Widget second,
    bool divided = true,
    bool flexible = true,
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
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: first),
          if (divided)
            Builder(
              builder: (context) => VerticalDivider(
                width: RevericSpacing.x6l,
                thickness: RevericSizes.dividerThickness,
                color: RevericTheme.colorsOf(context).borderSubtle,
              ),
            )
          else
            const SizedBox(width: RevericSpacing.x4l),
          if (flexible) Expanded(child: second) else second,
        ],
      ),
    );
  }

  Widget _flexible({required bool wide, required Widget child}) =>
      wide ? Expanded(child: child) : child;
}

class _Figure extends StatelessWidget {
  const _Figure({required this.value, required this.unit});
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(value, style: typo.display.copyWith(color: colors.textPrimary)),
        const SizedBox(width: RevericSpacing.xs),
        Flexible(
          child: Text(
            unit,
            style: typo.uiSmall.copyWith(color: colors.textSecondary),
          ),
        ),
      ],
    );
  }
}

class _Price extends StatelessWidget {
  const _Price({
    required this.resolution,
    required this.label,
    required this.price,
  });
  final String resolution;
  final String label;
  final String price;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              resolution,
              style: typo.uiSmallSemibold.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(width: RevericSpacing.sm),
            Flexible(
              child: Text(
                label,
                style: typo.uiTiny.copyWith(color: colors.textMuted),
              ),
            ),
          ],
        ),
        const SizedBox(height: RevericSpacing.sm),
        _Figure(
          value: price,
          unit: context.t(LocaleKeys.providerMetasoPriceUnit),
        ),
      ],
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature({
    required this.icon,
    required this.title,
    required this.description,
  });
  final String icon;
  final String title;
  final String description;

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
                description,
                style: typo.uiTiny.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

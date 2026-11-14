// 职责: 展示 91Token 的多模态模型能力、接入指引与渠道入口。
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

const token91Showcase = ProviderShowcase(
  card: _buildCard,
  listTagline: _listTagline,
);

Widget _buildCard(BuildContext context) => const _Token91Card();

String _listTagline(BuildContext context) =>
    context.t(LocaleKeys.providerToken91ListTagline);

class _Token91Card extends StatelessWidget {
  const _Token91Card();

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
                      context.t(LocaleKeys.providerToken91Category),
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
                context.t(LocaleKeys.providerToken91Title),
                style: typo.heading2.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: RevericSpacing.sm),
              Text(
                context.t(LocaleKeys.providerToken91Summary),
                style: typo.uiSmall.copyWith(color: colors.textSecondary),
              ),
              divider,
              _pair(
                wide: wide,
                first: _Capability(
                  icon: RevericIcons.pencil_simple,
                  title: context.t(LocaleKeys.providerToken91ChatModels),
                  models: 'GPT · Claude · Gemini · DeepSeek',
                ),
                second: _Capability(
                  icon: RevericIcons.image,
                  title: context.t(LocaleKeys.providerToken91ImageModels),
                  models: 'Nano Banana · GPT Image · Seedream · Midjourney',
                ),
              ),
              const SizedBox(height: RevericSpacing.x3l),
              _pair(
                wide: wide,
                first: _Capability(
                  icon: RevericIcons.film_slate,
                  title: context.t(LocaleKeys.providerToken91VideoModels),
                  models: context.t(LocaleKeys.providerToken91VideoModelsList),
                ),
                second: _Capability(
                  icon: RevericIcons.microphone,
                  title: context.t(LocaleKeys.providerToken91VoiceModels),
                  models: 'Gemini TTS · OpenAI TTS',
                ),
              ),
              divider,
              Text(
                context.t(LocaleKeys.providerToken91SetupTitle),
                style: typo.uiSemibold.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: RevericSpacing.sm),
              Text(
                context.t(LocaleKeys.providerToken91Setup),
                style: typo.uiSmall.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: RevericSpacing.x3l),
              Wrap(
                spacing: RevericSpacing.lg,
                runSpacing: RevericSpacing.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  RevericButton.primary(
                    label: context.t(LocaleKeys.providerToken91Link),
                    icon: RevericIcons.arrow_square_out,
                    onPressed: () => openProviderChannelUrl(
                      context,
                      providerChannelUrls['token91']!,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: RevericSpacing.lg),
              Text(
                context.t(LocaleKeys.providerToken91Note),
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

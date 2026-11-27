// 职责: 展示供应商渠道入口，处理链接打开反馈和匿名点击上报。
// 关联文件:
//   lib/shared/models/provider_brand.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/widgets/settings/providers/registry.dart
//   lib/shared/providers/anonymous_reporting_providers.dart
//   lib/shared/services/app_activity_reporter.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/zh-CN/provider.json
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../components/dialog_feedback.dart';
import '../../components/reveric_button.dart';
import '../../localization/ai_provider_localization.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../logger/app_logger.dart';
import '../../models/ai_provider.dart';
import '../../models/provider_brand.dart';
import '../../providers/anonymous_reporting_providers.dart';
import '../../services/app_activity_reporter.dart';
import '../../theme/theme.dart';
import 'providers/registry.dart';

final _log = AppLogger.forModule('ProviderConfig');

/// 已支持类型的模型能力摘要；不支持的类型由列表中的徽标说明，不再重复。
String providerCapabilitySummary(BuildContext context, AiProvider config) =>
    config.supportedModelKinds
        .map(
          (kind) => context.t(switch (kind) {
            AiModelKind.chat => LocaleKeys.providerChatModelsLabel,
            AiModelKind.image => LocaleKeys.providerImageModelsLabel,
            AiModelKind.video => LocaleKeys.providerVideoModelsLabel,
            AiModelKind.audio => LocaleKeys.providerAudioModelsLabel,
            AiModelKind.asr => LocaleKeys.providerTranscription,
          }),
        )
        .join(' · ');

class ProviderOverview extends StatelessWidget {
  const ProviderOverview({
    super.key,
    required this.config,
    this.showCapabilities = true,
  });
  final AiProvider config;
  final bool showCapabilities;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final showcase = providerShowcases[config.type];
    if (showcase != null) {
      return showcase.card(context);
    }
    final url = providerChannelUrls[config.type];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showCapabilities) ...[
          Text(
            providerCapabilitySummary(context, config),
            style: typo.uiSemibold.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: RevericSpacing.sm),
        ],
        Text(
          localizedProviderTypeDescription(context, config.typeEnum),
          style: typo.ui.copyWith(color: colors.textSecondary),
        ),
        if (url != null) ...[
          const SizedBox(height: RevericSpacing.lg),
          RevericButton.secondary(
            label: context.t(LocaleKeys.settingsAiGetApiKey),
            onPressed: () =>
                openProviderChannelUrl(context, url, providerType: config.type),
          ),
        ],
        const SizedBox(height: RevericSpacing.lg),
        Divider(
          height: RevericSizes.dividerThickness,
          color: colors.borderSubtle,
        ),
      ],
    );
  }
}

Future<void> openProviderChannelUrl(
  BuildContext context,
  String url, {
  required String providerType,
}) async {
  unawaited(_reportChannelClick(context, providerType));
  try {
    if (await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) {
      return;
    }
    _log.warning('URL launch returned false: $url');
  } catch (error, stackTrace) {
    _log.error(
      'Failed to open API key page: $url',
      error: error,
      stackTrace: stackTrace,
    );
  }
  if (!context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: DialogToast(
        variant: DialogToastVariant.error,
        child: Text(context.t(LocaleKeys.settingsAiOpenApiKeyFailed)),
      ),
    ),
  );
}

Future<void> _reportChannelClick(
  BuildContext context,
  String providerType,
) async {
  final occurredAt = DateTime.now();
  try {
    final container = ProviderScope.containerOf(context, listen: false);
    final consent = await container.read(
      anonymousReportingConsentProvider.future,
    );
    if (!consent) {
      return;
    }
    await reportProviderLinkClick(
      outbox: container.read(anonymousOutboxServiceProvider),
      providerType: providerType,
      occurredAt: occurredAt,
    );
  } catch (error, stackTrace) {
    _log.error(
      'Failed to queue provider link click: $providerType',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

// 职责: 共享通用设置区 — 语言、网络代理与匿名诊断上报同意。
// 关联文件:
//   lib/shared/widgets/settings/settings_section_widgets.dart
//   lib/shared/widgets/settings/proxy_settings_section.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/providers/anonymous_reporting_providers.dart
//   lib/shared/app_config.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../app_config.dart';
import '../../components/reveric_segmented_control.dart';
import '../../components/reveric_switch.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../providers/anonymous_reporting_providers.dart';
import '../../providers/settings_providers.dart';
import '../../theme/theme.dart';
import 'proxy_settings_section.dart';
import 'settings_section_widgets.dart';

/// 通用设置 section（语言、网络代理、匿名诊断上报）。
class GeneralSettingsSection extends StatelessWidget {
  const GeneralSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(RevericSpacing.x4l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _LanguageSection(),
          const SizedBox(height: RevericSpacing.x4l),
          const ProxySettingsSection(),
          // 本构建未配置上报地址时同意无效，不展示入口。
          if (anonymousReportingBaseUrl.isNotEmpty) ...[
            const SizedBox(height: RevericSpacing.x4l),
            const _PrivacySection(),
          ],
        ],
      ),
    );
  }
}

class _LanguageSection extends ConsumerWidget {
  const _LanguageSection();

  static const _zhCN = Locale('zh', 'CN');
  static const _en = Locale('en');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentLocale = context.locale;

    Future<void> updateLocale(Locale nextLocale) async {
      if (currentLocale == nextLocale) {
        return;
      }
      final settingsNotifier = ref.read(appSettingsProvider.notifier);
      await context.setLocale(nextLocale);
      await settingsNotifier.setLanguage(
        nextLocale.toLanguageTag().replaceAll('-', '_'),
      );
    }

    return SettingsSection(
      titleKey: LocaleKeys.settingsLanguageSection,
      descriptionKey: LocaleKeys.settingsLanguageDescription,
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: RevericSegmentedControl<Locale>(
            selected: currentLocale == _zhCN ? _zhCN : _en,
            onChanged: updateLocale,
            segments: [
              RevericSegment(
                value: _zhCN,
                label: context.t(LocaleKeys.settingsChineseSimplified),
              ),
              RevericSegment(
                value: _en,
                label: context.t(LocaleKeys.settingsEnglish),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrivacySection extends ConsumerWidget {
  const _PrivacySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    // 加载完成前禁用开关，避免覆盖尚未读取的本机设置。
    final consent = ref.watch(anonymousReportingConsentProvider).value;
    final setConsent = consent == null
        ? null
        : ref.read(anonymousReportingConsentProvider.notifier).set;
    return SettingsSection(
      titleKey: LocaleKeys.settingsPrivacySection,
      child: SettingsCard(
        padding: EdgeInsets.zero,
        children: [
          MergeSemantics(
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: consent == null || setConsent == null
                    ? null
                    : () => setConsent(!consent),
                hoverColor: colors.hover,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.lg,
                    vertical: RevericSpacing.x2l,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.t(LocaleKeys.settingsAnonymousReporting),
                              style: typo.uiSemibold.copyWith(
                                color: colors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: RevericSpacing.xxs),
                            Text(
                              context.t(
                                LocaleKeys.settingsAnonymousReportingDescription,
                              ),
                              style: typo.uiSmall.copyWith(
                                color: colors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: RevericSpacing.lg),
                      RevericSwitch(
                        value: consent ?? true,
                        onChanged: setConsent,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

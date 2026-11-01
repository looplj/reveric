// 职责: 展示共享调试操作与更新提示验证。
// 关联文件:
//   lib/shared/providers/update_providers.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/providers/device_id_providers.dart
//   lib/shared/services/app_initialization.dart
//   lib/shared/services/debug/sqlite_schema_repair_orchestrator.dart
//   lib/shared/logger/app_logger.dart
//   lib/shared/localization/locale_keys.dart
//   lib/shared/theme/theme.dart
//   assets/translations/en/settings.json
//   assets/translations/en/plugin.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/zh-CN/plugin.json
//   lib/shared/widgets/a2ui/preview/preview_panel.dart
//   assets/translations/en/a2ui.json
//   assets/translations/zh-CN/a2ui.json
// 遵循的 Rules:
//   .agents/rules/directory-structure.md
//   .agents/rules/hooks.md
//   .agents/rules/i18n.md
//   .agents/rules/design-system.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../components/dialog_feedback.dart';
import '../../components/reveric_switch.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../logger/app_logger.dart';
import '../../providers/device_id_providers.dart';
import '../../providers/novel_providers.dart';
import '../../providers/settings_providers.dart';
import '../../providers/update_providers.dart';
import '../../services/app_initialization.dart';
import '../../services/debug/sqlite_schema_repair_orchestrator.dart';
import '../../theme/theme.dart';
import '../a2ui/preview/preview_panel.dart';
import '../plugin_view/preview.dart';
import '../../components/reveric_button.dart';

final _log = AppLogger.forModule('Settings Debug');

/// 调试设置 section。
class DebugSettingsSection extends HookConsumerWidget {
  const DebugSettingsSection({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final debugMode = ref.watch(appDebugModeProvider);
    final notifier = ref.read(appSettingsProvider.notifier);
    final isRepairingSchema = useState(false);
    final isRefreshingDeviceId = useState(false);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(RevericSpacing.x4l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  context.t(LocaleKeys.settingsDebug),
                  style: typo.heading2.copyWith(color: colors.textPrimary),
                ),
              ),
              const SizedBox(width: RevericSpacing.lg),
              TextButton.icon(
                onPressed: () async {
                  await notifier.setDebugMode(false);
                  await notifier.setDebugPageUnlocked(false);
                  onClose();
                },
                icon: RevericIcon(
                  RevericIcons.close,
                  size: 16,
                  color: colors.textSecondary,
                ),
                label: Text(context.t(LocaleKeys.settingsDebugCloseSection)),
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.md),
          Text(
            context.t(LocaleKeys.settingsDebugDescription),
            style: typo.ui.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: RevericSpacing.x2l),
          _DebugToggleCard(
            title: context.t(LocaleKeys.settingsDebugMode),
            description: context.t(LocaleKeys.settingsDebugModeDescription),
            value: debugMode,
            onChanged: notifier.setDebugMode,
            colors: colors,
            typo: typo,
          ),
          const SizedBox(height: RevericSpacing.xl),
          _DebugActionCard(
            title: context.t(LocaleKeys.settingsDebugResetOnboarding),
            description: context.t(
              LocaleKeys.settingsDebugResetOnboardingDescription,
            ),
            action: _DebugActionButton(
              label: context.t(LocaleKeys.settingsDebugResetOnboardingButton),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final successMessage = context.t(
                  LocaleKeys.settingsDebugResetOnboardingSuccess,
                );
                final failedMessage = context.t(
                  LocaleKeys.settingsDebugResetOnboardingFailed,
                );
                final database = ref.read(appDatabaseProvider);
                try {
                  await clearOnboardingAndFeatureUsageRecords(database);
                  messenger.showSnackBar(
                    SnackBar(
                      content: DialogToast(
                        variant: DialogToastVariant.success,
                        child: Text(successMessage),
                      ),
                    ),
                  );
                } catch (_) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: DialogToast(
                        variant: DialogToastVariant.error,
                        child: Text(failedMessage),
                      ),
                    ),
                  );
                }
              },
              colors: colors,
              typo: typo,
            ),
            colors: colors,
            typo: typo,
          ),
          const SizedBox(height: RevericSpacing.xl),
          _DebugActionCard(
            title: context.t(LocaleKeys.settingsDebugTriggerUpdateReminder),
            description: context.t(
              LocaleKeys.settingsDebugTriggerUpdateReminderDescription,
            ),
            action: _DebugActionButton(
              label: context.t(LocaleKeys.settingsDebugTriggerUpdateReminder),
              onPressed: () async {
                final reminder = ref.read(
                  updateReminderPreviewProvider.notifier,
                );
                final route = ModalRoute.of(context)!;
                Navigator.of(context).pop();
                // 等设置路由退出完成，复用全局实际提示和查看更新的导航。
                await route.completed;
                reminder.show();
              },
              colors: colors,
              typo: typo,
            ),
            colors: colors,
            typo: typo,
          ),
          const SizedBox(height: RevericSpacing.xl),
          _DebugActionCard(
            title: context.t(LocaleKeys.settingsDebugRefreshDeviceId),
            description: context.t(
              LocaleKeys.settingsDebugRefreshDeviceIdDescription,
            ),
            action: _DebugActionButton(
              label: context.t(
                isRefreshingDeviceId.value
                    ? LocaleKeys.settingsDebugRefreshDeviceIdRunning
                    : LocaleKeys.settingsDebugRefreshDeviceIdButton,
              ),
              onPressed: isRefreshingDeviceId.value
                  ? null
                  : () async {
                      isRefreshingDeviceId.value = true;
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        await ref.read(deviceIdServiceProvider).regenerate();
                        if (!context.mounted) {
                          return;
                        }
                        messenger.showSnackBar(
                          SnackBar(
                            content: DialogToast(
                              variant: DialogToastVariant.success,
                              child: Text(
                                context.t(
                                  LocaleKeys
                                      .settingsDebugRefreshDeviceIdSuccess,
                                ),
                              ),
                            ),
                          ),
                        );
                      } catch (error, stackTrace) {
                        _log.error(
                          'device ID regeneration failed',
                          error: error,
                          stackTrace: stackTrace,
                        );
                        if (!context.mounted) {
                          return;
                        }
                        messenger.showSnackBar(
                          SnackBar(
                            content: DialogToast(
                              variant: DialogToastVariant.error,
                              child: Text(
                                context.t(
                                  LocaleKeys.settingsDebugRefreshDeviceIdFailed,
                                ),
                              ),
                            ),
                          ),
                        );
                      } finally {
                        if (context.mounted) {
                          isRefreshingDeviceId.value = false;
                        }
                      }
                    },
              colors: colors,
              typo: typo,
            ),
            colors: colors,
            typo: typo,
          ),
          const SizedBox(height: RevericSpacing.xl),
          _DebugActionCard(
            title: context.t(LocaleKeys.settingsDebugRepairSqliteSchema),
            description: context.t(
              LocaleKeys.settingsDebugRepairSqliteSchemaDescription,
            ),
            action: _DebugActionButton(
              label: context.t(
                isRepairingSchema.value
                    ? LocaleKeys.settingsDebugRepairSqliteSchemaRunning
                    : LocaleKeys.settingsDebugRepairSqliteSchemaButton,
              ),
              onPressed: isRepairingSchema.value
                  ? null
                  : () async {
                      isRepairingSchema.value = true;
                      final messenger = ScaffoldMessenger.of(context);
                      final result = await SqliteSchemaRepairOrchestrator()
                          .repair();
                      if (!context.mounted) {
                        return;
                      }
                      messenger.showSnackBar(
                        SnackBar(
                          content: DialogToast(
                            variant: DialogToastVariant.error,
                            child: Text(
                              context.t(
                                result.success
                                    ? LocaleKeys
                                          .settingsDebugRepairSqliteSchemaSuccess
                                    : LocaleKeys
                                          .settingsDebugRepairSqliteSchemaFailed,
                              ),
                            ),
                          ),
                        ),
                      );
                      isRepairingSchema.value = false;
                    },
              colors: colors,
              typo: typo,
            ),
            colors: colors,
            typo: typo,
          ),
          const SizedBox(height: RevericSpacing.xl),
          _DebugActionCard(
            title: context.t(LocaleKeys.a2uiPreviewTitle),
            description: context.t(LocaleKeys.a2uiPreviewDescription),
            action: _DebugActionButton(
              label: context.t(LocaleKeys.a2uiPreviewOpen),
              onPressed: () => showA2uiPreview(context),
              colors: colors,
              typo: typo,
            ),
            colors: colors,
            typo: typo,
          ),
          const SizedBox(height: RevericSpacing.xl),
          _DebugActionCard(
            title: context.t(LocaleKeys.pluginPreviewTitle),
            description: context.t(LocaleKeys.pluginPreviewDescription),
            action: RevericButton.secondary(
              label: context.t(LocaleKeys.commonOpen),
              onPressed: () => showPluginUiPreview(context),
            ),
            colors: colors,
            typo: typo,
          ),
          const SizedBox(height: RevericSpacing.lg),
        ],
      ),
    );
  }
}

class _DebugToggleCard extends StatelessWidget {
  const _DebugToggleCard({
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
    required this.colors,
    required this.typo,
  });

  final String title;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(RevericSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surfaceDim,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: RevericSpacing.xxs),
                Text(
                  description,
                  style: typo.uiSmall.copyWith(color: colors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: RevericSpacing.lg),
          RevericSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _DebugActionCard extends StatelessWidget {
  const _DebugActionCard({
    required this.title,
    required this.description,
    required this.action,
    required this.colors,
    required this.typo,
  });

  final String title;
  final String description;
  final Widget action;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(RevericSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surfaceDim,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: RevericSpacing.xxs),
                Text(
                  description,
                  style: typo.uiSmall.copyWith(color: colors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: RevericSpacing.lg),
          action,
        ],
      ),
    );
  }
}

class _DebugActionButton extends StatelessWidget {
  const _DebugActionButton({
    required this.label,
    required this.onPressed,
    required this.colors,
    required this.typo,
  });

  final String label;
  final VoidCallback? onPressed;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: colors.accent.withValues(alpha: 0.1),
        foregroundColor: colors.accent,
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.md,
          vertical: RevericSpacing.md,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RevericRadius.button),
        ),
      ),
      child: Text(label, style: typo.ui.copyWith(color: colors.accent)),
    );
  }
}

// 职责: 展示插件待授权能力并确认授权或保留数据卸载。
// 关联文件:
//   lib/shared/widgets/settings/plugins/row.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import '../../../services/plugins/runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../components/reveric_button.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../logger/app_logger.dart';
import '../../../services/plugins/host.dart';
import '../../../theme/theme.dart';

final _log = AppLogger.forModule('PluginManage');

class PluginManagePanel extends HookWidget {
  const PluginManagePanel({
    super.key,
    required this.host,
    required this.status,
  });
  final PluginHostService host;
  final PluginStatus status;
  @override
  Widget build(BuildContext context) {
    final confirming = useState(false),
        busy = useState(false),
        failed = useState(false);
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    Future<void> run(Future<void> Function() action) async {
      busy.value = true;
      failed.value = false;
      try {
        await action();
      } catch (error, stack) {
        if (error is PluginHostError && error.code == 'cancelled') {
          return;
        }
        _log.error(
          'Plugin management failed: ${status.id}',
          error: error,
          stackTrace: stack,
        );
        if (context.mounted) {
          failed.value = true;
        }
      } finally {
        if (context.mounted) {
          busy.value = false;
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (status.state == 'needs_permission') ...[
          Text(
            context.t(LocaleKeys.settingsPluginsNewPermissions),
            style: typo.uiSemibold.copyWith(color: colors.textPrimary),
          ),
          for (final permission in status.manifest!.permissions)
            Text(
              permission == 'ai.generateText'
                  ? context.t(LocaleKeys.settingsPluginsAiPermission)
                  : permission,
              style: typo.ui.copyWith(color: colors.textSecondary),
            ),
          RevericButton.primary(
            label: context.t(LocaleKeys.commonConfirm),
            loading: busy.value,
            onPressed: busy.value
                ? null
                : () => run(() => host.confirmPermissions(status.id)),
          ),
        ],
        if (status.state != 'needs_permission' &&
            status.manifest?.permissions.isNotEmpty == true) ...[
          Text(
            context.t(LocaleKeys.settingsPluginsPermissions),
            style: typo.uiSemibold.copyWith(color: colors.textPrimary),
          ),
          for (final permission in status.manifest!.permissions)
            Text(
              permission == 'ai.generateText'
                  ? context.t(LocaleKeys.settingsPluginsAiPermission)
                  : permission,
              style: typo.ui.copyWith(color: colors.textSecondary),
            ),
          RevericButton.text(
            label: context.t(LocaleKeys.commonRevoke),
            loading: busy.value,
            onPressed: busy.value
                ? null
                : () => run(() => host.revokePermissions(status.id)),
          ),
        ],
        if (status.source == 'local') ...[
          if (confirming.value) ...[
            Text(
              context.t(LocaleKeys.settingsPluginsUninstallConfirm),
              style: typo.ui.copyWith(color: colors.textSecondary),
            ),
            Wrap(
              spacing: RevericSpacing.sm,
              children: [
                RevericButton.danger(
                  label: context.t(LocaleKeys.commonUninstall),
                  loading: busy.value,
                  onPressed: busy.value
                      ? null
                      : () => run(() => host.uninstall(status.id)),
                ),
                RevericButton.text(
                  label: context.t(LocaleKeys.commonCancel),
                  onPressed: busy.value ? null : () => confirming.value = false,
                ),
              ],
            ),
          ] else
            RevericButton.text(
              label: context.t(LocaleKeys.commonUninstall),
              onPressed: () => confirming.value = true,
            ),
        ],
        if (failed.value)
          Text(
            context.t(LocaleKeys.settingsPluginsSaveFailed),
            style: typo.uiSmall.copyWith(color: colors.warningText),
          ),
      ],
    );
  }
}

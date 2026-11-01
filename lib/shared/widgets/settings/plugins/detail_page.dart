// 职责: 已安装插件的详情子页面 — 组合身份、授权、配置、后台任务、工具与卸载分区。
// 关联文件:
//   lib/shared/widgets/settings/plugins/subpage.dart
//   lib/shared/widgets/settings/plugins/config_panel.dart
//   lib/shared/widgets/settings/plugins/tasks_panel.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/widgets/settings/leave_guard.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/en/plugin.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/zh-CN/plugin.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/widget-decomposition.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../components/reveric_badge.dart';
import '../../../components/reveric_button.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../logger/app_logger.dart';
import '../../../providers/plugin_providers.dart';
import '../../../providers/settings_providers.dart';
import '../../../services/plugins/runtime.dart';
import '../../../theme/theme.dart';
import '../../confirm_dialog.dart';
import '../../unsaved_changes_dialog.dart';
import '../leave_guard.dart';
import '../settings_section_widgets.dart';
import 'config_panel.dart';
import 'enable_switch.dart';
import 'overview.dart';
import 'permissions.dart';
import 'row.dart';
import 'status.dart';
import 'subpage.dart';
import 'tasks_panel.dart';
import 'tools_section.dart';

final _log = AppLogger.forModule('PluginManage');

class PluginDetailPage extends HookConsumerWidget {
  const PluginDetailPage({
    super.key,
    required this.pluginId,
    required this.mobile,
    required this.onClose,
  });

  final String pluginId;
  final bool mobile;

  /// 返回插件列表。
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statuses = ref.watch(pluginStatusesProvider).asData?.value;
    final status = statuses?.where((item) => item.id == pluginId).firstOrNull;
    final host = ref.watch(pluginHostServiceProvider);
    final busy = useState(false), failed = useState(false);
    final configDirty = useMemoized(() => ValueNotifier(false));
    useEffect(() => configDirty.dispose, [configDirty]);
    final leaveGuard = useRef<SettingsLeaveGuard?>(null);
    final colors = RevericTheme.colorsOf(context);
    final locale = Localizations.localeOf(context);

    // 移动端全屏页返回不做未保存拦截，只有桌面设置弹窗内需要询问。
    final leave = mobile ? null : SettingsLeaveScope.maybeOf(context);
    Future<bool> confirmLeave() async {
      if (busy.value) {
        return false;
      }
      if (!configDirty.value) {
        return true;
      }
      final decision = await showUnsavedChangesDialog(
        context: context,
        titleKey: LocaleKeys.commonDiscardChanges,
        messageKey: LocaleKeys.pluginUnsavedChangesMessage,
        // 保存按钮在配置表单内，离开前只能放弃或留下。
        showSave: false,
      );
      return decision == UnsavedChangesDecision.discard;
    }

    leaveGuard.value = confirmLeave;
    useEffect(() {
      if (leave == null) {
        return null;
      }
      Future<bool> guard() => leaveGuard.value!();
      leave.register(guard);
      return () => leave.unregister(guard);
    }, [leave]);
    Future<void> back() async {
      if (await confirmLeave()) {
        onClose();
      }
    }

    // 卸载或包被移除后详情不再有对象，回到列表。
    final missing = statuses != null && status == null;
    useEffect(() {
      if (missing) {
        WidgetsBinding.instance.addPostFrameCallback((_) => onClose());
      }
      return null;
    }, [missing]);
    if (status == null) {
      return PluginSubpage(
        title: context.t(LocaleKeys.settingsPlugins),
        mobile: mobile,
        onBack: onClose,
        children: const [LinearProgressIndicator()],
      );
    }

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

    Future<void> revoke() async {
      final confirmed = await showConfirmDialog(
        context,
        title: context.t(LocaleKeys.commonRevoke),
        message: context.t(LocaleKeys.pluginRevokeConfirm),
        confirmLabel: context.t(LocaleKeys.commonRevoke),
        variant: ConfirmDialogVariant.warning,
      );
      if (confirmed && context.mounted) {
        await run(() => host.revokePermissions(status.id));
      }
    }

    Future<void> uninstall() async {
      final confirmed = await showConfirmDialog(
        context,
        title: context.t(LocaleKeys.commonUninstall),
        message: context.t(LocaleKeys.pluginUninstallConfirm),
        confirmLabel: context.t(LocaleKeys.commonUninstall),
        variant: ConfirmDialogVariant.warning,
      );
      if (confirmed && context.mounted) {
        await run(() => host.uninstall(status.id));
      }
    }

    final manifest = status.manifest;
    final name = pluginDisplayName(status, locale);
    final (statusKey, statusColor) = pluginStatusBadge(status, colors);
    final unavailableModels = pluginUnavailableModelFields(
      status,
      ref.watch(aiSettingsProvider),
      locale,
    );
    final needsPermission = status.state == 'needs_permission';
    final tools = host.registry.toolsFor(status.id);
    final notices = [
      if (failed.value)
        PluginNotice(message: context.t(LocaleKeys.pluginSaveFailed)),
      if (status.state == 'failed')
        PluginNotice(message: context.t(pluginFailureKey(status.error))),
      if (needsPermission)
        PluginNotice(message: context.t(LocaleKeys.pluginPermissionRequired)),
      if (status.needsConfig)
        PluginNotice(message: context.t(LocaleKeys.pluginConfigRequired)),
      if (unavailableModels.isNotEmpty)
        PluginNotice(
          message: context.t(
            LocaleKeys.pluginModelUnavailable,
            namedArgs: {'fields': unavailableModels.join(', ')},
          ),
        ),
      if (status.promptDiagnostic case final diagnostic?)
        PluginNotice(
          message: context.t(
            LocaleKeys.pluginPromptSkipped,
            namedArgs: {'requestId': diagnostic.requestId},
          ),
        ),
    ];
    return PluginSubpage(
      title: name,
      mobile: mobile,
      onBack: back,
      children: [
        if (manifest == null)
          ...notices
        else
          PluginOverview(
            manifest: manifest,
            local: status.source == 'local',
            badge: RevericBadge(
              label: context.t(statusKey),
              color: statusColor,
            ),
            trailing: PluginEnableSwitch(
              status: status,
              semanticLabel: name,
              // 开关旁的提示已说明需要先填写配置。
              onNeedsConfig: () {},
              onSaveFailed: (value) => failed.value = value,
            ),
            notices: notices,
          ),
        if (manifest != null && manifest.permissions.isNotEmpty)
          SettingsSection(
            titleKey: LocaleKeys.pluginPermissions,
            trailing: needsPermission
                ? RevericButton.primary(
                    label: context.t(LocaleKeys.commonGrant),
                    size: RevericButtonSize.compact,
                    loading: busy.value,
                    onPressed: busy.value
                        ? null
                        : () => run(() => host.confirmPermissions(status.id)),
                  )
                : RevericButton.text(
                    label: context.t(LocaleKeys.commonRevoke),
                    size: RevericButtonSize.compact,
                    onPressed: busy.value ? null : revoke,
                  ),
            child: PluginPermissionList(permissions: manifest.permissions),
          ),
        if (manifest != null &&
            (manifest.settings.isNotEmpty || manifest.actions.isNotEmpty))
          SettingsSection(
            titleKey: LocaleKeys.pluginSettings,
            child: SettingsCard(
              padding: const EdgeInsets.all(RevericSpacing.lg),
              children: [
                PluginConfigPanel(
                  host: host,
                  manifest: manifest,
                  dirty: configDirty,
                ),
              ],
            ),
          ),
        if (manifest != null && manifest.tasks.isNotEmpty)
          PluginTasksPanel(host: host, pluginId: status.id),
        PluginToolsSection(
          tools: tools,
          emptyText: context.t(LocaleKeys.pluginNoTools),
          overriddenBy: (tool) {
            final owner = host.registry.resolve(tool.name);
            return owner == null || owner.pluginId == status.id
                ? null
                : owner.pluginName.resolve(locale);
          },
        ),
        if (status.source == 'local')
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: RevericButton.danger(
              label: context.t(LocaleKeys.commonUninstall),
              onPressed: busy.value ? null : uninstall,
            ),
          ),
      ],
    );
  }
}

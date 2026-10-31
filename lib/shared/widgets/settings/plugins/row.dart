// 职责: 展示单个插件的详情与配置入口，并持久化启停选择。
// 关联文件:
//   lib/shared/widgets/settings/plugins/section.dart
//   lib/shared/widgets/settings/plugins/config_panel.dart
//   lib/shared/providers/plugin_providers.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import '../../../services/plugins/runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../components/reveric_switch.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../logger/app_logger.dart';
import '../../../providers/plugin_providers.dart';
import '../../../services/plugins/host.dart';
import '../../../theme/theme.dart';
import 'config_panel.dart';
import 'manage_panel.dart';
import 'tasks_panel.dart';

final _log = AppLogger.forModule('Plugin');

String pluginFailureKey(String? failure) {
  final text = failure?.toLowerCase() ?? '';
  if (text.contains('unsupported plugin api')) {
    return LocaleKeys.settingsPluginsApiMismatch;
  }
  if (text.contains('conflict') ||
      text.contains('duplicate') ||
      text.contains('reserved')) {
    return LocaleKeys.settingsPluginsConflict;
  }
  if (text.contains('plugin_timeout') || text.contains('plugin_memory_limit')) {
    return LocaleKeys.settingsPluginsResourceLimit;
  }
  if (text.contains('format') ||
      text.contains('manifest') ||
      text.contains('entry') ||
      text.contains('schema')) {
    return LocaleKeys.settingsPluginsInvalid;
  }
  return LocaleKeys.settingsPluginsActivationFailed;
}

class PluginSettingsRow extends HookConsumerWidget {
  const PluginSettingsRow({super.key, required this.status});
  final PluginStatus status;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = useState(false),
        // 首次展开后保留详情，收起时不丢失未保存的配置输入。
        opened = useState(
          false,
        ),
        busy = useState(false),
        notice = useState<String?>(null);
    final host = ref.watch(pluginHostServiceProvider),
        manifest = status.manifest;
    final colors = RevericTheme.colorsOf(context),
        typo = RevericTheme.typographyOf(context);
    final locale = Localizations.localeOf(context);
    final name =
        manifest?.name.resolve(locale) ??
        status.path
            .split('/')
            .where((part) => part.isNotEmpty)
            .skip(2)
            .firstOrNull ??
        status.id;
    final statusKey = switch (status.state) {
      'disabled' when status.needsConfig =>
        LocaleKeys.settingsPluginsNeedsConfig,
      'needs_config' => LocaleKeys.settingsPluginsNeedsConfig,
      'needs_permission' => LocaleKeys.settingsPluginsNeedsPermission,
      'disabled' => LocaleKeys.settingsPluginsDisabled,
      'unsupported' => LocaleKeys.settingsPluginsUnsupported,
      'activating' => LocaleKeys.settingsPluginsActivating,
      'available' => LocaleKeys.settingsPluginsAvailable,
      _ => LocaleKeys.settingsPluginsFailed,
    };
    void setExpanded(bool value) {
      expanded.value = value;
      if (value) {
        opened.value = true;
      }
    }

    Future<void> toggle(bool value) async {
      if (busy.value) {
        return;
      }
      if (value && status.needsConfig) {
        setExpanded(true);
        notice.value = LocaleKeys.settingsPluginsConfigRequired;
        return;
      }
      busy.value = true;
      notice.value = null;
      try {
        await host.setEnabled(status.id, value);
      } catch (error, stack) {
        if (error is PluginHostError && error.code == 'cancelled') {
          return;
        }
        _log.error(
          'Enable preference failed: ${status.id}',
          error: error,
          stackTrace: stack,
        );
        if (context.mounted) {
          notice.value = LocaleKeys.settingsPluginsSaveFailed;
        }
      } finally {
        if (context.mounted) {
          busy.value = false;
        }
      }
    }

    final tools = host.registry.toolsFor(status.id);
    return Padding(
      padding: const EdgeInsets.all(RevericSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  key: ValueKey('plugin-details-${status.id}'),
                  onTap: () => setExpanded(!expanded.value),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: RevericSpacing.sm,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                style: typo.uiSemibold.copyWith(
                                  color: colors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: RevericSpacing.xxs),
                              Wrap(
                                spacing: RevericSpacing.sm,
                                runSpacing: RevericSpacing.xxs,
                                children: [
                                  if (manifest != null)
                                    Text(
                                      manifest.version,
                                      style: typo.uiSmall.copyWith(
                                        color: colors.textMuted,
                                      ),
                                    ),
                                  Text(
                                    context.t(
                                      status.source == 'bundled'
                                          ? LocaleKeys.settingsPluginsBundled
                                          : LocaleKeys.settingsPluginsLocal,
                                    ),
                                    style: typo.uiSmall.copyWith(
                                      color: colors.textMuted,
                                    ),
                                  ),
                                  Text(
                                    context.t(statusKey),
                                    style: typo.uiSmall.copyWith(
                                      color: status.state == 'failed'
                                          ? colors.warningText
                                          : colors.textMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        RevericIcon(
                          expanded.value
                              ? RevericIcons.expand_less_rounded
                              : RevericIcons.expand_more,
                          size: RevericSizes.buttonIconSize,
                          color: colors.textMuted,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Semantics(
                label: name,
                child: RevericSwitch(
                  key: ValueKey('plugin-toggle-${status.id}'),
                  value: status.enabled,
                  onChanged: busy.value || manifest == null ? null : toggle,
                ),
              ),
            ],
          ),
          if (status.promptDiagnostic case final diagnostic?)
            Text(
              context.t(
                LocaleKeys.settingsPluginsPromptSkipped,
                namedArgs: {'requestId': diagnostic.requestId},
              ),
              style: typo.uiSmall.copyWith(color: colors.warningText),
            ),
          // 配置已补齐后提示自动消失。
          if (notice.value case final key?
              when key != LocaleKeys.settingsPluginsConfigRequired ||
                  status.needsConfig)
            Text(
              context.t(key),
              style: typo.uiSmall.copyWith(color: colors.warningText),
            ),
          if (opened.value)
            Visibility(
              visible: expanded.value,
              maintainState: true,
              child: ExcludeFocus(
                excluding: !expanded.value,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: RevericSpacing.sm),
                    if (manifest?.description case final description?)
                      Text(
                        description.resolve(locale),
                        style: typo.ui.copyWith(color: colors.textSecondary),
                      ),
                    if (manifest?.author case final author?
                        when author.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: RevericSpacing.sm),
                        child: Text(
                          context.t(
                            LocaleKeys.settingsPluginsAuthor,
                            namedArgs: {'author': author},
                          ),
                          style: typo.uiSmall.copyWith(color: colors.textMuted),
                        ),
                      ),
                    if (status.state == 'failed')
                      Padding(
                        padding: const EdgeInsets.only(top: RevericSpacing.sm),
                        child: Text(
                          context.t(pluginFailureKey(status.error)),
                          style: typo.ui.copyWith(color: colors.warningText),
                        ),
                      ),
                    PluginManagePanel(host: host, status: status),
                    PluginTasksPanel(host: host, pluginId: status.id),
                    if (manifest != null && manifest.settings.isNotEmpty) ...[
                      const SizedBox(height: RevericSpacing.lg),
                      PluginConfigPanel(host: host, manifest: manifest),
                    ],
                    const SizedBox(height: RevericSpacing.lg),
                    Text(
                      context.t(LocaleKeys.settingsPluginsTools),
                      style: typo.uiSemibold.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: RevericSpacing.xxs),
                    if (tools.isEmpty)
                      Text(
                        context.t(LocaleKeys.settingsPluginsNoTools),
                        style: typo.uiSmall.copyWith(color: colors.textMuted),
                      ),
                    for (final tool in tools)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: RevericSpacing.xxs,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              host.registry.resolve(tool.name)?.pluginId ==
                                      status.id
                                  ? tool.name
                                  : '${tool.name} · ${context.t(LocaleKeys.settingsPluginsOverridden, namedArgs: {'plugin': (host.registry.resolve(tool.name)?.pluginName ?? tool.pluginName).resolve(locale)})}',
                              style: typo.uiSmall.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                            // 描述写给模型看，可能很长，只露出开头。
                            Text(
                              tool.toolDef.description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: typo.uiSmall.copyWith(
                                color: colors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// 职责: 在供应商设置中编辑插件实例字段并用当前草稿检查连接。
// 关联文件:
//   lib/shared/widgets/settings/provider_config_panel.dart
//   lib/shared/widgets/settings/plugins/config_form.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/provider.json
//   assets/translations/en/plugin.json
//   assets/translations/zh-CN/plugin.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/ai_provider.dart';
import '../../models/plugin/action.dart';
import '../../models/plugin/text.dart';
import '../../providers/plugin_providers.dart';
import '../../providers/settings_providers.dart';
import '../../services/plugins/runtime.dart';
import '../../services/plugins/config.dart';
import 'plugins/config_form.dart';
import 'plugin_provider_models.dart';
import '../../theme/theme.dart';

class PluginProviderFields extends HookConsumerWidget {
  const PluginProviderFields({
    super.key,
    required this.config,
    required this.isDraft,
    this.draftController,
  });
  final AiProvider config;
  final bool isDraft;
  final PluginConfigDraftController? draftController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(pluginStatusesProvider);
    final host = ref.watch(pluginHostServiceProvider);
    final manifest = host.providerManifest(config.pluginId!);
    final declaration = manifest?.provider;
    final future = useMemoized(
      () => isDraft || declaration == null
          ? null
          : host.loadProviderConfig(config),
      [host, config.id, manifest, isDraft],
    );
    final loaded = useFuture(future, preserveState: false);
    final committed = useMemoized(() => ValueNotifier<PluginConfig?>(null), [
      host,
      config.id,
      manifest,
      isDraft,
    ]);
    useEffect(() => committed.dispose, [committed]);
    final committedConfig = useValueListenable(committed);
    final saved = isDraft
        ? (values: <String, Object?>{}, savedSecrets: <String>{})
        : committedConfig ?? loaded.data;
    final accountLabel = useRef<String?>(null);
    final locale = Localizations.localeOf(context);
    final checkLabel = context.t(LocaleKeys.providerPluginCheckConnection);
    final canCheck = host.providerHasMethod(
      config.pluginId!,
      'checkConnection',
    );
    final actions = useMemoized(
      () => [
        if (canCheck && declaration != null)
          PluginAction(
            name: 'checkConnection',
            title: PluginText.plain(checkLabel),
            requires: declaration.fields
                .where((field) => field.required)
                .map((field) => field.key)
                .toList(),
          ),
        for (final action in declaration?.actions ?? const <PluginAction>[])
          PluginAction(
            name: 'provider_action_${action.name}',
            title: action.title,
            requires: action.requires,
          ),
      ],
      [declaration, canCheck, checkLabel],
    );
    if (declaration == null) {
      return Text(context.t(LocaleKeys.providerPluginUnavailable));
    }
    if (loaded.hasError) {
      return Text(context.t(LocaleKeys.commonLoadFailed));
    }
    if (saved == null) {
      return const LinearProgressIndicator();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!config.isTypeSupported)
          Text(context.t(LocaleKeys.providerPluginUnavailable)),
        PluginConfigForm(
          key: ValueKey(config.id),
          fields: declaration.fields,
          draftController: isDraft ? draftController : null,
          values: saved.values,
          savedSecrets: saved.savedSecrets,
          requiredSecretClearHint: context.t(
            LocaleKeys.providerPluginSecretClearHint,
          ),
          onSave: (submission) async {
            await ref
                .read(appSettingsProvider.notifier)
                .savePluginProviderConfiguration(
                  config.id,
                  settings: submission.settings,
                  secrets: submission.secrets,
                );
            final latest = await host.loadProviderConfig(config);
            if (context.mounted) {
              committed.value = latest;
            }
          },
          actions: actions,
          actionSuccessText: (_) => accountLabel.value,
          onAction: (name, submission) async {
            accountLabel.value = null;
            try {
              final method = name == 'checkConnection'
                  ? name
                  : 'actions.${name.substring('provider_action_'.length)}';
              final result = await host.callProvider(
                config,
                method,
                draftSettings: submission.settings,
                draftSecrets: submission.secrets,
              );
              if (name.startsWith('provider_action_')) {
                final value = result as Map<String, dynamic>;
                accountLabel.value = parseOptionalPluginText(
                  value['text'],
                  'provider action text',
                )?.resolve(locale);
                return (
                  ok: value['ok'] == true,
                  code: value['code'] as String?,
                );
              }
              if (result is Map && result['accountLabel'] is String) {
                final label = (result['accountLabel'] as String).trim();
                accountLabel.value = label.isEmpty ? null : label;
              }
              return (ok: true, code: null);
            } catch (error) {
              return (
                ok: false,
                code: switch (error) {
                  PluginHostError() => error.code,
                  PluginExecutionError() => error.code,
                  _ => 'plugin_error',
                },
              );
            }
          },
        ),
        if (!isDraft) ...[
          const SizedBox(height: RevericSpacing.lg),
          PluginProviderModelsSection(config: config),
        ],
      ],
    );
  }
}

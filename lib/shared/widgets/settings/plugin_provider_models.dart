// 职责: 在供应商设置中按媒体类型获取、勾选并原子保存插件模型声明。
// 关联文件:
//   lib/shared/widgets/settings/provider_config_panel.dart
//   lib/shared/widgets/settings/plugin_provider_fields.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/provider.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/plugin.json
//   assets/translations/zh-CN/plugin.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../mobile/widgets/sheet.dart';
import '../../components/reveric_button.dart';
import '../../components/reveric_dialog.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/ai_provider.dart';
import '../../models/plugin/provider_registry.dart';
import '../../providers/plugin_providers.dart';
import '../../providers/settings_providers.dart';
import '../../services/plugins/provider_models.dart';
import '../../theme/theme.dart';
import 'provider_config_panel.dart';
import 'provider_models_editor.dart';

class PluginProviderModelsSection extends HookConsumerWidget {
  const PluginProviderModelsSection({super.key, required this.config});
  final AiProvider config;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(pluginProviderModelsRevisionProvider);
    ref.watch(pluginStatusesProvider);
    final host = ref.watch(pluginHostServiceProvider);
    final locale = Localizations.localeOf(context);
    final retrying = useState(false);
    final failure = pluginProviderModels.refreshErrorFor(config);
    final reason = failure == null
        ? null
        : context.t(
            switch (failure.code) {
              'authentication' ||
              'unauthorized' => LocaleKeys.pluginActionUnauthorized,
              'network' || 'unavailable' => LocaleKeys.pluginActionNetwork,
              'timeout' || 'plugin_timeout' => LocaleKeys.pluginActionTimeout,
              'configuration_required' => LocaleKeys.pluginNeedsConfig,
              'invalid_models' => LocaleKeys.providerPluginModelsInvalid,
              _ => LocaleKeys.pluginActionFailed,
            },
            namedArgs: failure.code == 'invalid_models'
                ? {
                    'details':
                        failure.detail ??
                        context.t(LocaleKeys.pluginActionFailed),
                  }
                : const {},
          );
    Future<void> retry() async {
      retrying.value = true;
      try {
        await host.refreshProviderModels(config);
      } catch (_) {
        // The observable instance error remains beside the retained model list.
      } finally {
        if (context.mounted) {
          retrying.value = false;
        }
      }
    }

    String savedModelLabel(AiModelKind kind, String id) {
      final model = pluginProviderModels.find(config, kind, id);
      return model?.name?.resolve(locale) ?? id;
    }

    Future<void> remove(AiModelKind kind, String id) async {
      try {
        await ref
            .read(appSettingsProvider.notifier)
            .removePluginProviderModel(config.id, kind, id);
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
          );
        }
      }
    }

    Future<void> choose(AiModelKind kind) async {
      PluginProviderDiscovery? discovery;
      final current = kind == AiModelKind.image
          ? config.imageModels
          : config.videoModels;
      Widget builder(BuildContext dialogContext) => ProviderModelsDialogContent(
        config: config,
        kind: kind,
        existingModels: current.toSet(),
        loadModels: () async {
          discovery = await host.discoverProviderModels(config);
          return {
            ...discovery!.models
                .where((model) => model.kind == kind)
                .map((model) => model.id),
            ...current,
          }.toList();
        },
        labelForModel: (id) {
          final model = discovery?.models
              .where((model) => model.kind == kind && model.id == id)
              .firstOrNull;
          return model == null
              ? '$id · ${context.t(LocaleKeys.providerPluginModelUnavailable)}'
              : model.name?.resolve(locale) ?? id;
        },
      );
      final selected = defaultTargetPlatform == TargetPlatform.android
          ? await showMobileSheet<Set<String>>(
              context: context,
              builder: builder,
            )
          : await showRevericDialog<Set<String>>(
              context: context,
              builder: builder,
            );
      if (selected == null || discovery == null || !context.mounted) {
        return;
      }
      try {
        await ref
            .read(appSettingsProvider.notifier)
            .selectPluginProviderModels(discovery!, {
              for (final id in selected) (kind, id),
              for (final id
                  in kind == AiModelKind.image
                      ? config.videoModels
                      : config.imageModels)
                (
                  kind == AiModelKind.image
                      ? AiModelKind.video
                      : AiModelKind.image,
                  id,
                ),
            });
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
          );
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (reason != null)
          Row(
            children: [
              Expanded(
                child: Text(
                  context.t(
                    LocaleKeys.pluginActionResult,
                    namedArgs: {
                      'action': context.t(LocaleKeys.providerFetchModels),
                      'result': reason,
                    },
                  ),
                ),
              ),
              RevericButton.text(
                label: context.t(LocaleKeys.commonRetry),
                loading: retrying.value,
                onPressed:
                    retrying.value ||
                        !host.providerHasMethod(config.pluginId!, 'listModels')
                    ? null
                    : retry,
              ),
            ],
          ),
        if (pluginProviderModels.errorFor(config) != null)
          Text(context.t(LocaleKeys.providerPluginModelsRefreshNeeded)),
        for (final kind in [AiModelKind.image, AiModelKind.video])
          if (config.supportsModelKind(kind) ||
              (kind == AiModelKind.image
                      ? config.imageModels
                      : config.videoModels)
                  .isNotEmpty) ...[
            ProviderModelsEditor(
              key: ValueKey((config.id, kind)),
              label: context.t(
                kind == AiModelKind.image
                    ? LocaleKeys.providerImageModelsLabel
                    : LocaleKeys.providerVideoModelsLabel,
              ),
              hint: context.t(LocaleKeys.providerModelIdHint),
              models: kind == AiModelKind.image
                  ? config.imageModels
                  : config.videoModels,
              allowManualAdd: false,
              labelForModel: (id) => savedModelLabel(kind, id),
              errorForModel: (id) =>
                  (!host.providerHasMethod(config.pluginId!, 'listModels') ||
                      pluginProviderModels.find(config, kind, id) == null)
                  ? context.t(LocaleKeys.providerPluginModelUnavailable)
                  : null,
              onChanged: (models) {
                final current = kind == AiModelKind.image
                    ? config.imageModels
                    : config.videoModels;
                for (final id in current.where((id) => !models.contains(id))) {
                  remove(kind, id);
                }
              },
              fetchButton: RevericButton.secondary(
                label: context.t(LocaleKeys.providerFetchModels),
                onPressed:
                    host.providerHasMethod(config.pluginId!, 'listModels')
                    ? () => choose(kind)
                    : null,
              ),
            ),
            const SizedBox(height: RevericSpacing.lg),
          ],
      ],
    );
  }
}

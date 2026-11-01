// 职责: 在插件详情中加载已保存配置与可选模型，并连接 A2UI 表单与宿主的保存、设置页操作入口。
// 关联文件:
//   lib/shared/widgets/settings/plugins/config_form.dart
//   lib/shared/widgets/settings/plugins/detail_page.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/models/plugin/manifest.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/plugin.json
//   assets/translations/zh-CN/plugin.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../logger/app_logger.dart';
import '../../../models/plugin/manifest.dart';
import '../../../models/plugin/setting_field.dart';
import '../../../providers/settings_providers.dart';
import '../../../services/plugins/config.dart';
import '../../../services/plugins/host.dart';
import '../../../theme/theme.dart';
import 'config_form.dart';
import 'config_surface.dart';

final _log = AppLogger.forModule('PluginConfig');

class PluginConfigPanel extends HookConsumerWidget {
  const PluginConfigPanel({
    super.key,
    required this.host,
    required this.manifest,
    this.dirty,
  });
  final PluginHostService host;
  final PluginManifest manifest;

  /// 有尚未保存的输入时为 true。
  final ValueNotifier<bool>? dirty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasModelField = manifest.settings.any(
      (field) => field.type == PluginSettingType.model,
    );
    final modelOptions = hasModelField
        ? [
            for (final option
                in ref.watch(aiSettingsProvider).availableModelOptions)
              (
                selection: (providerId: option.providerId, model: option.model),
                label:
                    '${option.providerDisplayName} · ${option.displayModelName}',
              ),
          ]
        : const <PluginConfigModelOption>[];
    final future = useMemoized(() async {
      try {
        return await host.loadConfig(manifest.id);
      } catch (error, stack) {
        _log.error(
          'Load plugin config failed: ${manifest.id}',
          error: error,
          stackTrace: stack,
        );
        rethrow;
      }
    }, [host, manifest]);
    final snapshot = useFuture<PluginConfig>(future);
    if (snapshot.hasError) {
      return Text(
        context.t(LocaleKeys.pluginLoadFailed),
        style: RevericTheme.typographyOf(
          context,
        ).ui.copyWith(color: RevericTheme.colorsOf(context).warningText),
      );
    }
    if (!snapshot.hasData) {
      return const LinearProgressIndicator();
    }
    final config = snapshot.requireData;
    return PluginConfigForm(
      fields: manifest.settings,
      values: config.values,
      savedSecrets: config.savedSecrets,
      onSave: (submission) => host.saveConfig(
        manifest.id,
        settings: submission.settings,
        secrets: submission.secrets,
      ),
      actions: manifest.actions,
      onAction: (name, submission) => host.runAction(
        manifest.id,
        name,
        settings: submission.settings,
        secrets: submission.secrets,
      ),
      modelOptions: modelOptions,
      dirty: dirty,
    );
  }
}

// 职责: 把插件运行状态、失败原因与模型配置可用性映射为界面文案和语义色。
// 关联文件:
//   lib/shared/widgets/settings/plugins/row.dart
//   lib/shared/widgets/settings/plugins/detail_page.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/plugin.json
//   assets/translations/zh-CN/plugin.json
import 'dart:ui';
import '../../../localization/locale_keys.dart';
import '../../../models/ai_provider.dart';
import '../../../services/plugins/host.dart';
import '../../../theme/theme.dart';

String pluginFailureKey(String? failure) {
  final text = failure?.toLowerCase() ?? '';
  if (text.contains('unsupported plugin api')) {
    return LocaleKeys.pluginApiMismatch;
  }
  if (text.contains('conflict') ||
      text.contains('duplicate') ||
      text.contains('reserved')) {
    return LocaleKeys.pluginConflict;
  }
  if (text.contains('plugin_timeout') || text.contains('plugin_memory_limit')) {
    return LocaleKeys.pluginResourceLimit;
  }
  if (text.contains('format') ||
      text.contains('manifest') ||
      text.contains('entry') ||
      text.contains('schema')) {
    return LocaleKeys.pluginInvalid;
  }
  return LocaleKeys.pluginActivationFailed;
}

/// 列表与详情共用的状态徽标文案和颜色。
(String, Color) pluginStatusBadge(PluginStatus status, RevericColors colors) =>
    switch (status.state) {
      'disabled' when status.needsConfig => (
        LocaleKeys.pluginNeedsConfig,
        colors.warningText,
      ),
      'needs_config' => (LocaleKeys.pluginNeedsConfig, colors.warningText),
      'needs_permission' => (
        LocaleKeys.pluginNeedsPermission,
        colors.warningText,
      ),
      'disabled' => (LocaleKeys.pluginDisabled, colors.textMuted),
      'unsupported' => (LocaleKeys.pluginUnsupported, colors.textSubtle),
      'activating' => (LocaleKeys.pluginActivating, colors.accentAmber),
      'available' => (LocaleKeys.pluginAvailable, colors.success),
      _ => (LocaleKeys.pluginFailed, colors.error),
    };

/// 已保存但当前 AI 设置中不可用（被删除、停用或配置失效）的模型配置项标题。
List<String> pluginUnavailableModelFields(
  PluginStatus status,
  AiSettings settings,
  Locale locale,
) {
  final fields = status.manifest?.settings ?? const [];
  return [
    for (final field in fields)
      if (status.modelSelections[field.key] case final selection?
          when settings.findModelOptionById(
                kind: AiModelKind.chat,
                optionId: '${selection.providerId}::${selection.model}',
              ) ==
              null)
        field.title.resolve(locale),
  ];
}

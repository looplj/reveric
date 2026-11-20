// 职责: 新建自定义供应商的草稿 — 创建、保存落库与离开确认。
// 关联文件:
//   lib/shared/widgets/settings/ai_providers_section.dart
//   lib/shared/widgets/settings/provider_config_panel.dart
//   lib/shared/widgets/settings/provider_type_picker.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/provider.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/state-management.md
//   .agents/rules/i18n.md

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../components/reveric_badge.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/ai_provider.dart';
import '../../providers/settings_providers.dart';
import '../../theme/theme.dart';
import '../../utils/random_id.dart';
import '../unsaved_changes_dialog.dart';
import 'ai_providers_section.dart' show localizedProviderTypeName;
import 'plugins/config_form.dart';

/// 未落库的新供应商；名称默认取类型名，保存前只存在于编辑界面。
AiProvider newProviderDraft(BuildContext context, String type) => _applyType(
  AiProvider(
    audioModels: const [],
    videoModels: const [],
    id: buildRandomId('prv', length: 6),
    name: localizedProviderTypeName(context, type),
    builtin: false,
    type: type,
    enabled: false,
    apiKey: '',
    baseUrl: '',
    models: const [],
    imageModels: const [],
    deletedAt: DateTime.fromMillisecondsSinceEpoch(0),
    embeddingModels: const [],
    temperature: 0.7,
    maxTurns: 512,
    proxyUrl: '',
    proxyUsername: '',
    proxyPassword: '',
    updatedAt: DateTime.now(),
  ),
  type,
);

AiProvider _applyType(AiProvider draft, String type) => draft.copyWith(
  baseUrl: aiProviderTypeConfigs[type]?.fixedBaseUrl == true
      ? aiProviderFixedBaseUrl(AiProviderType.values.byName(type))
      : '',
  videoModels: type == 'metaso'
      ? aiProviderBuiltinById('metaso')!.videoModels
      : const [],
);

/// 草稿保存条件；名称为空时不能创建。
bool canSaveProviderDraft(AiProvider draft) => draft.name.trim().isNotEmpty;

/// 写入草稿并返回新供应商 ID；配置已满足启用条件时直接启用。
Future<String> saveProviderDraft(
  WidgetRef ref,
  AiProvider draft, {
  PluginConfigDraftController? pluginDraft,
}) {
  final config = draft.copyWith(
    name: draft.name.trim(),
    enabled: draft.enableValidationMessage == null,
    updatedAt: DateTime.now(),
  );
  if (config.isPluginProvider) {
    final submission = pluginDraft!.read();
    return ref
        .read(appSettingsProvider.notifier)
        .addPluginProvider(
          config,
          settings: submission.settings,
          secrets: submission.secrets,
        );
  }
  return ref.read(appSettingsProvider.notifier).addCustomProvider(config);
}

/// 离开草稿前询问保存、丢弃或继续编辑；名称为空时不提供保存。
Future<UnsavedChangesDecision?> askLeaveProviderDraft(
  BuildContext context,
  AiProvider draft,
) => showUnsavedChangesDialog(
  context: context,
  titleKey: LocaleKeys.editorUnsavedChangesTitle,
  messageKey: LocaleKeys.editorUnsavedChangesMessage,
  showSave: canSaveProviderDraft(draft),
);

class ProviderDraftBadge extends StatelessWidget {
  const ProviderDraftBadge({super.key});

  @override
  Widget build(BuildContext context) => RevericBadge(
    label: context.t(LocaleKeys.providerDraftBadge),
    color: RevericTheme.colorsOf(context).warningText,
  );
}

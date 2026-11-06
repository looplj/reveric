// 职责: 在共享供应商表单中编辑视频模型列表。
// 关联文件:
//   lib/shared/widgets/settings/provider_config_panel.dart
//   lib/shared/widgets/settings/provider_models_editor.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/widgets/settings/provider_video_highlights.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/provider.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md

import 'package:flutter/material.dart';

import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/ai_provider.dart';
import 'provider_models_editor.dart';
import 'provider_video_highlights.dart';

class ProviderVideoModels extends StatelessWidget {
  const ProviderVideoModels({
    super.key,
    required this.config,
    required this.onChanged,
    this.fetchButton,
  });
  final AiProvider config;
  final ValueChanged<List<String>> onChanged;
  final Widget? fetchButton;

  @override
  Widget build(BuildContext context) {
    if (!config.supportsModelKind(AiModelKind.video)) {
      return const SizedBox.shrink();
    }
    return ProviderModelsEditor(
      key: ValueKey(config.id),
      label: context.t(LocaleKeys.providerVideoModelsLabel),
      hint: context.t(LocaleKeys.providerModelIdHint),
      models: config.availableVideoModels,
      onChanged: onChanged,
      fetchButton: fetchButton,
      modelTrailing: (model) =>
          providerVideoHighlights(context, config.type, model),
      modelNotice: (model) => providerVideoNotice(context, config.type, model),
    );
  }
}

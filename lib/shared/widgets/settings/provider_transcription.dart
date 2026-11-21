// 职责: 编辑供应商的语音识别模型列表并选择 Agent 默认模型。
// 关联文件:
//   lib/shared/widgets/settings/provider_config_panel.dart
//   lib/shared/models/transcription/catalog.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/provider.json

import 'package:flutter/material.dart';

import '../../components/reveric_icon_button.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/ai_provider.dart';
import 'provider_models_editor.dart';
import '../../theme/theme.dart';

class ProviderTranscriptionSettings extends StatelessWidget {
  const ProviderTranscriptionSettings({
    super.key,
    required this.provider,
    required this.onModelsChanged,
    required this.fetchButton,
    this.defaultModelId,
    this.onDefaultChanged,
  });

  final AiProvider provider;
  final ValueChanged<List<String>> onModelsChanged;
  final Widget fetchButton;
  final String? defaultModelId;
  final ValueChanged<String?>? onDefaultChanged;

  @override
  Widget build(BuildContext context) => ProviderModelsEditor(
    label: context.t(LocaleKeys.providerTranscription),
    hint: context.t(LocaleKeys.providerModelIdHint),
    models: provider.availableAsrModels,
    onChanged: onModelsChanged,
    fetchButton: fetchButton,
    modelTrailing: onDefaultChanged == null
        ? null
        : (model) {
            final id = '${provider.id}::$model';
            final isDefault = id == defaultModelId;
            return RevericIconButton(
              icon: isDefault ? RevericIcons.check : RevericIcons.star,
              tooltip: context.t(LocaleKeys.providerDefaultTranscription),
              onPressed: () => onDefaultChanged!(isDefault ? null : id),
            );
          },
  );
}

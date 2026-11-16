// 职责: 封面与地图表单的临时图片模型选择，候选项来自用户已配置的可用图片模型。
// 关联文件:
//   lib/shared/providers/ai_providers.dart
//   lib/shared/widgets/cover_studio/sections.dart
//   lib/shared/widgets/map/map_generate_fields.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../mobile/widgets/model_selector.dart';
import '../../../mobile/widgets/model_effort_sheet.dart';
import '../../components/reveric_select.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/ai_provider.dart';
import '../../providers/ai_providers.dart';
import '../../providers/settings_providers.dart';
import '../../theme/theme.dart';

class StudioImageModelSelector extends ConsumerWidget {
  const StudioImageModelSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String? value;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = ref
        .watch(aiSettingsProvider)
        .availableModelOptionsForKind(AiModelKind.image);
    final selection = ref.watch(studioImageModelSelectionProvider(value));
    final selected = selection == null
        ? null
        : '${selection.config.id}::${selection.model}';
    final label = context.t(LocaleKeys.settingsAiModel);
    final placeholder = context.t(LocaleKeys.aiModelUnavailableReselect);
    final mobile =
        Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (mobile) ...[
          Text(label, style: RevericTheme.typographyOf(context).uiSmall),
          const SizedBox(height: RevericSpacing.sm),
          IgnorePointer(
            ignoring: !enabled || options.isEmpty,
            child: MobileModelSelector.bar(
              models: options,
              selectedId: selected,
              selectedEffort: null,
              placeholder: placeholder,
              onTap: () => showAiModelEffortSheet(
                context,
                title: label,
                subtitle: context.t(LocaleKeys.aiImageModelCurrentDraft),
                models: options,
                selectedId: selected,
                selectedEffort: null,
                disabledModelIds: const {},
                onSelectModel: (option) => onChanged(option.id),
                onSelectEffort: (option, _) => onChanged(option.id),
              ),
              onSelectEffort: (option, _) => onChanged(option.id),
            ),
          ),
        ] else
          RevericSelect<String>(
            label: label,
            value: selected,
            placeholder: placeholder,
            enabled: enabled && options.isNotEmpty,
            items: [
              for (final option in options)
                RevericSelectItem(
                  value: option.id,
                  subtitle: option.providerDisplayName,
                  label: option.displayModelName,
                ),
            ],
            onChanged: onChanged,
          ),
      ],
    );
  }
}

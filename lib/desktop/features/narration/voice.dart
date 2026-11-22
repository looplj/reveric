// 职责: 选择朗读预设音色或输入自定义音色 ID。
// 关联文件:
//   lib/desktop/features/narration/setup.dart
//   lib/shared/localization/audio_voice_localization.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/audio.json
//   assets/translations/zh-CN/audio.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/form.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_dialog.dart';
import '../../../shared/components/reveric_select.dart';
import '../../../shared/form/form.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/audio_voice_localization.dart';
import '../../../shared/localization/locale_keys.dart';

const _custom = '\u0000custom';

class NarrationVoiceSelect extends StatelessWidget {
  const NarrationVoiceSelect({
    super.key,
    required this.label,
    required this.value,
    required this.voices,
    required this.onChanged,
    this.allowNarrator = true,
  });
  final bool allowNarrator;
  final String label, value;
  final List<String> voices;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => RevericSelect<String>(
    label: label,
    value: value.isEmpty && !allowNarrator ? null : value,
    placeholder: context.t(LocaleKeys.narrationChooseVoice),
    items: [
      if (allowNarrator)
        RevericSelectItem(
          value: '',
          label: context.t(LocaleKeys.narrationUseNarrator),
        ),
      for (final voice in {...voices, if (value.isNotEmpty) value})
        RevericSelectItem(
          value: voice,
          label: localizedAudioVoiceName(
            context,
            voice,
            presetIndex: voices.indexOf(voice),
          ),
        ),
      RevericSelectItem(
        value: _custom,
        label: context.t(LocaleKeys.productionSpeechCustomVoice),
      ),
    ],
    onChanged: (value) async {
      if (value != _custom) {
        onChanged(value);
        return;
      }
      final custom = await showRevericDialog<String>(
        context: context,
        useRootNavigator: false,
        builder: (_) => const _CustomVoiceDialog(),
      );
      if (custom != null && context.mounted) {
        onChanged(custom);
      }
    },
  );
}

enum _VoiceField<T> implements FieldSchema {
  voice<String>(validators: [RequiredValidator<String>()]);

  const _VoiceField({this.validators});
  @override
  final List<Validator<T>>? validators;
}

class _CustomVoiceDialog extends HookWidget {
  const _CustomVoiceDialog();
  @override
  Widget build(BuildContext context) {
    final form = useForm<_VoiceField>();
    return RevericDialog(
      title: context.t(LocaleKeys.productionSpeechVoiceId),
      content: HookedForm(
        form: form,
        child: HookedTextFormField<_VoiceField>(
          fieldHook: _VoiceField.voice,
          autofocus: true,
          hintText: context.t(LocaleKeys.productionSpeechVoiceIdHint),
          validator: (value) => value?.trim().isNotEmpty == true
              ? null
              : context.t(LocaleKeys.productionSpeechVoiceRequired),
        ),
      ),
      actions: [
        RevericButton.text(
          label: context.t(LocaleKeys.commonCancel),
          onPressed: () => Navigator.pop(context),
        ),
        RevericButton.primary(
          label: context.t(LocaleKeys.commonConfirm),
          onPressed: () {
            if (form.validate()) {
              Navigator.pop(
                context,
                form.getValue<String>(_VoiceField.voice)!.trim(),
              );
            }
          },
        ),
      ],
    );
  }
}

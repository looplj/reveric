// 职责: 在移动弹层中选择人物图像风格及补充要求，返回生成提示文本。
// 关联文件:
//   lib/mobile/widgets/character_image_actions.dart
//   lib/mobile/widgets/sheet.dart
//   lib/shared/form/hooked_text_form_field.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
//   assets/translations/en/agent.json
//   assets/translations/zh-CN/agent.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/form.md
//   .agents/rules/design-system.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../shared/components/reveric_button.dart';
import '../../shared/form/hooked_text_form_field.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/models/cover_style.dart';
import '../../shared/theme/theme.dart';
import '../../third/form/flutter_hook_form.dart';
import 'sheet.dart';

enum _ImageFields<T> implements FieldSchema {
  style<String>(),
  customStyle<String>(),
  extra<String>();

  const _ImageFields();

  @override
  List<Validator<T>> get validators => const [];
}

const _styleKeys = [
  LocaleKeys.editorCoverStyleCinematic,
  LocaleKeys.editorCoverStyleIllustration,
  LocaleKeys.editorCoverStyleEastern,
  LocaleKeys.editorCoverStyleMinimal,
  LocaleKeys.editorCoverStyleCg3d,
  LocaleKeys.agentRoleCustom,
];

class MobileCharacterImageStyleSheet extends HookWidget {
  const MobileCharacterImageStyleSheet({
    super.key,
    required this.title,
    required this.confirmLabel,
  });

  final String title;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final form = useForm<_ImageFields>();
    final style = form.getValue<String>(_ImageFields.style);
    final custom = style == LocaleKeys.agentRoleCustom;
    final canConfirm =
        style != null &&
        (!custom ||
            (form.getValue<String>(_ImageFields.customStyle) ?? '')
                .trim()
                .isNotEmpty);

    return HookedForm(
      form: form,
      child: MobileSheetScaffold(
        header: MobileSheetHeader.closable(
          title: title,
          onClose: () => Navigator.of(context).pop(),
        ),
        footer: RevericButton.primary(
          key: const ValueKey('character-image-confirm'),
          label: confirmLabel,
          onPressed: canConfirm
              ? () {
                  if (!form.validate()) {
                    return;
                  }
                  final styleText = custom
                      ? form.getValue<String>(_ImageFields.customStyle)!.trim()
                      : style == LocaleKeys.editorCoverStyleCg3d
                      ? coverStyleCg3dPrompt
                      : context.t(style);
                  final extra =
                      (form.getValue<String>(_ImageFields.extra) ?? '').trim();
                  Navigator.of(
                    context,
                  ).pop(extra.isEmpty ? styleText : '$styleText\n\n$extra');
                }
              : null,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(RevericSpacing.x2l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.t(LocaleKeys.editorCoverStyle),
                style: typo.uiSemibold.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: RevericSpacing.sm),
              HookedFormField<_ImageFields, String>(
                fieldHook: _ImageFields.style,
                notifyOnChange: true,
                builder: (value, onChanged, error) => Wrap(
                  spacing: RevericSpacing.sm,
                  runSpacing: RevericSpacing.xxs,
                  children: [
                    for (final key in _styleKeys)
                      ChoiceChip(
                        label: Text(context.t(key)),
                        selected: value == key,
                        onSelected: (_) => onChanged!(key),
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                      ),
                  ],
                ),
              ),
              if (custom) ...[
                const SizedBox(height: RevericSpacing.lg),
                HookedTextFormField<_ImageFields>(
                  fieldHook: _ImageFields.customStyle,
                  fieldKey: const ValueKey('character-image-custom-style'),
                  hintText: context.t(LocaleKeys.editorCoverStyleCustomHint),
                  multiline: true,
                  minLines: 1,
                  maxLines: 2,
                  notifyOnChange: true,
                ),
              ],
              const SizedBox(height: RevericSpacing.xl),
              HookedTextFormField<_ImageFields>(
                fieldHook: _ImageFields.extra,
                fieldKey: const ValueKey('character-image-extra'),
                label: context.t(LocaleKeys.editorCoverExtraRequirements),
                hintText: context.t(LocaleKeys.editorCoverExtraHint),
                multiline: true,
                minLines: 2,
                maxLines: 4,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

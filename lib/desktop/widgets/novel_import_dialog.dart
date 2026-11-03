// 职责: 桌面端 TXT 作品导入表单 — 填写作品信息、选择类型并确认拆章导入，可选导入后直接改编。
// 关联文件:
//   lib/desktop/pages/home.dart
//   lib/shared/services/novel_import.dart
//   lib/shared/models/novel_type.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
// 遵循的 Rules:
//   .agents/rules/form.md
//   .agents/rules/hooks.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/components/reveric_button.dart';
import '../../shared/components/reveric_tags_editor.dart';
import '../../shared/form/form.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/models/novel_type.dart';
import '../../shared/logger/app_logger.dart';
import '../../shared/providers/dictionary_providers.dart';
import '../../shared/services/novel_import.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/novel/category_field.dart';
import '../../shared/widgets/novel/import_adapt_option.dart';

final _log = AppLogger.forModule('NovelImport');

typedef NovelImportSubmitter =
    Future<NovelImportResult> Function({
      required String title,
      required String description,
      required String category,
      required String type,
      required List<String> tags,
      required String? adaptationTitle,
      required int? plannedEpisodeCount,
    });

enum NovelImportFormField<T> implements FieldSchema {
  title<String>(validators: [RequiredValidator<String>()]),
  plannedEpisodeCount<String>(),
  description<String>(),
  category<String>(),
  type<String>(),
  tags<List<String>>();

  const NovelImportFormField({this.validators});

  @override
  final List<Validator<dynamic>>? validators;
}

class NovelImportDialog extends HookConsumerWidget {
  const NovelImportDialog({
    super.key,
    required this.filePath,
    required this.parsed,
    required this.onSubmit,
  });

  final String filePath;
  final ParsedNovelImport parsed;
  final NovelImportSubmitter onSubmit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final form = useForm<NovelImportFormField>(
      initialValues: {
        NovelImportFormField.title: parsed.suggestedTitle,
        NovelImportFormField.description: '',
        NovelImportFormField.plannedEpisodeCount: '',
        NovelImportFormField.category: '',
        NovelImportFormField.type: novelTypeOriginal,
        NovelImportFormField.tags: <String>[],
      },
      keys: [filePath],
    );
    final isBusy = useState(false);
    final adaptAfterImport = useState(false);
    // 标签建议：loading 中传 null（纯自由文本），加载完成后自动补全。
    final tagSuggestions = ref.watch(novelTagsProvider).value;

    Future<void> handleSubmit() async {
      if (isBusy.value) {
        return;
      }
      if (!form.validate()) {
        return;
      }

      final title = (form.getValue<String>(NovelImportFormField.title) ?? '')
          .trim();
      final description =
          (form.getValue<String>(NovelImportFormField.description) ?? '')
              .trim();
      final category =
          (form.getValue<String>(NovelImportFormField.category) ?? '').trim();
      final type =
          form.getValue<String>(NovelImportFormField.type) ?? novelTypeOriginal;
      final tags =
          form.getValue<List<String>>(NovelImportFormField.tags) ?? const [];

      final episodeText =
          (form.getValue<String>(NovelImportFormField.plannedEpisodeCount) ??
                  '')
              .trim();
      final episodeCount = int.tryParse(episodeText);
      isBusy.value = true;
      try {
        final result = await onSubmit(
          title: title,
          description: description,
          category: category,
          type: novelTypes.contains(type) ? type : novelTypeOriginal,
          tags: tags,
          adaptationTitle: adaptAfterImport.value
              ? context.t(
                  LocaleKeys.libraryAdaptationTitle,
                  namedArgs: {'title': title},
                )
              : null,
          plannedEpisodeCount: adaptAfterImport.value ? episodeCount : null,
        );
        if (context.mounted) {
          Navigator.of(context).pop<NovelImportResult>(result);
        }
      } on NovelImportException catch (e) {
        if (context.mounted) {
          form.setError(NovelImportFormField.title, e.message);
        }
      } catch (error, stackTrace) {
        _log.error('Import failed', error: error, stackTrace: stackTrace);
        if (context.mounted) {
          form.setError(
            NovelImportFormField.title,
            context.t(LocaleKeys.libraryImportTxtFailed),
          );
        }
      } finally {
        if (context.mounted) {
          isBusy.value = false;
        }
      }
    }

    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RevericRadius.x2l),
      ),
      insetPadding: const EdgeInsets.all(RevericSpacing.x2l),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 640,
          maxHeight: MediaQuery.sizeOf(context).height - RevericSpacing.x6l,
        ),
        child: Padding(
          padding: const EdgeInsets.all(RevericSpacing.x3l),
          child: HookedForm<NovelImportFormField>(
            form: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.t(LocaleKeys.libraryImportTxt),
                  style: typo.heading2.copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: RevericSpacing.sm),
                Text(
                  context.t(
                    LocaleKeys.libraryImportTxtSummary,
                    namedArgs: {
                      'chapters': '${parsed.chapters.length}',
                      'volumes': '${parsed.volumeCount}',
                    },
                  ),
                  style: typo.uiSmall.copyWith(color: colors.textMuted),
                ),
                const SizedBox(height: RevericSpacing.x2l),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ImportInputField(
                          label: context.t(LocaleKeys.libraryNovelName),
                          fieldHook: NovelImportFormField.title,
                          autofocus: true,
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? context.t(LocaleKeys.formRequired)
                              : null,
                        ),
                        const SizedBox(height: RevericSpacing.sm),
                        ConstrainedBox(
                          constraints: const BoxConstraints(
                            minHeight: RevericSizes.touchTargetSize,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: NovelImportAdaptOption(
                                  value: adaptAfterImport.value,
                                  onChanged: isBusy.value
                                      ? null
                                      : (value) =>
                                            adaptAfterImport.value = value,
                                ),
                              ),
                              if (adaptAfterImport.value) ...[
                                const SizedBox(width: RevericSpacing.lg),
                                SizedBox(
                                  width: 144,
                                  child: HookedTextFormField<NovelImportFormField>(
                                    key: const ValueKey(
                                      'import-planned-episodes',
                                    ),
                                    enabled: !isBusy.value,
                                    autovalidateMode:
                                        AutovalidateMode.onUserInteraction,
                                    validator: (value) {
                                      final text = value?.trim() ?? '';
                                      final count = int.tryParse(text);
                                      return text.isNotEmpty &&
                                              (count == null || count < 1)
                                          ? context.t(
                                              LocaleKeys
                                                  .libraryPlannedEpisodeCountInvalid,
                                            )
                                          : null;
                                    },
                                    fieldHook: NovelImportFormField
                                        .plannedEpisodeCount,
                                    hintText: context.t(
                                      LocaleKeys.libraryPlannedEpisodeCount,
                                    ),
                                    keyboardType: TextInputType.number,
                                    textInputAction: TextInputAction.next,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: RevericSpacing.lg),
                        _ImportInputField(
                          label: context.t(LocaleKeys.libraryDescription),
                          fieldHook: NovelImportFormField.description,
                          minLines: 4,
                          maxLines: 4,
                          keyboardType: TextInputType.multiline,
                        ),
                        const SizedBox(height: RevericSpacing.lg),
                        NovelCategoryField(
                          fieldHook: NovelImportFormField.category,
                        ),
                        const SizedBox(height: RevericSpacing.lg),
                        _TypeField(form: form),
                        const SizedBox(height: RevericSpacing.lg),
                        _TagsField(form: form, suggestions: tagSuggestions),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: RevericSpacing.x2l),
                Divider(
                  height: RevericSizes.dividerThickness,
                  color: colors.borderSubtle,
                ),
                const SizedBox(height: RevericSpacing.lg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    RevericButton.text(
                      onPressed: isBusy.value
                          ? null
                          : () => Navigator.of(context).pop(),
                      label: context.t(LocaleKeys.commonCancel),
                    ),
                    const SizedBox(width: RevericSpacing.sm),
                    RevericButton.primary(
                      onPressed: handleSubmit,
                      loading: isBusy.value,
                      icon: RevericIcons.upload,
                      label: context.t(LocaleKeys.libraryStartImport),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ImportInputField extends StatelessWidget {
  const _ImportInputField({
    required this.label,
    required this.fieldHook,
    this.validator,
    this.autofocus = false,
    this.minLines,
    this.maxLines,
    this.keyboardType,
  });

  final String label;
  final NovelImportFormField fieldHook;
  final String? Function(String?)? validator;
  final bool autofocus;
  final int? minLines;
  final int? maxLines;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return HookedTextFormField<NovelImportFormField>(
      fieldHook: fieldHook,
      label: label,
      autofocus: autofocus,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: validator,
      multiline: minLines != null || maxLines != null,
      minLines: minLines ?? 4,
      maxLines: maxLines,
      keyboardType: keyboardType,
    );
  }
}

class _TypeField extends StatelessWidget {
  const _TypeField({required this.form});

  final FormFieldsController<NovelImportFormField> form;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t(LocaleKeys.libraryNovelType),
          style: typo.uiSemibold.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: RevericSpacing.sm),
        HookedFormField<NovelImportFormField, String>(
          fieldHook: NovelImportFormField.type,
          notifyOnChange: true,
          builder: (value, onChanged, error) {
            final selected = value ?? novelTypeOriginal;
            return Wrap(
              spacing: RevericSpacing.sm,
              runSpacing: RevericSpacing.sm,
              children: [
                for (final type in novelTypes)
                  ChoiceChip(
                    label: Text(_novelTypeLabel(context, type)),
                    selected: selected == type,
                    onSelected: (_) {
                      form.updateValue(
                        NovelImportFormField.type,
                        type,
                        notify: true,
                      );
                    },
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

String _novelTypeLabel(BuildContext context, String type) {
  return switch (type) {
    novelTypeOriginal => context.t(LocaleKeys.libraryNovelTypeOriginal),
    novelTypeAdaptation => context.t(LocaleKeys.libraryNovelTypeAdaptation),
    novelTypeSequel => context.t(LocaleKeys.libraryNovelTypeSequel),
    novelTypeFanfic => context.t(LocaleKeys.libraryNovelTypeFanfic),
    novelTypeDerivative => context.t(LocaleKeys.libraryNovelTypeDerivative),
    novelTypeMaterial => context.t(LocaleKeys.libraryNovelTypeMaterial),
    _ => type,
  };
}

class _TagsField extends StatelessWidget {
  const _TagsField({required this.form, this.suggestions});

  final FormFieldsController<NovelImportFormField> form;
  final List<String>? suggestions;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t(LocaleKeys.libraryTagsLabel),
          style: typo.uiSemibold.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: RevericSpacing.sm),
        HookedFormField<NovelImportFormField, List<String>>(
          fieldHook: NovelImportFormField.tags,
          notifyOnChange: true,
          builder: (tags, onChanged, error) {
            final currentTags = tags ?? const <String>[];
            return RevericTagsEditor(
              tags: currentTags,
              onChanged: (updated) {
                form.updateValue(
                  NovelImportFormField.tags,
                  updated,
                  notify: true,
                );
              },
              addLabel: context.t(LocaleKeys.libraryAddTag),
              hintText: context.t(LocaleKeys.libraryTagHint),
              suggestions: suggestions,
            );
          },
        ),
      ],
    );
  }
}

// 职责: 移动端 TXT 作品导入页 — 填写作品信息、选择类型并确认拆章导入
// 关联文件:
//   lib/mobile/pages/library_page.dart
//   lib/shared/services/novel_import.dart
//   lib/shared/models/novel_type.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/form.md
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/form/form.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/models/novel_type.dart';
import '../../shared/logger/app_logger.dart';
import '../../shared/providers/dictionary_providers.dart';
import '../../shared/services/novel_import.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/novel/category_field.dart';

final _log = AppLogger.forModule('NovelImport');

typedef MobileNovelImportSubmitter =
    Future<NovelImportResult> Function({
      required String title,
      required String description,
      required String category,
      required String type,
      required List<String> tags,
    });

enum _ImportFormField<T> implements FieldSchema {
  title<String>(validators: [RequiredValidator<String>()]),
  description<String>(),
  category<String>(),
  type<String>(),
  tags<List<String>>();

  const _ImportFormField({this.validators});

  @override
  final List<Validator<dynamic>>? validators;
}

class MobileNovelImportPage extends HookConsumerWidget {
  const MobileNovelImportPage({
    super.key,
    required this.filePath,
    required this.parsed,
    required this.onSubmit,
  });

  final String filePath;
  final ParsedNovelImport parsed;
  final MobileNovelImportSubmitter onSubmit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final form = useForm<_ImportFormField>(
      initialValues: {
        _ImportFormField.title: parsed.suggestedTitle,
        _ImportFormField.description: '',
        _ImportFormField.category: '',
        _ImportFormField.type: novelTypeOriginal,
        _ImportFormField.tags: <String>[],
      },
      keys: [filePath],
    );
    final isBusy = useState(false);
    // 标签建议：loading 中传 null（纯自由文本），加载完成后自动补全。
    final tagSuggestions = ref.watch(novelTagsProvider).value;

    Future<void> handleSubmit() async {
      if (isBusy.value) {
        return;
      }
      if (!form.validate()) {
        return;
      }
      final title = (form.getValue<String>(_ImportFormField.title) ?? '')
          .trim();
      final description =
          (form.getValue<String>(_ImportFormField.description) ?? '').trim();
      final category = (form.getValue<String>(_ImportFormField.category) ?? '')
          .trim();
      final type =
          form.getValue<String>(_ImportFormField.type) ?? novelTypeOriginal;
      final tags =
          form.getValue<List<String>>(_ImportFormField.tags) ?? const [];
      isBusy.value = true;
      try {
        final result = await onSubmit(
          title: title,
          description: description,
          category: category,
          type: type,
          tags: tags,
        );
        if (context.mounted) {
          Navigator.of(context).pop<NovelImportResult>(result);
        }
      } on NovelImportException catch (e) {
        if (context.mounted) {
          form.setError(_ImportFormField.title, e.message);
        }
      } catch (error, stackTrace) {
        _log.error('Import failed', error: error, stackTrace: stackTrace);
        if (context.mounted) {
          form.setError(
            _ImportFormField.title,
            context.t(LocaleKeys.libraryImportTxtFailed),
          );
        }
      } finally {
        if (context.mounted) {
          isBusy.value = false;
        }
      }
    }

    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.canvas,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: RevericIcon(
            RevericIcons.arrow_back,
            size: 22,
            color: colors.textSecondary,
          ),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          context.t(LocaleKeys.libraryImportTxt),
          style: typo.uiSemibold.copyWith(color: colors.textPrimary),
        ),
        actions: [
          TextButton(
            onPressed: isBusy.value ? null : handleSubmit,
            child: Text(
              isBusy.value
                  ? context.t(LocaleKeys.libraryImportingTxt)
                  : context.t(LocaleKeys.libraryStartImport),
              style: typo.uiSemibold.copyWith(
                color: isBusy.value ? colors.textSubtle : colors.accentWarm,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: HookedForm<_ImportFormField>(
          form: form,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.x3l,
              RevericSpacing.lg,
              RevericSpacing.x3l,
              RevericSpacing.x6l,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
                HookedTextFormField<_ImportFormField>(
                  fieldHook: _ImportFormField.title,
                  label: context.t(LocaleKeys.libraryNovelName),
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: RevericSpacing.xl),
                HookedTextFormField<_ImportFormField>(
                  fieldHook: _ImportFormField.description,
                  label: context.t(LocaleKeys.libraryDescription),
                  multiline: true,
                  minLines: 3,
                  maxLines: 5,
                  keyboardType: TextInputType.multiline,
                ),
                const SizedBox(height: RevericSpacing.xl),
                _FieldLabel(text: context.t(LocaleKeys.libraryNovelType)),
                const _TypeField(),
                const SizedBox(height: RevericSpacing.xl),
                NovelCategoryField(fieldHook: _ImportFormField.category),
                const SizedBox(height: RevericSpacing.xl),
                _FieldLabel(text: context.t(LocaleKeys.libraryTagsLabel)),
                _TagsField(form: form, suggestions: tagSuggestions),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: RevericSpacing.sm),
      child: Text(
        text,
        style: typo.uiSemibold.copyWith(color: colors.textSecondary),
      ),
    );
  }
}

class _TypeField extends StatelessWidget {
  const _TypeField();

  @override
  Widget build(BuildContext context) {
    return HookedFormField<_ImportFormField, String>(
      fieldHook: _ImportFormField.type,
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
                onSelected: (_) => onChanged?.call(type),
              ),
          ],
        );
      },
    );
  }
}

class _TagsField extends StatelessWidget {
  const _TagsField({required this.form, this.suggestions});

  final FormFieldsController<_ImportFormField> form;
  final List<String>? suggestions;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);

    return HookedFormField<_ImportFormField, List<String>>(
      fieldHook: _ImportFormField.tags,
      notifyOnChange: true,
      builder: (tags, onChanged, error) {
        final currentTags = tags ?? const <String>[];
        return Container(
          decoration: BoxDecoration(
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(RevericRadius.large),
            border: Border.all(color: colors.borderInput),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.md,
            vertical: RevericSpacing.sm,
          ),
          child: Wrap(
            spacing: RevericSpacing.sm,
            runSpacing: RevericSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final tag in currentTags)
                _TagChip(
                  label: tag,
                  onDeleted: () {
                    final updated = List<String>.from(currentTags)..remove(tag);
                    onChanged?.call(updated);
                  },
                ),
              _AddTagInput(
                onAdd: (tag) {
                  if (currentTags.contains(tag)) {
                    return;
                  }
                  onChanged?.call(List<String>.from(currentTags)..add(tag));
                },
                suggestions: suggestions,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.label, required this.onDeleted});

  final String label;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      padding: const EdgeInsets.only(
        left: RevericSpacing.md,
        right: RevericSpacing.xs,
        top: RevericSpacing.xxs,
        bottom: RevericSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: colors.selected,
        borderRadius: BorderRadius.circular(RevericRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: typo.uiSmall.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(width: RevericSpacing.xxs),
          InkWell(
            onTap: onDeleted,
            customBorder: const CircleBorder(),
            child: RevericIcon(
              RevericIcons.close,
              size: 14,
              color: colors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _AddTagInput extends HookWidget {
  const _AddTagInput({required this.onAdd, this.suggestions});

  final ValueChanged<String> onAdd;

  /// 非空时启用 Autocomplete 下拉建议。
  final List<String>? suggestions;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final controller = useTextEditingController();
    final focusNode = useFocusNode();
    final hasSuggestions = suggestions != null && suggestions!.isNotEmpty;

    void submit() {
      final text = controller.text.trim();
      if (text.isEmpty) {
        return;
      }
      onAdd(text);
      controller.clear();
    }

    void submitValue(String value) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) {
        onAdd(trimmed);
      }
      controller.clear();
    }

    final field = TextField(
      controller: controller,
      focusNode: focusNode,
      style: typo.uiSmall.copyWith(color: colors.textPrimary),
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        hintText: context.t(LocaleKeys.libraryTagHint),
        hintStyle: typo.uiSmall.copyWith(color: colors.textSubtle),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.xs,
          vertical: RevericSpacing.xs,
        ),
      ),
      onSubmitted: (_) => submit(),
      onEditingComplete: submit,
    );

    if (!hasSuggestions) {
      return IntrinsicWidth(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 72),
          child: field,
        ),
      );
    }

    return IntrinsicWidth(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 72),
        child: RawAutocomplete<String>(
          textEditingController: controller,
          focusNode: focusNode,
          optionsBuilder: (textEditingValue) {
            final query = textEditingValue.text.toLowerCase();
            if (query.isEmpty) {
              return suggestions!;
            }
            return suggestions!.where((s) => s.toLowerCase().contains(query));
          },
          optionsViewBuilder: (context, onSelected, options) {
            return _TagOptionsView(
              options: options.toList(),
              colors: colors,
              typo: typo,
              onTap: (value) {
                onSelected(value);
                submitValue(value);
              },
            );
          },
          fieldViewBuilder:
              (context, controller, focusNode, onFieldSubmitted) => field,
        ),
      ),
    );
  }
}

/// 标签自动补全下拉浮层（移动端内联 TextField 专用）。
class _TagOptionsView extends StatelessWidget {
  const _TagOptionsView({
    required this.options,
    required this.colors,
    required this.typo,
    required this.onTap,
  });

  final List<String> options;
  final RevericColors colors;
  final RevericTypography typo;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(RevericRadius.small),
        color: colors.surface,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: options.length > 5 ? 200 : options.length * 36.0 + 8,
            maxWidth: 200,
          ),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            shrinkWrap: true,
            children: [
              for (final option in options)
                InkWell(
                  onTap: () => onTap(option),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: RevericSpacing.md,
                      vertical: 6,
                    ),
                    child: Text(
                      option,
                      style: typo.uiSmall.copyWith(color: colors.textPrimary),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
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

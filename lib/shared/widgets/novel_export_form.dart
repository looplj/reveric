// 职责: 管理小说与剧本的导出表单、范围选择和跨平台文件保存。
// 关联文件:
//   lib/desktop/widgets/novel_export_dialog.dart
//   lib/mobile/widgets/novel_export_sheet.dart
//   lib/shared/services/novel_export.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/entity.json
//   assets/translations/zh-CN/entity.json
//   assets/translations/en/assets.json
//   assets/translations/zh-CN/assets.json
//   lib/third/form/flutter_hook_form.dart
// 遵循的 Rules:
//   .agents/rules/form.md
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../components/dialog_feedback.dart';
import '../components/reveric_select.dart';
import '../localization/app_localization.dart';
import '../localization/locale_keys.dart';
import '../models/novel.dart';
import '../models/content_kind.dart';
import '../providers/novel_providers.dart';
import '../services/novel_export.dart';
import '../theme/theme.dart';
import '../../third/form/flutter_hook_form.dart';
import '../components/reveric_button.dart';

enum _NovelExportFields<T> implements FieldSchema {
  scopes<Set<NovelExportScope>>(),
  chapterNumberFormat<NovelExportChapterNumberFormat>(),
  chapterTitleAlignment<NovelExportChapterTitleAlignment>(),
  outputDirectory<String>();

  const _NovelExportFields({this.validators});

  @override
  final List<Validator<dynamic>>? validators;
}

class NovelExportForm extends HookConsumerWidget {
  const NovelExportForm({
    super.key,
    required this.novel,
    required this.usesNativeSaveSheet,
    required this.shellBuilder,
    this.showNovelTitle = true,
  });

  final Novel novel;
  final bool usesNativeSaveSheet;
  final bool showNovelTitle;
  final Widget Function(
    BuildContext context,
    Widget content,
    List<Widget> actions,
  )
  shellBuilder;

  bool get _isScreenplay => novel.contentKind == contentKindScreenplay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final form = useForm<_NovelExportFields>(
      initialValues: {
        _NovelExportFields.scopes: const <NovelExportScope>{
          NovelExportScope.body,
        },
        _NovelExportFields.chapterNumberFormat:
            NovelExportChapterNumberFormat.chinese,
        _NovelExportFields.chapterTitleAlignment:
            NovelExportChapterTitleAlignment.center,
        _NovelExportFields.outputDirectory: '',
      },
      keys: [novel.id],
    );
    final isBusy = useState(false);

    Future<void> selectDirectory() async {
      final path = await getDirectoryPath(
        confirmButtonText: context.t(LocaleKeys.libraryExportSelectFolder),
      );
      if (!context.mounted || path == null) {
        return;
      }
      form.updateValue(_NovelExportFields.outputDirectory, path, notify: true);
    }

    Future<void> submit() async {
      if (isBusy.value) {
        return;
      }
      if (!novel.hasContentDatabase) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.t(LocaleKeys.libraryExportNoContentDatabase)),
          ),
        );
        return;
      }
      if (!form.validate()) {
        return;
      }

      final scopes =
          form.getValue<Set<NovelExportScope>>(_NovelExportFields.scopes) ??
          const <NovelExportScope>{};
      final options = NovelExportOptions(
        scopes: scopes,
        labels: _localizedNovelExportLabels(
          context,
          isScreenplay: _isScreenplay,
        ),
        chapterNumberFormat:
            form.getValue<NovelExportChapterNumberFormat>(
              _NovelExportFields.chapterNumberFormat,
            ) ??
            NovelExportChapterNumberFormat.chinese,
        chapterTitleAlignment:
            form.getValue<NovelExportChapterTitleAlignment>(
              _NovelExportFields.chapterTitleAlignment,
            ) ??
            NovelExportChapterTitleAlignment.center,
      );
      final outputDirectory =
          form.getValue<String>(_NovelExportFields.outputDirectory)?.trim() ??
          '';
      final service = ref.read(novelExportProvider(novel.contentDatabasePath!));

      isBusy.value = true;
      try {
        if (usesNativeSaveSheet) {
          final archive = await service.exportToTemporaryZip(
            novel: novel,
            options: options,
          );
          if (!context.mounted) {
            return;
          }
          final result = await SharePlus.instance.share(
            ShareParams(
              files: [XFile(archive.path, mimeType: 'application/zip')],
              fileNameOverrides: [archive.uri.pathSegments.last],
            ),
          );
          if (!context.mounted || result.status != ShareResultStatus.success) {
            return;
          }
          Navigator.of(context).pop();
          return;
        }

        final directory = await service.exportToDirectory(
          novel: novel,
          options: options,
          outputDirectory: outputDirectory,
        );
        if (!context.mounted) {
          return;
        }
        Navigator.of(context).pop();
        DialogFeedback.hostMessengerOf(context).showSnackBar(
          SnackBar(
            content: DialogToast(
              variant: DialogToastVariant.success,
              child: Text(
                context.t(
                  LocaleKeys.libraryExportSuccess,
                  namedArgs: {'file': directory.path},
                ),
              ),
            ),
          ),
        );
      } catch (error, stackTrace) {
        debugPrintStack(stackTrace: stackTrace);
        if (!context.mounted) {
          return;
        }
        if (!usesNativeSaveSheet) {
          form.setError(
            _NovelExportFields.outputDirectory,
            context.t(LocaleKeys.libraryExportFailed),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: DialogToast(
                variant: DialogToastVariant.error,
                child: Text(context.t(LocaleKeys.libraryExportFailed)),
              ),
            ),
          );
        }
      } finally {
        if (context.mounted) {
          isBusy.value = false;
        }
      }
    }

    final content = DialogFeedback.surface(
      builder: (context) => SizedBox(
        width: double.infinity,
        child: HookedForm<_NovelExportFields>(
          form: form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showNovelTitle) ...[
                  Text(
                    novel.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.ui.copyWith(color: colors.textMuted),
                  ),
                  const SizedBox(height: RevericSpacing.x2l),
                ],
                _buildScopeAndFormatFields(context),
                const SizedBox(height: RevericSpacing.x3l),
                if (usesNativeSaveSheet)
                  Text(
                    context.t(LocaleKeys.libraryExportMobileFolderHint),
                    style: typo.uiSmall.copyWith(color: colors.textMuted),
                  )
                else
                  _buildDirectoryField(
                    context: context,
                    onSelectDirectory: selectDirectory,
                    isBusy: isBusy.value,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    final actions = <Widget>[
      RevericButton.secondary(
        label: context.t(LocaleKeys.commonCancel),
        onPressed: isBusy.value ? null : () => Navigator.of(context).pop(),
      ),
      RevericButton.primary(
        label: isBusy.value
            ? context.t(LocaleKeys.libraryExporting)
            : context.t(LocaleKeys.libraryExportAction),
        icon: RevericIcons.download,
        loading: isBusy.value,
        onPressed: isBusy.value ? null : submit,
      ),
    ];
    return shellBuilder(context, content, actions);
  }

  Widget _buildScopeAndFormatFields(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final scopeOptions = _novelExportScopeOptions(_isScreenplay);
    return HookedFormField<_NovelExportFields, Set<NovelExportScope>>(
      fieldHook: _NovelExportFields.scopes,
      notifyOnChange: true,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: (value) {
        if (value == null || value.isEmpty) {
          return context.t(LocaleKeys.libraryExportScopeRequired);
        }
        return null;
      },
      builder: (value, onChanged, error) {
        final selected = value ?? const <NovelExportScope>{};
        final allSelected = selected.length == scopeOptions.length;
        final selectedOptions = scopeOptions
            .where((option) => selected.contains(option.scope))
            .toList();
        final scopeDescription = switch (selectedOptions) {
          [final option] => context.t(option.hintKey),
          _ =>
            selectedOptions
                .map((option) => context.t(option.labelKey))
                .join(' · '),
        };

        void toggleScope(NovelExportScope scope, bool enabled) {
          final next = Set<NovelExportScope>.from(selected);
          if (enabled) {
            next.add(scope);
          } else {
            next.remove(scope);
          }
          onChanged?.call(next);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: RevericSpacing.sm,
                    runSpacing: RevericSpacing.xxs,
                    children: [
                      Text(
                        context.t(LocaleKeys.libraryExportScope),
                        style: typo.uiSmallSemibold.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                      Text(
                        context.t(
                          LocaleKeys.libraryExportScopeCount,
                          namedArgs: {
                            'selected': '${selected.length}',
                            'total': '${scopeOptions.length}',
                          },
                        ),
                        style: typo.uiSmall.copyWith(color: colors.textMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: RevericSpacing.sm),
                RevericButton.text(
                  size: RevericButtonSize.compact,
                  onPressed: () => onChanged?.call(
                    allSelected
                        ? <NovelExportScope>{}
                        : scopeOptions.map((option) => option.scope).toSet(),
                  ),
                  label: context.t(
                    allSelected
                        ? LocaleKeys.libraryExportScopeDeselectAll
                        : LocaleKeys.libraryExportScopeSelectAll,
                  ),
                ),
              ],
            ),
            const SizedBox(height: RevericSpacing.sm),
            Wrap(
              spacing: RevericSpacing.sm,
              runSpacing: RevericSpacing.sm,
              children: [
                for (final option in scopeOptions)
                  _NovelExportScopeChip(
                    scope: option.scope,
                    label: context.t(option.labelKey),
                    selected: selected.contains(option.scope),
                    onTap: () => toggleScope(
                      option.scope,
                      !selected.contains(option.scope),
                    ),
                  ),
              ],
            ),
            if (error != null || scopeDescription.isNotEmpty) ...[
              const SizedBox(height: RevericSpacing.xs),
              Text(
                error ?? scopeDescription,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: typo.uiTiny.copyWith(
                  color: error == null
                      ? colors.textMuted
                      : colors.deletionBorder,
                ),
              ),
            ],
            if (!_isScreenplay && selected.contains(NovelExportScope.body)) ...[
              const SizedBox(height: RevericSpacing.x2l),
              Text(
                context.t(LocaleKeys.libraryExportBodyFormat),
                style: typo.uiSmallSemibold.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: RevericSpacing.md),
              LayoutBuilder(
                builder: (context, constraints) {
                  final fields = [
                    KeyedSubtree(
                      key: const ValueKey('novel-export-number-format'),
                      child: _buildNumberFormatField(context),
                    ),
                    KeyedSubtree(
                      key: const ValueKey('novel-export-title-alignment'),
                      child: _buildAlignmentField(context),
                    ),
                  ];
                  if (constraints.maxWidth < 400) {
                    return Column(
                      children: [
                        fields.first,
                        const SizedBox(height: RevericSpacing.lg),
                        fields.last,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: fields.first),
                      const SizedBox(width: RevericSpacing.lg),
                      Expanded(child: fields.last),
                    ],
                  );
                },
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildNumberFormatField(BuildContext context) {
    return HookedFormField<_NovelExportFields, NovelExportChapterNumberFormat>(
      fieldHook: _NovelExportFields.chapterNumberFormat,
      notifyOnChange: true,
      builder: (value, onChanged, _) {
        return RevericSelect<NovelExportChapterNumberFormat>(
          label: context.t(LocaleKeys.libraryExportChapterNumberFormat),
          leadingIcon: RevericIcons.format_list_numbered,
          value: value ?? NovelExportChapterNumberFormat.chinese,
          items: [
            RevericSelectItem(
              value: NovelExportChapterNumberFormat.chinese,
              label: context.t(LocaleKeys.libraryExportChapterNumberChinese),
            ),
            RevericSelectItem(
              value: NovelExportChapterNumberFormat.number,
              label: context.t(LocaleKeys.libraryExportChapterNumberNumeric),
            ),
          ],
          onChanged: (format) => onChanged?.call(format),
        );
      },
    );
  }

  Widget _buildAlignmentField(BuildContext context) {
    return HookedFormField<
      _NovelExportFields,
      NovelExportChapterTitleAlignment
    >(
      fieldHook: _NovelExportFields.chapterTitleAlignment,
      notifyOnChange: true,
      builder: (value, onChanged, _) {
        return RevericSelect<NovelExportChapterTitleAlignment>(
          label: context.t(LocaleKeys.libraryExportChapterTitleAlignment),
          leadingIcon: RevericIcons.format_heading,
          value: value ?? NovelExportChapterTitleAlignment.center,
          items: [
            RevericSelectItem(
              value: NovelExportChapterTitleAlignment.left,
              label: context.t(LocaleKeys.libraryExportAlignmentLeft),
            ),
            RevericSelectItem(
              value: NovelExportChapterTitleAlignment.center,
              label: context.t(LocaleKeys.libraryExportAlignmentCenter),
            ),
            RevericSelectItem(
              value: NovelExportChapterTitleAlignment.right,
              label: context.t(LocaleKeys.libraryExportAlignmentRight),
            ),
          ],
          onChanged: (alignment) => onChanged?.call(alignment),
        );
      },
    );
  }

  Widget _buildDirectoryField({
    required BuildContext context,
    required VoidCallback onSelectDirectory,
    required bool isBusy,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return HookedFormField<_NovelExportFields, String>(
      fieldHook: _NovelExportFields.outputDirectory,
      notifyOnChange: true,
      validator: (value) {
        if (value == null || value.trim().isEmpty) {
          return context.t(LocaleKeys.formRequired);
        }
        return null;
      },
      builder: (value, _, error) {
        final path = value?.trim() ?? '';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.t(LocaleKeys.libraryExportFolder),
              style: typo.uiSmallSemibold.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: RevericSpacing.xs),
            LayoutBuilder(
              builder: (context, constraints) {
                final directoryPreview = Container(
                  height: RevericSizes.fieldHeight,
                  padding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.lg,
                  ),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(RevericRadius.large),
                    border: Border.all(
                      color: error == null
                          ? colors.borderInput
                          : colors.deletionBorder,
                    ),
                  ),
                  child: Text(
                    path.isEmpty
                        ? context.t(LocaleKeys.libraryExportFolderPlaceholder)
                        : path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.ui.copyWith(
                      color: path.isEmpty
                          ? colors.textSubtle
                          : colors.textPrimary,
                    ),
                  ),
                );
                final selectButton = RevericButton.secondary(
                  onPressed: isBusy ? null : onSelectDirectory,
                  icon: RevericIcons.folder_outlined,
                  label: context.t(LocaleKeys.libraryExportSelectFolder),
                );
                if (constraints.maxWidth < 400) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      directoryPreview,
                      const SizedBox(height: RevericSpacing.sm),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: selectButton,
                      ),
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: directoryPreview),
                    const SizedBox(width: RevericSpacing.sm),
                    selectButton,
                  ],
                );
              },
            ),
            if (error != null) ...[
              const SizedBox(height: RevericSpacing.xxs),
              Text(
                error,
                style: typo.uiTiny.copyWith(color: colors.deletionBorder),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _NovelExportScopeOption {
  const _NovelExportScopeOption({
    required this.scope,
    required this.labelKey,
    required this.hintKey,
  });

  final NovelExportScope scope;
  final String labelKey;
  final String hintKey;
}

class _NovelExportScopeChip extends StatelessWidget {
  const _NovelExportScopeChip({
    required this.scope,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final NovelExportScope scope;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Semantics(
      key: ValueKey('novel-export-scope-${scope.name}'),
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(RevericRadius.pill),
        child: Container(
          constraints: const BoxConstraints(
            minHeight: RevericSizes.buttonHeightSm,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.md,
            vertical: RevericSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: selected ? colors.surfaceContainerHigh : colors.surface,
            border: Border.all(
              color: selected ? colors.accentWarm : colors.borderInput,
            ),
            borderRadius: BorderRadius.circular(RevericRadius.pill),
          ),
          child: Text(
            label,
            style: typo.uiSmall.copyWith(
              color: selected ? colors.accentWarm : colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

List<_NovelExportScopeOption> _novelExportScopeOptions(bool isScreenplay) => [
  _NovelExportScopeOption(
    scope: NovelExportScope.outlines,
    labelKey: LocaleKeys.libraryExportScopeOutlines,
    hintKey: isScreenplay
        ? LocaleKeys.libraryExportScreenplayOutlinesHint
        : LocaleKeys.libraryExportScopeOutlinesHint,
  ),
  if (!isScreenplay)
    _NovelExportScopeOption(
      scope: NovelExportScope.chapter_outlines,
      labelKey: LocaleKeys.libraryExportScopeChapterOutlines,
      hintKey: LocaleKeys.libraryExportScopeChapterOutlinesHint,
    ),
  _NovelExportScopeOption(
    scope: NovelExportScope.settings,
    labelKey: LocaleKeys.libraryExportScopeSettings,
    hintKey: LocaleKeys.libraryExportScopeSettingsHint,
  ),
  _NovelExportScopeOption(
    scope: NovelExportScope.materials,
    labelKey: LocaleKeys.libraryExportScopeMaterials,
    hintKey: LocaleKeys.libraryExportScopeMaterialsHint,
  ),
  _NovelExportScopeOption(
    scope: NovelExportScope.body,
    labelKey: isScreenplay
        ? LocaleKeys.screenplayScript
        : LocaleKeys.libraryExportScopeBody,
    hintKey: isScreenplay
        ? LocaleKeys.libraryExportScreenplayBodyHint
        : LocaleKeys.libraryExportScopeBodyHint,
  ),
];

NovelExportLabels _localizedNovelExportLabels(
  BuildContext context, {
  required bool isScreenplay,
}) {
  return NovelExportLabels(
    sections: {
      NovelExportScope.chapter_outlines: context.t(
        LocaleKeys.libraryExportScopeChapterOutlines,
      ),
      NovelExportScope.outlines: context.t(
        LocaleKeys.libraryExportScopeOutlines,
      ),
      NovelExportScope.settings: context.t(
        LocaleKeys.libraryExportScopeSettings,
      ),
      NovelExportScope.materials: context.t(
        LocaleKeys.libraryExportScopeMaterials,
      ),
      NovelExportScope.body: context.t(
        isScreenplay
            ? LocaleKeys.screenplayScript
            : LocaleKeys.libraryExportScopeBody,
      ),
    },
    settingSections: {
      NovelExportSettingSection.worldbuilding: context.t(
        LocaleKeys.workspaceLore,
      ),
      NovelExportSettingSection.characters: context.t(
        LocaleKeys.workspaceCharacters,
      ),
      NovelExportSettingSection.locations: context.t(
        LocaleKeys.entityTypeLocation,
      ),
      NovelExportSettingSection.factions: context.t(
        LocaleKeys.workspaceFactions,
      ),
      NovelExportSettingSection.creatures: context.t(
        LocaleKeys.workspaceCreatures,
      ),
      NovelExportSettingSection.items: context.t(LocaleKeys.workspaceItems),
      NovelExportSettingSection.skills: context.t(LocaleKeys.workspaceSkills),
      NovelExportSettingSection.foreshadowings: context.t(
        LocaleKeys.workspaceForeshadowings,
      ),
    },
    fields: {
      NovelExportField.interior: context.t(LocaleKeys.screenplayInterior),
      NovelExportField.exterior: context.t(LocaleKeys.screenplayExterior),
      NovelExportField.interior_exterior: context.t(
        LocaleKeys.screenplayInteriorAndExterior,
      ),
      NovelExportField.cast: context.t(LocaleKeys.screenplayCastLine),
      NovelExportField.note: context.t(LocaleKeys.screenplayNotePrefix),
      NovelExportField.untitled_scene: context.t(
        LocaleKeys.screenplayUntitledScene,
      ),
      NovelExportField.unknown_character: context.t(
        LocaleKeys.screenplayUnknownCharacter,
      ),
      NovelExportField.season: context.t(LocaleKeys.screenplaySeason),
      NovelExportField.episode: context.t(LocaleKeys.screenplayEpisode),
      NovelExportField.scene: context.t(LocaleKeys.screenplayScene),
      NovelExportField.scenes: context.t(LocaleKeys.screenplayScenes),
      NovelExportField.author: context.t(LocaleKeys.libraryAuthorName),
      NovelExportField.category: context.t(LocaleKeys.libraryCategory),
      NovelExportField.tags: context.t(LocaleKeys.libraryTags),
      NovelExportField.description: context.t(LocaleKeys.commonDescription),
      NovelExportField.identity: context.t(
        LocaleKeys.assetExportFieldKeys['identity']!,
      ),
      NovelExportField.age: context.t(LocaleKeys.assetExportFieldKeys['age']!),
      NovelExportField.motivation: context.t(
        LocaleKeys.assetExportFieldKeys['motivation']!,
      ),
      NovelExportField.personality: context.t(
        LocaleKeys.assetExportFieldKeys['personality']!,
      ),
      NovelExportField.characterArc: context.t(
        LocaleKeys.assetExportFieldKeys['arc']!,
      ),
      NovelExportField.biography: context.t(
        LocaleKeys.assetExportFieldKeys['biography']!,
      ),
      NovelExportField.currentState: context.t(
        LocaleKeys.workspaceCharacterDescriptionLabel,
      ),
      NovelExportField.setup: context.t(LocaleKeys.commonSetup),
      NovelExportField.payoff: context.t(LocaleKeys.commonPayoff),
      NovelExportField.chapterCount: context.t(
        LocaleKeys.workspaceOutlineBeatChapterCountLabel,
      ),
    },
    storyOutline: context.t(
      isScreenplay
          ? LocaleKeys.screenplayOutline
          : LocaleKeys.workspaceOutlines,
    ),
    chapterOutline: context.t(LocaleKeys.workspaceChapterOutline),
    untitled: context.t(LocaleKeys.commonUntitled),
    untitledBeat: context.t(LocaleKeys.workspaceOutlineUntitledBeat),
    fieldSeparator: Localizations.localeOf(context).languageCode == 'zh'
        ? '：'
        : ': ',
  );
}

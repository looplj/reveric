// 职责: 通用资料条目编辑器 — 编辑世界观、素材、技能、物品、势力等标题与正文内容，及物品照片管理。
// 关联文件:
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/components/reveric_button.dart
//   lib/desktop/widgets/workspace/novel_workspace_panel.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/components/reveric_text_field.dart
//   lib/shared/widgets/md/reveric_markdown_editor.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/hooks.md
import 'dart:io';
import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_text_field.dart';
import '../../../shared/database/app_database.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/cover_style.dart';
import '../../../shared/services/ai/chat.dart';
import '../../../shared/services/name_generator_service.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/media_asset_image.dart';
import '../../../shared/widgets/md/reveric_markdown_editor.dart';
import '../../../shared/widgets/name_assistant_button.dart';
import '../agent_management/agent_model_settings_page.dart';
import '../../../shared/components/reveric_dialog.dart';
import '../../../shared/components/reveric_button.dart';

const _imageStyles = [
  (
    style: CoverStyle.cinematic,
    label: LocaleKeys.editorCoverStyleCinematic,
    icon: RevericIcons.movie_outlined,
  ),
  (
    style: CoverStyle.illustration,
    label: LocaleKeys.editorCoverStyleIllustration,
    icon: RevericIcons.brush_outlined,
  ),
  (
    style: CoverStyle.eastern,
    label: LocaleKeys.editorCoverStyleEastern,
    icon: RevericIcons.temple_buddhist_outlined,
  ),
  (
    style: CoverStyle.minimal,
    label: LocaleKeys.editorCoverStyleMinimal,
    icon: RevericIcons.crop_square_rounded,
  ),
];

Future<String?> _showItemImageStyleDialog({
  required BuildContext context,
  required String title,
  required String confirmLabel,
}) {
  final extraController = TextEditingController();
  final customStyleController = TextEditingController();
  CoverStyle? selectedStyle;
  String? selectedLabel;
  var isCustom = false;
  return showRevericDialog<String>(
    context: context,
    builder: (context) {
      final colors = RevericTheme.colorsOf(context);
      final typo = RevericTheme.typographyOf(context);
      return StatefulBuilder(
        builder: (context, setDialogState) {
          final canConfirm =
              selectedStyle != null ||
              (isCustom && customStyleController.text.trim().isNotEmpty);
          return RevericDialog(
            title: title,
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.t(LocaleKeys.editorCoverStyle),
                    style: typo.uiSemibold.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: RevericSpacing.md),
                  Wrap(
                    spacing: RevericSpacing.md,
                    runSpacing: RevericSpacing.md,
                    children: [
                      ..._imageStyles.map((option) {
                        final isSelected = selectedStyle == option.style;
                        return GestureDetector(
                          onTap: () {
                            setDialogState(() {
                              selectedStyle = option.style;
                              selectedLabel = context.t(option.label);
                              isCustom = false;
                            });
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.symmetric(
                              horizontal: RevericSpacing.lg,
                              vertical: RevericSpacing.sm,
                            ),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? colors.accent.withValues(alpha: 0.15)
                                  : colors.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(
                                RevericRadius.large,
                              ),
                              border: Border.all(
                                color: isSelected
                                    ? colors.accent
                                    : colors.borderSubtle,
                                width: isSelected ? 1.5 : 1,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                RevericIcon(
                                  option.icon,
                                  size: 16,
                                  color: isSelected
                                      ? colors.accent
                                      : colors.textSecondary,
                                ),
                                const SizedBox(width: RevericSpacing.sm),
                                Text(
                                  context.t(option.label),
                                  style: typo.uiSmall.copyWith(
                                    color: isSelected
                                        ? colors.accent
                                        : colors.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                      GestureDetector(
                        onTap: () {
                          setDialogState(() {
                            isCustom = true;
                            selectedStyle = null;
                            selectedLabel = null;
                          });
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.symmetric(
                            horizontal: RevericSpacing.lg,
                            vertical: RevericSpacing.md,
                          ),
                          decoration: BoxDecoration(
                            color: isCustom
                                ? colors.accent.withValues(alpha: 0.1)
                                : colors.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(
                              RevericRadius.large,
                            ),
                            border: Border.all(
                              color: isCustom ? colors.accent : colors.border,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              RevericIcon(
                                RevericIcons.edit_outlined,
                                size: 16,
                                color: isCustom
                                    ? colors.accent
                                    : colors.textSecondary,
                              ),
                              const SizedBox(width: RevericSpacing.sm),
                              Text(
                                context.t(LocaleKeys.agentRoleCustom),
                                style: typo.uiSemibold.copyWith(
                                  color: isCustom
                                      ? colors.accent
                                      : colors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (isCustom) ...[
                    const SizedBox(height: RevericSpacing.lg),
                    RevericTextField(
                      controller: customStyleController,
                      onChanged: (_) => setDialogState(() {}),
                      hintText: context.t(
                        LocaleKeys.editorCoverStyleCustomHint,
                      ),
                      multiline: true,
                      minLines: 1,
                      maxLines: 2,
                    ),
                  ],
                  const SizedBox(height: RevericSpacing.xl),
                  Text(
                    context.t(LocaleKeys.editorCoverExtraRequirements),
                    style: typo.uiSemibold.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: RevericSpacing.md),
                  RevericTextField(
                    controller: extraController,
                    hintText: context.t(LocaleKeys.editorCoverExtraHint),
                    multiline: true,
                    minLines: 2,
                    maxLines: 4,
                  ),
                ],
              ),
            ),
            width: 400,
            actions: [
              RevericButton.secondary(
                label: context.t(LocaleKeys.commonCancel),
                onPressed: () => Navigator.of(context).pop(),
              ),
              RevericButton.primary(
                label: confirmLabel,
                onPressed: canConfirm
                    ? () {
                        final style = isCustom
                            ? customStyleController.text.trim()
                            : selectedLabel ?? '';
                        final extra = extraController.text.trim();
                        final result = [
                          if (style.isNotEmpty) '风格：$style',
                          if (extra.isNotEmpty) '额外要求：$extra',
                        ].join('\n');
                        Navigator.of(context).pop(result);
                      }
                    : null,
              ),
            ],
          );
        },
      );
    },
  );
}

class WorkspaceEntryEditor extends HookWidget {
  const WorkspaceEntryEditor({
    super.key,
    required this.selectedItemId,
    this.isCreating = false,
    required this.entries,
    required this.title,
    required this.description,
    required this.typeLabel,
    this.emptyStateTitle,
    this.emptyStateMessage,
    required this.categoryHint,
    required this.newEntryLabel,
    required this.titleController,
    required this.contentController,
    required this.categoryController,
    required this.titleFocusNode,
    required this.contentFocusNode,
    required this.categoryFocusNode,
    this.titleErrorText,
    this.showMetadataFields = true,
    required this.onCreateEntry,
    this.editorFontFamily = 'Georgia',
    this.editorFontSize = 16,
    this.nameAssistantAiService,
    this.novel,
    this.nameType,
    this.photos,
    this.isPhotoAdding = false,
    this.isImageGenerationConfigured = false,
    this.onAddPhoto,
    this.onRemovePhoto,
    this.onGeneratePhoto,
  });

  final String? selectedItemId;
  final bool isCreating;
  final List<dynamic> entries;
  final String title;
  final String description;
  final String typeLabel;

  /// 空状态整句覆盖；为 null 时按 [typeLabel] 走通用插值文案。
  final String? emptyStateTitle;
  final String? emptyStateMessage;
  final String categoryHint;
  final String newEntryLabel;
  final TextEditingController titleController;
  final TextEditingController contentController;
  final TextEditingController categoryController;
  final FocusNode titleFocusNode;
  final FocusNode contentFocusNode;
  final FocusNode categoryFocusNode;
  final String? titleErrorText;

  /// 为 false 时不在主编辑区展示标题/分类（改由侧栏右键弹框编辑）。
  final bool showMetadataFields;
  final VoidCallback onCreateEntry;
  final String editorFontFamily;
  final int editorFontSize;
  final AiClient? nameAssistantAiService;
  final Novel? novel;
  final NameType? nameType;

  /// 照片的图片资产 id。
  final List<String>? photos;
  final bool isPhotoAdding;
  final bool isImageGenerationConfigured;
  final Future<void> Function()? onAddPhoto;
  final Future<void> Function(String path)? onRemovePhoto;
  final void Function(String prompt, String itemId)? onGeneratePhoto;

  @override
  Widget build(BuildContext context) {
    final pageScrollController = useScrollController();

    if (selectedItemId == null && !isCreating) {
      return _EmptyEntryEditorState(
        hasEntries: entries.isNotEmpty,
        typeLabel: typeLabel,
        actionLabel: newEntryLabel,
        onCreate: onCreateEntry,
        title: emptyStateTitle,
        message: emptyStateMessage,
      );
    }

    final currentEntry = _selectedEntry();
    if (currentEntry != null &&
        currentEntry is Document &&
        currentEntry.isFolder) {
      return _FolderPlaceholder(folder: currentEntry);
    }

    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Scrollbar(
      controller: pageScrollController,
      thumbVisibility: true,
      child: CustomScrollView(
        controller: pageScrollController,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.x6l,
              RevericSpacing.x4l,
              RevericSpacing.x6l,
              0,
            ),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        title,
                        style: typo.heading2.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: RevericSpacing.sm),
                  Text(
                    description,
                    style: typo.bodySmall.copyWith(color: colors.textMuted),
                  ),
                  if (showMetadataFields) ...[
                    const SizedBox(height: RevericSpacing.x4l),
                    _EntryTitleField(
                      controller: titleController,
                      focusNode: titleFocusNode,
                      errorText: titleErrorText,
                      suffixIcon: nameType != null
                          ? NameAssistantButton(
                              nameType: nameType!,
                              aiClient: nameAssistantAiService,
                              novel: novel,
                              entityDescription: contentController.text.trim(),
                              onNameGenerated: (name) {
                                titleController.text = name;
                                titleController.selection =
                                    TextSelection.fromPosition(
                                      TextPosition(offset: name.length),
                                    );
                              },
                            )
                          : null,
                    ),
                    const SizedBox(height: RevericSpacing.x2l),
                    _EntryCategoryField(
                      controller: categoryController,
                      focusNode: categoryFocusNode,
                      hintText: categoryHint,
                    ),
                  ],
                  if (photos != null) ...[
                    const SizedBox(height: RevericSpacing.x2l),
                    _ItemPhotoSection(
                      photos: photos!,
                      isAdding: isPhotoAdding,
                      isImageGenerationConfigured: isImageGenerationConfigured,
                      onAdd: onAddPhoto,
                      onRemove: onRemovePhoto,
                      onGenerate: isCreating || onGeneratePhoto == null
                          ? null
                          : _handleGeneratePhoto,
                    ),
                  ],
                  SizedBox(
                    height: showMetadataFields || photos != null
                        ? RevericSpacing.x2l
                        : RevericSpacing.x4l,
                  ),
                  Text(
                    context.t(LocaleKeys.commonContent),
                    style: typo.uiSemibold.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: RevericSpacing.sm),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.x6l,
              0,
              RevericSpacing.x6l,
              RevericSpacing.x6l,
            ),
            sliver: SliverLayoutBuilder(
              builder: (context, sliverConstraints) {
                final remainingHeight =
                    sliverConstraints.viewportMainAxisExtent -
                    sliverConstraints.precedingScrollExtent -
                    RevericSpacing.x6l;
                final editorHeight = math.max(360.0, remainingHeight);

                return SliverToBoxAdapter(
                  child: SizedBox(
                    height: editorHeight,
                    child: RevericMarkdownEditor(
                      controller: contentController,
                      focusNode: contentFocusNode,
                      hintText: context.t(LocaleKeys.workspaceEntryContentHint),
                      fontFamily: editorFontFamily,
                      fontSize: editorFontSize,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _handleGeneratePhoto(BuildContext context) {
    if (onGeneratePhoto == null || selectedItemId == null) {
      return;
    }
    if (!isImageGenerationConfigured) {
      showAgentModelSettingsDialog(context);
      return;
    }
    _showItemImageStyleDialog(
      context: context,
      title: context.t(LocaleKeys.workspaceItemGeneratePhoto),
      confirmLabel: context.t(LocaleKeys.toolNameGeneratePhoto),
    ).then((stylePrompt) {
      if (stylePrompt == null ||
          stylePrompt.isEmpty ||
          selectedItemId == null) {
        return;
      }
      final prompt = '请为物品「${titleController.text}」生成照片或插画。\n\n$stylePrompt';
      onGeneratePhoto!(prompt, selectedItemId!);
    });
  }

  dynamic _selectedEntry() {
    for (final entry in entries) {
      if (entry is Document && entry.id == selectedItemId) {
        return entry;
      }
      if (entry is Item && entry.id == selectedItemId) {
        return entry;
      }
    }
    return null;
  }
}

class _EmptyEntryEditorState extends StatelessWidget {
  const _EmptyEntryEditorState({
    required this.hasEntries,
    required this.typeLabel,
    required this.actionLabel,
    required this.onCreate,
    this.title,
    this.message,
  });

  final bool hasEntries;
  final String typeLabel;
  final String actionLabel;
  final VoidCallback onCreate;

  /// 整句覆盖 — 图鉴等合并入口不能套用 `{type}` 插值（「新建一个图鉴」不通）。
  /// 为 null 时回落到按 [typeLabel] 插值的通用文案。
  final String? title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(RevericSpacing.x6l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevericIcon(
              RevericIcons.description_outlined,
              color: colors.textSubtle,
              size: 32,
            ),
            const SizedBox(height: RevericSpacing.lg),
            Text(
              title ??
                  context.t(
                    LocaleKeys.workspaceNoEntrySelected,
                    namedArgs: {'type': typeLabel},
                  ),
              style: typo.uiSemibold.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: RevericSpacing.sm),
            Text(
              message ??
                  (hasEntries
                      ? context.t(
                          LocaleKeys.workspaceSelectEntryToEdit,
                          namedArgs: {'type': typeLabel},
                        )
                      : context.t(
                          LocaleKeys.workspaceCreateFirstEntry,
                          namedArgs: {'type': typeLabel},
                        )),
              style: typo.ui.copyWith(color: colors.textMuted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: RevericSpacing.x2l),
            FilledButton(onPressed: onCreate, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}

class _FolderPlaceholder extends StatelessWidget {
  const _FolderPlaceholder({required this.folder});

  final Document folder;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final folderName = folder.title.isEmpty
        ? tr(LocaleKeys.workspaceUntitledFolder)
        : folder.title;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RevericIcon(
            RevericIcons.folder_outlined,
            size: 64,
            color: colors.textSubtle,
          ),
          const SizedBox(height: RevericSpacing.x2l),
          Text(
            folderName,
            style: typo.heading2.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: RevericSpacing.md),
          Text(
            tr(LocaleKeys.workspaceFolder),
            style: typo.ui.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: RevericSpacing.x4l),
          Text(
            tr(LocaleKeys.workspaceFolderCreateHint),
            style: typo.uiSmall.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _EntryTitleField extends StatelessWidget {
  const _EntryTitleField({
    required this.controller,
    required this.focusNode,
    this.errorText,
    this.suffixIcon,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String? errorText;
  final Widget? suffixIcon;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t(LocaleKeys.commonTitle),
          style: typo.uiTinySemibold.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: RevericSpacing.xs),
        RevericTextField(
          controller: controller,
          focusNode: focusNode,
          hintText: context.t(LocaleKeys.workspaceEntryTitleHint),
          errorText: errorText,
          fillColor: colors.surfaceContainerHigh,
          suffixIcon: suffixIcon,
        ),
      ],
    );
  }
}

class _EntryCategoryField extends StatelessWidget {
  const _EntryCategoryField({
    required this.controller,
    required this.focusNode,
    required this.hintText,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t(LocaleKeys.workspaceEntryCategoryLabel),
          style: typo.uiTinySemibold.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: RevericSpacing.xs),
        RevericTextField(
          controller: controller,
          focusNode: focusNode,
          hintText: hintText,
          fillColor: colors.surfaceContainerHigh,
        ),
      ],
    );
  }
}

class _ItemPhotoSection extends StatelessWidget {
  const _ItemPhotoSection({
    required this.photos,
    required this.isAdding,
    required this.isImageGenerationConfigured,
    this.onAdd,
    this.onRemove,
    this.onGenerate,
  });

  final List<String> photos;
  final bool isAdding;
  final bool isImageGenerationConfigured;
  final Future<void> Function()? onAdd;
  final Future<void> Function(String path)? onRemove;
  final void Function(BuildContext context)? onGenerate;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      padding: const EdgeInsets.all(RevericSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(RevericRadius.xl),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  context.t(LocaleKeys.workspaceItemPhotos),
                  style: typo.uiSemibold.copyWith(color: colors.textSecondary),
                ),
              ),
              if (onGenerate != null) ...[
                Tooltip(
                  message: isImageGenerationConfigured
                      ? ''
                      : context.t(LocaleKeys.aiNoImageModelConfigured),
                  child: TextButton.icon(
                    onPressed: () => onGenerate!(context),
                    icon: RevericIcon(
                      RevericIcons.auto_awesome_outlined,
                      size: 14,
                      color: colors.accent,
                    ),
                    label: Text(
                      context.t(LocaleKeys.workspaceItemGeneratePhoto),
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSmall.copyWith(color: colors.accent),
                    ),
                    style: TextButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(
                        horizontal: RevericSpacing.sm,
                      ),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: RevericSpacing.md),
          SizedBox(
            height: 110,
            child: photos.isEmpty && !isAdding
                ? _EmptyItemPhotosState(onAdd: onAdd)
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: photos.length + 1,
                    separatorBuilder: (_, _) =>
                        const SizedBox(width: RevericSpacing.sm),
                    itemBuilder: (context, index) {
                      if (index < photos.length) {
                        return _ItemPhotoThumbnail(
                          assetId: photos[index],
                          onRemove: () => onRemove?.call(photos[index]),
                        );
                      }
                      return _AddItemPhotoButton(
                        isAdding: isAdding,
                        onAdd: onAdd,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _EmptyItemPhotosState extends StatelessWidget {
  const _EmptyItemPhotosState({this.onAdd});

  final Future<void> Function()? onAdd;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Center(
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: RevericSpacing.sm,
        runSpacing: RevericSpacing.xs,
        children: [
          OutlinedButton.icon(
            onPressed: onAdd,
            icon: RevericIcon(
              RevericIcons.add_rounded,
              size: 16,
              color: colors.accent,
            ),
            label: Text(
              context.t(LocaleKeys.workspaceItemPickPhoto),
              overflow: TextOverflow.ellipsis,
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: colors.accent,
              side: BorderSide(color: colors.accent),
              minimumSize: const Size(0, RevericSizes.buttonHeightSm),
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.lg,
              ),
              textStyle: typo.uiSmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemPhotoThumbnail extends ConsumerWidget {
  const _ItemPhotoThumbnail({required this.assetId, required this.onRemove});

  final String assetId;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final resolved = watchMediaAssetFile(ref, assetId);
    final exists = resolved != null;

    return GestureDetector(
      onTap: exists ? () => _showImagePreview(context, resolved) : null,
      child: SizedBox(
        width: 88,
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(RevericRadius.medium),
              child: Container(
                color: colors.surfaceDim,
                height: 110,
                child: exists
                    ? Image.file(File(resolved), fit: BoxFit.cover)
                    : Center(
                        child: RevericIcon(
                          RevericIcons.broken_image_outlined,
                          color: colors.textSubtle,
                          size: 24,
                        ),
                      ),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: Tooltip(
                message: context.t(LocaleKeys.workspaceItemRemovePhoto),
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: IconButton(
                    onPressed: onRemove,
                    icon: RevericIcon(
                      RevericIcons.close_rounded,
                      size: 14,
                      color: colors.warningText,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    style: IconButton.styleFrom(
                      backgroundColor: colors.surface.withValues(alpha: 0.92),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddItemPhotoButton extends StatelessWidget {
  const _AddItemPhotoButton({required this.isAdding, this.onAdd});

  final bool isAdding;
  final Future<void> Function()? onAdd;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return SizedBox(
      width: 88,
      child: Material(
        color: colors.surfaceDim,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        child: InkWell(
          borderRadius: BorderRadius.circular(RevericRadius.medium),
          onTap: isAdding ? null : () => onAdd?.call(),
          child: Center(
            child: isAdding
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(colors.accent),
                    ),
                  )
                : RevericIcon(
                    RevericIcons.add_rounded,
                    size: 28,
                    color: colors.textMuted,
                  ),
          ),
        ),
      ),
    );
  }
}

void _showImagePreview(BuildContext context, String imagePath) {
  showRevericDialog(
    context: context,
    barrierColor: Colors.black87,
    builder: (context) {
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(RevericSpacing.x4l),
        child: Stack(
          children: [
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(RevericRadius.xl),
                child: InteractiveViewer(
                  child: Image.file(
                    File(imagePath),
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          RevericIcon(
                            RevericIcons.broken_image_outlined,
                            size: 64,
                          ),
                          const SizedBox(height: RevericSpacing.md),
                          Text('无法加载图片'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: RevericIcon(
                  RevericIcons.close_rounded,
                  size: 24,
                  color: Colors.white,
                ),
                style: IconButton.styleFrom(backgroundColor: Colors.black38),
              ),
            ),
          ],
        ),
      );
    },
  );
}

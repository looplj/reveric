// 职责: 编辑移动端资料与图鉴照片，串行防抖保存草稿并在保存失败时保留编辑页。
// 关联文件:
//   lib/mobile/pages/entry_editor_save.dart
//   lib/mobile/widgets/compendium_photos.dart
//   lib/mobile/widgets/section_panel.dart
//   lib/mobile/widgets/detail_scaffold.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/widgets/md/reveric_markdown_editor.dart
//   lib/shared/theme/theme.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
//   .agents/rules/error-handling.md
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/database/novel_content_database.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/logger/app_logger.dart';
import '../../shared/utils/text_input_composing.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/md/reveric_markdown_editor.dart';
import '../widgets/detail_scaffold.dart';
import '../widgets/editor_app_bar.dart';
import '../widgets/compendium_photos.dart';
import 'entry_editor_save.dart';

final _log = AppLogger.forModule('MobileEntryEditor');

/// 本期可用的简单分区（标题 + markdown 正文同一套表单）。
/// lore/materials 落 documents 表，skills/items/factions/creatures 落 items 表。
enum MobileEditorSection { lore, materials, skills, items, factions, creatures }

extension MobileEditorSectionMeta on MobileEditorSection {
  /// 数据是否落在 documents 表（否则落在 items 表）。
  bool get isDocument =>
      this == MobileEditorSection.lore || this == MobileEditorSection.materials;

  /// documents/items 表中的 type 判别值。
  String get typeValue => switch (this) {
    MobileEditorSection.lore => documentTypeLore,
    MobileEditorSection.materials => 'material',
    MobileEditorSection.skills => entityTypeSkill,
    MobileEditorSection.items => 'item',
    MobileEditorSection.factions => 'faction',
    MobileEditorSection.creatures => 'creature',
  };

  String get labelKey => switch (this) {
    MobileEditorSection.lore => LocaleKeys.workspaceLore,
    MobileEditorSection.materials => LocaleKeys.workspaceMaterials,
    MobileEditorSection.skills => LocaleKeys.workspaceSkills,
    MobileEditorSection.items => LocaleKeys.workspaceItems,
    MobileEditorSection.factions => LocaleKeys.workspaceFactions,
    MobileEditorSection.creatures => LocaleKeys.workspaceCreatures,
  };

  String get hintKey => switch (this) {
    MobileEditorSection.lore => LocaleKeys.workspaceLoreHint,
    MobileEditorSection.materials => LocaleKeys.workspaceMaterialsHint,
    MobileEditorSection.skills => LocaleKeys.workspaceSkillsHint,
    MobileEditorSection.items => LocaleKeys.workspaceItemsHint,
    MobileEditorSection.factions => LocaleKeys.workspaceFactionsHint,
    MobileEditorSection.creatures => LocaleKeys.workspaceCreaturesHint,
  };

  String get newLabelKey => switch (this) {
    MobileEditorSection.lore => LocaleKeys.workspaceNewWorldbuilding,
    MobileEditorSection.materials => LocaleKeys.workspaceNewMaterial,
    MobileEditorSection.skills => LocaleKeys.workspaceNewSkill,
    MobileEditorSection.items => LocaleKeys.workspaceNewItem,
    MobileEditorSection.factions => LocaleKeys.workspaceNewFaction,
    MobileEditorSection.creatures => LocaleKeys.workspaceNewCreature,
  };

  String get categoryHintKey => switch (this) {
    MobileEditorSection.lore => LocaleKeys.workspaceEntryCategoryLoreHint,
    MobileEditorSection.materials =>
      LocaleKeys.workspaceEntryCategoryMaterialsHint,
    MobileEditorSection.skills => LocaleKeys.workspaceEntryCategorySkillsHint,
    MobileEditorSection.items => LocaleKeys.workspaceEntryCategoryItemsHint,
    MobileEditorSection.factions =>
      LocaleKeys.workspaceEntryCategoryFactionsHint,
    MobileEditorSection.creatures =>
      LocaleKeys.workspaceEntryCategoryCreaturesHint,
  };

  /// 列表/详情页左侧图标（`RevericIcons` 常量）。
  String get listIcon => switch (this) {
    MobileEditorSection.lore => RevericIcons.public,
    MobileEditorSection.materials => RevericIcons.folder_outlined,
    MobileEditorSection.skills => RevericIcons.lightning,
    MobileEditorSection.items => RevericIcons.inventory_2_outlined,
    MobileEditorSection.factions => RevericIcons.groups_outlined,
    MobileEditorSection.creatures => RevericIcons.bug_beetle_outlined,
  };

  Color listTint(RevericColors colors) => switch (this) {
    MobileEditorSection.lore => colors.accentWarm.withValues(alpha: 0.16),
    MobileEditorSection.materials => colors.accent.withValues(alpha: 0.13),
    MobileEditorSection.skills => colors.accent.withValues(alpha: 0.14),
    MobileEditorSection.items => colors.accentAmber.withValues(alpha: 0.14),
    MobileEditorSection.factions => colors.accent.withValues(alpha: 0.12),
    MobileEditorSection.creatures => colors.success.withValues(alpha: 0.12),
  };
}

/// 通用条目编辑页（按 section + id 加载）：从对应本地列表取条目后渲染编辑视图，
/// 内部按 [MobileEditorSectionMeta.isDocument] 决定加载/保存走 documents 还是 items。
class MobileEntryEditorPage extends ConsumerWidget {
  const MobileEntryEditorPage({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.section,
    required this.entryId,
  });

  final String databasePath;
  final String novelId;
  final MobileEditorSection section;
  final String entryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(novelContentServiceProvider(databasePath));

    String? title;
    String? content;
    Item? selectedItem;
    String category = '';
    if (section.isDocument) {
      final docs = ref
          .watch(documentsProvider(path: databasePath, type: section.typeValue))
          .asData
          ?.value;
      final doc = docs?.cast<Document?>().firstWhere(
        (d) => d?.id == entryId,
        orElse: () => null,
      );
      title = doc?.title;
      content = doc?.content;
      category = doc?.category ?? '';
    } else {
      final items = ref
          .watch(itemsProvider(path: databasePath, type: section.typeValue))
          .asData
          ?.value;
      final item = items?.cast<Item?>().firstWhere(
        (i) => i?.id == entryId,
        orElse: () => null,
      );
      selectedItem = item;
      title = item?.title;
      content = item?.content;
      category = item?.category ?? '';
    }

    if (title == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return MobileEntryEditorView(
      key: ValueKey(entryId),
      sectionLabel: context.t(section.labelKey),
      initialTitle: title,
      initialContent: content ?? '',
      initialCategory: category,
      titleHint: context.t(LocaleKeys.workspaceEntryTitleHint),
      contentHint: context.t(LocaleKeys.workspaceEntryContentHint),
      categoryHint: context.t(section.categoryHintKey),
      photos: selectedItem == null
          ? null
          : MobileCompendiumPhotos(
              novelId: novelId,
              databasePath: databasePath,
              item: selectedItem,
            ),
      onSave: (t, c, cat) async {
        try {
          if (section.isDocument) {
            await service.documentsService.updateDocument(
              id: entryId,
              title: t,
              content: c,
              category: cat,
            );
          } else {
            await service.updateItem(
              entryId: entryId,
              title: t,
              content: c,
              category: cat,
            );
          }
        } catch (error, stackTrace) {
          _log.error(
            '[DB] table=${section.isDocument ? 'documents' : 'items'} '
            'operation=UPDATE id=$entryId',
            error: error,
            stackTrace: stackTrace,
          );
          rethrow;
        }
      },
    );
  }
}

/// 通用条目编辑视图：标题 + 正文，编辑即防抖自动保存，退出时冲刷未落盘改动。
class MobileEntryEditorView extends HookWidget {
  const MobileEntryEditorView({
    super.key,
    required this.sectionLabel,
    required this.initialTitle,
    required this.initialContent,
    required this.initialCategory,
    required this.titleHint,
    required this.contentHint,
    required this.categoryHint,
    required this.onSave,
    this.photos,
  });

  final String sectionLabel;
  final String initialTitle;
  final String initialContent;
  final String initialCategory;
  final String titleHint;
  final String contentHint;
  final String categoryHint;
  final Widget? photos;
  final Future<void> Function(String title, String content, String category)
  onSave;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);

    final titleController = useTextEditingController(text: initialTitle);
    final contentController = useTextEditingController(text: initialContent);
    final categoryController = useTextEditingController(text: initialCategory);
    final contentFocusNode = useFocusNode();
    final undoController = useMemoized(UndoHistoryController.new);
    useEffect(() => undoController.dispose, const []);
    final saver = useMemoized(
      () => EntryEditorSaveController(
        onSave: onSave,
        initialValues: (
          title: initialTitle.trim(),
          content: initialContent,
          category: initialCategory,
        ),
      ),
      const [],
    );
    saver.onSave = onSave;
    useEffect(() => saver.dispose, [saver]);
    useListenable(saver);
    final navigating = useRef(false);

    bool hasComposingText() =>
        isTextInputComposing(titleController) ||
        isTextInputComposing(contentController) ||
        isTextInputComposing(categoryController);

    void scheduleSave() {
      if (hasComposingText()) {
        return;
      }
      saver.update((
        title: titleController.text.trim(),
        content: contentController.text,
        category: categoryController.text,
      ));
    }

    useOnListenableChange(titleController, scheduleSave);
    useOnListenableChange(contentController, scheduleSave);
    useOnListenableChange(categoryController, scheduleSave);
    useListenableSelector(
      contentController,
      () => isTextInputComposing(contentController),
    );
    useListenableSelector(
      categoryController,
      () => isTextInputComposing(categoryController),
    );

    Future<void> leave() async {
      if (navigating.value || hasComposingText()) {
        return;
      }
      navigating.value = true;
      try {
        scheduleSave();
        if (await saver.flush() && context.mounted) {
          final navigator = Navigator.of(context);
          if (navigator.canPop()) {
            navigator.pop();
          }
        }
      } finally {
        navigating.value = false;
      }
    }

    useListenable(titleController);

    final displayTitle = titleController.text.trim().isEmpty
        ? context.t(LocaleKeys.commonUntitled)
        : titleController.text.trim();

    return PopScope<void>(
      canPop: !saver.isDirty && !saver.isSaving && !hasComposingText(),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          unawaited(leave());
        }
      },
      child: Scaffold(
        backgroundColor: colors.canvas,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              MobileEditorAppBar(
                title: displayTitle,
                subtitle: sectionLabel,
                saving: saver.isSaving,
                savedAt: saver.savedAt,
                onBack: leave,
                undoController: undoController,
              ),
              Expanded(
                child: CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        mobileDetailBodyPadding.left,
                        mobileDetailBodyPadding.top,
                        mobileDetailBodyPadding.right,
                        0,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          children: [
                            MobileDetailTitleField(
                              controller: titleController,
                              undoController: undoController,
                              hintText: titleHint,
                              errorText: saver.failed
                                  ? context.t(LocaleKeys.commonSaveFailed)
                                  : null,
                            ),
                            const SizedBox(height: RevericSpacing.lg),
                            MobileDetailFieldList(
                              children: [
                                MobileDetailFieldRow(
                                  label: context.t(
                                    LocaleKeys.workspaceEntryCategoryLabel,
                                  ),
                                  child: _EntryCategoryInput(
                                    controller: categoryController,
                                    hintText: categoryHint,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: RevericSpacing.x2l),
                            if (photos != null) ...[
                              photos!,
                              const SizedBox(height: RevericSpacing.x2l),
                            ],
                          ],
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        mobileDetailBodyPadding.left,
                        0,
                        mobileDetailBodyPadding.right,
                        mobileDetailBodyPadding.bottom,
                      ),
                      sliver: SliverLayoutBuilder(
                        builder: (context, sliverConstraints) {
                          final remainingHeight =
                              sliverConstraints.viewportMainAxisExtent -
                              sliverConstraints.precedingScrollExtent -
                              mobileDetailBodyPadding.bottom;
                          final editorHeight = math.max(360.0, remainingHeight);

                          return SliverToBoxAdapter(
                            child: SizedBox(
                              height: editorHeight,
                              child: RevericMarkdownEditor(
                                controller: contentController,
                                focusNode: contentFocusNode,
                                undoController: undoController,
                                hintText: contentHint,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 条目 meta 行的右对齐单行分类输入，无边框贴合 `.srow` 值样式。
class _EntryCategoryInput extends StatelessWidget {
  const _EntryCategoryInput({required this.controller, required this.hintText});

  final TextEditingController controller;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return TextField(
      controller: controller,
      textAlign: TextAlign.right,
      style: typo.ui.copyWith(color: colors.textPrimary),
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: EdgeInsets.zero,
        hintText: hintText,
        hintStyle: typo.ui.copyWith(color: colors.textSubtle),
      ),
    );
  }
}

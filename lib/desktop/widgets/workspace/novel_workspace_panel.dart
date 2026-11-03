// 职责: 小说工作区主面板 — 按当前工作区选择组织章节、资料、角色、伏笔、大纲等编辑 UI。
// 关联文件:
//   lib/desktop/widgets/workspace/chapter_editor.dart
//   lib/desktop/widgets/workspace/chapter_outline_window.dart
//   lib/desktop/features/reading/reading_window.dart
//   lib/desktop/widgets/workspace/chapter_preview_dialog.dart
//   lib/shared/widgets/chapter_copy_replace_panel.dart
//   lib/desktop/widgets/workspace/volume_editor.dart
//   lib/desktop/widgets/workspace/character_profile_editor_region.dart
//   lib/desktop/widgets/workspace/foreshadowing_editor.dart
//   lib/desktop/widgets/entity_graph_panel.dart
//   lib/desktop/widgets/workspace/workspace_item_editor.dart
//   lib/desktop/widgets/workspace/outline_editor.dart
//   lib/desktop/widgets/workspace/outline_global_view.dart
//   lib/desktop/features/map/map_studio_page.dart
//   lib/shared/models/novel_workspace.dart
//   lib/shared/models/ai_shortcut_action.dart
//   lib/shared/providers/ai_shortcut_action_providers.dart
//   lib/shared/utils/chapter_text_formatter.dart
//   lib/shared/services/chapter_format_all.dart
//   lib/shared/widgets/confirm_dialog.dart
//   lib/shared/widgets/format_all_progress_dialog.dart
//   lib/shared/utils/number_format.dart
//   lib/shared/utils/text_unit_count.dart
//   lib/desktop/widgets/settings/settings_dialog.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/agent_shortcut.json
//   assets/translations/zh-CN/agent_shortcut.json
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
import '../../../shared/app_config.dart';

import '../../features/production/region.dart';
import '../../features/production/status.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_context_menu.dart';
import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/database/app_database.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/providers/canvas_providers.dart';
import '../../../shared/providers/production_view.dart';
import '../../../shared/providers/screenplay_providers.dart';
import '../../../shared/providers/screenplay_workspace_state_provider.dart';
import '../../../shared/providers/workspace_navigation_provider.dart';
import '../../../shared/models/screenplay_workspace_state.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/services/ai/chat.dart';
import '../../../shared/services/chapter_format_all.dart';
import '../../../shared/services/working_overlay.dart';
import '../../../shared/services/name_generator_service.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/ai_shortcut_action.dart';
import '../../../shared/models/content_kind.dart';
import '../../../shared/models/novel_workspace.dart';
import '../../../shared/models/outline.dart';
import '../../../shared/providers/ai_shortcut_action_providers.dart';
import '../../../shared/providers/settings_providers.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/utils/chapter_text_formatter.dart';
import '../../../shared/utils/number_format.dart';
import '../../../shared/utils/text_unit_count.dart';
import '../../../shared/widgets/app_background.dart';
import '../../../shared/widgets/chapter_copy_replace_panel.dart';
import '../../../shared/widgets/confirm_dialog.dart';
import '../../../shared/widgets/foreshadowing/position_links.dart';
import '../../../shared/widgets/format_all_progress_dialog.dart';
import '../../../shared/widgets/frame_safe_text_editing_value_builder.dart';
import 'chapter_editor.dart';
import 'chapter_outline_window.dart';
import '../../features/reading/reading_window.dart';
import '../detached_window.dart';
import 'chapter_preview_dialog.dart';
import 'story_progress_panel.dart';
import '../desktop_window_frame.dart';
import '../entity_graph_panel.dart';
import 'foreshadowing_editor.dart';
import '../history/resource_history_button.dart';
import '../../features/canvas/widgets/canvas_region.dart';
import '../../features/map/map_studio_page.dart';
import '../../features/screenplay/outline.dart';
import '../../features/screenplay/overview.dart';
import '../../features/screenplay/scenes.dart';
import '../../features/screenplay/script.dart';
import '../settings/settings_dialog.dart';
import 'novel_description_editor.dart';
import 'novel_overview.dart';
import 'outline_global_view.dart';
import 'outlines_landing_state.dart';
import 'outline_editor.dart';
import 'volume_editor.dart';
import 'workspace_item_editor.dart';

final _log = AppLogger.forModule('NovelWorkspacePanel');

class NovelWorkspacePanel extends ConsumerWidget {
  const NovelWorkspacePanel({
    super.key,
    required this.novel,
    required this.selection,
    required this.chapters,
    required this.selectedChapterDetails,
    this.lastWrittenChapter,
    required this.worldbuildingEntries,
    required this.outlineEntries,
    required this.selectedOutline,
    required this.materialEntries,
    required this.characterProfiles,
    required this.skillEntries,
    required this.items,
    required this.factionEntries,
    required this.creatureEntries,
    required this.locations,
    required this.foreshadowings,
    required this.chapterTitleController,
    required this.chapterOutlineController,
    required this.chapterOutlineWindowSession,
    required this.readingWindowSession,
    required this.chapterContentController,
    required this.chapterTitleUndoController,
    required this.chapterOutlineUndoController,
    required this.chapterContentUndoController,
    required this.novelDescriptionController,
    required this.entryTitleController,
    required this.entryContentController,
    required this.entryCategoryController,
    required this.characterEditor,
    required this.foreshadowSetupController,
    required this.foreshadowPayoffController,
    required this.chapterTitleFocusNode,
    required this.chapterOutlineFocusNode,
    required this.chapterContentFocusNode,
    required this.novelDescriptionFocusNode,
    required this.entryTitleFocusNode,
    required this.entryContentFocusNode,
    required this.entryCategoryFocusNode,
    required this.foreshadowTitleFocusNode,
    required this.foreshadowSetupFocusNode,
    required this.foreshadowPayoffFocusNode,
    required this.chapterAutoSaveFeedback,
    required this.isSavingEntry,
    required this.selectedStatus,
    required this.foreshadowPositions,
    this.createFieldError,
    this.entryTitleFieldError,
    this.headerGestureExclusionKey,
    this.headerLeadingInset = 0,
    this.headerTrailingInset = 0,
    this.onBack,
    required this.onSelectionChanged,
    required this.onContinueWriting,
    required this.onCreateEntry,
    required this.onOutlineChanged,
    required this.onSaveChapter,
    required this.onSaveEntry,
    this.onDiscardCreateDraft,
    required this.onStatusChanged,
    required this.onForeshadowPositionsChanged,
    required this.onOpenCoverStudio,
    required this.onUploadCover,
    required this.coverThumbnailKey,
    required this.coverMenuTrigger,
    this.onEditNovel,
    required this.isImageGenerationConfigured,
    required this.canOpenCoverStudio,
    required this.onViewPendingChanges,
    required this.onViewHistory,
    this.itemPhotos = const <String>[],
    this.isItemPhotoAdding = false,
    this.onAddItemPhoto,
    this.onRemoveItemPhoto,
    this.onGenerateItemPhoto,
    this.databasePath,
    this.onRegisterScreenplaySceneFlush,
    this.onProductionPrompt,
    this.productionChat,
    this.editorFontFamily = 'Georgia',
    this.editorFontSize = 16,
    this.nameAssistantAiService,
    this.onNavigateToChapter,
    this.onRunShortcutAction,
    this.onAddChapterSelectionToChat,
  });

  final Novel novel;
  final WorkspaceSelection selection;
  final List<Chapter> chapters;

  /// 当前章节的单章详情；章节树只提供轻量元数据，不含 brief/events。
  final Chapter? selectedChapterDetails;
  final Chapter? lastWrittenChapter;
  final List<Document> worldbuildingEntries;
  final List<OutlineDraft> outlineEntries;
  final OutlineDraft? selectedOutline;
  final List<Document> materialEntries;
  final List<CharacterProfile> characterProfiles;
  final List<Item> skillEntries;
  final List<Item> items;
  final List<Item> factionEntries;
  final List<Item> creatureEntries;
  final List<Location> locations;
  final List<Foreshadowing> foreshadowings;
  final TextEditingController chapterTitleController;
  final TextEditingController chapterOutlineController;
  final ChapterOutlineWindowSession chapterOutlineWindowSession;
  final ReadingWindowSession readingWindowSession;
  final TextEditingController chapterContentController;
  final UndoHistoryController chapterTitleUndoController;
  final UndoHistoryController chapterOutlineUndoController;
  final UndoHistoryController chapterContentUndoController;
  final TextEditingController novelDescriptionController;
  final TextEditingController entryTitleController;
  final TextEditingController entryContentController;
  final TextEditingController entryCategoryController;
  final Widget characterEditor;
  final TextEditingController foreshadowSetupController;
  final TextEditingController foreshadowPayoffController;
  final FocusNode chapterTitleFocusNode;
  final FocusNode chapterOutlineFocusNode;
  final FocusNode chapterContentFocusNode;
  final FocusNode novelDescriptionFocusNode;
  final FocusNode entryTitleFocusNode;
  final FocusNode entryContentFocusNode;
  final FocusNode entryCategoryFocusNode;
  final FocusNode foreshadowTitleFocusNode;
  final FocusNode foreshadowSetupFocusNode;
  final FocusNode foreshadowPayoffFocusNode;
  final ValueNotifier<int> chapterAutoSaveFeedback;
  final bool isSavingEntry;
  final String selectedStatus;
  final ForeshadowingPositionIds foreshadowPositions;
  final String? createFieldError;
  final String? entryTitleFieldError;
  final GlobalKey? headerGestureExclusionKey;
  final double headerLeadingInset;
  final double headerTrailingInset;
  final VoidCallback? onBack;
  final ValueSetter<WorkspaceSelection> onSelectionChanged;
  final ValueChanged<String> onContinueWriting;
  final Future<void> Function() onCreateEntry;
  final ValueChanged<OutlineDraft> onOutlineChanged;
  final Future<void> Function() onSaveChapter;
  final Future<void> Function() onSaveEntry;
  final VoidCallback? onDiscardCreateDraft;
  final ValueSetter<String> onStatusChanged;
  final ValueSetter<ForeshadowingPositionIds> onForeshadowPositionsChanged;
  final VoidCallback onOpenCoverStudio;
  final VoidCallback onUploadCover;
  final GlobalKey coverThumbnailKey;
  final ValueNotifier<int> coverMenuTrigger;
  final VoidCallback? onEditNovel;

  /// 剧本正文区挂载时交回它的落盘函数，宿主页在切走前调用；卸载时传 null。
  final ValueChanged<Future<void> Function()?>? onRegisterScreenplaySceneFlush;
  final ProductionAsk? onProductionPrompt;

  /// 制片画布视图里浮在画布上的聊天层；不在画布视图时宿主传 null。
  final Widget? productionChat;

  /// 条目配图生成要求本地配了图片模型。
  final bool isImageGenerationConfigured;

  /// 配置可用的图片模型后可进入封面工作台。
  final bool canOpenCoverStudio;
  final VoidCallback onViewPendingChanges;
  final VoidCallback onViewHistory;
  final List<String> itemPhotos;
  final bool isItemPhotoAdding;
  final Future<void> Function()? onAddItemPhoto;
  final Future<void> Function(String path)? onRemoveItemPhoto;
  final Future<void> Function(String prompt, String itemId)?
  onGenerateItemPhoto;
  final String? databasePath;

  final String editorFontFamily;
  final int editorFontSize;
  final AiClient? nameAssistantAiService;
  final ValueChanged<String>? onNavigateToChapter;
  final ValueChanged<AiShortcutActionDefinition>? onRunShortcutAction;

  /// 把章节正文选区作为快照引用加入当前 AI 对话。
  final ValueChanged<String>? onAddChapterSelectionToChat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final appBackgroundActive = ref.watch(appBackgroundActiveProvider);
    final selectedCanvasName =
        selection.section == NovelWorkspaceSection.canvas &&
            selection.itemId != null &&
            databasePath != null
        ? ref
              .watch(
                canvasEntryProvider((
                  canvasId: selection.itemId!,
                  databasePath: databasePath!,
                )),
              )
              .asData
              ?.value
              ?.name
        : null;

    // 画布铺满到底，工具簇贴在左下角；制片的画布 / 列表视图同理，底栏统计只跟着分镜视图。
    final showStatusBar = switch (selection.section) {
      NovelWorkspaceSection.maps || NovelWorkspaceSection.canvas => false,
      NovelWorkspaceSection.storyboard => ref.watch(
        productionSegmentsViewProvider(novel.id),
      ),
      _ => true,
    };

    return Container(
      color: appBackgroundActive ? Colors.transparent : colors.surface,
      child: Column(
        children: [
          _buildHeader(
            context,
            ref,
            appBackgroundActive: appBackgroundActive,
            selectedCanvasName: selectedCanvasName,
            selectedCanvasLocked: false,
          ),
          Divider(height: RevericSizes.dividerThickness, color: colors.border),
          Expanded(child: _buildBody(context)),
          if (showStatusBar) ...[
            Divider(
              height: RevericSizes.dividerThickness,
              color: colors.borderSubtle,
            ),
            _buildStatusBar(context, appBackgroundActive: appBackgroundActive),
          ],
        ],
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    WidgetRef ref, {
    required bool appBackgroundActive,
    required String? selectedCanvasName,
    required bool selectedCanvasLocked,
  }) {
    final colors = RevericTheme.colorsOf(context);
    // 图鉴四类在侧栏合并成一个入口，面包屑的 section 级也统一显示「图鉴」；
    // 具体类型只在选中条目后作为中间级出现（图鉴 > 势力 > 玄冥宗），
    // 未选中时不显示类型，避免暗示当前只在看某一类。
    final isCompendium = isCompendiumSection(selection.section);
    final sectionLabel = isCompendium
        ? context.t(LocaleKeys.workspaceSidebarCompendium)
        : _labelForSection(context, selection.section);
    final canShowActions = _showsHeaderActions();
    final sourceNovel =
        selection.section == NovelWorkspaceSection.screenplay_script &&
            novel.sourceNovelId != null
        ? ref.watch(novelProvider(novel.sourceNovelId!)).value
        : null;
    // 制片里打开剪辑或导演台时，面包屑在「视频」后多一级子页面名称。
    final databasePath = novel.contentDatabasePath;
    final subpage =
        selection.section == NovelWorkspaceSection.storyboard &&
            databasePath != null
        ? ref.watch(productionSubpageProvider(databasePath))
        : null;

    return Container(
      color: appChromeBackgroundColor(
        colors,
        appBackgroundActive,
        colors.surfaceContainer,
      ),
      height: DesktopWindowFrame.titleBarHeight,
      padding: EdgeInsets.only(
        left: RevericSpacing.x2l + headerLeadingInset,
        right: RevericSpacing.x2l + headerTrailingInset,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Row(
              children: [
                if (onBack != null) ...[
                  Tooltip(
                    message: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    child: InkWell(
                      onTap: onBack,
                      borderRadius: BorderRadius.circular(RevericRadius.small),
                      hoverColor: colors.hover,
                      child: Padding(
                        padding: const EdgeInsets.all(RevericSpacing.xs),
                        child: RevericIcon(
                          RevericIcons.chevron_left,
                          size: 18,
                          color: colors.accent,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                ],
                _breadcrumb(context, novel.title),
                _separator(context),
                _breadcrumb(
                  context,
                  sectionLabel,
                  active: selection.itemId == null && subpage == null,
                ),
                if (subpage != null) ...[
                  _separator(context),
                  Flexible(
                    child: _breadcrumb(context, subpage.label, active: true),
                  ),
                ],
                if (isCompendium && selection.itemId != null) ...[
                  _separator(context),
                  _breadcrumb(
                    context,
                    _labelForSection(context, selection.section),
                  ),
                ],
                if (selection.itemId != null &&
                    _selectedItemLabel(
                          context,
                          selectedCanvasName: selectedCanvasName,
                        ) !=
                        sectionLabel) ...[
                  _separator(context),
                  Flexible(
                    child: _breadcrumb(
                      context,
                      _selectedItemLabel(
                        context,
                        selectedCanvasName: selectedCanvasName,
                      ),
                      active: true,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (canShowActions) ...[
            const SizedBox(width: RevericSpacing.x2l),
            // 这个 key 会被 DesktopWindowFrame 用来排除标题栏拖拽命中；
            // 否则双击 Save/History/Preview 等按钮可能同时触发窗口缩放。
            KeyedSubtree(
              key: headerGestureExclusionKey,
              child: _buildEditorToolbar(
                context,
                isSaving: isSavingEntry,
                onSave: switch (selection.section) {
                  NovelWorkspaceSection.chapters => onSaveChapter,
                  NovelWorkspaceSection.canvas => () => _saveCanvas(
                    context,
                    ref,
                  ),
                  _ => onSaveEntry,
                },
                onDiscardCreateDraft: onDiscardCreateDraft,
                selectedCanvasLocked: false,
              ),
            ),
          ] else if (sourceNovel?.contentDatabasePath != null) ...[
            const SizedBox(width: RevericSpacing.x2l),
            KeyedSubtree(
              key: headerGestureExclusionKey,
              child: IconButton(
                tooltip: context.t(LocaleKeys.screenplayViewSource),
                icon: RevericIcon(
                  RevericIcons.book_open,
                  size: 18,
                  color: colors.textMuted,
                ),
                onPressed: () {
                  unawaited(
                    readingWindowSession.openNovel(
                      sourceNovel!,
                      theme: DetachedWindowTheme.fromSettings(
                        ref.read(appSettingsNotifierProvider).asData?.value,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (selection.section) {
      case NovelWorkspaceSection.overview:
        // 剧本作品的概览是集 / 场次 / 时长口径，和小说的章节字数口径不通用。
        if (novel.contentKind == contentKindScreenplay) {
          return _buildScreenplayOverview();
        }
        return NovelOverview(
          onContinueWriting: onContinueWriting,
          novel: novel,
          chapters: chapters,
          lastWrittenChapter: lastWrittenChapter,
          characterProfiles: characterProfiles,
          worldbuildingEntries: worldbuildingEntries,
          foreshadowings: foreshadowings,
          canOpenCoverStudio: canOpenCoverStudio,
          onOpenCoverStudio: onOpenCoverStudio,
          onUploadCover: onUploadCover,
          onSelectionChanged: onSelectionChanged,
          onEditNovel: onEditNovel,
          coverThumbnailKey: coverThumbnailKey,
          coverMenuTrigger: coverMenuTrigger,
        );
      case NovelWorkspaceSection.maps:
        return _buildMapsPanel(context);
      case NovelWorkspaceSection.novel_description:
        return _buildNovelDescriptionEditor(context);
      case NovelWorkspaceSection.story_progress:
        return StoryProgressPanel(
          databasePath: databasePath,
          chapters: chapters,
        );
      case NovelWorkspaceSection.chapters:
        final selectedChapterMeta = chapters
            .where((chapter) => chapter.id == selection.itemId)
            .firstOrNull;
        final selectedChapter = selectedChapterDetails?.id == selection.itemId
            ? selectedChapterDetails
            : selectedChapterMeta;
        if (selectedChapter?.isVolume ?? false) {
          return VolumeEditor(
            volume: selectedChapter!,
            volumeNumber: selectedChapterMeta?.volumeNum,
            titleController: chapterTitleController,
            outlineController: chapterOutlineController,
            titleFocusNode: chapterTitleFocusNode,
            outlineFocusNode: chapterOutlineFocusNode,
          );
        }
        return ChapterEditor(
          key: ValueKey(selectedChapter?.id),
          chapters: chapters,
          selectedChapter: selectedChapter,
          chapterNumber: selectedChapterMeta?.chapterNum,
          characterProfiles: characterProfiles,
          locations: locations,
          skillEntries: skillEntries,
          items: items,
          creatureEntries: creatureEntries,
          factionEntries: factionEntries,
          titleController: chapterTitleController,
          outlineController: chapterOutlineController,
          outlineWindowSession: chapterOutlineWindowSession,
          contentController: chapterContentController,
          titleUndoController: chapterTitleUndoController,
          outlineUndoController: chapterOutlineUndoController,
          contentUndoController: chapterContentUndoController,
          titleFocusNode: chapterTitleFocusNode,
          outlineFocusNode: chapterOutlineFocusNode,
          contentFocusNode: chapterContentFocusNode,
          onCreateChapter: onCreateEntry,
          databasePath: databasePath,
          onAddSelectionToChat: onAddChapterSelectionToChat,
        );
      case NovelWorkspaceSection.lore:
        return _buildSimpleEntryEditor(
          context,
          title: context.t(LocaleKeys.workspaceLore),
          description: context.t(LocaleKeys.workspaceLoreHint),
        );
      case NovelWorkspaceSection.outlines:
        if (selection.itemId == null) {
          return selection.isViewingAllOutlines
              ? AllOutlinesArchitectureView(outlines: outlineEntries)
              : OutlinesLandingState(
                  onViewAll: () => onSelectionChanged(
                    const WorkspaceSelection(
                      section: NovelWorkspaceSection.outlines,
                      isViewingAllOutlines: true,
                    ),
                  ),
                  onCreate: onCreateEntry,
                );
        }
        return OutlineEditor(
          draft: selectedOutline,
          onChanged: onOutlineChanged,
          onCreateFirstBeat: onCreateEntry,
          onRunShortcutAction: onRunShortcutAction,
          titleErrorText: selection.isCreating
              ? createFieldError
              : entryTitleFieldError,
        );
      case NovelWorkspaceSection.materials:
        return _buildSimpleEntryEditor(
          context,
          title: context.t(LocaleKeys.workspaceMaterials),
          description: context.t(LocaleKeys.workspaceMaterialsHint),
        );
      case NovelWorkspaceSection.characters:
        return _buildCharacterEditor(context);
      case NovelWorkspaceSection.skills:
        return _buildSimpleEntryEditor(
          context,
          title: context.t(LocaleKeys.workspaceSkills),
          description: context.t(LocaleKeys.workspaceSkillsHint),
          nameType: NameType.skill,
        );
      case NovelWorkspaceSection.items:
        return _buildSimpleEntryEditor(
          context,
          title: context.t(LocaleKeys.workspaceItems),
          description: context.t(LocaleKeys.workspaceItemsHint),
          nameType: NameType.item,
        );
      case NovelWorkspaceSection.factions:
        return _buildSimpleEntryEditor(
          context,
          title: context.t(LocaleKeys.workspaceFactions),
          description: context.t(LocaleKeys.workspaceFactionsHint),
        );
      case NovelWorkspaceSection.creatures:
        return _buildSimpleEntryEditor(
          context,
          title: context.t(LocaleKeys.workspaceCreatures),
          description: context.t(LocaleKeys.workspaceCreaturesHint),
          nameType: NameType.creature,
        );
      case NovelWorkspaceSection.foreshadowings:
        return _buildForeshadowingEditor(context);
      case NovelWorkspaceSection.entity_graph:
        return _buildEntityGraphPanel(context);
      case NovelWorkspaceSection.canvas:
        return ideationCanvasEnabled
            ? _buildCanvasPanel(context)
            : const SizedBox.shrink();
      case NovelWorkspaceSection.screenplay_script:
        return ScreenplayScriptRegion(
          novel: novel,
          registerFlush: onRegisterScreenplaySceneFlush ?? (_) {},
        );
      case NovelWorkspaceSection.screenplay_outline:
        return ScreenplayOutlineRegion(
          novel: novel,
          registerFlush: onRegisterScreenplaySceneFlush ?? (_) {},
        );
      case NovelWorkspaceSection.storyboard:
        return ProductionRegion(
          novel: novel,
          selectedClipId: selection.itemId,
          onAsk: onProductionPrompt,
          chat: productionChat,
          registerFlush: onRegisterScreenplaySceneFlush ?? (_) {},
        );
      case NovelWorkspaceSection.screenplay_scenes:
        return ScreenplayScenesRegion(novel: novel);
    }
  }

  /// 剧本概览需要 screenplay 根 id；根还没读出来时先留白，不闪错误态。
  Widget _buildScreenplayOverview() {
    final path = novel.contentDatabasePath;
    if (path == null || path.isEmpty) {
      return const SizedBox.shrink();
    }
    return Consumer(
      builder: (context, ref, _) {
        final screenplayId = ref.watch(screenplayRootProvider(path)).value?.id;
        if (screenplayId == null) {
          return const SizedBox.shrink();
        }
        return ScreenplayOverviewRegion(
          novel: novel,
          screenplayId: screenplayId,
          onEditNovel: onEditNovel,
        );
      },
    );
  }

  Widget _buildNovelDescriptionEditor(BuildContext context) {
    return NovelDescriptionEditor(
      novelTitle: novel.title,
      controller: novelDescriptionController,
      focusNode: novelDescriptionFocusNode,
    );
  }

  Widget _buildSimpleEntryEditor(
    BuildContext context, {
    required String title,
    required String description,
    NameType? nameType,
  }) {
    // 图鉴四类共用一个空状态：四种「还没有选中势力/生物/物品/技能」在合并后
    // 只是同一个面板的不同落点，对用户是同一件事。用整句而不是 `{type}` 插值，
    // 因为「选择一个图鉴」「新建图鉴」都不通。
    final isCompendium = isCompendiumSection(selection.section);
    final typeLabel = _labelForSection(context, selection.section);
    final hasCompendiumEntries = isCompendium && _currentEntries().isNotEmpty;
    final hideMetadataInEditor =
        selection.section == NovelWorkspaceSection.materials &&
        !selection.isCreating;
    return WorkspaceEntryEditor(
      selectedItemId: selection.itemId,
      isCreating: selection.isCreating,
      entries: _currentEntries(),
      title: title,
      description: description,
      typeLabel: typeLabel,
      emptyStateTitle: isCompendium
          ? context.t(LocaleKeys.workspaceCompendiumNoSelection)
          : null,
      emptyStateMessage: isCompendium
          ? context.t(
              hasCompendiumEntries
                  ? LocaleKeys.workspaceCompendiumSelectToEdit
                  : LocaleKeys.workspaceCompendiumCreateFirst,
            )
          : null,
      categoryHint: context.t(_entryCategoryHintLocaleKey(selection.section)),
      newEntryLabel: context.t(
        isCompendium
            ? LocaleKeys.workspaceNewCompendiumEntry
            : _newEntryLocaleKey(selection.section),
      ),
      titleController: entryTitleController,
      contentController: entryContentController,
      categoryController: entryCategoryController,
      titleFocusNode: entryTitleFocusNode,
      contentFocusNode: entryContentFocusNode,
      categoryFocusNode: entryCategoryFocusNode,
      showMetadataFields: !hideMetadataInEditor,
      titleErrorText: selection.isCreating
          ? createFieldError
          : entryTitleFieldError,
      onCreateEntry: onCreateEntry,
      editorFontFamily: editorFontFamily,
      editorFontSize: editorFontSize,
      nameAssistantAiService: nameAssistantAiService,
      novel: novel,
      nameType: nameType,
      photos: isCompendium ? itemPhotos : null,
      isPhotoAdding: isCompendium && isItemPhotoAdding,
      isImageGenerationConfigured:
          !selection.isCreating && isImageGenerationConfigured,
      onAddPhoto: isCompendium ? onAddItemPhoto : null,
      onRemovePhoto: isCompendium ? onRemoveItemPhoto : null,
      onGeneratePhoto: selection.section == NovelWorkspaceSection.items
          ? onGenerateItemPhoto
          : null,
    );
  }

  Widget _buildCharacterEditor(BuildContext context) {
    return characterEditor;
  }

  Widget _buildForeshadowingEditor(BuildContext context) {
    return ForeshadowingEditor(
      selectedItemId: selection.itemId,
      isCreating: selection.isCreating,
      foreshadowings: foreshadowings,
      titleController: entryTitleController,
      setupController: foreshadowSetupController,
      payoffController: foreshadowPayoffController,
      titleFocusNode: foreshadowTitleFocusNode,
      setupFocusNode: foreshadowSetupFocusNode,
      payoffFocusNode: foreshadowPayoffFocusNode,
      titleErrorText: selection.isCreating
          ? createFieldError
          : entryTitleFieldError,
      selectedStatus: selectedStatus,
      onStatusChanged: onStatusChanged,
      positions: foreshadowPositions,
      onPositionsChanged: onForeshadowPositionsChanged,
      onCreateForeshadowing: onCreateEntry,
      editorFontFamily: editorFontFamily,
      databasePath: databasePath,
      onNavigateToChapter: onNavigateToChapter,
      onNavigateToPosition: (target) {
        if (target.scene == null) {
          onNavigateToChapter?.call(target.id);
          return;
        }
        final path = novel.contentDatabasePath;
        if (path == null) {
          return;
        }
        // 全程同步：`read(autoDisposeProvider.future)` 没有监听者时会随读取一起
        // 释放，future 等不到值，点击表现为毫无反应。family 参数取 novel 自身，
        // 与消费方 ScreenplayScriptRegion 一致。
        final container = ProviderScope.containerOf(context);
        final provider = screenplayWorkspaceStateControllerProvider(
          novel.id,
          path,
        );
        container
            .read(provider.notifier)
            .update(
              container
                  .read(provider)
                  .copyWith(
                    section: ScreenplayWorkspaceSection.script,
                    seasonId: target.seasonId,
                    episodeId: target.scene!.episodeId,
                    sceneId: target.id,
                  ),
            );
        container
            .read(workspaceNavigationProvider.notifier)
            .request(
              WorkspaceNavigationRequest(
                section: NovelWorkspaceSection.screenplay_script,
                itemId: target.id,
              ),
            );
      },
    );
  }

  Widget _buildEntityGraphPanel(BuildContext context) {
    if (databasePath == null) {
      return Center(
        child: Text(context.t(LocaleKeys.workspaceDatabasePathLoadFailed)),
      );
    }

    return EntityGraphPanel(
      databasePath: databasePath!,
      selectedEntityKey: selection.itemId,
      onSelectedEntityKeyChanged: (entityKey) {
        onSelectionChanged(
          WorkspaceSelection(
            section: NovelWorkspaceSection.entity_graph,
            itemId: entityKey,
          ),
        );
      },
    );
  }

  /// 画布嵌在工作区主内容区，复用工作区那一个聊天面板（不再单开路由页）。
  Widget _buildCanvasPanel(BuildContext context) {
    final canvasId = selection.itemId;
    final path = databasePath;
    if (canvasId == null || canvasId.isEmpty || path == null) {
      return _buildCanvasEmptyState(context);
    }
    return CanvasRegion(
      canvasId: canvasId,
      databasePath: path,
      workId: novel.id,
      exportSource: (id: novel.id, contentKind: novel.contentKind),
    );
  }

  Future<void> _saveCanvas(BuildContext context, WidgetRef ref) async {
    final canvasId = selection.itemId;
    final path = databasePath;
    if (canvasId == null || path == null) {
      return;
    }
    try {
      await ref
          .read(canvasServiceProvider(path))
          .refreshReferenceTitlesForCanvas(canvasId);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.commonSaved))),
        );
      }
    } catch (error, stackTrace) {
      _log.error(
        'Canvas save failed id=$canvasId',
        error: error,
        stackTrace: stackTrace,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
        );
      }
    }
  }

  Widget _buildCanvasEmptyState(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(RevericSpacing.x3l),
        child: Text(
          context.t(LocaleKeys.canvasEmptyHint),
          style: typo.ui.copyWith(color: colors.textMuted),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildMapsPanel(BuildContext context) {
    if (databasePath == null) {
      return Center(
        child: Text(context.t(LocaleKeys.workspaceDatabasePathLoadFailed)),
      );
    }

    return MapStudioPage(
      novelId: novel.id,
      databasePath: databasePath!,
      worldId: selection.itemId,
      onWorldSelected: (worldId) {
        onSelectionChanged(
          WorkspaceSelection(
            section: NovelWorkspaceSection.maps,
            itemId: worldId,
          ),
        );
      },
    );
  }

  Widget _buildEditorToolbar(
    BuildContext context, {
    required bool isSaving,
    required Future<void> Function() onSave,
    VoidCallback? onDiscardCreateDraft,
    required bool selectedCanvasLocked,
  }) {
    final resourceId = selection.itemId;
    final dbPath = databasePath;
    final showHistoryButton =
        resourceId != null &&
        dbPath != null &&
        selection.section != NovelWorkspaceSection.overview &&
        selection.section != NovelWorkspaceSection.novel_description &&
        selection.section != NovelWorkspaceSection.outlines &&
        selection.section != NovelWorkspaceSection.chapters &&
        selection.section != NovelWorkspaceSection.canvas;

    final isLocked =
        selection.section == NovelWorkspaceSection.canvas &&
        selectedCanvasLocked;
    final showEditorSettingsButton =
        selection.section == NovelWorkspaceSection.chapters;
    final selectedChapter = selection.section == NovelWorkspaceSection.chapters
        ? chapters
              .where((chapter) => chapter.id == selection.itemId)
              .firstOrNull
        : null;
    final showChapterPreviewButton =
        selectedChapter != null && !selectedChapter.isVolume;
    final showChapterCopyButton = showChapterPreviewButton;

    return Align(
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selection.isCreating) ...[
            Text(
              context.t(LocaleKeys.commonUnsaved),
              style: RevericTheme.typographyOf(context).uiSmall.copyWith(
                color: RevericTheme.colorsOf(context).textMuted,
              ),
            ),
            const SizedBox(width: RevericSpacing.sm),
            TextButton(
              onPressed: isSaving ? null : onDiscardCreateDraft,
              child: Text(context.t(LocaleKeys.commonDiscard)),
            ),
            const SizedBox(width: RevericSpacing.sm),
          ],
          if (showHistoryButton) ...[
            ResourceHistoryButton(
              databasePath: dbPath,
              resourceId: resourceId,
              resourceLabel: _resourceHistoryLabel(context),
            ),
            const SizedBox(width: RevericSpacing.sm),
          ],
          if (showChapterPreviewButton) ...[
            _ChapterUndoControls(
              titleUndoController: chapterTitleUndoController,
              outlineUndoController: chapterOutlineUndoController,
              contentUndoController: chapterContentUndoController,
              titleFocusNode: chapterTitleFocusNode,
              outlineFocusNode: chapterOutlineFocusNode,
              contentFocusNode: chapterContentFocusNode,
            ),
            const SizedBox(width: RevericSpacing.sm),
          ],
          if (showChapterCopyButton) ...[
            IconButton(
              tooltip: context.t(LocaleKeys.workspaceChapterCopy),
              icon: RevericIcon(
                RevericIcons.copy_outlined,
                size: 18,
                color: RevericTheme.colorsOf(context).textMuted,
              ),
              onPressed: () {
                showChapterCopyReplace(
                  context,
                  contentController: chapterContentController,
                );
              },
            ),
            const SizedBox(width: RevericSpacing.sm),
          ],
          if (showEditorSettingsButton) ...[
            IconButton(
              tooltip: context.t(LocaleKeys.settingsFonts),
              icon: RevericIcon(
                RevericIcons.settings_outlined,
                size: 18,
                color: RevericTheme.colorsOf(context).textMuted,
              ),
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (_) => const SettingsDialog(initialNavId: 'editor'),
                );
              },
            ),
            const SizedBox(width: RevericSpacing.sm),
          ],
          if (showChapterPreviewButton) ...[
            IconButton(
              tooltip: context.t(LocaleKeys.workspacePreview),
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (_) => ChapterPreviewDialog(
                    chapterTitle: chapterTitleController.text,
                    chapterContent: chapterContentController.text,
                  ),
                );
              },
              icon: RevericIcon(
                RevericIcons.visibility_outlined,
                size: 18,
                color: RevericTheme.colorsOf(context).textMuted,
              ),
            ),
            const SizedBox(width: RevericSpacing.sm),
          ],
          _ShortcutActionsMenu(
            location: _shortcutLocationForSelection(),
            onRunShortcutAction: onRunShortcutAction,
          ),
          const SizedBox(width: RevericSpacing.sm),
          if (selection.section == NovelWorkspaceSection.chapters ||
              selection.section == NovelWorkspaceSection.canvas)
            NovelWorkspaceSaveButton(onSave: onSave, isLocked: isLocked)
          else
            FilledButton(
              onPressed: (isSaving || isLocked) ? null : onSave,
              child: Text(
                isSaving
                    ? context.t(LocaleKeys.commonSaving)
                    : context.t(LocaleKeys.commonSave),
              ),
            ),
        ],
      ),
    );
  }

  AiShortcutActionLocation? _shortcutLocationForSelection() {
    if (selection.isCreating) {
      return null;
    }
    switch (selection.section) {
      case NovelWorkspaceSection.novel_description:
        return AiShortcutActionLocation.novel_description;
      case NovelWorkspaceSection.chapters:
        return selection.itemId == null
            ? null
            : AiShortcutActionLocation.chapter;
      case NovelWorkspaceSection.outlines:
        return selection.itemId == null
            ? null
            : AiShortcutActionLocation.outline;
      case NovelWorkspaceSection.lore:
        return selection.itemId == null
            ? null
            : AiShortcutActionLocation.worldbuilding;
      case NovelWorkspaceSection.materials:
        return selection.itemId == null
            ? null
            : AiShortcutActionLocation.material;
      case NovelWorkspaceSection.characters:
        return selection.itemId == null
            ? null
            : AiShortcutActionLocation.character;
      case NovelWorkspaceSection.skills:
        return selection.itemId == null
            ? null
            : AiShortcutActionLocation.skill_entry;
      case NovelWorkspaceSection.items:
        return selection.itemId == null ? null : AiShortcutActionLocation.item;
      case NovelWorkspaceSection.factions:
        return selection.itemId == null
            ? null
            : AiShortcutActionLocation.faction;
      case NovelWorkspaceSection.creatures:
        return selection.itemId == null
            ? null
            : AiShortcutActionLocation.creature;
      case NovelWorkspaceSection.foreshadowings:
        return selection.itemId == null
            ? null
            : AiShortcutActionLocation.foreshadowing;
      case NovelWorkspaceSection.overview:
      case NovelWorkspaceSection.maps:
      case NovelWorkspaceSection.entity_graph:
      case NovelWorkspaceSection.story_progress:
      case NovelWorkspaceSection.canvas:
      case NovelWorkspaceSection.screenplay_script:
      case NovelWorkspaceSection.screenplay_outline:
      case NovelWorkspaceSection.storyboard:
      case NovelWorkspaceSection.screenplay_scenes:
        return null;
    }
  }

  bool _showsHeaderActions() {
    if (selection.section == NovelWorkspaceSection.maps) {
      return false;
    }
    if (selection.isCreating) {
      return true;
    }
    if (selection.section != NovelWorkspaceSection.overview &&
        selection.section != NovelWorkspaceSection.novel_description &&
        selection.itemId == null) {
      return false;
    }

    if (selection.section == NovelWorkspaceSection.lore ||
        selection.section == NovelWorkspaceSection.outlines ||
        selection.section == NovelWorkspaceSection.materials) {
      final currentEntriesList = _currentEntries();
      dynamic currentEntry;
      for (final entry in currentEntriesList) {
        if (entry is OutlineDraft) {
          if (entry.documentId == selection.itemId) {
            currentEntry = entry;
            break;
          }
        } else if (entry.id == selection.itemId) {
          currentEntry = entry;
          break;
        }
      }

      if (currentEntry != null &&
          currentEntry is Document &&
          currentEntry.isFolder) {
        return false;
      }
    }

    switch (selection.section) {
      case NovelWorkspaceSection.overview:
      case NovelWorkspaceSection.maps:
        return false;
      case NovelWorkspaceSection.novel_description:
        return true;
      case NovelWorkspaceSection.chapters:
      case NovelWorkspaceSection.lore:
      case NovelWorkspaceSection.outlines:
      case NovelWorkspaceSection.materials:
      case NovelWorkspaceSection.characters:
      case NovelWorkspaceSection.skills:
      case NovelWorkspaceSection.items:
      case NovelWorkspaceSection.factions:
      case NovelWorkspaceSection.creatures:
      case NovelWorkspaceSection.foreshadowings:
        return true;
      case NovelWorkspaceSection.entity_graph:
      case NovelWorkspaceSection.story_progress:
      case NovelWorkspaceSection.screenplay_script:
      case NovelWorkspaceSection.screenplay_outline:
      case NovelWorkspaceSection.storyboard:
      case NovelWorkspaceSection.screenplay_scenes:
        return false;
      case NovelWorkspaceSection.canvas:
        return true;
    }
  }

  Widget _buildStatusBar(
    BuildContext context, {
    required bool appBackgroundActive,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final selectedChapter = selection.section == NovelWorkspaceSection.chapters
        ? chapters
              .where((chapter) => chapter.id == selection.itemId)
              .firstOrNull
        : null;
    final showChapterMetrics =
        selectedChapter != null && !selectedChapter.isVolume;
    final showHistoryButton =
        selection.section != NovelWorkspaceSection.entity_graph;

    // 剧本正文的统计（自动保存 / 集 / 页 / 时长 / 场 / 台词）也落在这一条上：
    // mockup 里剧本只有一条底栏，统计在左、「历史」在右。分区自己再画一条
    // 就会和这一条上下叠成两层。
    final showScriptStatus =
        selection.section == NovelWorkspaceSection.screenplay_script &&
        novel.contentKind == contentKindScreenplay &&
        novel.contentDatabasePath != null;
    final showProductionStatus =
        selection.section == NovelWorkspaceSection.storyboard &&
        novel.contentDatabasePath != null;
    final primaryStatus = showScriptStatus
        ? ScreenplayScriptStatusItems(novel: novel)
        : showProductionStatus
        ? ProductionStatusItems(novel: novel)
        : selectedChapter == null
        ? const SizedBox.shrink()
        : NovelWorkspaceAutoSaveStatus(savedSignal: chapterAutoSaveFeedback);
    final secondaryStatus = showChapterMetrics
        ? NovelWorkspaceChapterStatusMetrics(
            controller: chapterContentController,
          )
        : null;
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showChapterMetrics) ...[
          _StatusBarPunctuationReplaceButton(
            controller: chapterContentController,
            onSave: onSaveChapter,
          ),
          const SizedBox(width: RevericSpacing.md),
          _StatusBarAutoFormatButton(
            controller: chapterContentController,
            onSave: onSaveChapter,
            databasePath: databasePath,
          ),
          const SizedBox(width: RevericSpacing.md),
        ],
        _PendingChangesBadge(
          databasePath: databasePath,
          onViewPendingChanges: onViewPendingChanges,
        ),
        if (showHistoryButton)
          TextButton.icon(
            onPressed: onViewHistory,
            icon: const RevericIcon(RevericIcons.history_rounded, size: 14),
            label: Text(context.t(LocaleKeys.historyOpen)),
            style: TextButton.styleFrom(
              foregroundColor: colors.textMuted,
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.sm,
              ),
              minimumSize: const Size(0, RevericSizes.buttonHeightSm),
              textStyle: typo.uiTiny,
            ),
          ),
      ],
    );

    return Container(
      color: appChromeBackgroundColor(
        colors,
        appBackgroundActive,
        colors.surface,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.x3l,
        vertical: RevericSpacing.sm,
      ),
      child: NovelWorkspaceStatusBarLayout(
        primaryStatus: primaryStatus,
        secondaryStatus: secondaryStatus,
        actions: actions,
      ),
    );
  }

  Widget _breadcrumb(
    BuildContext context,
    String label, {
    bool active = false,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Text(
      label,
      style: (active ? typo.uiMedium : typo.ui).copyWith(
        color: active ? colors.textPrimary : colors.textMuted,
      ),
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _separator(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.xs),
      child: Text('>', style: typo.ui.copyWith(color: colors.textSubtle)),
    );
  }

  List<dynamic> _currentEntries() {
    switch (selection.section) {
      case NovelWorkspaceSection.novel_description:
        return const <dynamic>[];
      case NovelWorkspaceSection.entity_graph:
        return const <dynamic>[];
      case NovelWorkspaceSection.story_progress:
        return const <dynamic>[];
      case NovelWorkspaceSection.maps:
        return const <dynamic>[];
      case NovelWorkspaceSection.lore:
        return worldbuildingEntries;
      case NovelWorkspaceSection.outlines:
        return outlineEntries;
      case NovelWorkspaceSection.materials:
        return materialEntries;
      case NovelWorkspaceSection.characters:
        return characterProfiles;
      case NovelWorkspaceSection.skills:
        return skillEntries;
      case NovelWorkspaceSection.items:
        return items;
      case NovelWorkspaceSection.factions:
        return factionEntries;
      case NovelWorkspaceSection.creatures:
        return creatureEntries;
      case NovelWorkspaceSection.foreshadowings:
        return foreshadowings;
      case NovelWorkspaceSection.chapters:
        return chapters;
      case NovelWorkspaceSection.overview:
      case NovelWorkspaceSection.canvas:
      case NovelWorkspaceSection.screenplay_script:
      case NovelWorkspaceSection.screenplay_outline:
      case NovelWorkspaceSection.storyboard:
      case NovelWorkspaceSection.screenplay_scenes:
        return const <dynamic>[];
    }
  }

  String _labelForSection(BuildContext context, NovelWorkspaceSection section) {
    return context.t(sectionLocaleKey(section));
  }

  String _newEntryLocaleKey(NovelWorkspaceSection section) {
    return switch (section) {
      NovelWorkspaceSection.lore => LocaleKeys.workspaceNewWorldbuilding,
      NovelWorkspaceSection.outlines => LocaleKeys.workspaceNewOutline,
      NovelWorkspaceSection.materials => LocaleKeys.workspaceNewMaterial,
      NovelWorkspaceSection.skills => LocaleKeys.workspaceNewSkill,
      NovelWorkspaceSection.items => LocaleKeys.workspaceNewItem,
      NovelWorkspaceSection.factions => LocaleKeys.workspaceNewFaction,
      NovelWorkspaceSection.creatures => LocaleKeys.workspaceNewCreature,
      NovelWorkspaceSection.characters => LocaleKeys.workspaceNewCharacter,
      NovelWorkspaceSection.foreshadowings =>
        LocaleKeys.workspaceNewForeshadowing,
      _ => LocaleKeys.workspaceNewEntry,
    };
  }

  String _entryCategoryHintLocaleKey(NovelWorkspaceSection section) {
    return switch (section) {
      NovelWorkspaceSection.lore => LocaleKeys.workspaceEntryCategoryLoreHint,
      NovelWorkspaceSection.materials =>
        LocaleKeys.workspaceEntryCategoryMaterialsHint,
      NovelWorkspaceSection.skills =>
        LocaleKeys.workspaceEntryCategorySkillsHint,
      NovelWorkspaceSection.items => LocaleKeys.workspaceEntryCategoryItemsHint,
      NovelWorkspaceSection.factions =>
        LocaleKeys.workspaceEntryCategoryFactionsHint,
      NovelWorkspaceSection.creatures =>
        LocaleKeys.workspaceEntryCategoryCreaturesHint,
      _ => LocaleKeys.workspaceEntryCategoryHint,
    };
  }

  String _selectedItemLabel(
    BuildContext context, {
    String? selectedCanvasName,
  }) {
    final itemId = selection.itemId!;
    switch (selection.section) {
      case NovelWorkspaceSection.novel_description:
        return context.t(LocaleKeys.workspaceNovelDescription);
      case NovelWorkspaceSection.entity_graph:
        return _entityGraphSelectedLabel(context, itemId);
      case NovelWorkspaceSection.maps:
        return context.t(LocaleKeys.workspaceMaps);
      case NovelWorkspaceSection.chapters:
        final chapter = chapters
            .where((entry) => entry.id == itemId)
            .firstOrNull;
        if (chapter == null) {
          return context.t(LocaleKeys.workspaceChapters);
        }
        return _chapterBreadcrumbLabel(context, chapter);
      case NovelWorkspaceSection.lore:
        return worldbuildingEntries
                .where((entry) => entry.id == itemId)
                .firstOrNull
                ?.title ??
            context.t(LocaleKeys.workspaceLore);
      case NovelWorkspaceSection.outlines:
        return outlineEntries
                .where((entry) => entry.documentId == itemId)
                .firstOrNull
                ?.title ??
            context.t(LocaleKeys.workspaceOutlines);
      case NovelWorkspaceSection.materials:
        return materialEntries
                .where((entry) => entry.id == itemId)
                .firstOrNull
                ?.title ??
            context.t(LocaleKeys.workspaceMaterials);
      case NovelWorkspaceSection.characters:
        return characterProfiles
                .where((entry) => entry.id == itemId)
                .firstOrNull
                ?.name ??
            context.t(LocaleKeys.workspaceCharacters);
      case NovelWorkspaceSection.skills:
        return skillEntries
                .where((entry) => entry.id == itemId)
                .firstOrNull
                ?.title ??
            context.t(LocaleKeys.workspaceSkills);
      case NovelWorkspaceSection.items:
        return items.where((entry) => entry.id == itemId).firstOrNull?.title ??
            context.t(LocaleKeys.workspaceItems);
      case NovelWorkspaceSection.factions:
        return factionEntries
                .where((entry) => entry.id == itemId)
                .firstOrNull
                ?.title ??
            context.t(LocaleKeys.workspaceFactions);
      case NovelWorkspaceSection.creatures:
        return creatureEntries
                .where((entry) => entry.id == itemId)
                .firstOrNull
                ?.title ??
            context.t(LocaleKeys.workspaceCreatures);
      case NovelWorkspaceSection.foreshadowings:
        return foreshadowings
                .where((entry) => entry.id == itemId)
                .firstOrNull
                ?.title ??
            context.t(LocaleKeys.workspaceForeshadowings);
      case NovelWorkspaceSection.overview:
        return context.t(LocaleKeys.workspaceOverview);
      case NovelWorkspaceSection.story_progress:
        return context.t(LocaleKeys.workspaceStoryProgress);
      case NovelWorkspaceSection.canvas:
        return selectedCanvasName ?? context.t(LocaleKeys.workspaceCanvas);
      case NovelWorkspaceSection.screenplay_script:
      case NovelWorkspaceSection.screenplay_outline:
      case NovelWorkspaceSection.storyboard:
      case NovelWorkspaceSection.screenplay_scenes:
        return context.t(sectionLocaleKey(selection.section));
    }
  }

  String _chapterBreadcrumbLabel(BuildContext context, Chapter chapter) {
    final title = chapter.title?.trim() ?? '';
    final prefix = _chapterBreadcrumbPrefix(context, chapter);
    if (title.isEmpty) {
      return prefix;
    }
    return '$prefix · $title';
  }

  String _chapterBreadcrumbPrefix(BuildContext context, Chapter chapter) {
    if (chapter.isVolume) {
      final volumeNum = chapter.volumeNum;
      if (volumeNum == null) {
        return context.t(LocaleKeys.workspaceVolume);
      }
      return context.t(
        LocaleKeys.workspaceVolumeNumber,
        namedArgs: {'number': '$volumeNum'},
      );
    }
    if (chapter.isExtra) {
      return context.t(LocaleKeys.workspaceExtra);
    }
    return context.t(
      LocaleKeys.commonChapterNumber,
      namedArgs: {'number': '${chapter.chapterNum ?? "?"}'},
    );
  }

  String _resourceHistoryLabel(BuildContext context) {
    final itemId = selection.itemId;
    if (itemId == null) {
      return _labelForSection(context, selection.section);
    }
    return _selectedItemLabel(context);
  }

  String _entityGraphSelectedLabel(BuildContext context, String entityKey) {
    final parts = entityKey.split('_');
    if (parts.length < 2) {
      return context.t(LocaleKeys.workspaceEntityGraph);
    }
    final entityType = parts.first;
    final entityId = parts.sublist(1).join('_');
    switch (entityType) {
      case entityTypeCharacter:
        return characterProfiles
                .where((entry) => entry.id == entityId)
                .firstOrNull
                ?.name ??
            context.t(LocaleKeys.workspaceEntityGraph);
      case entityTypeFaction:
        return factionEntries
                .where((entry) => entry.id == entityId)
                .firstOrNull
                ?.title ??
            context.t(LocaleKeys.workspaceEntityGraph);
      case entityTypeSkill:
        return skillEntries
                .where((entry) => entry.id == entityId)
                .firstOrNull
                ?.title ??
            context.t(LocaleKeys.workspaceEntityGraph);
      case entityTypeItem:
        return items
                .where((entry) => entry.id == entityId)
                .firstOrNull
                ?.title ??
            context.t(LocaleKeys.workspaceEntityGraph);
      case entityTypeCreature:
        return creatureEntries
                .where((entry) => entry.id == entityId)
                .firstOrNull
                ?.title ??
            context.t(LocaleKeys.workspaceEntityGraph);
      case entityTypeLocation:
        return locations
                .where((entry) => entry.id == entityId)
                .firstOrNull
                ?.name ??
            context.t(LocaleKeys.workspaceEntityGraph);
      default:
        return context.t(LocaleKeys.workspaceEntityGraph);
    }
  }
}

class _ShortcutActionsMenu extends ConsumerWidget {
  const _ShortcutActionsMenu({
    required this.location,
    required this.onRunShortcutAction,
  });

  final AiShortcutActionLocation? location;
  final ValueChanged<AiShortcutActionDefinition>? onRunShortcutAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shortcutLocation = location;
    if (shortcutLocation == null || onRunShortcutAction == null) {
      return const SizedBox.shrink();
    }
    final actions = ref.watch(
      enabledAiShortcutActionsForLocationProvider(shortcutLocation),
    );
    if (actions.isEmpty) {
      return const SizedBox.shrink();
    }
    return RevericIconButton(
      icon: RevericIcons.rocket_launch_outlined,
      tooltip: context.t(LocaleKeys.agentShortcutTitle),
      onPressed: () {
        final box = context.findRenderObject()! as RenderBox;
        showRevericContextMenu(
          context: context,
          position: box.localToGlobal(Offset(0, box.size.height)),
          entries: [
            for (final action in actions)
              RevericMenuItem(
                label: action.name,
                icon: RevericIcons.rocket_launch_outlined,
                onTap: () => onRunShortcutAction!(action),
              ),
          ],
        );
      },
    );
  }
}

@visibleForTesting
class NovelWorkspaceAutoSaveStatus extends StatefulWidget {
  const NovelWorkspaceAutoSaveStatus({
    super.key,
    required this.savedSignal,
    this.successDisplayDuration = const Duration(milliseconds: 1200),
    this.fadeDuration = const Duration(milliseconds: 180),
    this.now,
  });

  final ValueNotifier<int> savedSignal;
  final Duration successDisplayDuration;
  final Duration fadeDuration;
  final DateTime Function()? now;

  @override
  State<NovelWorkspaceAutoSaveStatus> createState() =>
      _NovelWorkspaceAutoSaveStatusState();
}

class _NovelWorkspaceAutoSaveStatusState
    extends State<NovelWorkspaceAutoSaveStatus> {
  Timer? _resetTimer;
  late int _lastSignal;
  DateTime? _savedAt;
  bool _showSuccess = false;

  @override
  void initState() {
    super.initState();
    _lastSignal = widget.savedSignal.value;
    widget.savedSignal.addListener(_handleSaved);
  }

  @override
  void didUpdateWidget(covariant NovelWorkspaceAutoSaveStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.savedSignal == widget.savedSignal) {
      return;
    }
    oldWidget.savedSignal.removeListener(_handleSaved);
    _lastSignal = widget.savedSignal.value;
    widget.savedSignal.addListener(_handleSaved);
  }

  void _handleSaved() {
    final signal = widget.savedSignal.value;
    if (signal == _lastSignal) {
      return;
    }
    _lastSignal = signal;
    _resetTimer?.cancel();
    setState(() {
      _savedAt = (widget.now ?? DateTime.now)();
      _showSuccess = true;
    });
    _resetTimer = Timer(widget.successDisplayDuration, () {
      if (!mounted) {
        return;
      }
      setState(() {
        _showSuccess = false;
      });
    });
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    widget.savedSignal.removeListener(_handleSaved);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final enabledLabel = context.t(LocaleKeys.workspaceAutoSaveEnabled);
    final succeededLabel = context.t(
      LocaleKeys.workspaceAutoSaveSucceeded,
      namedArgs: {
        'time': _savedAt == null ? '00:00:00' : _formatAutoSaveTime(_savedAt!),
      },
    );
    final sizingSucceededLabel = context.t(
      LocaleKeys.workspaceAutoSaveSucceeded,
      namedArgs: const {'time': '88:88:88'},
    );
    final effectiveFadeDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : widget.fadeDuration;
    final textStyle = typo.uiTiny.copyWith(color: colors.textMuted);

    return Semantics(
      key: const Key('auto-save-status-semantics'),
      liveRegion: _showSuccess,
      label: _showSuccess ? succeededLabel : enabledLabel,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevericIcon(
              RevericIcons.save_outlined,
              size: 12,
              color: colors.textMuted,
            ),
            const SizedBox(width: RevericSpacing.xs),
            Stack(
              alignment: Alignment.centerLeft,
              children: [
                Opacity(
                  opacity: 0,
                  child: Text(sizingSucceededLabel, style: textStyle),
                ),
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AnimatedOpacity(
                      key: const Key('auto-save-enabled-opacity'),
                      opacity: _showSuccess ? 0 : 1,
                      duration: effectiveFadeDuration,
                      curve: Curves.easeOutQuart,
                      child: Text(enabledLabel, style: textStyle),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AnimatedOpacity(
                      key: const Key('auto-save-success-opacity'),
                      opacity: _showSuccess ? 1 : 0,
                      duration: effectiveFadeDuration,
                      curve: Curves.easeOutQuart,
                      child: Text(succeededLabel, style: textStyle),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _formatAutoSaveTime(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  final second = local.second.toString().padLeft(2, '0');
  return '$hour:$minute:$second';
}

@visibleForTesting
class NovelWorkspaceStatusBarLayout extends StatelessWidget {
  const NovelWorkspaceStatusBarLayout({
    super.key,
    required this.primaryStatus,
    required this.secondaryStatus,
    required this.actions,
  });

  final Widget primaryStatus;
  final Widget? secondaryStatus;
  final Widget actions;

  @override
  Widget build(BuildContext context) {
    // 字数是章节编辑的核心状态，始终保留；空间不足时让操作区换行。
    return OverflowBar(
      alignment: MainAxisAlignment.spaceBetween,
      spacing: RevericSpacing.x3l,
      overflowAlignment: OverflowBarAlignment.start,
      overflowSpacing: RevericSpacing.sm,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 剧本正文的统计有六项，窄面板下要能折行；Row 直接塞会给子级
            // 无界宽度，Wrap 就永远不折，直接溢出。
            Flexible(child: primaryStatus),
            if (secondaryStatus != null) ...[
              const SizedBox(width: RevericSpacing.x3l),
              secondaryStatus!,
            ],
          ],
        ),
        actions,
      ],
    );
  }
}

/// 待处理变更数量徽标 — 自订阅 workingChanges，仅本徽标随变更重建，
/// 不连坐父级 NovelWorkspacePanel / ChapterEditor。
@visibleForTesting
int countReviewableWorkspaceChanges(Iterable<WorkingChange> changes) {
  return changes
      .where(
        (change) =>
            change.status == workingChangeStatusActive &&
            change.source == workingChangeSourceAi,
      )
      .length;
}

class _PendingChangesBadge extends ConsumerWidget {
  const _PendingChangesBadge({
    required this.databasePath,
    required this.onViewPendingChanges,
  });

  final String? databasePath;
  final VoidCallback onViewPendingChanges;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dbPath = databasePath;
    if (dbPath == null || dbPath.isEmpty) {
      return const SizedBox.shrink();
    }
    final changes = ref.watch(workingChangesProvider(dbPath)).asData?.value;
    final count = changes == null
        ? 0
        : countReviewableWorkspaceChanges(changes);
    if (count <= 0) {
      return const SizedBox.shrink();
    }
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.only(right: RevericSpacing.md),
      child: TextButton(
        onPressed: onViewPendingChanges,
        child: Text(
          context.t(
            LocaleKeys.workspaceChangesSummary,
            namedArgs: {'count': '$count'},
          ),
          style: typo.uiTiny.copyWith(color: colors.accent),
        ),
      ),
    );
  }
}

/// 章节编辑即时撤销/重做：每个字段维护独立历史，工具栏只路由到最近聚焦的字段。
class _ChapterUndoControls extends StatefulWidget {
  const _ChapterUndoControls({
    required this.titleUndoController,
    required this.outlineUndoController,
    required this.contentUndoController,
    required this.titleFocusNode,
    required this.outlineFocusNode,
    required this.contentFocusNode,
  });

  final UndoHistoryController titleUndoController;
  final UndoHistoryController outlineUndoController;
  final UndoHistoryController contentUndoController;
  final FocusNode titleFocusNode;
  final FocusNode outlineFocusNode;
  final FocusNode contentFocusNode;

  @override
  State<_ChapterUndoControls> createState() => _ChapterUndoControlsState();
}

class _ChapterUndoControlsState extends State<_ChapterUndoControls> {
  int? _activeFieldIndex;
  late final List<VoidCallback> _focusListeners = List<VoidCallback>.generate(
    3,
    (index) =>
        () => _handleFocusChanged(index),
  );

  List<UndoHistoryController> get _controllers => [
    widget.titleUndoController,
    widget.outlineUndoController,
    widget.contentUndoController,
  ];

  List<FocusNode> get _focusNodes => [
    widget.titleFocusNode,
    widget.outlineFocusNode,
    widget.contentFocusNode,
  ];

  @override
  void initState() {
    super.initState();
    _attachListeners();
  }

  @override
  void didUpdateWidget(covariant _ChapterUndoControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    final controllersChanged =
        oldWidget.titleUndoController != widget.titleUndoController ||
        oldWidget.outlineUndoController != widget.outlineUndoController ||
        oldWidget.contentUndoController != widget.contentUndoController;
    final focusNodesChanged =
        oldWidget.titleFocusNode != widget.titleFocusNode ||
        oldWidget.outlineFocusNode != widget.outlineFocusNode ||
        oldWidget.contentFocusNode != widget.contentFocusNode;
    if (!controllersChanged && !focusNodesChanged) {
      return;
    }
    _detachListeners(oldWidget);
    _activeFieldIndex = null;
    _attachListeners();
  }

  @override
  void dispose() {
    _detachListeners(widget);
    super.dispose();
  }

  void _attachListeners() {
    for (var index = 0; index < _focusNodes.length; index++) {
      _focusNodes[index].addListener(_focusListeners[index]);
      _controllers[index].addListener(_handleUndoHistoryChanged);
      if (_focusNodes[index].hasFocus) {
        _activeFieldIndex = index;
      }
    }
  }

  void _detachListeners(_ChapterUndoControls source) {
    final focusNodes = [
      source.titleFocusNode,
      source.outlineFocusNode,
      source.contentFocusNode,
    ];
    final controllers = [
      source.titleUndoController,
      source.outlineUndoController,
      source.contentUndoController,
    ];
    for (var index = 0; index < focusNodes.length; index++) {
      focusNodes[index].removeListener(_focusListeners[index]);
      controllers[index].removeListener(_handleUndoHistoryChanged);
    }
  }

  void _handleFocusChanged(int index) {
    if (_focusNodes[index].hasFocus && _activeFieldIndex != index) {
      setState(() => _activeFieldIndex = index);
    }
  }

  void _handleUndoHistoryChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _invoke({required bool redo}) {
    final index = _activeFieldIndex;
    if (index == null) {
      return;
    }
    final controller = _controllers[index];
    // UndoHistory 会恢复完整 TextEditingValue（含 selection）。先恢复编辑器焦点，
    // 避免 post-frame requestFocus 覆盖撤销刚恢复的光标位置。
    _focusNodes[index].requestFocus();
    if (redo) {
      controller.redo();
    } else {
      controller.undo();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final activeIndex = _activeFieldIndex;
    final activeController = activeIndex == null
        ? null
        : _controllers[activeIndex];
    final canUndo = activeController?.value.canUndo ?? false;
    final canRedo = activeController?.value.canRedo ?? false;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: context.t(LocaleKeys.workspaceUndo),
          onPressed: canUndo ? () => _invoke(redo: false) : null,
          icon: RevericIcon(
            RevericIcons.undo,
            size: 18,
            color: canUndo ? colors.textMuted : colors.textSubtle,
          ),
        ),
        IconButton(
          tooltip: context.t(LocaleKeys.workspaceRedo),
          onPressed: canRedo ? () => _invoke(redo: true) : null,
          icon: RevericIcon(
            RevericIcons.redo,
            size: 18,
            color: canRedo ? colors.textMuted : colors.textSubtle,
          ),
        ),
      ],
    );
  }
}

@visibleForTesting
class NovelWorkspaceChapterStatusMetrics extends StatelessWidget {
  const NovelWorkspaceChapterStatusMetrics({
    super.key,
    required this.controller,
  });

  final TextEditingController controller;

  void _showWordCountDetails(BuildContext context, String text) {
    showDialog<void>(
      context: context,
      builder: (_) => _WordCountDetailsDialog(text: text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return FrameSafeTextEditingValueBuilder(
      controller: controller,
      builder: (context, value, _) {
        final text = value.text;
        final wordCount = countTextUnits(text);
        final formattedWordCount = formatCompactWordCount(
          wordCount,
          languageCode: Localizations.localeOf(context).languageCode,
        );

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: context.t(
                LocaleKeys.workspaceReadingTime,
                namedArgs: {'minutes': '${(wordCount / 200).ceil()}'},
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(RevericRadius.small),
                onTap: () => _showWordCountDetails(context, text),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.xs,
                    vertical: RevericSpacing.xxs,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RevericIcon(
                        RevericIcons.text_fields_outlined,
                        size: 12,
                        color: colors.textMuted,
                      ),
                      const SizedBox(width: RevericSpacing.xs),
                      Text(
                        context.t(
                          LocaleKeys.workspaceWordCount,
                          namedArgs: {'count': formattedWordCount},
                        ),
                        style: typo.uiTiny.copyWith(color: colors.textMuted),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _WordCountDetailsDialog extends StatelessWidget {
  const _WordCountDetailsDialog({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final stats = countTextUnitStats(text);
    final screenSize = MediaQuery.sizeOf(context);
    final width = screenSize.width.clamp(420.0, 560.0);

    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RevericRadius.x2l),
        side: BorderSide(color: colors.borderSubtle),
      ),
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.all(RevericSpacing.x3l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  RevericIcon(
                    RevericIcons.text_fields_outlined,
                    size: 18,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  Expanded(
                    child: Text(
                      context.t(LocaleKeys.workspaceWordCountDetails),
                      style: typo.heading2.copyWith(color: colors.textPrimary),
                    ),
                  ),
                  IconButton(
                    tooltip: context.t(LocaleKeys.commonClose),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: RevericIcon(
                      RevericIcons.close_rounded,
                      size: 18,
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: RevericSpacing.sm),
              Text(
                context.t(LocaleKeys.workspaceWordCountDetailsHint),
                style: typo.uiSmall.copyWith(color: colors.textMuted),
              ),
              const SizedBox(height: RevericSpacing.x2l),
              _WordCountStatRow(
                label: context.t(LocaleKeys.workspaceWordUnits),
                value: stats.wordUnits,
                emphasized: true,
              ),
              _WordCountDivider(color: colors.borderSubtle),
              _WordCountStatRow(
                label: context.t(LocaleKeys.workspaceCjkCharacters),
                value: stats.cjkCharacters,
              ),
              _WordCountStatRow(
                label: context.t(LocaleKeys.workspaceLatinWords),
                value: stats.latinWords,
              ),
              _WordCountStatRow(
                label: context.t(LocaleKeys.workspacePunctuation),
                value: stats.punctuation,
              ),
              _WordCountStatRow(
                label: context.t(LocaleKeys.workspaceArabicDigits),
                value: stats.arabicDigits,
              ),
              _WordCountDivider(color: colors.borderSubtle),
              _WordCountStatRow(
                label: context.t(LocaleKeys.workspaceTextCharacters),
                value: stats.characters,
              ),
              _WordCountStatRow(
                label: context.t(LocaleKeys.workspaceWhitespace),
                value: stats.whitespace,
              ),
              _WordCountStatRow(
                label: context.t(LocaleKeys.workspaceIndents),
                value: stats.indents,
              ),
              _WordCountStatRow(
                label: context.t(LocaleKeys.workspaceParagraphs),
                value: stats.paragraphs,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WordCountStatRow extends StatelessWidget {
  const _WordCountStatRow({
    required this.label,
    required this.value,
    this.emphasized = false,
  });

  final String label;
  final int value;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final labelStyle = emphasized ? typo.uiSemibold : typo.ui;
    final valueStyle = emphasized ? typo.heading2 : typo.uiSemibold;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: RevericSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: labelStyle.copyWith(color: colors.textMuted),
            ),
          ),
          Text(
            _formatStatNumber(value),
            style: valueStyle.copyWith(color: colors.textPrimary),
          ),
        ],
      ),
    );
  }
}

class _WordCountDivider extends StatelessWidget {
  const _WordCountDivider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: RevericSpacing.xs),
      child: Divider(height: 1, thickness: 1, color: color),
    );
  }
}

String _formatStatNumber(int value) {
  final raw = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    final remaining = raw.length - i;
    buffer.write(raw[i]);
    if (remaining > 1 && remaining % 3 == 1) {
      buffer.write(',');
    }
  }
  return buffer.toString();
}

@visibleForTesting
class NovelWorkspaceSaveButton extends StatefulWidget {
  const NovelWorkspaceSaveButton({
    super.key,
    required this.onSave,
    required this.isLocked,
    this.minimumBusyDuration = const Duration(milliseconds: 400),
  });

  final Future<void> Function() onSave;
  final bool isLocked;
  final Duration minimumBusyDuration;

  @override
  State<NovelWorkspaceSaveButton> createState() =>
      _NovelWorkspaceSaveButtonState();
}

class _NovelWorkspaceSaveButtonState extends State<NovelWorkspaceSaveButton> {
  bool _isSaving = false;

  Future<void> _save() async {
    if (_isSaving || widget.isLocked) {
      return;
    }
    setState(() {
      _isSaving = true;
    });
    final stopwatch = Stopwatch()..start();
    try {
      await widget.onSave();
    } finally {
      final remaining = widget.minimumBusyDuration - stopwatch.elapsed;
      if (remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: (_isSaving || widget.isLocked) ? null : _save,
      child: Text(
        _isSaving
            ? context.t(LocaleKeys.commonSaving)
            : context.t(LocaleKeys.commonSave),
      ),
    );
  }
}

class _StatusBarPunctuationReplaceButton extends StatelessWidget {
  const _StatusBarPunctuationReplaceButton({
    required this.controller,
    required this.onSave,
  });

  final TextEditingController controller;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Tooltip(
      message: context.t(LocaleKeys.workspaceChapterReplace),
      child: TextButton.icon(
        onPressed: () {
          showChapterPunctuationReplace(
            context,
            contentController: controller,
            onReplace: (replaced) async {
              controller.value = TextEditingValue(
                text: replaced,
                selection: TextSelection.collapsed(offset: replaced.length),
              );
              await onSave();
            },
          );
        },
        icon: RevericIcon(
          RevericIcons.swap_horiz_rounded,
          size: 14,
          color: colors.textMuted,
        ),
        label: Text(context.t(LocaleKeys.workspaceChapterReplace)),
        style: TextButton.styleFrom(
          foregroundColor: colors.textMuted,
          padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.sm),
          minimumSize: const Size(0, RevericSizes.buttonHeightSm),
          textStyle: typo.uiTiny,
        ),
      ),
    );
  }
}

/// 提供本章排版按钮与全部章节排版菜单。
class _StatusBarAutoFormatButton extends ConsumerStatefulWidget {
  const _StatusBarAutoFormatButton({
    required this.controller,
    required this.onSave,
    this.databasePath,
  });

  final TextEditingController controller;
  final Future<void> Function() onSave;

  /// 当前小说内容库路径。为 null 时「格式化全部章节」不可用。
  final String? databasePath;

  @override
  ConsumerState<_StatusBarAutoFormatButton> createState() =>
      _StatusBarAutoFormatButtonState();
}

class _StatusBarAutoFormatButtonState
    extends ConsumerState<_StatusBarAutoFormatButton> {
  bool _formatAllRunning = false;

  void _formatCurrent() {
    final original = widget.controller.text;
    final formatted = formatText(
      original,
      indentCount: ref.read(editorFormatIndentCountProvider),
      blankLineBetweenParagraphs:
          ref.read(editorFormatParagraphSpacingProvider) ==
          EditorParagraphSpacing.one_blank_line,
      allowSpaces: ref.read(editorFormatAllowSpacesProvider),
    );
    if (formatted == original) {
      return;
    }
    widget.controller.value = TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }

  Future<void> _formatAll() async {
    final databasePath = widget.databasePath;
    if (databasePath == null || _formatAllRunning) {
      return;
    }
    // 先落盘当前章节，避免批量排版读到过期基线、或保存时把排版结果盖回旧文。
    await widget.onSave();
    if (!mounted) {
      return;
    }
    final service = ref.read(novelContentServiceProvider(databasePath));
    final indentCount = ref.read(editorFormatIndentCountProvider);
    final blankLineBetweenParagraphs =
        ref.read(editorFormatParagraphSpacingProvider) ==
        EditorParagraphSpacing.one_blank_line;
    final allowSpaces = ref.read(editorFormatAllowSpacesProvider);
    final chapterIds = await service.getChapterIdsWithContent();
    if (!mounted) {
      return;
    }
    final pendingCount = chapterIds.length;
    if (pendingCount == 0) {
      return;
    }
    final confirmed = await showConfirmDialog(
      context,
      title: context.t(LocaleKeys.workspaceChapterFormatConfirmTitle),
      message: context.t(
        LocaleKeys.workspaceChapterFormatConfirmMessage,
        namedArgs: {'count': '$pendingCount'},
      ),
    );
    if (!confirmed || !mounted) {
      return;
    }
    setState(() {
      _formatAllRunning = true;
    });
    try {
      final (count, error) = await showFormatAllProgressDialog(
        context,
        run: (onProgress) => formatAllChapterContents(
          contentService: service,
          chapterIds: chapterIds,
          indentCount: indentCount,
          blankLineBetweenParagraphs: blankLineBetweenParagraphs,
          allowSpaces: allowSpaces,
          onProgress: onProgress,
        ),
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error != null
                ? context.t(
                    LocaleKeys.workspaceChapterFormatFailed,
                    namedArgs: {'count': '$count'},
                  )
                : context.t(
                    LocaleKeys.workspaceChapterFormatDone,
                    namedArgs: {'count': '$count'},
                  ),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _formatAllRunning = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final formatAllAvailable =
        widget.databasePath != null && !_formatAllRunning;

    return FrameSafeTextEditingValueBuilder(
      controller: widget.controller,
      builder: (context, value, _) {
        final alreadyFormatted =
            value.text.isEmpty ||
            isChapterBodyFormatted(
              value.text,
              indentCount: ref.watch(editorFormatIndentCountProvider),
              blankLineBetweenParagraphs:
                  ref.watch(editorFormatParagraphSpacingProvider) ==
                  EditorParagraphSpacing.one_blank_line,
              allowSpaces: ref.watch(editorFormatAllowSpacesProvider),
            );

        // 左侧按钮点击直接排版本章；右侧箭头区域才弹出「格式化全部章节」菜单。
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: context.t(LocaleKeys.workspaceChapterAutoFormat),
              child: TextButton.icon(
                onPressed: alreadyFormatted ? null : _formatCurrent,
                icon: RevericIcon(
                  RevericIcons.auto_fix_high_outlined,
                  size: 14,
                  color: alreadyFormatted
                      ? colors.textSubtle
                      : colors.textMuted,
                ),
                label: Text(context.t(LocaleKeys.workspaceChapterAutoFormat)),
                style: TextButton.styleFrom(
                  foregroundColor: alreadyFormatted
                      ? colors.textSubtle
                      : colors.textMuted,
                  padding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.sm,
                  ),
                  minimumSize: const Size(0, RevericSizes.buttonHeightSm),
                  textStyle: typo.uiTiny,
                ),
              ),
            ),
            Builder(
              builder: (buttonContext) => RevericIconButton(
                icon: RevericIcons.expand_more,
                tooltip: context.t(LocaleKeys.commonMoreActions),
                onPressed: () {
                  final box = buttonContext.findRenderObject()! as RenderBox;
                  showRevericContextMenu(
                    context: context,
                    position: box.localToGlobal(Offset(0, box.size.height)),
                    entries: [
                      RevericMenuItem(
                        label: context.t(LocaleKeys.workspaceChapterFormatAll),
                        icon: RevericIcons.auto_fix_high_outlined,
                        enabled: formatAllAvailable,
                        onTap: _formatAll,
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

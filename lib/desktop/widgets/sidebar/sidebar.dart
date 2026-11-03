// 职责: 小说编辑侧边栏 — 组织工作区导航（rail 分组：系统/创作/世界观/AI）、AI 会话列表与小说切换入口。
// 关联文件:
//   lib/desktop/widgets/ai/chat/session_list.dart
//   lib/desktop/pages/novel_editor.dart
//   lib/shared/models/novel_workspace.dart
//   lib/desktop/widgets/sidebar/chapter_tree.dart
//   lib/shared/entity_graph/entity_list_section.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
import '../../../shared/app_config.dart';

import '../../../shared/widgets/plugin_view/navigation.dart';
import '../../../shared/widgets/plugin_view/page.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/collapsible_list_group.dart';
import '../../../shared/components/reveric_checkbox.dart';
import '../../../shared/components/reveric_context_menu.dart';
import '../../../shared/components/reveric_filter_chip.dart';
import '../../../shared/components/reveric_search_field.dart';
import '../../../shared/components/reveric_text_field.dart';
import '../../../shared/components/resizable_pane_divider.dart';
import '../../../shared/database/app_database.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/entity_graph/entity_graph.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/ai_session_mode.dart';
import '../../../shared/models/content_kind.dart';
import '../../../shared/models/novel_workspace.dart';
import '../../../shared/models/outline.dart';
import '../../../shared/models/subagent.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/providers/novel_workspace_state_provider.dart';
import '../../../shared/providers/screenplay_providers.dart';
import '../../../shared/providers/settings_providers.dart';
import '../../../shared/providers/subagent_providers.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/utils/chapter_tree_layout.dart';
import '../../../shared/widgets/confirm_dialog.dart';
import '../../../shared/widgets/screenplay/labels.dart';
import '../../features/cover_studio/records.dart';
import '../../features/canvas/widgets/canvas_list_panel.dart';
import '../../features/screenplay/context_panel.dart';
import '../ai/chat/session_list.dart';
import 'rail_only.dart';
import '../ai/mode_session_list_row.dart';
import '../context_column/context_column_scaffold.dart';
import '../desktop_window_frame.dart';
import '../user_profile_bar.dart';
import '../update_entry.dart';
import '../ai/feature_onboarding_dialog.dart';
import 'character_groups.dart';
import '../../../shared/components/reveric_dialog.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/widgets/media_asset_image.dart';

part 'rail.dart';
part 'sections.dart';
part 'chapter_tree.dart';
part 'menus.dart';
part 'header.dart';
part 'tree_items.dart';

class LeftSidebar extends ConsumerStatefulWidget {
  /// 展开态 rail 宽度（含文字标签）；内容直接在 Main 展示时侧栏仅保留此宽度。
  static const double railWidth = _leftSidebarRailWidth;

  const LeftSidebar({
    super.key,
    this.onBack,
    this.isCollapsed = false,
    this.expandedRailWidth = _leftSidebarRailWidth,
    this.sidebarWidth = RevericSizes.editorSidebarWidth,
    this.onRailWidthDragUpdate,
    this.onRailWidthDragEnd,
    required this.novelTitle,
    this.novelDescription,
    this.coverAssetId,
    required this.currentNovelId,
    required this.databasePath,
    this.contentKind = contentKindNovel,
    this.onPrepareWorkspaceTransition,
    required this.selection,
    required this.chapters,
    required this.worldbuildingEntries,
    required this.outlineEntries,
    required this.materialEntries,
    required this.characterProfiles,
    required this.skillEntries,
    required this.items,
    required this.factionEntries,
    required this.creatureEntries,
    required this.foreshadowings,
    required this.maps,
    required this.locations,
    required this.onSelect,
    this.onOpenCoverStudio = _noopVoidCallback,
    required this.onEditDetails,
    required this.onCreateChapter,
    required this.onCollapse,
    required this.onExpand,
    required this.onSwitchNovel,
    this.onCreateFolder,
    this.onCreateDocument,
    this.onImportOutline,
    this.onImportDocument,
    this.onCreateFolderInParent,
    this.onCreateDocumentInParent,
    this.onDeleteDocument,
    this.onRenameDocument,
    this.onDeleteItem,
    this.onDeleteChapter,
    this.onMoveToVolume,
    this.onUpdateChapterStat,
    this.onPublishChapter,
    this.onCreateVolume,
    this.onCreateChapterInVolume,
    this.aiChatSessions = const [],
    this.activeAiChatSessionId,
    this.onSelectAiChatSession,
    this.onCreateAiChatSession,
    this.onDeleteAiChatSession,
    this.onContinueAiChatSession,
    this.hasMoreAiChatSessions = false,
    this.isLoadingMoreAiChatSessions = false,
    this.onLoadMoreAiChatSessions,
    this.onSelectSubAgent,
    this.selectedSubAgentId,
    this.onShowAgentRules,
    this.onOpenAgentCouncil,
    this.onOpenCouncilWithSession,
    this.onOpenMonologue,
    this.onOpenMonologueWithSession,
    this.onOpenTheater,
    this.onOpenTheaterWithSession,
    this.onOpenRoleplay,
    this.onOpenRoleplayWithSession,
    this.onOpenMonologueWithId,
    this.isWorkspaceContentActive = true,
    this.isCoverStudioActive = false,
    this.isAiChatExpandedActive = false,
    this.isAgentCouncilActive = false,
    this.isMonologueActive = false,
    this.isTheaterActive = false,
    this.isRoleplayActive = false,
    this.isAgentRulesActive = false,
    this.activeCouncilSessionId,
    this.activeTheaterSessionId,
    this.activeMonologueSessionId,
    this.activeRoleplaySessionId,
  });

  final VoidCallback? onBack;
  final bool isCollapsed;
  final double expandedRailWidth;
  final double sidebarWidth;
  final ValueChanged<double>? onRailWidthDragUpdate;
  final VoidCallback? onRailWidthDragEnd;
  final String novelTitle;
  final String? novelDescription;
  final String? coverAssetId;
  final String currentNovelId;
  final String? databasePath;

  /// 作品类型（[contentKindNovel] / [contentKindScreenplay]）— 只决定 rail
  /// 创作组换成哪一套条目，其余四组两种类型共用。
  final String contentKind;

  /// 中栏内部切换（剧本换季 / 换集 / 换场次）前的落盘钩子，返回 false 表示拦下。
  /// rail 切 section 走的是 `onSelect`，由宿主页自己保存，不经过这里。
  final Future<bool> Function()? onPrepareWorkspaceTransition;

  final WorkspaceSelection selection;
  final List<Chapter> chapters;
  final List<Document> worldbuildingEntries;
  final List<OutlineDraft> outlineEntries;
  final List<Document> materialEntries;
  final List<CharacterProfile> characterProfiles;
  final List<Item> skillEntries;
  final List<Item> items;
  final List<Item> factionEntries;
  final List<Item> creatureEntries;
  final List<Foreshadowing> foreshadowings;
  final List<NovelMap> maps;
  final List<Location> locations;
  final ValueSetter<WorkspaceSelection> onSelect;
  final VoidCallback onOpenCoverStudio;
  final VoidCallback onEditDetails;
  final Future<void> Function() onCreateChapter;
  final Future<void> Function()? onCreateVolume;
  final Future<void> Function(String volumeId)? onCreateChapterInVolume;
  final VoidCallback onCollapse;
  final VoidCallback onExpand;
  final ValueSetter<Novel> onSwitchNovel;
  final Future<void> Function(NovelWorkspaceSection section)? onCreateFolder;
  final Future<void> Function(NovelWorkspaceSection section)? onCreateDocument;
  final Future<void> Function()? onImportOutline;
  final Future<void> Function(NovelWorkspaceSection section, String? parentId)?
  onImportDocument;
  final Future<void> Function(String parentId)? onCreateFolderInParent;
  final Future<void> Function(String parentId)? onCreateDocumentInParent;
  final Future<void> Function(String documentId)? onDeleteDocument;
  final Future<void> Function(
    String documentId,
    String newTitle, {
    String? category,
  })?
  onRenameDocument;
  // 新增通过侧边栏条目菜单删除的 workspace section 时，必须同步处理
  // lib/desktop/pages/novel_editor.dart 中 LeftSidebar.onDeleteItem 的 switch。
  // 文档、章节、地图地点使用各自独立的删除回调，不走这里。
  final Future<void> Function(NovelWorkspaceSection section, String itemId)?
  onDeleteItem;
  final Future<void> Function(String chapterId)? onDeleteChapter;
  final Future<void> Function(String chapterId, String volumeId)?
  onMoveToVolume;
  final Future<void> Function(String chapterId, String stat)?
  onUpdateChapterStat;
  final Future<void> Function(String chapterId, bool useChronicler)?
  onPublishChapter;
  final List<AiChatSession> aiChatSessions;
  final String? activeAiChatSessionId;
  final ValueSetter<String>? onSelectAiChatSession;
  final VoidCallback? onCreateAiChatSession;
  final ValueSetter<String>? onDeleteAiChatSession;
  final ValueSetter<String>? onContinueAiChatSession;
  final bool hasMoreAiChatSessions;
  final bool isLoadingMoreAiChatSessions;
  final VoidCallback? onLoadMoreAiChatSessions;
  final ValueChanged<SubAgent>? onSelectSubAgent;
  final String? selectedSubAgentId;
  final VoidCallback? onShowAgentRules;
  final VoidCallback? onOpenAgentCouncil;
  final ValueChanged<String>? onOpenCouncilWithSession;
  final VoidCallback? onOpenMonologue;
  final ValueChanged<String>? onOpenMonologueWithSession;
  final VoidCallback? onOpenTheater;
  final ValueChanged<String>? onOpenTheaterWithSession;
  final VoidCallback? onOpenRoleplay;
  final ValueChanged<String>? onOpenRoleplayWithSession;
  final ValueChanged<String>? onOpenMonologueWithId;
  final bool isWorkspaceContentActive;
  final bool isCoverStudioActive;
  final bool isAiChatExpandedActive;
  final bool isAgentCouncilActive;
  final bool isMonologueActive;
  final bool isTheaterActive;
  final bool isRoleplayActive;

  /// Main 正在展示规则列表/编辑时，侧栏仅保留 Rail（中栏收起）。
  final bool isAgentRulesActive;
  final String? activeCouncilSessionId;
  final String? activeTheaterSessionId;
  final String? activeMonologueSessionId;
  final String? activeRoleplaySessionId;

  @override
  ConsumerState<LeftSidebar> createState() => _LeftSidebarState();
}

enum _PanelMode { content, aiChats }

enum _AgentItem { subagents, agentRules, council, monologue, theater, roleplay }

const double _leftSidebarRailWidth = 132;
const double _leftSidebarRailCollapsedWidth = 48;
const String _iconBookOpen = 'assets/icons/phosphor/book-open.svg';
const String _iconListNumbers = 'assets/icons/phosphor/list-numbers.svg';
const String _iconUsers = 'assets/icons/phosphor/users.svg';
const String _iconGlobeSimple = 'assets/icons/phosphor/globe-simple.svg';
const String _iconMapTrifold = 'assets/icons/phosphor/map-trifold.svg';
const String _iconFlagPennant = 'assets/icons/phosphor/flag-pennant.svg';
const String _iconUsersThree = 'assets/icons/phosphor/users-three.svg';
const String _iconPackage = 'assets/icons/phosphor/package.svg';
const String _iconLightning = 'assets/icons/phosphor/lightning.svg';
const String _iconFolderSimpleStar =
    'assets/icons/phosphor/folder-simple-star.svg';
const String _iconChats = 'assets/icons/phosphor/chats.svg';
const String _iconShield = 'assets/icons/phosphor/shield.svg';
const String _iconGridNine = 'assets/icons/phosphor/grid-nine.svg';
const String _iconTreeStructure = 'assets/icons/phosphor/tree-structure.svg';
const String _iconTrendUp = 'assets/icons/phosphor/trend-up.svg';
const String _iconFrameCorners = 'assets/icons/phosphor/frame-corners.svg';
const String _iconPlus = 'assets/icons/phosphor/plus.svg';
const String _iconFileText = 'assets/icons/phosphor/file-text.svg';
const String _iconFolderPlus = 'assets/icons/phosphor/folder-plus.svg';
const String _iconSortAscending = 'assets/icons/phosphor/sort-ascending.svg';
const String _iconSortDescending = 'assets/icons/phosphor/sort-descending.svg';
const String _iconNotePencil = 'assets/icons/phosphor/note-pencil.svg';
const String _iconPencilSimple = 'assets/icons/phosphor/pencil-simple.svg';
const String _iconTrashSimple = 'assets/icons/phosphor/trash-simple.svg';
const String _iconCaretDown = 'assets/icons/phosphor/caret-down.svg';
const String _iconX = 'assets/icons/phosphor/x.svg';
const String _iconCheck = 'assets/icons/phosphor/check.svg';
const String _iconCheckCircle = 'assets/icons/phosphor/check-circle.svg';
const String _iconArrowCounterClockwise =
    'assets/icons/phosphor/arrow-counter-clockwise.svg';
const String _iconFolderOpen = 'assets/icons/phosphor/folder-open.svg';
const String _iconFolder = 'assets/icons/phosphor/folder.svg';
const String _iconUser = 'assets/icons/phosphor/user.svg';
const String _iconCaretRight = 'assets/icons/phosphor/caret-right.svg';
const String _iconFilmStrip = 'assets/icons/phosphor/film-strip.svg';
const String _iconChatCentered = 'assets/icons/phosphor/chat-centered.svg';
const String _iconBugBeetle = 'assets/icons/phosphor/bug-beetle.svg';
const String _iconImageSquare = 'assets/icons/phosphor/image-square.svg';
const String _iconUsersFour = 'assets/icons/phosphor/users-four.svg';
const String _iconArticle = 'assets/icons/phosphor/article.svg';
const String _iconSquaresFour = 'assets/icons/phosphor/squares-four.svg';

void _noopVoidCallback() {}

class _LeftSidebarState extends ConsumerState<LeftSidebar> {
  _PanelMode _panelMode = _PanelMode.content;

  /// 上一次访问的「内容型」section，用于在 overview/search 等
  /// 无列表 section 激活时，panel 仍能展示一份用户最近看的内容列表。
  /// 初值按作品类型给：剧本作品落到剧本，否则中栏一进来就是章节列表。
  late NovelWorkspaceSection _lastContentSection;

  final Map<NovelWorkspaceSection, String> _sectionSearchQueries = {};

  static const Duration _sectionSearchDebounceDuration = Duration(
    milliseconds: 250,
  );

  /// 图鉴中栏的类型筛选，null 表示展示全部四类。
  NovelWorkspaceSection? _compendiumFilter;

  /// 图鉴中栏的搜索词 — 四类共用一个输入框，不走 [_sectionSearchQueries]。
  String _compendiumSearchQuery = '';

  /// 上一次在图鉴内查看的类型，决定 rail 点「图鉴」后的落点 section。
  NovelWorkspaceSection _lastCompendiumSection = NovelWorkspaceSection.factions;

  /// 图鉴中被折叠的分组。分组与条目在 `ListView.builder` 里拍平成行以保持
  /// 惰性构建，因此展开态由这里持有，而不是各分组自己 setState。
  /// 默认全部折叠：四类合计可达上千条，一进来就铺开没法用。
  final Set<NovelWorkspaceSection> _collapsedCompendiumGroups = {
    ...compendiumSections,
  };

  _AgentItem? _activeAgentItem;

  /// Main 被封面工作台 / Agent 等独占时为 true；rail 内容项不得同时高亮。
  bool get _hasAuxiliaryContentSelection =>
      widget.isCoverStudioActive ||
      widget.selectedSubAgentId != null ||
      widget.isAgentCouncilActive ||
      widget.isMonologueActive ||
      widget.isTheaterActive ||
      widget.isRoleplayActive ||
      widget.isAgentRulesActive;

  static bool _isContentSection(NovelWorkspaceSection section) {
    switch (section) {
      case NovelWorkspaceSection.chapters:
      case NovelWorkspaceSection.outlines:
      case NovelWorkspaceSection.characters:
      case NovelWorkspaceSection.lore:
      case NovelWorkspaceSection.materials:
      case NovelWorkspaceSection.foreshadowings:
      case NovelWorkspaceSection.factions:
      case NovelWorkspaceSection.creatures:
      case NovelWorkspaceSection.items:
      case NovelWorkspaceSection.skills:
      case NovelWorkspaceSection.novel_description:
      case NovelWorkspaceSection.entity_graph:
      case NovelWorkspaceSection.canvas:
      // 剧本四个 section 共用同一棵季 / 集 / 场次树当中栏。
      case NovelWorkspaceSection.screenplay_script:
      case NovelWorkspaceSection.screenplay_outline:
      case NovelWorkspaceSection.storyboard:
      case NovelWorkspaceSection.screenplay_scenes:
        return true;
      // 地图工作台自带地点树与地图列表，与 overview 一样整体占用 Main，
      // 不再展开中栏。
      case NovelWorkspaceSection.maps:
      case NovelWorkspaceSection.overview:
      // 当前进展没有二级列表，和 overview 同类。
      case NovelWorkspaceSection.story_progress:
        return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _lastContentSection = widget.contentKind == contentKindScreenplay
        ? NovelWorkspaceSection.screenplay_script
        : NovelWorkspaceSection.chapters;
    if (_isContentSection(widget.selection.section)) {
      _lastContentSection = widget.selection.section;
    }
    if (isCompendiumSection(widget.selection.section)) {
      _lastCompendiumSection = widget.selection.section;
    }
  }

  /// 同步外部状态：
  /// - 选中 subagent / skill / 模式 → 设置对应 _activeAgentItem
  /// - 选中某个内容 section → 记下来作为「最近访问的内容 section」
  @override
  void didUpdateWidget(covariant LeftSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedSubAgentId != null &&
        widget.selectedSubAgentId != oldWidget.selectedSubAgentId) {
      _activeAgentItem = _AgentItem.subagents;
    } else if (widget.isAgentCouncilActive && !oldWidget.isAgentCouncilActive) {
      _activeAgentItem = _AgentItem.council;
    } else if (widget.isMonologueActive && !oldWidget.isMonologueActive) {
      _activeAgentItem = _AgentItem.monologue;
    } else if (widget.isTheaterActive && !oldWidget.isTheaterActive) {
      _activeAgentItem = _AgentItem.theater;
    } else if (widget.isRoleplayActive && !oldWidget.isRoleplayActive) {
      _activeAgentItem = _AgentItem.roleplay;
    } else if (widget.isAgentRulesActive && !oldWidget.isAgentRulesActive) {
      _activeAgentItem = _AgentItem.agentRules;
    }

    if (_isContentSection(widget.selection.section) &&
        widget.selection.section != oldWidget.selection.section) {
      _lastContentSection = widget.selection.section;
      if (isCompendiumSection(widget.selection.section)) {
        _lastCompendiumSection = widget.selection.section;
      }
      if (!_hasAuxiliaryContentSelection) {
        _activeAgentItem = null;
      }
      if (_panelMode != _PanelMode.content && !_hasAuxiliaryContentSelection) {
        _panelMode = _PanelMode.content;
      }
    }
  }

  void _activatePanel(_PanelMode mode) {
    if (_panelMode == mode) {
      return;
    }
    setState(() {
      _panelMode = mode;
      _activeAgentItem = null;
    });
    if (mode == _PanelMode.aiChats) {
      final activeSessionId = widget.activeAiChatSessionId;
      if (activeSessionId != null) {
        widget.onSelectAiChatSession?.call(activeSessionId);
      } else {
        widget.onCreateAiChatSession?.call();
      }
    }
  }

  void _activateAgentItem(_AgentItem item) {
    setState(() {
      _panelMode = _PanelMode.content;
      _activeAgentItem = item;
    });
    _maybeShowOnboardingForItem(item);
    switch (item) {
      case _AgentItem.council:
        widget.onOpenAgentCouncil?.call();
      case _AgentItem.monologue:
        widget.onOpenMonologue?.call();
      case _AgentItem.theater:
        widget.onOpenTheater?.call();
      case _AgentItem.roleplay:
        widget.onOpenRoleplay?.call();
      case _AgentItem.agentRules:
        widget.onShowAgentRules?.call();
      case _AgentItem.subagents:
        break;
    }
  }

  void _maybeShowOnboardingForItem(_AgentItem item) async {
    final type = switch (item) {
      _AgentItem.council => FeatureOnboardingType.council,
      _AgentItem.monologue => FeatureOnboardingType.monologue,
      _AgentItem.theater => FeatureOnboardingType.theater,
      _AgentItem.roleplay => FeatureOnboardingType.roleplay,
      _AgentItem.agentRules => FeatureOnboardingType.agentRules,
      _ => null,
    };
    if (type == null) return;
    await triggerFeatureOnboardingIfNeeded(context, ref, type);
  }

  void _activateSystemSection(NovelWorkspaceSection section) {
    setState(() {
      _panelMode = _PanelMode.content;
      _activeAgentItem = null;
    });
    widget.onSelect(WorkspaceSelection(section: section));
  }

  void _activateContentSection(NovelWorkspaceSection section) {
    setState(() {
      _panelMode = _PanelMode.content;
      _lastContentSection = section;
      if (isCompendiumSection(section)) {
        _lastCompendiumSection = section;
      }
      _activeAgentItem = null;
    });
    widget.onSelect(
      WorkspaceSelection(
        section: section,
        itemId: widget.selection.section == section
            ? widget.selection.itemId
            : null,
      ),
    );
  }

  Set<String> _expandedFolderIds(NovelWorkspaceSection section) {
    return ref
        .read(novelWorkspaceStateControllerProvider(widget.currentNovelId))
        .expandedNodeIdsFor(section);
  }

  void _toggleExpandedFolder(NovelWorkspaceSection section, String documentId) {
    ref
        .read(
          novelWorkspaceStateControllerProvider(widget.currentNovelId).notifier,
        )
        .toggleExpandedNode(section, documentId);
  }

  void _expandFolder(NovelWorkspaceSection section, String documentId) {
    ref
        .read(
          novelWorkspaceStateControllerProvider(widget.currentNovelId).notifier,
        )
        .ensureExpandedNode(section, documentId);
  }

  String _searchQueryForSection(NovelWorkspaceSection section) {
    return (_sectionSearchQueries[section] ?? '').trim();
  }

  bool _hasSearchQueryForSection(NovelWorkspaceSection section) {
    return _searchQueryForSection(section).isNotEmpty;
  }

  bool _matchesSearchQuery(NovelWorkspaceSection section, String value) {
    final query = _searchQueryForSection(section).toLowerCase();
    if (query.isEmpty) {
      return true;
    }
    return value.toLowerCase().contains(query);
  }

  void _setSearchQueryForSection(NovelWorkspaceSection section, String value) {
    if (_sectionSearchQueries[section] == value) {
      return;
    }
    setState(() {
      _sectionSearchQueries[section] = value;
    });
  }

  void _setCompendiumFilter(NovelWorkspaceSection? section) {
    if (_compendiumFilter == section) {
      return;
    }
    setState(() {
      _compendiumFilter = section;
      // 筛到具体类型就是想看这一类，保持折叠会让面板看着是空的。
      if (section != null) {
        _collapsedCompendiumGroups.remove(section);
      }
    });
  }

  void _setCompendiumSearchQuery(String value) {
    if (_compendiumSearchQuery == value) {
      return;
    }
    setState(() {
      _compendiumSearchQuery = value;
    });
  }

  void _toggleCompendiumGroup(NovelWorkspaceSection section) {
    setState(() {
      if (!_collapsedCompendiumGroups.remove(section)) {
        _collapsedCompendiumGroups.add(section);
      }
    });
  }

  /// 当前 panel 应展示哪个内容 section。
  NovelWorkspaceSection get _displayedContentSection {
    final current = widget.selection.section;
    if (_isContentSection(current)) return current;
    return _lastContentSection;
  }

  /// 规则内容在 Main，中栏与 Main 列表重复，仅保留 Rail。
  /// 以父级 contentSelection 标志为准，避免仅依赖本地 _activeAgentItem
  /// 时外层 AnimatedContainer 仍占满 editorSidebarWidth 留下空中栏。
  bool get _railOnlyAgentItem {
    return widget.isAgentRulesActive;
  }

  /// overview 等内容直接在 Main，不展示中栏。
  /// 封面工作台保留中栏，用来挂生成记录（见 `_buildPanelBody`）。
  bool get _railOnlyWorkspaceSection {
    return widget.isWorkspaceContentActive &&
        isRailOnlyWorkspaceSection(widget.selection.section);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(
      novelWorkspaceStateControllerProvider(
        widget.currentNovelId,
      ).select((state) => state.expandedNodeIdsFor(_lastContentSection)),
    );
    final colors = RevericTheme.colorsOf(context);
    final railWidth = widget.isCollapsed
        ? _leftSidebarRailCollapsedWidth
        : widget.expandedRailWidth;
    // overview / 技能 / 规则：内容在 Main，侧栏仅保留 Rail。
    if (!widget.isCollapsed &&
        (_railOnlyWorkspaceSection || _railOnlyAgentItem)) {
      return ClipRect(
        child: SizedBox(
          width: widget.expandedRailWidth,
          child: _buildRail(context),
        ),
      );
    }
    final dividerLink = LayerLink();
    return ClipRect(
      child: SizedBox(
        width: widget.sidebarWidth,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: railWidth,
              child: RepaintBoundary(child: _buildRail(context)),
            ),
            Positioned(
              left: railWidth,
              top: 0,
              bottom: 0,
              width: widget.sidebarWidth - railWidth,
              child: IgnorePointer(
                ignoring: widget.isCollapsed,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.onRailWidthDragUpdate != null &&
                        widget.onRailWidthDragEnd != null)
                      ResizablePaneDividerAnchor(link: dividerLink)
                    else
                      VerticalDivider(
                        width: RevericSizes.dividerThickness,
                        thickness: RevericSizes.dividerThickness,
                        color: colors.border,
                      ),
                    Expanded(
                      child: RepaintBoundary(child: _buildPanel(context)),
                    ),
                  ],
                ),
              ),
            ),
            if (!widget.isCollapsed &&
                widget.onRailWidthDragUpdate != null &&
                widget.onRailWidthDragEnd != null)
              ResizablePaneDivider(
                link: dividerLink,
                onDragUpdate: widget.onRailWidthDragUpdate!,
                onDragEnd: widget.onRailWidthDragEnd!,
              ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Rail (左侧列：图标 + 文字标签导航)
  // ---------------------------------------------------------------------------
}

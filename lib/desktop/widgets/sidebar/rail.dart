// 职责: 作品编辑侧边栏 — 以声明式导航表构建左侧 rail（图标 + 文字标签），分组展示系统/创作/世界观/AI/灵感 五组，创作组按作品类型（小说 / 剧本）分叉，底部内嵌用户资料栏，折叠态显示展开按钮并隐藏 label。
// 关联文件:
//   lib/desktop/widgets/sidebar/sidebar.dart
//   lib/desktop/widgets/sidebar/header.dart
//   lib/desktop/widgets/user_profile_bar.dart
//   lib/shared/models/content_kind.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/desktop-window-frame.md
//   .agents/rules/icons.md
part of 'sidebar.dart';

// ---------------------------------------------------------------------------
// 导航表模型
// ---------------------------------------------------------------------------

/// Rail 入口的跳转目标 — 同时决定点击行为（[_activateRailTarget]）
/// 与高亮判定（[_isRailTargetSelected]）。
sealed class _RailTarget {
  const _RailTarget();
}

/// 内容型 section：中栏展示自己的列表，仅在 panel 处于内容模式时高亮。
final class _RailContentTarget extends _RailTarget {
  const _RailContentTarget(this.section);

  final NovelWorkspaceSection section;
}

/// 系统型 section：内容直接在 Main，高亮只看当前 selection。
final class _RailSystemTarget extends _RailTarget {
  const _RailSystemTarget(this.section);

  final NovelWorkspaceSection section;
}

/// 封面工作台：Main 独占，中栏改挂生成记录。
final class _RailCoverStudioTarget extends _RailTarget {
  const _RailCoverStudioTarget();
}

/// AI 会话列表：只切 panel 模式，不改 selection。
final class _RailAiChatsTarget extends _RailTarget {
  const _RailAiChatsTarget();
}

/// Agent 类入口（各对话模式 / 规则）。
final class _RailAgentTarget extends _RailTarget {
  const _RailAgentTarget(this.item);

  final _AgentItem item;
}

/// 图鉴：势力 / 生物 / 物品 / 技能四类共用一个入口，中栏按类型分组。
/// 四类中任一 section 激活时都算选中；落点是上次查看的类型。
final class _RailCompendiumTarget extends _RailTarget {
  const _RailCompendiumTarget();
}

/// Rail 单行入口。[labelKey] 同时用作 tooltip 与展开态标签。
class _RailEntry {
  const _RailEntry({
    required this.icon,
    required this.labelKey,
    required this.target,
  });

  final String icon;
  final String labelKey;
  final _RailTarget target;
}

/// Rail 分组。组与组之间渲染分割线，[headerKey] 仅在展开态显示。
class _RailGroup {
  const _RailGroup({required this.headerKey, required this.entries});

  final String headerKey;
  final List<_RailEntry> entries;
}

/// Rail 导航表 — 新增/调整入口在此改表，不要回到手写 `_buildRailIcon`。
/// 图标不得在表内重复：折叠态只剩图标时重复图标无法区分。
///
/// 小说与剧本共用系统 / 世界观 / AI / 灵感四组，只有创作组分叉
/// （[_writingGroupNovel] 与 [_writingGroupScreenplay]），由
/// [_railGroupsFor] 按作品类型拼装。
const _RailGroup _systemGroup = _RailGroup(
  headerKey: LocaleKeys.workspaceSidebarGroupSystem,
  entries: <_RailEntry>[
    _RailEntry(
      icon: _iconGridNine,
      labelKey: LocaleKeys.workspaceOverview,
      target: _RailSystemTarget(NovelWorkspaceSection.overview),
    ),
    _RailEntry(
      icon: _iconTreeStructure,
      labelKey: LocaleKeys.workspaceSidebarEntityGraph,
      target: _RailSystemTarget(NovelWorkspaceSection.entity_graph),
    ),
    _RailEntry(
      icon: _iconTrendUp,
      labelKey: LocaleKeys.workspaceStoryProgress,
      target: _RailSystemTarget(NovelWorkspaceSection.story_progress),
    ),
    if (ideationCanvasEnabled)
      _RailEntry(
        icon: _iconFrameCorners,
        labelKey: LocaleKeys.workspaceCanvas,
        target: _RailSystemTarget(NovelWorkspaceSection.canvas),
      ),
    _RailEntry(
      icon: _iconImageSquare,
      labelKey: LocaleKeys.editorCoverNavLabel,
      target: _RailCoverStudioTarget(),
    ),
  ],
);

const _RailGroup _writingGroupNovel = _RailGroup(
  headerKey: LocaleKeys.workspaceSidebarGroupWriting,
  entries: <_RailEntry>[
    _RailEntry(
      icon: _iconBookOpen,
      labelKey: LocaleKeys.workspaceChapters,
      target: _RailContentTarget(NovelWorkspaceSection.chapters),
    ),
    _RailEntry(
      icon: _iconListNumbers,
      labelKey: LocaleKeys.workspaceSidebarOutline,
      target: _RailContentTarget(NovelWorkspaceSection.outlines),
    ),
    _RailEntry(
      icon: _iconUsers,
      labelKey: LocaleKeys.workspaceCharacters,
      target: _RailContentTarget(NovelWorkspaceSection.characters),
    ),
    _RailEntry(
      icon: _iconFlagPennant,
      labelKey: LocaleKeys.workspaceSidebarForeshadowing,
      target: _RailContentTarget(NovelWorkspaceSection.foreshadowings),
    ),
    _RailEntry(
      icon: _iconFolderSimpleStar,
      labelKey: LocaleKeys.workspaceSidebarAssets,
      target: _RailContentTarget(NovelWorkspaceSection.materials),
    ),
  ],
);

/// 剧本的创作组。角色出场矩阵不在这里 —— 它是场次区域的第三个视图。
const _RailGroup _writingGroupScreenplay = _RailGroup(
  headerKey: LocaleKeys.workspaceSidebarGroupWriting,
  entries: <_RailEntry>[
    _RailEntry(
      icon: _iconArticle,
      labelKey: LocaleKeys.screenplayScript,
      target: _RailContentTarget(NovelWorkspaceSection.screenplay_script),
    ),
    _RailEntry(
      icon: _iconListNumbers,
      labelKey: LocaleKeys.screenplayOutline,
      target: _RailContentTarget(NovelWorkspaceSection.screenplay_outline),
    ),
    _RailEntry(
      icon: _iconUsers,
      labelKey: LocaleKeys.workspaceCharacters,
      target: _RailContentTarget(NovelWorkspaceSection.characters),
    ),
    _RailEntry(
      icon: _iconFlagPennant,
      labelKey: LocaleKeys.workspaceSidebarForeshadowing,
      target: _RailContentTarget(NovelWorkspaceSection.foreshadowings),
    ),
    _RailEntry(
      icon: _iconSquaresFour,
      labelKey: LocaleKeys.screenplayScenes,
      target: _RailContentTarget(NovelWorkspaceSection.screenplay_scenes),
    ),
    _RailEntry(
      icon: _iconSquaresFour,
      labelKey: LocaleKeys.productionTitle,
      target: _RailContentTarget(NovelWorkspaceSection.storyboard),
    ),
    _RailEntry(
      icon: _iconFolderSimpleStar,
      labelKey: LocaleKeys.workspaceSidebarAssets,
      target: _RailContentTarget(NovelWorkspaceSection.materials),
    ),
  ],
);

const _RailGroup _worldGroup = _RailGroup(
  headerKey: LocaleKeys.workspaceSidebarGroupWorld,
  entries: <_RailEntry>[
    _RailEntry(
      icon: _iconGlobeSimple,
      labelKey: LocaleKeys.workspaceLore,
      target: _RailContentTarget(NovelWorkspaceSection.lore),
    ),
    _RailEntry(
      icon: _iconMapTrifold,
      labelKey: LocaleKeys.workspaceSidebarMap,
      target: _RailContentTarget(NovelWorkspaceSection.maps),
    ),
    _RailEntry(
      icon: _iconPackage,
      labelKey: LocaleKeys.workspaceSidebarCompendium,
      target: _RailCompendiumTarget(),
    ),
  ],
);

const _RailGroup _aiGroup = _RailGroup(
  headerKey: LocaleKeys.workspaceSidebarGroupAi,
  entries: <_RailEntry>[
    _RailEntry(
      icon: _iconChats,
      labelKey: LocaleKeys.workspaceChats,
      target: _RailAiChatsTarget(),
    ),
    _RailEntry(
      icon: _iconShield,
      labelKey: LocaleKeys.agentRuleTitle,
      target: _RailAgentTarget(_AgentItem.agentRules),
    ),
  ],
);

const _RailGroup _inspirationGroup = _RailGroup(
  headerKey: LocaleKeys.workspaceSidebarGroupInspiration,
  entries: <_RailEntry>[
    _RailEntry(
      icon: _iconUsersFour,
      labelKey: LocaleKeys.aiSessionModeCouncil,
      target: _RailAgentTarget(_AgentItem.council),
    ),
    _RailEntry(
      icon: _iconUser,
      labelKey: LocaleKeys.aiSessionModeMonologue,
      target: _RailAgentTarget(_AgentItem.monologue),
    ),
    _RailEntry(
      icon: _iconFilmStrip,
      labelKey: LocaleKeys.aiSessionModeTheater,
      target: _RailAgentTarget(_AgentItem.theater),
    ),
    _RailEntry(
      icon: _iconChatCentered,
      labelKey: LocaleKeys.aiSessionModeRoleplay,
      target: _RailAgentTarget(_AgentItem.roleplay),
    ),
  ],
);

const List<_RailGroup> _railGroupsNovel = <_RailGroup>[
  _systemGroup,
  _writingGroupNovel,
  _worldGroup,
  _aiGroup,
  _inspirationGroup,
];

const List<_RailGroup> _railGroupsScreenplay = <_RailGroup>[
  _systemGroup,
  _writingGroupScreenplay,
  _worldGroup,
  _aiGroup,
  _inspirationGroup,
];

List<_RailGroup> _railGroupsFor(String contentKind) {
  return contentKind == contentKindScreenplay
      ? _railGroupsScreenplay
      : _railGroupsNovel;
}

/// 测试用：按渲染顺序取出各分组的条目 labelKey。
/// `_RailGroup` 是库私有类型，测试拿不到，只能通过 labelKey 断言导航表。
@visibleForTesting
List<List<String>> railGroupLabelKeysFor(String contentKind) {
  return <List<String>>[
    for (final group in _railGroupsFor(contentKind))
      <String>[for (final entry in group.entries) entry.labelKey],
  ];
}

extension _LeftSidebarRail on _LeftSidebarState {
  List<_RailGroup> get _resolvedRailGroups =>
      _railGroupsFor(widget.contentKind);
  bool _isRailTargetSelected(_RailTarget target) {
    final hasExclusiveMain = _hasAuxiliaryContentSelection;
    final selectionSection = widget.selection.section;
    return switch (target) {
      _RailContentTarget(:final section) =>
        !hasExclusiveMain &&
            _panelMode == _PanelMode.content &&
            selectionSection == section,
      _RailSystemTarget(:final section) =>
        !hasExclusiveMain && selectionSection == section,
      _RailCompendiumTarget() =>
        !hasExclusiveMain &&
            _panelMode == _PanelMode.content &&
            isCompendiumSection(selectionSection),
      _RailCoverStudioTarget() => widget.isCoverStudioActive,
      _RailAiChatsTarget() =>
        widget.isAiChatExpandedActive ||
            (!hasExclusiveMain && _panelMode == _PanelMode.aiChats),
      _RailAgentTarget(:final item) => _activeAgentItem == item,
    };
  }

  void _activateRailTarget(_RailTarget target) {
    switch (target) {
      case _RailContentTarget(:final section):
        _activateContentSection(section);
      case _RailSystemTarget(:final section):
        _activateSystemSection(section);
      case _RailCompendiumTarget():
        _activateContentSection(_lastCompendiumSection);
      case _RailCoverStudioTarget():
        widget.onOpenCoverStudio();
      case _RailAiChatsTarget():
        _activatePanel(_PanelMode.aiChats);
      case _RailAgentTarget(:final item):
        _activateAgentItem(item);
    }
  }

  Widget _buildRail(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final showLabels = !widget.isCollapsed;
    final railWidth = widget.isCollapsed
        ? _leftSidebarRailCollapsedWidth
        : widget.expandedRailWidth;
    final showCollapseInRail =
        !widget.isCollapsed &&
        (_railOnlyWorkspaceSection || _railOnlyAgentItem);
    final collapseFitsTitleBar =
        railWidth >=
        DesktopWindowFrame.sidebarLeadingInset +
            RevericSpacing.sm +
            RevericSizes.iconButtonSize;

    final groups = _resolvedRailGroups;
    final navChildren = <Widget>[];
    for (var i = 0; i < groups.length; i++) {
      if (i > 0) {
        navChildren.add(_buildRailDivider(context));
      }
      final group = groups[i];
      if (showLabels) {
        navChildren.add(
          _buildRailGroupHeader(context, context.t(group.headerKey)),
        );
      }
      for (final entry in group.entries) {
        final label = context.t(entry.labelKey);
        navChildren.add(
          _buildRailIcon(
            context,
            iconAsset: entry.icon,
            tooltip: label,
            label: showLabels ? label : null,
            selected: _isRailTargetSelected(entry.target),
            onTap: () => _activateRailTarget(entry.target),
          ),
        );
      }
    }

    navChildren.add(
      PluginPageNavigation(
        builder: (context, views) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (groups.isNotEmpty) _buildRailDivider(context),
            if (showLabels)
              _buildRailGroupHeader(
                context,
                context.t(LocaleKeys.settingsPlugins),
              ),
            for (final view in views)
              _buildRailIcon(
                context,
                iconAsset: pluginPageIcon,
                tooltip: view.title.resolve(Localizations.localeOf(context)),
                label: showLabels
                    ? view.title.resolve(Localizations.localeOf(context))
                    : null,
                selected: false,
                onTap: () => openPluginPage(
                  context,
                  view,
                  workId: widget.currentNovelId,
                ),
              ),
          ],
        ),
      ),
    );
    return SizedBox(
      width: railWidth,
      child: Column(
        children: [
          // Rail-only 页面没有中栏顶栏，折叠入口由 rail 接管。
          SizedBox(
            height: DesktopWindowFrame.sidebarTopInset,
            child: showCollapseInRail && collapseFitsTitleBar
                ? Padding(
                    padding: EdgeInsets.only(
                      left: DesktopWindowFrame.sidebarLeadingInset,
                      right: RevericSpacing.sm,
                    ),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _buildSidebarCollapseButton(
                        context,
                        onTap: widget.onCollapse,
                      ),
                    ),
                  )
                : null,
          ),
          if (showCollapseInRail && !collapseFitsTitleBar)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: RevericSpacing.sm),
                child: _buildSidebarCollapseButton(
                  context,
                  onTap: widget.onCollapse,
                ),
              ),
            ),
          const SizedBox(height: RevericSpacing.sm),
          if (widget.isCollapsed)
            _buildRailIcon(
              context,
              tooltip: context.t(LocaleKeys.commonExpandSidebar),
              selected: false,
              onTap: widget.onExpand,
              child: SvgPicture.asset(
                'assets/icons/collapse.svg',
                width: 18,
                height: 18,
                colorFilter: ColorFilter.mode(colors.accent, BlendMode.srcIn),
              ),
            ),
          Expanded(
            child: SingleChildScrollView(child: Column(children: navChildren)),
          ),
          Divider(height: RevericSizes.dividerThickness, color: colors.border),
          DesktopUpdateEntry(iconOnly: widget.isCollapsed),
          UserProfileBar(
            mode: widget.isCollapsed
                ? UserProfileBarMode.iconOnly
                : UserProfileBarMode.dense,
          ),
        ],
      ),
    );
  }

  Widget _buildRailDivider(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: RevericSpacing.xxs),
      child: Divider(
        height: RevericSizes.dividerThickness,
        indent: RevericSpacing.sm,
        endIndent: RevericSpacing.sm,
        color: colors.border,
      ),
    );
  }

  Widget _buildRailGroupHeader(BuildContext context, String label) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.only(
          left: RevericSpacing.sm,
          top: RevericSpacing.xxs,
          bottom: RevericSpacing.xxs,
        ),
        child: Text(
          label,
          textAlign: TextAlign.left,
          style: typo.uiSmall.copyWith(
            color: colors.textMuted,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildRailIcon(
    BuildContext context, {
    required String tooltip,
    required bool selected,
    required VoidCallback onTap,
    String? iconAsset,
    String? label,
    Widget? child,
  }) {
    final colors = RevericTheme.colorsOf(context);
    assert(iconAsset != null || child != null);
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        hoverColor: colors.hover,
        child: Container(
          width: double.infinity,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? colors.selected : Colors.transparent,
          ),
          child:
              child ??
              _buildRailItemContent(
                context,
                iconAsset!,
                label: label,
                selected: selected,
              ),
        ),
      ),
    );
  }

  Widget _buildRailItemContent(
    BuildContext context,
    String iconAsset, {
    required String? label,
    required bool selected,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final iconColor = selected ? colors.accent : colors.textMuted;
    final icon = _themedSvgIcon(iconAsset, size: 18, color: iconColor);

    if (label == null) return icon;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.sm),
      child: Row(
        children: [
          icon,
          const SizedBox(width: RevericSpacing.sm),
          Expanded(
            child: Text(
              label,
              style: typo.uiSmall.copyWith(color: iconColor),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _themedSvgIcon(
    String assetPath, {
    required double size,
    required Color color,
  }) {
    return SvgPicture.asset(
      assetPath,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }

  // ---------------------------------------------------------------------------
  // Panel (右侧宽列：当前 rail 对应的内容)
  // ---------------------------------------------------------------------------
}

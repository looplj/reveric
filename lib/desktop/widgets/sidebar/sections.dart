// 职责: 小说编辑侧边栏 — 构建内容、AI 会话、AI 互动面板。
// 关联文件:
//   lib/desktop/widgets/sidebar/sidebar.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
part of 'sidebar.dart';

class _DocumentTreeRow {
  const _DocumentTreeRow({
    required this.document,
    required this.depth,
    required this.hasChildren,
  });

  final Document document;
  final int depth;
  final bool hasChildren;
}

/// 图鉴面板拍平后的一行 — 分组标题或分组内的条目。
sealed class _CompendiumRow {
  const _CompendiumRow();
}

final class _CompendiumGroupRow extends _CompendiumRow {
  const _CompendiumGroupRow(this.section, this.count);

  final NovelWorkspaceSection section;
  final int count;
}

final class _CompendiumEntryRow extends _CompendiumRow {
  const _CompendiumEntryRow(this.section, this.entry);

  final NovelWorkspaceSection section;
  final Item entry;
}

extension _LeftSidebarSections on _LeftSidebarState {
  Widget _buildPanel(BuildContext context) {
    // 红绿灯需要 sidebarLeadingInset(76px on macOS) 横向避让，
    // rail 已占用当前宽度，panel 顶栏只需要补齐剩余部分。
    final railLeadingInset =
        (DesktopWindowFrame.sidebarLeadingInset - widget.expandedRailWidth)
            .clamp(0, double.infinity)
            .toDouble();

    return ContextColumnScaffold(
      onBack: widget.onBack,
      leadingInset: railLeadingInset,
      trailing: _buildSidebarCollapseButton(context, onTap: widget.onCollapse),
      novelHeader: _buildWorkspaceHeader(context),
      child: _buildPanelBody(context),
    );
  }

  Widget _buildPanelBody(BuildContext context) {
    // 封面工作台占用 Main；中栏换成生成记录，顶栏仍走 ContextColumnScaffold。
    if (widget.isCoverStudioActive) {
      return CoverStudioRecordsList(novelId: widget.currentNovelId);
    }
    switch (_panelMode) {
      case _PanelMode.aiChats:
        return ChatSessionList(
          sessions: widget.aiChatSessions,
          activeSessionId: widget.activeAiChatSessionId,
          onSelectSession: widget.onSelectAiChatSession,
          onCreateSession: widget.onCreateAiChatSession,
          onDeleteSession: widget.onDeleteAiChatSession,
          onContinueSession: widget.onContinueAiChatSession,
          databasePath: widget.databasePath,
          hasMore: widget.hasMoreAiChatSessions,
          isLoadingMore: widget.isLoadingMoreAiChatSessions,
          onLoadMore: widget.onLoadMoreAiChatSessions,
        );
      case _PanelMode.content:
        if (_activeAgentItem != null) {
          return _buildAgentList(context, _activeAgentItem!);
        }
        return _buildSectionPanel(context, _displayedContentSection);
    }
  }

  // ---------------------------------------------------------------------------
  // 单分类 Panel：每个内容 section 直接展示自己的列表，没有外层 folder 包裹。
  // ---------------------------------------------------------------------------

  Widget _buildSectionPanel(
    BuildContext context,
    NovelWorkspaceSection section,
  ) {
    switch (section) {
      case NovelWorkspaceSection.chapters:
        return _buildChapterSectionPanel(context);
      case NovelWorkspaceSection.outlines:
        return _buildOutlinesSectionPanel(context);
      case NovelWorkspaceSection.characters:
        return _buildCharacterSectionPanel(context, section: section);
      case NovelWorkspaceSection.foreshadowings:
        return _buildForeshadowingSectionPanel(context, section: section);
      // 四类 Item 共用图鉴面板，按类型分组展示。
      case NovelWorkspaceSection.factions:
      case NovelWorkspaceSection.items:
      case NovelWorkspaceSection.creatures:
      case NovelWorkspaceSection.skills:
        return _buildCompendiumPanel(context);
      case NovelWorkspaceSection.lore:
        return _buildDocumentSectionPanel(
          context,
          title: context.t(LocaleKeys.workspaceLore),
          documents: widget.worldbuildingEntries,
          section: section,
          onImport: widget.onImportDocument == null
              ? null
              : () => unawaited(widget.onImportDocument!(section, null)),
        );
      case NovelWorkspaceSection.materials:
        return _buildDocumentSectionPanel(
          context,
          title: context.t(LocaleKeys.workspaceMaterials),
          documents: widget.materialEntries,
          section: section,
          onImport: widget.onImportDocument == null
              ? null
              : () => unawaited(widget.onImportDocument!(section, null)),
        );
      case NovelWorkspaceSection.entity_graph:
        return EntityListSection(
          characters: widget.characterProfiles,
          factions: widget.factionEntries,
          skills: widget.skillEntries,
          items: widget.items,
          creatures: widget.creatureEntries,
          selectedEntityKey: widget.selection.section == section
              ? widget.selection.itemId
              : null,
          databasePath: widget.databasePath,
          onEntitySelected: (entityKey) {
            final nextKey =
                widget.selection.section == section &&
                    widget.selection.itemId == entityKey
                ? null
                : entityKey;
            widget.onSelect(
              WorkspaceSelection(section: section, itemId: nextKey),
            );
          },
        );
      case NovelWorkspaceSection.canvas:
        if (!ideationCanvasEnabled || widget.databasePath == null) {
          return const SizedBox.shrink();
        }
        return CanvasListPanel(
          databasePath: widget.databasePath!,
          novelId: widget.currentNovelId,
          novelName: widget.novelTitle,
          novelDescription: widget.novelDescription,
          selectedCanvasId:
              widget.selection.section == NovelWorkspaceSection.canvas
              ? widget.selection.itemId
              : null,
          onOpenCanvas: (canvasId) => widget.onSelect(
            WorkspaceSelection(
              section: NovelWorkspaceSection.canvas,
              itemId: canvasId,
            ),
          ),
        );
      // 剧本四个 section 共用一棵季 / 集 / 场次树，切 rail 不换中栏。
      case NovelWorkspaceSection.screenplay_script:
      case NovelWorkspaceSection.screenplay_outline:
      case NovelWorkspaceSection.storyboard:
      case NovelWorkspaceSection.screenplay_scenes:
        return _buildScreenplaySectionPanel(context);
      case NovelWorkspaceSection.novel_description:
      case NovelWorkspaceSection.overview:
      case NovelWorkspaceSection.maps:
      // 当前进展是整块只读视图，没有二级列表。
      case NovelWorkspaceSection.story_progress:
        return const SizedBox.shrink();
    }
  }

  /// 剧本中栏 — 季 / 集 / 场次树。树本身住在 feature 目录，这里只做挂载，
  /// 与 [CanvasListPanel] / [CoverStudioRecordsList] 同一种接法。
  Widget _buildScreenplaySectionPanel(BuildContext context) {
    final path = widget.databasePath;
    if (path == null || path.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    final screenplayId = ref.watch(screenplayRootProvider(path)).value?.id;
    if (screenplayId == null) {
      return const SizedBox.shrink();
    }
    return ScreenplayContextPanel(
      novelId: widget.currentNovelId,
      databasePath: path,
      screenplayId: screenplayId,
      onFlush: widget.onPrepareWorkspaceTransition ?? () async => true,
    );
  }

  Widget _buildCharacterSectionPanel(
    BuildContext context, {
    required NovelWorkspaceSection section,
  }) {
    // 分组行的折叠态与文档树共用 expandedNodeIds（人物 section 此前没有可展开节点），
    // 节点 id 直接用分组名。
    final rows = buildCharacterSidebarRows(
      characters: widget.characterProfiles,
      expandedGroups: _expandedFolderIds(section),
      matches: (character) => _matchesSearchQuery(
        section,
        [character.name, ...character.aliases].join('\n'),
      ),
      isSearching: _hasSearchQueryForSection(section),
    );

    return _buildLeafSectionPanel(
      context,
      title: context.t(LocaleKeys.workspaceCharacters),
      count: widget.characterProfiles.length,
      section: section,
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        return switch (row) {
          CharacterGroupRow() => _buildCharacterGroupRow(
            context,
            section: section,
            row: row,
          ),
          CharacterEntryRow() => _buildCharacterLeaf(
            context,
            depth: row.depth,
            label: row.character.name,
            itemId: row.character.id,
          ),
        };
      },
    );
  }

  Widget _buildCharacterGroupRow(
    BuildContext context, {
    required NovelWorkspaceSection section,
    required CharacterGroupRow row,
  }) {
    return _buildTreeRow(
      context,
      depth: 0,
      iconAsset: row.isExpanded ? _iconFolderOpen : _iconFolder,
      label: row.name,
      trailing: '${row.count}',
      isExpanded: row.isExpanded,
      showArrow: true,
      // 搜索态强制展开，此时折叠只会改回写入的状态却看不到效果，索性不响应点击。
      onTap: _hasSearchQueryForSection(section)
          ? null
          : () => _toggleExpandedFolder(section, row.name),
    );
  }

  Widget _buildForeshadowingSectionPanel(
    BuildContext context, {
    required NovelWorkspaceSection section,
  }) {
    final untitledLabel = context.t(LocaleKeys.sidebarUntitledEntry);
    final foreshadowings = widget.foreshadowings
        .where(
          (item) => _matchesSearchQuery(
            section,
            item.title.isEmpty ? untitledLabel : item.title,
          ),
        )
        .toList(growable: false);

    return _buildLeafSectionPanel(
      context,
      title: context.t(LocaleKeys.workspaceForeshadowings),
      count: widget.foreshadowings.length,
      section: section,
      itemCount: foreshadowings.length,
      itemBuilder: (context, index) {
        final item = foreshadowings[index];
        final label = item.title.isEmpty ? untitledLabel : item.title;
        return _buildDeleteContextMenuWrapper(
          context,
          label: label,
          section: NovelWorkspaceSection.foreshadowings,
          itemId: item.id,
          child: _buildLeaf(
            context,
            depth: 0,
            label: label,
            section: NovelWorkspaceSection.foreshadowings,
            itemId: item.id,
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 图鉴 Panel：势力 / 生物 / 物品 / 技能合并为一个带类型筛选的分组列表。
  // ---------------------------------------------------------------------------

  List<Item> _compendiumEntriesFor(NovelWorkspaceSection section) {
    return switch (section) {
      NovelWorkspaceSection.factions => widget.factionEntries,
      NovelWorkspaceSection.creatures => widget.creatureEntries,
      NovelWorkspaceSection.items => widget.items,
      NovelWorkspaceSection.skills => widget.skillEntries,
      _ => const <Item>[],
    };
  }

  String _compendiumLabelFor(
    BuildContext context,
    NovelWorkspaceSection section,
  ) {
    return switch (section) {
      NovelWorkspaceSection.factions => context.t(LocaleKeys.workspaceFactions),
      NovelWorkspaceSection.creatures => context.t(
        LocaleKeys.workspaceCreatures,
      ),
      NovelWorkspaceSection.items => context.t(LocaleKeys.workspaceItems),
      NovelWorkspaceSection.skills => context.t(LocaleKeys.workspaceSkills),
      _ => '',
    };
  }

  String _compendiumIconFor(NovelWorkspaceSection section) {
    return switch (section) {
      NovelWorkspaceSection.factions => _iconUsersThree,
      NovelWorkspaceSection.creatures => _iconBugBeetle,
      NovelWorkspaceSection.items => _iconPackage,
      NovelWorkspaceSection.skills => _iconLightning,
      _ => _iconPackage,
    };
  }

  /// 把可见分组与条目拍平成行，交给 `ListView.builder` 惰性构建。
  /// 直接用 `ListView(children: ...)` 会一次性构造全部条目，
  /// 长列表下正是 `sidebar_virtualized_list_test` 守着的回归。
  List<_CompendiumRow> _compendiumRows(BuildContext context) {
    final untitledLabel = context.t(LocaleKeys.sidebarUntitledEntry);
    final query = _compendiumSearchQuery.trim().toLowerCase();
    final visibleSections = _compendiumFilter == null
        ? compendiumSections
        : <NovelWorkspaceSection>[_compendiumFilter!];

    final rows = <_CompendiumRow>[];
    for (final section in visibleSections) {
      final all = _compendiumEntriesFor(section);
      final entries = query.isEmpty
          ? all
          : all
                .where(
                  (entry) => (entry.title.isEmpty ? untitledLabel : entry.title)
                      .toLowerCase()
                      .contains(query),
                )
                .toList(growable: false);
      if (entries.isEmpty) {
        continue;
      }
      rows.add(_CompendiumGroupRow(section, entries.length));
      if (_collapsedCompendiumGroups.contains(section)) {
        continue;
      }
      for (final entry in entries) {
        rows.add(_CompendiumEntryRow(section, entry));
      }
    }
    return rows;
  }

  Widget _buildCompendiumPanel(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final untitledLabel = context.t(LocaleKeys.sidebarUntitledEntry);
    final rows = _compendiumRows(context);

    var totalCount = 0;
    for (final section in compendiumSections) {
      totalCount += _compendiumEntriesFor(section).length;
    }

    const leadingRowCount = 3;
    return ListView.builder(
      key: const ValueKey('sidebar-section-list-compendium'),
      padding: const EdgeInsets.only(top: RevericSpacing.sm),
      addAutomaticKeepAlives: false,
      itemCount: leadingRowCount + (rows.isEmpty ? 1 : rows.length),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Builder(
            builder: (headerContext) => _buildPanelSectionHeader(
              headerContext,
              title: context.t(LocaleKeys.workspaceSidebarCompendium),
              count: totalCount,
              onAdd: widget.onCreateDocument == null
                  ? null
                  : () => _onCompendiumAdd(headerContext),
            ),
          );
        }
        if (index == 1) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.x2l,
              0,
              RevericSpacing.x2l,
              RevericSpacing.sm,
            ),
            child: RevericDebouncedSearchField(
              key: const ValueKey('section-search-compendium'),
              hint: context.t(LocaleKeys.workspaceSearch),
              initialQuery: _compendiumSearchQuery,
              debounce: _LeftSidebarState._sectionSearchDebounceDuration,
              onDebouncedChanged: _setCompendiumSearchQuery,
            ),
          );
        }
        if (index == 2) {
          return _buildCompendiumFilterChips(context, totalCount: totalCount);
        }
        if (rows.isEmpty) {
          return _buildEmptyHint(context);
        }
        final row = rows[index - leadingRowCount];
        return switch (row) {
          _CompendiumGroupRow(:final section, :final count) =>
            CollapsibleListGroupHeader(
              title: _compendiumLabelFor(context, section),
              count: count,
              expanded: !_collapsedCompendiumGroups.contains(section),
              leading: _themedSvgIcon(
                _compendiumIconFor(section),
                size: 14,
                color: colors.textSubtle,
              ),
              onTap: () => _toggleCompendiumGroup(section),
            ),
          _CompendiumEntryRow(:final section, :final entry) => _buildItemLeaf(
            context,
            depth: 1,
            label: entry.title.isEmpty ? untitledLabel : entry.title,
            section: section,
            itemId: entry.id,
          ),
        };
      },
    );
  }

  Widget _buildCompendiumFilterChips(
    BuildContext context, {
    required int totalCount,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.x2l,
        0,
        RevericSpacing.x2l,
        RevericSpacing.sm,
      ),
      child: Wrap(
        spacing: RevericSpacing.xxs,
        runSpacing: RevericSpacing.xxs,
        children: [
          RevericFilterChip(
            label: context.t(LocaleKeys.commonFilterAll),
            count: totalCount,
            selected: _compendiumFilter == null,
            onTap: () => _setCompendiumFilter(null),
          ),
          for (final section in compendiumSections)
            RevericFilterChip(
              label: _compendiumLabelFor(context, section),
              count: _compendiumEntriesFor(section).length,
              selected: _compendiumFilter == section,
              onTap: () => _setCompendiumFilter(section),
            ),
        ],
      ),
    );
  }

  /// 已筛选到具体类型时直接新建该类型；处于「全部」时先让用户选类型。
  void _onCompendiumAdd(BuildContext context) {
    final onCreate = widget.onCreateDocument;
    if (onCreate == null) {
      return;
    }
    final filter = _compendiumFilter;
    if (filter != null) {
      unawaited(onCreate(filter));
      return;
    }

    final box = context.findRenderObject() as RenderBox?;
    final anchor = box == null
        ? Offset.zero
        : box.localToGlobal(box.size.bottomLeft(Offset.zero));
    showRevericContextMenu(
      context: context,
      position: anchor,
      entries: [
        for (final section in compendiumSections)
          RevericMenuItem(
            icon: _compendiumIconFor(section),
            label: _compendiumLabelFor(context, section),
            onTap: () => unawaited(onCreate(section)),
          ),
      ],
    );
  }

  Widget _buildLeafSectionPanel(
    BuildContext context, {
    required String title,
    required int count,
    required NovelWorkspaceSection section,
    required int itemCount,
    required NullableIndexedWidgetBuilder itemBuilder,
  }) {
    return ListView.builder(
      key: ValueKey('sidebar-section-list-${section.name}'),
      padding: const EdgeInsets.only(top: RevericSpacing.sm),
      addAutomaticKeepAlives: false,
      itemCount: 2 + (itemCount == 0 ? 1 : itemCount),
      itemBuilder: (context, index) {
        if (index == 0) {
          return _buildPanelSectionHeader(
            context,
            title: title,
            count: count,
            onAdd: widget.onCreateDocument == null
                ? null
                : () => unawaited(widget.onCreateDocument!(section)),
          );
        }
        if (index == 1) {
          return _buildSectionSearchField(context, section: section);
        }
        if (itemCount == 0) {
          return _buildEmptyHint(context);
        }
        return itemBuilder(context, index - 2);
      },
    );
  }

  Widget _buildOutlinesSectionPanel(BuildContext context) {
    const section = NovelWorkspaceSection.outlines;
    final outlines = widget.outlineEntries.where((outline) {
      final title = outline.title.isEmpty
          ? context.t(LocaleKeys.workspaceOutlines)
          : outline.title;
      return _matchesSearchQuery(section, title);
    }).toList();

    return Column(
      children: [
        _buildPanelSectionHeader(
          context,
          title: context.t(LocaleKeys.workspaceOutlines),
          count: widget.outlineEntries.length,
          onAdd: widget.onCreateDocument == null
              ? null
              : () => unawaited(
                  widget.onCreateDocument!(NovelWorkspaceSection.outlines),
                ),
        ),
        _buildSectionSearchField(context, section: section),
        Expanded(
          child: ListView.builder(
            key: ValueKey('sidebar-section-list-${section.name}'),
            padding: EdgeInsets.zero,
            addAutomaticKeepAlives: false,
            itemCount: outlines.isEmpty ? 1 : outlines.length,
            itemBuilder: (context, index) {
              if (outlines.isEmpty) {
                return _buildEmptyHint(context);
              }
              final outline = outlines[index];
              final label = outline.title.isEmpty
                  ? context.t(LocaleKeys.workspaceOutlines)
                  : outline.title;
              return _buildDeleteContextMenuWrapper(
                context,
                label: label,
                section: NovelWorkspaceSection.outlines,
                itemId: outline.documentId,
                child: _buildLeaf(
                  context,
                  depth: 0,
                  label: label,
                  section: NovelWorkspaceSection.outlines,
                  itemId: outline.documentId,
                ),
              );
            },
          ),
        ),
        if (widget.onImportOutline != null)
          _buildImportPanelFooter(
            context,
            () => unawaited(widget.onImportOutline!()),
          ),
        _buildGlobalOutlinesFooter(context),
      ],
    );
  }

  Widget _buildGlobalOutlinesFooter(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final selected =
        widget.selection.section == NovelWorkspaceSection.outlines &&
        widget.selection.itemId == null &&
        widget.selection.isViewingAllOutlines &&
        !_hasAuxiliaryContentSelection;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.x2l,
        RevericSpacing.sm,
        RevericSpacing.x2l,
        RevericSpacing.x2l,
      ),
      child: InkWell(
        onTap: () {
          widget.onSelect(
            const WorkspaceSelection(
              section: NovelWorkspaceSection.outlines,
              isViewingAllOutlines: true,
            ),
          );
        },
        borderRadius: BorderRadius.circular(RevericRadius.small),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.md,
            vertical: RevericSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: selected ? colors.selected : Colors.transparent,
            border: Border.all(color: selected ? colors.accent : colors.border),
            borderRadius: BorderRadius.circular(RevericRadius.small),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _themedSvgIcon(
                _iconTreeStructure,
                size: 14,
                color: selected ? colors.accent : colors.textSubtle,
              ),
              const SizedBox(width: RevericSpacing.xs),
              Text(
                context.t(LocaleKeys.workspaceOutlineGlobal),
                style: typo.uiSmall.copyWith(
                  color: selected ? colors.textPrimary : colors.textSubtle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDocumentSectionPanel(
    BuildContext context, {
    required String title,
    required List<Document> documents,
    required NovelWorkspaceSection section,
    VoidCallback? onImport,
  }) {
    final visibleDocuments = _hasSearchQueryForSection(section)
        ? _filterDocumentsBySearch(context, section, documents)
        : documents;
    final visibleRows = _buildDocumentTreeRows(visibleDocuments, section);
    final leafCount = documents.where((doc) => !doc.isFolder).length;
    final canCreate =
        widget.onCreateFolder != null &&
        (section == NovelWorkspaceSection.lore ||
            section == NovelWorkspaceSection.outlines ||
            section == NovelWorkspaceSection.materials);

    return ListView.builder(
      padding: const EdgeInsets.only(top: RevericSpacing.sm),
      addAutomaticKeepAlives: false,
      itemCount:
          2 +
          (visibleRows.isEmpty ? 1 : visibleRows.length) +
          (onImport == null ? 0 : 1),
      itemBuilder: (context, index) {
        if (index == 0) {
          return GestureDetector(
            onSecondaryTapDown: canCreate
                ? (details) => _showRootContextMenu(context, details, section)
                : null,
            child: _buildPanelSectionHeader(
              context,
              title: title,
              count: leafCount,
              onAdd: canCreate && widget.onCreateDocument != null
                  ? () => unawaited(widget.onCreateDocument!(section))
                  : null,
              onAddFolder: canCreate && widget.onCreateFolder != null
                  ? () => unawaited(widget.onCreateFolder!(section))
                  : null,
            ),
          );
        }
        if (index == 1) {
          return _buildSectionSearchField(context, section: section);
        }
        if (visibleRows.isEmpty) {
          if (index == 2) {
            return _buildEmptyHint(context);
          }
          return _buildImportPanelFooter(context, onImport!);
        }
        if (index < 2 + visibleRows.length) {
          final row = visibleRows[index - 2];
          return _buildDocumentItem(
            context,
            row.document,
            section,
            row.depth,
            hasChildren: row.hasChildren,
          );
        }
        return _buildImportPanelFooter(context, onImport!);
      },
    );
  }

  List<_DocumentTreeRow> _buildDocumentTreeRows(
    List<Document> documents,
    NovelWorkspaceSection section,
  ) {
    final childrenByParent = <String?, List<Document>>{};
    for (final document in documents) {
      childrenByParent.putIfAbsent(document.parentId, () => []).add(document);
    }
    for (final children in childrenByParent.values) {
      children.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    }

    final rows = <_DocumentTreeRow>[];
    void addChildren(String? parentId, int depth) {
      for (final document in childrenByParent[parentId] ?? const <Document>[]) {
        final children = childrenByParent[document.id] ?? const <Document>[];
        rows.add(
          _DocumentTreeRow(
            document: document,
            depth: depth,
            hasChildren: children.isNotEmpty,
          ),
        );
        if (document.isFolder &&
            _expandedFolderIds(section).contains(document.id)) {
          addChildren(document.id, depth + 1);
        }
      }
    }

    addChildren(null, 0);
    return rows;
  }

  List<Document> _filterDocumentsBySearch(
    BuildContext context,
    NovelWorkspaceSection section,
    List<Document> documents,
  ) {
    final byId = {for (final document in documents) document.id: document};
    final visibleIds = <String>{};

    void addWithAncestors(Document document) {
      var current = document;
      while (visibleIds.add(current.id)) {
        final parentId = current.parentId;
        if (parentId == null) {
          break;
        }
        final parent = byId[parentId];
        if (parent == null) {
          break;
        }
        current = parent;
      }
    }

    for (final document in documents) {
      final label = document.title.isEmpty
          ? document.isFolder
                ? context.t(LocaleKeys.sidebarUntitledFolder)
                : context.t(LocaleKeys.sidebarUntitledDocument)
          : document.title;
      if (_matchesSearchQuery(section, label)) {
        addWithAncestors(document);
      }
    }

    return documents
        .where((document) => visibleIds.contains(document.id))
        .toList();
  }

  Widget _buildImportPanelFooter(BuildContext context, VoidCallback onImport) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.x2l,
        vertical: RevericSpacing.sm,
      ),
      child: InkWell(
        onTap: onImport,
        borderRadius: BorderRadius.circular(RevericRadius.small),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.md,
            vertical: RevericSpacing.sm,
          ),
          decoration: BoxDecoration(
            border: Border.all(color: colors.border),
            borderRadius: BorderRadius.circular(RevericRadius.small),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _themedSvgIcon(_iconFileText, size: 14, color: colors.textSubtle),
              const SizedBox(width: RevericSpacing.xs),
              Text(
                context.t(LocaleKeys.workspaceImportFile),
                style: typo.uiTiny.copyWith(color: colors.textSubtle),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionSearchField(
    BuildContext context, {
    required NovelWorkspaceSection section,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.x2l,
        0,
        RevericSpacing.x2l,
        RevericSpacing.sm,
      ),
      child: RevericDebouncedSearchField(
        key: ValueKey('section-search-${section.name}'),
        hint: context.t(LocaleKeys.workspaceSearch),
        initialQuery: _searchQueryForSection(section),
        debounce: _LeftSidebarState._sectionSearchDebounceDuration,
        onDebouncedChanged: (value) {
          _setSearchQueryForSection(section, value);
        },
      ),
    );
  }

  Widget _buildPanelSectionHeader(
    BuildContext context, {
    required String title,
    required int count,
    VoidCallback? onAdd,
    VoidCallback? onAddFolder,
    VoidCallback? onToggleSort,
    bool sortDescending = false,
    bool useProminentMetrics = false,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final actionPad = useProminentMetrics
        ? RevericSpacing.sm
        : RevericSpacing.xs;
    final actionSize = useProminentMetrics ? 18.0 : 16.0;
    final actions = <Widget>[
      if (onToggleSort != null)
        Tooltip(
          message: context.t(
            sortDescending
                ? LocaleKeys.sidebarSortDescending
                : LocaleKeys.sidebarSortAscending,
          ),
          child: InkWell(
            onTap: onToggleSort,
            borderRadius: BorderRadius.circular(RevericRadius.small),
            child: Padding(
              padding: EdgeInsets.all(actionPad),
              child: _themedSvgIcon(
                sortDescending ? _iconSortDescending : _iconSortAscending,
                size: actionSize,
                color: colors.textSubtle,
              ),
            ),
          ),
        ),
      if (onAddFolder != null)
        InkWell(
          onTap: onAddFolder,
          borderRadius: BorderRadius.circular(RevericRadius.small),
          child: Padding(
            padding: EdgeInsets.all(actionPad),
            child: _themedSvgIcon(
              _iconFolderPlus,
              size: actionSize,
              color: colors.textSubtle,
            ),
          ),
        ),
      if (onAdd != null)
        InkWell(
          onTap: onAdd,
          borderRadius: BorderRadius.circular(RevericRadius.small),
          child: Padding(
            padding: const EdgeInsets.all(RevericSpacing.xs),
            child: _themedSvgIcon(
              _iconPlus,
              size: 16,
              color: colors.textSubtle,
            ),
          ),
        ),
    ];

    return ContextColumnSectionHeader(
      title: title,
      count: count,
      useProminentMetrics: useProminentMetrics,
      actions: actions,
    );
  }

  Widget _buildEmptyHint(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.x2l,
        vertical: RevericSpacing.lg,
      ),
      child: Text(
        context.t(LocaleKeys.sidebarEmptyHint),
        style: typo.uiSmall.copyWith(color: colors.textMuted),
      ),
    );
  }

  Widget _buildTreeRowWithContextMenu(
    BuildContext context, {
    required int depth,
    required String iconAsset,
    required String label,
    String? trailing,
    bool isExpanded = false,
    bool isSelected = false,
    bool showArrow = false,
    required Document document,
    VoidCallback? onTap,
  }) {
    final treeRow = _buildTreeRow(
      context,
      depth: depth,
      iconAsset: iconAsset,
      label: label,
      trailing: trailing,
      isExpanded: isExpanded,
      isSelected: isSelected,
      showArrow: showArrow,
      onTap: onTap,
    );

    if (widget.onDeleteDocument == null && widget.onRenameDocument == null) {
      return treeRow;
    }

    return GestureDetector(
      onSecondaryTapDown: (details) {
        _showDocumentContextMenu(context, details, document);
      },
      child: treeRow,
    );
  }

  Widget _buildLeafWithContextMenu(
    BuildContext context, {
    required int depth,
    required String label,
    required NovelWorkspaceSection section,
    String? itemId,
    required Document document,
  }) {
    final child = _buildTreeRow(
      context,
      depth: depth,
      iconAsset: _iconFileText,
      label: label,
      isSelected:
          widget.selection.section == section &&
          widget.selection.itemId == itemId &&
          !_hasAuxiliaryContentSelection,
      onTap: () {
        widget.onSelect(WorkspaceSelection(section: section, itemId: itemId));
      },
    );

    if (itemId == null) return child;

    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final reference = AiContextReference(
      section: section,
      itemId: itemId,
      label: label,
    );

    final draggable = Draggable<AiContextReference>(
      data: reference,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.lg,
            vertical: RevericSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(RevericRadius.pill),
            border: Border.all(color: colors.accent),
            boxShadow: [
              BoxShadow(
                color: colors.textPrimary.withValues(alpha: 0.12),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _themedSvgIcon(_iconFileText, size: 14, color: colors.accent),
              const SizedBox(width: RevericSpacing.xs),
              Text(
                label,
                style: typo.uiSmall.copyWith(color: colors.textPrimary),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: child),
      child: child,
    );

    if (widget.onDeleteDocument == null && widget.onRenameDocument == null) {
      return draggable;
    }

    return GestureDetector(
      onSecondaryTapDown: (details) {
        _showDocumentContextMenu(context, details, document);
      },
      child: draggable,
    );
  }

  // ---------------------------------------------------------------------------
  // Agent 列表 Panel
  // ---------------------------------------------------------------------------

  Widget _buildAgentList(BuildContext context, _AgentItem item) {
    switch (item) {
      case _AgentItem.subagents:
        return _buildSubAgentList(context);
      case _AgentItem.agentRules:
        // 列表在 Main（Setup / 规则网格）；中栏已收起，不应走到这里。
        return const SizedBox.shrink();
      case _AgentItem.council:
        return _buildModeSessionList(
          context,
          mode: AiSessionMode.council,
          title: context.t(LocaleKeys.aiSessionModeCouncil),
          activeSessionId: widget.activeCouncilSessionId,
          onOpenMode: widget.onOpenAgentCouncil,
          onSelectSession: widget.onOpenCouncilWithSession,
        );
      case _AgentItem.monologue:
        return _buildModeSessionList(
          context,
          mode: AiSessionMode.monologue,
          title: context.t(LocaleKeys.aiSessionModeMonologue),
          activeSessionId: widget.activeMonologueSessionId,
          onOpenMode: widget.onOpenMonologue,
          onSelectSession: widget.onOpenMonologueWithSession,
        );
      case _AgentItem.theater:
        return _buildModeSessionList(
          context,
          mode: AiSessionMode.theater,
          title: context.t(LocaleKeys.aiSessionModeTheater),
          activeSessionId: widget.activeTheaterSessionId,
          onOpenMode: widget.onOpenTheater,
          onSelectSession: widget.onOpenTheaterWithSession,
        );
      case _AgentItem.roleplay:
        return _buildModeSessionList(
          context,
          mode: AiSessionMode.roleplay,
          title: context.t(LocaleKeys.aiSessionModeRoleplay),
          activeSessionId: widget.activeRoleplaySessionId,
          onOpenMode: widget.onOpenRoleplay,
          onSelectSession: widget.onOpenRoleplayWithSession,
        );
    }
  }

  Widget _buildSubAgentList(BuildContext context) {
    final mergedAgents = ref
        .watch(mergedSubAgentsProvider)
        .where(isUserVisibleSubAgent)
        .toList(growable: false);
    final count = mergedAgents.length;

    return ListView(
      padding: const EdgeInsets.only(top: RevericSpacing.sm),
      children: [
        _buildAgentSectionHeader(
          context,
          title: context.t(LocaleKeys.subagentTitle),
          count: count,
          onAdd: () {
            widget.onSelectSubAgent?.call(
              SubAgent(
                id: '__new__${DateTime.now().microsecondsSinceEpoch}',
                slug: '',
                name: '',
                description: '',
                prompt: '',
                scope: SubAgentScope.global,
                sortOrder: 0,
              ),
            );
          },
        ),
        ...mergedAgents.map((agent) => _buildSubAgentItem(context, agent)),
        if (mergedAgents.isEmpty) _buildEmptyHint(context),
      ],
    );
  }

  Widget _buildSubAgentItem(BuildContext context, SubAgent agent) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final isSelected = widget.selectedSubAgentId == agent.id;

    return Material(
      color: isSelected ? colors.selected : Colors.transparent,
      child: InkWell(
        onTap: () => widget.onSelectSubAgent?.call(agent),
        hoverColor: colors.hover,
        child: Padding(
          padding: const EdgeInsets.only(
            left: RevericSpacing.x2l,
            right: RevericSpacing.x2l,
            top: RevericSpacing.xs,
            bottom: RevericSpacing.xs,
          ),
          child: Row(
            children: [
              RevericIcon(
                RevericIcons.smart_toy_outlined,
                size: 16,
                color: isSelected ? colors.accent : colors.textSubtle,
              ),
              const SizedBox(width: RevericSpacing.sm),
              Expanded(
                child: Text(
                  agent.name,
                  style: (isSelected ? typo.uiSemibold : typo.ui).copyWith(
                    color: isSelected
                        ? colors.textPrimary
                        : colors.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAgentSectionHeader(
    BuildContext context, {
    required String title,
    required int count,
    VoidCallback? onAdd,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.only(
        left: RevericSpacing.x2l,
        right: RevericSpacing.sm,
        top: RevericSpacing.xs,
        bottom: RevericSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: typo.uiSmallSemibold.copyWith(color: colors.textSecondary),
            ),
          ),
          Text('$count', style: typo.uiTiny.copyWith(color: colors.textSubtle)),
          if (onAdd != null) ...[
            const SizedBox(width: RevericSpacing.xs),
            InkWell(
              onTap: onAdd,
              borderRadius: BorderRadius.circular(RevericRadius.small),
              child: Padding(
                padding: const EdgeInsets.all(RevericSpacing.xs),
                child: _themedSvgIcon(
                  _iconPlus,
                  size: 16,
                  color: colors.textSubtle,
                ),
              ),
            ),
          ] else
            const SizedBox(width: RevericSpacing.sm),
        ],
      ),
    );
  }

  Widget _buildModeSessionList(
    BuildContext context, {
    required AiSessionMode mode,
    required String title,
    required String? activeSessionId,
    required VoidCallback? onOpenMode,
    ValueChanged<String>? onSelectSession,
  }) {
    final sessionsAsync = ref.watch(
      aiChatSessionsByModeProvider(
        novelId: widget.currentNovelId,
        databasePath: widget.databasePath,
        mode: mode.value,
      ),
    );

    return sessionsAsync.when(
      data: (sessionList) {
        return ListView(
          padding: const EdgeInsets.only(top: RevericSpacing.sm),
          children: [
            _buildAgentSectionHeader(
              context,
              title: title,
              count: sessionList.length,
              onAdd: onOpenMode,
            ),
            ...sessionList.map(
              (session) => ModeSessionListRow(
                session: session,
                mode: mode,
                isActive: session.id == activeSessionId,
                onSelectSession: onSelectSession,
                onDeleteSession: widget.onDeleteAiChatSession,
              ),
            ),
            if (sessionList.isEmpty) _buildEmptyHint(context),
          ],
        );
      },
      loading: () => const Center(child: SizedBox.shrink()),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

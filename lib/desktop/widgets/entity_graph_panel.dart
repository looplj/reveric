// 职责: 实体关系图面板 — 工具栏 + 画布 + 图例 + PNG 导出，选中实体时展示右侧 Inspector (hero/tabs/关系详情卡片/实体详情)。
// 关联文件:
//   lib/shared/entity_graph/entity_graph.dart
//   lib/desktop/widgets/workspace/chapter_list_dropdown.dart
//   lib/shared/widgets/relation_edit_dialog.dart
//   lib/shared/widgets/character_avatar.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/entity_graph.json
//   assets/translations/zh-CN/entity_graph.json
//   assets/translations/en/entity.json
//   assets/translations/zh-CN/entity.json
//   assets/translations/en/relation.json
//   assets/translations/zh-CN/relation.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/error-handling.md
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/components/reveric_checkbox.dart';
import '../../shared/components/reveric_context_menu.dart';
import '../../shared/components/reveric_icon_button.dart';
import '../../shared/database/novel_content_database.dart';
import '../../shared/entity_graph/entity_graph.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/logger/app_logger.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/app_background.dart';
import '../../shared/widgets/character_avatar.dart';
import '../../shared/widgets/relation_edit_dialog.dart';
import '../../shared/widgets/relation/list_region.dart';
import '../../shared/providers/workspace_navigation_provider.dart';
import '../../shared/models/novel_workspace.dart';

final _log = AppLogger.forModule('EntityGraphPanel');

const double _kToolbarCheckboxSize = 14;
const double _kToolbarExportIconSize = 14;

/// Material 3 TextButton.icon 图标与文字的间距。
const double _kTextButtonIconGap = 8;

class EntityGraphPanel extends HookConsumerWidget {
  const EntityGraphPanel({
    super.key,
    required this.novelId,
    required this.databasePath,
    required this.selectedEntityKey,
    required this.onSelectedEntityKeyChanged,
  });

  final String novelId;
  final String databasePath;
  final String? selectedEntityKey;
  final ValueChanged<String?> onSelectedEntityKeyChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final active = ref.watch(appBackgroundActiveProvider);

    final relationsAsync = ref.watch(allRelationsProvider(databasePath));
    final characters =
        ref.watch(characterProfilesProvider(databasePath)).value ?? const [];
    final factions =
        ref
            .watch(itemsProvider(path: databasePath, type: entityTypeFaction))
            .value ??
        const [];
    final skills =
        ref
            .watch(itemsProvider(path: databasePath, type: entityTypeSkill))
            .value ??
        const [];
    final items =
        ref
            .watch(itemsProvider(path: databasePath, type: entityTypeItem))
            .value ??
        const [];
    final creatures =
        ref
            .watch(itemsProvider(path: databasePath, type: entityTypeCreature))
            .value ??
        const [];
    final chapters =
        ref.watch(chaptersProvider(databasePath)).value ?? const [];
    final chapterMap = {for (final chapter in chapters) chapter.id: chapter};

    final showLabels = useState(true);
    final showDirection = useState(true);
    final displayDepth = useState(3);
    final centerEntityKey = useState<String?>(null);
    final selectedEntityTypes = useState(
      Set<String>.from(kEntityGraphDefaultEntityTypeFilter),
    );
    final layoutGeneration = useState(0);
    // 图谱区域焦点 — 接收 ESC 退出聚焦。
    final graphFocusNode = useFocusNode();
    final exportController = useMemoized(
      () => EntityGraphExportController(),
      const [],
    );
    final isExporting = useState(false);
    final novelTitle = ref.watch(novelProvider(novelId)).value?.title;

    final allRelations = relationsAsync.value ?? const [];

    final nameMap = buildEntityGraphNameMap(
      characters: characters,
      factions: factions,
      skills: skills,
      items: items,
      creatures: creatures,
    );

    final avatarMap = buildEntityGraphAvatarMap(characters: characters);

    final typeNameMap = buildEntityGraphTypeNameMap(
      characters: characters,
      factions: factions,
      skills: skills,
      items: items,
      creatures: creatures,
    );

    final entityTypeFilteredRelations = filterRelationsByEntityTypes(
      allRelations,
      selectedEntityTypes.value,
    );

    final centerCandidateKeys = entityGraphCenterCandidateKeys(
      relations: entityTypeFilteredRelations,
      nameMap: nameMap,
    );
    final defaultCenterNodeKey = resolveDefaultCenterEntityKey(
      characters: characters,
      relations: entityTypeFilteredRelations,
    );
    final effectiveCenterKey = resolveEffectiveCenterEntityKey(
      overrideKey: centerEntityKey.value,
      defaultKey: defaultCenterNodeKey,
      candidateKeys: centerCandidateKeys,
    );

    // 可见关系集以中心点做 BFS 展开；点选节点只聚焦，不改中心。
    final filteredRelations = filterEntityGraphRelations(
      allRelations: allRelations,
      defaultCenterEntityKey: effectiveCenterKey,
      depth: displayDepth.value,
      entityTypes: selectedEntityTypes.value,
    );

    final graphNodes = buildEntityGraphNodes(
      context: context,
      relations: filteredRelations,
      nameMap: nameMap,
      avatarMap: avatarMap,
      typeNameMap: typeNameMap,
    );
    final graphEdges = buildEntityGraphEdges(
      context: context,
      relations: filteredRelations,
    );

    final selectedRelations = selectedEntityKey != null
        ? relationsForEntityKey(allRelations, selectedEntityKey!)
        : <RelationSummary>[];

    useEffect(
      () {
        if (selectedEntityKey == null) {
          return null;
        }
        if (nameMap.containsKey(selectedEntityKey)) {
          return null;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onSelectedEntityKeyChanged(null);
        });
        return null;
      },
      [
        selectedEntityKey,
        selectedEntityTypes.value,
        displayDepth.value,
        effectiveCenterKey,
        allRelations.length,
      ],
    );

    Future<void> exportPng() async {
      if (isExporting.value) {
        return;
      }
      isExporting.value = true;
      try {
        final result = await runEntityGraphPngExport(
          context,
          controller: exportController,
          edges: graphEdges,
          novelTitle: novelTitle,
        );
        if (!context.mounted) {
          return;
        }
        // 移动端的分享面板自带反馈，只有真正落盘才提示路径。
        if (result.status == EntityGraphPngSaveStatus.saved &&
            result.path != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.t(
                  LocaleKeys.entityGraphExportSuccess,
                  namedArgs: {'file': result.path!},
                ),
              ),
            ),
          );
        }
      } catch (error, stackTrace) {
        _log.error('导出关系图 PNG 失败', error: error, stackTrace: stackTrace);
        if (!context.mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.t(LocaleKeys.entityGraphExportFailed)),
          ),
        );
      } finally {
        if (context.mounted) {
          isExporting.value = false;
        }
      }
    }

    return Row(
      children: [
        // Graph area
        Expanded(
          child: Container(
            color: appChromeBackgroundColor(colors, active, colors.canvas),
            child: Column(
              children: [
                _GraphToolbar(
                  colors: colors,
                  typo: typo,
                  showLabels: showLabels,
                  showDirection: showDirection,
                  displayDepth: displayDepth,
                  centerSelect: EntityGraphCenterSelect(
                    centerKey: effectiveCenterKey,
                    candidateKeys: centerCandidateKeys,
                    nameMap: nameMap,
                    typeNameMap: typeNameMap,
                    onChanged: (key) {
                      centerEntityKey.value = key;
                      onSelectedEntityKeyChanged(key);
                    },
                  ),
                  selectedEntityTypes: selectedEntityTypes,
                  canExport: graphNodes.isNotEmpty,
                  isExporting: isExporting.value,
                  onExport: exportPng,
                  onReset: () {
                    showLabels.value = true;
                    showDirection.value = true;
                    displayDepth.value = 3;
                    centerEntityKey.value = null;
                    selectedEntityTypes.value = Set<String>.from(
                      kEntityGraphDefaultEntityTypeFilter,
                    );
                    layoutGeneration.value++;
                  },
                ),
                Divider(height: 1, color: colors.borderSubtle),
                Expanded(
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.escape): () =>
                          onSelectedEntityKeyChanged(null),
                    },
                    child: Focus(
                      focusNode: graphFocusNode,
                      autofocus: true,
                      child: relationsAsync.when(
                        data: (_) {
                          if (graphNodes.isEmpty) {
                            return Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  RevericIcon(
                                    RevericIcons.link_off,
                                    size: 48,
                                    color: colors.textSubtle,
                                  ),
                                  const SizedBox(height: RevericSpacing.x2l),
                                  Text(
                                    context.t(LocaleKeys.entityGraphNoData),
                                    style: typo.ui.copyWith(
                                      color: colors.textMuted,
                                    ),
                                  ),
                                  const SizedBox(height: RevericSpacing.sm),
                                  FilledButton.icon(
                                    onPressed: () => RelationEditDialog.show(
                                      context,
                                      databasePath: databasePath,
                                    ),
                                    icon: const RevericIcon(
                                      RevericIcons.add,
                                      size: 16,
                                    ),
                                    label: Text(
                                      context.t(
                                        LocaleKeys.entityGraphAddRelation,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }
                          return EntityGraphWidget(
                            databasePath: databasePath,
                            nodes: graphNodes,
                            edges: graphEdges,
                            selectedNodeKey: selectedEntityKey,
                            defaultCenterNodeKey: effectiveCenterKey,
                            showLabels: showLabels.value,
                            showDirection: showDirection.value,
                            layoutGeneration: layoutGeneration.value,
                            exportController: exportController,
                            onNodeTap: (key) {
                              onSelectedEntityKeyChanged(
                                selectedEntityKey == key ? null : key,
                              );
                            },
                            onClearSelection: () =>
                                onSelectedEntityKeyChanged(null),
                          );
                        },
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (error, _) => Center(
                          child: Text(
                            context.t(
                              LocaleKeys.entityGraphLoadError,
                              namedArgs: {'error': '$error'},
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (graphEdges.isNotEmpty)
                  EntityGraphLegend(counts: relationCategoryCounts(graphEdges)),
              ],
            ),
          ),
        ),

        // Right panel — entity inspector
        ...[
          VerticalDivider(width: 1, thickness: 1, color: colors.border),
          SizedBox(
            width: 320,
            child: Container(
              color: appChromeBackgroundColor(
                colors,
                active,
                colors.surfaceDim,
              ),
              child: _EntityInspector(
                colors: colors,
                typo: typo,
                selectedKey: selectedEntityKey,
                relations: selectedRelations,
                allRelations: allRelations,
                nameMap: nameMap,
                avatarMap: avatarMap,
                typeNameMap: typeNameMap,
                chapterMap: chapterMap,
                databasePath: databasePath,
                onEntitySelected: onSelectedEntityKeyChanged,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _GraphToolbar extends StatelessWidget {
  const _GraphToolbar({
    required this.colors,
    required this.typo,
    required this.showLabels,
    required this.showDirection,
    required this.displayDepth,
    required this.centerSelect,
    required this.selectedEntityTypes,
    required this.canExport,
    required this.isExporting,
    required this.onExport,
    required this.onReset,
  });

  final RevericColors colors;
  final RevericTypography typo;
  final ValueNotifier<bool> showLabels;
  final ValueNotifier<bool> showDirection;
  final ValueNotifier<int> displayDepth;
  final Widget centerSelect;
  final ValueNotifier<Set<String>> selectedEntityTypes;
  final bool canExport;
  final bool isExporting;
  final VoidCallback onExport;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.x2l,
        vertical: RevericSpacing.sm,
      ),
      child: Row(
        children: [
          centerSelect,
          const SizedBox(width: RevericSpacing.sm),
          EntityGraphDepthSelect(
            depth: displayDepth.value,
            onChanged: (depth) {
              displayDepth.value = depth;
            },
          ),
          const SizedBox(width: RevericSpacing.sm),

          EntityGraphEntityTypeFilter(
            selectedTypes: selectedEntityTypes.value,
            onChanged: (types) => selectedEntityTypes.value = types,
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => Align(
                alignment: Alignment.centerRight,
                child: box.maxWidth >= _actionsWidth(context)
                    ? _actions(context)
                    : _moreButton(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 右侧操作组完整展开所需宽度；按当前语言的文案实测，放不下就收进「⋯」菜单。
  double _actionsWidth(BuildContext context) {
    final direction = Directionality.of(context);
    double text(String key) => (TextPainter(
      text: TextSpan(text: context.t(key), style: typo.uiSmall),
      maxLines: 1,
      textDirection: direction,
    )..layout()).width;
    const toggleChrome = _kToolbarCheckboxSize + RevericSpacing.xxs;
    const buttonPadding = RevericSpacing.sm * 2;
    return RevericSpacing.sm +
        toggleChrome +
        text(LocaleKeys.entityGraphShowLabels) +
        RevericSpacing.sm +
        toggleChrome +
        text(LocaleKeys.entityGraphShowDirection) +
        RevericSpacing.sm +
        (canExport
            ? buttonPadding +
                  _kToolbarExportIconSize +
                  _kTextButtonIconGap +
                  text(LocaleKeys.entityGraphExportImage)
            : 0) +
        RevericSpacing.xxs +
        buttonPadding +
        text(LocaleKeys.entityGraphReset);
  }

  Widget _actions(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Show labels toggle
        _ToolbarToggle(
          label: context.t(LocaleKeys.entityGraphShowLabels),
          value: showLabels.value,
          colors: colors,
          typo: typo,
          onChanged: (v) => showLabels.value = v,
        ),
        const SizedBox(width: RevericSpacing.sm),

        // Show direction toggle
        _ToolbarToggle(
          label: context.t(LocaleKeys.entityGraphShowDirection),
          value: showDirection.value,
          colors: colors,
          typo: typo,
          onChanged: (v) => showDirection.value = v,
        ),
        const SizedBox(width: RevericSpacing.sm),

        // Export PNG
        if (canExport)
          TextButton.icon(
            key: const ValueKey('entity_graph_export_button'),
            onPressed: isExporting ? null : onExport,
            style: TextButton.styleFrom(
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.sm,
                vertical: RevericSpacing.xxs,
              ),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: isExporting
                ? SizedBox.square(
                    dimension: _kToolbarExportIconSize,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.textMuted,
                    ),
                  )
                : RevericIcon(
                    RevericIcons.download_outlined,
                    size: _kToolbarExportIconSize,
                    color: colors.textMuted,
                  ),
            label: Text(
              context.t(LocaleKeys.entityGraphExportImage),
              style: typo.uiSmall.copyWith(color: colors.textMuted),
            ),
          ),
        const SizedBox(width: RevericSpacing.xxs),

        // Reset button
        TextButton(
          onPressed: onReset,
          style: TextButton.styleFrom(
            minimumSize: Size.zero,
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.sm,
              vertical: RevericSpacing.xxs,
            ),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            context.t(LocaleKeys.entityGraphReset),
            style: typo.uiSmall.copyWith(color: colors.textMuted),
          ),
        ),
      ],
    );
  }

  Widget _moreButton(BuildContext context) {
    return Builder(
      builder: (context) => RevericIconButton(
        icon: RevericIcons.more_horiz,
        tooltip: context.t(LocaleKeys.commonMoreActions),
        onPressed: () {
          final box = context.findRenderObject() as RenderBox;
          unawaited(
            showRevericContextMenu(
              context: context,
              position: box.localToGlobal(
                Offset(0, box.size.height + RevericSpacing.xxs),
              ),
              entries: [
                RevericMenuItem(
                  icon: showLabels.value
                      ? RevericIcons.check_box_rounded
                      : RevericIcons.check_box_outline_blank_rounded,
                  label: context.t(LocaleKeys.entityGraphShowLabels),
                  onTap: () => showLabels.value = !showLabels.value,
                ),
                RevericMenuItem(
                  icon: showDirection.value
                      ? RevericIcons.check_box_rounded
                      : RevericIcons.check_box_outline_blank_rounded,
                  label: context.t(LocaleKeys.entityGraphShowDirection),
                  onTap: () => showDirection.value = !showDirection.value,
                ),
                const RevericMenuDivider(),
                if (canExport)
                  RevericMenuItem(
                    icon: RevericIcons.download_outlined,
                    label: context.t(LocaleKeys.entityGraphExportImage),
                    enabled: !isExporting,
                    onTap: onExport,
                  ),
                RevericMenuItem(
                  label: context.t(LocaleKeys.entityGraphReset),
                  onTap: onReset,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ToolbarToggle extends StatelessWidget {
  const _ToolbarToggle({
    required this.label,
    required this.value,
    required this.colors,
    required this.typo,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final RevericColors colors;
  final RevericTypography typo;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: _kToolbarCheckboxSize,
            child: RevericCheckbox(value: value, onChanged: onChanged),
          ),
          const SizedBox(width: RevericSpacing.xxs),
          Text(
            label,
            style: typo.uiSmall.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _EntityInspector extends HookConsumerWidget {
  const _EntityInspector({
    required this.colors,
    required this.typo,
    required this.selectedKey,
    required this.relations,
    required this.allRelations,
    required this.nameMap,
    required this.avatarMap,
    required this.typeNameMap,
    required this.chapterMap,
    required this.databasePath,
    required this.onEntitySelected,
  });

  final RevericColors colors;
  final RevericTypography typo;
  final String? selectedKey;
  final List<RelationSummary> relations;
  final List<RelationSummary> allRelations;
  final Map<String, String> nameMap;
  final Map<String, String?> avatarMap;
  final Map<String, String> typeNameMap;
  final Map<String, Chapter> chapterMap;
  final String databasePath;
  final ValueChanged<String?> onEntitySelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (selectedKey == null) {
      return _InspectorEmptyState(colors: colors, typo: typo);
    }

    final parts = selectedKey!.split('_');
    final entityType = parts[0];
    final entityId = parts.sublist(1).join('_');

    final detailAsync = ref.watch(
      entityGraphNodeDetailProvider(
        databasePath: databasePath,
        entityType: entityType,
        entityId: entityId,
      ),
    );

    final tab = useState(0); // 0 = relations, 1 = details

    // Refocus → reset tab + select first relation.
    useEffect(() {
      tab.value = 0;
      return null;
    }, [selectedKey]);

    final entityName = nameMap[selectedKey] ?? selectedKey!;
    final entityAvatar = avatarMap[selectedKey];
    final typeName = typeNameMap[selectedKey] != null
        ? localizeEntityNodeTypeName(context, typeNameMap[selectedKey]!)
        : null;
    final ringColor = entityGraphRingColor(
      entityType,
      colors,
      typeKey: typeNameMap[selectedKey],
    );

    final graphEdges = buildEntityGraphEdges(
      context: context,
      relations: allRelations,
      includeEdgeLabels: false,
    );
    final centerStats = entityGraphCenterStats(graphEdges, selectedKey);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Hero
        _InspectorHero(
          name: entityName,
          typeName: typeName,
          avatarAssetId: entityAvatar,
          ringColor: ringColor,
          colors: colors,
          typo: typo,
        ),
        Divider(height: 1, color: colors.borderSubtle),

        // Tabs
        _InspectorTabBar(
          tab: tab.value,
          colors: colors,
          typo: typo,
          onChanged: (t) => tab.value = t,
        ),
        Divider(height: 1, color: colors.borderSubtle),

        // Body
        Expanded(
          child: tab.value == 0
              ? RelationListRegion(
                  key: ValueKey(selectedKey),
                  databasePath: databasePath,
                  entityKey: selectedKey!,
                  names: nameMap,
                  onOpenEvidence: (kind, id) {
                    ref
                        .read(workspaceNavigationProvider.notifier)
                        .request(
                          WorkspaceNavigationRequest(
                            section: kind == 'chapter'
                                ? NovelWorkspaceSection.chapters
                                : NovelWorkspaceSection.screenplay_script,
                            itemId: id,
                          ),
                        );
                  },
                )
              : _DetailsTab(
                  detailAsync: detailAsync,
                  entityName: entityName,
                  entityType: entityType,
                  typeName: typeName,
                  typeKey: typeNameMap[selectedKey],
                  relations: relations,
                  centerStats: centerStats,
                  graphEdges: graphEdges,
                  selectedKey: selectedKey!,
                  colors: colors,
                  typo: typo,
                ),
        ),
      ],
    );
  }
}

class _InspectorEmptyState extends StatelessWidget {
  const _InspectorEmptyState({required this.colors, required this.typo});

  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(RevericSpacing.x4l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevericIcon(
              RevericIcons.account_tree,
              size: 40,
              color: colors.textSubtle,
            ),
            const SizedBox(height: RevericSpacing.lg),
            Text(
              context.t(LocaleKeys.entityGraphNoData),
              style: typo.uiSmall.copyWith(color: colors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _InspectorHero extends StatelessWidget {
  const _InspectorHero({
    required this.name,
    required this.typeName,
    required this.avatarAssetId,
    required this.ringColor,
    required this.colors,
    required this.typo,
  });

  final String name;
  final String? typeName;
  final String? avatarAssetId;
  final Color ringColor;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.x2l,
        RevericSpacing.x2l,
        RevericSpacing.x2l,
        RevericSpacing.md,
      ),
      child: Column(
        children: [
          CharacterAvatar(
            avatarAssetId: avatarAssetId,
            fallbackName: name,
            size: 48,
            backgroundColor: ringColor.withValues(alpha: 0.15),
            textColor: ringColor,
          ),
          const SizedBox(height: RevericSpacing.sm),
          Text(
            name,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: typo.heading2.copyWith(color: colors.textPrimary),
          ),
          if (typeName != null) ...[
            const SizedBox(height: RevericSpacing.xxs),
            _TypeBadge(
              label: typeName!,
              color: ringColor,
              colors: colors,
              typo: typo,
            ),
          ],
        ],
      ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  const _TypeBadge({
    required this.label,
    required this.color,
    required this.colors,
    required this.typo,
  });

  final String label;
  final Color color;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(RevericRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: RevericSpacing.xxs),
          Text(label, style: typo.uiTinySemibold.copyWith(color: color)),
        ],
      ),
    );
  }
}

class _InspectorTabBar extends StatelessWidget {
  const _InspectorTabBar({
    required this.tab,
    required this.colors,
    required this.typo,
    required this.onChanged,
  });

  final int tab;
  final RevericColors colors;
  final RevericTypography typo;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.lg),
      child: Row(
        children: [
          _TabButton(
            label: context.t(LocaleKeys.entityGraphInspectorRelations),
            selected: tab == 0,
            colors: colors,
            typo: typo,
            onTap: () => onChanged(0),
          ),
          const SizedBox(width: RevericSpacing.md),
          _TabButton(
            label: context.t(LocaleKeys.entityGraphInspectorDetails),
            selected: tab == 1,
            colors: colors,
            typo: typo,
            onTap: () => onChanged(1),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.selected,
    required this.colors,
    required this.typo,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final RevericColors colors;
  final RevericTypography typo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: RevericSpacing.sm),
        child: Text(
          label,
          style: (selected ? typo.uiSmallSemibold : typo.uiSmall).copyWith(
            color: selected ? colors.textPrimary : colors.textMuted,
          ),
        ),
      ),
    );
  }
}

class _DetailKV extends StatelessWidget {
  const _DetailKV({
    required this.label,
    required this.value,
    required this.colors,
    required this.typo,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: RevericSpacing.xxs),
      child: Row(
        children: [
          Text(label, style: typo.uiTiny.copyWith(color: colors.textMuted)),
          const Spacer(),
          Text(
            value,
            style: typo.uiSmall.copyWith(
              color: valueColor ?? colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailsTab extends StatelessWidget {
  const _DetailsTab({
    required this.detailAsync,
    required this.entityName,
    required this.entityType,
    required this.typeName,
    required this.typeKey,
    required this.relations,
    required this.centerStats,
    required this.graphEdges,
    required this.selectedKey,
    required this.colors,
    required this.typo,
  });

  final AsyncValue<EntityGraphNodeDetail?> detailAsync;
  final String entityName;
  final String entityType;
  final String? typeName;
  final String? typeKey;
  final List<RelationSummary> relations;
  final ({int direct, int indirect}) centerStats;
  final List<EntityEdgeData> graphEdges;
  final String selectedKey;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    final ringColor = entityGraphRingColor(
      entityType,
      colors,
      typeKey: typeKey,
    );

    // Category breakdown for this entity
    final entityEdges = graphEdges
        .where((e) => e.sourceKey == selectedKey || e.targetKey == selectedKey)
        .toList();
    final catCounts = relationCategoryCounts(entityEdges);
    final catEntries = catCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return ListView(
      padding: const EdgeInsets.only(bottom: RevericSpacing.x2l),
      children: [
        // Profile section
        _DetailSection(
          title: context.t(LocaleKeys.entityGraphInspectorProfile),
          colors: colors,
          typo: typo,
          child: detailAsync.when(
            loading: () => const SizedBox(
              height: 20,
              child: Center(
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
            error: (_, _) => Text(
              context.t(LocaleKeys.commonNoDescription),
              style: typo.uiSmall.copyWith(color: colors.textSecondary),
            ),
            data: (detail) => Text(
              detail?.description ?? context.t(LocaleKeys.commonNoDescription),
              style: typo.uiSmall.copyWith(
                color: colors.textSecondary,
                height: 1.7,
              ),
            ),
          ),
        ),

        // Basic attributes
        _DetailSection(
          title: context.t(LocaleKeys.entityGraphInspectorBasicAttrs),
          colors: colors,
          typo: typo,
          child: Column(
            children: [
              _DetailKV(
                label: context.t(LocaleKeys.entityGraphInspectorRelationType),
                value: typeName ?? entityType,
                valueColor: ringColor,
                colors: colors,
                typo: typo,
              ),
              _DetailKV(
                label: context.t(LocaleKeys.entityGraphInspectorOriginName),
                value: entityName,
                colors: colors,
                typo: typo,
              ),
              _DetailKV(
                label: context.t(LocaleKeys.entityGraphTabAll),
                value: '${relations.length}',
                colors: colors,
                typo: typo,
              ),
            ],
          ),
        ),

        // Relation overview
        _DetailSection(
          title: context.t(LocaleKeys.entityGraphInspectorRelationOverview),
          colors: colors,
          typo: typo,
          child: Column(
            children: [
              // Stat grid
              Row(
                children: [
                  Expanded(
                    child: _StatCell(
                      value: '${centerStats.direct}',
                      label: context.t(
                        LocaleKeys.entityGraphInspectorDirectRelations,
                      ),
                      colors: colors,
                      typo: typo,
                    ),
                  ),
                  const SizedBox(width: RevericSpacing.xs),
                  Expanded(
                    child: _StatCell(
                      value: '${centerStats.indirect}',
                      label: context.t(
                        LocaleKeys.entityGraphInspectorIndirectRelations,
                      ),
                      colors: colors,
                      typo: typo,
                    ),
                  ),
                ],
              ),
              if (catEntries.isNotEmpty) ...[
                const SizedBox(height: RevericSpacing.sm),
                for (final entry in catEntries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1.5),
                    child: Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: relationCategoryColor(entry.key),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: RevericSpacing.xs),
                        Expanded(
                          child: Text(
                            localizeRelationCategoryLabel(context, entry.key),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: typo.uiTiny.copyWith(
                              color: colors.textSecondary,
                            ),
                          ),
                        ),
                        Text(
                          '${entry.value}',
                          style: typo.uiTiny.copyWith(color: colors.textSubtle),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({
    required this.title,
    required this.colors,
    required this.typo,
    required this.child,
  });

  final String title;
  final RevericColors colors;
  final RevericTypography typo;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.x2l,
            RevericSpacing.md,
            RevericSpacing.x2l,
            RevericSpacing.sm,
          ),
          child: Text(
            title,
            style: typo.uiTinySemibold.copyWith(
              color: colors.textMuted,
              letterSpacing: 0.4,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.x2l,
            0,
            RevericSpacing.x2l,
            RevericSpacing.lg,
          ),
          child: child,
        ),
        Divider(height: 1, color: colors.borderSubtle),
      ],
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({
    required this.value,
    required this.label,
    required this.colors,
    required this.typo,
  });

  final String value;
  final String label;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: RevericSpacing.sm),
      decoration: BoxDecoration(
        color: colors.surfaceDim,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: typo.uiMedium.copyWith(
              color: colors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: typo.uiTiny.copyWith(color: colors.textMuted)),
        ],
      ),
    );
  }
}

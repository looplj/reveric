// 职责: 移动端实体关系图分区 — 力导向关系图画布、深度/实体类型/标签/方向工具栏、PNG 导出分享、选中实体后底部展示其关系并可编辑。
// 关联文件:
//   lib/mobile/pages/novel_editor_page.dart
//   lib/mobile/widgets/section_scaffold.dart
//   lib/shared/entity_graph/entity_graph.dart
//   lib/shared/widgets/relation_edit_dialog.dart
//   lib/shared/widgets/character_avatar.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/entity_graph.json
//   assets/translations/zh-CN/entity_graph.json
//   assets/translations/en/entity.json
//   assets/translations/zh-CN/entity.json
//   assets/translations/en/relation.json
//   assets/translations/zh-CN/relation.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
//   .agents/rules/error-handling.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/database/novel_content_database.dart';
import '../../shared/entity_graph/entity_graph.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/logger/app_logger.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/character_avatar.dart';
import 'section_scaffold.dart';
import 'relation_panel.dart';

final _log = AppLogger.forModule('MobileEntityGraphPanel');

class MobileEntityGraphPanel extends HookConsumerWidget {
  const MobileEntityGraphPanel({
    super.key,
    required this.novelId,
    required this.databasePath,
    required this.onCreate,
  });

  final String novelId;
  final String databasePath;

  /// 新建关系入口由标题栏右上角承载；空状态引导按钮复用同一回调。
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);

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

    final showLabels = useState(true);
    final showDirection = useState(true);
    final displayDepth = useState(3);
    final centerEntityKey = useState<String?>(null);
    final selectedEntityTypes = useState(
      Set<String>.from(kEntityGraphDefaultEntityTypeFilter),
    );
    final selectedEntityKey = useState<String?>(null);
    final layoutGeneration = useState(0);
    final exportController = useMemoized(
      () => EntityGraphExportController(),
      const [],
    );
    final isExporting = useState(false);
    final novelTitle = ref.watch(novelProvider(novelId)).value?.title;

    final allRelations = relationsAsync.value ?? const <RelationSummary>[];

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

    final defaultCenterNodeKey = resolveDefaultCenterEntityKey(
      characters: characters,
      relations: entityTypeFilteredRelations,
    );
    final centerCandidateKeys = entityGraphCenterCandidateKeys(
      relations: entityTypeFilteredRelations,
      nameMap: nameMap,
    );
    final effectiveCenterKey = resolveEffectiveCenterEntityKey(
      overrideKey: centerEntityKey.value,
      defaultKey: defaultCenterNodeKey,
      candidateKeys: centerCandidateKeys,
    );

    // 可见关系集以中心点做 BFS 展开，不随底部条聚焦变化。
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
      includeEdgeLabels: false,
    );

    final selectedKey = selectedEntityKey.value;
    final selectedRelations = selectedKey != null
        ? relationsForEntityKey(allRelations, selectedKey)
        : const <RelationSummary>[];

    useEffect(
      () {
        if (selectedKey == null) {
          return null;
        }
        if (nameMap.containsKey(selectedKey)) {
          return null;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          selectedEntityKey.value = null;
        });
        return null;
      },
      [
        selectedKey,
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
        // 移动端走系统分享面板，面板本身就是反馈；只有落盘路径才值得提示。
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

    return Column(
      children: [
        _MobileGraphToolbar(
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
              selectedEntityKey.value = key;
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
        Align(
          alignment: Alignment.centerLeft,
          child: RelationEntityPickerButton(
            databasePath: databasePath,
            onSelected: (key) => selectedEntityKey.value = key,
          ),
        ),
        Expanded(
          child: relationsAsync.when(
            data: (_) {
              if (graphNodes.isEmpty) {
                return MobileSectionEmptyState(
                  icon: RevericIcons.link_off,
                  sectionLabel: context.t(LocaleKeys.workspaceEntityGraph),
                  hint: context.t(LocaleKeys.entityGraphNoData),
                  actionLabel: context.t(LocaleKeys.entityGraphAddRelation),
                  onCreate: onCreate,
                  actionKey: const ValueKey(
                    'mobile_entity_graph_empty_create_button',
                  ),
                );
              }
              return EntityGraphWidget(
                databasePath: databasePath,
                nodes: graphNodes,
                edges: graphEdges,
                selectedNodeKey: selectedKey,
                defaultCenterNodeKey: effectiveCenterKey,
                showLabels: showLabels.value,
                showDirection: showDirection.value,
                layoutGeneration: layoutGeneration.value,
                exportController: exportController,
                onNodeTap: (key) {
                  selectedEntityKey.value = selectedKey == key ? null : key;
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
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
        if (selectedKey != null)
          _SelectedEntityBar(
            entityName: nameMap[selectedKey] ?? selectedKey,
            entityType: _entityTypeOfKey(selectedKey),
            typeKey: typeNameMap[selectedKey],
            avatarAssetId: avatarMap[selectedKey],
            relationCount: selectedRelations
                .where((r) => r.status == 'active')
                .length,
            onClose: () => selectedEntityKey.value = null,
            onViewRelations: () => showRelationListSheet(
              context,
              databasePath,
              selectedKey,
              nameMap,
              novelId: novelId,
            ),
          ),
      ],
    );
  }
}

String _entityTypeOfKey(String key) => key.split('_').first;

/// 关系图工具栏（横向滚动）：中心点、深度、实体类型筛选、标签/方向开关、导出图片、重置。
class _MobileGraphToolbar extends StatelessWidget {
  const _MobileGraphToolbar({
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
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.x2l,
          vertical: RevericSpacing.sm,
        ),
        children: [
          centerSelect,
          const SizedBox(width: RevericSpacing.sm),
          EntityGraphDepthSelect(
            depth: displayDepth.value,
            onChanged: (depth) => displayDepth.value = depth,
          ),
          const SizedBox(width: RevericSpacing.sm),
          EntityGraphEntityTypeFilter(
            selectedTypes: selectedEntityTypes.value,
            onChanged: (types) => selectedEntityTypes.value = types,
            usePillStyle: true,
          ),
          const SizedBox(width: RevericSpacing.sm),
          _ToolbarToggle(
            label: context.t(LocaleKeys.entityGraphShowLabels),
            value: showLabels.value,
            colors: colors,
            typo: typo,
            onChanged: (v) => showLabels.value = v,
          ),
          const SizedBox(width: RevericSpacing.sm),
          _ToolbarToggle(
            label: context.t(LocaleKeys.entityGraphShowDirection),
            value: showDirection.value,
            colors: colors,
            typo: typo,
            onChanged: (v) => showDirection.value = v,
          ),
          const SizedBox(width: RevericSpacing.sm),
          if (canExport)
            InkWell(
              key: const ValueKey('mobile_entity_graph_export_button'),
              onTap: isExporting ? null : onExport,
              borderRadius: BorderRadius.circular(RevericRadius.pill),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.md,
                  vertical: RevericSpacing.xs,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(RevericRadius.pill),
                  border: Border.all(color: colors.borderSubtle),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isExporting)
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.textMuted,
                        ),
                      )
                    else
                      RevericIcon(
                        RevericIcons.download_outlined,
                        size: 14,
                        color: colors.textSecondary,
                      ),
                    const SizedBox(width: RevericSpacing.xxs),
                    Text(
                      context.t(LocaleKeys.entityGraphExportImage),
                      style: typo.uiSmall.copyWith(color: colors.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(width: RevericSpacing.sm),
          TextButton(
            onPressed: onReset,
            style: TextButton.styleFrom(
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.md,
                vertical: RevericSpacing.xs,
              ),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              context.t(LocaleKeys.entityGraphReset),
              style: typo.uiSmall.copyWith(color: colors.textMuted),
            ),
          ),
        ],
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
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(RevericRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.md,
          vertical: RevericSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: value
              ? colors.accent.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(RevericRadius.pill),
          border: Border.all(
            color: value
                ? colors.accent.withValues(alpha: 0.4)
                : colors.borderSubtle,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevericIcon(
              value
                  ? RevericIcons.check_box_rounded
                  : RevericIcons.check_box_outline_blank_rounded,
              size: 14,
              color: value ? colors.accent : colors.textSubtle,
            ),
            const SizedBox(width: RevericSpacing.xxs),
            Text(
              label,
              style: typo.uiSmall.copyWith(
                color: value ? colors.accent : colors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 选中实体时的底部信息条：头像 + 名称 + 关系数，点击查看关系列表，可关闭。
class _SelectedEntityBar extends StatelessWidget {
  const _SelectedEntityBar({
    required this.entityName,
    required this.entityType,
    required this.typeKey,
    required this.avatarAssetId,
    required this.relationCount,
    required this.onClose,
    required this.onViewRelations,
  });

  final String entityName;
  final String entityType;
  final String? typeKey;
  final String? avatarAssetId;
  final int relationCount;
  final VoidCallback onClose;
  final VoidCallback onViewRelations;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final ringColor = entityGraphRingColor(
      entityType,
      colors,
      typeKey: typeKey,
    );

    return Material(
      color: colors.surface,
      child: InkWell(
        onTap: onViewRelations,
        child: Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.borderSubtle)),
          ),
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.x2l,
            RevericSpacing.md,
            RevericSpacing.md,
            RevericSpacing.md,
          ),
          child: Row(
            children: [
              _EntityAvatar(
                entityType: entityType,
                name: entityName,
                avatarAssetId: avatarAssetId,
                ringColor: ringColor,
                size: 34,
              ),
              const SizedBox(width: RevericSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      entityName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSemibold.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      localizeEntityNodeTypeName(context, entityType),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiTiny.copyWith(color: colors.textMuted),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.sm,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: colors.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(RevericRadius.pill),
                ),
                child: Text(
                  '$relationCount',
                  style: typo.uiSmallSemibold.copyWith(color: colors.accent),
                ),
              ),
              const SizedBox(width: RevericSpacing.xs),
              RevericIcon(
                RevericIcons.chevron_right,
                size: 18,
                color: colors.textSubtle,
              ),
              InkWell(
                onTap: onClose,
                customBorder: const CircleBorder(),
                child: Padding(
                  padding: const EdgeInsets.all(RevericSpacing.sm),
                  child: RevericIcon(
                    RevericIcons.close,
                    size: 18,
                    color: colors.textSubtle,
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

class _EntityAvatar extends StatelessWidget {
  const _EntityAvatar({
    required this.entityType,
    required this.name,
    required this.avatarAssetId,
    required this.ringColor,
    required this.size,
  });

  final String entityType;
  final String name;
  final String? avatarAssetId;
  final Color ringColor;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (entityType == entityTypeCharacter) {
      return CharacterAvatar(
        avatarAssetId: avatarAssetId,
        fallbackName: name,
        size: size,
        backgroundColor: ringColor.withValues(alpha: 0.15),
        textColor: ringColor,
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: ringColor.withValues(alpha: 0.12),
      ),
      child: Center(
        child: RevericIcon(
          entityGraphIcon(entityType),
          size: size * 0.5,
          color: ringColor,
        ),
      ),
    );
  }
}

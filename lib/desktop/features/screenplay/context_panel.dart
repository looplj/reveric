// 职责: 桌面剧本上下文栏 — 季选择与管理、分集列表与场次列表及其新增入口。
// 关联文件:
//   lib/desktop/widgets/sidebar/sections.dart
//   lib/desktop/features/screenplay/season_manager.dart
//   lib/desktop/features/screenplay/episode_move_sheet.dart
//   lib/shared/providers/screenplay_providers.dart
//   lib/shared/providers/screenplay_workspace_state_provider.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/zh-CN/common.json
//   assets/translations/en/common.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/database/novel_content_database.dart'
    show Location, ScreenplayEpisodeRow, ScreenplaySeasonRow;
import '../../../shared/components/reveric_context_menu.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/screenplay.dart';
import '../../../shared/models/screenplay_workspace_state.dart';
import '../../../shared/providers/maps_providers.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/providers/screenplay_providers.dart';
import '../../../shared/providers/screenplay_workspace_state_provider.dart';
import '../../../shared/services/screenplay_service.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/confirm_dialog.dart';
import '../../../shared/widgets/screenplay/episode_count.dart';
import 'episode_move_sheet.dart';
import 'season_manager.dart';
import 'support.dart';

/// 季选择器的展开状态。单季作品永远停在 [closed]，且整个选择器不渲染。
enum _SeasonMode { closed, list }

class ScreenplayContextPanel extends HookConsumerWidget {
  const ScreenplayContextPanel({
    super.key,
    required this.novelId,
    required this.databasePath,
    required this.screenplayId,
    required this.onFlush,
  });

  final String novelId;
  final String databasePath;
  final String screenplayId;
  final Future<bool> Function() onFlush;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final seasonMode = useState(_SeasonMode.closed);
    final openEpisodeMenu = useState<String?>(null);
    final stateProvider = screenplayWorkspaceStateControllerProvider(
      novelId,
      databasePath,
    );
    final workspace = ref.watch(stateProvider);
    final seasons =
        ref
            .watch(screenplaySeasonsProvider(databasePath, screenplayId))
            .value ??
        const <ScreenplaySeasonRow>[];
    final multiSeason = seasons.length > 1;
    final currentSeason = _findSeason(seasons, workspace.seasonId);
    // 整剧的集只取一条 stream，再按季分组 —— 按季各开一条 query 的话，
    // 季数一多右栏每次重建都要等 N 条 query 回来。两边都按 episodeNumber
    // 排序，分组保序。
    final allEpisodes =
        ref
            .watch(
              screenplayEpisodesOfScreenplayProvider(
                databasePath,
                screenplayId,
              ),
            )
            .value ??
        const <ScreenplayEpisodeRow>[];
    final episodesBySeason = <String, List<ScreenplayEpisodeRow>>{};
    for (final episode in allEpisodes) {
      episodesBySeason.putIfAbsent(episode.seasonId, () => []).add(episode);
    }
    final episodeCounts = screenplaySeasonEpisodeCounts(allEpisodes);
    final episodes = currentSeason == null
        ? const <ScreenplayEpisodeRow>[]
        : episodesBySeason[currentSeason.id] ?? const <ScreenplayEpisodeRow>[];
    final currentEpisode = _findEpisode(episodes, workspace.episodeId);
    final scenes = currentEpisode == null
        ? const <ScreenplaySceneSummary>[]
        : ref
                  .watch(
                    screenplayScenesProvider(databasePath, currentEpisode.id),
                  )
                  .value ??
              const <ScreenplaySceneSummary>[];
    final locations =
        ref.watch(locationsProvider(databasePath)).value ?? const <Location>[];
    final locationNames = {
      for (final location in locations) location.id: location.name,
    };
    final service = ref.read(
      screenplayServiceProvider(databasePath, novelId: novelId),
    );
    // 正文滚动会把选中场次一路往下带，跟丢了列表就没有联动可言。
    final sceneListController = useScrollController();
    final sceneKeys = useMemoized(() => <String, GlobalKey>{}, [
      currentEpisode?.id,
    ]);
    useEffect(() {
      final target = sceneKeys[workspace.sceneId];
      if (target == null) {
        return null;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final rowContext = target.currentContext;
        if (rowContext == null || !sceneListController.hasClients) {
          return;
        }
        final box = rowContext.findRenderObject();
        if (box is! RenderBox || !box.hasSize) {
          return;
        }
        final viewport = RenderAbstractViewport.maybeOf(box);
        if (viewport == null) {
          return;
        }
        final pixels = sceneListController.position.pixels;
        // 已经完整可见就不动，否则每跟随一次都把列表甩到中间，读起来很晃。
        if (pixels <= viewport.getOffsetToReveal(box, 0).offset &&
            pixels >= viewport.getOffsetToReveal(box, 1).offset) {
          return;
        }
        unawaited(
          Scrollable.ensureVisible(
            rowContext,
            alignment: 0.5,
            duration: const Duration(milliseconds: 180),
          ),
        );
      });
      return null;
    }, [workspace.sceneId, sceneKeys]);

    Future<void> selectSeason(String seasonId) async {
      seasonMode.value = _SeasonMode.closed;
      if (!await onFlush()) return;
      final nextEpisodes = await ref
          .read(novelContentDatabaseProvider(databasePath))
          .screenplayDao
          .getEpisodes(seasonId);
      ref
          .read(stateProvider.notifier)
          .update(
            workspace.copyWith(
              seasonId: seasonId,
              episodeId: nextEpisodes.firstOrNull?.id,
              clearEpisodeId: nextEpisodes.isEmpty,
              clearSceneId: true,
            ),
          );
    }

    Future<void> selectEpisode(String episodeId) async {
      if (!await onFlush()) return;
      ref
          .read(stateProvider.notifier)
          .update(workspace.copyWith(episodeId: episodeId, clearSceneId: true));
    }

    Future<void> addSeason() async {
      seasonMode.value = _SeasonMode.closed;
      if (!await onFlush()) return;
      try {
        final created = await service.createSeason(screenplayId: screenplayId);
        ref
            .read(stateProvider.notifier)
            .update(
              workspace.copyWith(
                seasonId: created.seasonId,
                episodeId: created.episodeId,
                clearSceneId: true,
              ),
            );
      } catch (_) {
        if (context.mounted) _showSaveError(context);
      }
    }

    Future<void> addEpisode() async {
      final season = currentSeason;
      if (season == null || !await onFlush()) return;
      try {
        final episodeId = await service.createEpisode(seasonId: season.id);
        ref
            .read(stateProvider.notifier)
            .update(
              workspace.copyWith(episodeId: episodeId, clearSceneId: true),
            );
      } catch (_) {
        if (context.mounted) _showSaveError(context);
      }
    }

    Future<void> addScene() async {
      final episode = currentEpisode;
      if (episode == null || !await onFlush()) return;
      try {
        final sceneId = await service.createScene(
          screenplayId: screenplayId,
          episodeId: episode.id,
        );
        ref
            .read(stateProvider.notifier)
            .update(workspace.copyWith(sceneId: sceneId));
      } catch (_) {
        if (context.mounted) _showSaveError(context);
      }
    }

    // 顶栏（返回钮）与作品头由 ContextColumnScaffold 提供，这里只出树。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 单季时季这一层在界面上不存在：没有选择器、没有「第 1 季」标签，
        // 也没有管理入口，唯一一季是隐式当前季。
        if (multiSeason && currentSeason != null)
          _SeasonPicker(
            novelId: novelId,
            databasePath: databasePath,
            screenplayId: screenplayId,
            seasons: seasons,
            currentSeason: currentSeason,
            episodeCounts: episodeCounts,
            mode: seasonMode.value,
            onModeChanged: (mode) => seasonMode.value = mode,
            onSelectSeason: (id) => unawaited(selectSeason(id)),
            onAddSeason: () => unawaited(addSeason()),
            onFlush: onFlush,
          ),
        if (episodes.isNotEmpty) ...[
          _SectionHeader(
            label: context.t(LocaleKeys.screenplayEpisodes),
            // 单季时季选择器不渲染，集数就是本季设置（规划集数）的入口。
            trailingCount: currentSeason == null
                ? null
                : Tooltip(
                    message: context.t(LocaleKeys.screenplayEditSeason),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(RevericRadius.small),
                      onTap: () => unawaited(
                        showScreenplaySeasonManager(
                          context,
                          novelId: novelId,
                          databasePath: databasePath,
                          screenplayId: screenplayId,
                          onFlush: onFlush,
                          editSeasonId: currentSeason.id,
                        ),
                      ),
                      child: ScreenplayEpisodeCount(
                        episodeCount: episodes.length,
                        planned: currentSeason.plannedEpisodeCount,
                      ),
                    ),
                  ),
            addTooltip: context.t(LocaleKeys.screenplayAddEpisode),
            onAdd: () => unawaited(addEpisode()),
          ),
          Flexible(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      RevericSpacing.sm,
                      0,
                      RevericSpacing.sm,
                      RevericSpacing.sm,
                    ),
                    children: [
                      for (final episode in episodes)
                        _EpisodeTile(
                          episode: episode,
                          sceneCount: ref
                              .watch(
                                screenplayScenesProvider(
                                  databasePath,
                                  episode.id,
                                ),
                              )
                              .value
                              ?.length,
                          selected: episode.id == currentEpisode?.id,
                          multiSeason: multiSeason,
                          menuOpen: openEpisodeMenu.value == episode.id,
                          canDelete: episodes.length > 1,
                          isOnlyEpisode: episodes.length == 1,
                          seasons: seasons,
                          onTap: () => unawaited(selectEpisode(episode.id)),
                          onToggleMenu: () => openEpisodeMenu.value =
                              openEpisodeMenu.value == episode.id
                              ? null
                              : episode.id,
                          onMove: () {
                            openEpisodeMenu.value = null;
                            unawaited(
                              showScreenplayEpisodeMoveSheet(
                                context,
                                service: service,
                                episode: episode,
                                currentSeasonEpisodes: episodes,
                                seasons: seasons,
                                onMoved: (seasonId) async {
                                  if (episode.id == workspace.episodeId) {
                                    ref
                                        .read(stateProvider.notifier)
                                        .update(
                                          workspace.copyWith(
                                            seasonId: seasonId,
                                            episodeId: episode.id,
                                            clearSceneId: true,
                                          ),
                                        );
                                  }
                                },
                              ),
                            );
                          },
                          onDelete: () {
                            openEpisodeMenu.value = null;
                            unawaited(
                              _deleteEpisode(
                                context,
                                ref,
                                service: service,
                                episode: episode,
                                episodes: episodes,
                                workspace: workspace,
                                stateProvider: stateProvider,
                                onFlush: onFlush,
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
                // 固定在分集区域底部，分集列表滚动时仍可新增季。
                if (!multiSeason)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      RevericSpacing.sm,
                      0,
                      RevericSpacing.sm,
                      RevericSpacing.sm,
                    ),
                    child: _AddRow(
                      icon: RevericIcons.movie_outlined,
                      label: context.t(LocaleKeys.screenplayAddSeason),
                      onTap: () => unawaited(addSeason()),
                    ),
                  ),
              ],
            ),
          ),
        ],
        _SectionHeader(
          label: context.t(LocaleKeys.screenplayScenes),
          trailingCount: Text(
            '${scenes.length}',
            style: typo.mono.copyWith(height: 1.2, color: colors.textSubtle),
          ),
          addTooltip: context.t(LocaleKeys.screenplayAddScene),
          onAdd: () => unawaited(addScene()),
        ),
        Flexible(
          flex: 2,
          // 场次排序只在这里做：整行都能拖，正文那边不再放拖拽手柄。
          child: ReorderableListView.builder(
            scrollController: sceneListController,
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.sm,
              0,
              RevericSpacing.sm,
              RevericSpacing.lg,
            ),
            buildDefaultDragHandles: false,
            // 面板一律无阴影，拖起来的那一行也不例外。
            proxyDecorator: (child, _, _) =>
                Material(color: Colors.transparent, child: child),
            itemCount: scenes.length,
            onReorderItem: (oldIndex, newIndex) async {
              if (oldIndex == newIndex || !await onFlush()) {
                return;
              }
              final moved = scenes[oldIndex];
              if (newIndex < oldIndex) {
                await service.moveSceneBefore(moved.id, scenes[newIndex].id);
              } else {
                await service.moveSceneAfter(moved.id, scenes[newIndex].id);
              }
            },
            footer: _AddRow(
              icon: RevericIcons.add,
              label: context.t(LocaleKeys.screenplayAddScene),
              onTap: () => unawaited(addScene()),
            ),
            itemBuilder: (context, index) {
              final scene = scenes[index];
              return ReorderableDragStartListener(
                key: ValueKey(scene.id),
                index: index,
                child: KeyedSubtree(
                  key: sceneKeys.putIfAbsent(scene.id, GlobalKey.new),
                  child: _SceneRow(
                    scene: scene,
                    locationNames: locationNames,
                    selected: scene.id == workspace.sceneId,
                    onTap: () async {
                      if (!await onFlush()) {
                        return;
                      }
                      ref
                          .read(stateProvider.notifier)
                          .update(workspace.copyWith(sceneId: scene.id));
                    },
                    onDelete: () => unawaited(
                      _deleteScene(
                        context,
                        ref,
                        service: service,
                        scene: scene,
                        stateProvider: stateProvider,
                        onFlush: onFlush,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// `.sp-season` —— 展开区就地推开列表，不做浮层：面板一律无阴影，
/// 浮在场次上面反而看不清自己正要离开哪一季。
class _SeasonPicker extends StatelessWidget {
  const _SeasonPicker({
    required this.novelId,
    required this.databasePath,
    required this.screenplayId,
    required this.seasons,
    required this.currentSeason,
    required this.episodeCounts,
    required this.mode,
    required this.onModeChanged,
    required this.onSelectSeason,
    required this.onAddSeason,
    required this.onFlush,
  });

  final String novelId;
  final String databasePath;
  final String screenplayId;
  final List<ScreenplaySeasonRow> seasons;
  final ScreenplaySeasonRow currentSeason;
  final Map<String, int> episodeCounts;
  final _SeasonMode mode;
  final ValueChanged<_SeasonMode> onModeChanged;
  final ValueChanged<String> onSelectSeason;
  final VoidCallback onAddSeason;
  final Future<bool> Function() onFlush;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final open = mode != _SeasonMode.closed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.sm,
        0,
        RevericSpacing.sm,
        RevericSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () =>
                onModeChanged(open ? _SeasonMode.closed : _SeasonMode.list),
            borderRadius: BorderRadius.circular(RevericRadius.large),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.x3l,
                vertical: RevericSpacing.md,
              ),
              decoration: BoxDecoration(
                color: colors.surfaceDim,
                borderRadius: BorderRadius.circular(RevericRadius.large),
                border: Border.all(
                  color: open ? colors.accent : colors.borderInput,
                ),
              ),
              child: Row(
                children: [
                  RevericIcon(
                    RevericIcons.movie_outlined,
                    size: 14,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  Expanded(
                    child: Text(
                      screenplaySeasonLabel(context, currentSeason),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiMedium.copyWith(
                        color: open ? colors.textPrimary : colors.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  ScreenplayEpisodeCount(
                    episodeCount: episodeCounts[currentSeason.id] ?? 0,
                    planned: currentSeason.plannedEpisodeCount,
                    showOverPlanned: false,
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  RevericIcon(
                    open
                        ? RevericIcons.expand_less_rounded
                        : RevericIcons.caret_down,
                    size: 12,
                    color: colors.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (mode == _SeasonMode.list)
            Container(
              margin: const EdgeInsets.only(top: RevericSpacing.xs),
              padding: const EdgeInsets.all(RevericSpacing.xs),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(RevericRadius.large),
                border: Border.all(color: colors.borderInput),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(context).height * 0.3,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final season in seasons)
                            _SeasonRow(
                              season: season,
                              episodeCount: episodeCounts[season.id] ?? 0,
                              selected: season.id == currentSeason.id,
                              onTap: () => onSelectSeason(season.id),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    height: 1,
                    margin: const EdgeInsets.symmetric(
                      vertical: RevericSpacing.xs,
                    ),
                    color: colors.borderSubtle,
                  ),
                  _SeasonAction(
                    icon: RevericIcons.add,
                    label: context.t(LocaleKeys.screenplayAddSeason),
                    onTap: onAddSeason,
                  ),
                  _SeasonAction(
                    icon: RevericIcons.tune,
                    label: context.t(LocaleKeys.screenplayManageSeasons),
                    onTap: () {
                      onModeChanged(_SeasonMode.closed);
                      unawaited(
                        showScreenplaySeasonManager(
                          context,
                          novelId: novelId,
                          databasePath: databasePath,
                          screenplayId: screenplayId,
                          onFlush: onFlush,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SeasonRow extends StatelessWidget {
  const _SeasonRow({
    required this.season,
    required this.episodeCount,
    required this.selected,
    required this.onTap,
  });

  final ScreenplaySeasonRow season;
  final int episodeCount;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.md,
          vertical: RevericSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: selected ? colors.selected : Colors.transparent,
          borderRadius: BorderRadius.circular(RevericRadius.medium),
          border: Border.all(
            color: selected ? colors.borderInput : Colors.transparent,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 季名和集数分两行 —— 第二列不宽，
            // 「第 1 季 · 淤沙」+「5/4 集」+「已超出规划」挤一行会把季名截断。
            Text(
              screenplaySeasonLabel(context, season),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (selected ? typo.uiMedium : typo.ui).copyWith(
                color: selected ? colors.textPrimary : colors.textSecondary,
              ),
            ),
            const SizedBox(height: 3),
            ScreenplayEpisodeCount(
              episodeCount: episodeCount,
              planned: season.plannedEpisodeCount,
            ),
          ],
        ),
      ),
    );
  }
}

class _SeasonAction extends StatelessWidget {
  const _SeasonAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final String icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.md,
          vertical: RevericSpacing.sm,
        ),
        child: Row(
          children: [
            RevericIcon(icon, size: 13, color: colors.textMuted),
            const SizedBox(width: RevericSpacing.sm),
            Text(label, style: typo.ui.copyWith(color: colors.textMuted)),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.label,
    required this.trailingCount,
    required this.addTooltip,
    required this.onAdd,
  });

  final String label;
  final Widget? trailingCount;
  final String addTooltip;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.lg,
        RevericSpacing.sm,
        RevericSpacing.xs,
        RevericSpacing.xs,
      ),
      child: Row(
        children: [
          Text(
            label,
            style: typo.uiSmallSemibold.copyWith(color: colors.textMuted),
          ),
          const SizedBox(width: RevericSpacing.sm),
          // ignore: use_null_aware_elements
          if (trailingCount != null) Flexible(child: trailingCount!),
          const Spacer(),
          IconButton(
            tooltip: addTooltip,
            onPressed: onAdd,
            iconSize: 12,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
            icon: RevericIcon(
              RevericIcons.add,
              size: 12,
              color: colors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _EpisodeTile extends StatefulWidget {
  const _EpisodeTile({
    required this.episode,
    required this.sceneCount,
    required this.selected,
    required this.multiSeason,
    required this.menuOpen,
    required this.canDelete,
    required this.isOnlyEpisode,
    required this.seasons,
    required this.onTap,
    required this.onToggleMenu,
    required this.onMove,
    required this.onDelete,
  });

  final ScreenplayEpisodeRow episode;
  final int? sceneCount;
  final bool selected;
  final bool multiSeason;
  final bool menuOpen;
  final bool canDelete;
  final bool isOnlyEpisode;
  final List<ScreenplaySeasonRow> seasons;
  final VoidCallback onTap;
  final VoidCallback onToggleMenu;
  final VoidCallback onMove;
  final VoidCallback onDelete;

  @override
  State<_EpisodeTile> createState() => _EpisodeTileState();
}

class _EpisodeTileState extends State<_EpisodeTile> {
  bool _hovered = false;

  void _showContextMenu(BuildContext context, TapDownDetails details) {
    final colors = RevericTheme.colorsOf(context);
    showRevericContextMenu(
      context: context,
      position: details.globalPosition,
      entries: [
        RevericMenuItem(
          icon: RevericIcons.delete_outline,
          iconColor: colors.deletionBorder,
          labelColor: colors.deletionBorder,
          label: context.t(LocaleKeys.commonDelete),
          onTap: widget.canDelete ? widget.onDelete : null,
          enabled: widget.canDelete,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final episode = widget.episode;
    final title = episode.title.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onSecondaryTapDown: (details) => _showContextMenu(context, details),
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(RevericRadius.medium),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.md,
                  vertical: RevericSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: widget.selected
                      ? colors.selected
                      : _hovered
                      ? colors.hover
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(RevericRadius.medium),
                  border: Border.all(
                    color: widget.selected
                        ? colors.borderInput
                        : Colors.transparent,
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      screenplayEpisodeNumberLabel(context, episode),
                      style: typo.uiMedium.copyWith(
                        color: widget.selected
                            ? colors.textPrimary
                            : colors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: RevericSpacing.sm),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.ui.copyWith(
                          color: widget.selected
                              ? colors.textSecondary
                              : colors.textMuted,
                        ),
                      ),
                    ),
                    // 跨季移动是多季才有的操作，单季作品连这个入口都不出现。
                    if (_hovered && widget.multiSeason)
                      IconButton(
                        tooltip: context.t(LocaleKeys.commonMoreActions),
                        onPressed: widget.onToggleMenu,
                        iconSize: 13,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 22,
                          height: 22,
                        ),
                        icon: RevericIcon(
                          RevericIcons.more_horiz,
                          size: 13,
                          color: colors.textMuted,
                        ),
                      )
                    else if (widget.sceneCount case final count?)
                      Text(
                        context.t(
                          LocaleKeys.screenplaySceneCount,
                          namedArgs: {'count': '$count'},
                        ),
                        style: typo.mono.copyWith(
                          height: 1.2,
                          color: colors.textSubtle,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (widget.menuOpen)
          Container(
            margin: const EdgeInsets.only(
              top: RevericSpacing.xs,
              bottom: RevericSpacing.sm,
            ),
            padding: const EdgeInsets.all(RevericSpacing.xs),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(RevericRadius.large),
              border: Border.all(color: colors.borderInput),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _MenuItem(
                  label: context.t(LocaleKeys.screenplayEpisodeMove),
                  onTap: widget.isOnlyEpisode ? null : widget.onMove,
                ),
                // 每季至少留一集 —— 移走最后一集会让这一季没有可写的地方。
                if (widget.isOnlyEpisode)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      RevericSpacing.md,
                      RevericSpacing.xs,
                      RevericSpacing.md,
                      RevericSpacing.sm,
                    ),
                    child: Text(
                      context.t(LocaleKeys.screenplayLastEpisodeInSeason),
                      style: typo.uiTiny.copyWith(
                        height: 1.6,
                        color: colors.textSubtle,
                      ),
                    ),
                  ),
                Container(
                  height: 1,
                  margin: const EdgeInsets.symmetric(
                    vertical: RevericSpacing.xs,
                  ),
                  color: colors.borderSubtle,
                ),
                _MenuItem(
                  label: context.t(LocaleKeys.commonDelete),
                  danger: true,
                  onTap: widget.canDelete ? widget.onDelete : null,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final color = onTap == null
        ? colors.textSubtle
        : danger
        ? colors.deletionBorder
        : colors.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.md,
          vertical: RevericSpacing.sm,
        ),
        child: Text(label, style: typo.ui.copyWith(color: color)),
      ),
    );
  }
}

/// `.sp-scene-row` —— 场号带顿号、地点撑满、拍摄条件靠右的紧凑单行。
class _SceneRow extends StatefulWidget {
  const _SceneRow({
    required this.scene,
    required this.locationNames,
    required this.selected,
    required this.onTap,
    required this.onDelete,
  });

  final ScreenplaySceneSummary scene;
  final Map<String, String> locationNames;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  State<_SceneRow> createState() => _SceneRowState();
}

class _SceneRowState extends State<_SceneRow> {
  bool _hovered = false;

  void _showContextMenu(BuildContext context, TapDownDetails details) {
    final colors = RevericTheme.colorsOf(context);
    showRevericContextMenu(
      context: context,
      position: details.globalPosition,
      entries: [
        RevericMenuItem(
          icon: RevericIcons.delete_outline,
          iconColor: colors.deletionBorder,
          labelColor: colors.deletionBorder,
          label: context.t(LocaleKeys.commonDelete),
          onTap: widget.onDelete,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final scene = widget.scene;
    final place = screenplaySceneLocation(
      context,
      scene,
      locationNames: widget.locationNames,
    );
    final (time, interiorExterior) = screenplaySceneCondition(context, scene);
    return GestureDetector(
      onSecondaryTapDown: (details) => _showContextMenu(context, details),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(RevericRadius.medium),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.md,
              vertical: RevericSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: widget.selected
                  ? colors.selected
                  : _hovered
                  ? colors.hover
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(RevericRadius.medium),
              border: Border.all(
                color: widget.selected
                    ? colors.borderInput
                    : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                Text(
                  '${scene.sceneNumber}、',
                  style: typo.ui.copyWith(
                    color: colors.textSubtle,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        scene.title.isEmpty ? place : scene.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.ui.copyWith(color: colors.textPrimary),
                      ),
                      Text(
                        [
                          if (scene.title.isNotEmpty) place,
                          [
                            time,
                            interiorExterior,
                          ].where((s) => s.isNotEmpty).join(' / '),
                        ].where((s) => s.isNotEmpty).join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.uiTiny.copyWith(color: colors.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AddRow extends StatelessWidget {
  const _AddRow({required this.icon, required this.label, required this.onTap});

  final String icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.md,
          vertical: RevericSpacing.sm,
        ),
        child: Row(
          children: [
            RevericIcon(icon, size: 14, color: colors.textSubtle),
            const SizedBox(width: RevericSpacing.sm),
            Text(label, style: typo.ui.copyWith(color: colors.textSubtle)),
          ],
        ),
      ),
    );
  }
}

ScreenplaySeasonRow? _findSeason(List<ScreenplaySeasonRow> rows, String? id) {
  for (final row in rows) {
    if (row.id == id) return row;
  }
  return rows.firstOrNull;
}

ScreenplayEpisodeRow? _findEpisode(
  List<ScreenplayEpisodeRow> rows,
  String? id,
) {
  for (final row in rows) {
    if (row.id == id) return row;
  }
  return rows.firstOrNull;
}

Future<void> _deleteEpisode(
  BuildContext context,
  WidgetRef ref, {
  required ScreenplayService service,
  required ScreenplayEpisodeRow episode,
  required List<ScreenplayEpisodeRow> episodes,
  required ScreenplayWorkspaceState workspace,
  required ScreenplayWorkspaceStateControllerProvider stateProvider,
  required Future<bool> Function() onFlush,
}) async {
  if (!await onFlush() || !context.mounted) return;
  final confirmed = await showConfirmDialog(
    context,
    title: context.t(LocaleKeys.commonDelete),
    message: context.t(LocaleKeys.screenplayConfirmDelete),
    variant: ConfirmDialogVariant.warning,
  );
  if (!confirmed) return;
  await service.deleteEpisode(episode.id);
  if (episode.id == workspace.episodeId) {
    final index = episodes.indexOf(episode);
    final remaining = [...episodes]..removeAt(index);
    final next = remaining[index.clamp(0, remaining.length - 1)];
    ref
        .read(stateProvider.notifier)
        .update(workspace.copyWith(episodeId: next.id, clearSceneId: true));
  }
}

Future<void> _deleteScene(
  BuildContext context,
  WidgetRef ref, {
  required ScreenplayService service,
  required ScreenplaySceneSummary scene,
  required ScreenplayWorkspaceStateControllerProvider stateProvider,
  required Future<bool> Function() onFlush,
}) async {
  if (!await onFlush() || !context.mounted) {
    return;
  }
  final confirmed = await showConfirmDialog(
    context,
    title: context.t(LocaleKeys.commonDelete),
    message: context.t(LocaleKeys.screenplayConfirmDelete),
    variant: ConfirmDialogVariant.warning,
  );
  if (!confirmed) {
    return;
  }
  await service.deleteScene(scene.id);
  if (!context.mounted) {
    return;
  }
  await ref.read(stateProvider.notifier).reconcile();
}

void _showSaveError(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(context.t(LocaleKeys.screenplaySaveFailed))),
  );
}

// 职责: 桌面剧本概览区域 — 组合页头、继续写作、故事简介与分集看板或各季摘要。
// 关联文件:
//   lib/desktop/widgets/workspace/novel_workspace_panel.dart
//   lib/desktop/features/screenplay/chrome.dart
//   lib/shared/providers/screenplay_providers.dart
//   lib/shared/providers/screenplay_workspace_state_provider.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/performance.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_segmented_control.dart';
import '../../../shared/database/app_database.dart';
import '../../../shared/database/novel_content_database.dart'
    show ScreenplayEpisodeRow, ScreenplaySeasonRow;
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/screenplay_providers.dart';
import '../../../shared/providers/screenplay_workspace_state_provider.dart';
import '../../../shared/theme/theme.dart';
import 'chips.dart';
import 'chrome.dart';
import 'overview_cards.dart';
import 'support.dart';

/// 概览的统计范围。单季作品这一层在界面上根本不存在，范围恒为整部剧集。
enum _OverviewScope { series, season }

class ScreenplayOverviewRegion extends HookConsumerWidget {
  const ScreenplayOverviewRegion({
    super.key,
    required this.novel,
    required this.screenplayId,
    this.onEditNovel,
  });

  final Novel novel;
  final String screenplayId;
  final VoidCallback? onEditNovel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = novel.contentDatabasePath!;
    final scope = useState(_OverviewScope.season);
    final stateProvider = screenplayWorkspaceStateControllerProvider(
      novel.id,
      path,
    );
    final workspace = ref.watch(stateProvider);
    final seasons =
        ref.watch(screenplaySeasonsProvider(path, screenplayId)).value ??
        const <ScreenplaySeasonRow>[];
    final multiSeason = seasons.length > 1;
    final currentSeason = _currentSeason(seasons, workspace.seasonId);
    final scoped = multiSeason && scope.value == _OverviewScope.season;
    final overview = ref
        .watch(
          screenplayOverviewProvider(
            path,
            screenplayId,
            seasonId: scoped ? currentSeason?.id : null,
          ),
        )
        .value;
    final episodesBySeason = <String, List<ScreenplayEpisodeRow>>{
      for (final season in seasons)
        season.id:
            ref.watch(screenplayEpisodesProvider(path, season.id)).value ??
            const <ScreenplayEpisodeRow>[],
    };
    final scopedEpisodes = scoped
        ? episodesBySeason[currentSeason?.id] ?? const <ScreenplayEpisodeRow>[]
        : [for (final rows in episodesBySeason.values) ...rows];

    // 继续写作落在当前集；还没选过集就落在当前季第一集。
    final currentEpisode =
        scopedEpisodes.where((e) => e.id == workspace.episodeId).firstOrNull ??
        (episodesBySeason[currentSeason?.id] ?? const <ScreenplayEpisodeRow>[])
            .firstOrNull;

    // 分区名由工作区面包屑给出，这里不再铺一条只写着「概览」的顶栏。
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.x5l,
        RevericSpacing.x4l,
        RevericSpacing.x5l,
        64,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: RevericSizes.screenplayOverviewMaxWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _OverviewHeader(
                novel: novel,
                onEditNovel: onEditNovel,
                seasonCount: seasons.length,
                episodeCount: scopedEpisodes.length,
              ),
              if (currentEpisode != null) ...[
                const SizedBox(height: RevericSpacing.x3l),
                ScreenplayContinueCard(
                  novelId: novel.id,
                  path: path,
                  episode: currentEpisode,
                ),
              ],
              // 范围同时决定下面的统计和列表，所以排在简介卡之前。
              if (multiSeason && currentSeason != null) ...[
                const SizedBox(height: RevericSpacing.x3l),
                Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: 300,
                    child: RevericSegmentedControl<_OverviewScope>(
                      selected: scope.value,
                      segments: [
                        RevericSegment(
                          value: _OverviewScope.series,
                          label: context.t(LocaleKeys.screenplayScopeSeries),
                          icon: RevericIcons.movie_outlined,
                        ),
                        RevericSegment(
                          value: _OverviewScope.season,
                          label: screenplaySeasonLabel(context, currentSeason),
                          icon: RevericIcons.stack,
                        ),
                      ],
                      onChanged: (next) => scope.value = next,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: RevericSpacing.x3l),
              ScreenplayIntroCard(
                novel: novel,
                overview: overview,
                showBeats: !(multiSeason && !scoped),
              ),
              const SizedBox(height: RevericSpacing.x3l),
              if (multiSeason && !scoped)
                _SeasonSummaryCard(
                  path: path,
                  screenplayId: screenplayId,
                  seasons: seasons,
                  episodesBySeason: episodesBySeason,
                  currentSeasonId: currentSeason?.id,
                  onSelectSeason: (seasonId) => ref
                      .read(stateProvider.notifier)
                      .update(
                        workspace.copyWith(
                          seasonId: seasonId,
                          clearEpisodeId: true,
                          clearSceneId: true,
                        ),
                      ),
                )
              else
                // 概览不挂剧集/场次中栏，分集入口由这张看板给出；集号跨季会从 1
                // 重来，所以多季时只排当前季。
                ScreenplayEpisodeBoard(
                  novelId: novel.id,
                  path: path,
                  episodes:
                      episodesBySeason[currentSeason?.id] ??
                      const <ScreenplayEpisodeRow>[],
                  currentEpisodeId: currentEpisode?.id,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

ScreenplaySeasonRow? _currentSeason(
  List<ScreenplaySeasonRow> seasons,
  String? id,
) {
  for (final season in seasons) {
    if (season.id == id) return season;
  }
  return seasons.firstOrNull;
}

/// 页头只留类型、标题和规模标签；logline 进简介卡，继续写进继续写作卡。
class _OverviewHeader extends StatelessWidget {
  const _OverviewHeader({
    required this.novel,
    required this.onEditNovel,
    required this.seasonCount,
    required this.episodeCount,
  });

  final Novel novel;
  final VoidCallback? onEditNovel;
  final int seasonCount;
  final int episodeCount;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RevericIcon(
                    RevericIcons.stack,
                    size: 13,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  Text(
                    context.t(LocaleKeys.screenplaySeries),
                    style: typo.uiTiny.copyWith(
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.6,
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: RevericSpacing.md),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      novel.title,
                      style: typo.body.copyWith(
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: RevericSpacing.md),
                  IconButton(
                    tooltip: context.t(LocaleKeys.editorEditNovelInfo),
                    onPressed: onEditNovel,
                    splashRadius: 18,
                    icon: RevericIcon(
                      RevericIcons.edit_outlined,
                      size: 18,
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: RevericSpacing.lg),
        Wrap(
          spacing: RevericSpacing.sm,
          runSpacing: RevericSpacing.sm,
          children: [
            if (seasonCount > 1)
              ScreenplayChip(
                icon: RevericIcons.movie_outlined,
                label:
                    '${context.t(LocaleKeys.screenplaySeasonCount, namedArgs: {'count': '$seasonCount'})}'
                    ' · '
                    '${context.t(LocaleKeys.screenplayEpisodeCount, namedArgs: {'count': '$episodeCount'})}',
              )
            else
              ScreenplayChip(
                icon: RevericIcons.stack,
                label: context.t(
                  LocaleKeys.screenplayEpisodeCount,
                  namedArgs: {'count': '$episodeCount'},
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 各季摘要 —— 只在多季 + 看整部剧集时出现，每一行都能直接进那一季。
class _SeasonSummaryCard extends ConsumerWidget {
  const _SeasonSummaryCard({
    required this.path,
    required this.screenplayId,
    required this.seasons,
    required this.episodesBySeason,
    required this.currentSeasonId,
    required this.onSelectSeason,
  });

  final String path;
  final String screenplayId;
  final List<ScreenplaySeasonRow> seasons;
  final Map<String, List<ScreenplayEpisodeRow>> episodesBySeason;
  final String? currentSeasonId;
  final ValueChanged<String> onSelectSeason;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return ScreenplayCard(
      icon: RevericIcons.movie_outlined,
      title: context.t(LocaleKeys.screenplayEachSeason),
      hint: Text(
        context.t(
          LocaleKeys.screenplaySeasonCount,
          namedArgs: {'count': '${seasons.length}'},
        ),
        style: typo.uiTiny.copyWith(color: colors.textSubtle),
      ),
      child: Column(
        children: [
          for (final season in seasons)
            _SeasonSummaryRow(
              path: path,
              screenplayId: screenplayId,
              season: season,
              episodeCount: episodesBySeason[season.id]?.length ?? 0,
              isCurrent: season.id == currentSeasonId,
              isLast: season.id == seasons.last.id,
              onTap: () => onSelectSeason(season.id),
            ),
        ],
      ),
    );
  }
}

class _SeasonSummaryRow extends ConsumerWidget {
  const _SeasonSummaryRow({
    required this.path,
    required this.screenplayId,
    required this.season,
    required this.episodeCount,
    required this.isCurrent,
    required this.isLast,
    required this.onTap,
  });

  final String path;
  final String screenplayId;
  final ScreenplaySeasonRow season;
  final int episodeCount;
  final bool isCurrent;
  final bool isLast;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final stats = ref
        .watch(
          screenplayOverviewProvider(path, screenplayId, seasonId: season.id),
        )
        .value;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.md,
          vertical: RevericSpacing.lg,
        ),
        decoration: BoxDecoration(
          border: isLast
              ? null
              : Border(bottom: BorderSide(color: colors.borderSubtle)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    screenplaySeasonLabel(context, season),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.uiSemibold.copyWith(
                      color: isCurrent
                          ? colors.accentWarm
                          : colors.textSecondary,
                    ),
                  ),
                ),
                RevericIcon(
                  RevericIcons.arrow_forward,
                  size: 13,
                  color: colors.textSubtle,
                ),
              ],
            ),
            const SizedBox(height: RevericSpacing.sm),
            Wrap(
              spacing: RevericSpacing.md,
              runSpacing: RevericSpacing.xxs,
              children: [
                Text(
                  context.t(
                    LocaleKeys.screenplayEpisodeCount,
                    namedArgs: {'count': '$episodeCount'},
                  ),
                  style: typo.uiTiny.copyWith(color: colors.textSubtle),
                ),
                if (stats != null) ...[
                  Text(
                    context.t(
                      LocaleKeys.screenplaySceneCount,
                      namedArgs: {'count': '${stats.sceneCount}'},
                    ),
                    style: typo.uiTiny.copyWith(color: colors.textSubtle),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

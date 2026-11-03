// 职责: 桌面剧本概览的三块区域 — 继续写作、故事简介与规模统计、分集看板。
// 关联文件:
//   lib/desktop/features/screenplay/overview.dart
//   lib/desktop/features/screenplay/chrome.dart
//   lib/shared/providers/screenplay_providers.dart
//   lib/shared/providers/storyboard.dart
//   lib/shared/providers/screenplay_workspace_state_provider.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/performance.md

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_button.dart';
import '../../../shared/database/app_database.dart' show Novel;
import '../../../shared/database/novel_content_database.dart'
    show ProductionClipRow, ScreenplayEpisodeRow;
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/novel_workspace.dart';
import '../../../shared/models/screenplay.dart';
import '../../../shared/providers/screenplay_providers.dart';
import '../../../shared/providers/screenplay_workspace_state_provider.dart';
import '../../../shared/providers/storyboard.dart';
import '../../../shared/providers/workspace_navigation_provider.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/collections/cover.dart';
import '../../../shared/widgets/screenplay/inline_stat.dart';
import '../../../shared/widgets/screenplay/scene_stage_cells.dart';
import 'chips.dart';
import 'chrome.dart';
import 'support.dart';

/// 选中某集（可选某场）后切到剧本。概览没有正文编辑器，不需要先 flush。
void _openScript(
  WidgetRef ref, {
  required String novelId,
  required String path,
  required String episodeId,
  String? sceneId,
}) {
  final provider = screenplayWorkspaceStateControllerProvider(novelId, path);
  final workspace = ref.read(provider);
  ref
      .read(provider.notifier)
      .update(
        sceneId == null
            ? workspace.copyWith(episodeId: episodeId, clearSceneId: true)
            : workspace.copyWith(episodeId: episodeId, sceneId: sceneId),
      );
  ref
      .read(workspaceNavigationProvider.notifier)
      .request(
        const WorkspaceNavigationRequest(
          section: NovelWorkspaceSection.screenplay_script,
        ),
      );
}

void _openSection(WidgetRef ref, NovelWorkspaceSection section) {
  ref
      .read(workspaceNavigationProvider.notifier)
      .request(WorkspaceNavigationRequest(section: section));
}

/// 继续写作 —— 落在当前选中的场次；没有选中就落在本集第一场草稿。
/// 引这一场正文的最后一句，作者一眼认得出自己停在哪。
class ScreenplayContinueCard extends ConsumerWidget {
  const ScreenplayContinueCard({
    super.key,
    required this.novelId,
    required this.path,
    required this.episode,
  });

  final String novelId;
  final String path;
  final ScreenplayEpisodeRow episode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final selectedSceneId = ref
        .watch(screenplayWorkspaceStateControllerProvider(novelId, path))
        .sceneId;
    final previews =
        ref
            .watch(screenplayEpisodeScriptPreviewProvider(path, episode.id))
            .value ??
        const <EpisodeScriptScenePreview>[];
    final (:preview, :quote) = screenplayContinuePoint(
      previews,
      selectedSceneId,
    );
    final scene = preview?.scene;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.x4l,
        vertical: RevericSpacing.x3l,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(RevericRadius.x2l),
        border: Border.all(color: colors.borderInput),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RevericIcon(
                RevericIcons.pencil_simple,
                size: 14,
                color: colors.accentWarm,
              ),
              const SizedBox(width: RevericSpacing.sm),
              Text(
                context.t(LocaleKeys.workspaceContinueWriting),
                style: typo.uiSmallSemibold.copyWith(color: colors.accentWarm),
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.lg),
          Row(
            children: [
              Flexible(
                child: Text(
                  [
                    screenplayEpisodeNumberLabel(context, episode),
                    if (episode.title.trim().isNotEmpty) episode.title.trim(),
                    if (scene != null) ...[
                      '·',
                      screenplaySceneLabel(context, scene),
                      screenplaySceneTitle(context, scene),
                    ],
                  ].where((part) => part.isNotEmpty).join(' '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.uiSmall.copyWith(color: colors.textMuted),
                ),
              ),
              if (scene != null) ...[
                const SizedBox(width: RevericSpacing.sm),
                ScreenplayStageBadge(stage: scene.stage),
              ],
            ],
          ),
          if (quote != null) ...[
            const SizedBox(height: RevericSpacing.md),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Text(
                quote,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: typo.body.copyWith(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  height: 1.6,
                  color: colors.textPrimary,
                ),
              ),
            ),
          ],
          const SizedBox(height: RevericSpacing.x2l),
          Wrap(
            spacing: RevericSpacing.sm,
            runSpacing: RevericSpacing.sm,
            children: [
              RevericButton.primary(
                icon: RevericIcons.pencil_simple,
                label: context.t(LocaleKeys.screenplayContinueWriting),
                onPressed: () => _openScript(
                  ref,
                  novelId: novelId,
                  path: path,
                  episodeId: episode.id,
                  sceneId: scene?.id,
                ),
              ),
              RevericButton.secondary(
                icon: RevericIcons.format_list_numbered,
                label: context.t(LocaleKeys.screenplayOutline),
                onPressed: () =>
                    _openSection(ref, NovelWorkspaceSection.screenplay_outline),
              ),
              RevericButton.secondary(
                icon: RevericIcons.stack,
                label: context.t(LocaleKeys.screenplayScenes),
                onPressed: () =>
                    _openSection(ref, NovelWorkspaceSection.screenplay_scenes),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 故事简介 + 规模统计 —— 统计收成卡底一条，不再各占一格大数字。
class ScreenplayIntroCard extends StatelessWidget {
  const ScreenplayIntroCard({
    super.key,
    required this.novel,
    required this.overview,
  });

  final Novel novel;
  final ScreenplayOverview? overview;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final logline = novel.description.trim();
    final stats = overview;
    return ScreenplayCard(
      icon: RevericIcons.book_open,
      title: context.t(LocaleKeys.screenplayStoryIntro),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 72,
                height: 100,
                child: CollectionWorkCover(work: novel),
              ),
              const SizedBox(width: RevericSpacing.x2l),
              Expanded(
                child: SelectionArea(
                  child: Text(
                    logline,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: typo.body.copyWith(color: colors.textSecondary),
                  ),
                ),
              ),
            ],
          ),
          if (stats != null) ...[
            const SizedBox(height: RevericSpacing.x2l),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.x2l,
                vertical: RevericSpacing.md,
              ),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(RevericRadius.large),
                border: Border.all(color: colors.borderSubtle),
              ),
              child: Wrap(
                spacing: RevericSpacing.x3l,
                runSpacing: RevericSpacing.sm,
                children: [
                  ScreenplayInlineStat(
                    label: context.t(LocaleKeys.screenplayScenes),
                    value: '${stats.sceneCount}',
                    unit: context.t(LocaleKeys.screenplayUnitScenes),
                  ),
                  ScreenplayInlineStat(
                    label: context.t(LocaleKeys.screenplayLength),
                    value: screenplayPageEighthsText(stats.pageEighths),
                    unit: context.t(LocaleKeys.screenplayPagesUnit),
                  ),
                  ScreenplayInlineStat(
                    label: context.t(LocaleKeys.screenplayDialogueLines),
                    value: '${stats.dialogueLineCount}',
                    unit: context.t(LocaleKeys.screenplayUnitLines),
                  ),
                  ScreenplayInlineStat(
                    label: context.t(LocaleKeys.screenplayCharacterList),
                    value: '${stats.characterCount}',
                    unit: context.t(LocaleKeys.screenplayUnitPeople),
                  ),
                  ScreenplayInlineStat(
                    label: context.t(LocaleKeys.screenplayPlaces),
                    value: '${stats.locationCount}',
                    unit: context.t(LocaleKeys.screenplayUnitPlaces),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 分集看板 —— 一集一行：场次格子（实心 = 定稿）、定稿数、分镜采用数。
/// 集数多到几十集也是一屏能扫完的列表，不做卡片墙。
class ScreenplayEpisodeBoard extends StatelessWidget {
  const ScreenplayEpisodeBoard({
    super.key,
    required this.novelId,
    required this.path,
    required this.episodes,
    required this.currentEpisodeId,
  });

  final String novelId;
  final String path;
  final List<ScreenplayEpisodeRow> episodes;
  final String? currentEpisodeId;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final head = typo.uiTiny.copyWith(
      fontWeight: FontWeight.w500,
      color: colors.textSubtle,
    );
    return ScreenplayCard(
      icon: RevericIcons.stack,
      title: context.t(LocaleKeys.screenplayEpisodes),
      hint: Text(
        context.t(
          LocaleKeys.screenplayEpisodeCount,
          namedArgs: {'count': '${episodes.length}'},
        ),
        style: typo.uiTiny.copyWith(color: colors.textSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _EpisodeRowLayout(
            number: const SizedBox.shrink(),
            title: const SizedBox.shrink(),
            cells: Text(context.t(LocaleKeys.screenplayScenes), style: head),
            finals: Text(
              context.t(LocaleKeys.screenplayFinal),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: head,
            ),
            clips: Text(
              context.t(LocaleKeys.storyboardBoard),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: head,
            ),
            trailing: const SizedBox.shrink(),
          ),
          for (final episode in episodes)
            _EpisodeBoardRow(
              novelId: novelId,
              path: path,
              episode: episode,
              isCurrent: episode.id == currentEpisodeId,
            ),
        ],
      ),
    );
  }
}

class _EpisodeBoardRow extends ConsumerWidget {
  const _EpisodeBoardRow({
    required this.novelId,
    required this.path,
    required this.episode,
    required this.isCurrent,
  });

  final String novelId;
  final String path;
  final ScreenplayEpisodeRow episode;
  final bool isCurrent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final scenes =
        ref.watch(screenplayScenesProvider(path, episode.id)).value ??
        const <ScreenplaySceneSummary>[];
    final clips =
        ref.watch(storyboardShotsProvider(path, episode.id)).value ??
        const <ProductionClipRow>[];
    final finals = scenes
        .where((scene) => scene.stage == screenplayStageFinal)
        .length;
    final adopted = clips.where((clip) => clip.adoptedAssetId != null).length;
    final numStyle = typo.mono.copyWith(
      fontSize: typo.uiTiny.fontSize,
      color: colors.textMuted,
    );
    return Material(
      color: isCurrent ? colors.selected : Colors.transparent,
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: InkWell(
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        hoverColor: colors.hover,
        onTap: () => _openScript(
          ref,
          novelId: novelId,
          path: path,
          episodeId: episode.id,
        ),
        child: _EpisodeRowLayout(
          number: Text(
            screenplayEpisodeNumberLabel(context, episode),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: typo.uiSmallSemibold.copyWith(
              color: isCurrent ? colors.accentWarm : colors.textSecondary,
            ),
          ),
          title: Text(
            episode.title.trim(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: typo.uiMedium.copyWith(color: colors.textPrimary),
          ),
          cells: scenes.isEmpty
              ? Text('—', style: numStyle)
              : ScreenplaySceneStageCells(scenes: scenes),
          finals: Text(
            scenes.isEmpty ? '—' : '$finals/${scenes.length}',
            textAlign: TextAlign.right,
            style: numStyle,
          ),
          clips: Text(
            clips.isEmpty ? '—' : '$adopted/${clips.length}',
            textAlign: TextAlign.right,
            style: numStyle,
          ),
          trailing: RevericIcon(
            RevericIcons.arrow_forward,
            size: 13,
            color: colors.textSubtle,
          ),
        ),
      ),
    );
  }
}

/// 表头和数据行共用一套列宽，保证「定稿」「分镜」两列右对齐到同一条线。
class _EpisodeRowLayout extends StatelessWidget {
  const _EpisodeRowLayout({
    required this.number,
    required this.title,
    required this.cells,
    required this.finals,
    required this.clips,
    required this.trailing,
  });

  final Widget number;
  final Widget title;
  final Widget cells;
  final Widget finals;
  final Widget clips;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.sm,
        vertical: RevericSpacing.md,
      ),
      child: Row(
        children: [
          SizedBox(width: 60, child: number),
          const SizedBox(width: RevericSpacing.lg),
          Expanded(flex: 10, child: title),
          const SizedBox(width: RevericSpacing.lg),
          Expanded(flex: 14, child: cells),
          const SizedBox(width: RevericSpacing.lg),
          SizedBox(width: 72, child: finals),
          const SizedBox(width: RevericSpacing.lg),
          SizedBox(width: 72, child: clips),
          const SizedBox(width: RevericSpacing.lg),
          SizedBox(width: 16, child: trailing),
        ],
      ),
    );
  }
}

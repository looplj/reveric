// 职责: 移动端剧本概览的继续写作卡与故事简介卡。
// 关联文件:
//   lib/mobile/features/screenplay/overview.dart
//   lib/shared/providers/screenplay_providers.dart
//   lib/shared/providers/screenplay_workspace_state_provider.dart
//   lib/shared/widgets/screenplay/inline_stat.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/state-management.md

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/database/app_database.dart' show Novel;
import '../../../shared/database/novel_content_database.dart'
    show ScreenplayEpisodeRow;
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/screenplay.dart';
import '../../../shared/models/screenplay_workspace_state.dart';
import '../../../shared/providers/screenplay_providers.dart';
import '../../../shared/providers/screenplay_workspace_state_provider.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/collections/cover.dart';
import '../../../shared/widgets/screenplay/chips.dart';
import '../../../shared/widgets/screenplay/inline_stat.dart';
import 'support.dart';

/// 继续写作 —— 落在当前选中的场次，引这一场正文的最后一句。
class MobileScreenplayContinueCard extends ConsumerWidget {
  const MobileScreenplayContinueCard({
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
    final provider = screenplayWorkspaceStateControllerProvider(novelId, path);
    final workspace = ref.watch(provider);
    final previews =
        ref
            .watch(screenplayEpisodeScriptPreviewProvider(path, episode.id))
            .value ??
        const <EpisodeScriptScenePreview>[];
    final (:preview, :quote) = screenplayContinuePoint(
      previews,
      workspace.sceneId,
    );
    final scene = preview?.scene;
    void open() {
      final current = ref.read(provider);
      ref
          .read(provider.notifier)
          .update(
            scene == null
                ? current.copyWith(
                    section: ScreenplayWorkspaceSection.script,
                    seasonId: episode.seasonId,
                    episodeId: episode.id,
                    clearSceneId: true,
                  )
                : current.copyWith(
                    section: ScreenplayWorkspaceSection.script,
                    seasonId: episode.seasonId,
                    episodeId: episode.id,
                    sceneId: scene.id,
                  ),
          );
    }

    return Container(
      padding: const EdgeInsets.all(RevericSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        border: Border.all(color: colors.borderInput),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
          const SizedBox(height: RevericSpacing.md),
          Row(
            children: [
              Flexible(
                child: Text(
                  [
                    mobileEpisodeLabel(context, episode),
                    if (scene != null) mobileSceneLabel(context, scene),
                  ].join(' · '),
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
            const SizedBox(height: RevericSpacing.sm),
            Text(
              quote,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: typo.body.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.6,
                color: colors.textPrimary,
              ),
            ),
          ],
          const SizedBox(height: RevericSpacing.lg),
          FilledButton.icon(
            onPressed: open,
            icon: const RevericIcon(RevericIcons.pencil_simple, size: 18),
            label: Text(
              context.t(LocaleKeys.screenplayContinueWriting),
              style: typo.uiSemibold.copyWith(color: colors.onAccent),
            ),
          ),
        ],
      ),
    );
  }
}

/// 故事简介 —— 封面、logline、来源与规模标签，卡底一条统计。
class MobileScreenplayIntroCard extends StatelessWidget {
  const MobileScreenplayIntroCard({
    super.key,
    required this.novel,
    required this.overview,
    required this.chips,
  });

  final Novel novel;
  final ScreenplayOverview overview;
  final List<String> chips;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final logline = novel.description.trim();
    return MobileScreenplayCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 56,
                height: 78,
                child: CollectionWorkCover(work: novel),
              ),
              const SizedBox(width: RevericSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.t(LocaleKeys.screenplayStoryIntro),
                      style: typo.uiSmallSemibold.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                    const SizedBox(height: RevericSpacing.xs),
                    Text(
                      logline.isEmpty ? novel.title : logline,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: typo.body.copyWith(color: colors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.md),
          Wrap(
            spacing: RevericSpacing.sm,
            runSpacing: RevericSpacing.xs,
            children: [for (final chip in chips) ScreenplayChip(label: chip)],
          ),
          const SizedBox(height: RevericSpacing.md),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.md,
              vertical: RevericSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(RevericRadius.medium),
            ),
            child: Wrap(
              spacing: RevericSpacing.lg,
              runSpacing: RevericSpacing.sm,
              children: [
                ScreenplayInlineStat(
                  label: context.t(LocaleKeys.screenplayScenes),
                  value: '${overview.sceneCount}',
                  unit: context.t(LocaleKeys.screenplayUnitScenes),
                ),
                ScreenplayInlineStat(
                  label: context.t(LocaleKeys.screenplayLength),
                  value: screenplayPageEighthsText(overview.pageEighths),
                  unit: context.t(LocaleKeys.screenplayPagesUnit),
                ),
                ScreenplayInlineStat(
                  label: context.t(LocaleKeys.screenplayDialogueLines),
                  value: '${overview.dialogueLineCount}',
                  unit: context.t(LocaleKeys.screenplayUnitLines),
                ),
                ScreenplayInlineStat(
                  label: context.t(LocaleKeys.screenplayCharacterList),
                  value: '${overview.characterCount}',
                  unit: context.t(LocaleKeys.screenplayUnitPeople),
                ),
                ScreenplayInlineStat(
                  label: context.t(LocaleKeys.screenplayPlaces),
                  value: '${overview.locationCount}',
                  unit: context.t(LocaleKeys.screenplayUnitPlaces),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

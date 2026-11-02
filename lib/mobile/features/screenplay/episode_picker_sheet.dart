// 职责: 移动端分集选择 Sheet — 选择、新增、移动或确认删除当前季分集，并提供低频季管理入口。
// 关联文件:
//   lib/mobile/features/screenplay/editor_page.dart
//   lib/mobile/features/screenplay/episode_move_sheet.dart
//   lib/mobile/features/screenplay/season_manage_sheet.dart
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
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/database/app_database.dart';
import '../../../shared/database/novel_content_database.dart'
    show ScreenplayEpisodeRow, ScreenplaySeasonRow;
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/screenplay_providers.dart';
import '../../../shared/providers/screenplay_workspace_state_provider.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/confirm_dialog.dart';
import 'episode_move_sheet.dart';
import 'season_manage_sheet.dart';
import 'support.dart';

Future<void> showMobileScreenplayEpisodePicker(
  BuildContext context, {
  required Novel novel,
  required String screenplayId,
  required Future<bool> Function() onFlush,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.75,
      child: _EpisodePickerSheet(
        novel: novel,
        screenplayId: screenplayId,
        onFlush: onFlush,
      ),
    ),
  );
}

class _EpisodePickerSheet extends ConsumerWidget {
  const _EpisodePickerSheet({
    required this.novel,
    required this.screenplayId,
    required this.onFlush,
  });

  final Novel novel;
  final String screenplayId;
  final Future<bool> Function() onFlush;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = novel.contentDatabasePath!;
    final stateProvider = screenplayWorkspaceStateControllerProvider(
      novel.id,
      path,
    );
    final workspace = ref.watch(stateProvider);
    final seasons =
        ref.watch(screenplaySeasonsProvider(path, screenplayId)).value ??
        const <ScreenplaySeasonRow>[];
    final season = seasons
        .where((row) => row.id == workspace.seasonId)
        .firstOrNull;
    final episodes = season == null
        ? const <ScreenplayEpisodeRow>[]
        : ref.watch(screenplayEpisodesProvider(path, season.id)).value ??
              const <ScreenplayEpisodeRow>[];
    final service = ref.read(
      screenplayServiceProvider(path, novelId: novel.id),
    );

    Future<void> select(ScreenplayEpisodeRow episode) async {
      if (!await onFlush()) return;
      ref
          .read(stateProvider.notifier)
          .update(
            workspace.copyWith(episodeId: episode.id, clearSceneId: true),
          );
      if (context.mounted) Navigator.of(context).pop();
    }

    Future<void> addEpisode() async {
      if (season == null || !await onFlush()) return;
      final id = await service.createEpisode(seasonId: season.id);
      ref
          .read(stateProvider.notifier)
          .update(workspace.copyWith(episodeId: id, clearSceneId: true));
      if (context.mounted) Navigator.of(context).pop();
    }

    Future<void> addSeason() async {
      if (!await onFlush()) return;
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
      if (context.mounted) Navigator.of(context).pop();
    }

    Future<bool> confirmDelete(ScreenplayEpisodeRow episode) async {
      if (episodes.length == 1 || !await onFlush() || !context.mounted) {
        return false;
      }
      return showConfirmDialog(
        context,
        title: context.t(LocaleKeys.commonDelete),
        message: context.t(LocaleKeys.screenplayConfirmDelete),
        variant: ConfirmDialogVariant.warning,
      );
    }

    return Column(
      children: [
        MobileScreenplaySectionHeader(
          title: context.t(LocaleKeys.screenplayEpisodes),
          subtitle: season == null ? null : mobileSeasonLabel(context, season),
          trailing: IconButton(
            onPressed: addEpisode,
            icon: const RevericIcon(RevericIcons.add, size: 20),
          ),
        ),
        // 季管理里整行点击就是切季，所以这里不再先弹一层「选择季」。
        // 先关掉本层再开管理层 —— 两层 bottom sheet 叠着，上面那层的标题
        // 会压住下面那层的标题。
        if (seasons.length > 1)
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              showMobileScreenplaySeasonManager(
                context,
                novel: novel,
                screenplayId: screenplayId,
                onFlush: onFlush,
              );
            },
            child: Text(context.t(LocaleKeys.screenplayManageSeasons)),
          )
        // 单季不显示季层，规划集数从「本季设置」直接进表单。
        else if (season != null)
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              showMobileScreenplaySeasonManager(
                context,
                novel: novel,
                screenplayId: screenplayId,
                onFlush: onFlush,
                editSeasonId: season.id,
              );
            },
            child: Text(context.t(LocaleKeys.screenplayEditSeason)),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.md),
            itemCount: episodes.length,
            itemBuilder: (context, index) {
              final episode = episodes[index];
              return Dismissible(
                key: ValueKey(episode.id),
                direction: episodes.length > 1
                    ? DismissDirection.endToStart
                    : DismissDirection.none,
                confirmDismiss: (_) => confirmDelete(episode),
                onDismissed: (_) async {
                  await service.deleteEpisode(episode.id);
                  await ref.read(stateProvider.notifier).reconcile();
                },
                background: _DeleteBackground(
                  label: context.t(LocaleKeys.commonDelete),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.md,
                  ),
                  minTileHeight: 52,
                  selected: episode.id == workspace.episodeId,
                  title: Text(mobileEpisodeLabel(context, episode)),
                  trailing: seasons.length > 1
                      ? IconButton(
                          tooltip: context.t(LocaleKeys.screenplayEpisodeMove),
                          onPressed: episodes.length == 1
                              ? null
                              : () => unawaited(
                                  showMobileScreenplayEpisodeMoveSheet(
                                    context,
                                    novel: novel,
                                    episode: episode,
                                    seasons: seasons,
                                    sourceEpisodes: episodes,
                                    onFlush: onFlush,
                                  ),
                                ),
                          icon: const RevericIcon(
                            RevericIcons.shuffle_outlined,
                            size: 18,
                          ),
                        )
                      : null,
                  onTap: () => unawaited(select(episode)),
                ),
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(RevericSpacing.lg),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: addSeason,
                icon: const RevericIcon(RevericIcons.add, size: 18),
                label: Text(context.t(LocaleKeys.screenplayAddSeason)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DeleteBackground extends StatelessWidget {
  const _DeleteBackground({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.x2l),
      color: colors.deletionBg,
      child: Text(label, style: TextStyle(color: colors.error)),
    );
  }
}

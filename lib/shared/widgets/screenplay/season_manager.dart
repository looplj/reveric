// 职责: 在平台弹层内管理季列表、编辑表单与季切换。
// 关联文件:
//   lib/shared/widgets/screenplay/season_edit_form.dart
//   lib/shared/widgets/screenplay/episode_count.dart
//   lib/shared/services/screenplay_service.dart
//   lib/shared/providers/screenplay_workspace_state_provider.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../mobile/widgets/sheet.dart';
import '../../components/reveric_context_menu.dart';
import '../../components/reveric_slidable_delete.dart';
import '../../database/novel_content_database.dart'
    show ScreenplayEpisodeRow, ScreenplaySeasonRow;
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../logger/app_logger.dart';
import '../../providers/novel_providers.dart';
import '../../providers/screenplay_providers.dart';
import '../../providers/screenplay_workspace_state_provider.dart';
import '../../theme/theme.dart';
import '../confirm_dialog.dart';
import 'episode_count.dart';
import 'labels.dart';
import 'season_edit_form.dart';

final _log = AppLogger.forModule('ScreenplaySeasonManager');

class ScreenplaySeasonManager extends HookConsumerWidget {
  const ScreenplaySeasonManager({
    super.key,
    required this.novelId,
    required this.databasePath,
    required this.screenplayId,
    required this.onFlush,
    this.editSeasonId,
  });

  final String novelId;
  final String databasePath;
  final String screenplayId;
  final Future<bool> Function() onFlush;

  /// 直接打开这一季的设置表单，取消或保存后关闭弹层而不是回到季列表。
  /// 单季作品不显示季层，规划集数只能从这里进。
  final String? editSeasonId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final isMobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final editing = useState<ScreenplaySeasonRow?>(null);
    final busy = useState(false);
    final error = useState(false);
    final scrollController = useScrollController();
    final stateProvider = screenplayWorkspaceStateControllerProvider(
      novelId,
      databasePath,
    );
    final workspace = ref.watch(stateProvider);
    final seasonData = ref.watch(
      screenplaySeasonsProvider(databasePath, screenplayId),
    );
    final seasons = seasonData.value ?? const <ScreenplaySeasonRow>[];
    final counts = screenplaySeasonEpisodeCounts(
      ref
              .watch(
                screenplayEpisodesOfScreenplayProvider(
                  databasePath,
                  screenplayId,
                ),
              )
              .value ??
          const <ScreenplayEpisodeRow>[],
    );
    final service = ref.read(
      screenplayServiceProvider(databasePath, novelId: novelId),
    );

    Future<void> run(Future<void> Function() action) async {
      if (busy.value) {
        return;
      }
      busy.value = true;
      error.value = false;
      try {
        await action();
      } catch (exception, stackTrace) {
        _log.error(
          'Season management failed',
          error: exception,
          stackTrace: stackTrace,
        );
        if (context.mounted) {
          error.value = true;
        }
      } finally {
        if (context.mounted) {
          busy.value = false;
        }
      }
    }

    Future<void> enter(ScreenplaySeasonRow season) async {
      if (!await onFlush() || !context.mounted) {
        return;
      }
      final rows = await ref
          .read(novelContentDatabaseProvider(databasePath))
          .screenplayDao
          .getEpisodes(season.id);
      if (!context.mounted) {
        return;
      }
      ref
          .read(stateProvider.notifier)
          .update(
            ref
                .read(stateProvider)
                .copyWith(
                  seasonId: season.id,
                  episodeId: rows.firstOrNull?.id,
                  clearEpisodeId: rows.isEmpty,
                  clearSceneId: true,
                ),
          );
      Navigator.of(context).pop();
    }

    Future<void> add() async {
      if (!await onFlush() || !context.mounted) {
        return;
      }
      final created = await service.createSeason(screenplayId: screenplayId);
      if (!context.mounted) {
        return;
      }
      ref
          .read(stateProvider.notifier)
          .update(
            ref
                .read(stateProvider)
                .copyWith(
                  seasonId: created.seasonId,
                  episodeId: created.episodeId,
                  clearSceneId: true,
                ),
          );
      Navigator.of(context).pop();
    }

    Future<void> move(int index, int offset) async {
      if (!await onFlush() || !context.mounted) {
        return;
      }
      await service.moveSeason(seasons[index].id, index + offset + 1);
    }

    Future<void> remove(int index) async {
      if (seasons.length <= 1 || !await onFlush() || !context.mounted) {
        return;
      }
      final confirmed = await showConfirmDialog(
        context,
        title: context.t(LocaleKeys.commonDelete),
        message: context.t(LocaleKeys.screenplayConfirmDelete),
        variant: ConfirmDialogVariant.warning,
      );
      if (!confirmed || !context.mounted) {
        return;
      }
      await service.deleteSeason(seasons[index].id);
      if (context.mounted) {
        await ref
            .read(stateProvider.notifier)
            .reconcile(preferredSeasonIndex: index);
      }
    }

    final editedSeason =
        editing.value ??
        seasons.where((season) => season.id == editSeasonId).firstOrNull;
    void closeEdit() {
      if (editSeasonId != null) {
        Navigator.of(context).pop();
      } else {
        editing.value = null;
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          // 左边距和下面的列表、提交条同为 x4l —— 标题要和季卡片左缘对齐。
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.x4l,
            RevericSpacing.lg,
            RevericSpacing.lg,
            RevericSpacing.lg,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  context.t(
                    editedSeason == null
                        ? LocaleKeys.screenplayManageSeasons
                        : LocaleKeys.screenplayEditSeason,
                  ),
                  style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                ),
              ),
              IconButton(
                tooltip: context.t(LocaleKeys.commonClose),
                onPressed: busy.value
                    ? null
                    : () => Navigator.of(context).pop(),
                icon: const RevericIcon(RevericIcons.close),
              ),
            ],
          ),
        ),
        Divider(
          height: RevericSizes.dividerThickness,
          color: colors.borderSubtle,
        ),
        if (error.value || (seasonData.hasError && seasonData.value == null))
          Padding(
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.x4l,
              RevericSpacing.lg,
              RevericSpacing.x4l,
              0,
            ),
            child: Text(
              context.t(
                error.value
                    ? LocaleKeys.commonSaveFailed
                    : LocaleKeys.commonLoadFailed,
              ),
              style: typo.ui.copyWith(color: colors.warningText),
            ),
          ),
        if (editedSeason != null)
          // Flexible 而不是 Expanded —— Expanded 会把 mainAxisSize.min 的这列
          // 撑满可用高度，点一次「本季设置」弹层就从贴合内容跳到 75% 屏高，
          // 取消后再缩回去。表单只有两个字段，让它自己决定高度。
          Flexible(
            child: ScreenplaySeasonEditForm(
              key: ValueKey(editedSeason.id),
              season: editedSeason,
              busy: busy.value,
              onCancel: closeEdit,
              onSave: (title, planned) => run(() async {
                await service.updateSeason(
                  seasonId: editedSeason.id,
                  title: title,
                  plannedEpisodeCount: Value(planned),
                );
                if (context.mounted) {
                  FocusScope.of(context).unfocus();
                  closeEdit();
                }
              }),
            ),
          )
        else ...[
          Flexible(
            child: seasonData.value == null && !seasonData.hasError
                ? const Center(child: CircularProgressIndicator())
                : ReorderableListView.builder(
                    shrinkWrap: true,
                    scrollController: scrollController,
                    buildDefaultDragHandles: false,
                    onReorderItem: (oldIndex, newIndex) {
                      if (oldIndex != newIndex) {
                        run(() => move(oldIndex, newIndex - oldIndex));
                      }
                    },
                    padding: const EdgeInsets.all(RevericSpacing.x4l),
                    itemCount: seasons.length,
                    itemBuilder: (context, index) {
                      final season = seasons[index];
                      final selected = workspace.seasonId == season.id;
                      final summary = InkWell(
                        borderRadius: BorderRadius.circular(
                          RevericRadius.large,
                        ),
                        onTap: busy.value
                            ? null
                            : () => run(() => enter(season)),
                        child: Padding(
                          padding: const EdgeInsets.all(RevericSpacing.lg),
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  screenplaySeasonLabel(context, season),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: typo.uiMedium.copyWith(
                                    color: selected
                                        ? colors.accent
                                        : colors.textPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: RevericSpacing.lg),
                              ScreenplayEpisodeCount(
                                episodeCount: counts[season.id] ?? 0,
                                planned: season.plannedEpisodeCount,
                              ),
                            ],
                          ),
                        ),
                      );
                      final actions = Wrap(
                        children: [
                          _SeasonAction(
                            icon: RevericIcons.expand_less_rounded,
                            label: context.t(LocaleKeys.screenplayMoveUp),
                            onPressed: busy.value || index == 0
                                ? null
                                : () => run(() => move(index, -1)),
                          ),
                          _SeasonAction(
                            icon: RevericIcons.caret_down,
                            label: context.t(LocaleKeys.screenplayMoveDown),
                            onPressed: busy.value || index == seasons.length - 1
                                ? null
                                : () => run(() => move(index, 1)),
                          ),
                          Builder(
                            builder: (buttonContext) => _SeasonAction(
                              icon: RevericIcons.more_horiz,
                              label: context.t(LocaleKeys.commonMoreActions),
                              onPressed: busy.value
                                  ? null
                                  : () async {
                                      void editSeason() {
                                        error.value = false;
                                        editing.value = season;
                                      }

                                      if (isMobile) {
                                        final edit = await showMobileSheet<bool>(
                                          context: context,
                                          showDragHandle: true,
                                          builder: (sheetContext) => ListTile(
                                            leading: RevericIcon(
                                              RevericIcons.pencil_simple,
                                              color: colors.textSecondary,
                                              size: 20,
                                            ),
                                            title: Text(
                                              sheetContext.t(
                                                LocaleKeys.screenplayEditSeason,
                                              ),
                                            ),
                                            onTap: () => Navigator.of(
                                              sheetContext,
                                            ).pop(true),
                                          ),
                                        );
                                        if (edit == true && context.mounted) {
                                          editSeason();
                                        }
                                        return;
                                      }
                                      final box =
                                          buttonContext.findRenderObject()!
                                              as RenderBox;
                                      await showRevericContextMenu(
                                        context: context,
                                        position: box.localToGlobal(
                                          Offset(0, box.size.height),
                                        ),
                                        entries: [
                                          RevericMenuItem(
                                            icon: RevericIcons.pencil_simple,
                                            label: context.t(
                                              LocaleKeys.screenplayEditSeason,
                                            ),
                                            onTap: editSeason,
                                          ),
                                          RevericMenuItem(
                                            icon: RevericIcons.delete_outline,
                                            iconColor: colors.warningText,
                                            labelColor: colors.warningText,
                                            label: context.t(
                                              LocaleKeys.commonDelete,
                                            ),
                                            tooltip: seasons.length <= 1
                                                ? context.t(
                                                    LocaleKeys
                                                        .screenplayAtLeastOneSeason,
                                                  )
                                                : null,
                                            enabled: seasons.length > 1,
                                            onTap: () =>
                                                run(() => remove(index)),
                                          ),
                                        ],
                                      );
                                    },
                            ),
                          ),
                        ],
                      );
                      Widget buildCard(BorderRadius borderRadius) => Container(
                        decoration: BoxDecoration(
                          color: selected ? colors.selected : colors.surface,
                          borderRadius: borderRadius,
                          border: Border.all(
                            color: selected
                                ? colors.accent
                                : colors.borderSubtle,
                          ),
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            if (constraints.maxWidth >=
                                RevericSizes.screenplaySeasonManagerWidth -
                                    RevericSpacing.x6l * 2) {
                              return Row(
                                children: [
                                  Expanded(child: summary),
                                  actions,
                                  const SizedBox(width: RevericSpacing.sm),
                                ],
                              );
                            }
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                summary,
                                Padding(
                                  padding: const EdgeInsets.only(
                                    right: RevericSpacing.sm,
                                    bottom: RevericSpacing.sm,
                                  ),
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: actions,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      );
                      final radius = BorderRadius.circular(RevericRadius.large);
                      return ReorderableDelayedDragStartListener(
                        key: ValueKey(season.id),
                        index: index,
                        enabled: !busy.value,
                        child: Padding(
                          padding: const EdgeInsets.only(
                            bottom: RevericSpacing.lg,
                          ),
                          child: isMobile && seasons.length > 1
                              ? RevericSlidableDelete(
                                  borderRadius: radius,
                                  deleteLabel: context.t(
                                    LocaleKeys.commonDelete,
                                  ),
                                  onDelete: () => run(() => remove(index)),
                                  childBuilder: (context, borderRadius) =>
                                      buildCard(borderRadius),
                                )
                              : buildCard(radius),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.x4l,
              0,
              RevericSpacing.x4l,
              RevericSpacing.x4l,
            ),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: busy.value || seasonData.value == null
                    ? null
                    : () => run(add),
                icon: const RevericIcon(RevericIcons.add),
                label: Text(context.t(LocaleKeys.screenplayAddSeason)),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _SeasonAction extends StatelessWidget {
  const _SeasonAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final String icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return IconButton(
      tooltip: label,
      constraints: const BoxConstraints.tightFor(
        width: RevericSizes.buttonHeight + RevericSpacing.xxs,
        height: RevericSizes.buttonHeight + RevericSpacing.xxs,
      ),
      onPressed: onPressed,
      icon: RevericIcon(
        icon,
        size: RevericSpacing.x3l,
        color: onPressed == null ? colors.textSubtle : colors.textSecondary,
      ),
    );
  }
}

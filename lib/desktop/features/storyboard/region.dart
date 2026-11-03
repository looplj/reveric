// 职责: 按场次组织当前集片段，提供编辑、排序、跨场移动、复制、软删除及 AI 拆片段入口。
// 关联文件:
//   lib/desktop/features/storyboard/edit_form.dart
//   lib/desktop/features/storyboard/shot_row.dart
//   lib/shared/providers/storyboard.dart
//   lib/desktop/features/production/ai_mark.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/components/reveric_context_menu.dart';
import '../../../shared/components/reveric_placeholder.dart';
import '../../../shared/database/app_database.dart' show Novel;
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/models/novel_workspace.dart';
import '../../../shared/models/screenplay.dart';
import '../../../shared/providers/maps_providers.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/providers/screenplay_providers.dart';
import '../../../shared/providers/screenplay_workspace_state_provider.dart';
import '../../../shared/providers/storyboard.dart';
import '../../../shared/providers/workspace_navigation_provider.dart';
import '../../../shared/services/storyboard/edit_orchestrator.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/screenplay/labels.dart';
import '../../../shared/widgets/confirm_dialog.dart';
import 'edit_form.dart';
import 'shot_row.dart';
import 'inline_editor.dart';
import '../production/ai_mark.dart';
import '../production/edit_session.dart';
import '../production/task_status.dart';
import 'support.dart';

final _log = AppLogger.forModule('Storyboard');

class StoryboardRegion extends HookConsumerWidget {
  const StoryboardRegion({
    super.key,
    required this.novel,
    this.onProduce,
    this.editSession,
    this.focusedClipId,
    this.sceneActions,
    this.taskActions,
  });
  final ProductionEditSession? editSession;
  final String? focusedClipId;
  final ProductionSceneActions? sceneActions;
  final Novel novel;
  final ValueChanged<String>? onProduce;
  final ProductionTaskActions? taskActions;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = novel.contentDatabasePath!;
    final workspace = ref.watch(
      screenplayWorkspaceStateControllerProvider(novel.id, path),
    );
    final busy = useState(false);
    final episodeId = workspace.episodeId;
    final service = ref.watch(storyboardServiceProvider(path));
    final overlay = ref.watch(workingOverlayServiceProvider(path));
    final shotsState = episodeId == null
        ? null
        : ref.watch(storyboardShotsProvider(path, episodeId));
    final scenesState = episodeId == null
        ? null
        : ref.watch(screenplayScenesProvider(path, episodeId));
    final shots = shotsState?.value ?? <ProductionClipRow>[];
    final scenes = scenesState?.value ?? <ScreenplaySceneSummary>[];

    final sceneKeys = useMemoized(
      () => {for (final scene in scenes) scene.id: GlobalKey()},
      [scenes.map((s) => s.id).join('|')],
    );
    final clipKeys = useMemoized(() => <String, GlobalKey>{}, [episodeId]);
    void reveal(BuildContext? target, double alignment) {
      if (target != null && target.mounted) {
        Scrollable.ensureVisible(target, alignment: alignment);
      }
    }

    // 明确定位的片段优先；之后在第二栏点场次，再滚到那一场。
    // 片段和场次分两次到达，场次到齐前行还没建出来，所以依赖里带上 sceneKeys。
    final clipIds = shots.map((s) => s.id).join('|');
    useEffect(() {
      if (focusedClipId == null) {
        return null;
      }
      var active = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (active) {
          reveal(clipKeys[focusedClipId]?.currentContext, 0.2);
        }
      });
      return () => active = false;
    }, [focusedClipId, clipKeys, clipIds, sceneKeys]);
    final revealedScene = useRef<String?>(
      focusedClipId == null ? null : workspace.sceneId,
    );
    useEffect(() {
      final sceneId = workspace.sceneId;
      if (sceneId == null || revealedScene.value == sceneId) {
        return null;
      }
      // 场次是跟着定位的片段同步过来的：已经滚到片段了，不再跳回场次开头。
      if (shots.any((s) => s.id == focusedClipId && s.sceneId == sceneId)) {
        revealedScene.value = sceneId;
        return null;
      }
      var active = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = sceneKeys[sceneId]?.currentContext;
        if (active && target != null) {
          revealedScene.value = sceneId;
          reveal(target, 0);
        }
      });
      return () => active = false;
    }, [workspace.sceneId, sceneKeys, clipIds]);

    Future<void> run(Future<void> Function() action) async {
      if (busy.value) {
        return;
      }
      busy.value = true;
      try {
        await action();
      } catch (e, stack) {
        _log.error('UI operation failed', error: e, stackTrace: stack);
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(shotError(context, e))));
        }
      } finally {
        if (context.mounted) {
          busy.value = false;
        }
      }
    }

    Future<void> edit(String sceneId, [ProductionClipRow? shot]) async {
      final production = episodeId == null ? null : await service.getSettings();
      if (context.mounted) {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => ShotEditForm(
            path: path,
            sceneId: sceneId,
            shot: shot,
            production: production,
          ),
        );
      }
    }

    void source(String id) {
      ref
          .read(
            screenplayWorkspaceStateControllerProvider(novel.id, path).notifier,
          )
          .update(workspace.copyWith(sceneId: id));
      ref
          .read(workspaceNavigationProvider.notifier)
          .request(
            WorkspaceNavigationRequest(
              section: NovelWorkspaceSection.screenplay_script,
              itemId: id,
            ),
          );
    }

    Future<void> transfer(ProductionClipRow shot, bool copy) async {
      final root = await service.database.screenplayDao.getRoot();
      if (root == null) {
        return;
      }
      final all = copy
          ? await service.database.screenplayDao
                .watchScenesOfScreenplay(root.id)
                .first
          : {episodeId!: scenes};
      final episodes = <String, String>{};
      for (final season in await service.database.screenplayDao.getSeasons(
        root.id,
      )) {
        for (final episode in await service.database.screenplayDao.getEpisodes(
          season.id,
        )) {
          episodes[episode.id] =
              '${season.seasonNumber}.${episode.episodeNumber} ${episode.title}';
        }
      }
      if (!context.mounted) {
        return;
      }
      final destination = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(context.t(LocaleKeys.storyboardChooseScene)),
          children: [
            for (final entry in all.entries)
              for (final scene in entry.value)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, scene.id),
                  child: Text(
                    '${episodes[entry.key]} · ${scene.sceneNumber} ${scene.title}',
                  ),
                ),
          ],
        ),
      );
      if (destination == null) {
        return;
      }
      if (copy) {
        await StoryboardEditOrchestrator().copy(
          service: service,
          overlay: overlay,
          shot: shot,
          sceneId: destination,
        );
      } else {
        final siblings = await service.sceneShots(destination);
        await StoryboardEditOrchestrator().save(
          service: service,
          overlay: overlay,
          shotId: shot.id,
          values: {
            'scene_id': destination,
            'sort_order': siblings.isEmpty ? 0 : siblings.last.sortOrder! + 1,
          },
        );
      }
    }

    void menu(
      ProductionClipRow shot,
      List<ProductionClipRow> siblings,
      Offset position,
    ) {
      final index = siblings.indexWhere((s) => s.id == shot.id);
      void reorder(int next) => run(() async {
        final target = [...siblings];
        target.removeAt(index);
        target.insert(next, shot);
        await StoryboardEditOrchestrator().reorder(
          service: service,
          overlay: overlay,
          ordered: target,
        );
      });
      showRevericContextMenu(
        context: context,
        position: position,
        entries: [
          RevericMenuItem(
            label: context.t(LocaleKeys.commonEdit),
            onTap: () => edit(shot.sceneId!, shot),
          ),
          RevericMenuItem(
            label: context.t(LocaleKeys.commonCopy),
            onTap: () => run(() async {
              await StoryboardEditOrchestrator().copy(
                service: service,
                overlay: overlay,
                shot: shot,
                sceneId: shot.sceneId!,
              );
            }),
          ),
          RevericMenuItem(
            label: context.t(LocaleKeys.storyboardCopyTo),
            onTap: () => run(() => transfer(shot, true)),
          ),
          RevericMenuItem(
            label: context.t(LocaleKeys.storyboardMoveTo),
            onTap: () => run(() => transfer(shot, false)),
          ),
          RevericMenuItem(
            label: context.t(LocaleKeys.storyboardUp),
            enabled: index > 0,
            onTap: () => reorder(index - 1),
          ),
          RevericMenuItem(
            label: context.t(LocaleKeys.storyboardDown),
            enabled: index < siblings.length - 1,
            onTap: () => reorder(index + 1),
          ),
          const RevericMenuDivider(),
          RevericMenuItem(
            label: context.t(LocaleKeys.commonDelete),
            icon: RevericIcons.delete_outline,
            iconColor: RevericTheme.colorsOf(context).deletionBorder,
            labelColor: RevericTheme.colorsOf(context).deletionBorder,
            enabled: !busy.value,
            onTap: () => run(() async {
              if (!(await editSession?.close() ?? true) || !context.mounted) {
                return;
              }
              final confirmed = await showConfirmDialog(
                context,
                title: context.t(LocaleKeys.commonDelete),
                message: context.t(
                  LocaleKeys.storyboardDeleteConfirm,
                  namedArgs: {'title': shot.title},
                ),
                confirmLabel: context.t(LocaleKeys.commonDelete),
                variant: ConfirmDialogVariant.error,
              );
              if (confirmed && context.mounted) {
                await service.softDelete(shot.id);
              }
            }),
          ),
        ],
      );
    }

    if (episodeId == null) {
      return Center(
        child: RevericPlaceholder.empty(
          icon: RevericIcons.movie_outlined,
          title: context.t(LocaleKeys.storyboardNoEpisode),
        ),
      );
    }
    if (shotsState!.hasError || scenesState!.hasError) {
      return Center(
        child: RevericPlaceholder.error(
          title: context.t(LocaleKeys.storyboardError),
        ),
      );
    }
    if (!shotsState.hasValue || !scenesState.hasValue) {
      return const Center(child: CircularProgressIndicator());
    }
    final groups = <String, List<ProductionClipRow>>{
      for (final scene in scenes) scene.id: [],
    };
    for (final shot in shots) {
      groups.putIfAbsent(shot.sceneId!, () => []).add(shot);
    }
    final sceneMap = {for (final scene in scenes) scene.id: scene};
    final database = ref.watch(appDatabaseProvider);
    final locationNames = {
      for (final location
          in ref.watch(locationsProvider(path)).value ?? const <Location>[])
        location.id: location.name,
    };
    if (groups.isEmpty) {
      return Center(
        child: RevericPlaceholder.empty(
          icon: RevericIcons.movie_outlined,
          title: context.t(LocaleKeys.storyboardNoScenes),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(RevericSpacing.x4l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final group in groups.entries)
            Padding(
              key: sceneKeys[group.key],
              padding: const EdgeInsets.only(bottom: RevericSpacing.x4l),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SceneHeader(
                    scene: sceneMap[group.key],
                    locationNames: locationNames,
                    clips: group.value,
                    onSplit: sceneActions?.ask == null
                        ? null
                        : () => sceneActions!.ask!(
                            '请读取场次 /scenes/${group.key} 及其角色、地点，将这一场拆成界面中的分镜（可生成的视频片段），加载「剧本制片」的视频提示词附件，按其中的 Shot 格式逐镜头编写提示词；写入前加载「剧本工具使用规范」的分镜与媒体节点附件。每个分镜关联本场，时长按所选模型能力设置，保留原剧本文本。',
                          ),
                    onSource: () => source(group.key),
                  ),
                  for (var i = 0; i < group.value.length; i++)
                    DragTarget<String>(
                      key: ValueKey(group.value[i].id),
                      onWillAcceptWithDetails: (d) =>
                          d.data != group.value[i].id &&
                          group.value.any((s) => s.id == d.data),
                      onAcceptWithDetails: (d) => run(() async {
                        if (!(await editSession?.close() ?? true)) {
                          return;
                        }
                        final ordered = [...group.value];
                        final moved = ordered.removeAt(
                          ordered.indexWhere((s) => s.id == d.data),
                        );
                        ordered.insert(i, moved);
                        await StoryboardEditOrchestrator().reorder(
                          service: service,
                          overlay: overlay,
                          ordered: ordered,
                        );
                      }),
                      builder: (_, candidates, _) => KeyedSubtree(
                        key: clipKeys.putIfAbsent(
                          group.value[i].id,
                          GlobalKey.new,
                        ),
                        child: ShotRow(
                          actions: (
                            onProduce: onProduce == null
                                ? null
                                : () => onProduce!(group.value[i].id),
                            onMenu: (position) =>
                                menu(group.value[i], group.value, position),
                          ),
                          focused: focusedClipId == group.value[i].id,
                          shot: group.value[i],
                          number:
                              '${sceneMap[group.key]?.sceneNumber ?? '?'}.${i + 1}',
                          marks: [
                            ProductionAiMark(
                              path: path,
                              clipId: group.value[i].id,
                            ),
                            ProductionTaskStatus(
                              shots: service,
                              database: database,
                              novelId: novel.id,
                              clipId: group.value[i].id,
                              actions: taskActions,
                            ),
                          ],
                          prompt: editSession == null
                              ? null
                              : InlineShotEditor(
                                  key: ValueKey(group.value[i].id),
                                  path: path,
                                  shot: group.value[i],
                                  session: editSession!,
                                  onProduce: () =>
                                      onProduce?.call(group.value[i].id),
                                ),
                        ),
                      ),
                    ),
                  if (sceneMap.containsKey(group.key))
                    Align(
                      alignment: Alignment.centerLeft,
                      child: RevericButton.text(
                        label: context.t(LocaleKeys.commonCreate),
                        icon: RevericIcons.add,
                        onPressed: busy.value ? null : () => edit(group.key),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 一场的组头：场号标题、完成数与计划时长，以及 AI 拆片段、查看原文。
class _SceneHeader extends StatelessWidget {
  const _SceneHeader({
    required this.scene,
    required this.locationNames,
    required this.clips,
    required this.onSplit,
    required this.onSource,
  });
  final ScreenplaySceneSummary? scene;
  final Map<String, String> locationNames;
  final List<ProductionClipRow> clips;
  final VoidCallback? onSplit;
  final VoidCallback onSource;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final scene = this.scene;
    final planned = clips.fold<int>(0, (sum, c) => sum + (c.durationMs ?? 0));
    final missing = clips.where((c) => c.durationMs == null).length;
    // 和第二栏场次行同一种写法：有标题时地点挪到条件里，没标题时地点当标题。
    final place = scene == null
        ? ''
        : screenplaySceneLocation(context, scene, locationNames: locationNames);
    final (time, interiorExterior) = scene == null
        ? ('', '')
        : screenplaySceneCondition(context, scene);
    final condition = [
      if (scene != null && scene.title.isNotEmpty && scene.locationId != null)
        place,
      [time, interiorExterior].where((s) => s.isNotEmpty).join(' / '),
    ].where((s) => s.isNotEmpty).join(' · ');
    final title = scene == null
        ? context.t(LocaleKeys.storyboardSourceMissing)
        : '${scene.sceneNumber}、${scene.title.isEmpty ? place : scene.title}';
    return Padding(
      padding: const EdgeInsets.only(bottom: RevericSpacing.xs),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              constraints.maxWidth <
              RevericSizes.storyboardHeaderCompactWidth *
                  MediaQuery.textScalerOf(context).scale(1);
          Widget action(String label, String icon, VoidCallback? onPressed) =>
              compact
              ? RevericIconButton(
                  icon: icon,
                  tooltip: label,
                  onPressed: onPressed,
                )
              : RevericButton.text(
                  label: label,
                  icon: icon,
                  size: RevericButtonSize.compact,
                  onPressed: onPressed,
                );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Tooltip(
                      message: title,
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.uiSemibold,
                      ),
                    ),
                  ),
                  if (scene != null && onSplit != null)
                    action(
                      context.t(LocaleKeys.productionSplit),
                      RevericIcons.auto_awesome,
                      onSplit,
                    ),
                  if (scene != null)
                    action(
                      context.t(LocaleKeys.storyboardSource),
                      RevericIcons.file_text,
                      onSource,
                    ),
                ],
              ),
              // 条件和统计按完整条目换行，不再和标题争用一行剩余宽度。
              Wrap(
                spacing: RevericSpacing.lg,
                runSpacing: RevericSpacing.xxs,
                children: [
                  if (condition.isNotEmpty)
                    Text(
                      condition,
                      style: typo.uiSmall.copyWith(color: colors.textMuted),
                    ),
                  Text(
                    clips.isEmpty
                        ? context.t(LocaleKeys.productionSceneEmpty)
                        : context.t(
                            LocaleKeys.productionSceneStat,
                            namedArgs: {
                              'done':
                                  '${clips.where((c) => c.adoptedAssetId != null).length}',
                              'count': '${clips.length}',
                              'seconds': '${(planned / 1000).round()}',
                            },
                          ),
                    style: typo.uiSmall.copyWith(color: colors.textMuted),
                  ),
                  if (missing > 0)
                    Text(
                      context.t(
                        LocaleKeys.productionSceneMissingDuration,
                        namedArgs: {'count': '$missing'},
                      ),
                      style: typo.uiSmall.copyWith(color: colors.warningText),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

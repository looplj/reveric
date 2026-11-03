// 职责: 移动端场次页 — 用信息卡而非宽表完成建场、排场、场景标题编辑和确认删除。
// 关联文件:
//   lib/shared/widgets/screenplay/scene_properties.dart
//   lib/mobile/features/screenplay/script_page.dart
//   lib/shared/providers/screenplay_providers.dart
//   lib/shared/services/screenplay_service.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/zh-CN/common.json
//   assets/translations/en/common.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/database/app_database.dart';
import '../../../shared/database/novel_content_database.dart' show Location;
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/screenplay.dart';
import '../../../shared/providers/maps_providers.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/providers/screenplay_providers.dart';
import '../../../shared/providers/screenplay_workspace_state_provider.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/confirm_dialog.dart';
import '../../../shared/models/screenplay_workspace_state.dart';
import '../../../shared/widgets/screenplay/chips.dart';
import '../../../shared/widgets/screenplay/labels.dart';
import 'support.dart';
import '../../../shared/widgets/screenplay/scene_properties.dart';
import '../../../shared/widgets/screenplay/emotion_badges.dart';

class MobileScreenplayScenesPage extends ConsumerWidget {
  const MobileScreenplayScenesPage({super.key, required this.novel});

  final Novel novel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = novel.contentDatabasePath!;
    final provider = screenplayWorkspaceStateControllerProvider(novel.id, path);
    final workspace = ref.watch(provider);
    final episodeId = workspace.episodeId;
    final scenes = episodeId == null
        ? const <ScreenplaySceneSummary>[]
        : ref.watch(screenplayScenesProvider(path, episodeId)).value ??
              const <ScreenplaySceneSummary>[];
    final service = ref.read(
      screenplayServiceProvider(path, novelId: novel.id),
    );

    Future<void> add() async {
      if (episodeId == null) return;
      final episode = await ref
          .read(novelContentDatabaseProvider(path))
          .screenplayDao
          .getEpisode(episodeId);
      if (episode == null) return;
      final id = await service.createScene(
        screenplayId: episode.screenplayId,
        episodeId: episodeId,
      );
      ref.read(provider.notifier).update(workspace.copyWith(sceneId: id));
    }

    void open(ScreenplaySceneSummary scene) {
      ref
          .read(provider.notifier)
          .update(
            workspace.copyWith(
              sceneId: scene.id,
              section: ScreenplayWorkspaceSection.script,
            ),
          );
    }

    final locations =
        ref.watch(locationsProvider(path)).value ?? const <Location>[];
    final names = {
      for (final location in locations) location.id: location.name,
    };

    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    final appearances = episodeId == null
        ? const <ScreenplayAppearanceMatrixRow>[]
        : ref
                  .watch(screenplayAppearanceMatrixProvider(path, episodeId))
                  .value ??
              const <ScreenplayAppearanceMatrixRow>[];
    Future<void> actions(ScreenplaySceneSummary scene, int index) async {
      final action = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(bottom: RevericSpacing.x5l),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(context.t(LocaleKeys.screenplayEditScript)),
                  onTap: () => Navigator.pop(context, 'script'),
                ),
                ListTile(
                  enabled: index > 0,
                  title: Text(context.t(LocaleKeys.screenplayMoveUp)),
                  onTap: () => Navigator.pop(context, 'up'),
                ),
                ListTile(
                  enabled: index + 1 < scenes.length,
                  title: Text(context.t(LocaleKeys.screenplayMoveDown)),
                  onTap: () => Navigator.pop(context, 'down'),
                ),
              ],
            ),
          ),
        ),
      );
      if (!context.mounted) {
        return;
      }
      if (action == 'script') {
        open(scene);
      }
      if (action == 'up' && index > 0) {
        await service.moveSceneBefore(scene.id, scenes[index - 1].id);
      }
      if (action == 'down' && index + 1 < scenes.length) {
        await service.moveSceneAfter(scene.id, scenes[index + 1].id);
      }
    }

    return ListView(
      key: PageStorageKey('scenes-$episodeId'),
      padding: const EdgeInsets.all(RevericSpacing.x2l),
      children: [
        if (scenes.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: RevericSpacing.x4l),
            child: MobileScreenplayEmpty(
              icon: RevericIcons.category_outlined,
              label: context.t(LocaleKeys.screenplayNoScenes),
            ),
          ),
        for (var index = 0; index < scenes.length; index++)
          Padding(
            padding: const EdgeInsets.only(bottom: RevericSpacing.md),
            child: Dismissible(
              key: ValueKey(scenes[index].id),
              direction: DismissDirection.endToStart,
              confirmDismiss: (_) => showConfirmDialog(
                context,
                title: context.t(LocaleKeys.commonDelete),
                message: context.t(LocaleKeys.screenplayConfirmDelete),
                variant: ConfirmDialogVariant.warning,
              ),
              onDismissed: (_) async {
                await service.deleteScene(scenes[index].id);
                await ref.read(provider.notifier).reconcile();
              },
              background: Container(color: colors.deletionBg),
              child: MobileScreenplayCard(
                onTap: () => showMobileScreenplaySceneSheet(
                  context,
                  novel: novel,
                  scene: scenes[index],
                ),
                onLongPress: () => actions(scenes[index], index),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${scenes[index].sceneNumber}、${screenplaySceneTitle(context, scenes[index], locationNames: names)}',
                            style: typo.body.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Flexible(
                          child: SceneEmotionBadges(
                            emotion: scenes[index].emotion,
                          ),
                        ),
                        const RevericIcon(RevericIcons.chevron_right, size: 18),
                      ],
                    ),
                    Text(
                      screenplaySceneHeading(
                        context,
                        scenes[index],
                        locationNames: names,
                      ),
                      style: typo.uiTiny.copyWith(color: colors.textMuted),
                    ),
                    if (scenes[index].synopsis.isNotEmpty) ...[
                      const SizedBox(height: RevericSpacing.sm),
                      Text(
                        scenes[index].synopsis,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: typo.bodySmall.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                    const SizedBox(height: RevericSpacing.sm),
                    Wrap(
                      spacing: RevericSpacing.xs,
                      runSpacing: RevericSpacing.xs,
                      children: [
                        ScreenplayStageBadge(stage: scenes[index].stage),
                        ScreenplayPagesText(
                          pageEighths: scenes[index].pageEighths,
                        ),
                        ScreenplayChip(
                          label: context.t(
                            LocaleKeys.screenplayPeopleUnit,
                            namedArgs: {
                              'count':
                                  '${appearances.where((a) => a.sceneId == scenes[index].id).firstOrNull?.characterIds.length ?? 0}',
                            },
                          ),
                          icon: RevericIcons.person,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        OutlinedButton.icon(
          onPressed: episodeId == null ? null : add,
          icon: const RevericIcon(RevericIcons.add, size: 18),
          label: Text(
            context.t(LocaleKeys.screenplayAddScene),
            style: typo.uiSemibold,
          ),
        ),
      ],
    );
  }
}

Future<void> showMobileScreenplaySceneSheet(
  BuildContext context, {
  required Novel novel,
  required ScreenplaySceneSummary scene,
}) => showSceneProperties(
  context,
  databasePath: novel.contentDatabasePath!,
  episodeId: scene.episodeId,
  sceneId: scene.id,
  mobile: true,
);

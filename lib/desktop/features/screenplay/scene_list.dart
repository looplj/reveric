// 职责: 桌面剧本场次的列表视图 — 以大纲式行展示当前集场序、梗概与属性入口。
// 关联文件:
//   lib/desktop/features/screenplay/scenes.dart
//   lib/desktop/features/screenplay/scene_dialog.dart
//   lib/shared/providers/screenplay_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_context_menu.dart';
import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/database/app_database.dart';
import '../../../shared/database/novel_content_database.dart' show Location;
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/screenplay.dart';
import '../../../shared/models/novel_workspace.dart';
import '../../../shared/providers/screenplay_workspace_state_provider.dart';
import '../../../shared/providers/workspace_navigation_provider.dart';
import '../../../shared/providers/maps_providers.dart';
import '../../../shared/providers/screenplay_providers.dart';
import '../../../shared/theme/theme.dart';
import 'chips.dart';
import 'scene_dialog.dart';
import '../../../shared/widgets/screenplay/emotion_badges.dart';
import 'support.dart';

/// 场次页的默认列表视图 —— 即大纲页的场次行模式，按当前集逐场排出
/// 场序、梗概与 meta chips。重排只在本集内移动。
class ScreenplaySceneList extends ConsumerWidget {
  const ScreenplaySceneList({
    super.key,
    required this.novel,
    required this.episodeId,
    required this.onOpenScript,
  });

  final Novel novel;
  final String episodeId;
  final ValueChanged<String> onOpenScript;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = novel.contentDatabasePath!;
    final entries =
        ref.watch(screenplayOutlineProvider(path, episodeId)).value ??
        const <ScreenplayOutlineEntry>[];
    final locationNames = {
      for (final location
          in ref.watch(locationsProvider(path)).value ?? const <Location>[])
        location.id: location.name,
    };
    final service = ref.read(
      screenplayServiceProvider(path, novelId: novel.id),
    );
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
            maxWidth: RevericSizes.screenplayOutlineMaxWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < entries.length; index += 1)
                ScreenplaySceneListRow(
                  novel: novel,
                  entry: entries[index],
                  locationNames: locationNames,
                  onOpenScript: () => onOpenScript(entries[index].scene.id),
                  onMoveUp: index == 0
                      ? null
                      : () => unawaited(
                          service.moveSceneBefore(
                            entries[index].scene.id,
                            entries[index - 1].scene.id,
                          ),
                        ),
                  onMoveDown: index + 1 == entries.length
                      ? null
                      : () => unawaited(
                          service.moveSceneAfter(
                            entries[index].scene.id,
                            entries[index + 1].scene.id,
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

/// `.sp-orow` —— 左列固定宽的场次头，右列梗概与 meta。
/// 整行可点：点开场次属性弹窗（含梗概），重排收在悬停出现的菜单里。
class ScreenplaySceneListRow extends StatefulWidget {
  const ScreenplaySceneListRow({
    super.key,
    required this.novel,
    required this.entry,
    required this.locationNames,
    required this.onOpenScript,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final Novel novel;
  final ScreenplayOutlineEntry entry;
  final Map<String, String> locationNames;
  final VoidCallback onOpenScript;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  @override
  State<ScreenplaySceneListRow> createState() => _ScreenplaySceneListRowState();
}

class _ScreenplaySceneListRowState extends State<ScreenplaySceneListRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final scene = widget.entry.scene;
    final place = screenplaySceneLocation(
      context,
      scene,
      locationNames: widget.locationNames,
    );
    final (time, interiorExterior) = screenplaySceneCondition(context, scene);
    final condition = [
      time,
      interiorExterior,
    ].where((part) => part.isNotEmpty).join(' / ');
    final synopsis = scene.synopsis.trim();
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () => unawaited(
          showScreenplaySceneDialog(
            context,
            databasePath: widget.novel.contentDatabasePath!,
            novelId: widget.novel.id,
            scene: scene,
          ),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.md,
            vertical: RevericSpacing.lg,
          ),
          decoration: BoxDecoration(
            color: _hovered ? colors.hover : Colors.transparent,
            borderRadius: BorderRadius.circular(RevericRadius.large),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 190,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${scene.sceneNumber}、${scene.title.isEmpty ? place : scene.title}',
                      style: typo.bodySmall.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    Text(
                      [
                        if (scene.title.isNotEmpty) place,
                        condition,
                      ].where((p) => p.isNotEmpty).join(' · '),
                      style: typo.uiTiny.copyWith(color: colors.textMuted),
                    ),
                    const SizedBox(height: RevericSpacing.xs),
                    SceneEmotionBadges(emotion: scene.emotion),
                  ],
                ),
              ),
              const SizedBox(width: RevericSpacing.x2l),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      synopsis.isEmpty
                          ? context.t(LocaleKeys.screenplaySynopsis)
                          : synopsis,
                      style: typo.bodySmall.copyWith(
                        height: 1.75,
                        color: synopsis.isEmpty
                            ? colors.textSubtle
                            : colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: RevericSpacing.sm),
                    Wrap(
                      spacing: RevericSpacing.sm,
                      runSpacing: RevericSpacing.xxs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ScreenplayStageBadge(stage: scene.stage),
                        ScreenplayChip(
                          icon: RevericIcons.clock,
                          label:
                              '${screenplayPageEighthsText(scene.pageEighths)} '
                              '${context.t(LocaleKeys.screenplayPagesUnit)}',
                        ),
                        if (widget.entry.characterIds.isNotEmpty)
                          ScreenplayChip(
                            icon: RevericIcons.person,
                            label: context.t(
                              LocaleKeys.screenplayPeopleUnit,
                              namedArgs: {
                                'count': '${widget.entry.characterIds.length}',
                              },
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 32,
                child: _hovered
                    ? _SceneListRowMenu(
                        onOpenStoryboard: () {
                          final ref = ProviderScope.containerOf(
                            context,
                            listen: false,
                          );
                          final provider =
                              screenplayWorkspaceStateControllerProvider(
                                widget.novel.id,
                                widget.novel.contentDatabasePath!,
                              );
                          ref
                              .read(provider.notifier)
                              .update(
                                ref
                                    .read(provider)
                                    .copyWith(sceneId: widget.entry.scene.id),
                              );
                          ref
                              .read(workspaceNavigationProvider.notifier)
                              .request(
                                WorkspaceNavigationRequest(
                                  section: NovelWorkspaceSection.storyboard,
                                ),
                              );
                        },
                        onOpenScript: widget.onOpenScript,
                        onMoveUp: widget.onMoveUp,
                        onMoveDown: widget.onMoveDown,
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SceneListRowMenu extends StatelessWidget {
  const _SceneListRowMenu({
    required this.onOpenStoryboard,
    required this.onOpenScript,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final VoidCallback onOpenStoryboard;
  final VoidCallback onOpenScript;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  @override
  Widget build(BuildContext context) {
    return RevericIconButton(
      icon: RevericIcons.more_horiz,
      tooltip: context.t(LocaleKeys.commonMoreActions),
      onPressed: () {
        final box = context.findRenderObject()! as RenderBox;
        showRevericContextMenu(
          context: context,
          position: box.localToGlobal(Offset(0, box.size.height)),
          entries: [
            RevericMenuItem(
              label: context.t(LocaleKeys.storyboardBoard),
              onTap: onOpenStoryboard,
            ),
            RevericMenuItem(
              label: context.t(LocaleKeys.screenplayEditScript),
              onTap: onOpenScript,
            ),
            RevericMenuItem(
              label: context.t(LocaleKeys.screenplayMoveUp),
              enabled: onMoveUp != null,
              onTap: onMoveUp,
            ),
            RevericMenuItem(
              label: context.t(LocaleKeys.screenplayMoveDown),
              enabled: onMoveDown != null,
              onTap: onMoveDown,
            ),
          ],
        );
      },
    );
  }
}

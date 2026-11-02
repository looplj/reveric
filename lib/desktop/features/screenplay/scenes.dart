// 职责: 桌面场次区域 — 以大纲式列表、点阵场次板与角色出场三种视图浏览、编辑当前集场次。
// 关联文件:
//   lib/desktop/widgets/workspace/novel_workspace_panel.dart
//   lib/desktop/features/screenplay/board.dart
//   lib/desktop/features/screenplay/characters.dart
//   lib/desktop/features/screenplay/scene_dialog.dart
//   lib/desktop/features/screenplay/scene_list.dart
//   lib/shared/providers/screenplay_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_segmented_control.dart';
import '../../../shared/database/app_database.dart';
import '../../../shared/database/novel_content_database.dart' show Location;
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/character_profile.dart';
import '../../../shared/models/novel_workspace.dart';
import '../../../shared/models/screenplay.dart';
import '../../../shared/models/screenplay_element.dart';
import '../../../shared/providers/maps_providers.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/providers/screenplay_providers.dart';
import '../../../shared/providers/screenplay_workspace_state_provider.dart';
import '../../../shared/providers/workspace_navigation_provider.dart';
import '../../../shared/theme/theme.dart';
import 'board.dart';
import 'characters.dart';
import 'chips.dart';
import 'chrome.dart';
import 'scene_dialog.dart';
import '../../../shared/widgets/screenplay/emotion_badges.dart';
import 'scene_list.dart';
import 'screenplay_text_styles.dart';
import 'support.dart';

enum _SceneView { list, cards, appearance }

class ScreenplayScenesRegion extends HookConsumerWidget {
  const ScreenplayScenesRegion({super.key, required this.novel});

  final Novel novel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = novel.contentDatabasePath!;
    final view = useState(_SceneView.list);
    final workspaceProvider = screenplayWorkspaceStateControllerProvider(
      novel.id,
      path,
    );
    final workspace = ref.watch(workspaceProvider);
    final episodeId = workspace.episodeId;
    final scenes = episodeId == null
        ? const <ScreenplaySceneSummary>[]
        : ref.watch(screenplayScenesProvider(path, episodeId)).value ??
              const <ScreenplaySceneSummary>[];

    Future<void> addScene() async {
      final screenplayId = ref.read(screenplayRootProvider(path)).value?.id;
      if (screenplayId == null || episodeId == null) return;
      final sceneId = await ref
          .read(screenplayServiceProvider(path, novelId: novel.id))
          .createScene(screenplayId: screenplayId, episodeId: episodeId);
      ref
          .read(workspaceProvider.notifier)
          .update(workspace.copyWith(sceneId: sceneId));
    }

    // 选中场次写进剧本工作区状态，再请宿主页把 Main 切到剧本。
    void openScript(String sceneId) {
      ref
          .read(workspaceProvider.notifier)
          .update(workspace.copyWith(sceneId: sceneId));
      ref
          .read(workspaceNavigationProvider.notifier)
          .request(
            WorkspaceNavigationRequest(
              section: NovelWorkspaceSection.screenplay_script,
              itemId: sceneId,
            ),
          );
    }

    return Column(
      // 默认 center 给的是松宽度约束，场次板（flow 画布）和场次表（横向 scroll
      // view）都会因此收缩到内容宽度，只占中间一条、两侧露出底色。
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 分区名由工作区面包屑给出；这一条只留统计和视图切换。
        ScreenplayRegionToolbar(
          status: context.t(
            LocaleKeys.screenplaySceneCount,
            namedArgs: {'count': '${scenes.length}'},
          ),
          trailing: [
            SizedBox(
              width: 300,
              child: RevericSegmentedControl<_SceneView>(
                selected: view.value,
                height: 30,
                segments: [
                  RevericSegment(
                    value: _SceneView.list,
                    label: context.t(LocaleKeys.screenplaySceneList),
                    icon: RevericIcons.list_alt_outlined,
                  ),
                  RevericSegment(
                    value: _SceneView.cards,
                    label: context.t(LocaleKeys.screenplaySceneCards),
                    icon: RevericIcons.category_outlined,
                  ),
                  RevericSegment(
                    value: _SceneView.appearance,
                    label: context.t(LocaleKeys.screenplaySceneAppearance),
                    icon: RevericIcons.space_dashboard_outlined,
                  ),
                ],
                onChanged: (next) => view.value = next,
              ),
            ),
          ],
        ),
        Expanded(
          child: scenes.isEmpty || episodeId == null
              ? ScreenplayEmptyState(
                  title: context.t(LocaleKeys.screenplayNoScenes),
                  message: context.t(LocaleKeys.screenplayNoScenesSub),
                  actionLabel: episodeId == null
                      ? null
                      : context.t(LocaleKeys.screenplayAddScene),
                  onAction: () => unawaited(addScene()),
                )
              : switch (view.value) {
                  _SceneView.list => ScreenplaySceneList(
                    novel: novel,
                    episodeId: episodeId,
                    onOpenScript: openScript,
                  ),
                  _SceneView.cards => _SceneBoard(
                    novel: novel,
                    episodeId: episodeId,
                    activeSceneId: workspace.sceneId,
                    onOpenScript: openScript,
                  ),
                  _SceneView.appearance => ScreenplayAppearanceView(
                    novel: novel,
                  ),
                },
        ),
      ],
    );
  }
}

class _SceneBoard extends ConsumerWidget {
  const _SceneBoard({
    required this.novel,
    required this.episodeId,
    required this.activeSceneId,
    required this.onOpenScript,
  });

  final Novel novel;
  final String episodeId;
  final String? activeSceneId;
  final ValueChanged<String> onOpenScript;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = novel.contentDatabasePath!;
    final previews =
        ref
            .watch(screenplayEpisodeScriptPreviewProvider(path, episodeId))
            .value ??
        const <EpisodeScriptScenePreview>[];
    final matrix =
        ref.watch(screenplayAppearanceMatrixProvider(path, episodeId)).value ??
        const <ScreenplayAppearanceMatrixRow>[];
    final castCounts = {
      for (final row in matrix) row.sceneId: row.characterIds.length,
    };
    final locations =
        ref.watch(locationsProvider(path)).value ?? const <Location>[];
    final characterNames = {
      for (final profile
          in ref.watch(characterProfilesProvider(path)).value ??
              const <CharacterProfile>[])
        profile.id: profile.name,
    };
    final locationNames = {
      for (final location in locations) location.id: location.name,
    };
    return ScreenplayBoard(
      focusCardId: activeSceneId,
      cards: [
        for (final preview in previews)
          ScreenplayBoardCard(
            id: preview.scene.id,
            child: _SceneCard(
              novel: novel,
              preview: preview,
              castCount: castCounts[preview.scene.id] ?? 0,
              characterNames: characterNames,
              locationNames: locationNames,
              active: preview.scene.id == activeSceneId,
              onOpenScript: () => onOpenScript(preview.scene.id),
            ),
          ),
      ],
    );
  }
}

class _SceneCard extends StatelessWidget {
  const _SceneCard({
    required this.novel,
    required this.preview,
    required this.castCount,
    required this.characterNames,
    required this.locationNames,
    required this.active,
    required this.onOpenScript,
  });

  final Novel novel;
  final EpisodeScriptScenePreview preview;
  final int castCount;
  final Map<String, String> characterNames;
  final Map<String, String> locationNames;
  final bool active;
  final VoidCallback onOpenScript;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final scene = preview.scene;
    final place = screenplaySceneLocation(
      context,
      scene,
      locationNames: locationNames,
    );
    final (time, interiorExterior) = screenplaySceneCondition(context, scene);
    final synopsis = scene.synopsis.trim();
    // 尺寸由 flow 节点给定（见 RevericSizes.screenplaySceneCard*），卡片自身
    // 不再声明宽高，只负责把固定高度分配给各段。
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.x2l),
        border: Border.all(color: active ? colors.accent : colors.borderInput),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ScenePeek(
            scene: scene,
            elements: preview.elements,
            characterNames: characterNames,
            locationNames: locationNames,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                RevericSpacing.x2l,
                RevericSpacing.x2l,
                RevericSpacing.x2l,
                RevericSpacing.lg,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: () => showScreenplaySceneDialog(
                      context,
                      databasePath: novel.contentDatabasePath!,
                      novelId: novel.id,
                      scene: scene,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          scene.title.isEmpty ? place : scene.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: typo.heading2,
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
                          style: typo.uiSmall.copyWith(color: colors.textMuted),
                        ),
                        SceneEmotionBadges(emotion: scene.emotion),
                      ],
                    ),
                  ),
                  const SizedBox(height: RevericSpacing.md),
                  Wrap(
                    spacing: RevericSpacing.xs,
                    runSpacing: RevericSpacing.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ScreenplayChip(
                        icon: RevericIcons.person,
                        label: context.t(
                          LocaleKeys.screenplayPeopleUnit,
                          namedArgs: {'count': '$castCount'},
                        ),
                      ),
                      ScreenplayChip(
                        icon: RevericIcons.chat_outlined,
                        label: context.t(
                          LocaleKeys.screenplayLinesUnit,
                          namedArgs: {'count': '${scene.dialogueLineCount}'},
                        ),
                      ),
                      ScreenplayChip(
                        icon: RevericIcons.summarize_rounded,
                        label:
                            '${screenplayPageEighthsText(scene.pageEighths)} '
                            '${context.t(LocaleKeys.screenplayPagesUnit)}',
                      ),
                      ScreenplayStageBadge(stage: scene.stage),
                    ],
                  ),
                  const SizedBox(height: RevericSpacing.lg),
                  // 卡高固定，梗概吃掉剩余空间：超过三行截断，剩余空间不足三行
                  // 时由 ClipRect 兜住，不把按钮挤出卡片。
                  Expanded(
                    child: ClipRect(
                      child: Text(
                        synopsis.isEmpty
                            ? context.t(LocaleKeys.screenplaySynopsis)
                            : synopsis,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: typo.bodySmall.copyWith(
                          height: 1.7,
                          color: synopsis.isEmpty
                              ? colors.textSubtle
                              : colors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.x2l,
              0,
              RevericSpacing.x2l,
              RevericSpacing.x2l,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutlinedButton.icon(
                  onPressed: onOpenScript,
                  icon: const RevericIcon(RevericIcons.pencil_simple, size: 13),
                  label: Text(context.t(LocaleKeys.screenplayEditScript)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// `.sp-scard__peek` —— 直接用真正文渲染的缩略，没有正文就说没有。
class _ScenePeek extends StatelessWidget {
  const _ScenePeek({
    required this.scene,
    required this.elements,
    required this.characterNames,
    required this.locationNames,
  });

  final ScreenplaySceneSummary scene;
  final List<ScreenplayElement> elements;
  final Map<String, String> characterNames;
  final Map<String, String> locationNames;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final styles = ScreenplayPeekTextStyles.of(context);
    final heading =
        '${scene.sceneNumber}、'
        '${screenplaySceneHeading(context, scene, locationNames: locationNames)}';
    final lines = <Widget>[
      Text(
        heading,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: styles.heading,
      ),
    ];
    if (elements.isEmpty) {
      lines.add(const SizedBox(height: RevericSpacing.sm));
      lines.add(
        Text(
          context.t(LocaleKeys.screenplayNoScriptYet),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: styles.line,
        ),
      );
    } else {
      for (final raw in elements.take(18)) {
        final element = raw.normalized();
        final (text, style, indent) = switch (element.type) {
          ScreenplayElementType.character => (
            '${characterNames[element.characterId] ?? context.t(LocaleKeys.screenplayDeletedCharacter)}：',
            styles.character,
            0.0,
          ),
          ScreenplayElementType.dialogue => (element.text, styles.line, 14.0),
          ScreenplayElementType.parenthetical => (
            '（${element.text}）',
            styles.parenthetical,
            14.0,
          ),
          ScreenplayElementType.scene_heading => throw StateError(
            'Body preview contains a heading.',
          ),
          ScreenplayElementType.note => ('', styles.line, 0.0),
          _ => (element.text, styles.line, 0.0),
        };
        if (text.isEmpty) continue;
        lines.add(
          Padding(
            padding: EdgeInsets.only(left: indent),
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        );
      }
    }
    return Container(
      height: RevericSizes.screenplayScenePeekHeight,
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.x2l,
        vertical: RevericSpacing.lg,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        border: Border(bottom: BorderSide(color: colors.borderSubtle)),
      ),
      child: ClipRect(
        child: ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black, Colors.black, Colors.transparent],
            stops: [0, 0.6, 1],
          ).createShader(bounds),
          blendMode: BlendMode.dstIn,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            maxHeight: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: lines,
            ),
          ),
        ),
      ),
    );
  }
}

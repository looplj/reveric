// 职责: 移动端剧本编辑页 — 组合自绘头部、共享选择状态与手机/平板自适应工作区。
// 关联文件:
//   lib/mobile/pages/workspace_editor_page.dart
//   lib/mobile/features/screenplay/script_page.dart
//   lib/shared/providers/screenplay_providers.dart
//   lib/shared/providers/screenplay_workspace_state_provider.dart
//   lib/mobile/pages/novel_chat_page.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/performance.md

import 'dart:async';
import '../../../shared/components/horizontal_wheel_scroll.dart';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/database/app_database.dart';
import '../../../shared/database/novel_content_database.dart'
    show ScreenplayEpisodeRow, ScreenplaySeasonRow;
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/screenplay_workspace_state.dart';
import '../../../shared/providers/screenplay_providers.dart';
import '../../../shared/providers/screenplay_workspace_state_provider.dart';
import '../../../shared/theme/theme.dart';
import '../../pages/novel_chat_page.dart';
import 'beats_page.dart';
import 'shared_content.dart';
import 'episode_picker_sheet.dart';
import 'outline_page.dart';
import 'overview.dart';
import 'scenes_page.dart';
import 'script_page.dart';
import 'header.dart';
import 'support.dart';

@visibleForTesting
const mobileScreenplaySectionLabelKeys = <ScreenplayWorkspaceSection, String>{
  ScreenplayWorkspaceSection.overview: LocaleKeys.screenplayOverview,
  ScreenplayWorkspaceSection.script: LocaleKeys.screenplayScript,
  ScreenplayWorkspaceSection.characters: LocaleKeys.workspaceCharacters,
  ScreenplayWorkspaceSection.foreshadowings: LocaleKeys.workspaceForeshadowings,
  ScreenplayWorkspaceSection.scenes: LocaleKeys.screenplayScenes,
  ScreenplayWorkspaceSection.lore: LocaleKeys.workspaceLore,
  ScreenplayWorkspaceSection.outline: LocaleKeys.screenplayOutline,
  ScreenplayWorkspaceSection.beats: LocaleKeys.screenplayBeats,
  ScreenplayWorkspaceSection.items: LocaleKeys.workspaceItems,
  ScreenplayWorkspaceSection.factions: LocaleKeys.workspaceFactions,
  ScreenplayWorkspaceSection.creatures: LocaleKeys.workspaceCreatures,
  ScreenplayWorkspaceSection.skills: LocaleKeys.workspaceSkills,
  ScreenplayWorkspaceSection.maps: LocaleKeys.workspaceMaps,
  ScreenplayWorkspaceSection.materials: LocaleKeys.workspaceMaterials,
  ScreenplayWorkspaceSection.entity_graph:
      LocaleKeys.workspaceSidebarEntityGraph,
  ScreenplayWorkspaceSection.story_progress: LocaleKeys.workspaceStoryProgress,
};

class MobileScreenplayEditorPage extends HookConsumerWidget {
  const MobileScreenplayEditorPage({super.key, required this.novel});

  final Novel novel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = novel.contentDatabasePath;
    final colors = RevericTheme.colorsOf(context);
    if (path == null || path.isEmpty) {
      return Scaffold(
        backgroundColor: colors.canvas,
        body: Center(
          child: Text(context.t(LocaleKeys.libraryWorkspaceLoadFailed)),
        ),
      );
    }
    final root = ref.watch(screenplayRootProvider(path));
    final provider = screenplayWorkspaceStateControllerProvider(novel.id, path);
    final workspace = ref.watch(provider);
    final flushRef = useRef<Future<void> Function()?>(null);
    final allowPop = useState(false);

    Future<bool> flush() async {
      try {
        await flushRef.value?.call();
        await ref.read(provider.notifier).flush();
        return true;
      } catch (_) {
        return false;
      }
    }

    Future<void> close() async {
      if (!await flush() || !context.mounted) return;
      allowPop.value = true;
      await Future<void>.delayed(Duration.zero);
      if (context.mounted) Navigator.of(context).maybePop();
    }

    return PopScope(
      canPop: allowPop.value,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) close();
      },
      child: Scaffold(
        backgroundColor: colors.canvas,
        body: SafeArea(
          bottom: false,
          child: root.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => Center(
              child: Text(context.t(LocaleKeys.libraryWorkspaceLoadFailed)),
            ),
            data: (screenplay) {
              if (screenplay == null) {
                return Center(
                  child: Text(context.t(LocaleKeys.libraryWorkspaceLoadFailed)),
                );
              }
              final seasons =
                  ref
                      .watch(screenplaySeasonsProvider(path, screenplay.id))
                      .value ??
                  const <ScreenplaySeasonRow>[];
              final season = seasons
                  .where((row) => row.id == workspace.seasonId)
                  .firstOrNull;
              final episodes = season == null
                  ? const <ScreenplayEpisodeRow>[]
                  : ref
                            .watch(screenplayEpisodesProvider(path, season.id))
                            .value ??
                        const <ScreenplayEpisodeRow>[];
              final episode = episodes
                  .where((row) => row.id == workspace.episodeId)
                  .firstOrNull;
              Future<void> openAssistant() async {
                if (!await flush()) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(context.t(LocaleKeys.commonSaveFailed)),
                      ),
                    );
                  }
                  return;
                }
                if (!context.mounted) {
                  return;
                }
                await Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => MobileNovelChatPage(
                      novelId: novel.id,
                      databasePath: path,
                      currentSeasonId: season?.id,
                      currentEpisodeId: episode?.id,
                      hasMultipleSeasons: seasons.length > 1,
                    ),
                  ),
                );
              }

              return Column(
                children: [
                  MobileScreenplayHeader(
                    title: novel.title,
                    subtitle:
                        {
                              ScreenplayWorkspaceSection.script,
                              ScreenplayWorkspaceSection.outline,
                              ScreenplayWorkspaceSection.beats,
                              ScreenplayWorkspaceSection.scenes,
                            }.contains(workspace.section) &&
                            episode != null
                        ? [
                            if (seasons.length > 1 && season != null)
                              mobileSeasonLabel(context, season),
                            mobileEpisodeLabel(context, episode),
                          ].join(' · ')
                        : context.t(LocaleKeys.screenplaySeries),
                    onBack: close,
                    onEpisode:
                        {
                          ScreenplayWorkspaceSection.script,
                          ScreenplayWorkspaceSection.outline,
                          ScreenplayWorkspaceSection.beats,
                          ScreenplayWorkspaceSection.scenes,
                        }.contains(workspace.section)
                        ? () => showMobileScreenplayEpisodePicker(
                            context,
                            novel: novel,
                            screenplayId: screenplay.id,
                            onFlush: flush,
                          )
                        : null,
                    onAi: openAssistant,
                  ),
                  _SectionBar(
                    selected: workspace.section,
                    onSelected: (section) async {
                      if (!await flush()) return;
                      ref
                          .read(provider.notifier)
                          .update(workspace.copyWith(section: section));
                    },
                  ),
                  Expanded(
                    child: _MobileScreenplayContent(
                      novel: novel,
                      screenplayId: screenplay.id,
                      section: workspace.section,
                      registerFlush: (value) => flushRef.value = value,
                      onOpenAssistant: openAssistant,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SectionBar extends StatelessWidget {
  const _SectionBar({required this.selected, required this.onSelected});

  final ScreenplayWorkspaceSection selected;
  final ValueChanged<ScreenplayWorkspaceSection> onSelected;

  @override
  Widget build(BuildContext context) {
    final items = [
      for (final entry in mobileScreenplaySectionLabelKeys.entries)
        (entry.key, context.t(entry.value)),
    ];
    return SizedBox(
      height: 48,
      child: HorizontalWheelScroll(
        builder: (context, controller) => ListView.separated(
          controller: controller,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.md),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(width: RevericSpacing.sm),
          itemBuilder: (context, index) {
            final active = selected == items[index].$1;
            final colors = RevericTheme.colorsOf(context);
            return InkWell(
              onTap: () => onSelected(items[index].$1),
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: RevericSpacing.sm),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: active ? colors.accent : colors.surface,
                  borderRadius: BorderRadius.circular(RevericRadius.pill),
                  border: Border.all(
                    color: active ? colors.accent : colors.borderSubtle,
                  ),
                ),
                child: Text(
                  items[index].$2,
                  style: RevericTheme.typographyOf(context).uiSemibold.copyWith(
                    color: active ? colors.onAccent : colors.textSecondary,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _MobileScreenplayContent extends StatelessWidget {
  const _MobileScreenplayContent({
    required this.novel,
    required this.screenplayId,
    required this.section,
    required this.registerFlush,
    required this.onOpenAssistant,
  });

  final Novel novel;
  final String screenplayId;
  final ScreenplayWorkspaceSection section;
  final ValueChanged<Future<void> Function()?> registerFlush;
  final VoidCallback onOpenAssistant;

  @override
  Widget build(BuildContext context) {
    return switch (section) {
      ScreenplayWorkspaceSection.overview => MobileScreenplayOverview(
        novel: novel,
        screenplayId: screenplayId,
      ),
      ScreenplayWorkspaceSection.script => MobileScreenplayScriptPage(
        novel: novel,
        registerFlush: registerFlush,
        onOpenAssistant: onOpenAssistant,
      ),
      ScreenplayWorkspaceSection.outline => MobileScreenplayOutlinePage(
        novel: novel,
        registerFlush: registerFlush,
      ),
      ScreenplayWorkspaceSection.beats => MobileScreenplayBeatsPage(
        novel: novel,
      ),
      ScreenplayWorkspaceSection.scenes => MobileScreenplayScenesPage(
        novel: novel,
      ),
      ScreenplayWorkspaceSection.foreshadowings ||
      ScreenplayWorkspaceSection.characters ||
      ScreenplayWorkspaceSection.lore ||
      ScreenplayWorkspaceSection.items ||
      ScreenplayWorkspaceSection.factions ||
      ScreenplayWorkspaceSection.creatures ||
      ScreenplayWorkspaceSection.skills ||
      ScreenplayWorkspaceSection.maps ||
      ScreenplayWorkspaceSection.materials ||
      ScreenplayWorkspaceSection.entity_graph ||
      ScreenplayWorkspaceSection.story_progress =>
        MobileScreenplaySharedContent(
          key: ValueKey(section),
          novel: novel,
          section: section,
        ),
    };
  }
}

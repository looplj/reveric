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

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_icon_button.dart';
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
import '../../widgets/section_chips.dart';
import '../../widgets/workspace_header.dart';
import 'shared_content.dart';
import 'episode_picker_sheet.dart';
import 'outline_page.dart';
import 'overview.dart';
import 'scenes_page.dart';
import 'script_page.dart';
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
  ScreenplayWorkspaceSection.compendium: LocaleKeys.workspaceSidebarCompendium,
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
    final createHandlers = useRef(
      <ScreenplayWorkspaceSection, Future<void> Function()>{},
    );
    final allowPop = useState(false);

    void registerCreate(
      ScreenplayWorkspaceSection section,
      Future<void> Function()? handler,
    ) {
      if (handler == null) {
        createHandlers.value.remove(section);
      } else {
        createHandlers.value[section] = handler;
      }
    }

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

              final sections = mobileScreenplaySectionLabelKeys.keys.toList(
                growable: false,
              );
              final selectedIndex = sections.indexOf(workspace.section);
              final isEpisodeSection = const {
                ScreenplayWorkspaceSection.script,
                ScreenplayWorkspaceSection.outline,
                ScreenplayWorkspaceSection.scenes,
              }.contains(workspace.section);
              final createLabelKey = mobileScreenplayCreateLabelKey(
                workspace.section,
              );

              return Column(
                children: [
                  MobileWorkspaceHeader(
                    title: novel.title,
                    subtitle: isEpisodeSection && episode != null
                        ? [
                            if (seasons.length > 1 && season != null)
                              mobileSeasonLabel(context, season),
                            mobileEpisodeLabel(context, episode),
                          ].join(' · ')
                        : context.t(
                            mobileScreenplaySectionLabelKeys[workspace
                                    .section] ??
                                LocaleKeys.screenplaySeries,
                          ),
                    onBack: close,
                    onTitleTap: isEpisodeSection
                        ? () => showMobileScreenplayEpisodePicker(
                            context,
                            novel: novel,
                            screenplayId: screenplay.id,
                            onFlush: flush,
                          )
                        : null,
                    actions: [
                      if (createLabelKey != null)
                        RevericIconButton(
                          icon: RevericIcons.add,
                          tooltip: context.t(createLabelKey),
                          onPressed: () {
                            final handler =
                                createHandlers.value[workspace.section];
                            if (handler != null) {
                              unawaited(handler());
                            }
                          },
                        ),
                      RevericIconButton(
                        icon: RevericIcons.auto_awesome,
                        tooltip: context.t(LocaleKeys.aiSessionModeChat),
                        onPressed: openAssistant,
                      ),
                    ],
                  ),
                  MobileSectionChips(
                    labels: [
                      for (final key in mobileScreenplaySectionLabelKeys.values)
                        context.t(key),
                    ],
                    selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
                    onSelect: (index) async {
                      final section = sections[index];
                      if (section == workspace.section) {
                        return;
                      }
                      if (!await flush() || !context.mounted) {
                        return;
                      }
                      ref
                          .read(provider.notifier)
                          .update(
                            ref.read(provider).copyWith(section: section),
                          );
                    },
                  ),
                  Expanded(
                    child: _MobileScreenplayContent(
                      novel: novel,
                      screenplayId: screenplay.id,
                      section: workspace.section,
                      registerFlush: (value) => flushRef.value = value,
                      registerCreate: registerCreate,
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

class _MobileScreenplayContent extends StatelessWidget {
  const _MobileScreenplayContent({
    required this.novel,
    required this.screenplayId,
    required this.section,
    required this.registerFlush,
    required this.registerCreate,
    required this.onOpenAssistant,
  });

  final Novel novel;
  final String screenplayId;
  final ScreenplayWorkspaceSection section;
  final ValueChanged<Future<void> Function()?> registerFlush;
  final void Function(
    ScreenplayWorkspaceSection section,
    Future<void> Function()? handler,
  )
  registerCreate;
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
      ScreenplayWorkspaceSection.scenes => MobileScreenplayScenesPage(
        novel: novel,
      ),
      ScreenplayWorkspaceSection.foreshadowings ||
      ScreenplayWorkspaceSection.characters ||
      ScreenplayWorkspaceSection.lore ||
      ScreenplayWorkspaceSection.compendium ||
      ScreenplayWorkspaceSection.maps ||
      ScreenplayWorkspaceSection.materials ||
      ScreenplayWorkspaceSection.entity_graph ||
      ScreenplayWorkspaceSection.story_progress =>
        MobileScreenplaySharedContent(
          key: ValueKey(section),
          novel: novel,
          section: section,
          registerCreate: registerCreate,
        ),
    };
  }
}

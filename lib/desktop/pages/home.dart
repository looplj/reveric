// 职责: 桌面端首页 — 分别展示小说库与剧本库、最近 AI 会话与全局智能体入口。
// 关联文件:
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/widgets/confirm_dialog.dart
//   lib/desktop/pages/workspace_editor_page.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/providers/subagent_providers.dart
//   lib/shared/providers/agent_skill_providers.dart
//   lib/shared/providers/novel_agent_skill_providers.dart
//   lib/shared/database/app_database.dart
//   lib/shared/services/novel_import.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/agent_shortcut.json
//   assets/translations/zh-CN/agent_shortcut.json
//   lib/desktop/features/reading/reading_page.dart
//   assets/translations/en/reading.json
//   assets/translations/zh-CN/reading.json
//   assets/translations/en/home.json
//   assets/translations/zh-CN/home.json
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
//   assets/translations/en/agent_studio.json
//   assets/translations/zh-CN/agent_studio.json
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
//   assets/translations/en/settings.json
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/zh-CN/provider.json
//   lib/shared/widgets/unsaved_changes_dialog.dart
//   lib/shared/widgets/settings/leave_guard.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
import '../../shared/widgets/plugin_view/navigation.dart';
import '../../shared/widgets/plugin_view/page.dart';
import '../../shared/models/plugin/view.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/components/dialog_feedback.dart';
import '../../shared/database/app_database.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/widgets/quick_start_idea.dart';
import '../../shared/models/ai_session_mode.dart';
import '../../shared/models/ai_shortcut_action.dart';
import '../../shared/models/content_kind.dart';
import '../../shared/models/novel_agent_skill.dart';
import '../../shared/models/subagent.dart';
import '../../shared/providers/ai_mode_processing.dart';
import '../../shared/models/novel.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/providers/novel_agent_skill_providers.dart';
import '../../shared/services/novel_import.dart';
import '../../shared/services/novel_actions.dart'
    show NovelTitleConflictException;
import '../../shared/theme/theme.dart';
import '../../shared/logger/app_logger.dart';
import '../../shared/widgets/app_background.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../../shared/widgets/settings/leave_guard.dart';
import '../../shared/widgets/unsaved_changes_dialog.dart';
import '../../shared/services/demo_novel.dart';
import '../widgets/agent_management/ai_shortcut_action_edit_panel.dart';
import '../widgets/agent_management/agent_model_settings_page.dart';
import '../widgets/agent_management/plugins_page.dart';
import '../widgets/agent_management/ai_assistant_page.dart';
import '../widgets/agent_management/ai_providers_page.dart';
import '../widgets/agent_management/mcp_page.dart';
import '../widgets/agent_management/expert_team_page.dart';
import '../features/agent_skills/setup_panel.dart';
import '../features/agent_skills/setup_edit_panel.dart';
import '../features/agent_skills/skill_revision_history_dialog.dart';
import '../widgets/desktop_window_frame.dart';
import '../widgets/desktop_save_shortcut.dart';
import '../widgets/novel_create_submitter.dart';
import '../widgets/novel_form_dialog.dart';
import '../widgets/novel_import_dialog.dart';
import '../../shared/services/screenplay_import.dart';
import '../../shared/widgets/screenplay/import_dialog.dart';
import '../widgets/home/library_home_panel.dart';
import '../widgets/settings/settings_dialog.dart';
import '../widgets/agent_management/subagent_edit_panel.dart';
import '../widgets/agent_management/subagent_prompt_edit_panel.dart';
import '../widgets/community_row.dart';
import '../widgets/user_profile_bar.dart';
import '../widgets/update_entry.dart';
import 'home_management_lists.dart';
import '../features/reading/reading_page.dart';
import 'workspace_editor_page.dart';
import '../../shared/components/reveric_dialog.dart';

final _log = AppLogger.forModule('Home');

final _recentSessionsProvider = StreamProvider.family<List<AiChatSession>, int>(
  (ref, limit) {
    final db = ref.watch(appDatabaseProvider);
    return db.aiChatSessionDao.watchRecent(
      limit: limit,
      mode: AiSessionMode.chat.value,
    );
  },
);

final _homeSessionsExpanded = ValueNotifier(false);

sealed class _HomeContentSelection {
  const _HomeContentSelection();
}

final class _HomeLibrarySelection extends _HomeContentSelection {
  const _HomeLibrarySelection(this.contentKind);

  /// 小说库与剧本库各是一个独立入口。
  final String contentKind;
}

final class _HomeSubAgentSelection extends _HomeContentSelection {
  const _HomeSubAgentSelection(this.agent);

  final SubAgent agent;
}

final class _HomeSubAgentPromptSelection extends _HomeContentSelection {
  const _HomeSubAgentPromptSelection(this.agent);

  final SubAgent agent;
}

final class _HomeAgentModelSettingsSelection extends _HomeContentSelection {
  const _HomeAgentModelSettingsSelection();
}

final class _HomeExpertTeamSelection extends _HomeContentSelection {
  const _HomeExpertTeamSelection();
}

final class _HomeAiProvidersSelection extends _HomeContentSelection {
  const _HomeAiProvidersSelection();
}

final class _HomeAiAssistantSelection extends _HomeContentSelection {
  const _HomeAiAssistantSelection();
}

final class _HomeMcpSelection extends _HomeContentSelection {
  const _HomeMcpSelection();
}

final class _HomePluginsSelection extends _HomeContentSelection {
  const _HomePluginsSelection();
}

final class _HomeSkillListSelection extends _HomeContentSelection {
  const _HomeSkillListSelection();
}

final class _HomeGlobalSkillSelection extends _HomeContentSelection {
  const _HomeGlobalSkillSelection(this.skill);

  final NovelAgentSkillModel? skill;
}

final class _HomeShortcutActionSelection extends _HomeContentSelection {
  const _HomeShortcutActionSelection(this.action);

  final AiShortcutActionDefinition action;
}

final class _HomeShortcutActionListSelection extends _HomeContentSelection {
  const _HomeShortcutActionListSelection();
}

final class _HomePluginPageSelection extends _HomeContentSelection {
  const _HomePluginPageSelection(this.view);

  final PluginView view;
}

Widget _buildGlobalSkillEditor({
  required BuildContext context,
  required WidgetRef ref,
  required NovelAgentSkillModel? skill,
  required GlobalKey headerGestureExclusionKey,
  required VoidCallback onBack,
  required ValueChanged<NovelAgentSkillModel> onSaved,
  ValueChanged<bool>? onHasChangesChanged,
  ValueChanged<Future<bool> Function()?>? onRegisterSave,
  ValueChanged<bool Function()?>? onRegisterHasChanges,
  ValueChanged<bool Function()?>? onRegisterIsBlankCreateDraft,
}) {
  var activeSkill = skill;
  return AgentSkillSetupEditPanel(
    draft: activeSkill == null
        ? const AgentSkillSetupEditDraft.novel()
        : AgentSkillSetupEditDraft(
            name: activeSkill.name,
            whenToUse: activeSkill.whenToUse,
            description: activeSkill.description,
            prompt: activeSkill.prompt,
            category: activeSkill.category,
            tags: activeSkill.tags,
            references: activeSkill.references,
            enabled: activeSkill.enabled,
          ),
    createTitleKey: LocaleKeys.commonCreate,
    headerGestureExclusionKey: headerGestureExclusionKey,
    headerTrailingInset: DesktopWindowFrame.trailingInset,
    onBack: onBack,
    // 新建草稿还没有任何版本，保存后才出现历史入口。
    onOpenHistory: activeSkill == null
        ? null
        : () => showSkillRevisionHistoryDialog(context, skill: activeSkill!),
    onHasChangesChanged: onHasChangesChanged,
    onRegisterSave: onRegisterSave,
    onRegisterHasChanges: onRegisterHasChanges,
    onRegisterIsBlankCreateDraft: onRegisterIsBlankCreateDraft,
    onSave: (draft) async {
      final notifier = ref.read(installedAgentSkillsProvider.notifier);
      late final NovelAgentSkillModel saved;
      if (activeSkill == null) {
        saved = await notifier.createNovelLocalSkill(
          InstallSkillInput(
            sourceKind: AgentSkillSourceKind.novelLocal,
            name: draft.name,
            whenToUse: draft.whenToUse,
            description: draft.description,
            prompt: draft.prompt,
            category: draft.category,
            tags: draft.tags,
            references: draft.references,
            enabled: draft.enabled,
          ),
        );
      } else {
        final updated = activeSkill!.copyWith(
          name: draft.name,
          whenToUse: draft.whenToUse,
          description: draft.description,
          prompt: draft.prompt,
          category: draft.category,
          tags: draft.tags,
          references: draft.references,
          enabled: draft.enabled,
        );
        await notifier.updateSnapshotFields(updated);
        saved = updated;
      }
      activeSkill = saved;
      return AgentSkillSetupEditDraft(
        name: saved.name,
        whenToUse: saved.whenToUse,
        description: saved.description,
        prompt: saved.prompt,
        category: saved.category,
        tags: saved.tags,
        references: saved.references,
        enabled: saved.enabled,
      );
    },
    onSaved: (_) {
      onSaved(activeSkill!);
    },
  );
}

class NovelHomePage extends HookConsumerWidget {
  const NovelHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final novelsAsync = ref.watch(novelsProvider);
    final recentSessionsAsync = ref.watch(_recentSessionsProvider(3));
    final selection = useState<_HomeContentSelection>(
      const _HomeLibrarySelection(contentKindNovel),
    );
    final novelSerial = useState(1);
    final isDeletingNovel = useState(false);
    // 顶部问候栏按钮（新建作品、导入 TXT）和 DesktopWindowFrame 的标题栏拖拽层重叠；
    // 将它注册为排除区域，避免双击按钮时触发窗口最大化/还原。
    // 小说库和剧本库同时挂载，各用一个 key，只登记当前可见的那个。
    final greetingHeaderKeys = useMemoized(
      () => {
        contentKindNovel: GlobalKey(),
        contentKindScreenplay: GlobalKey(),
        contentKindCanvas: GlobalKey(),
      },
      [],
    );
    // 编辑面板标题栏按钮（Save / Cancel / Delete 等）同样在标题栏拖拽层内；
    // 共用一个 key，因为同一时刻只有一个面板可见。
    final editPanelHeaderKey = useMemoized(() => GlobalKey(), []);
    final subAgentHasChanges = useState(false);
    final skillHasChanges = useState(false);
    final shortcutActionHasChanges = useState(false);
    final activeAgentPanelSave = useRef<Future<bool> Function()?>(null);
    final activeAgentPanelHasChanges = useRef<bool Function()?>(null);
    final activeAgentPanelIsBlankCreateDraft = useRef<bool Function()?>(null);
    final pluginPageHasChanges = useRef<bool Function()?>(null);
    // 供应商草稿、MCP 编辑表单沿用设置区的离开守卫，切换侧栏前由它们自行询问。
    final settingsLeave = useMemoized(SettingsLeaveController.new);
    final sessionsExpanded = _homeSessionsExpanded;
    useListenable(sessionsExpanded);
    // 快速开书：占位建书后直接进编辑器，其余设定交给创作向导 onboarding。
    // 从首页顶栏直接触发（无对话框可关），故不做 dialog pop。
    Future<void> quickStartNovel() async {
      final idea = await showQuickStartIdea(context, mobile: false);
      if (!context.mounted || idea == null) {
        return;
      }
      final kickoffPrompt = buildQuickStartKickoffPrompt(idea);
      final actions = ref.read(novelActionsProvider);
      final messenger = ScaffoldMessenger.of(context);
      final navigator = Navigator.of(context);
      try {
        final novelId = await actions.createQuickStartNovel(
          untitledTitle: context.t(LocaleKeys.libraryUntitledNovel),
        );
        if (!context.mounted) {
          return;
        }
        novelSerial.value += 1;
        navigator.push(
          MaterialPageRoute(
            builder: (_) => WorkspaceEditorPage(
              novelId: novelId,
              initialChatKickoffPrompt: kickoffPrompt,
            ),
          ),
        );
      } catch (error) {
        _log.error('quickStartNovel caught error=$error', error: error);
        if (!context.mounted) {
          return;
        }
        messenger.showSnackBar(
          SnackBar(
            content: Text(context.t(LocaleKeys.libraryCreateNovelFailed)),
          ),
        );
      }
    }

    Future<void> deleteNovel(Novel novel) async {
      if (isDeletingNovel.value) {
        return;
      }

      final shouldDelete = await _showDeleteConfirm(context, novel);
      if (!context.mounted || !shouldDelete) {
        return;
      }

      final actions = ref.read(novelActionsProvider);
      final messenger = ScaffoldMessenger.of(context);
      isDeletingNovel.value = true;

      try {
        await actions.deleteNovel(novel);
        if (!context.mounted) {
          return;
        }
        isDeletingNovel.value = false;
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              context.t(
                LocaleKeys.libraryDeleteNovelSuccess,
                namedArgs: {'title': novel.title},
              ),
            ),
          ),
        );
      } catch (error) {
        if (!context.mounted) {
          return;
        }
        isDeletingNovel.value = false;
        messenger.showSnackBar(
          SnackBar(
            content: Text(context.t(LocaleKeys.libraryDeleteNovelFailed)),
          ),
        );
      }
    }

    void openEditNovelDialog(Novel novel) {
      showRevericDialog<void>(
        context: context,
        builder: (_) => DialogFeedback.scope(
          builder: (dialogContext) => NovelFormDialog.edit(
            novel: novel,
            onSubmit:
                ({
                  required title,
                  required authorName,
                  required description,
                  required category,
                  required type,
                  required contentKind,
                  required plannedEpisodeCount,
                  required sourceNovelId,
                  required coverSourcePath,
                  required removeCover,
                  required tags,
                }) async {
                  final actions = ref.read(novelActionsProvider);
                  final messenger = ScaffoldMessenger.of(dialogContext);
                  try {
                    await actions.updateNovel(
                      novel: novel,
                      title: title,
                      authorName: authorName,
                      description: description,
                      category: category,
                      type: type,
                      updateSourceNovel: true,
                      sourceNovelId: sourceNovelId,
                      coverSourcePath: coverSourcePath,
                      removeCover: removeCover,
                      tags: tags,
                    );
                    if (!dialogContext.mounted) {
                      return true;
                    }
                    DialogFeedback.hostMessengerOf(dialogContext).showSnackBar(
                      SnackBar(
                        content: Text(context.t(LocaleKeys.commonSaved)),
                      ),
                    );
                    return true;
                  } on NovelTitleConflictException catch (error) {
                    if (!dialogContext.mounted) {
                      return false;
                    }
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          context.t(
                            LocaleKeys.libraryDuplicateName,
                            namedArgs: {'name': error.title},
                          ),
                        ),
                      ),
                    );
                    return false;
                  } catch (_) {
                    if (!dialogContext.mounted) {
                      return false;
                    }
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          context.t(LocaleKeys.editorSaveNovelFailed),
                        ),
                      ),
                    );
                    return false;
                  }
                },
          ),
        ),
      );
    }

    Future<void> createCanvas() async {
      try {
        final id = await ref
            .read(novelActionsProvider)
            .createCanvas(
              defaultTitle: context.t(LocaleKeys.libraryDefaultCanvasTitle),
            );
        if (context.mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => WorkspaceEditorPage(novelId: id),
            ),
          );
        }
      } catch (error, stack) {
        _log.error('Create canvas failed', error: error, stackTrace: stack);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.t(LocaleKeys.editorSaveNovelFailed)),
            ),
          );
        }
      }
    }

    void openCreateNovelDialog(String contentKind) {
      if (contentKind == contentKindCanvas) {
        createCanvas();
        return;
      }

      final isNovel = contentKind == contentKindNovel;
      final novels = novelsAsync.maybeWhen(
        data: (list) => list,
        orElse: () => <Novel>[],
      );
      final hasDemo = novels.any((n) => n.tags.contains('demo'));

      showRevericDialog<void>(
        context: context,
        builder: (_) => DialogFeedback.scope(
          builder: (dialogContext) => NovelFormDialog.create(
            initialContentKind: contentKind,
            onSubmit: createWorkSubmitter(
              context,
              ref,
              feedbackContext: dialogContext,
            ),
            // 快速开书和演示作品都只建小说，剧本库不提供。
            onQuickStart: !isNovel
                ? null
                : () {
                    // 先关表单对话框，再走占位建书 + 进编辑器。
                    Navigator.of(context, rootNavigator: true).pop();
                    quickStartNovel();
                  },
            onCreateDemoNovel: !isNovel || hasDemo
                ? null
                : () => createDemoNovelWithNavigation(
                    context,
                    ref,
                    feedbackContext: dialogContext,
                  ),
          ),
        ),
      );
    }

    // 导入剧本：以文件名建剧本并把原文存为资料，进编辑器后由 AI 按提示词分段读取改编。
    Future<void> importScreenplay() async {
      final request = await showScreenplayImport(context, mobile: false);
      if (!context.mounted || request == null) {
        return;
      }
      final actions = ref.read(novelActionsProvider);
      final messenger = ScaffoldMessenger.of(context);
      final navigator = Navigator.of(context);
      final kickoffTitle = context.t(LocaleKeys.libraryImportScreenplay);
      try {
        final title = request.source.title.isEmpty
            ? context.t(LocaleKeys.libraryUntitledNovel)
            : request.source.title;
        final screenplayId = await actions.createImportedScreenplay(
          title: title,
          sourceContent: request.source.content,
        );
        if (!context.mounted) {
          return;
        }
        novelSerial.value += 1;
        navigator.push(
          MaterialPageRoute(
            builder: (_) => WorkspaceEditorPage(
              novelId: screenplayId,
              initialChatKickoffPrompt: buildScreenplayImportKickoffPrompt(
                prompt: request.prompt,
                materialTitle: title,
                lineCount: request.source.lineCount,
              ),
              initialChatKickoffTitle: kickoffTitle,
            ),
          ),
        );
      } catch (error) {
        _log.error('importScreenplay caught error=$error', error: error);
        if (!context.mounted) {
          return;
        }
        messenger.showSnackBar(
          SnackBar(
            content: Text(context.t(LocaleKeys.libraryCreateNovelFailed)),
          ),
        );
      }
    }

    /// 从一本小说出发新建改编剧本：类型、来源与原著信息预填，其余交给用户确认。
    void adaptNovel(Novel novel) {
      showNovelAdaptationDialog(context, ref, novel);
    }

    Future<void> openImportNovelDialog() async {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: 'text', extensions: ['txt']),
        ],
      );
      if (!context.mounted || file == null) {
        return;
      }
      final filePath = file.path;

      final actions = ref.read(novelActionsProvider);
      final importService = NovelImportService(actions: actions);
      final messenger = ScaffoldMessenger.of(context);
      final navigator = Navigator.of(context);
      late final ParsedNovelImport parsed;
      try {
        parsed = await importService.parseTxtFile(filePath);
        if (parsed.chapters.isEmpty) {
          if (!context.mounted) {
            return;
          }
          // 提示里带了章节标题的格式要求，多留些时间读完。
          messenger.showSnackBar(
            SnackBar(
              content: Text(context.t(LocaleKeys.libraryImportTxtEmpty)),
              duration: const Duration(seconds: 8),
            ),
          );
          return;
        }
      } catch (error) {
        if (!context.mounted) {
          return;
        }
        messenger.showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.libraryImportTxtFailed))),
        );
        return;
      }

      if (!context.mounted) {
        return;
      }
      final importResult = await showRevericDialog<NovelImportResult>(
        context: context,
        builder: (_) => NovelImportDialog(
          filePath: filePath,
          parsed: parsed,
          onSubmit:
              ({
                required title,
                required description,
                required category,
                required type,
                required tags,
              }) {
                return importService.importTxt(
                  filePath: filePath,
                  title: title,
                  description: description,
                  category: category,
                  type: type,
                  tags: tags,
                );
              },
        ),
      );
      if (!context.mounted || importResult == null) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            context.t(
              LocaleKeys.libraryImportTxtSuccess,
              namedArgs: {
                'chapters': '${importResult.chapterCount}',
                'volumes': '${importResult.volumeCount}',
              },
            ),
          ),
        ),
      );

      navigator.push(
        MaterialPageRoute(
          builder: (_) => WorkspaceEditorPage(
            novelId: importResult.novelId,
            openChatOnEntry: true,
          ),
        ),
      );
    }

    Future<void> updateNovelStatus(Novel novel, String status) async {
      final actions = ref.read(novelActionsProvider);
      final messenger = ScaffoldMessenger.of(context);

      try {
        await actions.updateNovelStatus(novelId: novel.id, status: status);
        if (!context.mounted) return;
        messenger.showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.commonSaved))),
        );
      } catch (error) {
        messenger.showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.homeUpdateStatusFailed))),
        );
      }
    }

    bool isSameSelection(
      _HomeContentSelection currentSelection,
      _HomeContentSelection nextSelection,
    ) {
      return switch ((currentSelection, nextSelection)) {
        (
          _HomeLibrarySelection(contentKind: final currentKind),
          _HomeLibrarySelection(contentKind: final nextKind),
        ) =>
          currentKind == nextKind,
        (
          _HomeSubAgentSelection(agent: final currentAgent),
          _HomeSubAgentSelection(agent: final nextAgent),
        ) =>
          currentAgent.id == nextAgent.id,
        (
          _HomeSubAgentPromptSelection(agent: final currentAgent),
          _HomeSubAgentPromptSelection(agent: final nextAgent),
        ) =>
          currentAgent.id == nextAgent.id,
        (
          _HomeAgentModelSettingsSelection(),
          _HomeAgentModelSettingsSelection(),
        ) =>
          true,
        (_HomeExpertTeamSelection(), _HomeExpertTeamSelection()) => true,
        (_HomeAiProvidersSelection(), _HomeAiProvidersSelection()) => true,
        (_HomeAiAssistantSelection(), _HomeAiAssistantSelection()) => true,
        (_HomeMcpSelection(), _HomeMcpSelection()) => true,
        (_HomePluginsSelection(), _HomePluginsSelection()) => true,
        (_HomeSkillListSelection(), _HomeSkillListSelection()) => true,
        (
          _HomeGlobalSkillSelection(skill: final currentSkill),
          _HomeGlobalSkillSelection(skill: final nextSkill),
        ) =>
          currentSkill?.id == nextSkill?.id,
        (
          _HomeShortcutActionSelection(action: final currentAction),
          _HomeShortcutActionSelection(action: final nextAction),
        ) =>
          currentAction.id == nextAction.id,
        (
          _HomeShortcutActionListSelection(),
          _HomeShortcutActionListSelection(),
        ) =>
          true,
        (
          _HomePluginPageSelection(view: final currentView),
          _HomePluginPageSelection(view: final nextView),
        ) =>
          currentView.pluginId == nextView.pluginId &&
              currentView.id == nextView.id,
        _ => false,
      };
    }

    bool hasUnsavedChanges() {
      return switch (selection.value) {
        _HomeSubAgentSelection() ||
        _HomeSubAgentPromptSelection() => subAgentHasChanges.value,
        _HomeGlobalSkillSelection() =>
          activeAgentPanelHasChanges.value?.call() ?? skillHasChanges.value,
        _HomeShortcutActionSelection() => shortcutActionHasChanges.value,
        _HomePluginPageSelection() =>
          pluginPageHasChanges.value?.call() ?? false,
        _ => false,
      };
    }

    bool isBlankCreateDraftSelection() {
      return switch (selection.value) {
        _HomeGlobalSkillSelection(:final skill) =>
          skill == null &&
              (activeAgentPanelIsBlankCreateDraft.value?.call() ?? false),
        _ => false,
      };
    }

    void clearActiveAgentHasChanges() {
      switch (selection.value) {
        case _HomeSubAgentSelection() || _HomeSubAgentPromptSelection():
          subAgentHasChanges.value = false;
        case _HomeGlobalSkillSelection():
          skillHasChanges.value = false;
        case _HomeShortcutActionSelection():
          shortcutActionHasChanges.value = false;
        default:
          break;
      }
    }

    Future<UnsavedChangesDecision?> showAgentUnsavedChangesDialog() {
      return showUnsavedChangesDialog(
        context: context,
        titleKey: LocaleKeys.editorUnsavedChangesTitle,
        messageKey: LocaleKeys.editorUnsavedChangesMessage,
        // 插件页面的草稿由插件自己保存，宿主只能放弃或留下。
        showSave: selection.value is! _HomePluginPageSelection,
      );
    }

    /// 返回 true 表示「拦截」（不允许离开）；false 表示放行。
    Future<bool> guardUnsavedChanges() async {
      if (!await settingsLeave.confirmLeave()) {
        return true;
      }
      if (isBlankCreateDraftSelection()) {
        clearActiveAgentHasChanges();
        return false;
      }
      if (!hasUnsavedChanges()) {
        return false;
      }
      final decision = await showAgentUnsavedChangesDialog();
      switch (decision) {
        case null:
          return true;
        case UnsavedChangesDecision.discard:
          clearActiveAgentHasChanges();
          return false;
        case UnsavedChangesDecision.save:
          final save = activeAgentPanelSave.value;
          final saved = save != null && await save();
          if (!saved) {
            return true;
          }
          clearActiveAgentHasChanges();
          return false;
      }
    }

    Future<void> selectContent(_HomeContentSelection nextSelection) async {
      if (isSameSelection(selection.value, nextSelection)) {
        return;
      }
      if (await guardUnsavedChanges()) {
        return;
      }
      selection.value = nextSelection;
    }

    void showSavedToast() {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.t(LocaleKeys.commonSaved))),
      );
    }

    _HomeContentSelection listSelectionForCurrentEdit() {
      return switch (selection.value) {
        _HomeSubAgentSelection() => const _HomeExpertTeamSelection(),
        _HomeSubAgentPromptSelection() =>
          const _HomeAgentModelSettingsSelection(),
        _HomeGlobalSkillSelection() => const _HomeSkillListSelection(),
        _HomeShortcutActionSelection() =>
          const _HomeShortcutActionListSelection(),
        _ => const _HomeLibrarySelection(contentKindNovel),
      };
    }

    void handleEntitySaved() {
      clearActiveAgentHasChanges();
      selection.value = listSelectionForCurrentEdit();
      showSavedToast();
    }

    SubAgent newSubAgentDraft() {
      return SubAgent(
        id: '__new__${DateTime.now().microsecondsSinceEpoch}',
        slug: '',
        name: '',
        description: '',
        prompt: '',
        scope: SubAgentScope.global,
        sortOrder: 0,
      );
    }

    AiShortcutActionDefinition newShortcutActionDraft() {
      return AiShortcutActionDefinition(
        id: '__new__${DateTime.now().microsecondsSinceEpoch}',
        name: '',
        prompt: '',
        locations: const <AiShortcutActionLocation>[],
        sortOrder: 0,
      );
    }

    final contentSelection = selection.value;

    HomeLibraryPanel buildLibraryPanel(String contentKind) {
      return HomeLibraryPanel(
        key: ValueKey(contentKind),
        contentKind: contentKind,
        novelsAsync: novelsAsync,
        headerGestureExclusionKey: greetingHeaderKeys[contentKind]!,
        onQuickStart: quickStartNovel,
        onCreateNovel: () => openCreateNovelDialog(contentKind),
        onImportNovel: openImportNovelDialog,
        onImportScreenplay: importScreenplay,
        onCreateDemoNovel: () => createDemoNovelWithNavigation(context, ref),
        onDeleteNovel: (novel) => deleteNovel(novel),
        onAdaptNovel: adaptNovel,
        onEditNovel: (novel) => openEditNovelDialog(novel),
        onOpenNovel: (novel) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => WorkspaceEditorPage(novelId: novel.id),
            ),
          );
        },
        onReadNovel: (novel) {
          if (!novel.hasContentDatabase) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  context.t(LocaleKeys.readingNoChaptersDescription),
                ),
              ),
            );
            return;
          }
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => DesktopReadingPage(
                novelId: novel.id,
                novelTitle: novel.title,
                databasePath: novel.contentDatabasePath!,
              ),
            ),
          );
        },
        onUpdateStatus: updateNovelStatus,
      );
    }

    final mainContent = switch (contentSelection) {
      _HomeAgentModelSettingsSelection() => AgentModelSettingsPage(
        headerGestureExclusionKey: editPanelHeaderKey,
        headerTrailingInset: DesktopWindowFrame.trailingInset,
        onEditPrompt: (agent) {
          selectContent(_HomeSubAgentPromptSelection(agent));
        },
      ),
      _HomeAiProvidersSelection() => AiProvidersPage(
        headerGestureExclusionKey: editPanelHeaderKey,
        headerTrailingInset: DesktopWindowFrame.trailingInset,
      ),
      _HomeAiAssistantSelection() => AiAssistantPage(
        headerGestureExclusionKey: editPanelHeaderKey,
        headerTrailingInset: DesktopWindowFrame.trailingInset,
      ),
      _HomeMcpSelection() => McpPage(
        headerGestureExclusionKey: editPanelHeaderKey,
        headerTrailingInset: DesktopWindowFrame.trailingInset,
      ),
      _HomePluginsSelection() => PluginsPage(
        headerGestureExclusionKey: editPanelHeaderKey,
        headerTrailingInset: DesktopWindowFrame.trailingInset,
      ),
      _HomeExpertTeamSelection() => AgentExpertTeamPage(
        headerGestureExclusionKey: editPanelHeaderKey,
        headerTrailingInset: DesktopWindowFrame.trailingInset,
        onOpen: (agent) {
          selectContent(_HomeSubAgentSelection(agent));
        },
        onCreate: () {
          selectContent(_HomeSubAgentSelection(newSubAgentDraft()));
        },
      ),
      _HomeSubAgentSelection(:final agent) => SubAgentEditPanel(
        agent: agent,
        headerGestureExclusionKey: editPanelHeaderKey,
        headerTrailingInset: DesktopWindowFrame.trailingInset,
        onBack: () {
          selectContent(const _HomeExpertTeamSelection());
        },
        onSaved: handleEntitySaved,
        onHasChangesChanged: (hasChanges) {
          subAgentHasChanges.value = hasChanges;
        },
        onRegisterSave: (save) => activeAgentPanelSave.value = save,
      ),
      _HomeSubAgentPromptSelection(:final agent) => SubAgentPromptEditPanel(
        agent: agent,
        headerGestureExclusionKey: editPanelHeaderKey,
        headerTrailingInset: DesktopWindowFrame.trailingInset,
        onBack: () {
          selectContent(const _HomeAgentModelSettingsSelection());
        },
        onSaved: handleEntitySaved,
        onHasChangesChanged: (hasChanges) {
          subAgentHasChanges.value = hasChanges;
        },
        onRegisterSave: (save) => activeAgentPanelSave.value = save,
      ),
      _HomeSkillListSelection() => SkillSetupPanel(
        headerTrailingInset: DesktopWindowFrame.trailingInset,
        headerGestureExclusionKey: editPanelHeaderKey,
        onCreateInstalledSkill: () {
          selectContent(const _HomeGlobalSkillSelection(null));
        },
        onOpenInstalledSkill: (skill) {
          if (skill.sourceKind != AgentSkillSourceKind.novelLocal) {
            return;
          }
          selectContent(_HomeGlobalSkillSelection(skill));
        },
      ),
      _HomeGlobalSkillSelection(:final skill) => _buildGlobalSkillEditor(
        context: context,
        ref: ref,
        skill: skill,
        headerGestureExclusionKey: editPanelHeaderKey,
        onBack: () {
          selectContent(const _HomeSkillListSelection());
        },
        onSaved: (_) {
          handleEntitySaved();
        },
        onHasChangesChanged: (hasChanges) {
          skillHasChanges.value = hasChanges;
        },
        onRegisterSave: (save) => activeAgentPanelSave.value = save,
        onRegisterHasChanges: (hasChanges) =>
            activeAgentPanelHasChanges.value = hasChanges,
        onRegisterIsBlankCreateDraft: (isBlank) =>
            activeAgentPanelIsBlankCreateDraft.value = isBlank,
      ),
      _HomeShortcutActionListSelection() => HomeShortcutActionGridPage(
        headerGestureExclusionKey: editPanelHeaderKey,
        headerTrailingInset: DesktopWindowFrame.trailingInset,
        onOpen: (action) {
          selectContent(_HomeShortcutActionSelection(action));
        },
        onCreate: () {
          selectContent(_HomeShortcutActionSelection(newShortcutActionDraft()));
        },
      ),
      _HomeShortcutActionSelection(:final action) => AiShortcutActionEditPanel(
        action: action,
        headerGestureExclusionKey: editPanelHeaderKey,
        headerTrailingInset: DesktopWindowFrame.trailingInset,
        onBack: () {
          selectContent(const _HomeShortcutActionListSelection());
        },
        onSaved: handleEntitySaved,
        onHasChangesChanged: (hasChanges) {
          shortcutActionHasChanges.value = hasChanges;
        },
        onRegisterSave: (save) => activeAgentPanelSave.value = save,
      ),
      _HomePluginPageSelection(:final view) => PluginPageRegion(
        key: ValueKey('plugin-page:${view.pluginId}/${view.id}'),
        view: view,
        headerTrailingInset: DesktopWindowFrame.trailingInset,
        onOpenView: (target) {
          selectContent(_HomePluginPageSelection(target));
        },
        onUnavailable: () {
          selection.value = const _HomeLibrarySelection(contentKindNovel);
        },
        onRegisterHasChanges: (hasChanges) =>
            pluginPageHasChanges.value = hasChanges,
      ),
      // 两个库同时挂载、只切换可见的那个：集合作品流不会随切换被释放重查，
      // 切换时不再先闪加载态再出内容；搜索、筛选和滚动位置也各自保留。
      _HomeLibrarySelection(:final contentKind) => IndexedStack(
        index: contentKind == contentKindCanvas
            ? 2
            : contentKind == contentKindScreenplay
            ? 1
            : 0,
        children: [
          buildLibraryPanel(contentKindNovel),
          buildLibraryPanel(contentKindScreenplay),
          buildLibraryPanel(contentKindCanvas),
        ],
      ),
    };

    final appBackgroundActive = ref.watch(appBackgroundActiveProvider);

    return DesktopSaveShortcut(
      onSave: () async {
        await activeAgentPanelSave.value?.call();
      },
      child: Scaffold(
        backgroundColor: appScaffoldBackgroundColor(
          colors,
          appBackgroundActive,
        ),
        body: DesktopWindowFrame(
          titleBarGestureExclusionKeys: [
            if (contentSelection case _HomeLibrarySelection(:final contentKind))
              greetingHeaderKeys[contentKind]!,
            editPanelHeaderKey,
          ],
          child: Row(
            children: [
              _buildSidebar(
                context,
                ref,
                recentSessionsAsync,
                contentSelection,
                selectContent,
                () {
                  showRevericDialog(
                    context: context,
                    builder: (_) => const SettingsDialog(),
                  );
                },
                sessionsExpanded,
              ),
              Container(
                width: RevericSizes.dividerThickness,
                color: colors.border,
              ),
              Expanded(
                child: SettingsLeaveScope(
                  controller: settingsLeave,
                  child: mainContent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _showDeleteConfirm(BuildContext context, Novel novel) {
    return showConfirmDialog(
      context,
      title: context.t(LocaleKeys.commonDelete),
      message: context.t(
        LocaleKeys.libraryDeleteNovelConfirm,
        namedArgs: {'title': novel.title},
      ),
      confirmLabel: context.t(LocaleKeys.commonDelete),
      variant: ConfirmDialogVariant.error,
    );
  }

  Widget _buildSidebar(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<AiChatSession>> recentSessionsAsync,
    _HomeContentSelection selection,
    ValueSetter<_HomeContentSelection> onContentSelected,
    VoidCallback onOpenSettings,
    ValueNotifier<bool> sessionsExpanded,
  ) {
    final colors = RevericTheme.colorsOf(context);
    final recentSessions = recentSessionsAsync.maybeWhen(
      data: (sessions) => sessions,
      orElse: () => <AiChatSession>[],
    );
    final libraryKind = selection is _HomeLibrarySelection
        ? selection.contentKind
        : null;
    final modelSettingsSelected =
        selection is _HomeAgentModelSettingsSelection ||
        selection is _HomeSubAgentPromptSelection;
    final expertTeamSelected =
        selection is _HomeExpertTeamSelection ||
        selection is _HomeSubAgentSelection;
    final skillsSelected =
        selection is _HomeSkillListSelection ||
        selection is _HomeGlobalSkillSelection;
    final shortcutsSelected =
        selection is _HomeShortcutActionListSelection ||
        selection is _HomeShortcutActionSelection;
    return Container(
      width: RevericSizes.sidebarWidth,
      color: appSidebarBackgroundColor(
        colors,
        ref.watch(appBackgroundActiveProvider),
      ),
      child: Column(
        children: [
          SizedBox(height: DesktopWindowFrame.sidebarTopInset),
          // 作品搜索在书库作品区那一行（只搜当前集合），侧栏不再放。
          const SizedBox(height: RevericSpacing.md),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                // Section 1: 作品 (Works)
                _buildSectionGroupHeader(
                  context,
                  title: context.t(LocaleKeys.homeSectionWorks),
                ),
                // 小说和剧本各是一个独立的库，不在同一个作品区里混排。
                _buildLeafNavItem(
                  context,
                  icon: RevericIcons.menu_book_rounded,
                  title: context.t(LocaleKeys.libraryContentKindNovel),
                  isSelected: libraryKind == contentKindNovel,
                  onTap: () {
                    onContentSelected(
                      const _HomeLibrarySelection(contentKindNovel),
                    );
                  },
                ),
                _buildLeafNavItem(
                  context,
                  icon: RevericIcons.movie_outlined,
                  title: context.t(LocaleKeys.libraryContentKindScreenplay),
                  isSelected: libraryKind == contentKindScreenplay,
                  onTap: () {
                    onContentSelected(
                      const _HomeLibrarySelection(contentKindScreenplay),
                    );
                  },
                ),
                _buildLeafNavItem(
                  context,
                  icon: RevericIcons.flow_arrow,
                  title: context.t(LocaleKeys.libraryContentKindCanvas),
                  isSelected: libraryKind == contentKindCanvas,
                  onTap: () => onContentSelected(
                    const _HomeLibrarySelection(contentKindCanvas),
                  ),
                ),
                const SizedBox(height: RevericSpacing.md),
                // Section 2: 模型
                _buildSectionGroupHeader(
                  context,
                  title: context.t(LocaleKeys.homeSectionModel),
                ),
                _buildLeafNavItem(
                  context,
                  icon: RevericIcons.hub_outlined,
                  title: context.t(LocaleKeys.providerTitle),
                  isSelected: selection is _HomeAiProvidersSelection,
                  onTap: () {
                    onContentSelected(const _HomeAiProvidersSelection());
                  },
                ),
                _buildLeafNavItem(
                  context,
                  icon: RevericIcons.tune,
                  title: context.t(LocaleKeys.agentStudioModelSettings),
                  isSelected: modelSettingsSelected,
                  onTap: () {
                    onContentSelected(const _HomeAgentModelSettingsSelection());
                  },
                ),
                const SizedBox(height: RevericSpacing.md),
                // Section 3: 智能体
                _buildSectionGroupHeader(
                  context,
                  title: context.t(LocaleKeys.homeSectionAgent),
                ),
                _buildLeafNavItem(
                  context,
                  icon: RevericIcons.smart_toy_outlined,
                  title: context.t(LocaleKeys.settingsAiAgents),
                  isSelected: selection is _HomeAiAssistantSelection,
                  onTap: () {
                    onContentSelected(const _HomeAiAssistantSelection());
                  },
                ),
                _buildLeafNavItem(
                  context,
                  icon: RevericIcons.auto_awesome_outlined,
                  title: context.t(LocaleKeys.agentSkillTitle),
                  isSelected: skillsSelected,
                  onTap: () {
                    onContentSelected(const _HomeSkillListSelection());
                  },
                ),
                _buildLeafNavItem(
                  context,
                  icon: RevericIcons.groups_outlined,
                  title: context.t(LocaleKeys.agentStudioExpertTeam),
                  isSelected: expertTeamSelected,
                  onTap: () {
                    onContentSelected(const _HomeExpertTeamSelection());
                  },
                ),
                _buildLeafNavItem(
                  context,
                  icon: RevericIcons.hub_outlined,
                  title: context.t(LocaleKeys.settingsMcp),
                  isSelected: selection is _HomeMcpSelection,
                  onTap: () {
                    onContentSelected(const _HomeMcpSelection());
                  },
                ),
                const SizedBox(height: RevericSpacing.md),
                // Section 4: 对话
                _buildSectionGroupHeader(
                  context,
                  title: context.t(LocaleKeys.homeSectionChat),
                ),
                _buildLeafNavItem(
                  context,
                  icon: RevericIcons.rocket_launch_outlined,
                  title: context.t(LocaleKeys.agentShortcutTitle),
                  isSelected: shortcutsSelected,
                  onTap: () {
                    onContentSelected(const _HomeShortcutActionListSelection());
                  },
                ),
                // 最近对话（对话 section 末尾）
                if (recentSessions.isNotEmpty) ...[
                  _buildCollapsibleSectionHeader(
                    context,
                    icon: RevericIcons.chat_bubble_outline,
                    title: context.t(LocaleKeys.homeRecentSessions),
                    isExpanded: sessionsExpanded.value,
                    onToggle: () =>
                        sessionsExpanded.value = !sessionsExpanded.value,
                  ),
                  if (sessionsExpanded.value) ...[
                    const SizedBox(height: RevericSpacing.xxs),
                    ...recentSessions.map(
                      (session) => _buildSessionItem(
                        context,
                        ref,
                        session,
                        () async {
                          if (!context.mounted) {
                            return;
                          }
                          final db = ref.read(appDatabaseProvider);
                          final novel = await db.novelDao.get(session.novelId);
                          if (novel != null && context.mounted) {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => WorkspaceEditorPage(
                                  novelId: novel.id,
                                  initialSessionId: session.id,
                                  openChatOnEntry: true,
                                ),
                              ),
                            );
                          }
                        },
                      ),
                    ),
                  ],
                ],
                // 插件页面：放在对话分区（含最近对话）之后，避免最近对话被归入插件。
                PluginPageNavigation(
                  builder: (context, views) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: RevericSpacing.md),
                      _buildSectionGroupHeader(
                        context,
                        title: context.t(LocaleKeys.settingsPlugins),
                      ),
                      for (final view in views)
                        _buildLeafNavItem(
                          context,
                          icon: pluginPageIcon,
                          title: view.title.resolve(
                            Localizations.localeOf(context),
                          ),
                          isSelected:
                              selection is _HomePluginPageSelection &&
                              selection.view.pluginId == view.pluginId &&
                              selection.view.id == view.id,
                          onTap: () {
                            onContentSelected(_HomePluginPageSelection(view));
                          },
                        ),
                    ],
                  ),
                ),
                // Section 5: 设置
                const SizedBox(height: RevericSpacing.md),
                _buildSectionGroupHeader(
                  context,
                  title: context.t(LocaleKeys.homeSectionSettings),
                ),
                _buildLeafNavItem(
                  context,
                  icon: RevericIcons.settings_outlined,
                  title: context.t(LocaleKeys.librarySettings),
                  onTap: onOpenSettings,
                ),
                _buildLeafNavItem(
                  context,
                  icon: RevericIcons.layers_outlined,
                  title: context.t(LocaleKeys.settingsPlugins),
                  isSelected: selection is _HomePluginsSelection,
                  onTap: () {
                    onContentSelected(const _HomePluginsSelection());
                  },
                ),
              ],
            ),
          ),
          const DesktopUpdateEntry(),
          Divider(height: 1, thickness: 1, color: colors.border),
          const Padding(
            padding: EdgeInsets.fromLTRB(
              RevericSpacing.x2l,
              RevericSpacing.md,
              RevericSpacing.x2l,
              0,
            ),
            child: CommunityRow(),
          ),
          const UserProfileBar(),
        ],
      ),
    );
  }

  Widget _buildSectionGroupHeader(
    BuildContext context, {
    required String title,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.x2l,
        RevericSpacing.lg,
        RevericSpacing.x2l,
        RevericSpacing.xxs,
      ),
      child: Text(
        title,
        style: typo.uiTinySemibold.copyWith(
          color: colors.textMuted,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildLeafNavItem(
    BuildContext context, {
    required String icon,
    required String title,
    bool isSelected = false,
    required VoidCallback onTap,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.sm),
      child: Material(
        color: isSelected ? colors.selected : Colors.transparent,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        child: InkWell(
          onTap: onTap,
          hoverColor: colors.hover,
          borderRadius: BorderRadius.circular(RevericRadius.medium),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.lg,
              vertical: RevericSpacing.md,
            ),
            child: Row(
              children: [
                RevericIcon(
                  icon,
                  size: 16,
                  color: isSelected ? colors.accent : colors.textMuted,
                ),
                const SizedBox(width: RevericSpacing.sm),
                Expanded(
                  child: Text(
                    title,
                    style: (isSelected ? typo.uiSemibold : typo.ui).copyWith(
                      color: isSelected
                          ? colors.textPrimary
                          : colors.textSecondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                RevericIcon(
                  RevericIcons.keyboard_arrow_right,
                  size: 18,
                  color: isSelected ? colors.accent : colors.textSubtle,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCollapsibleSectionHeader(
    BuildContext context, {
    required String icon,
    required String title,
    required bool isExpanded,
    required VoidCallback onToggle,
    Widget? trailing,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.sm),
      child: InkWell(
        onTap: onToggle,
        hoverColor: colors.hover,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.lg,
            vertical: RevericSpacing.md,
          ),
          child: Row(
            children: [
              RevericIcon(icon, size: 16, color: colors.textMuted),
              const SizedBox(width: RevericSpacing.sm),
              Text(title, style: typo.ui.copyWith(color: colors.textSecondary)),
              const Spacer(),
              if (trailing != null) ...[
                trailing,
                const SizedBox(width: RevericSpacing.sm),
              ],
              AnimatedRotation(
                turns: isExpanded ? 0.25 : 0,
                duration: const Duration(milliseconds: 200),
                child: RevericIcon(
                  RevericIcons.keyboard_arrow_right,
                  size: 18,
                  color: colors.textSubtle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSessionItem(
    BuildContext context,
    WidgetRef ref,
    AiChatSession session,
    VoidCallback onTap,
  ) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final title = session.title.trim().isEmpty
        ? context.t(LocaleKeys.homeWritingAssistant)
        : session.title;
    final mode = AiSessionMode.fromString(session.mode);
    final isProcessing = ref.watch(
      aiSessionProcessingProvider(mode: mode, sessionId: session.id),
    );
    final subtitle = isProcessing
        ? context.t(LocaleKeys.aiSessionProcessingBackground)
        : _formatSessionTime(context, session.updatedAt);

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: InkWell(
        onTap: onTap,
        hoverColor: colors.hover,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.x2l,
            vertical: RevericSpacing.xs,
          ),
          child: Row(
            children: [
              if (isProcessing)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    valueColor: AlwaysStoppedAnimation<Color>(colors.textMuted),
                  ),
                )
              else
                RevericIcon(
                  RevericIcons.chat_bubble_outline,
                  size: 14,
                  color: colors.textSubtle,
                ),
              const SizedBox(width: RevericSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: typo.uiSmall.copyWith(color: colors.textSecondary),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      subtitle,
                      style: typo.uiTiny.copyWith(
                        color: isProcessing ? colors.accent : colors.textMuted,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatSessionTime(BuildContext context, DateTime when) {
    final now = DateTime.now();
    final date = DateTime(when.year, when.month, when.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(date).inDays;
    if (diff == 0) {
      final hh = when.hour.toString().padLeft(2, '0');
      final mm = when.minute.toString().padLeft(2, '0');
      return context.t(LocaleKeys.homeToday, namedArgs: {'time': '$hh:$mm'});
    }
    if (diff == 1) return context.t(LocaleKeys.homeYesterday);
    if (diff < 7) {
      return context.t(LocaleKeys.homeDaysAgo, namedArgs: {'count': '$diff'});
    }
    return '${when.year}-${when.month.toString().padLeft(2, '0')}-${when.day.toString().padLeft(2, '0')}';
  }

  Future<void> createDemoNovelWithNavigation(
    BuildContext context,
    WidgetRef ref, {
    BuildContext? feedbackContext,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final errorContext = feedbackContext ?? context;
    final errorMessenger = ScaffoldMessenger.of(errorContext);
    final navigator = Navigator.of(context);
    try {
      final database = ref.read(appDatabaseProvider);
      final novelId = await createDemoNovel(database);
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(context.t(LocaleKeys.libraryCreateDemoNovelSuccess)),
        ),
      );
      navigator.push(
        MaterialPageRoute(
          builder: (_) => WorkspaceEditorPage(novelId: novelId),
        ),
      );
    } catch (error) {
      if (!errorContext.mounted) {
        return;
      }
      errorMessenger.showSnackBar(
        SnackBar(
          content: Text(context.t(LocaleKeys.libraryCreateDemoNovelFailed)),
        ),
      );
    }
  }
}

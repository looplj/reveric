// 职责: 桌面端 AI 聊天面板 — 处理会话恢复、消息发送、工具调用、会话持久化与自动贴底滚动。
// 关联文件:
//   lib/shared/widgets/ai/chat/session_next_action_bar.dart
//   lib/shared/heuristic/chat_next_action.dart
//   lib/shared/widgets/ai/chat/ui_message.dart
//   lib/shared/widgets/ai/chat/auto_scroll_hook.dart
//   lib/shared/widgets/ai/chat/chat_send_completion_guard.dart
//   lib/shared/services/ai/chat.dart
//   lib/shared/services/ai/session_persistence.dart
//   lib/shared/providers/ai_providers.dart
//   lib/desktop/widgets/agent_management/agent_model_settings_page.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/text-input-ime.md
import 'dart:async';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../shared/logger/app_logger.dart';
import '../../../../shared/localization/app_localization.dart';
import '../../../../shared/localization/locale_keys.dart';
import '../../../../shared/models/ai_chat_models.dart';
import '../../../../shared/models/ai_provider.dart';
import '../../../../shared/models/ai_session_mode.dart';
import '../../../../shared/models/agent_profile.dart';
import '../../../../shared/models/novel_workspace.dart';
import '../../../../shared/models/subagent.dart';
import '../../../../shared/models/agent_skill.dart';
import '../../../../shared/models/slash_entry.dart';
import '../../../../shared/models/agent_rule.dart';
import '../../../../shared/database/app_database.dart' show Novel;
import '../../../../shared/database/novel_content_database.dart';
import '../../../../shared/providers/ai_providers.dart';
import '../../../../shared/providers/agent_rule_providers.dart';
import '../../../../shared/providers/chat_continue_offer_provider.dart';
import '../../../../shared/providers/prompt_template_provider.dart';
import '../../../../shared/services/ai/prompts/ai_prompt_service.dart';
import '../../../../shared/providers/settings_providers.dart';
import '../../../../shared/heuristic/chat_next_action.dart';
import '../../../../shared/models/feature_id.dart';
import '../../../../shared/providers/novel_providers.dart';
import '../../../../shared/providers/subagent_providers.dart';
import '../../../../shared/providers/agent_skill_providers.dart';
import '../../../../shared/providers/ai_mode_processing.dart';
import '../../../../shared/agent/agent.dart';
import '../../../../shared/services/ai/chat_attachments.dart';
import '../../../../shared/services/ai/chat_session_controller.dart';
import '../../../../shared/services/ai/handoff_service.dart';
import '../../../../shared/services/ai/chat_prompt_builder.dart';
import '../../../../shared/services/ai/context_message_matcher.dart';
import '../../../../shared/theme/theme.dart';
import '../../../../shared/hooks/use_text_input_recovery.dart';
import '../../../../shared/utils/text_input_composing.dart';
import '../../../../shared/widgets/app_background.dart';
import '../../../../shared/widgets/ai/chat/background_agents.dart';
import '../../../../shared/widgets/ai/chat/tool_operation_strip.dart';
import '../../../../shared/models/tool_permission.dart';
import '../../../../shared/widgets/ai/tool_permission_editor.dart';
import 'package:reveric/shared/widgets/ai/chat/auto_scroll_hook.dart';
import 'package:reveric/shared/widgets/ai/tool_approval_card.dart';
import 'package:reveric/shared/widgets/ai/chat/chat_send_completion_guard.dart';
import 'package:reveric/shared/widgets/ai/chat/assistant_empty_state.dart';
import 'package:reveric/shared/widgets/ai/chat/chat_message_view.dart';
import 'package:reveric/shared/widgets/ai/chat/continue_session_offer_bar.dart';
import 'package:reveric/shared/widgets/ai/chat/session_next_action_bar.dart';
import 'package:reveric/shared/widgets/ai/chat/feedback_dialog.dart';
import 'package:reveric/shared/widgets/ai/chat/message_action_confirm_dialog.dart';
import 'package:reveric/shared/widgets/ai/chat/ui_message.dart';
import 'state.dart';
import 'header.dart';
import 'config_hint.dart';
import 'composer.dart';
import '../diff/pending_changes_summary_card.dart';
import 'chat_onboarding_bubble.dart';
import '../../agent_management/agent_model_settings_page.dart';
import 'package:reveric/shared/widgets/ai/chat/todo_panel.dart';

import 'handoff_activation.dart';

part 'models.dart';
part 'message_mapping.dart';
part 'message_renderer.dart';
part 'agent_factory.dart';
part 'context_loader.dart';
part 'agent_selection.dart';
part 'runtime.dart';
part 'handoff.dart';

final _log = AppLogger.forModule('ChatPanel');

class AiChatPanel extends HookConsumerWidget {
  final VoidCallback? onClose;
  final Novel novel;
  String get novelId => novel.id;
  String get novelName => novel.title;
  String get novelDescription => novel.description;
  bool get novelDraft => novel.draft;
  final String? chapterId;
  final String? chapterTitle;
  final int? chapterNumber;
  final String? databasePath;
  final NovelWorkspaceSection? workspaceSection;
  final String? workspaceItemId;
  final String? workspaceTitle;
  final String? workspaceContent;
  final String? workspaceMetaTitle;
  final String? workspaceMetaContent;
  String get contentKind => novel.contentKind;
  final String? currentSeasonId;
  final String? currentEpisodeId;
  final bool hasMultipleSeasons;
  final Future<void> Function(String content)? onApplyGeneratedContent;
  final String? activeSessionId;
  final Future<void> Function()? onRequestNewSession;
  final ValueChanged<bool>? onEditingStateChanged;

  /// 应用到指定角色头像。`characterId` 来自生成该图片的 image 命令，
  /// 而非当前选中项，确保 apply 到对应对象。
  final Future<void> Function(String assetId, String characterId)?
  onSetAsAvatar;

  /// 添加照片到指定角色或物品。二者至少其一非空（由 image 命令决定）。
  final Future<void> Function(
    String assetId, {
    String? characterId,
    String? itemId,
  })?
  onAddPhoto;

  /// Optional input placeholder. Defaults to the chat placeholder when
  /// `null`.
  final String? composerHint;

  final AiChatDraftMessage? draftMessage;
  final AiChatHandoffDraft? handoffDraft;
  final ValueChanged<AiChatHandoffDraft>? onRequestHandoff;
  final AiChatShortcutDraft? shortcutDraft;
  final ValueChanged<String>? onHandoffDraftConsumed;
  final ValueChanged<String>? onShortcutDraftConsumed;

  /// When true, the panel renders in expanded mode (without internal TodoPanel
  /// or PendingChanges, which are handled by the parent ExpandedChatArea).
  final bool isExpanded;

  /// Callback invoked when the user taps the expand button in the chat header.
  final VoidCallback? onExpand;

  /// Whether the header should clear Windows caption buttons (side panel is
  /// rightmost): uses top inset on Windows. Expanded layouts pass false when
  /// a sibling panel owns that space.
  final bool avoidWindowCaption;

  /// 浮在画布上的外壳（见 floating.dart）：不避让窗口按钮，[onClose] 收成悬浮球。
  final bool floating;

  /// Callback invoked when a session is automatically restored from persistence.
  /// The parameter is the restored session id.
  final ValueChanged<String>? onSessionRestored;

  /// Callback invoked when the active session id changes (including when
  /// a new session is created or loaded).
  final Future<void> Function(String?)? onActiveSessionIdChanged;

  /// Callback invoked when a handoff source-session chip is clicked.
  final Future<void> Function(String sessionId, AiSessionMode mode)?
  onOpenSessionReference;

  /// 当前 chat onboarding 引导步骤：0 = 隐藏，1..3 = 面板，4 = 页面级 overlay。
  final int onboardingStep;

  /// 进入下一步引导的回调。
  final VoidCallback? onOnboardingNext;

  /// 关闭并持久化引导状态的回调。
  final VoidCallback? onOnboardingDismiss;

  /// 跳到指定功能（圆桌 / 小剧场 / 封面工作台），`seedText` 预填目标输入框。
  ///
  /// 为 null 表示宿主不提供跳转能力：SuggestNextAction 不下发，空态目录里的
  /// 跳转项也会被过滤掉。
  final void Function(FeatureId feature, String? seedText)? onOpenFeature;

  /// 外部传入的 composer 焦点节点。设置后,外部可通过 `requestFocus()`
  /// 聚焦输入框(如画布页「AI 共创」按钮)。为 null 时面板自建焦点节点。
  final FocusNode? composerFocusNode;

  const AiChatPanel({
    super.key,
    this.onClose,
    required this.novel,
    this.chapterId,
    this.chapterTitle,
    this.chapterNumber,
    this.databasePath,
    this.workspaceSection,
    this.workspaceItemId,
    this.workspaceTitle,
    this.workspaceContent,
    this.workspaceMetaTitle,
    this.workspaceMetaContent,
    this.currentSeasonId,
    this.currentEpisodeId,
    this.hasMultipleSeasons = false,
    this.onApplyGeneratedContent,
    this.activeSessionId,
    this.onRequestNewSession,
    this.onEditingStateChanged,
    this.onSetAsAvatar,
    this.onAddPhoto,
    this.composerHint,
    this.draftMessage,
    this.handoffDraft,
    this.onRequestHandoff,
    this.shortcutDraft,
    this.onHandoffDraftConsumed,
    this.onShortcutDraftConsumed,
    this.isExpanded = false,
    this.onExpand,
    this.avoidWindowCaption = true,
    this.floating = false,
    this.onSessionRestored,
    this.onActiveSessionIdChanged,
    this.onOpenSessionReference,
    this.onboardingStep = 0,
    this.onOnboardingNext,
    this.onOnboardingDismiss,
    this.onOpenFeature,
    this.composerFocusNode,
  }) : assert(
         onOpenFeature == null ||
             (onRequestHandoff != null && onActiveSessionIdChanged != null),
         'Suggestion navigation requires handoff and session-selection callbacks.',
       );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final appBackgroundActive = ref.watch(appBackgroundActiveProvider);
    final sessionChrome = ref.watch(
      aiChatSessionProvider(activeSessionId).select(
        (session) => (
          sessionId: session.sessionId,
          title: session.title,
          providerId: session.providerId,
          model: session.model,
          reasoningEffort: session.reasoningEffort,
          sessionMode: session.sessionMode,
          agentSlug: session.agentSlug,
          isLoaded: session.isLoaded,
        ),
      ),
    );
    final sessionState = AiChatSessionState(
      sessionId: sessionChrome.sessionId,
      title: sessionChrome.title,
      providerId: sessionChrome.providerId,
      model: sessionChrome.model,
      reasoningEffort: sessionChrome.reasoningEffort,
      sessionMode: sessionChrome.sessionMode,
      agentSlug: sessionChrome.agentSlug,
      isLoaded: sessionChrome.isLoaded,
    );
    final runtimeSessionId = sessionState.sessionId ?? activeSessionId;
    final runtimeState = ref.watch(aiChatRuntimeProvider(runtimeSessionId));
    // messages 的订阅已下沉到 _ChatMessageListArea：streaming delta 到达时
    // 只重建消息列表区，header / TodoPanel / composer 不再逐 delta 陪跑。
    useEffect(() {
      final sid = runtimeSessionId;
      if (sid == null || sid.isEmpty || sid.startsWith('__new__')) {
        return null;
      }
      final tracker = ref.read(aiModeProcessingTrackerProvider.notifier);
      tracker.setForegroundSession(
        mode: AiSessionMode.chat,
        sessionId: sid,
        foreground: true,
      );
      return () {
        tracker.setForegroundSession(
          mode: AiSessionMode.chat,
          sessionId: sid,
          foreground: false,
        );
      };
    }, [runtimeSessionId]);
    final sessionChangesAsync = databasePath != null && databasePath!.isNotEmpty
        ? ref.watch(sessionChangesProvider(databasePath!, activeSessionId))
        : const AsyncValue<List<WorkingChange>>.loading();
    final pendingAiChanges =
        sessionChangesAsync.asData?.value ?? const <WorkingChange>[];
    final isCreatingSession = useRef(false);
    final requestNewSession = onRequestNewSession == null
        ? null
        : () {
            if (isCreatingSession.value) {
              return;
            }
            isCreatingSession.value = true;
            // 直接新建，不再先问「新对话 / 延续」：延续降级成新会话里的一次性
            // 提议条。宿主不提供 handoff 能力时提议点了也没用，不下发。
            if (onRequestHandoff != null) {
              final sourceTitle = sessionState.title.trim();
              unawaited(
                ref
                    .read(chatContinueOfferProvider.notifier)
                    .offerAfterNewSession(
                      novelId: novelId,
                      sourceSessionId:
                          sessionState.sessionId ?? activeSessionId,
                      sourceTitle: sourceTitle.isEmpty
                          ? context.t(LocaleKeys.aiSessionTitleDefault)
                          : sourceTitle,
                      databasePath: databasePath,
                    ),
              );
            }
            unawaited(() async {
              try {
                await onRequestNewSession!();
              } catch (error, stackTrace) {
                _log.error(
                  'request new session failed activeSessionId=$activeSessionId',
                  error: error,
                  stackTrace: stackTrace,
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(context.t(LocaleKeys.aiRequestFailed)),
                    ),
                  );
                }
              } finally {
                isCreatingSession.value = false;
              }
            }());
          };
    final isConfigured = ref.watch(isAiConfiguredProvider);
    final availableModels = ref.watch(availableAiModelsProvider);
    final defaultChatModelOptionId = ref.watch(
      defaultAiModelOptionIdProvider(AiModelKind.chat),
    );
    final s = useAiChatPanelState(
      ref: ref,
      databasePath: databasePath,
      pendingAiChanges: pendingAiChanges,
      isAgentTurnActive: runtimeState.isEditing,
      composerFocusNode: composerFocusNode,
    );
    // 窗口重获焦点时重建文本输入连接，恢复被 embedder 静默卡死的中文输入法。
    useTextInputConnectionRecovery(
      focusNode: s.composerFocusNode,
      controller: s.composerController,
    );
    final providerContainer = ProviderScope.containerOf(context, listen: false);
    useEffect(
      () {
        final runtime = providerContainer.read(
          aiChatRuntimeProvider(runtimeSessionId).notifier,
        );
        final stagedMessage = runtime.pendingNextTurnMessage;
        final visibleMessage = s.queuedMessages.forSession(runtimeSessionId);
        if (stagedMessage != null) {
          // 侧栏与展开聊天会在切换时重建；队列的真源在 session runtime，重建后的
          // panel 据此恢复横幅，不能把「下一轮发送」悄悄变成后台操作。
          s.queuedMessages.setForSession(runtimeSessionId, stagedMessage);
        } else if (visibleMessage?.sendOnNextTurn == true) {
          // Agent 已消费/取消 staged 消息时，旧 panel 的回调可能已经卸载；由当前
          // panel 观察 runtime 状态完成横幅收尾。
          s.queuedMessages.setForSession(runtimeSessionId, null);
        }
        return null;
      },
      [
        providerContainer,
        runtimeSessionId,
        runtimeState.hasPendingNextTurnMessage,
        s.queuedMessages,
      ],
    );
    final onEditingStateChangedRef = useRef(onEditingStateChanged);
    onEditingStateChangedRef.value = onEditingStateChanged;
    final onSessionRestoredRef = useRef(onSessionRestored);
    onSessionRestoredRef.value = onSessionRestored;
    final onHandoffDraftConsumedRef = useRef(onHandoffDraftConsumed);
    onHandoffDraftConsumedRef.value = onHandoffDraftConsumed;
    final onShortcutDraftConsumedRef = useRef(onShortcutDraftConsumed);
    onShortcutDraftConsumedRef.value = onShortcutDraftConsumed;

    final promptBuilder = useMemoized(
      () => ChatPromptBuilder(
        workspaceTitle: workspaceTitle,
        workspaceContent: workspaceContent,
        workspaceMetaTitle: workspaceMetaTitle,
        workspaceMetaContent: workspaceMetaContent,
        workspaceSection: workspaceSection,
        workspaceItemId: workspaceItemId,
      ),
      [
        workspaceTitle,
        workspaceContent,
        workspaceMetaTitle,
        workspaceMetaContent,
        workspaceSection,
        workspaceItemId,
      ],
    );
    final aiPromptService = ref.read(aiPromptServiceProvider);
    final mergedSubAgents = ref.watch(mergedSubAgentsProvider);
    final availableSubAgents = _runtimeChatSubAgents(mergedSubAgents);
    final userVisibleSubAgents = _userVisibleChatSubAgents(mergedSubAgents);
    // slash 面板只展示用户已安装且可执行的技能。
    final slashSkills =
        ref.watch(chatSlashSkillsProvider).asData?.value ??
        const <SkillDefinition>[];
    // 输入监听器只注册一次，通过 ref 读取最新候选，避免导入技能后
    // listener 仍捕获旧列表。
    final slashAgentsRef = useRef<List<SubAgent>>(userVisibleSubAgents);
    slashAgentsRef.value = userVisibleSubAgents;
    final slashSkillsRef = useRef<List<SkillDefinition>>(slashSkills);
    slashSkillsRef.value = slashSkills;
    final slashCandidateKeys = <Object?>[
      for (final agent in userVisibleSubAgents) ...[
        agent.id,
        agent.name,
        agent.enabled,
        agent.description,
        agent.prompt,
      ],
      for (final skill in slashSkills) ...[
        skill.id,
        skill.name,
        skill.description,
      ],
    ];
    final settings = ref.watch(appSettingsProvider).asData?.value;
    final agentRules = databasePath == null || databasePath!.isEmpty
        ? const <AgentRule>[]
        : ref.watch(agentRulesStreamProvider(databasePath!)).asData?.value ??
              const <AgentRule>[];
    final novelChatSessionCount = ref
        .watch(
          novelChatSessionCountProvider(
            novelId: novelId,
            databasePath: databasePath,
          ),
        )
        .asData
        ?.value;

    final promptContext = _buildPromptContext(
      promptBuilder: promptBuilder,
      username: settings?.username ?? '',
      userRules: _formatAgentRules(agentRules),
      novelChatSessionCount: novelChatSessionCount,
    );
    void runProviderWriteAfterBuild(VoidCallback action) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        action();
      });
    }

    void refreshSlashSuggestions() {
      final value = s.composerController.text.trimLeft();
      if (value.contains('\n') || !value.startsWith('/')) {
        s.slashMatches.value = const [];
        s.slashIndex.value = 0;
        return;
      }
      final commandPart = value.split(' ').first.toLowerCase();
      bool matchesPrefix(String name) =>
          '/${name.toLowerCase().replaceAll(' ', '_')}'.startsWith(commandPart);
      final matches = <SlashEntry>[
        for (final agent in slashAgentsRef.value)
          if (agent.enabled && matchesPrefix(agent.name))
            SlashEntry(
              kind: SlashEntryKind.subagent,
              id: agent.id,
              label: agent.name,
              description: agent.description.trim().isNotEmpty
                  ? agent.description.trim()
                  : agent.prompt.trim(),
              icon: RevericIcons.smart_toy_outlined,
            ),
        for (final skill in slashSkillsRef.value)
          if (matchesPrefix(skill.name))
            SlashEntry(
              kind: SlashEntryKind.skill,
              id: skill.id,
              label: skill.name,
              description: skill.description.trim(),
              icon: RevericIcons.lightning,
            ),
      ];
      s.slashMatches.value = matches;
      if (matches.isEmpty) {
        s.slashIndex.value = 0;
      } else if (s.slashIndex.value >= matches.length) {
        s.slashIndex.value = 0;
      }
    }

    useOnListenableChange(s.composerController, refreshSlashSuggestions);

    // 会话元数据即时落库；消息 debounce 落库，流式结束后立即 flush。
    useEffect(() {
      final dbPath = databasePath;
      final nid = novelId;
      Timer? messageSaveTimer;
      AiChatSessionState? pendingMessageSaveSession;
      var saveGeneration = 0;

      Future<void> persistSession({
        required AiChatSessionState session,
        bool includeMessages = true,
        bool syncMessages = true,
      }) async {
        final sid = session.sessionId;
        if (dbPath == null ||
            dbPath.isEmpty ||
            sid == null ||
            !session.isLoaded) {
          return;
        }
        if (sid.startsWith('__new__') || sid.startsWith('__handoff')) {
          return;
        }
        final generation = ++saveGeneration;
        final persistence = providerContainer.read(
          aiSessionPersistenceServiceProvider(
            novelId: nid,
            databasePath: dbPath,
          ),
        );
        try {
          await persistence.upsertSession(
            id: sid,
            title: session.title,
            provider: session.providerId,
            model: session.model,
            mode: session.sessionMode.value,
            agentSlug: session.agentSlug,
            reasoningEffort: session.reasoningEffort,
          );
          if (!includeMessages || session.messages.isEmpty) {
            return;
          }
          if (generation != saveGeneration) {
            return;
          }
          final contextSnapshot = providerContainer
              .read(aiChatRuntimeProvider(sid).notifier)
              .agent
              ?.contextManager
              .snapshot();
          final novelDb = providerContainer.read(
            novelContentDatabaseProvider(dbPath),
          );
          if (syncMessages) {
            await persistence.saveMessages(
              sessionId: sid,
              messages: session.messages,
              novelDatabase: novelDb,
              contextSnapshot: contextSnapshot,
            );
          } else {
            await persistence.upsertCompletedMessages(
              sessionId: sid,
              messages: session.messages,
              novelDatabase: novelDb,
              contextSnapshot: contextSnapshot,
            );
          }
        } catch (error, stackTrace) {
          _log.error(
            'persist failed sessionId=$sid',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }

      void scheduleMessageSave(AiChatSessionState session) {
        pendingMessageSaveSession = session;
        messageSaveTimer?.cancel();
        messageSaveTimer = Timer(const Duration(milliseconds: 800), () {
          final pending = pendingMessageSaveSession;
          if (pending == null) {
            return;
          }
          unawaited(persistSession(session: pending, includeMessages: true));
        });
      }

      bool hasActiveToolCalls(List<AiMessage> messages) {
        for (final message in messages) {
          for (final block in message.blocks) {
            if (block is! AiToolCallBlock) {
              continue;
            }
            if (block.status == AiToolCallStatus.pending ||
                block.status == AiToolCallStatus.running) {
              return true;
            }
          }
        }
        return false;
      }

      final removeListener = ref.listenManual(
        aiChatSessionProvider(activeSessionId),
        (previous, next) {
          if (dbPath == null || dbPath.isEmpty) {
            return;
          }
          if (!next.isLoaded) {
            return;
          }

          final metaChanged =
              previous == null ||
              previous.sessionId != next.sessionId ||
              previous.title != next.title ||
              previous.providerId != next.providerId ||
              previous.model != next.model ||
              previous.sessionMode != next.sessionMode ||
              previous.agentSlug != next.agentSlug;

          if (metaChanged) {
            unawaited(persistSession(session: next, includeMessages: false));
          }

          if (next.messages.isEmpty) {
            messageSaveTimer?.cancel();
            return;
          }

          final isStreaming = next.messages.any(
            (message) => message.isStreaming,
          );
          if (isStreaming) {
            return;
          }
          if (hasActiveToolCalls(next.messages)) {
            return;
          }
          if (identical(previous?.messages, next.messages)) {
            return;
          }
          scheduleMessageSave(next);
        },
      );

      return () {
        messageSaveTimer?.cancel();
        final latest = providerContainer.read(
          aiChatSessionProvider(activeSessionId),
        );
        if (!latest.messages.any((message) => message.isStreaming) &&
            !hasActiveToolCalls(latest.messages)) {
          unawaited(persistSession(session: latest, includeMessages: true));
        }
        removeListener.close();
      };
    }, [activeSessionId, databasePath, novelId, providerContainer]);

    final defaultSessionTitle = context.t(LocaleKeys.aiSessionTitleDefault);

    // 加载会话（当外部要求切换 activeSessionId 时）
    useEffect(
      () {
        var cancelled = false;
        bool stale() => cancelled || !context.mounted;
        void cancel() {
          cancelled = true;
        }

        final dbPath = databasePath;
        final nid = novelId;
        final targetId = activeSessionId;
        if (dbPath == null || dbPath.isEmpty) {
          return null;
        }
        if (targetId == null) {
          // 没有指定会话时，只恢复 active session；若没有 active，则保持空会话状态。
          if (sessionState.isLoaded) return null; // 已经加载了会话
          final persistence = ref.read(
            aiSessionPersistenceServiceProvider(
              novelId: nid,
              databasePath: dbPath,
            ),
          );
          final novelDb = ref.read(novelContentDatabaseProvider(dbPath));
          Future(() async {
            try {
              final preferredSession = await persistence.getPreferredSession();
              if (stale() || preferredSession == null) return;
              final preferredState = providerContainer.read(
                aiChatSessionProvider(preferredSession.id),
              );
              if (preferredState.isLoaded) {
                onSessionRestoredRef.value?.call(preferredSession.id);
                return;
              }
              await persistence.activateSession(
                preferredSession.id,
                isCurrent: () => !stale(),
              );
              final persisted = await persistence.loadSessionMessages(
                sessionId: preferredSession.id,
                novelDatabase: novelDb,
              );
              if (stale()) return;
              providerContainer
                  .read(aiChatSessionProvider(preferredSession.id).notifier)
                  .loadSessionIfUnloaded(
                    sessionId: preferredSession.id,
                    title: preferredSession.title.isEmpty
                        ? defaultSessionTitle
                        : preferredSession.title,
                    messages: persisted.messages,
                    providerId: preferredSession.provider,
                    model: preferredSession.model,
                    persistedReasoningEffort: preferredSession.reasoningEffort,
                    sessionMode: AiSessionMode.fromString(
                      preferredSession.mode,
                    ),
                    agentSlug: _resolvePersistedAgentSlug(preferredSession),
                  );
              // 通知外部会话已恢复
              onSessionRestoredRef.value?.call(preferredSession.id);
            } catch (error, stackTrace) {
              _log.error(
                'Restore active chat failed',
                error: error,
                stackTrace: stackTrace,
              );
            }
          });
          return cancel;
        }
        if (_isDraftHandoffSessionSignal(targetId)) {
          return null;
        }
        if (targetId.startsWith('__new__')) {
          // 临时 signal 只表示 UI 草稿；首轮 send 会在构造 Runner/Agent 前
          // single-flight 物化真实会话。
          return null;
        }
        s.pendingLoadTarget.value = targetId;
        final persistence = ref.read(
          aiSessionPersistenceServiceProvider(
            novelId: nid,
            databasePath: dbPath,
          ),
        );
        final novelDb = ref.read(novelContentDatabaseProvider(dbPath));
        Future(() async {
          try {
            if (stale() || s.pendingLoadTarget.value != targetId) {
              if (_log.isDebugEnabled) {
                _log.debug(
                  'load-specific: STALE targetId=$targetId pending=${s.pendingLoadTarget.value}',
                );
              }
              return;
            }
            final session = await persistence.getSession(targetId);
            if (session == null) {
              return;
            }
            if (stale() || s.pendingLoadTarget.value != targetId) {
              if (_log.isDebugEnabled) {
                _log.debug(
                  'load-specific: STALE after getSession targetId=$targetId pending=${s.pendingLoadTarget.value}',
                );
              }
              return;
            }
            await persistence.activateSession(
              targetId,
              isCurrent: () => !stale(),
            );
            if (stale()) return;
            if (providerContainer
                .read(aiChatSessionProvider(targetId))
                .isLoaded) {
              return;
            }
            final persisted = await persistence.loadSessionMessages(
              sessionId: targetId,
              novelDatabase: novelDb,
            );
            if (stale()) return;
            if (_log.isDebugEnabled) {
              _log.debug(
                'load-specific: ${persisted.messages.length} messages',
              );
            }
            providerContainer
                .read(aiChatSessionProvider(targetId).notifier)
                .loadSessionIfUnloaded(
                  sessionId: targetId,
                  title: session.title,
                  messages: persisted.messages,
                  providerId: session.provider,
                  model: session.model,
                  persistedReasoningEffort: session.reasoningEffort,
                  sessionMode: AiSessionMode.fromString(session.mode),
                  agentSlug: _resolvePersistedAgentSlug(session),
                );
            if (_log.isDebugEnabled) {
              _log.debug('load-specific: hydration DONE sessionId=$targetId');
            }
          } catch (error, stackTrace) {
            _log.error(
              'Load selected chat failed',
              error: error,
              stackTrace: stackTrace,
            );
          }
        });
        return cancel;
      },
      [
        activeSessionId,
        databasePath,
        novelId,
        sessionState.sessionId,
        sessionState.isLoaded,
        availableModels,
        defaultChatModelOptionId,
      ],
    );

    // 当章节变化时更新上下文
    useEffect(
      () {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          ref
              .read(aiSessionContextNotifierProvider.notifier)
              .updateContext(_buildPanelContext());
          if (chapterId != null) {
            ref.read(chapterWritingProvider.notifier).startWriting(chapterId!);
          }
        });
        return null;
      },
      [
        chapterId,
        chapterTitle,
        databasePath,
        novelId,
        novelName,
        workspaceSection,
        workspaceItemId,
        workspaceTitle,
        workspaceContent,
        workspaceMetaTitle,
        workspaceMetaContent,
        contentKind,
        currentSeasonId,
        currentEpisodeId,
        hasMultipleSeasons,
      ],
    );

    useEffect(() {
      final isEditing = runtimeState.isEditing;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        onEditingStateChangedRef.value?.call(isEditing);
      });
      return null;
    }, [runtimeState.isEditing]);

    useEffect(() {
      return () {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          onEditingStateChangedRef.value?.call(false);
        });
      };
    }, const []);

    // 面板卸载（折叠 / 返回离开编辑器）时：普通排队随 UI 状态销毁；若所属会话的
    // agent 仍在跑，提升为下一轮 stage，由 keepAlive 的 turn 续发（与「立即发送」同路）。
    // s / providerContainer 在面板生命周期内稳定，const [] cleanup 可安全捕获。
    useEffect(() {
      final panelState = s;
      final container = providerContainer;
      return () {
        for (final queued in panelState.queuedMessages.all) {
          promoteQueuedMessageForSurvivingTurn(
            container: container,
            queued: queued,
          );
        }
      };
    }, const []);

    useEffect(() {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          refreshSlashSuggestions();
        }
      });
      return null;
    }, slashCandidateKeys);

    useEffect(() {
      final shouldShowSlashMenu = s.slashMatches.value.isNotEmpty;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        if (shouldShowSlashMenu) {
          s.slashMenuController.show();
        } else if (s.slashMenuController.isShowing) {
          s.slashMenuController.hide();
        }
      });
      return null;
    }, [s.slashMatches.value.isNotEmpty, s.slashMenuController]);

    useEffect(() {
      final draft = draftMessage;
      if (draft == null || s.consumedDraftId.value == draft.id) {
        return null;
      }
      s.consumedDraftId.value = draft.id;
      writeControllerTextAfterComposing(
        s.composerController,
        (_) => draft.text,
      );
      if (draft.autoSend) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          s.userScrolledUp.value = false;
          _handleSendMessage(
            context,
            ref,
            draft.text,
            state: s,
            availableSubAgents: availableSubAgents,
            promptContext: promptContext,
            promptBuilder: promptBuilder,
            aiPromptService: aiPromptService,
          );
        });
      } else {
        s.composerFocusNode.requestFocus();
      }
      return null;
    }, [draftMessage]);

    useEffect(() {
      final draft = shortcutDraft;
      if (draft == null || s.consumedDraftId.value == draft.id) {
        return null;
      }
      s.consumedDraftId.value = draft.id;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) {
          return;
        }
        final currentText = s.composerController.text;
        final nextText = draft.text.trim().isEmpty
            ? currentText
            : currentText.trim().isEmpty
            ? draft.text
            : '$currentText\n\n${draft.text}';
        // 这里保持即时计算：下面 autoSend 分支要用同一个 nextText 发送，发送语义不能变。
        // 仅把「赋值」做成组词安全的，避免清空 composing 触发 discardMarkedText。
        writeControllerTextAfterComposing(
          s.composerController,
          (_) => nextText,
        );
        if (draft.references.isNotEmpty) {
          final references = <AiContextReference>[
            ...s.attachedReferences.value,
          ];
          for (final reference in draft.references) {
            if (!references.contains(reference)) {
              references.add(reference);
            }
          }
          s.attachedReferences.value = references;
        }
        onShortcutDraftConsumedRef.value?.call(draft.id);
        if (draft.autoSend && !runtimeState.isRequestInFlight) {
          s.userScrolledUp.value = false;
          _handleSendMessage(
            context,
            ref,
            nextText,
            state: s,
            availableSubAgents: availableSubAgents,
            promptContext: promptContext,
            promptBuilder: promptBuilder,
            aiPromptService: aiPromptService,
          );
        } else {
          s.composerFocusNode.requestFocus();
        }
      });
      return null;
    }, [shortcutDraft]);

    final incomingHandoff = handoffDraft;
    final handoffTarget = incomingHandoff == null
        ? null
        : incomingHandoff.needsSourceValidation
        ? activeSessionId
        : _isDraftHandoffSessionSignal(incomingHandoff.id)
        ? incomingHandoff.id
        : _draftHandoffSessionSignal(
            incomingHandoff.id,
            builtinAgentSlugOrchestrator,
          );
    useHandoffActivation(
      requestId: incomingHandoff?.id,
      targetSessionId: handoffTarget,
      activeSessionId: activeSessionId,
      onSelectSession: onActiveSessionIdChanged,
      onReady: () {
        final draft = incomingHandoff!;
        if (draft.needsSourceValidation) {
          unawaited(_continueSession(context, ref, s, draft.sourceSessionId!));
          onHandoffDraftConsumedRef.value?.call(draft.id);
          return;
        }
        s.attachedReferences.value = draft.references.isNotEmpty
            ? draft.references
            : const [];
        if (draft.references.isNotEmpty || draft.initialText != null) {
          final handoffBody = draft.content.trim();
          final seededComposer = draft.initialText?.trim() ?? '';
          final composerAlreadyHasHandoffBody =
              seededComposer.isNotEmpty &&
              handoffBody.isNotEmpty &&
              seededComposer == handoffBody;
          if (!composerAlreadyHasHandoffBody &&
              (draft.autoSend || handoffBody.isNotEmpty)) {
            if (draft.autoSend) {
              _log.debug('autoSend with refs — keeping pendingHandoff');
            }
            s.pendingHandoff.value = PendingChatHandoff(
              label: draft.label,
              content: draft.content,
              sourceSessionId: draft.sourceSessionId,
              sourceMode: draft.sourceMode,
            );
          } else {
            s.pendingHandoff.value = null;
          }
          final attachments = draft.files
              .map(
                (file) =>
                    s.composerController.register(ChatDraftAttachment(file)),
              )
              .join();
          writeControllerTextAfterComposing(
            s.composerController,
            (_) => '$attachments${draft.initialText ?? ''}',
          );
        } else {
          s.pendingHandoff.value = PendingChatHandoff(
            label: draft.label,
            content: draft.content,
            sourceSessionId: draft.sourceSessionId,
            sourceMode: draft.sourceMode,
          );
          // clear() 同样会把 composing 置空，必须走组词安全写入。
          writeControllerTextAfterComposing(s.composerController, (_) => '');
        }
        const targetAgentSlug = builtinAgentSlugOrchestrator;
        final draftSignal = _isDraftHandoffSessionSignal(draft.id)
            ? draft.id
            : _draftHandoffSessionSignal(draft.id, targetAgentSlug);
        ref
            .read(aiChatSessionProvider(draftSignal).notifier)
            .startNewSession(
              sessionId: draftSignal,
              title: draft.title,
              providerId: draft.providerId,
              model: draft.model,
              reasoningEffort: draft.reasoningEffort,
              sessionMode: AiSessionMode.chat,
              agentSlug: targetAgentSlug,
            );
        s.composerFocusNode.requestFocus();
        onHandoffDraftConsumedRef.value?.call(draft.id);
        if (draft.autoSend) {
          s.pendingAutoSendSessionId.value = draftSignal;
        } else {
          s.composerFocusNode.requestFocus();
        }
      },
    );

    useEffect(
      () {
        final pendingSessionId = s.pendingAutoSendSessionId.value;
        if (pendingSessionId == null ||
            pendingSessionId != activeSessionId ||
            !sessionState.isLoaded) {
          return null;
        }
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted ||
              s.pendingAutoSendSessionId.value != pendingSessionId) {
            return;
          }
          s.pendingAutoSendSessionId.value = null;
          s.userScrolledUp.value = false;
          _handleSendMessage(
            context,
            ref,
            s.composerController.text,
            state: s,
            availableSubAgents: availableSubAgents,
            promptContext: promptContext,
            promptBuilder: promptBuilder,
            aiPromptService: aiPromptService,
          );
        });
        return null;
      },
      [
        activeSessionId,
        sessionState.isLoaded,
        s.pendingAutoSendSessionId.value,
      ],
    );

    useEffect(
      () {
        if (availableModels.isEmpty) {
          return null;
        }
        final hasNoSelection =
            sessionState.providerId == null && sessionState.model == null;

        // 额度耗尽且当前仍选中 Reveric：空闲时自动切换到最近的可用（非 Reveric）模型。
        // 请求进行中不切换，避免 session 状态和已创建的 Agent/AiClient 分叉。

        if (!hasNoSelection) {
          return null;
        }
        final target = availableModels.firstWhere(
          (item) => item.id == defaultChatModelOptionId,
          orElse: () => availableModels.first,
        );
        // 没有其它可用模型（只剩被禁用的 Reveric）：保持现状，由输入框禁用发送并提示。
        if (target.providerId == sessionState.providerId &&
            target.model == sessionState.model) {
          return null;
        }
        runProviderWriteAfterBuild(() {
          ref
              .read(aiChatSessionProvider(activeSessionId).notifier)
              .selectModel(providerId: target.providerId, model: target.model);
        });
        return null;
      },
      [
        availableModels,
        defaultChatModelOptionId,
        sessionState.providerId,
        sessionState.model,
        runtimeState.isRequestInFlight,
      ],
    );

    final onboardingStep = this.onboardingStep;
    useEffect(() {
      if (onboardingStep == 2) {
        s.modelSelectorOpenTrigger.value++;
      }
      return null;
    }, [onboardingStep]);

    final onboardingActive = onboardingStep >= 1 && onboardingStep <= 2;
    final onboardingLink = switch (onboardingStep) {
      1 => s.composerInputLink,
      2 => s.modelSelectorLink,
      _ => s.composerInputLink,
    };
    final onboardingLeftOfTarget = onboardingStep == 2;
    final onboardingTail = onboardingLeftOfTarget
        ? OnboardingBubbleTail.rightCenter
        : OnboardingBubbleTail.bottomStart;
    final onboardingOffset = onboardingLeftOfTarget
        ? const Offset(0, -72)
        : const Offset(0, -4);
    final onboardingTitleKey = switch (onboardingStep) {
      2 => LocaleKeys.aiChatOnboardingModelTitle,
      _ => LocaleKeys.aiChatOnboardingTitle,
    };
    final onboardingMessageKey = switch (onboardingStep) {
      2 => LocaleKeys.aiChatOnboardingModelMessage,
      _ => LocaleKeys.aiChatOnboardingMessage,
    };
    // ── 下一步建议 ──────────────────────────────────────────────────────
    // 建议来自模型的 SuggestNextAction 调用；模型没挂就什么都不显示，
    // 不做本地兜底（空态目录除外，那是零调用时的引导）。
    final suggestionsEnabled = ref.watch(aiAgentNextActionSuggestionsProvider);
    final nextActionEnv = ChatNextActionEnvironment(
      suggestionsEnabled: suggestionsEnabled,
      hasCover: novel.coverAssetId != null,
      metadataReady:
          novel.title.trim().isNotEmpty && novel.description.trim().isNotEmpty,
      setupDone: !novel.draft,
    );
    // 宿主不提供跳转时过滤掉空态目录里的跳转项，避免点了没反应。
    final emptyActions = [
      for (final action in emptyStateActions(nextActionEnv))
        if (onOpenFeature != null || !action.isFeatureTarget) action,
    ];
    void handleNextAction(ChatNextAction action) {
      switch (action.target) {
        case PromptActionTarget(:final prompt, :final intent):
          if (intent == ChatNextActionIntent.new_chat ||
              intent == ChatNextActionIntent.continue_in_new_chat) {
            if (intent == ChatNextActionIntent.continue_in_new_chat) {
              onRequestHandoff!(
                AiChatHandoffDraft.fromContinuation(
                  buildSessionContinuationDraft(
                    workId: novelId,
                    sourceSessionId: runtimeSessionId!,
                    sourceTitle: sessionState.title,
                    sourceMode: sessionState.sessionMode,
                    initialText: prompt,
                    references: s.attachedReferences.value,
                    modelSelection: (
                      providerId:
                          s.pendingModelSelection.value?.providerId ??
                          sessionState.providerId,
                      model:
                          s.pendingModelSelection.value?.model ??
                          sessionState.model,
                      reasoningEffort:
                          s.pendingModelSelection.value?.reasoningEffort ??
                          sessionState.reasoningEffort,
                    ),
                  ),
                ),
              );
            } else {
              onRequestHandoff!(
                AiChatHandoffDraft(
                  id: 'suggest_${DateTime.now().microsecondsSinceEpoch}',
                  label: action.label,
                  content: '',
                  title: '',
                  initialText: prompt,
                  providerId:
                      s.pendingModelSelection.value?.providerId ??
                      sessionState.providerId,
                  model:
                      s.pendingModelSelection.value?.model ??
                      sessionState.model,
                  reasoningEffort:
                      s.pendingModelSelection.value?.reasoningEffort ??
                      sessionState.reasoningEffort,
                ),
              );
            }
            return;
          }
          // 提示词类只填入 composer，不自动发送 —— 用户可以先改。
          s.composerNotice.value = null;
          writeControllerTextAfterComposing(
            s.composerController,
            (_) => prompt,
          );
          s.composerFocusNode.requestFocus();
        case FeatureActionTarget(:final feature, :final seedText):
          final open = onOpenFeature;
          if (open == null) {
            _log.warning(
              'next action ignored: no host navigation feature=$feature',
            );
            return;
          }
          open(feature, seedText);
      }
    }

    final onboardingOverlayController = useMemoized(
      () => OverlayPortalController(debugLabel: 'chat_onboarding'),
      [],
    );
    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) {
          return;
        }
        if (onboardingActive) {
          onboardingOverlayController.show();
        } else {
          onboardingOverlayController.hide();
        }
      });
      return null;
    }, [onboardingActive, onboardingStep]);

    return Container(
      color: appChromeBackgroundColor(
        colors,
        appBackgroundActive,
        colors.surfaceContainerHigh,
      ),
      child: Stack(
        children: [
          Column(
            children: [
              ChatHeader(
                sessionState: sessionState,
                runtimeState: runtimeState,
                novelId: novelId,
                databasePath: databasePath,
                activeSessionId: runtimeSessionId,
                onSelectSession: onActiveSessionIdChanged,
                onRequestNewSession: requestNewSession,
                onContinueSession: onRequestHandoff == null
                    ? null
                    : (id) => unawaited(_continueSession(context, ref, s, id)),
                onClose: onClose,
                onExpand: onExpand != null ? () => onExpand!() : null,
                onOpenPermissions:
                    toolApprovalEnabled &&
                        novelId.isNotEmpty &&
                        runtimeSessionId != null
                    ? () => unawaited(
                        showToolPermissionEditor(
                          context,
                          ToolPermissionContext(
                            workId: novelId,
                            sessionId: runtimeSessionId,
                            episodeId: promptContext.currentEpisodeId,
                          ),
                        ),
                      )
                    : null,
                avoidWindowCaption: avoidWindowCaption && !floating,
                floating: floating,
              ),
              Divider(height: 1, color: colors.border),
              if (!isExpanded)
                TodoPanel(
                  initialExpanded: false,
                  sessionId: sessionState.sessionId ?? activeSessionId,
                  maxListHeight: TodoPanel.inlineMaxListHeight,
                ),
              if (!isConfigured)
                const ChatConfigHint()
              else ...[
                Expanded(
                  child: _ChatMessageListArea(
                    panel: this,
                    runtimeSessionId: runtimeSessionId,
                    panelState: s,
                    sessionState: sessionState,
                    promptBuilder: promptBuilder,
                    promptContext: promptContext,
                    availableSubAgents: availableSubAgents,
                    emptyStateActions: emptyActions,
                    onQuickAction: (action) {
                      if (!isConfigured) {
                        return;
                      }
                      // 空态卡片的提示词类沿用旧行为：填入后立刻发送。
                      final prompt = resolveNextActionPrompt(context, action);
                      if (prompt.isNotEmpty) {
                        if (runtimeState.isRequestInFlight) {
                          return;
                        }
                        s.composerController.value = TextEditingValue(
                          text: prompt,
                          selection: TextSelection.collapsed(
                            offset: prompt.length,
                          ),
                        );
                        s.composerNotice.value = null;
                        s.userScrolledUp.value = false;
                        _handleSendMessage(
                          context,
                          ref,
                          prompt,
                          state: s,
                          availableSubAgents: availableSubAgents,
                          promptContext: promptContext,
                          promptBuilder: promptBuilder,
                          aiPromptService: aiPromptService,
                        );
                        return;
                      }
                      handleNextAction(action);
                    },
                  ),
                ),
                // composer 正上方。无建议时 NextActionBar 自己返回
                // SizedBox.shrink()，这里不留占位。
                SessionNextActionBar(
                  sessionId: activeSessionId,
                  enabled: suggestionsEnabled && onOpenFeature != null,
                  onPick: handleNextAction,
                ),
                ToolOperationStrip(
                  key: ValueKey('tool_operations_$runtimeSessionId'),
                  sessionId: runtimeSessionId,
                ),
                BackgroundAgents(
                  key: ValueKey('background_agents_$runtimeSessionId'),
                  sessionId: runtimeSessionId,
                  novelId: novelId,
                  databasePath: databasePath,
                ),
                // composer 外面、和后台任务条同级：放进 composer 会多吃一层
                // 水平内边距，两张卡的左右边缘对不齐。
                // 展开模式由右侧面板展示；agent turn 未完成时（请求在途或工具
                // 执行中）不展示待处理变更摘要。
                if (!isExpanded &&
                    !runtimeState.isEditing &&
                    pendingAiChanges.isNotEmpty &&
                    databasePath != null)
                  PendingChangesSummaryCard(
                    databasePath: databasePath!,
                    changes: pendingAiChanges,
                  ),
                // 点「新对话」后的一次性提议，5 秒后自动隐藏。
                ContinueSessionOfferBar(
                  novelId: novelId,
                  onAccept: (sourceId) =>
                      unawaited(_continueSession(context, ref, s, sourceId)),
                ),
                ChatComposer(
                  state: s,
                  sessionId: activeSessionId,
                  isConfigured: isConfigured,
                  sessionState: sessionState,
                  runtimeState: runtimeState,
                  availableModels: availableModels,
                  availableSubAgents: availableSubAgents,
                  promptBuilder: promptBuilder,
                  databasePath: databasePath,
                  composerHint: composerHint,

                  onRequestNewSession: requestNewSession,
                  onSendMessage: (text) {
                    s.userScrolledUp.value = false;
                    _handleSendMessage(
                      context,
                      ref,
                      text,
                      state: s,
                      availableSubAgents: availableSubAgents,
                      promptContext: promptContext,
                      promptBuilder: promptBuilder,
                      aiPromptService: aiPromptService,
                    );
                  },
                  onCancelRequest: () => _cancelActiveRequest(
                    context,
                    providerContainer,
                    runtimeSessionId: runtimeSessionId,
                    state: s,
                    availableSubAgents: availableSubAgents,
                    aiPromptService: aiPromptService,
                    promptContext: promptContext,
                    promptBuilder: promptBuilder,
                  ),
                  onSelectModel: (option) {
                    s.composerNotice.value = null;
                    final current = ref.read(
                      aiChatSessionProvider(activeSessionId),
                    );
                    final selection = PendingChatModelSelection(
                      providerId: option.providerId,
                      model: option.model,
                      reasoningEffort: defaultReasoningEffortFor(
                        option.reasoningEfforts,
                      ),
                    );
                    s.pendingModelSelection.value =
                        selection.hasSameModelAs(current) &&
                            selection.reasoningEffort == current.reasoningEffort
                        ? null
                        : selection;
                  },
                  onSelectModelWithEffort: (option, effort) {
                    s.composerNotice.value = null;
                    final current = ref.read(
                      aiChatSessionProvider(activeSessionId),
                    );
                    final selection = PendingChatModelSelection(
                      providerId: option.providerId,
                      model: option.model,
                      reasoningEffort: effort,
                    );
                    s.pendingModelSelection.value =
                        selection.hasSameModelAs(current) &&
                            selection.reasoningEffort == current.reasoningEffort
                        ? null
                        : selection;
                  },
                  onRemoveReference: (ref) {
                    s.attachedReferences.value = [...s.attachedReferences.value]
                      ..remove(ref);
                  },
                  onOpenHandoff: s.pendingHandoff.value?.sourceSessionId == null
                      ? null
                      : () {
                          final pending = s.pendingHandoff.value!;
                          unawaited(
                            onOpenSessionReference?.call(
                              pending.sourceSessionId!,
                              pending.sourceMode ?? AiSessionMode.chat,
                            ),
                          );
                        },
                  onClearHandoff: () {
                    s.pendingHandoff.value = null;
                  },
                  onSendQueuedMessageNow: () {
                    _sendQueuedMessageNow(
                      context,
                      state: s,
                      availableSubAgents: availableSubAgents,
                      promptContext: promptContext,
                      promptBuilder: promptBuilder,
                      aiPromptService: aiPromptService,
                    );
                  },
                  onClearQueuedMessage: () {
                    _clearQueuedMessage(
                      context,
                      state: s,
                      availableSubAgents: availableSubAgents,
                      promptContext: promptContext,
                      promptBuilder: promptBuilder,
                      aiPromptService: aiPromptService,
                    );
                  },
                ),
              ],
            ],
          ),
          OverlayPortal(
            controller: onboardingOverlayController,
            overlayChildBuilder: (context) {
              if (!onboardingActive) {
                return const SizedBox.shrink();
              }
              return Positioned.fill(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: CompositedTransformFollower(
                    link: onboardingLink,
                    showWhenUnlinked: false,
                    targetAnchor: onboardingLeftOfTarget
                        ? Alignment.centerLeft
                        : Alignment.topLeft,
                    followerAnchor: onboardingLeftOfTarget
                        ? Alignment.centerRight
                        : Alignment.bottomLeft,
                    offset: onboardingOffset,
                    child: Material(
                      color: Colors.transparent,
                      child: ChatOnboardingBubble(
                        key: ValueKey('onboarding_$onboardingStep'),
                        stepIndex: onboardingStep,
                        totalSteps: 3,
                        title: context.t(onboardingTitleKey),
                        message: context.t(onboardingMessageKey),
                        tail: onboardingTail,
                        onDismiss: () => onOnboardingDismiss?.call(),
                        onNext: onboardingStep < 3
                            ? () => onOnboardingNext?.call()
                            : null,
                      ),
                    ),
                  ),
                ),
              );
            },
            child: const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// 消息列表区（空态 / ListView）。把 `messages` 的订阅收在这里，
/// streaming delta 高频更新时只重建本区域，面板其余部分不陪跑。
class _ChatMessageListArea extends HookConsumerWidget {
  const _ChatMessageListArea({
    required this.panel,
    required this.runtimeSessionId,
    required this.panelState,
    required this.sessionState,
    required this.promptBuilder,
    required this.promptContext,
    required this.availableSubAgents,
    required this.emptyStateActions,
    required this.onQuickAction,
  });

  final AiChatPanel panel;
  final String? runtimeSessionId;
  final AiChatPanelState panelState;
  final AiChatSessionState sessionState;
  final ChatPromptBuilder promptBuilder;
  final AiSessionContext promptContext;
  final List<SubAgent> availableSubAgents;
  final List<ChatNextAction> emptyStateActions;
  final ValueChanged<ChatNextAction> onQuickAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final messages = ref.watch(
      aiChatSessionProvider(
        panel.activeSessionId,
      ).select((session) => session.messages),
    );
    final uiMessages = groupMessagesForUi(messages);
    // 该状态由 ChatTurnRunner 在 AgentCompactionStart/End 间维护。
    // 直接订阅，避免上层为降低 streaming rebuild 而构造的 sessionState 丢失瞬态字段。
    final isCompacting = ref.watch(
      aiChatSessionProvider(
        panel.activeSessionId,
      ).select((session) => session.isCompactingContext),
    );
    final retryProgress = ref.watch(
      aiChatSessionProvider(
        panel.activeSessionId,
      ).select((session) => session.retryProgress),
    );
    final isWaitingForResponse = ref.watch(
      aiChatSessionProvider(
        panel.activeSessionId,
      ).select((session) => session.isWaitingForResponse),
    );
    // 自动贴底滚动（流式跟随 / 用户上滑暂停 / ask-user 强制滚底 / 会话切换重置）
    // 逻辑封装在 shared hook，桌面与移动端复用。
    final scrollController = useChatAutoScroll(
      uiMessages: uiMessages,
      userScrolledUp: panelState.userScrolledUp,
      sessionId: runtimeSessionId,
      hasTrailingActivity: isCompacting || isWaitingForResponse,
    );
    final revealSlot = useApprovalReveal(
      locator: ref.watch(toolApprovalLocatorProvider),
      controller: scrollController,
      uiMessages: uiMessages,
    );

    if (uiMessages.isEmpty) {
      return AssistantEmptyState(
        actions: emptyStateActions,
        onActionTap: onQuickAction,
      );
    }
    // SliverSpacing 已经会加上 composer 实测高度（由 _MeasuredComposer 上报到
    // ComposerHeightNotifier），这里只需提供一点呼吸空间即可，避免在 pending
    // changes summary card 展开时遮挡最新消息。
    const bottomPadding = RevericSpacing.lg;
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.only(
        top: RevericSpacing.x2l,
        bottom: bottomPadding,
      ),
      itemCount: uiMessages.length,
      itemBuilder: (context, index) {
        return revealSlot(
          index,
          panel._buildChatMessage(
            context,
            ref,
            colors,
            uiMessages[index],
            panelState,
            promptBuilder,
            promptContext: promptContext,
            availableSubAgents: availableSubAgents,
            isCompactingContext: isCompacting && index == uiMessages.length - 1,
            isWaitingForResponse:
                isWaitingForResponse && index == uiMessages.length - 1,
            retryProgress: index == uiMessages.length - 1 ? retryProgress : '',
            sessionState: sessionState,
          ),
        );
      },
    );
  }
}

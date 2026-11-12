// 职责: 移动端作品内 AI 聊天页 — 新会话首次发送时落库或加载历史会话，经共享 ChatSessionController 发送/流式/工具/取消/排队/slash/引用/handoff，含模型选择；监听「最近改动」跳转信号 push 对应 id 化编辑页。
// 关联文件:
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/components/reveric_button.dart
//   lib/shared/widgets/novel_open_boundary.dart
//   lib/shared/database/app_database.dart
//   lib/shared/localization/locale_keys.dart
//   lib/shared/agent/agent.dart
//   lib/shared/services/ai/chat_session_controller.dart
//   lib/shared/services/ai/session_persistence.dart
//   lib/shared/services/ai/chat_prompt_builder.dart
//   lib/shared/services/ai/context_message_matcher.dart
//   lib/shared/components/reveric_search_field.dart
//   lib/shared/widgets/ai/chat/chat_message_view.dart
//   lib/shared/widgets/ai/chat/auto_scroll_hook.dart
//   lib/shared/widgets/ai/chat/chat_send_completion_guard.dart
//   lib/shared/widgets/ai/chat/feedback_dialog.dart
//   lib/shared/widgets/ai/chat/message_action_confirm_dialog.dart
//   lib/shared/widgets/ai/chat/todo_panel.dart
//   lib/shared/widgets/ai/diff/recent_changes_log.dart
//   lib/shared/providers/workspace_navigation_provider.dart
//   lib/mobile/pages/chapter_editor_page.dart
//   lib/mobile/pages/outline_editor_page.dart
//   lib/mobile/pages/character_editor_page.dart
//   lib/mobile/pages/foreshadowing_editor_page.dart
//   lib/mobile/pages/entry_editor_page.dart
//   lib/mobile/widgets/chat_composer.dart
//   lib/mobile/widgets/chat_image_actions.dart
//   lib/mobile/widgets/model_effort_sheet.dart
//   lib/mobile/widgets/mobile_ai_session_app_bar.dart
//   lib/mobile/widgets/mobile_ai_mode.dart
//   lib/mobile/widgets/ai_session_history_sheet.dart
//   lib/mobile/providers/chat_providers.dart
//   lib/mobile/providers/ai_mode_session_memory_provider.dart
//   lib/shared/providers/ai_providers.dart
//   lib/shared/heuristic/chat_next_action.dart
//   lib/shared/widgets/ai/chat/session_next_action_bar.dart
//   lib/shared/providers/ai_mode_processing.dart
//   lib/shared/providers/agent_rule_providers.dart
//   lib/shared/providers/agent_skill_providers.dart
//   lib/shared/models/slash_entry.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/services/novel_actions.dart
//   lib/shared/providers/anonymous_reporting_providers.dart
//   lib/shared/logger/app_logger.dart
//   lib/shared/widgets/ai/chat/composer_notice.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
//   assets/translations/en/subagent.json
//   assets/translations/zh-CN/subagent.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/widgets/novel_open_boundary.dart';
import '../../shared/agent/agent.dart';
import '../../shared/components/reveric_search_field.dart';
import '../../shared/components/reveric_surfaces.dart';
import '../../shared/database/app_database.dart' show AiChatSession, Novel;
import '../../shared/database/novel_content_database.dart'
    show AgentRule, WorkingChange;
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/logger/app_logger.dart';
import '../../shared/models/agent_profile.dart';
import '../../shared/models/ai_provider.dart';
import '../../shared/models/ai_chat_models.dart';
import '../../shared/models/ai_session_mode.dart';
import '../../shared/models/agent_skill.dart';
import '../../shared/models/novel_workspace.dart';
import '../../shared/models/screenplay_workspace_state.dart';
import '../../shared/models/slash_entry.dart';
import '../../shared/models/subagent.dart';
import '../../shared/providers/agent_rule_providers.dart';
import '../../shared/providers/agent_skill_providers.dart';
import '../../shared/providers/ai_mode_processing.dart';
import '../../shared/providers/ai_providers.dart' hide AiChatSession;
import '../../shared/providers/chat_continue_offer_provider.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/providers/subagent_providers.dart';
import '../../shared/providers/prompt_template_provider.dart';
import '../../shared/services/ai/chat_session_controller.dart';
import '../../shared/services/ai/handoff_service.dart';
import '../../shared/widgets/ai/chat/chat_message_parts.dart';
import '../../shared/widgets/ai/chat/attachment_input.dart';
import '../../shared/widgets/ai/chat/composer_controller.dart';
import '../../shared/services/ai/chat_prompt_builder.dart';
import '../../shared/services/ai/context_message_matcher.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/ai/chat/composer_notice.dart';
import '../../shared/utils/random_id.dart';
import '../../shared/utils/text_input_composing.dart';
import 'package:reveric/shared/heuristic/chat_next_action.dart';
import 'package:reveric/shared/models/feature_id.dart';
import 'package:reveric/shared/widgets/ai/chat/assistant_empty_state.dart';
import 'package:reveric/shared/widgets/ai/chat/chat_message_view.dart';
import 'package:reveric/shared/widgets/ai/chat/continue_session_offer_bar.dart';
import 'package:reveric/shared/widgets/ai/chat/session_next_action_bar.dart';
import 'package:reveric/shared/widgets/ai/chat/background_agents.dart';
import 'package:reveric/shared/widgets/ai/chat/tool_operation_strip.dart';
import 'package:reveric/shared/widgets/ai/tool_permission_editor.dart';
import 'package:reveric/shared/models/tool_permission.dart';
import 'package:reveric/shared/widgets/ai/chat/auto_scroll_hook.dart';
import 'package:reveric/shared/widgets/ai/tool_approval_card.dart';
import 'package:reveric/shared/widgets/ai/chat/chat_send_completion_guard.dart';
import 'package:reveric/shared/widgets/ai/chat/feedback_dialog.dart';
import 'package:reveric/shared/widgets/ai/chat/message_action_confirm_dialog.dart';
import 'package:reveric/shared/widgets/ai/chat/todo_panel.dart';
import 'package:reveric/shared/widgets/ai/chat/ui_message.dart';
import 'package:reveric/shared/widgets/ai/diff/recent_changes_log.dart';

import '../../shared/providers/workspace_navigation_provider.dart';
import '../../shared/providers/screenplay_workspace_state_provider.dart';
import '../providers/ai_mode_session_memory_provider.dart';
import '../providers/chat_providers.dart';
import '../features/cover_studio/apply_cover.dart';
import '../features/cover_studio/studio_page.dart';
import '../features/map/draft_navigation.dart';
import '../features/map/studio_page.dart';
import '../widgets/ai_session_history_sheet.dart';
import '../widgets/chat_composer.dart';
import '../widgets/chat_image_actions.dart';
import '../widgets/model_effort_sheet.dart';
import '../widgets/model_selector.dart';
import '../widgets/mobile_ai_mode.dart';
import '../widgets/mobile_ai_session_app_bar.dart';
import 'agent_model_settings_page.dart';
import 'character_editor_page.dart';
import 'chapter_editor_page.dart';
import 'entry_editor_page.dart';
import 'foreshadowing_editor_page.dart';
import 'outline_editor_page.dart';
import '../../shared/components/reveric_dialog.dart';
import '../../shared/components/reveric_button.dart';
import '../../shared/utils/route_pop.dart';

enum _AiProcessingExitDecision { background, pause }

final _log = AppLogger.forModule('MobileNovelChat');

void _syncMobilePersistedContextState(
  ProviderContainer container, {
  required String activeSessionId,
  required Agent agent,
}) {
  final current = container.read(aiChatSessionProvider(activeSessionId));
  final sessionId = current.sessionId;
  if (sessionId == null) {
    return;
  }
  final snapshot = agent.contextManager.snapshot();
  final summary = snapshot.summary?.trim();
  final nextMessages = List<AiMessage>.from(current.messages);

  if (summary != null && summary.isNotEmpty) {
    final summaryId = compactSummaryMessageId(
      sessionId,
      snapshot.compactionCount,
    );
    final alreadyExists = nextMessages.any(
      (message) => message.id == summaryId,
    );
    if (!alreadyExists) {
      final placement = resolveCompactSummaryPlacement(
        uiMessages: nextMessages,
        retainedMessages: snapshot.messages,
        sessionId: sessionId,
        compactedMessageCount: snapshot.lastCompactionMessageCount,
      );
      if (placement != null) {
        nextMessages.insert(
          placement.insertIndex,
          AiMessage(
            id: summaryId,
            role: AiMessageRole.user,
            type: AiMessageType.compact_summary,
            content: summary,
            timestamp: DateTime.now(),
            metadata: buildCompactSummaryMetadata(
              compactionCount: snapshot.compactionCount,
              replayFromMessageId: placement.replayFromMessageId,
              tokensBefore: snapshot.lastCompactionTokensBefore,
              tokensAfter: snapshot.lastCompactionTokensAfter,
            ),
          ),
        );
      }
    }
  }

  container
      .read(aiChatSessionProvider(activeSessionId).notifier)
      .syncContext(messages: nextMessages);
}

/// 作品内聊天页：从编辑器「AI 助手」进入。新会话先使用临时 session ID，
/// 首次发送时由 [ChatSessionController] 物化并切换为持久化会话。
class MobileNovelChatPage extends HookConsumerWidget {
  const MobileNovelChatPage({
    super.key,
    required this.novelId,
    required this.databasePath,
    this.chapterId,
    this.chapterTitle,
    this.chapterNumber,
    this.handoff,
    this.existingSessionId,
    this.currentSeasonId,
    this.currentEpisodeId,
    this.hasMultipleSeasons = false,
    this.returnMapDraftTarget = false,
  });

  final String novelId;
  final String databasePath;

  /// 从地图工作台「让 Agent 设计」进入时为 true：Agent 提交制图草案、这一轮说完后
  /// 关掉本页，把草案所属地点 id 作为返回值交回工作台；否则在本页之上打开那张地图。
  final bool returnMapDraftTarget;

  final String? chapterId;
  final String? chapterTitle;
  final int? chapterNumber;
  final String? currentSeasonId;
  final String? currentEpisodeId;
  final bool hasMultipleSeasons;

  /// 进入时携带的接力上下文（如「带本章讨论」）；首次发送会拼入正文。
  final PendingChatHandoff? handoff;

  /// 非空表示打开一条已存在的会话（从「助手」历史列表进入）：不新建会话，
  /// 改由 body 从持久化加载历史消息注入 provider，可继续对话。
  final String? existingSessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return NovelOpenBoundary(
      novelId: novelId,
      child: Consumer(
        builder: (context, ref, _) {
          final work = ref.watch(novelProvider(novelId));
          if (work.hasError) {
            _log.error(
              'Failed to load chat work id=$novelId',
              error: work.error,
              stackTrace: work.stackTrace,
            );
          }
          return work.when(
            skipLoadingOnReload: true,
            skipError: true,
            data: (novel) => novel == null
                ? _buildWorkLoadingState(
                    context,
                    message: context.t(LocaleKeys.editorNovelNotFound),
                  )
                : HookConsumer(
                    builder: (context, ref, _) =>
                        _buildContent(context, ref, novel),
                  ),
            loading: () => _buildWorkLoadingState(context),
            error: (_, _) => _buildWorkLoadingState(
              context,
              message: context.t(LocaleKeys.commonLoadFailed),
            ),
          );
        },
      ),
    );
  }

  Widget _buildWorkLoadingState(BuildContext context, {String? message}) {
    return Scaffold(
      backgroundColor: RevericTheme.colorsOf(context).canvas,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message == null)
              const CircularProgressIndicator()
            else
              Text(message),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: Text(context.t(LocaleKeys.commonCancel)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, WidgetRef ref, Novel novel) {
    final initialSessionId = useMemoized(
      () => existingSessionId ?? '__new__${buildRandomId('mobile_chat_draft')}',
      [novelId, existingSessionId],
    );
    final sessionId = useState(initialSessionId);
    final sessionProcessing = ref.watch(
      aiSessionProcessingProvider(
        mode: AiSessionMode.chat,
        sessionId: sessionId.value,
      ),
    );
    final pendingMapTarget = useMapDraftNavigation(
      context,
      processing: sessionProcessing,
      returnToCaller: returnMapDraftTarget,
      openMap: (target) => openMobileMapStudioPage(
        context,
        novelId: novelId,
        databasePath: databasePath,
        worldId: target,
      ),
    );

    // 「最近改动」点击条目 → 关闭 sheet 并 push 对应 id 化编辑页（返回即回到本聊天页）。
    ref.listen(workspaceNavigationProvider, (previous, next) {
      if (next == null) {
        return;
      }
      ref.read(workspaceNavigationProvider.notifier).clear();
      // Agent 提交制图草案会发一条 maps 导航，指向草案所属地点；
      // 草案在那张地图的制图师抽屉里审阅，跳转等这一轮结束（useMapDraftNavigation）。
      if (next.section == NovelWorkspaceSection.maps) {
        pendingMapTarget.value = next.itemId;
        return;
      }
      _openWorkspaceResource(context, ref, databasePath, novelId, next);
    });

    useEffect(
      () {
        // 无论新建还是打开历史会话，都先设置 AI 作用域，供 aiServiceProvider / prompt 构建使用。
        // updateContext 会写 provider，hooks 的 effect 在首帧 build 期同步执行，需延后到帧后。
        Future<void>(() {
          if (!context.mounted) {
            return;
          }
          ref
              .read(aiSessionContextNotifierProvider.notifier)
              .updateContext(
                AiSessionContext(
                  databasePath: databasePath,
                  currentSeasonId: currentSeasonId,
                  currentEpisodeId: currentEpisodeId,
                  hasMultipleSeasons: hasMultipleSeasons,
                  chapterId: chapterId,
                  chapterTitle: chapterTitle,
                ).withWork(novel),
              );
        });
        return null;
      },
      [
        databasePath,
        novel,
        currentSeasonId,
        currentEpisodeId,
        hasMultipleSeasons,
        chapterId,
        chapterTitle,
      ],
    );

    final id = sessionId.value;
    final novelContext = MobileAiNovelContext(
      novelId: novel.id,
      novelName: novel.title,
      databasePath: databasePath,
      novelDescription: novel.description,
      novelDraft: novel.draft,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      chapterNumber: chapterNumber,
      contentKind: novel.contentKind,
      currentSeasonId: currentSeasonId,
      currentEpisodeId: currentEpisodeId,
      hasMultipleSeasons: hasMultipleSeasons,
    );
    return _MobileNovelChatBody(
      sessionId: id,
      novel: novel,
      novelContext: novelContext,
      handoff: handoff,
      loadFromHistory: existingSessionId != null,

      onSessionIdChanged: (nextSessionId) {
        sessionId.value = nextSessionId;
      },
    );
  }
}

class _MobileNovelChatBody extends HookConsumerWidget {
  const _MobileNovelChatBody({
    required this.sessionId,
    required this.novel,
    required this.novelContext,
    required this.handoff,
    required this.loadFromHistory,
    required this.onSessionIdChanged,
  });

  final String sessionId;
  final Novel novel;
  final MobileAiNovelContext novelContext;
  final PendingChatHandoff? handoff;
  final ValueChanged<String> onSessionIdChanged;

  /// 从「助手」历史列表进入：需从持久化加载该会话历史消息注入 provider。
  final bool loadFromHistory;

  String get novelId => novel.id;
  String get novelName => novel.title;
  String get databasePath => novelContext.databasePath;
  String get novelDescription => novel.description;
  bool get novelDraft => novel.draft;
  String? get chapterId => novelContext.chapterId;
  String? get chapterTitle => novelContext.chapterTitle;
  int? get chapterNumber => novelContext.chapterNumber;
  String get contentKind => novel.contentKind;
  String? get currentSeasonId => novelContext.currentSeasonId;
  String? get currentEpisodeId => novelContext.currentEpisodeId;
  bool get hasMultipleSeasons => novelContext.hasMultipleSeasons;

  /// 把当前会话截止到（含）[cutAtSourceId] 这条消息分叉为一条新 chat session，
  /// 并替换当前页打开它。失败时弹 snackbar，不透出底层异常。
  Future<void> _forkFromMessage(
    BuildContext context,
    WidgetRef ref,
    String cutAtSourceId,
  ) async {
    final confirmed = await showAiForkSessionConfirmDialog(context);
    if (!confirmed || !context.mounted) {
      return;
    }
    try {
      final persistence = ref.read(
        aiSessionPersistenceServiceProvider(
          novelId: novelId,
          databasePath: databasePath,
        ),
      );
      final novelDb = ref.read(novelContentDatabaseProvider(databasePath));
      final forkedId = await persistence.forkSession(
        sourceSessionId: sessionId,
        cutAtSourceId: cutAtSourceId,
        titleSuffix: context.t(LocaleKeys.aiForkSuffix),
        novelDatabase: novelDb,
      );
      if (!context.mounted) {
        return;
      }
      ref
          .read(mobileAiModeSessionMemoryProvider(novelId).notifier)
          .remember(AiSessionMode.chat, forkedId);
      unawaited(
        pushReplacementMobileAiModePage(
          context,
          mode: AiSessionMode.chat,
          novel: novelContext,
          existingSessionId: forkedId,
          rememberCurrent: false,
          restoreRemembered: false,
          useChatPreferredFallback: false,
        ),
      );
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.aiForkFailed))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // messages 的订阅已下沉到 _MobileChatMessageList：streaming delta 到达时
    // 只重建消息列表区，TodoPanel / composer / 各 bar 不陪跑（与桌面 panel 一致）。
    // body 仅窄订阅自己用到的字段。

    final activeSessionIdRef = useRef(sessionId);
    activeSessionIdRef.value = sessionId;

    // 前台会话追踪：让处理中徽章/通知在本页显示期间归属当前 chat 会话。
    useEffect(() {
      if (sessionId.isEmpty) {
        return null;
      }
      final tracker = ref.read(aiModeProcessingTrackerProvider.notifier);
      tracker.setForegroundSession(
        mode: AiSessionMode.chat,
        sessionId: sessionId,
        foreground: true,
      );
      return () {
        tracker.setForegroundSession(
          mode: AiSessionMode.chat,
          sessionId: sessionId,
          foreground: false,
        );
      };
    }, [sessionId]);

    final isSessionProcessing = ref.watch(
      aiSessionProcessingProvider(
        mode: AiSessionMode.chat,
        sessionId: sessionId,
      ),
    );
    final allowLeaveWithRunningAgent = useState(false);
    final isSessionLoaded = ref.watch(
      aiChatSessionProvider(sessionId).select((session) => session.isLoaded),
    );
    final sessionProviderId = ref.watch(
      aiChatSessionProvider(sessionId).select((session) => session.providerId),
    );
    final sessionModel = ref.watch(
      aiChatSessionProvider(sessionId).select((session) => session.model),
    );
    final sessionReasoningEffort = ref.watch(
      aiChatSessionProvider(
        sessionId,
      ).select((session) => session.reasoningEffort),
    );
    // 当前会话模型 id（供 composer 的模型选择器解析展示名与 effort）。
    final availableModels = ref.watch(availableAiModelsProvider);
    final resolvedModelId = (sessionProviderId != null && sessionModel != null)
        ? '$sessionProviderId::$sessionModel'
        : null;
    final runtime = ref.watch(aiChatRuntimeProvider(sessionId));
    final isBusy = runtime.isEditing;

    final composerController = useChatComposerController();
    final composerFocusNode = useFocusNode();
    final userScrolledUp = useRef(false);
    // 可观察的编排输入态：refs/handoff/队列用 useState（UI 响应），sendGuard 用普通字段。
    final attachedReferences = useState<List<AiContextReference>>(const []);
    final pendingHandoff = useState<PendingChatHandoff?>(null);
    final queuedMessage = useState<QueuedChatMessage?>(null);
    final pendingModelSelection = useState<PendingChatModelSelection?>(null);
    final composerWarning = useState<String?>(null);
    final composerStore = useMemoized(
      () => _MobileComposerStore(
        references: attachedReferences,
        handoff: pendingHandoff,
        queued: queuedMessage,
      ),
      [attachedReferences, pendingHandoff, queuedMessage],
    );
    final consumedIncomingHandoff = useRef(false);
    final pendingAutoSend = useState(false);

    // 页面卸载时：若普通排队尚未 stage 且 agent 仍在跑，提升为下一轮（与桌面面板卸载一致）。
    // 「后台运行」路径通常已在 handleProcessingExit 里 sendQueuedMessageNow；此处作兜底。
    useEffect(() {
      final queuedNotifier = queuedMessage;
      final providerContainer = ProviderScope.containerOf(
        context,
        listen: false,
      );
      return () {
        promoteQueuedMessageForSurvivingTurn(
          container: providerContainer,
          queued: queuedNotifier.value,
        );
      };
    }, const []);

    // 进入时若带 handoff，seed 引用/composer/pendingHandoff；autoSend 等会话就绪后触发。
    useEffect(() {
      final incoming = handoff;
      if (incoming == null || consumedIncomingHandoff.value) {
        return null;
      }
      consumedIncomingHandoff.value = true;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) {
          return;
        }
        if (incoming.references.isNotEmpty) {
          attachedReferences.value = incoming.references;
        }
        if (incoming.references.isNotEmpty || incoming.initialText != null) {
          final handoffBody = incoming.content.trim();
          final seededComposer = incoming.initialText?.trim() ?? '';
          final composerAlreadyHasHandoffBody =
              seededComposer.isNotEmpty &&
              handoffBody.isNotEmpty &&
              seededComposer == handoffBody;
          if (!composerAlreadyHasHandoffBody &&
              (incoming.autoSend || handoffBody.isNotEmpty)) {
            pendingHandoff.value = incoming;
          } else {
            pendingHandoff.value = null;
          }
          final initialText = incoming.initialText ?? '';
          writeControllerTextAfterComposing(
            composerController,
            (_) => initialText,
          );
        } else {
          pendingHandoff.value = incoming;
          // clear() 同样会把 composing 置空，必须走组词安全写入。
          writeControllerTextAfterComposing(composerController, (_) => '');
        }
        if (incoming.autoSend) {
          pendingAutoSend.value = true;
        } else {
          composerFocusNode.requestFocus();
        }
      });
      return null;
    }, [sessionId]);

    // 会话落库接线（移动端无桌面 panel 的元数据/消息落库监听）：
    // 1) 准备内存态会话：从历史进入时拉取持久化消息注入 provider（可继续对话）；
    //    新建会话从 handoff 继承模型选择后标记 isLoaded。两者都使 ChatTurnRunner 的消息落库守卫（要求 isLoaded）
    //    放行，否则对话消息永不入库，重开会话时显示「无法加载对话」。
    // 2) 监听标题变化并落库——首次发送后控制器据用户消息改名，需写回库供列表展示，
    //    否则会话名固定为创建时的占位标题。
    useEffect(() {
      var cancelled = false;
      bool stale() => cancelled || !context.mounted;
      final persistence = ref.read(
        aiSessionPersistenceServiceProvider(
          novelId: novelId,
          databasePath: databasePath,
        ),
      );
      // markLoaded/loadSession 会写 provider state；hooks 的 effect 在首帧 build 期同步
      // 执行，直接调用会触发「Tried to modify a provider while building」，故延后到帧后。
      // body 自身 watch 了 aiChatSessionProvider(sessionId)，写入作用在存活 provider 上，
      // 避免外层 read-改与 body watch 之间 autoDispose 复位的竞态。
      Future<void>(() async {
        if (stale()) {
          return;
        }
        final notifier = ref.read(aiChatSessionProvider(sessionId).notifier);
        if (!loadFromHistory) {
          if (handoff != null &&
              !ref.read(aiChatSessionProvider(sessionId)).isLoaded) {
            notifier.startNewSession(
              sessionId: sessionId,
              title: '',
              providerId: handoff!.providerId,
              model: handoff!.model,
              reasoningEffort: handoff!.reasoningEffort,
              sessionMode: AiSessionMode.chat,
              agentSlug: builtinAgentSlugOrchestrator,
            );
          }
          notifier.markLoaded();
          return;
        }
        // 从「助手」历史列表进入：加载该会话的持久化消息（与 desktop panel 一致）。
        final persisted = await persistence.getSession(sessionId);
        if (stale()) {
          return;
        }
        if (persisted == null) {
          notifier.markLoaded();
          return;
        }
        await persistence.activateSession(sessionId, isCurrent: () => !stale());
        if (stale() || ref.read(aiChatSessionProvider(sessionId)).isLoaded) {
          return;
        }
        final novelDb = ref.read(novelContentDatabaseProvider(databasePath));
        final data = await persistence.loadSessionMessages(
          sessionId: sessionId,
          novelDatabase: novelDb,
        );
        if (stale()) {
          return;
        }
        notifier.loadSessionIfUnloaded(
          sessionId: sessionId,
          title: persisted.title,
          messages: data.messages,
          providerId: persisted.provider,
          model: persisted.model,
          persistedReasoningEffort: persisted.reasoningEffort,
          sessionMode: AiSessionMode.fromString(persisted.mode),
          agentSlug: builtinAgentSlugOrchestrator,
        );
      });
      var lastTitle = '';
      Future<void> persistTitle(String title) async {
        if (isTemporaryAiChatSessionId(sessionId)) {
          return;
        }
        try {
          await persistence.updateTitle(id: sessionId, title: title);
        } catch (error, stackTrace) {
          _log.error(
            '[DB] table=ai_chat_sessions operation=UPDATE_TITLE '
            'sessionId=$sessionId',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }

      final subscription = ref.listenManual(
        aiChatSessionProvider(sessionId).select((session) => session.title),
        (previous, next) {
          final title = next.trim();
          if (title.isEmpty || title == lastTitle) {
            return;
          }
          lastTitle = title;
          unawaited(persistTitle(title));
        },
        fireImmediately: true,
      );
      return () {
        cancelled = true;
        subscription.close();
      };
    }, [sessionId, novelId, databasePath, loadFromHistory]);

    // Slash 建议：输入 / 时匹配的 subagent + skill 条目。
    final slashMatches = useState<List<SlashEntry>>(const []);

    final promptBuilder = useMemoized(ChatPromptBuilder.new);
    final aiPromptService = ref.read(aiPromptServiceProvider);
    final mergedSubAgents = ref.watch(mergedSubAgentsProvider);
    final availableSubAgents = mergedSubAgents
        .where(
          (agent) => agent.enabled && agent.mode == AiSessionMode.chat.value,
        )
        .toList(growable: false);
    // slash 面板只展示用户已安装且可执行的技能。
    final slashSkills =
        ref.watch(chatSlashSkillsProvider).asData?.value ??
        const <SkillDefinition>[];
    // 保存最新候选列表，供 composer 监听器读取（避免闭包过期）。
    final slashAgents = availableSubAgents
        .where(isUserVisibleSubAgent)
        .toList(growable: false);
    final slashAgentsRef = useRef<List<SubAgent>>(const []);
    slashAgentsRef.value = slashAgents;
    final slashSkillsRef = useRef<List<SkillDefinition>>(const []);
    slashSkillsRef.value = slashSkills;
    final slashCandidateKeys = <Object?>[
      for (final agent in slashAgents) ...[
        agent.id,
        agent.name,
        agent.description,
        agent.prompt,
      ],
      for (final skill in slashSkills) ...[
        skill.id,
        skill.name,
        skill.description,
      ],
    ];

    // 监听输入：以 / 开头且无空格/换行时弹出匹配的 subagent + skill 建议。
    void recomputeSlashMatches() {
      // CJK 输入法合成期（composing region 非空）不读文本匹配 slash，避免干扰中文等合成输入。
      final composing = composerController.value.composing;
      if (composing.isValid && !composing.isCollapsed) {
        return;
      }
      final value = composerController.text.trimLeft();
      if (value.contains('\n') || !value.startsWith('/')) {
        slashMatches.value = const [];
        return;
      }
      final commandPart = value.split(' ').first.toLowerCase();
      bool matchesPrefix(String name) =>
          '/${name.toLowerCase().replaceAll(' ', '_')}'.startsWith(commandPart);
      slashMatches.value = <SlashEntry>[
        for (final agent in slashAgentsRef.value)
          if (matchesPrefix(agent.name))
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
    }

    useOnListenableChange(composerController, recomputeSlashMatches);

    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          recomputeSlashMatches();
        }
      });
      return null;
    }, slashCandidateKeys);

    final settings = ref.watch(appSettingsProvider).asData?.value;
    final agentRules = databasePath.isEmpty
        ? const <AgentRule>[]
        : ref.watch(agentRulesStreamProvider(databasePath)).asData?.value ??
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
    final promptContext =
        AiSessionContext(
              databasePath: databasePath,
              currentSeasonId: currentSeasonId,
              currentEpisodeId: currentEpisodeId,
              hasMultipleSeasons: hasMultipleSeasons,
            )
            .withWork(novel)
            .copyWith(
              chapterId: chapterId,
              chapterTitle: chapterTitle,
              workspaceTitle: chapterTitle,
              workspaceContent: promptBuilder.buildWorkspaceSeedContent(),
              username: settings?.username ?? '',
              userRules: _formatMobileAgentRules(agentRules),
              novelChatSessionCount: novelChatSessionCount,
            );
    final container = ProviderScope.containerOf(context, listen: false);

    // ── 下一步建议 ──────────────────────────────────────────────────────
    // 建议来自模型的 SuggestNextAction 调用；模型没挂就什么都不显示。
    final suggestionsEnabled = ref.watch(aiAgentNextActionSuggestionsProvider);
    final nextActionEnv = ChatNextActionEnvironment(
      suggestionsEnabled: suggestionsEnabled,
      hasCover: novel.coverAssetId != null,
      metadataReady:
          novel.title.trim().isNotEmpty && novel.description.trim().isNotEmpty,
      setupDone: !novel.draft,
    );

    void startNewSession() {
      // 直接新建，不再先问「新对话 / 延续」：延续降级成新会话里的一次性提议条。
      final sourceTitle = ref
          .read(aiChatSessionProvider(sessionId))
          .title
          .trim();
      unawaited(
        ref
            .read(chatContinueOfferProvider.notifier)
            .offerAfterNewSession(
              novelId: novelId,
              sourceSessionId: sessionId,
              sourceTitle: sourceTitle.isEmpty
                  ? context.t(LocaleKeys.aiSessionTitleDefault)
                  : sourceTitle,
              databasePath: databasePath,
            ),
      );
      ref
          .read(mobileAiModeSessionMemoryProvider(novelId).notifier)
          .clear(AiSessionMode.chat);
      unawaited(
        pushReplacementMobileAiModePage(
          context,
          mode: AiSessionMode.chat,
          novel: novelContext,
          rememberCurrent: false,
          restoreRemembered: false,
          useChatPreferredFallback: false,
        ),
      );
    }

    Future<void> continueSession(String sourceId) async {
      bool sourceBusy() {
        final state = ref.read(aiChatRuntimeProvider(sourceId));
        return state.isRequestInFlight || state.isSessionMutationInFlight;
      }

      try {
        if (sourceBusy()) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.aiCancelFirst))),
          );
          return;
        }
        final source = await loadSessionContinuationSource(
          database: ref.read(appDatabaseProvider),
          contentDatabase: ref.read(novelContentDatabaseProvider(databasePath)),
          workId: novelId,
          sessionId: sourceId,
        );
        if (!context.mounted) {
          return;
        }
        if (source == null || sourceBusy()) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.t(
                  source == null
                      ? LocaleKeys.aiChatSourceUnavailable
                      : LocaleKeys.aiCancelFirst,
                ),
              ),
            ),
          );
          return;
        }
        final draft = buildSessionContinuation(
          source: source,
          initialText: composerController.text,
          references: attachedReferences.value,
          modelSelection: (
            providerId:
                pendingModelSelection.value?.providerId ?? sessionProviderId,
            model: pendingModelSelection.value?.model ?? sessionModel,
            reasoningEffort:
                pendingModelSelection.value?.reasoningEffort ??
                sessionReasoningEffort,
          ),
        );
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => MobileNovelChatPage(
              novelId: novelId,
              databasePath: databasePath,
              handoff: draft,
              chapterId: chapterId,
              chapterTitle: chapterTitle,
              chapterNumber: chapterNumber,
              currentSeasonId: currentSeasonId,
              currentEpisodeId: currentEpisodeId,
              hasMultipleSeasons: hasMultipleSeasons,
            ),
          ),
        );
      } catch (error, stackTrace) {
        _log.error(
          'Prepare mobile session continuation failed source=$sourceId',
          error: error,
          stackTrace: stackTrace,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.t(LocaleKeys.aiChatSourceUnavailable)),
            ),
          );
        }
      }
    }

    Future<void> openSource(String sourceId, AiSessionMode mode) async {
      final source = await ref
          .read(appDatabaseProvider)
          .aiChatSessionDao
          .getById(sourceId, novelId: novelId);
      if (!context.mounted) {
        return;
      }
      if (source == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.t(LocaleKeys.aiChatSourceUnavailable)),
          ),
        );
        return;
      }
      final sourceMode = AiSessionMode.fromString(source.mode);
      if (sourceMode != AiSessionMode.chat) {
        await pushReplacementMobileAiModePage(
          context,
          mode: sourceMode,
          novel: novelContext,
          existingSessionId: sourceId,
          rememberCurrent: false,
          restoreRemembered: false,
          useChatPreferredFallback: false,
        );
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MobileNovelChatPage(
            novelId: novelId,
            databasePath: databasePath,
            existingSessionId: sourceId,
          ),
        ),
      );
    }

    // 共享发送编排：移动端与桌面共用同一份 ChatSessionController。新会话首轮发送
    // 会把临时 id 物化为真实会话；日期、剧本季集上下文由共享发送链路投递。
    // 引用接力仅创建草稿，首次发送由共享控制器落库。
    ChatSessionController buildController() {
      final submittedText = composerController.text;
      return ChatSessionController(
        container: container,
        scope: ChatScope(
          activeSessionId: sessionId,
          novel: novel,
          databasePath: databasePath,
        ),
        host: ChatHost(
          encodeComposerBlocks: composerController.encodeBlocks,
          clearComposer: () {
            if (context.mounted && composerController.text == submittedText) {
              composerController.clear();
            }
          },
          focusComposer: composerFocusNode.requestFocus,
          openModelSelector: () async {
            final selection = await _showModelSelector(context, ref, sessionId);
            if (selection != null) {
              pendingModelSelection.value = selection;
            }
          },
          resetScroll: () => userScrolledUp.value = false,
          isMounted: () => context.mounted,
          onActiveSessionIdChanged: (nextSessionId) async {
            if (nextSessionId == null || nextSessionId.isEmpty) {
              throw StateError('Materialized mobile chat session id is empty.');
            }
            activeSessionIdRef.value = nextSessionId;
            if (context.mounted) {
              onSessionIdChanged(nextSessionId);
            }
          },
          onComposerWarning: (message) {
            if (!context.mounted) {
              return;
            }
            if (message == context.t(LocaleKeys.aiIncompleteResponse)) {
              composerWarning.value = message;
              return;
            }
            showAiComposerNotice(
              context,
              message,
              onNewSession: startNewSession,
            );
          },
          restoreComposerText: (text) {
            // 原先是 `.text=` 再 `.selection=` 两次赋值，等于两次 setEditingState；
            // 现在合并成一次组词安全的原子写入。
            writeControllerTextAfterComposing(
              composerController,
              (currentText) =>
                  currentText.isEmpty ? text : '$currentText\n$text',
            );
            composerFocusNode.requestFocus();
          },
          onContextCompacted: (agent) => _syncMobilePersistedContextState(
            container,
            activeSessionId: activeSessionIdRef.value,
            agent: agent,
          ),
          onContextSettled: (agent) => _syncMobilePersistedContextState(
            container,
            activeSessionId: activeSessionIdRef.value,
            agent: agent,
          ),
        ),
        store: composerStore,
        promptBuilder: promptBuilder,
        availableSubAgents: availableSubAgents,
        availableSkills: slashSkills,
        aiPromptService: aiPromptService,
        promptContext: promptContext,

        nextActionEnvironment: nextActionEnv,
        // 移动端始终能跳（封面走既有 handoff prompt，不需要独立工作台页）。
        supportsNextActionSuggestions: true,
      );
    }

    /// 点击一条下一步建议。
    ///
    /// 提示词类只填入输入框，不自动发送 —— 用户可以先改。跳转类切到目标模式页；
    /// 封面在移动端没有独立工作台，沿用 novel_editor_page 的 cover handoff prompt。
    void handleNextAction(ChatNextAction action) {
      switch (action.target) {
        case PromptActionTarget(:final prompt, :final intent):
          if (intent == ChatNextActionIntent.new_chat ||
              intent == ChatNextActionIntent.continue_in_new_chat) {
            final session = ref.read(aiChatSessionProvider(sessionId));
            final draft = intent == ChatNextActionIntent.continue_in_new_chat
                ? buildSessionContinuationDraft(
                    workId: novelId,
                    sourceSessionId: session.sessionId ?? sessionId,
                    sourceTitle: session.title,
                    sourceMode: session.sessionMode,
                    initialText: prompt,
                    references: attachedReferences.value,
                    modelSelection: (
                      providerId:
                          pendingModelSelection.value?.providerId ??
                          sessionProviderId,
                      model: pendingModelSelection.value?.model ?? sessionModel,
                      reasoningEffort:
                          pendingModelSelection.value?.reasoningEffort ??
                          sessionReasoningEffort,
                    ),
                  )
                : PendingChatHandoff(
                    label: action.label,
                    content: '',
                    initialText: prompt,
                    providerId:
                        pendingModelSelection.value?.providerId ??
                        sessionProviderId,
                    model: pendingModelSelection.value?.model ?? sessionModel,
                    reasoningEffort:
                        pendingModelSelection.value?.reasoningEffort ??
                        sessionReasoningEffort,
                  );
            unawaited(
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => MobileNovelChatPage(
                    novelId: novelId,
                    databasePath: databasePath,
                    handoff: draft,
                    chapterId: chapterId,
                    chapterTitle: chapterTitle,
                    chapterNumber: chapterNumber,
                    currentSeasonId: currentSeasonId,
                    currentEpisodeId: currentEpisodeId,
                    hasMultipleSeasons: hasMultipleSeasons,
                  ),
                ),
              ),
            );
            return;
          }
          composerWarning.value = null;
          writeControllerTextAfterComposing(composerController, (_) => prompt);
          composerFocusNode.requestFocus();
        case FeatureActionTarget(:final feature, :final seedText):
          switch (feature) {
            case FeatureId.ai_council:
            case FeatureId.ai_theater:
            case FeatureId.ai_roleplay:
              // 建议跳转是「带着 seed 开新局」，不能恢复该模式的旧会话，
              // 否则 restoreSession 会盖掉议题 / 场景 / 角色预选。
              unawaited(
                pushReplacementMobileAiModePage(
                  context,
                  mode: switch (feature) {
                    FeatureId.ai_council => AiSessionMode.council,
                    FeatureId.ai_theater => AiSessionMode.theater,
                    _ => AiSessionMode.roleplay,
                  },
                  novel: novelContext,
                  currentMode: AiSessionMode.chat,
                  currentSessionId: sessionId,
                  restoreRemembered: false,
                  useChatPreferredFallback: false,
                  // 角色扮演的 seed 是角色名，由目标页解析成角色卡。
                  seedText: seedText,
                ),
              );
            case FeatureId.ai_cover_studio:
              unawaited(
                openMobileCoverStudioPage(
                  context,
                  novel: novel,
                  // 空串表示内容库还没打开；工作台按 null 收起封面档案功能。
                  databasePath: databasePath.isEmpty ? null : databasePath,
                  onApply: (assetId) => applyMobileNovelCover(
                    context,
                    ref,
                    novel: novel,
                    assetId: assetId,
                  ),
                ),
              );
            default:
              _log.warning(
                'next action ignored unsupported feature=${feature.name}',
              );
          }
      }
    }

    Future<void> send() async {
      composerWarning.value = null;
      final selection = pendingModelSelection.value;
      await composerController.submit(
        () => runChatSendWithMountedCompletion(
          context: context,
          send: () => buildController().send(
            composerController.text,
            draft: composerController.snapshot(),
            pendingModelSelection: selection,
          ),
          onMounted: () {
            final session = ref.read(
              aiChatSessionProvider(activeSessionIdRef.value),
            );
            if (selection != null &&
                selection.hasSameModelAs(session) &&
                selection.reasoningEffort == session.reasoningEffort) {
              pendingModelSelection.value = null;
            }
          },
        ),
      );
    }

    useEffect(() {
      if (!pendingAutoSend.value || !isSessionLoaded) {
        return null;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!context.mounted || !pendingAutoSend.value) {
          return;
        }
        pendingAutoSend.value = false;
        await composerController.submit(
          () => buildController().send(
            composerController.text,
            draft: composerController.snapshot(),
          ),
        );
      });
      return null;
    }, [isSessionLoaded, pendingAutoSend.value]);

    void stop() {
      buildController().cancel(sessionId);
    }

    // 回退本轮 AI 改动并把原 prompt 放回输入框供编辑重发；冲突时弹覆盖确认。
    Future<void> rollbackTurnAndRedraft(String messageId) async {
      final confirmed = await showAiRollbackMessageConfirmDialog(context);
      if (!confirmed || !context.mounted) {
        return;
      }
      final prompt = await buildController().rollbackTurnAndPrepareResend(
        messageId,
      );
      if (prompt != null) {
        final current = composerController.value.text;
        final text = current.isEmpty ? prompt : '$current\n$prompt';
        composerController.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
        composerFocusNode.requestFocus();
      }
    }

    final chatSessions =
        ref
            .watch(
              mobileNovelModeSessionsProvider((
                novelId: novelId,
                mode: AiSessionMode.chat,
              )),
            )
            .asData
            ?.value ??
        const <AiChatSession>[];

    Future<void> openHistory() async {
      final picked = await showAiSessionHistorySheet(
        context,
        sessions: chatSessions,
        currentSessionId: sessionId,
        mode: AiSessionMode.chat,
        modeLabel: mobileAiModeLabel(context, AiSessionMode.chat),
        databasePath: databasePath,
        onContinue: (source) => continueSession(source.id),
        onDelete: (session) async {
          final service = ref.read(
            aiSessionPersistenceServiceProvider(
              novelId: novelId,
              databasePath: databasePath,
            ),
          );
          await service.deleteSession(session.id);
        },
      );
      if (picked == null || !context.mounted) {
        return;
      }
      if (picked.id == sessionId) {
        return;
      }
      ref
          .read(mobileAiModeSessionMemoryProvider(novelId).notifier)
          .remember(AiSessionMode.chat, picked.id);
      unawaited(
        pushReplacementMobileAiModePage(
          context,
          mode: AiSessionMode.chat,
          novel: novelContext,
          existingSessionId: picked.id,
          rememberCurrent: false,
          restoreRemembered: false,
          useChatPreferredFallback: false,
        ),
      );
    }

    Future<_AiProcessingExitDecision?> showAiProcessingExitDialog() {
      return showRevericDialog<_AiProcessingExitDecision>(
        context: context,
        builder: (dialogContext) => RevericDialog(
          title: context.t(LocaleKeys.editorAiProcessingExitTitle),
          content: Text(context.t(LocaleKeys.editorAiProcessingExitMessage)),
          actions: [
            RevericButton.secondary(
              label: context.t(LocaleKeys.commonCancel),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            RevericButton.text(
              label: context.t(LocaleKeys.commonPause),
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_AiProcessingExitDecision.pause),
            ),
            RevericButton.primary(
              label: context.t(LocaleKeys.commonContinueInBackground),
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_AiProcessingExitDecision.background),
            ),
          ],
        ),
      );
    }

    Future<void> handleProcessingExit() async {
      final decision = await showAiProcessingExitDialog();
      if (decision == null) {
        return;
      }
      if (decision == _AiProcessingExitDecision.pause) {
        await ref
            .read(aiChatRuntimeProvider(sessionId).notifier)
            .stopAll(source: AiChatCancelSource.exitPause);
      } else if (queuedMessage.value != null) {
        // 后台继续运行 AI：把排队消息交给仍存活（processing 期间 keepAlive）的 agent，
        // 由下一轮消费，避免离页后排队内容既不发送也不恢复而静默丢失。
        await buildController().sendQueuedMessageNow();
      }
      allowLeaveWithRunningAgent.value = true;
      await Future<void>.delayed(Duration.zero);
      if (context.mounted) {
        popIfRouteCurrent(context);
      }
    }

    // 本会话最近 AI 改动（active + committed）。用于底部「最近改动」bar 与轮次 ↩ 门控。
    final sessionChanges = databasePath.isEmpty
        ? const <WorkingChange>[]
        : (ref
                  .watch(sessionChangesProvider(databasePath, sessionId))
                  .asData
                  ?.value ??
              const <WorkingChange>[]);

    void openRecentChangesSheet() {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: RevericTheme.colorsOf(context).surface,
        showDragHandle: true,
        builder: (sheetContext) => _RecentChangesSheet(
          databasePath: databasePath,
          sessionId: sessionId,
        ),
      );
    }

    final canPop = allowLeaveWithRunningAgent.value || !isSessionProcessing;

    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || canPop) {
          return;
        }
        unawaited(handleProcessingExit());
      },
      child: MobileAiSessionScaffold(
        title: novelName,
        currentMode: AiSessionMode.chat,
        novelContext: novelContext,
        currentSessionId: sessionId,
        historyTooltip: context.t(LocaleKeys.aiSessionHistoryTitle),
        newSessionTooltip: context.t(LocaleKeys.aiNewSession),
        onHistory: openHistory,
        onNew: startNewSession,
        onPermissions: toolApprovalEnabled && novelId.isNotEmpty
            ? () => unawaited(
                showToolPermissionEditor(
                  context,
                  ToolPermissionContext(workId: novelId, sessionId: sessionId),
                ),
              )
            : null,
        body: Column(
          children: [
            TodoPanel(
              initialExpanded: false,
              sessionId: sessionId,
              maxListHeight: TodoPanel.inlineMaxListHeight,
            ),
            Expanded(
              child: _MobileChatMessageList(
                sessionId: sessionId,
                novelId: novelId,
                databasePath: databasePath,
                userScrolledUp: userScrolledUp,
                onFork: (sourceId) => _forkFromMessage(context, ref, sourceId),
                onOpenSessionReference: openSource,
                onRollbackTurn: rollbackTurnAndRedraft,
                emptyStateActions: emptyStateActions(nextActionEnv),
                onEmptyStateAction: (action) {
                  final prompt = resolveNextActionPrompt(context, action);
                  if (prompt.isEmpty) {
                    handleNextAction(action);
                    return;
                  }
                  // 空态提示词卡沿用旧行为：填入后立刻发送。
                  composerWarning.value = null;
                  composerController.value = TextEditingValue(
                    text: prompt,
                    selection: TextSelection.collapsed(offset: prompt.length),
                  );
                  userScrolledUp.value = false;
                  unawaited(send());
                },
              ),
            ),
            // 输入条正上方。无建议时 NextActionBar 自己返回 SizedBox.shrink()。
            SessionNextActionBar(
              sessionId: sessionId,
              enabled: suggestionsEnabled,
              onPick: handleNextAction,
            ),
            ToolOperationStrip(
              key: ValueKey('tool_operations_$sessionId'),
              sessionId: sessionId,
            ),
            BackgroundAgents(
              key: ValueKey('background_agents_$sessionId'),
              sessionId: sessionId,
              novelId: novelId,
              databasePath: databasePath,
            ),
            if (pendingHandoff.value?.isSessionContinuation == true)
              SessionContinuationDraftChip(
                title: pendingHandoff.value!.label,
                onRemove: () => composerStore.pendingHandoff = null,
                onOpen: () => unawaited(
                  openSource(
                    pendingHandoff.value!.sourceSessionId!,
                    pendingHandoff.value!.sourceMode ?? AiSessionMode.chat,
                  ),
                ),
              )
            else if (pendingHandoff.value != null)
              _PendingHandoffChip(
                label: pendingHandoff.value!.label,
                onClear: () => composerStore.pendingHandoff = null,
              ),
            if (attachedReferences.value.isNotEmpty)
              _AttachedReferencesBar(
                references: attachedReferences.value,
                onRemove: (reference) {
                  attachedReferences.value = [...attachedReferences.value]
                    ..remove(reference);
                },
              ),
            if (queuedMessage.value != null)
              _QueuedMessagePreview(
                queuedMessage: queuedMessage.value!,
                onSendNow: () {
                  composerWarning.value = null;
                  buildController().sendQueuedMessageNow();
                },
                onClear: () {
                  buildController().clearQueuedMessage(restoreToComposer: true);
                },
              ),
            if (slashMatches.value.isNotEmpty)
              _SlashSuggestions(
                matches: slashMatches.value,
                onSelect: (entry) {
                  // 选中 → 落成 chip（去重），清空 `/` token。
                  final reference = entry.toReference();
                  final current = attachedReferences.value;
                  if (!current.contains(reference)) {
                    attachedReferences.value = [...current, reference];
                  }
                  composerController.clear();
                  slashMatches.value = const [];
                  composerFocusNode.requestFocus();
                },
              ),
            if (sessionChanges.isNotEmpty)
              _RecentChangesBar(
                count: countChangeGroups(sessionChanges),
                onTap: openRecentChangesSheet,
              ),

            if (composerWarning.value != null)
              MobileChatComposerNotice(
                message: composerWarning.value!,
                onDismiss: () => composerWarning.value = null,
              ),
            // 点「新对话」后的一次性提议，5 秒后自动隐藏。
            ContinueSessionOfferBar(
              novelId: novelId,
              onAccept: (sourceId) => unawaited(continueSession(sourceId)),
            ),
            MobileChatComposer(
              controller: composerController,
              focusNode: composerFocusNode,
              isBusy: isBusy,

              queueOccupied:
                  queuedMessage.value != null ||
                  runtime.isPreparingQueuedMessage,
              hasPendingHandoff: pendingHandoff.value != null,
              modelSelector: !isBusy && queuedMessage.value == null
                  ? MobileModelSelector.pill(
                      models: availableModels,
                      selectedId: pendingModelSelection.value != null
                          ? '${pendingModelSelection.value!.providerId}::${pendingModelSelection.value!.model}'
                          : resolvedModelId,
                      selectedEffort:
                          pendingModelSelection.value?.reasoningEffort ??
                          sessionReasoningEffort,
                      onTap: () async {
                        final selection = await _showModelSelector(
                          context,
                          ref,
                          sessionId,
                        );
                        if (selection != null) {
                          pendingModelSelection.value = selection;
                        }
                      },
                    )
                  : null,
              onSend: () {
                send();
              },
              onStop: stop,
              onAttach: () => _showReferencePicker(
                context,
                databasePath,
                attachedReferences,
              ),
              onAttachFile: () =>
                  pickChatAttachments(context, composerController),
            ),
          ],
        ),
      ),
    );
  }
}

/// 消息列表区（空态 / ListView）。把 `messages` / `isCompactingContext` 的订阅
/// 收在这里，streaming delta 高频更新时只重建本区域，body 其余部分不陪跑
/// （与桌面 panel 的 `_ChatMessageListArea` 同一策略）。
class _MobileChatMessageList extends HookConsumerWidget {
  const _MobileChatMessageList({
    required this.sessionId,
    required this.novelId,
    required this.databasePath,
    required this.userScrolledUp,
    required this.onFork,
    required this.onOpenSessionReference,
    required this.onRollbackTurn,
    required this.emptyStateActions,
    required this.onEmptyStateAction,
  });

  final String sessionId;
  final String novelId;
  final String databasePath;
  final ObjectRef<bool> userScrolledUp;

  /// 以消息的 sourceId 为切点分叉会话。
  final ValueChanged<String> onFork;
  final Future<void> Function(String, AiSessionMode) onOpenSessionReference;
  final Future<void> Function(String messageId) onRollbackTurn;

  /// 空会话固定目录（客户端产出，非模型建议）。
  final List<ChatNextAction> emptyStateActions;
  final ValueChanged<ChatNextAction> onEmptyStateAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = ref
        .watch(
          aiChatSessionProvider(
            sessionId,
          ).select((session) => session.messages),
        )
        .where((m) => m.role != AiMessageRole.system)
        .toList(growable: false);
    final uiMessages = groupMessagesForUi(messages);
    // 该状态由 ChatTurnRunner 在 AgentCompactionStart/End 间维护，瞬态字段直接订阅。
    final isCompacting = ref.watch(
      aiChatSessionProvider(
        sessionId,
      ).select((session) => session.isCompactingContext),
    );
    final retryProgress = ref.watch(
      aiChatSessionProvider(
        sessionId,
      ).select((session) => session.retryProgress),
    );
    final isWaitingForResponse = ref.watch(
      aiChatSessionProvider(
        sessionId,
      ).select((session) => session.isWaitingForResponse),
    );
    // 共享 hook 负责流式贴底、用户上滑暂停、AskUser 强制滚底。
    final scrollController = useChatAutoScroll(
      uiMessages: uiMessages,
      userScrolledUp: userScrolledUp,
      sessionId: sessionId,
      hasTrailingActivity: isCompacting || isWaitingForResponse,
    );
    final revealSlot = useApprovalReveal(
      locator: ref.watch(toolApprovalLocatorProvider),
      controller: scrollController,
      uiMessages: uiMessages,
    );

    if (messages.isEmpty) {
      return AssistantEmptyState(
        actions: emptyStateActions,
        onActionTap: onEmptyStateAction,
        illustrationHeight: 140,
      );
    }
    return NotificationListener<ScrollNotification>(
      // 触摸拖动起点即暂停自动跟随，避免流式 jumpTo 取消上滑手势。
      onNotification: (n) => handleChatUserDragNotification(n, userScrolledUp),
      child: ListView.separated(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(
          RevericSpacing.lg,
          RevericSpacing.lg,
          RevericSpacing.lg,
          RevericSpacing.lg,
        ),
        itemCount: uiMessages.length,
        separatorBuilder: (_, _) => const SizedBox(height: RevericSpacing.lg),
        itemBuilder: (context, index) {
          final msg = uiMessages[index];
          return revealSlot(
            index,
            ChatMessageView(
              message: msg,
              activeSessionId: sessionId,
              onConfigureImageModel: () =>
                  openMobileAgentModelSettingsPage(context),
              onSetAsAvatar: (assetId, characterId) =>
                  setGeneratedImageAsAvatar(
                    context,
                    ref,
                    databasePath: databasePath,
                    assetId: assetId,
                    characterId: characterId,
                  ),
              onAddPhoto: (assetId, {characterId, itemId}) =>
                  addGeneratedImageAsPhoto(
                    context,
                    ref,
                    databasePath: databasePath,
                    assetId: assetId,
                    characterId: characterId,
                    itemId: itemId,
                  ),
              onOpenSessionReference: onOpenSessionReference,
              databasePath: databasePath,
              novelId: novelId,
              isCompactingContext:
                  isCompacting && index == uiMessages.length - 1,
              isWaitingForResponse:
                  isWaitingForResponse && index == uiMessages.length - 1,
              retryProgress: index == uiMessages.length - 1
                  ? retryProgress
                  : '',
              // 事件回调按需 read 全量会话态，不在 build 期订阅。
              onFeedback: () => showAiChatFeedbackDialog(
                context: context,
                ref: ref,
                sessionState: ref.read(aiChatSessionProvider(sessionId)),
                novelId: novelId,
                databasePath: databasePath,
              ),
              onFork: () => onFork(msg.sourceIds.last),
              onRollbackTurn: (id) async {
                await onRollbackTurn(id);
                return null;
              },
            ),
          );
        },
      ),
    );
  }
}

/// 适配 hooks 的 ValueNotifier 到共享 [ChatComposerStore]。refs/handoff/队列可观察
/// （useState ⇒ UI 响应），sendGuard 不需观察用普通字段（adapter 被 memo 稳定持有）。
class _MobileComposerStore implements ChatComposerStore {
  _MobileComposerStore({
    required this.references,
    required this.handoff,
    required this.queued,
  });

  final ValueNotifier<List<AiContextReference>> references;
  final ValueNotifier<PendingChatHandoff?> handoff;
  final ValueNotifier<QueuedChatMessage?> queued;
  DateTime? _sendGuardUntil;

  @override
  List<AiContextReference> get attachedReferences => references.value;
  @override
  set attachedReferences(List<AiContextReference> value) =>
      references.value = value;

  @override
  PendingChatHandoff? get pendingHandoff => handoff.value;
  @override
  set pendingHandoff(PendingChatHandoff? value) => handoff.value = value;

  @override
  QueuedChatMessage? get queuedMessage => queued.value;
  @override
  set queuedMessage(QueuedChatMessage? value) => queued.value = value;

  @override
  QueuedChatMessage? queuedMessageForSession(String? sessionId) => queued.value;

  @override
  void setQueuedMessageForSession(
    String? sessionId,
    QueuedChatMessage? message,
  ) {
    queued.value = message;
  }

  @override
  DateTime? get sendGuardUntil => _sendGuardUntil;
  @override
  set sendGuardUntil(DateTime? value) => _sendGuardUntil = value;
}

/// 底部「最近改动」单行 bar：展示本会话 AI 改动数量，点击打开 review sheet 逐条回退。
class _RecentChangesBar extends StatelessWidget {
  const _RecentChangesBar({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    // 与正上方的后台任务条同款描边卡；实心底会让这两条在同一个堆叠里像两种控件。
    return RevericElevatedInkWell(
      fallback: colors.surface,
      onTap: onTap,
      margin: const EdgeInsets.fromLTRB(
        RevericSpacing.lg,
        0,
        RevericSpacing.lg,
        RevericSpacing.sm,
      ),
      borderRadius: BorderRadius.circular(RevericRadius.large),
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.md,
        vertical: RevericSpacing.sm,
      ),
      child: Row(
        children: [
          RevericIcon(
            RevericIcons.history_outlined,
            size: 16,
            color: colors.accent,
          ),
          const SizedBox(width: RevericSpacing.md),
          Expanded(
            child: Text(
              '${context.t(LocaleKeys.workspaceRecentChanges)} · $count ${context.t(LocaleKeys.commonItemUnit)}',
              style: typo.uiMedium.copyWith(
                color: colors.textPrimary,
                fontSize: 13,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            context.t(LocaleKeys.workspaceViewChanges),
            style: typo.uiMedium.copyWith(color: colors.accent, fontSize: 12),
          ),
          // 去掉实心底后靠箭头方向区分：向右 = 开 sheet，向下 = 后台任务条折叠。
          SizedBox(
            // 与 MobileChatComposer 的发送按钮共用 40px 槽位，图标中心对齐。
            width: RevericSizes.buttonHeight,
            child: Center(
              child: RevericIcon(
                RevericIcons.chevron_right,
                size: 14,
                color: colors.textSubtle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 最近改动 review sheet：全屏底部弹层，内嵌共享 [RecentChangesLog] 逐条/全部回退。
/// 直接 watch [sessionChangesProvider]，回退后列表实时更新（已回退项即时消失），
/// 避免用 sheet 打开时的快照导致「已回退仍可点击」。
class _RecentChangesSheet extends ConsumerWidget {
  const _RecentChangesSheet({
    required this.databasePath,
    required this.sessionId,
  });

  final String databasePath;
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final changes = databasePath.isEmpty
        ? const <WorkingChange>[]
        : (ref
                  .watch(sessionChangesProvider(databasePath, sessionId))
                  .asData
                  ?.value ??
              const <WorkingChange>[]);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.lg,
            RevericSpacing.sm,
            RevericSpacing.lg,
            RevericSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.t(LocaleKeys.workspaceRecentChanges),
                style: typo.uiSemibold.copyWith(
                  color: colors.textPrimary,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: RevericSpacing.md),
              if (changes.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: RevericSpacing.x2l,
                  ),
                  child: Text(
                    context.t(LocaleKeys.workspaceNoPendingChanges),
                    textAlign: TextAlign.center,
                    style: typo.uiSmall.copyWith(color: colors.textMuted),
                  ),
                )
              else
                RecentChangesLog(
                  databasePath: databasePath,
                  changes: changes,
                  bounded: false,
                  enableNavigation: true,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 排队消息预览：AI 回复进行中暂存的下一条消息，可立即发送或删除。
class _QueuedMessagePreview extends StatelessWidget {
  const _QueuedMessagePreview({
    required this.queuedMessage,
    required this.onSendNow,
    required this.onClear,
  });

  final QueuedChatMessage queuedMessage;
  final VoidCallback onSendNow;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final sendingNext = queuedMessage.sendOnNextTurn;
    return Container(
      margin: const EdgeInsets.fromLTRB(
        RevericSpacing.lg,
        0,
        RevericSpacing.lg,
        RevericSpacing.sm,
      ),
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.md,
        RevericSpacing.sm,
        RevericSpacing.sm,
        RevericSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Row(
        children: [
          RevericIcon(RevericIcons.clock, size: 16, color: colors.textMuted),
          const SizedBox(width: RevericSpacing.sm),
          Expanded(
            child: Text(
              context.t(
                sendingNext
                    ? LocaleKeys.aiQueuedMessageSendingNextPrefix
                    : LocaleKeys.mobileChatQueuedPrefix,
                namedArgs: {'text': queuedMessage.text},
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typo.uiSmall.copyWith(color: colors.textSecondary),
            ),
          ),
          if (!sendingNext)
            GestureDetector(
              onTap: onSendNow,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(RevericSpacing.xxs),
                child: RevericIcon(
                  RevericIcons.send_rounded,
                  size: 16,
                  color: colors.accent,
                ),
              ),
            ),
          GestureDetector(
            onTap: onClear,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(RevericSpacing.xxs),
              child: RevericIcon(
                RevericIcons.close,
                size: 16,
                color: colors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 待发送的接力上下文 chip：展示 handoff label，可清除。
class _PendingHandoffChip extends StatelessWidget {
  const _PendingHandoffChip({required this.label, required this.onClear});

  final String label;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(
        RevericSpacing.lg,
        0,
        RevericSpacing.lg,
        RevericSpacing.sm,
      ),
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.md,
        RevericSpacing.sm,
        RevericSpacing.sm,
        RevericSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Row(
        children: [
          RevericIcon(RevericIcons.link, size: 16, color: colors.textMuted),
          const SizedBox(width: RevericSpacing.sm),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typo.uiSmall.copyWith(color: colors.textSecondary),
            ),
          ),
          GestureDetector(
            onTap: onClear,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(RevericSpacing.xxs),
              child: RevericIcon(
                RevericIcons.close,
                size: 16,
                color: colors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 已附加引用条：展示当前 attachedReferences，可逐个移除。
class _AttachedReferencesBar extends StatelessWidget {
  const _AttachedReferencesBar({
    required this.references,
    required this.onRemove,
  });

  final List<AiContextReference> references;
  final ValueChanged<AiContextReference> onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
        RevericSpacing.lg,
        0,
        RevericSpacing.lg,
        RevericSpacing.sm,
      ),
      child: Wrap(
        spacing: RevericSpacing.xs,
        runSpacing: RevericSpacing.xs,
        children: [
          for (final reference in references)
            Container(
              padding: const EdgeInsets.fromLTRB(
                RevericSpacing.sm,
                3,
                RevericSpacing.xs,
                3,
              ),
              decoration: BoxDecoration(
                color: colors.surfaceContainer,
                borderRadius: BorderRadius.circular(RevericRadius.full),
                border: Border.all(color: colors.borderSubtle),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RevericIcon(
                    switch (reference.kind) {
                      AiContextReferenceKind.file =>
                        RevericIcons.description_outlined,
                      AiContextReferenceKind.selection =>
                        RevericIcons.format_quote,
                      AiContextReferenceKind.skill => RevericIcons.lightning,
                      AiContextReferenceKind.subagent =>
                        RevericIcons.smart_toy_outlined,
                      AiContextReferenceKind.agent_rule =>
                        RevericIcons.rule_outlined,
                      AiContextReferenceKind.workspace =>
                        RevericIcons.clipboard_text,
                    },
                    size: 12,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: RevericSpacing.xxs),
                  Text(
                    reference.label,
                    style: typo.uiTiny.copyWith(color: colors.textSecondary),
                  ),
                  const SizedBox(width: RevericSpacing.xxs),
                  GestureDetector(
                    onTap: () => onRemove(reference),
                    behavior: HitTestBehavior.opaque,
                    child: RevericIcon(
                      RevericIcons.close,
                      size: 12,
                      color: colors.textMuted,
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

/// 引用资源选择底部弹窗：列出章节/人物，点选切换附加状态。
Future<void> _showReferencePicker(
  BuildContext context,
  String databasePath,
  ValueNotifier<List<AiContextReference>> attached,
) {
  final colors = RevericTheme.colorsOf(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: colors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(RevericRadius.x2l),
      ),
    ),
    builder: (_) =>
        _ReferencePickerSheet(databasePath: databasePath, attached: attached),
  );
}

class _ReferencePickerSheet extends HookConsumerWidget {
  const _ReferencePickerSheet({
    required this.databasePath,
    required this.attached,
  });

  final String databasePath;
  final ValueNotifier<List<AiContextReference>> attached;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    final chapters =
        ref.watch(chaptersProvider(databasePath)).value ?? const [];
    final characters =
        ref.watch(characterProfilesProvider(databasePath)).value ?? const [];

    final chapterRefs = [
      for (final chapter in chapters)
        if ((chapter.title ?? '').trim().isNotEmpty)
          AiContextReference(
            section: NovelWorkspaceSection.chapters,
            itemId: chapter.id,
            label: chapter.title!.trim(),
          ),
    ];
    final characterRefs = [
      for (final character in characters)
        if (character.name.trim().isNotEmpty)
          AiContextReference(
            section: NovelWorkspaceSection.characters,
            itemId: character.id,
            label: character.name.trim(),
          ),
    ];

    final tabController = useTabController(initialLength: 2);
    final search = useDebouncedSearch();

    List<AiContextReference> filtered(List<AiContextReference> refs) {
      final q = search.query;
      if (q.isEmpty) {
        return refs;
      }
      return refs
          .where((ref) => ref.label.toLowerCase().contains(q))
          .toList(growable: false);
    }

    final filteredChapters = filtered(chapterRefs);
    final filteredCharacters = filtered(characterRefs);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: ValueListenableBuilder<List<AiContextReference>>(
            valueListenable: attached,
            builder: (context, current, _) {
              void toggle(AiContextReference reference) {
                if (current.contains(reference)) {
                  attached.value = [...current]..remove(reference);
                } else {
                  attached.value = [...current, reference];
                }
              }

              Widget buildList(List<AiContextReference> refs) {
                if (refs.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(RevericSpacing.lg),
                      child: Text(
                        context.t(LocaleKeys.mobileChatReferenceEmpty),
                        style: typo.uiSmall.copyWith(color: colors.textMuted),
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: RevericSpacing.lg),
                  itemCount: refs.length,
                  itemBuilder: (context, index) {
                    final reference = refs[index];
                    final selected = current.contains(reference);
                    return ListTile(
                      dense: true,
                      title: Text(
                        reference.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.body.copyWith(color: colors.textPrimary),
                      ),
                      trailing: selected
                          ? RevericIcon(
                              RevericIcons.check,
                              size: 18,
                              color: colors.accent,
                            )
                          : null,
                      onTap: () => toggle(reference),
                    );
                  },
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      RevericSpacing.lg,
                      RevericSpacing.lg,
                      RevericSpacing.lg,
                      RevericSpacing.sm,
                    ),
                    child: Text(
                      context.t(LocaleKeys.mobileChatReferenceTitle),
                      style: typo.uiSemibold.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: RevericSpacing.lg,
                    ),
                    child: RevericSearchField(
                      controller: search.controller,
                      hint: context.t(LocaleKeys.mobileChatReferenceSearch),
                      height: RevericSizes.fieldHeight,
                    ),
                  ),
                  const SizedBox(height: RevericSpacing.sm),
                  TabBar(
                    controller: tabController,
                    labelColor: colors.textPrimary,
                    unselectedLabelColor: colors.textMuted,
                    indicatorColor: colors.accent,
                    labelStyle: typo.uiSmallSemibold,
                    tabs: [
                      Tab(
                        text:
                            '${context.t(LocaleKeys.workspaceChapters)} (${filteredChapters.length})',
                      ),
                      Tab(
                        text:
                            '${context.t(LocaleKeys.workspaceCharacters)} (${filteredCharacters.length})',
                      ),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      controller: tabController,
                      children: [
                        buildList(filteredChapters),
                        buildList(filteredCharacters),
                      ],
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

/// Slash 命令建议条：分 SubAgents / Skills 两个分区，点选落成 chip。
class _SlashSuggestions extends StatelessWidget {
  const _SlashSuggestions({required this.matches, required this.onSelect});

  final List<SlashEntry> matches;
  final ValueChanged<SlashEntry> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final subagents = matches
        .where((e) => e.kind == SlashEntryKind.subagent)
        .toList(growable: false);
    final skills = matches
        .where((e) => e.kind == SlashEntryKind.skill)
        .toList(growable: false);
    return Container(
      constraints: const BoxConstraints(maxHeight: 240),
      margin: const EdgeInsets.fromLTRB(
        RevericSpacing.lg,
        0,
        RevericSpacing.lg,
        RevericSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        border: Border.all(color: colors.borderSubtle),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: RevericSpacing.xs),
        children: [
          if (subagents.isNotEmpty)
            _SlashSuggestionsSection(
              title: context.t(LocaleKeys.subagentTitle),
              entries: subagents,
              onSelect: onSelect,
            ),
          if (skills.isNotEmpty)
            _SlashSuggestionsSection(
              title: context.t(LocaleKeys.agentSkillSlashSection),
              entries: skills,
              onSelect: onSelect,
            ),
        ],
      ),
    );
  }
}

class _SlashSuggestionsSection extends StatelessWidget {
  const _SlashSuggestionsSection({
    required this.title,
    required this.entries,
    required this.onSelect,
  });

  final String title;
  final List<SlashEntry> entries;
  final ValueChanged<SlashEntry> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.lg,
            RevericSpacing.xs,
            RevericSpacing.lg,
            RevericSpacing.xxs,
          ),
          child: Text(
            title,
            style: typo.uiTinySemibold.copyWith(color: colors.textMuted),
          ),
        ),
        for (final entry in entries)
          InkWell(
            onTap: () => onSelect(entry),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.lg,
                vertical: RevericSpacing.sm + 2,
              ),
              child: Row(
                children: [
                  RevericIcon(entry.icon, size: 16, color: colors.accent),
                  const SizedBox(width: RevericSpacing.sm),
                  Text(
                    entry.command,
                    style: typo.uiSmallSemibold.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  if (entry.description.isNotEmpty) ...[
                    const SizedBox(width: RevericSpacing.sm),
                    Expanded(
                      child: Text(
                        entry.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.uiTiny.copyWith(color: colors.textMuted),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 模型选择底部弹窗：列出可用模型，点选写回当前会话。
Future<PendingChatModelSelection?> _showModelSelector(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
) async {
  final models = ref.read(availableAiModelsProvider);
  if (models.isEmpty) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(RevericRadius.x2l),
        ),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(RevericSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                sheetContext.t(LocaleKeys.mobileChatModelTitle),
                style: typo.uiSemibold.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: RevericSpacing.md),

              Text(
                sheetContext.t(LocaleKeys.mobileChatNoModels),
                style: typo.uiSmall.copyWith(color: colors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
    return null;
  }

  final current = ref.read(aiChatSessionProvider(sessionId));

  const disabledModelIds = <String>{};
  AiModelOption? selected;
  if (current.providerId != null && current.model != null) {
    for (final option in models) {
      if (option.providerId == current.providerId &&
          option.model == current.model) {
        selected = option;
        break;
      }
    }
  }

  PendingChatModelSelection? pendingSelection;

  // 两级弹窗：模型列表 → 推理模型下钻推理强度。选择暂存，下一次发送时才真正切换。
  await showAiModelEffortSheet(
    context,
    title: context.t(LocaleKeys.mobileChatModelTitle),
    subtitle: context.t(LocaleKeys.mobileChatModelSubtitle),
    models: models,
    selectedId: selected?.id,
    selectedEffort: current.reasoningEffort,
    disabledModelIds: disabledModelIds,

    onSelectModel: (option) {
      pendingSelection = PendingChatModelSelection(
        providerId: option.providerId,
        model: option.model,
        reasoningEffort: defaultReasoningEffortFor(option.reasoningEfforts),
      );
    },
    onSelectEffort: (option, effort) {
      pendingSelection = PendingChatModelSelection(
        providerId: option.providerId,
        model: option.model,
        reasoningEffort: effort,
      );
    },
  );
  return pendingSelection;
}

/// 「最近改动」点击条目后的工作区跳转：关掉 sheet，按 section push 对应 id 化编辑页。
/// push 在本聊天页之上，返回即回到聊天页。移动端无落点的 section（作品简介/地图等）忽略。
Future<void> _openWorkspaceResource(
  BuildContext context,
  WidgetRef ref,
  String databasePath,
  String novelId,
  WorkspaceNavigationRequest request,
) async {
  final navigator = Navigator.of(context);
  // 条目点击从「最近改动」sheet 内触发，sheet 必在栈顶，先关掉它。
  navigator.pop();

  final id = request.itemId;
  Widget? page;
  switch (request.section) {
    case NovelWorkspaceSection.chapters:
      if (id == null) {
        return;
      }
      // 用稳定主键 novelId 一次性直查，避免 StreamProvider.future 冷读未完成导致静默不跳转。
      final novel = await ref.read(appDatabaseProvider).novelDao.get(novelId);
      if (novel == null) {
        return;
      }
      page = MobileChapterEditorPage(
        novel: novel,
        databasePath: databasePath,
        initialChapterId: id,
      );
    case NovelWorkspaceSection.outlines:
      if (id == null) {
        return;
      }
      page = MobileOutlineEditorPage(databasePath: databasePath, outlineId: id);
    case NovelWorkspaceSection.characters:
      if (id == null) {
        return;
      }
      page = MobileCharacterEditorPage(
        databasePath: databasePath,
        characterId: id,
      );
    case NovelWorkspaceSection.foreshadowings:
      if (id == null) {
        return;
      }
      page = MobileForeshadowingEditorPage(
        novelId: novelId,
        databasePath: databasePath,
        foreshadowingId: id,
      );
    case NovelWorkspaceSection.lore:
    case NovelWorkspaceSection.materials:
    case NovelWorkspaceSection.skills:
    case NovelWorkspaceSection.items:
    case NovelWorkspaceSection.factions:
    case NovelWorkspaceSection.creatures:
      final section = _entrySectionFor(request.section);
      if (id == null || section == null) {
        return;
      }
      page = MobileEntryEditorPage(
        databasePath: databasePath,
        section: section,
        entryId: id,
      );
    // 移动端无对应独立编辑页（关系图/当前进展在小说编辑页内切分区，此处不 push）。
    case NovelWorkspaceSection.overview:
    case NovelWorkspaceSection.maps:
    case NovelWorkspaceSection.novel_description:
    case NovelWorkspaceSection.entity_graph:
    case NovelWorkspaceSection.story_progress:
    case NovelWorkspaceSection.canvas:
    case NovelWorkspaceSection.storyboard:
      return;
    case NovelWorkspaceSection.screenplay_script:
    case NovelWorkspaceSection.screenplay_outline:
    case NovelWorkspaceSection.screenplay_scenes:
      final provider = screenplayWorkspaceStateControllerProvider(
        novelId,
        databasePath,
      );
      final current = ref.read(provider);
      final section = switch (request.section) {
        NovelWorkspaceSection.screenplay_outline =>
          ScreenplayWorkspaceSection.outline,
        _ => ScreenplayWorkspaceSection.script,
      };
      // 大纲区按集寻址：id 是集 ID，写进 sceneId 会被 reconcile 丢掉。
      final isEpisodeTarget =
          request.section == NovelWorkspaceSection.screenplay_outline;
      if (isEpisodeTarget && id != null) {
        try {
          await ref.read(provider.notifier).openEpisodeOutline(id);
          if (context.mounted) {
            navigator.pop();
          }
        } catch (error, stackTrace) {
          _log.error(
            'episode outline navigation failed',
            error: error,
            stackTrace: stackTrace,
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.t(LocaleKeys.commonLoadFailed))),
            );
          }
        }
        return;
      }
      ref
          .read(provider.notifier)
          .update(
            isEpisodeTarget
                ? current.copyWith(
                    section: section,
                    episodeId: id,
                    clearEpisodeId: id == null,
                  )
                : current.copyWith(
                    section: section,
                    sceneId: id,
                    clearSceneId: id == null,
                  ),
          );
      navigator.pop();
      return;
  }

  if (!context.mounted) {
    return;
  }
  await navigator.push(MaterialPageRoute<void>(builder: (_) => page!));
}

String? _formatMobileAgentRules(List<AgentRule> rules) {
  final enabled = <AgentRule>[];
  for (final rule in rules) {
    if (rule.enabled) {
      enabled.add(rule);
    }
  }
  enabled.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  if (enabled.isEmpty) {
    return null;
  }
  return enabled
      .map((rule) => '${rule.name}：${rule.content.trim()}')
      .join('\n');
}

/// resourceType 已被还原为 [NovelWorkspaceSection]，此处再映射到移动端 entry 分区。
MobileEditorSection? _entrySectionFor(NovelWorkspaceSection section) =>
    switch (section) {
      NovelWorkspaceSection.lore => MobileEditorSection.lore,
      NovelWorkspaceSection.materials => MobileEditorSection.materials,
      NovelWorkspaceSection.skills => MobileEditorSection.skills,
      NovelWorkspaceSection.items => MobileEditorSection.items,
      NovelWorkspaceSection.factions => MobileEditorSection.factions,
      NovelWorkspaceSection.creatures => MobileEditorSection.creatures,
      _ => null,
    };

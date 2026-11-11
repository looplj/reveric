// 职责: 跨平台 AI 聊天「发送编排层」单一实现 — 队列/会话迁移/模型兜底/handoff 拼装/slash（subagent 软提示 + skill chip 直接加载）；turn 执行委托 ChatTurnRunner。
// 关联文件:
//   lib/shared/services/ai/chat_turn_runner.dart
//   lib/shared/services/ai/chat_prompt_builder.dart
//   lib/shared/models/queued_chat_message.dart
//   lib/shared/models/agent_skill.dart
//   lib/desktop/widgets/ai/chat/runtime.dart
//   lib/mobile/pages/novel_chat_page.dart
//   lib/shared/providers/ai_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/history.json
//   assets/translations/zh-CN/history.json
import 'dart:async';
import 'chat_attachments.dart';
import '../../models/models_catalog.dart';

import 'package:characters/characters.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../agent/agent.dart';
import '../../agent/message.dart';
import '../../database/app_database.dart' show Novel;
import '../../database/novel_content_database.dart'
    show ScreenplayEpisodeRow, locationTypeWorld;
import '../../localization/locale_keys.dart';
import '../../logger/app_logger.dart';
import '../../models/ai_chat_models.dart';
import '../../models/ai_provider.dart';
import '../../models/agent_skill.dart';
import '../../models/agent_skill_reference.dart';
import '../../models/content_kind.dart';
import '../../models/novel_workspace.dart';
import '../../models/queued_chat_message.dart';
import '../../models/subagent.dart';
import '../../heuristic/chat_next_action.dart';
import '../../providers/ai_providers.dart';
import '../../providers/maps_providers.dart';
import '../../providers/novel_providers.dart';
import '../../providers/production_view.dart';
import '../../providers/settings_providers.dart';
import '../../providers/subagent_providers.dart';
import '../../utils/random_id.dart';
import 'chat.dart';
import 'chat_prompt_builder.dart';
import 'chat_turn_outcome.dart';
import 'chat_turn_runner.dart';
import 'agent_message_mapping.dart';
import 'prompts/ai_prompt_service.dart';
import 'xml_utils.dart';
import 'handoff_service.dart' show sessionContinuationInstruction;

export '../../models/queued_chat_message.dart'
    show PendingChatHandoff, QueuedChatMessage;

final _log = AppLogger.forModule('ChatSessionController');

/// 收集从 [startIndex] 起会被聊天截断移除的 user turn ids。
///
/// 返回顺序为最新到最旧，保证同一资源被多轮连续改动时先撤后写入的轮次，再撤更早轮次。
List<String> rollbackTurnIdsForTruncatedMessages(
  List<AiMessage> messages,
  int startIndex,
) {
  final turnIds = <String>[];
  final seen = <String>{};
  for (var index = messages.length - 1; index >= startIndex; index--) {
    final message = messages[index];
    if (message.role != AiMessageRole.user ||
        message.type == AiMessageType.system_remind) {
      continue;
    }
    final id = message.id.trim();
    if (id.isEmpty || !seen.add(id)) {
      continue;
    }
    turnIds.add(id);
  }
  return turnIds;
}

/// 聊天 UI 卸载时把尚未 stage 的普通排队提升为下一轮消费。
///
/// 桌面折叠面板 / 返回离开、移动端 pop 都会销毁 panel-scoped 的
/// [QueuedChatMessage]；若该会话 agent 仍在跑，本函数把它 stage 进
/// runtime（processing 期间 keepAlive），避免普通排队随 UI 卸载静默丢失。
/// 已 `sendOnNextTurn`、无 agent、或 agent 已停则 no-op。
///
/// 返回 true 表示已成功 stage。
bool promoteQueuedMessageForSurvivingTurn({
  required ProviderContainer container,
  required QueuedChatMessage? queued,
}) {
  if (queued == null || queued.sendOnNextTurn) {
    return false;
  }
  final sessionId = queued.sessionId;
  if (sessionId == null || sessionId.isEmpty) {
    return false;
  }
  final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
  final agent = runtime.agent;
  if (agent == null || !agent.isProcessing) {
    return false;
  }
  final stagedMessage = queued.copyWith(sendOnNextTurn: true);
  agent.stageNextTurn(
    'queued_chat',
    AgentMessage.user(
      id: 'queued_chat',
      content: stagedMessage.modelBlocks.isEmpty ? stagedMessage.agentText : '',
      blocks: stagedMessage.modelBlocks,
    ),
  );
  runtime.stagePendingNextTurnMessage(stagedMessage);
  return true;
}

/// 当前工作区的位置上下文：资源路径可选，也可仅提供剧本季、集。
class CurrentWorkspaceContext {
  const CurrentWorkspaceContext({
    this.section,
    this.path,
    this.title,
    this.stagingId,
    this.hint = 'Read',
    this.seasonId,
    this.episodeId,
    this.episodeNumber,
    this.episodeTitle,
  });

  final NovelWorkspaceSection? section;
  final String? path;
  final String? title;
  final String? stagingId;
  final String hint;

  /// 剧本资源的归属信息：seasonId 仅多季作品填充；选中集级/场级资源时填
  /// episode 字段。无具体资源选择时，来自宿主的当前季、集。
  final String? seasonId;
  final String? episodeId;
  final int? episodeNumber;
  final String? episodeTitle;
}

/// 「快速开书」草稿状态的 novel_draft system-remind：仅 draft=true 时注入 active，
/// 用户在页面点「加入书架」清 draft 后由页面投 cleared。字符串集中在此，避免漂移。
const String novelDraftRemindKind = 'novel_draft';
const String novelDraftRemindActive =
    "<system-remind type='novel_draft' status='active' />";
const String novelDraftRemindCleared =
    "<system-remind type='novel_draft' status='cleared' />";

/// 把一条 `<system-remind>` 作为 [AiMessageType.system_remind] 的 user 消息写入会话
/// （随消息链路持久化、agent 重建时随 history 回放）；warm agent 空闲时同步注入其
/// context；运行中排到下一轮，确保 tool_result 先闭合历史。冷启动由重建路径覆盖，
/// 无需注入。发送失败/取消后该消息保留：它描述的是运行时状态，且已与持久化一致。
///
/// 供 [ChatSessionController] 与页面级动作（如「加入书架」按钮）共用，保持单一投递入口。
void deliverSystemRemindToSession(
  ProviderContainer container,
  String? sessionId,
  String remind, {
  required String kind,
}) {
  final message = container
      .read(aiChatSessionProvider(sessionId).notifier)
      .addUserMessage(
        remind,
        id: 'system_remind_${kind}_${DateTime.now().microsecondsSinceEpoch}',
        type: AiMessageType.system_remind,
      );
  final agent = container.read(aiChatRuntimeProvider(sessionId).notifier).agent;
  if (agent == null) {
    return;
  }
  final agentMessage = AgentMessage.user(id: message.id, content: remind);
  // da7e58ef: 运行中禁止直写 context，否则会插在未闭合的 tool_call/tool_result 之间。
  if (agent.isProcessing) {
    agent.stageNextTurn(message.id, agentMessage);
    return;
  }
  agent.contextManager.addMessages([agentMessage]);
}

/// Checks the most recent current-workspace-context reminder only.
///
/// A session intentionally keeps historical reminders, so scanning with
/// `any` would mistake an old selection for the current context after the user
/// switches A → B → A. The last reminder describes the complete workspace context
/// at the tail of the conversation context.
String? _latestCurrentWorkspaceContextReminder(List<AiMessage> messages) {
  for (var index = messages.length - 1; index >= 0; index--) {
    final message = messages[index];
    if (message.type != AiMessageType.system_remind) {
      continue;
    }
    final text = message.effectiveText.trim();
    if (!_isCurrentWorkspaceContextReminder(text)) {
      continue;
    }
    return text;
  }
  return null;
}

bool _isCurrentWorkspaceContextReminder(String text) {
  return text.startsWith("<system-remind type='current_workspace_context'") ||
      text.startsWith('<system-remind type="current_workspace_context"');
}

/// current_date remind 的日期串（YYYY-MM-DD，月/日两位补零）。
/// chat 与 assistant 通道共用，保证投递与去重比较使用同一格式。
String currentDateRemindDateString(DateTime now) =>
    '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

/// 构造 current_date system-remind：environment 块删除后由它按需告知模型「今天」。
String buildCurrentDateRemind(String date) =>
    "<system-remind type='current_date' date='$date' />";

/// Checks the most recent current-date reminder only（同 workspace remind 的
/// 「只看最后一条」模式）：跨天后最后一条的日期不再匹配，下一次主动 send 会
/// 重新注入今天的日期。
bool hasLatestCurrentDateReminder(List<AiMessage> messages, String date) {
  for (var index = messages.length - 1; index >= 0; index--) {
    final message = messages[index];
    if (message.type != AiMessageType.system_remind) {
      continue;
    }
    final text = message.effectiveText.trim();
    if (!_isCurrentDateReminder(text)) {
      continue;
    }
    final reminded = _currentDateRemindDate(text);
    return reminded != null && reminded == date;
  }
  return false;
}

bool _isCurrentDateReminder(String text) {
  return text.startsWith("<system-remind type='current_date'") ||
      text.startsWith('<system-remind type="current_date"');
}

String? _currentDateRemindDate(String text) {
  final match = RegExp("date=['\\\"]([^\\\"]+)['\\\"]").firstMatch(text);
  return match?.group(1);
}

/// 发送编排读到的稳定作用域数据（取代散落的 `widget.xxx`）。
class ChatScope {
  const ChatScope({
    required this.activeSessionId,
    required this.novel,
    required this.databasePath,
    this.workspaceSection,
    this.workspaceItemId,
    this.workspaceTitle,
  });

  final String? activeSessionId;
  final Novel novel;
  final String? databasePath;
  final NovelWorkspaceSection? workspaceSection;
  final String? workspaceItemId;
  final String? workspaceTitle;
}

/// 将聊天发送门禁原因归类为稳定的失败码。
@visibleForTesting
String classifyChatBlockedFailureCode({
  required String? providerId,
  required String? model,
  required AiProvider? config,
}) {
  if (providerId == null || model == null) {
    return 'model_unavailable';
  }
  if (config == null || !config.enabled) {
    return 'feature_not_enabled';
  }
  if (!config.hasCredentialConfiguration) {
    return 'api_key_missing';
  }
  if (!config.availableModels.contains(model)) {
    return 'model_unavailable';
  }
  return 'feature_not_enabled';
}

/// 真正触碰 UI 的副作用 + 平台专属动作，注入回调；移动端给空/部分实现。
class ChatHost {
  const ChatHost({
    required this.clearComposer,
    required this.focusComposer,
    required this.openModelSelector,
    required this.resetScroll,
    required this.isMounted,
    this.onActiveSessionIdChanged,
    this.onComposerWarning,
    this.restoreComposerText,
    this.encodeComposerBlocks,
    this.onContextCompacted,
    this.onContextSettled,
  });

  /// 清空输入框（桌面 `composerController.clear()`）。
  final void Function() clearComposer;

  /// 输入框聚焦（桌面 `composerFocusNode.requestFocus()`）。
  final void Function() focusComposer;

  /// 打开模型选择（桌面 `modelSelectorOpenTrigger++`；移动端底部弹窗）。
  final void Function() openModelSelector;

  /// 重置滚动到底（桌面 `userScrolledUp=false`）。
  final void Function() resetScroll;

  /// 替代散落的 `context.mounted` 守卫。
  final bool Function() isMounted;

  /// 会话迁移（临时→持久）后通知外部切换 activeSessionId。
  final Future<void> Function(String?)? onActiveSessionIdChanged;

  /// 可恢复错误提示（桌面写 composer notice）。
  final void Function(String message)? onComposerWarning;

  /// 错误后将用户输入恢复到输入框（桌面 set composerController.text）。
  /// 若输入框已有内容则先追加换行。
  final void Function(String text)? restoreComposerText;
  final String Function(List<AiMessageBlock>)? encodeComposerBlocks;

  /// 每次成功压缩后立即回写上下文，保留同一 turn 内的每条摘要。
  final void Function(Agent agent)? onContextCompacted;

  /// 一轮结束后回写压缩上下文（桌面 `_syncPersistedContextState`）。
  final void Function(Agent agent)? onContextSettled;
}

/// 跨发送存活的编排输入态访问（不规定存储位置）。
///
/// 桌面用适配器包住 panel-scoped 的 `AiChatPanelState` notifier（存储不迁移）；
/// 移动端用 [DefaultChatComposerStore]（普通字段）。
abstract class ChatComposerStore {
  List<AiContextReference> get attachedReferences;
  set attachedReferences(List<AiContextReference> value);

  PendingChatHandoff? get pendingHandoff;
  set pendingHandoff(PendingChatHandoff? value);

  QueuedChatMessage? get queuedMessage;
  set queuedMessage(QueuedChatMessage? value);

  /// 按运行中的会话读取队列。默认实现适用于只有单一会话视图的移动端。
  QueuedChatMessage? queuedMessageForSession(String? sessionId) =>
      queuedMessage;

  /// 按运行中的会话更新队列。桌面面板覆盖此方法以保留各会话独立的队列。
  void setQueuedMessageForSession(
    String? sessionId,
    QueuedChatMessage? message,
  ) {
    queuedMessage = message;
  }

  DateTime? get sendGuardUntil;
  set sendGuardUntil(DateTime? value);
}

/// 用户已选择、等待随下一条消息应用的会话模型。
///
/// 切换不能发生在选择时：只有真正发送时才释放旧 runtime、清理旧 provider 的私有
/// 推理状态并写回新的模型配置。
class PendingChatModelSelection {
  const PendingChatModelSelection({
    required this.providerId,
    required this.model,
    this.reasoningEffort,
  });

  final String providerId;
  final String model;
  final String? reasoningEffort;

  bool hasSameModelAs(AiChatSessionState session) =>
      providerId == session.providerId && model == session.model;
}

/// 普通字段实现，供移动端等不需要 UI 观察这些状态的场景使用。
class DefaultChatComposerStore implements ChatComposerStore {
  @override
  List<AiContextReference> attachedReferences = const [];

  @override
  PendingChatHandoff? pendingHandoff;

  @override
  QueuedChatMessage? queuedMessage;

  @override
  QueuedChatMessage? queuedMessageForSession(String? sessionId) =>
      queuedMessage;

  @override
  void setQueuedMessageForSession(
    String? sessionId,
    QueuedChatMessage? message,
  ) {
    queuedMessage = message;
  }

  @override
  DateTime? sendGuardUntil;
}

/// 架在 [ChatTurnRunner] 之上的共享「发送编排层」。
///
/// 桌面与移动端共用同一份发送/重试/取消编排，回到单一实现。每次发送/重试/取消
/// 临时构造一个薄对象（与原 `_buildChatTurnRunner` 同样 ephemeral），不持久。
class ChatSessionController {
  ChatSessionController({
    required this.container,
    required this.scope,
    required this.host,
    required this.store,
    required this.promptBuilder,
    required this.availableSubAgents,
    this.availableSkills = const [],
    required this.aiPromptService,
    required AiSessionContext promptContext,
    this.nextActionEnvironment = const ChatNextActionEnvironment(),
    this.supportsNextActionSuggestions = false,
  }) : promptContext = promptContext
           .copyWith(databasePath: scope.databasePath)
           .withWork(scope.novel);

  final ProviderContainer container;
  final ChatScope scope;
  final ChatHost host;
  final ChatComposerStore store;
  final ChatPromptBuilder promptBuilder;
  final List<SubAgent> availableSubAgents;

  /// slash 面板可加载的技能（与菜单同源）。用于把 skill chip 解析成完整指令直接注入。
  final List<SkillDefinition> availableSkills;
  final AiPromptService aiPromptService;
  final AiSessionContext promptContext;

  String _queuedDraftText(QueuedChatMessage message) => message.blocks.isEmpty
      ? message.text
      : host.encodeComposerBlocks?.call(message.blocks) ?? message.agentText;

  Future<List<AiMessageBlock>?> _prepareAttachments(
    String? sessionId,
    String text,
    ChatDraft? draft,
    List<AiMessageBlock> saved,
  ) async {
    final session = container.read(aiChatSessionProvider(sessionId));
    final hasImages =
        draft?.hasImages == true ||
        saved.whereType<AiAttachmentBlock>().any((b) => b.isImage);
    final historyHasImages = messagesSinceLatestCompact(
      session.messages,
    ).any((m) => m.blocks.whereType<AiAttachmentBlock>().any((b) => b.isImage));
    if ((hasImages || historyHasImages) &&
        session.model != null &&
        lookupCatalogImageInput(session.model!) == false) {
      host.onComposerWarning?.call(tr(LocaleKeys.aiAttachmentModelUnsupported));
      return null;
    }
    if (saved.isNotEmpty || draft == null || draft.attachments.isEmpty) {
      return saved;
    }
    try {
      if (sessionId == null || isTemporaryAiChatSessionId(sessionId)) {
        throw const ChatAttachmentException('session_missing');
      }
      final prepared = await ChatAttachmentOrchestrator().prepare(
        sessionId,
        ChatDraft(text, draft.attachments),
        novelId: scope.novel.id,
      );
      await hydrateChatBlocks(prepared, strict: true);
      return prepared;
    } on ChatAttachmentException {
      host.onComposerWarning?.call(tr(LocaleKeys.aiAttachmentFailed));
      return null;
    }
  }

  /// 下一步建议开关与宿主能力，由 UI 宿主解析后注入 [ChatTurnRunner]。
  final ChatNextActionEnvironment nextActionEnvironment;
  final bool supportsNextActionSuggestions;

  /// 发送一条消息（含 in-flight 排队、临时→持久会话迁移、模型兜底、references/handoff
  /// 拼装、slash）。行为与原桌面 `_handleSendMessageWithReferences` 一致。
  Future<void> send(
    String text, {
    ChatDraft? draft,
    List<AiMessageBlock> attachmentBlocks = const [],
    String? sessionIdOverride,
    List<AiContextReference>? overrideReferences,
    PendingChatHandoff? overrideHandoff,
    PendingChatModelSelection? pendingModelSelection,
  }) async {
    final sessionId = sessionIdOverride ?? scope.activeSessionId;
    final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
    final release = runtime.retainSessionEntry();
    enableCompletionDelivery(sessionId);
    try {
      await _send(
        text,
        draft: draft,
        attachmentBlocks: attachmentBlocks,
        sessionIdOverride: sessionIdOverride,
        overrideReferences: overrideReferences,
        overrideHandoff: overrideHandoff,
        pendingModelSelection: pendingModelSelection,
      );
    } finally {
      release();
    }
  }

  /// 完成结果使用普通聊天 runner；没有自动回答 AskUser 的 headless handler。
  void enableCompletionDelivery(String? sessionId) {
    container
        .read(aiChatRuntimeProvider(sessionId).notifier)
        .configureCompletionDelivery(
          (sourceTurnId) => _deliverCompletions(sessionId, sourceTurnId),
        );
  }

  Future<bool> _deliverCompletions(
    String? sessionId,
    String sourceTurnId,
  ) async {
    final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
    final state = container.read(aiChatRuntimeProvider(sessionId));
    if (runtime.hasActiveRequest || state.isSessionMutationInFlight) {
      return true;
    }
    final hasOrigin = container
        .read(aiChatSessionProvider(sessionId))
        .messages
        .any(
          (message) =>
              message.id == sourceTurnId &&
              message.role == AiMessageRole.user &&
              message.type != AiMessageType.system_remind,
        );
    if (!hasOrigin) {
      runtime.operations.revokeCompletions({sourceTurnId});
      for (final notice in state.subAgents.pending) {
        if (notice.run.sourceTurnId == sourceTurnId) {
          runtime.subAgents.cancelRun(
            notice.run.runId,
            source: 'origin_removed',
          );
        }
      }
      return true;
    }
    final requestId = runtime.startRequest();
    final sessionLease = container.listen(
      aiChatSessionProvider(sessionId),
      (_, _) {},
    );
    try {
      final outcome = await _buildTurnRunner().runTurn(
        '',
        requestId: requestId,
        sessionId: sessionId,
        sourceTurnId: sourceTurnId,
        completionInput: true,
      );
      if (outcome.isFailed) {
        runtime.invalidateAgent();
        if (host.isMounted() && outcome.error != null) {
          host.onComposerWarning?.call(outcome.error!.safeMessage);
        }
      }
      return !outcome.isFailed;
    } finally {
      try {
        runtime.markRequestIdle(requestId);
        await _flushQueuedMessageAfterRequest(sessionId, requestId);
      } finally {
        sessionLease.close();
      }
    }
  }

  Future<void> _send(
    String text, {
    ChatDraft? draft,
    List<AiMessageBlock> attachmentBlocks = const [],
    String? sessionIdOverride,
    List<AiContextReference>? overrideReferences,
    PendingChatHandoff? overrideHandoff,
    PendingChatModelSelection? pendingModelSelection,
  }) async {
    final serviceUnavailableText = tr(LocaleKeys.aiServiceUnavailable);
    final trimmedText = text.trim();
    // 请求完成后的排队接力必须使用实际运行请求的 session id。移动端首次发送
    // 会把临时 id 物化为真实 id，但当前 controller 的 scope 是按发送开始时创建的，
    // 不能在接力时再次读取已过期的临时 id。
    var targetSessionId = sessionIdOverride ?? scope.activeSessionId;
    var runtimeState = container.read(aiChatRuntimeProvider(targetSessionId));
    var runtime = container.read(
      aiChatRuntimeProvider(targetSessionId).notifier,
    );
    ProviderSubscription<AiChatSessionState>? sessionKeepAlive;
    var didMigrateToPersistedSession = false;
    final sendWatch = Stopwatch()..start();
    void logSendTiming(String stage, [String extra = '']) => _log.info(
      'send timing stage=$stage elapsedMs=${sendWatch.elapsedMilliseconds} '
      'sessionId=$targetSessionId attachments=${draft?.attachments.length ?? 0} '
      'savedBlocks=${attachmentBlocks.length}$extra',
    );
    if (runtimeState.isSessionMutationInFlight) {
      _log.info(
        'send ignored while session history mutation is in progress '
        'sessionId=$targetSessionId',
      );
      return;
    }
    if (runtime.hasActiveRequest) {
      // 模型切换只在 idle 时的 send 里应用（见 _applyPendingModelSelection）。
      // 首轮调用会 await 整个 Agent turn 后才清掉 UI 暂存 selection；这期间的
      // 排队发送可能再次携带同一个旧值。它已经归当前请求消费，不能阻断排队，
      // 也不能在运行中再次切换模型。
      if (pendingModelSelection != null) {
        _log.warning(
          'dropping pendingModelSelection on queued/in-flight send '
          'sessionId=$targetSessionId provider=${pendingModelSelection.providerId} '
          'model=${pendingModelSelection.model}',
        );
      }
      final pendingHandoff = overrideHandoff ?? store.pendingHandoff;
      if (trimmedText.isEmpty && pendingHandoff == null) {
        final guardUntil = store.sendGuardUntil;
        if (guardUntil != null && DateTime.now().isBefore(guardUntil)) {
          _log.info('send guard active, ignoring empty send');
          return;
        }
        _log.info('empty send while in-flight, cancelling active request');
        cancel(targetSessionId);
        return;
      }

      // 同时只允许一条排队消息；已有队列或附件准备中时拒绝，由 UI 禁用发送。
      if (runtime.isPreparingQueuedMessage ||
          runtime.queuedMessage != null ||
          store.queuedMessage != null) {
        _log.info('queue occupied, ignoring send while in-flight');
        return;
      }

      final refs = List<AiContextReference>.from(
        overrideReferences ?? store.attachedReferences,
      );
      _log.info(
        'building message: text="$text" refs=${refs.length} '
        'pendingHandoff=$pendingHandoff',
      );
      final queuedAgentText = _buildAgentTextWithHandoff(
        trimmedText,
        _contentRefsOnly(refs),
        pendingHandoff,
      );
      List<AiMessageBlock>? blocks;
      List<MessageBlock> modelBlocks;
      runtime.isPreparingQueuedMessage = true;
      try {
        blocks = await _prepareAttachments(
          targetSessionId,
          queuedAgentText,
          draft,
          attachmentBlocks,
        );
        if (blocks == null) {
          return;
        }
        modelBlocks = blocks.isEmpty
            ? <MessageBlock>[]
            : await hydrateChatBlocks(blocks, strict: true);
      } on ChatAttachmentException {
        host.onComposerWarning?.call(tr(LocaleKeys.aiAttachmentFailed));
        return;
      } finally {
        runtime.isPreparingQueuedMessage = false;
        logSendTiming('queued_attachments_prepared');
      }
      // The active turn can finish while the file is being decoded/copied.
      // In that case dispatch directly; there is no future queue-flush callback.
      if (!runtime.hasActiveRequest) {
        await _send(
          text,
          attachmentBlocks: blocks,
          sessionIdOverride: targetSessionId,
          overrideReferences: overrideReferences,
          overrideHandoff: overrideHandoff,
        );
        return;
      }
      if (host.isMounted() && overrideReferences == null) {
        store.attachedReferences = [];
      }
      if (host.isMounted() && overrideHandoff == null) {
        store.pendingHandoff = null;
      }
      final queued = QueuedChatMessage(
        text: blocks.isEmpty ? trimmedText : chatBlocksText(blocks),
        agentText: blocks.isEmpty ? queuedAgentText : chatBlocksText(blocks),
        blocks: blocks,
        modelBlocks: modelBlocks,
        userMessageId: buildRandomId('msg'),
        references: refs,
        sessionId: targetSessionId,
        handoff: pendingHandoff,
      );
      runtime.queuedMessage = queued;
      if (host.isMounted()) {
        store.queuedMessage = queued;
      }
      runtime.onQueuedMessageTaken = () {
        if (host.isMounted()) {
          store.setQueuedMessageForSession(targetSessionId, null);
        }
      };
      // workspace system-remind 只随用户主动发出的 turn 一起投递；
      // 排队阶段不单独注入，等 finally 里真正 send 时再带上。
      if (host.isMounted()) {
        host.clearComposer();
        host.focusComposer();
      }
      return;
    }
    final pendingHandoff = overrideHandoff ?? store.pendingHandoff;
    if (trimmedText.isEmpty && pendingHandoff == null) {
      _log.info(
        'send: early return text="$text" pendingHandoff=$pendingHandoff',
      );
      return;
    }
    final proposedModel =
        pendingModelSelection?.model ??
        container.read(aiChatSessionProvider(targetSessionId)).model;
    final retained = messagesSinceLatestCompact(
      container.read(aiChatSessionProvider(targetSessionId)).messages,
    );
    if (proposedModel != null &&
        lookupCatalogImageInput(proposedModel) == false &&
        (draft?.hasImages == true ||
            attachmentBlocks.whereType<AiAttachmentBlock>().any(
              (b) => b.isImage,
            ) ||
            retained.any(
              (m) =>
                  m.blocks.whereType<AiAttachmentBlock>().any((b) => b.isImage),
            ))) {
      host.onComposerWarning?.call(tr(LocaleKeys.aiAttachmentModelUnsupported));
      return;
    }
    logSendTiming('image_model_checked');
    var currentSession = await _applyPendingModelSelection(
      sessionId: targetSessionId,
      pending: pendingModelSelection,
    );
    if (currentSession == null) {
      return;
    }
    currentSession = await _ensureSendModelSelection(targetSessionId);
    if (currentSession == null) {
      return;
    }

    logSendTiming('model_and_auth_checked');
    final materialized = await _materializeSessionForSend(
      targetSessionId: targetSessionId,
      draft: currentSession,
    );
    if (materialized == null) {
      return;
    }
    logSendTiming('session_materialized');
    targetSessionId = materialized.sessionId;
    currentSession = materialized.session;
    didMigrateToPersistedSession = materialized.didCreate;
    runtime = container.read(aiChatRuntimeProvider(targetSessionId).notifier);
    runtimeState = container.read(aiChatRuntimeProvider(targetSessionId));
    if (runtime.hasActiveRequest && !runtimeState.isSessionMutationInFlight) {
      // 准备期间另一条用户发送取得了执行入口；保留本条消息并走同一排队路径。
      await _send(
        text,
        draft: draft,
        attachmentBlocks: attachmentBlocks,
        sessionIdOverride: targetSessionId,
        overrideReferences: overrideReferences,
        overrideHandoff: overrideHandoff,
      );
      return;
    }
    if (runtime.hasActiveRequest || runtimeState.isSessionMutationInFlight) {
      _log.info(
        'session became busy while materializing; '
        'ignoring concurrent send sessionId=$targetSessionId',
      );
      return;
    }

    final refs = overrideReferences ?? store.attachedReferences;

    final hadMessages = currentSession.messages.isNotEmpty;
    final requestId = runtime.startRequest();
    enableCompletionDelivery(targetSessionId);
    sessionKeepAlive = container.listen(
      aiChatSessionProvider(targetSessionId),
      (_, _) {},
    );
    final temporarySignal = materialized.temporarySignal;
    // 认领临时 signal、或本轮刚新建 session，两种情况都必须把真实 id 交还父级。
    // 只判 temporarySignal 会漏掉 activeSessionId 为 null 时直接 create 的路径：
    // 那条路上新建的 session 无人认领，消息写进去也没人订阅。
    if (temporarySignal != null || materialized.didCreate) {
      try {
        // 父级切换会卸载当前 chat panel；必须先让本轮请求持有真实 session，
        // 否则 autoDispose 会在 runner 读取模型前清掉刚初始化的 state。
        await host.onActiveSessionIdChanged!(targetSessionId);
        if (temporarySignal != null) {
          releaseAiChatNewSessionId(
            novelId: scope.novel.id,
            signal: temporarySignal,
          );
        }
      } catch (error, stackTrace) {
        _log.error(
          'failed to adopt materialized chat session '
          'sessionId=$targetSessionId signal=$temporarySignal',
          error: error,
          stackTrace: stackTrace,
        );
        host.onComposerWarning?.call(tr(LocaleKeys.aiRequestFailed));
        runtime.markRequestIdle(requestId, notifyOnComplete: false);
        sessionKeepAlive.close();
        return;
      }
    }
    store.sendGuardUntil = DateTime.now().add(
      const Duration(milliseconds: 400),
    );
    final runner = _buildTurnRunner();
    AiClient? aiService;
    var notifyOnComplete = false;
    var turnStarted = false;
    var restoreContinuation = false;
    var sentBlocks = const <AiMessageBlock>[];
    try {
      aiService = await runner.resolveAiService(
        requestId: requestId,
        sessionId: targetSessionId,
      );
      if (aiService == null) {
        _notifySendBlocked(currentSession);
        return;
      }

      logSendTiming('ai_service_resolved');
      runtime.attachAiService(aiService);

      if (didMigrateToPersistedSession) {
        await runner.reportSessionStart(currentSession);
      }

      notifyOnComplete = true;
      final slashCommand = _matchSlashCommand(trimmedText, availableSubAgents);
      final userMessageText = _buildAgentTextWithHandoff(
        trimmedText,
        _contentRefsOnly(refs),
        pendingHandoff,
      );
      final blocks = await _prepareAttachments(
        targetSessionId,
        userMessageText,
        draft,
        attachmentBlocks,
      );
      if (blocks == null || runtime.cancelledRequestIds.contains(requestId)) {
        notifyOnComplete = false;
        return;
      }
      logSendTiming('attachments_prepared', ' blocks=${blocks.length}');
      sentBlocks = blocks;
      final agent = await runner.getOrCreateChatAgent(
        sessionId: targetSessionId,
      );
      logSendTiming('agent_ready');
      if (agent == null) {
        container
            .read(aiChatSessionProvider(targetSessionId).notifier)
            .addAssistantMessage(
              serviceUnavailableText,
              type: AiMessageType.text,
            );
        return;
      }

      // agent 已确认可用，先投递 system-remind（持久化 + warm context），
      // 再落用户消息，保证 remind 在 agent history 中先于本轮输入。
      await _deliverCurrentContextReminds(targetSessionId);
      _deliverNovelDraftRemind(targetSessionId);
      final slashRemind = _buildSlashCommandRemind(slashCommand);
      if (slashRemind != null) {
        _deliverSystemRemind(
          targetSessionId,
          slashRemind,
          kind: 'slash_subagent_hint',
        );
      }
      _deliverSlashChipReminds(targetSessionId, refs);
      logSendTiming('reminds_delivered');

      // slash chip（skill / subagent）名写入用户消息 metadata，供聊天记录气泡展示（随消息持久化）。
      final userMessage = container
          .read(aiChatSessionProvider(targetSessionId).notifier)
          .addUserMessage(
            blocks.isEmpty ? userMessageText : chatBlocksText(blocks),
            blocks: blocks,
            metadata: slashChipsMetadataFromReferences(refs),
          );

      logSendTiming('user_message_added');
      // Consume the draft only after initialization and user-message creation succeed.
      if (overrideReferences == null) {
        store.attachedReferences = [];
      }
      if (overrideHandoff == null) {
        store.pendingHandoff = null;
      }
      if (host.isMounted()) {
        host.clearComposer();
        host.focusComposer();
      }

      // 发送后强制贴底：清除「用户上滑」标记，让新用户消息与随后的流式回复滚入视图。
      if (host.isMounted()) {
        host.resetScroll();
      }

      final titleInstruction =
          trimmedText.isEmpty && pendingHandoff?.isSessionContinuation == true
          ? sessionContinuationInstruction
          : blocks.isEmpty
          ? trimmedText
          : chatBlocksText(blocks);
      if (!hadMessages && titleInstruction.isNotEmpty) {
        _maybeGenerateSessionTitle(targetSessionId, titleInstruction);
      }

      turnStarted = true;
      final outcome = await runner.runTurn(
        userMessage.content,
        requestId: requestId,
        sessionId: targetSessionId,
        userMessageId: userMessage.id,
        sourceTurnId: userMessage.id,
      );

      restoreContinuation = outcome.isFailed;
      if (outcome.isFailed && outcome.error != null) {
        // 失败保留用户消息：本轮可能已落库或已有工具改动，删 UI 消息既不回滚
        // 作品改动也不删 DB 行，只会让两边分叉、弄断轮次回退锚点。需要撤回时走
        // 用户消息上的常驻回退入口 rollbackTurnAndPrepareResend（回滚改动 +
        // 截断会话 + 回填 prompt），由用户决定是否连带回滚。
        runtime.invalidateAgent();
        if (host.isMounted()) {
          host.onComposerWarning?.call(outcome.error!.safeMessage);
        }
      }
    } catch (error) {
      restoreContinuation = turnStarted;

      rethrow;
    } finally {
      if (restoreContinuation &&
          pendingHandoff?.isSessionContinuation == true &&
          host.isMounted()) {
        store.pendingHandoff ??= pendingHandoff;
        store.attachedReferences = [
          ...refs.where((ref) => !store.attachedReferences.contains(ref)),
          ...store.attachedReferences,
        ];
        // clearComposer dropped the attachment atoms; rebuild them from blocks.
        host.restoreComposerText?.call(
          sentBlocks.isEmpty
              ? trimmedText
              : host.encodeComposerBlocks?.call(sentBlocks) ?? trimmedText,
        );
      }
      sessionKeepAlive.close();
      container
          .read(aiChatRuntimeProvider(targetSessionId).notifier)
          .markRequestIdle(requestId, notifyOnComplete: notifyOnComplete);
      if (aiService != null) {
        container
            .read(aiChatRuntimeProvider(targetSessionId).notifier)
            .clearAiService(aiService);
      }
      await _flushQueuedMessageAfterRequest(targetSessionId, requestId);
    }
  }

  Future<
    ({
      String sessionId,
      AiChatSessionState session,
      bool didCreate,
      String? temporarySignal,
    })?
  >
  _materializeSessionForSend({
    required String? targetSessionId,
    required AiChatSessionState draft,
  }) async {
    final currentId = draft.sessionId ?? targetSessionId;
    if (currentId != null && !isTemporaryAiChatSessionId(currentId)) {
      return (
        sessionId: currentId,
        session: draft,
        didCreate: false,
        temporarySignal: null,
      );
    }

    final databasePath = scope.databasePath;
    final novelId = scope.novel.id;
    if (databasePath == null || databasePath.isEmpty) {
      _log.error(
        'cannot materialize chat session: missing novel persistence '
        'temporarySessionId=$currentId novelId=$novelId',
      );
      host.onComposerWarning?.call(tr(LocaleKeys.aiRequestFailed));
      return null;
    }

    final signal = currentId != null && isTemporaryAiChatSessionId(currentId)
        ? currentId
        : null;
    // 走到这里说明必须新建(或认领)一个真实 session，调用方**一定**要能接住新 id：
    // 消息全部写进 `aiChatSessionProvider(<新 id>)`，父级不更新 activeSessionId 的话
    // UI 仍订阅旧 key，会出现「日志里 turn 正常跑完、界面停在空态」的静默故障。
    // 早先这里只挡了 signal != null 的临时 id 路径，activeSessionId 直接为 null 的
    // 调用方(canvas 页)从这里静默漏了过去。
    if (host.onActiveSessionIdChanged == null) {
      _log.error(
        'cannot materialize chat session without an adoption callback '
        'temporarySessionId=$signal novelId=$novelId',
      );
      host.onComposerWarning?.call(tr(LocaleKeys.aiRequestFailed));
      return null;
    }
    var createdByThisCall = false;
    Future<String> create() async {
      createdByThisCall = true;
      final sessionId = buildRandomId('ai_session');
      final title = draft.title.trim().isEmpty
          ? tr(LocaleKeys.aiSessionTitleDefault)
          : draft.title;
      final persistence = container.read(
        aiSessionPersistenceServiceProvider(
          novelId: novelId,
          databasePath: databasePath,
        ),
      );
      await persistence.createActiveSession(
        id: sessionId,
        title: title,
        provider: draft.providerId,
        model: draft.model,
        mode: draft.sessionMode.value,
        agentSlug: draft.agentSlug,
        reasoningEffort: draft.reasoningEffort,
      );
      container
          .read(aiChatSessionProvider(sessionId).notifier)
          .startNewSession(
            sessionId: sessionId,
            title: title,
            providerId: draft.providerId,
            model: draft.model,
            reasoningEffort: draft.reasoningEffort,
            sessionMode: draft.sessionMode,
            agentSlug: draft.agentSlug,
          );
      return sessionId;
    }

    try {
      final sessionId = signal == null
          ? await create()
          : await materializeAiChatNewSession(
              novelId: novelId,
              signal: signal,
              create: create,
            );
      final session = container.read(aiChatSessionProvider(sessionId));
      return (
        sessionId: sessionId,
        session: session,
        didCreate: createdByThisCall,
        temporarySignal: signal,
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] CREATE ai_chat_sessions failed '
        'temporarySessionId=$currentId novelId=$novelId '
        'databasePath=$databasePath',
        error: error,
        stackTrace: stackTrace,
      );
      host.onComposerWarning?.call(tr(LocaleKeys.aiRequestFailed));
      return null;
    }
  }

  Future<AiChatSessionState?> _applyPendingModelSelection({
    required String? sessionId,
    required PendingChatModelSelection? pending,
  }) async {
    if (pending == null) {
      return container.read(aiChatSessionProvider(sessionId));
    }

    final current = container.read(aiChatSessionProvider(sessionId));
    final modelChanged = !pending.hasSameModelAs(current);
    final effortChanged = pending.reasoningEffort != current.reasoningEffort;
    if (!modelChanged && !effortChanged) {
      return current;
    }

    final runtimeState = container.read(aiChatRuntimeProvider(sessionId));
    if (runtimeState.isRequestInFlight ||
        runtimeState.activeToolExecutions > 0) {
      _log.warning(
        'model switch rejected while request is active '
        'sessionId=$sessionId inFlight=${runtimeState.isRequestInFlight} '
        'toolExecutions=${runtimeState.activeToolExecutions}',
      );
      return null;
    }

    final messages = modelChanged
        ? stripProviderPrivateConversationState(current.messages)
        : current.messages;
    final persistedSessionId = current.sessionId;
    final databasePath = scope.databasePath;
    final novelId = scope.novel.id;
    if (persistedSessionId != null &&
        !isTemporaryAiChatSessionId(persistedSessionId) &&
        databasePath != null &&
        databasePath.isNotEmpty) {
      final persistence = container.read(
        aiSessionPersistenceServiceProvider(
          novelId: novelId,
          databasePath: databasePath,
        ),
      );
      final novelDatabase = container.read(
        novelContentDatabaseProvider(databasePath),
      );
      var didSaveSanitizedMessages = false;
      try {
        if (modelChanged) {
          await persistence.saveMessages(
            sessionId: persistedSessionId,
            messages: messages,
            novelDatabase: novelDatabase,
          );
          didSaveSanitizedMessages = true;
        }
        await persistence.updateModelSelection(
          id: persistedSessionId,
          provider: pending.providerId,
          model: pending.model,
          reasoningEffort: pending.reasoningEffort,
        );
      } catch (error, stackTrace) {
        if (didSaveSanitizedMessages) {
          try {
            await persistence.saveMessages(
              sessionId: persistedSessionId,
              messages: current.messages,
              novelDatabase: novelDatabase,
            );
          } catch (restoreError, restoreStackTrace) {
            _log.error(
              '[DB] RESTORE ai_chat_messages after model switch failure '
              'sessionId=$persistedSessionId',
              error: restoreError,
              stackTrace: restoreStackTrace,
            );
          }
        }
        _log.error(
          '[DB] SWITCH ai_chat_sessions failed '
          'sessionId=$persistedSessionId provider=${pending.providerId} '
          'model=${pending.model}',
          error: error,
          stackTrace: stackTrace,
        );
        return null;
      }
    }

    container
        .read(aiChatRuntimeProvider(sessionId).notifier)
        .cancel(source: AiChatCancelSource.modelSwitch);
    container
        .read(aiChatSessionProvider(sessionId).notifier)
        .applyModelSwitch(
          providerId: pending.providerId,
          model: pending.model,
          reasoningEffort: pending.reasoningEffort,
          messages: messages,
        );
    return container.read(aiChatSessionProvider(sessionId));
  }

  /// 重试某条失败的 assistant 消息（复用其前一条用户消息文本）。
  /// 行为与原桌面 `_retryAssistantMessage` 一致。
  Future<void> retry(String assistantMessageId) async {
    final runtime = container.read(
      aiChatRuntimeProvider(scope.activeSessionId).notifier,
    );
    final release = runtime.retainSessionEntry();
    enableCompletionDelivery(scope.activeSessionId);
    try {
      await _retry(assistantMessageId);
    } finally {
      release();
    }
  }

  Future<void> _retry(String assistantMessageId) async {
    final targetSessionId = scope.activeSessionId;
    final runtimeState = container.read(aiChatRuntimeProvider(targetSessionId));
    if (container
            .read(aiChatRuntimeProvider(targetSessionId).notifier)
            .hasActiveRequest ||
        runtimeState.isSessionMutationInFlight) {
      return;
    }

    final messages = container
        .read(aiChatSessionProvider(targetSessionId))
        .messages;
    final failedIndex = messages.indexWhere(
      (message) => message.id == assistantMessageId,
    );
    if (failedIndex <= 0) {
      return;
    }

    AiMessage? previousUserMessage;
    for (var index = failedIndex - 1; index >= 0; index--) {
      final candidate = messages[index];
      if (candidate.role == AiMessageRole.user &&
          candidate.type != AiMessageType.system_remind) {
        previousUserMessage = candidate;
        break;
      }
    }
    final retryText = previousUserMessage?.effectiveText.trim();
    if (retryText == null || retryText.isEmpty) {
      return;
    }

    final session = await _ensureSendModelSelection(targetSessionId);
    if (session == null) {
      return;
    }
    final retryRuntimeState = container.read(
      aiChatRuntimeProvider(targetSessionId),
    );
    if (container
            .read(aiChatRuntimeProvider(targetSessionId).notifier)
            .hasActiveRequest ||
        retryRuntimeState.isSessionMutationInFlight) {
      _log.info(
        'retry ignored after async preparation because session became busy '
        'sessionId=$targetSessionId',
      );
      return;
    }

    final runtime = container.read(
      aiChatRuntimeProvider(targetSessionId).notifier,
    );
    final requestId = runtime.startRequest();
    store.sendGuardUntil = DateTime.now().add(
      const Duration(milliseconds: 400),
    );
    final runner = _buildTurnRunner();
    AiClient? aiService;
    var notifyOnComplete = false;
    late ChatTurnOutcome outcome;
    try {
      aiService = await runner.resolveAiService(
        requestId: requestId,
        sessionId: targetSessionId,
      );
      if (aiService == null) {
        _notifySendBlocked(session);
        return;
      }

      runtime.attachAiService(aiService);
      if (host.isMounted()) {
        host.resetScroll();
      }
      // warm agent 直接注入 context；冷启动时 runTurn 内重建 history 自然回放
      // 已持久化的 remind 消息。
      await _deliverCurrentContextReminds(targetSessionId);

      notifyOnComplete = true;
      outcome = await runner.runTurn(
        retryText,
        requestId: requestId,
        sessionId: targetSessionId,
        streamingMessageId: assistantMessageId,
        userMessageId: previousUserMessage?.id,
        sourceTurnId: previousUserMessage?.id,
      );
    } finally {
      runtime.markRequestIdle(requestId, notifyOnComplete: notifyOnComplete);
      if (aiService != null) {
        runtime.clearAiService(aiService);
      }
      await _flushQueuedMessageAfterRequest(targetSessionId, requestId);
    }
    if (outcome.isFailed && outcome.error != null) {
      // 与 send 失败分支同理：保留原 user 消息，只提示失败。撤回交给该消息上的
      // 常驻回退入口，避免删 UI 消息而 DB/作品改动仍在。
      runtime.invalidateAgent();
      host.onComposerWarning?.call(outcome.error!.safeMessage);
    }
  }

  /// 回退本轮 AI 改动并准备重发：回退工作区变更 + 截断会话至该 user 消息之前 +
  /// 返回原 prompt 文本供调用方放入 composer。
  ///
  /// 返回值：原 prompt 文本；无匹配消息或目标恢复失败时返回 null。
  Future<String?> rollbackTurnAndPrepareResend(String userMessageId) async {
    final targetSessionId = scope.activeSessionId;
    final session = container.read(aiChatSessionProvider(targetSessionId));
    final messages = session.messages;
    final userMessageIndex = messages.indexWhere(
      (message) => message.id == userMessageId,
    );
    if (userMessageIndex < 0) {
      return null;
    }
    final userMessage = messages[userMessageIndex];
    final originalPrompt = userMessage.effectiveText.trim();
    if (originalPrompt.isEmpty) {
      return null;
    }
    final runtime = container.read(
      aiChatRuntimeProvider(targetSessionId).notifier,
    );
    if (!runtime.tryBeginSessionMutation()) {
      _log.info(
        'rollback ignored while session history mutation is in progress '
        'sessionId=$targetSessionId',
      );
      return null;
    }

    final sessionSubscription = container.listen(
      aiChatSessionProvider(targetSessionId),
      (_, _) {},
    );
    try {
      if (runtime.hasActiveRequest) {
        cancel(targetSessionId, source: AiChatCancelSource.rollback);
        await runtime.waitForActiveRequests();
      }

      final latestSession = container.read(
        aiChatSessionProvider(targetSessionId),
      );
      final latestMessages = latestSession.messages;
      final latestUserMessageIndex = latestMessages.indexWhere(
        (message) => message.id == userMessageId,
      );
      if (latestUserMessageIndex < 0) {
        return null;
      }
      final rollbackTurnIds = rollbackTurnIdsForTruncatedMessages(
        latestMessages,
        latestUserMessageIndex,
      );
      try {
        await runtime.subAgents.stopTurns(rollbackTurnIds.toSet());
        await runtime.operations.stopTurns(rollbackTurnIds.toSet());
      } catch (error, stackTrace) {
        _log.error(
          'rollback child cleanup failed sessionId=$targetSessionId',
          error: error,
          stackTrace: stackTrace,
        );
        host.onComposerWarning?.call(tr(LocaleKeys.historyRollbackFailed));
        return null;
      }

      final dbPath = scope.databasePath;
      if (dbPath != null && dbPath.isNotEmpty) {
        try {
          final overlay = container.read(workingOverlayServiceProvider(dbPath));
          final result = await overlay.rollbackTurns(turnIds: rollbackTurnIds);
          if (result.skippedPaths.isNotEmpty) {
            host.onComposerWarning?.call(
              tr(
                LocaleKeys.historyRollbackSkipped,
                namedArgs: {
                  'restored': '${result.rolledBack}',
                  'skipped': '${result.skippedPaths.length}',
                },
              ),
            );
          }
        } catch (error, stackTrace) {
          _log.error(
            'rollbackTurnAndPrepareResend rollbackTurn error=$error '
            'sessionId=$targetSessionId userMessageId=$userMessageId',
            error: error,
            stackTrace: stackTrace,
          );
          host.onComposerWarning?.call(tr(LocaleKeys.historyRollbackFailed));
          return null;
        }
      }

      final sessionNotifier = container.read(
        aiChatSessionProvider(targetSessionId).notifier,
      );
      final messagesCopy = List<AiMessage>.from(
        container.read(aiChatSessionProvider(targetSessionId)).messages,
      );
      final truncated = messagesCopy.sublist(0, latestUserMessageIndex);
      sessionNotifier.replaceMessages(truncated);

      // Invalidate before any persistence await. The runtime mutation guard
      // prevents a new send from being started until this history is durable.
      runtime.invalidateAgent();

      // 持久化截断：把会话已落库消息同步成截断后的列表（syncSession 会删除多余行），
      // 否则重新打开会话会从 DB 加载到回退前的消息。
      final novelId = scope.novel.id;
      if (dbPath != null && dbPath.isNotEmpty && targetSessionId != null) {
        try {
          final persistence = container.read(
            aiSessionPersistenceServiceProvider(
              novelId: novelId,
              databasePath: dbPath,
            ),
          );
          final novelDatabase = container.read(
            novelContentDatabaseProvider(dbPath),
          );
          await persistence.saveMessages(
            sessionId: targetSessionId,
            messages: truncated,
            novelDatabase: novelDatabase,
          );
        } catch (error, stackTrace) {
          _log.error(
            'rollbackTurnAndPrepareResend persist truncation error=$error '
            'sessionId=$targetSessionId userMessageId=$userMessageId',
            error: error,
            stackTrace: stackTrace,
          );
          sessionNotifier.replaceMessages(messagesCopy);
          host.onComposerWarning?.call(tr(LocaleKeys.historyRollbackFailed));
          return null;
        }
      }

      if (userMessage.blocks.any((b) => b is AiAttachmentBlock)) {
        return host.encodeComposerBlocks?.call(userMessage.blocks) ??
            originalPrompt;
      }
      return originalPrompt;
    } finally {
      runtime.endSessionMutation();
      sessionSubscription.close();
    }
  }

  /// 取消指定会话当前在途请求。行为与原桌面 `_cancelActiveRequest` 一致。
  void cancel(
    String? runtimeSessionId, {
    AiChatCancelSource source = AiChatCancelSource.stopButton,
  }) {
    final sessionId = runtimeSessionId;
    if (sessionId == null || sessionId.isEmpty) {
      return;
    }
    final runtimeState = container.read(aiChatRuntimeProvider(sessionId));
    final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
    if (!runtimeState.isRequestInFlight || runtimeState.requestSequence == 0) {
      if (_log.isDebugEnabled) {
        _log.debug(
          'cancel IGNORED sessionId=$sessionId '
          'isRequestInFlight=${runtimeState.isRequestInFlight} '
          'seq=${runtimeState.requestSequence}',
        );
      }
      return;
    }
    _log.info(
      'cancel sessionId=$sessionId '
      'requestId=${runtimeState.requestSequence} '
      'isRequestInFlight=${runtimeState.isRequestInFlight}',
    );
    final sessionNotifier = container.read(
      aiChatSessionProvider(sessionId).notifier,
    );
    sessionNotifier.cancelPendingToolCallsForRequest(
      runtimeState.requestSequence,
    );
    runtime.cancelRequest(runtimeState.requestSequence, source: source);
    // 取消请求时把排队消息恢复到输入框：无论已 stage 的「立即发送」还是普通排队，
    // 都是用户已编辑但尚未成功送达的内容，停止不应静默丢弃。
    final queued = store.queuedMessage;
    clearQueuedMessage(restoreToComposer: queued != null);
    sessionNotifier.endStreamingMessage();
    sessionNotifier.removeLastAssistantMessageIfInvisible();
  }

  Future<AiChatSessionState?> _ensureSendModelSelection(
    String? sessionId,
  ) async {
    final session = container.read(aiChatSessionProvider(sessionId));
    if (session.providerId != null && session.model != null) {
      return session;
    }

    final fallbackOption = container.read(
      resolvedAiModelOptionForKindProvider(
        kind: AiModelKind.chat,
        databasePath: scope.databasePath,
      ),
    );
    final providerId = fallbackOption?.providerId;
    final model = fallbackOption?.model;
    if (providerId == null || model == null) {
      return session;
    }

    container
        .read(aiChatSessionProvider(sessionId).notifier)
        .selectModel(providerId: providerId, model: model);
    return container.read(aiChatSessionProvider(sessionId));
  }

  String _classifyBlockedFailureCode(AiChatSessionState session) {
    final providerId = session.providerId;
    final model = session.model;
    final config = providerId == null
        ? null
        : container.read(aiSettingsProvider).findConfigById(providerId);
    return classifyChatBlockedFailureCode(
      providerId: providerId,
      model: model,
      config: config,
    );
  }

  /// 发送被门禁拦住时给用户可见提示（桌面 composer notice / 移动端 snackbar）。
  ///
  /// 仅空会话（尚无历史）在绑定模型失效时自动弹出换模选择器作为便捷入口；
  /// 有历史的会话不自动弹出——用户可随时用 composer 的模型选择器换模，切换会
  /// 随下一次发送清理跨模型不可重放的私有推理状态（见 _applyPendingModelSelection）。
  void _notifySendBlocked(AiChatSessionState session) {
    final failureCode = _classifyBlockedFailureCode(session);
    if (!host.isMounted()) {
      return;
    }
    host.onComposerWarning?.call(_blockedSendUserMessage(session, failureCode));
    final staleBoundModel =
        failureCode == 'model_unavailable' &&
        session.providerId != null &&
        session.model != null;
    if (staleBoundModel && session.messages.isEmpty) {
      host.openModelSelector();
    }
  }

  String _blockedSendUserMessage(
    AiChatSessionState session,
    String failureCode,
  ) {
    return switch (failureCode) {
      'api_key_missing' => tr(LocaleKeys.aiApiKeyMissing),
      'model_unavailable' => _modelUnavailableUserMessage(session),
      _ => tr(LocaleKeys.aiPleaseConfigure),
    };
  }

  String _modelUnavailableUserMessage(AiChatSessionState session) {
    if (session.providerId == null || session.model == null) {
      return tr(LocaleKeys.aiPleaseConfigure);
    }
    // 有历史：引导新建会话，避免跨模型续聊。
    if (session.messages.isNotEmpty) {
      return tr(LocaleKeys.aiModelUnavailable);
    }
    return tr(LocaleKeys.aiModelUnavailableReselect);
  }

  /// 取消待发送队列，并取消已 stage 的 `queued_chat`。
  ///
  /// [restoreToComposer] 为 true 时把文案 append 回输入框（用户点「取消排队」）；
  /// 取消整次请求时传 false，避免把队列文本塞回输入框。
  void clearQueuedMessage({bool restoreToComposer = false}) {
    final queued = store.queuedMessage;
    store.queuedMessage = null;
    _unstageQueuedChat(queued?.sessionId ?? scope.activeSessionId);
    if (!restoreToComposer || queued == null) {
      return;
    }
    if (queued.text.isNotEmpty) {
      host.restoreComposerText?.call(_queuedDraftText(queued));
    }
    // 恢复排队消息「原本携带的引用」，覆盖排队后又新增的引用：恢复出的文案与其
    // 原始引用配对，避免再次发送时引用上下文已变（排队时 composer 引用已被清空）。
    store.attachedReferences = List<AiContextReference>.from(queued.references);
    if (queued.handoff != null && store.pendingHandoff == null) {
      store.pendingHandoff = queued.handoff;
    }
    host.focusComposer();
  }

  /// 立刻发送排队消息：stage 进当前 in-flight agent 的下一轮 LLM（与旧 queue 行为一致）。
  /// 同时投递 workspace system-remind（处理中走 stage，遵守 da7e58ef）。
  Future<void> sendQueuedMessageNow() async {
    final queued = store.queuedMessage;
    if (queued == null) {
      return;
    }
    // 归属会话优先取排队时记录的 session，避免切到别的会话后误发到当前 active 会话。
    final sessionId = queued.sessionId ?? scope.activeSessionId;
    final runtimeState = container.read(aiChatRuntimeProvider(sessionId));
    if (runtimeState.isSessionMutationInFlight) {
      _log.info(
        'send queued-now ignored while session history mutation is in progress '
        'sessionId=$sessionId',
      );
      return;
    }
    final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
    final agent = runtime.agent;
    if (agent == null || !agent.isProcessing) {
      store.queuedMessage = null;
      runtime.takeQueuedMessage();
      await send(
        queued.text,
        sessionIdOverride: sessionId,
        attachmentBlocks: queued.blocks,
        overrideReferences: queued.references,
        overrideHandoff: queued.handoff,
      );
      return;
    }

    await _deliverCurrentContextReminds(sessionId);
    agent.stageNextTurn(
      'queued_chat',
      AgentMessage.user(
        id: 'queued_chat',
        content: queued.modelBlocks.isEmpty ? queued.agentText : '',
        blocks: queued.modelBlocks,
      ),
    );
    // 消费源放在 runtime（processing 期间 keepAlive），使离页/折叠面板后仍存活的
    // turn 能在下一轮消费它，避免排队内容随面板卸载而静默丢失（见 turn runner）。
    final stagedMessage = queued.copyWith(sendOnNextTurn: true);
    runtime.stagePendingNextTurnMessage(stagedMessage);
    store.queuedMessage = stagedMessage;
  }

  void _unstageQueuedChat(String? sessionId) {
    container.read(aiChatRuntimeProvider(sessionId).notifier)
      ..takeQueuedMessage()
      ..agent?.stageNextTurn('queued_chat', null)
      ..clearPendingNextTurnMessage();
  }

  /// 请求结束后接力发送排队消息；若已选「立刻发送」则不再走完整 send。
  ///
  /// 设计决策：普通排队消息的自动接力沿用上一条请求 Controller 的
  /// scope.workspace* 与 promptContext，不随排队期间的界面工作区切换而改变。
  /// 队列不保存独立工作区快照；这里继续使用本 Controller.send 是有意行为。
  ///
  /// 「立即发送」staged 的消息本应在下一轮由 turn runner 消费；若本轮报错/取消前
  /// 未能消费，这里取回并 unstage。界面仍在时恢复到输入框；界面已卸载时，继续按
  /// 原有引用与 handoff 在后台接力发送，避免用户消息丢失。
  Future<void> _flushQueuedMessageAfterRequest(
    String? sessionId,
    int requestId,
  ) async {
    final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
    // 旧请求的 finally 可在新请求已经开始后才执行。必须先确认本请求仍是当前请求，
    // 再消费 runtime 共享的 staged 消息，否则会取走新请求的「立即发送」内容。
    if (container.read(aiChatRuntimeProvider(sessionId)).requestSequence !=
        requestId) {
      return;
    }
    final unconsumedStagedMessage = runtime.takePendingNextTurnMessage();
    if (unconsumedStagedMessage != null) {
      runtime.agent?.stageNextTurn('queued_chat', null);
    }
    final queuedMessage =
        runtime.takeQueuedMessage() ??
        (host.isMounted() ? store.queuedMessageForSession(sessionId) : null);
    if (!host.isMounted()) {
      final detachedMessage = unconsumedStagedMessage ?? queuedMessage;
      if (detachedMessage != null &&
          (unconsumedStagedMessage != null ||
              !detachedMessage.sendOnNextTurn)) {
        await _sendDetachedQueuedMessage(sessionId, detachedMessage);
      }
      return;
    }
    if (queuedMessage == null) {
      return;
    }
    store.setQueuedMessageForSession(sessionId, null);
    if (unconsumedStagedMessage != null) {
      // 立即发送但本轮未送达：恢复文案 + 原始引用到输入框，不静默丢弃。
      if (queuedMessage.text.isNotEmpty) {
        host.restoreComposerText?.call(_queuedDraftText(queuedMessage));
      }
      store.attachedReferences = List<AiContextReference>.from(
        queuedMessage.references,
      );
      if (queuedMessage.handoff != null && store.pendingHandoff == null) {
        store.pendingHandoff = queuedMessage.handoff;
      }
      host.focusComposer();
      return;
    }
    if (queuedMessage.sendOnNextTurn) {
      // 已被成功消费的 staged 消息（runtime pending 已清空）：无需重发。
      return;
    }
    await send(
      queuedMessage.text,
      sessionIdOverride: sessionId,
      attachmentBlocks: queuedMessage.blocks,
      overrideReferences: queuedMessage.references,
      overrideHandoff: queuedMessage.handoff,
    );
  }

  /// UI 已卸载后仍要发送的队列使用独立的普通 store，不能继续写 panel-scoped 的
  /// hooks notifier。保留上下文同步回调，它们只同步 Agent 上下文到会话状态。
  /// 工作区沿用上述自动接力决策：新 Controller 复制原 scope.workspace* 与
  /// promptContext，离页不会重新选择工作区上下文。
  Future<void> _sendDetachedQueuedMessage(
    String? sessionId,
    QueuedChatMessage message,
  ) {
    return ChatSessionController(
      container: container,
      scope: ChatScope(
        activeSessionId: sessionId,
        novel: scope.novel,
        databasePath: scope.databasePath,
        workspaceSection: scope.workspaceSection,
        workspaceItemId: scope.workspaceItemId,
        workspaceTitle: scope.workspaceTitle,
      ),
      host: ChatHost(
        clearComposer: () {},
        focusComposer: () {},
        openModelSelector: () {},
        resetScroll: () {},
        isMounted: () => false,
        onContextCompacted: host.onContextCompacted,
        onContextSettled: host.onContextSettled,
      ),
      store: DefaultChatComposerStore(),
      promptBuilder: promptBuilder,
      availableSubAgents: availableSubAgents,
      aiPromptService: aiPromptService,
      promptContext: promptContext,

      // UI 已卸载：建议没有落点，工具不下发。
      nextActionEnvironment: nextActionEnvironment,
      supportsNextActionSuggestions: false,
    ).send(
      message.text,
      sessionIdOverride: sessionId,
      attachmentBlocks: message.blocks,
      overrideReferences: message.references,
      overrideHandoff: message.handoff,
    );
  }

  @visibleForTesting
  Future<void> flushQueuedMessageAfterRequestForTest(
    String? sessionId,
    int requestId,
  ) {
    return _flushQueuedMessageAfterRequest(sessionId, requestId);
  }

  /// 设计决策：日期与工作区提醒只在发送入口按当时最新压缩边界后的消息去重。
  /// Agent 随后在本轮内压缩时，不强制保留或重新投递这两类提醒，因此不保证
  /// 本轮压缩后的每次 LLM 请求仍有独立提醒；下次进入发送入口时再检查补发。
  Future<void> _deliverCurrentContextReminds(String? sessionId) async {
    await _deliverCurrentWorkspaceContextRemind(sessionId);
    _deliverCurrentDateRemind(sessionId);
  }

  /// 测试发送、重试和立即发送排队消息共同使用的上下文投递链路。
  @visibleForTesting
  Future<void> debugDeliverCurrentContextReminds(String? sessionId) =>
      _deliverCurrentContextReminds(sessionId);

  Future<CurrentWorkspaceContext?> _currentScreenplaySelection() async {
    final databasePath = scope.databasePath;
    if (databasePath == null) {
      return null;
    }
    final dao = container
        .read(novelContentServiceProvider(databasePath))
        .database
        .screenplayDao;
    final selectedEpisodeId = promptContext.currentEpisodeId?.trim();
    var episode = selectedEpisodeId == null || selectedEpisodeId.isEmpty
        ? null
        : await dao.getEpisode(selectedEpisodeId);
    final selectedSeasonId = promptContext.currentSeasonId?.trim();
    final seasonId = selectedSeasonId == null || selectedSeasonId.isEmpty
        ? episode?.seasonId
        : selectedSeasonId;
    final season = seasonId == null ? null : await dao.getSeason(seasonId);
    if (season == null) {
      return null;
    }
    // 切季后残留的上一季集选择不能与当前季一起发送。
    if (episode?.seasonId != season.id) {
      episode = null;
    }
    if (episode == null && !promptContext.hasMultipleSeasons) {
      return null;
    }
    return CurrentWorkspaceContext(
      seasonId: promptContext.hasMultipleSeasons ? season.id : null,
      episodeId: episode?.id,
      episodeNumber: episode?.episodeNumber,
      episodeTitle: episode?.title.trim(),
    );
  }

  /// 完整上下文随主动 send / retry / sendQueuedMessageNow 投递。
  /// 以压缩后消息流中的最后一条提醒去重，资源或季集变化均会更新。
  Future<void> _deliverCurrentWorkspaceContextRemind(String? sessionId) async {
    final context = await _currentWorkspaceContext();
    final messages = messagesSinceLatestCompact(
      container.read(aiChatSessionProvider(sessionId)).messages,
    );
    final previous = _latestCurrentWorkspaceContextReminder(messages);
    if (context == null && previous == null) {
      return;
    }
    final remind = _buildCurrentWorkspaceContextRemind(context);
    if (previous == remind) {
      return;
    }
    _deliverSystemRemind(sessionId, remind, kind: 'current_workspace_context');
  }

  /// 投递 current_date system-remind：environment 块删除后由这里按需告知模型
  /// 「今天」。消息流持久化本身就是真源（跨天或新会话时最后一条不再是今天），
  /// 无需 runtime key；当天已投过则跳过。
  void _deliverCurrentDateRemind(String? sessionId) {
    final session = container.read(aiChatSessionProvider(sessionId));
    final date = currentDateRemindDateString(DateTime.now());
    if (hasLatestCurrentDateReminder(
      messagesSinceLatestCompact(session.messages),
      date,
    )) {
      return;
    }
    _deliverSystemRemind(
      sessionId,
      buildCurrentDateRemind(date),
      kind: 'current_date',
    );
  }

  /// 「快速开书」草稿：仅 `scope.novel.draft` 为 true 且本会话未投过时，注入一条
  /// active novel_draft remind，让创作向导据此在方向定后询问「加入书架」。
  void _deliverNovelDraftRemind(String? sessionId) {
    if (!scope.novel.draft) {
      return;
    }
    final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
    if (!runtime.needsNovelDraftRemind()) {
      return;
    }
    _deliverSystemRemind(
      sessionId,
      novelDraftRemindActive,
      kind: novelDraftRemindKind,
    );
    runtime.markNovelDraftRemindSent();
  }

  void _deliverSystemRemind(
    String? sessionId,
    String remind, {
    required String kind,
  }) {
    deliverSystemRemindToSession(container, sessionId, remind, kind: kind);
  }

  /// 测试入口：覆盖「agent 处理中投递 system-remind」路径（da7e58ef）。
  @visibleForTesting
  void debugDeliverSystemRemind(
    String? sessionId,
    String remind, {
    required String kind,
  }) {
    _deliverSystemRemind(sessionId, remind, kind: kind);
  }

  String _buildCurrentWorkspaceContextRemind(CurrentWorkspaceContext? view) {
    if (view == null) {
      return "<system-remind type='current_workspace_context' status='cleared' />";
    }
    // 路径资源以 path 首段标记 section（选中卷时标 volumes）；导演台通过
    // staging_id 寻址，不生成 Read 不支持的路径。
    final buffer = StringBuffer(
      "<system-remind type='current_workspace_context'",
    );
    final path = view.path;
    final stagingId = view.stagingId;
    if (stagingId != null && stagingId.isNotEmpty) {
      buffer.write(" section='stagings'");
    } else if (path != null && path.isNotEmpty) {
      final sectionLabel = path
          .split('/')
          .firstWhere((segment) => segment.trim().isNotEmpty);
      buffer.write(" section='${escapeXmlAttribute(sectionLabel)}'");
    }
    if (path != null && path.isNotEmpty) {
      buffer.write(" path='${escapeXmlAttribute(path)}'");
    }
    if (view.title != null) {
      buffer.write(" title='${escapeXmlAttribute(view.title!)}'");
    }
    if (stagingId != null && stagingId.isNotEmpty) {
      buffer.write(" staging_id='${escapeXmlAttribute(stagingId)}'");
    }
    buffer.write(" hint='${escapeXmlAttribute(view.hint)}'");
    // 剧本属性：选中集级/场级资源时附带集归属；season_id 仅多季作品注入。
    final episodeId = view.episodeId?.trim();
    if (episodeId != null && episodeId.isNotEmpty) {
      buffer.write(" episode_id='${escapeXmlAttribute(episodeId)}'");
    }
    final episodeNumber = view.episodeNumber;
    if (episodeNumber != null) {
      buffer.write(" episode_number='$episodeNumber'");
    }
    final episodeTitle = view.episodeTitle?.trim();
    if (episodeTitle != null && episodeTitle.isNotEmpty) {
      buffer.write(" episode_title='${escapeXmlAttribute(episodeTitle)}'");
    }
    final seasonId = view.seasonId?.trim();
    if (seasonId != null && seasonId.isNotEmpty) {
      buffer.write(" season_id='${escapeXmlAttribute(seasonId)}'");
    }
    buffer.write(' />');
    return buffer.toString();
  }

  /// 测试入口：解析 current workspace context（验证 canvas name / 卷路径映射）。
  @visibleForTesting
  Future<CurrentWorkspaceContext?> resolveCurrentWorkspaceContextForTest() {
    return _currentWorkspaceContext();
  }

  /// 测试入口：构造 remind 字符串（验证 section 标签以 path 为准）。
  @visibleForTesting
  String buildCurrentWorkspaceContextRemindForTest(
    CurrentWorkspaceContext? view,
  ) {
    return _buildCurrentWorkspaceContextRemind(view);
  }

  /// 测试入口：覆盖 current_date remind 的按需投递路径（当日去重）。
  @visibleForTesting
  void debugDeliverCurrentDateRemind(String? sessionId) {
    _deliverCurrentDateRemind(sessionId);
  }

  /// 合并当前资源与季集选择；资源路径和剧本范围都为空才清除上下文。
  Future<CurrentWorkspaceContext?> _currentWorkspaceContext() async {
    final resource = await _currentWorkspaceResource();
    // 具体剧本资源的归属只能来自资源自身；所属集缺失时也不合并宿主选择，
    // 避免把旧季集贴到仍然存在的场次路径上。
    if (promptContext.contentKind != contentKindScreenplay ||
        const {
          NovelWorkspaceSection.screenplay_outline,
          NovelWorkspaceSection.screenplay_script,
          NovelWorkspaceSection.screenplay_scenes,
        }.contains(resource?.section)) {
      return resource;
    }
    final selection = await _currentScreenplaySelection();
    if (selection == null) {
      return resource;
    }
    return CurrentWorkspaceContext(
      section: resource?.section,
      path: resource?.path,
      title: resource?.title,
      stagingId: resource?.stagingId,
      hint: resource?.hint ?? selection.hint,
      seasonId: selection.seasonId,
      episodeId: selection.episodeId,
      episodeNumber: selection.episodeNumber,
      episodeTitle: selection.episodeTitle,
    );
  }

  /// 校验当前资源并解析 AI 路径：canvas 按 name 寻址，卷使用 /volumes/{id}；
  /// 剧本资源附带真实集归属。资源不存在时不再携带旧的路径。
  Future<CurrentWorkspaceContext?> _currentWorkspaceResource() async {
    final section = scope.workspaceSection;
    if (section == null || section.isReadOnly) {
      return null;
    }
    if (section == NovelWorkspaceSection.novel_description) {
      return CurrentWorkspaceContext(
        section: section,
        path: '/profile',
        title: scope.workspaceTitle?.trim().isNotEmpty == true
            ? scope.workspaceTitle!.trim()
            : scope.novel.title.trim(),
      );
    }
    final databasePath = scope.databasePath;
    if (section == NovelWorkspaceSection.storyboard &&
        (promptContext.contentKind == contentKindScreenplay ||
            promptContext.contentKind == contentKindCanvas) &&
        databasePath != null) {
      final stagingId = container
          .read(productionSubpageProvider(databasePath))
          ?.stagingId;
      if (stagingId != null) {
        final staging = await container
            .read(novelContentServiceProvider(databasePath))
            .database
            .screenplayDao
            .getStaging(stagingId);
        // 打开的调度优先于底层画布选中的片段；失效时也不回退到被遮住的片段。
        return staging == null
            ? null
            : CurrentWorkspaceContext(
                section: section,
                title: staging.title.trim(),
                stagingId: staging.id,
                hint: 'Run stagings read',
              );
      }
    }
    if (section == NovelWorkspaceSection.storyboard &&
        promptContext.contentKind == contentKindCanvas) {
      return CurrentWorkspaceContext(
        section: section,
        path: '/production/canvas',
        title: scope.novel.title.trim(),
      );
    }
    final itemId = scope.workspaceItemId?.trim();
    if (itemId == null || itemId.isEmpty) {
      return null;
    }
    if (section == NovelWorkspaceSection.canvas && databasePath != null) {
      final canvas = await container
          .read(novelContentServiceProvider(databasePath))
          .canvasService
          .getCanvasById(itemId);
      if (canvas == null) {
        return null;
      }
      final name = canvas.name.trim();
      return CurrentWorkspaceContext(
        section: section,
        path: '/canvas/$name',
        title: name,
      );
    }
    if (section == NovelWorkspaceSection.maps && databasePath != null) {
      // 地图工作台的 selection 是当前地图所属地点：顶层 world 或它的子地点。
      final service = container.read(locationsServiceProvider(databasePath));
      final target = await service.getLocationById(itemId);
      if (target == null) {
        return null;
      }
      var root = target;
      final visited = <String>{root.id};
      while (root.parentId != null) {
        final parent = await service.getLocationById(root.parentId!);
        if (parent == null || !visited.add(parent.id)) {
          return null;
        }
        root = parent;
      }
      if (root.type != locationTypeWorld) {
        return null;
      }
      return CurrentWorkspaceContext(
        section: section,
        path: '/locations/$itemId',
        title: target.name.trim(),
      );
    }
    if (section == NovelWorkspaceSection.chapters && databasePath != null) {
      final chapter = await container
          .read(novelContentServiceProvider(databasePath))
          .getChapterById(itemId);
      if (chapter == null) {
        return null;
      }
      if (chapter.isVolume) {
        return CurrentWorkspaceContext(
          section: section,
          path: '/volumes/$itemId',
          title: chapter.title?.trim() ?? '',
        );
      }
    }
    // 剧本区：outline 的 itemId 是集 id；beats/script/scenes 分别是节拍/场次 id，
    // 需经实体反查所属集。选中的实体已删时返回 null；节拍或场次仍在、但所属集
    // 查不到时只保留资源路径，不附加季集归属。
    String? seasonId;
    String? episodeId;
    int? episodeNumber;
    String? episodeTitle;
    void fillFromEpisode(ScreenplayEpisodeRow episode) {
      episodeId = episode.id;
      episodeNumber = episode.episodeNumber;
      final trimmedEpisodeTitle = episode.title.trim();
      if (trimmedEpisodeTitle.isNotEmpty) {
        episodeTitle = trimmedEpisodeTitle;
      }
      if (promptContext.hasMultipleSeasons) {
        seasonId = episode.seasonId;
      }
    }

    if (databasePath != null) {
      final screenplayDao = container
          .read(novelContentServiceProvider(databasePath))
          .database
          .screenplayDao;
      switch (section) {
        // outline 按 /episodes/{id}/outline 寻址，itemId 即集 id。
        case NovelWorkspaceSection.screenplay_outline:
          final episode = await screenplayDao.getEpisode(itemId);
          if (episode == null) {
            return null;
          }
          fillFromEpisode(episode);
        // script/scenes 按 /scenes/{scene_id} 寻址，经场反查所属集。
        case NovelWorkspaceSection.screenplay_script:
        case NovelWorkspaceSection.screenplay_scenes:
          final scene = await screenplayDao.getScene(itemId);
          if (scene == null) {
            return null;
          }
          final episode = await screenplayDao.getEpisode(scene.episodeId);
          if (episode != null) {
            fillFromEpisode(episode);
          }
        default:
          break;
      }
    }
    final path = section.aiResourcePath(
      itemId: itemId,
      title: scope.workspaceTitle,
    );
    if (path == null || path.isEmpty) {
      return null;
    }
    return CurrentWorkspaceContext(
      section: section,
      path: path,
      title: scope.workspaceTitle?.trim() ?? '',
      seasonId: seasonId,
      episodeId: episodeId,
      episodeNumber: episodeNumber,
      episodeTitle: episodeTitle,
    );
  }

  String _buildAgentTextWithHandoff(
    String text,
    List<AiContextReference> refs,
    PendingChatHandoff? handoff,
  ) {
    final instruction =
        text.trim().isEmpty && handoff?.isSessionContinuation == true
        ? sessionContinuationInstruction
        : text.trim();
    final userText = promptBuilder
        .buildAgentTextWithReferences(instruction, refs)
        .trim();
    if (handoff == null) {
      return userText;
    }
    final handoffBody = handoff.content.trim();
    if (userText.isEmpty) {
      return handoffBody;
    }
    // 封面工作室等 handoff 会把同一段 prompt 同时填入 composer 与 pendingHandoff；
    // 引用标签/Read 提醒会使 userText 与 handoffBody 不完全相等，但正文已包含时不应再拼接。
    if (handoffBody.isEmpty ||
        userText == handoffBody ||
        userText.contains(handoffBody)) {
      return userText;
    }
    return '$userText\n\n$handoffBody';
  }

  String? _buildSlashCommandRemind(SubAgent? agent) {
    if (agent == null) {
      return null;
    }
    // Slash command 是 model-only 提示，不在聊天 UI 中渲染。发送失败撤回用户
    // 消息后该提示仍保留在会话中；其文案本身是弱偏好提示，残留无害。
    final id = escapeXmlAttribute(agent.id);
    final name = escapeXmlAttribute(agent.name);
    final description = escapeXmlAttribute(agent.description.trim());
    return "<system-remind type='slash_subagent_hint' "
        "subagent-id='$id' subagent-name='$name' "
        "description='$description'>"
        '用户输入的 slash command 只是偏好提示：优先考虑这个 SubAgent，'
        '但仍按普通消息处理，由主控根据任务匹配度决定是否 SpawnAgent。'
        '</system-remind>';
  }

  /// 只保留内容类引用（章节/人物/agent_rule/file/selection）。subagent / skill chip 不走
  /// 「请自行读取」提醒链路，改由 [_deliverSlashChipReminds] 单独处理。
  List<AiContextReference> _contentRefsOnly(List<AiContextReference> refs) {
    return refs
        .where(
          (ref) =>
              ref.kind != AiContextReferenceKind.subagent &&
              ref.kind != AiContextReferenceKind.skill,
        )
        .toList(growable: false);
  }

  /// 处理由 `/` 命令面板选中生成的 chip：
  /// - subagent chip → 软偏好提示（与手打 `/name` 同款）。
  /// - skill chip → 直接加载：把完整技能指令封入 `<agent_skill>` 块注入本轮。
  void _deliverSlashChipReminds(
    String? sessionId,
    List<AiContextReference> refs,
  ) {
    for (final ref in refs) {
      switch (ref.kind) {
        case AiContextReferenceKind.subagent:
          final agent = availableSubAgents
              .where((item) => item.id == ref.itemId)
              .firstOrNull;
          final remind = _buildSlashCommandRemind(agent);
          if (remind != null) {
            _deliverSystemRemind(
              sessionId,
              remind,
              kind: 'slash_subagent_hint',
            );
          }
        case AiContextReferenceKind.skill:
          final remind = _buildSlashSkillRemind(ref.label);
          if (remind != null) {
            _deliverSystemRemind(sessionId, remind, kind: 'slash_skill_load');
          }
        case AiContextReferenceKind.workspace:
        case AiContextReferenceKind.agent_rule:
        case AiContextReferenceKind.file:
        case AiContextReferenceKind.selection:
          break;
      }
    }
  }

  /// 按名称把技能完整指令包成「直接加载」的 system-remind；找不到/未启用则返回 null。
  ///
  /// 匹配键是 chip 的 `label`（= SkillDefinition.name，即应用全局唯一的工具名）；
  /// 注入的 `<agent_skill><name>` 块沿用同一个 name，与 AgentSkill 工具去重规则
  /// 对齐——避免注入块与工具列表名不一致导致模型重复加载。
  String? _buildSlashSkillRemind(String skillName) {
    final skill = availableSkills
        .where((item) => item.name == skillName && item.enabled)
        .firstOrNull;
    if (skill == null) {
      return null;
    }
    final blockName = skill.name;
    final escapedName = escapeXmlAttribute(blockName);
    final block = buildAgentSkillBlock(
      blockName,
      instructions: skill.prompt,
      references: [
        for (final ref in skill.references)
          AgentSkillReferenceDescriptor(path: ref.path),
      ],
    );
    return "<system-remind type='slash_skill_load' skill-name='$escapedName'>"
        '用户通过 slash 命令主动加载了技能「$escapedName」，以下是其完整指令，'
        '请在本次请求中遵循执行。\n$block\n'
        '</system-remind>';
  }

  void _maybeGenerateSessionTitle(String? sessionId, String firstUserMessage) {
    final fallback = firstUserMessage.trim();
    if (fallback.isNotEmpty) {
      final title = fallback.characters.take(20).toString();
      container
          .read(aiChatSessionProvider(sessionId).notifier)
          .setSessionTitle(title);
    }
  }

  SubAgent? _matchSlashCommand(String input, List<SubAgent> availableAgents) {
    final normalized = input.trimLeft();
    if (!normalized.startsWith('/')) {
      return null;
    }
    final commandToken = normalized.split(RegExp(r'\s+')).first;
    for (final agent in availableAgents) {
      if (!agent.enabled || !isUserVisibleSubAgent(agent)) {
        continue;
      }
      final agentCommand = '/${agent.name.replaceAll(' ', '_')}';
      if (agentCommand == commandToken) {
        return agent;
      }
    }
    return null;
  }

  ChatTurnRunner _buildTurnRunner() {
    return ChatTurnRunner(
      container: container,
      novel: scope.novel,
      databasePath: scope.databasePath,
      aiPromptService: aiPromptService,
      promptContext: promptContext,
      onComposerWarning: (message) {
        if (host.isMounted()) {
          host.onComposerWarning?.call(message);
        }
      },
      takeQueuedMessage: (turnSessionId) {
        final queuedMessage = container
            .read(aiChatRuntimeProvider(turnSessionId).notifier)
            .takePendingNextTurnMessage();
        if (queuedMessage == null) {
          return null;
        }
        container
            .read(aiChatRuntimeProvider(turnSessionId).notifier)
            .takeQueuedMessage();
        // 消费成功：清掉 UI 排队横幅（面板卸载后 store 不可写，用 isMounted 守卫）。
        if (host.isMounted()) {
          store.setQueuedMessageForSession(
            queuedMessage.sessionId ?? turnSessionId,
            null,
          );
        }
        return queuedMessage;
      },
      onAgentContextCompacted: host.onContextCompacted,
      onAgentContextSettled: host.onContextSettled,

      nextActionEnvironment: nextActionEnvironment,
      supportsNextActionSuggestions: supportsNextActionSuggestions,
    );
  }
}

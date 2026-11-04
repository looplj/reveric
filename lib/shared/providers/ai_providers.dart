// 职责: AI 运行时与服务 Provider — 管理聊天会话状态、运行时资源和 AI Client 构建。
// 关联文件:
//   lib/shared/services/ai/chat.dart
//   lib/shared/services/ai/provider_initializer.dart
//   lib/shared/providers/ai_mode_processing.dart
//   lib/shared/models/ai_chat_session_id.dart
//   lib/shared/models/queued_chat_message.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
import 'dart:async';
import 'package:reveric/shared/models/asset_purpose.dart';
import '../services/ai/tool_operations.dart';
import '../services/tool_permission_gate.dart';
import 'tool_permissions.dart';
import 'tool_operations.dart';

import 'package:hooks_riverpod/hooks_riverpod.dart'
    show ProviderListenableSelect, ProviderSubscription;
import 'package:hooks_riverpod/misc.dart' show KeepAliveLink;
import 'package:http/http.dart' as http;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../agent/agent.dart';
import '../agent/client.dart';
import '../agent/client/trace_headers_http_client.dart'
    show buildTraceSessionHeaders;
import '../database/novel_content_database.dart';
import '../models/ai_chat_models.dart';
import '../models/ai_chat_session_id.dart';
import '../models/queued_chat_message.dart';
import '../models/ai_provider.dart';
import '../models/ai_session_mode.dart';
import '../models/agent_profile.dart';
import '../logger/app_logger.dart';
import '../services/ai/ai_http_client_lease.dart';
import '../services/ai/image.dart';
import '../services/ai/pending_ask_user.dart';
import '../services/ai/chat.dart';
import '../services/ai/spawn_agent_handler.dart';
import '../services/ai/tool_result_payloads.dart';
import '../agent/tool_approval.dart';
import '../services/ai/tools.dart';
import 'ai_mode_processing.dart';
import 'canvas_providers.dart';
import 'maps_providers.dart';
import 'novel_providers.dart';
import 'settings_providers.dart';
import 'spawn_agent_run_providers.dart';

export '../models/ai_chat_session_id.dart' show isTemporaryAiChatSessionId;

part 'ai_providers.g.dart';

final _aiProvidersLog = AppLogger.forModule('aiProviders');

/// 本轮 assistant 消息里的 tool 是否都已执行完毕（无 pending/running）。
/// 用于 runtime.finishUiAssistantRoundIfSettled：对齐 Agent「先 MessageEnd、后跑工具」的顺序。
bool aiAssistantMessageToolCallsSettled(AiMessage message) {
  var hasToolCall = false;
  for (final block in message.blocks) {
    if (block is! AiToolCallBlock) {
      continue;
    }
    hasToolCall = true;
    if (block.status == AiToolCallStatus.pending ||
        block.status == AiToolCallStatus.running) {
      return false;
    }
  }
  return hasToolCall;
}

// ==================== New session signal dedup ====================

typedef _AiChatNewSessionSignalKey = ({String novelId, String signal});

/// Chat runtime 的稳定取消来源，用于匿名 trace 区分正常控制流入口。
enum AiChatCancelSource {
  stopButton('stop_button'),
  exitPause('exit_pause'),
  modelSwitch('model_switch'),
  rollback('rollback'),
  workDeleted('work_deleted'),
  runtimeDispose('runtime_dispose'),
  parentCancel('parent_cancel');

  const AiChatCancelSource(this.code);

  final String code;
}

final Map<_AiChatNewSessionSignalKey, String> _aiChatNewSignalToSessionId =
    <_AiChatNewSessionSignalKey, String>{};
final Map<_AiChatNewSessionSignalKey, Future<String>>
_aiChatNewSessionMaterializations =
    <_AiChatNewSessionSignalKey, Future<String>>{};

_AiChatNewSessionSignalKey _newSessionSignalKey({
  required String novelId,
  required String signal,
}) => (novelId: novelId, signal: signal);

void registerAiChatNewSessionId({
  required String novelId,
  required String signal,
  required String sessionId,
}) {
  final key = _newSessionSignalKey(novelId: novelId, signal: signal);
  _aiChatNewSignalToSessionId[key] = sessionId;
}

/// 将 UI 临时 signal 物化为真实会话。同一 novel/signal 的并发调用共享一个 Future；
/// 失败后移除占位，允许下一次发送重试。
Future<String> materializeAiChatNewSession({
  required String novelId,
  required String signal,
  required Future<String> Function() create,
}) {
  final resolved = resolveAiChatNewSessionId(
    novelId: novelId,
    activeId: signal,
  );
  if (resolved != null) {
    return Future.value(resolved);
  }
  final key = _newSessionSignalKey(novelId: novelId, signal: signal);
  final existing = _aiChatNewSessionMaterializations[key];
  if (existing != null) {
    return existing;
  }

  final materialization = () async {
    try {
      final sessionId = await create();
      registerAiChatNewSessionId(
        novelId: novelId,
        signal: signal,
        sessionId: sessionId,
      );
      return sessionId;
    } finally {
      _aiChatNewSessionMaterializations.remove(key);
    }
  }();
  _aiChatNewSessionMaterializations[key] = materialization;
  return materialization;
}

String? resolveAiChatNewSessionId({
  required String novelId,
  required String? activeId,
}) {
  if (activeId == null) {
    return null;
  }
  if (!isTemporaryAiChatSessionId(activeId)) {
    return null;
  }
  final key = _newSessionSignalKey(novelId: novelId, signal: activeId);
  return _aiChatNewSignalToSessionId[key];
}

void releaseAiChatNewSessionId({
  required String novelId,
  required String signal,
}) {
  final key = _newSessionSignalKey(novelId: novelId, signal: signal);
  _aiChatNewSignalToSessionId.remove(key);
}

// ==================== Tool Approval Provider ====================

/// Global broker that the tool execution layer uses to request user approval
/// for Write / Edit calls. The UI listens on this to render pending tool
/// cards.
@riverpod
AiToolApprovalController aiToolApprovalController(Ref ref) {
  final controller = AiToolApprovalController();
  ref.onDispose(controller.dispose);
  return controller;
}

// ==================== AI Chat Session Provider ====================

/// AI 聊天会话状态
class AiChatSessionState {
  final String? sessionId;
  final String title;
  final List<AiMessage> messages;
  final String? providerId;
  final String? model;
  final String? reasoningEffort;
  final AiSessionMode sessionMode;
  final String? agentSlug;
  final bool isLoaded;
  final bool isCompactingContext;

  /// 流式请求在网络重试等待期间的瞬态状态，不持久化。
  final bool isWaitingForResponse;

  /// 当前重试进度，仅用于等待提示，不持久化。
  final String retryProgress;

  AiChatSessionState({
    this.sessionId,
    this.title = '',
    this.messages = const [],
    this.providerId,
    this.model,
    this.reasoningEffort,
    this.sessionMode = AiSessionMode.chat,
    this.agentSlug = builtinAgentSlugOrchestrator,
    this.isLoaded = false,
    this.isCompactingContext = false,
    this.isWaitingForResponse = false,
    this.retryProgress = '',
  });

  AiChatSessionState copyWith({
    String? sessionId,
    String? title,
    List<AiMessage>? messages,
    Object? providerId = _sentinel,
    Object? model = _sentinel,
    Object? reasoningEffort = _sentinel,
    AiSessionMode? sessionMode,
    Object? agentSlug = _sentinel,
    bool? isLoaded,
    bool? isCompactingContext,
    bool? isWaitingForResponse,
    String? retryProgress,
    bool clearSessionId = false,
  }) {
    return AiChatSessionState(
      sessionId: clearSessionId ? null : (sessionId ?? this.sessionId),
      title: title ?? this.title,
      messages: messages ?? this.messages,
      providerId: providerId == _sentinel
          ? this.providerId
          : providerId as String?,
      model: model == _sentinel ? this.model : model as String?,
      reasoningEffort: reasoningEffort == _sentinel
          ? this.reasoningEffort
          : reasoningEffort as String?,
      sessionMode: sessionMode ?? this.sessionMode,
      agentSlug: agentSlug == _sentinel ? this.agentSlug : agentSlug as String?,
      isLoaded: isLoaded ?? this.isLoaded,
      isCompactingContext: isCompactingContext ?? this.isCompactingContext,
      isWaitingForResponse: isWaitingForResponse ?? this.isWaitingForResponse,
      retryProgress: retryProgress ?? this.retryProgress,
    );
  }
}

const _sentinel = Object();

typedef _AiServiceSessionConfig = ({
  String? providerId,
  String? model,
  String? reasoningEffort,
});

_AiServiceSessionConfig _watchAiServiceSessionConfig(
  Ref ref,
  String? sessionId,
) {
  return ref.watch(
    aiChatSessionProvider(sessionId).select(
      (session) => (
        providerId: session.providerId,
        model: session.model,
        reasoningEffort: session.reasoningEffort,
      ),
    ),
  );
}

class AiChatRuntimeState {
  const AiChatRuntimeState({
    this.isRequestInFlight = false,
    this.requestSequence = 0,
    this.activeToolExecutions = 0,
    this.hasPendingNextTurnMessage = false,
    this.isSessionMutationInFlight = false,
    this.isPreparingQueuedMessage = false,
    this.subAgents = const SpawnAgentSessionState(),
    this.operations = const ToolOperationState(),
  });

  final bool isRequestInFlight;
  final int requestSequence;
  final int activeToolExecutions;
  final bool hasPendingNextTurnMessage;
  final bool isSessionMutationInFlight;

  /// 排队消息的附件正在处理，尚未写入队列；UI 据此禁用发送。
  final bool isPreparingQueuedMessage;
  final SpawnAgentSessionState subAgents;
  final ToolOperationState operations;

  int get backgroundAgentCount => subAgents.backgroundCount;

  bool get isEditing =>
      isRequestInFlight ||
      activeToolExecutions > 0 ||
      isSessionMutationInFlight;

  AiChatRuntimeState copyWith({
    bool? isRequestInFlight,
    int? requestSequence,
    int? activeToolExecutions,
    bool? hasPendingNextTurnMessage,
    bool? isSessionMutationInFlight,
    bool? isPreparingQueuedMessage,
    SpawnAgentSessionState? subAgents,
    ToolOperationState? operations,
  }) {
    return AiChatRuntimeState(
      isRequestInFlight: isRequestInFlight ?? this.isRequestInFlight,
      requestSequence: requestSequence ?? this.requestSequence,
      activeToolExecutions: activeToolExecutions ?? this.activeToolExecutions,
      hasPendingNextTurnMessage:
          hasPendingNextTurnMessage ?? this.hasPendingNextTurnMessage,
      isSessionMutationInFlight:
          isSessionMutationInFlight ?? this.isSessionMutationInFlight,
      isPreparingQueuedMessage:
          isPreparingQueuedMessage ?? this.isPreparingQueuedMessage,
      subAgents: subAgents ?? this.subAgents,
      operations: operations ?? this.operations,
    );
  }
}

@riverpod
class AiChatRuntime extends _$AiChatRuntime {
  Agent? agent;
  AiClient? activeAiService;
  AiClient? agentAiService;

  /// 快速开书草稿的 novel_draft remind 每会话仅投递一次的已发标记。
  bool novelDraftRemindSent = false;

  /// 「立即发送」staged 到当前 in-flight agent 下一轮的完整排队消息。
  ///
  /// 存在 runtime（processing 期间 keepAlive）而非 panel-scoped store，使得
  /// 离开 / 折叠聊天界面后，仍存活的 turn 能在下一轮消费它，避免排队内容随
  /// 面板卸载而静默丢失（见 chat_session_controller 的 send-now / flush 逻辑）。
  QueuedChatMessage? _pendingNextTurnMessage;

  /// 供重建后的聊天面板恢复「下一轮发送」横幅；消费仍只允许走 take 方法。
  QueuedChatMessage? get pendingNextTurnMessage => _pendingNextTurnMessage;

  /// 普通排队消息随会话保留，自动唤醒或离页面后的收尾也能接力。
  QueuedChatMessage? queuedMessage;
  bool get isPreparingQueuedMessage => state.isPreparingQueuedMessage;
  set isPreparingQueuedMessage(bool value) {
    if (!_disposed && state.isPreparingQueuedMessage != value) {
      state = state.copyWith(isPreparingQueuedMessage: value);
    }
  }

  void Function()? onQueuedMessageTaken;

  QueuedChatMessage? takeQueuedMessage() {
    final message = queuedMessage;
    queuedMessage = null;
    final onTaken = onQueuedMessageTaken;
    onQueuedMessageTaken = null;
    onTaken?.call();
    return message;
  }

  /// 本 runtime 借用的主 client http.Client 租约池。
  /// 按 config 去重：runtime 是单个长期消费者，一个 config 只持一份租约，统一在
  /// [_cancelResources] 归还。子任务通过独立资源工厂取得并归还自己的租约。
  ///
  /// 惰性建立，且只在 [httpClientFor]（turn 处理期，ref 可用）里建；不能用
  /// `late final` + 字段初始化，否则从未跑过 turn 的 runtime 在 dispose 时会触发
  /// 惰性初始化，在 onDispose 里 `ref.read` 违反 Riverpod 约束。
  AiHttpClientLeasePool? _httpLeasePool;
  final Set<int> cancelledRequestIds = <int>{};
  final Map<int, Completer<void>> _requestCompletions =
      <int, Completer<void>>{};
  final Map<String, PendingAskUser> pendingAskUserRequests =
      <String, PendingAskUser>{};
  KeepAliveLink? _processingKeepAliveLink;
  KeepAliveLink? _sessionMutationKeepAliveLink;
  late SpawnAgentSessionRuns subAgents;
  late ToolOperationManager operations;
  Future<void> Function(ToolOperationRecord record)? persistOperation;
  int _stopAllDepth = 0;
  String? lastCancellationSource;
  bool _disposed = false;
  Future<bool> Function(String sourceTurnId)? _deliverCompletions;
  bool _completionScheduled = false;
  bool _completionRunning = false;
  int _sessionEntryDepth = 0;

  /// 取消信号发出后，执行体收尾期间仍不能开启另一条主循环。
  bool get hasActiveRequest => _requestCompletions.isNotEmpty;

  /// 用户发送的异步准备和排队接力也占用会话入口，避免通知抢先唤醒。
  void Function() retainSessionEntry() {
    final entryRef = ref;
    final lease = entryRef.keepAlive();
    _sessionEntryDepth++;
    return () {
      if (entryRef.mounted) {
        _sessionEntryDepth--;
        _scheduleCompletionDelivery();
      }
      lease.close();
    };
  }

  void configureCompletionDelivery(
    Future<bool> Function(String sourceTurnId) deliver,
  ) {
    _deliverCompletions = deliver;
    _scheduleCompletionDelivery();
  }

  bool get hasPendingCompletions =>
      state.subAgents.pending.isNotEmpty || state.operations.pending.isNotEmpty;
  (String, String)? get _nextCompletion {
    final child = state.subAgents.pending.firstOrNull;
    if (child != null) {
      return (child.run.runId, child.run.sourceTurnId!);
    }
    final operation = state.operations.pending.firstOrNull;
    if (operation != null) {
      return (operation.record.runId, operation.record.sourceTurnId);
    }
    return null;
  }

  void _scheduleCompletionDelivery() {
    if (_disposed ||
        _completionScheduled ||
        _completionRunning ||
        _sessionEntryDepth > 0 ||
        hasActiveRequest ||
        state.isSessionMutationInFlight ||
        _stopAllDepth > 0 ||
        !hasPendingCompletions ||
        _deliverCompletions == null) {
      return;
    }
    _completionScheduled = true;
    final deliveryRef = ref;
    scheduleMicrotask(() async {
      if (!deliveryRef.mounted) {
        return;
      }
      _completionScheduled = false;
      if (_sessionEntryDepth > 0 ||
          hasActiveRequest ||
          state.isSessionMutationInFlight ||
          _stopAllDepth > 0 ||
          !hasPendingCompletions) {
        return;
      }
      final first = _nextCompletion!;
      final lease = deliveryRef.keepAlive();
      _completionRunning = true;
      var mayContinue = false;
      try {
        mayContinue = await _deliverCompletions!(first.$2);
      } catch (error, stackTrace) {
        _aiProvidersLog.error(
          'completion delivery failed sessionId=$sessionId runId=${first.$1}',
          error: error,
          stackTrace: stackTrace,
        );
      } finally {
        if (deliveryRef.mounted) {
          _completionRunning = false;
          _setModeProcessing(
            processing: false,
            notifyOnComplete: lastCancellationSource == null,
          );
          // 初始化失败时保留待交付结果，不无条件重试制造自动请求循环。
          if (mayContinue ||
              (!state.subAgents.pending.any(
                    (notice) => notice.run.runId == first.$1,
                  ) &&
                  !state.operations.pending.any(
                    (notice) => notice.record.runId == first.$1,
                  ))) {
            _scheduleCompletionDelivery();
          }
        }
        lease.close();
      }
    });
  }

  @override
  AiChatRuntimeState build(String? sessionId) {
    _disposed = false;
    _deliverCompletions = null;
    _completionScheduled = false;
    _completionRunning = false;
    _sessionEntryDepth = 0;
    // Notifier 可以复用，但失效重建会关闭上一代 Ref 的租约和订阅。
    // 子任务回调及其保活只引用创建它们的这一代 build。
    final runRef = ref;
    KeepAliveLink? childLease;
    ProviderSubscription<AiChatSessionState>? sessionSubscription;
    final activities = <String, SpawnAgentActiveRun>{};
    void publishRunDisplay(
      SpawnAgentRunRecord run, [
      Map<String, dynamic>? result,
    ]) {
      if (!runRef.mounted || !run.background || run.callId == null) {
        return;
      }
      final session = runRef.read(aiChatSessionProvider(sessionId).notifier);
      final block = session.findToolCallByCallId(run.callId!)?.$2;
      if (block == null) {
        return;
      }
      // 仅更新随会话历史保存的卡片展示信息；原 Spawn tool result 仍是 running，
      // 完成结果只由独立 system_remind 投递一次。
      session.patchToolCallByCallId(
        run.callId!,
        metadata: {
          ...?block.metadata,
          'background_run': {
            'run_id': run.runId,
            'session_id': run.subSessionId,
            'status': run.status.name,
            'result': ?result,
          },
        },
      );
    }

    subAgents = SpawnAgentSessionRuns(
      parentSessionId: sessionId,
      onChanged: (next) {
        if (!runRef.mounted) {
          return;
        }
        if (next.needsRetention) {
          childLease ??= runRef.keepAlive();
          // 子任务回调会更新父消息；read 本身不能保活这份会话。
          sessionSubscription ??= runRef.listen(
            aiChatSessionProvider(sessionId),
            (_, _) {},
          );
        }
        final wasStopping = state.subAgents.runs.any(
          (run) => run.status == SpawnAgentRunStatus.stopping,
        );
        for (final run in next.runs) {
          publishRunDisplay(run);
        }
        state = state.copyWith(subAgents: next);
        _setModeProcessing(processing: false, notifyOnComplete: !wasStopping);
        _scheduleCompletionDelivery();
        if (!next.needsRetention) {
          sessionSubscription?.close();
          sessionSubscription = null;
          childLease?.close();
          childLease = null;
        }
      },
      onActivityStarted: (run) {
        final callId = run.callId;
        if (callId != null) {
          final activity = runRef.read(
            spawnAgentActiveRunProvider(callId).notifier,
          );
          activities[run.runId] = activity;
          activity.begin(run.runId);
        }
      },
      onActivity: (run, event) {
        activities[run.runId]?.apply(event, runId: run.runId);
      },
      onActivityFinished: (run) {
        activities.remove(run.runId)?.clear(runId: run.runId);
      },
      onRunFinished: publishRunDisplay,
    );
    KeepAliveLink? operationLease;
    ProviderSubscription<AiChatSessionState>? operationSession;
    final approvals = runRef.watch(aiToolApprovalControllerProvider);
    operations = ToolOperationManager(
      ownerSessionId: sessionId ?? '',
      registry: runRef.watch(toolOperationRegistryProvider),
      gate: () => ToolPermissionGate(
        runRef.read(toolPermissionServiceProvider),
        approvals,
      ),
      onChanged: (next) {
        if (!runRef.mounted) {
          return;
        }
        if (next.needsRetention) {
          operationLease ??= runRef.keepAlive();
          operationSession ??= runRef.listen(
            aiChatSessionProvider(sessionId),
            (_, _) {},
          );
        }
        state = state.copyWith(operations: next);
        _scheduleCompletionDelivery();
        if (!next.needsRetention) {
          operationSession?.close();
          operationSession = null;
          operationLease?.close();
          operationLease = null;
        }
      },
      onFinished: (record) async {
        final lease = runRef.keepAlive();
        try {
          await persistOperation?.call(record);
        } finally {
          lease.close();
        }
      },
      onRecord: (record) {
        if (!runRef.mounted) {
          return;
        }
        final session = runRef.read(
          aiChatSessionProvider(record.sourceSessionId).notifier,
        );
        final block = session
            .findToolCallByCallId(record.historyCallId ?? record.callId)
            ?.$2;
        if (block != null) {
          session.patchToolCallByCallId(
            record.historyCallId ?? record.callId,
            metadata: mergeToolOperationBlock(
              block,
              operations.state.runs.where(
                (r) => r.sourceSessionId == record.sourceSessionId,
              ),
            ).metadata,
          );
        }
      },
    );
    ref.onDispose(_disposeRuntime);
    return const AiChatRuntimeState();
  }

  SpawnAgentRun startSubAgent({
    required SpawnAgentHandler handler,
    required Map<String, dynamic> input,
    String? resumeSessionId,
    String? callId,
    ToolExecutionContext? context,
    bool background = false,
  }) {
    if (_stopAllDepth > 0) {
      throw StateError(
        'Sub-agent startup is blocked while stopping the session.',
      );
    }
    return subAgents.start(
      handler: handler,
      input: input,
      resumeSessionId: resumeSessionId,
      callId: callId,
      context: context,
      background: background,
    );
  }

  Future<SpawnAgentRun> resumeSubAgent({
    required SpawnAgentHandler handler,
    required String sessionId,
    required String message,
    String? callId,
    ToolExecutionContext? context,
  }) async {
    final lease = ref.keepAlive();
    try {
      if (_stopAllDepth > 0) {
        throw StateError(
          'Sub-agent startup is blocked while stopping the session.',
        );
      }
      return await subAgents.resume(
        handler: handler,
        sessionId: sessionId,
        message: message,
        callId: callId,
        context: context,
      );
    } finally {
      lease.close();
    }
  }

  /// Stop All 在任何取消回调之前撤销全部子结果，等待主子执行真正收尾。
  Future<void> stopAll({
    AiChatCancelSource source = AiChatCancelSource.stopButton,
  }) async {
    final lease = ref.keepAlive();
    _stopAllDepth++;
    final requests = _requestCompletions.values.map((c) => c.future).toList();
    final children = subAgents.stopAll(source: source.code);
    final operationCleanup = operations.stopTurns(
      operations.state.runs.map((run) => run.sourceTurnId).toSet(),
    );
    try {
      takeQueuedMessage();
      clearPendingNextTurnMessage();
      cancelRequest(state.requestSequence, source: source);
      await Future.wait<void>([children, operationCleanup, ...requests]);
    } finally {
      _stopAllDepth--;
      lease.close();
    }
  }

  /// Register before publishing the card; finish only the matching invocation.
  PendingAskUser registerAskUser(
    AskUserRequest request, {
    void Function(PendingAskUser pending)? onReminder,
  }) {
    final tracker = ref.read(aiModeProcessingTrackerProvider.notifier);
    final sessionNotifier = ref.read(aiChatSessionProvider(sessionId).notifier);
    if (_aiProvidersLog.isDebugEnabled) {
      _aiProvidersLog.debug(
        'AskUser registered runId=${state.requestSequence} callId=${request.callId}',
      );
    }
    pendingAskUserRequests[request.callId]?.cancel();
    final pending = PendingAskUser(
      request: request,
      runId: state.requestSequence,
      onReminder: onReminder,
      onResolved: (pending, result) {
        tracker.removeResumeCheck(pending.checkDeadline);
        if (!identical(pendingAskUserRequests[request.callId], pending)) {
          return;
        }
        pendingAskUserRequests.remove(request.callId);
        final status = AiAskUserStatus.fromResult(result);
        if (_aiProvidersLog.isDebugEnabled) {
          _aiProvidersLog.debug(
            'AskUser resolved runId=${pending.runId} callId=${request.callId} status=${status.name}',
          );
        }
        if (_disposed) {
          return;
        }
        sessionNotifier.patchAskUserBlockByCallId(
          request.callId,
          blockId: pending.blockId,
          status: status,
          answers: result.answers?.map((a) => a.toJson()).toList(),
          resolution: result.resolution,
          unansweredQuestionIds: result.unansweredQuestionIds,
        );
      },
    );
    pendingAskUserRequests[request.callId] = pending;
    sessionNotifier.addAskUserBlock(
      AiAskUserBlock(
        id: pending.blockId,
        callId: request.callId,
        questions: request.questions.map((q) => q.toJson()).toList(),
      ),
    );
    tracker.addResumeCheck(pending.checkDeadline);
    pending.start();
    return pending;
  }

  int startRequest() {
    if (state.isSessionMutationInFlight || _stopAllDepth > 0) {
      throw StateError('Chat startup is blocked by a session operation.');
    }
    final nextRequestId = state.requestSequence + 1;
    cancelledRequestIds.remove(nextRequestId);
    _requestCompletions[nextRequestId] = Completer<void>();
    lastCancellationSource = null;
    _retainWhileProcessing();
    _setModeProcessing(processing: true);
    state = state.copyWith(
      requestSequence: nextRequestId,
      isRequestInFlight: true,
    );
    return nextRequestId;
  }

  void attachAiService(AiClient service) {
    activeAiService = service;
  }

  /// 取用 [config] 的共享 http.Client，租约随本 runtime 的资源清理一并归还。
  /// 同一 config 复用同一份租约（见 [_httpLeasePool]）。
  http.Client httpClientFor(AiProvider config) {
    final pool = _httpLeasePool ??= AiHttpClientLeasePool(
      ref.read(aiHttpClientRegistryProvider),
    );
    return pool.clientFor(config);
  }

  /// 快速开书草稿的 novel_draft remind 是否尚未投递（每会话一次）。
  bool needsNovelDraftRemind() => !novelDraftRemindSent;

  void markNovelDraftRemindSent() {
    novelDraftRemindSent = true;
  }

  /// 记录「立即发送」staged 的下一轮完整消息（配合 agent.stageNextTurn 使用）。
  void stagePendingNextTurnMessage(QueuedChatMessage message) {
    _pendingNextTurnMessage = message;
    state = state.copyWith(hasPendingNextTurnMessage: true);
  }

  /// 取出并清空 staged 的下一轮完整消息；未 staged 时返回 null。
  QueuedChatMessage? takePendingNextTurnMessage() {
    final message = _pendingNextTurnMessage;
    _pendingNextTurnMessage = null;
    if (state.hasPendingNextTurnMessage) {
      state = state.copyWith(hasPendingNextTurnMessage: false);
    }
    return message;
  }

  void clearPendingNextTurnMessage() {
    _pendingNextTurnMessage = null;
    if (state.hasPendingNextTurnMessage) {
      state = state.copyWith(hasPendingNextTurnMessage: false);
    }
  }

  void clearAiService(AiClient service) {
    if (activeAiService == service) {
      activeAiService = null;
      service.dispose();
    }
  }

  void attachAgentAiService(AiClient service) {
    if (identical(agentAiService, service)) {
      return;
    }
    agentAiService?.dispose();
    agentAiService = service;
  }

  /// Starts a session-history mutation such as rollback. The synchronous
  /// check/set closes the window before the mutation's first await.
  bool tryBeginSessionMutation() {
    if (state.isSessionMutationInFlight) {
      return false;
    }
    _sessionMutationKeepAliveLink = ref.keepAlive();
    subAgents.beginSessionMutation();
    operations.beginSessionMutation();
    state = state.copyWith(isSessionMutationInFlight: true);
    return true;
  }

  void endSessionMutation() {
    if (!state.isSessionMutationInFlight) {
      return;
    }
    state = state.copyWith(isSessionMutationInFlight: false);
    subAgents.endSessionMutation();
    operations.endSessionMutation();
    _sessionMutationKeepAliveLink?.close();
    _sessionMutationKeepAliveLink = null;
  }

  /// 会话历史被外部截断/改写（如回退重发）后调用：丢弃 cached agent，
  /// 下次发送从截断后的会话历史重建 context，避免模型仍看到已删除的消息。
  /// 非在途回退不会经过 cancel，必须显式失效。
  void invalidateAgent() {
    agent = null;
    agentAiService?.dispose();
    agentAiService = null;
  }

  void incrementToolExecutions() {
    // 工具回调可能晚于 runtime dispose 到达；晚到时跳过，避免
    // UnmountedRefException。
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(
      activeToolExecutions: state.activeToolExecutions + 1,
    );
  }

  void decrementToolExecutions() {
    if (!ref.mounted) {
      return;
    }
    final next = state.activeToolExecutions <= 0
        ? 0
        : state.activeToolExecutions - 1;
    state = state.copyWith(activeToolExecutions: next);
  }

  void markRequestIdle(int requestId, {bool notifyOnComplete = true}) {
    // completer 无条件完成：waitForRequestCompletion 的调用方不依赖 ref，
    // runtime 已 dispose 时不完成会让收尾 await 永远挂起。
    final completion = _requestCompletions.remove(requestId);
    if (completion != null && !completion.isCompleted) {
      completion.complete();
    }
    if (!ref.mounted) {
      return;
    }
    final wasCancelled = cancelledRequestIds.contains(requestId);
    if (state.requestSequence == requestId) {
      state = state.copyWith(isRequestInFlight: false);
      _setModeProcessing(
        processing: false,
        notifyOnComplete: notifyOnComplete && !wasCancelled,
      );
    }
    cancelledRequestIds.remove(requestId);
    // 新请求可能先于被取消的旧请求结束；最后一个执行体收尾后才释放。
    if (_requestCompletions.isEmpty) {
      _releaseProcessingRetention();
    }
    _scheduleCompletionDelivery();
  }

  /// 等待指定请求的执行体真正结束；cancelRequest 只发出取消信号，
  /// 调用方需要等待这个 Future 才能安全地回退或重建会话历史。
  Future<void> waitForRequestCompletion(int requestId) {
    final completion = _requestCompletions[requestId];
    if (completion == null) {
      return Future<void>.value();
    }
    return completion.future;
  }

  /// 历史修改守卫期间等待全部执行体，包括已发取消但仍在收尾的旧请求。
  Future<void> waitForActiveRequests() => Future.wait<void>(
    _requestCompletions.values.map((completion) => completion.future),
  );

  void cancelRequest(int requestId, {AiChatCancelSource? source}) {
    cancelledRequestIds.add(requestId);
    // 旧 turn 的取消收尾可能晚于下一次发送；当前资源已属于新请求。
    if (state.requestSequence != requestId) {
      return;
    }
    if (source != null) {
      lastCancellationSource = source.code;
    }
    for (final pending in pendingAskUserRequests.values.toList()) {
      if (pending.runId == requestId) {
        pending.cancel();
      }
    }
    agent?.cancel();
    // cancel() 仅向底层请求发出中断，旧 Agent 的 process stream 仍可能要等
    // 网络层/工具链收尾后才退出。此时 UI 已允许再次发送；若保留引用，下一次
    // runTurn 会复用仍处于 processing 的 Agent，抛出 "already processing"。
    // 立刻脱离旧实例，让后续请求构造独立 Agent；旧 stream 会继续自行收尾。
    agent = null;
    agentAiService?.dispose();
    agentAiService = null;
    activeAiService?.cancel();
    _setModeProcessing(processing: false, notifyOnComplete: false);
    // 取消只发信号。turn 的 finally 还会访问本 runtime，由 markRequestIdle
    // 在执行体真正结束时释放保活，不能随 UI 恢复可发送状态提前释放。
    state = state.copyWith(isRequestInFlight: false, activeToolExecutions: 0);
  }

  void cancel({AiChatCancelSource source = AiChatCancelSource.runtimeDispose}) {
    lastCancellationSource = source.code;
    // cancel() can run while a session-history mutation is awaiting I/O or a
    // conflict dialog. Keep the mutation guard owned by that operation; a
    // wholesale state reset must not reopen concurrent sends mid-mutation.
    final sessionMutationInFlight = state.isSessionMutationInFlight;
    if (source != AiChatCancelSource.modelSwitch) {
      subAgents.cancelAll(source: source.code);
    }
    _cancelResources();
    _setModeProcessing(processing: false, notifyOnComplete: false);
    if (_requestCompletions.isEmpty) {
      _releaseProcessingRetention();
    }
    state = AiChatRuntimeState(
      requestSequence: state.requestSequence,
      isSessionMutationInFlight: sessionMutationInFlight,
      subAgents: state.subAgents,
      operations: state.operations,
    );
  }

  void _disposeRuntime() {
    _disposed = true;
    subAgents.dispose();
    operations.dispose();
    lastCancellationSource = AiChatCancelSource.runtimeDispose.code;
    _cancelResources();
    // 注意：不在 dispose 生命周期里调用 `_setModeProcessing`。
    // Riverpod 禁止在 onDispose 中 `ref.read` 其他 notifier；资源清理只处理
    // runtime 自己持有的 Agent/AiClient/Completer。
  }

  void _cancelResources() {
    for (final pending in pendingAskUserRequests.values.toList()) {
      pending.cancel();
    }
    agent?.cancel();
    activeAiService?.dispose();
    agentAiService?.dispose();
    agent = null;
    activeAiService = null;
    agentAiService = null;
    novelDraftRemindSent = false;
    _pendingNextTurnMessage = null;
    cancelledRequestIds.clear();
    queuedMessage = null;
    onQueuedMessageTaken = null;
    // agent / activeAiService 已销毁，其借用的 client 不会再被使用，归还全部租约。
    // 从未跑过 turn 时 pool 为 null，无需（也不能在 dispose 里）建。
    _httpLeasePool?.dispose();
    _httpLeasePool = null;
  }

  void _retainWhileProcessing() {
    _processingKeepAliveLink ??= ref.keepAlive();
  }

  void _releaseProcessingRetention() {
    _processingKeepAliveLink?.close();
    _processingKeepAliveLink = null;
  }

  void _setModeProcessing({
    required bool processing,
    bool notifyOnComplete = true,
  }) {
    final sid = sessionId;
    if (sid == null || sid.isEmpty || sid.startsWith('__new__')) {
      return;
    }
    // runtime 可能在 turn 结束、keepAlive 释放后被 dispose，晚到的回调仍会进入
    // 这里。只更新全局 processing tracker，卸载后跳过即可，避免 UnmountedRefException。
    if (!ref.mounted) {
      return;
    }
    ref
        .read(aiModeProcessingTrackerProvider.notifier)
        .setProcessing(
          mode: AiSessionMode.chat,
          sessionId: sid,
          processing:
              processing ||
              hasActiveRequest ||
              state.subAgents.needsRetention ||
              state.operations.needsRetention ||
              _completionRunning,
          notifyOnComplete:
              notifyOnComplete &&
              _stopAllDepth == 0 &&
              !state.isSessionMutationInFlight,
        );
  }
}

/// AI 聊天会话 Notifier
@riverpod
class AiChatSession extends _$AiChatSession {
  int _messageSequence = 0;

  /// Streaming 通知合帧窗口。delta 高频到达时 `state` 始终实时更新（任何
  /// `ref.read` 都能拿到最新内容），但对 listener 的通知每窗口最多一次，
  /// 避免每个 chunk 触发一轮完整 UI 重建（profile 实测单次重建 ~50ms）。
  static const _streamNotifyWindow = Duration(milliseconds: 100);
  Timer? _streamNotifyTimer;
  bool _suppressStreamNotify = false;
  bool _streamNotifyPending = false;

  @override
  AiChatSessionState build(String? sessionId) {
    ref.onDispose(() {
      _streamNotifyTimer?.cancel();
      _streamNotifyTimer = null;
    });
    return AiChatSessionState(sessionId: sessionId);
  }

  @override
  bool updateShouldNotify(
    AiChatSessionState previous,
    AiChatSessionState next,
  ) {
    if (_suppressStreamNotify && !identical(previous, next)) {
      _streamNotifyPending = true;
      return false;
    }
    // 任何正常通知都会携带最新 state，积压的合帧通知随之作废。
    _streamNotifyPending = false;
    return super.updateShouldNotify(previous, next);
  }

  /// 以合帧方式提交 streaming 增量 state：窗口空闲时立即通知（leading
  /// edge）；窗口内的后续增量只更新 state 不通知；窗口结束时若有积压则
  /// 补发一次通知并顺延窗口（trailing edge）。仅用于逐 chunk 的高频路径
  /// （文本 / thinking delta、工具参数流），低频状态变更走正常赋值。
  void _setStreamStateThrottled(AiChatSessionState next) {
    if (_streamNotifyTimer == null) {
      state = next;
      _streamNotifyTimer = Timer(
        _streamNotifyWindow,
        _onStreamNotifyWindowElapsed,
      );
      return;
    }
    _suppressStreamNotify = true;
    try {
      state = next;
    } finally {
      _suppressStreamNotify = false;
    }
  }

  void _onStreamNotifyWindowElapsed() {
    _streamNotifyTimer = null;
    if (!_streamNotifyPending) {
      return;
    }
    _streamNotifyPending = false;
    if (!ref.mounted) {
      return;
    }
    _streamNotifyTimer = Timer(
      _streamNotifyWindow,
      _onStreamNotifyWindowElapsed,
    );
    // 无参 copyWith 仅为产生新实例、把积压的最新内容通知出去。
    state = state.copyWith();
  }

  String _nextMessageId() {
    _messageSequence += 1;
    return 'msg_${DateTime.now().microsecondsSinceEpoch}_$_messageSequence';
  }

  /// 添加用户消息
  AiMessage addUserMessage(
    String content, {
    String? id,
    AiMessageType type = AiMessageType.text,
    Map<String, dynamic>? metadata,
    List<AiMessageBlock> blocks = const [],
  }) {
    final message = AiMessage.user(
      id: id ?? _nextMessageId(),
      content: content,
      type: type,
      metadata: metadata,
      blocks: blocks,
    );
    // turn 收尾可能晚于 session dispose；消息对象照常返回，跳过已失效的
    // state 写入，避免 UnmountedRefException。
    if (!ref.mounted) {
      return message;
    }
    state = state.copyWith(messages: [...state.messages, message]);
    return message;
  }

  /// 添加助手消息
  void addAssistantMessage(
    String content, {
    String? id,
    AiMessageType type = AiMessageType.text,
    Map<String, dynamic>? metadata,
    List<AiMessageBlock> blocks = const [],
  }) {
    final message = AiMessage.assistant(
      id: id ?? _nextMessageId(),
      content: content,
      type: type,
      metadata: metadata,
      blocks: blocks,
    );
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(messages: [...state.messages, message]);
  }

  /// 替换完整消息列表（用于回退截断等场景）。
  void replaceMessages(List<AiMessage> messages) {
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(messages: messages);
  }

  /// 添加流式消息（开始），或复用已有 assistant 消息进行重试。
  void startStreamingMessage({
    AiMessageType type = AiMessageType.text,
    String? messageId,
  }) {
    if (!ref.mounted) {
      return;
    }
    if (messageId != null) {
      final index = state.messages.indexWhere(
        (message) =>
            message.id == messageId && message.role == AiMessageRole.assistant,
      );
      if (index >= 0) {
        final messages = List<AiMessage>.from(state.messages);
        final current = messages[index];
        final metadata = Map<String, dynamic>.from(current.metadata ?? {});
        metadata.remove('retryable');
        messages[index] = AiMessage(
          id: current.id,
          role: AiMessageRole.assistant,
          content: '',
          type: type,
          timestamp: current.timestamp,
          metadata: metadata.isEmpty ? null : metadata,
          isStreaming: true,
          blocks: const [],
        );
        state = state.copyWith(messages: messages);
        return;
      }
    }

    final message = AiMessage.assistant(
      id: _nextMessageId(),
      content: '',
      type: type,
      isStreaming: true,
    );
    state = state.copyWith(messages: [...state.messages, message]);
  }

  /// 清空当前 streaming 气泡的 partial 内容（文本 / thinking / tool call blocks），
  /// 保留 `id` / `timestamp` / `isStreaming=true`，复用同一气泡承接重试流。
  ///
  /// 用于 AgentRoundRetry：重试前清掉 partial，避免与重试流叠加产生重复/乱码。
  /// 无 active streaming 消息时直接返回。tool block 只存在该 streaming 消息的
  /// `blocks` 内、仅内存，故 `blocks = const []` 即清空所有 pending 工具调用 UI，
  /// 无需 `cancelPendingToolCallsForRequest`。
  void clearActiveStreamingMessage() {
    if (!ref.mounted) return;
    final messages = state.messages;
    final index = _activeStreamingAssistantIndex(messages);
    if (index < 0) return;
    final current = messages[index];
    final nextMessages = List<AiMessage>.from(messages);
    nextMessages[index] = AiMessage(
      id: current.id,
      role: AiMessageRole.assistant,
      content: '',
      type: current.type,
      timestamp: current.timestamp,
      metadata: current.metadata,
      isStreaming: true,
      blocks: const [],
    );
    state = state.copyWith(messages: nextMessages);
  }

  // ==================== Block-based streaming API ====================

  int _blockSequence = 0;
  String _nextBlockId(String prefix) {
    _blockSequence += 1;
    return '${prefix}_${DateTime.now().microsecondsSinceEpoch}_$_blockSequence';
  }

  int _activeStreamingAssistantIndex(List<AiMessage> messages) {
    for (var index = messages.length - 1; index >= 0; index--) {
      final message = messages[index];
      if (message.role == AiMessageRole.assistant && message.isStreaming) {
        return index;
      }
    }
    return -1;
  }

  /// Append a text delta to the last assistant message. If the tail block is
  /// a text block we extend it; otherwise (e.g. a tool call was just emitted)
  /// a new [AiTextBlock] is started so tool call blocks stay visually separate.
  void appendTextDelta(String delta) {
    if (!ref.mounted) return;
    if (delta.isEmpty) return;
    final messages = state.messages;
    if (messages.isEmpty) return;
    final targetIndex = _activeStreamingAssistantIndex(messages);
    if (targetIndex < 0) return;
    final target = messages[targetIndex];

    final blocks = List<AiMessageBlock>.from(target.blocks);
    if (blocks.isNotEmpty && blocks.last is AiTextBlock) {
      final current = blocks.last as AiTextBlock;
      blocks[blocks.length - 1] = current.copyWith(text: current.text + delta);
    } else {
      blocks.add(AiTextBlock(id: _nextBlockId('text'), text: delta));
    }

    final updated = target.copyWith(
      blocks: blocks,
      content: target.content + delta,
    );
    final nextMessages = List<AiMessage>.from(messages);
    nextMessages[targetIndex] = updated;
    _setStreamStateThrottled(state.copyWith(messages: nextMessages));
  }

  /// Append a reasoning delta to the last assistant message. Reasoning is kept
  /// separate from visible text so the UI can default-collapse it.
  void appendThinkingDelta(String delta) {
    if (!ref.mounted) return;
    if (delta.isEmpty) return;
    final messages = state.messages;
    if (messages.isEmpty) return;
    final targetIndex = _activeStreamingAssistantIndex(messages);
    if (targetIndex < 0) return;
    final target = messages[targetIndex];

    final blocks = List<AiMessageBlock>.from(target.blocks);
    if (blocks.isNotEmpty && blocks.last is AiThinkingBlock) {
      final current = blocks.last as AiThinkingBlock;
      blocks[blocks.length - 1] = current.copyWith(text: current.text + delta);
    } else {
      blocks.add(AiThinkingBlock(id: _nextBlockId('thinking'), text: delta));
    }

    final updated = target.copyWith(blocks: blocks);
    final nextMessages = List<AiMessage>.from(messages);
    nextMessages[targetIndex] = updated;
    _setStreamStateThrottled(state.copyWith(messages: nextMessages));
  }

  void setActiveThinkingSignature(String signature) {
    if (!ref.mounted) return;
    if (signature.isEmpty) return;
    final messages = state.messages;
    if (messages.isEmpty) return;
    final targetIndex = _activeStreamingAssistantIndex(messages);
    if (targetIndex < 0) return;
    final target = messages[targetIndex];

    final blocks = List<AiMessageBlock>.from(target.blocks);
    for (var i = blocks.length - 1; i >= 0; i--) {
      final block = blocks[i];
      if (block is AiThinkingBlock) {
        blocks[i] = block.copyWith(signature: signature);
        final nextMessages = List<AiMessage>.from(messages);
        nextMessages[targetIndex] = target.copyWith(blocks: blocks);
        state = state.copyWith(messages: nextMessages);
        return;
      }
    }

    // A provider may emit a signature without a thinking_delta (for example
    // omitted/redacted thinking). Keep a signature-only block so persistence
    // and the next rebuilt conversation can replay it.
    blocks.insert(
      0,
      AiThinkingBlock(
        id: _nextBlockId('thinking'),
        text: '',
        signature: signature,
      ),
    );
    final nextMessages = List<AiMessage>.from(messages);
    nextMessages[targetIndex] = target.copyWith(blocks: blocks);
    state = state.copyWith(messages: nextMessages);
  }

  /// Inserts or updates a tool call block on the message that already owns
  /// [block.callId], or on the active streaming assistant message.
  void upsertToolCallBlock(AiToolCallBlock block) {
    if (!ref.mounted) return;
    final messages = state.messages;
    if (messages.isEmpty) return;

    // 优先更新已持有 callId 的消息（含 MessageEnd 后 isStreaming=false 的本轮气泡），
    // 避免工具阶段再建一条 isStreaming 的重复气泡。
    final located = findToolCallByCallId(block.callId);
    final int targetIndex;
    if (located != null) {
      targetIndex = located.$1;
    } else {
      final streamingIndex = _activeStreamingAssistantIndex(messages);
      if (streamingIndex >= 0) {
        targetIndex = streamingIndex;
      } else {
        final newMessage = AiMessage.assistant(
          id: _nextMessageId(),
          content: '',
          isStreaming: true,
        );
        state = state.copyWith(messages: [...messages, newMessage]);
        targetIndex = state.messages.length - 1;
      }
    }
    final target = state.messages[targetIndex];

    final blocks = List<AiMessageBlock>.from(target.blocks);
    final existingIndex = blocks.indexWhere(
      (b) => b is AiToolCallBlock && b.callId == block.callId,
    );
    if (existingIndex >= 0) {
      final existing = blocks[existingIndex] as AiToolCallBlock;
      blocks[existingIndex] = existing.copyWith(
        toolName: block.toolName,
        arguments: block.arguments.isNotEmpty ? block.arguments : null,
        status: block.status,
        result: block.result,
        errorMessage: block.errorMessage,
        targetPath: block.targetPath,
        diffOldText: block.diffOldText,
        diffNewText: block.diffNewText,
      );
    } else {
      blocks.add(block);
    }
    final updated = target.copyWith(blocks: blocks);
    final newList = List<AiMessage>.from(state.messages);
    newList[targetIndex] = updated;
    // 工具参数流（AgentToolCallDelta）逐 chunk 调用本方法，同样需要合帧；
    // status 变更走 patchToolCallByCallId 正常通知，不受影响。
    _setStreamStateThrottled(state.copyWith(messages: newList));
  }

  /// Locate a tool call block across all messages. Used by UI handlers that
  /// react to approval decisions.
  (int messageIndex, AiToolCallBlock block)? findToolCallByCallId(
    String callId,
  ) {
    // onToolStarted 闭包可能在 UI 卸载、session dispose 后仍被后台 Agent
    // 调用；此时无消息可查，返回 null 而不是抛 UnmountedRefException。
    if (!ref.mounted) {
      return null;
    }
    for (var i = 0; i < state.messages.length; i++) {
      final msg = state.messages[i];
      for (final block in msg.blocks) {
        if (block is AiToolCallBlock && block.callId == callId) {
          return (i, block);
        }
      }
    }
    return null;
  }

  /// Patch a tool call block by its call id.
  void patchToolCallByCallId(
    String callId, {
    AiToolCallStatus? status,
    Map<String, dynamic>? result,
    Map<String, dynamic>? metadata,
    String? errorMessage,
    String? targetPath,
    String? diffOldText,
    String? diffNewText,
    List<AiNestedToolCall>? nestedCalls,
    bool throttle = false,
  }) {
    if (!ref.mounted) return;
    final messages = List<AiMessage>.from(state.messages);
    var changed = false;
    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      var blockChanged = false;
      final blocks = List<AiMessageBlock>.from(msg.blocks);
      for (var j = 0; j < blocks.length; j++) {
        final b = blocks[j];
        if (b is AiToolCallBlock && b.callId == callId) {
          blocks[j] = b.copyWith(
            status: status,
            result: result,
            metadata: metadata,
            errorMessage: errorMessage,
            targetPath: targetPath,
            diffOldText: diffOldText,
            diffNewText: diffNewText,
            nestedCalls: nestedCalls,
          );
          blockChanged = true;
        }
      }
      if (blockChanged) {
        messages[i] = msg.copyWith(blocks: blocks);
        changed = true;
      }
    }
    if (changed) {
      final next = state.copyWith(messages: messages);
      if (throttle) {
        _setStreamStateThrottled(next);
      } else {
        state = next;
      }
    }
  }

  /// A late child can update only its existing parent in the originating request.
  void upsertNestedToolCall(String parentCallId, AiNestedToolCall record) {
    final located = findToolCallByCallId(parentCallId);
    if (located == null) {
      return;
    }
    final parent = located.$2;
    if (parent.status == AiToolCallStatus.cancelled &&
        record.status == AiNestedToolStatus.running) {
      record = record.copyWith(status: AiNestedToolStatus.cancelled);
    }
    final records = List<AiNestedToolCall>.from(parent.nestedCalls);
    final index = records.indexWhere((item) => item.callId == record.callId);
    if (index < 0) {
      records.add(record);
    } else {
      records[index] = record;
    }
    patchToolCallByCallId(
      parentCallId,
      nestedCalls: records,
      throttle: record.status == AiNestedToolStatus.running,
    );
  }

  void cancelPendingToolCallsForRequest(int requestId) {
    _settlePendingToolCallsForRequest(
      requestId,
      status: AiToolCallStatus.cancelled,
      result: aiCancelledToolResultPayload(),
      errorMessage: aiUserCancelledToolResultError,
    );
  }

  void failPendingToolCallsForRequest(
    int requestId, {
    required String errorCode,
    required String errorMessage,
  }) {
    _settlePendingToolCallsForRequest(
      requestId,
      status: AiToolCallStatus.error,
      result: {'ok': false, 'error': errorMessage, 'error_code': errorCode},
      errorMessage: errorMessage,
    );
  }

  void _settlePendingToolCallsForRequest(
    int requestId, {
    required AiToolCallStatus status,
    required Map<String, dynamic> result,
    required String errorMessage,
  }) {
    if (!ref.mounted) return;
    final messages = List<AiMessage>.from(state.messages);
    var changed = false;
    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      var blockChanged = false;
      final blocks = List<AiMessageBlock>.from(msg.blocks);
      for (var j = 0; j < blocks.length; j++) {
        final block = blocks[j];
        if (block is! AiToolCallBlock || block.requestId != requestId) {
          continue;
        }
        if (!aiToolCallStatusIsActive(block.status)) {
          continue;
        }
        blocks[j] = block.copyWith(
          status: status,
          result: block.toolName == 'Codemode'
              ? {...?block.result, ...result}
              : result,
          errorMessage: errorMessage,
          nestedCalls: settleNestedCalls(
            block.nestedCalls,
            cancelled: status == AiToolCallStatus.cancelled,
          ),
        );
        blockChanged = true;
      }
      if (blockChanged) {
        messages[i] = msg.copyWith(blocks: blocks);
        changed = true;
      }
    }
    if (changed) {
      state = state.copyWith(messages: messages);
    }
  }

  void upsertImageBlock(AiImageBlock block) {
    if (!ref.mounted) return;
    final messages = state.messages;
    if (messages.isEmpty) return;

    var targetIndex = _activeStreamingAssistantIndex(messages);
    AiMessage target;
    if (targetIndex >= 0) {
      target = messages[targetIndex];
    } else {
      target = AiMessage.assistant(
        id: _nextMessageId(),
        content: '',
        isStreaming: true,
      );
      state = state.copyWith(messages: [...messages, target]);
      targetIndex = state.messages.length - 1;
      target = state.messages[targetIndex];
    }

    final blocks = List<AiMessageBlock>.from(target.blocks);
    final existingIndex = blocks.indexWhere(
      (b) => b is AiImageBlock && b.id == block.id,
    );
    if (existingIndex >= 0) {
      blocks[existingIndex] = block;
    } else {
      blocks.add(block);
    }
    final updated = target.copyWith(blocks: blocks);
    final newList = List<AiMessage>.from(state.messages);
    newList[targetIndex] = updated;
    state = state.copyWith(messages: newList);
  }

  void patchImageBlock(
    String blockId, {
    AiImageStatus? status,
    String? imageUrl,
    String? imageBase64,
    String? localFilePath,
    String? assetId,
    String? revisedPrompt,
    String? characterId,
    String? itemId,
    String? errorMessage,
  }) {
    if (!ref.mounted) return;
    final messages = List<AiMessage>.from(state.messages);
    var changed = false;
    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      var blockChanged = false;
      final blocks = List<AiMessageBlock>.from(msg.blocks);
      for (var j = 0; j < blocks.length; j++) {
        final b = blocks[j];
        if (b is AiImageBlock && b.id == blockId) {
          blocks[j] = b.copyWith(
            status: status,
            imageUrl: imageUrl,
            imageBase64: imageBase64,
            localFilePath: localFilePath,
            assetId: assetId,
            revisedPrompt: revisedPrompt,
            characterId: characterId,
            itemId: itemId,
            errorMessage: errorMessage,
          );
          blockChanged = true;
        }
      }
      if (blockChanged) {
        messages[i] = msg.copyWith(blocks: blocks);
        changed = true;
      }
    }
    if (changed) {
      state = state.copyWith(messages: messages);
    }
  }

  /// Inserts or updates a next-action suggestion block in the last assistant
  /// message.
  ///
  /// 与 [addAskUserBlock] 平行，但不阻塞回合：模型挂完就走，用户没点也是正常终态。
  void addSuggestNextActionBlock(AiSuggestNextActionBlock block) {
    if (!ref.mounted) {
      return;
    }
    final messages = state.messages;
    if (messages.isEmpty) {
      return;
    }
    final targetIndex = _activeStreamingAssistantIndex(messages);
    // 没有在途 assistant 消息时直接丢弃：建议只在一轮收尾有意义，
    // 不为它单独造一条空 assistant 消息。
    if (targetIndex < 0) {
      return;
    }
    final target = messages[targetIndex];
    final blocks = List<AiMessageBlock>.from(target.blocks);
    final existingIndex = blocks.indexWhere(
      (b) => b is AiSuggestNextActionBlock && b.callId == block.callId,
    );
    if (existingIndex >= 0) {
      blocks[existingIndex] = block;
    } else {
      blocks.add(block);
    }
    final updatedMessages = [...messages];
    updatedMessages[targetIndex] = target.copyWith(blocks: blocks);
    state = state.copyWith(messages: updatedMessages);
  }

  /// Inserts or updates an AskUser block inside the last assistant message.
  void addAskUserBlock(AiAskUserBlock block) {
    if (!ref.mounted) return;
    final messages = state.messages;
    if (messages.isEmpty) return;

    var targetIndex = _activeStreamingAssistantIndex(messages);
    AiMessage target;
    if (targetIndex >= 0) {
      target = messages[targetIndex];
    } else {
      target = AiMessage.assistant(
        id: _nextMessageId(),
        content: '',
        isStreaming: true,
      );
      state = state.copyWith(messages: [...messages, target]);
      targetIndex = state.messages.length - 1;
      target = state.messages[targetIndex];
    }

    final blocks = List<AiMessageBlock>.from(target.blocks);
    final existingIndex = blocks.indexWhere(
      (b) => b is AiAskUserBlock && b.id == block.id,
    );
    if (existingIndex >= 0) {
      blocks[existingIndex] = block;
    } else {
      blocks.add(block);
    }

    final updatedMessages = [...state.messages];
    updatedMessages[targetIndex] = target.copyWith(blocks: blocks);
    state = state.copyWith(messages: updatedMessages);
  }

  /// Patch an AskUser block by its call id.
  ///
  /// 这里只更新会话内存态，落库由会话持久化流程负责。进程退出或运行时
  /// 已释放时，历史记录可能仍是 pending；它只代表最后保存的状态，不能
  /// 据此认定请求仍可回答。卡片将没有对应存活请求的 pending 派生为
  /// interrupted 展示，不回写 DB；显式中断结果仍通过本方法更新状态。
  void patchAskUserBlockByCallId(
    String callId, {
    AiAskUserStatus? status,
    List<Map<String, dynamic>>? answers,
    String? errorMessage,
    String? blockId,
    AskUserResolution? resolution,
    List<String>? unansweredQuestionIds,
  }) {
    if (!ref.mounted) {
      return;
    }
    final messages = List<AiMessage>.from(state.messages);
    var changed = false;
    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      var blockChanged = false;
      final blocks = List<AiMessageBlock>.from(msg.blocks);
      for (var j = 0; j < blocks.length; j++) {
        final b = blocks[j];
        if (b is AiAskUserBlock &&
            b.callId == callId &&
            (blockId == null || b.id == blockId)) {
          blocks[j] = b.copyWith(
            status: status,
            answers: answers,
            errorMessage: errorMessage,
            resolution: resolution,
            unansweredQuestionIds: unansweredQuestionIds,
          );
          blockChanged = true;
        }
      }
      if (blockChanged) {
        messages[i] = msg.copyWith(blocks: blocks);
        changed = true;
      }
    }
    if (changed) {
      state = state.copyWith(messages: messages);
    }
  }

  /// 更新流式消息内容
  void updateStreamingMessage(String content) {
    // 检查 provider 是否已被 dispose
    if (!ref.mounted) return;
    if (state.messages.isEmpty) return;
    final targetIndex = _activeStreamingAssistantIndex(state.messages);
    if (targetIndex < 0) return;
    final target = state.messages[targetIndex];

    final newMessages = List<AiMessage>.from(state.messages);
    newMessages[targetIndex] = target.copyWith(content: content);
    state = state.copyWith(messages: newMessages);
  }

  /// 结束流式消息
  void endStreamingMessage({AiUsage? usage, String? messageId}) {
    // 检查 provider 是否已被 dispose
    if (!ref.mounted) return;
    if (state.messages.isEmpty) return;
    final targetIndex = messageId == null
        ? _activeStreamingAssistantIndex(state.messages)
        : state.messages.indexWhere(
            (message) => message.id == messageId && message.isStreaming,
          );
    if (targetIndex < 0) return;
    final target = state.messages[targetIndex];

    final updatedMessage = target.copyWith(isStreaming: false, usage: usage);
    final newMessages = List<AiMessage>.from(state.messages);
    newMessages[targetIndex] = updatedMessage;
    state = state.copyWith(messages: newMessages);
  }

  void failStreamingMessage(String content, {Map<String, dynamic>? metadata}) {
    if (!ref.mounted) return;
    if (state.messages.isEmpty) {
      addAssistantMessage(content, metadata: metadata);
      return;
    }
    final targetIndex = _activeStreamingAssistantIndex(state.messages);
    if (targetIndex < 0) {
      addAssistantMessage(content, metadata: metadata);
      return;
    }
    final target = state.messages[targetIndex];
    final nextMessages = List<AiMessage>.from(state.messages);
    nextMessages[targetIndex] = AiMessage(
      id: target.id,
      role: AiMessageRole.assistant,
      content: content,
      type: target.type,
      timestamp: target.timestamp,
      metadata: metadata,
      isStreaming: false,
    );
    state = state.copyWith(messages: nextMessages);
  }

  void removeLastMessageIf(bool Function(AiMessage message) predicate) {
    if (!ref.mounted) return;
    // system_remind 是 model-only 状态消息，可能排在待清理的气泡之后（排队 /
    // retry 投递）；「末条消息」按最后一条非 remind 消息判定，remind 自身保留。
    for (var index = state.messages.length - 1; index >= 0; index--) {
      final message = state.messages[index];
      if (message.type == AiMessageType.system_remind) {
        continue;
      }
      if (!predicate(message)) {
        return;
      }
      final messages = List<AiMessage>.from(state.messages)..removeAt(index);
      state = state.copyWith(messages: messages);
      return;
    }
  }

  /// Removes the trailing completed assistant message when it has no UI-visible
  /// content. Provider-private empty thinking blocks may still carry a
  /// signature for runtime replay, but must not keep an empty transcript row.
  void removeLastAssistantMessageIfInvisible({String? removableText}) {
    removeLastMessageIf((message) {
      if (message.role != AiMessageRole.assistant || message.isStreaming) {
        return false;
      }
      final content = message.content.trim();
      if (content.isNotEmpty && content != removableText) {
        return false;
      }
      return !message.blocks.any((block) {
        return switch (block) {
          AiTextBlock(:final text) => text.trim().isNotEmpty,
          AiThinkingBlock(:final text) => text.trim().isNotEmpty,
          _ => true,
        };
      });
    });
  }

  void removeMessageById(String messageId) {
    if (!ref.mounted) {
      return;
    }
    final nextMessages = state.messages
        .where((message) => message.id != messageId)
        .toList(growable: false);
    if (nextMessages.length == state.messages.length) {
      return;
    }
    state = state.copyWith(messages: nextMessages);
  }

  /// 更新消息元数据
  void updateMessageMetadata(String messageId, Map<String, dynamic> metadata) {
    if (!ref.mounted) {
      return;
    }
    final newMessages = state.messages.map((msg) {
      if (msg.id == messageId) {
        return msg.copyWith(metadata: {...?msg.metadata, ...metadata});
      }
      return msg;
    }).toList();
    state = state.copyWith(messages: newMessages);
  }

  /// 清空会话
  void clearSession() {
    state = AiChatSessionState();
  }

  /// 开启一个空的新会话（保留 sessionId 为空，稍后由 UI 赋值）。
  void startNewSession({
    String? sessionId,
    String title = '写作助手',
    String? providerId,
    String? model,
    String? reasoningEffort,
    AiSessionMode? sessionMode,
    String? agentSlug,
  }) {
    state = AiChatSessionState(
      sessionId: sessionId,
      title: title,
      messages: const [],
      providerId: providerId,
      model: model,
      reasoningEffort: resolveSessionReasoningEffort(
        providerId: providerId,
        model: model,
        persistedEffort: reasoningEffort,
        settings: ref.read(aiSettingsProvider),
      ),
      sessionMode: sessionMode ?? AiSessionMode.chat,
      agentSlug: agentSlug ?? builtinAgentSlugOrchestrator,
      isLoaded: true,
    );
  }

  /// 从持久化中恢复会话。
  void loadSession({
    required String sessionId,
    required String title,
    required List<AiMessage> messages,
    String? providerId,
    String? model,
    String? persistedReasoningEffort,
    AiSessionMode? sessionMode,
    String? agentSlug,
  }) {
    state = AiChatSessionState(
      sessionId: sessionId,
      title: title.isEmpty ? '写作助手' : title,
      messages: messages,
      providerId: providerId,
      model: model,
      reasoningEffort: resolveSessionReasoningEffort(
        providerId: providerId,
        model: model,
        persistedEffort: persistedReasoningEffort,
        settings: ref.read(aiSettingsProvider),
      ),
      sessionMode: sessionMode ?? AiSessionMode.chat,
      agentSlug: agentSlug,
      isLoaded: true,
    );
  }

  /// 仅在当前 family 尚未载入该会话时从持久化恢复。
  ///
  /// 页面离开后，后台 turn 仍可能继续更新内存消息；重新进入页面触发的异步持久化
  /// 读取可能比这些更新更晚返回。此入口用于 UI hydration，避免旧数据库快照覆盖
  /// streaming 消息或仍在执行的 tool block。需要主动替换已加载内容的内部流程仍应
  /// 使用 [loadSession]。
  void loadSessionIfUnloaded({
    required String sessionId,
    required String title,
    required List<AiMessage> messages,
    String? providerId,
    String? model,
    String? persistedReasoningEffort,
    AiSessionMode? sessionMode,
    String? agentSlug,
  }) {
    if (state.sessionId == sessionId && state.isLoaded) {
      return;
    }
    loadSession(
      sessionId: sessionId,
      title: title,
      messages: messages,
      providerId: providerId,
      model: model,
      persistedReasoningEffort: persistedReasoningEffort,
      sessionMode: sessionMode,
      agentSlug: agentSlug,
    );
  }

  /// 绑定会话 id（一般在第一次发送消息时调用）。
  void bindSessionId(String sessionId) {
    if (state.sessionId == sessionId) return;
    state = state.copyWith(sessionId: sessionId, isLoaded: true);
  }

  /// 将已创建（但内存态仍未标记加载）的会话标记为已加载。
  /// ChatTurnRunner 的消息落库守卫要求 isLoaded；桌面经 [loadSession] 置位，
  /// 移动端进入即新建会话时用此轻量入口置位，避免重置 messages/标题等字段。
  void markLoaded() {
    if (state.isLoaded) {
      return;
    }
    state = state.copyWith(isLoaded: true);
  }

  void syncContext({required List<AiMessage> messages}) {
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(messages: messages);
  }

  /// 设置上下文压缩进行中状态（瞬态，不持久化）。
  void setCompactingContext(bool value) {
    if (!ref.mounted) {
      return;
    }
    if (state.isCompactingContext == value) return;
    state = state.copyWith(isCompactingContext: value);
  }

  /// 设置流式请求等待响应的瞬态状态（例如网络重试退避期间）。
  void setWaitingForResponse(bool value, {String retryProgress = ''}) {
    if (!ref.mounted) {
      return;
    }
    final progress = value ? retryProgress : '';
    if (state.isWaitingForResponse == value &&
        state.retryProgress == progress) {
      return;
    }
    state = state.copyWith(
      isWaitingForResponse: value,
      retryProgress: progress,
    );
  }

  void selectModel({required String providerId, required String model}) {
    final settings = ref.read(aiSettingsProvider);
    final reasoningEffort = resolveSessionReasoningEffort(
      providerId: providerId,
      model: model,
      settings: settings,
    );
    state = state.copyWith(
      providerId: providerId,
      model: model,
      reasoningEffort: reasoningEffort,
    );
  }

  /// 应用已持久化的模型切换，原子更新模型、推理档位与消息内存快照。
  void applyModelSwitch({
    required String providerId,
    required String model,
    required String? reasoningEffort,
    required List<AiMessage> messages,
  }) {
    state = state.copyWith(
      providerId: providerId,
      model: model,
      reasoningEffort: reasoningEffort,
      messages: messages,
    );
  }

  /// 设置当前会话模型的 reasoning effort；传 null 表示「关闭」（不推理）。
  void selectEffort(String? effort) {
    state = state.copyWith(reasoningEffort: effort);
  }

  void selectSessionMode(AiSessionMode mode) {
    state = state.copyWith(
      sessionMode: mode,
      agentSlug: mode == AiSessionMode.chat
          ? builtinAgentSlugOrchestrator
          : null,
    );
  }

  void setSessionTitle(String title) {
    final nextTitle = title.trim();
    if (nextTitle.isEmpty) {
      return;
    }
    state = state.copyWith(title: nextTitle);
  }

  /// 获取最后一条消息
  AiMessage? get lastMessage =>
      state.messages.isNotEmpty ? state.messages.last : null;
}

// ==================== AI Session Context Provider ====================

/// AI 会话上下文 Notifier
@riverpod
class AiSessionContextNotifier extends _$AiSessionContextNotifier {
  @override
  AiSessionContext build() {
    return const AiSessionContext();
  }

  void updateContext(AiSessionContext context) {
    state = context;
  }
}

// ==================== Chapter Writing State Provider ====================

/// 章节写作状态 Notifier
@riverpod
class ChapterWriting extends _$ChapterWriting {
  @override
  ChapterWritingState? build() {
    return null;
  }

  void startWriting(String chapterId) {
    state = ChapterWritingState.idle(chapterId);
  }

  void reset() {
    state = null;
  }
}

// ==================== AI HTTP Client Registry ====================

/// 共享 http.Client 的引用计数注册表。
///
/// 必须 keepAlive:借用方(聊天、dreaming、剧场等)的生命周期远长于任何单个页面
/// 或 provider,client 何时关闭只能由 [AiHttpClientLease.release] 决定,不能交给
/// autoDispose。
@Riverpod(keepAlive: true)
AiHttpClientRegistry aiHttpClientRegistry(Ref ref) => AiHttpClientRegistry();

// ==================== AI Service Provider ====================

/// AI 服务 Provider
@riverpod
AiClient? aiService(Ref ref, String? sessionId) {
  final sessionConfig = _watchAiServiceSessionConfig(ref, sessionId);
  final writerConfig = ref.watch(
    currentAiConfigProvider(
      providerId: sessionConfig.providerId,
      model: sessionConfig.model,
    ),
  );
  final context = ref.watch(aiSessionContextNotifierProvider);
  final novelContentPath = context.databasePath;
  final currentWorkId = context.workId?.trim();
  final writerOption = ref.watch(
    resolvedAiModelOptionForRoleProvider(
      role: AiModelRole.writer,
      databasePath: novelContentPath,
    ),
  );
  final config =
      writerConfig ??
      (writerOption == null
          ? null
          : ref.watch(
              currentAiConfigProvider(
                providerId: writerOption.providerId,
                model: writerOption.model,
              ),
            ));
  if (config == null || !config.isValid) return null;
  final chatModel = writerOption?.model ?? sessionConfig.model;
  if (chatModel == null) return null;
  final contentService = novelContentPath == null || novelContentPath.isEmpty
      ? null
      : ref.watch(novelContentServiceProvider(novelContentPath));
  final workingOverlay = novelContentPath == null || novelContentPath.isEmpty
      ? null
      : ref.watch(workingOverlayServiceProvider(novelContentPath));
  final locationsService = novelContentPath == null || novelContentPath.isEmpty
      ? null
      : ref.watch(locationsServiceProvider(novelContentPath));
  final imageCallback = currentWorkId == null || currentWorkId.isEmpty
      ? null
      : ref.watch(imageGenerationCallbackProvider(currentWorkId));
  final lease = ref.read(aiHttpClientRegistryProvider).acquire(config);
  ref.onDispose(lease.release);
  final httpClient = lease.client;
  // 只订阅 trace 头所需的字段：流式期间 messages 每 100ms 合帧通知一次，
  // 若 watch 整个 session state，每次通知都会重建 AiClient / AiToolManager。
  final sessionTrace = ref.watch(
    aiChatSessionProvider(
      sessionId,
    ).select((s) => (sessionId: s.sessionId, sessionMode: s.sessionMode)),
  );
  final service = AiClient(
    config,
    chatModel: chatModel,
    reasoningEffort: sessionConfig.reasoningEffort,
    novelContentService: contentService,
    workingOverlayService: workingOverlay,
    providerReader: () async =>
        (await ref.read(appSettingsProvider.future)).aiSettings.providers,
    crossWorkAccess:
        contentService == null ||
            novelContentPath == null ||
            currentWorkId == null ||
            currentWorkId.isEmpty
        ? null
        : CrossWorkResolver(
            appDatabase: ref.watch(appDatabaseProvider),
            currentDatabasePath: novelContentPath,
            currentContentService: contentService,
            currentWorkId: currentWorkId,
          ),
    sessionContext: context,
    imageGenerationCallback: imageCallback,

    httpClient: httpClient,
    traceHeadersProvider: () => buildTraceSessionHeaders(
      sessionId: sessionTrace.sessionId ?? sessionId,
      sessionMode: sessionTrace.sessionMode.value,
    ),
    createLocationCallback: locationsService == null
        ? null
        : ({
            required String name,
            String? description,
            String? type,
            String? parentId,
          }) {
            return locationsService.createLocation(
              name: name,
              description: description ?? '',
              type: type == null || type.isEmpty ? locationTypeGeneric : type,
              parentId: parentId,
            );
          },
    canvasActivityReporter: (activity) =>
        ref.read(canvasAiActivityProvider.notifier).report(activity),
  );
  ref.onDispose(service.dispose);
  return service;
}

/// AI 服务异步 Provider（用于执行 AI 操作）
@riverpod
Future<AiClient?> aiServiceAsync(Ref ref, String? sessionId) async {
  final sessionConfig = _watchAiServiceSessionConfig(ref, sessionId);
  final writerConfig = ref.watch(
    currentAiConfigProvider(
      providerId: sessionConfig.providerId,
      model: sessionConfig.model,
    ),
  );
  final context = ref.watch(aiSessionContextNotifierProvider);
  final novelContentPath = context.databasePath;
  final currentWorkId = context.workId?.trim();
  final writerOption = ref.watch(
    resolvedAiModelOptionForRoleProvider(
      role: AiModelRole.writer,
      databasePath: novelContentPath,
    ),
  );
  final config =
      writerConfig ??
      (writerOption == null
          ? null
          : ref.watch(
              currentAiConfigProvider(
                providerId: writerOption.providerId,
                model: writerOption.model,
              ),
            ));
  if (config == null || !config.isValid) return null;
  final chatModel = writerOption?.model ?? sessionConfig.model;
  if (chatModel == null) return null;
  final contentService = novelContentPath == null || novelContentPath.isEmpty
      ? null
      : ref.watch(novelContentServiceProvider(novelContentPath));
  final workingOverlay = novelContentPath == null || novelContentPath.isEmpty
      ? null
      : ref.watch(workingOverlayServiceProvider(novelContentPath));
  final locationsService = novelContentPath == null || novelContentPath.isEmpty
      ? null
      : ref.watch(locationsServiceProvider(novelContentPath));
  final imageCallback = currentWorkId == null || currentWorkId.isEmpty
      ? null
      : ref.watch(imageGenerationCallbackProvider(currentWorkId));
  final lease = ref.read(aiHttpClientRegistryProvider).acquire(config);
  ref.onDispose(lease.release);
  final httpClient = lease.client;
  // 只订阅 trace 头所需的字段：流式期间 messages 每 100ms 合帧通知一次，
  // 若 watch 整个 session state，每次通知都会重建 AiClient / AiToolManager。
  final sessionTrace = ref.watch(
    aiChatSessionProvider(
      sessionId,
    ).select((s) => (sessionId: s.sessionId, sessionMode: s.sessionMode)),
  );
  final service = AiClient(
    config,
    chatModel: chatModel,
    reasoningEffort: sessionConfig.reasoningEffort,
    novelContentService: contentService,
    workingOverlayService: workingOverlay,
    providerReader: () async =>
        (await ref.read(appSettingsProvider.future)).aiSettings.providers,
    crossWorkAccess:
        contentService == null ||
            novelContentPath == null ||
            currentWorkId == null ||
            currentWorkId.isEmpty
        ? null
        : CrossWorkResolver(
            appDatabase: ref.watch(appDatabaseProvider),
            currentDatabasePath: novelContentPath,
            currentContentService: contentService,
            currentWorkId: currentWorkId,
          ),
    sessionContext: context,
    imageGenerationCallback: imageCallback,

    httpClient: httpClient,
    traceHeadersProvider: () => buildTraceSessionHeaders(
      sessionId: sessionTrace.sessionId ?? sessionId,
      sessionMode: sessionTrace.sessionMode.value,
    ),
    createLocationCallback: locationsService == null
        ? null
        : ({
            required String name,
            String? description,
            String? type,
            String? parentId,
          }) {
            return locationsService.createLocation(
              name: name,
              description: description ?? '',
              type: type == null || type.isEmpty ? locationTypeGeneric : type,
              parentId: parentId,
            );
          },
    canvasActivityReporter: (activity) =>
        ref.read(canvasAiActivityProvider.notifier).report(activity),
  );
  ref.onDispose(service.dispose);
  await service.initialize();
  return service;
}

final aiSessionContextNotifierProvider = aiSessionContextProvider;

// ==================== Image Generation Provider ====================

/// 封面工作台使用用户配置的默认图片模型。
class CoverStudioImageModelSelection {
  const CoverStudioImageModelSelection({
    required this.config,
    required this.model,
  });

  final AiProvider config;
  final String model;
}

@riverpod
CoverStudioImageModelSelection? coverStudioImageModelSelection(Ref ref) {
  final option = ref.watch(
    resolvedAiModelOptionForKindProvider(kind: AiModelKind.image),
  );
  if (option == null) {
    return null;
  }
  final config = ref
      .watch(aiSettingsProvider)
      .findConfigById(option.providerId);
  if (config == null) {
    return null;
  }
  return CoverStudioImageModelSelection(config: config, model: option.model);
}

@riverpod
AiProvider? imageGenerationConfig(Ref ref) {
  final option = ref.watch(
    resolvedAiModelOptionForKindProvider(kind: AiModelKind.image),
  );
  if (option == null) return null;
  final settings = ref.watch(aiSettingsProvider);
  return settings.findConfigForSelection(
    providerId: option.providerId,
    model: option.model,
    kind: AiModelKind.image,
  );
}

@riverpod
AiImageGenerationCallback? imageGenerationCallback(Ref ref, String workId) {
  if (workId.trim().isEmpty) {
    throw ArgumentError.value(
      workId,
      'workId',
      'Image generation requires a work ID.',
    );
  }
  final config = ref.watch(imageGenerationConfigProvider);
  if (config == null) return null;
  final preferredOption = ref.watch(
    resolvedAiModelOptionForKindProvider(kind: AiModelKind.image),
  );
  if (preferredOption == null) {
    return null;
  }
  final defaultModel = preferredOption.model;
  final imageLibrary = ref.watch(imageLibraryServiceProvider);
  return (String prompt, {String? model, String? size, String? quality}) async {
    // 生图工具只作用于作品内的角色和物品，结果按作品入库。
    final service = AiImageGenerationService(
      config,
      model: model ?? defaultModel,
    );
    final result = await service.generateImage(
      prompt,
      model: model,
      size: size,
      quality: quality,
    );
    final asset = await imageLibrary.importGenerated(
      result,
      novelId: workId,
      purpose: AssetPurpose.ai_chat_generated,
      prompt: prompt,
      model: model ?? defaultModel,
    );
    return AiImageGenerationResult(
      imageUrl: result.imageUrl,
      imageBase64: result.imageBase64,
      revisedPrompt: result.revisedPrompt,
      mimeSubtype: result.mimeSubtype,
      localFilePath: imageLibrary.resolve(asset.path),
      assetId: asset.id,
    );
  };
}

@riverpod
AiImageGenerationCallback? coverImageGenerationCallback(Ref ref) {
  final selection = ref.watch(coverStudioImageModelSelectionProvider);
  if (selection == null) return null;
  return (String prompt, {String? model, String? size, String? quality}) {
    return AiImageGenerationService(
      selection.config,
      model: model ?? selection.model,
    ).generateImage(prompt, model: model, size: size, quality: quality);
  };
}

@riverpod
AiMultiImageEditCallback? coverImageMultiEditCallback(Ref ref) {
  final selection = ref.watch(coverStudioImageModelSelectionProvider);
  if (selection == null) return null;
  return (
    String prompt, {
    required List<String> imageData,
    String? model,
    String? size,
    String? quality,
  }) {
    return AiImageGenerationService(
      selection.config,
      model: model ?? selection.model,
    ).editImages(
      prompt,
      imageData: imageData,
      model: model,
      size: size,
      quality: quality,
    );
  };
}

@riverpod
AiImageEditCallback? imageEditCallback(Ref ref, String workId) {
  if (workId.trim().isEmpty) {
    throw ArgumentError.value(
      workId,
      'workId',
      'Image editing requires a work ID.',
    );
  }
  final config = ref.watch(imageGenerationConfigProvider);
  if (config == null) return null;
  final preferredOption = ref.watch(
    resolvedAiModelOptionForKindProvider(kind: AiModelKind.image),
  );
  if (preferredOption == null) {
    return null;
  }
  final defaultModel = preferredOption.model;
  final imageLibrary = ref.watch(imageLibraryServiceProvider);
  return (String prompt, {required String imageData, String? model}) async {
    // 生图工具只作用于作品内的角色和物品，结果按作品入库。
    final service = AiImageGenerationService(
      config,
      model: model ?? defaultModel,
    );
    final result = await service.editImage(
      prompt,
      imageData: imageData,
      model: model,
    );
    final asset = await imageLibrary.importGenerated(
      result,
      novelId: workId,
      purpose: AssetPurpose.ai_chat_generated,
      prompt: prompt,
      model: model ?? defaultModel,
    );
    return AiImageGenerationResult(
      imageUrl: result.imageUrl,
      imageBase64: result.imageBase64,
      revisedPrompt: result.revisedPrompt,
      mimeSubtype: result.mimeSubtype,
      localFilePath: imageLibrary.resolve(asset.path),
      assetId: asset.id,
    );
  };
}

@riverpod
AiMultiImageEditCallback? imageMultiEditCallback(Ref ref) {
  final config = ref.watch(imageGenerationConfigProvider);
  if (config == null) return null;
  final context = ref.watch(aiSessionContextNotifierProvider);
  final preferredOption = ref.watch(
    resolvedAiModelOptionForKindProvider(
      kind: AiModelKind.image,
      databasePath: context.databasePath,
    ),
  );
  if (preferredOption == null) {
    return null;
  }
  final defaultModel = preferredOption.model;
  return (
    String prompt, {
    required List<String> imageData,
    String? model,
    String? size,
    String? quality,
  }) async {
    final service = AiImageGenerationService(
      config,
      model: model ?? defaultModel,
    );
    final result = await service.editImages(
      prompt,
      imageData: imageData,
      model: model,
      size: size,
      quality: quality,
    );
    return result;
  };
}

@riverpod
bool isImageGenerationConfigured(Ref ref) {
  final defaultId = ref.watch(
    resolvedAiModelOptionIdForKindProvider(kind: AiModelKind.image),
  );
  return defaultId != null;
}

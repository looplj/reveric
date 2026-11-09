// 职责: Agent 运行时 — 持有 persona + 工具循环 + steer/followUp/fork/cancel + 上下文压缩
// 关联文件:
//   lib/shared/agent/agent_context_manager.dart
//   lib/shared/agent/agent_event.dart
//   lib/shared/agent/agent_tool_dispatcher.dart
//   lib/shared/agent/token_estimator.dart
//   lib/shared/services/ai/ai_chat_service.dart
//   lib/shared/services/ai/tool_result_payloads.dart

import 'package:reveric/shared/utils/ai_error.dart';
import 'tool_result.dart';
import 'dart:async';
import 'dart:convert';

import '../logger/app_logger.dart';
import '../models/ai_run_failure.dart';
import '../services/ai/tool_result_payloads.dart';

import 'message.dart';
import 'client.dart';
import 'agent_config.dart';
import 'round_assembler.dart';
import '../utils/random_id.dart';
import 'agent_hook.dart';
import 'agent_context_manager.dart';
import 'agent_event.dart';
import 'agent_tool_dispatcher.dart';
import 'loop_detector.dart';
import 'surrogate_carry.dart';
import 'token_estimator.dart';
import '../services/ai/tool_error_normalize.dart';

final _log = AppLogger.forModule('Agent');

/// 流式 round 重试上限（不含首次尝试）：共 `maxStreamRetries + 1` 次尝试。
/// 可后续提升进 AgentConfig（见 docs/solutions/agent-stream-retry.md 妥协 #2）。
///
/// 代价：每次重试原样重发整轮请求，全量输入 token 重新计费；首事件超时的那次
/// 尝试要等满 [defaultAgentStreamInactivityTimeout] 才判死，所以最坏情况下用户
/// 等待时间随该值线性增长。调整前先看这两项。
const int maxStreamRetries = 4;

/// 流式 round 重试上限（不含首次尝试）。
int streamRetryLimit({required String? providerId, int? statusCode}) {
  return maxStreamRetries;
}

/// Provider 流在首事件或相邻事件之间允许保持静默的最长时间。
///
/// HTTP/SSE 连接可能在服务端已经结束后仍既不产出事件、也不关闭或抛错。没有该边界时，
/// [process] 会永久停在 `await for`，上层的 assistant streaming 气泡也无法收口。
const Duration defaultAgentStreamInactivityTimeout = Duration(minutes: 2);

/// 连续「只思考、不产出」轮次的上限，超过即判定模型陷住并终止。
///
/// 这不是正常路径的限制，而是失控兜底：process 是 `while (true)`，旧的
/// 「最多补救 1 次」硬上限移除后，需要它保证收敛。有实质产出（正文或
/// tool call）即清零。
const int maxThinkingOnlyRounds = 5;

/// 连续「正文被截断并自动续写」轮次的上限，超过即终止并报告 incomplete response。
///
/// 这是独立于 [maxThinkingOnlyRounds] 的失控兜底：每轮都有少量正文时，
/// thinking-only 计数会被清零，不能用它保证截断续写收敛。
const int maxTruncatedResponseRounds = 5;

/// 模型只输出 thinking、没有正文时，代其写入的 assistant 自述。
///
/// 只陈述「上一轮在思考」这个事实，不复述也不伪造任何结论 —— 历史轮的
/// reasoning_content 不会进入下一轮 prompt（已实测确认），模型看不到自己
/// 想过什么，替它编造结论会污染后续推理。
const String thinkingOnlyContinuationMessage =
    '我已经对这件事做了充分思考。接下来需要判断是继续想，还是可以开始执行。';

/// thinking-only 续跑时追加的隐藏 user 回合。
///
/// 隔开连续 assistant，避免 Anthropic 等要求角色交替的上游 400。内容走
/// `<system-remind>`，UI 不渲染；写入会话后随 history 重建，后续请求前缀保持稳定。
const String thinkingOnlyContinuationRemind =
    "<system-remind type='incomplete_continue'>请继续。</system-remind>";

/// 模型已经产出部分正文但撞到输出上限时，要求它从截断位置继续。
///
/// 与 thinking-only remind 一样走 `<system-remind>`：隔开连续 assistant，
/// UI 不渲染，写入会话后随 history 重建，后续请求前缀保持稳定。
const String truncatedResponseContinuationRemind =
    "<system-remind type='incomplete_continue'>"
    '上一轮回复被截断了。请从断开的地方接着写，不要重复已经写过的内容。'
    '</system-remind>';

/// 本轮没有任何完整 tool call、只留下半截调用时，要求模型重新发起。
///
/// 半截调用被 [assembleRound] 丢弃，不会出现在 assistant 消息的 blocks 里，
/// 模型无从得知它没执行。没有这条提示，模型会当作工具已经跑过并接着往下走。
const String incompleteToolCallContinuationRemind =
    "<system-remind type='incomplete_continue'>"
    '上一轮的工具调用参数没有传输完整，该调用未执行。请重新发起这次调用，'
    '参数要完整。'
    '</system-remind>';

/// [Agent.processText] 失败时抛出的结构化异常。
class AgentProcessException implements Exception {
  const AgentProcessException(this.failure, {this.technicalMessage});

  final AiRunFailure failure;
  final String? technicalMessage;

  @override
  String toString() => 'AgentProcessException: $failure';
}

/// 单次执行的追加消息入口；关闭后明确拒绝，已接收消息按顺序消费。
class AgentMessageInbox {
  final List<AgentMessage> _pending = [];
  bool _closed = false;

  bool add(AgentMessage message) {
    if (_closed) {
      return false;
    }
    _pending.add(message);
    return true;
  }

  List<AgentMessage> _drain() {
    final messages = List<AgentMessage>.of(_pending);
    _pending.clear();
    return messages;
  }

  void close() {
    _closed = true;
  }
}

/// Fork 配置 — 让 ForkAgent 工具或外部代码派生出新 Agent。
class ForkConfig {
  const ForkConfig({this.allowedTools, this.excludeTools = const {}});

  /// fork 后允许的工具名;null 表示沿用父 Agent 的 allowedTools。
  final List<String>? allowedTools;

  /// 永远不允许的工具(在 [allowedTools] 之上再过滤)。
  final Set<String> excludeTools;
}

/// Agent 运行时。
///
/// 是 Council/Theater/Monologue/Chat Panel 等场景共用的底层抽象。
/// - persona = id / systemPrompt / allowedTools
/// - 对话历史 = [AgentContextManager]（Agent 不直接持 List）
/// - state   = _roundIndex / steer & followUp 队列
/// - api     = process / processText / steer / followUp / fork / cancel
class Agent {
  Agent._({
    required this.id,
    required this.systemPrompt,
    required this.allowedTools,
    required this._client,
    required this._config,
    required this._toolManager,
    AgentContextManager? contextManager,
    List<AgentMessage>? initialMessages,
    int initialRoundIndex = 0,
    this.providerId,
    this.hooks = const [],
    this.streamInactivityTimeout = defaultAgentStreamInactivityTimeout,
    this._emitToolEvents = true,
    this.rejectToolCalls = false,
  }) : _contextManager = contextManager ?? SimpleAgentContextManager() {
    if (initialMessages != null && initialMessages.isNotEmpty) {
      _contextManager.addMessages(initialMessages);
    }
    _contextManager.roundIndex = initialRoundIndex;
  }

  // ---------------------------------------------------------------------------
  // identity / config
  // ---------------------------------------------------------------------------

  final String id;
  String systemPrompt;
  List<String>? allowedTools;

  final String? providerId;
  final List<AgentHook> hooks;

  // ---------------------------------------------------------------------------
  // collaborators
  // ---------------------------------------------------------------------------

  final ProviderClient _client;
  final AgentConfig _config;
  final AgentToolDispatcher _toolManager;
  final bool _emitToolEvents;

  /// 保留工具 schema、但在模型返回 tool call 时立即终止本次运行。
  ///
  /// 上下文压缩需要与主请求使用相同的工具定义以命中 provider prefix
  /// cache；该模式确保即使模型错误地产生 tool call，也不会造成副作用。
  final bool rejectToolCalls;
  final Duration streamInactivityTimeout;

  AgentToolDispatcher get toolManager => _toolManager;

  // ---------------------------------------------------------------------------
  // context manager
  // ---------------------------------------------------------------------------

  final AgentContextManager _contextManager;

  /// 公开 context manager，供 fork 或外部持久化。
  AgentContextManager get contextManager => _contextManager;

  // ---------------------------------------------------------------------------
  // state
  // ---------------------------------------------------------------------------

  bool _processing = false;
  bool _cancelled = false;
  AgentCancellationController? _activeCancellationController;

  final List<AgentMessage> _steeringQueue = [];
  final List<AgentMessage> _nextTurnQueue = [];
  final List<AgentMessage> _followUpQueue = [];

  // ---------------------------------------------------------------------------
  // factories
  // ---------------------------------------------------------------------------

  /// 通用工厂 — 给所有场景用。
  factory Agent.custom({
    required String id,
    required String systemPrompt,
    required ProviderClient client,
    required AgentConfig config,
    required AgentToolDispatcher toolManager,
    List<String>? allowedTools,
    AgentContextManager? contextManager,
    List<AgentMessage>? initialMessages,
    String? providerId,
    List<AgentHook> hooks = const [],
    Duration streamInactivityTimeout = defaultAgentStreamInactivityTimeout,
    bool emitToolEvents = true,
    bool rejectToolCalls = false,
  }) {
    return Agent._(
      id: id,
      systemPrompt: systemPrompt,
      allowedTools: allowedTools,
      client: client,
      config: config,
      toolManager: toolManager,
      contextManager: contextManager,
      initialMessages: initialMessages,
      providerId: providerId,
      hooks: hooks,
      streamInactivityTimeout: streamInactivityTimeout,
      emitToolEvents: emitToolEvents,
      rejectToolCalls: rejectToolCalls,
    );
  }

  // ---------------------------------------------------------------------------
  // queue mutators
  // ---------------------------------------------------------------------------

  /// Steer:在 process 进行中插队,在下一轮 LLM 调用前/工具调用前应用。
  void steer(AgentMessage msg) {
    _steeringQueue.add(msg);
  }

  /// FollowUp:本轮 LLM 无 tool_calls 准备退出 loop 时拼接为新 user message 继续。
  void followUp(AgentMessage msg) {
    _followUpQueue.add(msg);
  }

  /// NextTurn:不打断当前 round/tool,在下一次 LLM 请求前追加 user message。
  void stageNextTurn(String slotId, AgentMessage? msg) {
    _nextTurnQueue.removeWhere((message) => message.id == slotId);
    if (msg != null) {
      if (msg.id != slotId) {
        throw ArgumentError.value(msg.id, 'msg.id', 'must match slotId');
      }
      _nextTurnQueue.add(msg);
    }
  }

  /// 取消当前 process。LLM 调用底层中断由 [ProviderClient.cancel] 触发。
  void cancel() {
    if (!_processing) {
      return;
    }
    if (_log.isDebugEnabled) {
      _log.debug(
        '[CANCEL] id=$id isProcessing=$_processing _cancelled=$_cancelled',
      );
    }
    _activeCancellationController?.cancel();
    if (!_cancelled) {
      _cancelled = true;
      _client.cancel();
    }
  }

  /// 当前是否在跑 process。
  bool get isProcessing => _processing;

  /// 当前轮次索引。
  int get roundIndex => _contextManager.roundIndex;

  /// 当前对话消息，不含 system（system 每轮由 [systemPrompt] 重建）。
  ///
  /// 用于把上下文交给之后新建的 Agent（[Agent.custom] 的 initialMessages），
  /// 让它带着已有的工具结果继续，而不必重新取一遍。传递消息而不是复用 Agent
  /// 实例，是因为 Agent 持有的 [ProviderClient] 绑定在创建时那次运行借用的
  /// http client 上，租约释放后不能再用。
  List<AgentMessage> get conversation => _contextManager
      .snapshot()
      .messages
      .where((m) => m.role != AgentMessageRole.system)
      .toList();

  /// 派生新 Agent(共享 client/toolManager,浅拷贝 contextManager,可改 allowedTools)。
  ///
  /// 调用方可通过 [ForkConfig.excludeTools] 过滤不应继承的工具。
  Agent fork(ForkConfig cfg) {
    final base =
        cfg.allowedTools ?? allowedTools ?? _toolManager.allToolNames();
    final filtered = base.where((n) => !cfg.excludeTools.contains(n)).toList();

    final snap = _contextManager.snapshot();
    final forkContextManager = switch (_contextManager) {
      SmartAgentContextManager smart => SmartAgentContextManager.fromSnapshot(
        snapshot: snap.copyWith(
          messages: snap.messages
              .where((m) => m.role != AgentMessageRole.system)
              .toList(),
        ),
        compactThreshold: smart.compactThreshold,
        contextTokens: smart.contextTokens,
        outputFloor: smart.outputFloor,
        summaryMaxChars: smart.summaryMaxChars,
        summarizer: smart.summarizer,
        contextSupplementProvider: smart.contextSupplementProvider,
      ),
      _ => SimpleAgentContextManager(
        initialMessages: snap.messages
            .where((m) => m.role != AgentMessageRole.system)
            .toList(),
        initialRoundIndex: snap.roundIndex,
      ),
    };

    return Agent._(
      id: '${id}_fork_$roundIndex',
      systemPrompt: systemPrompt,
      allowedTools: filtered,
      client: _client,
      config: _config,
      toolManager: _toolManager,
      contextManager: forkContextManager,
      providerId: providerId,
      hooks: hooks,
      streamInactivityTimeout: streamInactivityTimeout,
      emitToolEvents: _emitToolEvents,
    );
  }

  /// 替换 allowedTools(给 chat panel 切模式用,不影响正在跑的 round)。
  void updateAllowedTools(List<String>? next) {
    allowedTools = next;
  }

  /// 更新 system prompt（上下文变化时更新，不影响正在跑的 round）。
  void updateSystemPrompt(String next) {
    systemPrompt = next;
  }

  // ---------------------------------------------------------------------------
  // message building
  // ---------------------------------------------------------------------------

  /// 构建送给 LLM 的完整消息列表：system prompt + context manager 输出。
  Future<List<AgentMessage>> _buildMessages() async {
    final systemContent = StringBuffer();
    final requestTools = _toolManager is AgentRequestToolDispatcher
        ? _toolManager as AgentRequestToolDispatcher
        : null;
    systemContent.write(requestTools?.systemPromptOverride ?? systemPrompt);
    if (requestTools != null && requestTools.requestSystemPrompt.isNotEmpty) {
      systemContent.writeln();
      systemContent.write(requestTools.requestSystemPrompt);
    }
    return [
      AgentMessage.system(id: 'sys_$id', content: systemContent.toString()),
      ...await _contextManager.buildMessages(),
    ];
  }

  // ---------------------------------------------------------------------------
  // process loop
  // ---------------------------------------------------------------------------

  /// 阻塞执行,返回最终文本(给 Orchestrator 用)。
  Future<String> processText(
    String task, {
    ToolExecutionContext? toolExecutionContext,
    String? userMessageId,
  }) async {
    var finalText = '';
    AgentError? processError;
    await for (final ev in process(
      task,
      toolExecutionContext: toolExecutionContext,
      userMessageId: userMessageId,
    )) {
      switch (ev) {
        case AgentRoundText(:final text):
          finalText = text;
        case AgentDone(:final finalText):
          return finalText;
        case AgentError():
          processError = ev;
        case AgentCancelled():
          throw _AgentCancelledException();
        default:
          break;
      }
    }
    if (processError != null) {
      throw AgentProcessException(
        processError.failure,
        technicalMessage: processError.technicalMessage,
      );
    }
    return finalText;
  }

  /// 流式执行,产出 Agent 事件序列。
  /// [completionInput] 用待交付通知启动，不插入普通用户消息；资格已撤销则不请求模型。
  /// [takeCompletionMessages] 只在模型请求前与正常结束边界惰性消费，
  /// 每条持久化事件处理完成后才取下一条，避免中断时丢失尚未交付的结果。
  Stream<AgentEvent> process(
    String task, {
    List<MessageBlock> inputBlocks = const [],
    ToolExecutionContext? toolExecutionContext,
    String? userMessageId,
    AgentMessageInbox? inbox,
    bool completionInput = false,
    Iterable<AgentMessage> Function()? takeCompletionMessages,
  }) async* {
    if (_processing) {
      throw StateError('Agent($id) is already processing');
    }
    _processing = true;
    _cancelled = false;
    final previousCancellationToken = toolExecutionContext?.cancellationToken;
    final cancellationController = AgentCancellationController();
    _activeCancellationController = cancellationController;
    final removeLocalCancellationListener = cancellationController.token
        .onCancel(() {
          if (_cancelled) {
            return;
          }
          _cancelled = true;
          _client.cancel();
        });
    final removeParentCancellationListener = previousCancellationToken
        ?.onCancel(cancellationController.cancel);
    if (toolExecutionContext != null) {
      toolExecutionContext.cancellationToken = cancellationController.token;
    }
    // 复位 Smart manager 的 turn 级退避状态。
    if (_contextManager case SmartAgentContextManager smart) {
      smart.resetTurnState();
    }
    final runId = buildRandomId('run');

    try {
      yield AgentStart(task: task);
      {
        final action = await _runOnStart(task);
        switch (action) {
          case HookAbort<String>(:final failure, :final technicalMessage):
            inbox?.close();
            yield AgentError(
              failure.withProviderId(providerId),
              technicalMessage: technicalMessage,
            );
            return;
          case HookMutate<String>(:final value):
            task = value;
          default:
        }
      }
      if (!completionInput) {
        final input = AgentMessage.user(
          id: userMessageId ?? 'user_${id}_$runId',
          content: inputBlocks.isEmpty ? task : '',
          blocks: inputBlocks,
        );
        final history = _contextManager.messages;
        final existing = inputBlocks.isEmpty
            ? -1
            : history.indexWhere(
                (m) => m.id == input.id && m.role == AgentMessageRole.user,
              );
        if (existing < 0) {
          _contextManager.addMessages([input]);
        } else {
          final replaced = history.toList();
          replaced[existing] = input;
          _contextManager.setMessages(replaced);
        }
      }
      var hasInput = !completionInput;

      Iterable<AgentMessage> takeCompletions() sync* {
        if (_cancelled) {
          return;
        }
        final messages =
            takeCompletionMessages?.call() ?? const <AgentMessage>[];
        for (final message in messages) {
          _contextManager.addMessages([message]);
          hasInput = true;
          yield message;
          if (_cancelled) {
            return;
          }
        }
      }

      String lastText = '';
      // run 级请求状态（如插件替换的 system prompt）只在本次 process 的首个请求刷新。
      var requestRunStart = true;
      final partialResponseText = StringBuffer();
      final loopDetector = LoopDetector();
      var thinkingOnlyRoundCount = 0;
      var truncatedResponseRoundCount = 0;

      while (true) {
        if (_cancelled) {
          await _runOnCancelled();
          inbox?.close();
          yield const AgentCancelled();
          return;
        }

        // Layer 2 轮间检测：检查上一轮 record 的状态推进签名。
        // 只处理 abort 级别；hint 级别由 tool 前置检测处理，避免 hint 注入后
        // preLoop 重复命中导致模型没有纠正机会。
        final preLoop = loopDetector.check();
        if (preLoop != null && preLoop.severity == LoopSeverity.abort) {
          yield AgentMessageEnd(round: _contextManager.roundIndex);
          yield AgentLoopDetected(
            reason: preLoop.reason,
            details: preLoop.details,
          );
          inbox?.close();
          yield AgentDone(lastText);
          return;
        }

        // Apply pending steering before each LLM round.
        final steered = _drainSteering();
        if (steered > 0) {
          yield AgentSteeringApplied(steered);
        }
        final nextTurn = _drainNextTurns();
        if (nextTurn > 0) {
          hasInput = true;
          yield AgentNextTurnApplied(nextTurn);
        }

        _contextManager.roundIndex += 1;
        yield AgentMessageStart(round: _contextManager.roundIndex);
        await _runBeforeRound(_contextManager.roundIndex);

        // Streaming round: yield text deltas as they arrive.
        // Round 内嵌 stream retry 循环：短暂网络错误时重试同一 round（roundIndex 不变、
        // 不重发 AgentMessageStart、不写上下文）。重试前 yield AgentRoundRetry 让消费方
        // 清空 partial 气泡；详见 docs/solutions/agent-stream-retry.md。
        late AgentRoundResult round;
        // 本轮流里是否出现过参数没传完的 tool call。round.toolCalls 只保留完整
        // 调用，这是外层判断「模型输出停在工具参数中途」的唯一依据。每次 attempt
        // 重新赋值，成功那次的值留给 round 后续处理。
        var roundHadIncompleteToolCall = false;
        var attempt = 0;
        // 当前生效的重试预算：首次尝试尚无错误，先按通用上限记；一旦决定重试，
        // 按该错误的状态码刷新，供两处 attempt 日志引用。
        var activeRetryLimit = maxStreamRetries;
        while (true) {
          // 每次尝试前检查：用户取消可能发生在上一轮 delay / onLLMError await 之后。
          if (_cancelled) {
            await _runOnCancelled();
            inbox?.close();
            yield const AgentCancelled();
            return;
          }
          attempt += 1;
          var streamReceivedFirstEvent = false;
          try {
            final requestTools = _toolManager is AgentRequestToolDispatcher
                ? _toolManager as AgentRequestToolDispatcher
                : null;
            if (requestTools != null) {
              await requestTools.prepareRequest(runStart: requestRunStart);
              requestRunStart = false;
            }
            final toolNames = allowedTools;
            final tools = toolNames != null
                ? _toolManager.toolDefsForNames(toolNames)
                : _toolManager.allToolDefs();
            final systemPromptTokens = estimateTextTokens(
              '${requestTools?.systemPromptOverride ?? systemPrompt}\n'
              '${requestTools?.requestSystemPrompt ?? ''}',
            );
            late List<AgentMessage> msgs;
            var hookTools = tools;
            while (true) {
              for (final message in takeCompletions()) {
                yield AgentMessageAdded(message);
              }
              if (_cancelled) {
                throw const _AgentCancelledException();
              }
              // 自动输入在异步初始化期间可能已被撤销；不能空跑或恢复旧任务。
              if (!hasInput) {
                yield const AgentDone('');
                return;
              }
              _contextManager.addMessages(inbox?._drain() ?? const []);
              // 先合并追加消息，再检查本次请求的压缩预算。
              if (_contextManager case SmartAgentContextManager smart) {
                if (smart.shouldCompact(
                  systemPromptTokens: systemPromptTokens,
                )) {
                  final tokensBefore = smart.currentTokensEstimate(
                    systemPromptTokens: systemPromptTokens,
                  );
                  yield AgentCompactionStart(tokensBefore: tokensBefore);
                  try {
                    final outcome = await smart.compact(
                      taskText: task,
                      cancellationToken: cancellationController.token,
                      systemPromptTokens: systemPromptTokens,
                    );
                    if (_cancelled) {
                      throw const _AgentCancelledException();
                    }
                    _log.info(
                      'compaction triggered tokensBefore=${outcome.tokensBefore} '
                      'tokensAfter=${outcome.tokensAfterEstimate} '
                      'cutKind=${outcome.cutKind.name} '
                      'overflowCount=${outcome.overflowCount}',
                    );
                    yield AgentCompactionEnd(
                      ok: true,
                      tokensBefore: outcome.tokensBefore,
                      tokensAfter: outcome.tokensAfterEstimate,
                    );
                  } catch (e) {
                    if (_cancelled) {
                      await _runOnCancelled();
                      inbox?.close();
                      yield const AgentCancelled();
                      return;
                    }
                    _log.error('compaction failed error=$e');
                    yield AgentCompactionEnd(
                      ok: false,
                      tokensBefore: tokensBefore,
                      tokensAfter: tokensBefore,
                      reason: e.toString(),
                    );
                  }
                  if (_cancelled) {
                    await _runOnCancelled();
                    inbox?.close();
                    yield const AgentCancelled();
                    return;
                  }
                }
              }
              // 请求级消息按压缩后的上下文判定，追加到历史末尾并发布给持久化方。
              if (requestTools != null) {
                final requestMessages = requestTools.requestMessages(
                  _contextManager.messages,
                );
                if (requestMessages.isNotEmpty) {
                  _contextManager.addMessages(requestMessages);
                  for (final message in requestMessages) {
                    yield AgentMessageAdded(message);
                  }
                }
              }
              msgs = await _buildMessages();
              hookTools = tools;
              for (final hook in hooks) {
                final action = await hook.beforeLLM(
                  BeforeLLMContext(messages: msgs, tools: hookTools),
                );
                switch (action) {
                  case HookMutate<BeforeLLMContext>(:final value):
                    msgs = value.messages;
                    hookTools = value.tools;
                  case HookAbort<BeforeLLMContext>(
                    :final failure,
                    :final technicalMessage,
                  ):
                    inbox?.close();
                    yield AgentError(
                      failure.withProviderId(providerId),
                      technicalMessage: technicalMessage,
                    );
                    return;
                  default:
                }
              }
              // beforeLLM / 上下文构建可能 await；请求发出前接入此间收到的指令。
              final completions = <AgentMessage>[];
              for (final message in takeCompletions()) {
                completions.add(message);
                yield AgentMessageAdded(message);
              }
              final inboxMessages = inbox?._drain() ?? const <AgentMessage>[];
              final addedMessages = [...completions, ...inboxMessages];
              if (addedMessages.isNotEmpty) {
                _contextManager.addMessages(inboxMessages);
                // 准备期间收到的新消息也要经过预算检查；压缩后重新构建请求与 hooks。
                if (_contextManager case SmartAgentContextManager smart) {
                  if (smart.shouldCompact(
                    systemPromptTokens: systemPromptTokens,
                  )) {
                    continue;
                  }
                }
                msgs = [...msgs, ...addedMessages];
              }
              break;
            }
            if (_cancelled) {
              throw const _AgentCancelledException();
            }
            // maxTokens 已由调用方经 resolveAgentMaxTokens 按模型解析（见
            // agent_config.dart），本轮直接沿用，不再按剩余上下文二次缩放。
            final effectiveConfig = _config;
            final contentChars = msgs.fold<int>(
              0,
              (total, message) => total + message.content.length,
            );
            final toolBlockCount = msgs.fold<int>(
              0,
              (total, message) =>
                  total + message.blocks.whereType<ToolCallBlock>().length,
            );
            _log.info(
              'stream attempt round=${_contextManager.roundIndex} '
              'attempt=$attempt/${activeRetryLimit + 1} '
              'sessionId=${_config.sessionId ?? 'none'} '
              'providerId=$providerId client=${_client.runtimeType} '
              'messages=${msgs.length} contentChars=$contentChars '
              'toolBlocks=$toolBlockCount toolDefs=${hookTools.length} '
              'temperature=${effectiveConfig.temperature} '
              'maxTokens=${effectiveConfig.maxTokens}',
            );
            final rawStream = _client.chatStream(
              messages: msgs,
              tools: hookTools,
              options: effectiveConfig,
            );
            // 同时覆盖「请求已发出但迟迟没有首事件」和「流中途失去终止信号」。
            // 不能只取消上层订阅：Responses SDK 可能仍 await 在 HTTP send()，此时
            // 必须显式通知 ProviderClient 关闭本次专用 client，才能中止底层请求。
            // TimeoutException 进入既有 transient retry，重试耗尽后 AgentError 再由
            // ChatTurnRunner 统一结束 streaming UI。
            final stream = assembleRound(
              rawStream.timeout(
                streamInactivityTimeout,
                onTimeout: (sink) {
                  _client.cancel();
                  sink.addError(
                    TimeoutException(
                      'Provider stream produced no event within '
                      '${streamInactivityTimeout.inMilliseconds}ms',
                      streamInactivityTimeout,
                    ),
                  );
                },
              ),
            );
            AgentRoundResult? complete;
            roundHadIncompleteToolCall = false;
            // provider 可能把 emoji 拆在两个 delta 之间；下游是裸拼接后立即渲染，
            // 半个代理对会让 ParagraphBuilder 抛 not well-formed UTF-16。
            final textCarry = SurrogateCarry();
            final thinkingCarry = SurrogateCarry();
            await for (final ev in stream) {
              streamReceivedFirstEvent = true;
              if (_cancelled) {
                inbox?.close();
                yield const AgentCancelled();
                return;
              }
              switch (ev) {
                case AgentRoundTextDelta(:final text):
                  final safe = textCarry.take(text);
                  if (safe.isNotEmpty) yield AgentTextDelta(safe);
                case AgentRoundThinkingDelta(:final text):
                  final safe = thinkingCarry.take(text);
                  if (safe.isNotEmpty) yield AgentThinkingDelta(safe);
                case AgentRoundToolCallDelta(:final request):
                  yield AgentToolCallDelta(
                    callId: request.callId,
                    toolName: request.toolName,
                    arguments: request.arguments,
                    thoughtSignature: request.thoughtSignature,
                  );
                case AgentRoundToolCallComplete(:final request):
                  yield AgentToolCallComplete(
                    callId: request.callId,
                    toolName: request.toolName,
                    arguments: request.arguments,
                    thoughtSignature: request.thoughtSignature,
                  );
                case AgentRoundToolCallIncomplete(:final request):
                  roundHadIncompleteToolCall = true;
                  yield AgentToolCallIncomplete(
                    callId: request.callId,
                    toolName: request.toolName,
                    arguments: request.arguments,
                    thoughtSignature: request.thoughtSignature,
                    reason: toolCallIncompleteErrorCode,
                  );
                case AgentRoundComplete(:final result):
                  complete = result;
              }
            }
            if (_cancelled) {
              inbox?.close();
              yield const AgentCancelled();
              return;
            }
            // 流结束仍挂着半个代理对 —— 上游真的截断了，补 U+FFFD 而不是丢字符。
            final textTail = textCarry.flush();
            if (textTail.isNotEmpty) yield AgentTextDelta(textTail);
            final thinkingTail = thinkingCarry.flush();
            if (thinkingTail.isNotEmpty) yield AgentThinkingDelta(thinkingTail);
            if (complete == null) {
              if (_cancelled) {
                await _runOnCancelled();
                inbox?.close();
                yield const AgentCancelled();
                return;
              }
              const technicalMessage = 'LLM stream ended without completion';
              _log.error(
                '$technicalMessage round=${_contextManager.roundIndex} '
                'attempt=$attempt assembledEvent=$streamReceivedFirstEvent',
              );
              inbox?.close();
              yield AgentError(
                AiRunFailure.streamInterrupted(providerId: providerId),
                technicalMessage: technicalMessage,
              );
              return;
            }
            round = complete;
            // 全空响应（无正文、无 thinking、无 tool call）当作请求失败，抛进
            // 下面的 attempt 重试循环原样重发。
            //
            // 本轮若只有半截 tool call 且没有任何 thinking 产出（含 encrypted /
            // redacted），也按全空响应重试：这类输出没有可保留的推理状态，直接
            // 重发比伪造 thinking-only 历史更准确。有 thinking 的半截 tool call
            // 则交给外层 incomplete-response 续跑；已完成的 tool 必须留下，半截
            // 的丢掉。contentFiltered 不走这里 —— 重发只会被再次过滤。
            //
            // length 截断也不走这里：同样的请求会在同一处再截断，原样重发
            // 纯属浪费，交给外层 thinking-only 续跑开新一轮（新轮有全新的输出
            // 预算）。
            //
            // hadIncompleteToolCall 一并写进异常：重试行为与全空响应相同，但
            // 匿名上报需要区分「流断在 tool call 中途」与「真正的空响应」。
            if (_incompleteResponseFor(
                  round,
                  hadIncompleteToolCall: roundHadIncompleteToolCall,
                )
                case final incomplete?) {
              final retryAsEmptyResponse =
                  (!roundHadIncompleteToolCall &&
                      incomplete.reason ==
                          IncompleteResponseReason.emptyResponse) ||
                  (roundHadIncompleteToolCall &&
                      incomplete.reason !=
                          IncompleteResponseReason.contentFiltered &&
                      round.finishReason != StreamFinishReason.length &&
                      round.text.trim().isEmpty &&
                      !_hasThinkingOutput(round));
              if (retryAsEmptyResponse) {
                throw IncompleteModelResponseException(
                  reason: IncompleteResponseReason.emptyResponse,
                  finishReason: incomplete.finishReason,
                  textChars: incomplete.textChars,
                  thinkingChars: incomplete.thinkingChars,
                  hadIncompleteToolCall: roundHadIncompleteToolCall,
                );
              }
            }
            {
              final action = await _runAfterLLM(round);
              switch (action) {
                case HookAbort<AgentRoundResult>(
                  :final failure,
                  :final technicalMessage,
                ):
                  inbox?.close();
                  yield AgentError(
                    failure.withProviderId(providerId),
                    technicalMessage: technicalMessage,
                  );
                  return;
                case HookMutate<AgentRoundResult>(:final value):
                  round = value;
                default:
              }
            }
            break; // 成功：退出 retry 循环，进入 round 后续处理
          } catch (e, st) {
            if (_cancelled) {
              await _runOnCancelled();
              inbox?.close();
              yield const AgentCancelled();
              return;
            }
            final action = await _runOnLLMError(
              e,
              attempt,
              isStreamError: streamReceivedFirstEvent,
            );
            // onLLMError / hooks 是异步的：await 期间用户可能已 cancel，
            // 必须在决定 retry 前再查一次，避免把取消当网络抖动重试。
            if (_cancelled) {
              await _runOnCancelled();
              inbox?.close();
              yield const AgentCancelled();
              return;
            }
            switch (action) {
              case LLMErrorRetry(:final delay):
                activeRetryLimit = streamRetryLimit(
                  providerId: providerId,
                  statusCode: tryReadStatusCode(e),
                );
                _log.warning(
                  'round retry attempt=$attempt/${activeRetryLimit + 1} '
                  'delay=${delay.inMilliseconds}ms '
                  'assembledEvent=$streamReceivedFirstEvent error=$e',
                );
                yield AgentRoundRetry(
                  attempt: attempt,
                  reason: e.toString(),
                  retryLimit: activeRetryLimit,
                );
                await Future.delayed(delay);
                if (_cancelled) {
                  await _runOnCancelled();
                  inbox?.close();
                  yield const AgentCancelled();
                  return;
                }
                continue; // 重试同一 round（不增 roundIndex，不发新 AgentMessageStart）
              case LLMErrorAbort(:final failure):
                _log.error(
                  'round error round=${_contextManager.roundIndex} '
                  'attempt=$attempt assembledEvent=$streamReceivedFirstEvent '
                  'exceptionType=${e.runtimeType}',
                  error: e,
                  stackTrace: st,
                );
                await _runOnError(e, st);
                inbox?.close();
                yield AgentError(failure, technicalMessage: e.toString());
                return;
              case LLMErrorProceed():
                // 防御：_runOnLLMError 不会返回 proceed，但 sealed switch 要求完备。
                inbox?.close();
                yield AgentError(
                  AiRunFailure.requestFailed(providerId: providerId),
                  technicalMessage: e.toString(),
                );
                return;
            }
          }
        }

        if (rejectToolCalls && round.toolCalls.isNotEmpty) {
          const technicalMessage =
              'Context compaction must return text without tools.';
          _log.error(technicalMessage);
          inbox?.close();
          yield AgentError(
            AiRunFailure.requestFailed(providerId: providerId),
            technicalMessage: technicalMessage,
          );
          return;
        }

        final accumulatedText = '$partialResponseText${round.text}'.trim();
        lastText = accumulatedText;
        _log.info(
          'round result round=${_contextManager.roundIndex} '
          'finishReason=${round.finishReason?.name ?? 'none'} '
          'textChars=${round.text.length} '
          'thinkingChars=${round.thinking.length} '
          'toolCalls=${round.toolCalls.length} '
          'encryptedContents=${round.encryptedContents.length} '
          'usage=${round.usage?.totalTokens ?? 'none'}',
        );
        yield AgentTextComplete(round.text);
        if (round.thinking.isNotEmpty) {
          yield AgentThinkingComplete(round.thinking);
        }
        yield AgentRoundText(
          round: _contextManager.roundIndex,
          text: round.text,
          thinking: round.thinking,
        );

        final assistantBlocks = <MessageBlock>[];
        if (round.thinking.isNotEmpty ||
            round.encryptedContents.isNotEmpty ||
            (round.thinkingSignature != null &&
                round.thinkingSignature!.isNotEmpty)) {
          assistantBlocks.add(
            ThinkingBlock(
              round.thinking,
              signature: round.thinkingSignature,
              encryptedContents: round.encryptedContents,
            ),
          );
        }
        for (final tc in round.toolCalls) {
          assistantBlocks.add(
            ToolCallBlock(
              callId: tc.callId,
              toolName: tc.toolName,
              arguments: tc.arguments,
              thoughtSignature: tc.thoughtSignature,
            ),
          );
        }
        final assistantMessage = AgentMessage.assistant(
          id: 'asst_${id}_${runId}_${_contextManager.roundIndex}',
          content: round.text,
          usage: round.usage,
          blocks: assistantBlocks,
        );

        final incompleteResponse = _incompleteResponseFor(
          round,
          hadIncompleteToolCall: roundHadIncompleteToolCall,
        );
        if (incompleteResponse != null) {
          // 走到这里只剩四种形态（emptyResponse 已在 round 组装处抛去重试）：
          //
          // 1. contentFiltered —— 重发只会被再次过滤，直接终态。
          // 2. 有部分正文的 outputLimit —— 保留正文并要求模型接着续写。
          // 3. thinking-only（outputLimit / missingFinalAnswer）—— 模型思考了
          //    但没给正文。
          // 4. 有正文的 incompleteToolCall —— 工具没执行，正文只是前置说明。
          //    与 2 共用续写通道和 maxTruncatedResponseRounds：两者都是「输出停
          //    在半路、需要开新一轮接着说」，没必要各算一套上限，靠 remind 文案
          //    和日志 reason 区分即可。
          //
          // thinking-only 不再当作「失败后补救一次」，而是当作一轮正常轮次：
          // 记录 assistant 消息、追加隐藏的续跑提示、进入下一轮。这样模型能
          // 持续推进，用户不必看到「请点击发送重试」手动重发。
          //
          // 为什么 assistant content 必须非空：实测上游对 content=null 直接返回
          // 400（content or tool_calls must be set）；而 content="" 虽被接受，
          // openai_client 又会因 content 与 toolCalls 皆空整条丢弃。更关键的是
          // 实测确认历史轮的 reasoning_content 不进 prompt（同一段文本放
          // reasoning 时 prompt_tokens 与空消息相同），所以 thinking 无论如何
          // 传不回模型。这里放一句中性的自述，只陈述「上一轮在思考」这个事实，
          // 不伪造模型没说过的结论。
          if (incompleteResponse.reason ==
              IncompleteResponseReason.contentFiltered) {
            _log.error(
              'incomplete response terminal '
              'round=${_contextManager.roundIndex} '
              'reason=${incompleteResponse.reason.name} '
              'finishReason=${round.finishReason?.name ?? 'none'} '
              'textChars=${round.text.length} '
              'thinkingChars=${round.thinking.length}',
            );
            await _runOnIncompleteResponse(
              incompleteResponse,
              willRetry: false,
            );
            await _runOnError(incompleteResponse, StackTrace.current);
            inbox?.close();
            yield AgentError(
              AiRunFailure.incompleteResponse(providerId: providerId),
              technicalMessage: incompleteResponse.toString(),
            );
            return;
          }

          // outputLimit 也可能发生在模型已经产出部分正文之后。此时不能走
          // thinking-only 分支：它会用固定自述替换掉 round.text，导致 UI、Agent
          // 上下文和 AgentDone.finalText 都丢失首轮正文。
          if (round.text.trim().isNotEmpty) {
            partialResponseText.write(round.text);
            thinkingOnlyRoundCount = 0;
            truncatedResponseRoundCount += 1;
            final exhausted =
                truncatedResponseRoundCount >= maxTruncatedResponseRounds;
            await _runOnIncompleteResponse(
              incompleteResponse,
              willRetry: !exhausted,
            );
            if (exhausted) {
              _log.error(
                'truncated response rounds exhausted '
                'round=${_contextManager.roundIndex} '
                'count=$truncatedResponseRoundCount '
                'limit=$maxTruncatedResponseRounds '
                'reason=${incompleteResponse.reason.name} '
                'finishReason=${round.finishReason?.name ?? 'none'} '
                'textChars=${round.text.length}',
              );
              await _runOnError(incompleteResponse, StackTrace.current);
              inbox?.close();
              yield AgentError(
                AiRunFailure.incompleteResponse(providerId: providerId),
                technicalMessage: incompleteResponse.toString(),
              );
              return;
            }
            final continueRemind = AgentMessage.user(
              id: 'auto_incomplete_continue_${id}_${runId}_${_contextManager.roundIndex}',
              content: incompleteResponse.hadIncompleteToolCall
                  ? incompleteToolCallContinuationRemind
                  : truncatedResponseContinuationRemind,
            );
            _contextManager.addMessages([assistantMessage, continueRemind]);
            yield AgentMessageAdded(assistantMessage);
            yield AgentMessageAdded(continueRemind);
            loopDetector.recordRound(
              lastText,
              round.toolCalls,
              resultDigest: _roundResultDigest(round.toolCalls),
            );
            // 截断续写是新轮次，不复用同一条 UI 气泡：先收口本轮正文，
            // 下一轮 AgentMessageStart 再开一条。内层重试因此只会清续写轮。
            yield AgentMessageEnd(round: _contextManager.roundIndex);
            continue;
          }

          thinkingOnlyRoundCount += 1;
          // 用 >= 而非 > ：LoopDetector 的 stateWindowSize 同为 5，thinking-only
          // 轮次签名恒等（无正文、无 tool call），晚一轮就会被 Layer 2 抢先判定
          // 振荡并 yield AgentDone —— 那是「静默空成功」，比明确报错更糟，也拿
          // 不到本文件的诊断字段。这里必须先于它终止。
          final exhausted = thinkingOnlyRoundCount >= maxThinkingOnlyRounds;
          await _runOnIncompleteResponse(
            incompleteResponse,
            willRetry: !exhausted,
          );
          if (exhausted) {
            // 兜底：连续多轮只思考不产出，说明模型陷住了。
            // 此处不回滚 Agent context：之前已写入的 continuation/remind
            // 仍需保留，否则 warm Agent 与重建后的 history 会分叉。
            // 当前失败轮的 thinking 仍是临时 streaming 输出，ChatTurnRunner
            // 会在 AgentError 时清理，不会留在 transcript。
            //
            // 带上轮次数上报：匿名侧靠它区分「第一轮就失败」与「续跑多轮仍未
            // 产出」，两者排查方向不同。
            final exhaustedError = IncompleteModelResponseException(
              reason: incompleteResponse.reason,
              finishReason: incompleteResponse.finishReason,
              textChars: incompleteResponse.textChars,
              thinkingChars: incompleteResponse.thinkingChars,
              thinkingOnlyRounds: thinkingOnlyRoundCount,
            );
            _log.error(
              'thinking-only rounds exhausted '
              'round=${_contextManager.roundIndex} '
              'count=$thinkingOnlyRoundCount '
              'limit=$maxThinkingOnlyRounds '
              'reason=${incompleteResponse.reason.name} '
              'finishReason=${round.finishReason?.name ?? 'none'} '
              'thinkingChars=${round.thinking.length}',
            );
            await _runOnError(exhaustedError, StackTrace.current);
            inbox?.close();
            yield AgentError(
              AiRunFailure.incompleteResponse(providerId: providerId),
              technicalMessage: exhaustedError.toString(),
            );
            return;
          }

          _log.warning(
            'thinking-only round continues '
            'round=${_contextManager.roundIndex} '
            'count=$thinkingOnlyRoundCount '
            'reason=${incompleteResponse.reason.name} '
            'finishReason=${round.finishReason?.name ?? 'none'} '
            'thinkingChars=${round.thinking.length}',
          );
          final continuationMessage = AgentMessage.assistant(
            id: 'asst_thinking_${id}_${runId}_${_contextManager.roundIndex}',
            content: thinkingOnlyContinuationMessage,
            usage: round.usage,
            blocks: assistantBlocks,
          );
          final continueRemind = AgentMessage.user(
            id: 'auto_thinking_continue_${id}_${runId}_${_contextManager.roundIndex}',
            content: incompleteResponse.hadIncompleteToolCall
                ? incompleteToolCallContinuationRemind
                : thinkingOnlyContinuationRemind,
          );
          _contextManager.addMessages([continuationMessage, continueRemind]);
          yield AgentMessageAdded(continuationMessage);
          yield AgentMessageAdded(continueRemind);
          // 计入循环检测：拿掉旧的「最多补救 1 次」硬上限后，thinkingOnlyRoundCount
          // 是唯一的收敛保证，但轮次本身也要让 Layer 2 看到状态有没有推进。
          loopDetector.recordRound(
            lastText,
            round.toolCalls,
            resultDigest: _roundResultDigest(round.toolCalls),
          );
          continue;
        }

        // 有实质产出（正文或 tool call）即清零，thinking-only 计数只统计连续轮次。
        thinkingOnlyRoundCount = 0;
        truncatedResponseRoundCount = 0;
        // 截断续写在本轮收口：前缀已并入 lastText，必须清空，否则它会一直挂在
        // 后续每一轮的 lastText 前面，让 AgentDone.finalText 混进早已完成的旧正文。
        partialResponseText.clear();
        _contextManager.addMessages([assistantMessage]);
        yield AgentMessageAdded(assistantMessage);

        yield AgentMessageEnd(round: _contextManager.roundIndex);

        if (round.toolCalls.isEmpty) {
          // 模型脱离了 tool 循环，重置连续重复检测状态。
          loopDetector.resetConsecutive();
          final nextTurn = _drainNextTurns();
          if (nextTurn > 0) {
            yield AgentNextTurnApplied(nextTurn);
            continue;
          }
          if (_followUpQueue.isNotEmpty) {
            final picked = List<AgentMessage>.from(_followUpQueue);
            _followUpQueue.clear();
            _contextManager.addMessages(picked);
            yield AgentFollowUpApplied(picked.length);
            continue;
          }
          await _runBeforeDone(lastText);
          if (_followUpQueue.isNotEmpty) {
            final picked = List<AgentMessage>.from(_followUpQueue);
            _followUpQueue.clear();
            _contextManager.addMessages(picked);
            yield AgentFollowUpApplied(picked.length);
            continue;
          }
          final addedMessages = inbox?._drain() ?? const <AgentMessage>[];
          _contextManager.addMessages(addedMessages);
          var hasCompletions = false;
          for (final message in takeCompletions()) {
            hasCompletions = true;
            yield AgentMessageAdded(message);
          }
          if (addedMessages.isNotEmpty || hasCompletions) {
            continue;
          }
          // 检查空队列与关闭接收之间无 await，避免 accepted 后遗漏指令。
          inbox?.close();
          await _runOnDone(lastText);
          yield AgentDone(lastText);
          return;
        }

        for (
          var toolIndex = 0;
          toolIndex < round.toolCalls.length;
          toolIndex++
        ) {
          final call = round.toolCalls[toolIndex];
          if (_cancelled) {
            for (var j = toolIndex; j < round.toolCalls.length; j++) {
              final pending = round.toolCalls[j];
              for (final event in _toolResultEvents(
                runId: runId,
                call: pending,
                result: _userCancelledToolResult(),
              )) {
                yield event;
              }
            }
            await _runOnCancelled();
            inbox?.close();
            yield const AgentCancelled();
            return;
          }
          final pre = _drainSteering();
          if (pre > 0) {
            yield AgentSteeringApplied(pre);
          }

          {
            final action = await _runBeforeToolCall(
              BeforeToolCallContext(call, source: _toolSource(call)),
            );
            switch (action) {
              case HookAbort<BeforeToolCallContext>(
                :final failure,
                :final technicalMessage,
              ):
                inbox?.close();
                yield AgentError(
                  failure.withProviderId(providerId),
                  technicalMessage: technicalMessage,
                );
                return;
              case HookMutate<BeforeToolCallContext>():
                break;
              default:
            }
          }

          // Layer 1 前置检测：执行 tool 前先记录并检查是否连续重复。
          // 命中则不执行 tool，补占位 tool_result 保持上下文闭合。
          loopDetector.recordToolCall(call);
          final loopCheck = loopDetector.check();
          if (loopCheck != null) {
            // 占位 tool_result — 标记为 skipped，让 _toolResultEvents 走 skipped 路径
            // 写入 _contextManager，保持消息历史闭合（assistant tool_calls 有配对 result）。
            final placeholderResult = <String, dynamic>{
              'ok': false,
              'skipped': true,
              'error': 'Loop detected, tool call skipped',
              'error_code': 'loop_skipped',
            };

            if (loopCheck.severity == LoopSeverity.abort ||
                loopDetector.hintInjected) {
              // 硬终止：模型已收到提示仍循环，或连续次数达 abort 阈值。
              for (final event in _toolResultEvents(
                runId: runId,
                call: call,
                result: placeholderResult,
              )) {
                yield event;
              }
              // 补齐本轮剩余 tool calls 的占位 result。
              for (var j = toolIndex + 1; j < round.toolCalls.length; j++) {
                final pending = round.toolCalls[j];
                for (final event in _toolResultEvents(
                  runId: runId,
                  call: pending,
                  result: placeholderResult,
                )) {
                  yield event;
                }
              }
              yield AgentLoopDetected(
                reason: loopCheck.reason,
                details: loopCheck.details,
              );
              inbox?.close();
              yield AgentDone(lastText);
              return;
            }

            // 软循环：注入提示后给模型一次纠正机会。
            loopDetector.markHintInjected();
            for (final event in _toolResultEvents(
              runId: runId,
              call: call,
              result: placeholderResult,
            )) {
              yield event;
            }
            // 补齐本轮剩余 tool calls 的占位 result。
            for (var j = toolIndex + 1; j < round.toolCalls.length; j++) {
              final pending = round.toolCalls[j];
              for (final event in _toolResultEvents(
                runId: runId,
                call: pending,
                result: placeholderResult,
              )) {
                yield event;
              }
            }
            // 注入提示 user message，下一轮 LLM 会看到。
            _contextManager.addMessages([
              AgentMessage.user(
                id: 'loop_hint_${id}_${runId}_${_contextManager.roundIndex}',
                content: _loopHintMessage,
              ),
            ]);
            yield AgentLoopDetected(
              reason: loopCheck.reason,
              details: loopCheck.details,
            );
            // break 出 tool 循环，进入下一轮 LLM 调用（给模型一次机会）。
            break;
          }

          yield AgentToolCallStart(
            callId: call.callId,
            toolName: call.toolName,
            arguments: call.arguments,
            thoughtSignature: call.thoughtSignature,
            metadata: _callMetadata(call, toolExecutionContext),
          );

          Map<String, dynamic> result;
          if (_toolSource(call) == AgentToolSource.mcp) {
            final progressEvents = StreamController<Map<String, dynamic>>();
            final originalObserver = toolExecutionContext?.lifecycleObserver;
            final callContext = ToolExecutionContext(
              sessionId: toolExecutionContext?.sessionId,
              sourceSessionId: toolExecutionContext?.sourceSessionId,
              sourceTurnId: toolExecutionContext?.sourceTurnId,
              cancellationToken:
                  toolExecutionContext?.cancellationToken ??
                  cancellationController.token,
              parentToolCallId: toolExecutionContext?.parentToolCallId,
              operationOwnerSessionId:
                  toolExecutionContext?.operationOwnerSessionId,
              approvalHostCallId: toolExecutionContext?.approvalHostCallId,
              lifecycleObserver: ToolLifecycleObserver(
                onStarted: originalObserver?.onStarted,
                onFinished: originalObserver?.onFinished,
                onWorkingChange: originalObserver?.onWorkingChange,
                onProgress: (progress) {
                  originalObserver?.onProgress?.call(progress);
                  if (!progressEvents.isClosed) {
                    progressEvents.add(progress);
                  }
                },
              ),
            );
            final pendingResult = _dispatchTool(
              call,
              toolExecutionContext: callContext,
            );
            unawaited(pendingResult.then<void>((_) => progressEvents.close()));
            await for (final progress in progressEvents.stream) {
              yield AgentToolCallProgress(
                callId: call.callId,
                toolName: call.toolName,
                arguments: call.arguments,
                progress: progress,
                metadata: _callMetadata(call, toolExecutionContext),
              );
            }
            result = await pendingResult;
          } else {
            result = await _dispatchTool(
              call,
              toolExecutionContext: toolExecutionContext,
            );
          }
          // 取消后的失败多半由中断本身造成（如请求被 abort），统一报告为取消；
          // 成功或工具自报取消的结果照原样保留：已发生的副作用不会撤销，
          // 覆盖成取消 payload 会让模型以为什么都没做。
          if (_cancelled &&
              !toolResultIsSuccess(result) &&
              result['cancelled'] != true &&
              result['executionState'] == null) {
            result = _userCancelledToolResult();
          }
          result = normalizeToolFailureResult(result, input: call.arguments);

          for (final event in _toolResultEvents(
            runId: runId,
            call: call,
            result: result,
          )) {
            yield event;
          }

          {
            final action = await _runAfterToolCall(
              AfterToolCallContext(
                call: call,
                result: result,
                source: _toolSource(call),
              ),
            );
            switch (action) {
              case HookAbort<AfterToolCallContext>(
                :final failure,
                :final technicalMessage,
              ):
                inbox?.close();
                yield AgentError(
                  failure.withProviderId(providerId),
                  technicalMessage: technicalMessage,
                );
                return;
              default:
            }
          }
        }

        // Layer 2 状态推进记录：本轮 text + tool calls + 结果摘要。
        // 在下一轮 LLM 调用前的 preLoop 检测中判定是否振荡。
        loopDetector.recordRound(
          lastText,
          round.toolCalls,
          resultDigest: _roundResultDigest(round.toolCalls),
        );

        await _runAfterRound(
          AfterRoundContext(
            roundIndex: _contextManager.roundIndex,
            roundResult: round,
            currentMessages: _contextManager.messages,
            totalToolCalls: round.toolCalls.length,
          ),
        );
      }
    } finally {
      inbox?.close();
      for (final hook in hooks) {
        try {
          await hook.onEnd();
        } catch (error, stackTrace) {
          // Finalizers are observational and must not replace the Agent's
          // business result (for example when telemetry's DB is closing).
          _log.warning(
            'onEnd hook failed hook=${hook.runtimeType} error=$error\n'
            '$stackTrace',
          );
        }
      }
      removeParentCancellationListener?.call();
      removeLocalCancellationListener();
      if (toolExecutionContext != null &&
          identical(
            toolExecutionContext.cancellationToken,
            cancellationController.token,
          )) {
        toolExecutionContext.cancellationToken = previousCancellationToken;
      }
      if (identical(_activeCancellationController, cancellationController)) {
        _activeCancellationController = null;
      }
      _processing = false;
      yield const AgentEnd();
    }
  }

  /// 按模型发起调用的同一条管线执行一次工具：beforeToolCall → 执行 → 结果归一化
  /// → afterToolCall。不发事件、不写上下文。
  ///
  /// 供会调用其他工具的组合工具（如 Codemode）执行子调用，让 trace / logging
  /// hooks 同样覆盖这些调用。hook 拦截返回错误结果，不抛异常。
  Future<Map<String, dynamic>> runToolCall(
    ToolCall call, {
    ToolExecutionContext? context,
  }) async {
    final before = await _runBeforeToolCall(
      BeforeToolCallContext(call, source: _toolSource(call)),
    );
    if (before is HookAbort<BeforeToolCallContext>) {
      return {
        'ok': false,
        'error_code': 'hook_aborted',
        'error': before.technicalMessage ?? 'Tool call was blocked by a hook.',
      };
    }
    var result = await _dispatchTool(call, toolExecutionContext: context);
    result = normalizeToolFailureResult(result, input: call.arguments);
    await _runAfterToolCall(
      AfterToolCallContext(
        call: call,
        result: result,
        source: _toolSource(call),
      ),
    );
    return result;
  }

  Map<String, dynamic>? _callMetadata(
    ToolCall call,
    ToolExecutionContext? context,
  ) => _toolManager is AgentRequestToolDispatcher
      ? (_toolManager as AgentRequestToolDispatcher).callMetadata(
          call.toolName,
          call.arguments,
          context,
        )
      : null;

  AgentToolSource _toolSource(ToolCall call) {
    final dispatcher = _toolManager;
    return dispatcher is AgentRequestToolDispatcher &&
            (dispatcher as AgentRequestToolDispatcher).isExternalCall(
              call.toolName,
              call.arguments,
            )
        ? AgentToolSource.mcp
        : AgentToolSource.builtin;
  }

  Future<Map<String, dynamic>> _dispatchTool(
    ToolCall call, {
    ToolExecutionContext? toolExecutionContext,
  }) async {
    try {
      return await _toolManager.executeTool(
        name: call.toolName,
        input: call.arguments,
        callId: call.callId,
        emitEvents: _emitToolEvents,
        context: toolExecutionContext,
      );
    } catch (e, st) {
      if (_toolSource(call) == AgentToolSource.mcp) {
        return {
          'ok': false,
          'error_code': 'mcp_dispatch_error',
          'error': (_toolManager as AgentRequestToolDispatcher)
              .externalErrorDiagnostic(e),
          '_metadata': _callMetadata(call, toolExecutionContext),
        };
      }
      if (_cancelled) {
        return _userCancelledToolResult();
      }
      // 附加诊断字段供匿名工具错误事件上报使用：
      // exception_type / exception_message / stack_top / tool_input
      return {
        'ok': false,
        'error': '$e',
        'error_code': 'exception',
        'exception_type': safeErrorTypeName(e),
        'exception_message': sanitizeExceptionMessage(e),
        'stack_top': sanitizeStackTop(st),
        'tool_input': sanitizeToolInput(call.toolName, call.arguments),
      };
    }
  }

  /// Standard tool payload when the user cancelled via [cancel].
  static Map<String, dynamic> _userCancelledToolResult() {
    return aiCancelledToolResultPayload();
  }

  /// 软循环注入给模型的提示文案。告知模型正在重复相同操作，引导换思路。
  static const _loopHintMessage =
      '[system] You are repeating the same tool call with identical arguments. '
      'This suggests you are stuck in a loop. Stop and try a different approach — '
      'use different arguments, a different tool, or explain what you are trying to achieve.';

  /// 从 context manager 最近的 tool_result 消息中提取结果摘要，用于 Layer 2 签名。
  ///
  /// 只取 ok/error 关键字段，避免把完整结果（可能很大）纳入签名。
  String _roundResultDigest(List<ToolCall> calls) {
    if (calls.isEmpty) return '';
    final msgs = _contextManager.messages;
    final digests = <String>[];
    for (final call in calls) {
      // 找到与 callId 匹配的 tool_result 消息。
      for (var i = msgs.length - 1; i >= 0; i--) {
        final m = msgs[i];
        if (m.type != AgentMessageType.tool_result) continue;
        final block = m.blocks.whereType<ToolResultBlock>().firstWhere(
          (b) => b.toolCallId == call.callId,
          orElse: () =>
              const ToolResultBlock(toolCallId: '', toolName: '', content: []),
        );
        if (block.toolCallId.isEmpty) continue;
        final text = block.content.whereType<TextBlock>().firstOrNull?.text;
        if (text == null) {
          digests.add('${call.toolName}:${block.isError ? 'err' : 'ok'}');
        } else {
          try {
            final payload = jsonDecode(text) as Map<String, dynamic>;
            final ok = !block.isError && toolResultIsSuccess(payload);
            final err = payload['error'];
            digests.add('${call.toolName}:${ok ? 'ok' : 'err:$err'}');
          } catch (_) {
            digests.add('${call.toolName}:${block.isError ? 'err' : 'ok'}');
          }
        }
        break;
      }
    }
    return digests.join('|');
  }

  Iterable<AgentEvent> _toolResultEvents({
    required String runId,
    required ToolCall call,
    required Map<String, dynamic> result,
  }) sync* {
    final structured = result is StructuredToolResult ? result : null;
    result = normalizeToolFailureResult(result, input: call.arguments);
    final skipped = result['skipped'] == true;
    final cancelled = result['cancelled'] == true;
    final ok = toolResultIsSuccess(result);

    // `_metadata` 仅供 UI 使用，不发送给模型：从模型可见结果中剥离。
    final rawMetadata = result['_metadata'];
    final metadata = rawMetadata is Map
        ? rawMetadata.cast<String, dynamic>()
        : null;
    final modelResult = metadata == null
        ? result
        : (Map<String, dynamic>.from(result)..remove('_metadata'));

    _contextManager.addMessages([
      AgentMessage(
        id: 'tool_${runId}_${call.callId}',
        role: AgentMessageRole.user,
        type: AgentMessageType.tool_result,
        blocks: [
          ToolResultBlock(
            toolCallId: call.callId,
            toolName: call.toolName,
            isError: !ok,
            content: structured?.content.isNotEmpty == true
                ? structured!.content
                : [TextBlock(jsonEncode(modelResult))],
          ),
        ],
      ),
    ]);

    if (skipped || cancelled) {
      yield AgentToolSkipped(
        callId: call.callId,
        toolName: call.toolName,
        arguments: call.arguments,
        reason: skipped
            ? result['message']?.toString()
            : result['error']?.toString(),
        output: modelResult,
        metadata: metadata,
      );
      return;
    }

    yield AgentToolCallResult(
      callId: call.callId,
      toolName: call.toolName,
      output: modelResult,
      metadata: metadata,
      errorMessage: ok ? null : (result['error']?.toString() ?? 'unknown'),
    );
  }

  int _drainSteering() {
    if (_steeringQueue.isEmpty) return 0;
    final n = _steeringQueue.length;
    _contextManager.addMessages(_steeringQueue.toList());
    _steeringQueue.clear();
    return n;
  }

  int _drainNextTurns() {
    if (_nextTurnQueue.isEmpty) return 0;
    final n = _nextTurnQueue.length;
    _contextManager.addMessages(_nextTurnQueue.toList());
    _nextTurnQueue.clear();
    return n;
  }

  /// 本轮是否有可保留的推理产出。
  ///
  /// 与 assistant ThinkingBlock 的构造条件保持一致：provider 可能只回
  /// encrypted / redacted thinking（text 为空），这同样是不该丢弃的推理状态，
  /// 不能只看 [AgentRoundResult.thinking]。
  bool _hasThinkingOutput(AgentRoundResult round) {
    return round.thinking.isNotEmpty ||
        round.encryptedContents.isNotEmpty ||
        (round.thinkingSignature != null &&
            round.thinkingSignature!.isNotEmpty);
  }

  /// 本轮是否没有产生可作为成功结果使用的输出。
  ///
  /// [hadIncompleteToolCall] 是本轮流里出现过半截 tool call 的标记。它只在本轮
  /// **没有任何完整 tool call** 时改变判定：这种轮次不论有没有正文都零推进，工具
  /// 没执行，正文往往只是一句前置说明，不能当作成功轮提交。
  ///
  /// 有完整调用时不看它：tool_result 已经推进了上下文，本轮按正常轮提交。代价是
  /// 半截的那个对模型不可见 —— [AgentToolCallIncomplete] 只到 UI（chat_turn_runner
  /// 把卡片标成 error，非 debug 隐藏），从不写进 Agent context，恢复会话时
  /// agent_message_mapping 也会丢弃它。所以「完整调用 + 半截调用」同轮时，模型仍会
  /// 以为那次半截调用执行过。这是本方案未覆盖的残留场景，不是已解决的。
  IncompleteModelResponseException? _incompleteResponseFor(
    AgentRoundResult round, {
    required bool hadIncompleteToolCall,
  }) {
    if (round.toolCalls.isNotEmpty) {
      return null;
    }
    final reason = switch (round.finishReason) {
      StreamFinishReason.contentFilter =>
        IncompleteResponseReason.contentFiltered,
      StreamFinishReason.length => IncompleteResponseReason.outputLimit,
      // 有正文通常就算成功轮；但正文加半截调用是例外：模型话说了一半、工具没
      // 发出去，直接提交会让用户只看到那句开场白（本方案要修的就是这个）。
      _ when round.text.trim().isNotEmpty =>
        hadIncompleteToolCall
            ? IncompleteResponseReason.incompleteToolCall
            : null,
      _ when _hasThinkingOutput(round) =>
        IncompleteResponseReason.missingFinalAnswer,
      _ => IncompleteResponseReason.emptyResponse,
    };
    if (reason == null) {
      return null;
    }
    return IncompleteModelResponseException(
      reason: reason,
      finishReason: round.finishReason,
      textChars: round.text.length,
      thinkingChars: round.thinking.length,
      hadIncompleteToolCall: hadIncompleteToolCall,
    );
  }

  // ---------------------------------------------------------------------------
  // hook dispatchers — iterate _hooks and return the first non-proceed result
  // ---------------------------------------------------------------------------

  Future<HookAction<String>> _runOnStart(String task) async {
    for (final hook in hooks) {
      final action = await hook.onStart(task);
      if (action is! HookProceed) return action;
    }
    return const HookAction.proceed();
  }

  Future<void> _runBeforeRound(int roundIndex) async {
    for (final hook in hooks) {
      await hook.beforeRound(roundIndex);
    }
  }

  Future<HookAction<AgentRoundResult>> _runAfterLLM(
    AgentRoundResult round,
  ) async {
    for (final hook in hooks) {
      final action = await hook.afterLLM(round);
      if (action is HookMutate<AgentRoundResult>) {
        round = action.value;
      } else if (action is HookAbort<AgentRoundResult>) {
        return action;
      }
    }
    return HookAction.proceed();
  }

  Future<LLMErrorAction> _runOnLLMError(
    Object error,
    int attempt, {
    bool isStreamError = false,
  }) async {
    // 用户主动取消：cancel 会中断底层 stream 并抛出看似可重试的网络异常
    // （ClientException 等）。此处不得返回 retry，否则会在用户取消后继续打模型。
    if (_cancelled) {
      return LLMErrorAction.abort(
        AiRunFailure.requestFailed(providerId: providerId),
      );
    }
    for (final hook in hooks) {
      final action = await hook.onLLMError(
        error,
        attempt,
        isStreamError: isStreamError,
      );
      if (_cancelled) {
        return LLMErrorAction.abort(
          AiRunFailure.requestFailed(providerId: providerId),
        );
      }
      if (action is LLMErrorRetry) {
        return action;
      }
      if (action is LLMErrorAbort) {
        return LLMErrorAction.abort(action.failure.withProviderId(providerId));
      }
      // LLMErrorProceed：该 hook 无意见，继续问下一个 hook。
    }
    if (_cancelled) {
      return LLMErrorAction.abort(
        AiRunFailure.requestFailed(providerId: providerId),
      );
    }
    if (error is IncompleteModelResponseException) {
      // 只有全空响应会走到这里（见 round 组装处的抛出点）。偶发空响应重发一次
      // 往往就正常，重试耗尽才终态。
      if (attempt <= maxStreamRetries) {
        return LLMErrorAction.retry(streamRetryDelay(attempt));
      }
      return LLMErrorAction.abort(
        AiRunFailure.incompleteResponse(providerId: providerId),
      );
    }
    if (isContextLengthExceeded(error)) {
      return LLMErrorAction.abort(
        AiRunFailure(
          kind: AiRunFailureKind.contextWindowExhausted,
          providerId: providerId,
          providerMessage: tryReadProviderMessage(error),
          providerCode: tryReadProviderErrorCode(error),
        ),
      );
    }
    final providerMessage = tryReadProviderMessage(error);
    final providerCode = tryReadProviderErrorCode(error);
    final statusCode = tryReadStatusCode(error);
    if (statusCode != null) {
      final isServerError = statusCode >= 500 && statusCode < 600;
      if (isServerError) {
        // 5xx：通用可重试的服务器错误。
        final retryLimit = streamRetryLimit(
          providerId: providerId,
          statusCode: statusCode,
        );
        if (attempt <= retryLimit) {
          return LLMErrorAction.retry(streamRetryDelay(attempt));
        }
        return LLMErrorAction.abort(
          AiRunFailure.http(
            statusCode: statusCode,
            providerId: providerId,
            providerMessage: providerMessage,
            providerCode: providerCode,
          ),
        );
      }
      return LLMErrorAction.abort(
        AiRunFailure.http(
          statusCode: statusCode,
          providerId: providerId,
          providerMessage: providerMessage,
          providerCode: providerCode,
        ),
      );
    }
    // SDK 的流内错误通常没有 HTTP 状态码。按异常类型有限重试，不猜测供应商
    // 文案或错误码；沿用 trace reporter 的类型名判定，避免 Agent 依赖具体 SDK。
    final isProviderStreamError =
        error.runtimeType.toString() == 'StreamException';
    if (attempt <= maxStreamRetries &&
        (isProviderStreamError || isTransientNetworkError(error))) {
      return LLMErrorAction.retry(streamRetryDelay(attempt));
    }
    if (isStreamError || isProviderStreamError) {
      return LLMErrorAction.abort(
        AiRunFailure.streamInterrupted(
          providerId: providerId,
          providerMessage: providerMessage,
          providerCode: providerCode,
        ),
      );
    }
    if (isTransientNetworkError(error)) {
      return LLMErrorAction.abort(AiRunFailure.network(providerId: providerId));
    }
    return LLMErrorAction.abort(
      AiRunFailure.requestFailed(
        providerId: providerId,
        providerMessage: providerMessage,
        providerCode: providerCode,
      ),
    );
  }

  Future<HookAction<BeforeToolCallContext>> _runBeforeToolCall(
    BeforeToolCallContext ctx,
  ) async {
    for (final hook in hooks) {
      final action = await hook.beforeToolCall(ctx);
      if (action is HookAbort<BeforeToolCallContext>) {
        return action;
      }
    }
    return const HookAction.proceed();
  }

  Future<HookAction<AfterToolCallContext>> _runAfterToolCall(
    AfterToolCallContext ctx,
  ) async {
    for (final hook in hooks) {
      final action = await hook.afterToolCall(ctx);
      if (action is HookMutate<AfterToolCallContext>) {
        ctx = action.value;
      } else if (action is HookAbort<AfterToolCallContext>) {
        return action;
      }
    }
    return HookAction.proceed();
  }

  Future<void> _runAfterRound(AfterRoundContext ctx) async {
    for (final hook in hooks) {
      await hook.afterRound(ctx);
    }
  }

  Future<void> _runBeforeDone(String finalText) async {
    if (hooks.isEmpty) {
      return;
    }
    final ctx = BeforeDoneContext(
      finalText: finalText,
      currentMessages: List<AgentMessage>.unmodifiable(
        _contextManager.messages,
      ),
      followUp: followUp,
    );
    for (final hook in hooks) {
      await hook.beforeDone(ctx);
    }
  }

  Future<void> _runOnDone(String finalText) async {
    for (final hook in hooks) {
      await hook.onDone(finalText);
    }
  }

  Future<void> _runOnIncompleteResponse(
    IncompleteModelResponseException error, {
    required bool willRetry,
  }) async {
    for (final hook in hooks) {
      await hook.onIncompleteResponse(error, willRetry: willRetry);
    }
  }

  Future<void> _runOnError(Object error, StackTrace? stackTrace) async {
    for (final hook in hooks) {
      await hook.onError(error, stackTrace);
    }
  }

  Future<void> _runOnCancelled() async {
    for (final hook in hooks) {
      await hook.onCancelled();
    }
  }
}

class _AgentCancelledException implements Exception {
  const _AgentCancelledException();
  @override
  String toString() => 'AgentCancelled';
}

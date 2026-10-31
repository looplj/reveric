// 职责: Agent Council 多智能体讨论编排 — 调度多个 AI 参与者进行剧情讨论，支持实时消息回调、流式输出与自定义模型。
// 关联文件:
//   lib/shared/models/agent_council_models.dart
//   lib/shared/models/agent_run_state.dart
//   lib/shared/agent/agent.dart
//   lib/shared/agent/agent_orchestrator.dart
//   lib/shared/services/ai/chat.dart
//   lib/shared/providers/agent_council_providers.dart
import 'dart:async';
import '../plugins/agent_dispatcher.dart';
import '../plugins/host.dart';
import '../mcp/settings_service.dart';
import 'mcp/agent_dispatcher.dart';
import '../../agent/agent_tool_dispatcher.dart';
import 'dart:math';

import '../../logger/app_logger.dart';

import '../../models/agent_council_models.dart';
import '../../models/ai_chat_models.dart';
import '../../models/ai_run_failure.dart';
import '../../models/ai_session_mode.dart';
import '../../utils/random_id.dart';
import '../../agent/agent.dart';
import '../../agent/message.dart';
import '../../agent/agent_hook.dart';
import '../../agent/agent_orchestrator.dart';
import '../../agent/client/trace_headers_http_client.dart'
    show buildTraceSubSessionId;
import '../../agent/hooks/trace_hook.dart';
import '../../services/ai/trace_reporter_service.dart';
import 'chat.dart';
import 'mode_output_parser.dart';
import 'usage_service.dart';
import 'usage_hook.dart';
import 'prompts/use_cases/mode_prompt_use_case.dart';
import 'prompts/use_cases/title_prompt_use_case.dart';

typedef CouncilMessageCallback =
    void Function(AgentCouncilSession session, CouncilMessage message);

typedef CouncilPhaseCallback = void Function(AgentCouncilSession session);

typedef CouncilTitleCallback = void Function(String title);

typedef CouncilAiServiceResolver =
    Future<AiClient?> Function(String? modelOptionId);

typedef CouncilTextDeltaCallback =
    void Function(String participantId, int round, String text);

typedef CouncilThinkingDeltaCallback =
    void Function(String participantId, int round, String thinking);

typedef CouncilToolCallCallback =
    void Function(String participantId, int round, AiToolCallBlock block);

/// Council 当前运行已失败。
class AgentCouncilRunException implements Exception {
  const AgentCouncilRunException(this.failure, {this.cause});

  final AiRunFailure failure;
  final Object? cause;

  @override
  String toString() => 'AgentCouncilRunException: $failure';
}

final _log = AppLogger.forModule('AgentCouncil');

/// 标题生成的硬上限：超时后放弃，由 provider 兜底默认标题，
/// 避免 provider 无响应时把已经跑完的讨论永久卡在收尾阶段。
const _titleTimeout = Duration(seconds: 20);

class AgentCouncilOrchestrator {
  late PluginHostService pluginHost;
  McpSettingsService? mcpService;

  /// 由运行资源提供独立标题客户端；不捕获 UI，也不借用正文的租约。
  Future<String> Function(Future<String> Function(AiClient))? titleClientRunner;

  bool _cancelled = false;
  AgentOrchestrator? _activeOrchestrator;
  String? _agentSessionId;
  TraceReporterService? _traceReporter;
  UsageService? _usageService;
  String? _usageNovelId;

  /// 各参与者跨轮沿用的对话上下文（不含 system）。追加一轮时作为新建 Agent 的
  /// initialMessages 传入，让它们带着上一轮已读到的作品概览、设定等工具结果继续，
  /// 不必重新调一遍工具。
  ///
  /// 存消息而不是 Agent 实例：Agent 的 [ProviderClient] 绑定在那次运行借用的
  /// http client 上（见 ai_http_client_lease.dart），运行结束租约释放后就用不了了。
  final Map<String, List<AgentMessage>> _transcriptsByParticipantId = {};

  /// 全局只保留最近一场议事的上下文。runtime provider 是 keepAlive family 且无人
  /// invalidate，跑过的每个会话都会留下一个 orchestrator；不设上界的话，每场议事
  /// 都会常驻一份带完整工具结果的上下文。
  static AgentCouncilOrchestrator? _transcriptCacheOwner;

  static String _identity(String key) => key;

  List<String>? _councilToolNames(AiClient aiService) {
    return aiService.toolManager!
        .allToolNames()
        .where(AiSessionMode.council.canUseTool)
        .toList();
  }

  List<AgentHook> _agentTraceHooks({
    required String sessionId,
    required AiClient aiService,
  }) {
    final reporter = _traceReporter;
    if (reporter == null) return const [];
    return buildTraceHooks(
      reporter: reporter,
      sessionId: () => sessionId,
      model: () => aiService.chatModel,
      providerId: () => aiService.providerId,
      sessionMode: AiSessionMode.council.value,
    );
  }

  List<AgentHook> _usageHooks({
    required String sessionId,
    required AiClient aiService,
  }) {
    final service = _usageService;
    if (service == null) {
      return const [];
    }
    return [
      UsageHook(
        service: service,
        providerId: () => aiService.providerId,
        model: () => aiService.chatModel,
        sessionId: () => sessionId,
        novelId: () => _usageNovelId,
        source: UsageSources.council,
      ),
    ];
  }

  List<AgentHook> _agentHooks({
    required String sessionId,
    required AiClient aiService,
  }) {
    return [
      ..._usageHooks(sessionId: sessionId, aiService: aiService),
      ..._agentTraceHooks(sessionId: sessionId, aiService: aiService),
    ];
  }

  Future<AgentCouncilSession> startDiscussion({
    required String novelId,
    required String topic,
    required List<CouncilParticipant> participants,
    required AiClient aiService,
    required AiSessionContext context,
    String? sessionId,
    AgentCouncilConfig config = const AgentCouncilConfig(),
    CouncilMessageCallback? onMessageGenerated,
    CouncilPhaseCallback? onPhaseChanged,
    CouncilTitleCallback? onTitleGenerated,
    CouncilAiServiceResolver? aiServiceResolver,
    String Function(String)? t,
    CouncilTextDeltaCallback? onTextDelta,
    CouncilThinkingDeltaCallback? onThinkingDelta,
    CouncilToolCallCallback? onToolCall,
    TraceReporterService? traceReporter,
    UsageService? usageService,
  }) async {
    _traceReporter = traceReporter;
    _usageService = usageService;
    _usageNovelId = novelId;
    _clearCachedTranscripts();
    _pendingUserMessages.clear();
    _cancelled = false;
    final now = DateTime.now();
    var session = AgentCouncilSession(
      id: sessionId ?? buildRandomId('council'),
      novelId: novelId,
      topic: topic,
      participants: participants,
      phase: CouncilPhase.discussing,
      createdAt: now,
      updatedAt: now,
    );

    final titleFuture = _generateSessionTitle(
      sessionId: session.id,
      aiService: aiService,
      topic: topic,
      participants: participants,
    );
    final discussionFinished = Completer<void>();
    if (onTitleGenerated != null) {
      unawaited(
        _forwardGeneratedTitle(
          titleFuture,
          discussionFinished.future,
          onTitleGenerated,
        ),
      );
    }
    try {
      onPhaseChanged?.call(session);
      session = await _runRoundsViaOrchestrator(
        session: session,
        topic: topic,
        participants: participants,
        context: context,
        aiService: aiService,
        maxRounds: config.maxRounds,
        startRound: 1,
        onMessageGenerated: onMessageGenerated,
        aiServiceResolver: aiServiceResolver,
        t: t,
        onTextDelta: onTextDelta,
        onThinkingDelta: onThinkingDelta,
        onToolCall: onToolCall,
      );
    } finally {
      discussionFinished.complete();
    }

    // 失败路径由 onTitleGenerated 异步交付标题，不阻塞错误返回。
    // 取消后同样要取标题：请求早在讨论开始前就发出了，此处只是收已完成的结果
    // （最长受 _titleTimeout 约束），不会拖慢停止响应。跳过的话被取消的会话
    // 会永久停留在兜底标题上，没有任何补偿路径。
    final title = await titleFuture;
    if (title.isNotEmpty) {
      session = session.copyWith(title: title);
    }

    if (!_cancelled) {
      // 讨论完成是独立于自动总结的稳定检查点。先发布并持久化讨论结果，
      // 可选总结失败时只影响总结，不把已经完成的讨论降级为运行失败。
      session = session.copyWith(
        phase: CouncilPhase.completed,
        clearFailure: true,
        updatedAt: DateTime.now(),
      );
      onPhaseChanged?.call(session);

      if (config.autoSummarize) {
        session = session.copyWith(phase: CouncilPhase.summarizing);
        onPhaseChanged?.call(session);
        try {
          final summary = await generateSummary(
            session: session,
            aiService: aiService,
            t: t,
            traceReporter: traceReporter,
            usageService: usageService,
          );
          session = session.copyWith(
            summary: summary,
            phase: CouncilPhase.completed,
            clearFailure: true,
            updatedAt: DateTime.now(),
          );
        } on AgentCouncilRunException catch (error) {
          session = session.copyWith(
            phase: CouncilPhase.completed,
            failure: error.failure,
            updatedAt: DateTime.now(),
          );
        }
        onPhaseChanged?.call(session);
      }
    }

    return session;
  }

  Future<AgentCouncilSession> runRound({
    required AgentCouncilSession session,
    required AiClient aiService,
    required AiSessionContext context,
    AgentCouncilConfig config = const AgentCouncilConfig(),
    CouncilMessageCallback? onMessageGenerated,
    CouncilPhaseCallback? onPhaseChanged,
    CouncilAiServiceResolver? aiServiceResolver,
    String Function(String)? t,
    CouncilTextDeltaCallback? onTextDelta,
    CouncilThinkingDeltaCallback? onThinkingDelta,
    CouncilToolCallCallback? onToolCall,
    TraceReporterService? traceReporter,
    UsageService? usageService,
    String? speakerId,
  }) async {
    _traceReporter = traceReporter;
    _usageService = usageService;
    _usageNovelId = session.novelId;
    _cancelled = false;
    // 上次运行没来得及并入的插话已由 provider 落定在 session 里，不能再追加一次。
    _pendingUserMessages.clear();
    var current = session.copyWith(
      phase: CouncilPhase.discussing,
      clearFailure: true,
    );
    onPhaseChanged?.call(current);

    final soloSpeaker = speakerId == null
        ? null
        : current.participants.where((p) => p.id == speakerId).firstOrNull;
    // 点名单人发言算作最后一轮的追加，不开新轮。
    final nextRound = soloSpeaker == null
        ? current.nextDiscussionRoundNumber
        : max(current.currentRoundNumber, 1);
    current = await _runRoundsViaOrchestrator(
      session: current,
      topic: current.topic,
      participants: soloSpeaker == null ? current.participants : [soloSpeaker],
      context: context,
      aiService: aiService,
      maxRounds: 1,
      startRound: nextRound,
      onMessageGenerated: onMessageGenerated,
      aiServiceResolver: aiServiceResolver,
      t: t,
      onTextDelta: onTextDelta,
      onThinkingDelta: onThinkingDelta,
      onToolCall: onToolCall,
    );

    current = current.copyWith(
      phase: CouncilPhase.completed,
      updatedAt: DateTime.now(),
    );
    onPhaseChanged?.call(current);

    return current;
  }

  Future<AgentCouncilSession> _runRoundsViaOrchestrator({
    required AgentCouncilSession session,
    required String topic,
    required List<CouncilParticipant> participants,
    required AiClient aiService,
    required int maxRounds,
    required int startRound,
    required AiSessionContext context,
    CouncilMessageCallback? onMessageGenerated,
    CouncilAiServiceResolver? aiServiceResolver,
    String Function(String)? t,
    CouncilTextDeltaCallback? onTextDelta,
    CouncilThinkingDeltaCallback? onThinkingDelta,
    CouncilToolCallCallback? onToolCall,
  }) async {
    if (_agentSessionId != session.id) {
      _clearCachedTranscripts();
      _agentSessionId = session.id;
    }
    _takeTranscriptCacheSlot();
    final orchestrator = AgentOrchestrator();
    _activeOrchestrator = orchestrator;

    var accumulatedSession = session;
    final translate = t ?? _identity;
    // 本次运行内建出来的 Agent，跑完后从这里回收上下文供下一轮沿用。
    final runAgents = <String, Agent>{};
    // 对话里已带着前文的成员：本轮任务只需给他上次发言之后的新内容。
    final remembers = <String>{};
    final sharedMcp = mcpService;

    Future<Agent> buildAgent(CouncilParticipant p) async {
      final svc =
          (aiServiceResolver != null &&
              p.modelOptionId != null &&
              p.modelOptionId!.isNotEmpty)
          ? (await aiServiceResolver(p.modelOptionId)) ?? aiService
          : aiService;
      final tm = svc.toolManager!;
      if (tm.workId != context.workId ||
          tm.contentKind != context.contentKind) {
        throw StateError(
          'Council participant work context does not match tool scope.',
        );
      }
      final mode = ModePromptUseCase(contentKind: context.contentKind);
      final basePrompt = p.resolvePrompt(translate);
      final enrichedPrompt = mode.councilSystem(
        basePrompt: basePrompt,
        context: context,
      );
      // 每个成员一条子会话：请求带 x-session-id=成员子会话、
      // x-session-parent-id=本次议事。派生不出来就退回该成员的共享 client。
      final subClient = await svc.providerClientForSubSession(
        buildTraceSubSessionId(
          parentSessionId: accumulatedSession.id,
          participantId: p.id,
        ),
      );

      final agent = Agent.custom(
        id: p.id,
        systemPrompt: enrichedPrompt,
        client: subClient ?? svc.providerClient,
        providerId: svc.providerId,
        config: svc.agentConfig,
        toolManager: PluginAgentToolDispatcher(
          agentId: p.id,
          scope: (workId: accumulatedSession.novelId, mode: 'council'),
          sessionId: accumulatedSession.id,
          host: pluginHost,
          inner: sharedMcp == null
              ? tm
              : McpAgentToolDispatcher(
                  inner: tm,
                  runTools: tm,
                  service: sharedMcp,
                  sourceSessionId: session.id,
                  allowedBuiltins: () => _councilToolNames(svc) ?? const [],
                  client: subClient ?? svc.providerClient,
                  isEnabled: () => true,
                  mcpOnlyRun: true,
                ),
        ),
        allowedTools: _councilToolNames(svc),
        // 沿用上一轮的上下文（含已读到的工具结果）；首轮为空。
        initialMessages: _transcriptsByParticipantId[p.id],
        hooks: _agentHooks(sessionId: accumulatedSession.id, aiService: svc),
      );
      runAgents[p.id] = agent;
      if (_transcriptsByParticipantId[p.id]?.isNotEmpty ?? false) {
        remembers.add(p.id);
      }
      return agent;
    }

    void append(CouncilMessage message) {
      accumulatedSession = _appendMessage(accumulatedSession, message);
      onMessageGenerated?.call(accumulatedSession, message);
    }

    void drainUserMessages() {
      while (_pendingUserMessages.isNotEmpty) {
        append(_pendingUserMessages.removeAt(0));
      }
    }

    try {
      await orchestrator.runRounds<CouncilParticipant, CouncilMessage>(
        participants: participants,
        buildAgent: buildAgent,
        toolExecutionContext: (p, _) => ToolExecutionContext(
          sessionId: buildTraceSubSessionId(
            parentSessionId: session.id,
            participantId: p.id,
          ),
          sourceSessionId: session.id,
        ),
        maxRounds: maxRounds,
        startRound: startRound,
        stopOnAgentError: true,
        pickNext: (remaining, previous) {
          // 插话在挑人之前并入，作者点名的成员才能被选中。
          drainUserMessages();
          return _pickNextSpeaker(remaining, accumulatedSession, previous);
        },
        buildRoundTask: (p, round) {
          drainUserMessages();
          return _buildRoundTaskPrompt(
            participant: p,
            round: round,
            session: accumulatedSession,
            t: translate,
            onlySinceOwnLast: remembers.contains(p.id),
          );
        },
        parseOutput: (p, raw, round) {
          final parsed = parseCouncilOutput(raw);
          final addressee = parsed.addressee;
          return CouncilMessage(
            id: buildRandomId('msg'),
            participantId: p.id,
            participantName: p.resolveName(translate),
            content: parsed.content,
            timestamp: DateTime.now(),
            round: round,
            addresseeId: addressee == null
                ? null
                : _participantNamed(
                    session.participants,
                    addressee,
                    translate,
                    except: p.id,
                  )?.id,
          );
        },
        onRoundBegin: (p, round) {
          onTextDelta?.call(p.id, round, '');
        },
        onTextDelta: (p, round, text) {
          onTextDelta?.call(p.id, round, text);
        },
        onThinkingDelta: (p, round, thinking) {
          onThinkingDelta?.call(p.id, round, thinking);
        },
        onToolCall: (p, round, record) {
          onToolCall?.call(p.id, round, record);
        },
        onAgentOutput: (round, p, message) {
          remembers.add(p.id);
          append(message);
        },
      );
      // 只在整轮正常跑完时留存上下文。取消或失败时 Agent 的对话可能停在半个
      // 工具调用上，带着它继续会把残缺状态传染给下一轮。
      for (final entry in runAgents.entries) {
        _transcriptsByParticipantId[entry.key] = entry.value.conversation;
      }
    } on AgentOrchestratorCancelledException {
      return accumulatedSession;
    } on AgentOrchestratorFailure catch (error, stackTrace) {
      Error.throwWithStackTrace(
        AgentCouncilRunException(error.failure, cause: error),
        stackTrace,
      );
    } finally {
      if (identical(_activeOrchestrator, orchestrator)) {
        _activeOrchestrator = null;
      }
    }

    final completedRounds = accumulatedSession.rounds.map((r) {
      return r.isComplete ? r : r.copyWith(isComplete: true);
    }).toList();

    return accumulatedSession.copyWith(
      rounds: completedRounds,
      updatedAt: DateTime.now(),
    );
  }

  /// 上一位点名的成员优先接话；最近一条是作者插话且提到了某位成员时，
  /// 由该成员接话。都没有时按原顺序。
  CouncilParticipant _pickNextSpeaker(
    List<CouncilParticipant> remaining,
    AgentCouncilSession session,
    CouncilMessage? previous,
  ) {
    final last = session.rounds.lastOrNull?.messages.lastOrNull;
    if (last != null && last.isUser) {
      final mentioned = remaining
          .where((p) => last.content.contains(p.name))
          .firstOrNull;
      if (mentioned != null) return mentioned;
    }
    final target = previous?.addresseeId;
    return remaining.where((p) => p.id == target).firstOrNull ??
        remaining.first;
  }

  CouncilParticipant? _participantNamed(
    List<CouncilParticipant> participants,
    String name,
    String Function(String) t, {
    required String except,
  }) {
    return participants
        .where(
          (p) => p.id != except && (p.name == name || p.resolveName(t) == name),
        )
        .firstOrNull;
  }

  static AgentCouncilSession _appendMessage(
    AgentCouncilSession session,
    CouncilMessage message,
  ) {
    final rounds = List<CouncilRound>.from(session.rounds);
    final last = rounds.lastOrNull;
    if (last != null && last.roundNumber == message.round) {
      rounds[rounds.length - 1] = last.copyWith(
        messages: [...last.messages, message],
      );
    } else {
      rounds.add(CouncilRound(roundNumber: message.round, messages: [message]));
    }
    return session.copyWith(rounds: rounds, updatedAt: DateTime.now());
  }

  /// [onlySinceOwnLast] 为 true 时成员的对话里已有前文，只附上他上次发言之后的新内容，
  /// 避免每轮把全部历史重复塞进上下文。
  String _buildRoundTaskPrompt({
    required CouncilParticipant participant,
    required int round,
    required AgentCouncilSession session,
    required String Function(String) t,
    bool onlySinceOwnLast = false,
  }) {
    final messages = [for (final r in session.rounds) ...r.messages];
    final lastOwn = messages.lastIndexWhere(
      (m) => m.participantId == participant.id,
    );
    final delta = onlySinceOwnLast && lastOwn >= 0;
    final visible = delta ? messages.sublist(lastOwn + 1) : messages;
    final prior = StringBuffer();
    int? roundShown;
    for (final msg in visible) {
      if (msg.round != roundShown) {
        roundShown = msg.round;
        prior.writeln('### 第 ${msg.round} 轮');
      }
      final speaker = msg.isUser ? '作者' : msg.participantName;
      prior.writeln('$speaker：${msg.content}');
      prior.writeln();
    }
    final priorText = prior.toString().trim();
    final others = [
      for (final p in session.participants)
        if (p.id != participant.id) p.resolveName(t),
    ];

    const mode = ModePromptUseCase();
    return mode.councilRound(
      topic: session.topic,
      participantName: participant.resolveName(t),
      participantDescription: participant.resolveDescription(t),
      round: round,
      otherMembers: others.join('、'),
      priorRounds: delta || priorText.isEmpty ? null : priorText,
      newMessages: delta ? priorText : null,
    );
  }

  /// 作者在讨论进行中的插话，下一位成员发言前并入讨论。
  final List<CouncilMessage> _pendingUserMessages = [];

  void queueUserMessage(CouncilMessage message) =>
      _pendingUserMessages.add(message);

  /// 讨论历史被改写（重说、删除）后，各成员记忆里的旧内容已不成立，
  /// 下一轮回到把完整历史放进任务的方式。
  void forgetTranscripts() => _clearCachedTranscripts();

  Future<CouncilSummary> generateSummary({
    required AgentCouncilSession session,
    required AiClient aiService,
    String Function(String)? t,
    TraceReporterService? traceReporter,
    UsageService? usageService,
  }) async {
    _traceReporter = traceReporter;
    _usageService = usageService;
    _usageNovelId = session.novelId;
    try {
      final discussionHistory = StringBuffer();
      for (final round in session.rounds) {
        discussionHistory.writeln('### 第 ${round.roundNumber} 轮');
        for (final msg in round.messages) {
          final speaker = msg.isUser ? '作者' : msg.participantName;
          discussionHistory.writeln('$speaker：${msg.content}');
          discussionHistory.writeln();
        }
      }

      const mode = ModePromptUseCase();
      final userPrompt = mode.councilSummary(
        topic: session.topic,
        discussionHistory: discussionHistory.toString().trim(),
      );

      final tm = aiService.toolManager!;

      final summarizer = Agent.custom(
        id: 'summarizer',
        systemPrompt: mode.councilSummarizerSystem(),
        client: aiService.providerClient,
        providerId: aiService.providerId,
        config: aiService.agentConfig,
        toolManager: PluginAgentToolDispatcher(
          agentId: 'summarizer',
          scope: (workId: session.novelId, mode: 'council'),
          inner: tm,
          host: pluginHost,
          sessionId: session.id,
        ),
        hooks: _agentHooks(sessionId: session.id, aiService: aiService),
      );

      final response = await summarizer.processText(userPrompt);

      final sections = parseCouncilSummary(response);

      return CouncilSummary(
        content: response.trim(),
        timestamp: DateTime.now(),
        coveredThroughRound: session.currentRoundNumber,
        coveredThroughMessageId: session.lastMessageId,
        keyPoints: sections.keyPoints,
        actionItems: sections.actionItems,
        openQuestions: sections.openQuestions,
      );
    } on AgentProcessException catch (error, stackTrace) {
      _log.error(
        'Summary generation error: $error',
        error: error,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(
        AgentCouncilRunException(error.failure, cause: error),
        stackTrace,
      );
    } catch (error, stackTrace) {
      _log.error(
        'Summary generation error: $error',
        error: error,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(
        AgentCouncilRunException(
          AiRunFailure.requestFailed(providerId: aiService.providerId),
          cause: error,
        ),
        stackTrace,
      );
    }
  }

  Future<String> _generateSessionTitle({
    required String sessionId,
    required AiClient aiService,
    required String topic,
    required List<CouncilParticipant> participants,
  }) async {
    final run = titleClientRunner;
    if (run == null) {
      return _generateSessionTitleWithClient(
        aiService: aiService,
        sessionId: sessionId,
        topic: topic,
        participants: participants,
      );
    }
    try {
      return await run(
        (client) => _generateSessionTitleWithClient(
          aiService: client,
          sessionId: sessionId,
          topic: topic,
          participants: participants,
        ),
      );
    } catch (error, stackTrace) {
      _log.warning(
        'Title client failed; session keeps its fallback title. error=$error stack=$stackTrace',
      );
      return '';
    }
  }

  Future<String> _generateSessionTitleWithClient({
    required String sessionId,
    required AiClient aiService,
    required String topic,
    required List<CouncilParticipant> participants,
  }) async {
    final participantNames = participants.map((p) => p.name).join('、');
    const titlePrompt = TitlePromptUseCase();
    try {
      final title = await aiService.chatCompletionDetached(
        [
          AiMessage.system(
            id: 'sys_council_title',
            content: titlePrompt.councilTitle(),
          ),
          AiMessage.user(
            id: 'user_council_title',
            content: '话题：$topic\n参与角色：$participantNames',
          ),
        ],
        timeout: _titleTimeout,
        hooks: _usageHooks(sessionId: sessionId, aiService: aiService),
      );
      return _normalizeTitle(title);
    } catch (error, stackTrace) {
      _log.warning(
        'Council title generation failed; fallback title will be used. '
        'topicLength=${topic.length} participants=${participants.length} '
        'error=$error stack=$stackTrace',
      );
      return '';
    }
  }

  Future<void> _forwardGeneratedTitle(
    Future<String> titleFuture,
    Future<void> discussionFinished,
    CouncilTitleCallback onTitleGenerated,
  ) async {
    try {
      final title = await titleFuture;
      await discussionFinished;
      if (title.isNotEmpty) {
        onTitleGenerated(title);
      }
    } catch (error, stackTrace) {
      _log.warning(
        'Council title callback failed. error=$error stack=$stackTrace',
      );
    }
  }

  String _normalizeTitle(String raw) {
    return raw
        .trim()
        .split('\n')
        .first
        .replaceAll('，', '')
        .replaceAll('。', '')
        .replaceAll('！', '')
        .replaceAll('？', '')
        .replaceAll('、', '')
        .replaceAll('；', '')
        .replaceAll('：', '')
        .replaceAll('"', '')
        .replaceAll("'", '')
        .replaceAll('`', '')
        .trim();
  }

  void cancel() {
    _cancelled = true;
    _activeOrchestrator?.cancel();
    _clearCachedTranscripts();
  }

  /// 一次运行正常结束后的收尾：停掉可能残留的在途请求，但**保留**各参与者的
  /// 对话上下文。追加一轮时把它作为新建 Agent 的 initialMessages 传进去，
  /// 上一轮读到的作品概览、设定还在，不必重新调工具取。
  /// 显式取消仍走 [cancel]，那里会连上下文一起清掉。
  void finishRun() {
    _activeOrchestrator?.cancel();
    // 本次运行期间槽位被别的议事接管了（council 允许离页后继续跑）：自己结束时
    // 归还上下文，否则这份上下文再也没有释放时机。
    if (!identical(_transcriptCacheOwner, this)) {
      _transcriptsByParticipantId.clear();
      _agentSessionId = null;
    }
  }

  /// 接管全局上下文槽位，释放上一场已结束议事的上下文。仍在运行的议事不动，
  /// 由它自己的 [finishRun] 归还。
  void _takeTranscriptCacheSlot() {
    final previous = _transcriptCacheOwner;
    if (identical(previous, this)) {
      return;
    }
    if (previous != null && previous._activeOrchestrator == null) {
      previous._clearCachedTranscripts();
    }
    _transcriptCacheOwner = this;
  }

  void _clearCachedTranscripts() {
    _transcriptsByParticipantId.clear();
    _agentSessionId = null;
    if (identical(_transcriptCacheOwner, this)) {
      _transcriptCacheOwner = null;
    }
  }
}

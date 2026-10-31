// 职责: 小剧场模式编排 — 调度多个小说角色在场景中互动表演，生成台词与舞台指示，支持流式输出。
// 关联文件:
//   lib/shared/models/theater_models.dart
//   lib/shared/models/agent_run_state.dart
//   lib/shared/agent/agent.dart
//   lib/shared/agent/agent_orchestrator.dart
//   lib/shared/services/ai/chat.dart
//   lib/shared/providers/theater_providers.dart
import 'dart:async';
import '../plugins/agent_dispatcher.dart';
import '../plugins/host.dart';
import 'dart:math';

import 'package:collection/collection.dart';

import '../../models/content_kind.dart';
import '../../logger/app_logger.dart';

import '../../models/ai_chat_models.dart';
import '../../models/ai_run_failure.dart';
import '../../models/ai_session_mode.dart';
import '../../models/theater_models.dart';
import '../../utils/random_id.dart';
import '../../agent/agent.dart';
import '../../agent/agent_hook.dart';
import '../../agent/agent_orchestrator.dart';
import '../../agent/client/trace_headers_http_client.dart'
    show buildTraceSubSessionId;
import '../../agent/hooks/trace_hook.dart';
import 'chat.dart';
import 'mode_output_parser.dart';
import 'usage_service.dart';
import 'usage_hook.dart';
import 'prompts/use_cases/mode_prompt_use_case.dart';
import 'prompts/use_cases/title_prompt_use_case.dart';
import 'trace_reporter_service.dart';

typedef TheaterLineCallback =
    void Function(TheaterSession session, TheaterLine line);

typedef TheaterPhaseCallback = void Function(TheaterSession session);

typedef TheaterTitleCallback = void Function(String title);

typedef TheaterTextDeltaCallback =
    void Function(String characterId, int round, String text);

typedef TheaterThinkingDeltaCallback =
    void Function(String characterId, int round, String thinking);

typedef TheaterToolCallCallback =
    void Function(String characterId, int round, AiToolCallBlock block);

/// 小剧场当前运行已失败。
class TheaterRunException implements Exception {
  const TheaterRunException(this.failure, {this.cause});

  final AiRunFailure failure;
  final Object? cause;

  @override
  String toString() => 'TheaterRunException: $failure';
}

final _log = AppLogger.forModule('Theater');

/// 标题生成的硬上限：超时后放弃，由 provider 兜底默认标题，
/// 避免 provider 无响应时把已经跑完的表演永久卡在收尾阶段。
const _titleTimeout = Duration(seconds: 20);

class TheaterOrchestrator {
  late PluginHostService pluginHost;

  /// 由运行资源提供独立标题客户端；不捕获 UI，也不借用正文的租约。
  Future<String> Function(Future<String> Function(AiClient))? titleClientRunner;

  /// 小剧场:角色代入表演。
  static String theaterPrompt(
    TheaterParticipant character,
    List<TheaterParticipant> allParticipants, {
    AiSessionContext? context,
    String? systemPrompt,
  }) {
    final otherParticipants = StringBuffer();
    for (final p in allParticipants) {
      if (p.characterId != character.characterId) {
        otherParticipants.writeln('- ${p.name}（${p.role}）：${p.biography}');
      }
    }
    final mode = ModePromptUseCase(
      contentKind: context?.contentKind ?? contentKindNovel,
    );
    return mode.theaterSystem(
      characterName: character.name,
      characterId: character.characterId,
      characterRole: character.role,
      characterSummary: character.biography.isNotEmpty
          ? character.biography
          : null,
      characterDescription: character.description.isNotEmpty
          ? character.description
          : null,
      otherParticipants: otherParticipants.toString().trim(),
      systemPrompt: systemPrompt,
    );
  }

  bool _cancelled = false;
  AgentOrchestrator? _activeOrchestrator;
  String? _agentSessionId;
  TraceReporterService? _traceReporter;
  UsageService? _usageService;
  String? _usageNovelId;
  final Map<String, Agent> _agentsByCharacterId = {};

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
      sessionMode: AiSessionMode.theater.value,
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
        source: UsageSources.theater,
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

  List<String>? _theaterToolNames(AiClient aiService) {
    return aiService.toolManager!
        .allToolNames()
        .where(AiSessionMode.theater.canUseTool)
        .toList();
  }

  Future<TheaterSession> startPerformance({
    required String novelId,
    required String sceneDescription,
    required List<TheaterParticipant> participants,
    required AiClient aiService,
    AiSessionContext? context,
    String? sessionId,
    TheaterConfig config = const TheaterConfig(),
    String? systemPrompt,
    TheaterLineCallback? onLineGenerated,
    TheaterPhaseCallback? onPhaseChanged,
    TheaterTitleCallback? onTitleGenerated,
    TheaterTextDeltaCallback? onTextDelta,
    TheaterThinkingDeltaCallback? onThinkingDelta,
    TheaterToolCallCallback? onToolCall,
    TraceReporterService? traceReporter,
    UsageService? usageService,
  }) async {
    _traceReporter = traceReporter;
    _usageService = usageService;
    _usageNovelId = novelId;
    _clearCachedAgents();
    _cancelled = false;
    final now = DateTime.now();
    var session = TheaterSession(
      id: sessionId ?? buildRandomId('theater'),
      novelId: novelId,
      sceneDescription: sceneDescription,
      participants: participants,
      phase: TheaterPhase.performing,
      createdAt: now,
      updatedAt: now,
    );

    final titleFuture = _generateSessionTitle(
      sessionId: session.id,
      aiService: aiService,
      sceneDescription: sceneDescription,
      participants: participants,
    );
    final performanceFinished = Completer<void>();
    if (onTitleGenerated != null) {
      unawaited(
        _forwardGeneratedTitle(
          titleFuture,
          performanceFinished.future,
          onTitleGenerated,
        ),
      );
    }
    try {
      onPhaseChanged?.call(session);
      session = await _runRoundsViaOrchestrator(
        session: session,
        participants: participants,
        aiService: aiService,
        systemPrompt: systemPrompt,
        maxRounds: config.maxRounds,
        startRound: 1,
        onLineGenerated: onLineGenerated,
        onTextDelta: onTextDelta,
        onThinkingDelta: onThinkingDelta,
        onToolCall: onToolCall,
      );
    } finally {
      performanceFinished.complete();
    }

    // 失败路径由 onTitleGenerated 异步交付标题，不阻塞错误返回。
    // 取消后同样要取标题：请求早在表演开始前就发出了，此处只是收已完成的结果
    // （最长受 _titleTimeout 约束），不会拖慢停止响应。跳过的话被取消的会话
    // 会永久停留在兜底标题上，没有任何补偿路径。
    final title = await titleFuture;
    if (title.isNotEmpty) {
      session = session.copyWith(title: title);
    }

    if (!_cancelled) {
      session = session.copyWith(
        phase: TheaterPhase.completed,
        updatedAt: DateTime.now(),
      );
      onPhaseChanged?.call(session);
    }

    return session;
  }

  Future<TheaterSession> continuePerformance({
    required TheaterSession session,
    required AiClient aiService,
    AiSessionContext? context,
    TheaterConfig config = const TheaterConfig(),
    String? systemPrompt,
    TheaterLineCallback? onLineGenerated,
    TheaterPhaseCallback? onPhaseChanged,
    TheaterTextDeltaCallback? onTextDelta,
    TheaterThinkingDeltaCallback? onThinkingDelta,
    TheaterToolCallCallback? onToolCall,
    TraceReporterService? traceReporter,
    UsageService? usageService,
    String? speakerId,
  }) async {
    _traceReporter = traceReporter;
    _usageService = usageService;
    _usageNovelId = session.novelId;
    _cancelled = false;
    // 上次运行没来得及并入的指令已由 provider 落定在 session 里，不能再追加一次。
    _pendingDirections.clear();
    final soloSpeaker = speakerId == null
        ? null
        : session.participants.firstWhereOrNull(
            (p) => p.characterId == speakerId,
          );
    var current = session.copyWith(
      phase: TheaterPhase.performing,
      clearFailure: true,
    );
    onPhaseChanged?.call(current);

    // 点名单人发言算作当前轮的追加，不开新轮。
    final round = soloSpeaker == null
        ? current.currentTurn + 1
        : max(current.currentTurn, 1);
    current = await _runRoundsViaOrchestrator(
      session: current,
      participants: current.participants,
      speakers: soloSpeaker == null ? null : [soloSpeaker],
      aiService: aiService,
      systemPrompt: systemPrompt,
      maxRounds: 1,
      startRound: round,
      onLineGenerated: onLineGenerated,
      onTextDelta: onTextDelta,
      onThinkingDelta: onThinkingDelta,
      onToolCall: onToolCall,
    );

    current = current.copyWith(
      phase: TheaterPhase.completed,
      updatedAt: DateTime.now(),
    );
    onPhaseChanged?.call(current);

    return current;
  }

  Future<TheaterSession> _runRoundsViaOrchestrator({
    required TheaterSession session,
    required List<TheaterParticipant> participants,
    List<TheaterParticipant>? speakers,
    required AiClient aiService,
    String? systemPrompt,
    required int maxRounds,
    required int startRound,
    TheaterLineCallback? onLineGenerated,
    TheaterTextDeltaCallback? onTextDelta,
    TheaterThinkingDeltaCallback? onThinkingDelta,
    TheaterToolCallCallback? onToolCall,
  }) async {
    if (_agentSessionId != session.id) {
      _clearCachedAgents();
      _agentSessionId = session.id;
    }

    final orchestrator = AgentOrchestrator();
    _activeOrchestrator = orchestrator;

    var accumulatedSession = session;

    Future<Agent> buildAgent(TheaterParticipant p) async {
      final tm = aiService.toolManager!;
      final otherParticipants = StringBuffer();
      for (final op in participants) {
        if (op.characterId != p.characterId) {
          otherParticipants.writeln('- ${op.name}（${op.role}）：${op.biography}');
        }
      }
      final mode = ModePromptUseCase(contentKind: tm.contentKind);
      final resolvedPrompt = mode.theaterSystem(
        characterName: p.name,
        characterId: p.characterId,
        characterRole: p.role,
        characterSummary: p.biography.isNotEmpty ? p.biography : null,
        characterDescription: p.description.isNotEmpty ? p.description : null,
        otherParticipants: otherParticipants.toString().trim(),
        systemPrompt: systemPrompt,
      );
      final existing = _agentsByCharacterId[p.characterId];
      if (existing != null) {
        existing.updateSystemPrompt(resolvedPrompt);
        existing.updateAllowedTools(_theaterToolNames(aiService));
        return existing;
      }

      // 每个角色一条子会话：请求带 x-session-id=角色子会话、
      // x-session-parent-id=本场表演。派生不出来就退回共享 client。
      final subClient = await aiService.providerClientForSubSession(
        buildTraceSubSessionId(
          parentSessionId: accumulatedSession.id,
          participantId: p.characterId,
        ),
      );

      final agent = Agent.custom(
        id: p.characterId,
        systemPrompt: resolvedPrompt,
        client: subClient ?? aiService.providerClient,
        providerId: aiService.providerId,
        config: aiService.agentConfig,
        toolManager: PluginAgentToolDispatcher(
          agentId: p.characterId,
          scope: (workId: accumulatedSession.novelId, mode: 'theater'),
          inner: tm,
          host: pluginHost,
          sessionId: accumulatedSession.id,
        ),
        allowedTools: _theaterToolNames(aiService),
        hooks: _agentHooks(
          sessionId: accumulatedSession.id,
          aiService: aiService,
        ),
      );
      _agentsByCharacterId[p.characterId] = agent;
      return agent;
    }

    try {
      try {
        await orchestrator.runRounds<TheaterParticipant, TheaterLine>(
          participants: speakers ?? participants,
          buildAgent: buildAgent,
          maxRounds: maxRounds,
          pickNext: (remaining, previous) => _pickNextSpeaker(
            remaining,
            previous ?? accumulatedSession.lastPerformance,
          ),
          buildRoundTask: (p, round) {
            final actualRound = startRound + round - 1;
            accumulatedSession = _drainDirections(
              accumulatedSession,
              onLineGenerated: onLineGenerated,
            );
            return _buildLinePrompt(
              participant: p,
              session: accumulatedSession,
              round: actualRound,
            );
          },
          parseOutput: (p, raw, round) {
            final actualRound = startRound + round - 1;
            return _parseLineForParticipant(p, raw, actualRound, participants);
          },
          onRoundBegin: (p, round) {
            final actualRound = startRound + round - 1;
            onTextDelta?.call(p.characterId, actualRound, '');
          },
          onTextDelta: (p, round, text) {
            final actualRound = startRound + round - 1;
            onTextDelta?.call(p.characterId, actualRound, text);
          },
          onThinkingDelta: (p, round, thinking) {
            final actualRound = startRound + round - 1;
            onThinkingDelta?.call(p.characterId, actualRound, thinking);
          },
          onToolCall: (p, round, record) {
            final actualRound = startRound + round - 1;
            onToolCall?.call(p.characterId, actualRound, record);
          },
          onAgentOutput: (round, p, line) {
            accumulatedSession = accumulatedSession.copyWith(
              lines: [...accumulatedSession.lines, line],
              updatedAt: DateTime.now(),
            );
            onLineGenerated?.call(accumulatedSession, line);
          },
          stopOnAgentError: true,
        );
      } on AgentOrchestratorCancelledException {
        return accumulatedSession;
      } on AgentOrchestratorFailure catch (error, stackTrace) {
        Error.throwWithStackTrace(
          TheaterRunException(error.failure, cause: error),
          stackTrace,
        );
      }

      return accumulatedSession;
    } finally {
      _activeOrchestrator = null;
    }
  }

  /// 上一句点名的对象优先接话；没有点名或对象本轮已说过时按原顺序。
  TheaterParticipant _pickNextSpeaker(
    List<TheaterParticipant> remaining,
    TheaterLine? previous,
  ) {
    final target = previous?.addresseeId;
    return remaining.firstWhereOrNull((p) => p.characterId == target) ??
        remaining.first;
  }

  /// 作者在表演进行中插入的导演指令，下一位发言前并入台词流。
  final List<TheaterLine> _pendingDirections = [];

  void queueDirection(TheaterLine line) => _pendingDirections.add(line);

  TheaterSession _drainDirections(
    TheaterSession session, {
    TheaterLineCallback? onLineGenerated,
  }) {
    var current = session;
    while (_pendingDirections.isNotEmpty) {
      final line = _pendingDirections.removeAt(0);
      current = current.copyWith(
        lines: [...current.lines, line],
        updatedAt: DateTime.now(),
      );
      onLineGenerated?.call(current, line);
    }
    return current;
  }

  TheaterLine _parseLineForParticipant(
    TheaterParticipant participant,
    String raw,
    int round,
    List<TheaterParticipant> participants,
  ) {
    if (raw.trim().isEmpty) {
      throw StateError('Theater agent completed without text output');
    }

    try {
      final parsed = parseTheaterOutput(raw);
      final addressee = parsed.addressee;
      return TheaterLine(
        id: buildRandomId('line'),
        characterId: participant.characterId,
        characterName: participant.name,
        dialogue: parsed.dialogue,
        stageDirection: parsed.stageDirection,
        addresseeId: addressee == null
            ? null
            : participants
                  .firstWhereOrNull(
                    (p) =>
                        p.name == addressee &&
                        p.characterId != participant.characterId,
                  )
                  ?.characterId,
        turn: round,
        timestamp: DateTime.now(),
      );
    } catch (e) {
      _log.error('Participant ${participant.name} error: $e');
      rethrow;
    }
  }

  String _buildLinePrompt({
    required TheaterParticipant participant,
    required TheaterSession session,
    required int round,
  }) {
    final priorLines = StringBuffer();
    for (final line in session.lines) {
      if (line.isDirection) {
        priorLines.writeln('【导演】${line.dialogue}');
        priorLines.writeln();
        continue;
      }
      if (line.stageDirection != null && line.stageDirection!.isNotEmpty) {
        priorLines.writeln('（${line.stageDirection}）');
      }
      priorLines.writeln('${line.characterName}：「${line.dialogue}」');
      priorLines.writeln();
    }
    final priorLinesText = priorLines.toString().trim();

    const mode = ModePromptUseCase();
    return mode.theaterLine(
      sceneDescription: session.sceneDescription,
      participantName: participant.name,
      participantCharacterId: participant.characterId,
      round: round,
      priorLines: priorLinesText.isNotEmpty ? priorLinesText : null,
    );
  }

  Future<String> _generateSessionTitle({
    required String sessionId,
    required AiClient aiService,
    required String sceneDescription,
    required List<TheaterParticipant> participants,
  }) async {
    final run = titleClientRunner;
    if (run == null) {
      return _generateSessionTitleWithClient(
        aiService: aiService,
        sessionId: sessionId,
        sceneDescription: sceneDescription,
        participants: participants,
      );
    }
    try {
      return await run(
        (client) => _generateSessionTitleWithClient(
          aiService: client,
          sessionId: sessionId,
          sceneDescription: sceneDescription,
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
    required String sceneDescription,
    required List<TheaterParticipant> participants,
  }) async {
    final participantNames = participants.map((p) => p.name).join('、');
    const titlePrompt = TitlePromptUseCase();
    try {
      final title = await aiService.chatCompletionDetached(
        [
          AiMessage.system(
            id: 'sys_theater_title',
            content: titlePrompt.theaterTitle(),
          ),
          AiMessage.user(
            id: 'user_theater_title',
            content: '场景：$sceneDescription\n角色：$participantNames',
          ),
        ],
        timeout: _titleTimeout,
        hooks: _usageHooks(sessionId: sessionId, aiService: aiService),
      );
      return _normalizeTitle(title);
    } catch (error, stackTrace) {
      _log.warning(
        'Theater title generation failed; fallback title will be used. '
        'sceneLength=${sceneDescription.length} '
        'participants=${participants.length} error=$error stack=$stackTrace',
      );
      return '';
    }
  }

  Future<void> _forwardGeneratedTitle(
    Future<String> titleFuture,
    Future<void> performanceFinished,
    TheaterTitleCallback onTitleGenerated,
  ) async {
    try {
      final title = await titleFuture;
      await performanceFinished;
      if (title.isNotEmpty) {
        onTitleGenerated(title);
      }
    } catch (error, stackTrace) {
      _log.warning(
        'Theater title callback failed. error=$error stack=$stackTrace',
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
    _clearCachedAgents();
  }

  void _clearCachedAgents({bool cancel = true}) {
    if (cancel) {
      for (final agent in _agentsByCharacterId.values) {
        if (agent.isProcessing) {
          agent.cancel();
        }
      }
    }
    _agentsByCharacterId.clear();
    _agentSessionId = null;
  }
}

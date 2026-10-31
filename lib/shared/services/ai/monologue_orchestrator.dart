// 职责: Monologue 模式编排 — 调度 AI 代入小说角色，生成内心独白与行动描述，支持流式输出。
// 关联文件:
//   lib/shared/models/monologue_models.dart
//   lib/shared/models/agent_run_state.dart
//   lib/shared/agent/agent.dart
//   lib/shared/services/ai/chat.dart
//   lib/shared/providers/monologue_providers.dart
import 'dart:async';
import '../plugins/agent_dispatcher.dart';
import '../plugins/host.dart';

import '../../models/content_kind.dart';
import '../../logger/app_logger.dart';

import '../../agent/agent_run_state.dart';
import '../../models/ai_chat_models.dart';
import '../../models/ai_run_failure.dart';
import '../../models/ai_session_mode.dart';
import '../../models/monologue_models.dart';
import '../../utils/random_id.dart';
import '../../agent/agent.dart';
import '../../agent/agent_event.dart';
import '../../agent/agent_hook.dart';
import '../../agent/message.dart';
import '../../agent/hooks/trace_hook.dart';
import 'chat.dart';
import 'mode_output_parser.dart';
import 'usage_service.dart';
import 'usage_hook.dart';
import 'prompts/use_cases/mode_prompt_use_case.dart';
import 'prompts/use_cases/title_prompt_use_case.dart';
import 'trace_reporter_service.dart';

typedef MonologueEntryCallback =
    void Function(MonologueSession session, MonologueEntry monologue);

typedef MonologuePhaseCallback = void Function(MonologueSession session);

typedef MonologueTitleCallback = void Function(String title);

typedef MonologueAiServiceResolver =
    Future<AiClient?> Function(String? modelOptionId);

typedef MonologueTextDeltaCallback =
    void Function(String characterId, String text);

typedef MonologueThinkingDeltaCallback =
    void Function(String characterId, String thinking);

typedef MonologueToolCallCallback =
    void Function(String characterId, AiToolCallBlock block);

/// 角色独白当前运行已失败。
class MonologueRunException implements Exception {
  const MonologueRunException(this.failure, {this.cause});

  final AiRunFailure failure;
  final Object? cause;

  @override
  String toString() => 'MonologueRunException: $failure';
}

final _log = AppLogger.forModule('Monologue');

/// 标题生成的硬上限：超时后放弃，由 provider 兜底默认标题，
/// 避免 provider 无响应时把已经跑完的独白永久卡在收尾阶段。
const _titleTimeout = Duration(seconds: 20);

class MonologueOrchestrator {
  late PluginHostService pluginHost;

  /// 由运行资源提供独立标题客户端；不捕获 UI，也不借用正文的租约。
  Future<String> Function(Future<String> Function(AiClient))? titleClientRunner;

  static String monologuePrompt({
    required MonologueSession session,
    AiSessionContext? context,
    String? systemPrompt,
  }) {
    final mode = ModePromptUseCase(
      contentKind: context?.contentKind ?? contentKindNovel,
    );
    final char = session.character;
    return mode.monologueSystem(
      characterName: char.name,
      characterRole: char.role,
      characterSummary: char.biography.isNotEmpty ? char.biography : null,
      characterDescription: char.description.isNotEmpty
          ? char.description
          : null,
      systemPrompt: systemPrompt,
    );
  }

  bool _cancelled = false;
  Agent? _activeAgent;
  String? _activeAgentKey;
  TraceReporterService? _traceReporter;
  UsageService? _usageService;
  String? _usageNovelId;

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
      sessionMode: AiSessionMode.monologue.value,
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
        source: UsageSources.monologue,
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

  List<String>? _monologueToolNames(AiClient aiService) {
    return aiService.toolManager!
        .allToolNames()
        .where(AiSessionMode.monologue.canUseTool)
        .toList();
  }

  Future<MonologueSession> startSession({
    required String novelId,
    required String topic,
    required MonologueParticipant character,
    required AiClient aiService,
    AiSessionContext? context,
    String? sessionId,
    MonologueConfig config = const MonologueConfig(),
    String? systemPrompt,
    MonologueEntryCallback? onMonologueGenerated,
    MonologuePhaseCallback? onPhaseChanged,
    MonologueTitleCallback? onTitleGenerated,
    MonologueAiServiceResolver? aiServiceResolver,
    MonologueTextDeltaCallback? onTextDelta,
    MonologueThinkingDeltaCallback? onThinkingDelta,
    MonologueToolCallCallback? onToolCall,
    TraceReporterService? traceReporter,
    UsageService? usageService,
  }) async {
    _traceReporter = traceReporter;
    _usageService = usageService;
    _usageNovelId = novelId;
    _cancelled = false;
    final now = DateTime.now();
    var session = MonologueSession(
      id: sessionId ?? buildRandomId('mono_session'),
      novelId: novelId,
      topic: topic,
      character: character,
      phase: MonologuePhase.generating,
      createdAt: now,
      updatedAt: now,
    );

    final titleFuture = _generateSessionTitle(
      sessionId: session.id,
      aiService: aiService,
      topic: topic,
      character: character,
    );
    final monologueFinished = Completer<void>();
    if (onTitleGenerated != null) {
      unawaited(
        _forwardGeneratedTitle(
          titleFuture,
          monologueFinished.future,
          onTitleGenerated,
        ),
      );
    }
    try {
      onPhaseChanged?.call(session);
      session = await _generateMonologue(
        session: session,
        aiService: aiService,
        systemPrompt: systemPrompt,
        userMessage: topic,
        onMonologueGenerated: onMonologueGenerated,
        onTextDelta: onTextDelta,
        onThinkingDelta: onThinkingDelta,
        onToolCall: onToolCall,
      );
    } finally {
      monologueFinished.complete();
    }

    // 失败路径由 onTitleGenerated 异步交付标题，不阻塞错误返回。
    // 取消后同样要取标题：请求早在独白开始前就发出了，此处只是收已完成的结果
    // （最长受 _titleTimeout 约束），不会拖慢停止响应。跳过的话被取消的会话
    // 会永久停留在兜底标题上，没有任何补偿路径。
    final title = await titleFuture;
    if (title.isNotEmpty) {
      session = session.copyWith(title: title);
    }

    if (!_cancelled) {
      session = session.copyWith(
        phase: MonologuePhase.completed,
        updatedAt: DateTime.now(),
      );
      onPhaseChanged?.call(session);
    }

    return session;
  }

  Future<MonologueSession> continueMonologue({
    required MonologueSession session,
    required AiClient aiService,
    AiSessionContext? context,
    String? systemPrompt,
    MonologueConfig config = const MonologueConfig(),
    MonologueEntryCallback? onMonologueGenerated,
    MonologuePhaseCallback? onPhaseChanged,
    MonologueAiServiceResolver? aiServiceResolver,
    MonologueTextDeltaCallback? onTextDelta,
    MonologueThinkingDeltaCallback? onThinkingDelta,
    MonologueToolCallCallback? onToolCall,
    TraceReporterService? traceReporter,
    UsageService? usageService,
  }) async {
    _traceReporter = traceReporter;
    _usageService = usageService;
    _usageNovelId = session.novelId;
    _cancelled = false;
    var current = session.copyWith(
      phase: MonologuePhase.generating,
      clearFailure: true,
    );
    onPhaseChanged?.call(current);

    current = await _generateMonologue(
      session: current,
      aiService: aiService,
      systemPrompt: systemPrompt,
      userMessage: current.topic,
      onMonologueGenerated: onMonologueGenerated,
      onTextDelta: onTextDelta,
      onThinkingDelta: onThinkingDelta,
      onToolCall: onToolCall,
    );

    current = current.copyWith(
      phase: MonologuePhase.completed,
      updatedAt: DateTime.now(),
    );
    onPhaseChanged?.call(current);

    return current;
  }

  Future<MonologueSession> _generateMonologue({
    required MonologueSession session,
    required AiClient aiService,
    String? systemPrompt,
    required String userMessage,
    MonologueEntryCallback? onMonologueGenerated,
    MonologueTextDeltaCallback? onTextDelta,
    MonologueThinkingDeltaCallback? onThinkingDelta,
    MonologueToolCallCallback? onToolCall,
  }) async {
    if (_cancelled) return session;

    final agent = _getOrCreateAgent(
      session: session,
      aiService: aiService,
      systemPrompt: systemPrompt,
    );

    try {
      final stream = agent.process(userMessage);
      var fullResponse = '';
      AiRunFailure? runFailure;
      var agentCancelled = false;

      await for (final ev in stream) {
        if (_cancelled) break;
        switch (ev) {
          case AgentTextDelta(:final text):
            fullResponse += text;
            onTextDelta?.call(session.character.characterId, text);
          case AgentThinkingDelta(:final text):
            onThinkingDelta?.call(session.character.characterId, text);
          case AgentToolCallStart(
            :final callId,
            :final toolName,
            :final arguments,
          ):
            onToolCall?.call(
              session.character.characterId,
              agentToolCallStartBlock(
                callId: callId,
                toolName: toolName,
                arguments: arguments,
              ),
            );
          case AgentToolCallResult(
            :final callId,
            :final toolName,
            :final output,
            :final metadata,
            :final errorMessage,
          ):
            onToolCall?.call(
              session.character.characterId,
              agentToolCallResultBlock(
                callId: callId,
                toolName: toolName,
                output: output,
                metadata: metadata,
                errorMessage: errorMessage,
              ),
            );
          case AgentDone(:final finalText):
            fullResponse = finalText;
          case AgentError(:final failure):
            runFailure = failure;
            break;
          case AgentCancelled():
            agentCancelled = true;
            break;
          case AgentRoundRetry():
            // 重试同一 round：重置本轮文本缓冲，避免跨 attempt 累积。
            fullResponse = '';
          default:
            break;
        }
      }

      if (_cancelled || agentCancelled) {
        _resetActiveAgent(agent);
        return session;
      }
      if (runFailure != null) {
        _resetActiveAgent(agent);
        throw MonologueRunException(runFailure);
      }

      final response = fullResponse;
      if (response.trim().isEmpty) {
        throw StateError('Monologue agent completed without text output');
      }
      final parsed = parseMonologueOutput(response);

      final monologue = MonologueEntry(
        id: buildRandomId('mono'),
        characterId: session.character.characterId,
        characterName: session.character.name,
        innerThoughts: parsed.innerThoughts,
        plannedActions: parsed.plannedActions,
        timestamp: DateTime.now(),
      );

      final updatedSession = session.copyWith(
        monologues: [...session.monologues, monologue],
        updatedAt: DateTime.now(),
      );

      onMonologueGenerated?.call(updatedSession, monologue);
      return updatedSession;
    } on MonologueRunException {
      rethrow;
    } catch (e, stackTrace) {
      _resetActiveAgent(agent);
      _log.error(
        'Monologue generation error: $e',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Agent _getOrCreateAgent({
    required MonologueSession session,
    required AiClient aiService,
    String? systemPrompt,
  }) {
    final tm = aiService.toolManager!;
    final agentKey = session.id;
    final mode = ModePromptUseCase(contentKind: tm.contentKind);
    final char = session.character;
    final resolvedPrompt = mode.monologueSystem(
      characterName: char.name,
      characterRole: char.role,
      characterSummary: char.biography.isNotEmpty ? char.biography : null,
      characterDescription: char.description.isNotEmpty
          ? char.description
          : null,
      systemPrompt: systemPrompt,
    );
    final existing = _activeAgent;
    if (existing != null && _activeAgentKey == agentKey) {
      existing.updateSystemPrompt(resolvedPrompt);
      existing.updateAllowedTools(_monologueToolNames(aiService));
      return existing;
    }

    existing?.cancel();
    final agent = Agent.custom(
      id: session.character.characterId,
      systemPrompt: resolvedPrompt,
      client: aiService.providerClient,
      providerId: aiService.providerId,
      config: aiService.agentConfig,
      toolManager: PluginAgentToolDispatcher(
        agentId: session.character.characterId,
        scope: (workId: session.novelId, mode: 'monologue'),
        inner: tm,
        host: pluginHost,
        sessionId: session.id,
      ),
      allowedTools: _monologueToolNames(aiService),
      initialMessages: _buildInitialMessages(session),
      hooks: _agentHooks(sessionId: session.id, aiService: aiService),
    );
    _activeAgent = agent;
    _activeAgentKey = agentKey;
    return agent;
  }

  List<AgentMessage> _buildInitialMessages(MonologueSession session) {
    if (session.monologues.isEmpty) return const [];

    final messages = <AgentMessage>[
      AgentMessage.user(id: '${session.id}_topic', content: session.topic),
    ];
    for (final monologue in session.monologues) {
      final content = StringBuffer();
      content.writeln('【内心活动】${monologue.innerThoughts}');
      if (monologue.plannedActions.isNotEmpty) {
        content.writeln('【接下来的行动】${monologue.plannedActions}');
      }
      messages.add(
        AgentMessage.assistant(
          id: monologue.id,
          content: content.toString().trim(),
        ),
      );
    }
    return messages;
  }

  Future<String> _generateSessionTitle({
    required String sessionId,
    required AiClient aiService,
    required String topic,
    required MonologueParticipant character,
  }) async {
    final run = titleClientRunner;
    if (run == null) {
      return _generateSessionTitleWithClient(
        aiService: aiService,
        sessionId: sessionId,
        topic: topic,
        character: character,
      );
    }
    try {
      return await run(
        (client) => _generateSessionTitleWithClient(
          aiService: client,
          sessionId: sessionId,
          topic: topic,
          character: character,
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
    required MonologueParticipant character,
  }) async {
    const titlePrompt = TitlePromptUseCase();
    try {
      final title = await aiService.chatCompletionDetached(
        [
          AiMessage.system(
            id: 'sys_monologue_title',
            content: titlePrompt.monologueTitle(),
          ),
          AiMessage.user(
            id: 'user_monologue_title',
            content: '角色：${character.name}\n话题：$topic',
          ),
        ],
        timeout: _titleTimeout,
        hooks: _usageHooks(sessionId: sessionId, aiService: aiService),
      );
      return _normalizeTitle(title);
    } catch (error, stackTrace) {
      _log.warning(
        'Monologue title generation failed; fallback title will be used. '
        'character=${character.name} topicLength=${topic.length} '
        'error=$error stack=$stackTrace',
      );
      return '';
    }
  }

  Future<void> _forwardGeneratedTitle(
    Future<String> titleFuture,
    Future<void> monologueFinished,
    MonologueTitleCallback onTitleGenerated,
  ) async {
    try {
      final title = await titleFuture;
      await monologueFinished;
      if (title.isNotEmpty) {
        onTitleGenerated(title);
      }
    } catch (error, stackTrace) {
      _log.warning(
        'Monologue title callback failed. error=$error stack=$stackTrace',
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
    final agent = _activeAgent;
    if (agent != null && agent.isProcessing) {
      agent.cancel();
    }
    _resetActiveAgent(agent);
  }

  void _resetActiveAgent(Agent? agent) {
    if (agent != null && identical(_activeAgent, agent)) {
      _activeAgent = null;
      _activeAgentKey = null;
    }
  }
}

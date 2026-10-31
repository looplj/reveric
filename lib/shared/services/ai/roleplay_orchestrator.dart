// 职责: Roleplay 模式编排 — 调度 AI 扮演小说角色，进行一对一对话交互，支持流式输出。
// 关联文件:
//   lib/shared/models/roleplay_models.dart
//   lib/shared/models/agent_run_state.dart
//   lib/shared/agent/agent.dart
//   lib/shared/services/ai/chat.dart
//   lib/shared/providers/roleplay_providers.dart
import 'dart:async';
import '../plugins/agent_dispatcher.dart';
import '../plugins/host.dart';

import '../../models/content_kind.dart';
import '../../logger/app_logger.dart';

import '../../agent/agent_run_state.dart';
import '../../models/ai_chat_models.dart';
import '../../models/ai_run_failure.dart';
import '../../models/ai_session_mode.dart';
import '../../models/roleplay_models.dart';
import '../../utils/random_id.dart';
import '../../agent/agent.dart';
import '../../agent/agent_event.dart';
import '../../agent/agent_hook.dart';
import '../../agent/message.dart';
import '../../agent/hooks/trace_hook.dart';
import 'chat.dart';
import 'usage_service.dart';
import 'usage_hook.dart';
import 'prompts/use_cases/mode_prompt_use_case.dart';
import 'prompts/use_cases/title_prompt_use_case.dart';
import 'trace_reporter_service.dart';

typedef RoleplayMessageCallback =
    void Function(RoleplaySession session, RoleplayMessage message);

typedef RoleplayPhaseCallback = void Function(RoleplaySession session);

typedef RoleplayTitleCallback = void Function(String title);

typedef RoleplayAiServiceResolver =
    Future<AiClient?> Function(String? modelOptionId);

typedef RoleplayTextDeltaCallback =
    void Function(String characterId, String text);

typedef RoleplayThinkingDeltaCallback =
    void Function(String characterId, String thinking);

typedef RoleplayToolCallCallback =
    void Function(String characterId, AiToolCallBlock block);

/// 角色扮演当前运行已失败。
class RoleplayRunException implements Exception {
  const RoleplayRunException(this.failure, {this.cause});

  final AiRunFailure failure;
  final Object? cause;

  @override
  String toString() => 'RoleplayRunException: $failure';
}

final _log = AppLogger.forModule('Roleplay');

/// 标题生成的硬上限：超时后放弃，由 provider 兜底默认标题，
/// 避免 provider 无响应时把已经生成完的回复永久卡在收尾阶段。
const _titleTimeout = Duration(seconds: 20);

class RoleplayOrchestrator {
  late PluginHostService pluginHost;

  /// 由运行资源提供独立标题客户端；不捕获 UI，也不借用正文的租约。
  Future<String> Function(Future<String> Function(AiClient))? titleClientRunner;

  /// 角色扮演:一对一对话。
  static String roleplayPrompt({
    required RoleplaySession session,
    AiSessionContext? context,
    String? systemPrompt,
  }) {
    final mode = ModePromptUseCase(
      contentKind: context?.contentKind ?? contentKindNovel,
    );
    final char = session.character;
    return mode.roleplaySystem(
      characterName: _displayName(char),
      characterRole: _roleLabel(char.role),
      characterSummary: char.biography.isNotEmpty ? char.biography : null,
      characterDescription: char.description.isNotEmpty
          ? char.description
          : null,
      systemPrompt: systemPrompt,
    );
  }

  static String _displayName(RoleplayParticipant character) {
    final name = character.name.trim();
    if (name.isNotEmpty) {
      return name;
    }
    return '指定角色';
  }

  static String _roleLabel(String role) {
    return switch (role.trim()) {
      'protagonist' => '主角',
      'antagonist' => '反派',
      'supporting' => '配角',
      'minor' => '龙套',
      final value => value,
    };
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
      sessionMode: AiSessionMode.roleplay.value,
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
        source: UsageSources.roleplay,
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

  Never _missingToolManager() => throw StateError(
    'AiClient.toolManager is null. Call AiClient.initialize() before roleplay generation.',
  );

  List<String>? _roleplayToolNames(AiClient aiService) {
    final toolManager = aiService.toolManager;
    if (toolManager == null) {
      _missingToolManager();
    }
    return toolManager
        .allToolNames()
        .where(AiSessionMode.roleplay.canUseTool)
        .toList();
  }

  Future<RoleplaySession> sendMessage({
    required String novelId,
    required String userMessage,
    required RoleplayParticipant character,
    required RoleplaySession session,
    required AiClient aiService,
    AiSessionContext? context,
    RoleplayConfig config = const RoleplayConfig(),
    String? systemPrompt,
    RoleplayMessageCallback? onMessageGenerated,
    RoleplayPhaseCallback? onPhaseChanged,
    RoleplayTitleCallback? onTitleGenerated,
    RoleplayAiServiceResolver? aiServiceResolver,
    RoleplayTextDeltaCallback? onTextDelta,
    RoleplayThinkingDeltaCallback? onThinkingDelta,
    RoleplayToolCallCallback? onToolCall,
    String? userMessageId,
    TraceReporterService? traceReporter,
    UsageService? usageService,
  }) async {
    _traceReporter = traceReporter;
    _usageService = usageService;
    _usageNovelId = novelId;
    _cancelled = false;

    final userMsg = RoleplayMessage(
      id: userMessageId ?? buildRandomId('rmsg'),
      speakerId: 'user',
      speakerName: 'user',
      content: userMessage,
      timestamp: DateTime.now(),
    );

    var current = session.copyWith(
      messages: [...session.messages, userMsg],
      phase: RoleplayPhase.generating,
      clearFailure: true,
      updatedAt: DateTime.now(),
    );

    final titleFuture = session.title.isEmpty && session.messages.isEmpty
        ? _generateSessionTitle(
            sessionId: session.id,
            aiService: aiService,
            characterName: _displayName(character),
            userMessage: userMessage,
          )
        : null;
    final responseFinished = Completer<void>();
    if (titleFuture != null && onTitleGenerated != null) {
      unawaited(
        _forwardGeneratedTitle(
          titleFuture,
          responseFinished.future,
          onTitleGenerated,
        ),
      );
    }
    try {
      onPhaseChanged?.call(current);
      current = await _generateResponse(
        session: current,
        aiService: aiService,
        systemPrompt: systemPrompt,
        userMessageId: userMsg.id,
        userMessage: userMessage,
        onMessageGenerated: onMessageGenerated,
        onTextDelta: onTextDelta,
        onThinkingDelta: onThinkingDelta,
        onToolCall: onToolCall,
      );
    } finally {
      responseFinished.complete();
    }

    // 失败路径由 onTitleGenerated 异步交付标题，不阻塞错误返回。
    // 取消后同样要取标题：请求早在回复生成前就发出了，此处只是收已完成的结果
    // （最长受 _titleTimeout 约束），不会拖慢停止响应。跳过的话被取消的会话
    // 会永久停留在兜底标题上，没有任何补偿路径。
    final title = await titleFuture;
    if (title != null && title.isNotEmpty) {
      current = current.copyWith(title: title);
    }

    if (!_cancelled) {
      current = current.copyWith(
        phase: RoleplayPhase.completed,
        updatedAt: DateTime.now(),
      );
      onPhaseChanged?.call(current);
    }

    return current;
  }

  Future<RoleplaySession> _generateResponse({
    required RoleplaySession session,
    required AiClient aiService,
    String? systemPrompt,
    required String userMessageId,
    required String userMessage,
    RoleplayMessageCallback? onMessageGenerated,
    RoleplayTextDeltaCallback? onTextDelta,
    RoleplayThinkingDeltaCallback? onThinkingDelta,
    RoleplayToolCallCallback? onToolCall,
  }) async {
    if (_cancelled) return session;

    final agent = _getOrCreateAgent(
      session: session,
      aiService: aiService,
      systemPrompt: systemPrompt,
      currentUserMessageId: userMessageId,
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
        throw RoleplayRunException(runFailure);
      }

      final response = fullResponse;
      if (response.trim().isEmpty) {
        throw StateError('Roleplay agent completed without text output');
      }

      final message = RoleplayMessage(
        id: buildRandomId('rmsg'),
        speakerId: session.character.characterId,
        speakerName: session.character.name,
        content: response,
        timestamp: DateTime.now(),
      );

      final updatedSession = session.copyWith(
        messages: [...session.messages, message],
        updatedAt: DateTime.now(),
      );

      onMessageGenerated?.call(updatedSession, message);
      return updatedSession;
    } on RoleplayRunException {
      rethrow;
    } catch (e, stackTrace) {
      _resetActiveAgent(agent);
      _log.error(
        'Response generation error: $e',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Agent _getOrCreateAgent({
    required RoleplaySession session,
    required AiClient aiService,
    String? systemPrompt,
    required String currentUserMessageId,
  }) {
    final tm = aiService.toolManager;
    if (tm == null) {
      _missingToolManager();
    }
    final agentKey = session.id;
    final mode = ModePromptUseCase(contentKind: tm.contentKind);
    final char = session.character;
    final resolvedPrompt = mode.roleplaySystem(
      characterName: _displayName(char),
      characterRole: _roleLabel(char.role),
      characterSummary: char.biography.isNotEmpty ? char.biography : null,
      characterDescription: char.description.isNotEmpty
          ? char.description
          : null,
      systemPrompt: systemPrompt,
    );
    final existing = _activeAgent;
    if (existing != null && _activeAgentKey == agentKey) {
      existing.updateSystemPrompt(resolvedPrompt);
      existing.updateAllowedTools(_roleplayToolNames(aiService));
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
        scope: (workId: session.novelId, mode: 'roleplay'),
        inner: tm,
        host: pluginHost,
        sessionId: session.id,
      ),
      allowedTools: _roleplayToolNames(aiService),
      initialMessages: _buildInitialMessages(
        session,
        currentUserMessageId: currentUserMessageId,
      ),
      hooks: _agentHooks(sessionId: session.id, aiService: aiService),
    );
    _activeAgent = agent;
    _activeAgentKey = agentKey;
    return agent;
  }

  List<AgentMessage> _buildInitialMessages(
    RoleplaySession session, {
    required String currentUserMessageId,
  }) {
    return session.messages
        .where((message) => message.id != currentUserMessageId)
        .map(
          (message) => message.speakerId == 'user'
              ? AgentMessage.user(id: message.id, content: message.content)
              : AgentMessage.assistant(
                  id: message.id,
                  content: message.content,
                ),
        )
        .toList(growable: false);
  }

  Future<String> _generateSessionTitle({
    required String sessionId,
    required AiClient aiService,
    required String characterName,
    required String userMessage,
  }) async {
    final run = titleClientRunner;
    if (run == null) {
      return _generateSessionTitleWithClient(
        aiService: aiService,
        sessionId: sessionId,
        characterName: characterName,
        userMessage: userMessage,
      );
    }
    try {
      return await run(
        (client) => _generateSessionTitleWithClient(
          aiService: client,
          sessionId: sessionId,
          characterName: characterName,
          userMessage: userMessage,
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
    required String characterName,
    required String userMessage,
  }) async {
    const titlePrompt = TitlePromptUseCase();
    try {
      final title = await aiService.chatCompletionDetached(
        [
          AiMessage.system(
            id: 'sys_roleplay_title',
            content: titlePrompt.roleplayTitle(),
          ),
          AiMessage.user(
            id: 'user_roleplay_title',
            content: '角色：$characterName\n对话内容：$userMessage',
          ),
        ],
        timeout: _titleTimeout,
        hooks: _usageHooks(sessionId: sessionId, aiService: aiService),
      );
      return _normalizeTitle(title);
    } catch (error, stackTrace) {
      _log.warning(
        'Roleplay title generation failed; fallback title will be used. '
        'character=$characterName messageLength=${userMessage.length} '
        'error=$error stack=$stackTrace',
      );
      return '';
    }
  }

  Future<void> _forwardGeneratedTitle(
    Future<String> titleFuture,
    Future<void> responseFinished,
    RoleplayTitleCallback onTitleGenerated,
  ) async {
    try {
      final title = await titleFuture;
      await responseFinished;
      if (title.isNotEmpty) {
        onTitleGenerated(title);
      }
    } catch (error, stackTrace) {
      _log.warning(
        'Roleplay title callback failed. error=$error stack=$stackTrace',
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

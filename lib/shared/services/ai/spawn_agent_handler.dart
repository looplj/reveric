// 职责: 创建或续跑独立子运行，保存子会话上下文并报告结束时的上下文用量。
// 关联文件:
//   lib/shared/services/ai/spawn_agent_run.dart
//   lib/shared/services/ai/chat_turn_runner.dart
//   lib/shared/services/ai/session_persistence.dart
//   lib/shared/services/ai/agent_message_mapping.dart
//   lib/shared/services/ai/context_summarizer.dart
//   lib/shared/services/ai/tools_subagent.dart
//   lib/shared/services/ai/prompts/prompt_fragments.dart
//   lib/shared/agent/agent_context_manager.dart
//   lib/shared/models/models_catalog.dart
//   lib/shared/models/ai_chat_session_id.dart
//   lib/shared/models/agent_skill.dart

import 'dart:async';
import '../plugins/agent_dispatcher.dart';
import '../plugins/host.dart';
import '../mcp/settings_service.dart';
import 'mcp/agent_dispatcher.dart';
import 'mcp/run_command_handler.dart';
import 'dart:math';

import '../../agent/agent.dart';
import '../../agent/agent_config.dart';
import '../../agent/agent_context_manager.dart';
import '../../agent/agent_event.dart';
import '../../agent/agent_hook.dart';
import '../../agent/client.dart';
import '../../agent/hooks/trace_hook.dart';
import '../../agent/message.dart';
import '../../agent/token_estimator.dart';
import '../../database/novel_content_database.dart';
import '../../logger/app_logger.dart';
import '../../models/agent_rule.dart';
import '../../models/agent_skill.dart';
import '../../models/ai_chat_models.dart';
import '../../models/ai_chat_session_id.dart';
import '../../models/ai_run_failure.dart';
import 'trace_reporter_service.dart' show anonymousProviderKind;
import '../../models/ai_provider.dart' show defaultReasoningEffortFor;
import '../../models/ai_session_mode.dart';
import '../../models/models_catalog.dart';
import '../../models/subagent.dart';
import '../../utils/random_id.dart';
import 'agent_message_mapping.dart';
import 'context_summarizer.dart';
import 'codemode/dispatcher.dart';
import 'codemode/orchestrator.dart';
import 'codemode/runtime.dart';
import 'codemode/scheduler.dart';
import 'codemode/tool.dart';
import 'usage_hook.dart';
import 'prompts/prompt_fragments.dart';
import 'prompts/use_cases/agent_prompt_use_case.dart';
import 'session_persistence.dart';
import 'tool_error_normalize.dart';
import 'tools.dart';
import 'builtin_agent_tools.dart';
import 'host_tool_policy.dart';

part 'spawn_agent_run.dart';

final _spawnAgentLog = AppLogger.forModule('SpawnAgent');

/// 子会话持久化完成后立刻通知调用方，用于把 session_id 回填到父级 tool call。
typedef SpawnAgentSessionStartedCallback =
    void Function(String callId, String subSessionId);

/// 子 Agent 运行事件透传给调用方；子会话消息要跑完才落库，运行中只能靠它展示动态。
typedef SpawnAgentEventCallback =
    void Function(String callId, AgentEvent event);

class SpawnAgentHandler {
  const SpawnAgentHandler({
    required this.availableSubAgents,
    required this.workContext,
    this.availableSkills = const [],
    required this.agentConfig,
    required this.defaultProviderId,
    required this.defaultModel,
    required this.parentSessionId,
    required this.persistence,
    required this.novelDatabase,
    required this.resourcesResolver,
    required this.codemodeScheduler,
    this.codemodeRuntimeFactory,
    this.mcpService,
    required this.pluginHost,
    this.onRunFinished,
    this.hooks = const [],
    this.defaultAllowedToolNames = defaultSubAgentToolNames,
    this.onSessionStarted,
    this.onSubAgentEvent,
    required this.contextSupplementForSession,
  });

  final AiSessionContext workContext;
  final List<SubAgent> availableSubAgents;
  final List<AgentSkillSummary> availableSkills;
  final AgentConfig agentConfig;
  final String? defaultProviderId;
  final String? defaultModel;
  final String? parentSessionId;
  final AiSessionPersistenceService? persistence;
  final NovelContentDatabase? novelDatabase;
  final SpawnAgentResourcesResolver resourcesResolver;
  final CodemodeScheduler codemodeScheduler;
  final FjsRuntime Function()? codemodeRuntimeFactory;
  final McpSettingsService? mcpService;
  final PluginHostService pluginHost;
  final void Function(SpawnAgentRun)? onRunFinished;
  final List<AgentHook> hooks;
  final List<String> Function() defaultAllowedToolNames;
  final SpawnAgentSessionStartedCallback? onSessionStarted;
  final SpawnAgentEventCallback? onSubAgentEvent;

  /// 按子会话 id 派生每轮结构化上下文。
  final Future<List<AgentMessage>> Function(String sessionId)
  contextSupplementForSession;

  Future<Map<String, dynamic>> run({
    required Map<String, dynamic> input,
    String? resumeSessionId,
    String? callId,
    ToolExecutionContext? toolExecutionContext,
  }) async {
    final execution = start(
      input: input,
      resumeSessionId: resumeSessionId,
      callId: callId,
      toolExecutionContext: toolExecutionContext,
    );
    // 同步 Spawn 保留父取消传播；独立 start 不借用父取消信号。
    final unlink = toolExecutionContext?.cancellationToken?.onCancel(
      () => execution.cancel(source: 'parent_cancel'),
    );
    try {
      return await execution.result;
    } finally {
      unlink?.call();
    }
  }

  /// [resumeSessionId] 只由内部续跑入口传入，不从工具 input 解析旧会话身份。
  SpawnAgentRun start({
    required Map<String, dynamic> input,
    String? resumeSessionId,
    String? callId,
    ToolExecutionContext? toolExecutionContext,
    void Function(SpawnAgentRun run)? onStatusChanged,
    void Function(SpawnAgentRun run, AgentEvent event)? onEvent,
    Future<void>? Function(SpawnAgentRun run)? waitForStart,
  }) {
    final requestedSessionId = resumeSessionId?.trim() ?? '';
    final frozenInput = Map<String, dynamic>.unmodifiable(input);
    return SpawnAgentRun._(
      runId: buildRandomId('sub_run'),
      subSessionId: requestedSessionId.isEmpty
          ? buildRandomId('sub_session')
          : requestedSessionId,
      parentSessionId: parentSessionId,
      sourceSessionId: toolExecutionContext?.sourceSessionId ?? parentSessionId,
      sourceTurnId: toolExecutionContext?.sourceTurnId,
      callId: callId,
      agentName: (input['agent'] as String? ?? '').trim(),
      name: (input['name'] as String? ?? '').trim(),
      task: _parseTask(input),
      execute: (execution) =>
          _executeRun(execution, frozenInput, requestedSessionId),
      reportInitializationFailure: (run, result, error, stackTrace) =>
          _reportFailure(run, result, error, stackTrace, 'initialization'),
      onFinished: onRunFinished,
      onStatusChanged: onStatusChanged,
      onEvent: onEvent,
      waitForStart: waitForStart,
    );
  }

  Future<Map<String, dynamic>> _executeRun(
    SpawnAgentRun execution,
    Map<String, dynamic> input,
    String requestedSessionId,
  ) async {
    if (input.containsKey('session_id') || input.containsKey('sessionId')) {
      return {
        'ok': false,
        'error_code': ToolErrorCode.invalid_argument.name,
        'error':
            'SpawnAgent creates a new session. Use SendAgentMessage to continue an existing session.',
      };
    }
    final cancellationToken = execution._cancellation.token;
    final callId = execution.callId;
    final agent = execution.agentName;
    final name = execution.name;
    final task = execution.task;
    if (agent.isEmpty || name.isEmpty || task.isEmpty) {
      return {'ok': false, 'error': 'agent, name and task are required'};
    }

    final persistence = this.persistence;
    final novelDatabase = this.novelDatabase;
    final parentSessionId = this.parentSessionId;
    if (persistence == null ||
        novelDatabase == null ||
        parentSessionId == null ||
        parentSessionId.isEmpty ||
        isTemporaryAiChatSessionId(parentSessionId)) {
      return {
        'ok': false,
        'error_code': ToolErrorCode.unavailable.name,
        'error': 'SpawnAgent requires a persisted parent session.',
      };
    }

    final reuse = requestedSessionId.isEmpty
        ? null
        : await _loadReusableSession(sessionId: requestedSessionId);
    if (requestedSessionId.isNotEmpty && reuse == null) {
      return {
        'ok': false,
        'error_code': ToolErrorCode.not_found.name,
        'error':
            'No sub-agent session belongs to this parent with that session_id.',
      };
    }

    // 续跑沿用会话持久化的专家身份，不按名称重新解析。
    final sub = reuse == null
        ? _resolveByName(agent)
        : _resolveEnabledBySlug(reuse.agentSlug);
    if (sub == null) {
      return reuse == null
          ? {
              'ok': false,
              'error':
                  'agent "$agent" not found. Available: ${_enabledNames().join(', ')}',
            }
          : {
              'ok': false,
              'error_code': ToolErrorCode.failed_precondition.name,
              'error': 'The original sub-agent is unavailable or disabled.',
            };
    }
    if (reuse != null) {
      execution._nestedCalls.addAll(reuse.nestedCalls);
    }

    // 先定下子会话 id：SubAgent 的 client 要带着它上报 trace，
    // 且 TodoWrite 在运行中就可能落库，必须提前分配并持久化。
    final subSessionId = execution.subSessionId;
    final modelResolution = await _resolveModel(
      execution,
      sub,
      subSessionId: subSessionId,
    );
    final subConfig = _resolveConfig(sub, modelResolution);
    final disabled =
        builtinSubAgentDisabledToolNames(sub.slug) ??
        builtinDefaultSubAgentDisabledToolNames;
    final configured = defaultAllowedToolNames()
        .where((name) => !disabled.contains(name))
        .toList();
    final allowed = [
      ...configured,
      if (configured.isNotEmpty && !configured.contains(codemodeToolName))
        codemodeToolName,
    ];
    final systemPrompt = await _buildSystemPrompt(
      sub,
      hasTools: allowed.isNotEmpty,
      toolManager: execution._resources!.toolManager,
    );
    final spawnRunId = execution.runId;
    final spawnRunLabel = _usageRunLabel(task);
    try {
      await _startPersistedRun(
        sessionId: subSessionId,
        runId: spawnRunId,
        subAgent: sub,
        name: name,
        providerId: modelResolution.providerId ?? defaultProviderId,
        model: modelResolution.model,
      );
    } catch (error, stackTrace) {
      _spawnAgentLog.error(
        '[DB] table=ai_chat_sessions operation=UPSERT_RUNNING '
        'subSessionId=$subSessionId parentSessionId=$parentSessionId',
        error: error,
        stackTrace: stackTrace,
      );
      final result = <String, dynamic>{
        'ok': false,
        'error_code': ToolErrorCode.unavailable.name,
        'error': 'SpawnAgent could not create its session.',
      };
      await _reportFailure(
        execution,
        result,
        error,
        stackTrace,
        'session_create',
      );
      return result;
    }
    _notifySessionStarted(callId: callId, subSessionId: subSessionId);
    // 初始化已被会话追踪；守卫期间可以收尾，但不能进入新的模型执行。
    while (true) {
      final wait = execution._waitForStart?.call(execution);
      if (wait == null) {
        break;
      }
      await wait;
    }
    if (!_shouldRun(cancellationToken)) {
      await _tryFinalizePersistedRun(
        execution: execution,
        sessionId: subSessionId,
        status: 'cancelled',
        errorCode: 'user_cancelled',
        messages: reuse?.contextSnapshot.messages ?? const [],
        contextSnapshot: reuse?.contextSnapshot,
      );
      return _cancelledResult(subSessionId);
    }
    // 子代理获得同等压缩保护：在实际模型窗口达到 80% 时压缩。
    final subModel = modelResolution.model ?? defaultModel;
    final catalogLimit = subModel != null ? lookupCatalogLimit(subModel) : null;
    final contextTokens = catalogLimit?.context ?? defaultContextTokenLimit;
    final outputFloor = catalogLimit?.output != null
        ? min(16000, catalogLimit!.output!)
        : 16000;
    final compactThreshold = compactThresholdForContextLimit(contextTokens);
    _spawnAgentLog.info(
      '[ctx] scope=spawn model=$subModel context=$contextTokens '
      'compactAt=$compactThreshold',
    );
    final subCtxMgr = SmartAgentContextManager(
      compactThreshold: compactThreshold,
      contextTokens: contextTokens,
      outputFloor: outputFloor,
      contextSupplementProvider: () =>
          contextSupplementForSession(subSessionId),
    );
    if (reuse != null) {
      subCtxMgr.restoreSnapshot(reuse.contextSnapshot);
    }
    final initialCompactions = subCtxMgr.compactionCount;
    final spawnHooks = _hooksForSpawn(
      hooks,
      sessionId: subSessionId,
      runId: spawnRunId,
      runLabel: spawnRunLabel,
      providerId: modelResolution.providerId ?? defaultProviderId,
      model: modelResolution.model ?? defaultModel,
      cancelSource: () => execution._cancellationSource,
    );
    late final Agent subAgent;
    final innerTools = execution._resources!.toolManager;
    bool codemodeAllowed() => allowed.contains(codemodeToolName);
    late final AgentToolDispatcher subTools;
    McpAgentToolDispatcher? mcpTools;
    final codemodeTools = CodemodeToolDispatcher(
      inner: HostToolPolicyDispatcher(
        inner: innerTools,
        // 外层 MCP dispatcher 统一校验 Run mcp/help mcp；普通 Run 仍由
        // mcpOnlyRun 拒绝，避免内层再次误拦已通过校验的 MCP 命令。
        disabled: mcpService != null ? disabled.difference({'Run'}) : disabled,
      ),
      isAllowed: codemodeAllowed,
      runCodemode: (input, callId, context) => CodemodeOrchestrator().execute(
        input: input,
        context: context,
        parentToolCallId: callId,
        tools: subTools,
        catalog: mcpTools?.catalog,
        runTool: (call, context) =>
            subAgent.runToolCall(call, context: context),
        onRecord: (record) =>
            (execution._nestedCalls[callId] ??= {})[record.callId] = record,
        scheduler: codemodeScheduler,
        isAllowed: codemodeAllowed,
        allowedToolNames: () => allowed,
        runtimeFactory: codemodeRuntimeFactory,
      ),
    );
    final sharedMcp = mcpService;
    if (sharedMcp != null) {
      mcpTools = McpAgentToolDispatcher(
        inner: codemodeTools,
        runTools: innerTools as McpRunCommandHost,
        service: sharedMcp,
        sourceSessionId: subSessionId,
        allowedBuiltins: () => allowed,
        client: modelResolution.client,
        isEnabled: () => true,
        mcpOnlyRun: disabled.contains('Run'),
      );
    }
    subTools = mcpTools ?? codemodeTools;
    subCtxMgr.summarizer = buildDefaultContextSummarizer(
      agentId: sub.id,
      systemPrompt: systemPrompt,
      allowedTools: allowed,
      client: modelResolution.client,
      providerId: modelResolution.providerId ?? defaultProviderId,
      config: subConfig,
      toolManager: subTools,
      contextSupplement: () async => subCtxMgr.contextSupplementMessages,
      hooks: spawnHooks.whereType<UsageHook>().toList(growable: false),
    );
    subAgent = Agent.custom(
      id: sub.id,
      systemPrompt: systemPrompt,
      allowedTools: allowed,
      client: modelResolution.client,
      providerId: modelResolution.providerId ?? defaultProviderId,
      config: subConfig,
      toolManager: PluginAgentToolDispatcher(
        agentId: sub.id,
        scope: (workId: workContext.workId, mode: 'chat'),
        inner: subTools,
        host: pluginHost,
        sessionId: subSessionId,
      ),
      contextManager: subCtxMgr,
      hooks: spawnHooks,
      emitToolEvents: false,
    );

    try {
      var output = '';
      AiRunFailure? runFailure;
      // Todo 与 current History 使用子会话；source History 与 mutation
      // 使用触发 Spawn 的父会话。
      final subToolContext = ToolExecutionContext(
        operationOwnerSessionId: execution.sourceSessionId,
        approvalHostCallId: execution.callId,
        sessionId: subSessionId,
        sourceSessionId: execution.sourceSessionId,
        sourceTurnId: execution.sourceTurnId,
        cancellationToken: cancellationToken,
      );
      execution._markStarted();
      await for (final event in subAgent.process(
        task,
        toolExecutionContext: subToolContext,
        inbox: execution._inbox,
      )) {
        _notifySubAgentEvent(execution: execution, event: event);
        switch (event) {
          case AgentDone(:final finalText):
            output = finalText;
          case AgentError(:final failure):
            runFailure = failure;
          default:
            break;
        }
      }
      if (!_shouldRun(cancellationToken)) {
        await _tryFinalizePersistedRun(
          execution: execution,
          sessionId: subSessionId,
          status: 'cancelled',
          errorCode: 'user_cancelled',
          messages: List<AgentMessage>.unmodifiable(
            subAgent.contextManager.messages,
          ),
          contextSnapshot: subCtxMgr.snapshot(),
        );
        return _cancelledResult(subSessionId);
      }
      if (runFailure != null) {
        await _tryFinalizePersistedRun(
          execution: execution,
          sessionId: subSessionId,
          status: 'failed',
          errorCode: 'sub_agent_error',
          messages: List<AgentMessage>.unmodifiable(
            subAgent.contextManager.messages,
          ),
          contextSnapshot: subCtxMgr.snapshot(),
        );
        if (!_shouldRun(cancellationToken)) {
          return _cancelledResult(subSessionId);
        }
        return {
          'ok': false,
          'error':
              'Sub-agent "$name" ($agent) failed: ${_failureReason(runFailure)}',
          'error_code': ToolErrorCode.internal.name,
          'failure_kind': runFailure.kind.name,
          'provider_kind': anonymousProviderKind(
            modelResolution.providerId ?? defaultProviderId,
          ),
          if (runFailure.statusCode != null)
            'status_code': runFailure.statusCode,
          'session_id': subSessionId,
        };
      }

      await _tryFinalizePersistedRun(
        execution: execution,
        sessionId: subSessionId,
        status: 'completed',
        messages: List<AgentMessage>.unmodifiable(
          subAgent.contextManager.messages,
        ),
        contextSnapshot: subCtxMgr.snapshot(),
      );

      if (!_shouldRun(cancellationToken)) {
        return _cancelledResult(subSessionId);
      }
      return {
        'ok': true,
        'output': output,
        'session_id': subSessionId,
        if (modelResolution.usedFallback ||
            (modelResolution.model != null &&
                modelResolution.model!.isNotEmpty))
          '_metadata': {
            'sub_agent_model': modelResolution.model ?? defaultModel,
            'sub_agent_provider_id':
                modelResolution.providerId ?? defaultProviderId,
          },
      };
    } catch (error, stackTrace) {
      _spawnAgentLog.error(
        'SpawnAgent failed agentSlug=${sub.slug}',
        error: error,
        stackTrace: stackTrace,
      );
      final cancelled = !_shouldRun(cancellationToken);
      await _tryFinalizePersistedRun(
        execution: execution,
        sessionId: subSessionId,
        status: cancelled ? 'cancelled' : 'failed',
        errorCode: cancelled ? 'user_cancelled' : 'spawn_agent_failed',
        messages: List<AgentMessage>.unmodifiable(
          subAgent.contextManager.messages,
        ),
        contextSnapshot: subCtxMgr.snapshot(),
      );
      if (!_shouldRun(cancellationToken)) {
        return _cancelledResult(subSessionId);
      }
      final result = <String, dynamic>{
        'ok': false,
        'error':
            'Sub-agent "$name" ($agent) could not complete execution due to an internal error. Check the application logs for details.',
        'error_code': ToolErrorCode.internal.name,
        'session_id': subSessionId,
      };
      await _reportFailure(execution, result, error, stackTrace, 'execution');
      return result;
    } finally {
      final tokens = subCtxMgr.currentTokensEstimate(
        systemPromptTokens: estimateTextTokens(systemPrompt),
      );
      execution._contextUsage = {
        'tokens_estimate': tokens,
        'window_tokens': contextTokens,
        'window_source': catalogLimit?.context == null ? 'default' : 'catalog',
        'usage_ratio': tokens / contextTokens,
        'compactions': subCtxMgr.compactionCount - initialCompactions,
      };
    }
  }

  /// 从持久化身份恢复原专家与名字；调用者不能将旧历史交给另一个专家。
  Future<Map<String, dynamic>> prepareResume(
    String sessionId,
    String message,
  ) async {
    final session = await persistence?.getSession(sessionId);
    if (session == null ||
        session.parentId != parentSessionId ||
        session.mode != AiSessionMode.chat.value) {
      throw const SpawnAgentResumeException(
        'not_found',
        'No sub-agent session belongs to this parent with that session_id.',
      );
    }
    final sub = _resolveEnabledBySlug(session.agentSlug);
    if (sub == null) {
      throw const SpawnAgentResumeException(
        'failed_precondition',
        'The original sub-agent is unavailable or disabled.',
      );
    }
    return {'agent': sub.name, 'name': session.title, 'task': message};
  }

  /// 子运行自行上报底层异常，覆盖后台完成及父工具尚未获得启动回执的情况。
  /// 仅将去重标记放入 UI metadata；原始诊断不会进入工具结果和对话历史。
  Future<void> _reportFailure(
    SpawnAgentRun execution,
    Map<String, dynamic> result,
    Object error,
    StackTrace stackTrace,
    String stage,
  ) async {
    final trace = hooks.whereType<TraceHook>().firstOrNull;
    if (trace == null) {
      return;
    }
    final sub = _resolveByName(execution.agentName);
    final hasOwnModel =
        sub?.providerId?.isNotEmpty == true && sub?.model?.isNotEmpty == true;
    final reported = await trace.reportToolException(
      toolName: 'SpawnAgent',
      model:
          execution._resourceModel ?? (hasOwnModel ? sub!.model : defaultModel),
      result: {
        ...result,
        'failure_stage': stage,
        'provider_kind': anonymousProviderKind(
          execution._resourceProviderId ??
              (hasOwnModel ? sub!.providerId : defaultProviderId),
        ),
      },
      error: error,
      stackTrace: stackTrace,
    );
    if (reported) {
      result['_metadata'] = {'tool_error_reported': true};
    }
  }

  String _failureReason(AiRunFailure failure) {
    return switch (failure.kind) {
      AiRunFailureKind.http =>
        'Provider request failed (HTTP ${failure.statusCode}): ${switch (failure.statusCode) {
          400 || 412 || 422 => 'invalid request; check the model and request parameters.',
          401 => 'authentication failed; check the provider credentials or login.',
          402 => 'payment required; check the provider balance or quota.',
          403 => 'access denied; check model permissions.',
          404 => 'resource not found; check the model and endpoint.',
          408 => 'request timed out.',
          429 => 'rate limit reached; wait before retrying.',
          final int code when code >= 500 && code < 600 => 'provider service error; try again later.',
          _ => 'the provider rejected the request.',
        }}',
      AiRunFailureKind.network =>
        'Network connection failed; check connectivity before retrying.',
      AiRunFailureKind.streamInterrupted =>
        'The response stream was interrupted before completion.',
      AiRunFailureKind.contextWindowExhausted =>
        'The model context window was exhausted; reduce the task context or start a new sub-session.',
      AiRunFailureKind.incompleteResponse =>
        'The model returned an incomplete response.',
      AiRunFailureKind.requestFailed =>
        'The model request failed; check the application logs for details.',
    };
  }

  bool _shouldRun(AgentCancellationToken? token) =>
      !(token?.isCancellationRequested ?? false);

  void _notifySessionStarted({
    required String? callId,
    required String subSessionId,
  }) {
    if (callId == null || callId.isEmpty) {
      return;
    }
    try {
      onSessionStarted?.call(callId, subSessionId);
    } catch (error, stackTrace) {
      _spawnAgentLog.warning(
        'SpawnAgent session-start notification failed '
        'callId=$callId subSessionId=$subSessionId error=$error\n$stackTrace',
      );
    }
  }

  void _notifySubAgentEvent({
    required SpawnAgentRun execution,
    required AgentEvent event,
  }) {
    final callId = execution.callId;
    // 运行中详情还不能读落库消息；批次终态携带与持久化相同的子调用快照。
    final displayEvent = switch (event) {
      AgentToolCallResult(callId: final toolCallId)
          when execution._nestedCalls.containsKey(toolCallId) =>
        event.withNestedCalls(
          List.unmodifiable(execution._nestedCalls[toolCallId]!.values),
        ),
      AgentToolSkipped(callId: final toolCallId)
          when execution._nestedCalls.containsKey(toolCallId) =>
        event.withNestedCalls(
          List.unmodifiable(execution._nestedCalls[toolCallId]!.values),
        ),
      _ => event,
    };
    try {
      execution._onEvent?.call(execution, displayEvent);
      if (callId != null && callId.isNotEmpty) {
        onSubAgentEvent?.call(callId, displayEvent);
      }
    } catch (error, stackTrace) {
      _spawnAgentLog.warning(
        'SpawnAgent sub-agent event notification failed '
        'callId=$callId event=${event.runtimeType} error=$error\n$stackTrace',
      );
    }
  }

  Map<String, dynamic> _cancelledResult(String sessionId) => {
    'cancelled': true,
    'error_code': 'user_cancelled',
    'error': 'User cancelled',
    'session_id': sessionId,
  };

  String _parseTask(Map<String, dynamic> input) {
    for (final key in [
      'task',
      'task_description',
      'mission',
      'description',
      'prompt',
    ]) {
      final value = input[key] as String?;
      if (value != null && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return '';
  }

  SubAgent? _resolveByName(String name) {
    final lower = name.toLowerCase();
    for (final agent in availableSubAgents) {
      if (!agent.enabled) {
        continue;
      }
      if (agent.name.toLowerCase() == lower) {
        return agent;
      }
    }
    return null;
  }

  SubAgent? _resolveEnabledBySlug(String? slug) => availableSubAgents
      .where((agent) => agent.enabled && agent.slug == slug)
      .firstOrNull;

  List<String> _enabledNames() => availableSubAgents
      .where((agent) => agent.enabled)
      .map((agent) => agent.name)
      .toList();

  /// 组装 SubAgent 的系统提示词，包含路径规则（有工具时）、用户规则与可用技能摘要。
  Future<String> _buildSystemPrompt(
    SubAgent subAgent, {
    required bool hasTools,
    required AgentToolDispatcher toolManager,
  }) async {
    final workBlock = PromptFragments.workContext(workContext);
    if (toolManager is AiToolManager) {
      final manager = toolManager;
      if (manager.workId != workContext.workId ||
          manager.contentKind != workContext.contentKind) {
        throw const SpawnAgentInitializationException(
          reason: 'work_context_mismatch',
          message: '子代理的工具范围与当前作品不一致。请重新打开当前作品后再试。',
        );
      }
    }
    final sections = <String>[
      const AgentPromptUseCase().renderPromptTemplate(
        subAgent.prompt,
        context: workContext,
      ),
      workBlock,
    ];
    // 有工具时注入 pathSchema：Read/Write 等工具描述会引用「系统 prompt 中的路径规则」。
    // 工具使用准则同理 —— 同一响应内工具调用不能互相依赖这类约束原先写在 Read 的
    // 描述里，SubAgent 靠工具描述读到；准则收归 toolUseGuidelines 后必须一并注入，
    // 否则 SubAgent 就丢了这条。
    if (hasTools) {
      final pathSchema = PromptFragments.pathSchemaBlock(
        kind: workContext.contentKind,
      );
      if (pathSchema.isNotEmpty) {
        sections.add(pathSchema);
      }
      final toolGuidelines = PromptFragments.toolUseGuidelines(
        codemodeAvailable: true,
      );
      if (toolGuidelines.isNotEmpty) {
        sections.add(toolGuidelines);
      }
    }
    final rawRules = await _loadUserRules();
    final rulesSection = PromptFragments.userRulesSection(rawRules);
    if (rulesSection.isNotEmpty) {
      sections.add(rulesSection);
    }
    final skillSection = PromptFragments.availableSkills(availableSkills);
    if (skillSection.isNotEmpty) {
      sections.add(skillSection);
    }
    return sections.where((section) => section.isNotEmpty).join('\n\n');
  }

  Future<String?> _loadUserRules() async {
    final database = novelDatabase;
    if (database == null) {
      return null;
    }
    try {
      final rules = await database.agentRuleDao.getAll();
      return rules.formatForPrompt();
    } catch (error, stackTrace) {
      _spawnAgentLog.error(
        '[DB] table=agent_rules operation=SELECT failed while loading user rules',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  AgentConfig _resolveConfig(
    SubAgent subAgent,
    _SpawnAgentModelResolution modelResolution,
  ) {
    final model = modelResolution.model;
    // 无 profile 模型时沿用 parent agentConfig（含会话级 reasoning effort）。
    if (model == null || model.isEmpty) {
      return agentConfig;
    }
    final catalogEfforts = normalizeReasoningEfforts(
      lookupCatalogReasoningEfforts(model),
    );
    final selectedEffort =
        subAgent.reasoningEffort ?? defaultReasoningEffortFor(catalogEfforts);
    return AgentConfig(
      temperature: agentConfig.temperature,
      // SubAgent 可能跑在与父会话不同的模型上，输出预算必须按自己的模型解析。
      maxTokens: resolveAgentMaxTokens(model),
      reasoningEffort: resolveReasoningEffort(selectedEffort, modelId: model),
      reasoningBudget: agentConfig.reasoningBudget,
      sessionId: agentConfig.sessionId,
      sessionParentId: agentConfig.sessionParentId,
    );
  }

  Future<_ReusableSpawnSession?> _loadReusableSession({
    required String sessionId,
  }) async {
    final persistence = this.persistence;
    final novelDatabase = this.novelDatabase;
    final parentSessionId = this.parentSessionId;
    if (persistence == null ||
        novelDatabase == null ||
        parentSessionId == null ||
        parentSessionId.isEmpty) {
      return null;
    }
    final session = await persistence.getSession(sessionId);
    if (session == null) {
      return null;
    }
    if (session.parentId != parentSessionId) {
      return null;
    }
    if (session.mode != AiSessionMode.chat.value) {
      return null;
    }

    final data = await persistence.loadSessionMessages(
      sessionId: session.id,
      novelDatabase: novelDatabase,
    );
    final restored = restorePersistedChatContext(data.messages);
    return _ReusableSpawnSession(
      sessionId: session.id,
      agentSlug: session.agentSlug,
      contextSnapshot: AgentContextSnapshot(
        messages: await _convertPersistedMessages(restored.retainedMessages),
        summary: restored.summary,
        compactionCount: restored.compactionCount,
        lastCompactionTokensBefore: restored.lastCompactionTokensBefore,
        lastCompactionTokensAfter: restored.lastCompactionTokensAfter,
      ),
      nestedCalls: {
        for (final message in data.messages)
          for (final block in message.blocks.whereType<AiToolCallBlock>())
            if (block.nestedCalls.isNotEmpty)
              block.callId: {
                for (final call in block.nestedCalls) call.callId: call,
              },
      },
    );
  }

  Future<List<AgentMessage>> _convertPersistedMessages(
    List<AiMessage> messages,
  ) => restoreAgentMessages(
    messagesSinceLatestCompact(messages).where(
      (message) => !message.isStreaming && message.role != AiMessageRole.system,
    ),
  );

  /// 即使沿用父模型，也必须取得本次 run 独立持有的 client 与工具资源。
  Future<_SpawnAgentModelResolution> _resolveModel(
    SpawnAgentRun execution,
    SubAgent subAgent, {
    required String subSessionId,
  }) async {
    final subProviderId = subAgent.providerId;
    final subModel = subAgent.model;
    final hasOwnModel =
        subProviderId != null &&
        subProviderId.isNotEmpty &&
        subModel != null &&
        subModel.isNotEmpty;
    final providerId = hasOwnModel ? subProviderId : defaultProviderId;
    final model = hasOwnModel ? subModel : defaultModel;
    if (providerId == null ||
        providerId.isEmpty ||
        model == null ||
        model.isEmpty) {
      throw const SpawnAgentInitializationException(
        reason: 'model_not_configured',
        message: '子代理没有完整的供应商和模型配置。请为父会话或子代理选择模型后再试。',
      );
    }
    Future<SpawnAgentResources> acquire(String provider, String selectedModel) {
      // 失败诊断必须归属实际尝试的模型，回退后不能继续记在原配置名下。
      execution._resourceProviderId = provider;
      execution._resourceModel = selectedModel;
      return resourcesResolver(
        providerId: provider,
        model: selectedModel,
        subSessionId: subSessionId,
        sourceSessionId: execution.sourceSessionId!,
      );
    }

    var usedFallback = false;
    SpawnAgentResources resources;
    try {
      resources = await acquire(providerId, model);
    } catch (error, stackTrace) {
      final parentProvider = defaultProviderId;
      final parentModel = defaultModel;
      if (!hasOwnModel ||
          parentProvider == null ||
          parentProvider.isEmpty ||
          parentModel == null ||
          parentModel.isEmpty ||
          (parentProvider == providerId && parentModel == model) ||
          !_shouldRun(execution._cancellation.token)) {
        rethrow;
      }
      _spawnAgentLog.warning(
        'SubAgent model initialization failed provider=$providerId model=$model; '
        'retrying with parent provider=$parentProvider model=$parentModel '
        'using independent resources. error=$error\n$stackTrace',
      );
      execution._fallbackFailure = execution._describeInitializationFailure(
        error,
      );
      resources = await acquire(parentProvider, parentModel);
      usedFallback = true;
    }
    execution._resources = resources;
    return _SpawnAgentModelResolution(
      client: resources.client,
      providerId: hasOwnModel && !usedFallback ? subProviderId : null,
      model: hasOwnModel && !usedFallback ? subModel : null,
      usedFallback: usedFallback,
    );
  }

  Future<void> _startPersistedRun({
    required String sessionId,
    required String runId,
    required SubAgent subAgent,
    required String name,
    required String? providerId,
    required String? model,
  }) async {
    final persistence = this.persistence!;
    final parentSessionId = this.parentSessionId!;
    final existing = await persistence.getSession(sessionId);
    final metadata = <String, dynamic>{...?existing?.metadata};
    metadata['spawn_run_status'] = 'running';
    metadata['spawn_run_id'] = runId;
    metadata['spawn_started_at'] = DateTime.now().toUtc().toIso8601String();
    metadata.remove('spawn_finished_at');
    metadata.remove('spawn_error_code');
    metadata.remove('spawn_persistence_error_code');
    final title = existing?.title ?? name;
    await persistence.upsertSession(
      id: sessionId,
      title: title,
      provider: providerId ?? defaultProviderId,
      model: model ?? defaultModel,
      mode: AiSessionMode.chat.value,
      agentSlug: subAgent.slug,
      parentId: parentSessionId,
      metadata: metadata,
      createdAt: existing?.createdAt,
    );
  }

  /// 尽力记录终态；子代理开始运行后，落库失败不得改写已经确定的工具结果。
  Future<void> _tryFinalizePersistedRun({
    required SpawnAgentRun execution,
    required String sessionId,
    required String status,
    required List<AgentMessage> messages,
    AgentContextSnapshot? contextSnapshot,
    String? errorCode,
  }) async {
    final persistence = this.persistence!;
    final novelDatabase = this.novelDatabase!;
    String? persistenceErrorCode;
    try {
      final aiMessages = prepareSpawnAgentRunMessagesForPersistence(messages)
          .map(
            (message) => message.copyWith(
              blocks: [
                for (final block in message.blocks)
                  if (block is AiToolCallBlock &&
                      execution._nestedCalls.containsKey(block.callId))
                    block.copyWith(
                      nestedCalls: execution._nestedCalls[block.callId]!.values
                          .toList(),
                    )
                  else
                    block,
              ],
            ),
          )
          .toList();
      await persistence.saveMessages(
        sessionId: sessionId,
        messages: aiMessages,
        novelDatabase: novelDatabase,
        contextSnapshot: contextSnapshot,
      );
    } catch (error, stackTrace) {
      _spawnAgentLog.error(
        '[DB] table=ai_chat_messages operation=UPSERT '
        'subSessionId=$sessionId parentSessionId=$parentSessionId',
        error: error,
        stackTrace: stackTrace,
      );
      persistenceErrorCode = 'spawn_message_persistence_failed';
      await _reportFailure(
        execution,
        {'ok': false, 'error_code': persistenceErrorCode},
        error,
        stackTrace,
        'message_persistence',
      );
    }
    try {
      final cancelled = execution._cancellation.token.isCancellationRequested;
      await _updatePersistedRunStatus(
        sessionId: sessionId,
        status: cancelled ? 'cancelled' : status,
        errorCode: cancelled ? 'user_cancelled' : errorCode,
        persistenceErrorCode: persistenceErrorCode,
      );
      // 取消可能发生在终态 UPDATE 的 await 期间；封口前补齐取消终态。
      if (!cancelled && execution._cancellation.token.isCancellationRequested) {
        await _updatePersistedRunStatus(
          sessionId: sessionId,
          status: 'cancelled',
          errorCode: 'user_cancelled',
          persistenceErrorCode: persistenceErrorCode,
        );
      }
    } catch (error, stackTrace) {
      _spawnAgentLog.error(
        '[DB] table=ai_chat_sessions operation=UPDATE_TERMINAL_STATUS '
        'subSessionId=$sessionId parentSessionId=$parentSessionId',
        error: error,
        stackTrace: stackTrace,
      );
      await _reportFailure(
        execution,
        {'ok': false, 'error_code': 'spawn_status_persistence_failed'},
        error,
        stackTrace,
        'status_persistence',
      );
    } finally {
      // 持久化已结束，后续取消不再改写已确定的执行结果。
      execution._cancellationSealed = true;
    }
  }

  Future<void> _updatePersistedRunStatus({
    required String sessionId,
    required String status,
    String? errorCode,
    String? persistenceErrorCode,
  }) async {
    final persistence = this.persistence!;
    final existing = await persistence.getSession(sessionId);
    if (existing == null) {
      throw StateError('Spawn session disappeared before finalization.');
    }
    final metadata = <String, dynamic>{...?existing.metadata};
    metadata['spawn_run_status'] = status;
    metadata['spawn_finished_at'] = DateTime.now().toUtc().toIso8601String();
    if (errorCode == null || errorCode.isEmpty) {
      metadata.remove('spawn_error_code');
    } else {
      metadata['spawn_error_code'] = errorCode;
    }
    if (persistenceErrorCode == null || persistenceErrorCode.isEmpty) {
      metadata.remove('spawn_persistence_error_code');
    } else {
      metadata['spawn_persistence_error_code'] = persistenceErrorCode;
    }
    await persistence.upsertSession(
      id: existing.id,
      title: existing.title,
      provider: existing.provider,
      model: existing.model,
      mode: existing.mode,
      agentSlug: existing.agentSlug,
      parentId: existing.parentId,
      metadata: metadata,
      reasoningEffort: existing.reasoningEffort,
      createdAt: existing.createdAt,
    );
  }
}

class _ReusableSpawnSession {
  const _ReusableSpawnSession({
    required this.sessionId,
    required this.agentSlug,
    required this.contextSnapshot,
    required this.nestedCalls,
  });

  final String sessionId;
  final String? agentSlug;
  final AgentContextSnapshot contextSnapshot;
  final Map<String, Map<String, AiNestedToolCall>> nestedCalls;
}

List<AgentHook> _hooksForSpawn(
  List<AgentHook> hooks, {
  required String sessionId,
  required String runId,
  required String runLabel,
  required String? providerId,
  required String? model,
  required String? Function() cancelSource,
}) {
  return [
    for (final hook in hooks)
      if (hook is UsageHook)
        hook.rebind(
          providerId: () => providerId,
          model: () => model,
          sessionId: () => sessionId,
          runId: () => runId,
          runLabel: () => runLabel,
        )
      else if (hook is TraceHook)
        hook.copyWith(
          cancelSource: cancelSource,
          providerId: () => providerId,
          sessionId: () => sessionId,
          model: () => model,
        )
      else
        hook,
  ];
}

String _usageRunLabel(String task) {
  final normalized = task.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.length <= 160) {
    return normalized;
  }
  return '${normalized.substring(0, 159)}…';
}

class _SpawnAgentModelResolution {
  const _SpawnAgentModelResolution({
    required this.client,
    required this.providerId,
    required this.model,
    this.usedFallback = false,
  });

  final ProviderClient client;
  final String? providerId;
  final String? model;
  final bool usedFallback;
}

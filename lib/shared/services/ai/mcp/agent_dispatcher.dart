// 职责: 为允许 MCP 的 Agent 构建请求快照并路由 direct 工具调用。
// 关联文件:
//   lib/shared/agent/agent_tool_dispatcher.dart
//   lib/shared/services/ai/tool_catalog.dart
//   lib/shared/services/mcp/settings_service.dart
//   lib/shared/services/mcp/tool_dispatcher.dart
import 'dart:async';
import 'package:mcp_dart/mcp_dart.dart' as sdk;
import '../../../agent/agent_tool_dispatcher.dart';
import '../../../agent/client.dart';
import '../../../agent/client/gemini_client.dart';
import '../../../agent/message.dart' show AgentMessage;
import '../../../models/mcp/config.dart';
import '../../../models/mcp/tool_descriptor.dart';
import '../../mcp/settings_service.dart';
import '../../mcp/runtime.dart';
import '../../mcp/tool_dispatcher.dart';
import '../../mcp/result_adapter.dart';
import '../../mcp/diagnostics.dart';
import '../codemode/tool.dart' show codemodeToolNames;
import '../tool_catalog.dart';
import 'run_command_handler.dart';

class McpAgentToolDispatcher
    implements AgentToolDispatcher, AgentRequestToolDispatcher {
  McpAgentToolDispatcher({
    required this.inner,
    required this.service,
    required this.isEnabled,
    required McpRunCommandHost runTools,
    this.mcpOnlyRun = false,
    this.client,
    this.sourceSessionId,
    this.allowedBuiltins,
  }) {
    session = service.session(sourceSessionId);
    catalog = AgentToolCatalog(
      session: session,
      runtime: service.runtime,
      builtins: () => inner
          .allToolDefs()
          .where(
            (tool) =>
                codemodeToolNames.contains(tool.name) &&
                (allowedBuiltins == null ||
                    allowedBuiltins!().contains(tool.name)),
          )
          .toList(),
    );
    runTools.mcpRunHandler = McpRunCommandHandler(
      catalog,
      sourceSessionId: sourceSessionId,
    );
    runTools.mcpAllowed = isEnabled;
  }
  final AgentToolDispatcher inner;
  final McpSettingsService service;
  final bool Function() isEnabled;
  final bool mcpOnlyRun;
  final ProviderClient? client;
  final String? sourceSessionId;
  final Iterable<String> Function()? allowedBuiltins;
  late final AgentToolCatalog catalog;
  late final McpSession session;
  bool _prepared = false;
  Map<String, McpToolDescriptor> _direct = {};
  @override
  String requestSystemPrompt = '';
  @override
  String? get systemPromptOverride => null;
  @override
  List<AgentMessage> requestMessages(List<AgentMessage> context) => const [];
  @override
  Future<void> prepareRequest({required bool runStart}) async {
    if (!isEnabled()) {
      _direct = {};
      requestSystemPrompt = '';
      return;
    }
    try {
      await service.activate();
    } catch (error) {
      session.configurationFailure ??= McpSessionFailure(
        'mcp_initialization_failed',
        error.toString(),
      );
    }
    session.captureConfigurationErrors();
    for (final server in catalog.servers) {
      if (session.failure(server.name) == null) {
        unawaited(
          session
              .ensureReady(server.name)
              .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        );
      }
    }
    if (!_prepared) {
      _prepared = true;
      await Future.wait([
        for (final server in catalog.servers)
          if (server.exposure == McpExposure.direct)
            session
                .ensureReady(server.name)
                .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ]).timeout(const Duration(seconds: 10), onTimeout: () => []);
    }
    _direct = {
      for (final tool in session.tools.values)
        if (catalog.servers.any(
          (s) => s.name == tool.server && s.exposure == McpExposure.direct,
        ))
          tool.name: tool,
    };
    catalog.declarationErrors.clear();
    if (client is GeminiClient) {
      for (final tool in _direct.values.toList()) {
        final diagnostic = geminiMcpSchemaIssue(tool.inputSchema);
        if (diagnostic != null) {
          catalog.declarationErrors[tool.name] = diagnostic;
          _direct.remove(tool.name);
        }
      }
    }
    requestSystemPrompt = catalog.summaryPrompt();
  }

  @override
  bool isExternalCall(String name, Map<String, dynamic> input) =>
      name.toLowerCase().startsWith('mcp__') ||
      service.runtime.knownTools.containsKey(name) ||
      (name == 'Run' &&
          input['command'] is String &&
          (input['command'] as String).trim().toLowerCase() == 'mcp');
  @override
  Map<String, dynamic>? callMetadata(
    String name,
    Map<String, dynamic> input,
    ToolExecutionContext? context,
  ) {
    if (!isExternalCall(name, input)) {
      return null;
    }
    final options = input['options'];
    final tool = service
        .runtime
        .knownTools[name == 'Run' && options is Map ? options['name'] : name];
    return {
      'tool_source': 'mcp',
      if (tool != null) 'mcp_server': tool.server,
      if (tool != null) 'mcp_tool': tool.rawName,
      'source_session_id':
          context?.sessionId ?? sourceSessionId ?? context?.sourceSessionId,
      'parent_call_id': context?.parentToolCallId,
    };
  }

  @override
  String externalErrorDiagnostic(Object error) =>
      mcpDiagnostic(error, null, maxCharacters: 2048);

  List<ToolDef> get _definitions => [
    for (final tool
        in (_direct.values.toList()..sort((a, b) => a.name.compareTo(b.name))))
      ToolDef(
        name: tool.name,
        description: tool.description,
        inputSchema: tool.inputSchema,
        outputSchema: tool.outputSchema,
      ),
  ];
  @override
  List<String> allToolNames() => [
    ...inner.allToolNames(),
    if (isEnabled()) ...session.tools.keys,
  ];
  @override
  List<ToolDef> allToolDefs() => [...inner.allToolDefs(), ..._definitions];
  @override
  List<ToolDef> toolDefsForNames(List<String> names) => [
    ...inner.toolDefsForNames([
      ...names,
      if (isEnabled() && !names.contains('Run')) 'Run',
    ]),
    ..._definitions,
  ];
  @override
  Future<Map<String, dynamic>> executeTool({
    required String name,
    required Map<String, dynamic> input,
    String? callId,
    bool emitEvents = true,
    ToolExecutionContext? context,
  }) async {
    if (name == 'Run' && mcpOnlyRun && input['command'] is String) {
      final command = (input['command'] as String).trim().toLowerCase();
      final action = input['subcommand'];
      input = {
        ...input,
        'command': command,
        if (command == 'help' && (action == null || action == ''))
          'subcommand': 'mcp',
      };
    }
    if (name == 'Run' &&
        mcpOnlyRun &&
        !(input['command'] == 'mcp' ||
            (input['command'] == 'help' &&
                (input['subcommand'] == 'mcp' ||
                    input['subcommand'] == null)))) {
      return {
        'ok': false,
        'error_code': 'permission_denied',
        'error': 'Only Run mcp and Run help mcp are available in this session.',
      };
    }
    if (isEnabled() &&
        (service.runtime.knownTools.containsKey(name) ||
            name.startsWith('mcp__'))) {
      final cancellation = sdk.BasicAbortController();
      final unlink = context?.cancellationToken?.onCancel(cancellation.abort);
      context?.lifecycleObserver?.onStarted?.call({'source': 'mcp'});
      try {
        final result =
            await McpToolDispatcher(service.runtime, session: session).call(
              name,
              input,
              signal: cancellation.signal,
              onProgress: context?.lifecycleObserver?.onProgress,
            );
        final bounded = context?.parentToolCallId != null
            ? result
            : McpResultAdapter.limit(result, McpResultAdapter.modelBudget);
        final payload = {
          ...bounded.toJson(),
          '_metadata': {
            ...?callMetadata(name, input, context),
            'execution_state': result.executionState.name,
            'effect_status': result.executionState.name == 'not_started'
                ? 'none'
                : 'unknown',
          },
        };
        context?.lifecycleObserver?.onFinished?.call(payload, null);
        return payload;
      } finally {
        unlink?.call();
        cancellation.abort();
      }
    }
    return inner.executeTool(
      name: name,
      input: input,
      callId: callId,
      emitEvents: emitEvents,
      context: context,
    );
  }
}

String? geminiMcpSchemaIssue(Map<String, dynamic> schema) {
  const supported = {
    'type',
    'format',
    'description',
    'nullable',
    'enum',
    'items',
    'properties',
    'required',
  };
  for (final key in schema.keys) {
    if (!supported.contains(key)) {
      return 'mcp_schema_unsupported: Gemini SDK cannot preserve $key in direct declarations.';
    }
  }
  if (schema['type'] != null && schema['type'] is! String) {
    return 'mcp_schema_unsupported: Gemini requires a single type.';
  }
  if (schema['enum'] is List &&
      (schema['enum'] as List).any((v) => v is! String)) {
    return 'mcp_schema_unsupported: Gemini SDK supports string enums only.';
  }
  final children = [
    if (schema['items'] is Map) schema['items'],
    if (schema['properties'] is Map) ...(schema['properties'] as Map).values,
  ];
  for (final child in children) {
    if (child is! Map<String, dynamic>) {
      return 'mcp_schema_unsupported: unsupported nested schema.';
    }
    final issue = geminiMcpSchemaIssue(child);
    if (issue != null) {
      return issue;
    }
  }
  return null;
}

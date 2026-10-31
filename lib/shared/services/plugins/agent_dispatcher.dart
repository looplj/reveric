// 职责: 在每轮模型请求捕获插件工具与 Prompt 快照，路由直接调用及历史展示元数据。
// 关联文件:
//   lib/shared/agent/agent_tool_dispatcher.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/services/plugins/registry.dart
//   lib/shared/services/ai/mcp/agent_dispatcher.dart
import '../../agent/agent_tool_dispatcher.dart';
import '../../agent/message.dart';
import 'host.dart';
import 'prompt.dart';
import 'registry.dart';
import '../../models/plugin/request.dart';
import '../../logger/app_logger.dart';
import 'package:uuid/uuid.dart';

final _log = AppLogger.forModule('PluginRequest');

class PluginAgentToolDispatcher
    implements AgentToolDispatcher, AgentRequestToolDispatcher {
  PluginAgentToolDispatcher({
    required this.inner,
    required this.host,
    this.sessionId,
    this.agentId = 'agent',
    this.scope,
  });
  final String? sessionId;
  final String agentId;
  final ({String? workId, String mode})? scope;
  final _ephemeralSessionId = const Uuid().v4();
  PluginRequestContext? _context;
  String? _systemPrompt;
  List<PluginPromptResult> _contexts = const [];
  final AgentToolDispatcher inner;
  final PluginHostService host;
  Map<String, PluginTool> _snapshot = {};
  AgentRequestToolDispatcher? get _request =>
      inner is AgentRequestToolDispatcher
      ? inner as AgentRequestToolDispatcher
      : null;
  bool _isPlugin(String name) =>
      _snapshot.containsKey(name) ||
      host.registry.knownToolNames.contains(name) ||
      host.registry.resolve(name) != null ||
      name == 'WebSearch' ||
      name == 'WebFetch';

  @override
  Future<void> prepareRequest({required bool runStart}) async {
    await _request?.prepareRequest(runStart: runStart);
    _snapshot = {
      for (final tool in host.registry.effectiveTools) tool.name: tool,
    };
    _contexts = const [];
    _context = null;
    if (runStart) {
      _systemPrompt = null;
    }
    try {
      final request = await host.requestContext(
        sessionId: sessionId,
        agentId: agentId,
        fallbackSessionId: _ephemeralSessionId,
        scope: scope,
      );
      _context = request;
      // system prompt 只在 run 开头取一次，同一 run 内的工具轮与重试保持前缀不变。
      if (runStart) {
        _systemPrompt = await host.requestSystemPrompt(request);
      }
      _contexts = await host.requestPromptContext(request);
    } catch (error, stack) {
      _log.error(
        'Plugin request scope unavailable session=$sessionId',
        error: error,
        stackTrace: stack,
      );
    }
  }

  @override
  String get requestSystemPrompt => _request?.requestSystemPrompt ?? '';
  @override
  String? get systemPromptOverride =>
      _systemPrompt ?? _request?.systemPromptOverride;
  @override
  List<AgentMessage> requestMessages(List<AgentMessage> context) {
    final inner = _request?.requestMessages(context) ?? const [];
    return [
      ...inner,
      ...pluginContextMessages(_contexts, [...context, ...inner]),
    ];
  }

  @override
  bool isExternalCall(String name, Map<String, dynamic> input) =>
      !_isPlugin(name) && (_request?.isExternalCall(name, input) ?? false);
  @override
  String externalErrorDiagnostic(Object error) =>
      _request?.externalErrorDiagnostic(error) ?? error.toString();
  @override
  Map<String, dynamic>? callMetadata(
    String name,
    Map<String, dynamic> input,
    ToolExecutionContext? context,
  ) {
    if (!_isPlugin(name)) {
      return _request?.callMetadata(name, input, context);
    }
    final tool = host.registry.resolve(name) ?? _snapshot[name];
    return {
      'tool_source': 'plugin',
      if (tool != null) ...{
        'plugin_id': tool.pluginId,
        'plugin_name': tool.pluginName.toJson(),
        if (tool.display != null) 'plugin_display': tool.display,
      },
    };
  }

  @override
  List<String> allToolNames() => [
    ...inner.allToolNames().where((name) => !_isPlugin(name)),
    ..._snapshot.keys,
  ];
  @override
  List<ToolDef> allToolDefs() => toolDefsForNames(inner.allToolNames());
  @override
  List<ToolDef> toolDefsForNames(List<String> names) => [
    ...inner.toolDefsForNames(names.where((name) => !_isPlugin(name)).toList()),
    for (final tool in _snapshot.values) tool.toolDef,
  ];
  @override
  Future<Map<String, dynamic>> executeTool({
    required String name,
    required Map<String, dynamic> input,
    String? callId,
    bool emitEvents = true,
    ToolExecutionContext? context,
  }) async {
    if (!_isPlugin(name)) {
      return inner.executeTool(
        name: name,
        input: input,
        callId: callId,
        emitEvents: emitEvents,
        context: context,
      );
    }
    final metadata = callMetadata(name, input, context);
    context?.lifecycleObserver?.onStarted?.call(metadata);
    final result = await host.execute(
      name,
      input,
      callId: callId ?? '',
      sessionId: context?.sessionId ?? sessionId,
      executionContext: context,
      cancellation: context?.cancellationToken,
      request: _context,
    );
    final payload = {...result, '_metadata': metadata};
    context?.lifecycleObserver?.onFinished?.call(payload, null);
    return payload;
  }
}

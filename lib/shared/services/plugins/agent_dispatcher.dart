// 职责: 在每轮模型请求捕获插件工具快照并路由直接调用及历史展示元数据。
// 关联文件:
//   lib/shared/agent/agent_tool_dispatcher.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/services/plugins/registry.dart
//   lib/shared/services/ai/mcp/agent_dispatcher.dart
import '../../agent/agent_tool_dispatcher.dart';
import 'host.dart';
import 'registry.dart';

class PluginAgentToolDispatcher
    implements AgentToolDispatcher, AgentRequestToolDispatcher {
  PluginAgentToolDispatcher({
    required this.inner,
    required this.host,
    this.sessionId,
  });
  final String? sessionId;
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
  Future<void> prepareRequest() async {
    await _request?.prepareRequest();
    _snapshot = {
      for (final tool in host.registry.effectiveTools) tool.name: tool,
    };
  }

  @override
  String get requestSystemPrompt => _request?.requestSystemPrompt ?? '';
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
    );
    final payload = {...result, '_metadata': metadata};
    context?.lifecycleObserver?.onFinished?.call(payload, null);
    return payload;
  }
}

// 职责: 执行 Run mcp 的发现和调用子命令，共用目录与执行结果预算。
// 关联文件:
//   lib/shared/services/ai/tool_catalog.dart
//   lib/shared/services/mcp/tool_dispatcher.dart
//   lib/shared/services/ai/tools_run.dart
import 'package:mcp_dart/mcp_dart.dart' as sdk;
import '../../../agent/agent_tool_dispatcher.dart';
import '../../mcp/tool_dispatcher.dart';
import '../../mcp/runtime.dart';
import '../../mcp/result_adapter.dart';
import '../files/attachments.dart' show prepareToolResult;
import '../tool_catalog.dart';

const mcpRunHelp = '''MCP commands:
Run mcp list options={server?, cursor?}: list services, or tools of the named server.
Run mcp search options={query, server?, limit?}: search MCP tools (limit 1–20, default 8).
Run mcp describe options={name}: get the complete tool definition.
Run mcp call options={name, arguments}: call the discovered tool name.
Names come from discovery results; server is the exact configured service name.
Tool calls report executionState. An unknown result must not be automatically replayed.''';

abstract interface class McpRunCommandHost {
  set mcpRunHandler(McpRunCommandHandler? handler);
  set mcpAllowed(bool Function()? allowed);
}

class McpRunCommandHandler {
  McpRunCommandHandler(this.catalog, {this.sourceSessionId});
  final String? sourceSessionId;
  final AgentToolCatalog catalog;
  Future<Map<String, dynamic>> execute(
    String action,
    Map<String, dynamic> options,
    ToolExecutionContext? context,
  ) async {
    final watch = Stopwatch()..start();
    Map<String, dynamic> payload;
    try {
      String requiredString(String field) {
        final value = options[field];
        if (value is! String || value.isEmpty) {
          throw ArgumentError('$field must be a nonempty string');
        }
        return value;
      }

      switch (action) {
        case 'list':
          payload = options.containsKey('server')
              ? await catalog.listTools(
                  mcpServer: requiredString('server'),
                  cursor: options['cursor'] as String?,
                )
              : catalog.listMcpServers(cursor: options['cursor'] as String?);
        case 'search':
          payload = await catalog.searchTool(
            requiredString('query'),
            source: 'mcp',
            mcpServer: options.containsKey('server')
                ? requiredString('server')
                : null,
            limit: options['limit'] as int? ?? 8,
          );
        case 'describe':
          payload = await catalog.describeTool(requiredString('name'));
          if (payload['source'] != 'mcp') {
            throw ArgumentError('Run mcp only accepts MCP tools');
          }
        case 'call':
          final name = requiredString('name');
          final arguments = options['arguments'];
          if (arguments is! Map<String, dynamic>) {
            throw ArgumentError('arguments must be an object');
          }
          final cancellation = sdk.BasicAbortController();
          final unlink = context?.cancellationToken?.onCancel(
            cancellation.abort,
          );
          try {
            final result =
                await McpToolDispatcher(
                  catalog.runtime,
                  session: catalog.session,
                ).call(
                  name,
                  arguments,
                  signal: cancellation.signal,
                  onProgress: context?.lifecycleObserver?.onProgress,
                );
            payload =
                (context?.parentToolCallId != null
                        ? result
                        : McpResultAdapter.limit(
                            result,
                            McpResultAdapter.modelBudget - 256,
                          ))
                    .toJson();
          } finally {
            unlink?.call();
            cancellation.abort();
          }
        default:
          throw ArgumentError('Unknown MCP action; use Run help mcp');
      }
    } catch (error) {
      payload = {
        'ok': false,
        'error_code': error is McpSessionFailure
            ? error.code
            : 'mcp_discovery_error',
        if (error is McpSessionFailure) 'executionState': 'not_started',
        'error': error.toString(),
      };
    }
    final tool = catalog.runtime.knownTools[options['name']];
    return prepareToolResult({
      ...payload,
      '_metadata': {
        'tool_source': 'mcp',
        'mcp_server': tool?.server,
        'mcp_tool': tool?.rawName,
        'source_session_id':
            context?.sessionId ?? sourceSessionId ?? context?.sourceSessionId,
        'parent_call_id': context?.parentToolCallId,
        if (payload['executionState'] != null)
          'execution_state': payload['executionState'],
        'effect_status':
            action != 'call' || payload['executionState'] == 'not_started'
            ? 'none'
            : 'unknown',
      },
      'command': 'mcp $action',
      'exit_code': payload['ok'] == false ? 1 : 0,
      'duration_ms': watch.elapsedMilliseconds,
    });
  }
}

// 职责: 验证请求级插件快照、静态允许名单穿透与内层 MCP 能力委托。
// 关联文件:
//   lib/shared/services/plugins/agent_dispatcher.dart
//   lib/shared/services/plugins/host.dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/agent/fake_agent.dart';
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/services/plugins/agent_dispatcher.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'host_test.dart' show FakeExecutor, package;

class RequestInner extends FakeAgentToolDispatcher
    implements AgentRequestToolDispatcher {
  RequestInner()
    : super(
        tools: {
          'Read': FakeAgentTool(
            def: const ToolDef(
              name: 'Read',
              description: 'Read',
              inputSchema: {'type': 'object'},
            ),
            handler: (_, _) async => {'ok': true},
          ),
        },
      );
  int requests = 0;
  @override
  Future<void> prepareRequest({required bool runStart}) async {
    requests++;
  }

  @override
  String get requestSystemPrompt => 'MCP summary';
  @override
  String? get systemPromptOverride => null;
  @override
  List<AgentMessage> requestMessages(List<AgentMessage> context) => const [];
  @override
  bool isExternalCall(String name, Map<String, dynamic> input) =>
      name.startsWith('mcp__');
  @override
  Map<String, dynamic>? callMetadata(
    String name,
    Map<String, dynamic> input,
    ToolExecutionContext? context,
  ) => {'tool_source': 'mcp'};
  @override
  String externalErrorDiagnostic(Object error) => 'MCP diagnostic: $error';
}

void main() {
  test(
    'next request sees enable changes; old names still refuse execution',
    () async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      final host = PluginHostService(
        dao: db.pluginDao,
        registry: PluginRegistry(hostToolNames: {'Read', 'Codemode'}),
        packages: () async => [package()],
        executorFactory: (call, stop) => FakeExecutor(),
        platform: 'macos',
      );
      addTearDown(host.dispose);
      final inner = RequestInner(),
          dispatcher = PluginAgentToolDispatcher(
            inner: RequestInner(),
            host: host,
          );
      final chained = PluginAgentToolDispatcher(inner: inner, host: host);
      expect(
        (await dispatcher.executeTool(
          name: 'WebFetch',
          input: {},
        ))['error_code'],
        'plugin_unavailable',
      );
      await host.start();
      await host.setEnabled('test.web', true);
      await chained.prepareRequest(runStart: true);
      expect(chained.toolDefsForNames(['Read']).map((d) => d.name), [
        'Read',
        'WebSearch',
        'WebFetch',
      ]);
      expect(
        chained
            .toolDefsForNames(['Read', 'WebFetch'])
            .map((d) => d.name)
            .where((n) => n == 'WebFetch'),
        hasLength(1),
      );
      expect(chained.requestSystemPrompt, 'MCP summary');
      expect(inner.requests, 1);
      expect(chained.isExternalCall('WebFetch', {}), false);
      expect(chained.isExternalCall('mcp__server__read', {}), true);
      expect(
        chained.callMetadata('mcp__server__read', {}, null)?['tool_source'],
        'mcp',
      );
      final result = await chained.executeTool(name: 'WebFetch', input: {});
      expect((result['_metadata'] as Map)['plugin_id'], 'test.web');
      await host.setEnabled('test.web', false);
      expect(
        (await chained.executeTool(name: 'WebFetch', input: {}))['error_code'],
        'plugin_unavailable',
      );
      await chained.prepareRequest(runStart: true);
      expect(chained.toolDefsForNames(['Read']).map((d) => d.name), ['Read']);
      await host.setEnabled('test.web', true);
      await chained.prepareRequest(runStart: true);
      expect(chained.allToolNames(), contains('WebFetch'));
      expect(inner.requests, 3);
    },
  );
}

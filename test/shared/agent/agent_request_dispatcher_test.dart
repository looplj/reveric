// 职责: 验证请求级调度器的 system prompt 替换按 run 刷新，以及每轮追加消息进入上下文并作为新消息发布。
// 关联文件:
//   lib/shared/agent/agent.dart
//   lib/shared/agent/agent_tool_dispatcher.dart
//   lib/shared/agent/fake_agent.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/agent_event.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/agent/fake_agent.dart';
import 'package:reveric/shared/agent/message.dart';

class _RequestDispatcher extends FakeAgentToolDispatcher
    implements AgentRequestToolDispatcher {
  _RequestDispatcher()
    : super(
        tools: {
          'Bump': FakeAgentTool(
            def: const ToolDef(
              name: 'Bump',
              description: 'Bump',
              inputSchema: {'type': 'object'},
            ),
            handler: (_, _) async {
              _version++;
              return {'ok': true};
            },
          ),
        },
      );

  static var _version = 1;
  final runStarts = <bool>[];
  var _runs = 0;

  String get _snapshot =>
      '<system-remind type="test">v$_version</system-remind>';

  @override
  Future<void> prepareRequest({required bool runStart}) async {
    runStarts.add(runStart);
    if (runStart) {
      _runs++;
    }
  }

  @override
  String get requestSystemPrompt => 'request appendix';

  @override
  String? get systemPromptOverride => 'override run $_runs';

  @override
  List<AgentMessage> requestMessages(List<AgentMessage> context) {
    final last = context.lastWhere(
      (m) => m.content.startsWith('<system-remind type="test">'),
      orElse: () => AgentMessage.user(id: '', content: ''),
    );
    return last.content == _snapshot
        ? const []
        : [AgentMessage.user(id: 'snapshot_v$_version', content: _snapshot)];
  }

  @override
  bool isExternalCall(String name, Map<String, dynamic> input) => false;

  @override
  Map<String, dynamic>? callMetadata(
    String name,
    Map<String, dynamic> input,
    ToolExecutionContext? context,
  ) => null;

  @override
  String externalErrorDiagnostic(Object error) => error.toString();
}

void main() {
  test(
    'override is refreshed per run and request messages are appended once',
    () async {
      final client = FakeProviderClient(
        responses: const [
          FakeProviderClientResponse.toolCalls([
            ToolCall(callId: 'call', toolName: 'Bump', arguments: {}),
          ]),
          FakeProviderClientResponse.text('done'),
          FakeProviderClientResponse.text('again'),
        ],
      );
      final dispatcher = _RequestDispatcher();
      final agent = FakeAgent.create(
        client: client,
        systemPrompt: 'default prompt',
        toolManager: dispatcher,
      );
      final added = <String>[];
      await for (final event in agent.process('task', userMessageId: 'task')) {
        if (event case AgentMessageAdded(
          :final message,
        ) when message.role == AgentMessageRole.user) {
          added.add(message.id);
        }
      }
      expect(dispatcher.runStarts, [true, false]);
      expect(added, ['snapshot_v1', 'snapshot_v2']);
      final requests = client.capturedStreamRequests;
      for (final request in requests) {
        final system = request.messages.first;
        expect(system.role, AgentMessageRole.system);
        expect(system.content, 'override run 1\nrequest appendix');
      }
      expect(requests[0].messages.map((m) => m.id).skip(1), [
        'task',
        'snapshot_v1',
      ]);
      final second = requests[1].messages.map((m) => m.id).toList();
      expect(second.where((id) => id == 'snapshot_v1'), hasLength(1));
      expect(second.last, 'snapshot_v2');

      added.clear();
      await for (final event in agent.process('next', userMessageId: 'next')) {
        if (event case AgentMessageAdded(
          :final message,
        ) when message.role == AgentMessageRole.user) {
          added.add(message.id);
        }
      }
      expect(dispatcher.runStarts, [true, false, true]);
      expect(added, isEmpty);
      expect(
        client.capturedStreamRequests.last.messages.first.content,
        'override run 2\nrequest appendix',
      );
    },
  );
}

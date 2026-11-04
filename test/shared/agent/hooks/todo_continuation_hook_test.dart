// 职责: TodoContinuationHook 测试 — 验证结束时未完成 Todo 的续跑决策与快照上报。
// 关联文件:
//   lib/shared/agent/hooks/todo_continuation_hook.dart
//   lib/shared/agent/agent.dart
//   lib/shared/models/todo.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/agent.dart';
import 'package:reveric/shared/agent/agent_config.dart';
import 'package:reveric/shared/agent/agent_event.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/agent/client.dart';
import 'package:reveric/shared/agent/hooks/todo_continuation_hook.dart';
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/models/todo.dart';

void main() {
  group('TodoContinuationHook', () {
    Agent buildAgent(_FakeProviderClient client, TodoContinuationHook hook) {
      return Agent.custom(
        id: 'test_agent',
        systemPrompt: 'system',
        client: client,
        config: const AgentConfig(),
        toolManager: const _FakeToolDispatcher(),
        hooks: [hook],
      );
    }

    test('continues once with a system-remind while todos remain', () async {
      final client = _FakeProviderClient(['first response', 'second response']);
      final snapshots = <UnfinishedTodoSnapshot>[];
      final agent = buildAgent(
        client,
        TodoContinuationHook(
          loadTodos: () => [
            createTodo(content: 'Run the focused tests', status: 'pending'),
          ],
          onUnfinishedAtDone: snapshots.add,
        ),
      );

      final events = await agent.process('start task').toList();

      expect(events.whereType<AgentFollowUpApplied>(), hasLength(1));
      expect(events.whereType<AgentDone>().single.finalText, 'second response');
      final remind = client.messagesByRound.last.last.content;
      expect(remind, startsWith("<system-remind type='todo_continuation'>"));
      expect(remind, contains('Run the focused tests'));
      expect(snapshots.map((s) => s.decision), [
        TodoContinuationDecision.continued,
        TodoContinuationDecision.limit_reached,
      ]);
      expect(snapshots.last.requestCount, 2);
      expect(snapshots.last.continuationCount, 1);
    });

    test('reports a snapshot without continuing when disabled', () async {
      final client = _FakeProviderClient(['done']);
      final snapshots = <UnfinishedTodoSnapshot>[];
      final agent = buildAgent(
        client,
        TodoContinuationHook(
          enabled: false,
          loadTodos: () => [
            createTodo(content: 'Draft', status: 'in_progress'),
            createTodo(content: 'Review', status: 'pending'),
            createTodo(content: 'Outline', status: 'completed'),
          ],
          onUnfinishedAtDone: snapshots.add,
        ),
      );

      final events = await agent.process('start task').toList();

      expect(events.whereType<AgentFollowUpApplied>(), isEmpty);
      expect(client.messagesByRound, hasLength(1));
      expect(snapshots.single.toTraceJson(), {
        'total': 3,
        'unfinished': 2,
        'pending': 1,
        'in_progress': 1,
        'ends_with_question': false,
        'continuation_count': 0,
        'decision': 'disabled',
      });
      expect(snapshots.single.requestCount, 1);
    });

    test('does not continue when the reply asks the user', () async {
      final client = _FakeProviderClient(['要先确认主角的名字吗？']);
      final snapshots = <UnfinishedTodoSnapshot>[];
      final agent = buildAgent(
        client,
        TodoContinuationHook(
          loadTodos: () => [createTodo(content: 'Rename', status: 'pending')],
          onUnfinishedAtDone: snapshots.add,
        ),
      );

      final events = await agent.process('start task').toList();

      expect(events.whereType<AgentFollowUpApplied>(), isEmpty);
      expect(snapshots.single.decision, TodoContinuationDecision.awaiting_user);
      expect(snapshots.single.endsWithQuestion, isTrue);
    });

    test('does nothing when all todos are completed or cancelled', () async {
      final client = _FakeProviderClient(['done']);
      final snapshots = <UnfinishedTodoSnapshot>[];
      final agent = buildAgent(
        client,
        TodoContinuationHook(
          loadTodos: () => [
            createTodo(content: 'Finished', status: 'completed'),
            createTodo(content: 'Skipped', status: 'cancelled'),
          ],
          onUnfinishedAtDone: snapshots.add,
        ),
      );

      final events = await agent.process('start task').toList();

      expect(events.whereType<AgentFollowUpApplied>(), isEmpty);
      expect(client.messagesByRound, hasLength(1));
      expect(snapshots, isEmpty);
    });
  });
}

class _FakeProviderClient implements ProviderClient {
  _FakeProviderClient(this.responses);

  final List<String> responses;
  final List<List<AgentMessage>> messagesByRound = [];
  int _roundIndex = 0;

  @override
  Future<ChatResponse> chat({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async {
    throw UnimplementedError();
  }

  @override
  Stream<StreamEvent> chatStream({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async* {
    messagesByRound.add(List<AgentMessage>.from(messages));
    final text = responses[_roundIndex];
    _roundIndex += 1;
    yield TextDelta(text);
    yield StreamComplete();
  }

  @override
  void cancel() {}
}

class _FakeToolDispatcher implements AgentToolDispatcher {
  const _FakeToolDispatcher();

  @override
  Future<Map<String, dynamic>> executeTool({
    required String name,
    required Map<String, dynamic> input,
    String? callId,
    bool emitEvents = true,
    ToolExecutionContext? context,
  }) async {
    return {'ok': true};
  }

  @override
  List<String> allToolNames() {
    return const [];
  }

  @override
  List<ToolDef> allToolDefs() {
    return const [];
  }

  @override
  List<ToolDef> toolDefsForNames(List<String> names) {
    return const [];
  }
}

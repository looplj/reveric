// 职责: 验证上下文压缩请求复用主 Agent 前缀，并安全保留 Todo 真源。
// 关联文件:
//   lib/shared/services/ai/context_summarizer.dart
//   lib/shared/agent/agent.dart
//   lib/shared/models/todo.dart
//   assets/prompts/system/context_compaction.md

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/agent.dart';
import 'package:reveric/shared/agent/agent_config.dart';
import 'package:reveric/shared/agent/agent_context_manager.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/agent/client.dart';
import 'package:reveric/shared/agent/fake_agent.dart';
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/models/todo.dart';
import 'package:reveric/shared/services/ai/context_summarizer.dart';
import 'package:reveric/shared/services/ai/prompt_template.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(PromptTemplateService.loadAll);

  test(
    'parent cancellation stops compaction without retry or commit',
    () async {
      final client = _CompactionCancellationClient();
      final tools = FakeAgentToolDispatcher();
      final manager = SmartAgentContextManager(compactThreshold: 1)
        ..setMessages([
          AgentMessage.user(id: 'old_user', content: 'old request'),
          AgentMessage.assistant(id: 'old_answer', content: 'old answer'),
        ])
        ..summarizer = buildDefaultContextSummarizer(
          agentId: 'summary',
          systemPrompt: 'system',
          allowedTools: const [],
          client: client,
          config: const AgentConfig(),
          toolManager: tools,
        );
      final agent = Agent.custom(
        id: 'parent',
        systemPrompt: 'system',
        client: client,
        config: const AgentConfig(),
        toolManager: tools,
        contextManager: manager,
      );
      final run = agent.process('current request').toList();
      await client.started.future;
      final before = manager.snapshot();
      agent.cancel();
      await run;

      expect(client.calls, 1, reason: 'a cancelled summary must not retry');
      expect(manager.snapshot().summary, before.summary);
      expect(manager.compactionCount, before.compactionCount);
      expect(manager.messages, before.messages);
      expect(agent.isProcessing, isFalse);
    },
  );

  for (final cancelDuringSupplement in [false, true]) {
    test(
      'cancellation preserves context during ${cancelDuringSupplement ? 'supplement' : 'summary'} completion',
      () async {
        final cancellation = AgentCancellationController();
        final started = Completer<void>();
        final release = Completer<void>();
        final manager =
            SmartAgentContextManager(
              compactThreshold: 1,
              contextSupplementProvider: () async {
                if (cancelDuringSupplement) {
                  started.complete();
                  await release.future;
                }
                return [];
              },
            )..setMessages([
              AgentMessage.user(id: 'old_user', content: 'old request'),
              AgentMessage.assistant(id: 'old_answer', content: 'old answer'),
              AgentMessage.user(id: 'current', content: 'current request'),
            ]);
        manager.summarizer =
            ({required messages, previousSummary, cancellationToken}) async {
              expect(cancellationToken, same(cancellation.token));
              if (!cancelDuringSupplement) {
                started.complete();
                await release.future;
              }
              return 'late summary';
            };
        final before = manager.snapshot();
        final run = manager.compact(cancellationToken: cancellation.token);
        final failure = expectLater(run, throwsA(isA<Exception>()));
        await started.future;
        cancellation.cancel();
        release.complete();
        await failure;
        expect(manager.snapshot().summary, before.summary);
        expect(manager.compactionCount, before.compactionCount);
        expect(manager.messages, before.messages);
      },
    );
  }

  test('compaction prompt excludes runtime-injected system content', () {
    final prompt = PromptTemplateService.instance.rawAsset(
      'assets/prompts/system/context_compaction',
    );

    expect(prompt, contains('不属于对话历史，不得复制到摘要'));
    expect(prompt, contains('用户自定义规则'));
    expect(prompt, contains('AgentSkill / SubAgent'));
    expect(prompt, contains('当前任务的临时要求'));
    expect(prompt, contains('已确认事实'));
    expect(prompt, contains('未确认线索'));
    expect(prompt, contains('执行进度'));
    expect(prompt, isNot(contains('## 用户偏好与禁忌')));
  });

  test('formatTodoContextSupplement returns authoritative empty list', () {
    expect(formatTodoContextSupplement(const []), '[当前结构化 Todo 真源]\n[]');
  });

  test('formatTodoContextSupplement keeps only active todos', () {
    final snapshot = formatTodoContextSupplement([
      createTodo(
        content: '子会话待办',
        status: 'in_progress',
        priority: 'high',
        sessionId: 'sub_session_1',
      ),
      createTodo(
        content: '已完成历史',
        status: 'completed',
        sessionId: 'sub_session_1',
      ),
    ]);
    expect(snapshot, startsWith('[当前结构化 Todo 真源]\n'));
    expect(snapshot, contains('"content":"子会话待办"'));
    expect(snapshot, contains('"status":"in_progress"'));
    expect(snapshot, contains('"priority":"high"'));
    expect(snapshot, isNot(contains('已完成历史')));
  });

  test(
    'appends the current Todo snapshot only after model compaction',
    () async {
      final client = FakeProviderClient(
        responses: const [FakeProviderClientResponse.text('compacted')],
      );
      final toolManager = FakeAgentToolDispatcher.withResults(
        results: {
          'Read': {'ok': true},
        },
      );
      var loadedAfterModelRequest = false;
      final summarize = buildDefaultContextSummarizer(
        agentId: 'orchestrator',
        systemPrompt: 'Main system prompt',
        memoryBlock: 'Stable memory',
        allowedTools: const ['Read'],
        client: client,
        config: const AgentConfig(),
        toolManager: toolManager,
        contextSupplement: () async {
          loadedAfterModelRequest = client.capturedStreamRequests.isNotEmpty;
          return [
            buildTodoContextSupplementMessage([
              createTodo(
                content: '验证缓存',
                status: 'in_progress',
                priority: 'high',
                sessionId: 'chat_session',
              ),
            ]),
          ];
        },
      );
      final history = [
        AgentMessage.user(id: 'old_user', content: 'old user request'),
        AgentMessage.assistant(id: 'old_assistant', content: 'old answer'),
      ];

      final result = await summarize(
        messages: history,
        previousSummary:
            'earlier summary\n\n'
            '[当前结构化 Todo 真源]\n'
            '[{"content":"stale todo"}]',
      );

      expect(loadedAfterModelRequest, isTrue);
      expect(result, startsWith('compacted\n\n[当前结构化 Todo 真源]'));
      expect(result, contains('验证缓存'));
      expect(result, isNot(contains('stale todo')));
      final request = client.capturedStreamRequests.single;
      expect(request.tools?.map((tool) => tool.name), ['Read']);
      expect(
        request.messages.first.content,
        'Main system prompt\n\n---\n\nStable memory',
      );
      expect(request.messages[1].id, 'ctx_summary');
      expect(request.messages[1].content, contains('earlier summary'));
      expect(request.messages[1].content, contains('stale todo'));
      expect(request.messages[2].id, 'old_user');
      expect(request.messages[3].id, 'old_assistant');
      expect(request.messages.last.content, contains('结构化 Todo'));
      expect(request.messages.last.content, isNot(contains('验证缓存')));
      expect(
        request.messages.where((message) => message.id == 'ctx_todos'),
        isEmpty,
      );
    },
  );

  test('subagent-style supplement binds to a fixed session_id', () async {
    const subSessionId = 'sub_session_compact';
    final client = FakeProviderClient(
      responses: const [FakeProviderClientResponse.text('compacted')],
    );
    final toolManager = FakeAgentToolDispatcher();
    String? loadedSessionId;
    Future<List<AgentMessage>> contextSupplementForSession(
      String sessionId,
    ) async {
      loadedSessionId = sessionId;
      return [
        buildTodoContextSupplementMessage([
          createTodo(content: '子待办', sessionId: sessionId),
        ]),
      ];
    }

    final summarize = buildDefaultContextSummarizer(
      agentId: 'sub_reviewer',
      systemPrompt: 'Sub system prompt',
      allowedTools: const [],
      client: client,
      config: const AgentConfig(),
      toolManager: toolManager,
      // 与 SpawnAgentHandler 相同的绑定形状。
      contextSupplement: () => contextSupplementForSession(subSessionId),
    );

    final result = await summarize(
      messages: [AgentMessage.user(id: 'old_user', content: 'old request')],
    );

    expect(loadedSessionId, subSessionId);
    expect(result, contains('子待办'));
    expect(
      client.capturedStreamRequests.single.messages.where(
        (message) => message.id == 'ctx_todos',
      ),
      isEmpty,
    );
  });

  test(
    'Todo enters context only after compaction and refreshes on the next compaction',
    () async {
      final firstTodoContent = '第一版待办-${List.filled(9000, 'x').join()}';
      var todoContent = firstTodoContent;
      var loadedAfterModelRequest = false;
      final client = FakeProviderClient(
        responses: const [
          FakeProviderClientResponse.text('first narrative'),
          FakeProviderClientResponse.text('second narrative'),
        ],
      );
      final toolManager = FakeAgentToolDispatcher();
      late SmartAgentContextManager manager;
      manager = SmartAgentContextManager(
        compactThreshold: 1,
        contextTokens: 100000,
        outputFloor: 1,
        contextSupplementProvider: () async {
          loadedAfterModelRequest = client.capturedStreamRequests.isNotEmpty;
          return [
            buildTodoContextSupplementMessage([
              createTodo(content: todoContent, sessionId: 'chat_session'),
            ]),
          ];
        },
      );
      manager.summarizer = buildDefaultContextSummarizer(
        agentId: 'orchestrator',
        systemPrompt: 'system',
        allowedTools: const [],
        client: client,
        config: const AgentConfig(),
        toolManager: toolManager,
        contextSupplement: () async => manager.contextSupplementMessages,
      );
      manager.setMessages([
        AgentMessage.user(id: 'old_user', content: 'old request'),
        AgentMessage.assistant(id: 'old_assistant', content: 'old answer'),
        AgentMessage.user(id: 'current_user', content: 'current request'),
      ]);

      final beforeCompaction = await manager.buildMessages();
      expect(
        beforeCompaction.map((message) => message.content).join('\n'),
        isNot(contains(todoContent)),
      );

      await manager.compact(taskText: 'current request');
      final afterFirstCompaction = await manager.buildMessages();
      expect(loadedAfterModelRequest, isTrue);
      expect(afterFirstCompaction.first.id, 'ctx_summary');
      expect(afterFirstCompaction.first.content, contains('first narrative'));
      expect(afterFirstCompaction.first.content, contains(firstTodoContent));
      expect(afterFirstCompaction.first.content.length, greaterThan(9000));
      expect(manager.snapshot().summary, afterFirstCompaction.first.content);
      expect(
        afterFirstCompaction.where((message) => message.id == 'ctx_todos'),
        isEmpty,
      );

      todoContent = '第二版待办';
      final beforeSecondCompaction = await manager.buildMessages();
      expect(beforeSecondCompaction.first.content, contains(firstTodoContent));
      expect(beforeSecondCompaction.first.content, isNot(contains('第二版待办')));

      manager.addMessages([
        AgentMessage.assistant(id: 'new_assistant', content: 'new answer'),
        AgentMessage.user(id: 'new_user', content: 'new request'),
      ]);
      await manager.compact(taskText: 'new request');
      final afterSecondCompaction = await manager.buildMessages();
      expect(afterSecondCompaction.first.content, contains('second narrative'));
      expect(afterSecondCompaction.first.content, contains('第二版待办'));
      expect(afterSecondCompaction.first.content, isNot(contains('第一版待办')));
      expect(
        client.capturedStreamRequests.last.messages
            .map((message) => message.content)
            .join('\n'),
        contains(firstTodoContent),
      );
    },
  );

  test(
    'does not execute a tool if the compaction model ignores its instruction',
    () async {
      final client = FakeProviderClient(
        responses: const [
          FakeProviderClientResponse.toolCalls([
            ToolCall(callId: 'compact_read', toolName: 'Read', arguments: {}),
          ]),
          FakeProviderClientResponse.text('compacted'),
        ],
      );
      final toolManager = FakeAgentToolDispatcher.withResults(
        results: {
          'Read': {'ok': true},
        },
      );
      final summarize = buildDefaultContextSummarizer(
        agentId: 'orchestrator',
        systemPrompt: 'Main system prompt',
        allowedTools: const ['Read'],
        client: client,
        config: const AgentConfig(),
        toolManager: toolManager,
      );

      await expectLater(
        summarize(
          messages: [AgentMessage.user(id: 'old_user', content: 'old request')],
        ),
        throwsA(
          isA<AgentProcessException>().having(
            (error) => error.technicalMessage,
            'technicalMessage',
            contains('must return text without tools'),
          ),
        ),
      );
      expect(toolManager.capturedCalls, isEmpty);
      expect(client.capturedStreamRequests, hasLength(1));
    },
  );
}

/// Models a provider that closes without a finish event on abort, then accepts
/// a fresh request. This is the production empty-response retry trigger.
class _CompactionCancellationClient extends FakeProviderClient {
  final started = Completer<void>();
  final aborted = Completer<void>();
  int calls = 0;

  @override
  Stream<StreamEvent> chatStream({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async* {
    calls += 1;
    if (calls == 1) {
      started.complete();
      await aborted.future;
      return;
    }
    yield TextDelta('late summary');
    yield StreamComplete(finishReason: StreamFinishReason.stop);
  }

  @override
  void cancel() {
    if (!aborted.isCompleted) {
      aborted.complete();
    }
  }
}

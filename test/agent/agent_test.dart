// 职责: 验证 Agent 消息往返、追加指令压缩与执行收尾的边界行为。
// 关联文件:
//   lib/shared/agent/agent.dart
//   lib/shared/agent/agent_context_manager.dart
//   lib/shared/agent/client/openai_client.dart
//   lib/shared/agent/client/openai_responses_client.dart

import 'package:reveric/shared/utils/ai_error.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show ClientException;
import 'package:openai_dart/openai_dart.dart' as openai;
import 'package:reveric/shared/agent/agent.dart';
import 'package:reveric/shared/agent/agent_config.dart';
import 'package:reveric/shared/agent/agent_context_manager.dart';
import 'package:reveric/shared/agent/agent_event.dart';
import 'package:reveric/shared/agent/agent_hook.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/agent/client.dart';
import 'package:reveric/shared/agent/client/openai_client.dart';
import 'package:reveric/shared/agent/client/openai_responses_client.dart';
import 'package:reveric/shared/agent/fake_agent.dart';
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/agent/token_estimator.dart';
import 'package:reveric/shared/models/ai_run_failure.dart';
import 'package:reveric/shared/localization/ai_run_failure_localization.dart';
import 'package:reveric/shared/services/ai/trace_reporter_service.dart';

/// A provider client that returns ThinkingDelta + TextDelta in its stream.
class _ThinkingFakeClient implements ProviderClient {
  _ThinkingFakeClient({
    this.text = 'answer',
    this.thinking = 'deep thoughts',
    this.signature,
    this.encryptedContents = const [],
  });

  final String text;
  final String thinking;
  final String? signature;
  final List<String> encryptedContents;
  final List<List<AgentMessage>> capturedMessages = [];

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
    capturedMessages.add(List.from(messages));
    yield ThinkingDelta(thinking);
    if (signature != null) {
      yield SignatureDelta(signature!);
    }
    for (final encryptedContent in encryptedContents) {
      yield EncryptedContentDelta(encryptedContent);
    }
    yield TextDelta(text);
    yield StreamComplete();
  }

  @override
  void cancel() {}
}

/// 模拟半开 SSE：请求订阅成功，但永远没有首事件、done 或 error。
class _NeverCompletingStreamClient implements ProviderClient {
  int calls = 0;
  int cancelCalls = 0;
  final List<StreamController<StreamEvent>> _controllers = [];

  @override
  Stream<StreamEvent> chatStream({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) {
    calls += 1;
    late final StreamController<StreamEvent> controller;
    controller = StreamController<StreamEvent>(
      onCancel: () {
        _controllers.remove(controller);
      },
    );
    _controllers.add(controller);
    return controller.stream;
  }

  Future<void> close() async {
    for (final controller in List.of(_controllers)) {
      await controller.close();
    }
    _controllers.clear();
  }

  @override
  Future<ChatResponse> chat({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) {
    throw UnimplementedError();
  }

  @override
  void cancel() {
    cancelCalls += 1;
  }
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
  List<String> allToolNames() => const [];

  @override
  List<ToolDef> allToolDefs() => const [];

  @override
  List<ToolDef> toolDefsForNames(List<String> names) => const [];
}

class _FailingToolDispatcher implements AgentToolDispatcher {
  const _FailingToolDispatcher();

  static const _tool = ToolDef(
    name: 'FailTool',
    description: 'Always returns an error for round-trip testing.',
    inputSchema: {'type': 'object'},
  );

  @override
  Future<Map<String, dynamic>> executeTool({
    required String name,
    required Map<String, dynamic> input,
    String? callId,
    bool emitEvents = true,
    ToolExecutionContext? context,
  }) async {
    return {'ok': false, 'error': 'intentional failure', 'input': input};
  }

  @override
  List<String> allToolNames() => const ['FailTool'];

  @override
  List<ToolDef> allToolDefs() => const [_tool];

  @override
  List<ToolDef> toolDefsForNames(List<String> names) =>
      names.contains('FailTool') ? const [_tool] : const [];
}

class _SlowToolDispatcher implements AgentToolDispatcher {
  _SlowToolDispatcher({
    required this.onExecute,
    this.result = const {
      'ok': false,
      'error': 'DioException [request cancelled]: aborted',
    },
  });

  final Future<void> Function() onExecute;
  final Map<String, dynamic> result;

  static const _tool = ToolDef(
    name: 'SlowTool',
    description: 'Simulates a long-running tool for cancel tests.',
    inputSchema: {'type': 'object'},
  );

  @override
  Future<Map<String, dynamic>> executeTool({
    required String name,
    required Map<String, dynamic> input,
    String? callId,
    bool emitEvents = true,
    ToolExecutionContext? context,
  }) async {
    await onExecute();
    return result;
  }

  @override
  List<String> allToolNames() => const ['SlowTool'];

  @override
  List<ToolDef> allToolDefs() => const [_tool];

  @override
  List<ToolDef> toolDefsForNames(List<String> names) =>
      names.contains('SlowTool') ? const [_tool] : const [];
}

class _ToolCallThenDoneClient implements ProviderClient {
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
    yield ToolCallDelta(
      callId: 'call_slow',
      toolName: 'SlowTool',
      arguments: const {},
    );
    yield StreamComplete();
  }

  @override
  void cancel() {}
}

class _ToolFailureRoundTripClient implements ProviderClient {
  final List<List<AgentMessage>> capturedMessages = [];
  int calls = 0;

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
    capturedMessages.add(List.from(messages));
    calls += 1;
    if (calls == 1) {
      yield ToolCallDelta(
        callId: 'call_1',
        toolName: 'FailTool',
        arguments: {'path': '/missing'},
      );
      yield StreamComplete();
      return;
    }
    yield TextDelta('handled failure');
    yield StreamComplete();
  }

  @override
  void cancel() {}
}

class _NestedAgentToolContextClient implements ProviderClient {
  final List<List<AgentMessage>> capturedMessages = [];

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
    capturedMessages.add(List.from(messages));
    final task = messages.last.content;
    if (task == 'use spawn') {
      yield ToolCallDelta(
        callId: 'call_spawn',
        toolName: 'SpawnAgent',
        arguments: const {'name': 'worker', 'task': 'child uses tool'},
      );
      yield StreamComplete();
      return;
    }
    if (task == 'use fork') {
      yield ToolCallDelta(
        callId: 'call_fork',
        toolName: 'ForkAgent',
        arguments: const {'task': 'fork uses tool'},
      );
      yield StreamComplete();
      return;
    }
    if (task == 'child uses tool' || task == 'fork uses tool') {
      yield ToolCallDelta(
        callId: 'call_nested_write',
        toolName: 'NestedWrite',
        arguments: const {'path': '/chapters/chapter_1/content'},
      );
      yield StreamComplete();
      return;
    }
    yield TextDelta('done');
    yield StreamComplete();
  }

  @override
  void cancel() {}
}

class _ContextCapturingToolDispatcher implements AgentToolDispatcher {
  final capturedContexts = <ToolExecutionContext?>[];

  static const _tool = ToolDef(
    name: 'NestedWrite',
    description: 'Captures the execution context.',
    inputSchema: {'type': 'object'},
  );

  @override
  Future<Map<String, dynamic>> executeTool({
    required String name,
    required Map<String, dynamic> input,
    String? callId,
    bool emitEvents = true,
    ToolExecutionContext? context,
  }) async {
    capturedContexts.add(context);
    return {'ok': true};
  }

  @override
  List<String> allToolNames() => const ['NestedWrite'];

  @override
  List<ToolDef> allToolDefs() => const [_tool];

  @override
  List<ToolDef> toolDefsForNames(List<String> names) =>
      names.contains('NestedWrite') ? const [_tool] : const [];
}

/// 一段 chatStream 脚本：先 yield [events]，若 [error] 非 null 则在最后抛出，
/// 用于模拟「已 emit 部分事件后中途断连」。
class _StreamScript {
  const _StreamScript({this.events = const [], this.error});
  final List<StreamEvent> events;
  final Object? error;
}

/// 按 [scripts] 顺序消费的 ProviderClient：每次 chatStream 取下一段脚本。
class _FlakyStreamClient implements ProviderClient {
  _FlakyStreamClient(this.scripts);
  final List<_StreamScript> scripts;
  int calls = 0;
  final List<List<AgentMessage>> capturedMessages = [];

  @override
  Stream<StreamEvent> chatStream({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async* {
    capturedMessages.add(List<AgentMessage>.from(messages));
    final script = scripts[calls];
    calls += 1;
    for (final event in script.events) {
      yield event;
    }
    final error = script.error;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<ChatResponse> chat({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async {
    throw UnimplementedError();
  }

  @override
  void cancel() {}
}

class _StatusCodeException implements Exception {
  const _StatusCodeException(this.statusCode, {this.message});
  final int statusCode;
  final String? message;
  @override
  String toString() => 'ApiException($statusCode): test';
}

/// 固定返回给定 [LLMErrorAction] 的 hook，用于覆盖内建 retry 策略。
class _ToolCallRecordingHook extends AgentHook {
  _ToolCallRecordingHook({this.block = false});
  final bool block;
  final before = <String>[];
  final after = <String>[];

  @override
  HookAction<BeforeToolCallContext> beforeToolCall(
    BeforeToolCallContext context,
  ) {
    before.add(context.call.toolName);
    return block
        ? HookAction.abort(AiRunFailure.requestFailed())
        : const HookAction.proceed();
  }

  @override
  HookAction<AfterToolCallContext> afterToolCall(AfterToolCallContext context) {
    after.add(context.call.toolName);
    return const HookAction.proceed();
  }
}

class _LLMErrorHook extends AgentHook {
  const _LLMErrorHook(this._action);
  final LLMErrorAction Function(Object error, int attempt) _action;
  @override
  FutureOr<LLMErrorAction> onLLMError(
    Object error,
    int attempt, {
    bool isStreamError = false,
  }) => _action(error, attempt);
}

/// 异步 onLLMError hook，用于模拟 hook await 期间发生 cancel 的竞态。
class _AsyncLLMErrorHook extends AgentHook {
  const _AsyncLLMErrorHook(this._action);
  final Future<LLMErrorAction> Function(Object error, int attempt) _action;
  @override
  Future<LLMErrorAction> onLLMError(
    Object error,
    int attempt, {
    bool isStreamError = false,
  }) => _action(error, attempt);
}

class _IncompleteResponseHook extends AgentHook {
  final List<bool> retryDecisions = [];
  Object? terminalError;

  @override
  void onIncompleteResponse(
    IncompleteModelResponseException error, {
    required bool willRetry,
  }) {
    retryDecisions.add(willRetry);
  }

  @override
  void onError(Object error, StackTrace? stackTrace) {
    terminalError = error;
  }
}

class _ThrowingEndHook extends AgentHook {
  @override
  Future<void> onEnd() async {
    throw StateError('telemetry database closed');
  }
}

class _ResultCaptureHook extends AgentHook {
  Map<String, dynamic>? result;
  @override
  HookAction<AfterToolCallContext> afterToolCall(AfterToolCallContext ctx) {
    result = ctx.result;
    return const HookAction.proceed();
  }
}

class _InboxBoundaryHook extends AgentHook {
  _InboxBoundaryHook(this.inbox);
  final AgentMessageInbox inbox;
  int doneChecks = 0;
  bool? lateAccepted;

  @override
  Future<HookAction<BeforeLLMContext>> beforeLLM(BeforeLLMContext ctx) async {
    if (doneChecks == 0) {
      await Future<void>.delayed(Duration.zero);
      expect(
        inbox.add(AgentMessage.user(id: 'during_prepare', content: '准备时追加')),
        isTrue,
      );
    }
    return const HookAction.proceed();
  }

  @override
  Future<void> beforeDone(BeforeDoneContext ctx) async {
    doneChecks++;
    if (doneChecks == 1) {
      await Future<void>.delayed(Duration.zero);
      expect(
        inbox.add(AgentMessage.user(id: 'during_finish', content: '结束前追加')),
        isTrue,
      );
    }
  }

  @override
  Future<void> onDone(String finalText) async {
    await Future<void>.delayed(Duration.zero);
    lateAccepted = inbox.add(AgentMessage.user(id: 'too_late', content: '已结束'));
  }
}

class _BeforeLLMCallbackHook extends AgentHook {
  _BeforeLLMCallbackHook(this.callback);

  final FutureOr<void> Function() callback;

  @override
  Future<HookAction<BeforeLLMContext>> beforeLLM(BeforeLLMContext ctx) async {
    await callback();
    return const HookAction.proceed();
  }
}

void main() {
  group('inbox compaction', () {
    for (final arrival in ['queued', 'beforeLLM', 'retry']) {
      test('checks appended input before sending: $arrival', () async {
        final inbox = AgentMessageInbox();
        final instruction = AgentMessage.user(
          id: 'additional_instruction',
          content: '新' * 310,
        );
        var delivered = false;
        void deliver() {
          if (!delivered) {
            expect(inbox.add(instruction), isTrue);
            delivered = true;
          }
        }

        var compactions = 0;
        final manager =
            SmartAgentContextManager(
                compactThreshold: 960,
                contextTokens: 1200,
                outputFloor: 1,
              )
              ..summarizer =
                  ({
                    required messages,
                    previousSummary,
                    cancellationToken,
                  }) async {
                    compactions++;
                    return 'summary';
                  };
        final client = FakeProviderClient(
          responder: (request) {
            if (arrival == 'retry' && request.callIndex == 0) {
              throw ClientException('Connection closed');
            }
            final tokens = estimateAgentMessagesTokens(request.messages);
            if (tokens > 1200) {
              throw StateError('maximum context length exceeded: $tokens');
            }
            return const FakeProviderClientResponse.text('done');
          },
        );
        final agent = Agent.custom(
          id: 'inbox_compaction',
          systemPrompt: 'test',
          client: client,
          config: const AgentConfig(maxTokens: 1),
          toolManager: FakeAgentToolDispatcher(),
          contextManager: manager,
          initialMessages: [
            AgentMessage.user(id: 'old_user', content: '旧' * 80),
            AgentMessage.assistant(id: 'old_answer', content: '文' * 870),
          ],
          hooks: [
            if (arrival == 'beforeLLM')
              _BeforeLLMCallbackHook(() async {
                await Future<void>.delayed(Duration.zero);
                deliver();
              }),
            if (arrival == 'retry')
              _LLMErrorHook((error, attempt) {
                deliver();
                return attempt == 1
                    ? const LLMErrorAction.retry(Duration.zero)
                    : const LLMErrorAction.abort(AiRunFailure.requestFailed());
              }),
          ],
        );
        if (arrival == 'queued') {
          deliver();
        }

        final events = await agent.process('继续', inbox: inbox).toList();

        expect(events.whereType<AgentError>(), isEmpty);
        expect(events.whereType<AgentDone>().single.finalText, 'done');
        expect(compactions, 1);
        expect(events.whereType<AgentCompactionEnd>().single.ok, isTrue);
        expect(events.whereType<AgentMessageStart>(), hasLength(1));
        expect(
          events.whereType<AgentRoundRetry>(),
          hasLength(arrival == 'retry' ? 1 : 0),
        );
        expect(
          client.capturedStreamRequests,
          hasLength(arrival == 'retry' ? 2 : 1),
        );
        final sent = client.capturedStreamRequests.last.messages;
        expect(estimateAgentMessagesTokens(sent), lessThanOrEqualTo(1200));
        expect(
          sent.where((m) => m.id == instruction.id).single.content,
          instruction.content,
        );
      });
    }

    test(
      'rechecks messages received during compaction in the same round',
      () async {
        final inbox = AgentMessageInbox();
        final instructions = [
          for (var i = 0; i < 3; i++)
            AgentMessage.user(id: 'during_compaction_$i', content: '新' * 310),
        ];
        var compactions = 0;
        final manager =
            SmartAgentContextManager(
                compactThreshold: 960,
                contextTokens: 1200,
                outputFloor: 1,
              )
              ..summarizer =
                  ({
                    required messages,
                    previousSummary,
                    cancellationToken,
                  }) async {
                    compactions++;
                    if (compactions == 1) {
                      await Future<void>.delayed(Duration.zero);
                      for (final instruction in instructions) {
                        expect(inbox.add(instruction), isTrue);
                      }
                    }
                    return 'summary';
                  };
        final client = FakeProviderClient(
          responder: (request) {
            final tokens = estimateAgentMessagesTokens(request.messages);
            if (tokens > 1200) {
              throw StateError('maximum context length exceeded: $tokens');
            }
            return const FakeProviderClientResponse.text('done');
          },
        );
        final agent = Agent.custom(
          id: 'inbox_during_compaction',
          systemPrompt: 'test',
          client: client,
          config: const AgentConfig(maxTokens: 1),
          toolManager: FakeAgentToolDispatcher(),
          contextManager: manager,
          initialMessages: [
            AgentMessage.user(id: 'old_user', content: '旧' * 80),
            AgentMessage.assistant(id: 'old_answer', content: '文' * 2000),
            AgentMessage.user(id: 'recent_user', content: '近' * 80),
            AgentMessage.assistant(id: 'recent_answer', content: '文' * 210),
          ],
        );

        final events = await agent.process('继续', inbox: inbox).toList();

        expect(events.whereType<AgentError>(), isEmpty);
        expect(events.whereType<AgentDone>().single.finalText, 'done');
        expect(compactions, 2);
        expect(events.whereType<AgentMessageStart>(), hasLength(1));
        expect(events.whereType<AgentRoundRetry>(), isEmpty);
        final sent = client.capturedStreamRequests.single.messages;
        expect(estimateAgentMessagesTokens(sent), lessThanOrEqualTo(1200));
        expect(
          sent.where((m) => m.id == instructions.last.id).single.content,
          instructions.last.content,
        );
      },
    );
  });

  test(
    'additional messages reach the next request across preparation and done boundaries',
    () async {
      final inbox = AgentMessageInbox();
      final hook = _InboxBoundaryHook(inbox);
      final client = FakeProviderClient(
        responses: const [
          FakeProviderClientResponse.text('initial'),
          FakeProviderClientResponse.text('updated'),
        ],
      );
      final agent = Agent.custom(
        id: 'child',
        systemPrompt: 'test',
        client: client,
        config: const AgentConfig(),
        toolManager: FakeAgentToolDispatcher(),
        hooks: [hook],
      );
      final events = await agent.process('task', inbox: inbox).toList();
      expect(client.capturedStreamRequests, hasLength(2));
      expect(
        client.capturedStreamRequests.first.messages.map((m) => m.id),
        contains('during_prepare'),
      );
      expect(
        client.capturedStreamRequests.last.messages.map((m) => m.id),
        contains('during_finish'),
      );
      expect(events.whereType<AgentDone>().single.finalText, 'updated');
      expect(hook.lateAccepted, isFalse);
      expect(
        inbox.add(AgentMessage.user(id: 'after', content: 'after')),
        isFalse,
      );
    },
  );

  group('Agent reasoning content round-trip', () {
    test('thinking delta stored as ThinkingBlock in context', () async {
      final client = _ThinkingFakeClient(
        thinking: 'step-by-step reasoning',
        text: 'final answer',
      );
      final ctxMgr = SimpleAgentContextManager();
      final agent = Agent.custom(
        id: 'test',
        systemPrompt: 'You are a helpful assistant.',
        client: client,
        config: const AgentConfig(),
        toolManager: const _FakeToolDispatcher(),
        contextManager: ctxMgr,
      );

      await agent.process('solve this').toList();

      final assistantMsgs = ctxMgr.messages
          .where((m) => m.role == AgentMessageRole.assistant)
          .toList();
      expect(assistantMsgs, hasLength(1));

      final msg = assistantMsgs.first;
      final thinkingBlocks = msg.blocks.whereType<ThinkingBlock>().toList();
      expect(thinkingBlocks, hasLength(1));
      expect(thinkingBlocks.first.text, 'step-by-step reasoning');
      expect(msg.content, 'final answer');
    });

    test(
      'thinking signature is stored with ThinkingBlock in context',
      () async {
        final client = _ThinkingFakeClient(
          thinking: 'signed reasoning',
          signature: 'sig123',
        );
        final ctxMgr = SimpleAgentContextManager();
        final agent = Agent.custom(
          id: 'test',
          systemPrompt: 'You are a helpful assistant.',
          client: client,
          config: const AgentConfig(),
          toolManager: const _FakeToolDispatcher(),
          contextManager: ctxMgr,
        );

        await agent.process('solve this').toList();

        final assistantMsg = ctxMgr.messages.singleWhere(
          (m) => m.role == AgentMessageRole.assistant,
        );
        final thinkingBlock = assistantMsg.blocks
            .whereType<ThinkingBlock>()
            .single;
        expect(thinkingBlock.text, 'signed reasoning');
        expect(thinkingBlock.signature, 'sig123');
      },
    );

    test(
      'signature-only thinking is stored with ThinkingBlock in context',
      () async {
        final client = _ThinkingFakeClient(thinking: '', signature: 'sig-only');
        final ctxMgr = SimpleAgentContextManager();
        final agent = Agent.custom(
          id: 'test',
          systemPrompt: 'You are a helpful assistant.',
          client: client,
          config: const AgentConfig(),
          toolManager: const _FakeToolDispatcher(),
          contextManager: ctxMgr,
        );

        await agent.process('solve this').toList();

        final assistantMsg = ctxMgr.messages.singleWhere(
          (m) => m.role == AgentMessageRole.assistant,
        );
        final thinkingBlock = assistantMsg.blocks
            .whereType<ThinkingBlock>()
            .single;
        expect(thinkingBlock.text, isEmpty);
        expect(thinkingBlock.signature, 'sig-only');
      },
    );

    test(
      'encrypted reasoning contents are stored with ThinkingBlock',
      () async {
        final client = _ThinkingFakeClient(
          encryptedContents: const ['enc_a', 'enc_b'],
        );
        final ctxMgr = SimpleAgentContextManager();
        final agent = Agent.custom(
          id: 'test',
          systemPrompt: 'You are a helpful assistant.',
          client: client,
          config: const AgentConfig(),
          toolManager: const _FakeToolDispatcher(),
          contextManager: ctxMgr,
        );

        await agent.process('solve this').toList();

        final assistantMsg = ctxMgr.messages.singleWhere(
          (message) => message.role == AgentMessageRole.assistant,
        );
        final thinkingBlock = assistantMsg.blocks
            .whereType<ThinkingBlock>()
            .single;
        expect(thinkingBlock.encryptedContents, ['enc_a', 'enc_b']);
      },
    );

    test(
      'encrypted reasoning contents become reasoning input items on the next Responses request',
      () async {
        final client = _ThinkingFakeClient(
          encryptedContents: const ['enc_a', 'enc_b'],
        );
        final ctxMgr = SimpleAgentContextManager();
        final agent = Agent.custom(
          id: 'test',
          systemPrompt: 'You are a helpful assistant.',
          client: client,
          config: const AgentConfig(),
          toolManager: const _FakeToolDispatcher(),
          contextManager: ctxMgr,
        );

        await agent.process('solve this').toList();

        final responsesClient = OpenAIResponsesClient(
          apiKey: 'sk-test',
          baseUrl: 'https://example.invalid',
          model: 'gpt-5',
        );
        final json = responsesClient
            .buildInputItems(ctxMgr.messages)
            .map((item) => item.toJson())
            .toList();
        final reasoningItems = json
            .where((item) => item['type'] == 'reasoning')
            .toList();

        expect(reasoningItems.map((item) => item['encrypted_content']), [
          'enc_a',
          'enc_b',
        ]);
        expect(
          json
              .where((item) => item['type'] == 'message')
              .expand((item) => (item['content'] as List).cast<Map>())
              .where((part) => part['type'] == 'reasoning_text'),
          isEmpty,
        );
      },
    );

    test('ThinkingBlock in context survives OpenAiClient conversion', () async {
      final client = _ThinkingFakeClient(
        thinking: 'reasoning trace',
        text: 'output',
      );
      final ctxMgr = SimpleAgentContextManager();
      final agent = Agent.custom(
        id: 'test',
        systemPrompt: 'Be helpful.',
        client: client,
        config: const AgentConfig(),
        toolManager: const _FakeToolDispatcher(),
        contextManager: ctxMgr,
      );

      await agent.process('hello').toList();

      final assistantMsgs = ctxMgr.messages
          .where((m) => m.role == AgentMessageRole.assistant)
          .toList();
      expect(assistantMsgs, hasLength(1));

      final openAi = OpenAiClient(
        apiKey: 'sk-test',
        baseUrl: 'https://example.invalid',
      );
      final converted = openAi.convertMessages([...ctxMgr.messages]);

      for (final msg in converted) {
        final json = msg.toJson();
        if (json['role'] == 'assistant') {
          expect(json['reasoning_content'], 'reasoning trace');
          expect(json['content'], 'output');
        }
      }
    });

    test('no thinking delta produces no ThinkingBlock', () async {
      final client = _ThinkingFakeClient(text: 'ok', thinking: '');
      final ctxMgr = SimpleAgentContextManager();
      final agent = Agent.custom(
        id: 'test',
        systemPrompt: 'Be helpful.',
        client: client,
        config: const AgentConfig(),
        toolManager: const _FakeToolDispatcher(),
        contextManager: ctxMgr,
      );

      await agent.process('hi').toList();

      final assistantMsgs = ctxMgr.messages
          .where((m) => m.role == AgentMessageRole.assistant)
          .toList();
      expect(assistantMsgs, hasLength(1));
      expect(
        assistantMsgs.first.blocks.whereType<ThinkingBlock>().toList(),
        isEmpty,
      );
    });
  });

  group('Agent user cancel', () {
    test(
      'in-flight tool result reports user cancelled, not API error',
      () async {
        final gate = Completer<void>();
        final ctxMgr = SimpleAgentContextManager();
        final agent = Agent.custom(
          id: 'test',
          systemPrompt: 'Be helpful.',
          client: _ToolCallThenDoneClient(),
          config: const AgentConfig(),
          toolManager: _SlowToolDispatcher(onExecute: () => gate.future),
          contextManager: ctxMgr,
        );

        final events = <AgentEvent>[];
        final processFuture = agent.process('run slow tool').listen(events.add);

        await Future<void>.delayed(const Duration(milliseconds: 20));
        agent.cancel();
        gate.complete();

        await processFuture.asFuture<void>();

        expect(events.whereType<AgentCancelled>(), isNotEmpty);
        expect(
          events.whereType<AgentToolCallResult>(),
          isEmpty,
          reason:
              'cancelled tools should surface as skipped, not error results',
        );

        final toolResultMessages = ctxMgr.messages
            .where((message) => message.type == AgentMessageType.tool_result)
            .toList();
        expect(toolResultMessages, hasLength(1));

        final block =
            toolResultMessages.single.blocks.single as ToolResultBlock;
        final payload =
            jsonDecode((block.content.single as TextBlock).text)
                as Map<String, dynamic>;
        expect(payload['cancelled'], isTrue);
        expect(payload['error_code'], 'user_cancelled');
        expect(payload['error'], 'User cancelled');
        expect(payload['error'], isNot(contains('DioException')));
      },
    );

    Future<(List<AgentEvent>, Map<String, dynamic>)> runCancelledTool(
      Map<String, dynamic> result,
    ) async {
      final gate = Completer<void>();
      final ctxMgr = SimpleAgentContextManager();
      final agent = Agent.custom(
        id: 'test',
        systemPrompt: 'Be helpful.',
        client: _ToolCallThenDoneClient(),
        config: const AgentConfig(),
        toolManager: _SlowToolDispatcher(
          onExecute: () => gate.future,
          result: result,
        ),
        contextManager: ctxMgr,
      );
      final events = <AgentEvent>[];
      final done = agent.process('run slow tool').listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      agent.cancel();
      gate.complete();
      await done.asFuture<void>();
      final block =
          ctxMgr.messages
                  .singleWhere(
                    (message) => message.type == AgentMessageType.tool_result,
                  )
                  .blocks
                  .single
              as ToolResultBlock;
      return (
        events,
        jsonDecode((block.content.single as TextBlock).text)
            as Map<String, dynamic>,
      );
    }

    test('successful result returned after cancel is kept as is', () async {
      final (events, payload) = await runCancelledTool({
        'ok': true,
        'updated': true,
        'id': 'written',
      });
      expect(events.whereType<AgentCancelled>(), isNotEmpty);
      expect(events.whereType<AgentToolCallResult>().single.output, payload);
      expect(payload['id'], 'written');
      expect(payload['cancelled'], isNull);
    });

    test(
      'self-reported cancellation keeps partial result on skipped event',
      () async {
        final (events, payload) = await runCancelledTool({
          'ok': false,
          'cancelled': true,
          'error_code': 'user_cancelled',
          'completed_operations': [
            {'call_id': 'written'},
          ],
        });
        final skipped = events.whereType<AgentToolSkipped>().single;
        expect(skipped.output, payload);
        expect(payload['completed_operations'], [
          {'call_id': 'written'},
        ]);
      },
    );
  });

  group('Agent.runToolCall', () {
    Agent build(_ToolCallRecordingHook hook, SimpleAgentContextManager ctx) =>
        Agent.custom(
          id: 'test',
          systemPrompt: 'Be helpful.',
          client: FakeProviderClient(),
          config: const AgentConfig(),
          toolManager: FakeAgentToolDispatcher.withResults(
            results: {
              'Read': {'ok': true, 'content': 'value'},
            },
          ),
          contextManager: ctx,
          hooks: [hook],
        );

    test('runs hooks once without touching history', () async {
      final hook = _ToolCallRecordingHook();
      final ctx = SimpleAgentContextManager();
      final result = await build(hook, ctx).runToolCall(
        const ToolCall(callId: 'child', toolName: 'Read', arguments: {}),
      );
      expect(result['content'], 'value');
      expect(hook.before, ['Read']);
      expect(hook.after, ['Read']);
      expect(ctx.messages, isEmpty);
    });

    test('blocked call returns an error result without dispatching', () async {
      final hook = _ToolCallRecordingHook(block: true);
      final result = await build(hook, SimpleAgentContextManager()).runToolCall(
        const ToolCall(callId: 'child', toolName: 'Read', arguments: {}),
      );
      expect(result['ok'], isFalse);
      expect(result['error_code'], 'hook_aborted');
      expect(hook.after, isEmpty);
    });
  });

  group('Agent tool result round-trip', () {
    test('model, events and hooks agree on legacy outcomes', () async {
      for (final scenario in <(Map<String, dynamic>, bool, bool)>[
        ({'updated': false}, true, false),
        (
          {
            'content': {'error': 'body', 'ok': false},
          },
          true,
          false,
        ),
        ({'ok': false}, false, false),
        (
          {
            'ok': false,
            'error': 'Sub-agent failed',
            'error_code': 'spawn_agent_failed',
            'session_id': 'child',
            '_metadata': {'sub_agent_model': 'test-model'},
          },
          false,
          false,
        ),
        ({'ok': true, 'error': 'failed'}, false, false),
        ({'cancelled': true}, false, true),
        ({'skipped': true}, false, true),
      ]) {
        final client = _ToolFailureRoundTripClient();
        final hook = _ResultCaptureHook();
        final agent = Agent.custom(
          id: 'outcome',
          systemPrompt: 'Test',
          client: client,
          config: const AgentConfig(),
          toolManager: FakeAgentToolDispatcher.withResults(
            results: {'FailTool': scenario.$1},
          ),
          contextManager: SimpleAgentContextManager(),
          hooks: [hook],
        );
        final events = await agent.process('call tool').toList();
        final block = client.capturedMessages.last
            .expand((message) => message.blocks)
            .whereType<ToolResultBlock>()
            .single;
        final payload =
            jsonDecode((block.content.single as TextBlock).text) as Map;
        expect(block.isError, !scenario.$2);
        expect(payload['ok'], scenario.$2);
        expect(hook.result!['ok'], scenario.$2);
        if (scenario.$3) {
          expect(events.whereType<AgentToolSkipped>(), hasLength(1));
          expect(events.whereType<AgentToolCallResult>(), isEmpty);
        } else {
          final event = events.whereType<AgentToolCallResult>().single;
          expect(event.errorMessage == null, scenario.$2);
          expect(event.output, payload);
          expect(event.metadata, scenario.$1['_metadata']);
          expect(payload.containsKey('_metadata'), isFalse);
        }
      }
    });

    test('failed tool result is sent to the next LLM round', () async {
      final client = _ToolFailureRoundTripClient();
      final ctxMgr = SimpleAgentContextManager();
      final agent = Agent.custom(
        id: 'test',
        systemPrompt: 'Be helpful.',
        client: client,
        config: const AgentConfig(),
        toolManager: const _FailingToolDispatcher(),
        contextManager: ctxMgr,
      );

      await agent.process('call the tool').toList();

      expect(client.capturedMessages, hasLength(2));
      final secondRoundMessages = client.capturedMessages[1];
      final toolResultMessages = secondRoundMessages
          .where((message) => message.type == AgentMessageType.tool_result)
          .toList();
      expect(toolResultMessages, hasLength(1));

      final block = toolResultMessages.single.blocks.single as ToolResultBlock;
      expect(block.toolCallId, 'call_1');
      expect(block.toolName, 'FailTool');
      expect(block.isError, isTrue);

      final text = (block.content.single as TextBlock).text;
      final payload = jsonDecode(text) as Map<String, dynamic>;
      expect(payload['ok'], isFalse);
      expect(payload['error'], 'intentional failure');
    });

    test(
      'message ids are unique across independent runs of the same agent',
      () async {
        Future<List<String>> runAgent() async {
          final ctxMgr = SimpleAgentContextManager();
          final agent = Agent.custom(
            id: 'reused_subagent',
            systemPrompt: 'Be helpful.',
            client: _ToolFailureRoundTripClient(),
            config: const AgentConfig(),
            toolManager: const _FailingToolDispatcher(),
            contextManager: ctxMgr,
          );

          await agent.process('call the tool').toList();

          return ctxMgr.messages.map((message) => message.id).toList();
        }

        final firstRunIds = await runAgent();
        final secondRunIds = await runAgent();

        expect(firstRunIds.toSet().intersection(secondRunIds.toSet()), isEmpty);
      },
    );

    test('SpawnAgent inherits parent tool execution context', () async {
      final client = _NestedAgentToolContextClient();
      final dispatcher = _ContextCapturingToolDispatcher();
      final agent = Agent.custom(
        id: 'test',
        systemPrompt: 'Be helpful.',
        client: client,
        config: const AgentConfig(),
        toolManager: dispatcher,
      );
      final context = ToolExecutionContext(
        sourceSessionId: 'session_1',
        sourceTurnId: 'turn_1',
      );

      await agent.process('use spawn', toolExecutionContext: context).toList();

      expect(dispatcher.capturedContexts, [same(context)]);
    });

    test('ForkAgent inherits parent tool execution context', () async {
      final client = _NestedAgentToolContextClient();
      final dispatcher = _ContextCapturingToolDispatcher();
      final agent = Agent.custom(
        id: 'test',
        systemPrompt: 'Be helpful.',
        client: client,
        config: const AgentConfig(),
        toolManager: dispatcher,
      );
      final context = ToolExecutionContext(
        sourceSessionId: 'session_1',
        sourceTurnId: 'turn_1',
      );

      await agent.process('use fork', toolExecutionContext: context).toList();

      expect(dispatcher.capturedContexts, [same(context)]);
    });
  });

  group('Agent stream retry', () {
    Agent build(
      ProviderClient client, {
      List<AgentHook> hooks = const [],
      AgentToolDispatcher? toolManager,
      AgentContextManager? ctxMgr,
      String? providerId,
      Duration streamInactivityTimeout = defaultAgentStreamInactivityTimeout,
    }) {
      return Agent.custom(
        id: 'test',
        systemPrompt: 'Be helpful.',
        client: client,
        providerId: providerId,
        config: const AgentConfig(),
        toolManager: toolManager ?? const _FakeToolDispatcher(),
        contextManager: ctxMgr ?? SimpleAgentContextManager(),
        hooks: hooks,
        streamInactivityTimeout: streamInactivityTimeout,
      );
    }

    for (final hasPartialOutput in [false, true]) {
      test(
        'StreamException retries with partial output=$hasPartialOutput',
        () async {
          final client = _FlakyStreamClient([
            _StreamScript(
              events: hasPartialOutput
                  ? [
                      TextDelta('discard this'),
                      ToolCallDelta(
                        callId: 'failed_call',
                        toolName: 'T',
                        arguments: const {},
                      ),
                    ]
                  : [],
              error: const openai.StreamException(
                message: 'opaque provider failure',
              ),
            ),
            _StreamScript(events: [TextDelta('full'), StreamComplete()]),
          ]);
          final dispatcher = FakeAgentToolDispatcher();
          final events = await build(
            client,
            toolManager: dispatcher,
          ).process('hi').toList();

          expect(client.calls, 2);
          expect(events.whereType<AgentRoundRetry>(), hasLength(1));
          expect(events.whereType<AgentMessageStart>(), hasLength(1));
          expect(events.whereType<AgentError>(), isEmpty);
          expect(events.whereType<AgentDone>().single.finalText, 'full');
          expect(dispatcher.capturedCalls, isEmpty);
          expect(
            client.capturedMessages[1].map(
              (message) => (message.role, message.content),
            ),
            client.capturedMessages[0].map(
              (message) => (message.role, message.content),
            ),
          );
        },
      );
    }

    test(
      'StreamException stops after retry exhaustion before first event',
      () async {
        final client = _FlakyStreamClient(
          List.generate(
            maxStreamRetries + 1,
            (_) => const _StreamScript(
              error: openai.StreamException(message: 'opaque provider failure'),
            ),
          ),
        );
        final events = await build(client).process('hi').toList();

        expect(client.calls, maxStreamRetries + 1);
        expect(
          events.whereType<AgentRoundRetry>(),
          hasLength(maxStreamRetries),
        );
        expect(events.whereType<AgentDone>(), isEmpty);
        expect(
          events.whereType<AgentError>().single.failure.kind,
          AiRunFailureKind.streamInterrupted,
        );
      },
    );

    test('StreamException does not retry after cancellation', () async {
      final client = _FlakyStreamClient([
        const _StreamScript(
          error: openai.StreamException(message: 'opaque provider failure'),
        ),
        _StreamScript(events: [TextDelta('full'), StreamComplete()]),
      ]);
      late Agent agent;
      agent = build(
        client,
        hooks: [
          _LLMErrorHook((_, _) {
            agent.cancel();
            return const LLMErrorAction.proceed();
          }),
        ],
      );
      final events = await agent.process('hi').toList();

      expect(client.calls, 1);
      expect(events.whereType<AgentRoundRetry>(), isEmpty);
      expect(events.whereType<AgentCancelled>(), hasLength(1));
      expect(events.whereType<AgentError>(), isEmpty);
      expect(events.whereType<AgentDone>(), isEmpty);
    });

    test(
      'mid-stream transient error then success retries and completes',
      () async {
        final client = _FlakyStreamClient([
          _StreamScript(
            events: [TextDelta('partial')],
            error: ClientException('Connection closed while receiving data'),
          ),
          _StreamScript(events: [TextDelta('full'), StreamComplete()]),
        ]);
        final agent = build(client);

        final events = await agent.process('hi').toList();

        expect(client.calls, 2);
        expect(events.whereType<AgentRoundRetry>(), hasLength(1));
        expect(events.whereType<AgentRoundRetry>().single.attempt, 1);
        expect(events.whereType<AgentDone>().single.finalText, 'full');
      },
    );

    test(
      'thinking-only completion gets one continuation before succeeding',
      () async {
        final client = _FlakyStreamClient([
          _StreamScript(
            events: [
              ThinkingDelta('long reasoning'),
              StreamComplete(finishReason: StreamFinishReason.length),
            ],
          ),
          _StreamScript(
            events: [
              TextDelta('final answer'),
              StreamComplete(finishReason: StreamFinishReason.stop),
            ],
          ),
        ]);
        final agent = build(client);

        final events = await agent.process('finish the task').toList();

        expect(client.calls, 2);
        expect(events.whereType<AgentMessageStart>(), hasLength(2));
        expect(events.whereType<AgentMessageEnd>(), hasLength(1));
        expect(events.whereType<AgentError>(), isEmpty);
        expect(events.whereType<AgentDone>().single.finalText, 'final answer');
        expect(
          client.capturedMessages[1].map((message) => message.content),
          contains(thinkingOnlyContinuationRemind),
        );
        expect(
          client.capturedMessages[1].map((message) => message.role),
          containsAllInOrder([
            AgentMessageRole.assistant,
            AgentMessageRole.user,
          ]),
        );
      },
    );

    test(
      'truncated tool call continues instead of forcing a manual resend',
      () async {
        // 线上 tool_call_incomplete：模型撞输出上限，最后一个 tool call 只收到
        // 半截参数。重试同一请求会在同一处再截断，用户只会看到「请点击发送重试」。
        final client = _FlakyStreamClient([
          _StreamScript(
            events: [
              TextDelta('先写了一段'),
              ToolCallDelta(
                callId: 'toolu_partial',
                toolName: 'Create',
                arguments: const {'path': '/chapters'},
                isPartial: true,
              ),
              StreamComplete(finishReason: StreamFinishReason.length),
            ],
          ),
          _StreamScript(
            events: [
              TextDelta('继续并完成'),
              StreamComplete(finishReason: StreamFinishReason.stop),
            ],
          ),
        ]);
        final agent = build(client);

        final events = await agent.process('写一章').toList();

        // 自动续跑，而不是抛错让用户手动重发。
        expect(client.calls, 2);
        expect(events.whereType<AgentError>(), isEmpty);
        // 截断正文先收口再开下一轮，不复用同一条气泡。
        expect(events.whereType<AgentMessageEnd>(), hasLength(2));
        expect(events.whereType<AgentDone>().single.finalText, '先写了一段继续并完成');
        expect(
          client.capturedMessages[1].any(
            (message) =>
                message.role == AgentMessageRole.assistant &&
                message.content == '先写了一段',
          ),
          isTrue,
        );
        expect(
          client.capturedMessages[1].last.content,
          incompleteToolCallContinuationRemind,
        );
        expect(client.capturedMessages[1].last.role, AgentMessageRole.user);
        // 半截参数不能被执行。
        expect(events.whereType<AgentToolCallStart>(), isEmpty);
        // 上层要收到通知才能把已渲染的 partial 卡片标成 incomplete。
        expect(events.whereType<AgentToolCallIncomplete>(), hasLength(1));
      },
    );

    test(
      'truncated text prefix is dropped once the continuation round completes',
      () async {
        // 截断续写用一个累积 buffer 拼接正文。它必须在续写收口的那一轮清空：
        // 否则前缀会一直挂在后续每一轮的 lastText 前面，AgentDone.finalText
        // 混进早已完成的旧正文（落库与 orchestrator 解析都读这个字段）。
        final client = _FlakyStreamClient([
          // 第 1 轮：撞输出上限，只写了一半。
          _StreamScript(
            events: [
              TextDelta('上半段'),
              StreamComplete(finishReason: StreamFinishReason.length),
            ],
          ),
          // 第 2 轮：补完正文，同时发起一次 tool call —— 截断续写在此收口。
          _StreamScript(
            events: [
              TextDelta('下半段'),
              ToolCallDelta(
                callId: 'toolu_ok',
                toolName: 'Read',
                arguments: const {'path': '/chapters'},
              ),
              StreamComplete(finishReason: StreamFinishReason.stop),
            ],
          ),
          // 第 3 轮：拿到 tool 结果后的最终回答，与前两轮正文无关。
          _StreamScript(
            events: [
              TextDelta('工具之后的最终回答'),
              StreamComplete(finishReason: StreamFinishReason.stop),
            ],
          ),
        ]);
        final agent = build(client);

        final events = await agent.process('写一章').toList();

        expect(client.calls, 3);
        expect(events.whereType<AgentError>(), isEmpty);
        expect(
          client.capturedMessages[1].last.content,
          truncatedResponseContinuationRemind,
        );
        // 第 2 轮的续写仍然要拼上前缀。
        expect(events.whereType<AgentRoundText>().map((e) => e.text), [
          '上半段',
          '下半段',
          '工具之后的最终回答',
        ]);
        // 第 3 轮已经是独立的一轮，不能再带上早已收口的「上半段」。
        expect(events.whereType<AgentDone>().single.finalText, '工具之后的最终回答');
      },
    );

    test(
      'thinking-only rounds keep going and only fail once the backstop trips',
      () async {
        // 旧行为是「补救 1 次仍无正文就报错」，用户会看到「请点击发送重试」。
        // 现在 thinking-only 当作正常轮次持续推进，只有连续 maxThinkingOnlyRounds
        // 轮都没有实质产出才判定模型陷住。
        final hook = _IncompleteResponseHook();
        final client = _FlakyStreamClient(
          List.generate(
            maxThinkingOnlyRounds + 1,
            (index) => _StreamScript(
              events: [
                ThinkingDelta('reasoning $index'),
                StreamComplete(finishReason: StreamFinishReason.length),
              ],
            ),
          ),
        );
        final agent = build(client, hooks: [hook]);

        final events = await agent.process('finish the task').toList();

        expect(client.calls, maxThinkingOnlyRounds);
        expect(events.whereType<AgentDone>(), isEmpty);
        expect(
          events.whereType<AgentError>().single.failure.kind,
          AiRunFailureKind.incompleteResponse,
        );
        // 前 maxThinkingOnlyRounds-1 轮都继续，第 maxThinkingOnlyRounds 轮终态。
        expect(hook.retryDecisions, [
          ...List.filled(maxThinkingOnlyRounds - 1, true),
          false,
        ]);
        final terminal = hook.terminalError;
        expect(terminal, isA<IncompleteModelResponseException>());
        // 上报要能区分「第一轮就失败」与「续跑多轮仍未产出」。
        expect(
          (terminal as IncompleteModelResponseException).thinkingOnlyRounds,
          maxThinkingOnlyRounds,
        );
        // 每一轮 thinking-only 后续跑请求都以隐藏 user remind 收尾，避免连续 assistant。
        for (var index = 1; index < client.capturedMessages.length; index++) {
          expect(
            client.capturedMessages[index].last.content,
            thinkingOnlyContinuationRemind,
          );
          expect(
            client.capturedMessages[index].last.role,
            AgentMessageRole.user,
          );
        }
      },
    );

    test(
      'truncated text rounds stop once the continuation backstop trips',
      () async {
        final client = _FlakyStreamClient(
          List.generate(
            maxTruncatedResponseRounds + 1,
            (_) => _StreamScript(
              events: [
                TextDelta('partial'),
                StreamComplete(finishReason: StreamFinishReason.length),
              ],
            ),
          ),
        );
        final agent = build(client);

        final events = await agent.process('finish the task').toList();

        expect(client.calls, maxTruncatedResponseRounds);
        expect(events.whereType<AgentDone>(), isEmpty);
        expect(
          events.whereType<AgentError>().single.failure.kind,
          AiRunFailureKind.incompleteResponse,
        );
      },
    );

    test(
      'terminal empty response leaves no assistant history behind',
      () async {
        // 全空响应现在走 attempt 重试（原样重发），耗尽后终态。
        // 不变量：空输出不能变成 assistant 历史条目。
        final context = SimpleAgentContextManager();
        final client = _FlakyStreamClient(
          List.generate(
            maxStreamRetries + 1,
            (_) => _StreamScript(events: [StreamComplete()]),
          ),
        );
        final agent = build(client, ctxMgr: context);

        await agent.process('finish the task').toList();

        expect(client.calls, maxStreamRetries + 1);
        expect(context.messages, hasLength(1));
        expect(context.messages.single.role, AgentMessageRole.user);
        expect(context.messages.single.content, 'finish the task');
      },
    );

    test(
      'empty response retries verbatim and succeeds without extra history',
      () async {
        final context = SimpleAgentContextManager();
        final client = _FlakyStreamClient([
          _StreamScript(events: [StreamComplete()]),
          _StreamScript(
            events: [
              TextDelta('final answer'),
              StreamComplete(finishReason: StreamFinishReason.stop),
            ],
          ),
        ]);
        final agent = build(client, ctxMgr: context);

        await agent.process('finish the task').toList();

        expect(client.calls, 2);
        // 原样重发：重试请求与首次完全一致，不追加任何指令，前缀不变才能命中
        // prompt 缓存。
        expect(
          client.capturedMessages[1].map((m) => '${m.role}:${m.content}'),
          client.capturedMessages[0].map((m) => '${m.role}:${m.content}'),
        );
        expect(
          client.capturedMessages[1].where(
            (message) => message.role == AgentMessageRole.assistant,
          ),
          isEmpty,
          reason:
              'empty model output must not become an assistant history item',
        );
        expect(context.messages, hasLength(2));
        expect(context.messages.map((message) => message.role), [
          AgentMessageRole.user,
          AgentMessageRole.assistant,
        ]);
      },
    );

    test(
      'thinking-only continuation keeps compaction state instead of rolling back',
      () async {
        // 旧实现会把续跑窗口内的压缩整体回滚。现在 thinking-only 是正常轮次，
        // 不存在「回滚到 incomplete 之前」——已产出的 thinking 与压缩都保留，
        // 否则界面会空一片、旧历史也会从后续请求里丢失。
        var summarizeCalls = 0;
        final smart =
            SmartAgentContextManager(
                inner: SimpleAgentContextManager(
                  initialMessages: [
                    AgentMessage.user(id: 'old_u', content: 'old request'),
                    AgentMessage.assistant(id: 'old_a', content: 'old answer'),
                  ],
                ),
                compactThreshold: 1,
              )
              ..summarizer =
                  ({
                    required messages,
                    previousSummary,
                    cancellationToken,
                  }) async => 'summary ${++summarizeCalls}';
        final client = _FlakyStreamClient([
          _StreamScript(
            events: [
              ThinkingDelta('reasoning'),
              StreamComplete(finishReason: StreamFinishReason.length),
            ],
          ),
          _StreamScript(
            events: [
              TextDelta('final answer'),
              StreamComplete(finishReason: StreamFinishReason.stop),
            ],
          ),
        ]);
        final agent = build(client, ctxMgr: smart);

        await agent.process('finish the task').toList();

        expect(client.calls, 2);
        // thinking-only 那轮写入了 assistant 自述，模型下一轮能看到「上一轮在思考」。
        expect(
          client.capturedMessages[1].any(
            (message) =>
                message.role == AgentMessageRole.assistant &&
                message.content == thinkingOnlyContinuationMessage,
          ),
          isTrue,
        );
        expect(
          client.capturedMessages[1].any(
            (message) => message.content == thinkingOnlyContinuationRemind,
          ),
          isTrue,
        );
        final built = await smart.buildMessages();
        expect(built.first.type, AgentMessageType.compact_summary);
      },
    );

    test(
      'retry does not increment roundIndex or resend AgentMessageStart',
      () async {
        final client = _FlakyStreamClient([
          _StreamScript(
            events: [TextDelta('partial')],
            error: ClientException('Connection closed'),
          ),
          _StreamScript(events: [TextDelta('full'), StreamComplete()]),
        ]);
        final ctxMgr = SimpleAgentContextManager();
        final agent = build(client, ctxMgr: ctxMgr);

        final events = await agent.process('hi').toList();

        expect(events.whereType<AgentMessageStart>(), hasLength(1));
        expect(ctxMgr.roundIndex, 1);
      },
    );

    test('failed attempt partial text is not written into context', () async {
      final client = _FlakyStreamClient([
        _StreamScript(
          events: [TextDelta('partial')],
          error: ClientException('Connection closed'),
        ),
        _StreamScript(events: [TextDelta('full'), StreamComplete()]),
      ]);
      final agent = build(client);

      await agent.process('hi').toList();

      // 第二次尝试的消息只含 system + user task，不含失败 attempt 的 'partial'。
      expect(client.calls, 2);
      final secondAttemptMessages = client.capturedMessages[1];
      expect(
        secondAttemptMessages.any((m) => m.content.contains('partial')),
        isFalse,
      );
    });

    test('exhausting retries yields friendly AgentError', () async {
      final client = _FlakyStreamClient(
        List.generate(
          maxStreamRetries + 1,
          (_) => _StreamScript(error: ClientException('Connection closed')),
        ),
      );
      final agent = build(client);

      final events = await agent.process('hi').toList();

      expect(client.calls, maxStreamRetries + 1);
      expect(events.whereType<AgentRoundRetry>(), hasLength(maxStreamRetries));
      expect(events.whereType<AgentDone>(), isEmpty);
      expect(
        events.whereType<AgentError>().single.failure.kind,
        AiRunFailureKind.network,
      );
    });

    test(
      'silent provider stream times out instead of leaving the round pending',
      () async {
        final client = _NeverCompletingStreamClient();
        addTearDown(client.close);
        final agent = build(
          client,
          streamInactivityTimeout: const Duration(milliseconds: 10),
        );

        // 退避是真实延时：maxStreamRetries=4 时累计 600+1200+2400+4800≈9s，
        // 上限必须留在它之上，否则失败的是这里的 timeout 而不是被测行为。
        final events = await agent
            .process('large history request')
            .toList()
            .timeout(const Duration(seconds: 30));

        expect(client.calls, maxStreamRetries + 1);
        expect(client.cancelCalls, maxStreamRetries + 1);
        expect(events.whereType<AgentMessageStart>(), hasLength(1));
        expect(
          events.whereType<AgentRoundRetry>(),
          hasLength(maxStreamRetries),
        );
        expect(events.whereType<AgentDone>(), isEmpty);
        expect(events.whereType<AgentError>(), hasLength(1));
        expect(events.whereType<AgentEnd>(), hasLength(1));
      },
    );

    test(
      'model not found reaches localized output through AgentError',
      () async {
        final client = _FlakyStreamClient([
          _StreamScript(
            error: const _StatusCodeException(
              422,
              message: '{"error":{"message":"model not found: example-model"}}',
            ),
          ),
        ]);
        final events = await build(
          client,
          providerId: 'custom',
        ).process('hi').toList();
        final failure = events.whereType<AgentError>().single.failure;
        expect(failure.providerMessage, 'model not found: example-model');
        expect(
          localizeAiRunFailure(failure, (key) => key),
          'ai.model_not_found',
        );
        expect(failure.statusCode, 422);
        expect(client.calls, 1);
        expect(events.whereType<AgentRoundRetry>(), isEmpty);
      },
    );

    test('401 preserves status and provider without retry', () async {
      final client = _FlakyStreamClient([
        _StreamScript(
          error: const _StatusCodeException(
            401,
            message: 'Provider key expired',
          ),
        ),
      ]);
      final agent = build(client, providerId: 'provider_parent');

      final events = await agent.process('hi').toList();

      expect(client.calls, 1);
      expect(events.whereType<AgentRoundRetry>(), isEmpty);
      final failure = events.whereType<AgentError>().single.failure;
      expect(failure.kind, AiRunFailureKind.http);
      expect(failure.statusCode, 401);
      expect(failure.providerId, 'provider_parent');
      expect(failure.providerMessage, 'Provider key expired');
    });

    test(
      'context limit codes produce a specific failure without retry',
      () async {
        final errors = <Object>[
          const openai.ApiException(
            statusCode: 400,
            message: 'Request rejected',
            code: 'context_length_exceeded',
          ),
          const openai.ApiException(
            statusCode: 400,
            message: 'Request rejected',
            type: 'context_length_exceeded',
          ),
          const openai.ApiException(
            statusCode: 400,
            message: 'Request rejected',
            body: {
              'error': {'code': 'context_length_exceeded'},
            },
          ),
          // 生产中的网关把整个 JSON 错误体保留在 SDK message 内。
          const _StatusCodeException(
            400,
            message:
                '{"error":{"message":"Maximum context length exceeded",'
                '"code":400},"error_type":"context_length_exceeded"}',
          ),
          const _StatusCodeException(
            400,
            message: '{"error":{"type":"context_length_exceeded"}}',
          ),
        ];
        for (final error in errors) {
          final client = _FlakyStreamClient([_StreamScript(error: error)]);
          final events = await build(
            client,
            providerId: 'custom',
          ).process('hi').toList();
          final failure = events.whereType<AgentError>().single.failure;
          expect(failure.kind, AiRunFailureKind.contextWindowExhausted);
          expect(failure.providerId, 'custom');
          expect(
            localizeAiRunFailure(failure, (key) => key),
            'ai.context_window_exhausted',
          );
          expect(classifyRequestError(error), 'context_length_exceeded');
          expect(
            shouldReportRequestError(classifyRequestError(error)),
            isFalse,
          );
          expect(client.calls, 1);
          expect(events.whereType<AgentRoundRetry>(), isEmpty);
        }
      },
    );

    test(
      'ordinary 400 and 413 are not inferred as context exhaustion',
      () async {
        final errors = <Object>[
          const _StatusCodeException(400, message: 'Invalid tool arguments'),
          const _StatusCodeException(
            400,
            message: 'Text mentions context_length_exceeded',
          ),
          const _StatusCodeException(
            400,
            message: '{"message":"context_length_exceeded"}',
          ),
          const _StatusCodeException(
            400,
            message: '{"error_type":"context_length_exceeded"',
          ),
          const openai.ApiException(
            statusCode: 413,
            message: 'Request too large',
          ),
        ];
        for (final error in errors) {
          final client = _FlakyStreamClient([_StreamScript(error: error)]);
          final events = await build(client).process('hi').toList();
          final failure = events.whereType<AgentError>().single.failure;
          expect(failure.kind, AiRunFailureKind.http);
          expect(failure.statusCode, tryReadStatusCode(error));
          expect(
            classifyRequestError(error),
            'http_${tryReadStatusCode(error)}',
          );
          expect(client.calls, 1);
          expect(events.whereType<AgentRoundRetry>(), isEmpty);
        }
      },
    );

    test('410 preserves provider message without retry', () async {
      final client = _FlakyStreamClient([
        _StreamScript(
          error: const _StatusCodeException(
            410,
            message: 'This model has been retired',
          ),
        ),
      ]);
      final events = await build(
        client,
        providerId: 'custom',
      ).process('hi').toList();
      expect(client.calls, 1);
      final failure = events.whereType<AgentError>().single.failure;
      expect(failure.statusCode, 410);
      expect(failure.providerMessage, 'This model has been retired');
      expect(failure.providerId, 'custom');
    });

    test(
      'provider codes survive the agent failure boundary without changing retries',
      () async {
        final client = _FlakyStreamClient([
          _StreamScript(
            error: const openai.AuthenticationException(
              message: 'Request failed',
              code: 'InvalidAccountStatus',
            ),
          ),
        ]);
        final events = await build(
          client,
          providerId: 'custom',
        ).process('hi').toList();
        final failure = events.whereType<AgentError>().single.failure;
        expect(failure.providerCode, 'InvalidAccountStatus');
        expect(failure.statusCode, 401);
        expect(client.calls, 1);
        expect(AiRunFailure.fromJson(failure.toJson()), failure);
      },
    );

    test(
      'provider 429 returns a rate-limit failure without retrying',
      () async {
        final client = _FlakyStreamClient([
          _StreamScript(error: const _StatusCodeException(429)),
          _StreamScript(events: [TextDelta('ok'), StreamComplete()]),
        ]);
        final agent = build(client, providerId: 'provider_child');

        final events = await agent.process('hi').toList();

        expect(client.calls, 1);
        expect(events.whereType<AgentRoundRetry>(), isEmpty);
        expect(events.whereType<AgentDone>(), isEmpty);
        final failure = events.whereType<AgentError>().single.failure;
        expect(failure.kind, AiRunFailureKind.http);
        expect(failure.statusCode, 429);
      },
    );

    test('onEnd hook failure does not replace the Agent result', () async {
      final client = _FlakyStreamClient([
        _StreamScript(events: [TextDelta('done'), StreamComplete()]),
      ]);
      final agent = build(client, hooks: [_ThrowingEndHook()]);

      final events = await agent.process('hi').toList();

      expect(events.whereType<AgentDone>().single.finalText, 'done');
      expect(events.whereType<AgentEnd>(), hasLength(1));
    });

    test('500 yields server error after retry exhaustion', () async {
      final client = _FlakyStreamClient(
        List.generate(
          maxStreamRetries + 1,
          (_) => _StreamScript(error: const _StatusCodeException(502)),
        ),
      );
      final agent = build(client);

      final events = await agent.process('hi').toList();

      expect(client.calls, maxStreamRetries + 1);
      expect(events.whereType<AgentRoundRetry>(), hasLength(maxStreamRetries));
      expect(events.whereType<AgentDone>(), isEmpty);
      final failure = events.whereType<AgentError>().single.failure;
      expect(failure.kind, AiRunFailureKind.http);
      expect(failure.statusCode, 502);
    });

    test('hook abort prevents retry', () async {
      final client = _FlakyStreamClient([
        _StreamScript(
          events: [TextDelta('partial')],
          error: ClientException('Connection closed'),
        ),
      ]);
      final agent = build(
        client,
        hooks: [
          _LLMErrorHook(
            (_, _) => const LLMErrorAction.abort(AiRunFailure.requestFailed()),
          ),
        ],
      );

      final events = await agent.process('hi').toList();

      expect(client.calls, 1);
      expect(events.whereType<AgentRoundRetry>(), isEmpty);
      expect(
        events.whereType<AgentError>().single.failure.kind,
        AiRunFailureKind.requestFailed,
      );
    });

    test('hook retry overrides built-in strategy and does not crash', () async {
      // 非瞬时 StateError：内建策略不会重试，但 hook retry 覆盖。
      final client = _FlakyStreamClient([
        _StreamScript(
          events: [TextDelta('partial')],
          error: StateError('boom'),
        ),
        _StreamScript(events: [TextDelta('full'), StreamComplete()]),
      ]);
      final agent = build(
        client,
        hooks: [
          _LLMErrorHook((_, _) => const LLMErrorAction.retry(Duration.zero)),
        ],
      );

      final events = await agent.process('hi').toList();

      expect(client.calls, 2);
      expect(events.whereType<AgentRoundRetry>(), hasLength(1));
      expect(events.whereType<AgentDone>().single.finalText, 'full');
      // 原缺陷：retry 分支缺 continue → 访问未赋值的 late round →
      // LateInitializationError。能正常完成即证明已修复。
    });

    test('cancel during retry delay does not retry again', () async {
      final client = _FlakyStreamClient([
        _StreamScript(
          events: [TextDelta('partial')],
          error: ClientException('Connection closed'),
        ),
        _StreamScript(events: [TextDelta('full'), StreamComplete()]),
      ]);
      final agent = build(
        client,
        hooks: [
          _LLMErrorHook(
            (_, _) => const LLMErrorAction.retry(Duration(milliseconds: 50)),
          ),
        ],
      );

      final events = <AgentEvent>[];
      final completer = Completer<void>();
      final sub = agent.process('hi').listen((event) {
        events.add(event);
        if (event is AgentRoundRetry) {
          agent.cancel();
        }
      }, onDone: () => completer.complete());
      await completer.future;
      await sub.cancel();

      expect(client.calls, 1);
      expect(events.whereType<AgentCancelled>(), isNotEmpty);
    });

    test('cancel during onLLMError await does not retry', () async {
      // 回归：cancel 中断 stream 后抛出 ClientException（看起来像可重试网络错误），
      // 若 _runOnLLMError 在 hook await 期间不检查 _cancelled，会错误地 AgentRoundRetry。
      final client = _FlakyStreamClient([
        _StreamScript(
          events: [TextDelta('partial')],
          error: ClientException('Connection closed'),
        ),
        _StreamScript(events: [TextDelta('full'), StreamComplete()]),
      ]);
      final enteredOnLLMError = Completer<void>();
      final agent = build(
        client,
        hooks: [
          _AsyncLLMErrorHook((error, attempt) async {
            if (!enteredOnLLMError.isCompleted) {
              enteredOnLLMError.complete();
            }
            // 停留在 onLLMError，给 cancel 留出窗口。
            await Future<void>.delayed(const Duration(milliseconds: 50));
            // proceed → 走内建策略；未修复时会把 ClientException 当 transient 重试。
            return const LLMErrorAction.proceed();
          }),
        ],
      );

      final events = <AgentEvent>[];
      final done = Completer<void>();
      final sub = agent.process('hi').listen(events.add, onDone: done.complete);

      await enteredOnLLMError.future;
      agent.cancel();
      await done.future;
      await sub.cancel();

      expect(client.calls, 1);
      expect(events.whereType<AgentRoundRetry>(), isEmpty);
      expect(events.whereType<AgentCancelled>(), isNotEmpty);
      expect(events.whereType<AgentDone>(), isEmpty);
    });

    test(
      'tool call emitted before break is never dispatched on failed attempt',
      () async {
        final client = _FlakyStreamClient([
          _StreamScript(
            events: [
              ToolCallDelta(
                callId: 'c1',
                toolName: 'T',
                arguments: const <String, dynamic>{},
              ),
            ],
            error: ClientException('Connection closed'),
          ),
          _StreamScript(events: [TextDelta('done'), StreamComplete()]),
        ]);
        final dispatcher = FakeAgentToolDispatcher();
        final agent = build(client, toolManager: dispatcher);

        final events = await agent.process('hi').toList();

        // 失败轮的 tool call 从未派发（dispatch 在 round complete 之后）。
        expect(dispatcher.capturedCalls, isEmpty);
        expect(events.whereType<AgentRoundRetry>(), hasLength(1));
        expect(events.whereType<AgentDone>().single.finalText, 'done');
      },
    );

    test(
      'incomplete tool call without thinking retries before later success',
      () async {
        // 无 finishReason 模拟流中途断连：只有这类才原样重发；
        // length 截断是确定性的，走外层续跑（见下方用例）。
        _StreamScript incompleteAttempt() => _StreamScript(
          events: [
            ToolCallDelta(
              callId: 'edit_partial',
              toolName: 'Edit',
              arguments: const {'path': '/chapters/1'},
              isPartial: true,
            ),
            StreamComplete(),
          ],
        );

        final client = _FlakyStreamClient([
          incompleteAttempt(),
          _StreamScript(
            events: [
              ToolCallDelta(
                callId: 'edit_complete',
                toolName: 'Edit',
                arguments: const {
                  'path': '/chapters/1',
                  'old_text': 'old',
                  'new_text': 'new',
                },
              ),
              StreamComplete(),
            ],
          ),
          _StreamScript(events: [TextDelta('done'), StreamComplete()]),
        ]);
        final dispatcher = FakeAgentToolDispatcher();
        final agent = build(client, toolManager: dispatcher);

        final events = await agent.process('edit').toList();

        expect(client.calls, 3);
        expect(events.whereType<AgentRoundRetry>(), hasLength(1));
        expect(
          client.capturedMessages[1].length,
          client.capturedMessages[0].length,
        );
        expect(dispatcher.capturedCalls, hasLength(1));
        expect(dispatcher.capturedCalls.single.callId, 'edit_complete');
        expect(events.whereType<AgentDone>().single.finalText, 'done');
      },
    );

    test(
      'incomplete tool call retry exhaustion never dispatches the tool',
      () async {
        _StreamScript incompleteAttempt(int index) => _StreamScript(
          events: [
            ToolCallDelta(
              callId: 'edit_partial_$index',
              toolName: 'Edit',
              arguments: const {'path': '/chapters/1'},
              isPartial: true,
            ),
            StreamComplete(),
          ],
        );

        final client = _FlakyStreamClient(
          List.generate(maxStreamRetries + 1, incompleteAttempt),
        );
        final dispatcher = FakeAgentToolDispatcher();
        final agent = build(client, toolManager: dispatcher);

        final events = await agent.process('edit').toList();

        expect(client.calls, maxStreamRetries + 1);
        expect(
          events.whereType<AgentRoundRetry>(),
          hasLength(maxStreamRetries),
        );
        expect(dispatcher.capturedCalls, isEmpty);
        expect(events.whereType<AgentDone>(), isEmpty);
        expect(
          events.whereType<AgentError>().single.failure.kind,
          AiRunFailureKind.incompleteResponse,
        );
      },
    );

    test(
      'length-truncated incomplete tool call continues instead of retrying',
      () async {
        // length 截断是确定性的：同样的请求会在同一处再截断，原样重发
        // 纯属浪费。应走外层 thinking-only 续跑开新一轮（新轮有全新的
        // 输出预算），而不是进内层 AgentRoundRetry。
        final client = _FlakyStreamClient([
          _StreamScript(
            events: [
              ToolCallDelta(
                callId: 'edit_partial',
                toolName: 'Edit',
                arguments: const {'path': '/chapters/1'},
                isPartial: true,
              ),
              StreamComplete(finishReason: StreamFinishReason.length),
            ],
          ),
          _StreamScript(events: [TextDelta('done'), StreamComplete()]),
        ]);
        final dispatcher = FakeAgentToolDispatcher();
        final agent = build(client, toolManager: dispatcher);

        final events = await agent.process('edit').toList();

        expect(
          client.capturedMessages[1].last.content,
          incompleteToolCallContinuationRemind,
        );
        expect(client.calls, 2);
        expect(events.whereType<AgentRoundRetry>(), isEmpty);
        // 续跑新轮比原样重发多带 continuation 自述 + 续跑 remind。
        expect(
          client.capturedMessages[1].length,
          client.capturedMessages[0].length + 2,
        );
        expect(dispatcher.capturedCalls, isEmpty);
        expect(events.whereType<AgentDone>().single.finalText, 'done');
      },
    );

    for (final finishReason in [
      null,
      StreamFinishReason.stop,
      StreamFinishReason.length,
    ]) {
      test(
        'incomplete tool call with preface text continues instead of finishing ($finishReason)',
        () async {
          // 线上回归：模型先说一句前置短句，紧接着的 Create 参数传到一半断流。
          // 改动前 _incompleteResponseFor 看见有正文就返回 null，这轮被当成功轮
          // 提交，用户只看到那句短句，工具从没执行过，也没有任何失败提示。
          final client = _FlakyStreamClient([
            _StreamScript(
              events: [
                TextDelta('按第61章节拍开写。'),
                ToolCallDelta(
                  callId: 'create_partial',
                  toolName: 'Create',
                  arguments: const {'path': '/chapters/61'},
                  isPartial: true,
                ),
                StreamComplete(finishReason: finishReason),
              ],
            ),
            _StreamScript(
              events: [
                ToolCallDelta(
                  callId: 'create_complete',
                  toolName: 'Create',
                  arguments: const {
                    'path': '/chapters/61',
                    'content': 'chapter body',
                  },
                ),
                StreamComplete(),
              ],
            ),
            _StreamScript(events: [TextDelta('done'), StreamComplete()]),
          ]);
          final dispatcher = FakeAgentToolDispatcher();
          final hook = _IncompleteResponseHook();
          final agent = build(client, toolManager: dispatcher, hooks: [hook]);

          final events = await agent.process('write chapter 61').toList();

          expect(hook.retryDecisions, [true]);
          expect(hook.terminalError, isNull);

          // 不是内层原样重发：正文要留给用户，开新一轮让模型接着发调用。
          expect(events.whereType<AgentRoundRetry>(), isEmpty);
          // 新一轮比上一轮多带 assistant 正文 + 续跑 remind。
          expect(
            client.capturedMessages[1].length,
            client.capturedMessages[0].length + 2,
          );
          expect(
            client.capturedMessages[1].last.content,
            incompleteToolCallContinuationRemind,
          );
          // 半截的那次绝不能执行，完整的只执行一次。
          expect(dispatcher.capturedCalls, hasLength(1));
          expect(dispatcher.capturedCalls.single.callId, 'create_complete');
          // 关键回归点：不能出现只有前置短句的成功回复。
          expect(
            events.whereType<AgentDone>().single.finalText,
            isNot('按第61章节拍开写。'),
          );
        },
      );
    }

    test(
      'incomplete tool call with preface text exhausts truncated rounds',
      () async {
        // 每轮都是「前置短句 + 半截调用」：走的是续写通道，由
        // maxTruncatedResponseRounds 收敛，不额外开一套上限。
        final client = _FlakyStreamClient(
          List.generate(
            maxTruncatedResponseRounds,
            (index) => _StreamScript(
              events: [
                TextDelta('开写。'),
                ToolCallDelta(
                  callId: 'create_partial_$index',
                  toolName: 'Create',
                  arguments: const {'path': '/chapters/61'},
                  isPartial: true,
                ),
                StreamComplete(),
              ],
            ),
          ),
        );
        final dispatcher = FakeAgentToolDispatcher();
        final hook = _IncompleteResponseHook();
        final agent = build(client, toolManager: dispatcher, hooks: [hook]);

        final events = await agent.process('write chapter 61').toList();

        expect(hook.retryDecisions, [
          ...List.filled(maxTruncatedResponseRounds - 1, true),
          false,
        ]);
        expect(hook.terminalError, isA<IncompleteModelResponseException>());
        expect(client.calls, maxTruncatedResponseRounds);
        expect(events.whereType<AgentRoundRetry>(), isEmpty);
        expect(dispatcher.capturedCalls, isEmpty);
        expect(events.whereType<AgentDone>(), isEmpty);
        expect(
          events.whereType<AgentError>().single.failure.kind,
          AiRunFailureKind.incompleteResponse,
        );
      },
    );
  });
}

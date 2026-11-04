// 职责: Agent 测试替身 — 提供 fake client、fake tool dispatcher 与快速创建测试 Agent 的入口
// 关联文件:
//   lib/shared/agent/agent.dart
//   lib/shared/agent/client.dart
//   lib/shared/agent/agent_tool_dispatcher.dart
//   lib/shared/agent/message.dart

import 'dart:async';

import 'agent.dart';
import 'agent_config.dart';
import 'agent_context_manager.dart';
import 'agent_hook.dart';
import 'agent_tool_dispatcher.dart';
import 'client.dart';
import 'message.dart';

class FakeProviderClientRequest {
  const FakeProviderClientRequest({
    required this.callIndex,
    required this.messages,
    required this.tools,
    required this.options,
  });

  final int callIndex;
  final List<AgentMessage> messages;
  final List<ToolDef>? tools;
  final AgentConfig? options;
}

typedef FakeProviderClientResponder =
    FutureOr<FakeProviderClientResponse> Function(
      FakeProviderClientRequest request,
    );

class FakeProviderClientResponse {
  const FakeProviderClientResponse({
    this.text = '',
    this.thinking = '',
    this.signature,
    this.encryptedContents = const [],
    this.toolCalls = const [],
    this.usage,
    this.events,
    this.eventDelay = Duration.zero,
  });

  const FakeProviderClientResponse.text(
    String text, {
    String thinking = '',
    String? signature,
    AiUsage? usage,
    Duration eventDelay = Duration.zero,
  }) : this(
         text: text,
         thinking: thinking,
         signature: signature,
         usage: usage,
         eventDelay: eventDelay,
       );

  const FakeProviderClientResponse.toolCalls(
    List<ToolCall> toolCalls, {
    String text = '',
    String thinking = '',
    String? signature,
    AiUsage? usage,
    Duration eventDelay = Duration.zero,
  }) : this(
         text: text,
         thinking: thinking,
         signature: signature,
         toolCalls: toolCalls,
         usage: usage,
         eventDelay: eventDelay,
       );

  const FakeProviderClientResponse.events(
    List<StreamEvent> events, {
    Duration eventDelay = Duration.zero,
  }) : this(events: events, eventDelay: eventDelay);

  final String text;
  final String thinking;
  final String? signature;
  final List<String> encryptedContents;
  final List<ToolCall> toolCalls;
  final AiUsage? usage;
  final List<StreamEvent>? events;
  final Duration eventDelay;

  ChatResponse toChatResponse() {
    return ChatResponse(
      text: text,
      thinking: thinking,
      signature: signature,
      encryptedContents: encryptedContents,
      toolCalls: toolCalls,
      usage: usage,
    );
  }

  List<StreamEvent> toStreamEvents() {
    final customEvents = events;
    if (customEvents != null) {
      return customEvents;
    }

    return [
      if (thinking.isNotEmpty) ThinkingDelta(thinking),
      if (signature != null) SignatureDelta(signature!),
      for (final encryptedContent in encryptedContents)
        EncryptedContentDelta(encryptedContent),
      if (text.isNotEmpty) TextDelta(text),
      for (final call in toolCalls)
        ToolCallDelta(
          callId: call.callId,
          toolName: call.toolName,
          arguments: call.arguments,
          thoughtSignature: call.thoughtSignature,
        ),
      StreamComplete(usage: usage),
    ];
  }
}

class FakeProviderClient implements ProviderClient {
  FakeProviderClient({
    this._responses = const [FakeProviderClientResponse.text('fake response')],
    this._responder,
    this.repeatLastResponse = true,
  });

  final List<FakeProviderClientResponse> _responses;
  final FakeProviderClientResponder? _responder;
  final bool repeatLastResponse;

  final List<FakeProviderClientRequest> capturedChatRequests = [];
  final List<FakeProviderClientRequest> capturedStreamRequests = [];

  int chatCallCount = 0;
  int streamCallCount = 0;
  int cancelCallCount = 0;
  bool cancelled = false;

  @override
  Future<ChatResponse> chat({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async {
    final request = FakeProviderClientRequest(
      callIndex: chatCallCount,
      messages: List<AgentMessage>.from(messages),
      tools: tools == null ? null : List<ToolDef>.from(tools),
      options: options,
    );
    chatCallCount += 1;
    capturedChatRequests.add(request);
    final response = await _resolveResponse(request);
    return response.toChatResponse();
  }

  @override
  Stream<StreamEvent> chatStream({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async* {
    final request = FakeProviderClientRequest(
      callIndex: streamCallCount,
      messages: List<AgentMessage>.from(messages),
      tools: tools == null ? null : List<ToolDef>.from(tools),
      options: options,
    );
    streamCallCount += 1;
    capturedStreamRequests.add(request);
    final response = await _resolveResponse(request);
    for (final event in response.toStreamEvents()) {
      if (cancelled) {
        yield StreamCancelled();
        return;
      }
      if (response.eventDelay > Duration.zero) {
        await Future<void>.delayed(response.eventDelay);
      }
      yield event;
    }
  }

  @override
  void cancel() {
    cancelCallCount += 1;
    cancelled = true;
  }

  Future<FakeProviderClientResponse> _resolveResponse(
    FakeProviderClientRequest request,
  ) async {
    final responder = _responder;
    if (responder != null) {
      return responder(request);
    }
    if (_responses.isEmpty) {
      throw StateError('FakeProviderClient has no responses configured.');
    }
    if (request.callIndex < _responses.length) {
      return _responses[request.callIndex];
    }
    if (repeatLastResponse) {
      return _responses.last;
    }
    throw StateError(
      'FakeProviderClient response exhausted at call ${request.callIndex}.',
    );
  }
}

typedef FakeToolHandler =
    FutureOr<Map<String, dynamic>> Function(
      Map<String, dynamic> input,
      String? callId,
    );

class FakeAgentTool {
  const FakeAgentTool({required this.def, required this.handler});

  final ToolDef def;
  final FakeToolHandler handler;
}

class FakeAgentToolCall {
  const FakeAgentToolCall({
    required this.name,
    required this.input,
    required this.callId,
    required this.emitEvents,
    required this.context,
  });

  final String name;
  final Map<String, dynamic> input;
  final String? callId;
  final bool emitEvents;
  final ToolExecutionContext? context;
}

class FakeAgentToolDispatcher implements AgentToolDispatcher {
  FakeAgentToolDispatcher({
    this._tools = const {},
    this._defaultResult = const {'ok': true},
  });

  factory FakeAgentToolDispatcher.withResults({
    required Map<String, Map<String, dynamic>> results,
  }) {
    return FakeAgentToolDispatcher(
      tools: {
        for (final entry in results.entries)
          entry.key: FakeAgentTool(
            def: ToolDef(
              name: entry.key,
              description: 'Fake tool ${entry.key}',
              inputSchema: const {'type': 'object'},
            ),
            handler: (_, _) => entry.value,
          ),
      },
    );
  }

  final Map<String, FakeAgentTool> _tools;
  final Map<String, dynamic> _defaultResult;
  final List<FakeAgentToolCall> capturedCalls = [];

  @override
  Future<Map<String, dynamic>> executeTool({
    required String name,
    required Map<String, dynamic> input,
    String? callId,
    bool emitEvents = true,
    ToolExecutionContext? context,
  }) async {
    capturedCalls.add(
      FakeAgentToolCall(
        name: name,
        input: Map<String, dynamic>.from(input),
        callId: callId,
        emitEvents: emitEvents,
        context: context,
      ),
    );
    final tool = _tools[name];
    if (tool == null) {
      return Map<String, dynamic>.from(_defaultResult);
    }
    return tool.handler(input, callId);
  }

  @override
  List<String> allToolNames() => _tools.keys.toList();

  @override
  List<ToolDef> allToolDefs() {
    return _tools.values.map((tool) => tool.def).toList();
  }

  @override
  List<ToolDef> toolDefsForNames(List<String> names) {
    return [
      for (final name in names)
        if (_tools[name] != null) _tools[name]!.def,
    ];
  }
}

class FakeAgent {
  const FakeAgent._();

  static Agent create({
    String id = 'fake_agent',
    String systemPrompt = 'You are a fake agent for tests.',
    FakeProviderClient? client,
    List<FakeProviderClientResponse> responses = const [
      FakeProviderClientResponse.text('fake response'),
    ],
    FakeProviderClientResponder? responder,
    AgentConfig config = const AgentConfig(),
    AgentToolDispatcher? toolManager,
    List<String>? allowedTools,
    AgentContextManager? contextManager,
    List<AgentMessage>? initialMessages,
    List<AgentHook> hooks = const [],
    bool emitToolEvents = true,
  }) {
    return Agent.custom(
      id: id,
      systemPrompt: systemPrompt,
      client:
          client ??
          FakeProviderClient(responses: responses, responder: responder),
      config: config,
      toolManager: toolManager ?? FakeAgentToolDispatcher(),
      allowedTools: allowedTools,
      contextManager: contextManager,
      initialMessages: initialMessages,
      hooks: hooks,
      emitToolEvents: emitToolEvents,
    );
  }
}

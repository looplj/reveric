// 职责: 验证 Debug provider 只暴露真实模型，并按场景改写真实 client 的标准流事件
// 关联文件:
//   lib/shared/services/debug/debug_ai_provider.dart
//   lib/shared/services/debug/debug_provider_client.dart
//   lib/shared/models/ai_provider.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/agent_config.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/agent/client.dart';
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/services/debug/debug_ai_provider.dart';
import 'package:reveric/shared/services/debug/debug_provider_client.dart';

void main() {
  setUp(() {});

  tearDown(() {});

  test(
    'truncated scenario preserves only a partial real text response',
    () async {
      final client = DebugInjectedProviderClient(
        inner: _ScriptedProviderClient([
          TextDelta('real provider response that keeps going'),
          StreamComplete(finishReason: StreamFinishReason.stop),
        ]),
        scenario: DebugAiProviderScenario.truncatedText,
      );

      final events = await client
          .chatStream(messages: const [], options: const AgentConfig())
          .toList();

      expect(
        events.whereType<TextDelta>().single.text,
        'real provider response that keeps going',
      );
      expect(
        events.whereType<StreamComplete>().single.finishReason,
        StreamFinishReason.length,
      );
    },
  );

  test(
    'thinking-only scenario keeps reasoning blocks and removes text',
    () async {
      final client = DebugInjectedProviderClient(
        inner: _ScriptedProviderClient([
          ThinkingDelta('real reasoning'),
          SignatureDelta('real-signature'),
          EncryptedContentDelta('real-encrypted'),
          TextDelta('real answer'),
          StreamComplete(finishReason: StreamFinishReason.stop),
        ]),
        scenario: DebugAiProviderScenario.thinkingOnly,
      );

      final events = await client
          .chatStream(messages: const [], options: const AgentConfig())
          .toList();

      expect(events.whereType<ThinkingDelta>().single.text, 'real reasoning');
      expect(
        events.whereType<SignatureDelta>().single.signature,
        'real-signature',
      );
      expect(
        events.whereType<EncryptedContentDelta>().single.encryptedContent,
        'real-encrypted',
      );
      expect(events.whereType<TextDelta>(), isEmpty);
      expect(
        events.whereType<StreamComplete>().single.finishReason,
        StreamFinishReason.length,
      );
    },
  );

  test(
    'partial tool scenario preserves complete calls before the last one',
    () async {
      final client = DebugInjectedProviderClient(
        inner: _ScriptedProviderClient([
          TextDelta('real preamble'),
          ToolCallDelta(
            callId: 'first-call',
            toolName: 'Read',
            arguments: {'path': '/debug/first'},
          ),
          ToolCallDelta(
            callId: 'last-call',
            toolName: 'Read',
            arguments: {'path': '/debug/last', 'mode': 'full'},
          ),
          StreamComplete(finishReason: StreamFinishReason.stop),
        ]),
        scenario: DebugAiProviderScenario.partialToolWithoutThinking,
      );

      final events = await client
          .chatStream(
            messages: const [],
            tools: const [
              ToolDef(
                name: 'Read',
                description: 'Read a file',
                inputSchema: {'type': 'object'},
              ),
            ],
            options: const AgentConfig(),
          )
          .toList();

      final toolCalls = events.whereType<ToolCallDelta>().toList();
      expect(toolCalls, hasLength(2));
      expect(toolCalls.first.callId, 'first-call');
      expect(toolCalls.first.isPartial, isFalse);
      expect(toolCalls.first.arguments, {'path': '/debug/first'});
      expect(toolCalls.last.callId, 'last-call');
      expect(toolCalls.last.isPartial, isTrue);
      expect(toolCalls.last.arguments, {'path': '/debug/last'});
      expect(events.whereType<ThinkingDelta>(), isEmpty);
      expect(
        events.whereType<StreamComplete>().single.finishReason,
        StreamFinishReason.length,
      );
    },
  );
}

class _ScriptedProviderClient implements ProviderClient {
  _ScriptedProviderClient(this._events);

  final List<StreamEvent> _events;

  @override
  Future<ChatResponse> chat({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async {
    return const ChatResponse();
  }

  @override
  Stream<StreamEvent> chatStream({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async* {
    yield* Stream<StreamEvent>.fromIterable(_events);
  }

  @override
  void cancel() {}
}

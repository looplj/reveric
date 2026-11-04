// 职责: Debug provider 流注入器 — 在真实 Reveric provider 响应上制造可重复的异常终态
// 关联文件:
//   lib/shared/services/debug/debug_ai_provider.dart
//   lib/shared/agent/client.dart
//   lib/shared/agent/agent_tool_dispatcher.dart

import '../../agent/agent_tool_dispatcher.dart' show ToolDef;
import '../../agent/agent_config.dart' show AgentConfig;
import '../../agent/client.dart';
import '../../agent/message.dart' show AgentMessage;
import 'debug_ai_provider.dart';

class DebugInjectedProviderClient implements ProviderClient {
  DebugInjectedProviderClient({required this._inner, required this._scenario});

  final ProviderClient _inner;
  final DebugAiProviderScenario _scenario;

  @override
  Future<ChatResponse> chat({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) {
    return _inner.chat(messages: messages, tools: tools, options: options);
  }

  @override
  Stream<StreamEvent> chatStream({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async* {
    var sawThinking = false;
    var sawCompletion = false;
    var emittedTextChars = 0;
    final toolCallsById = <String, ToolCallDelta>{};

    await for (final event in _inner.chatStream(
      messages: messages,
      tools: tools,
      options: options,
    )) {
      if (event is StreamCancelled || event is StreamError) {
        yield event;
        return;
      }

      switch (event) {
        case ThinkingDelta():
          sawThinking = true;
          if (_scenario == DebugAiProviderScenario.partialToolWithoutThinking) {
            continue;
          }
        case SignatureDelta():
          if (_scenario == DebugAiProviderScenario.partialToolWithoutThinking) {
            continue;
          }
        case EncryptedContentDelta():
          if (_scenario == DebugAiProviderScenario.partialToolWithoutThinking) {
            continue;
          }
        case TextDelta(:final text):
          if (_scenario == DebugAiProviderScenario.truncatedText) {
            const maxTextChars = 48;
            final remaining = maxTextChars - emittedTextChars;
            if (remaining > 0) {
              final visible = text.length <= remaining
                  ? text
                  : text.substring(0, remaining);
              if (visible.isNotEmpty) {
                emittedTextChars += visible.length;
                yield TextDelta(visible);
              }
            }
            continue;
          }
          if (_scenario == DebugAiProviderScenario.thinkingOnly) {
            continue;
          }
        case ToolCallDelta(:final callId, toolName: final eventToolName):
          if (_scenario == DebugAiProviderScenario.partialToolWithoutThinking ||
              _scenario == DebugAiProviderScenario.partialToolWithThinking) {
            if (callId.isNotEmpty && eventToolName.isNotEmpty) {
              toolCallsById[callId] = event;
            }
            continue;
          }
        case StreamComplete(:final usage):
          sawCompletion = true;
          if (_scenario == DebugAiProviderScenario.thinkingOnly) {
            if (!sawThinking) {
              yield ThinkingDelta('[debug injected thinking]');
            }
            yield StreamComplete(
              usage: usage,
              finishReason: StreamFinishReason.length,
            );
            return;
          }
          if (_scenario == DebugAiProviderScenario.truncatedText) {
            yield StreamComplete(
              usage: usage,
              finishReason: StreamFinishReason.length,
            );
            return;
          }
          if (_scenario == DebugAiProviderScenario.partialToolWithoutThinking ||
              _scenario == DebugAiProviderScenario.partialToolWithThinking) {
            yield* _lastToolAsIncomplete(toolCallsById.values);
            yield StreamComplete(
              usage: usage,
              finishReason: StreamFinishReason.length,
            );
            return;
          }
        default:
          break;
      }

      yield event;
    }

    if (sawCompletion) {
      return;
    }
    if (_scenario == DebugAiProviderScenario.truncatedText ||
        _scenario == DebugAiProviderScenario.thinkingOnly) {
      if (_scenario == DebugAiProviderScenario.thinkingOnly && !sawThinking) {
        yield ThinkingDelta('[debug injected thinking]');
      }
      yield StreamComplete(finishReason: StreamFinishReason.length);
      return;
    }
    if (_scenario == DebugAiProviderScenario.partialToolWithoutThinking ||
        _scenario == DebugAiProviderScenario.partialToolWithThinking) {
      yield* _lastToolAsIncomplete(toolCallsById.values);
      yield StreamComplete(finishReason: StreamFinishReason.length);
    }
  }

  Stream<ToolCallDelta> _lastToolAsIncomplete(
    Iterable<ToolCallDelta> toolCalls,
  ) async* {
    final ordered = toolCalls.toList();
    if (ordered.isEmpty) {
      return;
    }

    // Keep every real call before the last one intact. Only the last call is
    // marked partial, so Agent can execute the completed prefix safely.
    for (final call in ordered.take(ordered.length - 1)) {
      if (!call.isPartial) {
        yield ToolCallDelta(
          callId: call.callId,
          toolName: call.toolName,
          arguments: call.arguments,
          thoughtSignature: call.thoughtSignature,
        );
      }
    }

    final last = ordered.last;
    final partialArguments = last.arguments.isEmpty
        ? const <String, dynamic>{'partial': true}
        : <String, dynamic>{
            last.arguments.entries.first.key:
                last.arguments.entries.first.value,
          };
    yield ToolCallDelta(
      callId: last.callId,
      toolName: last.toolName,
      arguments: partialArguments,
      isPartial: true,
      thoughtSignature: last.thoughtSignature,
    );
  }

  @override
  void cancel() {
    _inner.cancel();
  }
}

// 职责: Agent 运行时消息与 block 类型 — 最小化，无业务依赖
// 关联文件:
//   lib/shared/agent/agent.dart
//   lib/shared/agent/agent_context_manager.dart
//   lib/shared/agent/agent_event.dart
//   lib/shared/agent/client.dart
//   lib/shared/services/ai/chat.dart

import 'client.dart' show AiUsage;

// ---------------------------------------------------------------------------
// Block types (agent-owned, used by both AgentMessage and ProviderClient)
// ---------------------------------------------------------------------------

sealed class MessageBlock {
  const MessageBlock();
}

class TextBlock extends MessageBlock {
  final String text;
  const TextBlock(this.text);
}

class ThinkingBlock extends MessageBlock {
  final String text;
  final String? signature;
  final List<String> encryptedContents;
  const ThinkingBlock(
    this.text, {
    this.signature,
    this.encryptedContents = const [],
  });
}

class ToolCallBlock extends MessageBlock {
  final String callId;
  final String toolName;
  final Map<String, dynamic> arguments;
  final List<int>? thoughtSignature;
  const ToolCallBlock({
    required this.callId,
    required this.toolName,
    required this.arguments,
    this.thoughtSignature,
  });
}

class ImageBlock extends MessageBlock {
  final String data;
  final String mimeType;
  const ImageBlock({required this.data, required this.mimeType});
}

class ToolResultBlock extends MessageBlock {
  final String toolCallId;
  final String toolName;
  final bool isError;
  final List<MessageBlock> content;

  /// JSON result for history when provider-facing content has been transformed.
  final Map<String, dynamic>? payload;
  const ToolResultBlock({
    required this.toolCallId,
    required this.toolName,
    required this.content,
    this.isError = false,
    this.payload,
  });
}

// ---------------------------------------------------------------------------
// Shared tool call type (merged from ProviderToolCall + AgentToolCallRequest)
// ---------------------------------------------------------------------------

class ToolCall {
  final String callId;
  final String toolName;
  final Map<String, dynamic> arguments;
  final List<int>? thoughtSignature;

  const ToolCall({
    required this.callId,
    required this.toolName,
    required this.arguments,
    this.thoughtSignature,
  });
}

// ---------------------------------------------------------------------------
// Agent message type
// ---------------------------------------------------------------------------

enum AgentMessageRole { user, assistant, system }

enum AgentMessageType { text, tool_result, compact_summary }

class AgentMessage {
  final String id;
  final AgentMessageRole role;
  final AgentMessageType type;
  final String content;
  final List<MessageBlock> blocks;
  final AiUsage? usage;

  const AgentMessage({
    required this.id,
    required this.role,
    this.type = AgentMessageType.text,
    this.content = '',
    this.blocks = const [],
    this.usage,
  });

  factory AgentMessage.user({
    required String id,
    required String content,
    AgentMessageType type = AgentMessageType.text,
    List<MessageBlock> blocks = const [],
  }) {
    return AgentMessage(
      id: id,
      role: AgentMessageRole.user,
      type: type,
      content: content,
      blocks: blocks,
    );
  }

  factory AgentMessage.assistant({
    required String id,
    required String content,
    AgentMessageType type = AgentMessageType.text,
    List<MessageBlock> blocks = const [],
    AiUsage? usage,
  }) {
    return AgentMessage(
      id: id,
      role: AgentMessageRole.assistant,
      type: type,
      content: content,
      blocks: blocks,
      usage: usage,
    );
  }

  factory AgentMessage.system({required String id, required String content}) {
    return AgentMessage(
      id: id,
      role: AgentMessageRole.system,
      content: content,
    );
  }

  AgentMessage copyWith({
    String? id,
    AgentMessageRole? role,
    AgentMessageType? type,
    String? content,
    List<MessageBlock>? blocks,
    AiUsage? usage,
  }) {
    return AgentMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      type: type ?? this.type,
      content: content ?? this.content,
      blocks: blocks ?? this.blocks,
      usage: usage ?? this.usage,
    );
  }
}

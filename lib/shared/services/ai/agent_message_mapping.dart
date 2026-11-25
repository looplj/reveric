// 职责: AI 聊天消息转换 — 将持久化 UI 消息恢复为 Agent 可发送历史，并在跨模型切换时清理 provider 私有推理状态。
// 关联文件:
//   lib/shared/models/ai_chat_models.dart
//   lib/shared/models/ai_message_block.dart
//   lib/shared/agent/message.dart
//   lib/shared/services/ai/tool_result_payloads.dart
//   lib/shared/services/ai/chat_turn_runner.dart

import 'dart:convert';

import '../../agent/client.dart' show toolCallIncompleteErrorCode;
import '../../agent/message.dart';
import '../../models/ai_chat_models.dart';
import '../../utils/random_id.dart';
import 'context_message_matcher.dart';
import 'files/attachments.dart';
import 'chat_attachments.dart';
import 'session_persistence.dart';
import 'tool_result_payloads.dart';
import 'tool_error_normalize.dart';

String encodeBase64(List<int> bytes) => base64Encode(bytes);

final _base64ThoughtSignaturePattern = RegExp(r'^[A-Za-z0-9+/]*={0,2}$');

/// 从已持久化聊天记录恢复 SmartAgentContextManager 所需的压缩状态。
///
/// 最新 compact_summary 是上下文快照的元数据，不应作为 retained history 再注入，
/// 否则 manager 会在下一轮同时丢失压缩序号和重复发送摘要。
class PersistedChatContext {
  const PersistedChatContext({
    required this.retainedMessages,
    this.summary,
    this.compactionCount = 0,
    this.lastCompactionTokensBefore,
    this.lastCompactionTokensAfter,
  });

  final List<AiMessage> retainedMessages;
  final String? summary;
  final int compactionCount;
  final int? lastCompactionTokensBefore;
  final int? lastCompactionTokensAfter;
}

/// 从持久化会话恢复上下文摘要及最后一次压缩后的 retained history。
///
/// 没有摘要时保留历史内容；摘要必须带当前结构的压缩计数。
PersistedChatContext restorePersistedChatContext(List<AiMessage> messages) {
  final compactIndex = messages.lastIndexWhere(
    (message) => message.type == AiMessageType.compact_summary,
  );
  if (compactIndex < 0) {
    return PersistedChatContext(retainedMessages: messages);
  }

  final summaryMessage = messages[compactIndex];
  final metadata = summaryMessage.metadata;
  final summary = summaryMessage.content.trim();
  return PersistedChatContext(
    summary: summary.isEmpty ? null : summary,
    compactionCount:
        _metadataNonNegativeInt(metadata, 'compaction_count') ??
        (throw const FormatException('Missing compaction count.')),
    lastCompactionTokensBefore: _metadataNonNegativeInt(
      metadata,
      'tokens_before',
    ),
    lastCompactionTokensAfter: _metadataNonNegativeInt(
      metadata,
      'tokens_after',
    ),
    retainedMessages: messagesSinceLatestCompact(messages)
        .where((message) => message.type != AiMessageType.compact_summary)
        .toList(growable: false),
  );
}

int? _metadataNonNegativeInt(Map<String, dynamic>? metadata, String key) {
  final value = metadata?[key];
  if (value is num && value >= 0 && value == value.roundToDouble()) {
    return value.toInt();
  }
  return null;
}

/// thought signature 必须是合法 base64（Google API 的 TYPE_BYTES）。
///
/// 参考 pi-mono `google-shared.ts` 的 `isValidThoughtSignature`：非法就丢弃、发
/// unsigned（Gemini 接受无签名的异源 function call），而不是让 base64Decode 抛出。
bool _isValidBase64ThoughtSignature(String signature) {
  if (signature.isEmpty || signature.length % 4 != 0) {
    return false;
  }
  return _base64ThoughtSignaturePattern.hasMatch(signature);
}

/// 清除跨模型不可重放的 provider 私有推理状态。
///
/// 参考 pi-mono `google-shared.ts` 的跨模型处理：
/// - thinking：降级为纯文本保留推理上下文，丢弃只有原模型能解释的
///   signature/encryptedContents，不加思考标签（避免新模型模仿思考格式）；空思考略过。
/// - tool call：保留调用与结果，清掉 provider 私有的 thought signature（Gemini
///   接受无签名的异源 function call，无需 sentinel）。
/// - 其余可见文本、上下文摘要原样保留。
List<AiMessage> stripProviderPrivateConversationState(
  List<AiMessage> messages,
) {
  return [
    for (final message in messages)
      message.copyWith(
        blocks: [
          for (final block in message.blocks)
            if (block is AiThinkingBlock)
              ...(block.text.trim().isEmpty
                  ? const <AiMessageBlock>[]
                  : [AiTextBlock(id: block.id, text: block.text)])
            else if (block is AiToolCallBlock)
              block.copyWith(thoughtSignature: null)
            else
              block,
        ],
      ),
  ];
}

/// Returns the persisted history that a rebuilt Agent actually replays.
///
/// Compaction summaries are append-only markers placed where compaction
/// happened. The latest marker carries [compactReplayFromMessageIdKey] naming
/// the first retained UI message, which may sit before or after the marker;
/// overflow before that id is not restored. Old summaries without the pointer,
/// or whose pointer no longer exists, fall back to slicing from the marker.
List<AiMessage> messagesSinceLatestCompact(List<AiMessage> messages) {
  final compactIndex = messages.lastIndexWhere(
    (message) => message.type == AiMessageType.compact_summary,
  );
  if (compactIndex < 0) {
    return messages;
  }
  final summary = messages[compactIndex];
  final replayFromId = compactReplayFromMessageId(summary.metadata);
  final replayFromIndex = replayFromId == null
      ? -1
      : messages.indexWhere((message) => message.id == replayFromId);
  if (replayFromIndex < 0) {
    return messages.sublist(compactIndex);
  }
  // 摘要在回放窗口之内时只保留最新一条并前置；更早的摘要已被它覆盖。
  final retained = messages
      .sublist(replayFromIndex)
      .where((message) => message.type != AiMessageType.compact_summary);
  return [summary, ...retained];
}

/// SpawnAgent 子会话落库：转换 Agent 历史并合并 tool_result，避免过程轮次被过滤掉。
List<AiMessage> prepareSpawnAgentRunMessagesForPersistence(
  List<AgentMessage> messages,
) {
  final converted = messages
      .where((message) => message.role != AgentMessageRole.system)
      .map(convertAgentMessageToAiMessage)
      .toList(growable: false);
  return finalizeAiMessagesToolCallsForPersistence(converted);
}

AiMessage convertAgentMessageToAiMessage(AgentMessage message) {
  final blocks = <AiMessageBlock>[];
  final metadata = <String, dynamic>{};
  final textBuffer = StringBuffer();

  for (final block in message.blocks) {
    switch (block) {
      case TextBlock(:final text):
        textBuffer.write(text);
        if (message.type != AgentMessageType.tool_result) {
          blocks.add(AiTextBlock(id: buildRandomId('text'), text: text));
        }
      case ThinkingBlock(
        :final text,
        :final signature,
        :final encryptedContents,
      ):
        if (text.isNotEmpty ||
            encryptedContents.isNotEmpty ||
            (signature != null && signature.isNotEmpty)) {
          blocks.add(
            AiThinkingBlock(
              id: buildRandomId('thinking'),
              text: text,
              signature: signature,
              encryptedContents: encryptedContents,
            ),
          );
        }
      case ToolCallBlock(
        :final callId,
        :final toolName,
        :final arguments,
        :final thoughtSignature,
      ):
        blocks.add(
          AiToolCallBlock(
            id: 'block_$callId',
            callId: callId,
            toolName: toolName,
            arguments: arguments,
            status: AiToolCallStatus.running,
            thoughtSignature: thoughtSignature != null
                ? encodeBase64(thoughtSignature)
                : null,
          ),
        );
      case ToolResultBlock(
        :final toolCallId,
        :final toolName,
        :final isError,
        :final content,
        :final payload,
      ):
        metadata['tool_call_id'] = toolCallId;
        metadata['tool_name'] = toolName;
        metadata['is_error'] = isError;
        if (payload != null) {
          textBuffer.write(jsonEncode(payload));
        } else if (content.isNotEmpty &&
            content.first is TextBlock &&
            _isFileResultText((content.first as TextBlock).text)) {
          textBuffer.write((content.first as TextBlock).text);
        } else {
          for (final item in content) {
            if (item is TextBlock) {
              textBuffer.write(item.text);
            }
          }
        }
      case ImageBlock():
        break;
    }
  }

  final content = message.content.isNotEmpty
      ? message.content
      : textBuffer.toString();
  return AiMessage(
    id: message.id,
    role: switch (message.role) {
      AgentMessageRole.user => AiMessageRole.user,
      AgentMessageRole.assistant => AiMessageRole.assistant,
      AgentMessageRole.system => AiMessageRole.system,
    },
    type: switch (message.type) {
      AgentMessageType.tool_result => AiMessageType.tool_result,
      AgentMessageType.compact_summary => AiMessageType.compact_summary,
      AgentMessageType.text => AiMessageType.text,
    },
    content: content,
    timestamp: DateTime.now(),
    metadata: metadata.isEmpty ? null : metadata,
    blocks: blocks,
    usage: message.usage,
  );
}

List<AgentMessage> convertAiMessageToAgentMessagesForModel(AiMessage message) {
  final blocks = <MessageBlock>[];
  final toolResults = <AgentMessage>[];
  for (var blockIndex = 0; blockIndex < message.blocks.length; blockIndex++) {
    final block = message.blocks[blockIndex];
    switch (block) {
      case AiTextBlock(:final text):
        if (message.content.isEmpty && text.isNotEmpty) {
          blocks.add(TextBlock(text));
        }
      case AiThinkingBlock(
        :final text,
        :final signature,
        :final encryptedContents,
      ):
        if (text.isNotEmpty ||
            encryptedContents.isNotEmpty ||
            (signature != null && signature.isNotEmpty)) {
          blocks.add(
            ThinkingBlock(
              text,
              signature: signature,
              encryptedContents: encryptedContents,
            ),
          );
        }
      case AiToolCallBlock(
        :final callId,
        :final toolName,
        :final arguments,
        :final status,
        :final result,
        :final errorMessage,
        :final thoughtSignature,
      ):
        if (result?['error_code'] == toolCallIncompleteErrorCode) {
          // Partial tool calls are UI terminal markers only. They were never
          // written into the live Agent context and must not be replayed after
          // restoring a session.
          continue;
        }
        // SuggestNextAction 与其他工具一视同仁地进上下文。曾经在这里成对剥离，
        // 结果是活着的 agent（ContextManager 里原样留着 tool_use/tool_result）与
        // 重建历史的 agent 看到的上下文不一致 —— 同一会话重启前后模型对「自己挂过
        // 什么建议」的记忆会变。代价只是每次约 300-400 字符的 args，换来模型不重复
        // 挂同一组建议。
        if (callId.trim().isEmpty) {
          throw const FormatException('Tool call is missing its call ID.');
        }
        final effectiveCallId = callId;
        blocks.add(
          ToolCallBlock(
            callId: effectiveCallId,
            toolName: toolName,
            arguments: arguments,
            thoughtSignature:
                thoughtSignature != null &&
                    _isValidBase64ThoughtSignature(thoughtSignature)
                ? base64Decode(thoughtSignature)
                : null,
          ),
        );
        final operationResult = aiToolOperationResult(block);
        final hasOperationOutcome = const {
          'completed',
          'failed',
          'cancelled',
          'interrupted',
        }.contains(operationResult?['status']);
        final effectiveResult = hasOperationOutcome ? operationResult : result;
        final effectiveStatus = hasOperationOutcome
            ? aiToolResultStatus(effectiveResult)
            : status;
        final effectiveError = hasOperationOutcome
            ? (effectiveResult?['error'] as String?)
            : errorMessage;
        final terminalPayload = aiTerminalToolResultPayload(
          status: effectiveStatus,
          result: effectiveResult,
          errorMessage: effectiveError,
        );
        if (terminalPayload != null) {
          final payload = _toolResultPayloadForModel(
            toolName: toolName,
            result: terminalPayload,
            errorMessage: effectiveError,
          );
          toolResults.add(
            AgentMessage(
              id: 'tool_$effectiveCallId',
              role: AgentMessageRole.user,
              type: AgentMessageType.tool_result,
              blocks: [
                ToolResultBlock(
                  toolCallId: effectiveCallId,
                  toolName: toolName,
                  isError:
                      effectiveStatus == AiToolCallStatus.error ||
                      effectiveError != null ||
                      !toolResultIsSuccess(payload),
                  content: [TextBlock(jsonEncode(payload))],
                ),
              ],
            ),
          );
        }
      case AiAttachmentBlock():
      case AiImageBlock():
      case AiAskUserBlock():
      case AiSuggestNextActionBlock():
        break;
    }
  }

  final agentMessage = AgentMessage(
    id: message.id,
    role: switch (message.role) {
      AiMessageRole.user => AgentMessageRole.user,
      AiMessageRole.assistant => AgentMessageRole.assistant,
      AiMessageRole.system => AgentMessageRole.system,
    },
    type: switch (message.type) {
      AiMessageType.tool_result => AgentMessageType.tool_result,
      AiMessageType.compact_summary => AgentMessageType.compact_summary,
      _ => AgentMessageType.text,
    },
    content: message.content,
    blocks: blocks,
    usage: message.usage,
  );
  if (message.role == AiMessageRole.assistant &&
      message.content.isEmpty &&
      blocks.isEmpty) {
    return toolResults;
  }
  return [agentMessage, ...toolResults];
}

Map<String, dynamic> _toolResultPayloadForModel({
  required String toolName,
  required Map<String, dynamic>? result,
  required String? errorMessage,
}) {
  if (result == null) {
    return {'error': errorMessage ?? 'unknown'};
  }
  result = normalizeToolFailureResult(result);
  if (!toolResultIsSuccess(result)) {
    // 失败结果的 `_metadata` 只供 UI 与匿名上报，与即时回执一致不发给模型。
    return result..remove('_metadata');
  }
  if (toolName == 'SpawnAgent') {
    // 后续传话、停止与续跑依赖回执中的任务身份；历史回放与即时回执保持一致。
    // 与 Agent 的即时结果处理相同，UI 元数据不发送给模型。
    return Map<String, dynamic>.from(result)..remove('_metadata');
  }
  return result;
}

bool _isFileResultText(String text) {
  try {
    final value = jsonDecode(text);
    return value is Map<String, dynamic> && fileContentPayload(value) != null;
  } on FormatException {
    return false;
  }
}

/// Async hydration is shared by main chat, assistant and resumed sub-agents.
Future<List<AgentMessage>> restoreAgentMessages(
  Iterable<AiMessage> messages, {
  String? root,
}) async {
  final restored = <AgentMessage>[];
  final history = messages.toList();
  final delivered = <String>{
    for (final message in history)
      if (operationCompletionPayload(message.content) != null)
        ...RegExp(
          r'\nRun: ([^\n]+)',
        ).allMatches(message.content).map((match) => match.group(1)!),
  };
  for (final original in history) {
    // A delivered completion already contains its images. Only hydrate the
    // original tool result from operation metadata if no reminder was saved.
    final message = delivered.isEmpty
        ? original
        : original.copyWith(
            blocks: [
              for (final block in original.blocks)
                if (block is AiToolCallBlock &&
                    block.metadata?['operations'] is List)
                  block.copyWith(
                    metadata: {
                      ...block.metadata!,
                      'operations': [
                        for (final operation
                            in block.metadata!['operations'] as List)
                          if (operation is! Map ||
                              !delivered.contains(operation['run_id']))
                            operation,
                      ],
                    },
                  )
                else
                  block,
            ],
          );
    if (message.blocks.any((b) => b is AiAttachmentBlock)) {
      restored.add(
        AgentMessage.user(
          id: message.id,
          content: '',
          blocks: await hydrateChatBlocks(message.blocks, root: root),
        ),
      );
      continue;
    }
    for (final mapped in convertAiMessageToAgentMessagesForModel(message)) {
      final blocks = <MessageBlock>[];
      for (final block in mapped.blocks) {
        if (block is ToolResultBlock) {
          final text = block.content
              .whereType<TextBlock>()
              .map((b) => b.text)
              .join();
          final payload = jsonDecode(text) as Map<String, dynamic>;
          blocks.add(
            ToolResultBlock(
              toolCallId: block.toolCallId,
              toolName: block.toolName,
              isError: block.isError,
              content: await assembleToolResultContent(payload, root: root),
              payload: payload,
            ),
          );
        } else {
          blocks.add(block);
        }
      }
      final completion = operationCompletionPayload(mapped.content);
      if (completion != null) {
        blocks.addAll(
          (await assembleToolResultContent(
            completion,
            root: root,
          )).whereType<ImageBlock>(),
        );
      }
      restored.add(mapped.copyWith(blocks: blocks));
    }
  }
  return restored;
}

Map<String, dynamic>? operationCompletionPayload(String text) {
  if (!text.startsWith('<system-remind type="operation_completed">')) {
    return null;
  }
  final start = text.indexOf('\nResult: ');
  final end = text.lastIndexOf('\n</system-remind>');
  if (start < 0 || end < start) {
    return null;
  }
  try {
    final value = jsonDecode(text.substring(start + 9, end));
    return value is Map<String, dynamic> ? value : null;
  } on FormatException {
    return null;
  }
}

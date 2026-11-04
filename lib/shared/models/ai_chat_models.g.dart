// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ai_chat_models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AiMessage _$AiMessageFromJson(Map<String, dynamic> json) => AiMessage(
  id: json['id'] as String,
  role: $enumDecode(_$AiMessageRoleEnumMap, json['role']),
  type:
      $enumDecodeNullable(_$AiMessageTypeEnumMap, json['type']) ??
      AiMessageType.text,
  content: json['content'] as String,
  timestamp: DateTime.parse(json['timestamp'] as String),
  metadata: json['metadata'] as Map<String, dynamic>?,
  isStreaming: json['is_streaming'] as bool? ?? false,
  blocks: json['blocks'] == null
      ? const []
      : const _AiMessageBlockListConverter().fromJson(json['blocks'] as List),
  usage: json['usage'] == null
      ? null
      : AiUsage.fromJson(json['usage'] as Map<String, dynamic>),
);

Map<String, dynamic> _$AiMessageToJson(AiMessage instance) => <String, dynamic>{
  'id': instance.id,
  'role': _$AiMessageRoleEnumMap[instance.role]!,
  'type': _$AiMessageTypeEnumMap[instance.type]!,
  'content': instance.content,
  'timestamp': instance.timestamp.toIso8601String(),
  'metadata': instance.metadata,
  'is_streaming': instance.isStreaming,
  'blocks': const _AiMessageBlockListConverter().toJson(instance.blocks),
  'usage': instance.usage,
};

const _$AiMessageRoleEnumMap = {
  AiMessageRole.user: 'user',
  AiMessageRole.assistant: 'assistant',
  AiMessageRole.system: 'system',
};

const _$AiMessageTypeEnumMap = {
  AiMessageType.text: 'text',
  AiMessageType.rewrite: 'rewrite',
  AiMessageType.outline: 'outline',
  AiMessageType.chapter_content: 'chapter_content',
  AiMessageType.diff: 'diff',
  AiMessageType.tool_result: 'tool_result',
  AiMessageType.compact_summary: 'compact_summary',
  AiMessageType.system_remind: 'system_remind',
};

RewriteSuggestion _$RewriteSuggestionFromJson(Map<String, dynamic> json) =>
    RewriteSuggestion(
      id: json['id'] as String,
      originalText: json['original_text'] as String,
      suggestedText: json['suggested_text'] as String,
      explanation: json['explanation'] as String,
      isAccepted: json['is_accepted'] as bool? ?? false,
    );

Map<String, dynamic> _$RewriteSuggestionToJson(RewriteSuggestion instance) =>
    <String, dynamic>{
      'id': instance.id,
      'original_text': instance.originalText,
      'suggested_text': instance.suggestedText,
      'explanation': instance.explanation,
      'is_accepted': instance.isAccepted,
    };

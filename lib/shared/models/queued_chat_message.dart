// 职责: 定义 AI 聊天请求进行中可跨 UI 生命周期保存的待发送消息，并提供「本轮使用的 slash chip（skill / subagent）名」写入/读回用户消息 metadata 的编解码。
// 关联文件:
//   lib/shared/services/ai/chat_session_controller.dart
//   lib/shared/providers/ai_providers.dart
//   lib/shared/services/ai/chat_turn_runner.dart
//   lib/shared/models/novel_workspace.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
import '../agent/message.dart';
import 'ai_message_block.dart';
import 'novel_workspace.dart';
import 'ai_session_mode.dart';

/// 用户消息 metadata 中记录「本轮发送使用的技能名」的 key（值为 `List<String>`）。
///
/// skill chip 不走 `<user-remind>` 正文标签（那是 model-only 的直接加载链路），
/// 因此单独写入 metadata，供聊天记录气泡展示，且随消息持久化。
const String kAiMessageSkillNamesKey = 'skill_names';

/// 用户消息 metadata 中记录「本轮发送点名的 subagent 名」的 key（值为 `List<String>`）。
///
/// subagent chip 同样只走 model-only 的软偏好提示，处理方式与 skill chip 一致。
const String kAiMessageSubagentNamesKey = 'subagent_names';

/// 从引用列表提取 slash chip（skill / subagent）的名称，生成写入用户消息
/// metadata 的 map；两类 chip 都没有时返回 null（不污染 metadata）。
Map<String, dynamic>? slashChipsMetadataFromReferences(
  List<AiContextReference> refs,
) {
  final skillNames = <String>[];
  final subagentNames = <String>[];
  for (final ref in refs) {
    final name = ref.label.trim();
    if (name.isEmpty) {
      continue;
    }
    switch (ref.kind) {
      case AiContextReferenceKind.skill:
        skillNames.add(name);
      case AiContextReferenceKind.subagent:
        subagentNames.add(name);
      case AiContextReferenceKind.workspace:
      case AiContextReferenceKind.agent_rule:
      case AiContextReferenceKind.file:
      case AiContextReferenceKind.selection:
        break;
    }
  }
  if (skillNames.isEmpty && subagentNames.isEmpty) {
    return null;
  }
  return <String, dynamic>{
    if (skillNames.isNotEmpty) kAiMessageSkillNamesKey: skillNames,
    if (subagentNames.isNotEmpty) kAiMessageSubagentNamesKey: subagentNames,
  };
}

/// 从用户消息 metadata 读回「本轮使用的技能名」列表；无记录时返回空列表。
List<String> skillNamesFromMessageMetadata(Map<String, dynamic>? metadata) =>
    _namesFromMessageMetadata(metadata, kAiMessageSkillNamesKey);

/// 从用户消息 metadata 读回「本轮点名的 subagent 名」列表；无记录时返回空列表。
List<String> subagentNamesFromMessageMetadata(Map<String, dynamic>? metadata) =>
    _namesFromMessageMetadata(metadata, kAiMessageSubagentNamesKey);

List<String> _namesFromMessageMetadata(
  Map<String, dynamic>? metadata,
  String key,
) {
  final raw = metadata?[key];
  if (raw is! List) {
    return const [];
  }
  return raw
      .whereType<String>()
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty)
      .toList(growable: false);
}

/// 待发送的 handoff 接力（封面工作室等场景把一段 prompt 暂存，发送时拼入正文）。
class PendingChatHandoff {
  const PendingChatHandoff({
    required this.label,
    required this.content,
    this.autoSend = false,
    this.references = const [],
    this.initialText,
    this.sourceSessionId,
    this.sourceMode,
    this.providerId,
    this.model,
    this.reasoningEffort,
  });

  final String label;
  final String content;
  final bool autoSend;
  final List<AiContextReference> references;
  final String? initialText;
  final String? sourceSessionId;
  final AiSessionMode? sourceMode;
  final String? providerId;
  final String? model;
  final String? reasoningEffort;

  bool get isSessionContinuation => sourceSessionId != null;
}

/// in-flight 期间再次发送时排队的消息。
///
/// 默认等本轮结束后由 ChatSessionController 接力发送。「立刻发送」会中断当前回复。
/// 聊天界面卸载时，[sendOnNextTurn] 标记已交给后台 Agent 下一轮消费的消息。
class QueuedChatMessage {
  const QueuedChatMessage({
    required this.text,
    required this.agentText,
    this.blocks = const [],
    this.modelBlocks = const [],
    this.userMessageId,
    required this.references,
    this.sessionId,
    this.handoff,
    this.sendOnNextTurn = false,
  });

  final String text;
  final String agentText;
  final List<AiMessageBlock> blocks;
  final List<MessageBlock> modelBlocks;
  final String? userMessageId;
  final List<AiContextReference> references;

  /// 排队时所属的会话 id，避免切换会话后消息误发到当前会话。
  final String? sessionId;

  final PendingChatHandoff? handoff;

  /// 已 stage 到当前 in-flight agent 的下一轮 LLM，不再走 finally 的完整 send。
  final bool sendOnNextTurn;

  QueuedChatMessage copyWith({bool? sendOnNextTurn}) {
    return QueuedChatMessage(
      text: text,
      agentText: agentText,
      blocks: blocks,
      modelBlocks: modelBlocks,
      userMessageId: userMessageId,
      references: references,
      sessionId: sessionId,
      handoff: handoff,
      sendOnNextTurn: sendOnNextTurn ?? this.sendOnNextTurn,
    );
  }
}

// 特殊 case: AiMessage 不直接用 Drift AiChatMessage DataClass
// AiMessage 是面向 UI/stream 的领域模型，包含 AiMessageRole/AiMessageType 枚举、
// isStreaming 瞬态状态、AiUsage 汇总、工厂构造器 (user/assistant/system) 等。
// Drift AiChatMessage 是 DB 实体，字段面向持久化存储（token 分列、sequence、sessionId）。
// 两者抽象层级不同，非简单字段重复，因此保留 AiMessage 作为领域模型。
// providers 层和 session_persistence 负责 AiChatMessage ↔ AiMessage 转换。

import 'package:json_annotation/json_annotation.dart';

import '../agent/client.dart';
import '../database/app_database.dart' show Novel, notDeletedSentinel;
import 'ai_message_block.dart';
import 'content_kind.dart';

export 'ai_message_block.dart';

part 'ai_chat_models.g.dart';

enum AiMessageRole { user, assistant, system }

enum AiMessageType {
  text,
  rewrite,
  outline,
  chapter_content,
  diff,
  tool_result,
  compact_summary,

  /// 运行时状态提醒（`<system-remind>`）：以 user role 持久化、参与 agent
  /// history 重建，但不在聊天 UI 中渲染。
  system_remind,
}

class _AiMessageBlockListConverter
    implements JsonConverter<List<AiMessageBlock>, List<dynamic>> {
  const _AiMessageBlockListConverter();

  @override
  List<AiMessageBlock> fromJson(List<dynamic> json) {
    return json
        .map((e) => AiMessageBlock.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  List<dynamic> toJson(List<AiMessageBlock> object) {
    return object.map((e) => e.toJson()).toList();
  }
}

@JsonSerializable(fieldRename: FieldRename.snake)
class AiMessage {
  final String id;
  final AiMessageRole role;
  final AiMessageType type;
  final String content;
  final DateTime timestamp;
  final Map<String, dynamic>? metadata;
  final bool isStreaming;
  @_AiMessageBlockListConverter()
  final List<AiMessageBlock> blocks;

  /// Token usage 统计 (仅 assistant 消息有)
  final AiUsage? usage;

  const AiMessage({
    required this.id,
    required this.role,
    this.type = AiMessageType.text,
    required this.content,
    required this.timestamp,
    this.metadata,
    this.isStreaming = false,
    this.blocks = const [],
    this.usage,
  });

  factory AiMessage.user({
    required String id,
    required String content,
    AiMessageType type = AiMessageType.text,
    Map<String, dynamic>? metadata,
    List<AiMessageBlock> blocks = const [],
  }) {
    return AiMessage(
      id: id,
      role: AiMessageRole.user,
      type: type,
      content: content,
      timestamp: DateTime.now(),
      metadata: metadata,
      blocks: blocks,
    );
  }

  factory AiMessage.assistant({
    required String id,
    required String content,
    AiMessageType type = AiMessageType.text,
    Map<String, dynamic>? metadata,
    bool isStreaming = false,
    List<AiMessageBlock> blocks = const [],
    AiUsage? usage,
  }) {
    return AiMessage(
      id: id,
      role: AiMessageRole.assistant,
      type: type,
      content: content,
      timestamp: DateTime.now(),
      metadata: metadata,
      isStreaming: isStreaming,
      blocks: blocks,
      usage: usage,
    );
  }

  factory AiMessage.system({required String id, required String content}) {
    return AiMessage(
      id: id,
      role: AiMessageRole.system,
      content: content,
      timestamp: DateTime.now(),
    );
  }

  AiMessage copyWith({
    String? id,
    AiMessageRole? role,
    AiMessageType? type,
    String? content,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
    bool? isStreaming,
    List<AiMessageBlock>? blocks,
    AiUsage? usage,
  }) {
    return AiMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      type: type ?? this.type,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      metadata: metadata ?? this.metadata,
      isStreaming: isStreaming ?? this.isStreaming,
      blocks: blocks ?? this.blocks,
      usage: usage ?? this.usage,
    );
  }

  String get effectiveText {
    if (blocks.any((b) => b is AiAttachmentBlock)) {
      return content;
    }
    if (blocks.isEmpty) return content;
    final buffer = StringBuffer();
    for (final block in blocks) {
      if (block is AiTextBlock) {
        buffer.write(block.text);
      }
    }
    final aggregated = buffer.toString();
    return aggregated.isEmpty ? content : aggregated;
  }

  factory AiMessage.fromJson(Map<String, dynamic> json) =>
      _$AiMessageFromJson(json);

  Map<String, dynamic> toJson() => _$AiMessageToJson(this);
}

@JsonSerializable(fieldRename: FieldRename.snake)
class RewriteSuggestion {
  final String id;
  final String originalText;
  final String suggestedText;
  final String explanation;
  final bool isAccepted;

  const RewriteSuggestion({
    required this.id,
    required this.originalText,
    required this.suggestedText,
    required this.explanation,
    this.isAccepted = false,
  });

  RewriteSuggestion copyWith({
    String? id,
    String? originalText,
    String? suggestedText,
    String? explanation,
    bool? isAccepted,
  }) {
    return RewriteSuggestion(
      id: id ?? this.id,
      originalText: originalText ?? this.originalText,
      suggestedText: suggestedText ?? this.suggestedText,
      explanation: explanation ?? this.explanation,
      isAccepted: isAccepted ?? this.isAccepted,
    );
  }

  factory RewriteSuggestion.fromJson(Map<String, dynamic> json) =>
      _$RewriteSuggestionFromJson(json);

  Map<String, dynamic> toJson() => _$RewriteSuggestionToJson(this);
}

enum ChapterWritingPhase { idle }

class ChapterWritingState {
  final String chapterId;

  const ChapterWritingState({required this.chapterId});

  factory ChapterWritingState.idle(String chapterId) {
    return ChapterWritingState(chapterId: chapterId);
  }

  ChapterWritingState copyWith({String? chapterId}) {
    return ChapterWritingState(chapterId: chapterId ?? this.chapterId);
  }
}

class AiSessionContext {
  final String? databasePath;

  /// 当前作品的稳定业务 ID；与内容数据库路径分开传递。
  final String? workId;

  /// 关联原作的稳定作品 ID；null 表示未关联。
  final String? sourceNovelId;

  /// 当前作品的稳定分类；与 [sourceNovelId] 组合表达来源关系。
  final String? workType;
  final String? novelName;
  // 无作品的聊天允许不传内容类型；作品上下文注入必须检查是否显式传入。
  final String? _contentKind;

  String get contentKind => _contentKind ?? contentKindNovel;
  bool get hasExplicitContentKind => _contentKind != null;
  final String? currentSeasonId;
  final String? currentEpisodeId;
  final bool hasMultipleSeasons;
  final String? userRules;
  final String? chapterId;
  final String? chapterTitle;
  final int? chapterNum;
  final String? chapterOutline;
  final String? chapterContent;
  final String? workspaceType;

  /// 当前作品在 AI 工作区路径空间中的绝对根路径，如 `/works/{work_id}`。
  /// 模型据此理解相对资源路径的解析起点。
  final String? workspacePath;
  final String? workspaceTitle;
  final String? workspaceContent;
  final String? outline;
  final String? previousContent;
  final List<String> characterProfiles;
  final List<String> worldbuildingNotes;
  final List<String> materialNotes;
  final String? username;

  /// 当前小说已创建的 chat 会话总数（不含 council/monologue 等特殊 mode；SQL COUNT）。
  /// 用于 setup_phase 门控，由 [novelChatSessionCountProvider] 提供。
  final int? novelChatSessionCount;

  const AiSessionContext({
    this.databasePath,
    this.workId,
    this.sourceNovelId,
    this.workType,
    this.novelName,
    this._contentKind,
    this.currentSeasonId,
    this.currentEpisodeId,
    this.hasMultipleSeasons = false,
    this.userRules,
    this.chapterId,
    this.chapterTitle,
    this.chapterNum,
    this.chapterOutline,
    this.chapterContent,
    this.workspaceType,
    this.workspacePath,
    this.workspaceTitle,
    this.workspaceContent,
    this.outline,
    this.previousContent,
    this.characterProfiles = const [],
    this.worldbuildingNotes = const [],
    this.materialNotes = const [],
    this.username,
    this.novelChatSessionCount,
  });

  bool get hasChapter => chapterId != null;

  /// 从已加载作品统一填充作品身份，保留本次聊天的章节、规则等上下文。
  AiSessionContext withWork(Novel novel) {
    if (novel.id.trim().isEmpty) {
      throw ArgumentError.value(
        novel.id,
        'novel.id',
        'Chat requires a work ID.',
      );
    }
    if (novel.deletedAt != notDeletedSentinel) {
      throw StateError('Current work is deleted.');
    }
    return copyWith(
      workId: novel.id,
      novelName: novel.title,
      contentKind: novel.contentKind,
      workType: novel.type,
      sourceNovelId: novel.sourceNovelId,
      clearSourceNovelId: novel.sourceNovelId == null,
      workspacePath: '/works/${novel.id}',
    );
  }

  AiSessionContext copyWith({
    String? databasePath,
    String? workId,
    String? sourceNovelId,
    bool clearSourceNovelId = false,
    String? workType,
    String? novelName,
    String? contentKind,
    String? currentSeasonId,
    String? currentEpisodeId,
    bool? hasMultipleSeasons,
    String? userRules,
    String? chapterId,
    String? chapterTitle,
    int? chapterNum,
    String? chapterOutline,
    String? chapterContent,
    String? workspaceType,
    String? workspacePath,
    String? workspaceTitle,
    String? workspaceContent,
    String? outline,
    String? previousContent,
    List<String>? characterProfiles,
    List<String>? worldbuildingNotes,
    List<String>? materialNotes,
    String? username,
    int? novelChatSessionCount,
  }) {
    return AiSessionContext(
      databasePath: databasePath ?? this.databasePath,
      workId: workId ?? this.workId,
      sourceNovelId: clearSourceNovelId
          ? null
          : sourceNovelId ?? this.sourceNovelId,
      workType: workType ?? this.workType,
      novelName: novelName ?? this.novelName,
      contentKind: contentKind ?? _contentKind,
      currentSeasonId: currentSeasonId ?? this.currentSeasonId,
      currentEpisodeId: currentEpisodeId ?? this.currentEpisodeId,
      hasMultipleSeasons: hasMultipleSeasons ?? this.hasMultipleSeasons,
      userRules: userRules ?? this.userRules,
      chapterId: chapterId ?? this.chapterId,
      chapterTitle: chapterTitle ?? this.chapterTitle,
      chapterNum: chapterNum ?? this.chapterNum,
      chapterOutline: chapterOutline ?? this.chapterOutline,
      chapterContent: chapterContent ?? this.chapterContent,
      workspaceType: workspaceType ?? this.workspaceType,
      workspacePath: workspacePath ?? this.workspacePath,
      workspaceTitle: workspaceTitle ?? this.workspaceTitle,
      workspaceContent: workspaceContent ?? this.workspaceContent,
      outline: outline ?? this.outline,
      previousContent: previousContent ?? this.previousContent,
      characterProfiles: characterProfiles ?? this.characterProfiles,
      worldbuildingNotes: worldbuildingNotes ?? this.worldbuildingNotes,
      materialNotes: materialNotes ?? this.materialNotes,
      username: username ?? this.username,
      novelChatSessionCount:
          novelChatSessionCount ?? this.novelChatSessionCount,
    );
  }
}

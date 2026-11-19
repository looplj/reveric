// 职责: 构造来源会话引用草稿，并保留已有模式转换的上下文交接入口。
// 关联文件:
//   lib/shared/services/ai/session_persistence.dart
//   lib/shared/services/ai/xml_utils.dart
//   lib/shared/models/ai_chat_models.dart
//   lib/desktop/widgets/ai/chat/message_renderer.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
import '../../database/novel_content_database.dart';
import '../../database/app_database.dart';
import '../../heuristic/chat_next_action.dart';
import '../../models/ai_chat_session_id.dart';
import '../../models/queued_chat_message.dart';
import '../../models/novel_workspace.dart';
import '../../models/ai_chat_models.dart';
import '../../models/ai_session_mode.dart';
import '../../utils/random_id.dart';
import 'session_persistence.dart';
import 'xml_utils.dart';

const sessionContinuationInstruction = '继续来源对话中的任务。';

PendingChatHandoff? buildWorkActionHandoff(
  WorkActionTarget target, {
  required String sourceWorkId,
  required String? sourceSessionId,
  required String sourceTitle,
  required AiSessionMode sourceMode,
}) {
  final prompt = target.prompt;
  if (prompt == null) {
    return null;
  }
  if (sourceSessionId == null || isTemporaryAiChatSessionId(sourceSessionId)) {
    return PendingChatHandoff(label: '', content: '', initialText: prompt);
  }
  return buildSessionContinuationDraft(
    workId: sourceWorkId,
    sourceSessionId: sourceSessionId,
    sourceTitle: sourceTitle,
    sourceMode: sourceMode,
    initialText: prompt,
  );
}

/// Only returns a real, available source with saved messages; never creates data.
Future<AiChatSession?> loadSessionContinuationSource({
  required AppDatabase database,
  required NovelContentDatabase contentDatabase,
  required String workId,
  required String sessionId,
}) async {
  final source = await database.aiChatSessionDao.getById(
    sessionId,
    novelId: workId,
  );
  if (source == null ||
      !await contentDatabase.aiChatMessageDao.hasSavedMessages(sessionId)) {
    return null;
  }
  return source;
}

/// The caller supplies a validated descriptor and the current composer draft.
PendingChatHandoff buildSessionContinuation({
  required AiChatSession source,
  String initialText = '',
  List<AiContextReference> references = const [],
  ({String? providerId, String? model, String? reasoningEffort})?
  modelSelection,
}) => buildSessionContinuationDraft(
  workId: source.novelId,
  sourceSessionId: source.id,
  sourceTitle: source.title,
  sourceMode: AiSessionMode.fromString(source.mode),
  initialText: initialText,
  references: references,
  modelSelection: modelSelection,
);

/// 从调用方已持有的会话信息构造延续草稿，不重新读取来源会话。
PendingChatHandoff buildSessionContinuationDraft({
  required String workId,
  required String sourceSessionId,
  required String sourceTitle,
  required AiSessionMode sourceMode,
  String initialText = '',
  List<AiContextReference> references = const [],
  ({String? providerId, String? model, String? reasoningEffort})?
  modelSelection,
}) {
  final work = escapeXmlAttribute(workId);
  final session = escapeXmlAttribute(sourceSessionId);
  final title = sourceTitle.trim().isEmpty ? sourceSessionId : sourceTitle;
  return PendingChatHandoff(
    label: title,
    sourceSessionId: sourceSessionId,
    sourceMode: sourceMode,
    initialText: initialText,
    references: List.unmodifiable(references),
    providerId: modelSelection?.providerId,
    model: modelSelection?.model,
    reasoningEffort: modelSelection?.reasoningEffort,
    content:
        '<user-remind type="session" path="ai-session:$session" work-id="$work" '
        'label="${escapeXmlAttribute(title)}" mode="${escapeXmlAttribute(sourceMode.value)}">\n'
        'This conversation continues work from the referenced session with fresh context.\n'
        'When earlier details are needed, use Run sessions with work_id="$work" and session_id="$session".\n'
        'Read only the history relevant to the current request.\n'
        '</user-remind>',
  );
}

class AiHandoffTarget {
  const AiHandoffTarget({
    required this.mode,
    required this.agentSlug,
    required this.agentName,
    this.providerId,
    this.model,
  });

  final AiSessionMode mode;
  final String agentSlug;
  final String agentName;
  final String? providerId;
  final String? model;
}

class AiHandoffReference {
  const AiHandoffReference({
    required this.type,
    required this.path,
    required this.label,
  });

  final String type;
  final String path;
  final String label;
}

/// AI 模式（小剧场/议会等）交接到 chat 的结果。
/// [targetSessionId] 仅在要求创建目标会话时非空。
class AiModeHandoff {
  const AiModeHandoff({
    required this.sourceSessionId,
    required this.sourceTitle,
    required this.chatTitle,
    required this.context,
    this.targetSessionId,
  });

  final String sourceSessionId;
  final String sourceTitle;
  final String chatTitle;
  final AiHandoffContext context;
  final String? targetSessionId;
}

class AiHandoffContext {
  const AiHandoffContext({
    required this.sourceSessionId,
    required this.sourceTitle,
    required this.fromMode,
    required this.fromAgentName,
    required this.target,
    required this.summary,
    this.fromAgentSlug,
    this.decisions = const [],
    this.constraints = const [],
    this.openQuestions = const [],
    this.references = const [],
  });

  final String sourceSessionId;
  final String sourceTitle;
  final AiSessionMode fromMode;
  final String fromAgentName;
  final String? fromAgentSlug;
  final AiHandoffTarget target;
  final String summary;
  final List<String> decisions;
  final List<String> constraints;
  final List<String> openQuestions;
  final List<AiHandoffReference> references;

  String toMessageContent() {
    final sourceLabel = sourceTitle.trim().isEmpty
        ? sourceSessionId
        : sourceTitle;
    final buffer = StringBuffer()
      ..writeln(
        '<session-handoff '
        'from-session-id="${escapeXmlAttribute(sourceSessionId)}" '
        'from-mode="${escapeXmlAttribute(fromMode.value)}" '
        'to-mode="${escapeXmlAttribute(target.mode.value)}" '
        'to-agent-slug="${escapeXmlAttribute(target.agentSlug)}" '
        'source-session-id="${escapeXmlAttribute(sourceSessionId)}" '
        'source-title="${escapeXmlAttribute(sourceLabel)}"/>',
      )
      ..writeln(
        "<user-remind type='session' "
        "path='${escapeXmlAttribute('ai-session:$sourceSessionId')}' "
        "label='${escapeXmlAttribute(sourceLabel)}' "
        "mode='${escapeXmlAttribute(fromMode.value)}'>"
        'Open the source session when the original context is needed.'
        '</user-remind>',
      );

    for (final ref in references) {
      buffer.writeln(
        "<user-remind type='${escapeXmlAttribute(ref.type)}' "
        "path='${escapeXmlAttribute(ref.path)}' "
        "label='${escapeXmlAttribute(ref.label)}'>"
        'Read this referenced context before continuing the handoff.'
        '</user-remind>',
      );
    }

    _writeSection(buffer, 'Summary', [summary]);
    _writeSection(buffer, 'Decisions', decisions);
    _writeSection(buffer, 'Constraints', constraints);
    _writeSection(buffer, 'Open questions', openQuestions);
    _writeSection(buffer, 'Next steps', [
      'If this handoff follows a published or completed chapter, ask the orchestrator to SpawnAgent 编年史者 to extract chapter facts, update continuity state, and整理角色/实体关系 with Read, GraphSearch, Create, Remove, and Write before continuing long-form writing.',
    ]);
    return buffer.toString().trim();
  }

  static void _writeSection(
    StringBuffer buffer,
    String title,
    List<String> values,
  ) {
    final cleaned = values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (cleaned.isEmpty) {
      return;
    }
    buffer
      ..writeln()
      ..writeln('## $title');
    for (final value in cleaned) {
      buffer.writeln('- $value');
    }
  }
}

class AiHandoffService {
  const AiHandoffService();

  Future<String> createTargetSession({
    required AiSessionPersistenceService persistence,
    required NovelContentDatabase novelDatabase,
    required AiHandoffContext context,
    required String title,
  }) async {
    final targetSessionId = buildRandomId('ai_session');
    await persistence.createActiveSession(
      id: targetSessionId,
      title: title,
      provider: context.target.providerId,
      model: context.target.model,
      mode: context.target.mode.value,
      agentSlug: context.target.agentSlug,
    );
    await persistence.saveMessages(
      sessionId: targetSessionId,
      messages: [
        AiMessage.user(
          id: '${targetSessionId}_handoff',
          content: context.toMessageContent(),
          metadata: {
            'handoff': true,
            'sourceSessionId': context.sourceSessionId,
            'sourceMode': context.fromMode.value,
            'sourceTitle': context.sourceTitle,
            'targetMode': context.target.mode.value,
            'targetAgentSlug': context.target.agentSlug,
          },
        ),
      ],
      novelDatabase: novelDatabase,
    );
    return targetSessionId;
  }
}

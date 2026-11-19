// 职责: 将聊天用户消息的控制标签解析为可见正文和引用元信息。
// 关联文件:
//   lib/shared/models/ai_session_mode.dart
//   lib/shared/widgets/ai/chat/chat_message_parts.dart
//   lib/shared/services/production/canvas_package_conversations.dart

import 'ai_session_mode.dart';

/// 用户消息里的引用标签（`<user-remind>`）。
class UserRemindReference {
  const UserRemindReference({
    required this.type,
    required this.path,
    required this.label,
    this.mode,
    this.workId,
  });

  final String type;
  final String path;
  final String label;
  final AiSessionMode? mode;
  final String? workId;
}

/// 接力（handoff）引用：从某个会话/agent 接力而来。
class AgentHandoffReference {
  const AgentHandoffReference({
    required this.fromAgent,
    required this.toAgent,
    required this.fromMode,
    required this.toMode,
    this.sourceSessionId,
    this.sourceTitle,
  });

  final String fromAgent;
  final String toAgent;
  final AiSessionMode fromMode;
  final AiSessionMode toMode;
  final String? sourceSessionId;
  final String? sourceTitle;
}

/// 解析后的用户消息展示模型：剥离控制标签后的正文 + 引用 + handoff。
class UserMessagePresentation {
  const UserMessagePresentation({
    required this.text,
    required this.references,
    this.handoff,
  });

  final String text;
  final List<UserRemindReference> references;
  final AgentHandoffReference? handoff;
}

/// 从用户消息正文里剥离 `<user-remind>`/handoff 控制标签，提取引用与 handoff。
UserMessagePresentation parseUserMessagePresentation(
  String raw, {
  bool withinHandoff = false,
}) {
  final references = <UserRemindReference>[];
  AgentHandoffReference? handoffRef;
  String processedText = raw;

  final userRemindPattern = RegExp(
    r'<user-remind\b([^>]*)>.*?</user-remind>',
    multiLine: true,
    dotAll: true,
  );
  processedText = processedText.replaceAllMapped(userRemindPattern, (match) {
    final attrs = _parseUserRemindAttributes(match.group(1) ?? '');
    references.add(
      UserRemindReference(
        type: attrs['type'] ?? '',
        path: attrs['path'] ?? '',
        workId: attrs['work-id'],
        label: attrs['label'] ?? attrs['path'] ?? attrs['type'] ?? '',
        mode: attrs['mode'] == null
            ? null
            : AiSessionMode.fromString(attrs['mode']!),
      ),
    );
    return '';
  });

  final handoffPattern = RegExp(
    r'<(?:agent|session)-handoff\b([^>]*)/>',
    multiLine: true,
  );
  final handoffMatch = handoffPattern.firstMatch(processedText);
  if (handoffMatch != null) {
    final attrs = _parseUserRemindAttributes(handoffMatch.group(1) ?? '');
    handoffRef = AgentHandoffReference(
      fromAgent: attrs['from-agent'] ?? attrs['from'] ?? '',
      toAgent: attrs['to-agent'] ?? attrs['to'] ?? '',
      fromMode: AiSessionMode.fromString(attrs['from-mode'] ?? 'chat'),
      toMode: AiSessionMode.fromString(attrs['to-mode'] ?? 'chat'),
      sourceSessionId: attrs['source-session-id'] ?? attrs['from-session-id'],
      sourceTitle: attrs['source-title'],
    );
    processedText = processedText.replaceAll(handoffPattern, '').trim();
  }

  if (handoffRef != null) {
    final visibleReferences = references
        .where((reference) => reference.type != 'session')
        .toList(growable: false);
    return UserMessagePresentation(
      text: _visibleHandoffText(processedText),
      references: visibleReferences,
      handoff: handoffRef,
    );
  }

  return UserMessagePresentation(
    text: withinHandoff
        ? _visibleHandoffText(processedText)
        : processedText.trim(),
    references: references,
    handoff: handoffRef,
  );
}

Map<String, String> _parseUserRemindAttributes(String raw) {
  final attrs = <String, String>{};
  final attrPattern = RegExp(r'''([a-zA-Z_][\w:-]*)\s*=\s*(['"])(.*?)\2''');
  for (final match in attrPattern.allMatches(raw)) {
    final key = match.group(1);
    final value = match.group(3);
    if (key == null || value == null) {
      continue;
    }
    attrs[key] = _decodeXmlEntities(value);
  }
  return attrs;
}

String _decodeXmlEntities(String value) {
  return value
      .replaceAll('&apos;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
}

/// 用于复制的纯文本（含引用/handoff label）。
String userMessageCopyText(UserMessagePresentation presentation) {
  final handoff = presentation.handoff;
  if (handoff != null) {
    final handoffLabel = _handoffDisplayLabel(handoff);
    if (presentation.text.isEmpty) {
      return handoffLabel;
    }
    return '$handoffLabel\n${presentation.text}';
  }
  final refs = presentation.references
      .map((ref) => '[${ref.type}: ${ref.label}]')
      .join(' ');
  if (refs.isEmpty) {
    return presentation.text;
  }
  if (presentation.text.isEmpty) {
    return refs;
  }
  return '$refs\n${presentation.text}';
}

String _handoffDisplayLabel(AgentHandoffReference handoff) {
  final sourceTitle = handoff.sourceTitle?.trim();
  if (sourceTitle != null && sourceTitle.isNotEmpty) {
    return sourceTitle;
  }
  if (handoff.fromAgent.isEmpty && handoff.toAgent.isEmpty) {
    return handoff.sourceSessionId ?? 'Session handoff';
  }
  return '${handoff.fromAgent} → ${handoff.toAgent}';
}

String _visibleHandoffText(String processedText) {
  final text = processedText.trim();
  if (text.isEmpty) {
    return '';
  }
  final detailSection = RegExp(
    r'(^|\n)## (Summary|Decisions|Constraints|Open questions|Next steps)\b',
    multiLine: true,
  ).firstMatch(text);
  if (detailSection == null) {
    return text;
  }
  return text.substring(0, detailSection.start).trim();
}

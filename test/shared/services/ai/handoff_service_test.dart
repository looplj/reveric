// 职责: 测试 AI session handoff 上下文消息格式，确保目标 agent 可读且 UI 可引用来源 session。
// 关联文件:
//   lib/shared/services/ai/handoff_service.dart
//   lib/desktop/widgets/ai/chat/message_renderer.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/heuristic/chat_next_action.dart';
import 'package:reveric/shared/models/ai_session_mode.dart';
import 'package:reveric/shared/services/ai/handoff_service.dart';

void main() {
  test(
    'work action carries an editable draft and the original work reference',
    () {
      const target = WorkActionTarget('new_work', prompt: '写第一集');
      final handoff = buildWorkActionHandoff(
        target,
        sourceWorkId: 'original',
        sourceSessionId: 'source_session',
        sourceTitle: '改编讨论',
        sourceMode: AiSessionMode.chat,
      )!;
      expect(handoff.initialText, '写第一集');
      expect(handoff.autoSend, isFalse);
      expect(handoff.content, contains('work-id="original"'));
      expect(handoff.content, contains('path="ai-session:source_session"'));
      expect(
        buildWorkActionHandoff(
          const WorkActionTarget('new_work'),
          sourceWorkId: 'original',
          sourceSessionId: 'source_session',
          sourceTitle: '改编讨论',
          sourceMode: AiSessionMode.chat,
        ),
        isNull,
      );
    },
  );

  test(
    'current chat continuation preserves its source and editable prompt without sending',
    () {
      final draft = buildSessionContinuationDraft(
        workId: 'work_1',
        sourceSessionId: 'current_session',
        sourceTitle: '讨论 "人物" & 剧情',
        sourceMode: AiSessionMode.chat,
        initialText: '按刚才确定的方向继续写',
        modelSelection: (
          providerId: 'provider_1',
          model: 'model_1',
          reasoningEffort: 'high',
        ),
      );

      expect(draft.sourceSessionId, 'current_session');
      expect(draft.sourceMode, AiSessionMode.chat);
      expect(draft.label, '讨论 "人物" & 剧情');
      expect(draft.content, contains('path="ai-session:current_session"'));
      expect(draft.content, contains('work-id="work_1"'));
      expect(draft.content, contains('label="讨论 &quot;人物&quot; &amp; 剧情"'));
      expect(draft.initialText, '按刚才确定的方向继续写');
      expect(draft.content, isNot(contains(draft.initialText!)));
      expect(draft.autoSend, isFalse);
      expect(draft.providerId, 'provider_1');
      expect(draft.model, 'model_1');
      expect(draft.reasoningEffort, 'high');
    },
  );

  test('handoff context serializes source session reference and sections', () {
    const context = AiHandoffContext(
      sourceSessionId: 'source_1',
      sourceTitle: 'Council session',
      fromMode: AiSessionMode.council,
      fromAgentName: 'Council',
      target: AiHandoffTarget(
        mode: AiSessionMode.chat,
        agentSlug: 'writer',
        agentName: 'Writer',
      ),
      summary: 'The council picked a conflict escalation.',
      decisions: ['Use the second outline option.'],
      constraints: ['Keep the protagonist unreliable.'],
      openQuestions: ['Confirm the ending tone.'],
    );

    final content = context.toMessageContent();

    expect(content, contains('<session-handoff '));
    expect(content, contains('from-mode="council"'));
    expect(content, contains('to-agent-slug="writer"'));
    expect(content, contains('source-session-id="source_1"'));
    expect(content, contains("type='session'"));
    expect(content, contains("path='ai-session:source_1'"));
    expect(content, contains("mode='council'"));
    expect(content, contains('## Summary'));
    expect(content, contains('The council picked a conflict escalation.'));
    expect(content, contains('## Decisions'));
    expect(content, contains('Use the second outline option.'));
    expect(content, contains('## Constraints'));
    expect(content, contains('Keep the protagonist unreliable.'));
    expect(content, contains('## Open questions'));
    expect(content, contains('Confirm the ending tone.'));
    expect(content, contains('## Next steps'));
    expect(content, contains('SpawnAgent 编年史者'));
    expect(content, contains('整理角色/实体关系'));
  });
}

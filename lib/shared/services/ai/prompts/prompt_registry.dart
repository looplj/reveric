// 职责: Prompt 注册表 — 集中声明内置 prompt 清单、模板路径和归属模块。
// 关联文件:
//   lib/shared/services/ai/prompts/prompt_definition.dart
//   lib/shared/services/ai/prompts/prompt_id.dart
//   lib/shared/services/ai/prompt_template.dart

import 'prompt_definition.dart';
import 'prompt_id.dart';

abstract final class PromptRegistry {
  static const definitions = <PromptDefinition>[
    PromptDefinition(
      id: PromptId.systemCouncilSummarizer,
      kind: PromptKind.system,
      owner: 'council',
      templatePath: 'assets/prompts/system/council_summarizer',
    ),
    PromptDefinition(
      id: PromptId.systemContextCompaction,
      kind: PromptKind.system,
      owner: 'chat',
      templatePath: 'assets/prompts/system/context_compaction',
    ),

    // Primary agents.
    PromptDefinition(
      id: PromptId.agentOrchestrator,
      kind: PromptKind.agent,
      owner: 'chat',
      templatePath: 'assets/prompts/agent/orchestrator',
    ),
    PromptDefinition(
      id: PromptId.agentAssistant,
      kind: PromptKind.agent,
      owner: 'assistant',
      templatePath: 'assets/prompts/agent/assistant',
    ),
    PromptDefinition(
      id: PromptId.agentWriter,
      kind: PromptKind.agent,
      owner: 'subagent',
      templatePath: 'assets/prompts/agent/writer',
      customizable: true,
    ),
    PromptDefinition(
      id: PromptId.agentChronicler,
      kind: PromptKind.agent,
      owner: 'agent',
      templatePath: 'assets/prompts/agent/chronicler',
      customizable: true,
    ),
    PromptDefinition(
      id: PromptId.agentMonologueNarrator,
      kind: PromptKind.agent,
      owner: 'monologue',
      templatePath: 'assets/prompts/agent/monologue_narrator',
      variables: [
        'character_name',
        'character_role',
        'character_summary',
        'character_description',
      ],
      customizable: true,
      requiresPathSchema: true,
    ),
    PromptDefinition(
      id: PromptId.agentRoleplayMaster,
      kind: PromptKind.agent,
      owner: 'roleplay',
      templatePath: 'assets/prompts/agent/roleplay_master',
      variables: [
        'character_name',
        'character_role',
        'character_summary',
        'character_description',
      ],
      customizable: true,
      requiresPathSchema: true,
    ),
    PromptDefinition(
      id: PromptId.agentTheaterActor,
      kind: PromptKind.agent,
      owner: 'theater',
      templatePath: 'assets/prompts/agent/theater_actor',
      variables: [
        'character_name',
        'character_id',
        'character_role',
        'character_summary',
        'character_description',
        'other_participants',
      ],
      customizable: true,
      requiresPathSchema: true,
    ),

    // Sub agents.
    PromptDefinition(
      id: PromptId.agentReview,
      kind: PromptKind.agent,
      owner: 'subagent',
      templatePath: 'assets/prompts/agent/review',
      customizable: true,
    ),
    PromptDefinition(
      id: PromptId.agentStylePolish,
      kind: PromptKind.agent,
      owner: 'subagent',
      templatePath: 'assets/prompts/agent/style_polish',
      customizable: true,
    ),
    PromptDefinition(
      id: PromptId.agentPlotArchitect,
      kind: PromptKind.agent,
      owner: 'subagent',
      templatePath: 'assets/prompts/agent/plot_architect',
      customizable: true,
    ),
    PromptDefinition(
      id: PromptId.agentCharacterAnalyst,
      kind: PromptKind.agent,
      owner: 'subagent',
      templatePath: 'assets/prompts/agent/character_analyst',
      customizable: true,
    ),
    PromptDefinition(
      id: PromptId.agentWorldBuilder,
      kind: PromptKind.agent,
      owner: 'subagent',
      templatePath: 'assets/prompts/agent/world_builder',
      customizable: true,
    ),
    PromptDefinition(
      id: PromptId.agentPacingExpert,
      kind: PromptKind.agent,
      owner: 'subagent',
      templatePath: 'assets/prompts/agent/pacing_expert',
      customizable: true,
    ),
    PromptDefinition(
      id: PromptId.agentConflictDesigner,
      kind: PromptKind.agent,
      owner: 'subagent',
      templatePath: 'assets/prompts/agent/conflict_designer',
      customizable: true,
    ),
    PromptDefinition(
      id: PromptId.agentThemeGuardian,
      kind: PromptKind.agent,
      owner: 'subagent',
      templatePath: 'assets/prompts/agent/theme_guardian',
      customizable: true,
    ),

    PromptDefinition(
      id: PromptId.agentExplorer,
      kind: PromptKind.agent,
      owner: 'subagent',
      templatePath: 'assets/prompts/agent/explorer',
      customizable: true,
    ),

    // Tasks.
    PromptDefinition(
      id: PromptId.taskCouncilRound,
      kind: PromptKind.task,
      owner: 'council',
      templatePath: 'assets/prompts/task/council_round',
      variables: [
        'topic',
        'prior_rounds',
        'new_messages',
        'other_members',
        'participant_name',
        'participant_description',
        'round',
      ],
    ),
    PromptDefinition(
      id: PromptId.taskCouncilSummary,
      kind: PromptKind.task,
      owner: 'council',
      templatePath: 'assets/prompts/task/council_summary',
      variables: ['topic', 'discussion_history'],
    ),
    PromptDefinition(
      id: PromptId.taskCoverAnalysis,
      kind: PromptKind.task,
      owner: 'cover',
      templatePath: 'assets/prompts/task/cover_analysis',
      variables: ['novel_title', 'style_label', 'tags'],
    ),
    PromptDefinition(
      id: PromptId.taskShortcutSummarize,
      kind: PromptKind.task,
      owner: 'chapter',
      templatePath: 'assets/prompts/task/shortcut_summarize',
      variables: ['chapter_title', 'outline', 'content'],
    ),
    PromptDefinition(
      id: PromptId.taskShortcutExpand,
      kind: PromptKind.task,
      owner: 'chapter',
      templatePath: 'assets/prompts/task/shortcut_expand',
      variables: ['chapter_title', 'outline', 'content'],
    ),
    PromptDefinition(
      id: PromptId.taskShortcutRewrite,
      kind: PromptKind.task,
      owner: 'chapter',
      templatePath: 'assets/prompts/task/shortcut_rewrite',
      variables: ['chapter_title', 'outline', 'content'],
    ),
    PromptDefinition(
      id: PromptId.taskTheaterLine,
      kind: PromptKind.task,
      owner: 'theater',
      templatePath: 'assets/prompts/task/theater_line',
      variables: [
        'scene_description',
        'prior_lines',
        'participant_name',
        'participant_character_id',
        'round',
      ],
    ),
    PromptDefinition(
      id: PromptId.taskVerifyOutput,
      kind: PromptKind.task,
      owner: 'review',
      templatePath: 'assets/prompts/task/verify_output',
      variables: ['content', 'user_rules'],
    ),
    PromptDefinition(
      id: PromptId.taskWorkspaceAction,
      kind: PromptKind.task,
      owner: 'workspace',
      templatePath: 'assets/prompts/task/workspace_action',
      variables: [
        'workspace_type',
        'title',
        'summarize',
        'expand',
        'rewrite',
        'meta_content',
        'content',
      ],
    ),
  ];

  static final Map<String, PromptDefinition> _byId = {
    for (final definition in definitions) definition.id: definition,
  };

  static PromptDefinition byId(String id) {
    final definition = _byId[id];
    if (definition == null) {
      throw ArgumentError('Prompt not registered: $id');
    }
    return definition;
  }

  static List<String> get templateAssetPaths {
    return definitions
        .map((definition) => definition.templatePath)
        .whereType<String>()
        .toList(growable: false);
  }
}

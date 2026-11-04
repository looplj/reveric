// 职责: Prompt ID 常量 — 为所有内置 prompt 提供稳定标识，避免业务层依赖模板路径。
// 关联文件:
//   lib/shared/services/ai/prompts/prompt_definition.dart
//   lib/shared/services/ai/prompts/prompt_registry.dart

abstract final class PromptId {
  static const systemCouncilSummarizer = 'system.council_summarizer';
  static const systemContextCompaction = 'system.context_compaction';

  static const agentOrchestrator = 'agent.orchestrator';
  static const agentAssistant = 'agent.assistant';
  static const agentWriter = 'agent.writer';
  static const agentChronicler = 'agent.chronicler';
  static const agentMonologueNarrator = 'agent.monologue_narrator';
  static const agentRoleplayMaster = 'agent.roleplay_master';
  static const agentTheaterActor = 'agent.theater_actor';
  static const agentReview = 'agent.review';
  static const agentStylePolish = 'agent.style_polish';
  static const agentPlotArchitect = 'agent.plot_architect';
  static const agentCharacterAnalyst = 'agent.character_analyst';
  static const agentWorldBuilder = 'agent.world_builder';
  static const agentPacingExpert = 'agent.pacing_expert';
  static const agentConflictDesigner = 'agent.conflict_designer';
  static const agentThemeGuardian = 'agent.theme_guardian';
  static const agentExplorer = 'agent.explorer';

  static const taskCouncilRound = 'task.council_round';
  static const taskCouncilSummary = 'task.council_summary';
  static const taskCoverAnalysis = 'task.cover_analysis';
  static const taskShortcutSummarize = 'task.shortcut_summarize';
  static const taskShortcutExpand = 'task.shortcut_expand';
  static const taskShortcutRewrite = 'task.shortcut_rewrite';
  static const taskTheaterLine = 'task.theater_line';
  static const taskVerifyOutput = 'task.verify_output';
  static const taskWorkspaceAction = 'task.workspace_action';
}

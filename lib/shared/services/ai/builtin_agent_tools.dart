// 职责: 声明内置 Agent 的工具权限。
// 关联文件:
//   lib/shared/services/initialization/agent_seeds.dart
//   lib/shared/services/initialization/primary_agent_seeds.dart
//   lib/shared/services/initialization/subagent_seeds.dart
//   lib/desktop/widgets/ai/chat/panel.dart
//   lib/shared/agent/agent.dart

const bashToolName = 'Bash';
const powerShellToolName = 'PowerShell';

/// 用户可见 special-mode primary agent（Home → 提示词）。
/// Chat 主控已收敛为 runtime `orchestrator`，不再对应 AgentProfile。
const builtinPrimaryAgentSlugs = {
  'monologue_narrator',
  'roleplay_master',
  'theater_actor',
};

/// Chat SubAgent 白名单。`chronicler` 为 orchestrator 内部调用，不出现在管理 UI。
const builtinSubAgentSlugs = {
  'explorer',
  'writer',
  'chronicler',
  'review',
  'style_polish',
  'plot_architect',
  'character_analyst',
  'world_builder',
  'pacing_expert',
  'conflict_designer',
  'theme_guardian',
};

// 只列禁止的 Host 工具；插件与 MCP 按各自的运行状态提供。
const builtinDefaultSubAgentDisabledToolNames = {
  'SpawnAgent',
  'ForkAgent',
  'AskUser',
  'SuggestNextAction',
  'SendAgentMessage',
  'StopAgent',
};
const builtinExplorerDisabledToolNames = {
  ...builtinDefaultSubAgentDisabledToolNames,
  'Create',
  'Write',
  'Edit',
  'Replace',
  'Remove',
  'Run',
  bashToolName,
  powerShellToolName,
  'TodoWrite',
};
const builtinSpecialModeDisabledToolNames = {
  'Create',
  'Write',
  'Edit',
  'Replace',
  'Remove',
  'Run',
  bashToolName,
  powerShellToolName,
  'TodoWrite',
  'AgentSkill',
  'SpawnAgent',
  'ForkAgent',
  'AskUser',
  'SuggestNextAction',
  'SendAgentMessage',
  'StopAgent',
  'Codemode',
};
Set<String>? builtinPrimaryAgentDisabledToolNames(String slug) =>
    builtinPrimaryAgentSlugs.contains(slug)
    ? builtinSpecialModeDisabledToolNames
    : null;
Set<String>? builtinSubAgentDisabledToolNames(String slug) =>
    !builtinSubAgentSlugs.contains(slug)
    ? null
    : slug == 'explorer'
    ? builtinExplorerDisabledToolNames
    : builtinDefaultSubAgentDisabledToolNames;

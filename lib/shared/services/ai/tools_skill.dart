// 职责: AgentSkill 工具定义 — 按技能名称加载 Agent 技能完整指令
// 关联文件:
//   lib/shared/services/ai/tools.dart (part)
//   lib/shared/models/agent_skill.dart

part of 'tools.dart';

const String skillToolName = 'AgentSkill';

const String _skillToolDescription = '''
按名称加载技能完整指令。开始任务前，检查 <available_agent_skills> 中的 <when_to_use>；若有明确匹配当前任务或子任务的技能，先加载并遵循其指令，再执行对应工作。多个技能分别覆盖不同任务环节时，按需加载；没有匹配技能时直接执行任务。

需要依据技能确定路径、参数或操作步骤时，等待技能返回后再生成相关调用，不与本次技能加载放在同一批调用中。互不依赖的调用可以并行。

同一次 Agent 运行中，每个技能最多加载一次。若当前上下文已有同名 <agent_skill> 的 <instructions>，直接遵循已有指令，不要重复加载。

返回技能完整指令及附带的参考资料列表。''';

const Map<String, dynamic> _skillToolInputSchema = {
  'type': 'object',
  'properties': {
    'name': {
      'type': 'string',
      'description':
          '要加载的技能名称，须与可用列表中 <name> 一致。该名称若已在当前上下文中出现完整 instructions，不要再次调用本工具。',
    },
  },
  'required': ['name'],
  'additionalProperties': false,
};

Future<Map<String, dynamic>> handleAgentSkillTool(
  Map<String, dynamic> input,
  SkillLoaderCallback? skillLoader, {
  List<String> availableNames = const <String>[],
}) async {
  final name = agentSkillNameFromInput(input);
  if (name.isEmpty) {
    return <String, dynamic>{
      'ok': false,
      'error': 'name is required',
      'error_code': ToolErrorCode.invalid_argument.name,
    };
  }
  if (skillLoader == null) {
    return <String, dynamic>{
      'ok': false,
      'error': 'AgentSkill tool not initialized',
      'error_code': ToolErrorCode.unavailable.name,
    };
  }
  final loaded = await skillLoader(name);
  if (loaded == null) {
    return <String, dynamic>{
      'ok': false,
      'error': 'AgentSkill "$name" not found or not enabled',
      'error_code': ToolErrorCode.not_found.name,
      'available_agent_skill_names': availableNames,
      'hint': availableNames.isEmpty
          ? 'Use an exact <name> from available_agent_skills.'
          : 'Use one of the available_agent_skill_names exactly.',
    };
  }
  return <String, dynamic>{
    'ok': true,
    'content': buildAgentSkillBlock(
      name,
      instructions: loaded.instructions,
      skillRoot: loaded.skillRoot,
      references: loaded.references,
    ),
  };
}

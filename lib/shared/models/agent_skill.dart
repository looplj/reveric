// 职责: AgentSkill 全量技能定义与摘要模型 —— 应用全局唯一 name 即工具名
// 关联文件:
//   lib/shared/providers/agent_skill_providers.dart
//   lib/shared/services/ai/tools_skill.dart
//   lib/shared/services/ai/chat_prompt_builder.dart
//   lib/shared/widgets/ai/tools/tool_card_descriptor.dart
//   lib/shared/models/novel_agent_skill.dart
//   lib/shared/models/agent_skill_reference.dart

import 'agent_skill_reference.dart';

/// 从 AgentSkill 工具参数中提取技能名。
///
/// `name` 是当前 schema 的标准字段；其余字段仅用于兼容历史会话和模型输出。
String agentSkillNameFromInput(Map<String, dynamic> input) {
  for (final key in const ['name', 'agent_skill_name', 'skill']) {
    final value = input[key]?.toString().trim() ?? '';
    if (value.isNotEmpty) {
      return value;
    }
  }
  return '';
}

/// 技能全量模型
class SkillDefinition {
  const SkillDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.prompt,
    this.whenToUse = '',
    this.references = const [],
    this.enabled = true,
    this.sortOrder = 0,
    this.createdAt,
    this.updatedAt,
  });

  final String id;

  /// 应用全局唯一,即 Agent tool 的有效名称与 `<agent_skill><name>` 块名。
  final String name;
  final String whenToUse;
  final String description;
  final String prompt;
  final List<AgentSkillReferenceFile> references;
  final bool enabled;
  final int sortOrder;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  SkillDefinition copyWith({
    String? id,
    String? name,
    String? whenToUse,
    String? description,
    String? prompt,
    List<AgentSkillReferenceFile>? references,
    bool? enabled,
    int? sortOrder,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return SkillDefinition(
      id: id ?? this.id,
      name: name ?? this.name,
      whenToUse: whenToUse ?? this.whenToUse,
      description: description ?? this.description,
      prompt: prompt ?? this.prompt,
      references: references ?? this.references,
      enabled: enabled ?? this.enabled,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// 技能创建草稿
class SkillDraft {
  const SkillDraft({
    required this.name,
    required this.description,
    required this.prompt,
    this.whenToUse = '',
    this.enabled = true,
  });

  final String name;
  final String whenToUse;
  final String description;
  final String prompt;
  final bool enabled;
}

/// AgentSkill 工具加载结果（instructions + references 清单）。
class AgentSkillLoadResult {
  const AgentSkillLoadResult({
    required this.instructions,
    this.references = const [],
  });

  final String instructions;
  final List<AgentSkillReferenceDescriptor> references;
}

/// 把技能完整指令包成模型识别的 `<agent_skill>` 块。
///
/// AgentSkill 工具（模型自行加载）与 slash「直接加载」共用同一封套，
/// 从而触发模型的同名去重规则（上下文已有同名块则禁止重复加载）。
///
/// [references] 非空时附带 `<skill_resources>`，只给出一次
/// `Run agent-skills reference-list` 目录发现命令，不预读路径或正文。
String buildAgentSkillBlock(
  String name, {
  required String instructions,
  List<AgentSkillReferenceDescriptor> references = const [],
}) {
  final buffer = StringBuffer();
  buffer.writeln('<agent_skill>');
  buffer.writeln('  <name>$name</name>');
  buffer.writeln('  <instructions>');
  buffer.writeln(instructions.trim());
  buffer.writeln('  </instructions>');
  if (references.isNotEmpty) {
    buffer.writeln('  <skill_resources>');
    buffer.writeln(
      '    <instruction>正文已给出准确附件路径时直接读取；未知路径时再列目录。读取单个文件时将当前技能名 '
      '`$name` 与正文或目录中的准确 path 一起传入：'
      '{"command":"agent-skills","subcommand":"reference-get",'
      '"options":{"name":"$name","path":"&lt;exact path&gt;"}}。'
      '不要臆造路径或预读。</instruction>',
    );
    buffer.writeln(
      '    <reference_files count="${references.length}" '
      'discovery="on_demand">',
    );
    buffer.writeln('      <command tool="Run" action="reference-list">');
    buffer.writeln(
      '        {"command":"agent-skills","subcommand":"reference-list",'
      '"options":{"name":"$name"}}',
    );
    buffer.writeln('      </command>');
    buffer.writeln('    </reference_files>');
    buffer.writeln('  </skill_resources>');
  }
  buffer.writeln('</agent_skill>');
  return buffer.toString().trim();
}

/// 技能摘要 — 系统提示词中仅公开 name + whenToUse（为空时回退 description），完整指令按需加载
class AgentSkillSummary {
  const AgentSkillSummary({
    required this.name,
    required this.description,
    this.whenToUse = '',
  });

  final String name;
  final String whenToUse;
  final String description;
}

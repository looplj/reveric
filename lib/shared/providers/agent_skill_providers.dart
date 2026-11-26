// 职责: AgentSkill 的 Riverpod Provider — App DB 入口与 chat slash 已安装技能查询
// 关联文件:
//   lib/shared/models/agent_skill.dart
//   lib/shared/database/app_database.dart
//   lib/shared/services/ai/chat_turn_runner.dart
//   lib/shared/providers/novel_agent_skill_providers.dart (installedAgentSkillsProvider)
// 遵循的 Rules:
//   .agents/rules/state-management.md

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_skill.dart';
import '../models/novel_agent_skill.dart';
import 'novel_agent_skill_providers.dart';

export 'novel_agent_skill_providers.dart' show agentSkillAppDatabaseProvider;

// ── Chat Slash Skills ────────────────────────────────────────────────────────

/// Slash 只列出已安装且可执行的技能，随安装状态更新。
final chatSlashSkillsProvider = Provider<AsyncValue<List<SkillDefinition>>>(
  (ref) => ref.watch(installedAgentSkillsProvider).whenData(chatSlashSkills),
);

List<SkillDefinition> chatSlashSkills(List<NovelAgentSkillModel> installed) => [
  for (final skill in installed)
    if (skill.isExecutable)
      SkillDefinition(
        id: skill.id,
        name: skill.name,
        whenToUse: skill.whenToUse,
        description: skill.description,
        prompt: skill.prompt,
        references: skill.references,
        skillRoot: skill.skillRoot,
        sortOrder: skill.sortOrder,
        createdAt: skill.createdAt,
        updatedAt: skill.updatedAt,
      ),
];

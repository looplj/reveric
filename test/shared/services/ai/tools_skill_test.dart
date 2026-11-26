// 职责: 验证 AgentSkill 兼容模型字段别名并在找不到技能时提供可恢复的精确名称列表
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_skill.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/agent_skill.dart';
import 'package:reveric/shared/services/ai/tools.dart';

void main() {
  test(
    'AgentSkill accepts name, skill, and agent_skill_name aliases',
    () async {
      for (final input in const [
        {'name': 'outline-review'},
        {'skill': 'outline-review'},
        {'agent_skill_name': 'outline-review'},
      ]) {
        final result = await handleAgentSkillTool(
          input,
          (name) async => name == 'outline-review'
              ? const AgentSkillLoadResult(instructions: 'Review the outline.')
              : null,
        );

        expect(result['ok'], isTrue, reason: 'input: $input');
      }
    },
  );

  test(
    'installed skill load exposes the escaped absolute package root',
    () async {
      final result = await handleAgentSkillTool(
        {'name': 'local'},
        (_) async => const AgentSkillLoadResult(
          instructions: 'Run scripts/tool.py',
          skillRoot: '/support & cache/agent_skills/local/pkg1',
        ),
      );
      expect(
        result['content'],
        contains(
          '<skill_root>/support &amp; cache/agent_skills/local/pkg1</skill_root>',
        ),
      );
      expect(result['content'], contains('Run scripts/tool.py'));
    },
  );

  test('AgentSkill keeps name as the primary field', () async {
    String? loadedName;
    await handleAgentSkillTool(
      {
        'name': 'outline-review',
        'agent_skill_name': 'legacy-skill',
        'skill': 'character-design',
      },
      (name) async {
        loadedName = name;
        return null;
      },
    );

    expect(loadedName, 'outline-review');
  });

  test(
    'AgentSkill not-found result lists the names available to this run',
    () async {
      final result = await handleAgentSkillTool(
        {'agent_skill_name': 'missing-skill'},
        (_) async => null,
        availableNames: const ['outline-review', 'character-design'],
      );

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'not_found');
      expect(result['available_agent_skill_names'], [
        'outline-review',
        'character-design',
      ]);
    },
  );
}

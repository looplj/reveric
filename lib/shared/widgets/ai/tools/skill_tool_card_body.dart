// 职责: Skill 工具卡片体 — 展示技能名称与结果状态。
// 关联文件:
//   lib/shared/widgets/ai/tools/tool_card_common.dart
//   lib/shared/models/agent_skill.dart
//   lib/shared/models/ai_message_block.dart
import 'package:flutter/material.dart';

import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/agent_skill.dart';
import 'package:reveric/shared/models/ai_message_block.dart';
import 'tool_card_common.dart';

class SkillToolCardBody extends StatelessWidget {
  const SkillToolCardBody({super.key, required this.block});

  final AiToolCallBlock block;

  @override
  Widget build(BuildContext context) {
    final skillName = agentSkillNameFromInput(block.arguments);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AiToolInfoChips(
          items: [
            context.t(LocaleKeys.toolUsingSkill),
            if (skillName.isNotEmpty) skillName,
          ],
        ),
      ],
    );
  }
}

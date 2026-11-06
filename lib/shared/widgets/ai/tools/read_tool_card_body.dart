// 职责: Read 工具摘要卡片体 — 展示读取目标、结果数量、发表状态与行范围。
// 关联文件:
//   lib/shared/widgets/ai/tools/tool_card_common.dart
//   lib/shared/widgets/ai/tools/tool_resource_resolver.dart
//   lib/shared/models/ai_message_block.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/tool.json
//   assets/translations/zh-CN/tool.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';

import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/ai_message_block.dart';
import 'tool_card_common.dart';
import 'tool_resource_resolver.dart';

class ReadToolCardBody extends StatelessWidget {
  const ReadToolCardBody({super.key, required this.block, this.resource});

  final AiToolCallBlock block;
  final AiToolResolvedResource? resource;

  @override
  Widget build(BuildContext context) {
    final result = block.result ?? const <String, dynamic>{};
    final total = _stringValue(result['total']);
    final startLine = _stringValue(result['start_line']);
    final endLine = _stringValue(result['end_line']);
    final chips = <String>[
      if (resource != null) resource!.displayLabel(context),
      if (result['status'] == 'published')
        context.t(LocaleKeys.chapterStatPublished),
      if (result['status'] == 'draft') context.t(LocaleKeys.chapterStatDraft),
      if (total != null && total != '0')
        context.t(LocaleKeys.toolResultCountFmt, namedArgs: {'count': total}),
      if (result['total_lines'] is int &&
          (result['total_lines'] as int) > 0 &&
          startLine != null &&
          endLine != null)
        context.t(
          LocaleKeys.toolLineRangeFmt,
          namedArgs: {'start': startLine, 'end': endLine},
        ),
    ];

    return AiToolInfoChips(items: chips);
  }

  String? _stringValue(Object? value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) {
      return null;
    }
    return text;
  }
}

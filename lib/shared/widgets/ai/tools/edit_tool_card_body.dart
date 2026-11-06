// 职责: Edit 工具摘要卡片体 — 展示编辑目标、替换范围、发表状态警告与新旧文本摘要。
// 关联文件:
//   lib/shared/widgets/ai/tools/tool_card_common.dart
//   lib/shared/widgets/ai/tools/tool_resource_resolver.dart
//   lib/shared/models/ai_message_block.dart
import 'package:flutter/material.dart';

import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/ai_message_block.dart';
import 'package:reveric/shared/services/ai/tool_error_normalize.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'tool_card_common.dart';
import 'tool_resource_resolver.dart';

class EditToolCardBody extends StatelessWidget {
  const EditToolCardBody({super.key, required this.block, this.resource});

  final AiToolCallBlock block;
  final AiToolResolvedResource? resource;

  @override
  Widget build(BuildContext context) {
    final replaceAll = block.arguments['all'] == true;
    final matchCount = block.result?['match_count'];
    final errorCode = block.result?['error_code'] as String?;
    final oldText = (block.arguments['old_text'] as String? ?? '').trim();
    final newText = (block.arguments['new_text'] as String? ?? '').trim();
    final chips = <String>[
      if (resource != null) resource!.displayLabel(context),
      if (errorCode == ToolErrorCode.locked.name)
        context.t(LocaleKeys.chapterStatPublished),
      if (matchCount != null)
        context.t(
          LocaleKeys.toolMatchesCountFmt,
          namedArgs: {'count': '$matchCount'},
        ),
      if (replaceAll) context.t(LocaleKeys.toolReplaceAll),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AiToolInfoChips(items: chips),
        if (oldText.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.sm),
          AiToolPreviewBlock(
            label: context.t(LocaleKeys.toolOldText),
            text: oldText,
            maxLines: 4,
          ),
        ],
        if (newText.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.sm),
          AiToolPreviewBlock(
            label: context.t(LocaleKeys.toolNewText),
            text: newText,
            maxLines: 4,
          ),
        ],
      ],
    );
  }
}

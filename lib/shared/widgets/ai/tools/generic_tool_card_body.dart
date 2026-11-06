// 职责: 未专门适配的工具摘要卡片体 — 展示关键参数与结果预览，避免直接暴露整段 JSON。
// 关联文件:
//   lib/shared/widgets/ai/tools/tool_card_common.dart
//   lib/shared/widgets/ai/tools/tool_resource_resolver.dart
//   lib/shared/models/ai_message_block.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/tool.json
//   assets/translations/zh-CN/tool.json
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/ai_message_block.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'tool_card_common.dart';
import 'tool_resource_resolver.dart';

class GenericToolCardBody extends StatelessWidget {
  const GenericToolCardBody({super.key, required this.block, this.resource});

  final AiToolCallBlock block;
  final AiToolResolvedResource? resource;

  @override
  Widget build(BuildContext context) {
    // 传话的结果只是「已接收」回执，卡片上要看的是传了什么。
    final agentMessage = block.toolName == 'SendAgentMessage'
        ? (block.arguments['message'] as String? ?? '').trim()
        : '';
    final preview = agentMessage.isNotEmpty ? agentMessage : _previewText();
    final infoEntries = <(String, String)>[
      if (resource != null)
        (context.t(LocaleKeys.toolTarget), resource!.displayLabel(context)),
      if ((block.arguments['question'] as String? ?? '').trim().isNotEmpty)
        (
          context.t(LocaleKeys.toolQuestion),
          (block.arguments['question'] as String).trim(),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AiToolKeyValueList(entries: infoEntries),
        if (preview != null) ...[
          const SizedBox(height: RevericSpacing.xs),
          AiToolPreviewBlock(
            label: context.t(
              agentMessage.isNotEmpty
                  ? LocaleKeys.toolAgentMessage
                  : LocaleKeys.toolPreview,
            ),
            text: preview,
            monospace: preview.startsWith('{') || preview.startsWith('['),
            maxLines: 8,
          ),
        ],
      ],
    );
  }

  String? _previewText() {
    final result = block.result;
    if (result != null && result.isNotEmpty) {
      final message = (result['message'] ?? result['summary'] ?? '')
          .toString()
          .trim();
      if (message.isNotEmpty) {
        return message;
      }
      return const JsonEncoder.withIndent('  ').convert(result);
    }
    if (block.arguments.isNotEmpty) {
      return const JsonEncoder.withIndent('  ').convert(block.arguments);
    }
    return null;
  }
}

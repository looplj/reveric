// 职责: 展示 MCP 服务来源、执行状态和返回内容。
// 关联文件:
//   lib/shared/models/ai_message_block.dart
//   lib/shared/widgets/ai/tools/tool_detail_body.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/tool.json
//   assets/translations/zh-CN/tool.json
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../../models/ai_message_block.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../theme/theme.dart';
import 'tool_card_common.dart';

class McpToolCardBody extends StatelessWidget {
  const McpToolCardBody({super.key, required this.block});
  final AiToolCallBlock block;
  @override
  Widget build(BuildContext context) {
    final result = block.result;
    final typo = RevericTheme.typographyOf(context);
    final content = result?['content'];
    final texts = content is List
        ? content
              .whereType<Map>()
              .where((item) => item['type'] == 'text')
              .map((item) => item['text'])
              .whereType<String>()
              .join('\n')
        : '';
    final structured = result?['structuredContent'];
    final progress = result?['mcp_progress'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (block.status == AiToolCallStatus.running && progress is Map)
          Text(
            '${progress['progress']}${progress['total'] == null ? '' : ' / ${progress['total']}'}${progress['message'] == null ? '' : ' · ${progress['message']}'}',
            style: typo.ui,
          ),
        if (block.mcpServer != null)
          Text(block.mcpServer!, style: typo.uiSemibold),
        if (result?['executionState'] == 'unknown')
          Text(context.t(LocaleKeys.settingsMcpUnknown), style: typo.ui),
        if (result?['ok'] == false && result?['executionState'] != 'unknown')
          Text(context.t(LocaleKeys.settingsMcpError), style: typo.ui),
        if (result?['ok'] != false && (texts.isNotEmpty || structured != null))
          AiToolPreviewBlock(
            label: context.t(LocaleKeys.toolPreview),
            text: texts.isNotEmpty ? texts : jsonEncode(structured),
            maxLines: 8,
            monospace: texts.isEmpty,
          ),
        if (result != null &&
            !result.containsKey('executionState') &&
            !result.containsKey('mcp_progress') &&
            result['ok'] != false)
          AiToolPreviewBlock(
            label: context.t(LocaleKeys.toolPreview),
            text: jsonEncode(result),
            maxLines: 8,
            monospace: true,
          ),
      ],
    );
  }
}

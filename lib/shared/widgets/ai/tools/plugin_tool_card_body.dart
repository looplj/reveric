// 职责: 按调用时的插件展示快照渲染参数、来源和结果预览。
// 关联文件:
//   lib/shared/widgets/ai/tools/plugin_tool_display.dart
//   lib/shared/widgets/ai/tools/tool_card_common.dart
//   lib/shared/models/ai_message_block.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../models/ai_message_block.dart';
import '../../../theme/theme.dart';
import 'plugin_tool_display.dart';
import 'plugin_result_card.dart';
import 'tool_card_common.dart';

class PluginToolCardBody extends StatelessWidget {
  const PluginToolCardBody({super.key, required this.block});
  final AiToolCallBlock block;
  @override
  Widget build(BuildContext context) {
    final preview = _preview();
    final source = pluginToolSource(context, block);
    final fallback = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AiToolInfoChips(
          items: [
            ?pluginToolSummary(block),
            if (source != null && source.isNotEmpty) source,
          ],
        ),
        if (preview != null && preview.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.sm),
          AiToolPreviewBlock(
            label: context.t(LocaleKeys.aiToolPreview),
            text: preview,
            maxLines: 8,
          ),
        ],
      ],
    );
    return block.metadata?['plugin_id'] is String &&
            pluginToolDisplay(block)['view'] is Map
        ? PluginResultCard(block: block, fallback: fallback)
        : fallback;
  }

  String? _preview() {
    final result = block.result;
    if (result == null || result['ok'] == false) {
      return null;
    }
    final display = pluginToolDisplay(block);
    final value = result[display['resultPath']];
    switch (display['result']) {
      case 'items':
        if (value is! List) {
          return null;
        }
        return value
            .whereType<Map>()
            .take(4)
            .map((item) {
              final title = (item['title'] ?? item['url'] ?? '')
                  .toString()
                  .trim();
              final snippet = (item['snippet'] ?? '').toString().trim();
              return title.isEmpty
                  ? ''
                  : snippet.isEmpty
                  ? title
                  : '$title\n$snippet';
            })
            .where((line) => line.isNotEmpty)
            .join('\n\n');
      case 'text':
        // Old WebFetch history may have used markdown instead of content.
        final text =
            value ??
            (block.source == 'builtin' && block.toolName == 'WebFetch'
                ? result['markdown']
                : null);
        return text is String ? text : null;
      default:
        return const JsonEncoder.withIndent('  ').convert(result);
    }
  }
}

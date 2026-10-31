// 职责: 从历史工具块读取插件展示快照并兼容插件化前的 Web 记录。
// 关联文件:
//   lib/shared/models/ai_message_block.dart
//   lib/shared/widgets/ai/tools/plugin_tool_card_body.dart
//   lib/shared/widgets/ai/tools/tool_card_descriptor.dart
import 'package:flutter/widgets.dart';
import '../../../models/ai_message_block.dart';
import '../../../models/plugin/text.dart';

bool isPluginToolBlock(AiToolCallBlock block) =>
    block.source == 'plugin' ||
    (block.source == 'builtin' &&
        const {'WebSearch', 'WebFetch'}.contains(block.toolName));
Map<String, dynamic> pluginToolDisplay(AiToolCallBlock block) {
  final saved = block.metadata?['plugin_display'];
  if (saved is Map<String, dynamic>) {
    return saved;
  }
  return switch (block.toolName) {
    'WebSearch' => const {
      'summaryArg': 'query',
      'result': 'items',
      'resultPath': 'results',
    },
    'WebFetch' => const {
      'summaryArg': 'url',
      'result': 'text',
      'resultPath': 'content',
    },
    _ => const {},
  };
}

String pluginToolTitle(BuildContext context, AiToolCallBlock block) =>
    readPluginText(
      pluginToolDisplay(block)['title'],
    )?.resolve(Localizations.localeOf(context)) ??
    block.toolName;

/// 调用时保存的插件名称，按当前界面语言取值。
String? pluginToolSource(BuildContext context, AiToolCallBlock block) =>
    readPluginText(
      block.metadata?['plugin_name'],
    )?.resolve(Localizations.localeOf(context));
String? pluginToolSummary(AiToolCallBlock block) {
  final key = pluginToolDisplay(block)['summaryArg'];
  final value = key is String ? block.arguments[key]?.toString().trim() : null;
  return value == null || value.isEmpty ? null : value;
}

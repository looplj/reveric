// 职责: Search 工具摘要卡片体 — 展示搜索词、命中数量与关键命中项。
// 关联文件:
//   lib/shared/widgets/ai/tools/tool_card_common.dart
//   lib/shared/models/ai_message_block.dart
//   lib/shared/localization/locale_keys.dart
import 'package:flutter/material.dart';

import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/ai_message_block.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'tool_card_common.dart';

class SearchToolCardBody extends StatelessWidget {
  const SearchToolCardBody({super.key, required this.block});

  final AiToolCallBlock block;

  @override
  Widget build(BuildContext context) {
    final query = (block.arguments['query'] as String? ?? '').trim();
    final matches =
        (block.result?['matches'] as List?)?.whereType<Map>().toList() ??
        const <Map>[];
    final chips = <String>[
      if (query.isNotEmpty) query,
      if (matches.isNotEmpty)
        context.t(
          LocaleKeys.toolMatchesCountFmt,
          namedArgs: {'count': '${matches.length}'},
        ),
    ];
    final preview = matches
        .take(4)
        .map((item) {
          final map = Map<String, dynamic>.from(item);
          final title = (map['title'] ?? map['path'] ?? '').toString().trim();
          final excerpt = (map['excerpt'] ?? '').toString().trim();
          if (title.isEmpty) return '';
          return excerpt.isEmpty ? title : '$title\n$excerpt';
        })
        .where((item) => item.isNotEmpty)
        .join('\n\n');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AiToolInfoChips(items: chips),
        if (preview.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.sm),
          AiToolPreviewBlock(
            label: context.t(LocaleKeys.toolPreview),
            text: preview,
            maxLines: 8,
          ),
        ],
      ],
    );
  }
}

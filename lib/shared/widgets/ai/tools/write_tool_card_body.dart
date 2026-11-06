// 职责: Write 工具摘要卡片体 — 展示写入目标、更新字段、发表状态警告与新内容预览。
// 关联文件:
//   lib/shared/widgets/ai/tools/tool_card_common.dart
//   lib/shared/widgets/ai/tools/tool_card_descriptor.dart
//   lib/shared/models/ai_message_block.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/tool.json
//   assets/translations/zh-CN/tool.json
//   assets/translations/en/chapter.json
//   assets/translations/zh-CN/chapter.json
import 'package:flutter/material.dart';

import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/ai_message_block.dart';
import 'package:reveric/shared/services/ai/tool_error_normalize.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'tool_card_common.dart';
import 'tool_card_descriptor.dart';
import 'tool_resource_resolver.dart';

class WriteToolCardBody extends StatelessWidget {
  const WriteToolCardBody({super.key, required this.block, this.resource});

  final AiToolCallBlock block;
  final AiToolResolvedResource? resource;

  @override
  Widget build(BuildContext context) {
    final fields = _extractFields(context);
    final preview = _extractPreview();
    final errorCode = block.result?['error_code'] as String?;
    final chips = <String>[
      if (resource != null) resource!.displayLabel(context),
      if (errorCode == ToolErrorCode.locked.name)
        context.t(LocaleKeys.chapterStatPublished),
      ...fields,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AiToolInfoChips(items: chips),
        if (preview != null) ...[
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

  List<String> _extractFields(BuildContext context) {
    final field = resource?.field;
    if (field != null && field.isNotEmpty) {
      return [fieldLabel(context, field)];
    }
    final rawFields = block.result?['fields'];
    if (rawFields is List) {
      return rawFields
          .map((field) => fieldLabel(context, field.toString()))
          .toList();
    }
    return const [];
  }

  String? _extractPreview() {
    if ((block.diffNewText ?? '').trim().isNotEmpty) {
      return block.diffNewText!.trim();
    }
    final rawValue = block.arguments['value'];
    if (rawValue is String) {
      final value = rawValue.trim();
      if (value.isNotEmpty) {
        return value;
      }
    }
    final fields = block.arguments['fields'];
    if (fields is Map<String, dynamic>) {
      final firstEntry = fields.entries.firstWhere(
        (entry) =>
            entry.value != null && entry.value.toString().trim().isNotEmpty,
        orElse: () => const MapEntry('', ''),
      );
      final preview = firstEntry.value.toString().trim();
      return preview.isEmpty ? null : preview;
    }
    return null;
  }
}

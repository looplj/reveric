// 职责: Create 系列工具摘要卡片体 — 展示新建资源名称、类型与草稿预览。
// 关联文件:
//   lib/shared/widgets/ai/tools/tool_card_common.dart
//   lib/shared/widgets/ai/tools/tool_resource_resolver.dart
//   lib/shared/models/ai_message_block.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/tool.json
//   assets/translations/zh-CN/tool.json
import 'package:flutter/material.dart';

import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/ai_message_block.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'tool_card_common.dart';
import 'tool_resource_resolver.dart';

class CreateToolCardBody extends StatelessWidget {
  const CreateToolCardBody({super.key, required this.block, this.resource});

  final AiToolCallBlock block;
  final AiToolResolvedResource? resource;

  @override
  Widget build(BuildContext context) {
    final chips = <String>[
      if (resource != null) resource!.displayLabel(context),
      ..._extractChips(context),
    ];
    final preview = _extractPreview();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AiToolInfoChips(items: chips),
        if (preview != null) ...[
          const SizedBox(height: RevericSpacing.sm),
          AiToolPreviewBlock(
            label: context.t(LocaleKeys.toolPreview),
            text: preview,
            maxLines: 6,
          ),
        ],
      ],
    );
  }

  List<String> _extractChips(BuildContext context) {
    switch (block.toolName) {
      case 'Create':
        final fields = _extractFields();
        final path = (block.arguments['path'] as String?) ?? '';
        if (path.contains('/outlines/') && path.endsWith('/beats')) {
          final chapterCount = fields?['chapter_count'] as int?;
          return [
            if (chapterCount != null)
              context.t(
                LocaleKeys.toolChaptersCountFmt,
                namedArgs: {'count': '$chapterCount'},
              ),
          ];
        }
        if (path == '/outlines') {
          final status = (fields?['status'] as String?)?.trim() ?? '';
          final beatsCount = (fields?['beats'] as List?)?.length;
          return [
            if (status.isNotEmpty) status,
            if (beatsCount != null)
              context.t(
                LocaleKeys.toolBeatsCountFmt,
                namedArgs: {'count': '$beatsCount'},
              ),
          ];
        }
        final type = (fields?['type'] ?? '').toString().trim();
        final role = (fields?['role'] as String?)?.trim() ?? '';
        final status = (fields?['status'] as String?)?.trim() ?? '';
        return [
          if (type.isNotEmpty) localizedChapterTypeLabel(context, type),
          if (role.isNotEmpty) role,
          if (status.isNotEmpty) status,
        ];
      case 'CreateChapter':
        final type = (block.result?['type'] ?? block.arguments['type'] ?? '')
            .toString()
            .trim();
        return [if (type.isNotEmpty) localizedChapterTypeLabel(context, type)];
      case 'CreateCharacter':
        final role = (block.arguments['role'] as String? ?? '').trim();
        return [if (role.isNotEmpty) role];
      case 'CreateForeshadowing':
        final status = (block.arguments['status'] as String? ?? '').trim();
        return [if (status.isNotEmpty) status];
      case 'CreateLocation':
        final type = (block.arguments['type'] as String? ?? '').trim();
        final name = (block.result?['name'] ?? block.arguments['name'] ?? '')
            .toString()
            .trim();
        return [if (type.isNotEmpty) type, if (name.isNotEmpty) name];
      case 'CreateOutline':
        final status = (block.arguments['status'] as String? ?? '').trim();
        final beatsCount = (block.arguments['beats'] as List?)?.length;
        return [
          if (status.isNotEmpty) status,
          if (beatsCount != null)
            context.t(
              LocaleKeys.toolBeatsCountFmt,
              namedArgs: {'count': '$beatsCount'},
            ),
        ];
      case 'CreateBeat':
        final outlineTitle = (block.arguments['outline_title'] as String? ?? '')
            .trim();
        final chapterCount = block.arguments['chapter_count'] as int?;
        return [
          if (outlineTitle.isNotEmpty) outlineTitle,
          if (chapterCount != null)
            context.t(
              LocaleKeys.toolChaptersCountFmt,
              namedArgs: {'count': '$chapterCount'},
            ),
        ];
      case 'CreateVolume':
        return const [];
      default:
        return const [];
    }
  }

  String? _extractPreview() {
    switch (block.toolName) {
      case 'Create':
        final fields = _extractFields();
        if (fields == null) return null;
        return ((fields['content'] as String?)?.trim().isNotEmpty ?? false)
            ? (fields['content'] as String).trim()
            : (fields['description'] as String?)?.trim();
      case 'CreateChapter':
        return ((block.arguments['outline'] as String?)?.trim().isNotEmpty ??
                false)
            ? (block.arguments['outline'] as String).trim()
            : (block.arguments['content'] as String?)?.trim();
      case 'CreateCharacter':
        return (block.arguments['summary'] as String?)?.trim();
      case 'CreateForeshadowing':
        return ((block.arguments['setup'] as String?)?.trim().isNotEmpty ??
                false)
            ? (block.arguments['setup'] as String).trim()
            : (block.arguments['payoff'] as String?)?.trim();
      case 'CreateLocation':
        return (block.arguments['description'] as String?)?.trim();
      case 'CreateOutline':
        return (block.arguments['content'] as String?)?.trim();
      case 'CreateBeat':
        return (block.arguments['content'] as String?)?.trim();
      case 'CreateVolume':
        return (block.arguments['description'] as String?)?.trim();
      default:
        return null;
    }
  }

  Map<String, dynamic>? _extractFields() {
    final fields = block.arguments['fields'];
    if (fields is Map<String, dynamic>) {
      return fields;
    }
    if (fields is Map) {
      return Map<String, dynamic>.from(fields);
    }
    return null;
  }
}

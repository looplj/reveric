// 职责: Glob/Grep 工具摘要卡片体 — 展示搜索模式、命中路径与 grep 文本结果。
// 关联文件:
//   lib/shared/widgets/ai/tools/tool_card_common.dart
//   lib/shared/widgets/ai/tools/tool_card_descriptor.dart
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
import 'tool_card_descriptor.dart';
import 'tool_resource_resolver.dart';

class GlobToolCardBody extends StatelessWidget {
  const GlobToolCardBody({super.key, required this.block});

  final AiToolCallBlock block;

  @override
  Widget build(BuildContext context) {
    final pattern = (block.arguments['pattern'] as String? ?? '').trim();
    final scopePath = (block.arguments['path'] as String? ?? '').trim();
    final result = block.result ?? const <String, dynamic>{};
    final matches =
        (result['matches'] as List?)?.whereType<String>().toList() ??
        const <String>[];
    final total = result['total'] as int? ?? matches.length;
    final truncated = result['truncated'] == true;

    final chips = <String>[
      if (pattern.isNotEmpty) pattern,
      if (total > 0)
        context.t(
          LocaleKeys.toolResultCountFmt,
          namedArgs: {'count': '$total'},
        ),
      if (truncated) context.t(LocaleKeys.toolResultsTruncated),
    ];

    final infoEntries = <(String, String)>[
      if (scopePath.isNotEmpty && scopePath != '/')
        (context.t(LocaleKeys.toolScope), _scopeLabel(context, scopePath)),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AiToolInfoChips(items: chips),
        if (infoEntries.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.xs),
          AiToolKeyValueList(entries: infoEntries),
        ],
        if (matches.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.sm),
          AiToolPathList(
            label: context.t(LocaleKeys.toolPaths),
            paths: matches,
            totalCount: total,
            truncated: truncated,
            formatPath: localizedToolPathLabel,
          ),
        ] else if (block.status == AiToolCallStatus.success) ...[
          const SizedBox(height: RevericSpacing.sm),
          Text(
            context.t(LocaleKeys.toolNoResults),
            style: RevericTheme.typographyOf(
              context,
            ).uiSmall.copyWith(color: RevericTheme.colorsOf(context).textMuted),
          ),
        ],
      ],
    );
  }
}

class GrepToolCardBody extends StatelessWidget {
  const GrepToolCardBody({super.key, required this.block});

  final AiToolCallBlock block;

  @override
  Widget build(BuildContext context) {
    final pattern = (block.arguments['pattern'] as String? ?? '').trim();
    final scopePath = (block.arguments['path'] as String? ?? '').trim();
    final glob = (block.arguments['glob'] as String? ?? '').trim();
    final outputMode = (block.arguments['output_mode'] as String? ?? 'content')
        .trim();
    final result = block.result ?? const <String, dynamic>{};
    final rawText = (result['text'] as String? ?? '').trim();
    final truncated = result['truncated'] == true;

    final lines = _parseGrepLines(rawText);
    final isEmpty = lines.isEmpty || _isNoResultsText(rawText);

    final chips = <String>[
      if (pattern.isNotEmpty) pattern,
      if (outputMode.isNotEmpty && outputMode != 'content')
        _outputModeLabel(context, outputMode),
      if (!isEmpty)
        context.t(
          LocaleKeys.toolResultCountFmt,
          namedArgs: {'count': '${lines.length}'},
        ),
      if (truncated) context.t(LocaleKeys.toolResultsTruncated),
    ];

    final infoEntries = <(String, String)>[
      if (scopePath.isNotEmpty && scopePath != '/')
        (context.t(LocaleKeys.toolScope), _scopeLabel(context, scopePath)),
      if (glob.isNotEmpty) (context.t(LocaleKeys.toolPattern), glob),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AiToolInfoChips(items: chips),
        if (infoEntries.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.xs),
          AiToolKeyValueList(entries: infoEntries),
        ],
        if (!isEmpty) ...[
          const SizedBox(height: RevericSpacing.sm),
          if (outputMode == 'files_with_matches')
            AiToolPathList(
              label: context.t(LocaleKeys.toolPaths),
              paths: lines,
              truncated: truncated,
              formatPath: localizedToolPathLabel,
            )
          else
            AiToolPreviewBlock(
              label: context.t(LocaleKeys.toolMatches),
              text: lines.join('\n'),
              monospace: true,
              maxLines: 12,
            ),
        ] else if (block.status == AiToolCallStatus.success) ...[
          const SizedBox(height: RevericSpacing.sm),
          Text(
            context.t(LocaleKeys.toolNoResults),
            style: RevericTheme.typographyOf(
              context,
            ).uiSmall.copyWith(color: RevericTheme.colorsOf(context).textMuted),
          ),
        ],
      ],
    );
  }

  String _outputModeLabel(BuildContext context, String mode) {
    return switch (mode) {
      'files_with_matches' => context.t(LocaleKeys.toolGrepModeFiles),
      'count' => context.t(LocaleKeys.toolGrepModeCount),
      _ => mode,
    };
  }
}

List<String> _parseGrepLines(String rawText) {
  if (rawText.isEmpty) {
    return const <String>[];
  }
  return rawText
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .where((line) => !line.startsWith('... (truncated'))
      .toList();
}

bool _isNoResultsText(String rawText) {
  final normalized = rawText.trim().toLowerCase();
  return normalized == 'no results found.' || normalized == 'no results found';
}

String _scopeLabel(BuildContext context, String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty || trimmed == '/') {
    return context.t(LocaleKeys.toolScopeRoot);
  }
  final segments = trimmed
      .split('/')
      .where((segment) => segment.trim().isNotEmpty)
      .toList();
  if (segments.isEmpty) {
    return trimmed;
  }
  return collectionLabel(context, segments.first);
}

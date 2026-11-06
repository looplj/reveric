// 职责: GraphSearch 工具摘要卡片体 — 展示实体关系图搜索结果，按深度分层显示关系。
// 关联文件:
//   lib/shared/widgets/ai/tools/tool_card_common.dart
//   lib/shared/models/ai_message_block.dart
//   lib/shared/services/ai/tools.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/tool.json
//   assets/translations/zh-CN/tool.json
import 'package:flutter/material.dart';

import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/ai_message_block.dart';
import 'package:reveric/shared/entity_graph/labels.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'tool_card_common.dart';

class GraphSearchToolCardBody extends StatelessWidget {
  const GraphSearchToolCardBody({super.key, required this.block});

  final AiToolCallBlock block;

  @override
  Widget build(BuildContext context) {
    final entityType = graphSearchTypeFromInput(block.arguments);
    final entityId = graphSearchIdFromInput(block.arguments);
    final depth = block.arguments['depth'] as int? ?? 1;
    final relationType = (block.arguments['relation_type'] as String? ?? '')
        .trim();

    final totalRelations = block.result?['total_relations'] as int? ?? 0;
    final layers =
        (block.result?['layers'] as List?)?.whereType<Map>().toList() ??
        const <Map>[];

    final entityTypeLabel = entityType.isEmpty
        ? ''
        : localizeEntityNodeTypeName(context, entityType);
    final relationTypeLabel = relationType.isEmpty
        ? ''
        : localizeRelationTypeLabel(context, relationType);

    final chips = <String>[
      if (entityId.isNotEmpty && entityTypeLabel.isNotEmpty)
        '$entityTypeLabel($entityId)'
      else if (entityId.isNotEmpty && entityType.isNotEmpty)
        '$entityType($entityId)',
      context.t(LocaleKeys.toolDepthFmt, namedArgs: {'depth': '$depth'}),
      if (relationTypeLabel.isNotEmpty) relationTypeLabel,
      if (totalRelations > 0)
        context.t(
          LocaleKeys.toolResultCountFmt,
          namedArgs: {'count': '$totalRelations'},
        ),
    ];

    final preview = layers
        .take(3)
        .map((layer) {
          final layerDepth = layer['depth'] as int? ?? 0;
          final relations =
              (layer['relations'] as List?)
                  ?.whereType<Map>()
                  .take(4)
                  .map((r) {
                    final sourceType = r['source_type'] ?? '';
                    final sourceId = r['source_id'] ?? '';
                    final targetType = r['target_type'] ?? '';
                    final targetId = r['target_id'] ?? '';
                    final relType = r['relation_type'] ?? '';
                    final sourceTypeLabel = localizeEntityNodeTypeName(
                      context,
                      '$sourceType',
                    );
                    final targetTypeLabel = localizeEntityNodeTypeName(
                      context,
                      '$targetType',
                    );
                    final relTypeLabel = localizeRelationTypeLabel(
                      context,
                      '$relType',
                      sourceType: '$sourceType',
                      targetType: '$targetType',
                    );
                    return '  $sourceTypeLabel($sourceId) --[$relTypeLabel]--> $targetTypeLabel($targetId)';
                  })
                  .join('\n') ??
              '';
          if (relations.isEmpty) return '';
          final layerLabel = context.t(
            LocaleKeys.toolLayerDepthFmt,
            namedArgs: {'depth': '$layerDepth'},
          );
          return '$layerLabel:\n$relations';
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
            maxLines: 12,
          ),
        ],
      ],
    );
  }
}

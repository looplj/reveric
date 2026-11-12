// 职责: 将同一制作画布的节点按内容顺序与类型平铺筛选，并点击定位原节点。
// 关联文件:
//   lib/desktop/features/production/region.dart
//   lib/desktop/features/production/node_card.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/assets.json
//   assets/translations/zh-CN/assets.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/components/reveric_filter_chip.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/theme/theme.dart';
import 'node_card.dart';
import 'task_status.dart';

String productionGridKind(CanvasNode node, ProductionClipRow? clip) =>
    clip?.sceneId != null
    ? 'segment'
    : clip?.characterId != null
    ? 'character'
    : clip?.locationId != null
    ? 'location'
    : clip?.itemId != null
    ? 'item'
    : node.type == canvasNodeTypeImage
    ? 'image'
    : node.type == canvasNodeTypeAudio
    ? 'audio'
    : node.type == canvasNodeTypeVideo
    ? 'video'
    : 'asset';

List<CanvasNode> sortProductionGrid(
  List<CanvasNode> nodes,
  Map<String, ProductionClipRow> clips,
  List<ProductionClipRow> segments,
) {
  const rank = {
    'segment': 0,
    'character': 1,
    'location': 2,
    'item': 3,
    'video': 4,
    'image': 5,
    'audio': 6,
    'asset': 7,
  };
  final positions = {
    for (var i = 0; i < segments.length; i++) segments[i].id: i,
  };
  return nodes.where((node) => node.type != canvasNodeTypeGroup).toList()
    ..sort((a, b) {
      final ka = productionGridKind(a, clips[a.clipId]),
          kb = productionGridKind(b, clips[b.clipId]);
      final order = rank[ka]!.compareTo(rank[kb]!);
      if (order != 0) {
        return order;
      }
      if (ka == 'segment') {
        return (positions[a.clipId] ?? segments.length).compareTo(
          positions[b.clipId] ?? segments.length,
        );
      }
      if (a.type == canvasNodeTypeStaging && b.type != canvasNodeTypeStaging) {
        return 1;
      }
      if (b.type == canvasNodeTypeStaging && a.type != canvasNodeTypeStaging) {
        return -1;
      }
      final time = a.createdAt.compareTo(b.createdAt);
      return time == 0 ? a.id.compareTo(b.id) : time;
    });
}

class ProductionNodeGrid extends HookWidget {
  const ProductionNodeGrid({
    super.key,
    required this.service,
    required this.canvasId,
    required this.segments,
    required this.onOpen,
    this.taskActions,
  });
  final ProductionCanvasService service;
  final String canvasId;
  final List<ProductionClipRow> segments;
  final ValueChanged<CanvasNode> onOpen;
  final ProductionTaskActions? taskActions;
  @override
  Widget build(BuildContext context) {
    final nodes = useStream(
      useMemoized(() => service.db.canvasDao.watchNodesByCanvas(canvasId), [
        service,
        canvasId,
      ]),
    );
    final clips = useStream(
      useMemoized(() => service.db.select(service.db.productionClips).watch(), [
        service,
      ]),
    );
    final edges = useStream(
      useMemoized(
        () => service.watchContent(canvasId).map((content) => content.edges),
        [service, canvasId],
      ),
    );
    final filter = useState('character');
    final byId = {
      for (final clip in clips.data ?? <ProductionClipRow>[]) clip.id: clip,
    };
    // 场次节点只给画布定位场次，不作为列表条目。
    final sorted = sortProductionGrid(
      [
        for (final n in nodes.data ?? <CanvasNode>[])
          if (n.type != canvasNodeTypeScene) n,
      ],
      byId,
      segments,
    );
    final visible = sorted
        .where((n) => productionGridKind(n, byId[n.clipId]) == filter.value)
        .toList();
    final typo = RevericTheme.typographyOf(context);
    final colors = RevericTheme.colorsOf(context);
    final filters = {
      'character': LocaleKeys.productionCharacter,
      'location': LocaleKeys.productionLocation,
      'item': LocaleKeys.workspaceSidebarCompendium,
      'video': LocaleKeys.productionVideoTag,
      'image': LocaleKeys.mediaImages,
      'audio': LocaleKeys.mediaAudio,
      'segment': LocaleKeys.productionAddSegment,
    };
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(RevericSpacing.lg),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: RevericSpacing.sm,
              runSpacing: RevericSpacing.sm,
              children: [
                for (final entry in filters.entries)
                  RevericFilterChip(
                    label: context.t(entry.value),
                    count: sorted
                        .where(
                          (n) =>
                              productionGridKind(n, byId[n.clipId]) ==
                              entry.key,
                        )
                        .length,
                    selected: filter.value == entry.key,
                    onTap: () => filter.value = entry.key,
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: nodes.hasError || clips.hasError
              ? Center(child: Text(context.t(LocaleKeys.productionFailed)))
              : GridView.builder(
                  padding: const EdgeInsets.all(RevericSpacing.lg),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 290,
                    mainAxisExtent: 236,
                    crossAxisSpacing: RevericSpacing.lg,
                    mainAxisSpacing: RevericSpacing.lg,
                  ),
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final node = visible[index];
                    final clip = byId[node.clipId];
                    final uses = (edges.data ?? <ProductionConnection>[])
                        .where((e) => e.sourceNodeId == node.id)
                        .length;
                    final title = clip?.title ?? node.title;
                    return Material(
                      key: ValueKey('production-grid-${node.id}'),
                      color: colors.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(RevericRadius.large),
                      child: InkWell(
                        onTap: () => onOpen(node),
                        borderRadius: BorderRadius.circular(
                          RevericRadius.large,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(RevericSpacing.lg),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: node.type == canvasNodeTypeStaging
                                    ? Center(
                                        child: RevericIcon(
                                          RevericIcons.cube,
                                          color: colors.textMuted,
                                        ),
                                      )
                                    : ProductionAdoptedFrame(
                                        service: service,
                                        assetId:
                                            clip?.adoptedAssetId ??
                                            node.mediaAssetId,
                                        node: node.isGenerationNode
                                            ? node
                                            : null,
                                      ),
                              ),
                              const SizedBox(height: RevericSpacing.sm),
                              Text(
                                title.isEmpty
                                    ? context.t(
                                        filters[productionGridKind(
                                          node,
                                          clip,
                                        )]!,
                                      )
                                    : title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: typo.uiSemibold,
                              ),
                              if (clip != null)
                                Text(
                                  clip.kind == 'audio'
                                      ? (clip.modelId ?? '')
                                      : '${clip.modelId ?? ''} · ${clip.ratio}${clip.kind == 'image' ? ' · ${clip.resolution}' : ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: typo.uiTiny.copyWith(
                                    color: colors.textMuted,
                                  ),
                                ),
                              Row(
                                children: [
                                  if (clip != null)
                                    Expanded(
                                      child: ProductionTaskStatus(
                                        shots: service.shots,
                                        database: service.library.database,
                                        novelId: service.novelId,
                                        clipId: clip.id,
                                        actions: taskActions,
                                        compact: true,
                                      ),
                                    )
                                  else
                                    const Spacer(),
                                  if (uses > 0)
                                    Row(
                                      children: [
                                        RevericIcon(
                                          RevericIcons.flow_arrow,
                                          size: 12,
                                          color: colors.textMuted,
                                        ),
                                        Text('$uses', style: typo.uiTiny),
                                      ],
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

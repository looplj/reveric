// 职责: 展示可生成图片节点铺满卡片的采用结果与进行中的任务反馈。
// 关联文件:
//   lib/desktop/features/production/node_card.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/database/app_database.dart' show GenerationTaskRequest;
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/theme/theme.dart';
import 'node_card.dart';
import 'task_status.dart';

class ProductionImageNode extends HookWidget {
  const ProductionImageNode({
    super.key,
    required this.service,
    required this.node,
    required this.clip,
    this.taskActions,
    this.selected = false,
  });
  final ProductionCanvasService service;
  final CanvasNode node;
  final ProductionClipRow? clip;
  final ProductionTaskActions? taskActions;
  final bool selected;
  @override
  Widget build(BuildContext context) {
    final clip = this.clip;
    final runs = useStream(
      useMemoized(
        () => service.library.database.generationTaskDao.watchSource(
          novelId: service.novelId,
          sourceType: 'production_clip',
          sourceId: node.clipId!,
        ),
        [service, node.clipId],
      ),
    ).data;
    final adopted = clip?.adoptedAssetId;
    // 采用的图不是这个节点生成的，就是上传或从资产库选来的。
    final uploaded =
        clip?.hasSubject != true &&
        adopted != null &&
        runs != null &&
        !runs.any((r) => r.resultAssetIds.contains(adopted));
    final candidates =
        runs
            ?.where((r) => r.resultAssetIds.contains(adopted))
            .firstOrNull
            ?.resultAssetIds
            .length ??
        0;
    return ProductionNodeFrame(
      service: service,
      node: node,
      taskActions: taskActions,
      frame: ProductionAdoptedFrame(
        service: service,
        assetId: adopted,
        node: node,
        borderRadius: 0,
        playing: selected,
        well: true,
        badge: uploaded
            ? context.t(LocaleKeys.commonImport)
            : candidates > 1
            ? context.t(
                LocaleKeys.productionImageCandidates,
                namedArgs: {'count': '$candidates'},
              )
            : null,
        emptyIcon: clip?.characterId != null
            ? RevericIcons.person
            : clip?.locationId != null
            ? RevericIcons.location_on
            : clip?.itemId != null
            ? RevericIcons.inventory_2
            : RevericIcons.image,
      ),
    );
  }
}

// 职责: 展示音频生成节点的采用结果（可就地播放）、提示词与任务状态。
// 关联文件:
//   lib/desktop/features/production/node_card.dart
//   lib/desktop/features/production/task_status.dart
//   lib/shared/services/production/canvas_service.dart
import 'package:flutter/material.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/models/storyboard/prompt.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/theme/theme.dart';
import 'node_card.dart';
import 'task_status.dart';

class ProductionAudioNode extends StatelessWidget {
  const ProductionAudioNode({
    super.key,
    required this.service,
    required this.node,
    required this.clip,
    required this.selected,
    this.taskActions,
    this.readOnly = false,
  });
  final ProductionCanvasService service;
  final CanvasNode node;
  final ProductionClipRow? clip;
  final bool selected;
  final ProductionTaskActions? taskActions;
  final bool readOnly;
  @override
  Widget build(BuildContext context) => ProductionNodeFrame(
    service: service,
    node: node,
    taskActions: taskActions,
    frame: ProductionAdoptedFrame(
      service: service,
      node: node,
      assetId: clip?.adoptedAssetId,
      emptyIcon: RevericIcons.waveform,
      hint: StoryboardPrompt.parse(clip?.prompt ?? '').plainText,
      well: true,
      borderRadius: 0,
      playing: selected,
      readOnly: readOnly,
    ),
  );
}

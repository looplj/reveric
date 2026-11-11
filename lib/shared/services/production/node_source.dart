// 职责: 解析制作图片节点当前采用的素材、文件路径及所属集。
// 关联文件:
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/production/view_derive_orchestrator.dart
//   lib/shared/services/production/grid_orchestrator.dart
import 'dart:io';
import '../../database/app_database.dart' show AssetRow;
import '../../database/novel_content_database.dart';
import '../../models/video/request.dart';
import '../storyboard/service.dart';
import 'canvas_service.dart';

class ProductionNodeSource {
  ProductionNodeSource._(this.node, this.asset, this.path, this.episodeId);
  final CanvasNode node;
  final AssetRow asset;
  final String path, episodeId;

  static Future<ProductionNodeSource> image(
    ProductionCanvasService canvas,
    String nodeId,
  ) async {
    final node = await canvas.requireNode(nodeId);
    if (!{canvasNodeTypeImage, canvasNodeTypeMedia}.contains(node.type)) {
      throw const StoryboardException('invalid_reference');
    }
    final asset = await canvas.inputAsset(
      ProductionInput.node(nodeId, VideoInputRole.reference_image),
    );
    final path = await File(
      canvas.library.resolve(asset),
    ).resolveSymbolicLinks();
    final episodeId = await canvas.episodeForCanvas(node.canvasId);
    return ProductionNodeSource._(node, asset, path, episodeId);
  }
}

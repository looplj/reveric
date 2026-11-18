// 职责: 将已渲染的剪辑成片登记为受控资产，并在剪辑节点旁创建关联视频节点。
// 关联文件:
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/editing/service.dart
//   lib/desktop/features/editing/export_dialog.dart
import 'dart:io';
import '../../database/novel_content_database.dart';
import '../../models/asset_purpose.dart';
import '../../models/production/media.dart';
import '../editing/service.dart';
import 'canvas_service.dart';
import 'ffmpeg_runner.dart';

class EditingOutputOrchestrator {
  Future<CanvasNode> run({
    required ProductionCanvasService service,
    required String editingId,
    required File file,
    required String name,
    MediaCancellation? cancellation,
  }) async {
    final token = cancellation ?? MediaCancellation();
    final canvasId = await EditingService(
      service.db,
      service.library,
    ).canvasForEditing(editingId);
    final nodes = await service.db.canvasDao.getNodesByCanvas(canvasId);
    final source = nodes.singleWhere((node) => node.editingId == editingId);
    await service.requireEditingNode(source.id);
    final asset = await service.library.importFile(
      file,
      name: name,
      novelId: service.novelId,
      purpose: AssetPurpose.production_output,
      cancellation: token,
    );
    if (token.cancelled) {
      throw const MediaException(MediaFailure.cancelled);
    }
    return service.addDerivedOutput(source.id, asset.id, title: name);
  }
}

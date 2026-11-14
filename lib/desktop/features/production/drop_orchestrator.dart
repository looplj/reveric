// 职责: 读取桌面拖入的数据，导入制作素材并在指定画布坐标创建可撤销节点。
// 关联文件:
//   lib/desktop/features/production/drop_region.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/production/library_service.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:super_clipboard/super_clipboard.dart' as clip;
import '../../../shared/models/asset_purpose.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/services/production/canvas_history.dart';
import '../../../shared/services/production/ffmpeg_runner.dart';
import '../../../shared/database/novel_content_database.dart';

class ProductionDropOrchestrator {
  static const List<clip.DataFormat> formats = [
    clip.Formats.fileUri,
    clip.Formats.png,
    clip.Formats.jpeg,
    clip.Formats.webp,
    clip.Formats.plainTextFile,
    clip.Formats.plainText,
  ];

  Future<T?> _readValue<T extends Object>(
    clip.DataReader reader,
    clip.ValueFormat<T> format,
  ) {
    final completed = Completer<T?>();
    final progress = reader.getValue(
      format,
      completed.complete,
      onError: completed.completeError,
    );
    if (progress == null) {
      completed.complete(null);
    }
    return completed.future;
  }

  Future<void> run({
    required clip.DataReader reader,
    required ProductionCanvasService service,
    required String canvasId,
    required Offset position,
    CanvasHistory? history,
  }) async {
    // 文件优先：同一次系统拖动可能同时携带文件 URI 和文件名文本。
    if (reader.canProvide(clip.Formats.fileUri)) {
      final uri = await _readValue(reader, clip.Formats.fileUri);
      if (uri == null || uri.scheme != 'file') {
        throw const FormatException('Expected a local file');
      }
      await importFile(
        file: File.fromUri(uri),
        service: service,
        canvasId: canvasId,
        position: position,
        history: history,
      );
      return;
    }
    final format = [
      clip.Formats.png,
      clip.Formats.jpeg,
      clip.Formats.webp,
      clip.Formats.plainTextFile,
    ].where(reader.canProvide).firstOrNull;
    if (format != null) {
      final directory = await (await getTemporaryDirectory()).createTemp(
        'production-drop-',
      );
      try {
        final extension = format == clip.Formats.jpeg
            ? '.jpg'
            : format == clip.Formats.webp
            ? '.webp'
            : format == clip.Formats.plainTextFile
            ? '.txt'
            : '.png';
        final file = File(p.join(directory.path, 'drop$extension'));
        final completed = Completer<void>();
        final progress = reader.getFile(format, (data) async {
          try {
            await data.getStream().cast<List<int>>().pipe(file.openWrite());
            completed.complete();
          } catch (error, stack) {
            completed.completeError(error, stack);
          }
        }, onError: completed.completeError);
        if (progress == null) {
          throw const FormatException('Dropped file is unavailable');
        }
        await completed.future;
        await importFile(
          file: file,
          service: service,
          canvasId: canvasId,
          position: position,
          history: history,
        );
      } finally {
        await directory.delete(recursive: true);
      }
      return;
    }
    final text = await _readValue(reader, clip.Formats.plainText);
    if (text == null || text.trim().isEmpty) {
      throw const FormatException('Dropped text is empty');
    }
    await _place(
      service,
      canvasId,
      position,
      history,
      () => service.addText(canvasId, content: text),
    );
  }

  Future<void> importFile({
    required File file,
    required ProductionCanvasService service,
    required String canvasId,
    required Offset position,
    CanvasHistory? history,
  }) async {
    final extension = p.extension(file.path).toLowerCase();
    if (const ['.txt', '.md', '.csv'].contains(extension)) {
      if (await file.length() > 4 * 1024 * 1024) {
        throw const FormatException('Dropped text file exceeds 4 MiB');
      }
      final text = await file.readAsString();
      if (text.trim().isEmpty) {
        throw const FormatException('Dropped text file is empty');
      }
      await _place(
        service,
        canvasId,
        position,
        history,
        () => service.addText(
          canvasId,
          title: p.basenameWithoutExtension(file.path),
          content: text,
        ),
      );
      return;
    }
    if (productionMediaFormat(file.path) == null) {
      throw const FormatException('Unsupported dropped file');
    }
    final asset = await service.library.importFile(
      file,
      name: p.basename(file.path),
      novelId: service.novelId,
      purpose: AssetPurpose.production_upload,
      cancellation: MediaCancellation(),
    );
    await _place(
      service,
      canvasId,
      position,
      history,
      () => service.addMedia(canvasId, asset.id),
    );
  }

  Future<CanvasNode> _place(
    ProductionCanvasService service,
    String canvasId,
    Offset position,
    CanvasHistory? history,
    Future<CanvasNode> Function() create,
  ) => withCanvasHistory(
    history,
    service.shots,
    'drop',
    const [],
    () => service.db.transaction(() async {
      final node = await create();
      await service.moveNodes(canvasId, {
        node.id: (x: position.dx, y: position.dy),
      });
      return node;
    }),
  );
}

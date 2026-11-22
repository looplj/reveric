// 职责: 读取制作画布从桌面导入的数据，将素材持久化并创建可撤销节点。
// 关联文件:
//   lib/desktop/features/production/drop_region.dart
//   lib/desktop/features/production/region.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/production/library_service.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:super_clipboard/super_clipboard.dart' as clip;
import '../../../shared/database/app_database.dart' show AssetRow;
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/models/asset_purpose.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/services/production/canvas_history.dart';
import '../../../shared/services/production/derived_placement.dart';
import '../../../shared/services/production/ffmpeg_runner.dart';
import '../../../shared/theme/theme.dart' show RevericSpacing;

final _log = AppLogger.forModule('ProductionCanvasImport');

const _imageFormats = {
  clip.Formats.png: '.png',
  clip.Formats.jpeg: '.jpg',
  clip.Formats.webp: '.webp',
};

const _dropFileFormats = {..._imageFormats, clip.Formats.plainTextFile: '.txt'};

class ProductionDropOrchestrator {
  static final List<clip.DataFormat> formats = List.unmodifiable([
    clip.Formats.fileUri,
    ..._dropFileFormats.keys,
    clip.Formats.plainText,
  ]);

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
    final format = _dropFileFormats.keys.where(reader.canProvide).firstOrNull;
    if (format != null) {
      await _withReaderFile(
        reader,
        format,
        _dropFileFormats[format]!,
        (file) => importFile(
          file: file,
          service: service,
          canvasId: canvasId,
          position: position,
          history: history,
        ),
      );
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
    final asset = await importMedia(file, service: service);
    await _place(
      service,
      canvasId,
      position,
      history,
      () => service.addMedia(canvasId, asset.id),
    );
  }

  Future<AssetRow> importMedia(
    File file, {
    required ProductionCanvasService service,
    String? name,
  }) => service.library.importFile(
    file,
    name: name ?? p.basename(file.path),
    novelId: service.novelId,
    purpose: AssetPurpose.production_upload,
    cancellation: MediaCancellation(),
  );

  Future<AssetRow?> pasteImage({
    required clip.DataReader reader,
    required ProductionCanvasService service,
    required String imageName,
  }) async {
    if (reader.canProvide(clip.Formats.fileUri)) {
      final uri = await _readValue(reader, clip.Formats.fileUri);
      if (uri != null &&
          uri.scheme == 'file' &&
          productionMediaFormat(uri.path)?.$1 == 'image') {
        return importMedia(File.fromUri(uri), service: service);
      }
    }
    final format = _imageFormats.keys.where(reader.canProvide).firstOrNull;
    if (format == null) {
      return null;
    }
    final extension = _imageFormats[format]!;
    return _withReaderFile(
      reader,
      format,
      extension,
      (file) =>
          importMedia(file, service: service, name: '$imageName$extension'),
    );
  }

  Future<T> _withReaderFile<T>(
    clip.DataReader reader,
    clip.FileFormat format,
    String extension,
    Future<T> Function(File file) useFile,
  ) async {
    final directory = await (await getTemporaryDirectory()).createTemp(
      'production-drop-',
    );
    try {
      final file = File(p.join(directory.path, 'drop$extension'));
      final completed = Completer<void>();
      final progress = reader.getFile(format, (data) async {
        try {
          final sink = file.openWrite();
          try {
            await sink.addStream(data.getStream());
          } finally {
            await sink.close();
          }
          completed.complete();
        } catch (error, stack) {
          completed.completeError(error, stack);
        }
      }, onError: completed.completeError);
      if (progress == null) {
        throw const FormatException('Desktop media data is unavailable');
      }
      await completed.future;
      _log.debug('Desktop file staged');
      return await useFile(file);
    } finally {
      await directory.delete(recursive: true);
      _log.debug('Desktop staging directory removed');
    }
  }

  Future<List<CanvasNode>> placeMedia({
    required List<AssetRow> assets,
    required ProductionCanvasService service,
    required String canvasId,
    required Offset? center,
    required CanvasHistory history,
  }) => withCanvasHistory(
    history,
    service.shots,
    'importMedia',
    const [],
    () async {
      final nodes = <CanvasNode>[];
      final positions = <String, ({double x, double y})>{};
      Offset? right;
      for (final asset in assets) {
        final node = await service.addMedia(canvasId, asset.id);
        nodes.add(node);
        if (center != null) {
          final size = productionNodeSize(
            node,
            mediaType: asset.type,
            aspect: productionMediaAspect(asset.content),
          );
          final position =
              right ?? center - Offset(size.width / 2, size.height / 2);
          positions[node.id] = (x: position.dx, y: position.dy);
          right = position + Offset(size.width + RevericSpacing.x2l, 0);
        }
      }
      if (positions.isNotEmpty) {
        await service.moveNodes(canvasId, positions);
      }
      return nodes;
    },
  );

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

// 职责: 将导演台导出的帧编码、校验并登记为图片或视频资产。
// 关联文件:
//   lib/shared/services/director/export_task.dart
//   lib/shared/services/production/media_service.dart
//   lib/shared/database/daos/asset_dao.dart
import 'dart:io';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import '../../database/app_database.dart';
import '../../utils/random_id.dart';
import '../../utils/storage_paths.dart';
import '../../models/director/document.dart';
import '../../models/production/media.dart';
import '../director/export_task.dart';
import 'library_service.dart';

class DirectorOutputOrchestrator {
  /// 每次导出落到按操作 id 区分的固定路径，相对资产库根目录。
  static String outputPath(
    String operation, {
    required String novelId,
    required bool single,
  }) => RevericPaths.mediaPath(
    novelId,
    single ? 'image' : 'video',
    'director/$operation/${single ? 'still.png' : 'preview.mp4'}',
  );

  Future<AssetRow> run({
    required MediaLibraryService library,
    required String novelId,
    required String documentTitle,
    required String? cameraName,
    required Directory frames,
    required Json manifest,
    required ExportTaskOrchestrator task,
  }) async {
    final operation = manifest['operationId'] as String;
    final single = manifest['kind'] == 'still';
    final path = outputPath(operation, novelId: novelId, single: single);
    final existing = await library.database.assetDao.findByPath(path);
    if (existing != null) {
      if (!await File(library.resolve(existing)).exists()) {
        throw const MediaException(MediaFailure.invalid_media);
      }
      return existing;
    }
    final fps = manifest['fps'] as int;
    final count = manifest['frameCount'] as int;
    final duration = Duration(microseconds: (count * 1000000 / fps).round());
    final source = File(p.join(frames.path, 'frame_000000.png'));
    final destination = File(p.join(library.root.path, path));
    await destination.parent.create(recursive: true);
    if (single) {
      await source.openRead().pipe(destination.openWrite());
    } else {
      final encoding = library.media.encodeVideo(
        inputPath: p.join(frames.path, 'frame_%06d.png'),
        imageSequence: true,
        width: manifest['width'] as int,
        height: manifest['height'] as int,
        fps: fps,
        duration: duration,
      );
      task.cancelEncoding = encoding.cancel;
      try {
        final encoded = await encoding.result;
        try {
          if (encoded.info.frameCount != count ||
              encoded.info.frameRate == null ||
              (encoded.info.frameRate! - fps).abs() > 0.001 ||
              (encoded.info.duration - duration).inMicroseconds.abs() >
                  1000000 / fps) {
            throw const MediaException(MediaFailure.encoding_failed);
          }
          await encoded.file.openRead().pipe(destination.openWrite());
        } finally {
          await encoded.dispose();
        }
      } finally {
        task.cancelEncoding = null;
      }
    }
    if (task.cancelled) {
      throw const MediaException(MediaFailure.cancelled);
    }
    final info = await library.media.probe(destination.path);
    if (info.width != manifest['width'] || info.height != manifest['height']) {
      throw const MediaException(MediaFailure.invalid_media);
    }
    final bytes = await destination.length();
    final hash = (await sha256.bind(destination.openRead()).first).toString();
    return library.database.transaction(() async {
      final previous = await library.database.assetDao.findByPath(path);
      if (previous != null) {
        return previous;
      }
      if (task.cancelled) {
        throw const MediaException(MediaFailure.cancelled);
      }
      final id = buildRandomId('ast', length: 12);
      await library.database.assetDao.insertAsset(
        AssetsCompanion.insert(
          id: id,
          type: single ? 'image' : 'video',
          purpose: AssetPurpose.director_output.value,
          name: Value(
            [documentTitle, ?cameraName, single ? 'PNG' : 'MP4'].join(' · '),
          ),
          novelId: Value(novelId),
          source: const Value('director'),
          path: Value(path),
          content: Value(
            single
                ? ImageAssetContent(
                    mimeType: 'image/png',
                    width: info.width,
                    height: info.height,
                    bytes: bytes,
                  )
                : VideoAssetContent(
                    mimeType: 'video/mp4',
                    width: info.width,
                    height: info.height,
                    durationMs: info.duration.inMilliseconds,
                    bytes: bytes,
                  ),
          ),
          sha256: Value(hash),
        ),
      );
      return (await library.database.assetDao.getAsset(id))!;
    });
  }
}

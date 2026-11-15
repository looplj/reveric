// 职责: 提供受控媒体文件读写、资产导入导出与按路径缓存的实测规格。
// 关联文件:
//   lib/shared/services/production/import_orchestrator.dart
//   lib/shared/providers/production_media.dart
//   lib/shared/database/daos/asset_dao.dart
// 遵循的 Rules:
//   .agents/rules/file-access.md
//   .agents/rules/service-naming.md

import 'dart:io';
import 'package:path/path.dart' as p;
import '../../database/app_database.dart';
import '../../logger/app_logger.dart';
import '../../models/asset_purpose.dart';
import '../../models/production/media.dart';
import '../../utils/storage_paths.dart';
import 'ffmpeg_runner.dart';
import 'import_orchestrator.dart';
import 'media_service.dart';
import 'video_thumbnail_cache.dart';

final _log = AppLogger.forModule('MediaLibrary');

class MediaLibraryService {
  MediaLibraryService(this.database, this.media, this.root);
  final AppDatabase database;
  final MediaService media;
  final Directory root;

  final _metadata = <(String, int, DateTime), Future<MediaInfo>>{};
  late final VideoThumbnailCache _videoThumbnails = VideoThumbnailCache(
    media: media,
    root: root,
  );

  /// 仅读取已缓存的视频第 0 帧 PNG 缩略图，未命中返回 null 且不触发 ffmpeg。
  Future<File?> cachedVideoThumbnail(String stored) {
    final path = relativePath(stored);
    final resolved = resolvePath(path);
    return _videoThumbnails.getIfCached(
      relativePath: path,
      resolvedPath: resolved,
    );
  }

  /// 抽取并缓存视频第 0 帧 PNG 缩略图，源文件大小或修改时间变更时自动失效。
  Future<File> videoThumbnail(
    String stored, {
    MediaCancellation? cancellation,
  }) {
    final path = relativePath(stored);
    final resolved = resolvePath(path);
    return _videoThumbnails.getOrCreate(
      relativePath: path,
      resolvedPath: resolved,
      cancellation: cancellation,
    );
  }

  /// Managed outputs are immutable; stat keys also invalidate replaced/imported files.
  Future<MediaInfo> probePath(String stored) async {
    final path = relativePath(stored);
    final file = File(resolvePath(path));
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size == 0) {
      _log.warning(
        'operation=metadata file unavailable name=${p.basename(path)}',
      );
      throw const MediaException(MediaFailure.invalid_media);
    }
    final key = (path, stat.size, stat.modified);
    final cached = _metadata.remove(key);
    if (cached != null) {
      _metadata[key] = cached;
      return cached;
    }
    late final Future<MediaInfo> pending;
    pending = media.probe(file.path).catchError((
      Object error,
      StackTrace stack,
    ) {
      if (identical(_metadata[key], pending)) {
        _metadata.remove(key);
      }
      _log.error(
        'operation=metadata probe failed file=${p.basename(path)}',
        error: error,
        stackTrace: stack,
      );
      Error.throwWithStackTrace(error, stack);
    });
    _metadata[key] = pending;
    if (_metadata.length > 128) {
      _metadata.remove(_metadata.keys.first);
    }
    return pending;
  }

  /// [addToLibrary] 同时将新建或复用的资产加入素材库；false 保留已有入库状态。
  Future<AssetRow> importFile(
    File file, {
    required String name,
    required String novelId,
    required AssetPurpose purpose,
    required MediaCancellation cancellation,
    bool addToLibrary = false,
    String source = 'uploaded',
    String? batchId,
    String? prompt,
    String? model,
    void Function(double progress)? onProgress,
  }) => MediaImportOrchestrator().run(
    database: database,
    root: root,
    media: media,
    file: file,
    name: name,
    novelId: novelId,
    purpose: purpose,
    cancellation: cancellation,
    addToLibrary: addToLibrary,
    source: source,
    batchId: batchId,
    prompt: prompt,
    model: model,
    onProgress: onProgress,
  );

  String resolve(AssetRow asset) {
    final stored = asset.path;
    if (stored == null) {
      throw const MediaException(MediaFailure.invalid_media);
    }
    return resolvePath(stored);
  }

  String relativePath(String stored) => p.posix.joinAll(
    p.split(p.relative(resolvePath(stored), from: root.path)),
  );

  String resolvePath(String stored) {
    if (stored.trim().isEmpty || stored.contains('://')) {
      throw const MediaException(MediaFailure.invalid_media);
    }
    final syntax = RevericPaths.contextForStoredPath(stored);
    final segments = syntax.split(stored);
    if (segments.contains('..')) {
      throw const MediaException(MediaFailure.invalid_media);
    }
    final relative = syntax.isRelative(stored)
        ? p.joinAll(segments)
        : p.isWithin(root.path, stored)
        ? p.relative(stored, from: root.path)
        : throw const MediaException(MediaFailure.invalid_media);
    if (p.split(relative).first != 'file_workspaces') {
      throw const MediaException(MediaFailure.invalid_media);
    }
    final path = p.normalize(p.join(root.path, relative));
    if (!p.isWithin(root.path, path)) {
      throw const MediaException(MediaFailure.invalid_media);
    }
    return path;
  }

  Future<void> delete(String id) => database.assetDao.softDeleteAsset(id);

  Future<void> exportFile(AssetRow asset, String destination) async {
    final source = File(resolve(asset));
    final target = File(destination);
    var created = false;
    try {
      if (!await source.exists()) {
        throw const MediaException(MediaFailure.invalid_media);
      }
      await target.create(exclusive: true);
      created = true;
      await source.openRead().pipe(target.openWrite());
      _log.info('operation=export completed id=${asset.id}');
    } catch (error, stack) {
      _log.error(
        'operation=export failed id=${asset.id}',
        error: error,
        stackTrace: stack,
      );
      if (created && await target.exists()) {
        await target.delete();
      }
      rethrow;
    }
  }
}

// 职责: 在一次发布或详情浏览会话中保留上传凭证、临时包和可恢复的下载进度，并按缓存键串行同一画布的下载与解包。
// 关联文件:
//   lib/shared/services/canvas_gallery/service.dart
//   lib/shared/services/production/canvas_package.dart
//   lib/desktop/features/canvas_gallery/publish_dialog.dart
//   lib/desktop/features/canvas_gallery/detail.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../logger/app_logger.dart';
import '../../utils/storage_paths.dart';
import '../production/canvas_package.dart';
import '../production/media_service.dart';
import 'service.dart';

final _log = AppLogger.forModule('CanvasGalleryCache');

typedef CanvasGalleryProgress = void Function(double fraction);

enum CanvasGalleryLoadStage { downloading, preparing }

class CanvasGalleryPublishOrchestrator {
  final _cancel = CancelToken();
  final _token = _randomValue();
  final _requestId = _randomValue();
  String? _uploadId;

  void cancel() => _cancel.cancel();

  Future<CanvasGalleryPublicationResult> publish({
    required CanvasGalleryService service,
    required File cover,
    required File archive,
    required String title,
    required String description,
    CanvasGalleryProgress? onProgress,
  }) async {
    final coverSize = await cover.length();
    final archiveSize = await archive.length();
    if (coverSize <= 0 ||
        coverSize > canvasGalleryCoverLimit ||
        archiveSize <= 0 ||
        archiveSize > canvasGalleryPackageLimit) {
      throw const CanvasGalleryFailure('package_too_large');
    }

    for (var negotiation = 0; negotiation < 3; negotiation++) {
      final upload = await service.requestUpload(
        token: _token,
        requestId: _requestId,
        coverSize: coverSize,
        archiveSize: archiveSize,
        uploadId: _uploadId,
        cancel: _cancel,
      );
      if (_uploadId != null && upload.id != _uploadId) {
        throw const CanvasGalleryFailure('invalid_reply');
      }
      _uploadId = upload.id;
      try {
        await _send(
          service: service,
          upload: upload,
          cover: cover,
          coverSize: coverSize,
          archive: archive,
          archiveSize: archiveSize,
          onProgress: onProgress,
        );
      } on CanvasGalleryFailure catch (error) {
        final renegotiate =
            error.code == 'signature_expired' ||
            error.status == 403 ||
            error.status == 412;
        if (renegotiate && negotiation < 2) {
          continue;
        }
        rethrow;
      }
      try {
        return await _finish(service, upload.id, title, description);
      } on CanvasGalleryFailure catch (error) {
        if (error.code == 'upload_incomplete' && negotiation < 2) {
          continue;
        }
        rethrow;
      }
    }
    throw const CanvasGalleryFailure('upload_incomplete');
  }

  Future<void> _send({
    required CanvasGalleryService service,
    required CanvasGalleryUpload upload,
    required File cover,
    required int coverSize,
    required File archive,
    required int archiveSize,
    CanvasGalleryProgress? onProgress,
  }) async {
    final partCount =
        (archiveSize + canvasGalleryPartSize - 1) ~/ canvasGalleryPartSize;
    final seen = <int>{};
    final parts = <({CanvasGallerySignedPut signed, int offset, int length})>[];
    for (final signed in upload.parts) {
      final part = signed.part;
      if (part == null || part < 1 || part > partCount || !seen.add(part)) {
        throw const CanvasGalleryFailure('invalid_reply');
      }
      final offset = (part - 1) * canvasGalleryPartSize;
      final length = math.min(canvasGalleryPartSize, archiveSize - offset);
      parts.add((signed: signed, offset: offset, length: length));
    }
    final expected = coverSize + archiveSize;
    var uploaded =
        archiveSize -
        parts.fold(0, (size, part) => size + part.length) +
        (upload.cover == null ? coverSize : 0);
    onProgress?.call(uploaded / expected);
    if (upload.cover case final signed?) {
      await service.put(
        signed: signed,
        source: cover,
        offset: 0,
        length: coverSize,
        cancel: _cancel,
      );
      uploaded += coverSize;
      onProgress?.call(uploaded / expected);
    }
    // Bound simultaneous streams and wait for all in-flight writes before
    // requesting new signatures or letting the dialog clean up the archive.
    for (var start = 0; start < parts.length; start += 4) {
      await Future.wait([
        for (final part in parts.skip(start).take(4))
          service
              .put(
                signed: part.signed,
                source: archive,
                offset: part.offset,
                length: part.length,
                cancel: _cancel,
              )
              .then((_) {
                uploaded += part.length;
                onProgress?.call(uploaded / expected);
              }),
      ]);
    }
  }

  Future<CanvasGalleryPublicationResult> _finish(
    CanvasGalleryService service,
    String id,
    String title,
    String description,
  ) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await service.create(
          token: _token,
          uploadId: id,
          title: title,
          description: description,
          cancel: _cancel,
        );
      } on CanvasGalleryFailure catch (error) {
        if (error.code != 'upload_finalizing' || attempt >= 4) {
          rethrow;
        }
        final seconds = (error.retryAfter?.inSeconds ?? 1).clamp(1, 30);
        await Future.any([
          Future<void>.delayed(Duration(seconds: seconds)),
          _cancel.whenCancel,
        ]);
        if (_cancel.isCancelled) {
          throw const CanvasGalleryFailure('cancelled');
        }
      }
    }
  }
}

class CanvasGalleryArchiveOrchestrator {
  CanvasGalleryArchiveOrchestrator({
    this.resolveCacheDirectory,
    this.maxCacheEntries = _defaultMaxCacheEntries,
    this.maxCacheBytes = _defaultMaxCacheBytes,
  });

  static const int _defaultMaxCacheEntries = 20;
  static const int _defaultMaxCacheBytes = 2 * 1024 * 1024 * 1024;
  static const Duration _stalePartAge = Duration(hours: 24);

  /// 进程内当前正被详情页打开的缓存目录集合（引用计数），供 LRU 淘汰跳过，
  /// 避免在 Windows 上删除仍有 SQLite / 媒体句柄占用的目录。
  static final _activeCacheCounts = <String, int>{};

  /// 同一缓存目录的下载、解包和目录替换。退出详情不会取消已接手的下一次打开。
  static final _cacheTurn = <String, Future<void>>{};

  final FutureOr<Directory> Function()? resolveCacheDirectory;
  final int maxCacheEntries;
  final int maxCacheBytes;

  final _cancel = CancelToken();
  Future<Directory>? _preparing;
  Future<ProductionCanvasPackagePreview>? _reading;
  ProductionCanvasPackagePreview? _preview;
  String? _leasedCachePath;
  bool _closed = false;

  static void _acquireLease(String normalizedPath) {
    _activeCacheCounts[normalizedPath] =
        (_activeCacheCounts[normalizedPath] ?? 0) + 1;
  }

  static void _releaseLease(String normalizedPath) {
    final current = _activeCacheCounts[normalizedPath] ?? 0;
    if (current <= 1) {
      _activeCacheCounts.remove(normalizedPath);
    } else {
      _activeCacheCounts[normalizedPath] = current - 1;
    }
  }

  static bool _isCacheActive(String normalizedPath) =>
      (_activeCacheCounts[normalizedPath] ?? 0) > 0;

  void _holdLease(Directory dir) {
    final normalized = p.normalize(dir.absolute.path);
    if (_leasedCachePath == normalized) {
      return;
    }
    if (_leasedCachePath != null) {
      _releaseLease(_leasedCachePath!);
    }
    _acquireLease(normalized);
    _leasedCachePath = normalized;
  }

  void _dropLease() {
    if (_leasedCachePath != null) {
      _releaseLease(_leasedCachePath!);
      _leasedCachePath = null;
    }
  }

  Future<Directory> _cacheRoot() async {
    final directory = resolveCacheDirectory != null
        ? await resolveCacheDirectory!()
        : Directory(
            p.join(RevericPaths.supportRoot, 'cache', 'canvas_gallery'),
          );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  ({Directory dir, File ready, File part}) _cachePaths(
    Directory root,
    CanvasGalleryDetail item,
  ) {
    final idPart = _cacheIdPart(item.id);
    final stem = '${idPart}_v${item.version}_${item.size}';
    final dir = Directory(p.join(root.path, stem));
    final ready = File(p.join(dir.path, canvasGalleryCacheReadyMarker));
    final part = File(p.join(root.path, '$stem.part'));
    if (!p.isWithin(root.path, dir.path) || !p.isWithin(root.path, part.path)) {
      throw const CanvasGalleryFailure('invalid_reply');
    }
    return (dir: dir, ready: ready, part: part);
  }

  String _cacheIdPart(String id) {
    final sanitized = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    if (sanitized.length <= 24) {
      return sanitized;
    }
    return '${sanitized.substring(0, 16)}_'
        '${sha256.convert(utf8.encode(id)).toString().substring(0, 8)}';
  }

  /// 这一版内容包已经解包在本地缓存里。
  Future<bool> hasReadyPackage(CanvasGalleryDetail item) async {
    if (_closed) {
      return false;
    }
    final root = await _cacheRoot();
    return _hasReadyCache(_cachePaths(root, item).ready);
  }

  /// 这个画布有任意已解包版本。详情接口返回前用它判断要不要跳过封面卡。
  Future<bool> hasAnyReadyPackage(String id) async {
    if (_closed) {
      return false;
    }
    final root = await _cacheRoot();
    if (!await root.exists()) {
      return false;
    }
    final pattern = RegExp('^${RegExp.escape(_cacheIdPart(id))}_v\\d+_\\d+\$');
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      if (!pattern.hasMatch(p.basename(entity.path))) {
        continue;
      }
      if (await File(
        p.join(entity.path, canvasGalleryCacheReadyMarker),
      ).exists()) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _hasReadyCache(File ready) => ready.exists();

  Future<void> _touchReady(File ready, String id) async {
    try {
      await ready.setLastModified(DateTime.now());
    } on FileSystemException catch (error) {
      _log.warning('Failed to touch gallery cache mtime id=$id error=$error');
    }
  }

  /// 确保该画布条目已解包并落盘到本地缓存目录；命中缓存时直接返回，未命中时走断点续传下载并解包。
  Future<Directory> prepareCache({
    required CanvasGalleryService service,
    required CanvasGalleryDetail item,
    required MediaService media,
    CanvasGalleryProgress? onProgress,
    void Function(CanvasGalleryLoadStage stage)? onStage,
  }) {
    if (_closed) {
      return Future.error(const CanvasGalleryFailure('cancelled'));
    }
    return _preparing ??= _ensurePreparedCache(
      service: service,
      item: item,
      media: media,
      onProgress: onProgress,
      onStage: onStage,
    ).whenComplete(() => _preparing = null);
  }

  Future<T> _exclusiveCache<T>(String key, Future<T> Function() action) {
    final previous = _cacheTurn[key] ?? Future<void>.value();
    final gate = Completer<void>();
    _cacheTurn[key] = gate.future;
    return previous
        .then<void>((_) {}, onError: (_, _) {})
        .then((_) => action())
        .whenComplete(() {
          if (!gate.isCompleted) {
            gate.complete();
          }
          if (identical(_cacheTurn[key], gate.future)) {
            _cacheTurn.remove(key);
          }
        });
  }

  Future<Directory> _ensurePreparedCache({
    required CanvasGalleryService service,
    required CanvasGalleryDetail item,
    required MediaService media,
    required CanvasGalleryProgress? onProgress,
    required void Function(CanvasGalleryLoadStage stage)? onStage,
    bool forceRefresh = false,
  }) async {
    final root = await _cacheRoot();
    final paths = _cachePaths(root, item);
    final key = p.normalize(paths.dir.absolute.path);
    return _exclusiveCache(key, () async {
      if (_closed) {
        throw const CanvasGalleryFailure('cancelled');
      }
      if (!forceRefresh && await _hasReadyCache(paths.ready)) {
        await _touchReady(paths.ready, item.id);
        onProgress?.call(1);
        return paths.dir;
      }
      if (forceRefresh && await paths.dir.exists()) {
        final active = _isCacheActive(p.normalize(paths.dir.absolute.path));
        if (active) {
          _log.warning('Gallery cache is open, skip replace id=${item.id}');
          throw const ProductionCanvasPackageException('invalid_package');
        }
        try {
          await paths.dir.delete(recursive: true);
        } on FileSystemException catch (error) {
          _log.warning(
            'Failed to clear stale gallery cache id=${item.id} error=$error',
          );
        }
      }
      onStage?.call(CanvasGalleryLoadStage.downloading);
      await service.download(
        item: item,
        file: paths.part,
        onProgress: onProgress == null
            ? null
            : (value) => onProgress((value * 0.7).clamp(0.0, 0.7)),
        cancel: _cancel,
      );
      if (_closed) {
        throw const CanvasGalleryFailure('cancelled');
      }
      onStage?.call(CanvasGalleryLoadStage.preparing);
      try {
        await prepareProductionCanvasPackageCache(
          paths.part,
          paths.dir,
          media: media,
          onProgress: onProgress == null
              ? null
              : (value) => onProgress((0.7 + value * 0.3).clamp(0.7, 1.0)),
        );
      } on ProductionCanvasPackageException catch (error) {
        // 字节数已经对齐的坏包会被 download 当成完成。完整性失败必须丢掉，
        // 否则重试不会再请求。下载中断留下的短文件不走这里，仍可续传。
        if (error.code == 'invalid_package') {
          _log.warning(
            'Discarding corrupt gallery package id=${item.id} bytes=${item.size}',
          );
          await _tryDeleteFile(paths.part);
        }
        rethrow;
      }
      // 解包落盘成功后删除临时 .part，避免磁盘保留双份体积。
      try {
        if (await paths.part.exists()) {
          await paths.part.delete();
        }
      } on FileSystemException catch (error) {
        _log.warning(
          'Failed to delete gallery part file id=${item.id} error=$error',
        );
      }
      await _evictCache(root, keepPath: p.normalize(paths.dir.absolute.path));
      return paths.dir;
    });
  }

  Future<void> _evictCache(Directory root, {required String keepPath}) async {
    try {
      final now = DateTime.now();
      final entries = <({Directory dir, int size, DateTime modified})>[];
      await for (final entity in root.list(followLinks: false)) {
        if (entity is File) {
          final name = p.basename(entity.path);
          if (name.endsWith('.canvas.zip')) {
            await _tryDeleteFile(entity);
            continue;
          }
          if (name.endsWith('.part')) {
            final stat = await entity.stat();
            if (now.difference(stat.modified) > _stalePartAge) {
              await _tryDeleteFile(entity);
            }
          }
          continue;
        }
        if (entity is! Directory) {
          continue;
        }
        final name = p.basename(entity.path);
        final normalized = p.normalize(entity.absolute.path);
        if (name.contains('.tmp_')) {
          final stat = await entity.stat();
          if (now.difference(stat.modified) > _stalePartAge) {
            await _tryDeleteDirectory(entity);
          }
          continue;
        }
        final ready = File(p.join(entity.path, canvasGalleryCacheReadyMarker));
        if (!await ready.exists()) {
          final stat = await entity.stat();
          if (now.difference(stat.modified) > _stalePartAge &&
              !_isCacheActive(normalized)) {
            await _tryDeleteDirectory(entity);
          }
          continue;
        }
        final readyStat = await ready.stat();
        final size = await _directorySize(entity);
        entries.add((dir: entity, size: size, modified: readyStat.modified));
      }
      entries.sort((a, b) => b.modified.compareTo(a.modified));
      var keptCount = 0;
      var keptBytes = 0;
      for (final entry in entries) {
        final normalized = p.normalize(entry.dir.absolute.path);
        final pinned =
            p.equals(normalized, keepPath) || _isCacheActive(normalized);
        if (pinned ||
            (keptCount < maxCacheEntries &&
                keptBytes + entry.size <= maxCacheBytes)) {
          keptCount += 1;
          keptBytes += entry.size;
        } else {
          await _tryDeleteDirectory(entry.dir);
        }
      }
    } catch (error, stackTrace) {
      _log.error(
        'Gallery cache eviction failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<int> _directorySize(Directory directory) async {
    var total = 0;
    try {
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          try {
            total += await entity.length();
          } on FileSystemException {
            continue;
          }
        }
      }
    } on FileSystemException {
      return total;
    }
    return total;
  }

  Future<void> _tryDeleteFile(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException catch (error) {
      _log.warning('Skipped deleting gallery cache file: $error');
    }
  }

  Future<void> _tryDeleteDirectory(Directory dir) async {
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } on FileSystemException catch (error) {
      _log.warning('Skipped deleting gallery cache directory: $error');
    }
  }

  Future<ProductionCanvasPackagePreview> preview({
    required CanvasGalleryService service,
    required CanvasGalleryDetail item,
    required MediaService media,
    CanvasGalleryProgress? onProgress,
    void Function(CanvasGalleryLoadStage stage)? onStage,
  }) {
    if (_closed) {
      return Future.error(const CanvasGalleryFailure('cancelled'));
    }
    final previous = _preview;
    if (previous != null && previous.canvas != null) {
      return Future.value(previous);
    }
    return _reading ??= _openPreview(
      service: service,
      item: item,
      media: media,
      onProgress: onProgress,
      onStage: onStage,
    ).whenComplete(() => _reading = null);
  }

  Future<ProductionCanvasPackagePreview> _openPreview({
    required CanvasGalleryService service,
    required CanvasGalleryDetail item,
    required MediaService media,
    required CanvasGalleryProgress? onProgress,
    required void Function(CanvasGalleryLoadStage stage)? onStage,
  }) async {
    final root = await _cacheRoot();
    final paths = _cachePaths(root, item);
    final wasCached = await _hasReadyCache(paths.ready);
    final dir = await prepareCache(
      service: service,
      item: item,
      media: media,
      onProgress: onProgress,
      onStage: onStage,
    );
    if (_closed) {
      throw const CanvasGalleryFailure('cancelled');
    }
    _holdLease(dir);
    ProductionCanvasPackagePreview opened;
    try {
      opened = await openProductionCanvasPackageCache(dir, media: media);
    } on ProductionCanvasPackageException catch (error) {
      if (!wasCached || error.code != 'invalid_package') {
        _dropLease();
        rethrow;
      }
      _log.warning('Gallery cache invalid, redownloading id=${item.id}');
      _dropLease();
      final refreshed = await _ensurePreparedCache(
        service: service,
        item: item,
        media: media,
        onProgress: onProgress,
        onStage: onStage,
        forceRefresh: true,
      );
      if (_closed) {
        throw const CanvasGalleryFailure('cancelled');
      }
      _holdLease(refreshed);
      opened = await openProductionCanvasPackageCache(refreshed, media: media);
    } catch (_) {
      _dropLease();
      rethrow;
    }
    if (_closed) {
      await opened.close();
      _dropLease();
      throw const CanvasGalleryFailure('cancelled');
    }
    final previous = _preview;
    _preview = opened;
    if (previous != null && !identical(previous, opened)) {
      await previous.close();
    }
    return opened;
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _cancel.cancel();
    await _reading?.then<void>((_) {}, onError: (Object _) {});
    await _preparing?.then<void>((_) {}, onError: (Object _) {});
    await _preview?.close();
    _preview = null;
    _dropLease();
  }
}

String _randomValue() {
  final random = math.Random.secure();
  return base64Url
      .encode(List<int>.generate(32, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

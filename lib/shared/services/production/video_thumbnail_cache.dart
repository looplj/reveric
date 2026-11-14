// 职责: 按视频文件规格缓存第 0 帧缩略图，合并并发抽取请求并按磁盘上限 LRU 淘汰。
// 关联文件:
//   lib/shared/services/production/library_service.dart
//   lib/shared/services/production/media_service.dart
//   lib/shared/services/production/ffmpeg_runner.dart
// 遵循的 Rules:
//   .agents/rules/file-access.md
//   .agents/rules/error-handling.md

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../../logger/app_logger.dart';
import '../../models/production/media.dart';
import '../../utils/random_id.dart';
import 'ffmpeg_runner.dart';
import 'media_service.dart';

final _log = AppLogger.forModule('VideoThumbCache');

class VideoThumbnailCache {
  VideoThumbnailCache({
    required this.media,
    required this.root,
    this.maxBytes = defaultMaxBytes,
    this.maxFiles = defaultMaxFiles,
  });

  static const int defaultMaxBytes = 128 * 1024 * 1024;
  static const int defaultMaxFiles = 1000;
  static const Duration _stalePendingAge = Duration(hours: 1);
  static const String _pendingPrefix = '.pending_';

  final MediaService media;
  final Directory root;
  final int maxBytes;
  final int maxFiles;

  final _inFlight = <String, _ThumbJob>{};
  Future<Directory>? _directory;
  Future<void> _evictTail = Future.value();

  Future<Directory> _ensureDirectory() {
    return _directory ??= () async {
      final dir = Directory(p.join(root.path, 'cache', 'video_thumbs'));
      await dir.create(recursive: true);
      await _sweepStalePending(dir);
      return dir;
    }().catchError((Object error, StackTrace stack) {
      _directory = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  static Future<void> _sweepStalePending(Directory dir) async {
    final now = DateTime.now();
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      if (!p.basename(entity.path).startsWith(_pendingPrefix)) {
        continue;
      }
      try {
        final stat = await entity.stat();
        if (now.difference(stat.modified) > _stalePendingAge) {
          await entity.delete();
        }
      } on FileSystemException catch (error) {
        _log.warning('stale pending thumbnail sweep failed: $error');
      }
    }
  }

  Future<File> getOrCreate({
    required String relativePath,
    required String resolvedPath,
    MediaCancellation? cancellation,
  }) async {
    if (cancellation?.cancelled == true) {
      throw const MediaException(MediaFailure.cancelled);
    }
    final stat = await File(resolvedPath).stat();
    if (stat.type != FileSystemEntityType.file || stat.size == 0) {
      throw const MediaException(MediaFailure.invalid_media);
    }
    final key = sha256
        .convert(
          utf8.encode(
            'v1\n$relativePath\n${stat.size}\n${stat.modified.microsecondsSinceEpoch}',
          ),
        )
        .toString();
    final dir = await _ensureDirectory();
    if (cancellation?.cancelled == true) {
      throw const MediaException(MediaFailure.cancelled);
    }
    final target = File(p.join(dir.path, '$key.png'));
    if (await target.exists() && await target.length() > 0) {
      unawaited(_touch(target));
      return target;
    }
    final job = _inFlight.putIfAbsent(
      key,
      () => _startJob(key, dir, resolvedPath, target),
    );
    return _awaitJob(key, job, cancellation);
  }

  _ThumbJob _startJob(
    String key,
    Directory dir,
    String resolvedPath,
    File target,
  ) {
    final job = _ThumbJob();
    job.future = () async {
      final pending = File(
        p.join(dir.path, '$_pendingPrefix${buildRandomId('thumb')}.png'),
      );
      try {
        await media.captureThumbnail(
          resolvedPath,
          pending,
          cancellation: job.token,
        );
        if (job.token.cancelled) {
          throw const MediaException(MediaFailure.cancelled);
        }
        if (!await pending.exists() || await pending.length() == 0) {
          throw const MediaException(MediaFailure.encoding_failed);
        }
        await pending.rename(target.path);
        unawaited(_touch(target));
        unawaited(_scheduleEvict(dir));
        return target;
      } finally {
        if (identical(_inFlight[key], job)) {
          _inFlight.remove(key);
        }
        try {
          if (await pending.exists()) {
            await pending.delete();
          }
        } on FileSystemException catch (error) {
          _log.warning('pending thumbnail cleanup failed: $error');
        }
      }
    }();
    job.future.ignore();
    return job;
  }

  Future<File> _awaitJob(
    String key,
    _ThumbJob job,
    MediaCancellation? cancellation,
  ) {
    if (cancellation?.cancelled == true) {
      return Future.error(const MediaException(MediaFailure.cancelled));
    }
    final completer = Completer<File>();
    job.waiters++;
    var settled = false;

    void onCancel() {
      if (settled) {
        return;
      }
      settled = true;
      job.waiters--;
      if (job.waiters <= 0) {
        if (identical(_inFlight[key], job)) {
          _inFlight.remove(key);
        }
        unawaited(job.token.cancel());
      }
      if (!completer.isCompleted) {
        completer.completeError(const MediaException(MediaFailure.cancelled));
      }
    }

    cancellation?.addCancelListener(onCancel);
    job.future.then(
      (file) {
        cancellation?.removeCancelListener(onCancel);
        if (!settled) {
          settled = true;
          job.waiters--;
          if (!completer.isCompleted) {
            completer.complete(file);
          }
        }
      },
      onError: (Object error, StackTrace stack) {
        cancellation?.removeCancelListener(onCancel);
        if (!settled) {
          settled = true;
          job.waiters--;
          if (!completer.isCompleted) {
            completer.completeError(error, stack);
          }
        }
      },
    );
    return completer.future;
  }

  static Future<void> _touch(File file) async {
    try {
      await file.setLastModified(DateTime.now());
    } on FileSystemException catch (_) {
      // 命中缓存时更新访问时间失败（例如文件刚被淘汰）不影响读取。
    }
  }

  Future<void> _scheduleEvict(Directory dir) {
    final next = _evictTail.then((_) async {
      try {
        await _evict(dir);
      } on FileSystemException catch (_) {
        // 缓存目录可能在测试清理或外部重置时被移除，不影响主流程。
      }
    });
    _evictTail = next;
    return next;
  }

  Future<void> _evict(Directory dir) async {
    final entries = <({File file, int size, DateTime modified})>[];
    var total = 0;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final name = p.basename(entity.path);
      if (name.startsWith(_pendingPrefix) || !name.endsWith('.png')) {
        continue;
      }
      try {
        final stat = await entity.stat();
        if (stat.type != FileSystemEntityType.file) {
          continue;
        }
        total += stat.size;
        entries.add((file: entity, size: stat.size, modified: stat.modified));
      } on FileSystemException catch (_) {
        continue;
      }
    }
    if (total <= maxBytes && entries.length <= maxFiles) {
      return;
    }
    entries.sort((a, b) => a.modified.compareTo(b.modified));
    var remaining = entries.length;
    for (final entry in entries) {
      if (total <= maxBytes && remaining <= maxFiles) {
        break;
      }
      try {
        await entry.file.delete();
      } on FileSystemException catch (_) {
        continue;
      }
      total -= entry.size;
      remaining--;
    }
  }
}

class _ThumbJob {
  final MediaCancellation token = MediaCancellation();
  int waiters = 0;
  late final Future<File> future;
}

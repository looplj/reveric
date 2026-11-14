// 职责: 验证视频首帧缩略图缓存的抽取、并发合并、取消传播、修改失效与 LRU 淘汰。
// 关联文件:
//   lib/shared/services/production/video_thumbnail_cache.dart
//   lib/shared/services/production/library_service.dart
//   lib/shared/services/production/ffmpeg_runner.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/video_thumbnail_cache.dart';

final Uint8List _oneByOnePng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

void main() {
  late Directory temporary;
  late Directory root;
  late _Media media;
  late VideoThumbnailCache cache;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('video-thumb-cache-');
    root = await Directory(p.join(temporary.path, 'support')).create();
    media = _Media();
    cache = VideoThumbnailCache(media: media, root: root);
  });

  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  Future<File> writeVideo(String relativePath, {List<int>? bytes}) async {
    final file = File(p.join(root.path, relativePath));
    await file.parent.create(recursive: true);
    return file.writeAsBytes(bytes ?? const [1, 2, 3, 4]);
  }

  test('extracts once on miss and reuses disk cache on subsequent calls', () async {
    final video = await writeVideo('file_workspaces/work/videos/clip.mp4');

    final first = await cache.getOrCreate(
      relativePath: 'file_workspaces/work/videos/clip.mp4',
      resolvedPath: video.path,
    );
    expect(media.calls, 1);
    expect(await first.exists(), isTrue);
    expect(await first.readAsBytes(), _oneByOnePng);

    final second = await cache.getOrCreate(
      relativePath: 'file_workspaces/work/videos/clip.mp4',
      resolvedPath: video.path,
    );
    expect(media.calls, 1);
    expect(second.path, first.path);
  });

  test('MediaLibraryService.videoThumbnail resolves relative paths cleanly', () async {
    final db = AppDatabase.forTest(NativeDatabase.memory());
    try {
      final library = MediaLibraryService(db, media, root);
      await writeVideo('file_workspaces/work/videos/via_library.mp4');

      final thumb = await library.videoThumbnail(
        'file_workspaces/work/videos/via_library.mp4',
      );
      expect(await thumb.exists(), isTrue);
      expect(media.calls, 1);
    } finally {
      await db.close();
    }
  });

  test(
    'deduplicates concurrent callers and only cancels extraction when all waiters cancel',
    () async {
      final video = await writeVideo('file_workspaces/work/videos/shared.mp4');
      final sharedStarted = Completer<void>();
      final gate = Completer<void>();
      media.onCapture = (input, output, cancellation) async {
        if (!sharedStarted.isCompleted) {
          sharedStarted.complete();
        }
        await gate.future;
      };

      final firstCancel = MediaCancellation();
      final secondCancel = MediaCancellation();
      final first = cache.getOrCreate(
        relativePath: 'file_workspaces/work/videos/shared.mp4',
        resolvedPath: video.path,
        cancellation: firstCancel,
      );
      final second = cache.getOrCreate(
        relativePath: 'file_workspaces/work/videos/shared.mp4',
        resolvedPath: video.path,
        cancellation: secondCancel,
      );
      await sharedStarted.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(media.calls, 1);
      expect(media.lastCancellation?.cancelled, isFalse);

      final firstRejected = expectLater(
        first,
        throwsA(
          isA<MediaException>().having(
            (e) => e.reason,
            'reason',
            MediaFailure.cancelled,
          ),
        ),
      );
      await firstCancel.cancel();
      await firstRejected;
      expect(media.lastCancellation?.cancelled, isFalse);

      gate.complete();
      final thumb = await second;
      expect(await thumb.exists(), isTrue);

      // Now verify cancelling the sole waiter propagates to captureThumbnail and deletes pending file.
      final soloVideo = await writeVideo('file_workspaces/work/videos/solo.mp4');
      final started = Completer<void>();
      final soloGate = Completer<void>();
      media.onCapture = (input, output, cancellation) async {
        await output.writeAsBytes(_oneByOnePng);
        started.complete();
        cancellation?.addCancelListener(() {
          if (!soloGate.isCompleted) {
            soloGate.complete();
          }
        });
        await soloGate.future;
      };

      final soloCancel = MediaCancellation();
      final soloFuture = cache.getOrCreate(
        relativePath: 'file_workspaces/work/videos/solo.mp4',
        resolvedPath: soloVideo.path,
        cancellation: soloCancel,
      );
      await started.future;
      final soloRejected = expectLater(
        soloFuture,
        throwsA(
          isA<MediaException>().having(
            (e) => e.reason,
            'reason',
            MediaFailure.cancelled,
          ),
        ),
      );
      await soloCancel.cancel();
      await soloRejected;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(media.lastCancellation?.cancelled, isTrue);

      final dir = Directory(p.join(root.path, 'cache', 'video_thumbs'));
      final pending = dir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('.pending_'))
          .toList();
      expect(pending, isEmpty);
    },
  );

  test('invalidates cache when file size or modified timestamp changes', () async {
    final video = await writeVideo('file_workspaces/work/videos/mutable.mp4');
    final first = await cache.getOrCreate(
      relativePath: 'file_workspaces/work/videos/mutable.mp4',
      resolvedPath: video.path,
    );
    expect(media.calls, 1);

    await video.writeAsBytes(const [1, 2, 3, 4, 5, 6]);
    final second = await cache.getOrCreate(
      relativePath: 'file_workspaces/work/videos/mutable.mp4',
      resolvedPath: video.path,
    );
    expect(media.calls, 2);
    expect(second.path, isNot(first.path));

    await video.setLastModified(
      DateTime.now().add(const Duration(seconds: 5)),
    );
    final third = await cache.getOrCreate(
      relativePath: 'file_workspaces/work/videos/mutable.mp4',
      resolvedPath: video.path,
    );
    expect(media.calls, 3);
    expect(third.path, isNot(second.path));
  });

  test('evicts least recently used thumbnails over maxFiles and maxBytes', () async {
    final bounded = VideoThumbnailCache(
      media: media,
      root: root,
      maxBytes: _oneByOnePng.length * 2,
      maxFiles: 2,
    );
    final v1 = await writeVideo('file_workspaces/work/videos/1.mp4');
    final v2 = await writeVideo('file_workspaces/work/videos/2.mp4');
    final v3 = await writeVideo('file_workspaces/work/videos/3.mp4');

    final t1 = await bounded.getOrCreate(
      relativePath: 'file_workspaces/work/videos/1.mp4',
      resolvedPath: v1.path,
    );
    final t2 = await bounded.getOrCreate(
      relativePath: 'file_workspaces/work/videos/2.mp4',
      resolvedPath: v2.path,
    );
    // Explicitly order mtimes so LRU choice is deterministic even on coarse filesystems.
    final now = DateTime.now();
    await t1.setLastModified(now.subtract(const Duration(minutes: 10)));
    await t2.setLastModified(now.subtract(const Duration(minutes: 5)));

    // Cache hit on t1 should touch its mtime so t2 becomes the oldest entry.
    await bounded.getOrCreate(
      relativePath: 'file_workspaces/work/videos/1.mp4',
      resolvedPath: v1.path,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final t3 = await bounded.getOrCreate(
      relativePath: 'file_workspaces/work/videos/3.mp4',
      resolvedPath: v3.path,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(await t1.exists(), isTrue);
    expect(await t2.exists(), isFalse);
    expect(await t3.exists(), isTrue);
  });

  test('sweeps stale pending files older than one hour on startup', () async {
    final dir = Directory(p.join(root.path, 'cache', 'video_thumbs'));
    await dir.create(recursive: true);
    final stale = await File(p.join(dir.path, '.pending_stale.png')).writeAsBytes([1]);
    final freshPending = await File(
      p.join(dir.path, '.pending_fresh.png'),
    ).writeAsBytes([1]);
    await stale.setLastModified(
      DateTime.now().subtract(const Duration(hours: 2)),
    );

    final v = await writeVideo('file_workspaces/work/videos/sweep.mp4');
    await cache.getOrCreate(
      relativePath: 'file_workspaces/work/videos/sweep.mp4',
      resolvedPath: v.path,
    );

    expect(await stale.exists(), isFalse);
    expect(await freshPending.exists(), isTrue);
  });

  test('rejects missing files cleanly without calling media', () async {
    await expectLater(
      cache.getOrCreate(
        relativePath: 'file_workspaces/work/videos/missing.mp4',
        resolvedPath: p.join(root.path, 'file_workspaces/work/videos/missing.mp4'),
      ),
      throwsA(
        isA<MediaException>().having(
          (e) => e.reason,
          'reason',
          MediaFailure.invalid_media,
        ),
      ),
    );
    expect(media.calls, 0);
  });
}

class _Media extends MediaService {
  _Media() : super(_Runner());

  int calls = 0;
  MediaCancellation? lastCancellation;
  Future<void> Function(
    String input,
    File output,
    MediaCancellation? cancellation,
  )?
  onCapture;

  @override
  Future<void> captureThumbnail(
    String input,
    File output, {
    MediaCancellation? cancellation,
  }) async {
    calls++;
    lastCancellation = cancellation;
    await onCapture?.call(input, output, cancellation);
    if (cancellation?.cancelled == true) {
      throw const MediaException(MediaFailure.cancelled);
    }
    await output.writeAsBytes(_oneByOnePng);
  }
}

class _Runner extends FfmpegRunner {
  @override
  Future<String> execute(
    List<String> arguments, {
    required bool probe,
    required MediaCancellation cancellation,
  }) => throw UnimplementedError();
}

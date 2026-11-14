// 职责: 探测媒体，串行生成经规格校验的 H.264/AAC 临时视频，以及截帧、分离音轨、静音、裁剪的临时产物。
// 关联文件:
//   lib/shared/models/production/media.dart
//   lib/shared/services/production/ffmpeg_runner.dart
//   lib/shared/providers/production_media.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../logger/app_logger.dart';
import '../../models/production/media.dart';
import 'ffmpeg_runner.dart';
import 'frame_capture.dart';

final _log = AppLogger.forModule('Media');

class EncodedMedia {
  EncodedMedia(this.file, this.info, this._directory);
  final File file;
  final MediaInfo info;
  final Directory _directory;
  Future<void> dispose() => _directory.delete(recursive: true);
}

class EncodingOperation {
  EncodingOperation(this.result, this._cancellation);
  final Future<EncodedMedia> result;
  final MediaCancellation _cancellation;
  Future<void> cancel() => _cancellation.cancel();
}

class MediaService {
  MediaService(this._runner);
  final FfmpegRunner _runner;
  bool _encoding = false;

  Future<MediaInfo> probe(
    String path, {
    MediaCancellation? cancellation,
  }) async {
    final token = cancellation ?? MediaCancellation();
    try {
      final native = _runner.execute(
        ['-v', 'error', '-show_format', '-show_streams', '-of', 'json', path],
        probe: true,
        cancellation: token,
      );
      final output = await native.timeout(
        const Duration(seconds: 30),
        onTimeout: () async {
          try {
            await token.cancel();
          } catch (error, stack) {
            _log.error(
              'timed-out probe cancellation request failed',
              error: error,
              stackTrace: stack,
            );
          }
          // cancel() only requests termination. The native callback must release
          // its input before callers can clean up a temporary output file.
          // This assumes the native media session eventually completes; a
          // permanently hung session is outside this timeout's recovery scope.
          try {
            await native;
          } catch (error) {
            // The timeout remains the cause even if native termination reports
            // cancellation or an encoding error afterwards.
            if (_log.isDebugEnabled) {
              _log.debug('timed-out probe finished: $error');
            }
          }
          throw const MediaException(MediaFailure.timeout);
        },
      );
      return MediaInfo.fromProbe(jsonDecode(output) as Map<String, dynamic>);
    } on MediaException {
      rethrow;
    } catch (error, stack) {
      _log.error('probe failed', error: error, stackTrace: stack);
      throw const MediaException(MediaFailure.invalid_media);
    }
  }

  EncodingOperation encodeVideo({
    required String inputPath,
    String? audioPath,
    bool imageSequence = false,
    int width = 720,
    int height = 1280,
    int fps = 24,
    Duration? duration,
  }) {
    if (_encoding) {
      throw const MediaException(MediaFailure.busy);
    }
    if (width <= 0 ||
        height <= 0 ||
        width.isOdd ||
        height.isOdd ||
        fps <= 0 ||
        (duration != null && duration <= Duration.zero)) {
      throw ArgumentError(
        'Encoding requires positive even dimensions, frame rate and duration',
      );
    }
    _encoding = true;
    final cancellation = MediaCancellation();
    final result = _encode(
      inputPath,
      audioPath,
      imageSequence,
      width,
      height,
      fps,
      duration,
      cancellation,
    ).whenComplete(() => _encoding = false);
    return EncodingOperation(result, cancellation);
  }

  /// 截取第 0 帧缩略图到 [output]（PNG，最长边 640px）；不额外探测输出。
  Future<void> captureThumbnail(
    String input,
    File output, {
    MediaCancellation? cancellation,
  }) async {
    final token = cancellation ?? MediaCancellation();
    await captureMediaFrame(_runner, input, output, token);
  }

  /// 截一帧 PNG。[last] 截最后一帧；否则截 [at] 处，落在末尾 100ms 内时按最后一帧截。
  Future<EncodedMedia> extractFrame(
    String input, {
    Duration at = Duration.zero,
    bool last = false,
    MediaCancellation? cancellation,
  }) async {
    final token = cancellation ?? MediaCancellation();
    final source = await probe(input, cancellation: token);
    if (!source.hasVideo) {
      throw const MediaException(MediaFailure.invalid_media);
    }
    final tail =
        last || at + const Duration(milliseconds: 100) >= source.duration;
    // 末帧：从最后一秒开始解码，-update 让同一张图被逐帧覆盖，留下的就是最后一帧。
    final start = tail
        ? source.duration - const Duration(seconds: 1)
        : at < Duration.zero
        ? Duration.zero
        : at;
    return _transform(input, '.png', [
      '-ss',
      _seconds(start < Duration.zero ? Duration.zero : start),
      '-i',
      input,
      '-map',
      '0:v:0',
      if (tail) ...['-update', '1'] else ...['-frames:v', '1'],
    ], token);
  }

  /// 把音轨单独转成 AAC。
  Future<EncodedMedia> extractAudio(
    String input, {
    MediaCancellation? cancellation,
  }) async {
    final token = cancellation ?? MediaCancellation();
    if (!(await probe(input, cancellation: token)).hasAudio) {
      throw const MediaException(MediaFailure.no_audio);
    }
    return _transform(input, '.m4a', [
      '-i',
      input,
      '-map',
      '0:a:0',
      '-vn',
      '-c:a',
      'aac',
      '-b:a',
      '192k',
    ], token);
  }

  /// 去掉音轨；H.264 画面直接拷贝，其余编码转成 H.264。
  Future<EncodedMedia> mute(
    String input, {
    MediaCancellation? cancellation,
  }) async {
    final token = cancellation ?? MediaCancellation();
    final source = await probe(input, cancellation: token);
    if (!source.hasVideo) {
      throw const MediaException(MediaFailure.invalid_media);
    }
    if (!source.hasAudio) {
      throw const MediaException(MediaFailure.no_audio);
    }
    return _transform(input, '.mp4', [
      '-i',
      input,
      '-map',
      '0:v:0',
      '-an',
      if (source.videoCodec == 'h264') ...['-c:v', 'copy'] else ..._h264,
      '-movflags',
      '+faststart',
    ], token);
  }

  /// 截出 [start, end) 一段；重新编码，切点落在任意帧上。
  Future<EncodedMedia> trim(
    String input,
    Duration start,
    Duration end, {
    MediaCancellation? cancellation,
  }) async {
    final token = cancellation ?? MediaCancellation();
    final source = await probe(input, cancellation: token);
    if (!source.hasVideo ||
        start < Duration.zero ||
        end <= start ||
        end > source.duration) {
      throw const MediaException(MediaFailure.invalid_media);
    }
    return _transform(input, '.mp4', [
      '-ss',
      _seconds(start),
      '-i',
      input,
      '-t',
      _seconds(end - start),
      '-map',
      '0:v:0',
      '-map',
      '0:a:0?',
      ..._h264,
      '-c:a',
      'aac',
      '-b:a',
      '192k',
      '-movflags',
      '+faststart',
    ], token);
  }

  /// libx264 要求偶数宽高。
  static const _h264 = [
    '-vf',
    'scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p',
    '-c:v',
    'libx264',
    '-crf',
    '18',
  ];

  static String _seconds(Duration value) =>
      '${value.inMicroseconds / Duration.microsecondsPerSecond}';

  /// 把 [arguments]（含输入）的结果写进临时目录里的 `result[extension]`，探测通过后交给调用方。
  Future<EncodedMedia> _transform(
    String input,
    String extension,
    List<String> arguments,
    MediaCancellation cancellation,
  ) async {
    final temporary = await Directory.systemTemp.createTemp(
      'reveric_media_transform_',
    );
    final output = File(p.join(temporary.path, 'result$extension'));
    try {
      await _runner.execute(
        ['-y', ...arguments, output.path],
        probe: false,
        cancellation: cancellation,
      );
      if (!await output.exists() || await output.length() == 0) {
        throw const MediaException(MediaFailure.encoding_failed);
      }
      return EncodedMedia(
        output,
        await probe(output.path, cancellation: cancellation),
        temporary,
      );
    } catch (error, stack) {
      await temporary.delete(recursive: true);
      _log.error(
        'transform failed output=$extension',
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  Future<EncodedMedia> _encode(
    String input,
    String? audio,
    bool sequence,
    int width,
    int height,
    int fps,
    Duration? duration,
    MediaCancellation cancellation,
  ) async {
    final temporary = await Directory.systemTemp.createTemp(
      'reveric_media_encode_',
    );
    final output = File(p.join(temporary.path, 'result.mp4'));
    try {
      await _runner.execute(
        [
          '-y',
          if (sequence) ...['-framerate', '$fps'],
          '-i',
          input,
          if (audio != null) ...['-i', audio],
          '-map',
          '0:v:0',
          '-map',
          '${audio != null ? 1 : 0}:a:0?',
          '-vf',
          'scale=$width:$height:force_original_aspect_ratio=decrease,pad=$width:$height:(ow-iw)/2:(oh-ih)/2,format=yuv420p',
          '-r',
          '$fps',
          '-c:v',
          'libx264',
          '-b:v',
          '4000k',
          '-c:a',
          'aac',
          '-b:a',
          '128k',
          if (duration != null) ...[
            '-t',
            '${duration.inMicroseconds / Duration.microsecondsPerSecond}',
          ],
          '-movflags',
          '+faststart',
          '-f',
          'mp4',
          output.path,
        ],
        probe: false,
        cancellation: cancellation,
      );
      if (cancellation.cancelled) {
        throw const MediaException(MediaFailure.cancelled);
      }
      final info = await probe(output.path);
      if (cancellation.cancelled) {
        throw const MediaException(MediaFailure.cancelled);
      }
      if (info.videoCodec != 'h264' ||
          info.pixelFormat != 'yuv420p' ||
          info.width != width ||
          info.height != height ||
          (info.hasAudio && info.audioCodec != 'aac') ||
          (audio != null && !info.hasAudio)) {
        throw const MediaException(MediaFailure.encoding_failed);
      }
      return EncodedMedia(output, info, temporary);
    } catch (error, stack) {
      await temporary.delete(recursive: true);
      _log.error('encoding failed', error: error, stackTrace: stack);
      rethrow;
    }
  }
}

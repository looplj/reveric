// 职责: 描述媒体探测规格及可区分的媒体操作失败。
// 关联文件:
//   lib/shared/services/production/media_service.dart
//   lib/shared/services/production/ffmpeg_runner.dart

class MediaInfo {
  const MediaInfo({
    required this.duration,
    required this.hasAudio,
    required this.hasVideo,
    this.width,
    this.height,
    this.frameRate,
    this.videoCodec,
    this.audioCodec,
    this.pixelFormat,
    this.formatName,
    this.frameCount,
    this.timeBase,
  });
  final Duration duration;
  final bool hasAudio;
  final bool hasVideo;
  final int? width;
  final int? height;
  final double? frameRate;
  final String? videoCodec;
  final String? audioCodec;
  final String? pixelFormat;
  final String? formatName;
  final int? frameCount;
  final String? timeBase;

  factory MediaInfo.fromProbe(Map<String, dynamic> json) {
    final streams = (json['streams'] as List).cast<Map<String, dynamic>>();
    Map<String, dynamic>? video;
    Map<String, dynamic>? audio;
    for (final stream in streams) {
      if (stream['codec_type'] == 'video' &&
          video == null &&
          (stream['disposition'] as Map<String, dynamic>?)?['attached_pic'] !=
              1) {
        video = stream;
      }
      if (stream['codec_type'] == 'audio' && audio == null) {
        audio = stream;
      }
    }
    if (video == null && audio == null) {
      throw const MediaException(MediaFailure.invalid_media);
    }
    final format = json['format'] as Map<String, dynamic>?;
    final seconds =
        double.tryParse(
          '${format?['duration'] ?? video?['duration'] ?? audio?['duration']}',
        ) ??
        0;
    final rate = '${video?['avg_frame_rate'] ?? ''}'.split('/');
    final numerator = double.tryParse(rate.first);
    final denominator = rate.length == 2 ? double.tryParse(rate.last) : 1.0;
    return MediaInfo(
      duration: Duration(
        microseconds: (seconds * Duration.microsecondsPerSecond).round(),
      ),
      hasAudio: audio != null,
      hasVideo: video != null,
      width: video?['width'] as int?,
      height: video?['height'] as int?,
      frameRate: numerator != null && denominator != null && denominator != 0
          ? numerator / denominator
          : null,
      videoCodec: video?['codec_name'] as String?,
      audioCodec: audio?['codec_name'] as String?,
      pixelFormat: video?['pix_fmt'] as String?,
      formatName: format?['format_name'] as String?,
      frameCount: int.tryParse('${video?['nb_frames']}'),
      timeBase: video?['time_base'] as String?,
    );
  }
}

enum MediaFailure {
  invalid_media,
  encoding_failed,
  cancelled,
  busy,
  timeout,

  /// 当前平台缺少执行该操作所需的原生媒体工具。
  tool_unavailable,

  /// 要处理音轨，但媒体没有音轨。
  no_audio,
}

class MediaException implements Exception {
  const MediaException(
    this.reason, {
    this.nativeSessionId,
    this.nativeExitCode,
    this.message,
    this.nativeLog,
  });
  final MediaFailure reason;
  final int? nativeSessionId, nativeExitCode;
  final String? message, nativeLog;
  @override
  String toString() =>
      'MediaException(${reason.name}'
      '${nativeSessionId == null ? '' : ', session=$nativeSessionId'}'
      '${nativeExitCode == null ? '' : ', exitCode=$nativeExitCode'})'
      '${message == null ? '' : ': $message'}';
}

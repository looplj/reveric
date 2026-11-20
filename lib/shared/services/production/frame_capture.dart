// 职责: 从本地媒体按指定时间截取有尺寸与执行时限的检查帧。
// 关联文件:
//   lib/shared/services/production/ffmpeg_runner.dart
//   lib/shared/services/editing/render_service.dart
//   lib/shared/services/ai/ffmpeg/command.dart
import 'dart:io';
import 'dart:typed_data';
import '../../models/production/media.dart';
import 'ffmpeg_runner.dart';

Future<Uint8List> captureMediaFrame(
  FfmpegRunner runner,
  String input,
  File output,
  MediaCancellation cancellation, {
  int timestampUs = 0,
  int? detailMaxSide,
}) async {
  final execution = runner.execute(
    [
      '-nostdin',
      '-ss',
      '${timestampUs / 1000000}',
      '-protocol_whitelist',
      'file',
      '-format_whitelist',
      'mov,mp4,m4a,3gp,3g2,mj2,matroska,webm,avi',
      '-i',
      input,
      '-map',
      '0:V:0',
      '-an',
      '-sn',
      '-dn',
      '-frames:v',
      '1',
      '-vf',
      detailMaxSide == null
          ? 'scale=640:640:force_original_aspect_ratio=decrease,setsar=1'
          : "scale='min($detailMaxSide,iw)':'min($detailMaxSide,ih)':force_original_aspect_ratio=decrease,setsar=1",
      output.path,
    ],
    probe: false,
    cancellation: cancellation,
  );
  await execution.timeout(
    const Duration(seconds: 30),
    onTimeout: () async {
      await cancellation.cancel();
      try {
        await execution;
      } on Object {
        // Native execution has settled; report the timeout below.
      }
      throw const MediaException(MediaFailure.timeout);
    },
  );
  if (cancellation.cancelled) {
    throw const MediaException(MediaFailure.cancelled);
  }
  if (!await output.exists() || await output.length() == 0) {
    throw const FormatException(
      'No video frame exists at the requested position.',
    );
  }
  return output.readAsBytes();
}

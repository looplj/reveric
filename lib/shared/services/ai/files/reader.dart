// 职责: 读取会话文件副本并返回限额文本、图片引用或音视频元数据。
// 关联文件:
//   lib/shared/services/ai/files/session_files.dart
//   lib/shared/services/ai/files/attachments.dart
//   lib/shared/services/production/ffmpeg_runner.dart
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import '../../../models/tool_permission.dart';
import '../../production/ffmpeg_runner.dart';
import '../chat_attachments.dart'
    show chatImageJpegQuality, chatImageMaxDimension;
import 'attachments.dart';
import 'text_reader.dart';
export 'text_reader.dart' show decodeText, readTextPage;
import 'session_files.dart';

class FileReader {
  FileReader(this.files, this.runner);
  final SessionFiles files;
  final FfmpegRunner runner;

  Future<Map<String, dynamic>> read(
    String sessionId,
    Map<String, dynamic> options,
    MediaCancellation cancellation,
  ) async {
    final path = options['path'];
    if (path is! String || path.isEmpty) {
      throw const FormatException('path is required');
    }
    const accepted = {'path', 'mode', 'offset', 'limit', 'continuation'};
    if (options.keys.any((key) => !accepted.contains(key))) {
      throw const FormatException('Unsupported file reader option');
    }
    final source = await files.resolve(path);
    final ext = p.extension(source.path).toLowerCase();
    final kind = switch (ext) {
      '.png' || '.jpg' || '.jpeg' || '.webp' || '.gif' || '.bmp' => 'image',
      '.mp4' || '.mov' || '.mkv' || '.webm' || '.avi' => 'video',
      '.mp3' || '.wav' || '.m4a' || '.ogg' || '.flac' || '.aac' => 'audio',
      _ => 'text',
    };
    final mode = options['mode'] ?? 'auto';
    if (mode != 'auto' && mode != kind) {
      throw const FormatException(
        'Requested content type does not match the file type',
      );
    }
    final originalStat = await source.stat();
    final size = originalStat.size;
    if (kind == 'image' && size > 32 * 1024 * 1024) {
      throw const ToolOperationException(
        'resource_exhausted',
        'Read a smaller image (maximum 32 MiB).',
      );
    }
    if (cancellation.cancelled) {
      throw const ToolOperationException(
        'cancelled',
        'File reading was cancelled.',
      );
    }
    final copy = await files.copy(
      sessionId,
      source,
      cancelled: () => cancellation.cancelled,
    );
    final afterCopy = await source.stat();
    if (afterCopy.size != originalStat.size ||
        afterCopy.modified != originalStat.modified) {
      throw const ToolOperationException(
        'conflict',
        'The file changed while being copied. Try again.',
      );
    }
    final reference = files.reference(copy);
    final result = <String, dynamic>{
      'ok': true,
      'content_format': 'session_files_v1',
      'file_path': reference,
      'kind': kind,
      'bytes': size,
    };
    if (kind == 'text') {
      final page = await readTextPage(
        copy,
        options,
        cancellation: cancellation,
      );
      result.addAll(page);
      result['mime_type'] = 'text/plain';
      result['content'] = [
        {
          'type': 'text',
          'text': jsonEncode({...result}..remove('content_format')),
        },
      ];
    } else if (kind == 'image') {
      final bytes = await copy.readAsBytes();
      final output = await Isolate.run(() => prepareImage(bytes));
      if (cancellation.cancelled) {
        throw const ToolOperationException(
          'cancelled',
          'File reading was cancelled.',
        );
      }
      final image = await files.allocate(sessionId, '.jpg');
      await image.writeAsBytes(output, flush: true);
      result['file_path'] = files.reference(image);
      result['mime_type'] = 'image/jpeg';
      result['content'] = [
        {
          'type': 'text',
          'text': jsonEncode({...result}..remove('content_format')),
        },
        {
          'type': 'image',
          'file_path': files.reference(image),
          'mime_type': 'image/jpeg',
        },
      ];
    } else {
      final output = await runner.execute(
        [
          '-v',
          'error',
          '-protocol_whitelist',
          'file',
          '-format_whitelist',
          'mov,mp4,m4a,3gp,3g2,mj2,matroska,webm,avi,mp3,wav,flac,ogg,aac',
          '-show_format',
          '-show_streams',
          '-of',
          'json',
          copy.path,
        ],
        probe: true,
        cancellation: cancellation,
      );
      final info = jsonDecode(output) as Map<String, dynamic>;
      (info['format'] as Map<String, dynamic>?)?.remove('filename');
      final streams = (info['streams'] as List).whereType<Map>();
      if (!streams.any((s) => s['codec_type'] == kind)) {
        throw const FormatException(
          'File does not contain the requested media type',
        );
      }
      result['mime_type'] = switch (ext) {
        '.mp3' => 'audio/mpeg',
        '.m4a' => 'audio/mp4',
        '.mov' => 'video/quicktime',
        '.mkv' => 'video/x-matroska',
        _ => '$kind/${ext.substring(1)}',
      };
      result['specifications'] = info;
      result['content'] = [
        {
          'type': 'text',
          'text': jsonEncode({...result}..remove('content_format')),
        },
      ];
    }
    if (cancellation.cancelled) {
      throw const ToolOperationException(
        'cancelled',
        'File reading was cancelled.',
      );
    }
    return result;
  }
}

/// 与聊天发图同一套处理：转正方向、长边封顶、透明铺白底，再固定质量编码 JPEG。
/// 写实图存 PNG 动辄超过 3 MiB。
Uint8List prepareImage(Uint8List bytes) {
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null) {
    throw const FormatException('Unsupported image');
  }
  if (info.width * info.height > 64000000) {
    throw const ToolOperationException(
      'resource_exhausted',
      'Image exceeds 64 million pixels.',
    );
  }
  final decoded = decoder!.decodeFrame(0);
  if (decoded == null) {
    throw const FormatException('Unreadable image');
  }
  var image = img.bakeOrientation(decoded);
  if (image.width > chatImageMaxDimension ||
      image.height > chatImageMaxDimension) {
    final landscape = image.width >= image.height;
    image = img.copyResize(
      image,
      width: landscape ? chatImageMaxDimension : null,
      height: landscape ? null : chatImageMaxDimension,
    );
  }
  if (image.hasAlpha) {
    final background = img.Image(width: image.width, height: image.height)
      ..clear(img.ColorRgb8(255, 255, 255));
    image = img.compositeImage(background, image);
  }
  final output = img.encodeJpg(image, quality: chatImageJpegQuality);
  if (output.length > maxAttachmentBytes) {
    throw const ToolOperationException(
      'resource_exhausted',
      'Encoded image exceeds 3 MiB; reduce its size.',
    );
  }
  return output;
}

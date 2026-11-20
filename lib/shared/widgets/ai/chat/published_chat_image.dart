// 职责: 对公开对话归档的本地图片限制读取字节和解码尺寸。
// 关联文件:
//   lib/shared/widgets/ai/chat/attachment_body.dart
//   lib/shared/widgets/ai/tools/character_image_tool_card.dart

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../../logger/app_logger.dart';

final _log = AppLogger.forModule('PublishedChatImage');

@immutable
class PublishedChatImage extends ImageProvider<PublishedChatImage> {
  const PublishedChatImage(this.path, {this.previewSide = 1280});

  final String path;
  final int previewSide;

  static const _encodedBytesLimit = 32 * 1024 * 1024;
  static const _originalSideLimit = 4096;

  @override
  Future<PublishedChatImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    PublishedChatImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(key._load());

  Future<ImageInfo> _load() async {
    try {
      final bytes = await _readBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          final width = descriptor.width;
          final height = descriptor.height;
          if (width < 1 ||
              height < 1 ||
              width > _originalSideLimit ||
              height > _originalSideLimit) {
            throw const FormatException(
              'Published image exceeds the dimension limit',
            );
          }
          final scale = math.min(1.0, previewSide / math.max(width, height));
          final codec = await descriptor.instantiateCodec(
            targetWidth: math.max(1, (width * scale).round()),
            targetHeight: math.max(1, (height * scale).round()),
          );
          try {
            final image = (await codec.getNextFrame()).image;
            if (image.width > previewSide || image.height > previewSide) {
              image.dispose();
              throw const FormatException(
                'Published image exceeds the output limit',
              );
            }
            return ImageInfo(image: image);
          } finally {
            codec.dispose();
          }
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
    } catch (error) {
      _log.warning('Published image preview failed type=${error.runtimeType}');
      rethrow;
    }
  }

  Future<Uint8List> _readBytes() async {
    final file = await File(path).open();
    try {
      final size = await file.length();
      if (size < 1 || size > _encodedBytesLimit) {
        throw const FormatException('Published image exceeds the byte limit');
      }
      final bytes = await file.read(size);
      if (bytes.length != size) {
        throw const FormatException('Published image changed during the read');
      }
      return bytes;
    } finally {
      await file.close();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PublishedChatImage &&
      other.path == path &&
      other.previewSide == previewSide;

  @override
  int get hashCode => Object.hash(path, previewSide);
}

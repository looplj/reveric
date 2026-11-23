// 职责: 读取静态图片的尺寸，供媒体导入和生图参考素材校验使用。
// 关联文件:
//   lib/shared/services/production/import_orchestrator.dart
//   lib/shared/services/ai/video/reference_storage_service.dart

import 'dart:io';

import 'package:image/image.dart' as img;

import '../../logger/app_logger.dart';

final _log = AppLogger.forModule('ImageDimensions');

/// 图片尺寸探测允许读入内存的最大字节数，避免误选超大文件导致 OOM。
const defaultMaxImageDimensionsBytes = 128 * 1024 * 1024;

/// 读取尺寸元数据。导入时可用 [expectedExtension] 校验文件名与格式是否匹配。
Future<(int, int)?> readImageDimensions(
  File file, {
  String? expectedExtension,
  int maxBytes = defaultMaxImageDimensionsBytes,
}) async {
  try {
    final length = await file.length();
    if (length <= 0) {
      return null;
    }
    if (length > maxBytes) {
      _log.warning(
        'image exceeds maxBytes length=$length limit=$maxBytes '
        'extension=$expectedExtension',
      );
      return null;
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > maxBytes) {
      return null;
    }
    final decoder = expectedExtension == null
        ? img.findDecoderForData(bytes)
        : img.findDecoderForNamedImage(expectedExtension);
    if (decoder == null ||
        (expectedExtension != null && !decoder.isValidFile(bytes))) {
      return null;
    }
    final info = decoder.startDecode(bytes);
    if (info == null || info.width <= 0 || info.height <= 0) {
      return null;
    }
    return (info.width, info.height);
  } catch (error, stack) {
    // 截断的图片或文件不可读时返回 null，由调用方按无效媒体处理。
    _log.error(
      'image header unreadable extension=$expectedExtension',
      error: error,
      stackTrace: stack,
    );
    return null;
  }
}

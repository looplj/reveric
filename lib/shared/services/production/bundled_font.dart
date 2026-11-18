// 职责: 把应用内置的中文字体解出为本机文件，供 FFmpeg drawtext 按路径读取。
// 关联文件:
//   lib/shared/services/editing/render_service.dart
//   lib/shared/services/ai/ffmpeg/inputs.dart
import 'dart:io';
import 'package:flutter/services.dart';

const bundledFontAsset = 'assets/fonts/LXGWWenKai-Regular.ttf';
Future<String>? _pending;

/// 字体解到系统临时目录的固定位置，多个调用方共用、不随某次渲染删除；
/// 临时目录被系统清理后，下次调用重新解出。
Future<String> bundledFontFile() async {
  final pending = _pending ??= _extract();
  try {
    final path = await pending;
    if (await File(path).exists()) {
      return path;
    }
  } catch (_) {
    if (identical(_pending, pending)) {
      _pending = null;
    }
    rethrow;
  }
  if (identical(_pending, pending)) {
    _pending = null;
  }
  return _pending ??= _extract();
}

Future<String> _extract() async {
  final data = await rootBundle.load(bundledFontAsset);
  final dir = await Directory(
    '${Directory.systemTemp.path}/reveric_fonts',
  ).create(recursive: true);
  final file = File('${dir.path}/LXGWWenKai-Regular.ttf');
  if (await file.exists() && await file.length() == data.lengthInBytes) {
    return file.path;
  }
  // 先写临时文件再改名，并发进程不会读到写了一半的字体。
  final part = File('${file.path}.$pid.part');
  await part.writeAsBytes(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    flush: true,
  );
  await part.rename(file.path);
  return file.path;
}

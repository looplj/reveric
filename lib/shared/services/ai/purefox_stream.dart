// 职责: 解析 PureFox 媒体网关 /v1/generate 的 NDJSON 帧，并识别终态与错误信息。
// 关联文件:
//   lib/shared/services/ai/image/purefox.dart
//   lib/shared/services/ai/video/purefox.dart
//   lib/shared/services/ai/media_diagnostics.dart
import 'dart:convert';

import '../../models/video/task_result.dart';
import '../../utils/ai_error.dart';

/// 逐行产出 NDJSON 对象；空行是心跳，直接跳过。
Stream<Map<String, dynamic>> purefoxFrames(Stream<List<int>> bytes) async* {
  var buffer = '';
  await for (final chunk in bytes.transform(utf8.decoder)) {
    buffer += chunk;
    while (true) {
      final index = buffer.indexOf('\n');
      if (index < 0) {
        break;
      }
      final line = buffer.substring(0, index).trim();
      buffer = buffer.substring(index + 1);
      final frame = _decode(line);
      if (frame != null) {
        yield frame;
      }
    }
  }
  final tail = _decode(buffer.trim());
  if (tail != null) {
    yield tail;
  }
}

Map<String, dynamic>? _decode(String line) {
  if (line.isEmpty) {
    return null;
  }
  try {
    final value = jsonDecode(line);
    return value is Map<String, dynamic> ? value : null;
  } on FormatException {
    return null;
  }
}

String? purefoxJobId(Map<String, dynamic> frame) {
  final id = frame['jobId'];
  return id is String && id.trim().isNotEmpty ? id.trim() : null;
}

bool purefoxIsTerminal(Map<String, dynamic> frame) =>
    const {'succeeded', 'failed'}.contains(frame['status']);

/// 终态帧转成视频结果；缺少产物地址或状态未知时抛 [FormatException]。
VideoTaskResult purefoxResult(Map<String, dynamic> frame, Uri endpoint) {
  final status = switch (frame['status']) {
    'queued' || 'pending' => VideoRemoteStatus.queued,
    'running' => VideoRemoteStatus.running,
    'succeeded' => VideoRemoteStatus.succeeded,
    'failed' => VideoRemoteStatus.failed,
    'cancelled' || 'canceled' => VideoRemoteStatus.cancelled,
    'expired' => VideoRemoteStatus.expired,
    _ => VideoRemoteStatus.unknown,
  };
  Uri? result;
  if (status == VideoRemoteStatus.succeeded) {
    final raw = frame['result'];
    if (raw is! String || raw.trim().isEmpty) {
      throw const FormatException('Missing result URL');
    }
    result = endpoint.resolve(raw.trim());
    if (!{'http', 'https'}.contains(result.scheme) ||
        result.host.isEmpty ||
        result.userInfo.isNotEmpty) {
      throw const FormatException('Invalid result URL');
    }
  }
  return VideoTaskResult(
    status: status,
    videoUrl: result,
    providerMessage: status == VideoRemoteStatus.failed
        ? tryReadProviderMessage(frame)
        : null,
  );
}

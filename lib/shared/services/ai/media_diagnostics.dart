// 职责: 为音视频 HTTP 诊断移除凭据并限制日志长度，保留 URL 供排查。
// 关联文件:
//   lib/shared/services/ai/audio/client.dart
//   lib/shared/services/ai/video/client.dart

String safeMediaDiagnostic(Object error, String apiKey) {
  var message = error is FormatException ? error.message : error.toString();
  if (apiKey.isNotEmpty) {
    message = message.replaceAll(apiKey, '[redacted]');
  }
  message = message.replaceAll(
    RegExp(r'data:[^,\s]+;base64,[A-Za-z0-9+/=]+'),
    '[inline media]',
  );
  final safe = message
      .replaceAll(
        RegExp(r'Bearer\s+\S+|\bsk-[\w-]+', caseSensitive: false),
        '[redacted]',
      )
      .replaceAll(RegExp(r'[\r\n\x00-\x1f]'), ' ');
  return safe.length > 1000 ? '${safe.substring(0, 1000)}…' : safe;
}

/// 脱敏后的供应商错误码和原文，供 Agent 判断失败原因；不用于界面展示。
String? providerErrorDetail(String? code, String? message, String apiKey) {
  final parts = [
    code?.trim(),
    message?.trim(),
  ].whereType<String>().where((part) => part.isNotEmpty);
  return parts.isEmpty ? null : safeMediaDiagnostic(parts.join(': '), apiKey);
}

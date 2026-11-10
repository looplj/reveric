// 职责: 申请 Purefox 参考素材上传地址、流式 PUT 并返回有期限的原始 key。
// 关联文件:
//   lib/shared/services/ai/video/reference_storage_service.dart
//   lib/shared/services/ai/video/purefox.dart
//   lib/shared/services/ai/uploads/transport.dart
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../../../models/ai_provider.dart';
import '../../../models/video/request.dart';
import '../../../models/video/task_result.dart';
import '../../../logger/app_logger.dart';
import 'transport.dart';

final _log = AppLogger.forModule('PurefoxUpload');

class PurefoxUploadOrchestrator {
  static const _types = {
    'image/png',
    'image/jpeg',
    'image/webp',
    'video/mp4',
    'video/webm',
    'video/quicktime',
    'audio/mpeg',
    'audio/wav',
    'audio/mp4',
    'audio/ogg',
  };

  static void validate(AiProvider provider, String mimeType, int size) {
    if (provider.effectiveApiKey.trim().isEmpty) {
      throw uploadError(VideoErrorCode.authentication, 'credentials');
    }
    final limit = switch (mimeType.split('/').first) {
      'image' => 20,
      'audio' => 25,
      'video' => 64,
      _ => 0,
    };
    if (!_types.contains(mimeType) || size < 1 || size > limit * 1024 * 1024) {
      throw uploadError(VideoErrorCode.invalid_request, 'file');
    }
    final endpoint = parseUploadUrl(provider.effectiveBaseUrl);
    if (endpoint.hasQuery || endpoint.hasFragment) {
      throw uploadError(VideoErrorCode.configuration_required, 'endpoint');
    }
  }

  Future<ChannelUploadResult> run({
    required AiProvider provider,
    required File file,
    required String mimeType,
    required http.Client client,
  }) async {
    final size = await file.length();
    validate(provider, mimeType, size);
    final apiKey = provider.effectiveApiKey;
    final expires = DateTime.now().toUtc().add(const Duration(minutes: 30));
    final base = Uri.parse(provider.effectiveBaseUrl);
    final request =
        http.Request(
            'POST',
            base.replace(
              path: '${base.path.replaceFirst(RegExp(r'/+$'), '')}/uploads',
            ),
          )
          ..followRedirects = false
          ..headers.addAll({
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          })
          ..body = jsonEncode({
            'kind': mimeType.split('/').first,
            'mime': mimeType,
          });
    final permit = await sendUpload(
      _log,
      client,
      request,
      'apply',
      apiKey: apiKey,
    );
    checkUploadStatus(_log, permit, 'apply', apiKey: apiKey);
    final Object? data;
    try {
      data = jsonDecode(permit.body);
    } on FormatException {
      throw uploadError(VideoErrorCode.invalid_response, 'permit');
    }
    if (data is! Map ||
        data['key'] is! String ||
        !isPurefoxUploadKey(data['key'] as String)) {
      throw uploadError(VideoErrorCode.invalid_response, 'key');
    }
    final put = FileUploadRequest(parseUploadUrl(data['url']), file, size)
      ..headers['Content-Type'] = mimeType;
    checkUploadStatus(
      _log,
      await sendUpload(_log, client, put, 'put', apiKey: apiKey),
      'put',
      apiKey: apiKey,
    );
    if (!expires.isAfter(DateTime.now().toUtc())) {
      throw uploadError(VideoErrorCode.invalid_response, 'expired');
    }
    return (url: data['key'] as String, expiresAt: expires);
  }
}

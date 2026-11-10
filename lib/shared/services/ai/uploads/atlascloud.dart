// 职责: 流式上传 AtlasCloud 参考素材，并检查无明确有效期的临时链接是否仍可复用。
// 关联文件:
//   lib/shared/services/ai/video/reference_storage_service.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/services/ai/uploads/transport.dart
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../logger/app_logger.dart';
import '../../../models/ai_provider.dart';
import '../../../models/video/task_result.dart';
import '../media_diagnostics.dart';
import 'transport.dart';

final _log = AppLogger.forModule('AtlasCloudUpload');

class AtlasCloudUploadOrchestrator {
  static final _endpoint = Uri.parse(
    'https://api.atlascloud.ai/api/v1/model/uploadMedia',
  );

  static void validate(AiProvider provider, String mimeType, int size) {
    if (provider.effectiveApiKey.trim().isEmpty) {
      throw uploadError(VideoErrorCode.authentication, 'credentials');
    }
    if (size < 1 || !['image/', 'video/', 'audio/'].any(mimeType.startsWith)) {
      throw uploadError(VideoErrorCode.invalid_request, 'file');
    }
  }

  Future<ChannelUploadResult> run({
    required AiProvider provider,
    required File file,
    required String mimeType,
    required http.Client client,
  }) async {
    validate(provider, mimeType, await file.length());
    final apiKey = provider.effectiveApiKey;
    final request = http.MultipartRequest('POST', _endpoint)
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer $apiKey';
    request.files.add(await http.MultipartFile.fromPath('file', file.path));
    final response = await sendUpload(
      _log,
      client,
      request,
      'POST',
      apiKey: apiKey,
    );
    checkUploadStatus(_log, response, 'http', apiKey: apiKey);
    final Object? data;
    try {
      data = jsonDecode(response.body);
    } on FormatException {
      throw uploadError(VideoErrorCode.invalid_response, 'receipt');
    }
    if (data is! Map) {
      throw uploadError(VideoErrorCode.invalid_response, 'receipt');
    }
    final code = data['code'];
    if (code != null && '$code' != '200') {
      _log.warning(
        'upload rejected: ${safeMediaDiagnostic(response.body, apiKey)}',
      );
      throw uploadError(VideoErrorCode.rejected, 'business:$code');
    }
    final result = data['data'];
    final url = result is Map ? result['download_url'] : null;
    parseUploadUrl(url);
    // 官方上传契约未提供到期时间；不能沿用生成产物的保留期限。
    return (url: url as String, expiresAt: null);
  }

  Future<bool> isAvailable(String url, http.Client client) async {
    final request = http.Request('HEAD', parseUploadUrl(url))
      ..followRedirects = false;
    // 素材地址可能属于对象存储域名，不能携带 AtlasCloud API Key。
    final response = await sendUpload(
      _log,
      client,
      request,
      'HEAD',
      apiKey: '',
    );
    if (response.statusCode == 404 || response.statusCode == 410) {
      return false;
    }
    checkUploadStatus(_log, response, 'http', apiKey: '');
    return true;
  }
}

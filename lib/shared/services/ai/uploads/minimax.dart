// 职责: 流式上传秘塔参考素材，校验业务回执并保留原始文件引用。
// 关联文件:
//   lib/shared/services/ai/video/reference_storage_service.dart
//   lib/shared/services/ai/video/minimax.dart
//   lib/shared/services/ai/uploads/transport.dart
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../../../models/ai_provider.dart';
import '../../../models/video/task_result.dart';
import '../../../logger/app_logger.dart';
import 'transport.dart';

final _log = AppLogger.forModule('MinimaxUpload');

class MinimaxUploadOrchestrator {
  static void validate(AiProvider provider, String mimeType, int size) {
    if (provider.effectiveApiKey.trim().isEmpty) {
      throw uploadError(VideoErrorCode.authentication, 'credentials');
    }
    if (size < 1 || !['image/', 'video/', 'audio/'].any(mimeType.startsWith)) {
      throw uploadError(VideoErrorCode.invalid_request, 'file');
    }
    final uri = Uri.tryParse(provider.effectiveBaseUrl);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw uploadError(VideoErrorCode.configuration_required, 'endpoint');
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
    final base = Uri.parse(provider.effectiveBaseUrl);
    final request =
        http.MultipartRequest(
            'POST',
            base.replace(
              path:
                  '${base.path.replaceFirst(RegExp(r'/+$'), '')}/v1/files/upload',
            ),
          )
          ..followRedirects = false
          ..headers['Authorization'] = 'Bearer $apiKey'
          ..fields['purpose'] = 'video_generation_input';
    // MultipartFile defaults to application/octet-stream and streams the file.
    request.files.add(await http.MultipartFile.fromPath('file', file.path));
    final response = await sendUpload(
      _log,
      client,
      request,
      'upload',
      apiKey: apiKey,
      timeout: const Duration(minutes: 10),
    );
    checkUploadStatus(_log, response, 'http', apiKey: apiKey);
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw uploadError(VideoErrorCode.invalid_response, 'receipt');
    }
    if (decoded is! Map<String, dynamic>) {
      throw uploadError(VideoErrorCode.invalid_response, 'receipt');
    }
    final baseResponse = decoded['base_resp'];
    if (baseResponse != null) {
      if (baseResponse is! Map) {
        throw uploadError(VideoErrorCode.invalid_response, 'base_resp');
      }
      final code = baseResponse['status_code'];
      if (code != null && code != 0) {
        _log.warning('upload rejected code=${code is int ? code : 'invalid'}');
        throw uploadError(
          VideoErrorCode.rejected,
          'business:${code is int ? code : 'invalid'}',
        );
      }
    }
    final info = decoded['file'];
    if (info is! Map) {
      throw uploadError(VideoErrorCode.invalid_response, 'file');
    }
    final id = info['file_id'];
    // Native Dart integers preserve IDs beyond JavaScript's 53-bit range.
    // Doubles are rejected because precision may already have been lost.
    if (id != null && id is! String && id is! int) {
      throw uploadError(VideoErrorCode.invalid_response, 'file_id');
    }
    final fileId = id?.toString();
    if (fileId != null && fileId.trim().isNotEmpty) {
      return (url: 'mm_file://$fileId', expiresAt: null);
    }
    final download = info['download_url'];
    parseUploadUrl(download, stage: 'download_url');
    return (url: download as String, expiresAt: null);
  }
}

// 职责: 编排 88API 上传凭证申请、流式 PUT 与一次匿名完成核对。
// 关联文件:
//   lib/shared/services/ai/video/reference_storage_service.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/services/ai/uploads/transport.dart
//   lib/shared/models/video/task_result.dart
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../../../models/ai_provider.dart';
import '../../../logger/app_logger.dart';
import '../../../models/video/task_result.dart';
import 'transport.dart';

final _log = AppLogger.forModule('Api88Upload');

class Api88UploadOrchestrator {
  static const mimeTypes = {
    'video/mp4',
    'video/webm',
    'video/quicktime',
    'audio/mpeg',
    'audio/wav',
    'audio/ogg',
    'audio/mp4',
    'audio/flac',
    'image/png',
    'image/jpeg',
    'image/webp',
    'image/gif',
  };

  static void validate(AiProvider provider, String mimeType, int size) {
    if (provider.effectiveApiKey.trim().isEmpty) {
      throw uploadError(VideoErrorCode.authentication, 'credentials');
    }
    if (!mimeTypes.contains(mimeType) || size < 1 || size > 100000000) {
      throw uploadError(VideoErrorCode.invalid_request, 'file');
    }
    _url(provider.effectiveBaseUrl);
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
    final digest = await sha256.bind(file.openRead()).first;
    final base = _url(provider.effectiveBaseUrl);
    final request =
        http.Request(
            'POST',
            base.replace(
              path:
                  '${base.path.replaceFirst(RegExp(r'/+$'), '')}/media/uploads',
            ),
          )
          ..followRedirects = false
          ..headers.addAll({
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          })
          ..body = jsonEncode({
            'size': size,
            'mime_type': mimeType,
            'sha256': base64Url.encode(digest.bytes).replaceAll('=', ''),
          });
    final permit = _json(
      await sendUpload(_log, client, request, 'apply', apiKey: apiKey),
      200,
      'apply',
      apiKey,
    );
    final readUrl = _url(permit['url']);
    final uploadUrl = _url(permit['upload_url']);
    _expiry(permit['expires_at']);
    final rawHeaders = permit['headers'];
    if (permit['method'] != 'PUT' ||
        rawHeaders is! Map ||
        rawHeaders.entries.any((e) => e.key is! String || e.value is! String)) {
      throw uploadError(VideoErrorCode.invalid_response, 'permit');
    }
    final headers = Map<String, String>.from(rawHeaders);
    final lower = {
      for (final e in headers.entries) e.key.toLowerCase(): e.value,
    };
    if (lower['content-type'] != mimeType ||
        (lower['x-media-upload-token']?.isEmpty ?? true) ||
        lower.containsKey('authorization') ||
        lower.containsKey('cookie')) {
      throw uploadError(VideoErrorCode.invalid_response, 'permit_headers');
    }
    final put = FileUploadRequest(uploadUrl, file, size)
      ..headers.addAll(headers);
    try {
      final response = await sendUpload(
        _log,
        client,
        put,
        'put',
        apiKey: apiKey,
      );
      if (response.statusCode != 409) {
        final result = _json(response, 201, 'put', apiKey);
        if (result['size'] != size || result['mime_type'] != mimeType) {
          throw uploadError(VideoErrorCode.invalid_response, 'metadata');
        }
        return (
          url: _url(result['url']).toString(),
          expiresAt: _expiry(result['expires_at']),
        );
      }
    } on FormatException {
      _log.warning('PUT receipt incomplete; confirming once');
    } on VideoException catch (error) {
      if (error.code != VideoErrorCode.unavailable) {
        rethrow;
      }
      _log.warning('PUT outcome unknown; confirming once');
    }
    return _confirm(client, readUrl, size, mimeType);
  }

  Future<ChannelUploadResult> _confirm(
    http.Client client,
    Uri url,
    int size,
    String mime,
  ) async {
    final response = await sendUpload(
      _log,
      client,
      http.Request('HEAD', url)..followRedirects = false,
      'confirm',
      apiKey: '',
    );
    if (response.statusCode != 200 ||
        int.tryParse(response.headers['content-length'] ?? '') != size ||
        response.headers['content-type']?.split(';').first.trim() != mime) {
      throw uploadError(
        VideoErrorCode.invalid_response,
        'confirm_unknown',
        response.statusCode,
      );
    }
    return (
      url: url.toString(),
      expiresAt: _expiry(
        int.tryParse(response.headers['x-media-expires-at'] ?? ''),
      ),
    );
  }

  Map<String, dynamic> _json(
    http.Response response,
    int expected,
    String stage,
    String apiKey,
  ) {
    checkUploadStatus(
      _log,
      response,
      stage,
      apiKey: apiKey,
      expected: expected,
    );
    final Object? value;
    try {
      value = jsonDecode(response.body);
    } on FormatException {
      // Do not attach the response body: it may contain signed media URLs or tokens.
      throw FormatException('Invalid upload receipt: $stage');
    }
    if (value is! Map<String, dynamic>) {
      throw uploadError(VideoErrorCode.invalid_response, stage);
    }
    return value;
  }

  /// 88API 的地址还要求不带 fragment。
  static Uri _url(Object? value) {
    final uri = parseUploadUrl(value);
    if (uri.hasFragment) {
      throw uploadError(VideoErrorCode.invalid_response, 'url');
    }
    return uri;
  }

  static DateTime _expiry(Object? value) {
    if (value is! int || value < 1 || value > 8640000000000) {
      throw uploadError(VideoErrorCode.invalid_response, 'expiry');
    }
    final date = DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
    if (!date.isAfter(DateTime.now().toUtc())) {
      throw uploadError(VideoErrorCode.invalid_response, 'expired');
    }
    return date;
  }
}

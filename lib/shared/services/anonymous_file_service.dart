// 职责: 将用户主动提交的诊断文件上传到私有诊断后端。
// 关联文件:
//   lib/shared/providers/upload_providers.dart
//   lib/shared/app_config.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../app_config.dart';
import '../logger/app_logger.dart';

final _log = AppLogger.forModule('AnonymousFile');

class UploadResult {
  const UploadResult({this.uploadId, required this.success, this.error});
  final String? uploadId;
  final bool success;
  final String? error;
}

class AnonymousFileService {
  AnonymousFileService({required this.createClient, required this.baseUrl});

  /// 每次上传创建独占客户端，完成或失败时由服务关闭。
  final FutureOr<http.Client> Function() createClient;
  final String baseUrl;
  Future<UploadResult> upload({
    required String namespace,
    required List<int> fileBytes,
    required String contentType,
  }) async {
    if (namespace != 'diagnostics' ||
        fileBytes.isEmpty ||
        fileBytes.length > 50 * 1024 * 1024) {
      throw ArgumentError('Invalid diagnostic upload');
    }
    final uri = Uri.parse('$baseUrl/v1/diagnostics');
    final client = await createClient();
    final http.Response response;
    try {
      response = await client
          .post(
            uri,
            headers: {
              'Content-Type': contentType,
              'X-App-Version': appVersion,
              'X-Platform': Platform.operatingSystem,
            },
            body: fileBytes,
          )
          .timeout(const Duration(seconds: 120));
    } catch (error, stackTrace) {
      _log.error(
        'Upload failed target=$uri',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    } finally {
      client.close();
    }
    if (response.statusCode != 201) {
      _log.warning(
        'Upload failed target=$uri status=${response.statusCode} body=${response.body}',
      );
      throw HttpException(
        'Diagnostic upload HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final id = data['upload_id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('Missing upload_id');
    }
    _log.info('Diagnostic uploaded id=$id');
    return UploadResult(uploadId: id, success: true);
  }
}

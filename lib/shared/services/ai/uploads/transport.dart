// 职责: 渠道参考素材上传共用的限时发送、状态码映射、地址校验与流式文件请求。
// 关联文件:
//   lib/shared/services/ai/uploads/api88.dart
//   lib/shared/services/ai/uploads/atlascloud.dart
//   lib/shared/services/ai/uploads/minimax.dart
//   lib/shared/services/ai/uploads/purefox.dart
//   lib/shared/models/video/task_result.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../localization/locale_keys.dart';
import '../../../logger/app_logger.dart';
import '../../../models/video/task_result.dart';
import '../media_diagnostics.dart';

typedef ChannelUploadResult = ({String url, DateTime? expiresAt});

VideoException uploadError(VideoErrorCode code, String detail, [int? status]) =>
    VideoException(
      code,
      field: 'reference_upload',
      statusCode: status,
      messageKey: LocaleKeys.productionReferenceUploadFailed,
      detail: detail,
    );

/// 发送并读完响应；连接失败或超时视为结果未知，按 `unavailable` 抛出。
Future<http.Response> sendUpload(
  ModuleLogger log,
  http.Client client,
  http.BaseRequest request,
  String stage, {
  required String apiKey,
  Duration timeout = const Duration(minutes: 2),
}) async {
  try {
    return await (() async => http.Response.fromStream(
      await client.send(request),
    ))().timeout(timeout);
  } catch (error) {
    log.warning(
      'stage=$stage ${request.method} host=${request.url.host} '
      'type=${error.runtimeType} ${safeMediaDiagnostic(error, apiKey)}',
    );
    throw uploadError(VideoErrorCode.unavailable, '${stage}_unknown');
  }
}

/// [expected] 为空时接受任意 2xx。失败时记录脱敏响应体，异常只带阶段和状态码。
void checkUploadStatus(
  ModuleLogger log,
  http.Response response,
  String stage, {
  required String apiKey,
  int? expected,
}) {
  final status = response.statusCode;
  if (expected == null ? status >= 200 && status < 300 : status == expected) {
    return;
  }
  log.warning(
    'stage=$stage host=${response.request?.url.host} status=$status '
    '${safeMediaDiagnostic(response.body, apiKey)}',
  );
  throw uploadError(
    switch (status) {
      401 || 403 => VideoErrorCode.authentication,
      429 => VideoErrorCode.rate_limited,
      _ => VideoErrorCode.rejected,
    },
    stage,
    status,
  );
}

/// 只接受不带用户信息的 http(s) 地址，否则视为渠道响应无效。
Uri parseUploadUrl(Object? value, {String stage = 'url'}) {
  final uri = value is String ? Uri.tryParse(value) : null;
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw uploadError(VideoErrorCode.invalid_response, stage);
  }
  return uri;
}

/// 以流的方式 PUT 本地文件，不把整个文件读进内存。
class FileUploadRequest extends http.BaseRequest {
  FileUploadRequest(Uri url, this.file, int size) : super('PUT', url) {
    contentLength = size;
    followRedirects = false;
  }

  final File file;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(file.openRead());
  }
}

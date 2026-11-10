// 职责: 以 PureFox 媒体网关的 /v1/generate NDJSON 协议提交、等待并查询视频任务。
// 关联文件:
//   lib/shared/services/ai/video/client.dart
//   lib/shared/services/ai/purefox_stream.dart
//   lib/shared/models/video/channels.dart
//   lib/shared/models/video/request.dart
//   lib/shared/models/video/task_result.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../localization/ai_run_failure_localization.dart';
import '../../../logger/app_logger.dart';
import '../../../models/ai_run_failure.dart';
import '../../../models/video/capabilities.dart';
import '../../../models/video/request.dart';
import '../../../models/video/task_result.dart';
import '../../../utils/ai_error.dart';
import '../media_diagnostics.dart';
import '../purefox_media.dart';
import '../purefox_stream.dart';
import 'client.dart';

final _log = AppLogger.forModule('PurefoxVideo');

/// 站点文档：https://img.purefox.org/docs
/// - POST /v1/generate 返回 NDJSON，响应头 `X-Job-Id` 与首帧同时给出 jobId，
///   且在参考素材下载之前写出，因此即使读不到响应体也能拿到任务 ID；
/// - 轮询走 `GET /v1/jobs/{jobId}`，响应字段与 NDJSON 终态帧一致；
/// - 参考素材放公网 http(s) 直链，由网关服务端代为下载。
class PurefoxVideoClient extends VideoClient {
  PurefoxVideoClient({
    required super.httpClient,
    required super.providerType,
    required super.endpoint,
    required super.apiKey,
    super.timeout = const Duration(minutes: 30),
  });

  /// 单次读流的静默上限；站点每 25 秒发一次心跳，超过这个时间没有帧说明连接已死。
  static const _frameTimeout = Duration(seconds: 90);

  @override
  String get createPath => 'generate';

  /// 单任务查询快照；提交仍是 /v1/generate。
  @override
  String queryPath(String id) => 'jobs/$id';

  @override
  Map<String, dynamic> encode(
    VideoRequest request,
    List<VideoReference> references,
  ) => {
    'model': purefoxUpstreamModel(request.modelId),
    'prompt': request.prompt,
    'quality': request.resolution,
    'ratio': request.ratio,
    'duration': request.durationSeconds,
    'refs': [for (final ref in references) ref.url],
  };

  @override
  String submissionId(Map<String, dynamic> json) {
    final id = purefoxJobId(json);
    if (id == null) {
      throw const FormatException('Missing job ID');
    }
    return id;
  }

  @override
  VideoTaskResult decodeResult(Map<String, dynamic> json) =>
      purefoxResult(json, endpoint);

  @override
  Future<VideoSubmission> submit(
    VideoRequest request,
    List<VideoReference> references, {
    bool draft = false,
    String? draftId,
  }) async {
    if (draft || draftId != null) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'draft',
      );
    }
    VideoCapabilities(providerType).validate(request, references);
    final body = encode(request, references);
    if (references.isNotEmpty) {
      body['refs'] = _referenceRefs(references);
    }
    // 响应头与首帧同时带 jobId，且先于参考素材下载写出；先用响应头兜底，
    // 避免首字节迟迟不到时把已受理的任务判成 submission_unknown。
    String? headerJobId;
    Map<String, dynamic>? frame;
    try {
      await _stream(
        body,
        (value) {
          frame = value;
          return purefoxJobId(value) != null ||
              purefoxIsTerminal(value) ||
              value['status'] != null;
        },
        onResponse: (response) {
          headerJobId = _jobIdHeader(response.headers);
        },
      );
    } catch (error) {
      // 任务已受理时响应头一定带了 jobId；此时读流失败不能再判成提交未知。
      if (headerJobId == null) {
        rethrow;
      }
      _log.warning(
        'POST ${url(createPath).origin}${url(createPath).path} '
        'stream failed after receipt task=$headerJobId '
        'type=${error.runtimeType} message=${safeMediaDiagnostic(error, apiKey)}',
      );
    }
    final id = headerJobId ?? (frame == null ? null : purefoxJobId(frame!));
    if (id == null) {
      throw const VideoException(VideoErrorCode.submission_unknown);
    }
    return VideoSubmission(
      taskId: id,
      modelId: request.modelId,
      pollingUrl: queryUrl(id, request.modelId),
    );
  }

  /// 读取单任务快照；运行中返回 running，终态直接带回产物或错误。
  @override
  Future<VideoTaskResult> query(VideoSubmission task) async {
    final expected = queryUrl(task.taskId, task.modelId);
    if (task.pollingUrl != expected) {
      throw const VideoException(VideoErrorCode.configuration_required);
    }
    final Map<String, dynamic> frame;
    try {
      frame = await _get(expected);
    } on VideoException {
      rethrow;
    } catch (error) {
      _log.warning(
        'GET ${expected.origin}${expected.path} task=${task.taskId} '
        'type=${error.runtimeType} message=${safeMediaDiagnostic(error, apiKey)}',
      );
      throw const VideoException(VideoErrorCode.invalid_response);
    }
    final result = decodeResult(frame);
    if (result.status != VideoRemoteStatus.failed) {
      return result;
    }
    final providerCode = tryReadProviderErrorCode(frame);
    final providerMessage = tryReadProviderMessage(frame);
    final failure = AiRunFailure.requestFailed(
      providerCode: providerCode,
      providerMessage: providerMessage,
    );
    return VideoTaskResult(
      status: result.status,
      videoUrl: result.videoUrl,
      messageKey: localizeAiRunFailure(
        failure,
        (key) => key,
        preferProviderMessage: false,
      ),
      providerMessage: recognizedAiRunFailureKey(failure) == null
          ? providerMessage
          : null,
      detail: providerErrorDetail(providerCode, providerMessage, apiKey),
    );
  }

  Future<Map<String, dynamic>> _get(Uri uri) async {
    final request = http.Request('GET', uri)..followRedirects = false;
    request.headers.addAll({
      'Authorization': 'Bearer $apiKey',
      'Accept': 'application/json',
    });
    final response = await httpClient.send(request).timeout(timeout);
    final text = await _readBody(response.stream);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _httpFailure(
        response.statusCode,
        text,
        _retryAfter(response.headers['retry-after']),
        uri: uri,
        submitting: false,
      );
    }
    try {
      final value = jsonDecode(text);
      if (value is Map<String, dynamic>) {
        return value;
      }
    } on FormatException {
      // 落到统一的 invalid_response。
    }
    throw const VideoException(VideoErrorCode.invalid_response);
  }

  /// 响应头 `X-Job-Id`；缺失或为空时返回 null，交给首帧判断。
  String? _jobIdHeader(Map<String, String> headers) {
    final id = headers['x-job-id']?.trim();
    return id == null || id.isEmpty ? null : id;
  }

  /// 读取 NDJSON 直到 [stop] 返回 true；网络断开按明确失败处理，避免重复扣费。
  Future<void> _stream(
    Map<String, dynamic> body,
    bool Function(Map<String, dynamic> frame) stop, {
    void Function(http.StreamedResponse response)? onResponse,
  }) async {
    final uri = url(createPath);
    VideoException? httpFailure;
    try {
      final request = http.Request('POST', uri)
        ..followRedirects = false
        ..headers.addAll({
          'Authorization': 'Bearer $apiKey',
          'Accept': 'application/x-ndjson, application/json',
          'Content-Type': 'application/json',
        })
        ..body = jsonEncode(body);
      final response = await httpClient.send(request).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final text = await _readBody(response.stream);
        httpFailure = _httpFailure(
          response.statusCode,
          text,
          _retryAfter(response.headers['retry-after']),
        );
        throw httpFailure;
      }
      onResponse?.call(response);
      final frames = StreamIterator(purefoxFrames(response.stream));
      try {
        while (await frames.moveNext().timeout(_frameTimeout)) {
          if (stop(frames.current)) {
            return;
          }
        }
      } finally {
        // 取消订阅会关闭本次 HTTP 连接，避免把已受理的流一直挂在后台。
        await frames.cancel();
      }
    } on VideoException {
      rethrow;
    } catch (error) {
      if (httpFailure != null) {
        throw httpFailure;
      }
      _log.warning(
        'POST ${uri.origin}${uri.path} '
        'type=${error.runtimeType} message=${safeMediaDiagnostic(error, apiKey)}',
      );
      if (error is Error && error is! TypeError) {
        rethrow;
      }
      throw const VideoException(VideoErrorCode.submission_unknown);
    }
  }

  /// 接受本渠道上传 key 或公网直链，保持原始字符串。
  List<String> _referenceRefs(List<VideoReference> references) {
    final refs = <String>[];
    for (final reference in references) {
      if (isPurefoxUploadKey(reference.url)) {
        refs.add(reference.url);
        continue;
      }
      final url = Uri.tryParse(reference.url);
      if (url == null ||
          !{'http', 'https'}.contains(url.scheme) ||
          url.host.isEmpty) {
        throw const VideoException(
          VideoErrorCode.invalid_request,
          field: 'reference',
        );
      }
      refs.add(reference.url);
    }
    return refs;
  }

  Future<String> _readBody(Stream<List<int>> stream) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > 64 * 1024) {
        throw const FormatException('Response too large');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 错误体优先按 JSON 解析；供应商错误信息只从 JSON 结构里取，
  /// 纯文本错误体原样保留给日志，不当作 message 使用。
  Object _jsonOrText(String body) {
    try {
      final value = jsonDecode(body);
      if (value is Map<String, dynamic> || value is String) {
        return value;
      }
    } on FormatException {
      // 非 JSON 错误体。
    }
    return const <String, dynamic>{};
  }

  VideoException _httpFailure(
    int status,
    String body,
    Duration? retryAfter, {
    Uri? uri,
    bool submitting = true,
  }) {
    final message = tryReadProviderMessage(_jsonOrText(body));
    final code = tryReadProviderErrorCode(_jsonOrText(body));
    final failure = AiRunFailure.http(
      statusCode: status,
      providerMessage: message,
      providerCode: code,
    );
    final target = uri ?? url(createPath);
    _log.warning(
      'HTTP ${target.origin}${target.path} '
      'status=$status message=${safeMediaDiagnostic(message ?? body, apiKey)}',
    );
    return VideoException(
      switch (status) {
        401 || 403 => VideoErrorCode.authentication,
        429 => VideoErrorCode.rate_limited,
        >= 500 => VideoErrorCode.unavailable,
        404 => VideoErrorCode.not_found,
        >= 400 && < 500 =>
          !submitting && message?.contains('任务不存在') == true
              ? VideoErrorCode.not_found
              : VideoErrorCode.rejected,
        _ => VideoErrorCode.invalid_response,
      },
      statusCode: status,
      retryAfter: retryAfter,
      messageKey: localizeAiRunFailure(
        failure,
        (key) => key,
        preferProviderMessage: false,
      ),
      providerMessage: recognizedAiRunFailureKey(failure) == null
          ? message
          : null,
      detail: providerErrorDetail(code, message, apiKey),
    );
  }

  Duration? _retryAfter(String? value) {
    if (value == null) {
      return null;
    }
    final seconds = int.tryParse(value);
    if (seconds != null) {
      return Duration(seconds: seconds < 0 ? 0 : seconds);
    }
    try {
      final delay = HttpDate.parse(value).difference(DateTime.now().toUtc());
      return delay.isNegative ? Duration.zero : delay;
    } on FormatException {
      return null;
    }
  }
}

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
import '../purefox_stream.dart';
import 'client.dart';

final _log = AppLogger.forModule('PurefoxVideo');

/// 站点文档：https://img.purefox.org/docs
/// - POST /v1/generate 返回 NDJSON，首帧带 jobId，末帧带终态；
/// - 断流后只带 jobId 重发即继续同一任务，不重复扣费；
/// - 参考素材先 POST /v1/uploads 拿预签名地址，PUT 后把 key 放进 refs。
class PurefoxVideoClient extends VideoClient {
  PurefoxVideoClient({
    required super.httpClient,
    required super.providerType,
    required super.endpoint,
    required super.apiKey,
    super.timeout = const Duration(minutes: 30),
  });

  static const _uploadTimeout = Duration(minutes: 5);

  /// 单次读流的静默上限；站点每 25 秒发一次心跳，超过这个时间没有帧说明连接已死。
  static const _frameTimeout = Duration(seconds: 90);

  @override
  String get createPath => 'generate';

  /// 查询与提交是同一个端点，任务 ID 只出现在请求体里。
  @override
  String queryPath(String id) => 'generate';

  @override
  Map<String, dynamic> encode(
    VideoRequest request,
    List<VideoReference> references,
  ) => {
    'model': request.modelId,
    'prompt': request.prompt,
    'quality': request.resolution,
    'ratio': request.ratio,
    'duration': request.durationSeconds,
    'refs': [for (final ref in references) ref.url.toString()],
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
      body['refs'] = await _uploadReferences(references);
    }
    Map<String, dynamic>? frame;
    await _stream(body, (value) {
      frame = value;
      return purefoxJobId(value) != null ||
          purefoxIsTerminal(value) ||
          value['status'] != null;
    });
    final receipt = frame;
    if (receipt == null) {
      throw const VideoException(VideoErrorCode.submission_unknown);
    }
    final id = purefoxJobId(receipt);
    if (id == null) {
      // 立即拿到终态（例如重连已完成的 jobId）也按成功提交处理。
      throw const VideoException(VideoErrorCode.submission_unknown);
    }
    return VideoSubmission(
      taskId: id,
      modelId: request.modelId,
      pollingUrl: queryUrl(id, request.modelId),
    );
  }

  /// 断流重连：只带 jobId 重发，直到拿到终态帧。
  @override
  Future<VideoTaskResult> query(VideoSubmission task) async {
    final expected = queryUrl(task.taskId, task.modelId);
    if (task.pollingUrl != expected) {
      throw const VideoException(VideoErrorCode.configuration_required);
    }
    Map<String, dynamic>? terminal;
    try {
      // 只读首帧：运行中返回 running，任务已完成时直接回终态帧。
      await _stream({'jobId': task.taskId}, (frame) {
        if (purefoxIsTerminal(frame)) {
          terminal = frame;
        }
        return true;
      });
    } on VideoException {
      rethrow;
    } catch (error) {
      _log.warning(
        'POST ${expected.origin}${expected.path} task=${task.taskId} '
        'type=${error.runtimeType} message=${safeMediaDiagnostic(error, apiKey)}',
      );
      throw const VideoException(VideoErrorCode.invalid_response);
    }
    final frame = terminal;
    if (frame == null) {
      return const VideoTaskResult(status: VideoRemoteStatus.running);
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

  /// 读取 NDJSON 直到 [stop] 返回 true；网络断开按明确失败处理，避免重复扣费。
  Future<void> _stream(
    Map<String, dynamic> body,
    bool Function(Map<String, dynamic> frame) stop,
  ) async {
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

  Future<List<String>> _uploadReferences(
    List<VideoReference> references,
  ) async {
    final keys = <String>[];
    for (final reference in references) {
      final bytes = await _download(reference.url);
      final key = await _upload(reference.mimeType, bytes);
      keys.add(key);
    }
    return keys;
  }

  Future<List<int>> _download(Uri url) async {
    if (!{'http', 'https'}.contains(url.scheme) || url.host.isEmpty) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'reference',
      );
    }
    final client = http.Client();
    try {
      final response = await client.get(url).timeout(_uploadTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const VideoException(
          VideoErrorCode.invalid_request,
          field: 'reference',
        );
      }
      return response.bodyBytes;
    } on VideoException {
      rethrow;
    } catch (error) {
      _log.warning(
        'GET ${url.origin}${url.path} '
        'type=${error.runtimeType} message=${safeMediaDiagnostic(error, apiKey)}',
      );
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'reference',
      );
    } finally {
      client.close();
    }
  }

  Future<String> _upload(String mimeType, List<int> bytes) async {
    final kind = switch (mimeType.split('/').first) {
      'image' => 'image',
      'video' => 'video',
      'audio' => 'audio',
      _ => null,
    };
    if (kind == null) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'mime_type',
      );
    }
    final session = await _json(
      'POST',
      url('uploads'),
      body: {'kind': kind, 'mime': mimeType},
    );
    final key = session['key'];
    final uploadUrl = session['url'];
    if (key is! String || key.trim().isEmpty || uploadUrl is! String) {
      throw const VideoException(VideoErrorCode.invalid_response);
    }
    final target = Uri.parse(uploadUrl);
    final client = http.Client();
    try {
      final response = await client
          .put(
            target,
            // 预签名地址把 Content-Type 签进了签名，必须与申请时完全一致。
            headers: {'Content-Type': mimeType},
            body: bytes,
          )
          .timeout(_uploadTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const VideoException(VideoErrorCode.invalid_response);
      }
      return key.trim();
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _json(
    String method,
    Uri uri, {
    Map<String, dynamic>? body,
  }) async {
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer $apiKey',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      });
    if (body != null) {
      request.body = jsonEncode(body);
    }
    final response = await httpClient.send(request).timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final text = await _readBody(response.stream);
      throw _httpFailure(
        response.statusCode,
        text,
        _retryAfter(response.headers['retry-after']),
      );
    }
    final text = await _readBody(response.stream);
    try {
      return jsonDecode(text) as Map<String, dynamic>;
    } on FormatException {
      throw const VideoException(VideoErrorCode.invalid_response);
    }
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

  VideoException _httpFailure(int status, String body, Duration? retryAfter) {
    final message = tryReadProviderMessage(body);
    final code = tryReadProviderErrorCode(body);
    final failure = AiRunFailure.http(
      statusCode: status,
      providerMessage: message,
      providerCode: code,
    );
    _log.warning(
      'HTTP ${url(createPath).origin}${url(createPath).path} '
      'status=$status message=${safeMediaDiagnostic(message ?? body, apiKey)}',
    );
    return VideoException(
      switch (status) {
        401 || 403 => VideoErrorCode.authentication,
        429 => VideoErrorCode.rate_limited,
        >= 500 => VideoErrorCode.unavailable,
        >= 400 && < 500 => VideoErrorCode.rejected,
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

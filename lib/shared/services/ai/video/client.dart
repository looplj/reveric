// 职责: 执行单次视频 HTTP 动作，区分明确失败与提交不确定性，并复用 Agent 错误文案匹配。
// 关联文件:
//   lib/shared/models/video/request.dart
//   lib/shared/models/video/task_result.dart
//   lib/shared/models/video/capabilities.dart
//   lib/shared/services/ai/media_diagnostics.dart
//   lib/shared/localization/ai_run_failure_localization.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart' as http;

import '../../../utils/ai_error.dart';
import '../../../localization/ai_run_failure_localization.dart';
import '../../../logger/app_logger.dart';
import '../../../models/ai_run_failure.dart';
import '../../../models/video/capabilities.dart';
import '../../../models/video/request.dart';
import '../../../models/video/task_result.dart';
import '../media_diagnostics.dart';
import '../../plugins/files.dart';
import '../../../models/generation/provider_result.dart';
export '../../../models/generation/provider_result.dart';

final _log = AppLogger.forModule('VideoClient');

abstract class VideoClient {
  VideoClient({
    required this.httpClient,
    required this.providerType,
    required this.endpoint,
    required this.apiKey,
    this.timeout = const Duration(seconds: 30),
  });
  final http.Client httpClient;

  /// 用于查找渠道登记的型号能力；同一协议可被多个 provider 类型共用。
  final String providerType;
  final Uri endpoint;
  final String apiKey;
  final Duration timeout;
  String get createPath;
  String queryPath(String id);
  Uri queryUrl(String id, String modelId) =>
      url(queryPath(Uri.encodeComponent(id)));

  /// 仅创建任务（POST）需要的额外请求头。
  /// 查询/下载接口不是异步调用入口，携带异步头会被上游判为 403
  /// access_denied（如 workspace 专属 Endpoint 的 `X-DashScope-Async`）。
  Map<String, String> get submitHeaders => const {};
  Map<String, dynamic> encode(
    VideoRequest request,
    List<VideoReference> references,
  );
  String submissionId(Map<String, dynamic> json);
  VideoTaskResult decodeResult(Map<String, dynamic> json);

  Uri url(String path) {
    if (!{'http', 'https'}.contains(endpoint.scheme) ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        apiKey.trim().isEmpty) {
      throw const VideoException(VideoErrorCode.configuration_required);
    }
    return endpoint.replace(
      path: '${endpoint.path.replaceFirst(RegExp(r'/+$'), '')}/$path',
    );
  }

  SubmitVideoInput? _preparedInput;
  PluginFileScope? _preparedScope;
  List<VideoReference>? _preparedReferences;

  Future<void> validateSubmission(
    SubmitVideoInput input,
    PluginFileScope files,
  ) async {
    final references = await nativeReferences(input, files);
    final body = encodeSubmission(
      input.request,
      references,
      draft: input.draft,
      draftId: input.draftOf?.remoteTaskId,
    );
    validateInlineBody(body, references);
  }

  Future<List<VideoReference>> nativeReferences(
    SubmitVideoInput input,
    PluginFileScope files,
  ) async {
    if (identical(input, _preparedInput) && identical(files, _preparedScope)) {
      return _preparedReferences!;
    }
    files.claim(
      pluginId: files.pluginId,
      providerId: files.providerId,
      taskId: files.taskId,
    );
    final result = <VideoReference>[];
    for (final ref in input.references) {
      final source = ref.source;
      final String url;
      switch (source['kind']) {
        case 'certified':
          url = 'asset://${source['remoteId']}';
        case 'url':
          url = source['url'] as String;
        case 'uploaded':
          url = source['ref'] as String;
        case 'file':
          final file = files.resolve(source['handle']);
          final bytes = await file.file.readAsBytes();
          if (bytes.length != ref.fileSize || file.mimeType != ref.mimeType) {
            throw const VideoException(
              VideoErrorCode.invalid_request,
              field: 'reference',
            );
          }
          url = 'data:${ref.mimeType};base64,${base64Encode(bytes)}';
        default:
          throw const VideoException(
            VideoErrorCode.invalid_request,
            field: 'reference',
          );
      }
      result.add(
        VideoReference(
          role: ref.role,
          url: url,
          mimeType: ref.mimeType,
          fileSize: ref.fileSize,
          mediaInfo: ref.mediaInfo,
        ),
      );
    }
    _preparedInput = input;
    _preparedScope = files;
    _preparedReferences = result;
    return result;
  }

  Future<ProviderSubmitResult> submit(
    SubmitVideoInput input,
    PluginFileScope files,
  ) async {
    final references = await nativeReferences(input, files);
    final receipt = await submitNative(
      input.request,
      references,
      draft: input.draft,
      draftId: input.draftOf?.remoteTaskId,
    );
    return ProviderSubmitted(
      receipt.taskId,
      state: {
        'queryUrl': receipt.pollingUrl.toString(),
        'modelId': receipt.modelId,
      },
    );
  }

  Map<String, String> outputHeaders(Uri url, VideoSubmission task) => const {};

  Future<ProviderQueryResult> query(ProviderQueryInput input) async {
    final state = input.state;
    if (state?['queryUrl'] is! String || state?['modelId'] is! String) {
      throw const VideoException(VideoErrorCode.configuration_required);
    }
    final task = VideoSubmission(
      taskId: input.remoteTaskId,
      modelId: state!['modelId'] as String,
      pollingUrl: Uri.parse(state['queryUrl'] as String),
    );
    final result = await queryNative(task);
    return switch (result.status) {
      VideoRemoteStatus.queued => ProviderPending(queued: true, state: state),
      VideoRemoteStatus.running => ProviderPending(state: state),
      VideoRemoteStatus.succeeded => ProviderSucceeded([
        ProviderUrlOutput(
          result.videoUrl!.toString(),
          headers: outputHeaders(result.videoUrl!, task),
        ),
      ]),
      VideoRemoteStatus.failed => ProviderFailed(
        ProviderFailure(
          code: 'upstream_failed',
          // 内置渠道在此译好文案；插件文案原样展示。
          message:
              result.providerMessage ??
              (result.messageKey == null
                  ? 'Video generation failed'
                  : tr(result.messageKey!)),
          detail: result.detail,
        ),
      ),
      VideoRemoteStatus.cancelled => const ProviderStopped(cancelled: true),
      VideoRemoteStatus.expired => const ProviderStopped(),
      VideoRemoteStatus.unknown => const ProviderUnknown(
        'Upstream task status is unknown',
      ),
    };
  }

  Future<VideoSubmission> submitNative(
    VideoRequest request,
    List<VideoReference> references, {
    bool draft = false,
    String? draftId,
  }) async {
    final body = await prepareSubmission(
      request,
      references,
      draft: draft,
      draftId: draftId,
    );
    validateInlineBody(body, references);
    final json = await sendRequest(
      'POST',
      url(createPath),
      submitting: true,
      body: body,
    );
    try {
      final id = submissionId(json);
      if (id.trim().isEmpty) {
        throw const FormatException('Missing task ID');
      }
      return VideoSubmission(
        taskId: id,
        modelId: request.modelId,
        pollingUrl: queryUrl(id, request.modelId),
      );
    } catch (error) {
      _log.warning(
        'POST ${endpoint.origin}${endpoint.path} '
        'type=${error.runtimeType} message=${safeMediaDiagnostic(error, apiKey)}',
      );
      if (error is Error && error is! TypeError) {
        rethrow;
      }
      // A successful HTTP response with no usable receipt may already be billed.
      throw const VideoException(VideoErrorCode.submission_unknown);
    }
  }

  /// 在参数校验后准备协议需要的内联素材；完成后才发送收费 POST。
  FutureOr<Map<String, dynamic>> prepareSubmission(
    VideoRequest request,
    List<VideoReference> references, {
    bool draft = false,
    String? draftId,
  }) => encodeSubmission(request, references, draft: draft, draftId: draftId);

  /// 校验并编码收费请求；任务层在进入提交不确定窗口前也调用此方法。
  Map<String, dynamic> encodeSubmission(
    VideoRequest request,
    List<VideoReference> references, {
    bool draft = false,
    String? draftId,
  }) {
    if (draft || draftId != null) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'draft',
      );
    }
    VideoCapabilities(providerType).validate(request, references);
    final body = encode(request, references);
    validateInlineBody(body, references);
    return body;
  }

  void validateInlineBody(
    Map<String, dynamic> body,
    List<VideoReference> references,
  ) {
    if (references.any((ref) => ref.url.startsWith('data:')) &&
        utf8.encode(jsonEncode(body)).length > videoInlineRequestMaxBytes) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'file_size',
      );
    }
  }

  /// 下载完成的视频；默认不带凭据直接 GET，需要鉴权的协议自行覆盖。
  Future<http.StreamedResponse> download(
    http.Client transport,
    Uri url,
    VideoSubmission task,
  ) => transport.send(http.Request('GET', url));

  Future<VideoTaskResult> queryNative(VideoSubmission task) async {
    // Never send a changed account's credentials to a persisted foreign origin.
    final expected = queryUrl(task.taskId, task.modelId);
    if (task.pollingUrl != expected) {
      throw const VideoException(VideoErrorCode.configuration_required);
    }
    final json = await sendRequest('GET', task.pollingUrl, submitting: false);
    try {
      final result = decodeResult(json);
      if (result.status != VideoRemoteStatus.failed) {
        return result;
      }
      _log.warning(
        'GET ${expected.origin}${expected.path} '
        'status=200 taskStatus=failed message=${safeMediaDiagnostic(jsonEncode(json), apiKey)}',
      );
      final providerCode = tryReadProviderErrorCode(json);
      final providerMessage = tryReadProviderMessage(json);
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
        // 已识别出专用文案时不再展示原文，原文仍保留在 detail 中。
        providerMessage: recognizedAiRunFailureKey(failure) == null
            ? providerMessage
            : null,
        detail: providerErrorDetail(providerCode, providerMessage, apiKey),
      );
    } catch (error) {
      _log.warning(
        'GET ${expected.origin}${expected.path} '
        'type=${error.runtimeType} message=${safeMediaDiagnostic(error, apiKey)}',
      );
      if (error is Error && error is! TypeError) {
        rethrow;
      }
      throw const VideoException(VideoErrorCode.invalid_response);
    }
  }

  Future<Map<String, dynamic>> sendRequest(
    String method,
    Uri uri, {
    required bool submitting,
    Map<String, dynamic>? body,
  }) async {
    VideoException? httpFailure;
    try {
      return await (() async {
        final request = http.Request(method, uri)
          ..followRedirects = false
          ..headers.addAll({
            'Authorization': 'Bearer $apiKey',
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          });
        // 异步头只在创建任务时发送；查询接口携带会被上游判为 403。
        if (submitting) {
          request.headers.addAll(submitHeaders);
        }
        if (body != null) {
          request.body = jsonEncode(body);
        }
        final response = await httpClient.send(request);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final status = response.statusCode;
          final retryAfter = _retryAfter(response.headers['retry-after']);
          // Preserve the received status even if reading the error body fails.
          httpFailure = _httpFailure(status, submitting, retryAfter);
          final bytes = <int>[];
          await for (final chunk in response.stream) {
            if (bytes.length + chunk.length > 64 * 1024) {
              throw const FormatException('Error response too large');
            }
            bytes.addAll(chunk);
          }
          // Adapt the HTTP body to the same message envelope used by SDK errors.
          final diagnosticBody = utf8.decode(bytes, allowMalformed: true);
          final message = tryReadProviderMessage((message: diagnosticBody));
          httpFailure = _httpFailure(
            status,
            submitting,
            retryAfter,
            message,
            tryReadProviderErrorCode((message: diagnosticBody)),
          );
          _log.warning(
            '$method ${uri.origin}${uri.path} '
            'status=$status type=VideoException '
            'message=${safeMediaDiagnostic(message ?? diagnosticBody, apiKey)}',
          );
          throw httpFailure!;
        }
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > 1024 * 1024) {
            throw const FormatException('Response too large');
          }
          bytes.addAll(chunk);
        }
        return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      })().timeout(timeout);
    } on VideoException {
      rethrow;
    } catch (error) {
      if (httpFailure != null) {
        _log.warning(
          '$method ${uri.origin}${uri.path} '
          'status=${httpFailure!.statusCode} bodyReadError=${error.runtimeType}',
        );
        throw httpFailure!;
      }
      _log.warning(
        '$method ${uri.origin}${uri.path} '
        'type=${error.runtimeType} message=${safeMediaDiagnostic(error, apiKey)}',
      );
      if (error is Error && error is! TypeError) {
        rethrow;
      }
      // No automatic POST retry: transport errors cannot prove non-acceptance.
      throw VideoException(
        submitting
            ? VideoErrorCode.submission_unknown
            : error is FormatException || error is TypeError
            ? VideoErrorCode.invalid_response
            : VideoErrorCode.unavailable,
      );
    }
  }

  VideoException _httpFailure(
    int status,
    bool submitting,
    Duration? retryAfter, [
    String? message,
    String? providerCode,
  ]) {
    final failure = AiRunFailure.http(
      statusCode: status,
      providerMessage: message,
      providerCode: providerCode,
    );
    return VideoException(
      switch (status) {
        401 || 403 => VideoErrorCode.authentication,
        429 => VideoErrorCode.rate_limited,
        404 when !submitting => VideoErrorCode.not_found,
        >= 500 => VideoErrorCode.unavailable,
        >= 400 && < 500 => VideoErrorCode.rejected,
        _ =>
          submitting
              ? VideoErrorCode.submission_unknown
              : VideoErrorCode.invalid_response,
      },
      statusCode: status,
      retryAfter: retryAfter,
      messageKey: localizeAiRunFailure(
        failure,
        (key) => key,
        preferProviderMessage: false,
      ),
      // 已识别出专用文案时不再展示原文，原文仍保留在 detail 中。
      providerMessage: recognizedAiRunFailureKey(failure) == null
          ? message
          : null,
      detail: providerErrorDetail(providerCode, message, apiKey),
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

VideoTaskResult videoResult(String status, Object? url, {bool wan = false}) {
  final parsed = switch (wan ? status.toLowerCase() : status) {
    'queued' || 'pending' => VideoRemoteStatus.queued,
    'running' => VideoRemoteStatus.running,
    'succeeded' => VideoRemoteStatus.succeeded,
    'failed' => VideoRemoteStatus.failed,
    'cancelled' || 'canceled' => VideoRemoteStatus.cancelled,
    'expired' => VideoRemoteStatus.expired,
    _ => VideoRemoteStatus.unknown,
  };
  Uri? result;
  if (parsed == VideoRemoteStatus.succeeded) {
    result = Uri.parse(url as String);
    if (!{'http', 'https'}.contains(result.scheme) ||
        result.host.isEmpty ||
        result.userInfo.isNotEmpty) {
      throw const FormatException('Missing video URL');
    }
  }
  return VideoTaskResult(status: parsed, videoUrl: result);
}

List<Map<String, dynamic>> videoContent(
  VideoRequest request,
  List<VideoReference> references,
) => [
  {'type': 'text', 'text': request.prompt},
  for (final ref in references)
    {
      'type': '${ref.role.kind.name}_url',
      '${ref.role.kind.name}_url': {'url': ref.url},
      'role': ref.role.name,
    },
];

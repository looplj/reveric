// 职责: 定义按协议实现的图片生成客户端基类，提供共用的 HTTP、回执解析、参考图归一化与错误分类。
// 关联文件:
//   lib/shared/services/ai/image.dart
//   lib/shared/models/image/channels.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/services/ai/image_reference_compression.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart' show compute, protected;
import 'package:http/http.dart' as http;

import '../../../localization/locale_keys.dart';
import '../../../localization/ai_run_failure_localization.dart';
import '../../../localization/ark_error_localization.dart';
import '../../../models/ai_run_failure.dart';
import '../../../utils/ai_error.dart';
import '../../../logger/app_logger.dart';
import '../../../models/ai_provider.dart';
import '../../../models/network_proxy.dart';
import '../../proxy_client.dart';
import '../../../models/image/channels.dart';
import '../image.dart';
import 'output.dart';
import '../../../models/image/request.dart';
export '../../../models/image/request.dart';
import '../../../models/generation/provider_result.dart';
export '../../../models/generation/provider_result.dart';
export 'output.dart' show ImageOutputContext;
import '../image_reference_compression.dart';

final _log = AppLogger.forModule('Image');

void writeImageLog(String message) => _log.info(message);

const imageHttpConnectTimeout = Duration(seconds: 30);
const imageHttpDataTimeout = Duration(minutes: 5);

/// 单个图片协议的请求编码与回执解析。渠道未登记的型号不做能力校验，
/// 原样提交；是否允许使用由业务层决定。
abstract class ImageClient {
  ImageClient(this.config);
  final AiProvider config;
  final _httpClients = <http.Client>{};
  final _dioClients = <Dio>{};
  bool _cancelled = false;
  void cancel() {
    _cancelled = true;
    for (final client in _httpClients) {
      client.close();
    }
    for (final client in _dioClients) {
      client.close(force: true);
    }
    _httpClients.clear();
    _dioClients.clear();
  }

  @protected
  http.Client newImageHttpClient() {
    if (_cancelled) {
      throw const ProviderFailure(
        code: 'cancelled',
        message: 'Image call cancelled',
      );
    }
    final client = config.createProxyClient() ?? http.Client();
    _httpClients.add(client);
    return client;
  }

  /// 不支持参考图编辑的协议返回 false。
  bool get supportsEdit => true;

  Future<ProviderSubmitResult> submit(
    SubmitImageInput request,
    ImageOutputContext outputs,
  );
  Future<ProviderQueryResult> query(
    ProviderQueryInput input,
    ImageOutputContext outputs,
  ) => throw const ProviderFailure(
    code: 'configuration_required',
    message: 'Image protocol does not support querying',
  );

  @protected
  ImageChannelModel? channelFor(String model) =>
      lookupImageChannelModel(config.type, model);

  /// 校验渠道登记的参考图数量和尺寸；未登记型号直接放行。
  @protected
  ImageChannelModel? validatedChannel(SubmitImageInput request) {
    final channel = channelFor(request.model);
    if (channel == null) {
      return null;
    }
    try {
      channel.capabilities.validateReferences(request.references.length);
    } on FormatException {
      throw invalidImageParameter();
    }
    try {
      channel.capabilities.validateSize(
        request.size ?? request.nativeDefaults.size,
        references: request.references.length,
      );
    } on FormatException {
      throw AiImageGenerationException(
        imageErrorMessage(AiImageErrorCode.size),
        code: AiImageErrorCode.size,
      );
    }
    return channel;
  }

  @protected
  String requireApiKey() {
    final apiKey = config.effectiveApiKey;
    if (apiKey.trim().isEmpty) {
      throw AiImageGenerationException(
        imageErrorMessage(AiImageErrorCode.auth),
        code: AiImageErrorCode.auth,
      );
    }
    return apiKey;
  }

  @protected
  Dio newImageDio() {
    if (_cancelled) {
      throw const ProviderFailure(
        code: 'cancelled',
        message: 'Image call cancelled',
      );
    }
    final client = createProxyDioClient(
      NetworkProxy(
        mode: config.hasProxy
            ? NetworkProxyMode.custom
            : NetworkProxyMode.environment,
        url: config.proxyUrl.trim(),
        username: config.proxyUsername.trim(),
        password: config.proxyPassword.trim(),
      ),
      options: BaseOptions(
        connectTimeout: imageHttpConnectTimeout,
        sendTimeout: imageHttpDataTimeout,
        receiveTimeout: imageHttpDataTimeout,
      ),
    );
    _dioClients.add(client);
    return client;
  }

  @protected
  Future<Map<String, dynamic>> postImageJson(
    Uri uri,
    Map<String, dynamic> body, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final apiKey = requireApiKey();
    final client = newImageHttpClient();
    try {
      writeImageLog(
        '[IMGDBG] http_request_start method=POST uri=${safeImageUriForLog(uri)} '
        'provider=${config.id} model=${body['model']}',
      );
      final response = await client
          .post(
            uri,
            headers: {
              ...?headers,
              if (headers == null) 'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout ?? imageHttpDataTimeout);
      writeImageLog(
        '[IMGDBG] http_response status=${response.statusCode} uri=${safeImageUriForLog(uri)}',
      );
      throwForImageHttpFailure(
        uri: uri,
        statusCode: response.statusCode,
        data: response.body,
        providerId: config.id,
      );
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['error'] != null || data['code'] != null) {
        throw AiImageGenerationException(
          _providerImageMessage(data, config.id) ??
              imageUserMessageFromServerMessage(
                extractImageServerMessage(data),
              ) ??
              tr(LocaleKeys.aiImageGenerationFailed),
          debugMessage:
              'Image API error at ${safeImageUriForLog(uri)} response=${safeImageSerializeForLog(data)}',
          code: classifyAiImageError(extractImageServerMessage(data)),
        );
      }
      return data;
    } finally {
      client.close();
    }
  }

  @protected
  Future<ProviderSucceeded> parseImageResponse(
    Map<String, dynamic> data,
    ImageOutputContext outputs, {
    required String emptyMessage,
  }) async {
    try {
      final images = data['data'] as List?;
      if (images == null || images.isEmpty) {
        throw invalidImageOutputs('Image result contains no images');
      }

      final firstImage = images.first as Map<String, dynamic>;
      if (firstImage['error'] != null) {
        final message = extractImageServerMessage(firstImage);
        throw AiImageGenerationException(
          _providerImageMessage(firstImage, config.id) ??
              imageUserMessageFromServerMessage(message) ??
              emptyMessage,
          debugMessage:
              'Image result error: ${safeImageSerializeForLog(firstImage['error'])}',
          code: classifyAiImageError(message),
        );
      }
      return await outputs.nativeImages([firstImage]);
    } on AiImageGenerationException {
      rethrow;
    } catch (error) {
      throw invalidImageOutputs(error);
    }
  }

  /// 原始文件字节仅由调用 scope 提供；URL/token 不会被误判为本地路径或 base64。
  @protected
  Future<String> imageInputAsDataUri(
    PreparedImageReference reference,
    ImageOutputContext context,
  ) async {
    final source = reference.source;
    if (source is! ImageFileReference) {
      throw const ProviderFailure(
        code: 'invalid_request',
        message: 'This protocol requires a file reference',
      );
    }
    final file = context.inputScope.resolve(source.handle);
    final data = await file.file.readAsBytes();
    return 'data:${reference.mimeType};base64,${base64Encode(data)}';
  }

  @protected
  Future<String> imageInputAsUrlOrDataUri(
    PreparedImageReference reference,
    ImageOutputContext context,
  ) async => switch (reference.source) {
    ImageFileReference() => imageInputAsDataUri(reference, context),
    ImageUrlReference(:final url) => url,
    ImageUploadedReference(:final ref) => ref,
  };

  /// 参考图按需压缩。解码/缩放/编码是 CPU 密集的同步活（实测 24MP 图 decode 就要
  /// 2s 量级），放在调用方 isolate 会直接卡住界面，所以整段丢进 [compute]。
  @protected
  Future<({Uint8List bytes, String extension})> prepareMultipartReference(
    List<int> sourceBytes,
    String sourceExtension,
  ) async {
    final result = await compute(
      compressImageReference,
      ImageReferenceCompressionRequest(
        bytes: Uint8List.fromList(sourceBytes),
        extension: sourceExtension,
      ),
    );
    writeImageLog('[IMGDBG] ${result.logLine}');
    if (result.decodeFailed) {
      throw const AiImageGenerationException(
        '参考图文件无法读取，可能已损坏或不是支持的图片格式，请换一张图片。',
      );
    }
    return (bytes: result.bytes, extension: result.extension);
  }

  @protected
  void logImageHttpResponse(
    Uri uri,
    int? statusCode,
    Headers headers,
    dynamic data,
  ) {
    final code = statusCode ?? -1;
    writeImageLog(
      '[IMGDBG] http_response status=$code uri=${safeImageUriForLog(uri)} '
      'headers=${_responseHeadersSummary(headers)} '
      'data=${_imageResponseSummary(data)}',
    );
    // Only log response body on error to reduce noise.
    if (code < 200 || code >= 300) {
      if (data != null) {
        writeImageLog(
          '[AiImageGeneration] response=${safeImageSerializeForLog(data)}',
        );
      }
    }
  }

  @protected
  void Function(int, int) receiveProgressLogger(Uri uri, String phase) {
    var lastLoggedBytes = -1;
    return (received, total) {
      final isFirst = lastLoggedBytes < 0;
      final isComplete = total >= 0 && received >= total;
      final crossedChunk = received - lastLoggedBytes >= 64 * 1024;
      if (!isFirst && !isComplete && !crossedChunk) {
        return;
      }
      lastLoggedBytes = received;
      writeImageLog(
        '[IMGDBG] receive_progress phase=$phase '
        'uri=${safeImageUriForLog(uri)} received=$received total=$total',
      );
    };
  }

  String _responseHeadersSummary(Headers headers) {
    const names = <String>[
      'content-length',
      'transfer-encoding',
      'content-encoding',
      'content-type',
      'connection',
    ];
    return names.map((name) => '$name=${headers.value(name) ?? '-'}').join(',');
  }

  String _imageResponseSummary(dynamic data) {
    if (data is List<int>) {
      return 'type=bytes bytes=${data.length}';
    }
    if (data is! Map) {
      return 'type=${data.runtimeType}';
    }

    final rawItems = data['data'];
    if (rawItems is! List) {
      return 'type=map keys=${data.keys.join(',')} data_items=0';
    }

    final first = rawItems.isNotEmpty && rawItems.first is Map
        ? rawItems.first as Map
        : null;
    final url = first?['url'];
    final b64 = first?['b64_json'];
    return 'type=map keys=${data.keys.join(',')} '
        'data_items=${rawItems.length} '
        'first_keys=${first?.keys.join(',') ?? '-'} '
        'url_present=${url is String && url.isNotEmpty} '
        'b64_chars=${b64 is String ? b64.length : 0}';
  }
}

AiImageGenerationException invalidImageParameter() =>
    AiImageGenerationException(
      imageErrorMessage(AiImageErrorCode.param),
      code: AiImageErrorCode.param,
    );

String imageErrorMessage(AiImageErrorCode code) {
  return switch (code) {
    AiImageErrorCode.auth => '图片生成鉴权失败，请检查 API Key 是否正确。',
    AiImageErrorCode.size => '图片尺寸不受当前模型支持，请调整 size 后重试。',
    AiImageErrorCode.moderation => '提示词或图片内容未通过审核，请调整后重试。',
    AiImageErrorCode.rate_limit => '图片生成请求过于频繁，请稍后再试。',
    AiImageErrorCode.param => '当前模型不支持该图片生成参数，请调整后重试。',
    AiImageErrorCode.credit => 'AI 供应商余额或额度不足，请检查供应商账户后重试。',
    AiImageErrorCode.model_forbidden => '当前账号已被限制使用该图片模型，请切换其他模型。',
  };
}

void throwForImageHttpFailure({
  required Uri uri,
  required int? statusCode,
  required dynamic data,
  required String? providerId,
}) {
  if (_log.isDebugEnabled) {
    _log.debug(
      'HTTP $uri status=$statusCode body=${data is String ? data : jsonEncode(data)}',
    );
  }
  final code = statusCode ?? -1;
  if (code >= 200 && code < 300) {
    return;
  }
  final serverMessage = extractImageServerMessage(data);
  final errorCode = imageErrorCodeFromStatus(code, serverMessage);
  throw AiImageSubmissionException(
    code >= 400 && code < 500
        ? _providerImageMessage(data, providerId) ??
              _userMessageFromStatusCode(code, serverMessage)
        : tr(LocaleKeys.aiImageSubmissionUnknown),
    debugMessage:
        'HTTP $code for ${safeImageUriForLog(uri)} response=${safeImageSerializeForLog(data)}',
    code: errorCode,
    failureCode: code >= 400 && code < 500 ? 'rejected' : 'submission_unknown',
  );
}

/// HTTP 状态码先于文案：401/403、402、429 不必等服务端文案措辞对得上关键字。
AiImageErrorCode? imageErrorCodeFromStatus(
  int? statusCode,
  String? serverMessage,
) {
  // 403 同时用于鉴权失败和模型禁用，先认出禁用，避免误导用户去查 API Key。
  if (statusCode == 403 &&
      classifyAiImageError(serverMessage) == AiImageErrorCode.model_forbidden) {
    return AiImageErrorCode.model_forbidden;
  }
  if (statusCode == 401 || statusCode == 403) {
    return AiImageErrorCode.auth;
  }
  if (statusCode == 402) {
    return AiImageErrorCode.credit;
  }
  if (statusCode == 429) {
    return AiImageErrorCode.rate_limit;
  }
  return classifyAiImageError(serverMessage);
}

AiImageGenerationException imageExceptionFromDio(
  DioException error, {
  required String? providerId,
}) {
  final serverMessage = extractImageServerMessage(error.response?.data);
  return AiImageGenerationException(
    _providerImageMessage(error.response?.data, providerId) ??
        _userMessageFromDio(error),
    debugMessage: error.message,
    code: imageErrorCodeFromStatus(error.response?.statusCode, serverMessage),
  );
}

String? _providerImageMessage(Object? response, String? providerId) {
  if (response == null) {
    return null;
  }
  final message = tryReadProviderMessage(response);
  if (message != null) {
    return message;
  }
  final code = tryReadProviderErrorCode(response);
  if (code == null) {
    return null;
  }
  final failure = AiRunFailure.requestFailed(
    providerId: providerId,
    providerCode: code,
    providerMessage: tryReadProviderMessage(response),
  );
  final key = localizeAiRunFailure(failure, (key) => key);
  if (key == LocaleKeys.aiRequestFailed) {
    return null;
  }
  // 错误码族只给出泛化原因；图片消息能分出尺寸、审核等具体原因时优先展示。
  if (key == arkErrorFamilyLocaleKey(code)) {
    return imageUserMessageFromServerMessage(
          extractImageServerMessage(response),
        ) ??
        tr(key);
  }
  return tr(key);
}

String _userMessageFromDio(DioException error) {
  switch (error.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.transformTimeout:
      return '图片生成请求超时，请稍后重试。';
    case DioExceptionType.connectionError:
      return '无法连接到图片生成服务，请检查网络或服务地址。';
    case DioExceptionType.badCertificate:
      return '图片生成服务的证书校验失败，请检查服务地址。';
    case DioExceptionType.cancel:
      return '图片生成已取消。';
    case DioExceptionType.badResponse:
      final statusCode = error.response?.statusCode;
      final serverMessage = extractImageServerMessage(error.response?.data);
      return _userMessageFromStatusCode(statusCode ?? -1, serverMessage);
    case DioExceptionType.unknown:
      final serverMessage = extractImageServerMessage(error.response?.data);
      return imageUserMessageFromServerMessage(serverMessage) ??
          '图片生成失败，请稍后重试。';
  }
}

String _userMessageFromStatusCode(int statusCode, String? serverMessage) {
  final code = imageErrorCodeFromStatus(statusCode, serverMessage);
  if (code != null) {
    return imageErrorMessage(code);
  }
  return imageUserMessageFromServerMessage(serverMessage) ??
      '图片生成服务暂时不可用，请稍后重试。';
}

String? imageUserMessageFromServerMessage(String? message) {
  final original = tryReadProviderMessage(message ?? '');
  if (original != null) {
    return original;
  }
  final code = classifyAiImageError(message);
  return code == null ? null : imageErrorMessage(code);
}

String? extractImageServerMessage(dynamic data) {
  final original = data == null ? null : tryReadProviderMessage(data);
  if (original != null) {
    return original;
  }
  if (data == null) {
    return null;
  }
  if (data is String) {
    return data;
  }
  if (data is Map<String, dynamic>) {
    final error = data['error'];
    if (error is Map<String, dynamic>) {
      return error['message']?.toString() ??
          error['msg']?.toString() ??
          error['code']?.toString();
    }
    return data['message']?.toString() ??
        data['msg']?.toString() ??
        data['detail']?.toString();
  }
  return data.toString();
}

String safeImageUriForLog(Uri uri) {
  final port = uri.hasPort ? ':${uri.port}' : '';
  return '${uri.scheme}://${uri.host}$port${uri.path}';
}

String safeImageSerializeForLog(dynamic data) {
  try {
    return jsonEncode(data);
  } catch (_) {
    return data.toString();
  }
}

/// Detects the MIME subtype from magic bytes (e.g. 'png', 'jpeg', 'webp').
String imageMimeFromBytes(List<int> bytes) {
  if (bytes.length < 4) return 'png';
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'png';
  }
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return 'jpeg';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'webp';
  }
  if (bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return 'gif';
  }
  return 'png';
}

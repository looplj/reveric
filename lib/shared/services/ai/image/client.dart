// 职责: 定义按协议实现的图片生成客户端基类，提供共用的 HTTP、结果落盘、参考图归一化与错误分类。
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
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart' show compute, protected;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../../localization/locale_keys.dart';
import '../../../utils/storage_paths.dart';
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
import '../image_reference_compression.dart';

final _log = AppLogger.forModule('Image');

void writeImageLog(String message) => _log.info(message);

const imageHttpConnectTimeout = Duration(seconds: 30);
const imageHttpDataTimeout = Duration(minutes: 5);

/// 一次图片生成；[images] 为空时是文生图，否则按参考图编辑。
class ImageGenerationRequest {
  const ImageGenerationRequest({
    required this.prompt,
    required this.model,
    this.size,
    this.quality,
    this.complexity,
    this.aspectRatio,
    this.resolution,
    this.images = const [],
    this.onSubmitted,
    this.onOutputs,
  });
  final String prompt;
  final String model;
  final String? size;
  final String? quality;
  final String? complexity;
  final String? aspectRatio;
  final String? resolution;
  final List<String> images;
  final ImageSubmitted? onSubmitted;
  final ImageOutputsReceived? onOutputs;
}

/// 单个图片协议的请求编码与回执解析。渠道未登记的型号不做能力校验，
/// 原样提交；是否允许使用由业务层决定。
abstract class ImageClient {
  ImageClient(this.config);
  final AiProvider config;

  /// 不支持参考图编辑的协议返回 false。
  bool get supportsEdit => true;

  Future<AiImageGenerationResult> generate(ImageGenerationRequest request);

  @protected
  ImageChannelModel? channelFor(String model) =>
      lookupImageChannelModel(config.type, model);

  /// 校验渠道登记的参考图数量和尺寸；未登记型号直接放行。
  @protected
  ImageChannelModel? validatedChannel(ImageGenerationRequest request) {
    final channel = channelFor(request.model);
    if (channel == null) {
      return null;
    }
    try {
      channel.capabilities.validateReferences(request.images.length);
    } on FormatException {
      throw invalidImageParameter();
    }
    try {
      channel.capabilities.validateSize(
        request.size ?? channel.requestDefaults.size,
        references: request.images.length,
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
  Dio newImageDio() => createProxyDioClient(
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

  @protected
  Future<Map<String, dynamic>> postImageJson(
    Uri uri,
    Map<String, dynamic> body, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final apiKey = requireApiKey();
    final client = config.createProxyClient() ?? http.Client();
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
  Future<AiImageGenerationResult> parseImageResponse(
    Map<String, dynamic> data, {
    required String emptyMessage,
  }) async {
    final images = data['data'] as List?;
    if (images == null || images.isEmpty) {
      throw AiImageGenerationException(emptyMessage);
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
    final b64Json = firstImage['b64_json'] as String?;
    final url = firstImage['url'] as String?;
    final revisedPrompt = firstImage['revised_prompt'] as String?;

    String? localPath;
    String mimeSubtype = 'png';
    String? imageBase64 = b64Json;
    if (b64Json != null && b64Json.isNotEmpty) {
      writeImageLog(
        '[IMGDBG] image_source kind=b64_json chars=${b64Json.length}',
      );
      localPath = await saveImageBase64(b64Json);
      mimeSubtype = imageMimeFromBytes(base64Decode(b64Json));
    } else if (url != null && url.isNotEmpty) {
      writeImageLog(
        '[IMGDBG] image_source kind=url uri=${safeImageUriForLog(Uri.parse(url))}',
      );
      final List<int> bytes;
      try {
        bytes = await _fetchUrlToBytes(url);
        localPath = await _saveBytesLocally(bytes);
      } catch (error) {
        throw AiImageFetchException(
          '图片下载失败，请稍后重试。',
          url: url,
          debugMessage:
              'Image download failed for ${safeImageUriForLog(Uri.parse(url))}: '
              '${error is AiImageGenerationException
                  ? error.debugMessage ?? error.userMessage
                  : error is DioException
                  ? error.error ?? error.message
                  : error}',
        );
      }
      mimeSubtype = imageMimeFromBytes(bytes);
      imageBase64 = null;
    } else {
      throw AiImageGenerationException(emptyMessage);
    }

    writeImageLog(
      '[IMGDBG] image_result_ready source=${b64Json != null && b64Json.isNotEmpty ? 'b64_json' : 'url'} '
      'local_saved=true mime=$mimeSubtype',
    );

    return AiImageGenerationResult(
      imageUrl: url,
      imageBase64: imageBase64,
      revisedPrompt: revisedPrompt,
      localFilePath: localPath,
      mimeSubtype: mimeSubtype,
    );
  }

  /// 已取得的候选地址作为整组保留，任一下载失败也不能丢掉其余地址。
  Future<AiImageGenerationResult> downloadResults(List<String> urls) async {
    if (urls.isEmpty) {
      throw invalidImageParameter();
    }
    final results = <AiImageGenerationResult>[];
    try {
      for (final url in urls) {
        results.add(await downloadResult(url));
      }
      return AiImageGenerationResult.group(results);
    } catch (error) {
      for (final result in results) {
        await result.disposeTemporary();
      }
      throw AiImageFetchException(
        tr(LocaleKeys.aiImageCandidatesFetchFailed),
        urls: urls,
        debugMessage: 'Candidate download failed: $error',
      );
    }
  }

  /// 按上游任务 ID 继续查询结果；只有异步任务协议支持。
  Future<AiImageGenerationResult> resumeResult(String providerTaskId) =>
      throw UnsupportedError('当前图片协议不支持按任务 ID 查询结果。');

  /// 重新下载上游已生成的图片 URL，失败时抛 [AiImageFetchException]。
  Future<AiImageGenerationResult> downloadResult(String url) =>
      parseImageResponse({
        'data': [
          {'url': url},
        ],
      }, emptyMessage: tr(LocaleKeys.aiImageNoResult));

  @protected
  Future<String> saveImageBase64(String base64Data) =>
      _saveBytesLocally(base64Decode(base64Data));

  Future<String> _saveBytesLocally(List<int> bytes) async {
    writeImageLog('[IMGDBG] local_save_start bytes=${bytes.length}');
    final root = Directory(RevericPaths.fileWorkspaceParent);
    final directory = Directory(p.join(root.path, 'file_workspaces'));

    await directory.create(recursive: true);
    final ext = _imageExtensionFromBytes(bytes);
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final random = Random().nextInt(10000);
    final filePath = p.join(
      directory.path,
      'reveric_image_result_${timestamp}_$random.$ext.part',
    );

    final file = await File(filePath).create(exclusive: true);
    try {
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {
      await file.delete();
      rethrow;
    }
    writeImageLog(
      '[IMGDBG] local_save_done bytes=${bytes.length} extension=$ext',
    );
    return filePath;
  }

  Future<List<int>> _fetchUrlToBytes(String url) async {
    if (url.startsWith('data:')) {
      final commaIndex = url.indexOf(',');
      if (commaIndex <= 0) {
        throw const AiImageGenerationException('图片下载失败，请稍后重试。');
      }
      return base64Decode(url.substring(commaIndex + 1));
    }
    final uri = Uri.parse(url);
    writeImageLog(
      '[IMGDBG] image_download_start uri=${safeImageUriForLog(uri)} '
      'timeout_s=${imageHttpDataTimeout.inSeconds}',
    );
    final dio = newImageDio();
    try {
      // 下载是幂等 GET，握手中断、连接重置这类瞬时网络错误就地重试。
      Response<List<int>>? response;
      for (var attempt = 1; response == null; attempt++) {
        try {
          response = await dio.get<List<int>>(
            url,
            options: Options(
              responseType: ResponseType.bytes,
              validateStatus: (_) => true,
            ),
            onReceiveProgress: receiveProgressLogger(uri, 'image_download'),
          );
        } on DioException catch (error) {
          if (attempt >= _imageDownloadAttempts ||
              !_isTransientDioError(error)) {
            rethrow;
          }
          writeImageLog(
            '[IMGDBG] image_download_retry attempt=$attempt '
            'uri=${safeImageUriForLog(uri)} error=${error.error ?? error.type}',
          );
          await Future<void>.delayed(Duration(seconds: attempt));
        }
      }
      final code = response.statusCode ?? -1;
      final data = response.data;
      writeImageLog(
        '[IMGDBG] image_download_response status=$code '
        'headers=${_responseHeadersSummary(response.headers)} '
        'bytes=${data?.length ?? -1}',
      );
      if (code < 200 || code >= 300 || data == null || data.isEmpty) {
        throw AiImageGenerationException(
          '图片下载失败，请稍后重试。',
          debugMessage: 'HTTP $code for ${safeImageUriForLog(uri)}',
        );
      }
      writeImageLog('[IMGDBG] image_download_done bytes=${data.length}');
      return data;
    } finally {
      dio.close(force: true);
    }
  }

  /// 归一化为 data URI：接受 data URI、URL、本地文件路径或裸 base64。
  @protected
  Future<String> imageInputAsDataUri(String imageData) async {
    final trimmed = imageData.trim();
    if (trimmed.startsWith('data:')) {
      return trimmed;
    }
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      final bytes = await _fetchUrlToBytes(trimmed);
      final mime = imageMimeFromBytes(bytes);
      return 'data:image/$mime;base64,${base64Encode(bytes)}';
    }
    return _localOrBase64AsDataUri(trimmed);
  }

  /// 归一化为接口可直接引用的地址：URL 与 data URI 原样保留，
  /// 本地文件路径或裸 base64 转为 data URI。
  @protected
  Future<String> imageInputAsUrlOrDataUri(String imageData) async {
    final trimmed = imageData.trim();
    if (trimmed.startsWith('http://') ||
        trimmed.startsWith('https://') ||
        trimmed.startsWith('data:')) {
      return trimmed;
    }
    return _localOrBase64AsDataUri(trimmed);
  }

  // Detect MIME from actual byte content so the data-URI prefix matches the
  // real format (e.g. a JPEG must declare image/jpeg).
  Future<String> _localOrBase64AsDataUri(String trimmed) async {
    final file = File(trimmed);
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      final mime = imageMimeFromBytes(bytes);
      return 'data:image/$mime;base64,${base64Encode(bytes)}';
    }
    try {
      final decoded = base64Decode(trimmed);
      final mime = imageMimeFromBytes(decoded);
      return 'data:image/$mime;base64,$trimmed';
    } catch (_) {
      return 'data:image/png;base64,$trimmed';
    }
  }

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
  final code = statusCode ?? -1;
  if (code >= 200 && code < 300) {
    return;
  }
  final serverMessage = extractImageServerMessage(data);
  final errorCode = imageErrorCodeFromStatus(code, serverMessage);
  throw AiImageGenerationException(
    _providerImageMessage(data, providerId) ??
        _userMessageFromStatusCode(code, serverMessage),
    debugMessage:
        'HTTP $code for ${safeImageUriForLog(uri)} response=${safeImageSerializeForLog(data)}',
    code: errorCode,
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

const _imageDownloadAttempts = 3;

bool _isTransientDioError(DioException error) => switch (error.type) {
  DioExceptionType.connectionTimeout ||
  DioExceptionType.connectionError => true,
  DioExceptionType.unknown =>
    error.error is SocketException || error.error is HandshakeException,
  _ => false,
};

/// Detects the image file extension from magic bytes.
String _imageExtensionFromBytes(List<int> bytes) {
  final mime = imageMimeFromBytes(bytes);
  return mime == 'jpeg' ? 'jpg' : mime;
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

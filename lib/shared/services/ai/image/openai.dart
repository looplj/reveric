// 职责: 将图片请求编码为 OpenAI Images 协议（generations / multipart edits）并解析回执。
// 关联文件:
//   lib/shared/services/ai/image/client.dart
//   lib/shared/models/ai_provider.dart
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../models/ai_provider.dart';
import '../image.dart';
import 'client.dart';

class OpenAiImageClient extends ImageClient {
  OpenAiImageClient(super.config);

  static const String _generateSize = '864x1536';
  static const String _editSize = '768x1024';

  @override
  Future<AiImageGenerationResult> generate(ImageGenerationRequest request) =>
      request.images.isEmpty ? _generate(request) : _edit(request);

  Future<AiImageGenerationResult> _generate(
    ImageGenerationRequest request,
  ) async {
    final apiKey = config.effectiveApiKey;
    if (apiKey.isEmpty) {
      throw const AiImageGenerationException('请先配置图片模型的 API Key。');
    }

    final dio = newImageDio();
    final uri = Uri.parse('${config.effectiveBaseUrl}/images/generations');
    writeImageLog(
      '[IMGDBG] http_request_start method=POST uri=${safeImageUriForLog(uri)} '
      'provider=${config.id} model=${request.model} '
      'timeout_s=${imageHttpDataTimeout.inSeconds}',
    );

    final quality = request.quality;
    final body = <String, dynamic>{
      'model': request.model,
      'prompt': request.prompt,
      'response_format': 'b64_json',
      'output_format': 'png',
      'n': 1,
      'size': request.size ?? _generateSize,
      // 只有 OpenAI 兼容通道认这个参数；Doubao / Gemini 不发，避免请求被拒。
      if (quality != null && quality.isNotEmpty) 'quality': quality,
      if (request.complexity case final String complexity)
        'complexity': complexity,
    };

    final response = await dio.post<Map<String, dynamic>>(
      uri.toString(),
      data: body,
      options: Options(
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        validateStatus: (_) => true,
      ),
      onReceiveProgress: receiveProgressLogger(uri, 'generate'),
    );
    logImageHttpResponse(
      uri,
      response.statusCode,
      response.headers,
      response.data,
    );
    throwForImageHttpFailure(
      uri: uri,
      statusCode: response.statusCode,
      data: response.data,
      providerId: config.id,
    );

    final data = response.data;
    if (data == null) {
      throw const AiImageGenerationException('图片生成服务返回了空结果，请稍后重试。');
    }

    return parseImageResponse(data, emptyMessage: '图片生成服务未返回图片，请稍后重试。');
  }

  Future<AiImageGenerationResult> _edit(ImageGenerationRequest request) async {
    final apiKey = config.effectiveApiKey;
    if (apiKey.isEmpty) {
      throw const AiImageGenerationException('请先配置图片模型的 API Key。');
    }

    final dio = newImageDio();
    final uri = Uri.parse('${config.effectiveBaseUrl}/images/edits');
    writeImageLog(
      '[IMGDBG] http_request_start method=POST uri=${safeImageUriForLog(uri)} '
      'provider=${config.id} model=${request.model} '
      'timeout_s=${imageHttpDataTimeout.inSeconds}',
    );

    final form = FormData.fromMap(<String, dynamic>{
      'model': request.model,
      'prompt': request.prompt,
      'output_format': 'png',
      'n': '1',
      'size': request.size ?? _editSize,
    });
    form.fields.add(const MapEntry('response_format', 'b64_json'));
    final quality = request.quality;
    if (quality != null && quality.isNotEmpty) {
      form.fields.add(MapEntry('quality', quality));
    }
    if (request.complexity case final String complexity) {
      form.fields.add(MapEntry('complexity', complexity));
    }
    for (final input in request.images) {
      final normalized = await imageInputAsDataUri(input);
      if (normalized.startsWith('data:')) {
        final comma = normalized.indexOf(',');
        final header = normalized.substring(0, comma);
        final bytes = base64Decode(normalized.substring(comma + 1));
        final sourceExtension = header.contains('jpeg') ? 'jpg' : 'png';
        final prepared = await prepareMultipartReference(
          bytes,
          sourceExtension,
        );
        form.files.add(
          MapEntry(
            'image[]',
            MultipartFile.fromBytes(
              prepared.bytes,
              filename: 'reference.${prepared.extension}',
            ),
          ),
        );
      } else {
        throw const AiImageGenerationException('图片参考图必须是本地文件或 data URI。');
      }
    }

    final response = await dio.post<Map<String, dynamic>>(
      uri.toString(),
      data: form,
      options: Options(
        headers: {'Authorization': 'Bearer $apiKey'},
        validateStatus: (_) => true,
      ),
      onReceiveProgress: receiveProgressLogger(uri, 'edit'),
    );
    logImageHttpResponse(
      uri,
      response.statusCode,
      response.headers,
      response.data,
    );
    throwForImageHttpFailure(
      uri: uri,
      statusCode: response.statusCode,
      data: response.data,
      providerId: config.id,
    );

    final data = response.data;
    if (data == null) {
      throw const AiImageGenerationException('图片编辑服务返回了空结果，请稍后重试。');
    }

    return parseImageResponse(data, emptyMessage: '图片编辑服务未返回图片，请稍后重试。');
  }
}

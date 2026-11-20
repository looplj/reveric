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
  Future<ProviderSubmitResult> submit(
    SubmitImageInput request,
    ImageOutputContext outputs,
  ) => request.references.isEmpty
      ? _generate(request, outputs)
      : _edit(request, outputs);

  Future<ProviderSubmitResult> _generate(
    SubmitImageInput request,
    ImageOutputContext outputs,
  ) async {
    final apiKey = config.effectiveApiKey;
    if (apiKey.isEmpty) {
      throw const AiImageGenerationException('请先配置图片模型的 API Key。');
    }

    final dio = newImageDio();
    try {
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
        'output_format': 'png',
        'n': 1,
        'size': request.size ?? _generateSize,
        // 只有 OpenAI 兼容通道认这个参数；Doubao / Gemini 不发，避免请求被拒。
        if (quality != null && quality.isNotEmpty) 'quality': quality,
        if (request.complexity case final String complexity)
          'complexity': complexity,
      };

      final response = await dio.post<Object?>(
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
      if (data is! Map<String, dynamic>) {
        throw invalidImageOutputs('Empty image response');
      }

      return await parseImageResponse(
        data,
        outputs,
        emptyMessage: '图片生成服务未返回图片，请稍后重试。',
      );
    } finally {
      dio.close(force: true);
    }
  }

  Future<ProviderSubmitResult> _edit(
    SubmitImageInput request,
    ImageOutputContext outputs,
  ) async {
    final apiKey = config.effectiveApiKey;
    if (apiKey.isEmpty) {
      throw const AiImageGenerationException('请先配置图片模型的 API Key。');
    }

    final dio = newImageDio();
    try {
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
      final quality = request.quality;
      if (quality != null && quality.isNotEmpty) {
        form.fields.add(MapEntry('quality', quality));
      }
      if (request.complexity case final String complexity) {
        form.fields.add(MapEntry('complexity', complexity));
      }
      for (final input in request.references) {
        final normalized = await imageInputAsDataUri(input, outputs);
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

      final response = await dio.post<Object?>(
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
      if (data is! Map<String, dynamic>) {
        throw invalidImageOutputs('Empty or malformed image edit response');
      }

      return await parseImageResponse(
        data,
        outputs,
        emptyMessage: '图片编辑服务未返回图片，请稍后重试。',
      );
    } finally {
      dio.close(force: true);
    }
  }
}

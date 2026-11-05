// 职责: 通过 New API 的 Images 与 Gemini 接口生成和编辑图片。
// 关联文件:
//   lib/shared/services/ai/image/client.dart
//   lib/shared/services/ai/new_api.dart
//   lib/shared/models/image/channels.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import 'dart:convert';
import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart' as http;
import '../../../models/ai_provider.dart';
import '../../../localization/locale_keys.dart';
import '../image.dart';
import 'client.dart';
import 'gemini.dart';

class NewApiImageClient extends ImageClient {
  NewApiImageClient(super.config);

  @override
  Future<AiImageGenerationResult> generate(
    ImageGenerationRequest request,
  ) async {
    final channel = validatedChannel(request);
    final catalogId = channel?.catalogId ?? request.model;
    if (catalogId.startsWith('gemini-')) {
      return GeminiImageClient(config, useGateway: true).generate(request);
    }
    final fields = <String, dynamic>{
      'model': request.model,
      'prompt': request.prompt,
      'n': 1,
      'response_format': 'b64_json',
      if (request.size ?? channel?.requestDefaults.size case final String size)
        'size': size,
      if (request.quality case final String quality) 'quality': quality,
      if (request.complexity case final String complexity)
        'complexity': complexity,
    };
    Map<String, dynamic> data;
    final base = config.effectiveBaseUrl;
    if (request.images.isEmpty) {
      data = await postImageJson(Uri.parse('$base/images/generations'), fields);
    } else if (catalogId.startsWith('seedream-')) {
      data = await postImageJson(Uri.parse('$base/images/generations'), {
        ...fields,
        'image': [
          for (final image in request.images)
            await imageInputAsUrlOrDataUri(image),
        ],
      });
    } else {
      final uri = Uri.parse('$base/images/edits');
      final form = http.MultipartRequest('POST', uri)
        ..followRedirects = false
        ..headers['Authorization'] = 'Bearer ${requireApiKey()}'
        ..fields.addAll(
          fields.map((key, value) => MapEntry(key, value.toString())),
        );
      for (final image in request.images) {
        final input = UriData.parse(await imageInputAsDataUri(image));
        final prepared = await prepareMultipartReference(
          input.contentAsBytes(),
          input.mimeType == 'image/jpeg' ? 'jpg' : 'png',
        );
        form.files.add(
          http.MultipartFile.fromBytes(
            'image[]',
            prepared.bytes,
            filename: 'reference.${prepared.extension}',
          ),
        );
      }
      final client = config.createProxyClient() ?? http.Client();
      try {
        final response = await (() async => http.Response.fromStream(
          await client.send(form),
        ))().timeout(imageHttpDataTimeout);
        throwForImageHttpFailure(
          uri: uri,
          statusCode: response.statusCode,
          data: response.body,
          providerId: config.id,
        );
        data = jsonDecode(response.body) as Map<String, dynamic>;
      } finally {
        client.close();
      }
    }
    return parseImageResponse(
      data,
      emptyMessage: tr(LocaleKeys.aiImageNoResult),
    );
  }
}

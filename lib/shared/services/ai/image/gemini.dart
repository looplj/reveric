// 职责: 通过 Gemini 官方或网关 generateContent 接口生成和编辑图片。
// 关联文件:
//   lib/shared/services/ai/image/client.dart
//   lib/shared/agent/client/gemini_client.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import 'dart:convert';


import '../../../agent/client/gemini_client.dart' show geminiModelEndpoint;
import '../../../models/ai_provider.dart';
import '../image.dart';
import 'client.dart';

class GeminiImageClient extends ImageClient {
  GeminiImageClient(super.config, {this.useGateway = false});

  final bool useGateway;

  @override
  Future<ProviderSubmitResult> submit(
    SubmitImageInput request,
    ImageOutputContext outputs,
  ) async {
    validatedChannel(request);
    final url = geminiModelEndpoint(
      useGateway
          ? config.effectiveImageBaseUrl.replaceFirst(RegExp(r'/v1$'), '')
          : config.effectiveImageBaseUrl,
      request.model,
      'generateContent',
    );
    final partsInput = <Map<String, dynamic>>[
      {'text': request.prompt},
    ];
    for (final image in request.references) {
      final data = UriData.parse(await imageInputAsDataUri(image, outputs));
      partsInput.add({
        'inlineData': {
          'mimeType': data.mimeType,
          'data': base64Encode(data.contentAsBytes()),
        },
      });
    }
    final data = await postImageJson(url, {
      'contents': [
        {'role': 'user', 'parts': partsInput},
      ],
      'generationConfig': {
        'responseModalities': ['IMAGE', 'TEXT'],
        if (request.aspectRatio != null || request.resolution != null)
          'imageConfig': {
            if (request.aspectRatio != null && request.aspectRatio != 'auto')
              'aspectRatio': request.aspectRatio,
            if (request.resolution != null && request.resolution != 'auto')
              'imageSize': request.resolution,
          },
      },
    }, headers: useGateway ? null : {'x-goog-api-key': requireApiKey()});
    final candidates = data['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      throw invalidImageOutputs('Gemini response contains no image');
    }
    final parts =
        (candidates[0] as Map<String, dynamic>)['content']?['parts'] as List? ??
        [];

    String? base64Data;
    for (final part in parts) {
      if (part is Map && part['inlineData'] is Map) {
        final inlineData = part['inlineData'] as Map;
        base64Data = inlineData['data'] as String?;
        break;
      }
    }

    if (base64Data == null) {
      throw invalidImageOutputs('Gemini response contains no image');
    }

    return outputs.nativeImages([
      {'b64_json': base64Data},
    ]);
  }
}

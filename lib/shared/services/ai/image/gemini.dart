// 职责: 通过 Gemini 官方或网关 generateContent 接口生成和编辑图片。
// 关联文件:
//   lib/shared/services/ai/image/client.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';

import '../../../models/ai_provider.dart';
import '../../../localization/locale_keys.dart';
import '../image.dart';
import 'client.dart';

class GeminiImageClient extends ImageClient {
  GeminiImageClient(super.config, {this.useGateway = false});

  final bool useGateway;

  @override
  Future<AiImageGenerationResult> generate(
    ImageGenerationRequest request,
  ) async {
    validatedChannel(request);
    final base = useGateway
        ? config.effectiveBaseUrl.replaceFirst(RegExp(r'/v1$'), '')
        : 'https://generativelanguage.googleapis.com';
    final url = Uri.parse(
      '$base/v1beta/models/${Uri.encodeComponent(request.model)}:generateContent',
    );
    final partsInput = <Map<String, dynamic>>[
      {'text': request.prompt},
    ];
    for (final image in request.images) {
      final data = UriData.parse(await imageInputAsDataUri(image));
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
      throw AiImageGenerationException(tr(LocaleKeys.aiImageNoResult));
    }
    final parts =
        (candidates[0] as Map<String, dynamic>)['content']?['parts'] as List? ??
        [];

    String? base64Data;
    String? mimeType;
    for (final part in parts) {
      if (part is Map && part['inlineData'] is Map) {
        final inlineData = part['inlineData'] as Map;
        base64Data = inlineData['data'] as String?;
        mimeType = inlineData['mimeType'] as String?;
        break;
      }
    }

    if (base64Data == null) {
      throw AiImageGenerationException(tr(LocaleKeys.aiImageNoResult));
    }

    final localPath = await saveImageBase64(base64Data);
    return AiImageGenerationResult(
      imageBase64: base64Data,
      localFilePath: localPath,
      mimeSubtype: _mimeSubtypeFromType(mimeType),
    );
  }

  String _mimeSubtypeFromType(String? mimeType) {
    if (mimeType == null) return 'png';
    if (mimeType.contains('jpeg') || mimeType.contains('jpg')) return 'jpeg';
    if (mimeType.contains('webp')) return 'webp';
    if (mimeType.contains('gif')) return 'gif';
    return 'png';
  }
}

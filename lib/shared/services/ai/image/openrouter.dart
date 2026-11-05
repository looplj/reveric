// 职责: 将图片请求编码为 OpenRouter images 协议并解析回执。
// 关联文件:
//   lib/shared/services/ai/image/client.dart
//   lib/shared/models/image/channels.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import 'package:easy_localization/easy_localization.dart';

import '../../../models/ai_provider.dart';
import '../../../localization/locale_keys.dart';
import '../image.dart';
import 'client.dart';

class OpenRouterImageClient extends ImageClient {
  OpenRouterImageClient(super.config);

  @override
  Future<AiImageGenerationResult> generate(
    ImageGenerationRequest request,
  ) async {
    final channel = validatedChannel(request);
    final aspectRatio = request.aspectRatio;
    final resolution = request.resolution;
    if (channel != null &&
        ((aspectRatio != null &&
                !channel.capabilities.ratios.contains(aspectRatio)) ||
            (resolution != null &&
                !channel.capabilities.resolutions.contains(resolution)))) {
      throw invalidImageParameter();
    }
    final references = <Map<String, dynamic>>[];
    for (final input in request.images) {
      references.add({
        'type': 'image_url',
        'image_url': {'url': await imageInputAsUrlOrDataUri(input)},
      });
    }
    final defaults = channel?.requestDefaults;
    final size = request.size;
    final data = await postImageJson(
      Uri.parse('${config.effectiveBaseUrl}/images'),
      {
        'model': request.model,
        'prompt': request.prompt,
        'n': 1,
        'output_format': ?defaults?.outputFormat,
        if (size != null && size != 'auto') 'size': size,
        if (aspectRatio != null && aspectRatio != 'auto')
          'aspect_ratio': aspectRatio,
        if (resolution != null && resolution != 'auto')
          'resolution': resolution,
        'quality': ?(request.quality ?? defaults?.quality),
        if (request.complexity case final String complexity)
          'provider': {
            'options': {
              'openai': {'complexity': complexity},
            },
          },
        if (references.isNotEmpty) 'input_references': references,
      },
    );
    return parseImageResponse(
      data,
      emptyMessage: tr(LocaleKeys.aiImageNoResult),
    );
  }
}

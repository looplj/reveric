// 职责: 将图片请求编码为百炼 Qwen / Wan 图片协议（images 接口或多模态生成接口）并解析回执。
// 关联文件:
//   lib/shared/services/ai/image/client.dart
//   lib/shared/models/image/channels.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import 'package:easy_localization/easy_localization.dart';

import '../../../models/ai_provider.dart';
import '../../../localization/locale_keys.dart';
import '../../../models/image/channels.dart';
import '../image.dart';
import 'client.dart';

class QwenImageClient extends ImageClient {
  QwenImageClient(super.config);

  @override
  Future<AiImageGenerationResult> generate(
    ImageGenerationRequest request,
  ) async {
    final channel = validatedChannel(request);
    final defaults = channel?.requestDefaults;
    final size = request.size;
    final requestedSize =
        channel != null && channel.capabilities.resolutions.contains(size)
        ? channel.capabilities.size('1:1', size!)
        : size ?? defaults?.size;
    final references = <String>[];
    for (final image in request.images) {
      references.add(await imageInputAsUrlOrDataUri(image));
    }
    final base = Uri.parse(config.effectiveBaseUrl);
    final basePath = base.path.replaceFirst(RegExp(r'/+$'), '');
    final options = channel?.protocolOptions as QwenImageOptions?;
    // Token Plan uses the native multimodal endpoint for all image models.
    final modern =
        config.typeEnum != AiProviderType.qwen_token_plan &&
        (options?.usesImagesApi ?? false);
    final uri = base.replace(
      path: modern
          ? '$basePath/images/generations'
          : '${basePath.replaceFirst(RegExp(r'/compatible-mode/v1$'), '')}/api/v1/services/aigc/multimodal-generation/generation',
    );
    final data = await postImageJson(
      uri,
      modern
          ? {
              'model': request.model,
              'prompt': request.prompt,
              'n': 1,
              'size': ?requestedSize,
              'watermark': ?defaults?.watermark,
              'prompt_extend': ?defaults?.promptExtend,
              if (references.isNotEmpty) 'image': references,
            }
          : {
              'model': request.model,
              'input': {
                'messages': [
                  {
                    'role': 'user',
                    'content': [
                      for (final image in references) {'image': image},
                      {'text': request.prompt},
                    ],
                  },
                ],
              },
              'parameters': {
                'n': 1,
                if (requestedSize != null && requestedSize != 'auto')
                  'size': requestedSize.replaceAll('x', '*'),
                'watermark': ?defaults?.watermark,
                'prompt_extend': ?defaults?.promptExtend,
              },
            },
    );
    if (modern) {
      return parseImageResponse(
        data,
        emptyMessage: tr(LocaleKeys.aiImageNoResult),
      );
    }
    final output = data['output'] as Map?;
    final choices = output?['choices'] as List? ?? const [];
    final images = <Map<String, dynamic>>[];
    for (final choice in choices.whereType<Map>()) {
      final message = choice['message'] as Map?;
      final content = message?['content'] as List? ?? const [];
      for (final part in content.whereType<Map>()) {
        if (part['image'] is String) {
          images.add({'url': part['image']});
        }
      }
    }
    return parseImageResponse({
      'data': images,
    }, emptyMessage: tr(LocaleKeys.aiImageNoResult));
  }
}

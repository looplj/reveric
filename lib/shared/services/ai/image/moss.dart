// 职责: 将文生图请求提交给 MOSS 并下载生成图片。
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

class MossImageClient extends ImageClient {
  MossImageClient(super.config);

  @override
  bool get supportsEdit => false;

  @override
  Future<AiImageGenerationResult> generate(
    ImageGenerationRequest request,
  ) async {
    final channel = validatedChannel(request);
    final size = request.size ?? channel?.requestDefaults.size ?? '1024x1024';
    final dimensions = RegExp(r'^(\d+)x(\d+)$').firstMatch(size);
    if (dimensions == null) {
      throw invalidImageParameter();
    }
    final width = int.parse(dimensions[1]!);
    final height = int.parse(dimensions[2]!);
    if (request.images.isNotEmpty ||
        request.prompt.trim().isEmpty ||
        request.prompt.runes.length > 4000 ||
        width < 256 ||
        width > 2048 ||
        height < 256 ||
        height > 2048 ||
        width % 16 != 0 ||
        height % 16 != 0 ||
        width * height > 2097152) {
      throw invalidImageParameter();
    }
    final data = await postImageJson(
      Uri.parse('${config.effectiveBaseUrl}/images/generations'),
      {
        'model': request.model,
        'prompt': request.prompt,
        'size': size,
        'n': 1,
        'response_format': 'url',
        'output_watermark': {'enabled': false},
      },
    );
    return parseImageResponse(
      data,
      emptyMessage: tr(LocaleKeys.aiImageNoResult),
    );
  }
}

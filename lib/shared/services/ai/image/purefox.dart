// 职责: 将图片请求编码为 PureFox 媒体网关的 OpenAI Images 兼容协议并解析回执。
// 关联文件:
//   lib/shared/services/ai/image/client.dart
//   lib/shared/models/image/channels.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import '../../../models/ai_provider.dart';
import '../image.dart';
import '../purefox_media.dart';
import 'client.dart';

/// 网关用 quality 档位（1K/2K/4K）而不是像素尺寸；传了 size 时由服务端忽略档位。
class PurefoxImageClient extends ImageClient {
  PurefoxImageClient(super.config);

  static const _qualityTiers = {'low': '1K', 'medium': '2K', 'high': '4K'};

  @override
  Future<AiImageGenerationResult> generate(
    ImageGenerationRequest request,
  ) async {
    final channel = validatedChannel(request);
    final caps = channel?.capabilities;
    if (caps != null) {
      // 站点目录只给 quality 档位，不给比例；未声明比例的型号由服务端校验。
      final ratios = caps.ratios;
      if (request.aspectRatio != null &&
          ratios.length > 1 &&
          !ratios.contains(request.aspectRatio)) {
        throw invalidImageParameter();
      }
      if (request.resolution != null &&
          !caps.resolutions.contains(request.resolution)) {
        throw invalidImageParameter();
      }
    }
    final editing = request.images.isNotEmpty;
    final body = <String, dynamic>{
      'model': purefoxUpstreamModel(request.model),
      'prompt': request.prompt,
      'n': 1,
      'response_format': 'url',
    };
    final size = request.size;
    if (size != null && size.isNotEmpty && size != 'auto') {
      body['size'] = size;
    } else {
      body['quality'] = _quality(
        request.quality,
        request.resolution,
        caps?.resolutions,
      );
    }
    if (request.aspectRatio != null && request.aspectRatio != 'auto') {
      body['aspect_ratio'] = request.aspectRatio;
    }
    if (editing) {
      body['images'] = [
        for (final input in request.images)
          await imageInputAsUrlOrDataUri(input),
      ];
    }
    final base = config.effectiveBaseUrl.replaceFirst(RegExp(r'/+$'), '');
    final data = await postImageJson(
      Uri.parse('$base/images/${editing ? 'edits' : 'generations'}'),
      body,
    );
    return parseImageResponse(data, emptyMessage: '图片生成服务未返回图片，请稍后重试。');
  }

  String _quality(String? quality, String? resolution, Set<String>? supported) {
    final tier =
        _qualityTiers[quality?.toLowerCase()] ?? quality?.toUpperCase();
    if (tier != null && tier.isNotEmpty) {
      return tier;
    }
    if (resolution != null && resolution.isNotEmpty) {
      return resolution;
    }
    return supported?.first ?? '1K';
  }
}

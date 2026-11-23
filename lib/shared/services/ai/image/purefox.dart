// 职责: 将图片请求编码为 PureFox 媒体网关的 OpenAI Images 兼容协议并解析回执。
// 关联文件:
//   lib/shared/services/ai/image/client.dart
//   lib/shared/models/image/channels.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import '../../../models/ai_provider.dart';
import '../../../models/image/config.dart';
import '../purefox_media.dart';
import 'client.dart';

/// 网关按像素 `size` 决定画幅与清晰度档位；`quality` 只接受真实的 OpenAI
/// 质量档位（low/medium/high）。把 1K/2K/4K 当 quality 发过去会被上游忽略，
/// 出图回落到 1:1。
class PurefoxImageClient extends ImageClient {
  PurefoxImageClient(super.config);

  static const _qualityTiers = {'low', 'medium', 'high'};

  @override
  Future<ProviderSubmitResult> submit(
    SubmitImageInput request,
    ImageOutputContext outputs,
  ) async {
    final channel = validatedChannel(request);
    final caps = channel?.capabilities;
    if (caps != null) {
      if (request.aspectRatio != null &&
          request.aspectRatio != 'auto' &&
          !caps.ratios.contains(request.aspectRatio)) {
        throw invalidImageParameter();
      }
      if (request.resolution != null &&
          request.resolution != 'auto' &&
          !caps.resolutions.contains(request.resolution)) {
        throw invalidImageParameter();
      }
    }
    final editing = request.references.isNotEmpty;
    final body = <String, dynamic>{
      'model': purefoxUpstreamModel(request.model),
      'prompt': request.prompt,
      'n': 1,
      'response_format': 'url',
    };
    final size = _pixelSize(request, caps);
    if (size != null) {
      body['size'] = size;
    }
    final quality = _quality(request.quality);
    if (quality != null) {
      body['quality'] = quality;
    }
    if (request.aspectRatio != null && request.aspectRatio != 'auto') {
      body['aspect_ratio'] = request.aspectRatio;
    }
    if (editing) {
      body['images'] = [
        for (final input in request.references)
          await imageInputAsUrlOrDataUri(input, outputs),
      ];
    }
    final base = config.effectiveBaseUrl.replaceFirst(RegExp(r'/+$'), '');
    final data = await postImageJson(
      Uri.parse('$base/images/${editing ? 'edits' : 'generations'}'),
      body,
    );
    return parseImageResponse(
      data,
      outputs,
      emptyMessage: '图片生成服务未返回图片，请稍后重试。',
    );
  }

  String? _quality(String? quality) {
    final value = quality?.trim().toLowerCase();
    return value != null && _qualityTiers.contains(value) ? value : null;
  }

  String? _pixelSize(
    SubmitImageInput request,
    ImageModelCapabilities? capabilities,
  ) {
    final explicit = request.size;
    if (explicit != null && explicit.isNotEmpty && explicit != 'auto') {
      return explicit;
    }
    final resolution = request.resolution;
    if (resolution == null || resolution.isEmpty || resolution == 'auto') {
      return null;
    }
    final ratio = request.aspectRatio;
    final aspect = ratio == null || ratio.isEmpty || ratio == 'auto'
        ? '1:1'
        : ratio;
    return capabilities?.sizes[resolution]?[aspect];
  }
}

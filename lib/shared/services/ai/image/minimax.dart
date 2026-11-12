// 职责: 将图片请求编码为 MiniMax H3 images/generations 与 images/edits，并解析回执。
// 关联文件:
//   lib/shared/services/ai/image/client.dart
//   lib/shared/models/image/channels.dart
//   lib/shared/models/ai_provider.dart
import '../../../models/ai_provider.dart';
import '../image.dart';
import 'client.dart';

/// 服务端最长等待 600 秒，短于该值的客户端会在服务端仍计费时断开。
const _minimaxImageTimeout = Duration(minutes: 10);

class MinimaxImageClient extends ImageClient {
  MinimaxImageClient(super.config);

  @override
  Future<AiImageGenerationResult> generate(
    ImageGenerationRequest request,
  ) async {
    final channel = validatedChannel(request);
    final editing = request.images.isNotEmpty;
    final defaults = channel?.requestDefaults;
    final body = <String, dynamic>{
      'model': request.model,
      'prompt': request.prompt,
      'n': 1,
      'response_format': defaults?.responseFormat ?? 'b64_json',
      'output_format': defaults?.outputFormat ?? 'png',
    };
    final size = request.size;
    final pixel =
        size != null && RegExp(r'^[1-9][0-9]*x[1-9][0-9]*$').hasMatch(size);
    if (pixel) {
      // 显式宽高不能同时带比例或面积，否则接口返回 400。
      body['size'] = size;
    } else {
      final ratio = request.aspectRatio;
      if (ratio != null && ratio.isNotEmpty && ratio != 'auto') {
        body['aspect_ratio'] = ratio;
      }
      final area = _area(request.resolution) ?? _area(size);
      if (area != null) {
        body['area'] = area;
      }
    }
    if (editing) {
      body['images'] = [
        for (final input in request.images)
          await imageInputAsUrlOrDataUri(input),
      ];
    }
    final data = await postImageJson(
      _uri(editing ? 'edits' : 'generations'),
      body,
      timeout: _minimaxImageTimeout,
    );
    return parseImageResponse(data, emptyMessage: '图片生成服务未返回图片，请稍后重试。');
  }

  Uri _uri(String action) {
    final endpoint = Uri.parse(config.effectiveBaseUrl);
    final path = endpoint.path.replaceFirst(RegExp(r'/+$'), '');
    return endpoint.replace(
      path: '$path${path.endsWith('/v1') ? '' : '/v1'}/images/$action',
    );
  }

  String? _area(String? value) {
    if (value == null || value.isEmpty || value == 'auto') {
      return null;
    }
    return const {'1K', '2K', '4K'}.contains(value) ? value : null;
  }
}

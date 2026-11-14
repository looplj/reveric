// 职责: 将图片请求编码为火山方舟 Seedream images/generations 协议并解析回执。
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
import 'client.dart';

class ArkImageClient extends ImageClient {
  ArkImageClient(super.config);

  @override
  Future<ProviderSubmitResult> submit(
    SubmitImageInput request,
    ImageOutputContext outputs,
  ) async {
    final channel = validatedChannel(request);
    final defaults = request.nativeDefaults;
    final options = channel?.protocolOptions as ArkImageOptions?;
    final references = <String>[];
    for (final image in request.references) {
      references.add(await imageInputAsUrlOrDataUri(image, outputs));
    }
    final data = await postImageJson(
      Uri.parse(
        '${config.effectiveBaseUrl.replaceFirst(RegExp(r'/+$'), '')}/images/generations',
      ),
      {
        'model': request.model,
        'prompt': request.prompt,
        'size': ?(request.size ?? defaults.size),
        'response_format': ?defaults.responseFormat,
        'output_format': ?defaults.outputFormat,
        'watermark': ?defaults.watermark,
        if (references.isNotEmpty) 'image': references,
        if (options?.requiresSequentialDisabled ?? false)
          'sequential_image_generation': 'disabled',
        if (defaults.promptOptimization != null)
          'optimize_prompt_options': {'mode': defaults.promptOptimization},
      },
    );
    return parseImageResponse(
      data,
      outputs,
      emptyMessage: tr(LocaleKeys.aiImageNoResult),
    );
  }
}

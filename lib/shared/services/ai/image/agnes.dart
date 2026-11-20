// 职责: 将图片请求编码为 Agnes images/generations 协议并解析回执。
// 关联文件:
//   lib/shared/services/ai/image/client.dart
//   lib/shared/models/image/channels.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';

import '../../../models/ai_provider.dart';
import '../../../localization/locale_keys.dart';
import '../../../models/image/channels.dart';
import '../image.dart';
import 'client.dart';

class AgnesImageClient extends ImageClient {
  AgnesImageClient(super.config);

  @override
  Future<ProviderSubmitResult> submit(
    SubmitImageInput request,
    ImageOutputContext outputs,
  ) async {
    final channel = validatedChannel(request);
    final Map<String, String> sizeParameters;
    try {
      sizeParameters = agnesSizeParameters(channel, request.size);
    } on FormatException {
      throw AiImageGenerationException(
        imageErrorMessage(AiImageErrorCode.size),
        code: AiImageErrorCode.size,
      );
    }
    final apiKey = requireApiKey();
    final references = <String>[];
    for (final input in request.references) {
      references.add(await imageInputAsUrlOrDataUri(input, outputs));
    }
    final baseUrl = config.effectiveBaseUrl.replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.parse('$baseUrl/images/generations');
    final dio = newImageDio();
    try {
      final response = await dio.post<Map<String, dynamic>>(
        uri.toString(),
        data: {
          'model': request.model,
          'prompt': request.prompt,
          ...sizeParameters,
          'extra_body': {
            'response_format': ?request.nativeDefaults.responseFormat,
            if (references.isNotEmpty) 'image': references,
          },
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          validateStatus: (_) => true,
        ),
        onReceiveProgress: receiveProgressLogger(uri, 'agnes'),
      );
      logImageHttpResponse(
        uri,
        response.statusCode,
        response.headers,
        response.data,
      );
      throwForImageHttpFailure(
        uri: uri,
        statusCode: response.statusCode,
        data: response.data,
        providerId: config.id,
      );
      return await parseImageResponse(
        response.data ?? {},
        outputs,
        emptyMessage: tr(LocaleKeys.aiImageNoResult),
      );
    } finally {
      dio.close();
    }
  }
}

/// Agnes 的尺寸参数：分档型号把像素尺寸还原为「档位 + 比例」，其余按像素发送。
/// 未登记型号原样发送请求的尺寸。
Map<String, String> agnesSizeParameters(
  ImageChannelModel? channel,
  String? requestedSize,
) {
  final value = requestedSize;
  if (value == null) {
    return {};
  }
  if (channel == null) {
    return {'size': value};
  }
  final caps = channel.capabilities;
  final options = channel.protocolOptions as AgnesImageOptions?;
  if (options?.sizeTiersWithRatio ?? false) {
    if (caps.resolutions.contains(value)) {
      return {'size': value};
    }
    for (final tier in caps.sizes.entries) {
      for (final ratio in tier.value.entries) {
        if (ratio.value == value) {
          return {'size': tier.key, 'ratio': ratio.key};
        }
      }
    }
  }
  caps.validateSize(value);
  if (!RegExp(r'^[1-9][0-9]*x[1-9][0-9]*$').hasMatch(value)) {
    throw const FormatException('Unsupported image size');
  }
  return {'size': value};
}

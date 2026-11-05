// 职责: 通过 Codex 账号的图片工具生成或编辑图片，并把 Codex 鉴权与工具错误映射为图片错误分类。
// 关联文件:
//   lib/shared/services/ai/image/client.dart
//   lib/shared/services/ai/codex/image_client.dart
//   lib/shared/services/ai/codex/credentials.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart' as http;

import '../../../models/ai_provider.dart';
import '../../../localization/locale_keys.dart';
import '../codex/credentials.dart';
import '../codex/image_client.dart';
import '../image.dart';
import 'client.dart';

class CodexImageGenerationClient extends ImageClient {
  CodexImageGenerationClient(super.config, {this.clientFactory});
  final CodexImageClient Function()? clientFactory;

  @override
  Future<AiImageGenerationResult> generate(
    ImageGenerationRequest request,
  ) async {
    try {
      if (!CodexCredentials.supportedPlatform) {
        throw const CodexAuthException(CodexAuthFailure.unsupported_platform);
      }
      final references = <String>[];
      for (final input in request.images) {
        final normalized = await imageInputAsDataUri(input);
        final data = UriData.parse(normalized);
        final prepared = await prepareMultipartReference(
          data.contentAsBytes(),
          data.mimeType == 'image/jpeg' ? 'jpg' : 'png',
        );
        final mime = imageMimeFromBytes(prepared.bytes);
        references.add(
          'data:image/$mime;base64,${base64Encode(prepared.bytes)}',
        );
      }
      final client =
          clientFactory?.call() ??
          CodexImageClient(client: config.createProxyClient() ?? http.Client());
      final response = await client.generate(
        prompt: request.prompt,
        imageModel: request.model,
        chatModels: config.availableModels,
        referenceImages: references,
        size: request.size,
        quality: request.quality,
        complexity: request.complexity,
      );
      return await parseImageResponse(
        response,
        emptyMessage: tr(LocaleKeys.aiImageNoResult),
      );
    } on CodexAuthException catch (error) {
      throw AiImageGenerationException(
        tr(LocaleKeys.aiCodexImageAuthFailed),
        code: AiImageErrorCode.auth,
        debugMessage: error.toString(),
      );
    } on CodexImageException catch (error) {
      final code =
          imageErrorCodeFromStatus(error.statusCode, null) ??
          switch (error.code) {
            'content_policy_violation' ||
            'moderation_blocked' => AiImageErrorCode.moderation,
            'rate_limit_exceeded' => AiImageErrorCode.rate_limit,
            'insufficient_quota' => AiImageErrorCode.credit,
            'invalid_api_key' => AiImageErrorCode.auth,
            'invalid_model' || 'model_not_found' => AiImageErrorCode.param,
            _ => imageErrorCodeFromStatus(error.statusCode, error.code),
          };
      final key = error.reason == 'no_chat_models'
          ? LocaleKeys.aiCodexImageNeedsChatModel
          : code == AiImageErrorCode.auth
          ? LocaleKeys.aiCodexImageAuthFailed
          : error.reason == 'no_image'
          ? LocaleKeys.aiImageNoResult
          : LocaleKeys.aiImageGenerationFailed;
      throw AiImageGenerationException(
        error.providerMessage ??
            (code != null && code != AiImageErrorCode.auth
                ? imageErrorMessage(code)
                : tr(key)),
        code: code,
        debugMessage: error.toString(),
      );
    }
  }
}

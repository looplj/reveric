// 职责: 提供 AI 供应商的本地化名称与类型说明，未知供应商保留用户名称。
// 关联文件:
//   lib/shared/models/ai_provider.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/zh-CN/provider.json
// 遵循的 Rules:
//   .agents/rules/i18n.md

import 'package:flutter/widgets.dart';

import '../models/ai_provider.dart';
import 'app_localization.dart';
import 'locale_keys.dart';

String localizedAiProviderName(BuildContext context, AiProvider provider) {
  return localizedBuiltinAiProviderName(
    context,
    provider.id,
    fallbackName: provider.displayName,
  );
}

String localizedBuiltinAiProviderName(
  BuildContext context,
  String providerId, {
  required String fallbackName,
}) {
  final key = switch (providerId) {
    'metaso' => LocaleKeys.settingsBuiltinProviderMetaso,
    'purefox' => LocaleKeys.settingsBuiltinProviderPurefox,
    'purefox_media' => LocaleKeys.settingsBuiltinProviderPurefoxMedia,
    'deepseek' => LocaleKeys.settingsBuiltinProviderDeepseek,
    'doubao' => LocaleKeys.settingsBuiltinProviderDoubao,
    'moonshot' => LocaleKeys.settingsBuiltinProviderMoonshot,
    'zhipu' => LocaleKeys.settingsBuiltinProviderZhipu,
    'openai' => LocaleKeys.settingsBuiltinProviderOpenai,
    'gemini' => LocaleKeys.settingsBuiltinProviderGemini,
    'anthropic' => LocaleKeys.settingsBuiltinProviderAnthropic,
    'xai' => LocaleKeys.settingsBuiltinProviderXai,
    'qwen' => LocaleKeys.settingsBuiltinProviderQwen,
    'ark' => LocaleKeys.settingsBuiltinProviderArk,
    'debug_deepseek_partial_tool' =>
      LocaleKeys.settingsDebugProviderDeepseekPartialTool,
    'debug_deepseek_truncated' =>
      LocaleKeys.settingsDebugProviderDeepseekTruncated,
    'debug_openai_responses_partial_tool' =>
      LocaleKeys.settingsDebugProviderOpenaiResponsesPartialTool,
    'debug_openai_responses_thinking_only' =>
      LocaleKeys.settingsDebugProviderOpenaiResponsesThinkingOnly,
    _ => null,
  };
  return key == null ? fallbackName : context.t(key);
}

String localizedProviderTypeDescription(
  BuildContext context,
  AiProviderType type,
) {
  final key = switch (type) {
    AiProviderType.openai => LocaleKeys.providerDescriptionOpenai,
    AiProviderType.codex => LocaleKeys.providerDescriptionCodex,
    AiProviderType.openai_compatible =>
      LocaleKeys.providerDescriptionOpenaiCompatible,
    AiProviderType.api88 => LocaleKeys.providerDescriptionApi88,
    AiProviderType.apikey => LocaleKeys.providerDescriptionApikey,
    AiProviderType.infistar => LocaleKeys.providerDescriptionInfistar,
    AiProviderType.ooki => LocaleKeys.providerDescriptionOoki,
    AiProviderType.openrouter => LocaleKeys.providerDescriptionOpenrouter,
    AiProviderType.xai => LocaleKeys.providerDescriptionXai,
    AiProviderType.anthropic => LocaleKeys.providerDescriptionAnthropic,
    AiProviderType.qwen => LocaleKeys.providerDescriptionQwen,
    AiProviderType.qwen_token_plan =>
      LocaleKeys.providerDescriptionQwenTokenPlan,
    AiProviderType.gemini => LocaleKeys.providerDescriptionGemini,
    AiProviderType.deepseek => LocaleKeys.providerDescriptionDeepseek,
    AiProviderType.moonshot => LocaleKeys.providerDescriptionMoonshot,
    AiProviderType.zhipu => LocaleKeys.providerDescriptionZhipu,
    AiProviderType.doubao => LocaleKeys.providerDescriptionDoubao,
    AiProviderType.volcengine => LocaleKeys.providerDescriptionVolcengine,
    AiProviderType.metaso => LocaleKeys.providerDescriptionMetaso,
    AiProviderType.minimax => LocaleKeys.providerDescriptionMinimax,
    AiProviderType.moss => LocaleKeys.providerDescriptionMoss,
    AiProviderType.agnes => LocaleKeys.providerDescriptionAgnes,
    AiProviderType.atlascloud => LocaleKeys.providerDescriptionAtlascloud,
    AiProviderType.purefox => LocaleKeys.providerDescriptionPurefox,
    AiProviderType.purefox_media => LocaleKeys.providerDescriptionPurefoxMedia,
  };
  return context.t(key);
}

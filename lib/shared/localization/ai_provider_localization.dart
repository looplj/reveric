// 职责: 提供 AI 供应商的本地化名称与类型说明，未知供应商保留用户名称。
// 关联文件:
//   lib/shared/models/ai_provider.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
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
    AiProviderType.openai => LocaleKeys.settingsProviderDescriptionOpenai,
    AiProviderType.codex => LocaleKeys.settingsProviderDescriptionCodex,
    AiProviderType.openai_compatible =>
      LocaleKeys.settingsProviderDescriptionOpenaiCompatible,
    AiProviderType.api88 => LocaleKeys.settingsProviderDescriptionApi88,
    AiProviderType.ooki => LocaleKeys.settingsProviderDescriptionOoki,
    AiProviderType.openrouter =>
      LocaleKeys.settingsProviderDescriptionOpenrouter,
    AiProviderType.xai => LocaleKeys.settingsProviderDescriptionXai,
    AiProviderType.anthropic => LocaleKeys.settingsProviderDescriptionAnthropic,
    AiProviderType.qwen => LocaleKeys.settingsProviderDescriptionQwen,
    AiProviderType.qwen_token_plan =>
      LocaleKeys.settingsProviderDescriptionQwenTokenPlan,
    AiProviderType.gemini => LocaleKeys.settingsProviderDescriptionGemini,
    AiProviderType.deepseek => LocaleKeys.settingsProviderDescriptionDeepseek,
    AiProviderType.moonshot => LocaleKeys.settingsProviderDescriptionMoonshot,
    AiProviderType.zhipu => LocaleKeys.settingsProviderDescriptionZhipu,
    AiProviderType.doubao => LocaleKeys.settingsProviderDescriptionDoubao,
    AiProviderType.volcengine =>
      LocaleKeys.settingsProviderDescriptionVolcengine,
    AiProviderType.metaso => LocaleKeys.settingsProviderDescriptionMetaso,
    AiProviderType.minimax => LocaleKeys.settingsProviderDescriptionMinimax,
    AiProviderType.agnes => LocaleKeys.settingsProviderDescriptionAgnes,
    AiProviderType.atlascloud =>
      LocaleKeys.settingsProviderDescriptionAtlascloud,
  };
  return context.t(key);
}

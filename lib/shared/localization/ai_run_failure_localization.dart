// 职责: 将 AI 失败映射为展示文案：已识别的专用文案优先，其次供应商原文，最后泛化提示。
// 关联文件:
//   lib/shared/models/ai_run_failure.dart
//   lib/shared/localization/ark_error_localization.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json

import '../models/ai_run_failure.dart';
import '../utils/ai_error.dart';
import 'ark_error_localization.dart';
import 'locale_keys.dart';

/// [preferProviderMessage] 为 false 时跳过供应商原文，只返回本地化文案（媒体客户端用来取 key）。
String localizeAiRunFailure(
  AiRunFailure failure,
  String Function(String key) t, {
  bool preferProviderMessage = true,
}) {
  // 识别出专用文案时优先于原文；否则原文比错误族、状态码的泛化提示具体。
  final recognized = recognizedAiRunFailureKey(failure);
  if (recognized != null) {
    return t(recognized);
  }
  if (preferProviderMessage) {
    final message = tryReadProviderMessage(failure.providerMessage ?? '');
    if (message != null) {
      return message;
    }
  }
  if (_isProviderFailure(failure)) {
    final family = arkErrorFamilyLocaleKey(failure.providerCode);
    if (family != null) {
      return t(family);
    }
  }
  final key = switch (failure.kind) {
    AiRunFailureKind.http => _httpFailureLocaleKey(failure),
    AiRunFailureKind.network => LocaleKeys.aiNetworkError,
    AiRunFailureKind.streamInterrupted => LocaleKeys.aiStreamInterrupted,
    AiRunFailureKind.contextWindowExhausted =>
      LocaleKeys.aiContextWindowExhausted,
    AiRunFailureKind.incompleteResponse => LocaleKeys.aiIncompleteResponse,
    AiRunFailureKind.invalid_conversation_history =>
      LocaleKeys.aiChatHistoryInvalid,
    AiRunFailureKind.requestFailed => LocaleKeys.aiRequestFailed,
  };
  return t(key);
}

/// 将插件或上游返回的可读错误拆解为专用本地化 key 或可透传的原文。
({String? messageKey, String? providerMessage}) resolveProviderFailureMessage({
  String? code,
  String? message,
}) {
  final rawMessage = message == null ? null : tryReadProviderMessage(message);
  if (rawMessage == null) {
    return (messageKey: null, providerMessage: null);
  }
  final recognized = recognizedAiRunFailureKey(
    AiRunFailure.requestFailed(providerMessage: rawMessage, providerCode: code),
  );
  return (
    messageKey: recognized,
    providerMessage: recognized == null ? rawMessage : null,
  );
}

/// 按精确错误码或消息规则识别出的专用文案 key。错误族前缀和 HTTP 状态码只给
/// 泛化原因，不算识别，返回 null，界面应优先展示供应商原文。
String? recognizedAiRunFailureKey(AiRunFailure failure) {
  // 已在本地判定为上下文耗尽时，比供应商的笼统拒绝原因更具体。
  if (failure.kind == AiRunFailureKind.contextWindowExhausted) {
    return LocaleKeys.aiContextWindowExhausted;
  }
  if (!_isProviderFailure(failure)) {
    return null;
  }
  final codeKey = arkErrorLocaleKey(
    failure.providerCode,
    failure.providerMessage,
  );
  // 通用参数码没有消息中的上下文长度等具体原因精确。
  return failure.providerCode?.trim().toLowerCase() == 'invalidparameter'
      ? _providerMessageLocaleKey(failure) ?? codeKey
      : codeKey ?? _providerMessageLocaleKey(failure);
}

// 本地化兜底只对 provider 失败匹配错误码；本地/流终态保留专用说明。
bool _isProviderFailure(AiRunFailure failure) =>
    failure.kind == AiRunFailureKind.http ||
    failure.kind == AiRunFailureKind.streamInterrupted ||
    failure.kind == AiRunFailureKind.requestFailed;

String? _providerMessageLocaleKey(AiRunFailure failure) {
  final message = failure.providerMessage?.trim().toLowerCase();
  if (message == null || message.isEmpty) {
    return null;
  }
  // 供应商余额错误使用明确文案；一般 quota 错误仍交给后面的规则。
  if (message.contains('insufficient credit') ||
      message.contains('credit.insufficient')) {
    return LocaleKeys.aiProviderPaymentRequired;
  }
  for (final (pattern, key) in _providerMessageRules) {
    if (pattern.hasMatch(message)) {
      return key;
    }
  }
  return null;
}

// 顺序具有语义：模型不存在/无权访问的歧义先于明确不存在；
// 上游渠道凭证耗尽先于用户 API Key 错误。规则只输出固定 key，不回显原文。
final _providerMessageRules = <(RegExp, String)>[
  (
    RegExp(r'\bmodel forbidden for user\b|\bmodel\.forbidden\b'),
    LocaleKeys.aiModelForbiddenForUser,
  ),
  (
    RegExp(
      r'\bmodel\b[^\n]{0,160}\bdoes not exist or you do not have access\b|\bdo not have access to (?:the |this )?model\b',
    ),
    LocaleKeys.aiModelMissingOrDenied,
  ),
  (
    RegExp(
      r'\bmodel not found\b|\bmodel_not_found\b|\bmodel\b[^\n]{0,120}\bdoes not exist\b',
    ),
    LocaleKeys.aiModelNotFound,
  ),
  (
    RegExp(r'\bmodel\b[^\n]{0,160}\breached its end of life\b'),
    LocaleKeys.aiModelRetired,
  ),
  (RegExp(r'\bfree promotion has ended\b'), LocaleKeys.aiModelPromotionEnded),
  (
    RegExp(
      r'\bmodel\b[^\n]{0,100}\bis not supported\b|\bmodel\b[^\n]{0,100}\bdoes not support\b|\bthe supported api model names are\b|\bmodel id\b[^\n]{0,160}\bhas no provider supported\b|模型不支持',
    ),
    LocaleKeys.aiModelUnsupported,
  ),
  (
    RegExp(r'\bmodel is unavailable\b'),
    LocaleKeys.aiModelTemporarilyUnavailable,
  ),
  (
    RegExp(
      r'\bmaximum context length\b|\bexceeded model token limit\b|\bprompt is too long\b|\bcontext_length_exceeded\b|\binput token count exceeds the maximum number of tokens allowed\b',
    ),
    LocaleKeys.aiContextWindowExhausted,
  ),
  (
    RegExp(
      r'\bunsupported parameter\b|\binvalid temperature\b|\brange of max_tokens\b|\blevel [^\n]{1,40}not supported, valid levels\b',
    ),
    LocaleKeys.aiRequestParameterUnsupported,
  ),
  (RegExp(r'请打开流式传输'), LocaleKeys.aiStreamingRequired),
  (
    RegExp(r'\bthinking mode must be passed back to the api\b'),
    LocaleKeys.aiThinkingHistoryRequired,
  ),
  (
    RegExp(
      r'\binputimagesensitivecontentdetected\.privacyinformation\b|\binput image\b[^\n]{0,160}\bmay contain real person\b',
    ),
    LocaleKeys.aiInputImagePrivacyRejected,
  ),
  (
    RegExp(
      r'\bgenerated (?:video|image|audio)\b[^\n]{0,80}\bcopyright restrictions\b',
    ),
    LocaleKeys.aiOutputCopyrightRejected,
  ),
  (
    RegExp(
      r'\bsensitive content detected\b|\bsensitive_words_detected\b|\binput may contain sensitive information\b',
    ),
    LocaleKeys.aiContentRejected,
  ),
  (
    RegExp(
      r'\bno available channel\b|无可用渠道|\bno available accounts\b|\bno active api keys available for this group\b|\bno credentials available\b',
    ),
    LocaleKeys.aiProviderChannelUnavailable,
  ),
  (
    RegExp(r'\binsufficient (?:account )?balance\b|预扣费额度失败'),
    LocaleKeys.aiProviderPaymentRequired,
  ),
  (
    RegExp(
      r'\binsufficient_quota\b|\bexceeded your current quota\b|\bbudget pool quota has been exhausted\b|\buser quota is insufficient\b|用户额度不足',
    ),
    LocaleKeys.aiProviderQuotaExceeded,
  ),
  (
    RegExp(
      r'\bconcurrency limit exceeded\b|\brequest queue is full\b|\bsystem protection triggered by request burst\b',
    ),
    LocaleKeys.aiRateLimited,
  ),
  (
    RegExp(r'\bapi key is disabled\b|\bapi key not valid\b'),
    LocaleKeys.aiApiKeyInvalid,
  ),
  (
    RegExp(r'\bservice temporarily overloaded\b'),
    LocaleKeys.aiServiceOverloaded,
  ),
  (
    RegExp(r'\bstream first event timeout\b|\btls handshake timeout\b'),
    LocaleKeys.aiRequestTimeout,
  ),
  (
    RegExp(
      r'\bgetaddrinfo enotfound\b|\ball connection attempts failed\b|\bunexpected_eof_while_reading\b',
    ),
    LocaleKeys.aiProviderConnectionFailed,
  ),
];

String _httpFailureLocaleKey(AiRunFailure failure) {
  return switch (failure.statusCode) {
    400 || 412 || 422 => LocaleKeys.aiBadRequest,
    401 => LocaleKeys.aiApiKeyInvalid,
    402 => LocaleKeys.aiProviderPaymentRequired,
    403 => LocaleKeys.aiAccessDenied,
    404 => LocaleKeys.aiNotFound,
    408 => LocaleKeys.aiRequestTimeout,
    410 => LocaleKeys.aiResourceGone,
    413 => LocaleKeys.aiRequestTooLarge,
    429 => LocaleKeys.aiRateLimited,
    500 => LocaleKeys.aiProviderServerError,
    502 || 503 => LocaleKeys.aiServiceOverloaded,
    504 => LocaleKeys.aiProviderGatewayTimeout,
    _ => LocaleKeys.aiRequestFailed,
  };
}

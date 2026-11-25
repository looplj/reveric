// 职责: 按火山方舟推理错误码选择用户可操作的提示，区分审核、配置、额度与服务故障。
// 关联文件:
//   lib/shared/localization/ai_run_failure_localization.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json

import 'locale_keys.dart';

/// 错误码来源：https://docs.volcengine.com/docs/ark/error-codes?lang=zh
/// 只匹配精确错误码；错误族的泛化提示见 [arkErrorFamilyLocaleKey]。
String? arkErrorLocaleKey(String? providerCode, String? message) {
  final code = providerCode?.trim().toLowerCase();
  if (code == null || code.isEmpty) {
    return null;
  }
  final exact = _codes[code];
  if (exact != null) {
    return exact;
  }
  if (code == 'quotaexceeded') {
    final detail = message?.toLowerCase() ?? '';
    if (detail.contains('free trial quota')) {
      return LocaleKeys.aiProviderTrialQuotaExhausted;
    }
    return LocaleKeys.aiProviderLimitExceeded;
  }
  return null;
}

/// 只按错误码族前缀兜底得到的泛化提示；命中精确错误码时返回 null。
String? arkErrorFamilyLocaleKey(String? providerCode) {
  final code = providerCode?.trim().toLowerCase();
  if (code == null || code.isEmpty || _codes.containsKey(code)) {
    return null;
  }
  for (final (prefix, key) in _families) {
    if (code == prefix || code.startsWith('$prefix.')) {
      return key;
    }
  }
  return null;
}

const _codes = <String, String>{
  'inputimagesensitivecontentdetected.privacyinformation':
      LocaleKeys.aiInputImagePrivacyRejected,
  'inputvideosensitivecontentdetected.privacyinformation':
      LocaleKeys.aiInputVideoPrivacyRejected,
  'inputtextsensitivecontentdetected.policyviolation':
      LocaleKeys.aiInputCopyrightRejected,
  'inputimagesensitivecontentdetected.policyviolation':
      LocaleKeys.aiInputCopyrightRejected,
  'inputvideosensitivecontentdetected.policyviolation':
      LocaleKeys.aiInputCopyrightRejected,
  'inputaudiosensitivecontentdetected.policyviolation':
      LocaleKeys.aiInputCopyrightRejected,
  'outputvideosensitivecontentdetected.policyviolation':
      LocaleKeys.aiOutputCopyrightRejected,
  'outputaudiosensitivecontentdetected.policyviolation':
      LocaleKeys.aiOutputCopyrightRejected,
  'outputimagesensitivecontentdetected.deepfake':
      LocaleKeys.aiOutputImageForgeryRejected,
  'inputtextriskdetection': LocaleKeys.aiContentRejected,
  'inputimageriskdetection': LocaleKeys.aiInputImageRejected,
  'outputtextriskdetection': LocaleKeys.aiOutputContentRejected,
  'outputimageriskdetection': LocaleKeys.aiOutputContentRejected,
  'contentsecuritydetectionerror': LocaleKeys.aiContentReviewUnavailable,
  'invalidparameter.tasktypeconstraint': LocaleKeys.aiTaskTypeMismatch,
  'invalidparameter.tasktypemismatch': LocaleKeys.aiTaskTypeMismatch,
  'invalidparameter.tosurlinvalid': LocaleKeys.aiRequestParameterUnsupported,
  'outofcontexterror': LocaleKeys.aiContextWindowExhausted,
  'invalidendpoint.closedendpoint': LocaleKeys.aiProviderEndpointUnavailable,
  'authenticationerror': LocaleKeys.aiApiKeyInvalid,
  'invalidaccountstatus': LocaleKeys.aiProviderAccountRestricted,
  'operationdenied.servicenotopen': LocaleKeys.aiModelNotActivated,
  'modelnotopen': LocaleKeys.aiModelNotActivated,
  'operationdenied.serviceoverdue': LocaleKeys.aiProviderPaymentRequired,
  'accountoverdueerror': LocaleKeys.aiProviderPaymentRequired,
  'accessdenied': LocaleKeys.aiAccessDenied,
  'operationdenied.permissiondenied': LocaleKeys.aiAccessDenied,
  'operationdenied.arkaccessrolenotfound': LocaleKeys.aiAccessDenied,
  'operationdenied.tosaccessdenied': LocaleKeys.aiAccessDenied,
  'operationdenied.invalidstate': LocaleKeys.aiProviderResourceNotReady,
  'operationdenied.unsupportedphase': LocaleKeys.aiProviderResourceNotReady,
  'operationdenied.filequotaexceeded': LocaleKeys.aiProviderFileQuotaExceeded,
  'invalidendpointormodel.notfound': LocaleKeys.aiModelMissingOrDenied,
  'invalidendpointormodel.modelidaccessdisabled':
      LocaleKeys.aiModelEndpointRequired,
  'unsupportedmodel': LocaleKeys.aiModelUnsupported,
  'serveroverloaded': LocaleKeys.aiServiceOverloaded,
  'requestbursttoofast': LocaleKeys.aiRateLimited,
  'modelaccountrpmratelimitexceeded': LocaleKeys.aiRateLimited,
  'modelaccounttpmratelimitexceeded': LocaleKeys.aiRateLimited,
  'modelaccountflextpmratelimitexceeded': LocaleKeys.aiRateLimited,
  'modelaccountipmratelimitexceeded': LocaleKeys.aiRateLimited,
  'apiaccountrpmratelimitexceeded': LocaleKeys.aiRateLimited,
  'accountratelimitexceeded': LocaleKeys.aiRateLimited,
  'inflightbatchsizeexceeded': LocaleKeys.aiRateLimited,
  'setlimitexceeded': LocaleKeys.aiProviderUsageLimitReached,
};

const _families = <(String, String)>[
  ('internalserviceerror', LocaleKeys.aiProviderServerError),
  ('sensitivecontentdetected', LocaleKeys.aiContentRejected),
  ('inputtextsensitivecontentdetected', LocaleKeys.aiContentRejected),
  ('inputimagesensitivecontentdetected', LocaleKeys.aiInputImageRejected),
  ('inputvideosensitivecontentdetected', LocaleKeys.aiInputVideoRejected),
  ('inputaudiosensitivecontentdetected', LocaleKeys.aiInputAudioRejected),
  ('outputtextsensitivecontentdetected', LocaleKeys.aiOutputContentRejected),
  ('outputimagesensitivecontentdetected', LocaleKeys.aiOutputContentRejected),
  ('outputvideosensitivecontentdetected', LocaleKeys.aiOutputContentRejected),
  ('outputaudiosensitivecontentdetected', LocaleKeys.aiOutputContentRejected),
  ('missingparameter', LocaleKeys.aiMissingRequestParameter),
  ('invalidparameter', LocaleKeys.aiRequestParameterUnsupported),
  ('invalidargumenterror', LocaleKeys.aiRequestParameterUnsupported),
  ('invalidimageurl', LocaleKeys.aiInputImageInvalid),
  ('ratelimitexceeded', LocaleKeys.aiRateLimited),
  ('quotaexceeded', LocaleKeys.aiProviderLimitExceeded),
  ('notfound', LocaleKeys.aiNotFound),
];

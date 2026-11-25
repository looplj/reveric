// 职责: 验证火山推理错误码按原因映射，避免把审核、额度和服务故障混为一类。
// 关联文件:
//   lib/shared/localization/ark_error_localization.dart
//   lib/shared/localization/ai_run_failure_localization.dart
//   lib/shared/models/ai_run_failure.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/localization/ai_run_failure_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/ai_run_failure.dart';

void main() {
  const cases = <(String, String)>[
    ('MissingParameter', LocaleKeys.aiMissingRequestParameter),
    (
      'InvalidParameter.UnsupportedParameter',
      LocaleKeys.aiRequestParameterUnsupported,
    ),
    ('InvalidParameter.TaskTypeConstraint', LocaleKeys.aiTaskTypeMismatch),
    ('InvalidParameter.TaskTypeMismatch', LocaleKeys.aiTaskTypeMismatch),
    (
      'InvalidArgumentError.InvalidPixelLimit',
      LocaleKeys.aiRequestParameterUnsupported,
    ),
    ('InvalidImageURL.InvalidFormat', LocaleKeys.aiInputImageInvalid),
    ('OutofContextError', LocaleKeys.aiContextWindowExhausted),
    (
      'InputImageSensitiveContentDetected.PrivacyInformation',
      LocaleKeys.aiInputImagePrivacyRejected,
    ),
    (
      'InputVideoSensitiveContentDetected.PrivacyInformation',
      LocaleKeys.aiInputVideoPrivacyRejected,
    ),
    ('SensitiveContentDetected.Violence', LocaleKeys.aiContentRejected),
    ('InputImageSensitiveContentDetected', LocaleKeys.aiInputImageRejected),
    ('InputVideoSensitiveContentDetected', LocaleKeys.aiInputVideoRejected),
    ('InputAudioSensitiveContentDetected', LocaleKeys.aiInputAudioRejected),
    (
      'InputTextSensitiveContentDetected.PolicyViolation',
      LocaleKeys.aiInputCopyrightRejected,
    ),
    (
      'OutputVideoSensitiveContentDetected.PolicyViolation',
      LocaleKeys.aiOutputCopyrightRejected,
    ),
    (
      'OutputImageSensitiveContentDetected.DeepFake',
      LocaleKeys.aiOutputImageForgeryRejected,
    ),
    ('OutputAudioSensitiveContentDetected', LocaleKeys.aiOutputContentRejected),
    ('InputImageRiskDetection', LocaleKeys.aiInputImageRejected),
    ('OutputTextRiskDetection', LocaleKeys.aiOutputContentRejected),
    ('ContentSecurityDetectionError', LocaleKeys.aiContentReviewUnavailable),
    (
      'InvalidEndpoint.ClosedEndpoint',
      LocaleKeys.aiProviderEndpointUnavailable,
    ),
    ('AuthenticationError', LocaleKeys.aiApiKeyInvalid),
    ('InvalidAccountStatus', LocaleKeys.aiProviderAccountRestricted),
    ('ModelNotOpen', LocaleKeys.aiModelNotActivated),
    ('OperationDenied.ServiceNotOpen', LocaleKeys.aiModelNotActivated),
    ('OperationDenied.ServiceOverdue', LocaleKeys.aiProviderPaymentRequired),
    ('AccountOverdueError', LocaleKeys.aiProviderPaymentRequired),
    (
      'OperationDenied.FileQuotaExceeded',
      LocaleKeys.aiProviderFileQuotaExceeded,
    ),
    ('OperationDenied.InvalidState', LocaleKeys.aiProviderResourceNotReady),
    ('OperationDenied.TosAccessDenied', LocaleKeys.aiAccessDenied),
    ('InvalidEndpointOrModel.NotFound', LocaleKeys.aiModelMissingOrDenied),
    (
      'InvalidEndpointOrModel.ModelIDAccessDisabled',
      LocaleKeys.aiModelEndpointRequired,
    ),
    ('RateLimitExceeded.EndpointRPMExceeded', LocaleKeys.aiRateLimited),
    ('ModelAccountTpmRateLimitExceeded', LocaleKeys.aiRateLimited),
    ('InflightBatchsizeExceeded', LocaleKeys.aiRateLimited),
    ('ServerOverloaded', LocaleKeys.aiServiceOverloaded),
    ('SetLimitExceeded', LocaleKeys.aiProviderUsageLimitReached),
    ('QuotaExceeded', LocaleKeys.aiProviderLimitExceeded),
    ('InternalServiceError', LocaleKeys.aiProviderServerError),
  ];
  for (final (code, expected) in cases) {
    test(
      '$code retains its meaning behind a gateway and after persistence',
      () {
        final failure = AiRunFailure.fromJson(
          AiRunFailure.http(
            statusCode: 400,
            providerId: 'openrouter',
            providerCode: code,
            providerMessage: 'Unknown error',
          ).toJson(),
        );
        expect(localizeAiRunFailure(failure, (key) => key), expected);
        expect(
          localizeAiRunFailure(
            AiRunFailure.requestFailed(providerCode: code),
            (key) => key,
          ),
          expected,
        );
      },
    );
  }
  test('quota without evidence does not imply an empty balance', () {
    for (final message in [
      'Task queue limit reached',
      'The request has exceeded the quota.',
      null,
    ]) {
      expect(
        localizeAiRunFailure(
          AiRunFailure.http(
            statusCode: 429,
            providerCode: 'QuotaExceeded',
            providerMessage: message,
          ),
          (key) => key,
          preferProviderMessage: false,
        ),
        LocaleKeys.aiProviderLimitExceeded,
      );
    }
    expect(
      localizeAiRunFailure(
        const AiRunFailure.http(
          statusCode: 429,
          providerCode: 'QuotaExceeded',
          providerMessage: 'Your account has exhausted its free trial quota.',
        ),
        (key) => key,
        preferProviderMessage: false,
      ),
      LocaleKeys.aiProviderTrialQuotaExhausted,
    );
  });
  test(
    'specific code wins over message; generic parameter code keeps detail',
    () {
      expect(
        localizeAiRunFailure(
          const AiRunFailure.http(
            statusCode: 403,
            providerCode: 'OperationDenied.ServiceOverdue',
            providerMessage: 'API key not valid',
          ),
          (key) => key,
          preferProviderMessage: false,
        ),
        LocaleKeys.aiProviderPaymentRequired,
      );
      expect(
        localizeAiRunFailure(
          const AiRunFailure.http(
            statusCode: 400,
            providerCode: 'InvalidParameter',
            providerMessage: 'maximum context length exceeded',
          ),
          (key) => key,
          preferProviderMessage: false,
        ),
        LocaleKeys.aiContextWindowExhausted,
      );
    },
  );
  test('unknown codes and explicit local failures preserve the fallback', () {
    for (final code in [
      'UnknownNewCode',
      'NotFoundSomething',
      'InputImageSensitiveContentDetectedTypo',
    ]) {
      expect(
        localizeAiRunFailure(
          AiRunFailure.http(statusCode: 401, providerCode: code),
          (key) => key,
        ),
        LocaleKeys.aiApiKeyInvalid,
      );
    }
    expect(
      localizeAiRunFailure(
        const AiRunFailure(
          kind: AiRunFailureKind.network,
          providerCode: 'AuthenticationError',
        ),
        (key) => key,
      ),
      LocaleKeys.aiNetworkError,
    );
  });
  test('mapped hints exist in both shipping locales', () {
    for (final locale in ['en', 'zh-CN']) {
      final translations =
          jsonDecode(
                File('assets/translations/$locale/ai.json').readAsStringSync(),
              )
              as Map;
      for (final (_, key) in cases) {
        expect(translations[key], isNotEmpty, reason: '$locale $key');
      }
    }
  });
}

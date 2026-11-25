// 职责: 验证 AI 错误按真实服务商消息优先映射安全文案，并保留状态码和终态兜底。
// 关联文件:
//   lib/shared/models/ai_run_failure.dart
//   lib/shared/localization/ai_run_failure_localization.dart
//   lib/shared/localization/locale_keys.dart

import 'package:reveric/shared/utils/ai_error.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/localization/ai_run_failure_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/ai_run_failure.dart';

void main() {
  String identity(String key) => key;

  test(
    'all AI failure kinds show provider message verbatim without translation',
    () {
      const message =
          'Unsupported audio=false; api_key=example-secret\nhttps://provider.test/help?q=1';
      for (final kind in AiRunFailureKind.values) {
        if (kind == AiRunFailureKind.contextWindowExhausted) {
          continue;
        }
        expect(
          localizeAiRunFailure(
            AiRunFailure(kind: kind, providerMessage: message),
            (_) => throw StateError('Provider messages must not be translated'),
          ),
          message,
        );
      }
    },
  );
  test('recognized codes and messages win over the provider message', () {
    expect(
      localizeAiRunFailure(
        const AiRunFailure.http(
          statusCode: 400,
          providerCode: 'InputImageSensitiveContentDetected.PrivacyInformation',
          providerMessage: 'Request failed',
        ),
        identity,
      ),
      LocaleKeys.aiInputImagePrivacyRejected,
    );
    expect(
      localizeAiRunFailure(
        const AiRunFailure.http(
          statusCode: 503,
          providerMessage: 'No available channel for private-model',
        ),
        identity,
      ),
      LocaleKeys.aiProviderChannelUnavailable,
    );
    expect(
      localizeAiRunFailure(
        const AiRunFailure(
          kind: AiRunFailureKind.contextWindowExhausted,
          providerMessage: 'Request rejected',
        ),
        identity,
      ),
      LocaleKeys.aiContextWindowExhausted,
    );
  });
  test(
    'code family prefixes are generic and yield to the provider message',
    () {
      const failure = AiRunFailure.http(
        statusCode: 400,
        providerCode: 'InvalidParameter.SomethingNew',
        providerMessage: 'The parameter `seed` must be below 2^31',
      );
      expect(recognizedAiRunFailureKey(failure), isNull);
      expect(
        localizeAiRunFailure(failure, identity),
        'The parameter `seed` must be below 2^31',
      );
      expect(
        localizeAiRunFailure(
          const AiRunFailure.http(
            statusCode: 400,
            providerCode: 'InvalidParameter.SomethingNew',
          ),
          identity,
        ),
        LocaleKeys.aiRequestParameterUnsupported,
      );
    },
  );
  test('only absent or unusable messages fall back to localized copy', () {
    for (final message in [null, '', '  ', '<html>Bad gateway</html>']) {
      expect(
        localizeAiRunFailure(
          AiRunFailure.http(statusCode: 400, providerMessage: message),
          identity,
        ),
        LocaleKeys.aiBadRequest,
      );
    }
    expect(
      localizeAiRunFailure(
        const AiRunFailure.http(
          statusCode: 400,
          providerMessage: '{"error":{"message":"audio is unsupported"}}',
        ),
        identity,
      ),
      'audio is unsupported',
    );
  });

  // 历史诊断的最小复现文本；模型名、渠道名、请求 ID 和金额均不保留。
  const samples = <(int, String, String)>[
    (
      400,
      'The input token count exceeds the maximum number of tokens allowed (1048576).',
      LocaleKeys.aiContextWindowExhausted,
    ),
    (403, 'user quota is insufficient', LocaleKeys.aiProviderQuotaExceeded),
    (
      502,
      '无法连接上游：[SSL: UNEXPECTED_EOF_WHILE_READING] EOF occurred in violation of protocol',
      LocaleKeys.aiProviderConnectionFailed,
    ),

    (
      400,
      'The supported API model names are example-a, example-b, but you passed example-c.',
      LocaleKeys.aiModelUnsupported,
    ),
    (500, '400错误，请打开流式传输~', LocaleKeys.aiStreamingRequired),
    (
      403,
      'Budget pool quota has been exhausted.',
      LocaleKeys.aiProviderQuotaExceeded,
    ),
    (
      500,
      'getaddrinfo ENOTFOUND example.invalid',
      LocaleKeys.aiProviderConnectionFailed,
    ),
    (
      500,
      'All connection attempts failed',
      LocaleKeys.aiProviderConnectionFailed,
    ),
    (
      500,
      'Upstream request failed: net/http: TLS handshake timeout',
      LocaleKeys.aiRequestTimeout,
    ),
    (422, 'model not found: example-model', LocaleKeys.aiModelNotFound),
    (400, 'MODEL NOT FOUND: example-model', LocaleKeys.aiModelNotFound),
    (404, 'model_not_found', LocaleKeys.aiModelNotFound),
    (
      401,
      'Model does not exist or you do not have access to it.',
      LocaleKeys.aiModelMissingOrDenied,
    ),
    (
      403,
      'You do not have access to this model.',
      LocaleKeys.aiModelMissingOrDenied,
    ),
    (404, 'Model example-model does not exist.', LocaleKeys.aiModelNotFound),
    (
      410,
      'The model has reached its end of life and is no longer available.',
      LocaleKeys.aiModelRetired,
    ),
    (
      401,
      'Free promotion has ended for example-model.',
      LocaleKeys.aiModelPromotionEnded,
    ),
    (
      401,
      'Model example-model is not supported',
      LocaleKeys.aiModelUnsupported,
    ),
    (
      400,
      'This model does not support tool calls',
      LocaleKeys.aiModelUnsupported,
    ),
    (400, '模型不支持 codex 协议', LocaleKeys.aiModelUnsupported),
    (
      400,
      'Model id : example-org/example-model , has no provider supported',
      LocaleKeys.aiModelUnsupported,
    ),
    (
      400,
      'Error from provider: Model is unavailable.',
      LocaleKeys.aiModelTemporarilyUnavailable,
    ),
    (
      400,
      'This model\'s maximum context length is 1000 tokens.',
      LocaleKeys.aiContextWindowExhausted,
    ),
    (
      400,
      'Your request exceeded model token limit: 1000',
      LocaleKeys.aiContextWindowExhausted,
    ),
    (400, 'prompt is too long', LocaleKeys.aiContextWindowExhausted),
    (
      400,
      'invalid temperature: only 1 is allowed for this model',
      LocaleKeys.aiRequestParameterUnsupported,
    ),
    (
      400,
      'Unsupported parameter: temperature',
      LocaleKeys.aiRequestParameterUnsupported,
    ),
    (
      400,
      'Range of max_tokens should be [1, 1000]',
      LocaleKeys.aiRequestParameterUnsupported,
    ),
    (
      400,
      "level 'high' not supported, valid levels: none",
      LocaleKeys.aiRequestParameterUnsupported,
    ),
    (
      400,
      "The 'reasoning_content' in the thinking mode must be passed back to the API.",
      LocaleKeys.aiThinkingHistoryRequired,
    ),
    (422, 'sensitive content detected', LocaleKeys.aiContentRejected),
    (
      400,
      "The request failed because the input image 'content[2]' 'content[3]' may contain real person.",
      LocaleKeys.aiInputImagePrivacyRejected,
    ),
    (
      400,
      'InputImageSensitiveContentDetected.PrivacyInformation',
      LocaleKeys.aiInputImagePrivacyRejected,
    ),
    (
      200,
      'The generated video may be related to copyright restrictions and has been blocked. Try adjusting your prompt or reference media.',
      LocaleKeys.aiOutputCopyrightRejected,
    ),
    (500, 'sensitive_words_detected', LocaleKeys.aiContentRejected),
    (
      400,
      'The request failed because the input may contain sensitive information.',
      LocaleKeys.aiContentRejected,
    ),
    (
      503,
      'No available channel for model example-model under group example',
      LocaleKeys.aiProviderChannelUnavailable,
    ),
    (503, '该分组下模型无可用渠道', LocaleKeys.aiProviderChannelUnavailable),
    (
      503,
      'No available accounts: no available accounts',
      LocaleKeys.aiProviderChannelUnavailable,
    ),
    (
      503,
      'No active API keys available for this group',
      LocaleKeys.aiProviderChannelUnavailable,
    ),
    (
      503,
      'No credentials available. Please add or enable credentials.',
      LocaleKeys.aiProviderChannelUnavailable,
    ),
    (
      401,
      'Insufficient balance. Manage your billing here.',
      LocaleKeys.aiProviderPaymentRequired,
    ),
    (402, 'Insufficient account balance', LocaleKeys.aiProviderPaymentRequired),
    (403, '预扣费额度失败', LocaleKeys.aiProviderPaymentRequired),
    (429, 'insufficient_quota', LocaleKeys.aiProviderQuotaExceeded),
    (
      429,
      'You exceeded your current quota',
      LocaleKeys.aiProviderQuotaExceeded,
    ),
    (403, '用户额度不足', LocaleKeys.aiProviderQuotaExceeded),
    (
      500,
      'Concurrency limit exceeded for account, please retry later',
      LocaleKeys.aiRateLimited,
    ),
    (500, 'The request queue is full.', LocaleKeys.aiRateLimited),
    (
      500,
      'System protection triggered by request burst.',
      LocaleKeys.aiRateLimited,
    ),
    (403, 'API key is disabled', LocaleKeys.aiApiKeyInvalid),
    (
      400,
      'API key not valid. Please pass a valid API key.',
      LocaleKeys.aiApiKeyInvalid,
    ),
    (500, 'Service temporarily overloaded', LocaleKeys.aiServiceOverloaded),
    (
      500,
      'failed to stream request: stream first event timeout',
      LocaleKeys.aiRequestTimeout,
    ),
  ];
  for (final (status, message, expected) in samples) {
    test('provider message overrides HTTP $status: $message', () {
      expect(
        localizeAiRunFailure(
          AiRunFailure.http(
            statusCode: status,
            providerId: 'custom',
            providerMessage: message,
          ),
          identity,
          preferProviderMessage: false,
        ),
        expected,
      );
      // 同一上游原因也可能通过 HTTP 200 的流内 error 到达。
      for (final kind in [
        AiRunFailureKind.streamInterrupted,
        AiRunFailureKind.requestFailed,
      ]) {
        expect(
          localizeAiRunFailure(
            AiRunFailure(kind: kind, providerMessage: message),
            identity,
            preferProviderMessage: false,
          ),
          expected,
        );
      }
    });
  }

  test('nested provider messages are extracted before mapping', () {
    final message = tryReadProviderMessage(
      const _ProviderError(
        'data: {"error":{"message":"model not found: example-model"}}',
      ),
    );
    expect(
      localizeAiRunFailure(
        AiRunFailure.http(statusCode: 422, providerMessage: message),
        identity,
        preferProviderMessage: false,
      ),
      LocaleKeys.aiModelNotFound,
    );
  });

  test('provider balance and quota remain distinct', () {
    for (final provider in ['openai', 'custom']) {
      expect(
        localizeAiRunFailure(
          AiRunFailure.http(
            statusCode: 402,
            providerId: provider,
            providerMessage: 'insufficient credit',
          ),
          identity,
          preferProviderMessage: false,
        ),
        LocaleKeys.aiProviderPaymentRequired,
      );
      expect(
        localizeAiRunFailure(
          AiRunFailure.http(
            statusCode: 429,
            providerId: provider,
            providerMessage: 'insufficient_quota',
          ),
          identity,
          preferProviderMessage: false,
        ),
        LocaleKeys.aiProviderQuotaExceeded,
      );
    }
  });

  test('unrelated resources and unknown text keep status fallback', () {
    for (final message in [
      'File not found: example.txt',
      'Tool not found: Read',
      'Resource not found in model configuration',
      'Unsupported media type',
      'Unknown provider explanation with private details',
    ]) {
      expect(
        localizeAiRunFailure(
          AiRunFailure.http(statusCode: 404, providerMessage: message),
          identity,
          preferProviderMessage: false,
        ),
        LocaleKeys.aiNotFound,
      );
    }
  });

  test('explicit terminal failure kinds retain their meaning', () {
    for (final kind in [
      AiRunFailureKind.network,
      AiRunFailureKind.contextWindowExhausted,
      AiRunFailureKind.incompleteResponse,
    ]) {
      expect(
        localizeAiRunFailure(
          AiRunFailure(kind: kind, providerMessage: 'model not found'),
          identity,
          preferProviderMessage: false,
        ),
        localizeAiRunFailure(AiRunFailure(kind: kind), identity),
      );
    }
  });

  test(
    'unknown provider messages stay diagnostic and use localized fallback',
    () {
      for (final code in [400, 401, 402, 403, 410, 451, 503]) {
        final failure = AiRunFailure.http(
          statusCode: code,
          providerMessage: '  Provider explanation  ',
        );
        final restored = AiRunFailure.fromJson(
          failure.toJson(),
        ).withProviderId('custom');
        expect(restored.providerMessage, failure.providerMessage);
        expect(
          restored.toString(),
          contains('providerMessage:   Provider explanation  '),
        );
        expect(
          localizeAiRunFailure(
            restored,
            identity,
            preferProviderMessage: false,
          ),
          localizeAiRunFailure(
            AiRunFailure.http(statusCode: code, providerId: 'custom'),
            identity,
            preferProviderMessage: false,
          ),
        );
      }
      for (final kind in AiRunFailureKind.values) {
        expect(
          localizeAiRunFailure(
            AiRunFailure(kind: kind, providerMessage: 'Provider explanation'),
            identity,
            preferProviderMessage: false,
          ),
          localizeAiRunFailure(AiRunFailure(kind: kind), identity),
        );
      }
    },
  );

  test('410 with absent or blank message uses generic resource gone copy', () {
    for (final message in [null, '', '  ']) {
      expect(
        localizeAiRunFailure(
          AiRunFailure.http(statusCode: 410, providerMessage: message),
          identity,
          preferProviderMessage: false,
        ),
        LocaleKeys.aiResourceGone,
      );
    }
    expect(
      AiRunFailure.fromJson({
        'kind': 'http',
        'status_code': 410,
      }).providerMessage,
      isNull,
    );
  });

  test('extracts provider message without SDK or JSON wrappers', () {
    for (final message in [
      ' Model retired ',
      '{"error":{"message":"Model retired","code":"gone"}}',
      '{"error":"Model retired"}',
      'data: {"error":{"message":"Model retired"}}',
      '{"error":{"code":"gone"},"message":"Model retired"}',
    ]) {
      expect(tryReadProviderMessage(_ProviderError(message)), 'Model retired');
    }
    for (final message in [
      '',
      ' ',
      'Unknown error',
      'openai_error',
      '<html>503</html>',
      '{"error":{"code":"gone"}}',
      '{invalid',
      'data: invalid',
    ]) {
      expect(tryReadProviderMessage(_ProviderError(message)), isNull);
    }
    expect(tryReadProviderMessage(StateError('internal detail')), isNull);
  });

  test('401 maps to invalid API key for all providers', () {
    expect(
      localizeAiRunFailure(
        const AiRunFailure.http(statusCode: 401, providerId: 'custom'),
        identity,
        preferProviderMessage: false,
      ),
      LocaleKeys.aiApiKeyInvalid,
    );
    expect(
      localizeAiRunFailure(
        const AiRunFailure.http(statusCode: 401, providerId: 'openai'),
        identity,
        preferProviderMessage: false,
      ),
      LocaleKeys.aiApiKeyInvalid,
    );
  });

  test('402 maps to insufficient balance for all providers', () {
    expect(
      localizeAiRunFailure(
        const AiRunFailure.http(statusCode: 402, providerId: 'custom'),
        identity,
        preferProviderMessage: false,
      ),
      LocaleKeys.aiProviderPaymentRequired,
    );
    expect(
      localizeAiRunFailure(
        const AiRunFailure.http(statusCode: 402, providerId: 'openai'),
        identity,
        preferProviderMessage: false,
      ),
      LocaleKeys.aiProviderPaymentRequired,
    );
  });

  test('provider model denial maps to dedicated copy, not API key error', () {
    expect(
      localizeAiRunFailure(
        const AiRunFailure.http(
          statusCode: 403,
          providerId: 'custom',
          providerMessage: 'model forbidden for user',
        ),
        identity,
        preferProviderMessage: false,
      ),
      LocaleKeys.aiModelForbiddenForUser,
    );
  });

  test('400, 412, and 422 without a known cause use generic request copy', () {
    for (final statusCode in [400, 412, 422]) {
      expect(
        localizeAiRunFailure(
          AiRunFailure.http(statusCode: statusCode),
          identity,
          preferProviderMessage: false,
        ),
        LocaleKeys.aiBadRequest,
      );
    }
  });

  test('413 maps to request-too-large regardless of body format', () {
    // 网关 HTML、上游 JSON 与中转站中文文案三类历史样本。
    for (final message in [
      '<html><head><title>413 Request Entity Too Large</title></head></html>',
      '{"error":{"message":"Provider returned error","code":413}}',
      '请求内容过大。',
    ]) {
      expect(
        localizeAiRunFailure(
          AiRunFailure.http(
            statusCode: 413,
            providerId: 'custom',
            providerMessage: message,
          ),
          identity,
          preferProviderMessage: false,
        ),
        LocaleKeys.aiRequestTooLarge,
      );
    }
  });

  test('stream interruption and overloaded statuses use dedicated copy', () {
    expect(
      localizeAiRunFailure(const AiRunFailure.streamInterrupted(), identity),
      LocaleKeys.aiStreamInterrupted,
    );
    for (final statusCode in [502, 503]) {
      expect(
        localizeAiRunFailure(
          AiRunFailure.http(statusCode: statusCode),
          identity,
          preferProviderMessage: false,
        ),
        LocaleKeys.aiServiceOverloaded,
      );
    }
  });

  test('incomplete model response uses dedicated recovery copy', () {
    expect(
      localizeAiRunFailure(const AiRunFailure.incompleteResponse(), identity),
      LocaleKeys.aiIncompleteResponse,
    );
  });

  test('unknown failures never expose technical messages', () {
    expect(
      localizeAiRunFailure(const AiRunFailure.requestFailed(), identity),
      LocaleKeys.aiRequestFailed,
    );
  });

  test(
    'server errors and gateway timeouts explain the cause without replacing a provider message',
    () {
      for (final (statusCode, messageKey) in [
        (500, LocaleKeys.aiProviderServerError),
        (504, LocaleKeys.aiProviderGatewayTimeout),
      ]) {
        expect(
          localizeAiRunFailure(
            AiRunFailure.http(statusCode: statusCode),
            identity,
          ),
          messageKey,
        );
        const providerMessage =
            'The inference endpoint did not finish loading.';
        expect(
          localizeAiRunFailure(
            AiRunFailure.http(
              statusCode: statusCode,
              providerCode: statusCode == 500 ? 'InternalServiceError' : null,
              providerMessage: providerMessage,
            ),
            identity,
          ),
          providerMessage,
        );
      }
    },
  );
}

class _ProviderError implements Exception {
  const _ProviderError(this.message);
  final String message;
}

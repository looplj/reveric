// 职责: AI Provider 初始化器 — 根据 AiProvider 配置创建 ProviderClient，支持请求追踪头
// 关联文件:
//   lib/shared/app_config.dart
//   lib/shared/services/ai/chat.dart
//   lib/shared/agent/client.dart
//   lib/shared/agent/client/openai_client.dart
//   lib/shared/agent/client/openai_responses_client.dart
//   lib/shared/agent/client/anthropic_client.dart
//   lib/shared/agent/client/gemini_client.dart
//   lib/shared/agent/client/trace_headers_http_client.dart
//   lib/shared/models/ai_provider.dart

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:http/http.dart' as http;

import '../../models/ai_provider.dart';
import '../../models/models_catalog.dart' show useThinkingField;
import '../../agent/client.dart';
import '../../agent/client/openai_client.dart';
import '../../agent/client/openai_responses_client.dart';
import '../../agent/client/codex_client.dart';
import '../../agent/client/anthropic_client.dart';
import '../../agent/client/gemini_client.dart';
import '../../agent/client/trace_headers_http_client.dart'
    show TraceHeadersProvider;
import 'new_api.dart';
import '../debug/debug_ai_provider.dart';
import '../debug/debug_provider_client.dart';

class AiProviderInitializer {
  AiProviderInitializer({
    required this._config,
    required this._chatModel,
    http.Client? httpClient,
    this._traceHeadersProvider,
    this._cacheKeyUserId,
  }) : _httpClient = httpClient,
       _ownsHttpClient = httpClient == null;

  final AiProvider _config;
  final String _chatModel;
  final TraceHeadersProvider? _traceHeadersProvider;
  final String? _cacheKeyUserId;

  final bool _ownsHttpClient;
  http.Client? _httpClient;

  ProviderClient? _client;
  Future<ProviderClient>? _initializing;
  int _generation = 0;

  bool get isInitialized => _client != null;

  Future<ProviderClient> initialize() {
    final client = _client;
    if (client != null) {
      return Future.value(client);
    }
    return _initializing ??= _initialize(_generation);
  }

  Future<ProviderClient> _initialize(int generation) async {
    try {
      if (_ownsHttpClient) {
        _httpClient = _config.createProxyClient();
      }
      var client = await _createClient();
      if (generation != _generation) {
        client.cancel();
        throw StateError('AI provider initialization was disposed');
      }
      if (kDebugMode) {
        final scenario = debugAiProviderScenarioForId(_config.id);
        if (scenario != null) {
          client = DebugInjectedProviderClient(
            inner: client,
            scenario: scenario,
          );
        }
      }
      _client = RetryDecorator(inner: client, maxRetries: 2);
      return _client!;
    } finally {
      if (generation == _generation) {
        _initializing = null;
      }
    }
  }

  void dispose() {
    _generation++;
    _initializing = null;
    _client?.cancel();
    _client = null;
    if (_ownsHttpClient) {
      _httpClient?.close();
    }
    _httpClient = null;
  }

  /// 为流式请求创建专用 http.Client。
  ///
  /// 复刻 [_config] 的代理配置：流式取消需要单独关闭本次请求的 client，不能复用
  /// 共享 client（会误杀其他在飞请求），但必须与共享 client 走同一代理，否则配了
  /// 代理的用户流式请求会绕过代理直连。
  http.Client _createStreamHttpClient() =>
      _config.createProxyClient() ?? http.Client();

  Future<ProviderClient> _createClient() async {
    switch (_config.typeEnum) {
      case AiProviderType.purefox_media:
        throw UnsupportedError(
          'PureFox Media is configured for image and video generation only',
        );
      case AiProviderType.moss:
        throw UnsupportedError('MOSS supports image and audio generation only');
      case AiProviderType.agnes:
        throw UnsupportedError(
          'Agnes is configured for image and video generation only',
        );
      case AiProviderType.metaso:
        throw UnsupportedError('METASO supports video generation only');
      case AiProviderType.codex:
        return CodexClient(
          model: _chatModel,
          sessionIdProvider: () =>
              _traceHeadersProvider?.call()['x-session-id'],
          httpClient: _httpClient,
          streamHttpClientFactory: _createStreamHttpClient,
        );
      case AiProviderType.api88:
      case AiProviderType.apikey:
      case AiProviderType.infistar:
      case AiProviderType.ooki:
        return NewApiClient(_config).chat(
          cacheKeyUserId: _cacheKeyUserId,
          model: _chatModel,
          httpClient: _httpClient,
          streamClientFactory: _createStreamHttpClient,
          traceHeadersProvider: _traceHeadersProvider,
        );
      case AiProviderType.openai:
        return OpenAIResponsesClient(
          apiKey: _config.effectiveApiKey,
          baseUrl: _config.effectiveBaseUrl,
          model: _chatModel,
          httpClient: _httpClient,
          streamHttpClientFactory: _createStreamHttpClient,
          traceHeadersProvider: _traceHeadersProvider,
        );
      case AiProviderType.openrouter:
      case AiProviderType.atlascloud:
      case AiProviderType.purefox:
      case AiProviderType.openai_compatible:
      case AiProviderType.xai:
      case AiProviderType.deepseek:
      case AiProviderType.moonshot:
      case AiProviderType.zhipu:
      case AiProviderType.doubao:
      case AiProviderType.volcengine:
      case AiProviderType.qwen:
      case AiProviderType.qwen_token_plan:
        return OpenAiClient(
          apiKey: _config.effectiveApiKey,
          baseUrl: _config.effectiveBaseUrl,
          model: _chatModel,
          httpClient: _httpClient,
          streamClientFactory: _createStreamHttpClient,
          traceHeadersProvider: _traceHeadersProvider,
          useOpenRouter: _config.typeEnum == AiProviderType.openrouter,
          useThinkingField: useThinkingField(_chatModel),
          useEnableThinkingField:
              _config.typeEnum == AiProviderType.qwen ||
              _config.typeEnum == AiProviderType.qwen_token_plan,
        );
      case AiProviderType.minimax:
        return AnthropicClient(
          apiKey: _config.effectiveApiKey,
          baseUrl: minimaxAnthropicBaseUrl(_config.effectiveBaseUrl),
          model: _chatModel,
          httpClient: _httpClient,
          streamHttpClientFactory: _createStreamHttpClient,
          traceHeadersProvider: _traceHeadersProvider,
        );
      case AiProviderType.anthropic:
        return AnthropicClient(
          apiKey: _config.effectiveApiKey,
          baseUrl: _config.effectiveBaseUrl,
          model: _chatModel,
          httpClient: _httpClient,
          streamHttpClientFactory: _createStreamHttpClient,
          traceHeadersProvider: _traceHeadersProvider,
          cacheKeyUserId: _cacheKeyUserId,
        );
      case AiProviderType.gemini:
        return GeminiClient(
          apiKey: _config.effectiveApiKey,
          baseUrl: _config.effectiveBaseUrl,
          model: _chatModel,
          httpClient: _httpClient,
          streamHttpClientFactory: _createStreamHttpClient,
          traceHeadersProvider: _traceHeadersProvider,
        );
    }
  }
}

String geminiGatewayBaseUrl(String baseUrl) {
  final trimmed = baseUrl.trim();
  return trimmed.endsWith('/v1')
      ? trimmed.substring(0, trimmed.length - 3)
      : trimmed;
}

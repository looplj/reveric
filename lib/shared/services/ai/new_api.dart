// 职责: 获取 New API 模型目录，并按模型名路由聊天协议、装配各类生成客户端。
// 关联文件:
//   lib/shared/models/new_api.dart
//   lib/shared/services/ai/provider_initializer.dart
//   lib/shared/services/ai/image/new_api.dart
//   lib/shared/services/ai/audio/gemini.dart
//   lib/shared/services/ai/video/new_api.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../agent/client.dart';
import '../../agent/client/openai_client.dart';
import '../../agent/client/openai_responses_client.dart';
import '../../agent/client/anthropic_client.dart';
import '../../agent/client/gemini_client.dart';
import '../../agent/client/trace_headers_http_client.dart';
import '../../logger/app_logger.dart';
import '../../models/ai_provider.dart';
import '../../models/new_api.dart';
import '../../models/models_catalog.dart';
import '../../models/audio/channels.dart';
import '../../models/audio/catalog.dart';
import '../../models/image/channels.dart';
import '../../models/video/channels.dart';
import '../../models/video/catalog.dart';
import 'media_diagnostics.dart';
import 'image/new_api.dart';
import 'audio/client.dart';
import 'audio/gemini.dart';
import 'audio/new_api.dart';
import 'video/new_api.dart';

final _log = AppLogger.forModule('NewApiModels');

class NewApiClient {
  const NewApiClient(this.config);
  final AiProvider config;

  Future<List<NewApiModel>> models({http.Client? httpClient}) async {
    final endpoint = Uri.parse(config.effectiveBaseUrl);
    if (!{'http', 'https'}.contains(endpoint.scheme) ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        config.effectiveApiKey.trim().isEmpty) {
      throw StateError('New API requires a valid base URL and API key');
    }
    final uri = endpoint.replace(path: '${endpoint.path}/models');
    final transport = httpClient ?? config.createProxyClient() ?? http.Client();
    try {
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers['Authorization'] = 'Bearer ${config.effectiveApiKey}';
      final response = await (() async => http.Response.fromStream(
        await transport.send(request),
      ))().timeout(const Duration(seconds: 30));
      if (_log.isDebugEnabled) {
        _log.debug(
          'GET $uri status=${response.statusCode} body=${response.body}',
        );
      }
      if (response.statusCode != 200) {
        throw StateError(
          'GET ${uri.origin}${uri.path}: HTTP ${response.statusCode} '
          '${safeMediaDiagnostic(response.body, config.effectiveApiKey)}',
        );
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return (json['data'] as List)
          .map((item) => NewApiModel.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (error) {
      _log.warning(
        'GET ${uri.origin}${uri.path} '
        'type=${error.runtimeType} message=${safeMediaDiagnostic(error, config.effectiveApiKey)}',
      );
      rethrow;
    } finally {
      if (httpClient == null) {
        transport.close();
      }
    }
  }

  Future<List<String>> modelIds(AiModelKind kind) async {
    final list = await models();
    return (list
        .where((model) {
          final image = lookupImageChannelModel(config.type, model.id) != null;
          final audio = lookupAudioChannelModel(config.type, model.id) != null;
          final video = lookupVideoChannelModel(config.type, model.id) != null;
          return switch (kind) {
            AiModelKind.image =>
              image &&
                  (model.id == 'mj_imagine' ||
                      model.endpointTypes.contains('image-generation') ||
                      model.endpointTypes.contains('gemini')),
            AiModelKind.audio =>
              audio &&
                  model.endpointTypes.contains(
                    lookupAudioChannelModel(
                          config.type,
                          model.id,
                        )!.catalogId.contains('gemini-')
                        ? 'gemini'
                        : 'openai',
                  ),
            AiModelKind.video =>
              video && model.endpointTypes.contains('openai-video'),
            AiModelKind.chat =>
              !image &&
                  !audio &&
                  !video &&
                  lookupImageModel(model.id) == null &&
                  lookupAudioModel(model.id) == null &&
                  !audioChannelModels[AudioProtocol.new_api_speech]!
                      .containsKey(model.id) &&
                  lookupVideoModel(model.id) == null &&
                  !model.endpointTypes.contains('image-generation') &&
                  !model.endpointTypes.contains('openai-video') &&
                  (model.endpointTypes.isEmpty ||
                      model.endpointTypes.any(
                        {
                          'openai',
                          'openai-response',
                          'anthropic',
                          'gemini',
                        }.contains,
                      )),
          };
        })
        .map((model) => model.id)
        .toSet()
        .toList()
      ..sort());
  }

  Future<ProviderClient> chat({
    required String model,
    http.Client? httpClient,
    http.Client Function()? streamClientFactory,
    TraceHeadersProvider? traceHeadersProvider,
    String? cacheKeyUserId,
  }) async {
    final root = config.effectiveBaseUrl.replaceFirst(RegExp(r'/v1$'), '');
    return switch (NewApiChatProtocol.forModel(model)) {
      NewApiChatProtocol.responses => OpenAIResponsesClient(
        apiKey: config.effectiveApiKey,
        baseUrl: config.effectiveBaseUrl,
        model: model,
        httpClient: httpClient,
        streamHttpClientFactory: streamClientFactory,
        traceHeadersProvider: traceHeadersProvider,
      ),
      NewApiChatProtocol.anthropic => AnthropicClient(
        apiKey: config.effectiveApiKey,
        baseUrl: root,
        model: model,
        httpClient: httpClient,
        streamHttpClientFactory: streamClientFactory,
        traceHeadersProvider: traceHeadersProvider,
        cacheKeyUserId: cacheKeyUserId,
      ),
      NewApiChatProtocol.gemini => GeminiClient(
        apiKey: config.effectiveApiKey,
        baseUrl: root,
        model: model,
        httpClient: httpClient,
        authAsHeader: true,
        streamHttpClientFactory: streamClientFactory,
        traceHeadersProvider: traceHeadersProvider,
      ),
      NewApiChatProtocol.openai => OpenAiClient(
        apiKey: config.effectiveApiKey,
        baseUrl: config.effectiveBaseUrl,
        model: model,
        httpClient: httpClient,
        streamClientFactory: streamClientFactory,
        traceHeadersProvider: traceHeadersProvider,
        useThinkingField: useThinkingField(model),
      ),
    };
  }

  NewApiImageClient image() => NewApiImageClient(config);
  AudioClient audio(http.Client transport, String model) {
    final catalogId =
        lookupAudioChannelModel(config.type, model)?.catalogId ?? model;
    if (catalogId.contains('gemini-')) {
      return GeminiAudioClient(
        transport,
        config.effectiveApiKey,
        providerType: config.type,
        endpoint: Uri.parse(
          config.effectiveBaseUrl.replaceFirst(RegExp(r'/v1$'), ''),
        ),
      );
    }
    return NewApiAudioClient(
      transport,
      config.effectiveApiKey,
      providerType: config.type,
      endpoint: Uri.parse(config.effectiveBaseUrl),
    );
  }

  NewApiVideoClient video(http.Client transport) => NewApiVideoClient(
    httpClient: transport,
    providerType: config.type,
    apiKey: config.effectiveApiKey,
    endpoint: Uri.parse(config.effectiveBaseUrl),
  );
}

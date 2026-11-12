// 职责: 验证 New API 模型发现、原生聊天路由和品牌配置。
// 关联文件:
//   lib/shared/services/ai/new_api.dart
//   lib/shared/services/ai/provider_initializer.dart
//   lib/shared/models/new_api.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/new_api.dart';
import 'package:reveric/shared/models/audio/channels.dart';
import 'package:reveric/shared/models/image/channels.dart';
import 'package:reveric/shared/models/video/channels.dart';
import 'package:reveric/shared/services/ai/new_api.dart';
import 'package:reveric/shared/services/ai/provider_initializer.dart';
import 'package:reveric/shared/widgets/settings/provider_config_panel.dart';
import 'package:reveric/shared/widgets/settings/providers/registry.dart';

AiProvider _provider([String type = 'api88']) =>
    aiProviderBuiltinById('openai')!.copyWith(
      type: type,
      apiKey: 'test-key',
      baseUrl: 'https://gateway.test/prefix/',
    );
const _allChat = ['openai', 'openai-response', 'anthropic', 'gemini'];
Map<String, dynamic> _model(String id, List<String> endpoints) => {
  'id': id,
  'supported_endpoint_types': endpoints,
};
http.Response _json(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('OOKiAPI is available only by manual creation without a showcase', () {
    expect(customAiProviderTypes, contains(AiProviderType.ooki));
    expect(aiProviderBuiltinById('ooki'), isNull);
    expect(providerShowcases, isNot(contains('ooki')));
  });
  test('Infistar is manually added with a sponsor showcase', () {
    expect(customAiProviderTypes, contains(AiProviderType.infistar));
    expect(aiProviderBuiltinById('infistar'), isNull);
    expect(providerShowcases, contains('infistar'));
  });
  test(
    'standard model lists without endpoint metadata retain chat models',
    () async {
      await http.runWithClient(
        () async {
          expect(await fetchProviderModels(_provider('infistar')), [
            'my-writer',
            'qwen-plus',
          ]);
        },
        () => MockClient(
          (request) async => _json({
            'object': 'list',
            'data': [
              for (final id in [
                'qwen-plus',
                'my-writer',
                'gpt-image-2',
                'gemini-3.1-flash-image',
                'gemini-3.1-flash-tts',
                'grok-imagine-video-1.5',
              ])
                {
                  'id': id,
                  'object': 'model',
                  'created': 0,
                  'owned_by': 'system',
                },
            ],
          }),
        ),
      );
    },
  );
  for (final (type, baseUrl) in [
    ('api88', 'https://api.88api.ai/v1'),
    ('ooki', 'https://api.ookiapi.com/v1'),
    ('apikey', 'https://api.apikey.fan/v1'),
    ('infistar', 'https://infistar.cc/v1'),
  ]) {
    group(type, () => _testProvider(type, baseUrl));
  }
}

void _testProvider(String type, String baseUrl) {
  test(
    'New API provider exposes its supported kinds without a separate client type',
    () {
      expect(_provider(type).effectiveBaseUrl, baseUrl);
      expect(
        _provider(type).supportedModelKinds,
        ['apikey', 'infistar'].contains(type)
            ? {AiModelKind.chat}
            : {
                AiModelKind.chat,
                AiModelKind.image,
                AiModelKind.audio,
                AiModelKind.video,
              },
      );
      expect(customAiProviderTypes, contains(AiProviderType.api88));
      expect(
        AiProviderType.values.map((type) => type.name),
        isNot(contains('new_api')),
      );
      expect(aiProviderTypeConfigFor('new_api'), isNull);
    },
  );

  if (!['apikey', 'infistar'].contains(type)) {
    test(
      'all registered media channel entries resolve to usable capabilities',
      () {
        for (final type in ['api88', 'ooki']) {
          for (final channel
              in imageChannelModels[ImageProtocol.new_api_images]!.values) {
            expect(channel.model, isNotNull);
          }
          for (final id in audioModelsForProvider(type)) {
            final channel = lookupAudioChannelModel(type, id)!;
            expect(channel.capabilities.speech, true);
            expect(channel.requestDefaults.voice, isNotEmpty);
          }
          for (final id in videoModelsForProvider(type)) {
            final channel = lookupVideoChannelModel(type, id)!;
            expect(channel.resolutions, isNotEmpty);
            expect(channel.durations, isNotEmpty);
          }
        }
      },
    );

    test(
      'fetch all kinds from authenticated models and filter by capabilities',
      () async {
        var requests = 0;
        await http.runWithClient(
          () async {
            expect(await fetchProviderModels(_provider(type)), [
              'deepseek-v4-flash',
            ]);
            expect(
              await fetchProviderModels(
                _provider(type),
                kind: AiModelKind.image,
              ),
              ['gemini-3.1-flash-image', 'gpt-image-2'],
            );
            expect(
              await fetchProviderModels(
                _provider(type),
                kind: AiModelKind.audio,
              ),
              ['gemini-3.1-flash-tts'],
            );
            expect(
              await fetchProviderModels(
                _provider(type),
                kind: AiModelKind.video,
              ),
              ['seedance-2.0官方版', 'veo-3.1'],
            );
          },
          () => MockClient((request) async {
            requests++;
            expect(request.url.toString(), '$baseUrl/models');
            expect(request.headers['Authorization'], 'Bearer test-key');
            return _json({
              'data': [
                _model('deepseek-v4-flash', _allChat),
                _model('gpt-image-2', ['image-generation', 'openai']),
                _model('gemini-3.1-flash-image', ['gemini', 'openai']),
                _model('gemini-3.1-flash-tts', ['gemini', 'openai']),
                _model('seedance-2.0官方版', ['openai-video']),
                _model('veo-3.1', ['openai-video']),
                _model('unknown-video', ['openai-video']),
              ],
            });
          }),
        );
        expect(requests, 4);
      },
    );
  }

  test(
    'chat model discovery uses the configured authenticated endpoint',
    () async {
      await http.runWithClient(
        () async {
          expect(await fetchProviderModels(_provider(type)), [
            'claude-opus-5-5',
            'gpt-6.1-sol',
          ]);
        },
        () => MockClient((request) async {
          expect(request.url.toString(), '$baseUrl/models');
          expect(request.headers['Authorization'], 'Bearer test-key');
          return _json({
            'data': [
              _model('gpt-6.1-sol', ['openai-response']),
              _model('claude-opus-5-5', ['anthropic']),
              _model('gpt-image-2', ['image-generation']),
              _model('grok-imagine-video', ['openai-video']),
            ],
          });
        }),
      );
    },
  );

  for (final (model, path, protocol) in [
    ('claude-sonnet-4-6', '/v1/messages', NewApiChatProtocol.anthropic),
    (
      'gemini-3.1-pro-preview',
      '/v1beta/models/gemini-3.1-pro-preview:generateContent',
      NewApiChatProtocol.gemini,
    ),
    ('gpt-5.4', '/v1/responses', NewApiChatProtocol.responses),
    ('deepseek-v4-flash', '/v1/chat/completions', NewApiChatProtocol.openai),
    ('my-writer', '/v1/chat/completions', NewApiChatProtocol.openai),
  ]) {
    test(
      '$model uses $protocol without model discovery or rewriting model ID',
      () async {
        var calls = 0;
        final initializer = AiProviderInitializer(
          config: _provider(type),
          chatModel: model,
          httpClient: MockClient((request) async {
            calls++;
            expect(request.method, 'POST');
            expect(request.url.path, path);
            expect(request.url.host, Uri.parse(baseUrl).host);
            final body = jsonDecode(request.body) as Map;
            if (protocol != NewApiChatProtocol.gemini) {
              expect(body['model'], model);
            }
            expect(request.url.queryParameters, isNot(contains('key')));
            switch (protocol) {
              case NewApiChatProtocol.openai:
                return _json({
                  'choices': [
                    {
                      'index': 0,
                      'message': {'role': 'assistant', 'content': 'ok'},
                      'finish_reason': 'stop',
                    },
                  ],
                });
              case NewApiChatProtocol.anthropic:
                expect(request.headers['x-api-key'], 'test-key');
                return _json({
                  'id': 'msg_1',
                  'type': 'message',
                  'role': 'assistant',
                  'model': model,
                  'content': [
                    {'type': 'text', 'text': 'ok'},
                  ],
                  'stop_reason': 'end_turn',
                  'usage': {'input_tokens': 1, 'output_tokens': 1},
                });
              case NewApiChatProtocol.gemini:
                expect(request.headers['x-goog-api-key'], 'test-key');
                return _json({
                  'candidates': [
                    {
                      'content': {
                        'role': 'model',
                        'parts': [
                          {'text': 'ok'},
                        ],
                      },
                      'finishReason': 'STOP',
                    },
                  ],
                });
              case NewApiChatProtocol.responses:
                expect(request.headers['Authorization'], 'Bearer test-key');
                return _json({
                  'id': 'resp_1',
                  'object': 'response',
                  'created_at': 1,
                  'model': model,
                  'status': 'completed',
                  'output': [
                    {
                      'type': 'message',
                      'id': 'msg_1',
                      'role': 'assistant',
                      'status': 'completed',
                      'content': [
                        {
                          'type': 'output_text',
                          'text': 'ok',
                          'annotations': [],
                        },
                      ],
                    },
                  ],
                });
            }
          }),
        );
        addTearDown(initializer.dispose);
        final client = await initializer.initialize();
        expect(calls, 0);
        await client.chat(
          messages: [AgentMessage.user(id: 'user', content: 'hello')],
        );
        expect(await initializer.initialize(), same(client));
        expect(calls, 1);
      },
    );
  }

  test(
    'protocol selection follows model names including prefixes and aliases',
    () {
      for (final (model, protocol) in [
        ('vendor/CLAUDE-sonnet-4-6', NewApiChatProtocol.anthropic),
        ('vendor/GEMINI-3.1-pro-preview', NewApiChatProtocol.gemini),
        ('vendor/GPT-5.4', NewApiChatProtocol.responses),
        ('o1', NewApiChatProtocol.responses),
        ('o3-mini', NewApiChatProtocol.responses),
        ('o4-mini', NewApiChatProtocol.responses),
        ('renamed', NewApiChatProtocol.openai),
        ('other-model', NewApiChatProtocol.openai),
      ]) {
        expect(NewApiChatProtocol.forModel(model), protocol, reason: model);
      }
    },
  );

  test(
    'concurrent initialization shares client and disposal prevents resurrection without HTTP',
    () async {
      var calls = 0;
      final transport = MockClient((_) async {
        calls++;
        throw StateError('Initialization must not make HTTP requests');
      });
      addTearDown(transport.close);
      final initializer = AiProviderInitializer(
        config: _provider(type),
        chatModel: 'writer',
        httpClient: transport,
      );
      final first = initializer.initialize();
      final second = initializer.initialize();
      final expectation = expectLater(first, throwsStateError);
      expect(second, same(first));
      initializer.dispose();
      await expectation;
      expect(calls, 0);
      expect(initializer.isInitialized, false);
    },
  );

  test('explicit model discovery preserves failure diagnostics', () async {
    var calls = 0;
    final transport = MockClient((request) async {
      calls++;
      expect(request.method, 'GET');
      expect(request.url.path, '/v1/models');
      return http.Response('{"error":{"message":"invalid test-key"}}', 401);
    });
    addTearDown(transport.close);
    await expectLater(
      NewApiClient(_provider(type)).models(httpClient: transport),
      throwsA(
        isA<StateError>().having(
          (e) => e.toString(),
          'diagnostic',
          allOf(contains('401'), isNot(contains('test-key'))),
        ),
      ),
    );
    expect(calls, 1);
  });
}

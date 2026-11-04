// 职责: 验证供应商聊天客户端的协议、国内固定路由、网关地址与权限门禁。
// 关联文件:
//   lib/shared/services/ai/provider_initializer.dart

import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/agent/agent_config.dart';
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/services/ai/provider_initializer.dart';
import 'package:reveric/shared/models/ai_provider.dart';

void main() {
  for (final providerType in ['deepseek', 'openai_compatible']) {
    test(
      '$providerType preserves parallel image tool results on the wire',
      () async {
        final provider = aiProviderBuiltinById(
          'deepseek',
        )!.copyWith(type: providerType, apiKey: 'test-key');
        final initializer = AiProviderInitializer(
          config: provider,
          chatModel: 'deepseek-flash',
          httpClient: MockClient((request) async {
            final body = jsonDecode(request.body) as Map;
            final messages = (body['messages'] as List).cast<Map>();
            expect(messages.map((m) => m['role']), [
              'assistant',
              'tool',
              'tool',
              'user',
              'user',
              'user',
            ]);
            expect(messages[1]['tool_call_id'], 'a');
            expect(messages[2]['tool_call_id'], 'b');
            for (var i = 0; i < 2; i++) {
              final content = (messages[i + 3]['content'] as List).cast<Map>();
              expect(
                content.last['image_url']['url'],
                'data:image/png;base64,${i == 0 ? 'AAA=' : 'BBB='}',
              );
            }
            expect(messages.last['content'], 'continue');
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'index': 0,
                    'message': {'role': 'assistant', 'content': 'ok'},
                    'finish_reason': 'stop',
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        addTearDown(initializer.dispose);
        final api = await initializer.initialize();
        await api.chat(
          messages: [
            const AgentMessage(
              id: 'assistant',
              role: AgentMessageRole.assistant,
              blocks: [
                ToolCallBlock(callId: 'a', toolName: 'Run', arguments: {}),
                ToolCallBlock(callId: 'b', toolName: 'Run', arguments: {}),
              ],
            ),
            for (final id in ['a', 'b'])
              AgentMessage(
                id: 'result-$id',
                role: AgentMessageRole.user,
                type: AgentMessageType.tool_result,
                blocks: [
                  ToolResultBlock(
                    toolCallId: id,
                    toolName: 'Run',
                    content: [
                      TextBlock('result $id'),
                      ImageBlock(
                        data: id == 'a' ? 'AAA=' : 'BBB=',
                        mimeType: 'image/png',
                      ),
                    ],
                  ),
                ],
              ),
            AgentMessage.user(id: 'next', content: 'continue'),
          ],
        );
      },
    );
  }

  test('AtlasCloud reuses Chat Completions with its account key', () async {
    final provider = aiProviderBuiltinById(
      'openai',
    )!.copyWith(type: 'atlascloud', apiKey: 'atlas-key');
    final initializer = AiProviderInitializer(
      config: provider,
      chatModel: 'deepseek-ai/deepseek-v3.2',
      httpClient: MockClient((r) async {
        expect(
          r.url.toString(),
          'https://api.atlascloud.ai/v1/chat/completions',
        );
        expect(r.headers['Authorization'], 'Bearer atlas-key');
        expect(
          (jsonDecode(r.body) as Map)['model'],
          'deepseek-ai/deepseek-v3.2',
        );
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'index': 0,
                'message': {'role': 'assistant', 'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(initializer.dispose);
    final api = await initializer.initialize();
    await api.chat(
      messages: [AgentMessage.user(id: 'user', content: 'hello')],
    );
  });
  test(
    'Volcengine chat uses the fixed domestic Ark route and shared API key',
    () async {
      final provider = aiProviderBuiltinById('doubao')!.copyWith(
        type: 'volcengine',
        baseUrl: 'https://override.example/v1',
        apiKey: 'shared-key',
      );
      final initializer = AiProviderInitializer(
        config: provider,
        chatModel: provider.models.first,
        httpClient: MockClient((r) async {
          expect(
            r.url.toString(),
            'https://ark.cn-beijing.volces.com/api/v3/chat/completions',
          );
          expect(r.headers['Authorization'], 'Bearer shared-key');
          expect((jsonDecode(r.body) as Map)['model'], provider.models.first);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'index': 0,
                  'message': {'role': 'assistant', 'content': 'ok'},
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(initializer.dispose);
      final api = await initializer.initialize();
      await api.chat(
        messages: [AgentMessage.user(id: 'user', content: 'hello')],
      );
    },
  );
  for (final type in ['qwen', 'qwen_token_plan']) {
    test('$type uses Chat Completions and enable_thinking', () async {
      final provider = aiProviderBuiltinById('openai')!.copyWith(
        type: type,
        baseUrl: 'https://proxy.example/prefix/compatible-mode/v1',
        apiKey: 'qwen-key',
      );
      expect(provider.hasFixedBaseUrl, type == 'qwen_token_plan');
      final initializer = AiProviderInitializer(
        config: provider,
        chatModel: 'qwen3.8-flash',
        httpClient: MockClient((r) async {
          expect(
            r.url.toString(),
            type == 'qwen_token_plan'
                ? 'https://token-plan.maas.qianwenaiapi.com/compatible-mode/v1/chat/completions'
                : 'https://proxy.example/prefix/compatible-mode/v1/chat/completions',
          );
          expect(r.headers['Authorization'], 'Bearer qwen-key');
          final body = jsonDecode(r.body) as Map;
          expect(body['enable_thinking'], false);
          expect(body.containsKey('thinking'), false);
          expect(body.containsKey('reasoning_effort'), false);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'index': 0,
                  'message': {'role': 'assistant', 'content': 'ok'},
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final api = await initializer.initialize();
      await api.chat(
        messages: [AgentMessage.user(id: 'user', content: 'hello')],
        options: const AgentConfig(reasoningEffort: 'none'),
      );
      initializer.dispose();
    });
  }
  test('Qwen default replaces only blank and known former fixed URL', () {
    for (final old in ['', 'https://dashscope.aliyuncs.com/apps/anthropic/']) {
      final provider = aiProviderBuiltinById(
        'openai',
      )!.copyWith(type: 'qwen', baseUrl: old, apiKey: 'existing-key');
      expect(provider.effectiveBaseUrl, qwenDefaultBaseUrl);
      expect(provider.apiKey, 'existing-key');
      expect(provider.hasBaseUrl, true);
    }
    expect(
      qwenBaseUrl('https://custom.example/proxy/v1'),
      'https://custom.example/proxy/v1',
    );
  });
  for (final builtin in [true, false]) {
    for (final (baseUrl, expectedRoot) in [
      ('https://relay.example', 'https://relay.example'),
      ('https://relay.example/v1beta', 'https://relay.example'),
      ('https://relay.example/proxy/v1beta/', 'https://relay.example/proxy'),
      (
        'https://generativelanguage.googleapis.com/v1beta',
        'https://generativelanguage.googleapis.com',
      ),
    ]) {
      test('Gemini builtin=$builtin respects chat address $baseUrl', () async {
        final requests = <Uri>[];
        final initializer = AiProviderInitializer(
          config: aiProviderBuiltinById('gemini')!.copyWith(
            id: builtin ? 'gemini' : 'custom-gemini',
            builtin: builtin,
            baseUrl: baseUrl,
            apiKey: 'relay-key',
          ),
          chatModel: 'gemini-test',
          httpClient: MockClient((request) async {
            requests.add(request.url);
            return http.Response(
              jsonEncode({
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
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        addTearDown(initializer.dispose);
        final client = await initializer.initialize();
        await client.chat(
          messages: [AgentMessage.user(id: 'user', content: 'hello')],
        );
        expect(requests, hasLength(1));
        expect(
          '${requests.single.origin}${requests.single.path}',
          '$expectedRoot/v1beta/models/gemini-test:generateContent',
        );
        expect(requests.single.queryParameters['key'], 'relay-key');
      });
    }
  }

  test('Gemini gateway base URL strips the OpenAI v1 suffix', () {
    expect(
      geminiGatewayBaseUrl('http://localhost:9010/v1'),
      'http://localhost:9010',
    );
  });

  test(
    'initializes a configured third-party provider without an account',
    () async {
      final provider = aiProviderBuiltinById(
        'deepseek',
      )!.copyWith(apiKey: 'test-key', enabled: true);
      final initializer = AiProviderInitializer(
        config: provider,
        chatModel: provider.models.first,
      );

      addTearDown(initializer.dispose);
      await expectLater(initializer.initialize(), completes);
    },
  );
}

// 职责: 验证 OpenRouter 固定路由、推理参数、完整推理回传。
// 关联文件:
//   lib/shared/agent/client/openai_client.dart
//   lib/shared/services/ai/provider_initializer.dart
//   lib/shared/agent/round_assembler.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/agent/agent_config.dart';
import 'package:reveric/shared/agent/agent_event.dart';
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/agent/client/openai_client.dart';
import 'package:reveric/shared/agent/round_assembler.dart';
import 'package:reveric/shared/services/ai/provider_initializer.dart';

const details = [
  {
    'type': 'reasoning.text',
    'index': 0,
    'id': 'r1',
    'format': 'anthropic-claude-v1',
    'text': 'think',
    'signature': 'signed',
    'future': {'v': 1},
  },
  {
    'type': 'reasoning.encrypted',
    'index': 1,
    'id': null,
    'format': 'openai-responses-v1',
    'data': 'secret',
  },
];

List<AgentMessage> history(String? signature) => [
  AgentMessage.assistant(
    id: 'a',
    content: '',
    blocks: [
      ThinkingBlock('think', signature: signature),
      const ToolCallBlock(callId: 'c', toolName: 'Read', arguments: {}),
    ],
  ),
  const AgentMessage(
    id: 't',
    role: AgentMessageRole.user,
    type: AgentMessageType.tool_result,
    blocks: [
      ToolResultBlock(
        toolCallId: 'c',
        toolName: 'Read',
        content: [TextBlock('done')],
      ),
    ],
  ),
];

http.Response response() => http.Response(
  jsonEncode({
    'choices': [
      {
        'index': 0,
        'message': {
          'role': 'assistant',
          'content': 'ok',
          'reasoning_details': details,
        },
        'finish_reason': 'stop',
      },
    ],
  }),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  test('fixed channel routes chat and retains all model lists', () async {
    final provider = aiProviderBuiltinById('openai')!.copyWith(
      type: 'openrouter',
      apiKey: 'key',
      baseUrl: 'https://ignored.invalid',
      enabled: true,
      models: ['openai/gpt-5.4'],
      imageModels: ['openai/gpt-image-1'],
      videoModels: ['google/veo-3.1'],
      audioModels: ['bytedance-seed/seed-audio-1-0'],
    );
    final restored = AiProvider.fromJson(provider.toJson());
    expect(restored.supportedModelKinds, AiModelKind.values.toSet());
    expect(restored.hasFixedBaseUrl, isTrue);
    expect(restored.isValid, isTrue);
    expect(restored.copyWith(apiKey: '').isValid, isFalse);
    expect(customAiProviderTypes, contains(AiProviderType.openrouter));
    expect(
      AiSettings(
        providers: [provider],
      ).availableModelOptions.first.reasoningEfforts,
      contains('high'),
    );
    final initializer = AiProviderInitializer(
      config: restored,
      chatModel: provider.models.first,
      httpClient: MockClient((r) async {
        expect(r.url.origin, 'https://openrouter.ai');
        expect(r.headers['Authorization'], 'Bearer key');
        expect(r.url.path, '/api/v1/chat/completions');
        expect((jsonDecode(r.body) as Map)['reasoning'], {'effort': 'high'});
        return response();
      }),
    );
    addTearDown(initializer.dispose);
    final client = await initializer.initialize();
    final result = await client.chat(
      messages: [AgentMessage.user(id: 'u', content: 'hi')],
      options: const AgentConfig(reasoningEffort: 'high'),
    );
    expect(result.thinking, 'think');
  });

  for (final effort in [null, 'none', 'on', 'max']) {
    test('reasoning $effort uses the OpenRouter request envelope', () async {
      final client = OpenAiClient(
        apiKey: 'key',
        baseUrl: 'https://openrouter.ai/api/v1',
        model: 'vendor/model',
        useOpenRouter: true,
        useThinkingField: true,
        httpClient: MockClient((r) async {
          final body = jsonDecode(r.body) as Map;
          expect(body['reasoning'], switch (effort) {
            null => null,
            'none' => {'enabled': false},
            'on' => {'enabled': true},
            _ => {'effort': effort},
          });
          expect(body.containsKey('reasoning_effort'), false);
          expect(body.containsKey('thinking'), false);
          return response();
        }),
      );
      final result = await client.chat(
        messages: [AgentMessage.user(id: 'u', content: 'hi')],
        options: AgentConfig(reasoningEffort: effort),
      );
      expect(
        client
            .convertMessages(history(result.signature))
            .first
            .toJson()['reasoning_details'],
        details,
      );
    });
  }

  test(
    'streamed tool round preserves ordered reasoning metadata for the next turn',
    () async {
      String chunk(Map<String, dynamic> delta, [String? finish]) =>
          'data: ${jsonEncode({
            'id': 'c',
            'created': 1,
            'model': 'm',
            'choices': [
              {'index': 0, 'delta': delta, 'finish_reason': finish},
            ],
          })}\n\n';
      final payload =
          '${chunk({
            'reasoning_details': [
              {...details.first, 'text': 'thi', 'signature': 'sig'},
            ],
          })}'
          '${chunk({
            'reasoning_details': [
              {'type': 'reasoning.text', 'index': 0, 'text': 'nk', 'signature': 'ned'},
              details.last,
            ],
          })}'
          '${chunk({
            'tool_calls': [
              {
                'index': 0,
                'id': 'c',
                'type': 'function',
                'function': {'name': 'Read', 'arguments': '{}'},
              },
            ],
          }, 'tool_calls')}'
          'data: [DONE]\n\n';
      final client = OpenAiClient(
        apiKey: 'key',
        baseUrl: 'https://openrouter.ai/api/v1',
        model: 'vendor/model',
        useOpenRouter: true,
        streamClientFactory: () => MockClient((r) async {
          expect((jsonDecode(r.body) as Map)['reasoning'], {'enabled': true});
          return http.Response(
            payload,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      final rounds = await assembleRound(
        client.chatStream(
          messages: [AgentMessage.user(id: 'u', content: 'go')],
          options: const AgentConfig(reasoningEffort: 'on'),
        ),
      ).toList();
      final result = rounds.whereType<AgentRoundComplete>().single.result;
      expect(result.thinking, 'think');
      expect(result.toolCalls.single.toolName, 'Read');
      expect(result.encryptedContents, isEmpty);
      expect(
        client
            .convertMessages(history(result.thinkingSignature))
            .first
            .toJson()['reasoning_details'],
        details,
      );
    },
  );
}

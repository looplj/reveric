// 职责: 验证插件 AI 的模型列表、模型与推理档位选择、输出上限透传、finishReason 与用量身份。
// 关联文件:
//   lib/shared/services/plugins/ai.dart
//   lib/shared/services/ai/chat.dart
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/agent/client.dart' show StreamFinishReason;
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/models_catalog.dart';
import 'package:reveric/shared/services/ai/chat.dart';
import 'package:reveric/shared/services/ai/usage_service.dart';
import 'package:reveric/shared/services/plugins/ai.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';

const reasoningModel = 'gpt-5';

Map<String, dynamic> responseBody({
  required String text,
  String status = 'completed',
  String? incompleteReason,
}) => {
  'id': 'completion',
  'object': 'response',
  'created_at': 1,
  'status': status,
  'model': 'test-model',
  if (incompleteReason != null)
    'incomplete_details': {'reason': incompleteReason},
  'output': [
    if (text.isNotEmpty)
      {
        'type': 'message',
        'id': 'msg',
        'role': 'assistant',
        'status': 'completed',
        'content': [
          {'type': 'output_text', 'text': text, 'annotations': []},
        ],
      },
  ],
  'usage': {'input_tokens': 11, 'output_tokens': 3, 'total_tokens': 14},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PluginAiRequest.fromArgs', () {
    PluginAiRequest parse(Map<String, dynamic> args) =>
        PluginAiRequest.fromArgs(args, pluginId: 'p', label: 'tool:T');
    Matcher invalid() => throwsA(
      isA<PluginHostError>().having((e) => e.code, 'code', 'invalid_argument'),
    );

    test('accepts optional model, effort and up to 64k output tokens', () {
      final request = parse({
        'system': '',
        'prompt': 'Hi',
        'providerId': 'p1',
        'model': 'm1',
        'maxOutputTokens': pluginAiMaxOutputTokens,
        'reasoningEffort': 'low',
      });
      expect(request.providerId, 'p1');
      expect(request.model, 'm1');
      expect(request.maxOutputTokens, 65536);
      expect(request.reasoningEffort, 'low');
      expect(parse({'system': 's', 'prompt': 'p'}).maxOutputTokens, isNull);
    });

    test('rejects invalid arguments', () {
      expect(() => parse({'system': 's', 'prompt': ' '}), invalid());
      expect(() => parse({'prompt': 'p'}), invalid());
      expect(
        () => parse({'system': 's', 'prompt': 'p', 'providerId': 'p1'}),
        invalid(),
      );
      expect(
        () => parse({'system': 's', 'prompt': 'p', 'maxOutputTokens': 65537}),
        invalid(),
      );
      expect(
        () => parse({'system': 's', 'prompt': 'p', 'maxOutputTokens': 0}),
        invalid(),
      );
      expect(
        () => parse({'system': 's', 'prompt': 'p', 'reasoningEffort': 1}),
        invalid(),
      );
    });
  });

  test(
    'lists models, selects default or explicit model and reports finish reason',
    () async {
      expect(lookupCatalogReasoningEfforts(reasoningModel), isNotEmpty);
      final db = AppDatabase.forTest(NativeDatabase.memory());
      final provider = AiProvider(
        id: 'test-provider',
        name: 'Test',
        builtin: false,
        type: 'openai',
        enabled: true,
        apiKey: 'test',
        baseUrl: 'https://example.invalid/v1',
        models: const ['test-model', reasoningModel],
        imageModels: const [],
        embeddingModels: const [],
        audioModels: const [],
        videoModels: const [],
        temperature: 0.7,
        maxTurns: 8,
        proxyUrl: '',
        proxyUsername: '',
        proxyPassword: '',
        updatedAt: DateTime(2026),
        deletedAt: notDeletedSentinel,
      );
      var settings = AiSettings(providers: [provider]);
      final requests = <Map<String, dynamic>>[];
      var reply = responseBody(text: 'Suggestion');
      final httpClient = MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode(reply),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = PluginAiService(
        settings: () => settings,
        usageService: UsageService(appDatabase: db),
        clientFactory: (config, model, effort) => AiClient(
          config,
          chatModel: model,
          reasoningEffort: effort,
          httpClient: httpClient,
        ),
      );
      PluginAiRequest input({
        String? model,
        int? maxOutputTokens,
        String? effort,
      }) => PluginAiRequest(
        pluginId: 'test.memory',
        label: 'task:organize',
        runId: 'run-1',
        system: 'System',
        prompt: 'Refine',
        providerId: model == null ? null : 'test-provider',
        model: model,
        maxOutputTokens: maxOutputTokens,
        reasoningEffort: effort,
      );
      Future<void> rejects(
        String code,
        PluginAiRequest request, {
        AgentCancellationToken? token,
      }) => expectLater(
        service.generate(request, token ?? AgentCancellationController().token),
        throwsA(isA<PluginHostError>().having((e) => e.code, 'code', code)),
      );
      try {
        final models = service.listModels();
        expect(models.map((m) => m['model']), ['test-model', reasoningModel]);
        expect(models.first['providerId'], 'test-provider');
        expect(models.first['isDefault'], false);
        expect(models.first['reasoningEfforts'], isNull);
        expect(models.last['reasoningEfforts'], isNotEmpty);

        await rejects('model_not_configured', input());
        await rejects('model_not_found', input(model: 'missing'));
        await rejects(
          'invalid_argument',
          input(model: 'test-model', effort: 'low'),
        );
        await rejects(
          'invalid_argument',
          input(model: reasoningModel, effort: 'bogus'),
        );
        expect(requests, isEmpty);

        settings = settings.copyWith(
          defaultChatModelId: 'test-provider::test-model',
        );
        expect(service.listModels().first['isDefault'], true);
        final result = await service.generate(
          input(maxOutputTokens: 60000),
          AgentCancellationController().token,
        );
        expect(result.text, 'Suggestion');
        expect(result.finishReason, 'stop');
        expect(result.model, 'test-model');
        expect(result.usage['input_tokens'], 11);
        expect(requests.single['model'], 'test-model');
        expect(requests.single['max_output_tokens'], 60000);
        final usages = await db.select(db.aiUsages).get();
        expect(usages.single.source, UsageSources.plugin);
        expect(usages.single.runId, 'run-1');
        expect(usages.single.runLabel, 'test.memory/task:organize');
        expect(usages.single.sessionId, isNull);

        final efforts = lookupCatalogReasoningEfforts(reasoningModel)!;
        final effort = efforts.contains('low') ? 'low' : efforts.last;
        reply = responseBody(
          text: '',
          status: 'incomplete',
          incompleteReason: 'max_output_tokens',
        );
        final truncated = await service.generate(
          input(model: reasoningModel, effort: effort),
          AgentCancellationController().token,
        );
        expect(truncated.text, isEmpty);
        expect(truncated.finishReason, 'length');
        expect(truncated.model, reasoningModel);
        expect(requests.last['model'], reasoningModel);
        expect((requests.last['reasoning'] as Map)['effort'], effort);

        final cancellation = AgentCancellationController()..cancel();
        await rejects('cancelled', input(), token: cancellation.token);
        expect(requests, hasLength(2));

        for (final status in ['failed', 'cancelled', 'queued', 'in_progress']) {
          reply = responseBody(text: '', status: status);
          await rejects('ai_error', input());
        }

        reply = responseBody(text: '', status: 'incomplete');
        final unknown = await service.generate(
          input(),
          AgentCancellationController().token,
        );
        expect(unknown.finishReason, 'unknown');

        reply = responseBody(
          text: '',
          status: 'incomplete',
          incompleteReason: 'content_filter',
        );
        final filtered = await service.generate(
          input(),
          AgentCancellationController().token,
        );
        expect(filtered.finishReason, 'content_filter');

        final client = AiClient(
          provider,
          chatModel: 'test-model',
          httpClient: httpClient,
        );
        final messages = [AiMessage.user(id: 'test', content: 'Hi')];
        try {
          await client.initialize();
          final response = await client.chatCompletionDetachedResponse(
            messages,
            timeout: const Duration(seconds: 5),
          );
          expect(response.text, isEmpty);
          expect(response.finishReason, StreamFinishReason.contentFilter);
          expect(response.usage?.inputTokens, 11);
          final emptyResponse = throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              contains('Empty response from provider'),
            ),
          );
          await expectLater(client.chatCompletion(messages), emptyResponse);
          await expectLater(
            client.chatCompletionDetached(
              messages,
              timeout: const Duration(seconds: 5),
            ),
            emptyResponse,
          );
          reply = responseBody(text: 'Hello');
          expect(await client.chatCompletion(messages), 'Hello');
          expect(
            await client.chatCompletionDetached(
              messages,
              timeout: const Duration(seconds: 5),
            ),
            'Hello',
          );
        } finally {
          client.dispose();
        }
      } finally {
        httpClient.close();
        await db.close();
      }
    },
  );
}

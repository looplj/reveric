// 职责: 验证任务默认模型选择、真实请求输出预算、用量身份与取消边界。
// 关联文件:
//   lib/shared/services/plugins/task_ai.dart
//   lib/shared/services/ai/chat.dart
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/services/ai/chat.dart';
import 'package:reveric/shared/services/ai/usage_service.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';
import 'package:reveric/shared/services/plugins/task_ai.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'explicit default, wire budget, usage identity and preflight limits',
    () async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      final provider = AiProvider(
        id: 'test-provider',
        name: 'Test',
        builtin: false,
        type: 'openai',
        enabled: true,
        apiKey: 'test',
        baseUrl: 'https://example.invalid/v1',
        models: const ['test-model'],
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
      final httpClient = MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'id': 'completion',
            'object': 'response',
            'created_at': 1,
            'status': 'completed',
            'model': 'test-model',
            'output': [
              {
                'type': 'message',
                'id': 'msg',
                'role': 'assistant',
                'status': 'completed',
                'content': [
                  {
                    'type': 'output_text',
                    'text': 'Suggestion',
                    'annotations': [],
                  },
                ],
              },
            ],
            'usage': {
              'input_tokens': 11,
              'output_tokens': 3,
              'total_tokens': 14,
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = PluginTaskAiService(
        settings: () => settings,
        usageService: UsageService(appDatabase: db),
        clientFactory: (config, model, effort) => AiClient(
          config,
          chatModel: model,
          reasoningEffort: effort,
          httpClient: httpClient,
        ),
      );
      PluginTaskAiRequest input({String prompt = 'Refine'}) =>
          PluginTaskAiRequest(
            pluginId: 'test.memory',
            taskId: 'organize',
            runId: 'run-1',
            system: 'System',
            prompt: prompt,
            maxOutputTokens: 37,
          );
      Future<void> rejects(
        String code, {
        String prompt = 'Refine',
        AgentCancellationToken? token,
      }) => expectLater(
        service.generate(
          input(prompt: prompt),
          token ?? AgentCancellationController().token,
        ),
        throwsA(isA<PluginHostError>().having((e) => e.code, 'code', code)),
      );
      try {
        await rejects('model_not_configured');
        expect(requests, isEmpty);
        settings = settings.copyWith(
          defaultChatModelId: 'test-provider::test-model',
        );
        final result = await service.generate(
          input(),
          AgentCancellationController().token,
        );
        expect(result.text, 'Suggestion');
        expect(requests.single['model'], 'test-model');
        expect(requests.single['max_output_tokens'], 37);
        expect(result.usage['input_tokens'], 11);
        final usages = await db.select(db.aiUsages).get();
        expect(usages.single.source, UsageSources.pluginTask);
        expect(usages.single.runId, 'run-1');
        expect(usages.single.runLabel, 'test.memory/organize');
        expect(usages.single.sessionId, isNull);
        final cancellation = AgentCancellationController()..cancel();
        await rejects('cancelled', token: cancellation.token);
        await rejects('context_limit', prompt: '字' * 1000000);
        expect(requests, hasLength(1));
      } finally {
        httpClient.close();
        await db.close();
      }
    },
  );
}

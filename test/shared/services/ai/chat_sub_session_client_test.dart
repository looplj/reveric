// 职责: 验证 AiClient 按子会话派生 ProviderClient 的复用、回退与释放行为
// 关联文件:
//   lib/shared/services/ai/chat.dart
//   lib/shared/agent/client/trace_headers_http_client.dart
//   lib/shared/services/ai/theater_orchestrator.dart
//   lib/shared/services/ai/agent_council_orchestrator.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/client/trace_headers_http_client.dart';
import 'package:reveric/shared/database/app_database.dart'
    show notDeletedSentinel;
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/services/ai/chat.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const model = 'fake-chat';
  final provider = AiProvider(
    asrModels: const [],
    audioModels: const [],
    videoModels: const [],
    id: 'fake_provider',
    name: 'Fake Provider',
    builtin: false,
    type: 'openai',
    enabled: true,
    apiKey: 'test-api-key',
    baseUrl: 'https://example.invalid/v1',
    models: const [model],
    imageModels: const [],
    embeddingModels: const [],
    temperature: 0.7,
    maxTurns: 8,
    proxyUrl: '',
    proxyUsername: '',
    proxyPassword: '',
    updatedAt: DateTime(2026, 1, 1),
    deletedAt: notDeletedSentinel,
  );

  AiClient buildClient({bool withSubSessionHeaders = true}) {
    return AiClient(
      provider,
      chatModel: model,
      traceHeadersProvider: () => buildTraceSessionHeaders(
        sessionId: 'theater_1',
        sessionMode: 'theater',
      ),
      subSessionTraceHeaders: withSubSessionHeaders
          ? (subSessionId) => buildTraceSessionHeaders(
              sessionId: subSessionId,
              parentSessionId: 'theater_1',
              sessionMode: 'theater',
            )
          : null,
    );
  }

  test(
    'reuses one client per sub session and keeps sub sessions apart',
    () async {
      final service = buildClient();
      addTearDown(service.dispose);
      await service.initialize();

      final a1 = await service.providerClientForSubSession(
        'sub_theater_1_char_a',
      );
      final a2 = await service.providerClientForSubSession(
        'sub_theater_1_char_a',
      );
      final b = await service.providerClientForSubSession(
        'sub_theater_1_char_b',
      );

      expect(a1, isNotNull);
      expect(identical(a1, a2), isTrue);
      expect(identical(a1, b), isFalse);
      // 子会话 client 与父会话 client 必须是两个实例，否则 trace 头还是父会话的。
      expect(identical(a1, service.providerClient), isFalse);
    },
  );

  test('falls back to null without a sub session header provider', () async {
    final service = buildClient(withSubSessionHeaders: false);
    addTearDown(service.dispose);
    await service.initialize();

    expect(
      await service.providerClientForSubSession('sub_theater_1_char_a'),
      isNull,
    );
  });

  test('falls back to null for an empty sub session id', () async {
    final service = buildClient();
    addTearDown(service.dispose);
    await service.initialize();

    expect(await service.providerClientForSubSession(''), isNull);
  });

  test('stops handing out sub session clients after dispose', () async {
    final service = buildClient();
    await service.initialize();
    expect(
      await service.providerClientForSubSession('sub_theater_1_char_a'),
      isNotNull,
    );

    service.dispose();

    expect(
      await service.providerClientForSubSession('sub_theater_1_char_a'),
      isNull,
    );
  });
}

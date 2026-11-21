// 职责: 验证 AI http.Client 租约的共享、引用计数关闭与代理配置隔离
// 关联文件:
//   lib/shared/services/ai/ai_http_client_lease.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/providers/ai_providers.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/services/ai/ai_http_client_lease.dart';

void main() {
  group('AiHttpClientRegistry', () {
    test('keeps a shared client open until every consumer releases it', () {
      final clients = <_RecordingClient>[];
      final registry = AiHttpClientRegistry(
        clientFactory: (_) {
          final client = _RecordingClient();
          clients.add(client);
          return client;
        },
      );

      final first = registry.acquire(_provider());
      final second = registry.acquire(_provider());

      expect(first.client, same(second.client));
      expect(registry.debugRefCountFor(_provider()), 2);

      first.release();

      expect(clients.single.closed, isFalse);
      expect(registry.debugRefCountFor(_provider()), 1);

      second.release();

      expect(clients.single.closed, isTrue);
      expect(registry.debugRefCountFor(_provider()), 0);

      second.release();
      expect(clients.single.closeCount, 1);
    });

    test('uses a separate client after proxy settings change', () {
      final clients = <_RecordingClient>[];
      final registry = AiHttpClientRegistry(
        clientFactory: (_) {
          final client = _RecordingClient();
          clients.add(client);
          return client;
        },
      );
      final direct = _provider();
      final proxied = _provider(proxyUrl: 'http://127.0.0.1:7890');

      final directLease = registry.acquire(direct);
      final proxiedLease = registry.acquire(proxied);

      expect(directLease.client, isNot(same(proxiedLease.client)));
      expect(clients, hasLength(2));

      directLease.release();
      proxiedLease.release();

      expect(clients.every((client) => client.closed), isTrue);
    });
  });
}

AiProvider _provider({String proxyUrl = ''}) {
  return AiProvider(
    asrModels: const [],
    audioModels: const [],
    videoModels: const [],
    id: 'provider_1',
    name: 'Test Provider',
    builtin: false,
    type: 'openai',
    enabled: true,
    apiKey: 'test-api-key',
    baseUrl: 'https://example.invalid/v1',
    models: const ['gpt-test'],
    imageModels: const [],
    embeddingModels: const [],
    temperature: 0.7,
    maxTurns: 8,
    proxyUrl: proxyUrl,
    proxyUsername: '',
    proxyPassword: '',
    updatedAt: DateTime(2026, 1, 1),
    deletedAt: notDeletedSentinel,
  );
}

class _RecordingClient extends http.BaseClient {
  bool closed = false;
  int closeCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw UnimplementedError('This test only verifies ownership.');
  }

  @override
  void close() {
    closed = true;
    closeCount++;
  }
}

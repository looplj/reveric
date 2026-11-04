// 职责: RetryDecorator 测试 — 验证短暂网络错误重试、非流式请求超时与流式输出后的不重试边界。
// 关联文件:
//   lib/shared/agent/client.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show ClientException;
import 'package:reveric/shared/agent/agent_config.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/agent/client.dart';
import 'package:reveric/shared/agent/message.dart';

void main() {
  group('RetryDecorator', () {
    test('retries chat on HandshakeException', () async {
      final inner = _FakeProviderClient(chatFailuresBeforeSuccess: 2);
      final client = RetryDecorator(
        inner: inner,
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
      );

      final response = await client.chat(messages: const []);

      expect(response.text, 'ok');
      expect(inner.chatAttempts, 3);
    });

    test('retries chat on HTTP 500 ApiException-shaped errors', () async {
      final inner = _FakeProviderClient(
        chatFailuresBeforeSuccess: 1,
        chatFailure: const _StatusCodeException(500),
      );
      final client = RetryDecorator(
        inner: inner,
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
      );

      final response = await client.chat(messages: const []);

      expect(response.text, 'ok');
      expect(inner.chatAttempts, 2);
    });

    test('retries HTTP 429 when rate-limit retry is enabled', () async {
      final inner = _FakeProviderClient(
        chatFailuresBeforeSuccess: 1,
        chatFailure: const _StatusCodeException(429),
      );
      final client = RetryDecorator(
        inner: inner,
        retryRateLimits: true,
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
      );

      final response = await client.chat(messages: const []);

      expect(response.text, 'ok');
      expect(inner.chatAttempts, 2);
    });

    test('does not retry HTTP 429 when rate-limit retry is disabled', () async {
      final inner = _FakeProviderClient(
        chatFailuresBeforeSuccess: 1,
        chatFailure: const _StatusCodeException(429),
      );
      final client = RetryDecorator(
        inner: inner,
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
      );

      await expectLater(
        client.chat(messages: const []),
        throwsA(isA<_StatusCodeException>()),
      );
      expect(inner.chatAttempts, 1);
    });

    test(
      'does not retry chat on HTTP 400 ApiException-shaped errors',
      () async {
        final inner = _FakeProviderClient(
          chatFailuresBeforeSuccess: 1,
          chatFailure: const _StatusCodeException(400),
        );
        final client = RetryDecorator(
          inner: inner,
          baseDelay: Duration.zero,
          maxDelay: Duration.zero,
        );

        await expectLater(
          client.chat(messages: const []),
          throwsA(isA<_StatusCodeException>()),
        );
        expect(inner.chatAttempts, 1);
      },
    );

    test('times out a hung chat and retries with a fresh request', () async {
      // 移动端切后台后连接半开：服务端已返回，客户端的 future 永不完成。
      final inner = _FakeProviderClient(chatHangsBeforeSuccess: 1);
      final client = RetryDecorator(
        inner: inner,
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
        requestTimeout: const Duration(milliseconds: 50),
      );

      final response = await client.chat(messages: const []);

      expect(response.text, 'ok');
      expect(inner.chatAttempts, 2);
    });

    test('throws TimeoutException when every chat attempt hangs', () async {
      final inner = _FakeProviderClient(chatHangsBeforeSuccess: 99);
      final client = RetryDecorator(
        inner: inner,
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
        requestTimeout: const Duration(milliseconds: 50),
      );

      await expectLater(
        client.chat(messages: const []),
        throwsA(isA<TimeoutException>()),
      );
      expect(inner.chatAttempts, 3);
    });

    test(
      'chatStream forwards without retry even before any event is emitted',
      () async {
        // RetryDecorator.chatStream 不再重试（纯转发）；流式重试由 Agent 层负责。
        final inner = _FakeProviderClient(streamFailuresBeforeSuccess: 1);
        final client = RetryDecorator(
          inner: inner,
          baseDelay: Duration.zero,
          maxDelay: Duration.zero,
        );

        await expectLater(
          client.chatStream(messages: const []).toList(),
          throwsA(isA<HandshakeException>()),
        );
        expect(inner.streamAttempts, 1);
      },
    );

    test(
      'chatStream forwards without retry after an event is emitted',
      () async {
        final inner = _FakeProviderClient(streamFailsAfterEvent: true);
        final client = RetryDecorator(
          inner: inner,
          baseDelay: Duration.zero,
          maxDelay: Duration.zero,
        );

        await expectLater(
          client.chatStream(messages: const []).toList(),
          throwsA(isA<HandshakeException>()),
        );
        expect(inner.streamAttempts, 1);
      },
    );

    test('chatStream forwards a successful stream unchanged', () async {
      final inner = _FakeProviderClient();
      final client = RetryDecorator(
        inner: inner,
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
      );

      final events = await client.chatStream(messages: const []).toList();

      expect(events.whereType<TextDelta>().single.text, 'ok');
      expect(inner.streamAttempts, 1);
    });
  });

  group('isTransientNetworkError', () {
    test('classifies transient network errors as retryable', () {
      expect(
        isTransientNetworkError(ClientException('Connection closed')),
        isTrue,
      );
      expect(
        isTransientNetworkError(SocketException('Connection refused')),
        isTrue,
      );
      expect(
        isTransientNetworkError(HandshakeException('handshake failed')),
        isTrue,
      );
      expect(isTransientNetworkError(TimeoutException('timed out')), isTrue);
      expect(isTransientNetworkError(const _StatusCodeException(500)), isTrue);
      expect(isTransientNetworkError(const _StatusCodeException(503)), isTrue);
      expect(isTransientNetworkError(const _StatusCodeException(429)), isFalse);
    });

    test('classifies non-transient errors as non-retryable', () {
      expect(isTransientNetworkError(const _StatusCodeException(400)), isFalse);
      expect(isTransientNetworkError(const _StatusCodeException(401)), isFalse);
      expect(isTransientNetworkError(StateError('boom')), isFalse);
    });
  });

  group('streamRetryDelay', () {
    test('exponential backoff bounded by maxDelay', () {
      expect(streamRetryDelay(1), const Duration(milliseconds: 600));
      expect(streamRetryDelay(2), const Duration(milliseconds: 1200));
      expect(streamRetryDelay(3), const Duration(milliseconds: 2400));
      // 高 attempt 被默认 maxDelay（5s）截断。
      expect(streamRetryDelay(10), const Duration(seconds: 5));
    });
  });
}

class _FakeProviderClient implements ProviderClient {
  _FakeProviderClient({
    this.chatFailuresBeforeSuccess = 0,
    this.chatHangsBeforeSuccess = 0,
    this.streamFailuresBeforeSuccess = 0,
    this.streamFailsAfterEvent = false,
    this.chatFailure = const HandshakeException(
      'Connection terminated during handshake',
    ),
  });

  final int chatFailuresBeforeSuccess;
  final int chatHangsBeforeSuccess;
  final int streamFailuresBeforeSuccess;
  final bool streamFailsAfterEvent;
  final Object chatFailure;

  int chatAttempts = 0;
  int streamAttempts = 0;

  @override
  Future<ChatResponse> chat({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async {
    chatAttempts += 1;
    if (chatAttempts <= chatHangsBeforeSuccess) {
      return Completer<ChatResponse>().future;
    }
    if (chatAttempts <= chatFailuresBeforeSuccess) {
      throw chatFailure;
    }
    return const ChatResponse(text: 'ok');
  }

  @override
  Stream<StreamEvent> chatStream({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async* {
    streamAttempts += 1;
    if (streamAttempts <= streamFailuresBeforeSuccess) {
      throw HandshakeException('Connection terminated during handshake');
    }
    yield TextDelta('ok');
    if (streamFailsAfterEvent) {
      throw HandshakeException('Connection terminated during handshake');
    }
    yield StreamComplete();
  }

  @override
  void cancel() {}
}

class _StatusCodeException implements Exception {
  const _StatusCodeException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'ApiException($statusCode): test';
}

// 职责: 验证各 Provider 的 Agent 取消立即收尾，并隔离 SDK 的迟到响应和清理错误。
// 关联文件:
//   third/ai_clients_dart/packages/openai_dart/lib/src/resources/streaming_resource.dart
//   third/ai_clients_dart/packages/open_responses/lib/src/resources/streaming_resource.dart
//   lib/shared/agent/agent.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/error-handling.md

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:openai_dart/openai_dart.dart';
import 'package:open_responses/open_responses.dart' as responses;

import 'package:reveric/shared/agent/agent.dart';
import 'package:reveric/shared/agent/agent_config.dart';
import 'package:reveric/shared/agent/agent_event.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/agent/fake_agent.dart';
import 'package:reveric/shared/agent/client/openai_client.dart' as app;
import 'package:reveric/shared/agent/client/openai_responses_client.dart'
    as app;
import 'package:reveric/shared/agent/client/anthropic_client.dart' as app;
import 'package:reveric/shared/agent/client/gemini_client.dart' as app;
import 'package:reveric/shared/agent/client/codex_client.dart' as app;
import 'package:reveric/shared/services/ai/codex/credentials.dart';

/// send() 会一直挂起，直到 close() 被调用（模拟 abort 关闭 dedicated client
/// 使 in-flight send() 失败的真实路径）。
class _HangingSendClient extends http.BaseClient {
  final _sendStarted = Completer<void>();
  final _sendError = Completer<Exception>();
  bool closed = false;

  Future<void> get sendStarted => _sendStarted.future;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _sendStarted.complete();
    await _sendError.future;
    throw http.ClientException(
      'Connection closed before full header was received',
      request.url,
    );
  }

  @override
  void close() {
    closed = true;
    if (!_sendError.isCompleted) {
      _sendError.complete(http.ClientException('closed by abort', Uri()));
    }
  }
}

class _BodyStreamClient extends http.BaseClient {
  final body = StreamController<List<int>>();
  final listening = Completer<void>();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    body.onListen = () => listening.complete();
    return http.StreamedResponse(body.stream, 200, request: request);
  }

  @override
  void close() {
    if (closed) {
      return;
    }
    closed = true;
    body.addError(
      http.ClientException('Connection closed while receiving data'),
    );
    unawaited(body.close());
  }
}

/// close 不帮助 send 或响应体结束，用于验证取消不依赖 transport 配合。
class _UnresponsiveClient extends http.BaseClient {
  final started = Completer<void>();
  final response = Completer<http.StreamedResponse>();
  int closeCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    started.complete();
    return response.future;
  }

  @override
  void close() {
    closeCount++;
  }
}

OpenAIClient _clientWith(_HangingSendClient mock) => OpenAIClient.withApiKey(
  'sk-test',
  baseUrl: 'https://example.invalid',
  streamClientFactory: () => mock,
);

ChatCompletionCreateRequest _request() => ChatCompletionCreateRequest(
  model: 'custom-chat-model',
  messages: [ChatMessage.user('hi')],
);

void main() {
  for (final provider in [
    'Chat',
    'Responses',
    'Anthropic',
    'Gemini',
    'Codex',
  ]) {
    for (final withHeaders in [false, true]) {
      test(
        'Agent cancels $provider before transport settles headers=$withHeaders',
        () async {
          final mock = _UnresponsiveClient();
          final client = switch (provider) {
            'Chat' => app.OpenAiClient(
              apiKey: 'test',
              baseUrl: 'https://example.invalid',
              model: 'test',
              streamClientFactory: () => mock,
            ),
            'Responses' => app.OpenAIResponsesClient(
              apiKey: 'test',
              baseUrl: 'https://example.invalid',
              model: 'test',
              streamHttpClientFactory: () => mock,
            ),
            'Anthropic' => app.AnthropicClient(
              apiKey: 'test',
              model: 'test',
              streamHttpClientFactory: () => mock,
            ),
            'Gemini' => app.GeminiClient(
              apiKey: 'test',
              model: 'test',
              streamHttpClientFactory: () => mock,
            ),
            _ => app.CodexClient(
              model: 'test',
              credentials: () async => const CodexCredentials(
                accessToken: 'test',
                accountId: 'test',
              ),
              streamHttpClientFactory: () => mock,
            ),
          };
          final agent = Agent.custom(
            id: 'cancel',
            systemPrompt: 'test',
            client: client,
            config: const AgentConfig(),
            toolManager: FakeAgentToolDispatcher(),
          );
          final parentCancellation = AgentCancellationController();
          final result = agent
              .process(
                'hi',
                toolExecutionContext: ToolExecutionContext(
                  cancellationToken: parentCancellation.token,
                ),
              )
              .toList();
          await mock.started.future;
          final cleanup = Completer<void>();
          final listening = Completer<void>();
          final body = StreamController<List<int>>(
            onListen: listening.complete,
            onCancel: () => cleanup.future,
          );
          if (withHeaders) {
            mock.response.complete(http.StreamedResponse(body.stream, 200));
            await listening.future;
          }
          if (withHeaders) {
            parentCancellation.cancel();
          } else {
            agent.cancel();
          }
          try {
            final events = await result.timeout(
              const Duration(milliseconds: 500),
            );
            expect(events.whereType<AgentCancelled>(), hasLength(1));
            expect(events.whereType<AgentEnd>(), hasLength(1));
            expect(events.whereType<AgentRoundRetry>(), isEmpty);
            expect(agent.isProcessing, isFalse);
            expect(mock.closeCount, greaterThanOrEqualTo(1));
          } finally {
            if (!withHeaders) {
              mock.response.completeError(
                http.ClientException('late transport error'),
              );
            }
            cleanup.complete();
            unawaited(body.close());
            await result;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        },
      );
    }
  }
  test('Agent cancels Codex while credentials are pending', () async {
    final started = Completer<void>();
    final credentials = Completer<CodexCredentials>();
    final client = app.CodexClient(
      model: 'test',
      credentials: () {
        started.complete();
        return credentials.future;
      },
    );
    final agent = Agent.custom(
      id: 'cancel',
      systemPrompt: 'test',
      client: client,
      config: const AgentConfig(),
      toolManager: FakeAgentToolDispatcher(),
    );
    final result = agent.process('hi').toList();
    await started.future;
    agent.cancel();
    try {
      final events = await result.timeout(const Duration(milliseconds: 500));
      expect(events.whereType<AgentCancelled>(), hasLength(1));
      expect(agent.isProcessing, isFalse);
    } finally {
      credentials.complete(
        const CodexCredentials(accessToken: 'test', accountId: 'test'),
      );
      await result;
    }
  });
  group('SDK streaming abort containment', () {
    for (final useResponses in [false, true]) {
      for (final phase in ['pending error', 'pending response', 'body']) {
        test(
          '${useResponses ? 'Responses' : 'Chat'} abort without transport cooperation: $phase',
          () async {
            final mock = _UnresponsiveClient();
            final abort = Completer<void>();
            final cleanup = Completer<void>();
            var bodyCancelled = false;
            final body = StreamController<List<int>>(
              onCancel: () {
                bodyCancelled = true;
                return cleanup.future;
              },
            );
            final Stream<Object> stream;
            if (useResponses) {
              final client = responses.OpenResponsesClient.withApiKey(
                'test',
                streamClientFactory: () => mock,
              );
              addTearDown(client.close);
              stream = client.responses.createStream(
                responses.CreateResponseRequest.text(
                  model: 'test',
                  input: 'hi',
                ),
                abortTrigger: abort.future,
              );
            } else {
              final client = OpenAIClient.withApiKey(
                'test',
                streamClientFactory: () => mock,
              );
              addTearDown(client.close);
              stream = client.chat.completions.createStream(
                _request(),
                abortTrigger: abort.future,
              );
            }
            final events = <Object>[];
            final errors = <Object>[];
            final done = Completer<void>();
            final sub = stream.listen(
              events.add,
              onError: errors.add,
              onDone: done.complete,
            );
            await mock.started.future;
            if (phase == 'body') {
              final listening = Completer<void>();
              body.onListen = listening.complete;
              mock.response.complete(http.StreamedResponse(body.stream, 200));
              await listening.future;
            }
            abort.complete();
            try {
              // 必须先结束消费方，之后才放行底层请求或清理。
              await done.future.timeout(const Duration(milliseconds: 500));
              expect(mock.closeCount, 1);
              expect(events, isEmpty);
              expect(errors, isEmpty);
            } finally {
              if (!mock.response.isCompleted) {
                if (phase == 'pending error') {
                  mock.response.completeError(
                    http.ClientException('late error'),
                  );
                } else {
                  mock.response.complete(
                    http.StreamedResponse(body.stream, 200),
                  );
                }
              }
              cleanup.complete();
              unawaited(body.close());
              await Future<void>.delayed(const Duration(milliseconds: 10));
              await sub.cancel();
              if (phase != 'pending error') {
                expect(bodyCancelled, isTrue);
              }
            }
          },
        );
      }
      for (final abortRequest in [false, true]) {
        test(
          '${useResponses ? 'Responses' : 'Chat'} after headers: ${abortRequest ? 'abort is contained' : 'network failure propagates'}',
          () async {
            final mock = _BodyStreamClient();
            final abort = Completer<void>();
            final Stream<Object> stream;
            if (useResponses) {
              final client = responses.OpenResponsesClient.withApiKey(
                'sk-test',
                baseUrl: 'https://example.invalid',
                streamClientFactory: () => mock,
              );
              addTearDown(client.close);
              stream = client.responses.createStream(
                responses.CreateResponseRequest.text(
                  model: 'test',
                  input: 'hi',
                ),
                abortTrigger: abort.future,
              );
            } else {
              final client = OpenAIClient.withApiKey(
                'sk-test',
                baseUrl: 'https://example.invalid',
                streamClientFactory: () => mock,
              );
              addTearDown(client.close);
              stream = client.chat.completions.createStream(
                _request(),
                abortTrigger: abort.future,
              );
            }
            final errors = <Object>[];
            final done = Completer<void>();
            final sub = stream.listen(
              (_) {},
              onError: errors.add,
              onDone: done.complete,
            );
            await mock.listening.future;
            if (abortRequest) {
              abort.complete();
            } else {
              mock.close();
            }
            await done.future.timeout(const Duration(seconds: 2));
            await sub.cancel();
            expect(
              errors,
              abortRequest ? isEmpty : [isA<http.ClientException>()],
            );
            expect(mock.closed, isTrue);
          },
        );
      }
    }

    test('abort 触发在 send 挂起期时返回空响应，不再抛 AbortedException', () async {
      final mock = _HangingSendClient();
      final client = _clientWith(mock);
      final abort = Completer<void>();
      final events = <Object>[];
      final errors = <Object>[];

      final stream = client.chat.completions.createStream(
        _request(),
        abortTrigger: abort.future,
      );
      final sub = stream.listen(events.add, onError: errors.add);
      await mock.sendStarted;
      abort.complete(); // abort → 关闭 client → send() 失败
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      // 修复前：SDK 抛 AbortedException 被 onError 收到；修复后：空响应正常结束。
      expect(errors, isEmpty, reason: 'abort 是主动取消，不应作为错误上抛');
      expect(events, isEmpty);
    });

    test('abort 与消费方取消并发时不产生 zone 级 unhandled 错误', () async {
      final mock = _HangingSendClient();
      final client = _clientWith(mock);
      final abort = Completer<void>();
      final unhandled = <Object>[];

      await runZonedGuarded(
        () async {
          final stream = client.chat.completions.createStream(
            _request(),
            abortTrigger: abort.future,
          );
          final sub = stream.listen((_) {});
          await mock.sendStarted;
          // 与真实超时路径一致：abort 与消费方拆除订阅几乎同时发生。
          abort.complete();
          await sub.cancel();
          await Future<void>.delayed(const Duration(milliseconds: 200));
        },
        (error, stackTrace) {
          unhandled.add(error);
        },
      );

      expect(unhandled, isEmpty, reason: 'abort 引发的底层错误不得落入已取消的 async* 生成器');
    });
  });
}

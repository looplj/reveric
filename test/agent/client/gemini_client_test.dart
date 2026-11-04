// 职责: GeminiClient 测试 — message 转换与流式 finish reason 映射
// 关联文件:
//   lib/shared/agent/client/gemini_client.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:reveric/shared/agent/client.dart';
import 'package:reveric/shared/agent/client/gemini_client.dart';
import 'package:reveric/shared/agent/message.dart';

GeminiClient _make({http.Client? httpClient}) => GeminiClient(
  apiKey: 'k',
  model: 'gemini-2.0-flash',
  httpClient: httpClient,
);

String _finishReasonStream(String finishReason) {
  return 'data: ${jsonEncode({
    'candidates': [
      {'finishReason': finishReason},
    ],
    'usageMetadata': {'promptTokenCount': 1, 'candidatesTokenCount': 2, 'totalTokenCount': 3},
  })}\n\n';
}

void main() {
  group('GeminiClient.convertMessages', () {
    test('skips system messages', () {
      final out = _make().convertMessages([
        AgentMessage.system(id: 's1', content: 'sys'),
        AgentMessage.user(id: 'u1', content: 'hi'),
      ]);
      expect(out.length, 1);
      expect(out.first.toJson()['role'], 'user');
    });

    test('user text message emits text part with role=user', () {
      final out = _make().convertMessages([
        AgentMessage.user(id: 'u1', content: 'hello'),
      ]);
      final json = out.first.toJson();
      expect(json['role'], 'user');
      final parts = (json['parts'] as List).cast<Map>();
      expect(parts.first['text'], 'hello');
    });

    test('user with ImageBlock emits inlineData part', () {
      final out = _make().convertMessages([
        AgentMessage(
          id: 'u1',
          role: AgentMessageRole.user,
          content: 'see',
          blocks: const [ImageBlock(data: 'AAA=', mimeType: 'image/png')],
        ),
      ]);
      final parts = (out.first.toJson()['parts'] as List).cast<Map>();
      expect(parts.length, 2);
      expect(parts.first['text'], 'see');
      final inline = parts.last['inlineData'] as Map;
      expect(inline['mimeType'], 'image/png');
      expect(inline['data'], 'AAA=');
    });

    test('tool_result emits user role with functionResponse part', () {
      final out = _make().convertMessages([
        const AgentMessage(
          id: 'assistant_c1',
          role: AgentMessageRole.assistant,
          blocks: [
            ToolCallBlock(
              callId: 'call_1',
              toolName: 'Read',
              arguments: {'path': '/novel'},
            ),
          ],
        ),
        AgentMessage(
          id: 'tool_c1',
          role: AgentMessageRole.user,
          type: AgentMessageType.tool_result,
          blocks: const [
            ToolResultBlock(
              toolCallId: 'call_1',
              toolName: 'Read',
              content: [TextBlock('result body')],
            ),
          ],
        ),
      ]);
      expect(out.length, 2);
      final json = out.last.toJson();
      expect(json['role'], 'user');
      final part = (json['parts'] as List).first as Map;
      final fr = part['functionResponse'] as Map;
      expect(fr['name'], 'Read');
      expect(fr['id'], 'call_1');
      expect((fr['response'] as Map)['output'], 'result body');
    });

    test('tool_result with isError uses error key', () {
      final out = _make().convertMessages([
        const AgentMessage(
          id: 'assistant_c2',
          role: AgentMessageRole.assistant,
          blocks: [
            ToolCallBlock(callId: 'call_2', toolName: 'X', arguments: {}),
          ],
        ),
        AgentMessage(
          id: 'tool_e',
          role: AgentMessageRole.user,
          type: AgentMessageType.tool_result,
          blocks: const [
            ToolResultBlock(
              toolCallId: 'call_2',
              toolName: 'X',
              isError: true,
              content: [TextBlock('boom')],
            ),
          ],
        ),
      ]);
      final part = (out.last.toJson()['parts'] as List).first as Map;
      final response = (part['functionResponse'] as Map)['response'] as Map;
      expect(response['error'], 'boom');
      expect(response.containsKey('output'), isFalse);
    });

    test(
      'tool_result with image attaches inlineData parts in same user turn',
      () {
        final out = _make().convertMessages([
          const AgentMessage(
            id: 'assistant_c3',
            role: AgentMessageRole.assistant,
            blocks: [
              ToolCallBlock(
                callId: 'call_3',
                toolName: 'Screenshot',
                arguments: {},
              ),
            ],
          ),
          AgentMessage(
            id: 'tool_img',
            role: AgentMessageRole.user,
            type: AgentMessageType.tool_result,
            blocks: const [
              ToolResultBlock(
                toolCallId: 'call_3',
                toolName: 'Screenshot',
                content: [
                  TextBlock('see'),
                  ImageBlock(data: 'BBB=', mimeType: 'image/jpeg'),
                ],
              ),
            ],
          ),
        ]);
        expect(out.length, 2);
        final parts = (out.last.toJson()['parts'] as List).cast<Map>();
        expect(parts.length, 2);
        expect(parts.first.containsKey('functionResponse'), isTrue);
        expect(parts.last.containsKey('inlineData'), isTrue);
      },
    );

    test('consecutive tool_result messages merge into a single user turn', () {
      final out = _make().convertMessages([
        const AgentMessage(
          id: 'assistant_parallel',
          role: AgentMessageRole.assistant,
          blocks: [
            ToolCallBlock(callId: 'c1', toolName: 'A', arguments: {}),
            ToolCallBlock(callId: 'c2', toolName: 'B', arguments: {}),
          ],
        ),
        AgentMessage(
          id: 't1',
          role: AgentMessageRole.user,
          type: AgentMessageType.tool_result,
          blocks: const [
            ToolResultBlock(
              toolCallId: 'c1',
              toolName: 'A',
              content: [TextBlock('r1')],
            ),
          ],
        ),
        AgentMessage(
          id: 't2',
          role: AgentMessageRole.user,
          type: AgentMessageType.tool_result,
          blocks: const [
            ToolResultBlock(
              toolCallId: 'c2',
              toolName: 'B',
              content: [TextBlock('r2')],
            ),
          ],
        ),
      ]);
      expect(out.length, 2);
      final parts = (out.last.toJson()['parts'] as List).cast<Map>();
      expect(parts.length, 2);
    });

    test('consecutive user text messages merge into a single user turn', () {
      final out = _make().convertMessages([
        AgentMessage.user(id: 'u1', content: 'first'),
        AgentMessage.user(id: 'u2', content: 'second'),
      ]);
      expect(out.length, 1);
      final parts = (out.single.toJson()['parts'] as List).cast<Map>();
      expect(parts.map((p) => p['text']), ['first', 'second']);
    });

    test('consecutive assistant messages merge into a single model turn', () {
      final out = _make().convertMessages([
        AgentMessage.user(id: 'u1', content: 'task'),
        AgentMessage.assistant(id: 'a1', content: 'partial'),
        AgentMessage.assistant(id: 'a2', content: 'final'),
      ]);
      expect(out.length, 2);
      expect(out.last.toJson()['role'], 'model');
      final parts = (out.last.toJson()['parts'] as List).cast<Map>();
      expect(parts.map((p) => p['text']), ['partial', 'final']);
    });

    test('assistant with role=model and TextBlock', () {
      final out = _make().convertMessages([
        AgentMessage(
          id: 'a1',
          role: AgentMessageRole.assistant,
          content: 'answer',
        ),
      ]);
      final json = out.first.toJson();
      expect(json['role'], 'model');
      expect(((json['parts'] as List).first as Map)['text'], 'answer');
    });

    test(
      'assistant ToolCallBlock emits functionCall part with id and args',
      () {
        final out = _make().convertMessages([
          AgentMessage(
            id: 'a1',
            role: AgentMessageRole.assistant,
            blocks: const [
              ToolCallBlock(
                callId: 'cid',
                toolName: 'Read',
                arguments: {'path': '/x'},
              ),
            ],
          ),
          const AgentMessage(
            id: 'tool_cid',
            role: AgentMessageRole.user,
            type: AgentMessageType.tool_result,
            blocks: [
              ToolResultBlock(
                toolCallId: 'cid',
                toolName: 'Read',
                content: [TextBlock('ok')],
              ),
            ],
          ),
        ]);
        final json = out.first.toJson();
        expect(json['role'], 'model');
        final part = (json['parts'] as List).first as Map;
        final fc = part['functionCall'] as Map;
        expect(fc['name'], 'Read');
        expect(fc['id'], 'cid');
        expect(fc['args'], {'path': '/x'});
      },
    );

    test('lone surrogate in content sanitized', () {
      final lone = String.fromCharCode(0xD800);
      final out = _make().convertMessages([
        AgentMessage.user(id: 'u1', content: 'x${lone}y'),
      ]);
      final text =
          ((out.first.toJson()['parts'] as List).first as Map)['text']
              as String;
      expect(text.contains('\uFFFD'), isTrue);
    });

    test('ThinkingBlock with empty text is skipped', () {
      final out = _make().convertMessages([
        AgentMessage(
          id: 'a1',
          role: AgentMessageRole.assistant,
          blocks: const [ThinkingBlock('')],
        ),
      ]);
      // empty thinking → no parts → message dropped
      expect(out, isEmpty);
    });

    test(
      'ThinkingBlock with text + signature emits thought:true text part',
      () {
        final out = _make().convertMessages([
          AgentMessage(
            id: 'a1',
            role: AgentMessageRole.assistant,
            blocks: const [ThinkingBlock('reasoning', signature: 'sig')],
          ),
        ]);
        final part = ((out.first.toJson()['parts'] as List).first as Map);
        expect(part['thought'], true);
        expect(part['text'], 'reasoning');
        expect(part.containsKey('thoughtSignature'), isTrue);
      },
    );
  });

  test(
    'Gemini dedicated stream preserves custom host and normalizes version',
    () async {
      final requests = <Uri>[];
      final client = GeminiClient(
        apiKey: 'relay-key',
        model: 'gemini-test',
        baseUrl: ' https://relay.example/proxy/v1beta/?route=chat ',
        streamHttpClientFactory: () => MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            _finishReasonStream('STOP'),
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      final events = await client
          .chatStream(
            messages: [AgentMessage.user(id: 'user', content: 'hello')],
          )
          .toList();
      expect(events, isNotEmpty);
      expect(requests, hasLength(1));
      expect(requests.single.host, 'relay.example');
      expect(
        requests.single.path,
        '/proxy/v1beta/models/gemini-test:streamGenerateContent',
      );
      expect(requests.single.queryParameters['route'], 'chat');
      expect(requests.single.queryParameters['key'], 'relay-key');
    },
  );

  group('GeminiClient.chatStream', () {
    test(
      'cancel closes the dedicated stream client before response headers',
      () async {
        final streamClient = _BlockingClient();
        final client = GeminiClient(
          apiKey: 'k',
          model: 'gemini-2.0-flash',
          streamHttpClientFactory: () => streamClient,
        );
        final errors = <Object>[];
        final done = Completer<void>();

        client
            .chatStream(
              messages: [AgentMessage.user(id: 'u1', content: 'hi')],
            )
            .listen((_) {}, onError: errors.add, onDone: done.complete);

        await streamClient.sendStarted.future;
        client.cancel();
        await done.future;

        expect(streamClient.closed, isTrue);
        expect(errors, hasLength(1));
      },
      timeout: const Timeout(Duration(seconds: 2)),
    );

    const finishReasons = {
      'STOP': StreamFinishReason.stop,
      'MAX_TOKENS': StreamFinishReason.length,
      'SAFETY': StreamFinishReason.contentFilter,
      'RECITATION': StreamFinishReason.contentFilter,
      'MALFORMED_FUNCTION_CALL': StreamFinishReason.unknown,
    };

    for (final entry in finishReasons.entries) {
      test('maps ${entry.key} to ${entry.value.name}', () async {
        final client = _make(
          httpClient: _GeminiSseMockClient(_finishReasonStream(entry.key)),
        );

        final events = await client
            .chatStream(
              messages: [AgentMessage.user(id: 'u1', content: 'continue')],
            )
            .toList();

        expect(
          events.whereType<StreamComplete>().single.finishReason,
          entry.value,
        );
      });
    }

    test('maps prompt-level block reason to contentFilter', () async {
      final body =
          'data: ${jsonEncode({
            'promptFeedback': {'blockReason': 'PROHIBITED_CONTENT'},
          })}\n\n';
      final client = _make(httpClient: _GeminiSseMockClient(body));

      final events = await client
          .chatStream(
            messages: [AgentMessage.user(id: 'u1', content: 'continue')],
          )
          .toList();

      expect(
        events.whereType<StreamComplete>().single.finishReason,
        StreamFinishReason.contentFilter,
      );
    });

    test('completes when an inline error follows a terminal chunk', () async {
      final body =
          'data: ${jsonEncode({
            'candidates': [
              {'finishReason': 'STOP'},
            ],
            'usageMetadata': {'promptTokenCount': 10, 'candidatesTokenCount': 2, 'totalTokenCount': 12},
          })}\n\n'
          'event: error\n'
          'data: {"error":{"message":"late relay error"}}\n\n';
      final client = _make(httpClient: _GeminiSseMockClient(body));

      final events = await client
          .chatStream(
            messages: [AgentMessage.user(id: 'u1', content: 'continue')],
          )
          .toList();

      expect(events.whereType<StreamComplete>(), hasLength(1));
      expect(
        events.whereType<StreamComplete>().single.finishReason,
        StreamFinishReason.stop,
      );
      expect(events.whereType<StreamComplete>().single.usage?.totalTokens, 12);
    });
  });
}

class _GeminiSseMockClient extends http.BaseClient {
  _GeminiSseMockClient(this.body);

  final String body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(request.method, 'POST');
    expect(
      request.url.path,
      '/v1beta/models/gemini-2.0-flash:streamGenerateContent',
    );
    expect(request.url.queryParameters['alt'], 'sse');
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}

class _BlockingClient extends http.BaseClient {
  final sendStarted = Completer<void>();
  final _response = Completer<http.StreamedResponse>();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sendStarted.complete();
    return _response.future;
  }

  @override
  void close() {
    if (closed) {
      return;
    }
    closed = true;
    _response.completeError(http.ClientException('Client is already closed.'));
  }
}

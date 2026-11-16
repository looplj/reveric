// 职责: OpenAIResponsesClient 测试 — 输入输出转换、流式结束原因与取消
// 关联文件:
//   lib/shared/agent/client/openai_responses_client.dart
//   lib/shared/agent/client/provider_history_preflight.dart
//   lib/shared/agent/agent_config.dart
//   lib/shared/agent/client.dart

import 'package:reveric/shared/utils/ai_error.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_responses/open_responses.dart' as or;

import 'package:reveric/shared/agent/agent_config.dart';
import 'package:reveric/shared/agent/client.dart';
import 'package:reveric/shared/agent/client/openai_responses_client.dart';
import 'package:reveric/shared/agent/client/provider_history_preflight.dart';
import 'package:reveric/shared/agent/message.dart';

OpenAIResponsesClient _make({
  http.Client? httpClient,
  http.Client Function()? streamHttpClientFactory,
}) => OpenAIResponsesClient(
  apiKey: 'sk-test',
  baseUrl: 'https://example.invalid',
  model: 'gpt-5',
  httpClient: httpClient,
  streamHttpClientFactory: streamHttpClientFactory,
);

String _responsesSseEvent(Map<String, dynamic> data) {
  return 'event: ${data['type']}\n'
      'data: ${jsonEncode(data)}\n\n';
}

void main() {
  for (final streaming in [false, true]) {
    for (final (model, enabled, effort, expected) in [
      ('gpt-5.4', true, null, 0.3),
      ('gpt-5.4', false, null, null),
      ('gpt-5.4', true, 'high', null),
      ('gpt-6-sol', true, null, null),
    ]) {
      test(
        'Responses temperature $model enabled=$enabled effort=$effort stream=$streaming',
        () async {
          Map<String, dynamic>? body;
          http.Client transport() => MockClient((request) async {
            body = jsonDecode(request.body) as Map<String, dynamic>;
            final response = {
              'id': 'resp_1',
              'status': 'completed',
              'output': [],
            };
            return http.Response(
              streaming
                  ? _responsesSseEvent({
                      'type': 'response.completed',
                      'response': response,
                    })
                  : jsonEncode(response),
              200,
              headers: {
                'content-type': streaming
                    ? 'text/event-stream'
                    : 'application/json',
              },
            );
          });
          final client = OpenAIResponsesClient(
            apiKey: 'test',
            baseUrl: 'https://example.invalid',
            model: model,
            httpClient: transport(),
            streamHttpClientFactory: transport,
          );
          final messages = [AgentMessage.user(id: 'u', content: 'hi')];
          final options = AgentConfig(
            enableTemperature: enabled,
            temperature: 0.3,
            reasoningEffort: effort,
          );
          if (streaming) {
            await client
                .chatStream(messages: messages, options: options)
                .toList();
          } else {
            await client.chat(messages: messages, options: options);
          }
          expect(body!.containsKey('temperature'), expected != null);
          expect(body!['temperature'], expected);
        },
      );
    }
  }

  group('OpenAIResponsesClient.buildInputItems', () {
    test('skips system messages', () {
      final out = _make().buildInputItems([
        AgentMessage.system(id: 's1', content: 'sys'),
        AgentMessage.user(id: 'u1', content: 'hi'),
      ]);
      expect(out.length, 1);
      final json = out.first.toJson();
      expect(json['type'], 'message');
      expect(json['role'], 'user');
    });

    test('user with content emits input_text part', () {
      final out = _make().buildInputItems([
        AgentMessage.user(id: 'u1', content: 'hello'),
      ]);
      final json = out.first.toJson();
      final content = (json['content'] as List).cast<Map>();
      expect(content.first['type'], 'input_text');
      expect(content.first['text'], 'hello');
    });

    test('user with ImageBlock emits input_image part with data URL', () {
      final out = _make().buildInputItems([
        AgentMessage(
          id: 'u1',
          role: AgentMessageRole.user,
          content: 'see',
          blocks: const [ImageBlock(data: 'AAA=', mimeType: 'image/png')],
        ),
      ]);
      final content = (out.first.toJson()['content'] as List).cast<Map>();
      expect(content.first['type'], 'input_text');
      expect(content.first['text'], 'see');
      expect(content.last['type'], 'input_image');
      expect(content.last['image_url'], 'data:image/png;base64,AAA=');
    });

    test('tool_result with text only emits function_call_output string', () {
      final out = _make().buildInputItems([
        const AgentMessage(
          id: 'a1',
          role: AgentMessageRole.assistant,
          blocks: [
            ToolCallBlock(
              callId: 'call_1',
              toolName: 'Read',
              arguments: {'path': '/x'},
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
      final json = out[1].toJson();
      expect(json['type'], 'function_call_output');
      expect(json['call_id'], 'call_1');
      expect(json['output'], 'result body');
    });

    test('tool_result with image emits function_call_output content list', () {
      final out = _make().buildInputItems([
        const AgentMessage(
          id: 'a1',
          role: AgentMessageRole.assistant,
          blocks: [
            ToolCallBlock(
              callId: 'call_2',
              toolName: 'Screenshot',
              arguments: {'path': '/x'},
            ),
          ],
        ),
        AgentMessage(
          id: 'tool_img',
          role: AgentMessageRole.user,
          type: AgentMessageType.tool_result,
          blocks: const [
            ToolResultBlock(
              toolCallId: 'call_2',
              toolName: 'Screenshot',
              content: [
                TextBlock('see'),
                ImageBlock(data: 'BBB=', mimeType: 'image/jpeg'),
              ],
            ),
          ],
        ),
      ]);
      final json = out[1].toJson();
      expect(json['type'], 'function_call_output');
      expect(json['call_id'], 'call_2');
      final outputList = (json['output'] as List).cast<Map>();
      expect(outputList.length, 2);
      expect(outputList.first['type'], 'input_text');
      expect(outputList.last['type'], 'input_image');
    });

    test('assistant ToolCallBlock emits function_call item when paired', () {
      final out = _make().buildInputItems([
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
        AgentMessage(
          id: 'tool_cid',
          role: AgentMessageRole.user,
          type: AgentMessageType.tool_result,
          blocks: const [
            ToolResultBlock(
              toolCallId: 'cid',
              toolName: 'Read',
              content: [TextBlock('ok')],
            ),
          ],
        ),
      ]);
      final json = out.first.toJson();
      expect(json['type'], 'function_call');
      expect(json['call_id'], 'cid');
      expect(json['name'], 'Read');
      expect(json['arguments'], '{"path":"/x"}');
      expect(out[1].toJson()['type'], 'function_call_output');
    });

    test('assistant ToolCallBlock without output is rejected', () {
      expect(
        () => _make().buildInputItems([
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
        ]),
        throwsA(
          isA<ProviderHistoryValidationException>().having(
            (error) => error.issue,
            'issue',
            ProviderHistoryIssue.missingToolResult,
          ),
        ),
      );
    });

    test(
      'assistant ThinkingBlock with encrypted contents emits reasoning items',
      () {
        final out = _make().buildInputItems([
          AgentMessage(
            id: 'a1',
            role: AgentMessageRole.assistant,
            blocks: const [
              ThinkingBlock('thought', encryptedContents: ['enc_a', 'enc_b']),
            ],
          ),
        ]);
        expect(out.map((item) => item.toJson()['encrypted_content']), [
          'enc_a',
          'enc_b',
        ]);
      },
    );

    test(
      'assistant ThinkingBlock without encrypted contents is not serialized as reasoning_text',
      () {
        final out = _make().buildInputItems([
          AgentMessage(
            id: 'a1',
            role: AgentMessageRole.assistant,
            blocks: const [ThinkingBlock('plain thought')],
          ),
        ]);
        expect(out, isEmpty);
      },
    );

    test('assistant text content emits assistant message', () {
      final out = _make().buildInputItems([
        AgentMessage(
          id: 'a1',
          role: AgentMessageRole.assistant,
          content: 'hello back',
        ),
      ]);
      final json = out.first.toJson();
      expect(json['type'], 'message');
      expect(json['role'], 'assistant');
    });

    test('lone surrogate in user content sanitized', () {
      final lone = String.fromCharCode(0xDC00);
      final out = _make().buildInputItems([
        AgentMessage.user(id: 'u1', content: 'a${lone}b'),
      ]);
      final content = (out.first.toJson()['content'] as List).cast<Map>();
      expect((content.first['text'] as String).contains('\uFFFD'), isTrue);
    });
  });

  group('OpenAIResponsesClient reasoning request', () {
    Future<Map<String, dynamic>> captureReasoningBody(String? effort) async {
      Map<String, dynamic>? body;
      final client = _make(
        httpClient: MockClient((request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({'id': 'resp_1', 'status': 'completed', 'output': []}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      await client.chat(
        messages: [AgentMessage.user(id: 'u1', content: 'hi')],
        options: AgentConfig(reasoningEffort: effort),
      );
      return body!;
    }

    test(
      'ignores the UI-only on toggle instead of sending unknown effort',
      () async {
        final body = await captureReasoningBody('on');
        expect(body['reasoning'], {'summary': 'auto'});
      },
    );

    test('sends max instead of serializing it as unknown', () async {
      final body = await captureReasoningBody('max');
      expect(body['reasoning'], {'effort': 'max', 'summary': 'auto'});
    });

    test('sends minimal instead of serializing it as unknown', () async {
      final body = await captureReasoningBody('minimal');
      expect(body['reasoning'], {'effort': 'minimal', 'summary': 'auto'});
    });
  });

  group('OpenAIResponsesClient.chatStream', () {
    const incompleteReasons = {
      'max_output_tokens': StreamFinishReason.length,
      'content_filter': StreamFinishReason.contentFilter,
    };

    for (final entry in incompleteReasons.entries) {
      test('maps ${entry.key} to ${entry.value.name}', () async {
        final body = _responsesSseEvent({
          'type': 'response.incomplete',
          'sequence_number': 1,
          'response': {
            'id': 'resp_incomplete',
            'object': 'response',
            'status': 'incomplete',
            'output': [],
            'incomplete_details': {'reason': entry.key},
            'usage': {'input_tokens': 1, 'output_tokens': 2, 'total_tokens': 3},
          },
        });
        final client = _make(
          streamHttpClientFactory: () => _ResponsesSseMockClient(body),
        );

        final events = await client
            .chatStream(
              messages: [AgentMessage.user(id: 'u1', content: 'continue')],
            )
            .toList();

        final complete = events.whereType<StreamComplete>().single;
        expect(complete.finishReason, entry.value);
        expect(complete.usage?.totalTokens, 3);
      });
    }

    Future<Object> streamError(Map<String, dynamic> event) async {
      final client = _make(
        streamHttpClientFactory: () =>
            _ResponsesSseMockClient(_responsesSseEvent(event)),
      );
      try {
        await client
            .chatStream(
              messages: [AgentMessage.user(id: 'u1', content: 'continue')],
            )
            .toList();
      } on Object catch (error) {
        return error;
      }
      fail('stream error was swallowed');
    }

    test('response.failed keeps provider code and message', () async {
      final error = await streamError({
        'type': 'response.failed',
        'sequence_number': 1,
        'response': {
          'id': 'resp_failed',
          'status': 'failed',
          'output': [],
          'error': {
            'code': 'context_length_exceeded',
            'message': 'Your input exceeds the context window.',
          },
        },
      });
      expect(
        error,
        isA<ProviderStreamException>().having(
          (e) => e.code,
          'code',
          'context_length_exceeded',
        ),
      );
      expect(isContextLengthExceeded(error), isTrue);
      expect(
        tryReadProviderMessage(error),
        'Your input exceeds the context window.',
      );
    });

    test('relay failed event with top-level string error', () async {
      final error = await streamError({
        'type': 'response.failed',
        'error': 'upstream unavailable',
      });
      expect(tryReadProviderMessage(error), 'upstream unavailable');
      expect(isContextLengthExceeded(error), isFalse);
    });

    test('relay error event with numeric code and JSON message', () async {
      final error = await streamError({
        'type': 'error',
        'error': {
          'code': 400,
          'message': jsonEncode({
            'error': {'type': 'context_length_exceeded', 'message': 'too long'},
          }),
        },
      });
      expect(
        error,
        isA<ProviderStreamException>().having((e) => e.code, 'code', '400'),
      );
      expect(isContextLengthExceeded(error), isTrue);
    });

    test('maps response.completed to stop', () async {
      final body = _responsesSseEvent({
        'type': 'response.completed',
        'sequence_number': 1,
        'response': {
          'id': 'resp_completed',
          'object': 'response',
          'status': 'completed',
          'output': [],
        },
      });
      final client = _make(
        streamHttpClientFactory: () => _ResponsesSseMockClient(body),
      );

      final events = await client
          .chatStream(
            messages: [AgentMessage.user(id: 'u1', content: 'continue')],
          )
          .toList();

      expect(
        events.whereType<StreamComplete>().single.finishReason,
        StreamFinishReason.stop,
      );
    });

    test('accepts response.completed without id and status', () async {
      final body = _responsesSseEvent({
        'type': 'response.completed',
        'sequence_number': 1,
        'response': {'output': []},
      });
      final client = _make(
        streamHttpClientFactory: () => _ResponsesSseMockClient(body),
      );

      final events = await client
          .chatStream(
            messages: [AgentMessage.user(id: 'u1', content: 'continue')],
          )
          .toList();

      expect(
        events.whereType<StreamComplete>().single.finishReason,
        StreamFinishReason.stop,
      );
    });

    test(
      'finalizes complete function arguments when the provider closes early',
      () async {
        final body = [
          _responsesSseEvent({
            'type': 'response.output_item.added',
            'sequence_number': 1,
            'output_index': 0,
            'item': {
              'type': 'function_call',
              'id': 'fc_1',
              'call_id': 'call_read',
              'name': 'Read',
              'arguments': '',
            },
          }),
          _responsesSseEvent({
            'type': 'response.function_call_arguments.delta',
            'sequence_number': 2,
            'item_id': 'fc_1',
            'output_index': 0,
            'delta': '{"path":"/chapters"}',
          }),
        ].join();
        final client = _make(
          streamHttpClientFactory: () => _ResponsesSseMockClient(body),
        );

        final events = await client
            .chatStream(
              messages: [AgentMessage.user(id: 'u1', content: 'read')],
            )
            .toList();
        final calls = events.whereType<ToolCallDelta>().toList();

        expect(calls.last.callId, 'call_read');
        expect(calls.last.toolName, 'Read');
        expect(calls.last.arguments, {'path': '/chapters'});
        expect(calls.last.isPartial, isFalse);
        expect(events.whereType<StreamComplete>(), hasLength(1));
      },
    );

    test('keeps streaming when added item is unknown or incomplete', () async {
      final addedItems = <Map<String, dynamic>>[
        {'type': 'web_search_call', 'id': 'web_1'},
        {
          'type': 'reasoning',
          'id': 'reasoning_1',
          // A relay may send a reasoning lifecycle stub without summary.
        },
      ];

      for (final item in addedItems) {
        final body = [
          _responsesSseEvent({
            'type': 'response.output_item.added',
            'sequence_number': 1,
            'output_index': 0,
            'item': item,
          }),
          _responsesSseEvent({
            'type': 'response.output_text.delta',
            'sequence_number': 2,
            'item_id': 'message_1',
            'output_index': 0,
            'content_index': 0,
            'delta': 'continued',
          }),
          _responsesSseEvent({
            'type': 'response.completed',
            'sequence_number': 3,
            'response': {
              'id': 'resp_completed',
              'object': 'response',
              'status': 'completed',
              'output': [],
            },
          }),
        ].join();
        final client = _make(
          streamHttpClientFactory: () => _ResponsesSseMockClient(body),
        );

        final events = await client
            .chatStream(
              messages: [AgentMessage.user(id: 'u1', content: 'continue')],
            )
            .toList();

        expect(
          events.whereType<TextDelta>().map((event) => event.text).join(),
          'continued',
        );
        expect(events.whereType<StreamComplete>(), hasLength(1));
      }
    });
  });

  group('OpenResponses streaming cancellation', () {
    test(
      'closes the dedicated stream client and ends cleanly on abort',
      () async {
        final streamClient = _BlockingClient();
        final abort = Completer<void>();
        final client = or.OpenResponsesClient.withApiKey(
          'sk-test',
          baseUrl: 'https://example.invalid/v1',
          streamClientFactory: () => streamClient,
        );
        final errors = <Object>[];
        final done = Completer<void>();

        client.responses
            .createStream(
              or.CreateResponseRequest(
                model: 'gpt-5',
                input: or.ResponseInput.items(const []),
              ),
              abortTrigger: abort.future,
            )
            .listen((_) {}, onError: errors.add, onDone: done.complete);

        await streamClient.sendStarted.future;
        abort.complete();
        await done.future;

        expect(streamClient.closed, isTrue);
        // 修复后：abort 是主动取消，SDK 返回空响应安静结束，不再抛
        // AbortedException（抛错会落入已取消的 async* 生成器变 unhandled）。
        expect(errors, isEmpty);
      },
    );
  });

  // store=false \u6A21\u5F0F\u4E0B\uFF0Cresponse.completed \u5FC5\u987B\u628A reasoning item \u7684
  // encrypted_content \u4F5C\u4E3A EncryptedContentDelta \u4E0A\u629B\uFF0C\u5426\u5219\u4E0B\u4E00\u8F6E\u65E0\u5185\u5BB9\u56DE\u4F20\u3001
  // \u63A8\u7406\u94FE\u65AD\u88C2\u3002\u8FD9\u4E9B\u7528\u4F8B\u5B88\u62A4\u8BE5\u56DE\u5F52\u3002
  group('OpenAIResponsesClient.completedResponseEvents', () {
    or.ResponseResource response(List<or.OutputItem> output) =>
        or.ResponseResource(
          id: 'resp_1',
          status: or.ResponseStatus.completed,
          output: output,
        );

    test(
      'reasoning item with encrypted_content emits EncryptedContentDelta',
      () {
        final events = _make().completedResponseEvents(
          response([
            const or.ReasoningItem(
              id: 'r1',
              summary: [],
              encryptedContent: 'enc-blob',
            ),
          ]),
        );
        final encrypted = events.whereType<EncryptedContentDelta>().toList();
        expect(encrypted, hasLength(1));
        expect(encrypted.first.encryptedContent, 'enc-blob');
      },
    );

    test('reasoning item without encrypted_content emits nothing', () {
      final events = _make().completedResponseEvents(
        response([const or.ReasoningItem(id: 'r1', summary: [])]),
      );
      expect(events.whereType<EncryptedContentDelta>(), isEmpty);
    });

    test(
      'multiple reasoning items each round-trip their encrypted_content',
      () {
        final events = _make().completedResponseEvents(
          response([
            const or.ReasoningItem(
              id: 'r1',
              summary: [],
              encryptedContent: 'a',
            ),
            const or.ReasoningItem(
              id: 'r2',
              summary: [],
              encryptedContent: 'b',
            ),
          ]),
        );
        expect(
          events.whereType<EncryptedContentDelta>().map(
            (e) => e.encryptedContent,
          ),
          ['a', 'b'],
        );
      },
    );

    test('function_call item emits a final (non-partial) ToolCallDelta', () {
      final events = _make().completedResponseEvents(
        response([
          const or.FunctionCallOutputItemResponse(
            id: 'fc1',
            callId: 'call_1',
            name: 'Read',
            arguments: '{"path":"/x"}',
          ),
        ]),
      );
      final calls = events.whereType<ToolCallDelta>().toList();
      expect(calls, hasLength(1));
      expect(calls.first.callId, 'call_1');
      expect(calls.first.toolName, 'Read');
      expect(calls.first.isPartial, isFalse);
      expect(calls.first.arguments, {'path': '/x'});
    });

    test('function_call item keeps malformed arguments partial', () {
      final events = _make().completedResponseEvents(
        response([
          const or.FunctionCallOutputItemResponse(
            id: 'fc1',
            callId: 'call_1',
            name: 'Edit',
            arguments: '{"path":"/x","new_text":"half',
          ),
        ]),
      );

      final call = events.whereType<ToolCallDelta>().single;
      expect(call.isPartial, isTrue);
    });
  });
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

class _ResponsesSseMockClient extends http.BaseClient {
  _ResponsesSseMockClient(this.body);

  final String body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(request.method, 'POST');
    expect(request.url.path, '/responses');
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}

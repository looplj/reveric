// 职责: 验证 OpenAiClient 的消息转换、请求构造、流式内容顺序与工具参数完整性。
// 关联文件:
//   lib/shared/agent/client/openai_client.dart
//   lib/shared/agent/client/provider_history_preflight.dart

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:reveric/shared/agent/agent_config.dart';
import 'package:reveric/shared/agent/agent_event.dart';
import 'package:reveric/shared/agent/client.dart';
import 'package:reveric/shared/agent/client/openai_client.dart';
import 'package:reveric/shared/agent/client/provider_history_preflight.dart';
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/agent/round_assembler.dart';

OpenAiClient _make() => OpenAiClient(
  apiKey: 'sk-test',
  baseUrl: 'https://example.invalid',
  model: 'gpt-4o-mini',
);

OpenAiClient _makeWithThinking({http.Client? httpClient}) => OpenAiClient(
  apiKey: 'sk-test',
  baseUrl: 'https://example.invalid',
  model: 'gpt-4o-mini',
  useThinkingField: true,
  httpClient: httpClient,
);

http.Response _okResponse() => http.Response(
  jsonEncode({
    'choices': [
      {
        'index': 0,
        'message': {'role': 'assistant', 'content': 'ok'},
        'finish_reason': 'stop',
      },
    ],
    'usage': {'prompt_tokens': 0, 'completion_tokens': 0, 'total_tokens': 0},
  }),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  test(
    'stream request closes each tool batch before sending its images',
    () async {
      var requests = 0;
      final client = OpenAiClient(
        apiKey: 'test',
        baseUrl: 'https://example.invalid',
        model: 'test',
        streamClientFactory: () => MockClient((request) async {
          requests++;
          final body = jsonDecode(request.body) as Map;
          expect(body['stream'], true);
          final messages = (body['messages'] as List).cast<Map>();
          expect(messages.map((m) => m['role']), [
            'assistant',
            'tool',
            'tool',
            'user',
            'assistant',
            'tool',
            'user',
            'user',
          ]);
          expect(messages[1]['tool_call_id'], 'a');
          expect(messages[2]['tool_call_id'], 'b');
          expect(messages[2]['content'], 'text-only result');
          expect(messages[5]['tool_call_id'], 'c');
          for (final entry in {3: 'AAA=', 6: 'CCC='}.entries) {
            final parts = (messages[entry.key]['content'] as List).cast<Map>();
            expect(
              parts.last['image_url']['url'],
              'data:image/png;base64,${entry.value}',
            );
          }
          expect(messages.last['content'], 'continue');
          return http.Response(
            '${_openAiSseChunk(delta: const {'content': 'ok'}, finishReason: 'stop')}data: [DONE]\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      final events = await client
          .chatStream(
            messages: [
              const AgentMessage(
                id: 'first',
                role: AgentMessageRole.assistant,
                blocks: [
                  ToolCallBlock(callId: 'a', toolName: 'Run', arguments: {}),
                  ToolCallBlock(callId: 'b', toolName: 'Run', arguments: {}),
                ],
              ),
              const AgentMessage(
                id: 'a',
                role: AgentMessageRole.user,
                type: AgentMessageType.tool_result,
                blocks: [
                  ToolResultBlock(
                    toolCallId: 'a',
                    toolName: 'Run',
                    content: [ImageBlock(data: 'AAA=', mimeType: 'image/png')],
                  ),
                ],
              ),
              const AgentMessage(
                id: 'b',
                role: AgentMessageRole.user,
                type: AgentMessageType.tool_result,
                blocks: [
                  ToolResultBlock(
                    toolCallId: 'b',
                    toolName: 'Run',
                    content: [TextBlock('text-only result')],
                  ),
                ],
              ),
              const AgentMessage(
                id: 'second',
                role: AgentMessageRole.assistant,
                blocks: [
                  ToolCallBlock(callId: 'c', toolName: 'Run', arguments: {}),
                ],
              ),
              const AgentMessage(
                id: 'c',
                role: AgentMessageRole.user,
                type: AgentMessageType.tool_result,
                blocks: [
                  ToolResultBlock(
                    toolCallId: 'c',
                    toolName: 'Run',
                    content: [ImageBlock(data: 'CCC=', mimeType: 'image/png')],
                  ),
                ],
              ),
              AgentMessage.user(id: 'next', content: 'continue'),
            ],
          )
          .toList();
      expect(requests, 1);
      expect(events.whereType<TextDelta>().single.text, 'ok');
    },
  );

  test('interleaved image wrappers retain their exact order', () {
    final out = _make().convertMessages([
      AgentMessage.user(
        id: 'images',
        content: '',
        blocks: const [
          TextBlock('before'),
          TextBlock('<image name="one">'),
          ImageBlock(data: 'AAA=', mimeType: 'image/png'),
          TextBlock('</image>'),
          TextBlock('between'),
          TextBlock('<image name="two">'),
          ImageBlock(data: 'BBB=', mimeType: 'image/png'),
          TextBlock('</image>'),
          TextBlock('after'),
        ],
      ),
    ]);
    final parts = (out.single.toJson()['content'] as List).cast<Map>();
    expect(parts.map((p) => p['type']), [
      'text',
      'text',
      'image_url',
      'text',
      'text',
      'text',
      'image_url',
      'text',
      'text',
    ]);
    expect(parts[4]['text'], 'between');
    expect(parts.last['text'], 'after');
  });

  group('OpenAiClient.convertMessages', () {
    test('system message converts to system role', () {
      final out = _make().convertMessages([
        AgentMessage.system(id: 's1', content: 'sys'),
      ]);
      expect(out.length, 1);
      final json = out.first.toJson();
      expect(json['role'], 'system');
      expect(json['content'], 'sys');
    });

    test('plain user text converts to user role with string content', () {
      final out = _make().convertMessages([
        AgentMessage.user(id: 'u1', content: 'hello'),
      ]);
      final json = out.first.toJson();
      expect(json['role'], 'user');
      expect(json['content'], 'hello');
    });

    test('user with ImageBlock emits image_url content part', () {
      final out = _make().convertMessages([
        AgentMessage(
          id: 'u1',
          role: AgentMessageRole.user,
          content: 'see',
          blocks: const [ImageBlock(data: 'AAA=', mimeType: 'image/png')],
        ),
      ]);
      final json = out.first.toJson();
      expect(json['role'], 'user');
      final parts = json['content'];
      expect(parts, isA<List>());
      final list = (parts as List).cast<Map>();
      expect(list.first['type'], 'text');
      expect(list.first['text'], 'see');
      expect(list.last['type'], 'image_url');
      final url = (list.last['image_url'] as Map)['url'] as String;
      expect(url, startsWith('data:image/png;base64,'));
      expect(url.endsWith('AAA='), isTrue);
    });

    test('tool_result converts to tool role with toolCallId', () {
      final out = _make().convertMessages([
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
      expect(json['role'], 'tool');
      expect(json['tool_call_id'], 'call_1');
      expect(json['content'], 'result body');
    });

    test(
      'tool_result with image emits tool message + follow-up user image turn',
      () {
        final out = _make().convertMessages([
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
                  TextBlock('see attached'),
                  ImageBlock(data: 'BBB=', mimeType: 'image/jpeg'),
                ],
              ),
            ],
          ),
        ]);
        expect(out.length, 3);
        final tool = out[1].toJson();
        expect(tool['role'], 'tool');
        expect(tool['tool_call_id'], 'call_2');
        expect(tool['content'], 'see attached');

        final user = out[2].toJson();
        expect(user['role'], 'user');
        final list = (user['content'] as List).cast<Map>();
        expect(list.first['type'], 'text');
        expect(list.last['type'], 'image_url');
      },
    );

    test('tool_result with no text uses placeholder content', () {
      final out = _make().convertMessages([
        const AgentMessage(
          id: 'a1',
          role: AgentMessageRole.assistant,
          blocks: [
            ToolCallBlock(
              callId: 'call_3',
              toolName: 'X',
              arguments: {'path': '/x'},
            ),
          ],
        ),
        AgentMessage(
          id: 'tool_only_img',
          role: AgentMessageRole.user,
          type: AgentMessageType.tool_result,
          blocks: const [
            ToolResultBlock(
              toolCallId: 'call_3',
              toolName: 'X',
              content: [ImageBlock(data: 'CCC=', mimeType: 'image/png')],
            ),
          ],
        ),
      ]);
      expect(out.length, 3);
      expect(out[1].toJson()['content'], '(see attached image)');
    });

    test('multiple tool_result blocks emit multiple tool messages', () {
      final out = _make().convertMessages([
        const AgentMessage(
          id: 'a1',
          role: AgentMessageRole.assistant,
          blocks: [
            ToolCallBlock(callId: 'c1', toolName: 'A', arguments: {}),
            ToolCallBlock(callId: 'c2', toolName: 'B', arguments: {}),
          ],
        ),
        AgentMessage(
          id: 't',
          role: AgentMessageRole.user,
          type: AgentMessageType.tool_result,
          blocks: const [
            ToolResultBlock(
              toolCallId: 'c1',
              toolName: 'A',
              content: [TextBlock('r1')],
            ),
            ToolResultBlock(
              toolCallId: 'c2',
              toolName: 'B',
              content: [TextBlock('r2')],
            ),
          ],
        ),
      ]);
      expect(out.length, 3);
      expect(out[1].toJson()['tool_call_id'], 'c1');
      expect(out[2].toJson()['tool_call_id'], 'c2');
    });

    test(
      'assistant message with toolCalls emits tool_calls field when paired',
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
        expect(json['role'], 'assistant');
        final calls = json['tool_calls'] as List;
        expect(calls.length, 1);
        final call = calls.first as Map;
        expect(call['id'], 'cid');
        final fn = call['function'] as Map;
        expect(fn['name'], 'Read');
        expect(fn['arguments'], '{"path":"/x"}');
        expect(out[1].toJson()['role'], 'tool');
      },
    );

    test('assistant toolCalls without tool_result are rejected', () {
      expect(
        () => _make().convertMessages([
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

    test('orphan tool_result is rejected', () {
      expect(
        () => _make().convertMessages([
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
        ]),
        throwsA(
          isA<ProviderHistoryValidationException>().having(
            (error) => error.issue,
            'issue',
            ProviderHistoryIssue.orphanToolResult,
          ),
        ),
      );
    });

    test('assistant message empty content + no toolCalls is dropped', () {
      final out = _make().convertMessages([
        AgentMessage(id: 'a1', role: AgentMessageRole.assistant, content: ''),
      ]);
      expect(out, isEmpty);
    });

    test(
      'assistant ThinkingBlock with signature populates reasoning_details',
      () {
        final out = _make().convertMessages([
          AgentMessage(
            id: 'a1',
            role: AgentMessageRole.assistant,
            content: 'answer',
            blocks: const [ThinkingBlock('thought', signature: 'sig')],
          ),
        ]);
        final json = out.first.toJson();
        expect(json['role'], 'assistant');
        expect(json['content'], 'answer');
        expect(json['reasoning_content'], 'thought');
        final details = (json['reasoning_details'] as List).cast<Map>();
        expect(details.length, 1);
        expect(details.first['type'], 'reasoning.encrypted');
        expect(details.first['data'], 'sig');
      },
    );

    test('lone surrogate in user content gets sanitized', () {
      final lone = String.fromCharCode(0xD800);
      final out = _make().convertMessages([
        AgentMessage.user(id: 'u1', content: 'a${lone}b'),
      ]);
      final content = out.first.toJson()['content'] as String;
      expect(content.contains('\uFFFD'), isTrue);
    });
  });

  group('_ThinkingChatRequest reasoning_effort', () {
    test('omits reasoning_effort when effort is none', () async {
      Map<String, dynamic>? body;
      final mock = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return _okResponse();
      });
      final client = _makeWithThinking(httpClient: mock);
      await client.chat(
        messages: [AgentMessage.user(id: 'u1', content: 'hi')],
        options: const AgentConfig(reasoningEffort: 'none'),
      );
      expect(body, isNotNull);
      expect(body!.containsKey('reasoning_effort'), isFalse);
      expect(body!['thinking'], {'type': 'disabled'});
    });

    test('includes reasoning_effort when effort is medium', () async {
      Map<String, dynamic>? body;
      final mock = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return _okResponse();
      });
      final client = _makeWithThinking(httpClient: mock);
      await client.chat(
        messages: [AgentMessage.user(id: 'u1', content: 'hi')],
        options: const AgentConfig(reasoningEffort: 'medium'),
      );
      expect(body, isNotNull);
      expect(body!['reasoning_effort'], 'medium');
      expect(body!['thinking'], {'type': 'enabled'});
    });
  });

  group('defaultHeaders reach transport via abortTrigger wrapper', () {
    // Regression: 非流式 chat() 恒带 abortTrigger，SDK 用
    // _AbortableRequestWrapper 包装请求，其 finalize() 会 clear 再从 inner
    // 重拷 headers，丢掉 TraceHeadersHttpClient 在 send 阶段加的头。静态
    // 自定义静态请求头必须走 SDK defaultHeaders，进入 inner request headers，
    // 才能在 wrapper 重拷时保留。
    test('X-Custom-Header from defaultHeaders is present on the wire', () async {
      Map<String, String>? seenHeaders;
      final mock = MockClient((req) async {
        seenHeaders = Map<String, String>.from(req.headers);
        return _okResponse();
      });
      final client = OpenAiClient(
        apiKey: 'sk-test',
        baseUrl: 'https://example.invalid',
        model: 'gpt-4o-mini',
        httpClient: mock,
        defaultHeaders: const {'X-Custom-Header': 'test-value'},
      );
      await client.chat(
        messages: [AgentMessage.user(id: 'u1', content: 'hi')],
      );
      expect(seenHeaders, isNotNull);
      expect(seenHeaders!['X-Custom-Header'], 'test-value');
    });

    test('omits X-Custom-Header when defaultHeaders not provided', () async {
      Map<String, String>? seenHeaders;
      final mock = MockClient((req) async {
        seenHeaders = Map<String, String>.from(req.headers);
        return _okResponse();
      });
      final client = OpenAiClient(
        apiKey: 'sk-test',
        baseUrl: 'https://example.invalid',
        model: 'gpt-4o-mini',
        httpClient: mock,
      );
      await client.chat(
        messages: [AgentMessage.user(id: 'u1', content: 'hi')],
      );
      expect(seenHeaders, isNotNull);
      expect(seenHeaders!.containsKey('X-Custom-Header'), isFalse);
    });
  });

  group('OpenAiClient.chatStream content ordering', () {
    for (final reasoningField in ['reasoning_content', 'reasoning']) {
      test('emits $reasoningField tail before text in a mixed chunk', () async {
        final client = OpenAiClient(
          apiKey: 'sk-test',
          baseUrl: 'https://example.invalid',
          model: 'deepseek-v4-flash',
          streamClientFactory: () => _OpenAiSseMockClient(
            [
              _openAiSseChunk(delta: {reasoningField: '核验通过'}),
              _openAiSseChunk(delta: {'content': '三', reasoningField: '。'}),
              _openAiSseChunk(delta: const {'content': '场正文全部落盘。'}),
              _openAiSseChunk(delta: const {}, finishReason: 'stop'),
              'data: [DONE]\n\n',
            ].join(),
          ),
        );

        final events = await assembleRound(
          client.chatStream(
            messages: [AgentMessage.user(id: 'u1', content: 'continue')],
          ),
        ).toList();

        // 相邻同类增量才能合为一个消息块；思考尾巴不能插进连续正文。
        expect(events, [
          isA<AgentRoundThinkingDelta>().having(
            (event) => event.text,
            'text',
            '核验通过',
          ),
          isA<AgentRoundThinkingDelta>().having(
            (event) => event.text,
            'text',
            '。',
          ),
          isA<AgentRoundTextDelta>().having((event) => event.text, 'text', '三'),
          isA<AgentRoundTextDelta>().having(
            (event) => event.text,
            'text',
            '场正文全部落盘。',
          ),
          isA<AgentRoundComplete>(),
        ]);
        final result = events.whereType<AgentRoundComplete>().single.result;
        expect(result.text, '三场正文全部落盘。');
        expect(result.thinking, '核验通过。');
        expect(result.finishReason, StreamFinishReason.stop);
      });
    }

    test('preserves text and reasoning order across separate chunks', () async {
      final client = OpenAiClient(
        apiKey: 'sk-test',
        baseUrl: 'https://example.invalid',
        model: 'deepseek-v4-flash',
        streamClientFactory: () => _OpenAiSseMockClient(
          [
            _openAiSseChunk(delta: const {'content': '先核验。'}),
            _openAiSseChunk(delta: const {'reasoning_content': '核验结果'}),
            _openAiSseChunk(delta: const {'content': '核验通过。'}),
            _openAiSseChunk(delta: const {}, finishReason: 'stop'),
            'data: [DONE]\n\n',
          ].join(),
        ),
      );

      final events = await client
          .chatStream(
            messages: [AgentMessage.user(id: 'u1', content: 'continue')],
          )
          .toList();

      expect(events, [
        isA<TextDelta>().having((event) => event.text, 'text', '先核验。'),
        isA<ThinkingDelta>().having((event) => event.text, 'text', '核验结果'),
        isA<TextDelta>().having((event) => event.text, 'text', '核验通过。'),
        isA<StreamComplete>(),
      ]);
    });

    test(
      'keeps tool calls after reasoning and text in a mixed chunk',
      () async {
        final client = OpenAiClient(
          apiKey: 'sk-test',
          baseUrl: 'https://example.invalid',
          model: 'deepseek-v4-flash',
          streamClientFactory: () => _OpenAiSseMockClient(
            [
              _openAiSseChunk(
                delta: {
                  'content': '读取正文。',
                  'reasoning_content': '需要核验。',
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_read',
                      'type': 'function',
                      'function': {
                        'name': 'Read',
                        'arguments': '{"path":"/chapters"}',
                      },
                    },
                  ],
                },
                finishReason: 'tool_calls',
              ),
              'data: [DONE]\n\n',
            ].join(),
          ),
        );

        final events = await client
            .chatStream(
              messages: [AgentMessage.user(id: 'u1', content: 'read')],
            )
            .toList();

        expect(events, [
          isA<ThinkingDelta>().having((event) => event.text, 'text', '需要核验。'),
          isA<TextDelta>().having((event) => event.text, 'text', '读取正文。'),
          isA<ToolCallDelta>().having(
            (event) => event.isPartial,
            'partial',
            true,
          ),
          isA<ToolCallDelta>().having(
            (event) => event.isPartial,
            'partial',
            false,
          ),
          isA<StreamComplete>().having(
            (event) => event.finishReason,
            'finishReason',
            StreamFinishReason.toolCalls,
          ),
        ]);
        final call = events.whereType<ToolCallDelta>().last;
        expect(call.callId, 'call_read');
        expect(call.toolName, 'Read');
        expect(call.arguments, {'path': '/chapters'});
      },
    );
  });

  group('OpenAiClient.chatStream tool arguments', () {
    for (final emptyId in [false, true]) {
      test(
        'assembles three calls with empty continuation names (emptyId=$emptyId)',
        () async {
          final client = OpenAiClient(
            apiKey: 'sk-test',
            baseUrl: 'https://example.invalid',
            model: 'deepseek-v4-flash',
            streamClientFactory: () => _OpenAiSseMockClient(
              [
                _openAiSseChunk(
                  delta: {
                    'tool_calls': [
                      for (var i = 0; i < 3; i++)
                        {
                          'index': i,
                          'id': 'call_read_$i',
                          'type': 'function',
                          'function': {'name': 'Read', 'arguments': '{"path":'},
                        },
                    ],
                  },
                ),
                _openAiSseChunk(
                  delta: {
                    'tool_calls': [
                      for (var i = 0; i < 3; i++)
                        {
                          'index': i,
                          if (emptyId) 'id': '',
                          'function': {
                            'name': '',
                            'arguments': '"/chapters/$i"}',
                          },
                        },
                    ],
                  },
                ),
                _openAiSseChunk(delta: const {}, finishReason: 'tool_calls'),
                'data: [DONE]\n\n',
              ].join(),
            ),
          );

          final events = await assembleRound(
            client.chatStream(
              messages: [AgentMessage.user(id: 'u1', content: 'read')],
            ),
          ).toList();
          final calls = events
              .whereType<AgentRoundComplete>()
              .single
              .result
              .toolCalls;

          expect(calls, hasLength(3));
          for (var i = 0; i < 3; i++) {
            expect(calls[i].callId, 'call_read_$i');
            expect(calls[i].toolName, 'Read');
            expect(calls[i].arguments, {'path': '/chapters/$i'});
          }
          expect(events.whereType<AgentRoundToolCallIncomplete>(), isEmpty);
        },
      );
    }

    test('preserves the provider finish reason on stream completion', () async {
      final client = OpenAiClient(
        apiKey: 'sk-test',
        baseUrl: 'https://example.invalid',
        model: 'deepseek-v4-flash',
        streamClientFactory: () => _OpenAiSseMockClient(
          [
            _openAiSseChunk(
              delta: const {'reasoning_content': 'still thinking'},
            ),
            _openAiSseChunk(delta: const {}, finishReason: 'length'),
            'data: [DONE]\n\n',
          ].join(),
        ),
      );

      final events = await client
          .chatStream(
            messages: [AgentMessage.user(id: 'u1', content: 'continue')],
          )
          .toList();

      expect(events.whereType<ThinkingDelta>(), hasLength(1));
      expect(
        events.whereType<StreamComplete>().single.finishReason,
        StreamFinishReason.length,
      );
    });

    test('keeps truncated JSON partial when the provider finishes', () async {
      final client = OpenAiClient(
        apiKey: 'sk-test',
        baseUrl: 'https://example.invalid',
        model: 'deepseek-v4-flash',
        streamClientFactory: () => _OpenAiSseMockClient(
          [
            _openAiSseChunk(
              delta: {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_edit',
                    'type': 'function',
                    'function': {
                      'name': 'Edit',
                      'arguments': '{"path":"/chapters/1","new_text":"half',
                    },
                  },
                ],
              },
            ),
            _openAiSseChunk(delta: const {}, finishReason: 'length'),
            'data: [DONE]\n\n',
          ].join(),
        ),
      );

      final events = await client
          .chatStream(
            messages: [AgentMessage.user(id: 'u1', content: 'edit')],
          )
          .toList();
      final calls = events.whereType<ToolCallDelta>().toList();

      expect(calls, isNotEmpty);
      expect(calls.last.callId, 'call_edit');
      expect(calls.last.toolName, 'Edit');
      expect(calls.last.isPartial, isTrue);
    });

    test(
      'finalizes complete JSON when the provider closes before finish reason',
      () async {
        final client = OpenAiClient(
          apiKey: 'sk-test',
          baseUrl: 'https://example.invalid',
          model: 'deepseek-v4-flash',
          streamClientFactory: () => _OpenAiSseMockClient(
            [
              _openAiSseChunk(
                delta: {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_read',
                      'type': 'function',
                      'function': {
                        'name': 'Read',
                        'arguments': '{"path":"/chapters"}',
                      },
                    },
                  ],
                },
              ),
              'data: [DONE]\n\n',
            ].join(),
          ),
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
  });
}

String _openAiSseChunk({
  required Map<String, dynamic> delta,
  String? finishReason,
}) {
  return 'data: ${jsonEncode({
    'id': 'chatcmpl_test',
    'object': 'chat.completion.chunk',
    'created': 1,
    'model': 'deepseek-v4-flash',
    'choices': [
      {'index': 0, 'delta': delta, 'finish_reason': finishReason},
    ],
  })}\n\n';
}

class _OpenAiSseMockClient extends http.BaseClient {
  _OpenAiSseMockClient(this.body);

  final String body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}

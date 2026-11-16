// 职责: AnthropicClient 测试 — message 转换、stream 工具调用兼容与 sanitize 行为
// 关联文件:
//   lib/shared/agent/client/anthropic_client.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/services/ai/agent_message_mapping.dart';
import 'package:reveric/shared/services/ai/tool_operations.dart';
import 'package:reveric/shared/agent/client/openai_client.dart';
import 'package:reveric/shared/agent/client/gemini_client.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/agent/agent_config.dart';

import 'package:reveric/shared/agent/client.dart';
import 'package:reveric/shared/agent/client/anthropic_client.dart';
import 'package:reveric/shared/agent/message.dart';

AnthropicClient _make() =>
    AnthropicClient(apiKey: 'sk-test', model: 'claude-3-5-sonnet');

Map<String, dynamic> _firstBlockJson(Map<String, dynamic> msg) {
  final content = msg['content'];
  expect(content, isA<List<dynamic>>());
  return (content as List).first as Map<String, dynamic>;
}

String _sseEvent(String event, Map<String, dynamic> data) {
  return 'event: $event\n'
      'data: ${jsonEncode(data)}\n\n';
}

String _stopReasonStream(String stopReason) {
  return _sseEvent('message_start', {
        'type': 'message_start',
        'message': {
          'id': 'msg_stop_reason',
          'type': 'message',
          'role': 'assistant',
          'content': [],
          'model': 'claude-3-5-sonnet',
          'usage': {'input_tokens': 1, 'output_tokens': 0},
        },
      }) +
      _sseEvent('message_delta', {
        'type': 'message_delta',
        'delta': {'stop_reason': stopReason},
        'usage': {'output_tokens': 8},
      }) +
      _sseEvent('message_stop', {'type': 'message_stop'});
}

void main() {
  for (final streaming in [false, true]) {
    for (final (model, enabled, effort, expected) in [
      ('claude-opus-4-7', true, null, null),
      ('claude-opus-4-8', true, 'none', null),
      ('claude-sonnet-4-6', true, null, 0.3),
      ('claude-sonnet-4-6', true, 'high', null),
      ('claude-sonnet-4-6', false, null, null),
    ]) {
      test(
        'temperature wire $model enabled=$enabled effort=$effort stream=$streaming',
        () async {
          Map<String, dynamic>? body;
          final client = AnthropicClient(
            apiKey: 'test',
            model: model,
            httpClient: MockClient((request) async {
              body = jsonDecode(request.body) as Map<String, dynamic>;
              return http.Response(
                streaming
                    ? _stopReasonStream('end_turn')
                    : jsonEncode({
                        'id': 'msg_test',
                        'type': 'message',
                        'role': 'assistant',
                        'model': model,
                        'content': [],
                        'stop_reason': 'end_turn',
                        'usage': {'input_tokens': 1, 'output_tokens': 1},
                      }),
                200,
                headers: {
                  'content-type': streaming
                      ? 'text/event-stream'
                      : 'application/json',
                },
              );
            }),
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

  test(
    'live and restored image completions send reminder and image once in actual Anthropic payload',
    () async {
      final root = await Directory.systemTemp.createTemp('completion-payload-');
      addTearDown(() => root.delete(recursive: true));
      final bytes = img.encodePng(img.Image(width: 1, height: 1));
      final encoded = base64Encode(bytes);
      final file = File(
        '${root.path}/file_workspaces/work/sessions/session/copy.png',
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      final completion = ToolOperationCompletion(
        ToolOperationRecord(
          runId: 'run',
          ownerSessionId: 'session',
          sourceSessionId: 'session',
          sourceTurnId: 'turn',
          callId: 'call',
          workId: 'work',
          kind: 'files.read',
          targetPath: 'source.png',
          background: true,
          createdAt: DateTime.now(),
          status: ToolOperationStatus.completed,
          result: {
            'ok': true,
            'content_format': 'session_files_v1',
            'content': [
              {
                'type': 'image',
                'file_path': 'file_workspaces/work/sessions/session/copy.png',
                'mime_type': 'image/png',
              },
            ],
          },
        ),
      );
      completion.modelImages = [
        ImageBlock(data: encoded, mimeType: 'image/png'),
      ];
      final live = AgentMessage(
        id: completion.messageId,
        role: AgentMessageRole.user,
        content: completion.reminder,
        blocks: completion.modelImages,
      );
      final restored = (await restoreAgentMessages([
        AiMessage.user(
          id: completion.messageId,
          content: completion.reminder,
          type: AiMessageType.system_remind,
        ),
      ], root: root.path)).single;
      Iterable<String> texts(Object? object) sync* {
        if (object is Map) {
          for (final entry in object.entries) {
            if (entry.key == 'text' && entry.value is String) {
              yield entry.value as String;
            } else {
              yield* texts(entry.value);
            }
          }
        } else if (object is List) {
          for (final value in object) {
            yield* texts(value);
          }
        }
      }

      void check(Object payload) {
        expect(
          texts(payload).where((text) => text == completion.reminder),
          hasLength(1),
        );
        expect(encoded.allMatches(jsonEncode(payload)), hasLength(1));
      }

      for (final message in [live, restored]) {
        final client = AnthropicClient(
          apiKey: 'sk-test',
          model: 'claude-3-5-sonnet',
          httpClient: _SseMockClient(
            _stopReasonStream('end_turn'),
            onRequest: check,
          ),
        );
        await client.chatStream(messages: [message]).toList();
        final openai = OpenAiClient(
          apiKey: 'test',
          model: 'test',
          baseUrl: 'https://example.test',
        );
        check(
          openai.convertMessages([message]).map((m) => m.toJson()).toList(),
        );
        final gemini = GeminiClient(apiKey: 'test', model: 'test');
        check(
          gemini.convertMessages([message]).map((m) => m.toJson()).toList(),
        );
      }
    },
  );

  group('AnthropicClient.convertMessages', () {
    test('user text message converts to single text block', () {
      final client = _make();
      final out = client.convertMessages([
        AgentMessage.user(id: 'u1', content: 'hello'),
      ]);
      expect(out.length, 1);
      final json = out.first.toJson();
      expect(json['role'], 'user');
      final block = _firstBlockJson(json);
      expect(block['type'], 'text');
      expect(block['text'], 'hello');
    });

    test(
      'user message with ImageBlock emits image block with base64 source',
      () {
        final client = _make();
        final msg = AgentMessage(
          id: 'u1',
          role: AgentMessageRole.user,
          content: 'see this',
          blocks: const [ImageBlock(data: 'AAA=', mimeType: 'image/png')],
        );
        final out = client.convertMessages([msg]);
        expect(out.length, 1);
        final blocks = out.first.toJson()['content'] as List;
        expect(blocks.length, 2);
        expect((blocks.first as Map)['text'], 'see this');
        final imgBlock = blocks.last as Map<String, dynamic>;
        expect(imgBlock['type'], 'image');
        final source = imgBlock['source'] as Map<String, dynamic>;
        expect(source['type'], 'base64');
        expect(source['media_type'], 'image/png');
        expect(source['data'], 'AAA=');
      },
    );

    test(
      'user message with content + TextBlock + ImageBlock includes both',
      () {
        final client = _make();
        final msg = AgentMessage(
          id: 'u1',
          role: AgentMessageRole.user,
          blocks: const [
            TextBlock('some text'),
            ImageBlock(data: 'BBB=', mimeType: 'image/jpeg'),
          ],
        );
        final out = client.convertMessages([msg]);
        final blocks = out.first.toJson()['content'] as List;
        expect(blocks.length, 2);
        expect((blocks[0] as Map)['type'], 'text');
        expect((blocks[0] as Map)['text'], 'some text');
        expect((blocks[1] as Map)['type'], 'image');
      },
    );

    test('tool_result message converts to user with tool_result block', () {
      final client = _make();
      final out = client.convertMessages([
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
      final tr = _firstBlockJson(json);
      expect(tr['type'], 'tool_result');
      expect(tr['tool_use_id'], 'call_1');
      final content = tr['content'] as List;
      expect(content.first['type'], 'text');
      expect(content.first['text'], 'result body');
    });

    test('isError tool result sets is_error flag', () {
      final client = _make();
      final out = client.convertMessages([
        const AgentMessage(
          id: 'assistant_c2',
          role: AgentMessageRole.assistant,
          blocks: [
            ToolCallBlock(callId: 'call_2', toolName: 'Read', arguments: {}),
          ],
        ),
        AgentMessage(
          id: 'tool_e',
          role: AgentMessageRole.user,
          type: AgentMessageType.tool_result,
          blocks: const [
            ToolResultBlock(
              toolCallId: 'call_2',
              toolName: 'Read',
              isError: true,
              content: [TextBlock('boom')],
            ),
          ],
        ),
      ]);
      final tr = _firstBlockJson(out.last.toJson());
      expect(tr['is_error'], isTrue);
    });

    test('tool_result with image content emits image block', () {
      final client = _make();
      final out = client.convertMessages([
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
                TextBlock('see attached'),
                ImageBlock(data: 'CCC=', mimeType: 'image/webp'),
              ],
            ),
          ],
        ),
      ]);
      final tr = _firstBlockJson(out.last.toJson());
      final content = tr['content'] as List;
      expect(content.length, 2);
      expect(content[0]['type'], 'text');
      expect(content[1]['type'], 'image');
      expect((content[1]['source'] as Map)['media_type'], 'image/webp');
    });

    test(
      'consecutive tool_result messages coalesce into single user message',
      () {
        final client = _make();
        final out = client.convertMessages([
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
        final blocks = out.last.toJson()['content'] as List;
        expect(blocks.length, 2);
        expect((blocks[0] as Map)['tool_use_id'], 'c1');
        expect((blocks[1] as Map)['tool_use_id'], 'c2');
      },
    );

    test(
      'assistant message with content does NOT double-write text (bug fix)',
      () {
        final client = _make();
        final out = client.convertMessages([
          AgentMessage(
            id: 'a1',
            role: AgentMessageRole.assistant,
            content: 'one',
            blocks: const [TextBlock('two')],
          ),
        ]);
        final blocks = out.first.toJson()['content'] as List;
        // expect 2 separate text blocks, not 'one' duplicated
        final texts = blocks.map((b) => (b as Map)['text']).toList();
        expect(texts, ['one', 'two']);
      },
    );

    test(
      'assistant ThinkingBlock with signature emits thinking input block',
      () {
        final client = _make();
        final out = client.convertMessages([
          AgentMessage(
            id: 'a1',
            role: AgentMessageRole.assistant,
            blocks: const [ThinkingBlock('reasoning', signature: 'sig123')],
          ),
        ]);
        final blocks = out.first.toJson()['content'] as List;
        expect(blocks.length, 1);
        final t = blocks.first as Map;
        expect(t['type'], 'thinking');
        expect(t['thinking'], 'reasoning');
        expect(t['signature'], 'sig123');
      },
    );

    test('assistant signed thinking stays before visible text on replay', () {
      final client = _make();
      final out = client.convertMessages([
        AgentMessage(
          id: 'a1',
          role: AgentMessageRole.assistant,
          content: 'answer',
          blocks: const [ThinkingBlock('reasoning', signature: 'sig123')],
        ),
      ]);

      final blocks = out.first.toJson()['content'] as List;
      expect(blocks.map((block) => (block as Map)['type']), [
        'thinking',
        'text',
      ]);
      expect((blocks.first as Map)['signature'], 'sig123');
      expect((blocks.last as Map)['text'], 'answer');
    });

    test('assistant signature-only thinking is replayed', () {
      final client = _make();
      final out = client.convertMessages([
        AgentMessage(
          id: 'a1',
          role: AgentMessageRole.assistant,
          blocks: const [ThinkingBlock('', signature: 'sig123')],
        ),
      ]);

      final blocks = out.first.toJson()['content'] as List;
      expect(blocks, hasLength(1));
      expect(blocks.first, {
        'type': 'thinking',
        'thinking': '',
        'signature': 'sig123',
      });
    });

    test('assistant ThinkingBlock without signature falls back to text', () {
      final client = _make();
      final out = client.convertMessages([
        AgentMessage(
          id: 'a1',
          role: AgentMessageRole.assistant,
          blocks: const [ThinkingBlock('reasoning')],
        ),
      ]);
      final blocks = out.first.toJson()['content'] as List;
      expect(blocks.length, 1);
      expect((blocks.first as Map)['type'], 'text');
      expect((blocks.first as Map)['text'], 'reasoning');
    });

    test('assistant ToolCallBlock emits tool_use block', () {
      final client = _make();
      final out = client.convertMessages([
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
      final block = (out.first.toJson()['content'] as List).first as Map;
      expect(block['type'], 'tool_use');
      expect(block['id'], 'cid');
      expect(block['name'], 'Read');
      expect(block['input'], {'path': '/x'});
    });

    test('system message is excluded from converted output', () {
      final client = _make();
      final out = client.convertMessages([
        AgentMessage.system(id: 's1', content: 'sys'),
        AgentMessage.user(id: 'u1', content: 'hi'),
      ]);
      expect(out.length, 1);
      expect(out.first.toJson()['role'], 'user');
    });

    test('lone surrogate is replaced (sanitizeSurrogates)', () {
      final client = _make();
      final lone = String.fromCharCode(0xD800);
      final out = client.convertMessages([
        AgentMessage.user(id: 'u1', content: 'a${lone}b'),
      ]);
      final block = _firstBlockJson(out.first.toJson());
      expect((block['text'] as String).contains('\uFFFD'), isTrue);
    });
  });

  group('AnthropicClient.chatStream', () {
    test(
      'cancel closes the dedicated stream client before response headers',
      () async {
        final streamClient = _BlockingClient();
        final client = AnthropicClient(
          apiKey: 'sk-test',
          model: 'claude-3-5-sonnet',
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
        // 修复后：abort 是主动取消，SDK 安静结束流而不是抛 AbortedException
        // （抛错会落入已取消的 async* 生成器变成 zone 级 unhandled）。
        expect(errors, isEmpty);
      },
      timeout: const Timeout(Duration(seconds: 2)),
    );

    const finishReasons = {
      'end_turn': StreamFinishReason.stop,
      'stop_sequence': StreamFinishReason.stop,
      'tool_use': StreamFinishReason.toolCalls,
      'max_tokens': StreamFinishReason.length,
      'pause_turn': StreamFinishReason.length,
      'compaction': StreamFinishReason.length,
      'model_context_window_exceeded': StreamFinishReason.length,
      'refusal': StreamFinishReason.contentFilter,
    };

    for (final entry in finishReasons.entries) {
      test('maps ${entry.key} to ${entry.value.name}', () async {
        final client = AnthropicClient(
          apiKey: 'sk-test',
          model: 'claude-3-5-sonnet',
          httpClient: _SseMockClient(_stopReasonStream(entry.key)),
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

    test(
      'finalizes complete tool args when provider omits content_block_stop',
      () async {
        final client = AnthropicClient(
          apiKey: 'sk-test',
          model: 'claude-3-5-sonnet',
          httpClient: _SseMockClient(
            _sseEvent('message_start', {
                  'type': 'message_start',
                  'message': {
                    'id': 'msg_1',
                    'type': 'message',
                    'role': 'assistant',
                    'content': [],
                    'model': 'claude-3-5-sonnet',
                    'usage': {'input_tokens': 1, 'output_tokens': 0},
                  },
                }) +
                _sseEvent('content_block_start', {
                  'type': 'content_block_start',
                  'index': 2,
                  'content_block': {
                    'type': 'tool_use',
                    'id': 'toolu_1',
                    'name': 'Read',
                    'input': <String, dynamic>{},
                  },
                }) +
                _sseEvent('content_block_delta', {
                  'type': 'content_block_delta',
                  'index': 2,
                  'delta': {
                    'type': 'input_json_delta',
                    'partial_json': '{"path": ',
                  },
                }) +
                _sseEvent('content_block_delta', {
                  'type': 'content_block_delta',
                  'index': 2,
                  'delta': {
                    'type': 'input_json_delta',
                    'partial_json': '"/novel"}',
                  },
                }) +
                _sseEvent('message_delta', {
                  'type': 'message_delta',
                  'delta': {'stop_reason': 'tool_use'},
                  'usage': {'output_tokens': 8},
                }) +
                _sseEvent('message_stop', {'type': 'message_stop'}),
          ),
        );

        final events = await client
            .chatStream(
              messages: [AgentMessage.user(id: 'u1', content: 'read')],
            )
            .toList();
        final toolCalls = events.whereType<ToolCallDelta>().toList();

        expect(toolCalls, hasLength(3));
        expect(toolCalls.first.isPartial, isTrue);
        expect(toolCalls[1].isPartial, isTrue);
        expect(toolCalls.last.isPartial, isFalse);
        expect(toolCalls.last.callId, 'toolu_1');
        expect(toolCalls.last.toolName, 'Read');
        expect(toolCalls.last.arguments, {'path': '/novel'});
        expect(events.last, isA<StreamComplete>());
      },
    );

    test(
      'finalizes complete tool args before a provider starts the next tool',
      () async {
        final client = AnthropicClient(
          apiKey: 'sk-test',
          model: 'claude-3-5-sonnet',
          httpClient: _SseMockClient(
            _sseEvent('message_start', {
                  'type': 'message_start',
                  'message': {
                    'id': 'msg_1',
                    'type': 'message',
                    'role': 'assistant',
                    'content': [],
                    'model': 'claude-3-5-sonnet',
                    'usage': {'input_tokens': 1, 'output_tokens': 0},
                  },
                }) +
                _sseEvent('content_block_start', {
                  'type': 'content_block_start',
                  'index': 2,
                  'content_block': {
                    'type': 'tool_use',
                    'id': 'toolu_1',
                    'name': 'Read',
                    'input': <String, dynamic>{},
                  },
                }) +
                _sseEvent('content_block_delta', {
                  'type': 'content_block_delta',
                  'index': 2,
                  'delta': {
                    'type': 'input_json_delta',
                    'partial_json': '{"path": "/novel"}',
                  },
                }) +
                _sseEvent('content_block_start', {
                  'type': 'content_block_start',
                  'index': 3,
                  'content_block': {
                    'type': 'tool_use',
                    'id': 'toolu_2',
                    'name': 'Read',
                    'input': <String, dynamic>{},
                  },
                }) +
                _sseEvent('content_block_delta', {
                  'type': 'content_block_delta',
                  'index': 3,
                  'delta': {
                    'type': 'input_json_delta',
                    'partial_json': '{"path": "/chapter"}',
                  },
                }) +
                _sseEvent('message_stop', {'type': 'message_stop'}),
          ),
        );

        final events = await client
            .chatStream(
              messages: [AgentMessage.user(id: 'u1', content: 'read')],
            )
            .toList();
        final finalToolCalls = events
            .whereType<ToolCallDelta>()
            .where((event) => !event.isPartial)
            .toList();

        expect(finalToolCalls, hasLength(2));
        expect(finalToolCalls[0].callId, 'toolu_1');
        expect(finalToolCalls[0].arguments, {'path': '/novel'});
        expect(finalToolCalls[1].callId, 'toolu_2');
        expect(finalToolCalls[1].arguments, {'path': '/chapter'});
        expect(events.last, isA<StreamComplete>());
      },
    );

    test(
      'keeps truncated tool JSON partial after content block stop',
      () async {
        final client = AnthropicClient(
          apiKey: 'sk-test',
          model: 'claude-3-5-sonnet',
          httpClient: _SseMockClient(
            _sseEvent('message_start', {
                  'type': 'message_start',
                  'message': {
                    'id': 'msg_1',
                    'type': 'message',
                    'role': 'assistant',
                    'content': [],
                    'model': 'claude-3-5-sonnet',
                    'usage': {'input_tokens': 1, 'output_tokens': 0},
                  },
                }) +
                _sseEvent('content_block_start', {
                  'type': 'content_block_start',
                  'index': 0,
                  'content_block': {
                    'type': 'tool_use',
                    'id': 'toolu_edit',
                    'name': 'Edit',
                    'input': <String, dynamic>{},
                  },
                }) +
                _sseEvent('content_block_delta', {
                  'type': 'content_block_delta',
                  'index': 0,
                  'delta': {
                    'type': 'input_json_delta',
                    'partial_json': '{"path":"/chapters/1","new_text":"half',
                  },
                }) +
                _sseEvent('content_block_stop', {
                  'type': 'content_block_stop',
                  'index': 0,
                }) +
                _sseEvent('message_stop', {'type': 'message_stop'}),
          ),
        );

        final events = await client
            .chatStream(
              messages: [AgentMessage.user(id: 'u1', content: 'edit')],
            )
            .toList();
        final calls = events.whereType<ToolCallDelta>().toList();

        expect(calls, isNotEmpty);
        expect(calls.last.callId, 'toolu_edit');
        expect(calls.last.isPartial, isTrue);
      },
    );
  });
}

class _SseMockClient extends http.BaseClient {
  _SseMockClient(this.body, {this.onRequest});
  final void Function(Map<String, dynamic>)? onRequest;

  final String body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(request.method, 'POST');
    expect(request.url.path, '/v1/messages');
    if (onRequest != null) {
      onRequest!(
        jsonDecode(await request.finalize().bytesToString())
            as Map<String, dynamic>,
      );
    }
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

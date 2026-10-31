// 职责: 验证 Anthropic 请求固定携带顶层自动缓存标记，非流式与流式请求一致。
// 关联文件:
//   lib/shared/agent/client/anthropic_client.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/agent/client/anthropic_client.dart';
import 'package:reveric/shared/agent/message.dart';

void main() {
  final messages = [
    AgentMessage.system(id: 'system', content: 'stable system'),
    AgentMessage.user(id: 'user', content: 'hello'),
  ];

  test(
    'non-streaming request sends top-level ephemeral cache_control',
    () async {
      Map<String, dynamic>? body;
      final client = AnthropicClient(
        apiKey: 'key',
        model: 'claude-test',
        httpClient: MockClient((request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'id': 'msg',
              'type': 'message',
              'role': 'assistant',
              'model': 'claude-test',
              'content': [
                {'type': 'text', 'text': 'ok'},
              ],
              'stop_reason': 'end_turn',
              'usage': {'input_tokens': 1, 'output_tokens': 1},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      await client.chat(messages: messages);
      expect(body?['cache_control'], {'type': 'ephemeral'});
      expect(body?['system'], 'stable system');
    },
  );

  test('streaming request sends top-level ephemeral cache_control', () async {
    Map<String, dynamic>? body;
    final client = AnthropicClient(
      apiKey: 'key',
      model: 'claude-test',
      streamHttpClientFactory: () => MockClient.streaming((
        request,
        stream,
      ) async {
        body =
            jsonDecode(await utf8.decodeStream(stream)) as Map<String, dynamic>;
        return http.StreamedResponse(
          Stream.value(utf8.encode('')),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    await client
        .chatStream(messages: messages)
        .drain<void>()
        .catchError((_) {});
    expect(body?['cache_control'], {'type': 'ephemeral'});
  });
}

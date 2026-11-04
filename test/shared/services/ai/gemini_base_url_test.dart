// 职责: 验证 Gemini 图片生成的直连请求遵循自定义 Base URL。
// 关联文件:
//   lib/shared/agent/client/gemini_client.dart
//   lib/shared/services/ai/image/gemini.dart

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/agent/client/gemini_client.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/services/ai/image.dart';
import 'package:reveric/shared/services/ai/image/client.dart';
import 'package:reveric/shared/services/ai/image/gemini.dart';

const _relay = ' https://relay.example/proxy/v1beta/?route=chat ';

final _provider = aiProviderBuiltinById(
  'gemini',
)!.copyWith(baseUrl: _relay, apiKey: 'relay-key', enabled: true);

void _expectRelayRequest(http.Request request, String model) {
  expect(request.url.host, 'relay.example');
  expect(request.url.path, '/proxy/v1beta/models/$model:generateContent');
  expect(request.url.queryParameters['route'], 'chat');
  expect(request.url.queryParameters.containsKey('key'), isFalse);
  expect(request.headers['x-goog-api-key'], 'relay-key');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('geminiModelEndpoint falls back to the official host', () {
    expect(
      geminiModelEndpoint('', 'gemini-test', 'generateContent').toString(),
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent',
    );
  });

  test('Gemini image generation uses the configured base URL', () async {
    final requests = <http.Request>[];
    await http.runWithClient(
      () async {
        await expectLater(
          GeminiImageClient(_provider).generate(
            const ImageGenerationRequest(
              prompt: 'a bird',
              model: 'gemini-image-test',
            ),
          ),
          throwsA(isA<AiImageGenerationException>()),
        );
      },
      () => MockClient((request) async {
        requests.add(request);
        return http.Response(jsonEncode({'candidates': []}), 200);
      }),
    );
    expect(requests, hasLength(1));
    _expectRelayRequest(requests.single, 'gemini-image-test');
  });
}

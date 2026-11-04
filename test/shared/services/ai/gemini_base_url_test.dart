// 职责: 验证 Gemini 图片生成与章节分段的直连请求遵循自定义 Base URL。
// 关联文件:
//   lib/shared/agent/client/gemini_client.dart
//   lib/shared/services/ai/image/gemini.dart
//   lib/shared/services/ai/embedding.dart

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/agent/client/gemini_client.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/services/ai/embedding.dart';
import 'package:reveric/shared/services/ai/image.dart';
import 'package:reveric/shared/services/ai/image/client.dart';
import 'package:reveric/shared/services/ai/image/gemini.dart';
import 'package:reveric/shared/services/ai/prompt_template.dart';
import 'package:reveric/shared/services/novel_content.dart';

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
  setUpAll(PromptTemplateService.loadAll);

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

  test('Gemini segmenter uses the configured base URL', () async {
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    final content = NovelContentService(db);
    try {
      final chapter = await content.createChapter(
        siblingOrder: 1,
        title: 'chapter',
      );
      await content.updateChapterContent(
        chapterId: chapter,
        title: 'chapter',
        outline: '',
        content: 'A bird crosses the sky.',
      );
      final segmenterRequests = <http.Request>[];
      final mock = MockClient((request) async {
        if (request.url.path.endsWith(':generateContent')) {
          segmenterRequests.add(request);
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': '["A bird crosses the sky."]'},
                    ],
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'embedding': {
              'values': [0.1, 0.2],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = AiEmbeddingService(
        providerClient: GeminiClient(
          apiKey: 'relay-key',
          baseUrl: _relay,
          httpClient: mock,
        ),
        config: _provider,
        novelContentService: content,
        embeddingModel: 'embedding-fixture',
        segmenterModel: 'gemini-segmenter-test',
      );
      await http.runWithClient(
        () => service.rebuildChapterEmbeddings(chapter),
        () => mock,
      );
      expect(segmenterRequests, hasLength(1));
      _expectRelayRequest(segmenterRequests.single, 'gemini-segmenter-test');
    } finally {
      await db.close();
    }
  });
}

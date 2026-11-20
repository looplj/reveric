// 职责: 验证 Codex 生图的主模型选择、图片协议、流完整性与编辑落盘。
// 关联文件:
//   lib/shared/services/ai/codex/image_client.dart
//   lib/shared/services/ai/codex/credentials.dart
//   lib/shared/services/ai/image.dart
//   lib/shared/models/ai_provider.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/services/ai/codex/credentials.dart';
import 'package:reveric/shared/services/ai/codex/image_client.dart';
import 'package:reveric/shared/services/ai/image.dart';

const _auth = CodexCredentials(
  accessToken: 'test-secret',
  accountId: 'account',
);
final _png = img.encodePng(img.Image(width: 2, height: 2));
Map<String, dynamic> _item() => {
  'type': 'image_generation_call',
  'id': 'image-1',
  'status': 'completed',
  'result': base64Encode(_png),
};
Map<String, dynamic> _completed({List<Object>? output}) => {
  'type': 'response.completed',
  'response': {
    'status': 'completed',
    'output': output ?? [_item()],
  },
};
String _event(Map<String, dynamic> event) =>
    'data: ${jsonEncode(event)}\r\n\r\n';
http.StreamedResponse _sse(String body, {bool split = false}) {
  final bytes = utf8.encode(body);
  return http.StreamedResponse(
    Stream.fromIterable(
      split
          ? [
              for (var i = 0; i < bytes.length; i += 7)
                bytes.sublist(i, min(i + 7, bytes.length)),
            ]
          : [bytes],
    ),
    200,
    headers: {'content-type': 'text/event-stream'},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Map<String, dynamic>> generate(
    _Client transport, {
    List<String> models = const ['other', 'gpt-6-luna'],
    List<String> references = const [],
    Random? random,
  }) =>
      CodexImageClient(
        client: transport,
        credentials: () async => _auth,
        random: random,
      ).generate(
        prompt: '画一棵树',
        imageModel: 'gpt-image-2',
        chatModels: models,
        referenceImages: references,
        size: '1024x1024',
        quality: 'low',
      );

  test(
    'uses Luna, auth and image tool parameters and decodes split SSE',
    () async {
      late http.Request request;
      final transport = _Client((r) {
        request = r;
        return _sse(_event(_completed()), split: true);
      });
      final result = await generate(transport);
      final body = jsonDecode(request.body) as Map;
      expect(
        request.url.toString(),
        'https://chatgpt.com/backend-api/codex/responses',
      );
      expect(request.headers['Authorization'], 'Bearer test-secret');
      expect(request.headers['Chatgpt-Account-Id'], 'account');
      expect(request.headers['session_id'], body['prompt_cache_key']);
      expect(request.headers['conversation_id'], body['prompt_cache_key']);
      expect(body['model'], 'gpt-6-luna');
      expect(body['stream'], true);
      expect(body['store'], false);
      expect(body['tool_choice'], 'required');
      expect(body['tools'], [
        {
          'type': 'image_generation',
          'model': 'gpt-image-2',
          'action': 'generate',
          'output_format': 'png',
          'size': '1024x1024',
          'quality': 'low',
        },
      ]);
      expect(body['input'][0]['content'][0]['text'], '画一棵树');
      expect(base64Decode(result['data'][0]['b64_json']), _png);
      expect(transport.closed, true);
    },
  );

  test(
    'randomly chooses from configured chat models when Luna is absent',
    () async {
      final random = _LastRandom();
      final transport = _Client((request) {
        expect(jsonDecode(request.body)['model'], 'second');
        return _sse(_event(_completed()));
      });
      await generate(transport, models: ['first', 'second'], random: random);
      expect(random.bound, 2);
    },
  );

  test('empty chat models fail before auth or networking', () async {
    final transport = _Client((_) => throw StateError('must not send'));
    final client = CodexImageClient(
      client: transport,
      credentials: () => throw StateError('must not read'),
    );
    await expectLater(
      client.generate(prompt: 'x', imageModel: 'gpt-image-2', chatModels: []),
      throwsA(
        isA<CodexImageException>().having(
          (e) => e.reason,
          'reason',
          'no_chat_models',
        ),
      ),
    );
    expect(transport.closed, true);
  });

  test('edits include all references and explicit edit action', () async {
    final refs = [
      'data:image/png;base64,${base64Encode(_png)}',
      'data:image/png;base64,${base64Encode(_png)}',
    ];
    final transport = _Client((request) {
      final body = jsonDecode(request.body) as Map;
      expect(body['tools'][0]['action'], 'edit');
      expect(
        (body['input'][0]['content'] as List)
            .skip(1)
            .map((e) => e['image_url']),
        refs,
      );
      return _sse(_event(_completed()));
    });
    await generate(transport, references: refs);
  });

  test(
    'completed item can precede a terminal response without repeated output',
    () async {
      final transport = _Client(
        (_) => _sse(
          _event({'type': 'response.output_item.done', 'item': _item()}) +
              _event(_completed(output: [])),
        ),
      );
      expect((await generate(transport))['data'], hasLength(1));
    },
  );

  for (final body in [
    _event({'type': 'response.output_item.done', 'item': _item()}),
    _event({
      'type': 'response.image_generation_call.partial_image',
      'partial_image_b64': base64Encode(_png),
    }),
    'data: [DONE]\n\n',
    _event({
      'type': 'response.incomplete',
      'response': {
        'status': 'incomplete',
        'output': [_item()],
      },
    }),
    _event({
      'type': 'response.failed',
      'response': {'status': 'failed'},
    }),
    _event({'type': 'error', 'message': 'secret'}) + _event(_completed()),
    'event: error\ndata: secret non-json\n\n${_event(_completed())}',
    'data: secret malformed json\n\n',
    _event(_completed(output: [])),
    _event(
      _completed(
        output: [
          {..._item(), 'result': base64Encode(utf8.encode('not an image'))},
        ],
      ),
    ),
    _event(
      _completed(
        output: [
          {..._item(), 'result': 'invalid base64!'},
        ],
      ),
    ),
    _event(
      _completed(
        output: [
          {..._item(), 'status': 'in_progress'},
        ],
      ),
    ),
  ]) {
    test(
      'rejects failed or incomplete image stream case ${body.hashCode}',
      () async {
        final transport = _Client((_) => _sse(body));
        await expectLater(
          generate(transport),
          throwsA(
            isA<CodexImageException>().having(
              (e) => e.toString(),
              'safe message',
              isNot(contains('secret')),
            ),
          ),
        );
        expect(transport.closed, true);
      },
    );
  }

  for (final status in [401, 403, 429, 500]) {
    test(
      'HTTP $status keeps classification without exposing auth or body',
      () async {
        final transport = _Client(
          (_) => http.StreamedResponse(
            Stream.value(
              utf8.encode(
                jsonEncode({
                  'error': {
                    'code': 'rate_limit_exceeded',
                    'message': 'test-secret',
                  },
                }),
              ),
            ),
            status,
          ),
        );
        await expectLater(
          generate(transport),
          throwsA(
            isA<CodexImageException>()
                .having((e) => e.statusCode, 'HTTP status', status)
                .having(
                  (e) => e.toString(),
                  'safe message',
                  isNot(contains('test-secret')),
                ),
          ),
        );
        expect(transport.closed, true);
      },
    );
  }

  test('supports completed JSON and data-URI image results', () async {
    final transport = _Client(
      (_) => http.StreamedResponse(
        Stream.value(
          utf8.encode(
            jsonEncode({
              'status': 'completed',
              'output': [
                {
                  ..._item(),
                  'result': 'data:image/png;base64,${base64Encode(_png)}',
                },
              ],
            }),
          ),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    expect(
      base64Decode((await generate(transport))['data'][0]['b64_json']),
      _png,
    );
  });

  test('timeout closes the transport', () async {
    final transport = _Client((_) => Completer<http.StreamedResponse>().future);
    final client = CodexImageClient(
      client: transport,
      credentials: () async => _auth,
      timeout: const Duration(milliseconds: 20),
    );
    await expectLater(
      client.generate(
        prompt: 'x',
        imageModel: 'gpt-image-2',
        chatModels: ['gpt-6-luna'],
      ),
      throwsA(
        isA<CodexImageException>().having((e) => e.reason, 'reason', 'timeout'),
      ),
    );
    expect(transport.closed, true);
  });

  test(
    'HTTP auth status takes precedence over the upstream error code',
    () async {
      final provider = aiProviderBuiltinById(
        'openai',
      )!.copyWith(type: 'codex', apiKey: '', models: ['gpt-6-luna']);
      final service = AiImageGenerationService(
        provider,
        model: 'gpt-image-2',
        codexImageClientFactory: () => CodexImageClient(
          credentials: () async => _auth,
          client: _Client(
            (_) => http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  jsonEncode({
                    'error': {
                      'code': 'rate_limit_exceeded',
                      'message': 'test-secret',
                    },
                  }),
                ),
              ),
              401,
            ),
          ),
        ),
      );
      await expectLater(
        service.generateImage('test'),
        throwsA(
          isA<AiImageGenerationException>()
              .having((e) => e.code, 'code', AiImageErrorCode.auth)
              .having(
                (e) => e.userMessage,
                'original provider message',
                'test-secret',
              ),
        ),
      );
    },
  );

  for (final (upstreamCode, expected) in [
    ('rate_limit_exceeded', AiImageErrorCode.rate_limit),
    ('insufficient_quota', AiImageErrorCode.credit),
    ('invalid_api_key', AiImageErrorCode.auth),
  ]) {
    test('facade preserves HTTP 200 SSE rejection $upstreamCode', () async {
      var posts = 0;
      final provider = aiProviderBuiltinById(
        'openai',
      )!.copyWith(type: 'codex', apiKey: '', models: ['gpt-6-luna']);
      final service = AiImageGenerationService(
        provider,
        model: 'gpt-image-2',
        codexImageClientFactory: () => CodexImageClient(
          credentials: () async => _auth,
          client: _Client((_) {
            posts++;
            return _sse(
              'event: error\ndata: ${jsonEncode({
                'error': {'code': upstreamCode, 'message': 'Provider $upstreamCode'},
              })}\n\n',
            );
          }),
        ),
      );
      await expectLater(
        service.generateImage('test'),
        throwsA(
          isA<AiImageSubmissionException>()
              .having((e) => e.failureCode, 'submission outcome', 'rejected')
              .having((e) => e.code, 'mapped category', expected)
              .having(
                (e) => e.userMessage,
                'provider message',
                'Provider $upstreamCode',
              ),
        ),
      );
      expect(posts, 1);
    });
  }
  test('facade keeps unclassified HTTP 200 SSE failure uncertain', () async {
    var posts = 0;
    final provider = aiProviderBuiltinById(
      'openai',
    )!.copyWith(type: 'codex', apiKey: '', models: ['gpt-6-luna']);
    final service = AiImageGenerationService(
      provider,
      model: 'gpt-image-2',
      codexImageClientFactory: () => CodexImageClient(
        credentials: () async => _auth,
        client: _Client((_) {
          posts++;
          return _sse(
            'event: error\ndata: {"error":{"code":"unknown","message":"unknown result"}}\n\n',
          );
        }),
      ),
    );
    await expectLater(
      service.generateImage('test'),
      throwsA(
        isA<AiImageSubmissionException>().having(
          (e) => e.failureCode,
          'submission outcome',
          'submission_unknown',
        ),
      ),
    );
    expect(posts, 1);
  });

  test('SSE error header retains structured quota classification', () async {
    final transport = _Client(
      (_) => _sse(
        'event: error\ndata: {"error":{"code":"rate_limit_exceeded"}}\n\n',
      ),
    );
    await expectLater(
      generate(transport),
      throwsA(
        isA<CodexImageException>().having(
          (e) => e.code,
          'code',
          'rate_limit_exceeded',
        ),
      ),
    );
  });

  test(
    'image service saves generation and multi-reference edit through the same adapter',
    () async {
      final support = await Directory.systemTemp.createTemp(
        'reveric-codex-image-test-',
      );
      addTearDown(() => support.delete(recursive: true));
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(channel, (call) async => support.path);
      await RevericPaths.initialize();
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final requests = <Map>[];
      final provider = aiProviderBuiltinById('openai')!.copyWith(
        type: 'codex',
        apiKey: '',
        models: ['gpt-6-luna'],
        imageModels: ['gpt-image-2'],
      );
      final service = AiImageGenerationService(
        provider,
        model: 'gpt-image-2',
        codexImageClientFactory: () => CodexImageClient(
          credentials: () async => _auth,
          client: _Client((request) {
            requests.add(jsonDecode(request.body) as Map);
            return _sse(_event(_completed()));
          }),
        ),
      );
      final result = await service.generateImage('a tree');
      expect(await File(result.localFilePath!).readAsBytes(), _png);
      final edited = await service.editImages(
        'make it blue',
        imageData: [result.localFilePath!, result.effectiveSource!],
      );
      expect(await File(edited.localFilePath!).readAsBytes(), _png);
      expect(requests.last['tools'][0]['action'], 'edit');
      expect(requests.last['input'][0]['content'], hasLength(3));
      expect(edited.mimeSubtype, 'png');
    },
  );
}

class _Client extends http.BaseClient {
  _Client(this.handle);
  final FutureOr<http.StreamedResponse> Function(http.Request) handle;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      handle(request as http.Request);
  @override
  void close() {
    closed = true;
  }
}

class _LastRandom implements Random {
  int? bound;
  @override
  int nextInt(int max) {
    bound = max;
    return max - 1;
  }

  @override
  bool nextBool() => throw UnimplementedError();
  @override
  double nextDouble() => throw UnimplementedError();
}

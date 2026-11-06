// 职责: 验证 OpenAI 兼容生图从 URL 拉字节落盘，下载失败不回退 b64。
// 关联文件:
//   lib/shared/services/ai/image.dart
//   lib/shared/models/ai_provider.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'dart:convert';
import 'dart:io';
import 'package:reveric/shared/utils/storage_paths.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/image/channels.dart';
import 'package:reveric/shared/services/ai/image.dart';

const _pngBytes = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory supportDir;
  late HttpServer server;
  late String baseUrl;
  String? requestedResponseFormat;
  Map<String, dynamic>? requestedBody;
  int imageStatus = 200;

  setUp(() async {
    HttpOverrides.global = null;
    supportDir = await Directory.systemTemp.createTemp('reveric_image_url_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async =>
              {
                'getApplicationSupportDirectory',
                'getTemporaryDirectory',
              }.contains(call.method)
              ? supportDir.path
              : null,
        );

    await RevericPaths.initialize();
    requestedResponseFormat = null;
    requestedBody = null;
    imageStatus = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}/v1';
    server.listen((request) async {
      if (request.method == 'POST' &&
          request.uri.path == '/v1/images/generations') {
        final raw = await utf8.decoder.bind(request).join();
        final body = jsonDecode(raw) as Map<String, dynamic>;
        requestedBody = body;
        requestedResponseFormat = body['response_format'] as String?;
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'created': 1,
              'data': [
                {
                  'url': 'http://127.0.0.1:${server.port}/generated.png',
                  'revised_prompt': 'cover',
                },
              ],
            }),
          );
        await request.response.close();
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/generated.png') {
        request.response.statusCode = imageStatus;
        if (imageStatus == 200) {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(_pngBytes);
        }
        await request.response.close();
        return;
      }
      request.response.statusCode = 404;
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (await supportDir.exists()) {
      await supportDir.delete(recursive: true);
    }
  });

  for (final model in imageModelsForProvider('agnes')) {
    test('$model generates and edits through Agnes JSON generations', () async {
      final service = AiImageGenerationService(
        _openAiCompatibleProvider(baseUrl).copyWith(type: 'agnes'),
        model: model,
      );
      final modern = model != 'agnes-image-2.0-flash';
      final result = await service.generateImage(
        'a cover',
        size: modern ? '2624x1472' : '1024x768',
        quality: 'high',
      );
      expect(result.localFilePath, isNotNull);
      expect(requestedBody, {
        'model': model,
        'prompt': 'a cover',
        'size': modern ? '2K' : '1024x768',
        if (modern) 'ratio': '16:9',
        'extra_body': {'response_format': 'b64_json'},
      });
      final inputs = [
        'data:image/png;base64,${base64Encode(_pngBytes)}',
        'https://reference.example/image.png',
      ];
      await service.editImages('combine', imageData: inputs);
      expect(requestedBody, {
        'model': model,
        'prompt': 'combine',
        'size': modern ? '1K' : '1024x1024',
        if (modern) 'ratio': '1:1',
        'extra_body': {'response_format': 'b64_json', 'image': inputs},
      });
    });
  }

  for (final type in ['openai_compatible', 'agnes']) {
    test('$type requests and image downloads use the provider proxy', () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      final calls = <(String, String, String?, String?)>[];
      proxy.listen((request) async {
        calls.add((
          request.method,
          request.uri.path,
          request.headers.value(HttpHeaders.authorizationHeader),
          request.headers.value(HttpHeaders.proxyAuthorizationHeader),
        ));
        await request.drain<void>();
        if (request.method == 'POST') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'data': [
                {'url': 'http://results.invalid/generated.png'},
              ],
            }),
          );
        } else {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(_pngBytes);
        }
        await request.response.close();
      });
      final service = AiImageGenerationService(
        _openAiCompatibleProvider(baseUrl).copyWith(
          type: type,
          proxyUrl: 'http://127.0.0.1:${proxy.port}',
          proxyUsername: 'user',
          proxyPassword: 'secret',
        ),
        model: type == 'agnes' ? 'agnes-image-2.0-flash' : 'image-advance',
      );
      final generated = await service.generateImage('cover');
      expect(File(generated.localFilePath!).readAsBytesSync(), _pngBytes);
      expect(calls.map((c) => (c.$1, c.$2)), [
        ('POST', '/v1/images/generations'),
        ('GET', '/generated.png'),
      ]);
      final edited = await service.editImages(
        'edit',
        imageData: ['http://127.0.0.1:${server.port}/reference.png'],
      );
      expect(File(edited.localFilePath!).readAsBytesSync(), _pngBytes);
      expect(
        calls.skip(2).map((c) => (c.$1, c.$2)),
        type == 'agnes'
            ? [('POST', '/v1/images/generations'), ('GET', '/generated.png')]
            : [
                ('GET', '/reference.png'),
                ('POST', '/v1/images/edits'),
                ('GET', '/generated.png'),
              ],
      );
      for (final call in calls) {
        expect(call.$3, call.$1 == 'POST' ? 'Bearer test-api-key' : null);
        expect(call.$4, 'Basic ${base64Encode(utf8.encode('user:secret'))}');
      }
      await generated.disposeTemporary();
      await edited.disposeTemporary();
    });
  }

  test('saves COS url bytes to disk without keeping b64', () async {
    final service = AiImageGenerationService(
      _openAiCompatibleProvider(baseUrl),
      model: 'image-advance',
    );

    final result = await service.generateImage('a cover');

    expect(requestedResponseFormat, 'b64_json');
    expect(result.imageBase64, isNull);
    expect(result.imageUrl, 'http://127.0.0.1:${server.port}/generated.png');
    expect(result.localFilePath, isNotNull);
    expect(File(result.localFilePath!).readAsBytesSync(), _pngBytes);
    expect(
      File(result.localFilePath!).parent.path,
      '${supportDir.path}/file_workspaces',
    );
    expect(result.localFilePath, endsWith('.png.part'));
    await result.disposeTemporary();
    expect(File(result.localFilePath!).existsSync(), false);
    expect(result.mimeSubtype, 'png');
  });

  test('fails loud when the image url cannot be downloaded', () async {
    imageStatus = 403;
    final service = AiImageGenerationService(
      _openAiCompatibleProvider(baseUrl),
      model: 'image-advance',
    );

    await expectLater(
      service.generateImage('a cover'),
      throwsA(
        isA<AiImageFetchException>()
            .having(
              (error) => error.userMessage,
              'userMessage',
              '图片下载失败，请稍后重试。',
            )
            .having(
              (error) => error.url,
              'url',
              'http://127.0.0.1:${server.port}/generated.png',
            ),
      ),
    );
  });
}

AiProvider _openAiCompatibleProvider(String baseUrl) {
  return AiProvider(
    audioModels: const [],
    videoModels: const [],
    id: 'openai_compat',
    name: 'OpenAI Compatible',
    builtin: false,
    type: 'openai_compatible',
    enabled: true,
    apiKey: 'test-api-key',
    baseUrl: baseUrl,
    models: const [],
    imageModels: const ['image-advance'],
    embeddingModels: const [],
    temperature: 0.7,
    maxTurns: 8,
    proxyUrl: '',
    proxyUsername: '',
    proxyPassword: '',
    updatedAt: DateTime(2026, 1, 1),
    deletedAt: notDeletedSentinel,
  );
}

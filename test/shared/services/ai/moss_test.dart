// 职责: 验证 MOSS 的模型登记、语音路由、请求校验与文生图下载。
// 关联文件:
//   lib/shared/services/ai/audio/moss.dart
//   lib/shared/services/ai/image/moss.dart
//   lib/shared/models/audio/channels.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/audio/channels.dart';
import 'package:reveric/shared/models/audio/exception.dart';
import 'package:reveric/shared/models/audio/request.dart';
import 'package:reveric/shared/models/image/channels.dart';
import 'package:reveric/shared/services/ai/audio/moss.dart';
import 'package:reveric/shared/services/ai/image.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==';
AudioRequest request(
  String model, {
  String? voice,
  String? instructions,
  String format = 'mp3',
}) => AudioRequest(
  providerId: 'moss',
  modelId: model,
  prompt: '你好',
  originalPrompt: '你好',
  parameters: AudioRequestDefaults(
    voice: ConfigValue(voice),
    instructions: ConfigValue(instructions),
    responseFormat: ConfigValue(format),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final provider = aiProviderBuiltinById('openai')!.copyWith(
    id: 'moss',
    name: 'MOSS',
    type: 'moss',
    apiKey: 'test-key',
    enabled: true,
    imageModels: imageModelsForProvider('moss'),
    audioModels: audioModelsForProvider('moss'),
  );
  late Directory support;
  late HttpServer server;
  HttpOverrides? previousOverrides;
  var downloads = 0;
  setUp(() async {
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    downloads = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      downloads++;
      expect(r.headers.value(HttpHeaders.authorizationHeader), isNull);
      r.response.headers.contentType = ContentType("image", "png");
      r.response.add(base64Decode(_png));
      await r.response.close();
    });
    support = await Directory.systemTemp.createTemp('moss-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => support.path,
        );
    await RevericPaths.initialize();
  });
  tearDown(() async {
    await server.close(force: true);
    HttpOverrides.global = previousOverrides;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await support.delete(recursive: true);
  });
  test('MOSS exposes only verified image and audio models', () {
    expect(provider.effectiveBaseUrl, 'https://api.mosi.cn/v1');
    expect(provider.typeConfig.supportedModelKinds, {
      AiModelKind.image,
      AiModelKind.audio,
    });
    expect(imageModelsForProvider('moss'), [
      'moss-image-base-1.0',
      'moss-image-sft-1.0',
    ]);
    expect(audioModelsForProvider('moss'), [
      'moss-tts-1.5-flash',
      'moss-tts-1.0-pro',
      'moss-voice-generator-1.0',
    ]);
  });
  for (final model in [
    'moss-tts-1.5-flash',
    'moss-tts-1.0-pro',
    'moss-voice-generator-1.0',
  ]) {
    test('$model sends its documented route and accepts URL output', () async {
      final design = model == 'moss-voice-generator-1.0';
      final transport = MockClient((r) async {
        expect(
          r.url.toString(),
          'https://api.mosi.cn/v1/audio/${design ? 'voice/generations' : 'speech'}',
        );
        expect(r.headers['Authorization'], 'Bearer test-key');
        expect(jsonDecode(r.body), {
          'model': model,
          'input': '你好',
          if (design) 'instruction': '温柔' else 'voice_id': 'voice-id',
          'response_format': 'mp3',
          'delivery_method': 'url',
        });
        return http.Response(
          jsonEncode({
            'status': 'SUCCESS',
            'url': 'https://cdn.example/audio.mp3',
            'content_type': 'audio/mpeg',
          }),
          200,
        );
      });
      addTearDown(transport.close);
      final result = await MossAudioClient(transport, 'test-key').generate(
        request(
          model,
          voice: design ? null : 'voice-id',
          instructions: design ? '温柔' : null,
        ),
      );
      expect(result.url.toString(), 'https://cdn.example/audio.mp3');
      expect(result.mimeType, 'audio/mpeg');
      expect(result.isPending, false);
    });
  }
  test(
    'missing voice or instructions and unsupported format never submit',
    () async {
      final transport = MockClient(
        (_) async => fail('Invalid input must not submit'),
      );
      addTearDown(transport.close);
      final client = MossAudioClient(transport, 'test-key');
      for (final input in [
        request('moss-tts-1.5-flash'),
        request('moss-voice-generator-1.0'),
        request('moss-tts-1.0-pro', voice: 'voice', format: 'pcm'),
      ]) {
        await expectLater(
          client.generate(input),
          throwsA(isA<AudioException>()),
        );
      }
    },
  );
  test(
    'HTTP failures preserve provider diagnostics and do not retry POST',
    () async {
      var calls = 0;
      final transport = MockClient((_) async {
        calls++;
        return http.Response(
          '{"error":{"code":"voice_not_found","message":"Voice does not exist"}}',
          404,
        );
      });
      addTearDown(transport.close);
      await expectLater(
        MossAudioClient(
          transport,
          'test-key',
        ).generate(request('moss-tts-1.5-flash', voice: 'missing')),
        throwsA(
          isA<AudioException>()
              .having((e) => e.statusCode, 'status', 404)
              .having((e) => e.detail, 'detail', contains('voice_not_found')),
        ),
      );
      expect(calls, 1);
    },
  );
  for (final model in imageModelsForProvider('moss')) {
    test(
      '$model requests URL output and downloads without credentials',
      () async {
        var calls = 0;
        await http.runWithClient(
          () async {
            final result = await AiImageGenerationService(
              provider,
              model: model,
            ).generateImage('An apple', size: '1024x1024');
            expect(
              await File(result.localFilePath!).readAsBytes(),
              base64Decode(_png),
            );
          },
          () => MockClient((r) async {
            calls++;
            if (r.method == 'POST') {
              expect(
                r.url.toString(),
                'https://api.mosi.cn/v1/images/generations',
              );
              expect(jsonDecode(r.body), {
                'model': model,
                'prompt': 'An apple',
                'size': '1024x1024',
                'n': 1,
                'response_format': 'url',
                'output_watermark': {'enabled': false},
              });
              return http.Response(
                '{"data":[{"url":"http://127.0.0.1:${server.port}/image.png"}]}',
                200,
              );
            }
            expect(r.headers['Authorization'], isNull);
            return http.Response.bytes(
              base64Decode(_png),
              200,
              headers: {'content-type': 'image/png'},
            );
          }),
        );
        expect(calls, 1);
        expect(downloads, 1);
      },
    );
  }
  test(
    'unsupported edits and dimensions fail before image submission',
    () async {
      await http.runWithClient(() async {
        final service = AiImageGenerationService(
          provider,
          model: 'moss-image-base-1.0',
        );
        for (final size in ['257x256', '2048x2048', '128x128']) {
          await expectLater(
            service.generateImage('apple', size: size),
            throwsA(isA<AiImageGenerationException>()),
          );
        }
        await expectLater(
          service.editImages(
            'apple',
            imageData: ['data:image/png;base64,$_png'],
          ),
          throwsA(isA<AiImageGenerationException>()),
        );
      }, () => MockClient((_) async => fail('Invalid input must not submit')));
    },
  );
}

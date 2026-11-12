// 职责: 验证 OpenRouter 图片、音频和视频协议及视频下载凭据边界。
// 关联文件:
//   lib/shared/services/ai/image.dart
//   lib/shared/services/ai/audio/openrouter.dart
//   lib/shared/services/ai/video/openrouter.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/image/channels.dart';
import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/models/audio/request.dart';
import 'package:reveric/shared/models/audio/exception.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:reveric/shared/services/ai/audio/openrouter.dart';
import 'package:reveric/shared/services/ai/image.dart';
import 'package:reveric/shared/services/ai/video/openrouter.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:reveric/shared/widgets/settings/provider_config_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final provider = aiProviderBuiltinById('openai')!.copyWith(
    type: 'openrouter',
    apiKey: 'key',
    baseUrl: 'https://ignored.invalid',
  );
  test(
    'model discovery routes chat and audio separately from media catalogs',
    () async {
      for (final kind in [AiModelKind.chat, AiModelKind.audio]) {
        final models = await http.runWithClient(
          () => fetchProviderModels(provider, kind: kind),
          () => MockClient((r) async {
            expect(r.url.origin, 'https://openrouter.ai');
            expect(r.url.path, '/api/v1/models');
            expect(r.url.queryParameters['output_modalities'], switch (kind) {
              AiModelKind.chat => 'text',
              AiModelKind.audio => 'speech',
              _ => null,
            });
            expect(r.headers['Authorization'], 'Bearer key');
            if (kind == AiModelKind.audio) {
              return http.Response(
                jsonEncode({
                  'data': [
                    {
                      'id': 'bytedance-seed/seed-audio-1-0',
                      'architecture': {
                        'output_modalities': ['speech'],
                      },
                    },
                    {
                      'id': 'vendor/model',
                      'architecture': {
                        'output_modalities': ['text'],
                      },
                    },
                  ],
                }),
                200,
              );
            }
            return http.Response('{"data":[{"id":"vendor/model"}]}', 200);
          }),
        );
        expect(
          models,
          kind == AiModelKind.audio
              ? ['bytedance-seed/seed-audio-1-0']
              : ['vendor/model'],
        );
      }
      final images = await http.runWithClient(
        () => fetchProviderModels(provider, kind: AiModelKind.image),
        () => MockClient((r) async {
          expect(r.url.origin, 'https://openrouter.ai');
          expect(r.url.path, '/api/v1/images/models');
          expect(r.url.queryParameters, isEmpty);
          expect(r.headers['Authorization'], 'Bearer key');
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'qwen/qwen-image-3'},
                {'id': 'bytedance-seed/seedream-5.5'},
              ],
            }),
            200,
          );
        }),
      );
      expect(images, ['bytedance-seed/seedream-5.5', 'qwen/qwen-image-3']);
      expect(
        lookupImageChannelModel('openrouter', 'bytedance-seed/seedream-5.5'),
        isNull,
      );
      final unlisted = ProductionImageCapabilities(
        provider,
        'bytedance-seed/seedream-5.5',
      );
      expect(unlisted.isSupported, isTrue);
      expect(unlisted.verifiedCapabilities, isNull);
      expect(unlisted.ratios, contains('16:9'));
      expect(unlisted.resolutions, contains('2K'));
      expect(unlisted.maxReferences, isNull);
      expect(
        lookupImageChannelModel('openrouter', 'qwen/qwen-image-3')!.catalogId,
        'qwen-image-3.0',
      );
      expect(
        await fetchProviderModels(provider, kind: AiModelKind.video),
        contains('google/veo-3.1'),
      );
    },
  );

  test(
    'image generation and editing use images JSON endpoint and save PNG',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'reveric_openrouter_image_',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => dir.path,
      );
      await RevericPaths.initialize();
      addTearDown(() async {
        messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        await dir.delete(recursive: true);
      });
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==';
      final bodies = <Map>[];
      await http.runWithClient(
        () async {
          final service = AiImageGenerationService(
            provider,
            model: 'google/gemini-2.5-flash-image',
          );
          final generated = await service.generateImage(
            'cover',
            size: '1024x1024',
          );
          expect(
            await File(generated.localFilePath!).readAsBytes(),
            base64Decode(png),
          );
          final edited = await service.editImage(
            'edit',
            imageData: 'data:image/png;base64,$png',
          );
          expect(edited.mimeSubtype, 'png');
        },
        () => MockClient((r) async {
          expect(r.url.toString(), 'https://openrouter.ai/api/v1/images');
          expect(r.headers['Authorization'], 'Bearer key');
          bodies.add(jsonDecode(r.body) as Map);
          return http.Response(
            jsonEncode({
              'data': [
                {'b64_json': png, 'media_type': 'image/png'},
              ],
            }),
            200,
          );
        }),
      );
      expect(bodies.first['size'], '1024x1024');
      expect(bodies.last['input_references'], [
        {
          'type': 'image_url',
          'image_url': {'url': 'data:image/png;base64,$png'},
        },
      ]);
    },
  );

  test('Seed audio sends references and wraps PCM as WAV', () async {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    final client = OpenRouterAudioClient(
      MockClient((r) async {
        expect(r.url.toString(), 'https://openrouter.ai/api/v1/audio/speech');
        expect(r.headers['Authorization'], 'Bearer key');
        final body = jsonDecode(r.body) as Map;
        expect(body['input'], '@Audio1 Hello');
        expect(body['response_format'], 'pcm');
        expect(
          (body['input_references'] as List).single['type'],
          'input_audio',
        );
        return http.Response.bytes(
          bytes,
          200,
          headers: {'content-type': 'audio/pcm;rate=48000;channels=2'},
        );
      }),
      'key',
      providerType: 'openrouter',
    );
    final result = await client.generate(
      AudioRequest(
        providerId: 'p',
        modelId: 'bytedance-seed/seed-audio-1-0',
        prompt: '@Audio1 Hello',
        originalPrompt: '@Audio1 Hello',
        references: [
          const AudioReference(
            assetId: 'r.wav',
            kind: 'audio',
            mimeType: 'audio/wav',
            bytes: 4,
            durationMs: 1000,
          ),
        ],
      ),
      references: [
        Uint8List.fromList([1, 2, 3, 4]),
      ],
    );
    expect(result.bytes.sublist(44), bytes);
    expect(ascii.decode(result.bytes.sublist(0, 4)), 'RIFF');
    final wav = ByteData.sublistView(result.bytes);
    expect(wav.getUint32(24, Endian.little), 48000);
    expect(wav.getUint16(22, Endian.little), 2);
    expect(wav.getUint16(34, Endian.little), 16);
  });

  test(
    'explicit MP3 request overrides the PCM default without transcoding',
    () async {
      final mp3 = Uint8List.fromList([73, 68, 51, 1]);
      final client = OpenRouterAudioClient(
        MockClient((r) async {
          expect((jsonDecode(r.body) as Map)['response_format'], 'mp3');
          return http.Response.bytes(
            mp3,
            200,
            headers: {'content-type': 'audio/mpeg'},
          );
        }),
        'key',
        providerType: 'openrouter',
      );
      final result = await client.generate(
        AudioRequest(
          providerId: 'p',
          modelId: 'bytedance-seed/seed-audio-1-0',
          prompt: 'Rain',
          originalPrompt: 'Rain',
          parameters: const AudioRequestDefaults(
            responseFormat: ConfigValue('mp3'),
          ),
        ),
      );
      expect(result.bytes, mp3);
    },
  );

  for (final (contentType, pcm) in [
    ('audio/pcm', [1, 2]),
    ('audio/pcm;rate=0;channels=1', [1, 2]),
    ('audio/pcm;rate=24000;channels=0', [1, 2]),
    ('audio/pcm;rate=24000;channels=2', [1, 2]),
    ('audio/pcm;rate=24000;channels=1', [1]),
    ('audio/pcm;rate=24000;channels=1', <int>[]),
    ('application/json', [123, 125]),
    ('audio/mpeg', [73, 68, 51, 1]),
  ]) {
    test(
      'PCM rejects missing metadata or malformed samples: $contentType $pcm',
      () async {
        var posts = 0;
        final client = OpenRouterAudioClient(
          MockClient((_) async {
            posts++;
            return http.Response.bytes(
              pcm,
              200,
              headers: {'content-type': contentType},
            );
          }),
          'key',
          providerType: 'openrouter',
        );
        await expectLater(
          client.generate(
            AudioRequest(
              providerId: 'p',
              modelId: 'bytedance-seed/seed-audio-1-0',
              prompt: 'Rain',
              originalPrompt: 'Rain',
            ),
          ),
          throwsA(
            isA<AudioException>().having(
              (e) => e.code,
              'code',
              'audio_submission_unknown',
            ),
          ),
        );
        expect(posts, 1);
      },
    );
  }

  test(
    'image authentication failures retain HTTP category for non-JSON bodies',
    () async {
      await http.runWithClient(() async {
        final service = AiImageGenerationService(
          provider,
          model: 'google/gemini-2.5-flash-image',
        );
        await expectLater(
          service.generateImage('cover'),
          throwsA(
            isA<AiImageGenerationException>().having(
              (e) => e.code,
              'code',
              AiImageErrorCode.auth,
            ),
          ),
        );
      }, () => MockClient((_) async => http.Response('Unauthorized', 401)));
    },
  );

  test(
    'audio HTTP rejection retains its category without parsing PCM',
    () async {
      final client = OpenRouterAudioClient(
        MockClient(
          (_) async => http.Response('{"error":{"message":"bad key"}}', 401),
        ),
        'key',
        providerType: 'openrouter',
      );
      await expectLater(
        client.generate(
          AudioRequest(
            providerId: 'p',
            modelId: 'bytedance-seed/seed-audio-1-0',
            prompt: 'rain',
            originalPrompt: 'rain',
          ),
        ),
        throwsA(
          isA<AudioException>().having((e) => e.code, 'code', 'authentication'),
        ),
      );
    },
  );

  test(
    'video creates and polls a task through fixed route and rejects invalid duration',
    () async {
      var calls = 0;
      final client = OpenRouterVideoClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          calls++;
          expect(r.headers['Authorization'], 'Bearer key');
          if (r.method == 'POST') {
            expect(r.url.toString(), 'https://openrouter.ai/api/v1/videos');
            final body = jsonDecode(r.body) as Map;
            expect(body['duration'], 6);
            expect(body['aspect_ratio'], '16:9');
            return http.Response('{"id":"job","status":"pending"}', 202);
          }
          expect(r.url.toString(), 'https://openrouter.ai/api/v1/videos/job');
          return http.Response(
            '{"id":"job","status":"completed","unsigned_urls":["https://untrusted.invalid/file"]}',
            200,
          );
        }),
        providerType: 'openrouter',
      );
      VideoRequest request(int duration) => VideoRequest(
        modelId: 'google/veo-3.1',
        prompt: 'a scene',
        mode: VideoMode.text,
        resolution: '720p',
        ratio: '16:9',
        durationSeconds: duration,
        audio: true,
      );
      await expectLater(
        client.submit(request(5), []),
        throwsA(isA<VideoException>()),
      );
      expect(calls, 0);
      final submission = await client.submit(request(6), []);
      final result = await client.query(submission);
      expect(result.status, VideoRemoteStatus.succeeded);
      expect(
        result.videoUrl.toString(),
        'https://openrouter.ai/api/v1/videos/job/content',
      );
    },
  );

  test(
    'video download authenticates canonical endpoint and drops key on redirects',
    () async {
      var calls = 0;
      final client = MockClient((r) async {
        calls++;
        expect(r.followRedirects, isFalse);
        if (calls == 1) {
          expect(r.headers['Authorization'], 'Bearer key');
          return http.Response(
            '',
            302,
            headers: {'location': 'https://cdn.example/video.mp4'},
          );
        }
        expect(r.headers.containsKey('Authorization'), false);
        return http.Response('video', 200);
      });
      await expectLater(
        downloadOpenRouterVideo(
          client,
          Uri.parse('https://untrusted.invalid/file'),
          taskId: 'job',
          apiKey: 'key',
        ),
        throwsA(isA<VideoException>()),
      );
      expect(calls, 0);
      final response = await downloadOpenRouterVideo(
        client,
        Uri.parse('https://openrouter.ai/api/v1/videos/job/content'),
        taskId: 'job',
        apiKey: 'key',
      );
      expect(await response.stream.bytesToString(), 'video');
      expect(calls, 2);
    },
  );
}

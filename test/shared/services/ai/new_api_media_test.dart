// 职责: 验证 New API 图片编辑、原生 Gemini 语音和视频任务的完整协议边界。
// 关联文件:
//   lib/shared/services/ai/new_api.dart
//   lib/shared/services/ai/image/gemini.dart
//   lib/shared/services/ai/audio/gemini.dart
//   lib/shared/services/ai/video/new_api.dart
import 'dart:async';
import 'package:drift/native.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/services/ai/video/reference_storage_service.dart';
import '../../../helpers/fake_object_storage.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:reveric/shared/models/audio/request.dart';
import 'package:reveric/shared/models/audio/result.dart';
import 'package:reveric/shared/models/audio/exception.dart';
import 'package:reveric/shared/models/video/channels.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:reveric/shared/providers/production_audio.dart';
import 'package:reveric/shared/services/ai/new_api.dart';
import 'package:reveric/shared/services/ai/image.dart';
import 'package:reveric/shared/services/ai/audio/gemini.dart';
import 'package:reveric/shared/services/ai/video/new_api.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==';
AiProvider _provider([String type = 'api88']) =>
    aiProviderBuiltinById('openai')!.copyWith(
      type: type,
      apiKey: 'test-key',
      baseUrl: 'https://gateway.test/prefix',
    );
http.Response _json(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);
VideoRequest _video(
  String model, {
  VideoMode mode = VideoMode.text,
  bool? audio,
}) => VideoRequest(
  modelId: model,
  prompt: 'A bird',
  mode: mode,
  resolution: '720p',
  ratio: '16:9',
  durationSeconds: 8,
  audio: audio,
);
VideoReference _reference() => VideoReference(
  role: VideoInputRole.first_frame,
  url: 'https://reference.test/image.png',
  mimeType: 'image/png',
  fileSize: 100,
  mediaInfo: const VideoMediaInfo(width: 1280, height: 720),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('reveric-new-api-media-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => dir.path,
        );
    await RevericPaths.initialize();
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await dir.delete(recursive: true);
  });

  for (final (type, model) in [
    ('api88', 'gpt-image-2'),
    ('token91', 'new-image-model'),
    ('token91', 'gpt-image-2.5-flare'),
  ]) {
    test(
      '$type $model OpenAI image generation and multipart edits preserve pixels and auth',
      () async {
        final lines = <String>[];
        final originalPrint = debugPrint;
        debugPrint = (message, {wrapWidth}) {
          if (message != null) {
            lines.add(message);
          }
        };
        addTearDown(() => debugPrint = originalPrint);
        final paths = <String>[];
        await http.runWithClient(
          () async {
            final service = AiImageGenerationService(
              _provider(type),
              model: model,
            );
            final generated = await service.generateImage(
              'cover',
              size: '1024x1024',
            );
            expect(
              await File(generated.localFilePath!).readAsBytes(),
              base64Decode(_png),
            );
            await service.editImage(
              'edit',
              imageData: 'data:image/png;base64,$_png',
              size: '1024x1024',
            );
          },
          () => MockClient((request) async {
            paths.add(request.url.path);
            expect(
              request.url.host,
              type == 'token91' ? 'api-no.91token.com' : 'api.88api.ai',
            );
            expect(request.headers['Authorization'], 'Bearer test-key');
            if (request.url.path.endsWith('edits')) {
              expect(
                request.headers['content-type'],
                startsWith('multipart/form-data'),
              );
              final body = utf8.decode(request.bodyBytes, allowMalformed: true);
              expect(body, contains('name="image[]"'));
              expect(body, contains(model));
            } else {
              expect((jsonDecode(request.body) as Map)['size'], '1024x1024');
            }
            return _json({
              'data': [
                {'b64_json': _png},
              ],
            });
          }),
        );
        for (final path in paths) {
          expect(
            lines.any(
              (line) =>
                  line.contains('$path status=200 body=') &&
                  line.contains(_png),
            ),
            isTrue,
          );
        }
        expect(paths, ['/v1/images/generations', '/v1/images/edits']);
      },
    );
  }

  test(
    'Seedream downloads URL references and sends declared file bytes in JSON',
    () async {
      final database = AppDatabase.forTest(NativeDatabase.memory());
      final references = ReferenceStorageService(
        database: database,
        storage: FakeObjectStorage(
          database,
          ({
            required file,
            required sha256,
            required mimeType,
            required fileSize,
          }) async =>
              (url: 'https://reference.test/image.png', expiresAt: null),
        ),
        probe: (_, {cancellation}) async => const MediaInfo(
          duration: Duration.zero,
          hasAudio: false,
          hasVideo: true,
          width: 1,
          height: 1,
        ),
      );
      addTearDown(() async {
        references.dispose();
        await database.close();
      });
      await http.runWithClient(
        () async {
          await AiImageGenerationService(
            _provider(),
            model: 'doubao-seedream-5-0-pro',
            referenceStorage: references,
          ).editImage(
            'edit',
            imageData: 'https://reference.test/image.png',
            size: '1024x1024',
          );
        },
        () => MockClient((request) async {
          if (request.url.toString() == 'https://reference.test/image.png') {
            expect(request.headers['authorization'], isNull);
            return http.Response.bytes(
              base64Decode(_png),
              200,
              headers: {'content-type': 'image/png'},
            );
          }
          expect(request.url.origin, 'https://api.88api.ai');
          expect(request.url.path, '/v1/images/generations');
          expect((jsonDecode(request.body) as Map)['image'], [
            'data:image/png;base64,$_png',
          ]);
          return _json({
            'data': [
              {'b64_json': _png},
            ],
          });
        }),
      );
    },
  );

  for (final type in ['gemini', 'api88', 'token91']) {
    test(
      '$type image reuses Gemini generateContent and saves the result',
      () async {
        await http.runWithClient(
          () async {
            final service = AiImageGenerationService(
              _provider(type).copyWith(baseUrl: ''),
              model: 'gemini-3.1-flash-image',
            );
            final result = type == 'gemini'
                ? await service.generateImage('cover')
                : await service.editImage(
                    'edit',
                    imageData: 'data:image/png;base64,$_png',
                    aspectRatio: '16:9',
                    resolution: '2K',
                  );
            expect(
              await File(result.localFilePath!).readAsBytes(),
              base64Decode(_png),
            );
          },
          () => MockClient((request) async {
            expect(
              request.url.host,
              type == 'gemini'
                  ? 'generativelanguage.googleapis.com'
                  : type == 'token91'
                  ? 'api-no.91token.com'
                  : 'api.88api.ai',
            );
            expect(
              request.url.path,
              endsWith('/v1beta/models/gemini-3.1-flash-image:generateContent'),
            );
            expect(request.url.query, isEmpty);
            final body = jsonDecode(request.body) as Map;
            expect(
              body['generationConfig']['responseModalities'],
              contains('IMAGE'),
            );
            if (type != 'gemini') {
              expect(
                body['contents'][0]['parts'][1]['inlineData']['data'],
                _png,
              );
              expect(body['generationConfig']['imageConfig'], {
                'aspectRatio': '16:9',
                'imageSize': '2K',
              });
            }
            return _json({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {
                        'inlineData': {'mimeType': 'image/png', 'data': _png},
                      },
                    ],
                  },
                },
              ],
            });
          }),
        );
      },
    );
  }

  for (final (mime, format) in [
    ('audio/wav', 'wav'),
    ('audio/mpeg', 'mp3'),
    ('audio/ogg; codecs=opus', 'ogg'),
  ]) {
    test(
      'Gemini narration preserves $mime and its actual output format',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final payload = base64Decode(
          'UklGRigAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQQAAAABAgME',
        );
        final provider = _provider();
        final result = await http.runWithClient(
          () => container.read(productionAudioInvokeProvider)(
            provider,
            AudioRequest(
              providerId: provider.id,
              modelId: 'gemini-3.8-flash-tts',
              prompt: 'hello',
              originalPrompt: 'hello',
            ),
            [],
            Completer<void>().future,
          ),
          () => MockClient((request) async {
            expect(request.headers['x-goog-api-key'], 'test-key');
            expect(
              request.url.path,
              endsWith('/v1beta/models/gemini-3.8-flash-tts:generateContent'),
            );
            final body = jsonDecode(request.body) as Map;
            expect(body['generationConfig'], isNot(contains('responseFormat')));
            return _json({
              'candidates': [
                {
                  'finishReason': 'STOP',
                  'content': {
                    'parts': [
                      {
                        'inlineData': {
                          'mimeType': mime,
                          'data': base64Encode(payload),
                        },
                      },
                    ],
                  },
                },
              ],
            });
          }),
        );
        expect(result.bytes, payload);
        expect(audioOutputFileFormat('wav', mimeType: result.mimeType), format);
      },
    );
  }

  test('other Gemini encodings report their MIME instead of missing audio', () {
    final transport = MockClient((_) async => throw StateError('No network'));
    addTearDown(transport.close);
    final client = GeminiAudioClient(
      transport,
      'key',
      providerType: 'api88',
      endpoint: Uri.parse('https://api.88api.ai'),
    );
    for (final mime in [
      'audio/L16;codec=pcm;rate=24000',
      'audio/alaw',
      'audio/mulaw',
    ]) {
      expect(
        () => client.decodeResult({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'inlineData': {'mimeType': mime, 'data': 'AQIDBA=='},
                  },
                ],
              },
            },
          ],
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'detail',
            contains('Unsupported Gemini audio MIME type'),
          ),
        ),
      );
    }
    expect(
      () => client.decodeResult({
        'candidates': [
          {'finishReason': 'SAFETY'},
        ],
      }),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'finish reason',
          contains('SAFETY'),
        ),
      ),
    );
  });

  test(
    'OpenAI speech uses audio/speech and returns MP3 without JSON decoding',
    () async {
      final transport = MockClient((request) async {
        expect(request.url.path, '/v1/audio/speech');
        final body = jsonDecode(request.body) as Map;
        expect(body, {
          'model': 'tts-1',
          'input': 'hello',
          'voice': 'alloy',
          'response_format': 'mp3',
        });
        return http.Response.bytes(
          [0x49, 0x44, 0x33, 0],
          200,
          headers: {'content-type': 'audio/mpeg'},
        );
      });
      addTearDown(transport.close);
      final result = await NewApiClient(_provider())
          .audio(transport, 'tts-1')
          .generate(
            AudioRequest(
              providerId: 'p',
              modelId: 'tts-1',
              prompt: 'hello',
              originalPrompt: 'hello',
            ),
          );
      expect(result.bytes, [0x49, 0x44, 0x33, 0]);
    },
  );

  test(
    'Gemini HTTP failure preserves upstream diagnostic with no POST retry',
    () async {
      var calls = 0;
      final transport = MockClient((_) async {
        calls++;
        return http.Response(
          '{"error":{"code":429,"message":"quota exceeded"}}',
          429,
        );
      });
      addTearDown(transport.close);
      final client = GeminiAudioClient(
        transport,
        'key',
        providerType: 'api88',
        endpoint: Uri.parse('https://gateway.test'),
      );
      await expectLater(
        client.generate(
          AudioRequest(
            providerId: 'p',
            modelId: 'gemini-3.1-flash-tts',
            prompt: 'hello',
            originalPrompt: 'hello',
          ),
        ),
        throwsA(
          isA<AudioException>().having((e) => e.statusCode, 'status', 429),
        ),
      );
      expect(calls, 1);
    },
  );

  test(
    'Seedance submits metadata content then polls and downloads without leaking credentials',
    () async {
      var posts = 0;
      final transport = MockClient((request) async {
        if (request.url.host == 'cdn.test') {
          expect(request.headers['Authorization'], isNull);
          return http.Response.bytes([1, 2, 3], 200);
        }
        expect(request.headers['Authorization'], 'Bearer test-key');
        if (request.method == 'POST') {
          posts++;
          final body = jsonDecode(request.body) as Map;
          expect(request.url.path, '/v1/videos');
          expect(body['seconds'], '8');
          expect(body['metadata']['generate_audio'], true);
          expect(body['metadata']['content'][1]['role'], 'first_frame');
          return _json({'id': 'task_1', 'status': 'queued'});
        }
        if (request.url.path.endsWith('/content')) {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://cdn.test/video.mp4'},
          );
        }
        return _json({'id': 'task_1', 'status': 'completed'});
      });
      addTearDown(transport.close);
      final client = NewApiClient(_provider()).video(transport);
      final task = await client.submitNative(
        _video('seedance-2.0官方版', mode: VideoMode.first_frame, audio: true),
        [_reference()],
      );
      final result = await client.queryNative(task);
      expect(result.status, VideoRemoteStatus.succeeded);
      expect(
        await (await client.download(
          transport,
          result.videoUrl!,
          task,
        )).stream.toBytes(),
        [1, 2, 3],
      );
      expect(posts, 1);
      await expectLater(
        client.download(
          transport,
          Uri.parse('https://foreign.test/content'),
          task,
        ),
        throwsA(isA<VideoException>()),
      );
    },
  );

  test(
    '91Token Seedance submits and polls through the shared New API route',
    () async {
      final provider = _provider('token91');
      final transport = MockClient((request) async {
        expect(request.url.host, 'api.91token.com');
        expect(request.headers['Authorization'], 'Bearer test-key');
        const path = '/v1/videos';
        if (request.method == 'POST') {
          expect(request.url.path, path);
          final body = jsonDecode(request.body) as Map;
          expect(body['model'], 'doubao-seedance-2-0');
          expect(body['metadata']['content'][1]['role'], 'first_frame');
          expect(body['metadata']['generate_audio'], true);
          return _json({'id': 'task_91', 'status': 'queued'});
        }
        expect(request.url.path, '$path/task_91');
        return _json({'status': 'completed', 'id': 'task_91'});
      });
      addTearDown(transport.close);
      final client = NewApiClient(provider).video(transport);
      final task = await client.submitNative(
        _video('doubao-seedance-2-0', mode: VideoMode.first_frame, audio: true),
        [_reference()],
      );
      final result = await client.queryNative(task);
      expect(result.status, VideoRemoteStatus.succeeded);
      expect(
        result.videoUrl.toString(),
        'https://api.91token.com/v1/videos/task_91/content',
      );
    },
  );

  test('Seedance 2.0 mini alias omits the audio switch 88api rejects', () {
    expect(
      lookupVideoChannelModel('api88', 'seedance-2.0-mini官方版')!.requiresAudio,
      isFalse,
    );
    expect(
      lookupVideoChannelModel('api88', 'seedance-2.0官方版')!.requiresAudio,
      isTrue,
    );
    final transport = MockClient(
      (_) async => throw StateError('must not submit'),
    );
    addTearDown(transport.close);
    final body = NewApiClient(
      _provider(),
    ).video(transport).encode(_video('seedance-2.0-mini官方版'), const []);
    expect(body['metadata'], isNot(contains('generate_audio')));
  });

  test('Seedance 2.5 reference mode preserves the Ark omni task type', () {
    final transport = MockClient(
      (_) async => throw StateError('must not submit'),
    );
    addTearDown(transport.close);
    final body = NewApiClient(_provider()).video(transport).encode(
      _video('seedance-2.5官方版', mode: VideoMode.reference, audio: true),
      [
        VideoReference(
          role: VideoInputRole.reference_image,
          url: 'https://reference.test/image.png',
          mimeType: 'image/png',
          fileSize: 100,
          mediaInfo: const VideoMediaInfo(width: 1280, height: 720),
        ),
      ],
    );
    expect(body['metadata']['omni_reference_task_type'], 'reference');
    expect(body['metadata']['content'][1]['role'], 'reference_image');
  });

  test(
    '88API submits a discovered Seedance alias with its original ID',
    () async {
      const model = 'vendor/seedance-2.5-flash-20261115';
      final transport = MockClient((request) async {
        expect(request.url.toString(), 'https://api.88api.ai/v1/videos');
        final body = jsonDecode(request.body) as Map;
        expect(body['model'], model);
        expect(body['metadata']['generate_audio'], true);
        expect(body['metadata']['content'][1]['role'], 'reference_image');
        expect(body['metadata'], isNot(contains('omni_reference_task_type')));
        return _json({'id': 'task_flash', 'status': 'queued'});
      });
      addTearDown(transport.close);
      final task = await NewApiClient(_provider())
          .video(transport)
          .submitNative(_video(model, mode: VideoMode.reference, audio: true), [
            VideoReference(
              role: VideoInputRole.reference_image,
              url: 'https://reference.test/image.png',
              mimeType: 'image/png',
              fileSize: 100,
              mediaInfo: const VideoMediaInfo(width: 1280, height: 720),
            ),
          ]);
      expect(task.taskId, 'task_flash');
    },
  );

  test(
    'Veo resolves reference URL into inline images before charging submission',
    () async {
      final transport = MockClient((request) async {
        if (request.url.host == 'reference.test') {
          expect(request.headers['Authorization'], isNull);
          return http.Response.bytes(base64Decode(_png), 200);
        }
        final body = jsonDecode(request.body) as Map;
        expect(body['images'], ['data:image/png;base64,$_png']);
        expect(body['metadata'], {'resolution': '720p', 'aspectRatio': '16:9'});
        expect(body['size'], '1280x720');
        return _json({'id': 'task_2', 'status': 'queued'});
      });
      addTearDown(transport.close);
      await NewApiClient(_provider()).video(transport).submitNative(
        _video('veo-3.1', mode: VideoMode.first_frame),
        [_reference()],
      );
    },
  );

  test('video POST uncertainty never retries a billed submission', () async {
    var calls = 0;
    final transport = MockClient((_) async {
      calls++;
      throw const SocketException('disconnected');
    });
    addTearDown(transport.close);
    final client = NewApiVideoClient(
      httpClient: transport,
      providerType: 'api88',
      endpoint: Uri.parse('https://gateway.test/v1'),
      apiKey: 'key',
    );
    await expectLater(
      client.submitNative(_video('veo-3.1'), []),
      throwsA(
        isA<VideoException>().having(
          (e) => e.code,
          'code',
          VideoErrorCode.submission_unknown,
        ),
      ),
    );
    expect(calls, 1);
  });
}

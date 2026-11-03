// 职责: 验证 AtlasCloud 图片模型参数、编辑路由、轮询和失败处理。
// 关联文件:
//   lib/shared/services/ai/image.dart
//   lib/shared/models/image/channels.dart
//   lib/shared/models/production/image_request.dart

import 'dart:convert';
import 'dart:io';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/image/channels.dart';
import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/services/ai/image.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==';
const _image = 'data:image/png;base64,$_png';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  final provider = aiProviderBuiltinById('openai')!.copyWith(
    id: 'atlascloud-test',
    type: 'atlascloud',
    enabled: true,
    apiKey: 'test-key',
    imageModels: imageModelsForProvider('atlascloud'),
  );
  setUp(() async {
    support = await Directory.systemTemp.createTemp('atlascloud-image-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async =>
              {
                'getApplicationSupportDirectory',
                'getTemporaryDirectory',
              }.contains(call.method)
              ? support.path
              : null,
        );
    await RevericPaths.initialize();
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await support.delete(recursive: true);
  });

  test(
    'unknown model preserves its ID for reference edits and sends chosen pixels',
    () async {
      const model = 'custom/image/edit';
      final custom = provider.copyWith(imageModels: [model]);
      final caps = ProductionImageCapabilities(custom, model);
      caps.validate(
        prompt: 'edit',
        ratio: '16:9',
        resolution: '2K',
        references: 2,
      );
      await http.runWithClient(
        () async {
          await AiImageGenerationService(custom, model: model).editImages(
            'edit',
            imageData: [_image, _image],
            size: caps.size('16:9', '2K'),
            aspectRatio: '16:9',
            resolution: '2K',
          );
        },
        () => MockClient((r) async {
          expect(jsonDecode(r.body), {
            'model': model,
            'prompt': 'edit',
            'size': '2048x1152',
            'images': [_image, _image],
          });
          return http.Response(
            jsonEncode({
              'code': 200,
              'data': {
                'id': 'custom-result',
                'status': 'completed',
                'outputs': [_image],
              },
            }),
            200,
          );
        }),
      );
    },
  );

  final samples = [
    (
      'bytedance/seedream-v5.0-pro/text-to-image',
      'bytedance/seedream-v5.0-pro/edit',
      '2K',
      '16:9',
      {'size': '2816*1584', 'output_format': 'png'},
    ),
    (
      'bytedance/seedream-v5.0-lite',
      'bytedance/seedream-v5.0-lite/edit',
      '3K',
      '16:9',
      {'size': '4096*2304', 'output_format': 'png'},
    ),
    (
      'google/nano-banana-2/text-to-image',
      'google/nano-banana-2/edit',
      '2K',
      '16:9',
      {'resolution': '2k', 'aspect_ratio': '16:9', 'output_format': 'png'},
    ),
    (
      'google/nano-banana-pro/text-to-image',
      'google/nano-banana-pro/edit',
      '4K',
      '16:9',
      {'resolution': '4k', 'aspect_ratio': '16:9', 'output_format': 'png'},
    ),
    (
      'openai/gpt-image-2/text-to-image',
      'openai/gpt-image-2/edit',
      '1K',
      '3:2',
      {'size': '1536x1024'},
    ),
    for (final variant in ['sunburst', 'flare'])
      (
        'openai/gpt-image-2.5-$variant/text-to-image',
        'openai/gpt-image-2.5-$variant/edit',
        '4K',
        '16:9',
        {'size': '3840x2160', 'output_format': 'png'},
      ),
  ];
  for (final (model, editModel, resolution, ratio, parameters) in samples) {
    test(
      '$model generation and editing encode channel parameters and save output',
      () async {
        final caps = ProductionImageCapabilities(provider, model);
        final service = AiImageGenerationService(provider, model: model);
        for (final editing in [false, true]) {
          caps.validate(
            prompt: 'scene',
            ratio: ratio,
            resolution: resolution,
            references: editing ? 2 : 0,
          );
          await http.runWithClient(
            () async {
              final result = editing
                  ? await service.editImages(
                      'scene',
                      imageData: ['https://reference.test/a.png', _image],
                      size: caps.size(ratio, resolution),
                      aspectRatio: ratio,
                      resolution: resolution,
                    )
                  : await service.generateImage(
                      'scene',
                      size: caps.size(ratio, resolution),
                      aspectRatio: ratio,
                      resolution: resolution,
                    );
              expect(
                await File(result.localFilePath!).readAsBytes(),
                base64Decode(_png),
              );
            },
            () => MockClient((r) async {
              expect(r.method, 'POST');
              expect(
                r.url.toString(),
                'https://api.atlascloud.ai/api/v1/model/generateImage',
              );
              expect(r.headers['Authorization'], 'Bearer test-key');
              expect(jsonDecode(r.body), {
                'model': editing ? editModel : model,
                'prompt': 'scene',
                ...parameters,
                if (editing) 'images': ['https://reference.test/a.png', _image],
              });
              return http.Response(
                jsonEncode({
                  'code': 200,
                  'data': {
                    'id': 'prediction-1',
                    'status': 'completed',
                    'outputs': [_image],
                  },
                }),
                200,
              );
            }),
          );
        }
      },
    );
  }

  test(
    'polls the original prediction without resubmitting or following server URLs',
    () async {
      var posts = 0;
      var gets = 0;
      await http.runWithClient(
        () async {
          final result = await AiImageGenerationService(
            provider,
            model: samples.first.$1,
          ).generateImage('scene');
          expect(result.hasImage, true);
        },
        () => MockClient((r) async {
          if (r.method == 'POST') {
            posts++;
            return http.Response(
              jsonEncode({
                'code': 200,
                'data': {
                  'id': 'original',
                  'status': 'processing',
                  'urls': {'get': 'https://foreign.test/task'},
                },
              }),
              200,
            );
          }
          gets++;
          expect(
            r.url.toString(),
            'https://api.atlascloud.ai/api/v1/model/prediction/original',
          );
          expect(r.headers['Authorization'], 'Bearer test-key');
          return http.Response(
            jsonEncode({
              'data': {
                'id': 'original',
                'status': 'completed',
                'outputs': [_image],
              },
            }),
            200,
          );
        }),
      );
      expect(posts, 1);
      expect(gets, 1);
    },
  );

  test(
    'retries interrupted TLS handshakes for submission and polling',
    () async {
      var posts = 0;
      var gets = 0;
      await http.runWithClient(
        () async {
          final result = await AiImageGenerationService(
            provider,
            model: samples.first.$1,
          ).generateImage('scene');
          expect(result.hasImage, true);
        },
        () => MockClient((r) async {
          if (r.method == 'POST') {
            if (++posts == 1) {
              throw const HandshakeException('terminated');
            }
            return http.Response(
              jsonEncode({
                'data': {'id': 'original', 'status': 'processing'},
              }),
              200,
            );
          }
          if (++gets == 1) {
            throw const HandshakeException('terminated');
          }
          return http.Response(
            jsonEncode({
              'data': {
                'id': 'original',
                'status': 'completed',
                'outputs': [_image],
              },
            }),
            200,
          );
        }),
      );
      expect(posts, 2);
      expect(gets, 2);
    },
  );

  test(
    'connection failures after retries surface the underlying error',
    () async {
      var posts = 0;
      await http.runWithClient(
        () async {
          await expectLater(
            AiImageGenerationService(
              provider,
              model: samples.first.$1,
            ).generateImage('scene'),
            throwsA(
              isA<AiImageGenerationException>()
                  .having((e) => e is AiImageFetchException, 'fetch', false)
                  .having(
                    (e) => e.debugMessage,
                    'debug',
                    contains('HandshakeException'),
                  ),
            ),
          );
        },
        () => MockClient((r) async {
          posts++;
          throw const HandshakeException('terminated');
        }),
      );
      expect(posts, 3);
    },
  );

  test('reports the prediction ID before polling starts', () async {
    final events = <String>[];
    await http.runWithClient(
      () async {
        final result =
            await AiImageGenerationService(
              provider,
              model: samples.first.$1,
            ).generateImage(
              'scene',
              onSubmitted: (id) async => events.add('submitted:$id'),
            );
        expect(result.hasImage, true);
      },
      () => MockClient((r) async {
        events.add(r.method);
        return http.Response(
          jsonEncode({
            'data': {
              'id': 'original',
              'status': r.method == 'POST' ? 'processing' : 'completed',
              'outputs': [_image],
            },
          }),
          200,
        );
      }),
    );
    expect(events, ['POST', 'submitted:original', 'GET']);
  });

  test(
    'poll failures after submission carry the prediction ID and resume polls it',
    () async {
      var posts = 0;
      var gets = 0;
      await http.runWithClient(
        () async {
          final service = AiImageGenerationService(
            provider,
            model: samples.first.$1,
          );
          await expectLater(
            service.generateImage('scene'),
            throwsA(
              isA<AiImageFetchException>()
                  .having((e) => e.providerTaskId, 'task', 'original')
                  .having((e) => e.url, 'url', isNull),
            ),
          );
          final result = await service.resumeResult('original');
          expect(result.hasImage, true);
        },
        () => MockClient((r) async {
          if (r.method == 'POST') {
            posts++;
            return http.Response(
              jsonEncode({
                'data': {'id': 'original', 'status': 'processing'},
              }),
              200,
            );
          }
          expect(
            r.url.toString(),
            'https://api.atlascloud.ai/api/v1/model/prediction/original',
          );
          if (++gets <= 3) {
            throw const HandshakeException('terminated');
          }
          return http.Response(
            jsonEncode({
              'data': {
                'id': 'original',
                'status': 'completed',
                'outputs': [_image],
              },
            }),
            200,
          );
        }),
      );
      expect(posts, 1);
      expect(gets, 4);
    },
  );

  // 供应商返回的可读错误未命中本地化文案时原样展示；其余失败用本地化说明。
  for (final (payload, providerMessage) in <(Map<String, Object>, String?)>[
    (
      {'code': 400, 'message': 'upstream quota exhausted'},
      'upstream quota exhausted',
    ),
    (
      {
        'data': {
          'id': 'task',
          'status': 'failed',
          'error': 'upstream quota exhausted',
        },
      },
      'upstream quota exhausted',
    ),
    (
      {
        'data': {'status': 'processing'},
      },
      null,
    ),
    (
      {
        'data': {'id': 'task', 'status': 'completed', 'outputs': []},
      },
      null,
    ),
    (
      {
        'data': {'id': 'task', 'status': 'unknown'},
      },
      null,
    ),
  ]) {
    test(
      'invalid prediction $payload fails without further network requests',
      () async {
        var requests = 0;
        await http.runWithClient(
          () async {
            await expectLater(
              AiImageGenerationService(
                provider,
                model: samples.first.$1,
              ).generateImage('scene'),
              throwsA(
                isA<AiImageGenerationException>().having(
                  (e) => e.userMessage,
                  'user message',
                  providerMessage ?? isNot(contains('upstream')),
                ),
              ),
            );
          },
          () => MockClient((r) async {
            requests++;
            return http.Response(jsonEncode(payload), 200);
          }),
        );
        expect(requests, 1);
      },
    );
  }

  test(
    'rejects unsupported models, reference counts and channel sizes before submission',
    () async {
      await http.runWithClient(() async {
        final service = AiImageGenerationService(
          provider,
          model: samples.first.$1,
        );
        for (final action in <Future<AiImageGenerationResult> Function()>[
          () => service.generateImage('scene', model: 'unknown'),
          () => service.editImages('scene', imageData: List.filled(11, _image)),
          () => service.generateImage('scene', size: '4096x4096'),
          () => service.generateImage(
            'scene',
            model: samples[2].$1,
            aspectRatio: 'auto',
          ),
        ]) {
          await expectLater(
            action(),
            throwsA(isA<AiImageGenerationException>()),
          );
        }
      }, () => MockClient((_) => throw StateError('must not submit')));
    },
  );
}

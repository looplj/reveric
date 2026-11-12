// 职责: 验证 Qwen、Seedream 和 OpenRouter 的图像请求协议、参考图和结果落盘。
// 关联文件:
//   lib/shared/services/ai/image.dart
//   lib/shared/models/image/channels.dart
//   lib/shared/providers/production_images.dart

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/image/channels.dart';
import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/production_images.dart';
import 'package:reveric/shared/services/ai/image.dart';
import 'package:reveric/shared/services/ai/image/client.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==';
const _image = 'data:image/png;base64,$_png';
const _references = ['https://reference.example/first.png', _image];

AiProvider _provider(String type) => aiProviderBuiltinById('openai')!.copyWith(
  type: type,
  enabled: true,
  apiKey: 'test-key',
  baseUrl: 'https://proxy.example/prefix/compatible-mode/v1/',
  imageModels: imageModelsForProvider(type),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  setUp(() async {
    support = await Directory.systemTemp.createTemp('reveric_image_channels_');
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

  for (final type in ['qwen', 'qwen_token_plan']) {
    for (final model in imageChannelModels[ImageProtocol.qwen_image]!.keys) {
      test(
        '$type $model uses its documented synchronous endpoint for generation and editing',
        () async {
          final service = AiImageGenerationService(
            _provider(type),
            model: model,
          );
          final modern =
              type == 'qwen' &&
              model.startsWith('qwen-') &&
              !model.contains('2.0');
          final root = type == 'qwen_token_plan'
              ? 'https://token-plan.maas.qianwenaiapi.com'
              : 'https://proxy.example/prefix';
          var count = 0;
          await http.runWithClient(
            () async {
              for (final editing in [false, true]) {
                final result = editing
                    ? await service.editImages(
                        'combine',
                        imageData: _references,
                        size: '2688x1536',
                      )
                    : await service.generateImage('combine', size: '2688x1536');
                expect(
                  File(result.localFilePath!).readAsBytesSync(),
                  base64Decode(_png),
                );
                expect(result.mimeSubtype, 'png');
              }
            },
            () => MockClient((request) async {
              final editing = count++ == 1;
              expect(request.method, 'POST');
              expect(request.headers['Authorization'], 'Bearer test-key');
              expect(
                request.url.toString(),
                modern
                    ? '$root/compatible-mode/v1/images/generations'
                    : '$root/api/v1/services/aigc/multimodal-generation/generation',
              );
              final body = jsonDecode(request.body) as Map;
              expect(body['model'], model);
              if (modern) {
                expect(body, {
                  'model': model,
                  'prompt': 'combine',
                  'n': 1,
                  'size': '2688x1536',
                  'watermark': false,
                  'prompt_extend': true,
                  if (editing) 'image': _references,
                });
              } else {
                expect(body['parameters'], {
                  'n': 1,
                  'size': '2688*1536',
                  'watermark': false,
                  if (model.startsWith('qwen-')) 'prompt_extend': true,
                });
                expect(body['input']['messages'][0]['content'], [
                  if (editing) ..._references.map((image) => {'image': image}),
                  {'text': 'combine'},
                ]);
              }
              return http.Response(
                jsonEncode(
                  modern
                      ? {
                          'data': [
                            {'url': _image},
                          ],
                        }
                      : {
                          'output': {
                            'choices': [
                              {
                                'message': {
                                  'content': [
                                    {'image': _image},
                                  ],
                                },
                              },
                            ],
                          },
                        },
                ),
                200,
              );
            }),
          );
          expect(count, 2);
        },
      );
    }
  }

  test(
    'Seedream model override controls defaults and sends every reference',
    () async {
      final service = AiImageGenerationService(
        _provider('doubao'),
        model: 'doubao-seedream-4-0-250828',
      );
      var count = 0;
      await http.runWithClient(
        () async {
          for (final model in imageModelsForProvider('doubao')) {
            final result = await service.editImages(
              'combine',
              model: model,
              imageData: _references,
            );
            expect(
              File(result.localFilePath!).readAsBytesSync(),
              base64Decode(_png),
            );
          }
        },
        () => MockClient((request) async {
          count++;
          final body = jsonDecode(request.body) as Map;
          final model = body['model'] as String;
          final modern =
              model.contains('-pro-') ||
              model.contains('-flash-') ||
              model.contains('-5-5-');
          expect(
            request.url.path,
            '/prefix/compatible-mode/v1/images/generations',
          );
          expect(body['image'], _references);
          expect(body['size'], '2048x2048');
          expect(body['response_format'], 'b64_json');
          expect(body['watermark'], false);
          expect(
            body['output_format'],
            model.contains('-5-0') || model.contains('-5-5-') ? 'png' : null,
          );
          expect(body.containsKey('sequential_image_generation'), !modern);
          expect(body['optimize_prompt_options'], {
            'mode': model.contains('-4-0') ? 'fast' : 'standard',
          });
          return http.Response(
            jsonEncode({
              'data': [
                {'b64_json': _png},
              ],
            }),
            200,
          );
        }),
      );
      expect(count, imageModelsForProvider('doubao').length);
    },
  );

  test(
    'production passes OpenRouter ratio and resolution without fabricated pixels',
    () async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer.test(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      final request = ProductionImageRequest(
        providerId: 'openrouter',
        modelId: 'qwen/qwen-image-3',
        originalPrompt: 'cover',
        prompt: 'cover',
        ratio: '16:9',
        resolution: '2K',
        size: null,
      );
      await http.runWithClient(
        () async {
          final result = await container.read(productionImageInvokeProvider)(
            _provider('openrouter'),
            request,
            (_) async {},
            (_) async {},
          );
          expect(
            File(result.localFilePath!).readAsBytesSync(),
            base64Decode(_png),
          );
        },
        () => MockClient((r) async {
          expect(r.url.toString(), 'https://openrouter.ai/api/v1/images');
          expect(jsonDecode(r.body), {
            'model': 'qwen/qwen-image-3',
            'prompt': 'cover',
            'n': 1,
            'aspect_ratio': '16:9',
            'resolution': '2K',
          });
          return http.Response(
            jsonEncode({
              'data': [
                {'b64_json': _png},
              ],
            }),
            200,
          );
        }),
      );
    },
  );

  test(
    'Wan generates at 4K but rejects editing above 2K before submission',
    () async {
      final service = AiImageGenerationService(
        _provider('qwen'),
        model: 'wan2.7-image-pro',
      );
      var requests = 0;
      await http.runWithClient(
        () async {
          await service.generateImage('landscape', size: '4K');
          for (final size in ['4K', '4096x2304']) {
            await expectLater(
              service.editImages('edit', imageData: _references, size: size),
              throwsA(
                isA<AiImageGenerationException>().having(
                  (error) => error.code,
                  'code',
                  AiImageErrorCode.size,
                ),
              ),
            );
          }
          await expectLater(
            service.editImages('edit', imageData: List.filled(10, _image)),
            throwsA(
              isA<AiImageGenerationException>().having(
                (error) => error.code,
                'code',
                AiImageErrorCode.param,
              ),
            ),
          );
        },
        () => MockClient((request) async {
          requests++;
          final body = jsonDecode(request.body) as Map;
          expect(
            request.url.path,
            '/prefix/api/v1/services/aigc/multimodal-generation/generation',
          );
          expect(body['parameters'], {
            'n': 1,
            'size': '4096*4096',
            'watermark': false,
          });
          return http.Response(
            jsonEncode({
              'output': {
                'choices': [
                  {
                    'message': {
                      'content': [
                        {'image': _image},
                      ],
                    },
                  },
                ],
              },
            }),
            200,
          );
        }),
      );
      expect(requests, 1);
    },
  );

  for (final model in ['qwen/qwen-image-2.1-turbo', 'krea/k3-edit']) {
    test('$model submits reference images with ratio and resolution', () async {
      final service = AiImageGenerationService(
        _provider('openrouter'),
        model: model,
      );
      var calls = 0;
      await http.runWithClient(
        () async {
          if (model == 'krea/k3-edit') {
            await expectLater(
              service.generateImage('edit'),
              throwsA(isA<AiImageGenerationException>()),
            );
          }
          final result = await service.editImages(
            'edit',
            imageData: _references,
            aspectRatio: '16:9',
            resolution: '2K',
          );
          expect(
            File(result.localFilePath!).readAsBytesSync(),
            base64Decode(_png),
          );
        },
        () => MockClient((r) async {
          calls++;
          expect(r.url.toString(), 'https://openrouter.ai/api/v1/images');
          expect(jsonDecode(r.body), {
            'model': model,
            'prompt': 'edit',
            'n': 1,
            'aspect_ratio': '16:9',
            'resolution': '2K',
            'input_references': [
              for (final image in _references)
                {
                  'type': 'image_url',
                  'image_url': {'url': image},
                },
            ],
          });
          return http.Response(
            jsonEncode({
              'data': [
                {'b64_json': _png},
              ],
            }),
            200,
          );
        }),
      );
      expect(calls, 1);
    });
  }

  test(
    'unknown configured image model validates and generates with automatic defaults',
    () async {
      const model = 'vendor/future-image';
      final provider = _provider('openrouter').copyWith(imageModels: [model]);
      final caps = ProductionImageCapabilities(provider, model);
      caps.validate(
        prompt: 'cover',
        ratio: 'auto',
        resolution: 'auto',
        references: 0,
      );
      expect(caps.verifiedCapabilities, isNull);
      caps.validate(
        prompt: 'cover',
        ratio: '16:9',
        resolution: '2K',
        references: 32,
      );
      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer.test(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      await http.runWithClient(
        () async {
          final result = await container.read(productionImageInvokeProvider)(
            provider,
            ProductionImageRequest(
              providerId: provider.id,
              modelId: model,
              originalPrompt: 'cover',
              prompt: 'cover',
              ratio: 'auto',
              resolution: 'auto',
              size: caps.size('auto', 'auto'),
            ),
            (_) async {},
            (_) async {},
          );
          expect(
            File(result.localFilePath!).readAsBytesSync(),
            base64Decode(_png),
          );
        },
        () => MockClient((r) async {
          expect(jsonDecode(r.body), {
            'model': model,
            'prompt': 'cover',
            'n': 1,
          });
          return http.Response(
            jsonEncode({
              'data': [
                {'b64_json': _png},
              ],
            }),
            200,
          );
        }),
      );
    },
  );

  test(
    'registered Gemini direct models send image config and references',
    () async {
      const model = 'gemini-3-pro-image';
      final provider = _provider('gemini').copyWith(imageModels: [model]);
      final caps = ProductionImageCapabilities(provider, model);
      expect(caps.verifiedCapabilities, isNotNull);
      caps.validate(
        prompt: 'edit',
        ratio: '16:9',
        resolution: '2K',
        references: 2,
      );
      await http.runWithClient(
        () => AiImageGenerationService(provider, model: model).editImages(
          'edit',
          imageData: [_image, _image],
          aspectRatio: '16:9',
          resolution: '2K',
        ),
        () => MockClient((r) async {
          final body = jsonDecode(r.body) as Map;
          expect(body['generationConfig']['imageConfig'], {
            'aspectRatio': '16:9',
            'imageSize': '2K',
          });
          expect(body['contents'][0]['parts'], hasLength(3));
          return http.Response(
            jsonEncode({
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
            }),
            200,
          );
        }),
      );
    },
  );

  for (final type in ['openrouter', 'gemini', 'qwen', 'api88']) {
    test(
      'unknown $type model sends selected specifications and references',
      () async {
        const model = 'future-image';
        final provider = _provider(type).copyWith(imageModels: [model]);
        final caps = ProductionImageCapabilities(provider, model);
        caps.validate(
          prompt: 'edit',
          ratio: '16:9',
          resolution: '2K',
          references: 2,
        );
        final service = AiImageGenerationService(provider, model: model);
        var calls = 0;
        await http.runWithClient(
          () async {
            final result = await service.editImages(
              'edit',
              imageData: [_image, _image],
              aspectRatio: '16:9',
              resolution: '2K',
              size: caps.size('16:9', '2K'),
            );
            expect(
              File(result.localFilePath!).readAsBytesSync(),
              base64Decode(_png),
            );
          },
          () => MockClient((r) async {
            calls++;
            if (type == 'api88') {
              expect(r.url.path, endsWith('/images/edits'));
              expect(
                r.headers['content-type'],
                startsWith('multipart/form-data'),
              );
              final body = latin1.decode(r.bodyBytes);
              expect(body, contains('2048x1152'));
              expect(RegExp(r'name="image\[\]"').allMatches(body).length, 2);
            } else {
              final body = jsonDecode(r.body) as Map;
              switch (type) {
                case 'openrouter':
                  expect(body, {
                    'model': model,
                    'prompt': 'edit',
                    'n': 1,
                    'aspect_ratio': '16:9',
                    'resolution': '2K',
                    'input_references': [
                      for (var i = 0; i < 2; i++)
                        {
                          'type': 'image_url',
                          'image_url': {'url': _image},
                        },
                    ],
                  });
                case 'gemini':
                  expect(body['generationConfig']['imageConfig'], {
                    'aspectRatio': '16:9',
                    'imageSize': '2K',
                  });
                  expect(body['contents'][0]['parts'], [
                    {'text': 'edit'},
                    for (var i = 0; i < 2; i++)
                      {
                        'inlineData': {'mimeType': 'image/png', 'data': _png},
                      },
                  ]);
                case 'qwen':
                  expect(body['parameters']['size'], '2048*1152');
                  expect(body['input']['messages'][0]['content'], [
                    {'image': _image},
                    {'image': _image},
                    {'text': 'edit'},
                  ]);
              }
            }
            return http.Response(
              jsonEncode(
                type == 'gemini'
                    ? {
                        'candidates': [
                          {
                            'content': {
                              'parts': [
                                {
                                  'inlineData': {
                                    'mimeType': 'image/png',
                                    'data': _png,
                                  },
                                },
                              ],
                            },
                          },
                        ],
                      }
                    : type == 'qwen'
                    ? {
                        'output': {
                          'choices': [
                            {
                              'message': {
                                'content': [
                                  {'image': _image},
                                ],
                              },
                            },
                          ],
                        },
                      }
                    : {
                        'data': [
                          {'b64_json': _png},
                        ],
                      },
              ),
              200,
            );
          }),
        );
        expect(calls, 1);
      },
    );
  }

  test('OpenRouter honors JPEG-only output and reference order', () async {
    final service = AiImageGenerationService(
      _provider('openrouter'),
      model: 'sourceful/riverflow-v2.5-fast',
    );
    await http.runWithClient(
      () => service.editImages('combine', imageData: _references),
      () => MockClient((r) async {
        expect(jsonDecode(r.body), {
          'model': 'sourceful/riverflow-v2.5-fast',
          'prompt': 'combine',
          'n': 1,
          'output_format': 'jpeg',
          'input_references': [
            for (final image in _references)
              {
                'type': 'image_url',
                'image_url': {'url': image},
              },
          ],
        });
        return http.Response(
          jsonEncode({
            'data': [
              {'b64_json': _png},
            ],
          }),
          200,
        );
      }),
    );
  });

  test(
    'Qwen tier requests resolve to pixels in the selected protocol',
    () async {
      final service = AiImageGenerationService(
        _provider('qwen'),
        model: 'qwen-image-2.0-pro',
      );
      await http.runWithClient(
        () => service.generateImage('cover', size: '1K'),
        () => MockClient((r) async {
          final body = jsonDecode(r.body) as Map;
          expect(body['parameters']['size'], '1024*1024');
          return http.Response(
            jsonEncode({
              'output': {
                'choices': [
                  {
                    'message': {
                      'content': [
                        {'image': _image},
                      ],
                    },
                  },
                ],
              },
            }),
            200,
          );
        }),
      );
    },
  );

  test('invalid dimensions and reference counts never submit', () async {
    await http.runWithClient(
      () async {
        final qwen = AiImageGenerationService(
          _provider('qwen'),
          model: 'qwen-image-3.0',
        );
        final seed = AiImageGenerationService(
          _provider('doubao'),
          model: 'doubao-seedream-5-0-260128',
        );
        for (final operation in [
          () => qwen.generateImage('cover', size: '4096x4096'),
          () => qwen.generateImage('cover', size: '4096x256'),
          () => qwen.editImages('cover', imageData: List.filled(4, _image)),
          () => seed.generateImage('cover', size: '1024x1024'),
          () => seed.generateImage('cover', size: '4K'),
        ]) {
          await expectLater(
            operation(),
            throwsA(isA<AiImageGenerationException>()),
          );
        }
      },
      () => MockClient(
        (_) => throw StateError('invalid request reached network'),
      ),
    );
  });

  for (final status in [400, 200]) {
    test(
      'Seedream HTTP $status preserves structured image rejection',
      () async {
        final service = AiImageGenerationService(
          _provider('doubao'),
          model: 'doubao-seedream-5-0-pro-260628',
        );
        final error = {
          'code': 'InputImageSensitiveContentDetected.PrivacyInformation',
          'message': 'private provider detail',
        };
        await http.runWithClient(
          () async {
            await expectLater(
              service.generateImage('cover'),
              throwsA(
                isA<AiImageGenerationException>().having(
                  (e) => e.userMessage,
                  'original provider message',
                  'private provider detail',
                ),
              ),
            );
          },
          () => MockClient(
            (_) async => http.Response(
              jsonEncode(
                status == 200
                    ? {
                        'data': [
                          {'error': error},
                        ],
                      }
                    : {'error': error},
              ),
              status,
            ),
          ),
        );
      },
    );
  }

  test('generic provider code yields to the specific image message hint', () async {
    final service = AiImageGenerationService(
      _provider('doubao'),
      model: 'doubao-seedream-5-0-pro-260628',
    );
    await http.runWithClient(
      () async {
        await expectLater(
          service.generateImage('cover'),
          throwsA(
            isA<AiImageGenerationException>().having(
              (e) => e.userMessage,
              'userMessage',
              'The parameter `size` specified in the request is not valid: image size must be at least 3686400 pixels',
            ),
          ),
        );
      },
      () => MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {
              'code': 'InvalidParameter',
              'message':
                  'The parameter `size` specified in the request is not valid: image size must be at least 3686400 pixels',
            },
          }),
          400,
        ),
      ),
    );
  });

  test('provider credit exhaustion shows the payment hint', () {
    expect(
      () => throwForImageHttpFailure(
        uri: Uri.parse('https://api.example/v1/images/generations'),
        statusCode: 402,
        data: jsonEncode({
          'error': {
            'code': 'credit.insufficient',
            'message': 'insufficient credit',
          },
        }),
        providerId: 'custom',
      ),
      throwsA(
        isA<AiImageGenerationException>().having(
          (e) => e.userMessage,
          'userMessage',
          'insufficient credit',
        ),
      ),
    );
  });

  test('provider HTTP failures and per-image errors remain failures', () async {
    final service = AiImageGenerationService(
      _provider('doubao'),
      model: 'doubao-seedream-5-0-pro-260628',
    );
    for (final status in [401, 429, 200]) {
      await http.runWithClient(
        () async {
          await expectLater(
            service.generateImage('cover'),
            throwsA(
              isA<AiImageGenerationException>().having(
                (e) => e.code,
                'code',
                status == 401
                    ? AiImageErrorCode.auth
                    : AiImageErrorCode.rate_limit,
              ),
            ),
          );
        },
        () => MockClient(
          (_) async => http.Response(
            jsonEncode(
              status == 200
                  ? {
                      'data': [
                        {
                          'error': {'message': 'rate limit exceeded'},
                        },
                      ],
                    }
                  : {
                      'error': {'message': 'provider error'},
                    },
            ),
            status,
          ),
        ),
      );
    }
  });

  test('MiniMax H3 sends ratio and area, or an exclusive pixel size', () async {
    final provider = _provider(
      'minimax',
    ).copyWith(baseUrl: 'https://api.minimax.cn');
    final service = AiImageGenerationService(
      provider,
      model: 'MiniMax-H3-Image',
    );
    var editing = false;
    await http.runWithClient(
      () async {
        final generated = await service.generateImage(
          'cover',
          aspectRatio: '16:9',
          resolution: '2K',
        );
        expect(
          File(generated.localFilePath!).readAsBytesSync(),
          base64Decode(_png),
        );
        editing = true;
        final edited = await service.editImages(
          'cover',
          imageData: _references,
          size: '2720x1536',
          aspectRatio: '16:9',
          resolution: '2K',
        );
        expect(
          File(edited.localFilePath!).readAsBytesSync(),
          base64Decode(_png),
        );
      },
      () => MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.headers['Authorization'], 'Bearer test-key');
        expect(
          request.url.toString(),
          editing
              ? 'https://api.minimax.cn/v1/images/edits'
              : 'https://api.minimax.cn/v1/images/generations',
        );
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], 'MiniMax-H3-Image');
        expect(body['response_format'], 'b64_json');
        expect(body['output_format'], 'png');
        if (editing) {
          expect(body['size'], '2720x1536');
          expect(body.containsKey('aspect_ratio'), isFalse);
          expect(body.containsKey('area'), isFalse);
          expect(body['images'], _references);
        } else {
          expect(body['aspect_ratio'], '16:9');
          expect(body['area'], '2K');
          expect(body.containsKey('size'), isFalse);
        }
        return http.Response(
          jsonEncode({
            'data': [
              {'b64_json': _png},
            ],
          }),
          200,
        );
      }),
    );
  });
}

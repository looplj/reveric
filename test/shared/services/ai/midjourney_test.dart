// 职责: 验证 MJ 三种渠道协议、四候选结果与受理后查询失败的重试边界。
// 关联文件:
//   lib/shared/services/ai/image/midjourney.dart
//   lib/shared/services/ai/image.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/image/channels.dart';
import 'package:reveric/shared/services/ai/image.dart';
import 'package:reveric/shared/services/ai/image/client.dart';
import 'package:reveric/shared/services/ai/image/midjourney.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late List<String> urls;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('midjourney-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await RevericPaths.initialize();
    urls = [
      for (var i = 0; i < 4; i++)
        'data:image/png;base64,${base64Encode(img.encodePng(img.Image(width: 2, height: 2)..setPixelRgb(0, 0, i * 60, 0, 0)))}',
    ];
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await root.delete(recursive: true);
  });
  AiProvider provider(String type) => aiProviderBuiltinById('openai')!.copyWith(
    id: 'mj',
    type: type,
    enabled: true,
    apiKey: 'test',
    baseUrl: 'https://gateway.example/v1',
  );

  test(
    '88api sends only model and prompt and retains all four candidates',
    () async {
      var receipts = 0;
      var calls = 0;
      await http.runWithClient(
        () async {
          final result =
              await AiImageGenerationService(
                provider('api88'),
                model: 'midjourney-v8.2-fast',
              ).generateImage(
                'city --ar 1:1 --s 250',
                aspectRatio: '16:9',
                onOutputs: (output) async {
                  expect(output, urls);
                  receipts++;
                },
              );
          expect(result.images, hasLength(4));
          for (var i = 0; i < 4; i++) {
            expect(
              await File(result.images[i].localFilePath!).readAsBytes(),
              UriData.parse(urls[i]).contentAsBytes(),
            );
          }
          await result.disposeTemporary();
        },
        () => MockClient((r) async {
          calls++;
          expect(r.url.path, '/v1/images/generations');
          expect(jsonDecode(r.body), {
            'model': 'midjourney-v8.2-fast',
            'prompt': 'city --s 250 --ar 16:9',
          });
          return http.Response(
            jsonEncode({
              'data': [
                for (final url in urls) {'url': url},
              ],
            }),
            200,
          );
        }),
      );
      expect(calls, 1);
      expect(receipts, 1);
    },
  );

  test(
    '88api base64 candidates without url are saved in response order',
    () async {
      await http.runWithClient(
        () async {
          final result = await AiImageGenerationService(
            provider('api88'),
            model: 'midjourney-v8.2',
          ).generateImage('city');
          expect(result.images, hasLength(4));
          for (var i = 0; i < 4; i++) {
            expect(
              await File(result.images[i].localFilePath!).readAsBytes(),
              UriData.parse(urls[i]).contentAsBytes(),
            );
          }
          await result.disposeTemporary();
        },
        () => MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': [
                for (final url in urls)
                  {'b64_json': url.split(',').last, 'url': null},
              ],
            }),
            200,
          ),
        ),
      );
    },
  );

  test(
    'mixed URL and base64 candidates preserve all four images in order',
    () async {
      await http.runWithClient(
        () async {
          final result = await AiImageGenerationService(
            provider('api88'),
            model: 'midjourney-v8.2',
          ).generateImage('city');
          expect(result.images, hasLength(4));
          for (var i = 0; i < 4; i++) {
            expect(
              await File(result.images[i].localFilePath!).readAsBytes(),
              UriData.parse(urls[i]).contentAsBytes(),
            );
          }
          await result.disposeTemporary();
        },
        () => MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': [
                for (var i = 0; i < 4; i++)
                  if (i.isEven)
                    {'url': urls[i]}
                  else
                    {'b64_json': urls[i].split(',').last},
              ],
            }),
            200,
          ),
        ),
      );
    },
  );

  test(
    'per-item provider error is reported instead of a null URL cast',
    () async {
      await http.runWithClient(
        () async {
          await expectLater(
            AiImageGenerationService(
              provider('api88'),
              model: 'midjourney-v8.2',
            ).generateImage('city'),
            throwsA(
              isA<AiImageGenerationException>().having(
                (error) => error.debugMessage,
                'provider diagnostic',
                contains('candidate rejected'),
              ),
            ),
          );
        },
        () => MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': [
                {
                  'error': {
                    'message': 'candidate rejected',
                    'code': 'invalid_request_error',
                  },
                },
              ],
            }),
            200,
          ),
        ),
      );
    },
  );

  test(
    'malformed candidate reports the invalid index instead of a cast error',
    () async {
      await http.runWithClient(
        () async {
          await expectLater(
            AiImageGenerationService(
              provider('api88'),
              model: 'midjourney-v8.2',
            ).generateImage('city'),
            throwsA(
              isA<AiImageGenerationException>().having(
                (error) => error.debugMessage,
                'response shape',
                allOf(contains('data[2]')),
              ),
            ),
          );
        },
        () => MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': [
                {'url': urls[0]},
                {'url': urls[1]},
                {'unexpected': 'secret-payload'},
                {'url': urls[3]},
              ],
            }),
            200,
          ),
        ),
      );
    },
  );

  test(
    'Atlas uses separate JSON parameters and persists ID before polling',
    () async {
      var submitted = false;
      await http.runWithClient(
        () async {
          final result =
              await AiImageGenerationService(
                provider('atlascloud'),
                model: 'youchuan/v8.2/text-to-image',
              ).generateImage(
                'city --s 250 --c 20 --q 4',
                aspectRatio: '16:9',
                resolution: '2K',
                onSubmitted: (id) async {
                  expect(id, 'prediction');
                  submitted = true;
                },
              );
          expect(result.images, hasLength(4));
          await result.disposeTemporary();
        },
        () => MockClient((r) async {
          if (r.method == 'POST') {
            expect(r.url.path, '/api/v1/model/generateImage');
            expect(jsonDecode(r.body), {
              'model': 'youchuan/v8.2/text-to-image',
              'prompt': 'city',
              'stylize': 250,
              'chaos': 20,
              'quality': 4,
              'aspect_ratio': '16:9',
              'hd': true,
            });
            return http.Response(
              jsonEncode({
                'code': 200,
                'data': {'id': 'prediction', 'status': 'processing'},
              }),
              200,
            );
          }
          expect(submitted, isTrue);
          expect(r.url.path, '/api/v1/model/prediction/prediction');
          return http.Response(
            jsonEncode({
              'data': {
                'id': 'prediction',
                'status': 'completed',
                'outputs': urls,
              },
            }),
            200,
          );
        }),
      );
    },
  );

  test(
    'native proxy splits imagine grid in reading order without upscale requests',
    () async {
      final grid = img.Image(width: 4, height: 4);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          grid.setPixelRgb(x, y, (y ~/ 2 * 2 + x ~/ 2) * 60, 0, 0);
        }
      }
      var posts = 0;
      await http.runWithClient(
        () async {
          final result = await AiImageGenerationService(
            provider('api88'),
            model: 'mj_imagine',
          ).generateImage('city');
          expect(result.images, hasLength(4));
          for (var i = 0; i < 4; i++) {
            final decoded = img.decodePng(
              await File(result.images[i].localFilePath!).readAsBytes(),
            )!;
            expect(decoded.width, 2);
            expect(decoded.getPixel(0, 0).r, i * 60);
          }
          await result.disposeTemporary();
        },
        () => MockClient((r) async {
          if (r.method == 'POST') {
            posts++;
            expect(r.url.path, '/mj/submit/imagine');
            expect(jsonDecode(r.body), {
              'botType': 'MID_JOURNEY',
              'prompt': 'city',
            });
            return http.Response('{"code":22,"result":"job"}', 200);
          }
          expect(r.url.path, '/mj/task/job/fetch');
          return http.Response(
            jsonEncode({
              'status': 'SUCCESS',
              'imageUrl':
                  'data:image/png;base64,${base64Encode(img.encodePng(grid))}',
            }),
            200,
          );
        }),
      );
      expect(posts, 1);
    },
  );

  test('accepted task query failure retains ID and never resubmits', () async {
    var posts = 0;
    await http.runWithClient(
      () async {
        await expectLater(
          AiImageGenerationService(
            provider('api88'),
            model: 'mj_imagine',
          ).generateImage('city'),
          throwsA(
            isA<AiImageFetchException>().having(
              (e) => e.providerTaskId,
              'task ID',
              'job',
            ),
          ),
        );
      },
      () => MockClient((r) async {
        if (r.method == 'POST') {
          posts++;
          return http.Response('{"code":1,"result":"job"}', 200);
        }
        return http.Response('unavailable', 503);
      }),
    );
    expect(posts, 1);
  });

  test(
    'Atlas parses long flags and adjacent boolean flags without consuming the next flag',
    () {
      expect(
        midjourneyBody(
          const ImageGenerationRequest(
            prompt: 'city --hd --seed 42 --stylize 100 --quality 4',
            model: 'youchuan/v8.2/text-to-image',
          ),
          MidjourneyProtocol.atlascloud,
        ),
        {
          'model': 'youchuan/v8.2/text-to-image',
          'prompt': 'city',
          'hd': true,
          'seed': 42,
          'stylize': 100,
          'quality': 4,
        },
      );
    },
  );

  test('quality capabilities differ by channel', () {
    expect(
      () => midjourneyBody(
        const ImageGenerationRequest(
          prompt: 'city --q 2',
          model: 'youchuan/v8.2/text-to-image',
        ),
        MidjourneyProtocol.atlascloud,
      ),
      throwsA(isA<AiImageGenerationException>()),
    );
    expect(
      midjourneyBody(
        const ImageGenerationRequest(
          prompt: 'city --q 2',
          model: 'midjourney-v8.2',
        ),
        MidjourneyProtocol.images,
      )['prompt'],
      'city --q 2',
    );
  });
}

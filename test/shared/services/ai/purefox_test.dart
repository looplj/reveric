// 职责: 验证 PureFox 媒体网关按 /v1/models 动态登记型号、图片档位编码、视频 NDJSON 流与参考素材上传。
// 关联文件:
//   lib/shared/services/ai/purefox_media.dart
//   lib/shared/services/ai/image/purefox.dart
//   lib/shared/services/ai/video/purefox.dart
//   lib/shared/models/image/channels.dart
//   lib/shared/models/video/channels.dart
//   lib/shared/providers/purefox_media_providers.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/image/channels.dart';
import 'package:reveric/shared/models/video/catalog.dart';
import 'package:reveric/shared/models/video/channels.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:reveric/shared/services/ai/image.dart';
import 'package:reveric/shared/services/ai/purefox_media.dart';
import 'package:reveric/shared/services/ai/video/purefox.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==';

const _videoId = 'site-video-model';
const _imageId = 'site-image-model';

/// 与内置目录撞名的站点型号，用于验证 PureFox 条目不污染其它供应商。
const _collidingImageId = 'gemini-3-pro-image-preview';
const _collidingVideoId = 'kwaivgi-kling-v4.0';
const _openAiImageId = 'gpt-image-2';

String _catalogId(String modelId) => '$purefoxMediaCatalogPrefix$modelId';

/// 站点真实信封：duration 是 {mode, options}，参考上限分三类。
String _payload() => jsonEncode({
  'object': 'list',
  'data': [
    {
      'id': _imageId,
      'kind': 'image',
      'qualities': ['1K', '2K'],
      'refImages': 3,
    },
    {
      'id': _videoId,
      'kind': 'video',
      'qualities': ['720p'],
      'duration': {
        'mode': 'options',
        'options': [5, 6],
      },
      'refImages': 4,
      'refVideos': 2,
      'refAudios': 1,
    },
    // 缺少时长：视频不可用，必须被过滤，不能进目录。
    {
      'id': 'no-duration-video',
      'kind': 'video',
      'qualities': ['720p'],
      'refImages': 2,
    },
  ],
});

AiProvider _media() => aiProviderBuiltinById(
  'purefox_media',
)!.copyWith(enabled: true, apiKey: 'purefox-key');

Future<PurefoxMediaModelCatalog> _registerCatalog() async {
  final catalog = await fetchPurefoxMediaModels(
    _media(),
    httpClient: MockClient((request) async {
      expect(request.url.toString(), 'https://img.purefox.org/v1/models');
      expect(request.headers['Authorization'], 'Bearer purefox-key');
      return http.Response(_payload(), 200);
    }),
  );
  catalog.register();
  return catalog;
}

/// 站点真实返回中存在与内置目录同名的型号；登记时必须落在 PureFox 命名空间。
String _collidingPayload() => jsonEncode({
  'data': [
    {
      'id': _collidingImageId,
      'kind': 'image',
      'qualities': ['1K'],
      'refImages': 1,
    },
    {
      'id': _openAiImageId,
      'kind': 'image',
      'qualities': ['1K'],
      'refImages': 1,
    },
    {
      'id': _collidingVideoId,
      'kind': 'video',
      'qualities': ['480p'],
      'duration': {
        'mode': 'options',
        'options': [4],
      },
      'refImages': 1,
    },
  ],
});

Future<void> _registerCollidingCatalog() async {
  final catalog = await fetchPurefoxMediaModels(
    _media(),
    httpClient: MockClient(
      (_) async => http.Response(_collidingPayload(), 200),
    ),
  );
  catalog.register();
}

VideoRequest _videoRequest({
  VideoMode mode = VideoMode.text,
  String modelId = _videoId,
}) => VideoRequest(
  modelId: modelId,
  prompt: 'A bird flying',
  mode: mode,
  resolution: '720p',
  ratio: '16:9',
  durationSeconds: 5,
);

final _pngBytes = base64Decode(_png);

VideoReference _reference(String url) => VideoReference(
  role: VideoInputRole.reference_image,
  url: url,
  mimeType: 'image/png',
  fileSize: _pngBytes.length,
  mediaInfo: const VideoMediaInfo(width: 1, height: 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('reveric_purefox_');
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
    purefoxMediaImageModels.remove(_imageId);
    purefoxMediaVideoModels.remove(_videoId);
    imageModelsCatalog.remove(_catalogId(_imageId));
    videoModelsCatalog.remove(_catalogId(_videoId));
    purefoxMediaImageModels.remove(_collidingImageId);
    purefoxMediaImageModels.remove(_openAiImageId);
    imageModelsCatalog.remove(_catalogId(_openAiImageId));
    purefoxMediaVideoModels.remove(_collidingVideoId);
    imageModelsCatalog.remove(_catalogId(_collidingImageId));
    videoModelsCatalog.remove(_catalogId(_collidingVideoId));
    await support.delete(recursive: true);
  });

  test('providers are built in but not seeded', () {
    expect(
      aiProviderFixedBaseUrl(AiProviderType.purefox),
      'https://purefox.org/v1',
    );
    expect(
      aiProviderFixedBaseUrl(AiProviderType.purefox_media),
      'https://img.purefox.org/v1',
    );
    expect(imageModelsForProvider('purefox_media'), isEmpty);
    expect(videoModelsForProvider('purefox_media'), isEmpty);
  });

  test('models come from /v1/models and are split by kind', () async {
    final catalog = await _registerCatalog();
    expect(catalog.idsOfKind('image'), [_imageId]);
    expect(catalog.idsOfKind('video'), [_videoId]);

    final image = lookupImageChannelModel('purefox_media', _imageId);
    expect(image, isNotNull);
    expect(image!.capabilities.resolutions, {'1K', '2K'});
    expect(image.capabilities.maxReferences, 3);

    final video = lookupVideoChannelModel('purefox_media', _videoId);
    expect(video, isNotNull);
    expect(video!.capabilities.resolutions, {'720p'});
    expect(video.capabilities.durations, {5, 6});
    expect(video.capabilities.maxReferences, 7);

    // 缺时长的视频不登记，避免 minDurationSeconds 崩溃/误提交。
    expect(
      lookupVideoChannelModel('purefox_media', 'no-duration-video'),
      isNull,
    );
  });

  test(
    'startup registration re-fetches only configured media providers',
    () async {
      var requests = 0;
      await ensurePurefoxMediaModelsRegistered(
        [
          aiProviderBuiltinById(
            'purefox',
          )!.copyWith(enabled: true, apiKey: 'text-key'),
          aiProviderBuiltinById(
            'purefox_media',
          )!.copyWith(enabled: false, apiKey: ''),
          _media(),
        ],
        httpClient: MockClient((request) async {
          requests++;
          return http.Response(_payload(), 200);
        }),
      );

      expect(requests, 1);
      expect(lookupVideoChannelModel('purefox_media', _videoId), isNotNull);
    },
  );

  test('startup registration keeps going when the gateway fails', () async {
    await expectLater(
      ensurePurefoxMediaModelsRegistered([
        _media(),
      ], httpClient: MockClient((_) async => http.Response('boom', 500))),
      completes,
    );
    expect(lookupVideoChannelModel('purefox_media', _videoId), isNull);
  });

  test('non-200 becomes an exception carrying the status code', () async {
    await expectLater(
      fetchPurefoxMediaModels(
        _media(),
        httpClient: MockClient((_) async => http.Response('nope', 401)),
      ),
      throwsA(
        isA<PurefoxMediaModelsException>().having(
          (e) => e.statusCode,
          'statusCode',
          401,
        ),
      ),
    );
  });

  test('image request sends quality tier and aspect ratio', () async {
    await _registerCatalog();
    final seen = <http.Request>[];
    await http.runWithClient(
      () async {
        final service = AiImageGenerationService(_media(), model: _imageId);
        final result = await service.generateImage(
          'a cat',
          aspectRatio: '16:9',
          resolution: '2K',
        );
        expect(
          File(result.localFilePath!).readAsBytesSync(),
          base64Decode(_png),
        );
      },
      () => MockClient((request) async {
        seen.add(request);
        return http.Response(
          jsonEncode({
            'data': [
              {'url': 'data:image/png;base64,$_png'},
            ],
          }),
          200,
        );
      }),
    );
    expect(
      seen.single.url.toString(),
      'https://img.purefox.org/v1/images/generations',
    );
    expect(jsonDecode(seen.single.body), {
      'model': _imageId,
      'prompt': 'a cat',
      'n': 1,
      'response_format': 'url',
      'quality': '2K',
      'aspect_ratio': '16:9',
    });
  });

  test('image rejects unsupported ratio before network', () async {
    await _registerCatalog();
    await http.runWithClient(() async {
      final service = AiImageGenerationService(_media(), model: _imageId);
      await expectLater(
        service.generateImage('a cat', aspectRatio: '1:1', resolution: '2K'),
        throwsA(isA<AiImageGenerationException>()),
      );
    }, () => MockClient((_) => throw StateError('must not send')));
  });

  test('video submit reads the receipt from the X-Job-Id header', () async {
    await _registerCatalog();
    final seen = <http.Request>[];
    final transport = MockClient((request) async {
      seen.add(request);
      return http.Response(
        '{"jobId":"job-1","status":"queued"}\n',
        200,
        headers: {'x-job-id': 'job-1'},
      );
    });
    final api = PurefoxVideoClient(
      httpClient: transport,
      providerType: 'purefox_media',
      endpoint: Uri.parse('https://img.purefox.org/v1'),
      apiKey: 'purefox-key',
    );
    final receipt = await api.submit(_videoRequest(), []);
    expect(receipt.taskId, 'job-1');
    expect(seen.single.url.path, '/v1/generate');
    expect(receipt.pollingUrl.path, '/v1/jobs/job-1');
    expect(jsonDecode(seen.single.body), {
      'model': _videoId,
      'prompt': 'A bird flying',
      'quality': '720p',
      'ratio': '16:9',
      'duration': 5,
      'refs': <String>[],
    });
    transport.close();
  });

  test(
    'video keeps the receipt when the stream breaks after headers',
    () async {
      await _registerCatalog();
      final transport = MockClient((request) async {
        // 响应头已带 jobId，响应体读到一半断流。
        return http.Response(
          '{"jobId":"job-1","stat',
          200,
          headers: {'x-job-id': 'job-1'},
        );
      });
      final api = PurefoxVideoClient(
        httpClient: transport,
        providerType: 'purefox_media',
        endpoint: Uri.parse('https://img.purefox.org/v1'),
        apiKey: 'purefox-key',
      );
      final receipt = await api.submit(_videoRequest(), []);
      expect(receipt.taskId, 'job-1');
      transport.close();
    },
  );

  test('video reports an unknown submission without a job id', () async {
    await _registerCatalog();
    final transport = MockClient(
      (request) async => http.Response('not json', 200),
    );
    final api = PurefoxVideoClient(
      httpClient: transport,
      providerType: 'purefox_media',
      endpoint: Uri.parse('https://img.purefox.org/v1'),
      apiKey: 'purefox-key',
    );
    await expectLater(
      api.submit(_videoRequest(), []),
      throwsA(
        isA<VideoException>().having(
          (e) => e.code,
          'code',
          VideoErrorCode.submission_unknown,
        ),
      ),
    );
    transport.close();
  });

  test('video passes public reference URLs straight to the gateway', () async {
    await _registerCatalog();
    final seen = <http.Request>[];
    final transport = MockClient((request) async {
      seen.add(request);
      expect(request.method, 'POST');
      return http.Response('{"jobId":"job-1","status":"running"}\n', 200);
    });
    final api = PurefoxVideoClient(
      httpClient: transport,
      providerType: 'purefox_media',
      endpoint: Uri.parse('https://img.purefox.org/v1'),
      apiKey: 'purefox-key',
    );
    await api.submit(_videoRequest(mode: VideoMode.reference), [
      _reference('https://bucket.example/references/a.png'),
    ]);
    // 公网直链不需要预签名上传：一次 POST /v1/generate 就是全部请求。
    expect(seen, hasLength(1));
    expect(seen.single.url.path, '/v1/generate');
    expect(jsonDecode(seen.single.body)['refs'], [
      'https://bucket.example/references/a.png',
    ]);
    transport.close();
  });

  test(
    'video submits uploaded keys verbatim without downloading them',
    () async {
      await _registerCatalog();
      final seen = <http.Request>[];
      final transport = MockClient((request) async {
        seen.add(request);
        expect(request.method, 'POST');
        return http.Response('{"jobId":"job-1","status":"running"}\n', 200);
      });
      final api = PurefoxVideoClient(
        httpClient: transport,
        providerType: 'purefox_media',
        endpoint: Uri.parse('https://img.purefox.org/v1'),
        apiKey: 'purefox-key',
      );
      await api.submit(_videoRequest(mode: VideoMode.reference), [
        _reference('uploads/AbC.png'),
      ]);
      // 已上传 key 只进入生成请求，不尝试 GET 或重新上传。
      expect(seen, hasLength(1));
      expect(seen.single.url.path, '/v1/generate');
      expect(jsonDecode(seen.single.body)['refs'], ['uploads/AbC.png']);
      transport.close();
    },
  );

  test('video rejects references the gateway cannot download', () async {
    await _registerCatalog();
    var requests = 0;
    final transport = MockClient((request) async {
      requests++;
      return http.Response('{"jobId":"job-1","status":"running"}\n', 200);
    });
    final api = PurefoxVideoClient(
      httpClient: transport,
      providerType: 'purefox_media',
      endpoint: Uri.parse('https://img.purefox.org/v1'),
      apiKey: 'purefox-key',
    );
    await expectLater(
      api.submit(_videoRequest(mode: VideoMode.reference), [
        _reference('asset://private-asset'),
      ]),
      throwsA(
        isA<VideoException>().having((e) => e.field, 'field', 'reference'),
      ),
    );
    expect(requests, 0);
    transport.close();
  });

  test('video polls the job snapshot endpoint', () async {
    await _registerCatalog();
    final seen = <http.Request>[];
    final api = PurefoxVideoClient(
      httpClient: MockClient((request) async {
        seen.add(request);
        return http.Response(
          jsonEncode({
            'jobId': 'job-1',
            'status': 'succeeded',
            'result': '/files/movie.mp4',
            'creditsCharged': 10,
            'refunded': false,
          }),
          200,
        );
      }),
      providerType: 'purefox_media',
      endpoint: Uri.parse('https://img.purefox.org/v1'),
      apiKey: 'purefox-key',
    );
    final result = await api.query(
      VideoSubmission(
        taskId: 'job-1',
        modelId: _videoId,
        pollingUrl: api.queryUrl('job-1', _videoId),
      ),
    );
    expect(result.status, VideoRemoteStatus.succeeded);
    expect(
      result.videoUrl.toString(),
      'https://img.purefox.org/files/movie.mp4',
    );
    expect(seen.single.method, 'GET');
    expect(seen.single.url.path, '/v1/jobs/job-1');
  });

  test('video poll maps a missing job to not_found', () async {
    await _registerCatalog();
    final api = PurefoxVideoClient(
      httpClient: MockClient(
        (request) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'error': {'code': '4001', 'message': '任务不存在'},
            }),
          ),
          400,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
      providerType: 'purefox_media',
      endpoint: Uri.parse('https://img.purefox.org/v1'),
      apiKey: 'purefox-key',
    );
    await expectLater(
      api.query(
        VideoSubmission(
          taskId: 'job-1',
          modelId: _videoId,
          pollingUrl: api.queryUrl('job-1', _videoId),
        ),
      ),
      throwsA(
        isA<VideoException>().having(
          (e) => e.code,
          'code',
          VideoErrorCode.not_found,
        ),
      ),
    );
  });

  test('video failure keeps a redacted provider message', () async {
    await _registerCatalog();
    final api = PurefoxVideoClient(
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'jobId': 'job-1',
            'status': 'failed',
            'error': {'code': '4001', 'message': 'content rejected'},
          }),
          200,
        ),
      ),
      providerType: 'purefox_media',
      endpoint: Uri.parse('https://img.purefox.org/v1'),
      apiKey: 'purefox-key',
    );
    final result = await api.query(
      VideoSubmission(
        taskId: 'job-1',
        modelId: _videoId,
        pollingUrl: api.queryUrl('job-1', _videoId),
      ),
    );
    expect(result.status, VideoRemoteStatus.failed);
    expect(result.providerMessage, 'content rejected');
    expect(result.videoUrl, isNull);
  });

  test('video rejects an unauthorized key without retrying', () async {
    await _registerCatalog();
    var posts = 0;
    final api = PurefoxVideoClient(
      httpClient: MockClient((_) async {
        posts++;
        return http.Response.bytes(
          utf8.encode('{"error":{"code":"4011","message":"无效的 API Key"}}'),
          401,
        );
      }),
      providerType: 'purefox_media',
      endpoint: Uri.parse('https://img.purefox.org/v1'),
      apiKey: 'purefox-key',
    );
    await expectLater(
      api.submit(_videoRequest(), []),
      throwsA(
        isA<VideoException>()
            .having((e) => e.code, 'code', VideoErrorCode.authentication)
            .having((e) => e.statusCode, 'status', 401),
      ),
    );
    expect(posts, 1);
  });

  test('PureFox registration never overwrites other providers', () async {
    // 这些 ID 同时存在于内置目录，PureFox 登记前先记录纯内置能力。
    final geminiCatalogBefore = imageModelsCatalog[_collidingImageId];
    final openaiCatalogBefore = imageModelsCatalog[_openAiImageId];
    final videoCatalogBefore = videoModelsCatalog[_collidingVideoId];
    expect(geminiCatalogBefore, isNotNull);
    expect(openaiCatalogBefore, isNotNull);
    expect(videoCatalogBefore, isNotNull);
    final geminiCapabilities = lookupImageChannelModel(
      'gemini',
      _collidingImageId,
    )!.capabilities;
    final openaiCapabilities = lookupImageChannelModel(
      'openai',
      _openAiImageId,
    )!.capabilities;
    final atlasCapabilities = lookupVideoChannelModel(
      'atlascloud',
      'kwaivgi/kling-v4.0',
    )!.capabilities;

    await _registerCollidingCatalog();

    // 其它供应商读取的目录条目必须仍是原来的对象。
    expect(imageModelsCatalog[_collidingImageId], same(geminiCatalogBefore));
    expect(imageModelsCatalog[_openAiImageId], same(openaiCatalogBefore));
    expect(videoModelsCatalog[_collidingVideoId], same(videoCatalogBefore));
    expect(
      lookupImageChannelModel(
        'gemini',
        _collidingImageId,
      )!.capabilities.resolutions,
      geminiCapabilities.resolutions,
    );
    expect(
      lookupImageChannelModel('openai', _openAiImageId)!.capabilities.ratios,
      openaiCapabilities.ratios,
    );
    expect(
      lookupVideoChannelModel(
        'atlascloud',
        'kwaivgi/kling-v4.0',
      )!.capabilities.durations,
      atlasCapabilities.durations,
    );

    // PureFox 自己的条目仍按站点返回登记，只是换到命名空间内。
    final purefox = lookupImageChannelModel('purefox_media', _collidingImageId);
    expect(purefox, isNotNull);
    expect(purefox!.capabilities.resolutions, {'1K'});
    expect(purefox.capabilities.maxReferences, 1);
    expect(
      imageModelsCatalog.containsKey(_catalogId(_collidingImageId)),
      isTrue,
    );

    final video = lookupVideoChannelModel('purefox_media', _collidingVideoId);
    expect(video, isNotNull);
    expect(video!.capabilities.resolutions, {'480p'});
    expect(video.capabilities.durations, {4});
    expect(
      videoModelsCatalog.containsKey(_catalogId(_collidingVideoId)),
      isTrue,
    );
  });

  test('requests strip the PureFox catalog prefix', () async {
    await _registerCollidingCatalog();
    final image = AiImageGenerationService(_media(), model: _collidingImageId);
    expect(
      purefoxUpstreamModel(_catalogId(_collidingImageId)),
      _collidingImageId,
    );

    final seen = <http.Request>[];
    await http.runWithClient(
      () => image.generateImage('a cat', aspectRatio: '1:1', resolution: '1K'),
      () => MockClient((request) async {
        seen.add(request);
        return http.Response(
          jsonEncode({
            'data': [
              {'url': 'data:image/png;base64,$_png'},
            ],
          }),
          200,
        );
      }),
    );
    expect(jsonDecode(seen.single.body)['model'], _collidingImageId);

    final api = PurefoxVideoClient(
      httpClient: MockClient((_) async => http.Response('', 200)),
      providerType: 'purefox_media',
      endpoint: Uri.parse('https://img.purefox.org/v1'),
      apiKey: 'purefox-key',
    );
    expect(
      api.encode(
        _videoRequest(modelId: _catalogId(_collidingVideoId)),
        [],
      )['model'],
      _collidingVideoId,
    );
    expect(
      api.encode(_videoRequest(modelId: _collidingVideoId), [])['model'],
      _collidingVideoId,
    );
  });
}

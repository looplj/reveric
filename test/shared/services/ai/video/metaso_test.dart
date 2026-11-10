// 职责: 验证 METASO H3 的渠道规格与 MiniMax V2 提交、轮询契约。
// 关联文件:
//   lib/shared/models/ai_provider.dart
//   lib/shared/models/video/channels.dart
//   lib/shared/services/ai/video/minimax.dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/video/channels.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:reveric/shared/services/ai/video/minimax.dart';
import 'package:reveric/shared/services/ai/provider_resources.dart';

void main() {
  final provider = aiProviderBuiltinById('openai')!.copyWith(
    type: 'metaso',
    baseUrl: '',
    apiKey: 'metaso-key',
    enabled: true,
    videoModels: ['MiniMax-H3'],
  );
  VideoRequest request({
    String resolution = '1080p',
    int duration = 30,
    String modelId = 'MiniMax-H3',
  }) => VideoRequest(
    modelId: modelId,
    prompt: 'A quiet city at dawn',
    mode: VideoMode.text,
    resolution: resolution,
    ratio: '16:9',
    durationSeconds: duration,
  );

  test('METASO exposes its video catalog and keeps native limits separate', () {
    expect(customAiProviderTypes, contains(AiProviderType.metaso));
    expect(provider.isValid, isTrue);
    expect(provider.supportedModelKinds, {AiModelKind.video});
    expect(provider.effectiveBaseUrl, 'https://metaso.cn/api/minimax');
    expect(videoModelsForProvider('metaso'), [
      'MiniMax-H3',
      'MiniMax-H3-priority',
      'seedance-2.0',
      'seedance-2.0-mini',
    ]);
    expect(lookupVideoChannelModel('metaso', 'minimax-h3'), isNull);
    final channel = lookupVideoChannelModel('metaso', 'MiniMax-H3')!;
    expect(channel.resolutions, {'480p', '768P', '1080p', '2K'});
    expect(channel.durationsForResolution('1080p').last, 30);
    expect(channel.durationsForResolution('2K').last, 15);
    final native = lookupVideoChannelModel('minimax', 'MiniMax-H3')!;
    expect(native.resolutions, {'768P', '2K'});
    expect(native.maxDurationSeconds, 15);
  });

  test('METASO submits and polls native task receipts with Bearer auth', () async {
    final calls = <http.Request>[];
    final transport = MockClient((r) async {
      calls.add(r);
      expect(r.headers['Authorization'], 'Bearer metaso-key');
      if (r.method == 'POST') {
        expect(
          r.url.toString(),
          'https://metaso.cn/api/minimax/v2/video_generation',
        );
        expect(jsonDecode(r.body), {
          'model': 'MiniMax-H3',
          'content': [
            {'type': 'text', 'text': 'A quiet city at dawn'},
          ],
          'resolution': '1080p',
          'duration': 30,
          'ratio': '16:9',
        });
        return http.Response('{"task_id":"424010985738629"}', 200);
      }
      expect(
        r.url.toString(),
        'https://metaso.cn/api/minimax/v2/query/video_generation/424010985738629',
      );
      return http.Response(
        '{"task":{"id":"424010985738629","status":"succeeded","content":{"url":"https://cdn.example/video.mp4"}}}',
        200,
      );
    });
    final client = MinimaxVideoClient(
      httpClient: transport,
      providerType: 'metaso',
      endpoint: Uri.parse(provider.effectiveBaseUrl),
      apiKey: provider.apiKey,
    );
    final submission = await client.submit(request(), []);
    final result = await client.query(submission);
    expect(result.status, VideoRemoteStatus.succeeded);
    expect(result.videoUrl.toString(), 'https://cdn.example/video.mp4');
    expect(calls, hasLength(2));
    transport.close();
  });

  test('2K over 15 seconds is rejected before a billable request', () async {
    final transport = MockClient((_) => throw StateError('must not submit'));
    final client = MinimaxVideoClient(
      httpClient: transport,
      providerType: 'metaso',
      endpoint: Uri.parse(provider.effectiveBaseUrl),
      apiKey: provider.apiKey,
    );
    expect(
      client.encodeSubmission(request(resolution: '2K', duration: 15), []),
      isNotEmpty,
    );
    await expectLater(
      client.submit(request(resolution: '2K', duration: 16), []),
      throwsA(
        isA<VideoException>().having((e) => e.field, 'field', 'duration'),
      ),
    );
    transport.close();
  });

  test('failed METASO tasks preserve provider diagnostics', () async {
    final transport = MockClient(
      (_) async => http.Response(
        '{"task":{"id":"job","status":"failed","error":{"code":"ContentPolicyViolation","message":"Input was rejected"}}}',
        200,
      ),
    );
    final client = MinimaxVideoClient(
      httpClient: transport,
      providerType: 'metaso',
      endpoint: Uri.parse(provider.effectiveBaseUrl),
      apiKey: provider.apiKey,
    );
    final result = await client.query(
      VideoSubmission(
        taskId: 'job',
        modelId: 'MiniMax-H3',
        pollingUrl: client.queryUrl('job', 'MiniMax-H3'),
      ),
    );
    expect(result.status, VideoRemoteStatus.failed);
    expect(result.detail, contains('ContentPolicyViolation'));
    expect(result.detail, contains('Input was rejected'));
    transport.close();
  });
  for (final model in ['seedance-2.0', 'seedance-2.0-mini']) {
    test('$model uses the METASO envelope and preserves its model ID', () async {
      final transport = MockClient((r) async {
        expect(r.headers['Authorization'], 'Bearer metaso-key');
        if (r.method == 'POST') {
          expect(r.url.path, '/api/minimax/v2/video_generation');
          expect(jsonDecode(r.body), {
            'model': model,
            'content': [
              {'type': 'text', 'text': 'A paper boat floats on a lake.'},
            ],
            'resolution': '720p',
            'duration': 15,
            'ratio': '16:9',
          });
          return http.Response('{"task_id":"seedance-job"}', 200);
        }
        expect(
          r.url.path,
          '/api/minimax/v2/query/video_generation/seedance-job',
        );
        return http.Response(
          '{"task":{"status":"succeeded","content":{"url":"https://cdn.example/seedance.mp4"}}}',
          200,
        );
      });
      final client = MinimaxVideoClient(
        httpClient: transport,
        providerType: 'metaso',
        endpoint: Uri.parse(provider.effectiveBaseUrl),
        apiKey: provider.apiKey,
      );
      final submission = await client.submit(
        VideoRequest(
          modelId: model,
          prompt: 'A paper boat floats on a lake.',
          mode: VideoMode.text,
          resolution: '720p',
          durationSeconds: 15,
          ratio: '16:9',
        ),
        [],
      );
      expect(
        (await client.query(submission)).videoUrl.toString(),
        'https://cdn.example/seedance.mp4',
      );
      final channel = lookupVideoChannelModel('metaso', model)!;
      expect(channel.requiresAudio, false);
      expect(channel.protocolOptions.supportsProviderAssets, false);
      expect(channel.resolutions.contains('4k'), model == 'seedance-2.0');
      expect(channel.durations, isNot(contains(16)));
      transport.close();
    });
  }
  test(
    'Seedance accepts first-frame URLs and rejects Mini 1080p before submission',
    () {
      final transport = MockClient((_) => throw StateError('must not send'));
      addTearDown(transport.close);
      final client = MinimaxVideoClient(
        httpClient: transport,
        providerType: 'metaso',
        endpoint: Uri.parse(provider.effectiveBaseUrl),
        apiKey: provider.apiKey,
      );
      final frame = VideoReference(
        role: VideoInputRole.first_frame,
        url: 'https://cdn.example/frame.png',
        mimeType: 'image/png',
        fileSize: 1000,
        mediaInfo: const VideoMediaInfo(width: 1280, height: 720),
      );
      VideoRequest seedance(String resolution) => VideoRequest(
        modelId: 'seedance-2.0-mini',
        prompt: 'Animate the paper boat.',
        mode: VideoMode.first_frame,
        resolution: resolution,
        durationSeconds: 4,
        ratio: '16:9',
      );
      final body = client.encodeSubmission(seedance('720p'), [frame]);
      expect((body['content'] as List).last, {
        'type': 'image_url',
        'image_url': {'url': frame.url.toString()},
        'role': 'first_frame',
      });
      expect(body.containsKey('generate_audio'), false);
      expect(
        () => client.encodeSubmission(seedance('1080p'), [frame]),
        throwsA(
          isA<VideoException>().having((e) => e.field, 'field', 'resolution'),
        ),
      );
    },
  );

  test(
    'Agent model resources expose the H3 resolution duration limit without credentials',
    () {
      final resource = providerModelResource(provider, 'video', 'MiniMax-H3');
      expect(resource['capabilities']['max_duration_by_resolution'], {
        '2K': 15,
      });
      expect(resource['capabilities']['durations'], contains(30));
      expect(jsonEncode(resource), isNot(contains('metaso-key')));
    },
  );
  test(
    'priority maps only the wire model and retains its alias across recovery',
    () async {
      const alias = 'MiniMax-H3-priority';
      final transport = MockClient((r) async {
        expect(r.headers['Authorization'], 'Bearer metaso-key');
        if (r.method == 'POST') {
          expect(r.url.path, '/api/minimax/v2/video_generation');
          expect(jsonDecode(r.body), {
            'model': 'MiniMax-H3',
            'fast_mode': true,
            'content': [
              {'type': 'text', 'text': 'A quiet city at dawn'},
            ],
            'resolution': '1080p',
            'duration': 30,
            'ratio': '16:9',
          });
          return http.Response('{"task_id":"priority-job"}', 200);
        }
        expect(
          r.url.path,
          '/api/minimax/v2/query/video_generation/priority-job',
        );
        return http.Response(
          '{"task":{"status":"succeeded","content":{"url":"https://cdn.example/priority.mp4"}}}',
          200,
        );
      });
      addTearDown(transport.close);
      MinimaxVideoClient client() => MinimaxVideoClient(
        httpClient: transport,
        providerType: 'metaso',
        endpoint: Uri.parse(provider.effectiveBaseUrl),
        apiKey: provider.apiKey,
      );
      final restored = VideoRequest.fromJson(request(modelId: alias).toJson());
      expect(restored.modelId, alias);
      final submission = await client().submit(restored, []);
      expect(submission.modelId, alias);
      expect(
        (await client().query(submission)).status,
        VideoRemoteStatus.succeeded,
      );
      final ordinary = lookupVideoChannelModel('metaso', 'MiniMax-H3')!;
      final priority = lookupVideoChannelModel('metaso', alias)!;
      expect(priority.catalogId, ordinary.catalogId);
      expect(priority.resolutions, ordinary.resolutions);
      expect(priority.durations, ordinary.durations);
      expect(
        priority.maxDurationByResolution,
        ordinary.maxDurationByResolution,
      );
      expect(
        priority.protocolOptions.framesRequireAdaptiveRatio,
        ordinary.protocolOptions.framesRequireAdaptiveRatio,
      );
      expect(priority.highlights, contains(VideoModelHighlight.priority));
      expect(
        ordinary.highlights,
        isNot(contains(VideoModelHighlight.priority)),
      );
      expect(priority.notices, [VideoModelNotice.priority_billing]);
      expect(ordinary.notices, isEmpty);
    },
  );

  test(
    'priority uses the same 2K duration limit before any billable request',
    () async {
      final transport = MockClient((_) => throw StateError('must not send'));
      addTearDown(transport.close);
      final client = MinimaxVideoClient(
        httpClient: transport,
        providerType: 'metaso',
        endpoint: Uri.parse(provider.effectiveBaseUrl),
        apiKey: provider.apiKey,
      );
      const alias = 'MiniMax-H3-priority';
      expect(
        client.encodeSubmission(
          request(modelId: alias, resolution: '2K', duration: 15),
          [],
        )['fast_mode'],
        true,
      );
      await expectLater(
        client.submit(
          request(modelId: alias, resolution: '2K', duration: 16),
          [],
        ),
        throwsA(
          isA<VideoException>().having((e) => e.field, 'field', 'duration'),
        ),
      );
    },
  );

  test(
    'priority suffix never enables priority on another provider or model',
    () {
      final transport = MockClient((_) => throw StateError('must not send'));
      addTearDown(transport.close);
      for (final sample in [
        ('minimax', 'MiniMax-H3-priority'),
        ('minimax', 'MiniMax-H3'),
        ('metaso', 'seedance-2.0-priority'),
      ]) {
        final client = MinimaxVideoClient(
          httpClient: transport,
          providerType: sample.$1,
          endpoint: Uri.parse('https://api.example'),
          apiKey: 'key',
        );
        final encoded = client.encode(request(modelId: sample.$2), []);
        expect(encoded['model'], sample.$2);
        expect(encoded.containsKey('fast_mode'), false);
      }
      expect(
        videoModelsForProvider('minimax'),
        isNot(contains('MiniMax-H3-priority')),
      );
      expect(
        lookupVideoChannelModel('metaso', 'seedance-2.0-priority'),
        isNull,
      );
    },
  );
}

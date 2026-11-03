// 职责: 以固定上游回执验证视频模型的协议、能力和提交不确定性。
// 关联文件:
//   lib/shared/services/ai/video/client.dart
//   lib/shared/services/ai/video/ark.dart
//   lib/shared/services/ai/video/minimax.dart
//   lib/shared/services/ai/video/wan.dart
//   lib/shared/models/video/capabilities.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/models/video/capabilities.dart';
import 'package:reveric/shared/models/video/channels.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:reveric/shared/services/ai/video/ark.dart';
import 'package:reveric/shared/services/ai/video/new_api.dart';
import 'package:reveric/shared/services/ai/video/atlascloud.dart';
import 'package:reveric/shared/services/ai/video/openrouter.dart';
import 'package:reveric/shared/services/ai/video/agnes.dart';
import 'package:reveric/shared/services/ai/video/client.dart';
import 'package:reveric/shared/services/ai/video/minimax.dart';
import 'package:reveric/shared/services/ai/video/wan.dart';
import '../../../../helpers/media_provider_types.dart';

VideoRequest request(
  VideoProtocol protocol,
  String model, {
  VideoMode mode = VideoMode.text,
  int duration = 5,
}) => VideoRequest(
  modelId: model,
  prompt: 'A bird flying',
  mode: mode,
  resolution: protocol == VideoProtocol.atlascloud_video
      ? '720p'
      : protocol == VideoProtocol.openrouter_video
      ? (lookupVideoChannelModel(
              videoProviderType(protocol),
              model,
            )?.resolutions.first ??
            '720p')
      : protocol == VideoProtocol.ark_video ||
            protocol == VideoProtocol.new_api_video
      ? '720p'
      : protocol == VideoProtocol.minimax_video_v2
      ? '768P'
      : '720P',
  ratio:
      protocol != VideoProtocol.agnes_video &&
          protocol != VideoProtocol.openrouter_video &&
          (mode == VideoMode.first_frame || mode == VideoMode.first_last_frame)
      ? 'adaptive'
      : '16:9',
  durationSeconds: protocol == VideoProtocol.openrouter_video && duration == 5
      ? (lookupVideoChannelModel(
              videoProviderType(protocol),
              model,
            )?.minDurationSeconds ??
            duration)
      : duration,
  audio: protocol == VideoProtocol.openrouter_video
      ? (lookupVideoChannelModel(
                  videoProviderType(protocol),
                  model,
                )?.requiresAudio ==
                true
            ? true
            : null)
      : protocol == VideoProtocol.minimax_video_v2 ||
            protocol == VideoProtocol.agnes_video
      ? null
      : true,
  promptExtend: protocol == VideoProtocol.wan_video ? true : null,
);

VideoReference reference(VideoInputRole role, {int duration = 2000}) =>
    VideoReference(
      role: role,
      url: Uri.parse('https://reference.example/${role.name}'),
      mimeType: switch (role.kind) {
        VideoMediaKind.image => 'image/png',
        VideoMediaKind.video => 'video/mp4',
        VideoMediaKind.audio => 'audio/mpeg',
      },
      fileSize: 100,
      mediaInfo: VideoMediaInfo(
        width: 720,
        height: 720,
        durationMs: duration,
        frameRate: 30,
      ),
    );

VideoClient client(VideoProtocol protocol, http.Client transport) =>
    switch (protocol) {
      VideoProtocol.new_api_video => NewApiVideoClient(
        httpClient: transport,
        providerType: videoProviderType(protocol),
        endpoint: Uri.parse('https://example.com/proxy/v1'),
        apiKey: 'secret',
      ),
      VideoProtocol.atlascloud_video => AtlasCloudVideoClient(
        httpClient: transport,
        providerType: videoProviderType(protocol),
        apiKey: 'secret',
      ),
      VideoProtocol.openrouter_video => OpenRouterVideoClient(
        httpClient: transport,
        providerType: videoProviderType(protocol),
        apiKey: 'secret',
      ),
      VideoProtocol.agnes_video => AgnesVideoClient(
        httpClient: transport,
        providerType: videoProviderType(protocol),
        endpoint: Uri.parse('https://example.com/proxy/v1'),
        apiKey: 'secret',
      ),
      VideoProtocol.ark_video => ArkVideoClient(
        httpClient: transport,
        providerType: videoProviderType(protocol),
        endpoint: Uri.parse('https://example.com/proxy/api/v3'),
        apiKey: 'secret',
      ),
      VideoProtocol.minimax_video_v2 => MinimaxVideoClient(
        httpClient: transport,
        providerType: videoProviderType(protocol),
        endpoint: Uri.parse('https://example.com/proxy'),
        apiKey: 'secret',
      ),
      VideoProtocol.wan_video => WanVideoClient(
        httpClient: transport,
        providerType: videoProviderType(protocol),
        endpoint: Uri.parse('https://example.com/proxy'),
        apiKey: 'secret',
      ),
    };

Map<String, dynamic> receipt(VideoProtocol protocol) => switch (protocol) {
  VideoProtocol.atlascloud_video => {
    'code': 200,
    'data': {'id': 'task-1', 'status': 'processing'},
  },
  VideoProtocol.openrouter_video ||
  VideoProtocol.new_api_video => {'id': 'task-1'},
  VideoProtocol.agnes_video => {
    'id': 'billing-task',
    'task_id': 'billing-task',
    'video_id': 'task-1',
  },
  VideoProtocol.ark_video => {'id': 'task-1'},
  VideoProtocol.minimax_video_v2 => {'task_id': 'task-1'},
  VideoProtocol.wan_video => {
    'output': {'task_id': 'task-1', 'task_status': 'PENDING'},
  },
};
Map<String, dynamic> result(
  VideoProtocol protocol,
  String status, {
  bool withUrl = true,
}) => switch (protocol) {
  VideoProtocol.atlascloud_video => {
    'code': 200,
    'data': {
      'id': 'task-1',
      'status': status == 'succeeded'
          ? 'completed'
          : status == 'running'
          ? 'processing'
          : status,
      'outputs': [if (withUrl) 'https://result.example/movie.mp4'],
    },
  },
  VideoProtocol.openrouter_video || VideoProtocol.new_api_video => {
    if (withUrl) 'id': 'task-1',
    'status': switch (status) {
      'running' => 'in_progress',
      'succeeded' => 'completed',
      _ => status,
    },
  },
  VideoProtocol.agnes_video => {
    'id': 'billing-task',
    'status': switch (status) {
      'running' => 'in_progress',
      'succeeded' => 'completed',
      _ => status,
    },
    'internal_status': 'pending',
    if (withUrl) 'url': 'https://result.example/movie.mp4',
  },
  VideoProtocol.ark_video => {
    'id': 'task-1',
    'status': status,
    'content': {if (withUrl) 'video_url': 'https://result.example/movie.mp4'},
  },
  VideoProtocol.minimax_video_v2 => {
    'task': {
      'id': 'task-1',
      'status': status,
      'content': {if (withUrl) 'url': 'https://result.example/movie.mp4'},
    },
  },
  VideoProtocol.wan_video => {
    'output': {
      'task_id': 'task-1',
      'task_status': status.toUpperCase(),
      if (withUrl) 'video_url': 'https://result.example/movie.mp4',
    },
  },
};

void main() {
  test(
    'AtlasCloud frame modes select the image route and preserve both frames',
    () async {
      for (final mode in [VideoMode.first_frame, VideoMode.first_last_frame]) {
        final api = client(
          VideoProtocol.atlascloud_video,
          MockClient((r) async {
            final body = jsonDecode(r.body) as Map;
            expect(body['model'], 'bytedance/seedance-2.5/image-to-video');
            expect(body['image'], 'https://reference.example/first_frame');
            expect(
              body['last_image'],
              mode == VideoMode.first_last_frame
                  ? 'https://reference.example/last_frame'
                  : null,
            );
            expect(body.containsKey('reference_images'), false);
            expect(body.containsKey('omni_reference_task_type'), false);
            return http.Response(
              jsonEncode(receipt(VideoProtocol.atlascloud_video)),
              200,
            );
          }),
        );
        await api.submit(
          request(
            VideoProtocol.atlascloud_video,
            'bytedance/seedance-2.5',
            mode: mode,
          ),
          [
            reference(VideoInputRole.first_frame),
            if (mode == VideoMode.first_last_frame)
              reference(VideoInputRole.last_frame),
          ],
        );
      }
    },
  );
  test('program errors are not hidden behind submission uncertainty', () async {
    final bug = StateError('unexpected program error');
    final api = client(
      VideoProtocol.agnes_video,
      MockClient((_) async => throw bug),
    );
    await expectLater(
      api.submit(request(VideoProtocol.agnes_video, 'agnes-video-2.5'), []),
      throwsA(same(bug)),
    );
  });
  test('transport failures retain a redacted diagnostic', () async {
    final lines = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) {
        lines.add(message);
      }
    };
    addTearDown(() => debugPrint = originalDebugPrint);
    final api = client(
      VideoProtocol.agnes_video,
      MockClient((_) async {
        throw http.ClientException(
          'connection reset secret https://private.example/?token=secret',
        );
      }),
    );
    await expectLater(
      api.submit(request(VideoProtocol.agnes_video, 'agnes-video-2.5'), []),
      throwsA(
        isA<VideoException>().having(
          (e) => e.code,
          'code',
          VideoErrorCode.submission_unknown,
        ),
      ),
    );
    final log = lines.join('\n');
    expect(log, contains('connection reset'));
    expect(log, contains('ClientException'));
    expect(log, isNot(contains('secret')));
    expect(log, contains('https://private.example/?token=[redacted]'));
  });
  test('HTTP error diagnostics retain URLs and redact credentials', () async {
    final lines = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) {
        lines.add(message);
      }
    };
    addTearDown(() => debugPrint = originalDebugPrint);
    final api = client(
      VideoProtocol.agnes_video,
      MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {
              'message':
                  'No available channel secret Bearer upstream-token sk-private-key https://signed.example/video?token=private-token\nnext line',
            },
          }),
          503,
        ),
      ),
    );
    await expectLater(
      api.submit(request(VideoProtocol.agnes_video, 'agnes-video-2.5'), []),
      throwsA(isA<VideoException>()),
    );
    final log = lines.join('\n');
    expect(log, contains('status=503'));
    expect(log, contains('No available channel'));
    expect(log, contains('https://signed.example/video?token=private-token'));
    for (final sensitive in [
      'secret',
      'upstream-token',
      'sk-private-key',
      '\nnext line',
    ]) {
      expect(log, isNot(contains(sensitive)));
    }
  });
  for (final brokenBody in [false, true]) {
    test(
      'received HTTP 503 survives body ${brokenBody ? "failure" : "timeout"}',
      () async {
        final stream = StreamController<List<int>>();
        final transport = MockClient.streaming((_, _) async {
          if (brokenBody) {
            stream.addError(StateError('response interrupted'));
          }
          return http.StreamedResponse(stream.stream, 503);
        });
        final api = AgnesVideoClient(
          httpClient: transport,
          providerType: 'agnes',
          endpoint: Uri.parse('https://example.com/v1'),
          apiKey: 'secret',
          timeout: const Duration(milliseconds: 50),
        );
        await expectLater(
          api.submit(request(VideoProtocol.agnes_video, 'agnes-video-2.5'), []),
          throwsA(
            isA<VideoException>()
                .having((e) => e.code, 'code', VideoErrorCode.unavailable)
                .having((e) => e.statusCode, 'HTTP status', 503)
                .having(
                  (e) => e.messageKey,
                  'fallback',
                  LocaleKeys.aiServiceOverloaded,
                ),
          ),
        );
        await stream.close();
        transport.close();
      },
    );
  }
  test(
    'Agnes uses explicit frame fields and never falls back to the billing task ID',
    () async {
      final api = client(
        VideoProtocol.agnes_video,
        MockClient((_) async => http.Response('{"id":"billing-task"}', 200)),
      );
      final req = request(
        VideoProtocol.agnes_video,
        'agnes-video-2.5',
        mode: VideoMode.first_last_frame,
      );
      final refs = [
        reference(VideoInputRole.first_frame),
        reference(VideoInputRole.last_frame),
      ];
      final body = api.encode(req, refs);
      expect(body['mode'], 'keyframe');
      expect(body['first_frame'], 'https://reference.example/first_frame');
      expect(body['last_frame'], 'https://reference.example/last_frame');
      expect(body.containsKey('images'), false);
      await expectLater(
        api.submit(req, refs),
        throwsA(
          isA<VideoException>().having(
            (e) => e.code,
            'code',
            VideoErrorCode.submission_unknown,
          ),
        ),
      );
    },
  );
  test(
    'Agnes validates persisted polling model and encodes opaque video IDs',
    () async {
      final api = client(
        VideoProtocol.agnes_video,
        MockClient((_) => throw StateError('must not send')),
      );
      final url = api.queryUrl('video/id?x=1&y=2', 'agnes-video-2.5');
      expect(url.queryParameters['video_id'], 'video/id?x=1&y=2');
      await expectLater(
        api.query(
          VideoSubmission(
            taskId: 'video/id?x=1&y=2',
            modelId: 'agnes-video-2.5',
            pollingUrl: url.replace(
              queryParameters: {
                ...url.queryParameters,
                'model_name': 'agnes-video-2.5-flash',
              },
            ),
          ),
        ),
        throwsA(
          isA<VideoException>().having(
            (e) => e.code,
            'code',
            VideoErrorCode.configuration_required,
          ),
        ),
      );
    },
  );
  test(
    'Wan removes only chat suffix while retaining host and proxy prefix',
    () {
      expect(
        wanVideoEndpoint(
          'https://maas.qianwenaiapi.com/compatible-mode/v1/',
        ).toString(),
        'https://maas.qianwenaiapi.com',
      );
      expect(
        wanVideoEndpoint(
          'https://custom.example/gateway/compatible-mode/v1',
        ).toString(),
        'https://custom.example/gateway',
      );
      expect(
        wanVideoEndpoint('https://custom.example/gateway').toString(),
        'https://custom.example/gateway',
      );
    },
  );
  for (final protocol in VideoProtocol.values) {
    test(
      '$protocol preserves output review failure on a successful poll',
      () async {
        final payload = result(protocol, 'failed');
        final target = protocol == VideoProtocol.atlascloud_video
            ? payload['data'] as Map<String, dynamic>
            : payload;
        target['error'] = {
          'code': 'OutputVideoSensitiveContentDetected',
          'message': 'private diagnostic',
        };
        final api = client(
          protocol,
          MockClient((_) async => http.Response(jsonEncode(payload), 200)),
        );
        final model = videoModelsForProvider(videoProviderType(protocol)).first;
        final received = await api.query(
          VideoSubmission(
            taskId: 'task-1',
            modelId: model,
            pollingUrl: api.queryUrl('task-1', model),
          ),
        );
        expect(received.status, VideoRemoteStatus.failed);
        expect(received.messageKey, LocaleKeys.aiOutputContentRejected);
        expect(received.providerMessage, 'private diagnostic');
      },
    );
    test(
      '$protocol preserves structured upstream codes through a gateway',
      () async {
        for (final (status, error, expected) in [
          (
            400,
            {'code': 'InputImageSensitiveContentDetected.PolicyViolation'},
            LocaleKeys.aiInputCopyrightRejected,
          ),
          (
            403,
            {
              'code': 'OperationDenied.ServiceOverdue',
              'message': 'Request failed',
            },
            LocaleKeys.aiProviderPaymentRequired,
          ),
          (
            429,
            {'code': 'ServerOverloaded', 'message': 'Request failed'},
            LocaleKeys.aiServiceOverloaded,
          ),
          (
            400,
            {
              'code': 400,
              'message': 'Provider returned error',
              'metadata': {
                'raw': jsonEncode({
                  'error': {'code': 'ModelNotOpen'},
                }),
              },
            },
            LocaleKeys.aiModelNotActivated,
          ),
        ]) {
          final api = client(
            protocol,
            MockClient(
              (_) async => http.Response(jsonEncode({'error': error}), status),
            ),
          );
          await expectLater(
            api.submit(
              request(
                protocol,
                videoModelsForProvider(videoProviderType(protocol)).first,
              ),
              [],
            ),
            throwsA(
              isA<VideoException>().having(
                (e) => e.messageKey,
                'safe key',
                expected,
              ),
            ),
          );
        }
      },
    );
    test(
      '$protocol identifies input image privacy rejection on HTTP 400',
      () async {
        final api = client(
          protocol,
          MockClient(
            (_) async => http.Response(
              jsonEncode({
                'error': {
                  'code':
                      'InputImageSensitiveContentDetected.PrivacyInformation',
                  'message':
                      "The request failed because the input image 'content[2]' 'content[3]' may contain real person. Request id: private-request-id",
                  'type': 'BadRequest',
                },
              }),
              400,
            ),
          ),
        );
        await expectLater(
          api.submit(
            request(
              protocol,
              videoModelsForProvider(videoProviderType(protocol)).first,
            ),
            [],
          ),
          throwsA(
            isA<VideoException>()
                .having((e) => e.code, 'code', VideoErrorCode.rejected)
                .having((e) => e.statusCode, 'status', 400)
                .having(
                  (e) => e.messageKey,
                  'safe message key',
                  LocaleKeys.aiInputImagePrivacyRejected,
                )
                .having(
                  (e) => e.toString().contains('private-request-id'),
                  'no raw diagnostic',
                  false,
                ),
          ),
        );
      },
    );
    test(
      '$protocol reuses agent message matching without exposing raw errors',
      () async {
        for (final (body, expected) in [
          (
            '{"error":{"message":"No available channel for private-model"}}',
            LocaleKeys.aiProviderChannelUnavailable,
          ),
          (
            '{"message":"insufficient account balance"}',
            LocaleKeys.aiProviderPaymentRequired,
          ),
          (
            '{"error":"model not found: private-model"}',
            LocaleKeys.aiModelNotFound,
          ),
          (
            'data: {"error":{"message":"service temporarily overloaded"}}',
            LocaleKeys.aiServiceOverloaded,
          ),
          (
            '{"error":{"message":"private unknown upstream failure"}}',
            LocaleKeys.aiServiceOverloaded,
          ),
          (
            '<html>private upstream failure</html>',
            LocaleKeys.aiServiceOverloaded,
          ),
          ('{"error":', LocaleKeys.aiServiceOverloaded),
          ('', LocaleKeys.aiServiceOverloaded),
          ('x' * (64 * 1024 + 1), LocaleKeys.aiServiceOverloaded),
        ]) {
          var posts = 0;
          final api = client(
            protocol,
            MockClient((_) async {
              posts++;
              return http.Response(body, 503);
            }),
          );
          await expectLater(
            api.submit(
              request(
                protocol,
                videoModelsForProvider(videoProviderType(protocol)).first,
              ),
              [],
            ),
            throwsA(
              isA<VideoException>()
                  .having((e) => e.code, 'code', VideoErrorCode.unavailable)
                  .having((e) => e.statusCode, 'HTTP status', 503)
                  .having((e) => e.messageKey, 'safe message key', expected)
                  .having(
                    (e) => e.providerMessage,
                    'original message',
                    body.contains('private unknown upstream failure')
                        ? 'private unknown upstream failure'
                        : anything,
                  )
                  .having(
                    (e) => e.toString().contains('private'),
                    'no raw response',
                    false,
                  ),
            ),
          );
          expect(posts, 1);
        }
      },
    );
    // New API 的 metadata 和内联素材契约由 new_api_media_test.dart 覆盖。
    // Seedance 的多模态字段断言只适用于这两个型号；AtlasCloud 其他端点
    // 的字段、模式和查询契约由 atlascloud_test.dart 覆盖。
    for (final model
        in protocol == VideoProtocol.new_api_video
            ? const <String>[]
            : protocol == VideoProtocol.atlascloud_video
            ? ['bytedance/seedance-2.5', 'bytedance/seedance-2.0']
            : videoModelsForProvider(videoProviderType(protocol))) {
      test('$model reference request and original-ID query contract', () async {
        final seen = <http.Request>[];
        final transport = MockClient((r) async {
          seen.add(r);
          expect(r.headers['Authorization'], 'Bearer secret');
          return http.Response(
            jsonEncode(
              r.method == 'POST'
                  ? receipt(protocol)
                  : result(protocol, 'succeeded'),
            ),
            200,
          );
        });
        final api = client(protocol, transport);
        final refs = [
          reference(
            protocol == VideoProtocol.openrouter_video
                ? VideoInputRole.first_frame
                : VideoInputRole.reference_image,
          ),
          if (protocol != VideoProtocol.openrouter_video &&
              model != 'agnes-video-2.5-flash')
            reference(VideoInputRole.reference_video),
          if (protocol != VideoProtocol.openrouter_video)
            reference(VideoInputRole.reference_audio),
        ];
        final submission = await api.submit(
          request(
            protocol,
            model,
            mode: protocol == VideoProtocol.openrouter_video
                ? VideoMode.first_frame
                : VideoMode.reference,
          ),
          refs,
        );
        final output = await api.query(submission);
        expect(output.status, VideoRemoteStatus.succeeded);
        expect(
          output.videoUrl.toString(),
          protocol == VideoProtocol.openrouter_video
              ? 'https://openrouter.ai/api/v1/videos/task-1/content'
              : 'https://result.example/movie.mp4',
        );
        expect(seen.map((r) => r.method), ['POST', 'GET']);
        expect(seen.last.url, submission.pollingUrl);
        expect(submission.taskId, 'task-1');
        final body = jsonDecode(seen.first.body) as Map;
        expect(
          body['model'],
          protocol == VideoProtocol.atlascloud_video
              ? '$model/reference-to-video'
              : model,
        );
        if (protocol == VideoProtocol.openrouter_video) {
          expect(seen.first.url.path, '/api/v1/videos');
          expect(body['frame_images'], [
            {
              'type': 'image_url',
              'image_url': {'url': 'https://reference.example/first_frame'},
              'frame_type': 'first_frame',
            },
          ]);
        } else if (protocol == VideoProtocol.atlascloud_video) {
          expect(
            seen.first.url.toString(),
            'https://api.atlascloud.ai/api/v1/model/generateVideo',
          );
          expect(seen.last.url.path, '/api/v1/model/prediction/task-1');
          expect(body['reference_images'], [
            'https://reference.example/reference_image',
          ]);
          expect(body['reference_videos'], [
            'https://reference.example/reference_video',
          ]);
          expect(body['reference_audios'], [
            'https://reference.example/reference_audio',
          ]);
          expect(body['generate_audio'], true);
          expect(body['duration'], 5);
          expect(
            body['omni_reference_task_type'],
            model.endsWith('2.5') ? 'reference' : null,
          );
        } else if (protocol == VideoProtocol.agnes_video) {
          expect(seen.first.url.path, '/proxy/v1/videos');
          expect(seen.last.url.path, '/proxy/agnesapi');
          expect(seen.last.url.queryParameters, {
            'video_id': 'task-1',
            'model_name': model,
          });
          expect(body, {
            'model': model,
            'prompt': 'A bird flying',
            'seconds': '5',
            'size': '720P',
            'aspect_ratio': '16:9',
            'mode': 'reference',
            'images': ['https://reference.example/reference_image'],
            'audios': ['https://reference.example/reference_audio'],
            if (model != 'agnes-video-2.5-flash')
              'videos': [
                {'url': 'https://reference.example/reference_video'},
              ],
          });
        } else if (protocol == VideoProtocol.wan_video) {
          expect(
            seen.first.url.path,
            '/proxy/api/v1/services/aigc/video-generation/video-synthesis',
          );
          expect(seen.last.url.path, '/proxy/api/v1/tasks/task-1');
          expect(seen.first.headers['X-DashScope-Async'], 'enable');
          // 查询接口是同步接口，携带异步头会被 workspace Endpoint 403 拒绝。
          expect(
            seen.last.headers.containsKey('X-DashScope-Async'),
            false,
            reason: '任务查询不得携带异步请求头',
          );
          expect(body['input']['media'], [
            for (final ref in refs)
              {'type': ref.role.name, 'url': ref.url.toString()},
          ]);
          expect(body['parameters'], {
            'resolution': '720P',
            'duration': 5,
            'ratio': '16:9',
            'audio': true,
            'prompt_extend': true,
          });
        } else {
          expect(body['content'], [
            {'type': 'text', 'text': 'A bird flying'},
            for (final ref in refs)
              {
                'type': '${ref.role.kind.name}_url',
                '${ref.role.kind.name}_url': {'url': ref.url.toString()},
                'role': ref.role.name,
              },
          ]);
          if (protocol == VideoProtocol.ark_video) {
            expect(
              seen.first.url.path,
              '/proxy/api/v3/contents/generations/tasks',
            );
            if (model == 'doubao-seedance-2-5-260628') {
              expect(body['omni_reference_task_type'], 'reference');
            } else {
              expect(body.containsKey('omni_reference_task_type'), false);
            }
            expect(body['generate_audio'], true);
          } else {
            expect(seen.first.url.path, '/proxy/v2/video_generation');
            expect(
              seen.last.url.path,
              '/proxy/v2/query/video_generation/task-1',
            );
            expect(body.containsKey('generate_audio'), false);
          }
        }
      });
      test('$model rejects unsupported inputs before network', () async {
        final api = client(
          protocol,
          MockClient((_) => throw StateError('must not send')),
        );
        await expectLater(
          api.submit(request(protocol, model), [
            reference(VideoInputRole.reference_image),
          ]),
          throwsA(isA<VideoException>()),
        );
        await expectLater(
          api.submit(request(protocol, model, duration: 31), []),
          throwsA(isA<VideoException>()),
        );
        await expectLater(
          api.submit(request(protocol, model, mode: VideoMode.first_frame), [
            reference(VideoInputRole.first_frame),
            reference(VideoInputRole.reference_audio),
          ]),
          throwsA(isA<VideoException>()),
        );
      });
    }
    final model = videoModelsForProvider(videoProviderType(protocol)).first;
    test(
      '$protocol maps all task states and rejects success without URL',
      () async {
        final api = client(
          protocol,
          MockClient((_) async => http.Response('{}', 200)),
        );
        for (final entry in {
          'queued': VideoRemoteStatus.queued,
          'running': VideoRemoteStatus.running,
          'failed': VideoRemoteStatus.failed,
          'cancelled': VideoRemoteStatus.cancelled,
          'UNKNOWN': VideoRemoteStatus.unknown,
        }.entries) {
          expect(
            api.decodeResult(result(protocol, entry.key)).status,
            entry.value,
          );
        }
        expect(
          () => api.decodeResult(result(protocol, 'succeeded', withUrl: false)),
          throwsA(anything),
        );
      },
    );
    test(
      '$protocol HTTP rejection, auth and throttling are distinct',
      () async {
        for (final entry in {
          400: VideoErrorCode.rejected,
          401: VideoErrorCode.authentication,
          403: VideoErrorCode.authentication,
          429: VideoErrorCode.rate_limited,
          500: VideoErrorCode.unavailable,
          503: VideoErrorCode.unavailable,
        }.entries) {
          final api = client(
            protocol,
            MockClient(
              (_) async => http.Response(
                'secret https://signed.example/?token=secret',
                entry.key,
                headers: {'retry-after': '120'},
              ),
            ),
          );
          await expectLater(
            api.submit(request(protocol, model), []),
            throwsA(
              isA<VideoException>()
                  .having((e) => e.code, 'code', entry.value)
                  .having(
                    (e) => e.toString().contains('secret'),
                    'redacted',
                    false,
                  )
                  .having(
                    (e) => e.retryAfter,
                    'retryAfter',
                    const Duration(seconds: 120),
                  ),
            ),
          );
        }
      },
    );
    test(
      '$protocol missing receipt or network failure never resubmits',
      () async {
        for (final response in ['{}', 'not JSON']) {
          var posts = 0;
          final api = client(
            protocol,
            MockClient((_) async {
              posts++;
              return http.Response(response, 200);
            }),
          );
          await expectLater(
            api.submit(request(protocol, model), []),
            throwsA(
              isA<VideoException>().having(
                (e) => e.code,
                'code',
                VideoErrorCode.submission_unknown,
              ),
            ),
          );
          expect(posts, 1);
        }
        var posts = 0;
        final api = client(
          protocol,
          MockClient((_) async {
            posts++;
            throw TimeoutException('secret');
          }),
        );
        await expectLater(
          api.submit(request(protocol, model), []),
          throwsA(
            isA<VideoException>().having(
              (e) => e.code,
              'code',
              VideoErrorCode.submission_unknown,
            ),
          ),
        );
        expect(posts, 1);
      },
    );
    test(
      '$protocol will not send credentials to changed polling URL',
      () async {
        final api = client(
          protocol,
          MockClient((_) => throw StateError('must not send')),
        );
        await expectLater(
          api.query(
            VideoSubmission(
              taskId: 'task-1',
              modelId: videoModelsForProvider(
                videoProviderType(protocol),
              ).first,
              pollingUrl: Uri.parse('https://foreign.example/tasks/task-1'),
            ),
          ),
          throwsA(
            isA<VideoException>().having(
              (e) => e.code,
              'code',
              VideoErrorCode.configuration_required,
            ),
          ),
        );
      },
    );
  }
  test(
    'channel alias uses catalog validation while preserving the request model ID',
    () async {
      const model = 'bytedance/seedance-2.5/image-to-video';
      var posts = 0;
      final api = client(
        VideoProtocol.ark_video,
        MockClient((r) async {
          posts++;
          final body = jsonDecode(r.body) as Map;
          expect(body['model'], model);
          return http.Response('{"id":"task-alias"}', 200);
        }),
      );
      await api.submit(
        request(VideoProtocol.ark_video, model, mode: VideoMode.first_frame),
        [reference(VideoInputRole.first_frame)],
      );
      expect(posts, 1);
      await expectLater(
        api.submit(request(VideoProtocol.ark_video, model, duration: 31), []),
        throwsA(
          isA<VideoException>().having((e) => e.field, 'field', 'duration'),
        ),
      );
      expect(posts, 1);
    },
  );
  test('Wan input plus output duration budget is enforced', () {
    final caps = VideoCapabilities(videoProviderType(VideoProtocol.wan_video));
    expect(
      () => caps.validate(
        request(
          VideoProtocol.wan_video,
          'wan3.0-video',
          mode: VideoMode.reference,
          duration: 20,
        ),
        [reference(VideoInputRole.reference_video, duration: 15000)],
      ),
      throwsA(
        isA<VideoException>().having((e) => e.field, 'field', 'total_duration'),
      ),
    );
  });
  test(
    'versioned persistence excludes immediate URL and rejects newer schema',
    () {
      final value = request(
        VideoProtocol.ark_video,
        'doubao-seedance-2-5-260628',
      );
      expect(VideoRequest.fromJson(value.toJson()).toJson(), value.toJson());
      expect(
        () => VideoRequest.fromJson({...value.toJson(), 'version': 2}),
        throwsFormatException,
      );
    },
  );
}

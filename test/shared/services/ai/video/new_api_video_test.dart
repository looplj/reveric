// 职责: 验证 New API 供应商共用视频协议、模型字段与已有原生任务的恢复。
// 关联文件:
//   lib/shared/services/ai/new_api.dart
//   lib/shared/services/ai/video/new_api.dart
//   lib/shared/models/video/channels.dart
import 'dart:convert';
import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/video/channels.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:reveric/shared/services/ai/new_api.dart';

AiProvider provider(String type) => aiProviderBuiltinById('openai')!.copyWith(
  type: type,
  apiKey: 'test-key',
  baseUrl: 'https://future.test/proxy/v1',
);
http.Response jsonResponse(Object data) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  test(
    'submission accepts a delayed receipt while queries retain a 30 second deadline',
    () {
      fakeAsync((clock) {
        final response = Completer<http.Response>();
        var calls = 0;
        final transport = MockClient((request) {
          calls++;
          return request.method == 'POST'
              ? response.future
              : Completer<http.Response>().future;
        });
        final client = NewApiClient(provider('token91')).video(transport);
        Map<String, dynamic>? receipt;
        Object? error;
        client
            .sendRequest(
              'POST',
              Uri.parse('https://api.91token.com/v1/videos'),
              submitting: true,
            )
            .then(
              (value) {
                receipt = value;
              },
              onError: (Object value) {
                error = value;
              },
            );
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 45));
        expect(error, isNull);
        expect(receipt, isNull);
        response.complete(jsonResponse({'id': 'late-task'}));
        clock.flushMicrotasks();
        expect(receipt?['id'], 'late-task');
        client
            .sendRequest(
              'GET',
              Uri.parse('https://api.91token.com/v1/videos/late-task'),
              submitting: false,
            )
            .then(
              (_) {},
              onError: (Object value) {
                error = value;
              },
            );
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 30));
        expect(
          error,
          isA<VideoException>().having(
            (e) => e.code,
            'code',
            VideoErrorCode.unavailable,
          ),
        );
        expect(calls, 2);
        transport.close();
      });
    },
  );
  test('submission stops at three minutes without a second POST', () {
    fakeAsync((clock) {
      var posts = 0;
      final transport = MockClient((_) {
        posts++;
        return Completer<http.Response>().future;
      });
      final client = NewApiClient(provider('token91')).video(transport);
      Object? error;
      client
          .sendRequest(
            'POST',
            Uri.parse('https://api.91token.com/v1/videos'),
            submitting: true,
          )
          .then(
            (_) {},
            onError: (Object value) {
              error = value;
            },
          );
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 179));
      expect(error, isNull);
      clock.elapse(const Duration(seconds: 1));
      expect(
        error,
        isA<VideoException>().having(
          (e) => e.code,
          'code',
          VideoErrorCode.submission_unknown,
        ),
      );
      expect(posts, 1);
      transport.close();
    });
  });
  setUpAll(() {
    aiProviderTypeConfigs['future_new_api'] = const AiProviderTypeConfig(
      displayName: 'Future gateway',
      modelIdSource: ModelIdSource.open,
      usesNewApi: true,
    );
  });
  tearDownAll(() => aiProviderTypeConfigs.remove('future_new_api'));
  for (final type in [
    'api88',
    'ooki',
    'apikey',
    'infistar',
    'token91',
    'future_new_api',
  ]) {
    for (final model in [
      'doubao-seedance-2-0',
      'MiniMax-H3',
      'wan3.0-video',
      'viduq3-turbo',
      'viduq3-ad',
      'grok-imagine-video',
    ]) {
      test(
        '$type $model uses the shared submit, query and content contract',
        () async {
          final config = provider(type);
          expect(config.supportedModelKinds, AiModelKind.values.toSet());
          final channel = lookupVideoChannelModel(type, model)!;
          final base = config.effectiveBaseUrl;
          final transport = MockClient((req) async {
            expect(req.headers['Authorization'], 'Bearer test-key');
            if (req.method == 'POST') {
              expect(req.url.toString(), '$base/videos');
              final body = jsonDecode(req.body) as Map;
              expect(body['model'], model);
              expect(body['seconds'], '8');
              if (model == 'MiniMax-H3' || model.startsWith('doubao-')) {
                expect(
                  body['metadata']['content'][1]['role'],
                  'reference_image',
                );
                expect(body['metadata']['ratio'], '16:9');
              } else if (model.startsWith('wan')) {
                expect(body['metadata']['input']['media'], [
                  {
                    'type': 'reference_image',
                    'url': 'https://reference.test/image.png',
                  },
                ]);
                expect(body['metadata']['parameters']['duration'], 8);
              } else if (model.startsWith('vidu')) {
                expect(body['metadata']['action'], 'reference_to_video');
                expect(body['metadata']['subjects'], [
                  {
                    'name': 'subject_1',
                    'images': ['https://reference.test/image.png'],
                  },
                ]);
              } else {
                expect(body['reference_images'], [
                  'https://reference.test/image.png',
                ]);
              }
              return jsonResponse({
                'id': 'task-1',
                'object': 'video',
                'status': 'queued',
              });
            }
            if (req.url.path.endsWith('/content')) {
              expect(req.url.toString(), '$base/videos/task-1/content');
              return http.Response.bytes([1, 2, 3], 200);
            }
            expect(req.url.toString(), '$base/videos/task-1');
            return jsonResponse({
              'id': 'task-1',
              'object': 'video',
              'status': 'completed',
            });
          });
          addTearDown(transport.close);
          final client = NewApiClient(config).video(transport);
          final task = await client.submitNative(
            VideoRequest(
              modelId: model,
              prompt: 'A bird',
              mode: VideoMode.reference,
              resolution: channel.resolutions.first,
              ratio: '16:9',
              durationSeconds: 8,
              audio: channel.requestDefaults.audio,
              promptExtend: channel.requestDefaults.promptExtend,
            ),
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
        },
      );
    }
  }
  test(
    'an existing native H3 receipt resumes by GET without resubmitting',
    () async {
      final config = provider('token91');
      final calls = <String>[];
      final transport = MockClient((req) async {
        calls.add('${req.method} ${req.url}');
        return jsonResponse({
          'id': 'task-1',
          'status': 'in_progress',
          'progress': 50,
        });
      });
      addTearDown(transport.close);
      final client = NewApiClient(config).video(transport);
      final result = await client.queryNative(
        VideoSubmission(
          taskId: 'task-1',
          modelId: 'MiniMax-H3',
          pollingUrl: Uri.parse(
            'https://api.91token.com/v2/query/video_generation/task-1',
          ),
        ),
      );
      expect(result.status, VideoRemoteStatus.running);
      expect(calls, ['GET https://api.91token.com/v1/videos/task-1']);
      await expectLater(
        client.queryNative(
          VideoSubmission(
            taskId: 'task-1',
            modelId: 'MiniMax-H3',
            pollingUrl: Uri.parse(
              'https://foreign.test/v2/query/video_generation/task-1',
            ),
          ),
        ),
        throwsA(isA<VideoException>()),
      );
      expect(calls.length, 1);
    },
  );
}

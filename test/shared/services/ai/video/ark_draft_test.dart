// 职责: 验证火山草稿和转高清请求遵循 Ark 参数契约，并在收费请求前拒绝无效选项。
// 关联文件:
//   lib/shared/services/ai/video/ark.dart
//   lib/shared/models/video/channels.dart
//   lib/shared/services/ai/video/client.dart

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:reveric/shared/services/ai/video/ark.dart';

const model = 'doubao-seedance-2-5-260628';

VideoRequest request({
  String modelId = model,
  VideoMode mode = VideoMode.text,
  String resolution = '480p',
}) => VideoRequest(
  modelId: modelId,
  prompt: 'original scene',
  mode: mode,
  resolution: resolution,
  ratio: mode == VideoMode.text ? '16:9' : 'adaptive',
  audio: true,
);

VideoReference reference(VideoInputRole role) => VideoReference(
  role: role,
  url: Uri.https('example.test', '/${role.name}').toString(),
  mimeType: 'image/png',
  fileSize: 100,
  mediaInfo: const VideoMediaInfo(width: 720, height: 720),
);

void main() {
  for (final provider in ['volcengine', 'doubao']) {
    group(provider, () {
      late ArkVideoClient client;
      final bodies = <Map<String, dynamic>>[];
      setUp(() {
        bodies.clear();
        final transport = MockClient((r) async {
          expect(r.method, 'POST');
          expect(r.url.path, '/api/v3/contents/generations/tasks');
          bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
          return http.Response('{"id":"remote-task"}', 200);
        });
        addTearDown(transport.close);
        client = ArkVideoClient(
          httpClient: transport,
          providerType: provider,
          endpoint: Uri.parse('https://ark.cn-beijing.volces.com/api/v3'),
          apiKey: 'test-key',
        );
      });

      for (final mode in VideoMode.values) {
        test('$mode draft preserves inputs and requests 480p MP4', () async {
          final roles = switch (mode) {
            VideoMode.text => <VideoInputRole>[],
            VideoMode.first_frame => [VideoInputRole.first_frame],
            VideoMode.first_last_frame => [
              VideoInputRole.first_frame,
              VideoInputRole.last_frame,
            ],
            VideoMode.reference => [VideoInputRole.reference_image],
          };
          await client.submit(
            request(mode: mode),
            roles.map(reference).toList(),
            draft: true,
          );
          expect(bodies.single, {
            'model': model,
            'content': [
              {'type': 'text', 'text': 'original scene'},
              for (final role in roles)
                {
                  'type': 'image_url',
                  'image_url': {'url': 'https://example.test/${role.name}'},
                  'role': role.name,
                },
            ],
            'resolution': '480p',
            'duration': 5,
            'ratio': mode == VideoMode.text ? '16:9' : 'adaptive',
            'generate_audio': true,
            if (mode == VideoMode.reference)
              'omni_reference_task_type': 'reference',
            'draft': true,
            'output_format': 'mp4',
          });
        });
      }

      test(
        'HD sends only the draft reference and completion options',
        () async {
          final receipt = await client.submit(
            request(mode: VideoMode.reference, resolution: '1080p'),
            [],
            draftId: 'original-draft',
          );
          expect(bodies.single, {
            'model': model,
            'content': [
              {
                'type': 'draft_task',
                'draft_task': {'id': 'original-draft'},
              },
            ],
            'resolution': '1080p',
            'output_format': 'mp4',
          });
          expect(receipt.taskId, 'remote-task');
          expect(receipt.modelId, model);
          expect(
            receipt.pollingUrl.path,
            '/api/v3/contents/generations/tasks/remote-task',
          );
        },
      );

      test('invalid draft requests never send a paid POST', () async {
        for (final id in [
          'doubao-seedance-2-0-260128',
          'doubao-seedance-2-0-mini-260615',
          'unknown-model',
        ]) {
          for (final completion in [false, true]) {
            await expectLater(
              client.submit(
                request(modelId: id, resolution: completion ? '1080p' : '480p'),
                [],
                draft: !completion,
                draftId: completion ? 'original' : null,
              ),
              throwsA(isA<VideoException>()),
            );
          }
        }
        for (final options in [
          (draft: true, id: 'original', resolution: '480p', refs: false),
          (draft: true, id: null, resolution: '720p', refs: false),
          (draft: false, id: ' ', resolution: '1080p', refs: false),
          (draft: false, id: 'original', resolution: '720p', refs: false),
          (draft: false, id: 'original', resolution: '1080p', refs: true),
        ]) {
          await expectLater(
            client.submit(
              request(resolution: options.resolution),
              [if (options.refs) reference(VideoInputRole.reference_image)],
              draft: options.draft,
              draftId: options.id,
            ),
            throwsA(isA<VideoException>()),
          );
        }
        // Draft generation must still perform ordinary capability validation.
        await expectLater(
          client.submit(request(mode: VideoMode.first_frame), [], draft: true),
          throwsA(isA<VideoException>()),
        );
        expect(bodies, isEmpty);
      });

      test('normal generation does not enable draft mode', () async {
        await client.submit(request(resolution: '720p'), []);
        expect(bodies.single['resolution'], '720p');
        expect(bodies.single.containsKey('draft'), false);
        expect(bodies.single.containsKey('output_format'), false);
      });
    });
  }
}

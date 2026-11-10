// 职责: 验证草稿与高清完成的收费请求严格遵守 AtlasCloud 参数契约。
// 关联文件:
//   lib/shared/services/ai/video/atlascloud.dart
//   lib/shared/services/ai/video/client.dart
//   lib/shared/models/video/channels.dart

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:reveric/shared/services/ai/video/atlascloud.dart';

void main() {
  for (final mode in VideoMode.values) {
    test(
      '$mode draft preserves its inputs and explicitly requests 480p MP4',
      () async {
        final roles = switch (mode) {
          VideoMode.text => <VideoInputRole>[],
          VideoMode.first_frame => [VideoInputRole.first_frame],
          VideoMode.first_last_frame => [
            VideoInputRole.first_frame,
            VideoInputRole.last_frame,
          ],
          VideoMode.reference => [VideoInputRole.reference_image],
        };
        final transport = MockClient((r) async {
          final body = jsonDecode(r.body) as Map<String, dynamic>;
          expect(body['draft'], isTrue);
          expect(body['resolution'], '480p');
          expect(body['output_format'], 'mp4');
          expect(body['prompt'], 'a bird');
          expect(body['generate_audio'], isTrue);
          expect(
            body['model'],
            'bytedance/seedance-2.5/${switch (mode) {
              VideoMode.text => 'text-to-video',
              VideoMode.first_frame || VideoMode.first_last_frame => 'image-to-video',
              VideoMode.reference => 'reference-to-video',
            }}',
          );
          if (roles.contains(VideoInputRole.first_frame)) {
            expect(body['image'], 'https://example.test/first_frame');
          }
          if (roles.contains(VideoInputRole.last_frame)) {
            expect(body['last_image'], 'https://example.test/last_frame');
          }
          if (mode == VideoMode.reference) {
            expect(body['reference_images'], [
              'https://example.test/reference_image',
            ]);
          }
          return http.Response(
            '{"code":200,"data":{"id":"draft-remote"}}',
            200,
          );
        });
        addTearDown(transport.close);
        final client = AtlasCloudVideoClient(
          httpClient: transport,
          providerType: 'atlascloud',
          apiKey: 'key',
        );
        await client.submit(
          VideoRequest(
            modelId: 'bytedance/seedance-2.5',
            prompt: 'a bird',
            mode: mode,
            resolution: '480p',
            ratio: '16:9',
            audio: true,
          ),
          [
            for (final role in roles)
              VideoReference(
                role: role,
                url: Uri.https('example.test', '/${role.name}').toString(),
                mimeType: 'image/png',
                fileSize: 100,
                mediaInfo: const VideoMediaInfo(width: 720, height: 720),
              ),
          ],
          draft: true,
        );
      },
    );
  }

  test(
    'HD submits only the completion contract, without stale generation inputs',
    () async {
      final transport = MockClient((r) async {
        expect(jsonDecode(r.body), {
          'model': 'bytedance/seedance-2.5/draft-complete',
          'draft_id': 'original-prediction',
          'output_format': 'mp4',
        });
        return http.Response('{"code":200,"data":{"id":"hd-remote"}}', 200);
      });
      addTearDown(transport.close);
      final client = AtlasCloudVideoClient(
        httpClient: transport,
        providerType: 'atlascloud',
        apiKey: 'key',
      );
      final receipt = await client.submit(
        const VideoRequest(
          modelId: 'bytedance/seedance-2.5',
          prompt: 'not sent',
          mode: VideoMode.reference,
          resolution: '1080p',
          ratio: 'adaptive',
          audio: true,
        ),
        [],
        draftId: 'original-prediction',
      );
      expect(receipt.taskId, 'hd-remote');
      expect(receipt.pollingUrl.path, '/api/v1/model/prediction/hd-remote');
    },
  );

  test(
    'unsupported draft models and ambiguous draft options never send a POST',
    () async {
      var posts = 0;
      final transport = MockClient((r) async {
        posts++;
        return http.Response('{}', 200);
      });
      addTearDown(transport.close);
      final client = AtlasCloudVideoClient(
        httpClient: transport,
        providerType: 'atlascloud',
        apiKey: 'key',
      );
      for (final model in ['bytedance/seedance-2.0', 'custom-model']) {
        await expectLater(
          client.submit(
            VideoRequest(
              modelId: model,
              prompt: 'bird',
              mode: VideoMode.text,
              resolution: '480p',
              ratio: '16:9',
              audio: true,
            ),
            [],
            draft: true,
          ),
          throwsA(isA<VideoException>()),
        );
      }
      await expectLater(
        client.submit(
          const VideoRequest(
            modelId: 'bytedance/seedance-2.5',
            prompt: 'bird',
            mode: VideoMode.text,
            resolution: '480p',
            ratio: '16:9',
            audio: true,
          ),
          [],
          draft: true,
          draftId: 'original',
        ),
        throwsA(isA<VideoException>()),
      );
      expect(posts, 0);
    },
  );
}

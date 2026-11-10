// 职责: 按 Agnes 视频契约提交任务，并使用 video_id 和模型名查询结果。
// 关联文件:
//   lib/shared/services/ai/video/client.dart
//   lib/shared/models/video/catalog.dart
//   lib/shared/models/video/request.dart
//   lib/shared/models/video/task_result.dart

import '../../../models/video/request.dart';
import '../../../models/video/task_result.dart';
import 'client.dart';

class AgnesVideoClient extends VideoClient {
  AgnesVideoClient({
    required super.httpClient,
    required super.providerType,
    required super.endpoint,
    required super.apiKey,
    super.timeout,
  });

  @override
  String get createPath => 'videos';
  @override
  String queryPath(String id) => 'agnesapi';

  @override
  Uri queryUrl(String id, String modelId) {
    // 轮询端点与 /v1 同级，保留用户配置的反向代理路径前缀。
    final base = url(createPath);
    final prefix = endpoint.path
        .replaceFirst(RegExp(r'/+$'), '')
        .replaceFirst(RegExp(r'/v1$'), '');
    return base.replace(
      path: '$prefix/agnesapi',
      queryParameters: {'video_id': id, 'model_name': modelId},
    );
  }

  @override
  Map<String, dynamic> encode(
    VideoRequest request,
    List<VideoReference> references,
  ) {
    return {
      'model': request.modelId,
      'prompt': request.prompt,
      'seconds': '${request.durationSeconds}',
      'size': request.resolution,
      'aspect_ratio': request.ratio,
      'mode': switch (request.mode) {
        VideoMode.text => 'text',
        VideoMode.first_frame || VideoMode.first_last_frame => 'keyframe',
        VideoMode.reference => 'reference',
      },
      for (final ref in references)
        if (ref.role == VideoInputRole.first_frame ||
            ref.role == VideoInputRole.last_frame)
          ref.role.name: ref.url,
      for (final (role, key) in [
        (VideoInputRole.reference_image, 'images'),
        (VideoInputRole.reference_audio, 'audios'),
        (VideoInputRole.reference_video, 'videos'),
      ])
        if (references.any((r) => r.role == role))
          key: [
            for (final ref in references.where((r) => r.role == role))
              if (role == VideoInputRole.reference_video)
                {'url': ref.url}
              else
                ref.url,
          ],
    };
  }

  @override
  String submissionId(Map<String, dynamic> json) => json['video_id'] as String;

  @override
  VideoTaskResult decodeResult(Map<String, dynamic> json) =>
      videoResult(switch (json['status'] as String) {
        'in_progress' => 'running',
        'completed' => 'succeeded',
        final status => status,
      }, json['url']);
}

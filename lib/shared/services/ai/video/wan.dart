// 职责: 将 Wan 与 HappyHorse 请求及回执转换为千问异步视频协议。
// 关联文件:
//   lib/shared/services/ai/video/client.dart
//   lib/shared/models/video/channels.dart
//   lib/shared/models/video/request.dart
//   lib/shared/models/video/task_result.dart

import '../../../models/video/channels.dart';
import '../../../models/video/request.dart';
import '../../../models/video/task_result.dart';
import 'client.dart';

/// Qwen chat and video share credentials and the proxy prefix before this suffix.
Uri wanVideoEndpoint(String configuredBaseUrl) {
  final uri = Uri.parse(configuredBaseUrl.trim());
  final path = uri.path
      .replaceFirst(RegExp(r'/+$'), '')
      .replaceFirst(RegExp(r'/compatible-mode/v1$'), '');
  return uri.replace(path: path);
}

class WanVideoClient extends VideoClient {
  WanVideoClient({
    required super.httpClient,
    required super.providerType,
    required super.endpoint,
    required super.apiKey,
    super.timeout,
  });
  @override
  String get createPath =>
      'api/v1/services/aigc/video-generation/video-synthesis';
  @override
  String queryPath(String id) => 'api/v1/tasks/$id';

  /// 仅创建任务需要声明异步；`GET api/v1/tasks/{id}` 属于同步查询接口，
  /// 携带该头时 workspace 专属 Endpoint 会直接返回
  /// `403 access_denied: current user api does not support asynchronous calls`。
  @override
  Map<String, String> get submitHeaders => {'X-DashScope-Async': 'enable'};
  @override
  Map<String, dynamic> encode(
    VideoRequest request,
    List<VideoReference> references,
  ) => {
    'model': request.modelId,
    'input': {
      'prompt': request.prompt,
      if (references.isNotEmpty)
        'media': [
          for (final ref in references) {'type': ref.role.name, 'url': ref.url},
        ],
    },
    'parameters': {
      'resolution': request.resolution,
      'duration': request.durationSeconds,
      if (lookupVideoChannelModel(
            providerType,
            request.modelId,
          )?.protocolOptions.requiredMode !=
          VideoMode.first_frame)
        'ratio': request.ratio,
      'audio': ?request.audio,
      'prompt_extend': ?request.promptExtend,
    },
  };
  @override
  String submissionId(Map<String, dynamic> json) =>
      (json['output'] as Map)['task_id'] as String;
  @override
  VideoTaskResult decodeResult(Map<String, dynamic> json) {
    final output = json['output'] as Map;
    return videoResult(
      output['task_status'] as String,
      output['video_url'],
      wan: true,
    );
  }
}

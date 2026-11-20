// 职责: 将 MiniMax V2 视频请求与回执转换为渠道协议，并映射秘塔 H3 优先通道别名。
// 关联文件:
//   lib/shared/services/ai/video/client.dart
//   lib/shared/models/video/request.dart
//   lib/shared/models/video/task_result.dart

import '../../../models/video/request.dart';
import '../../../models/video/task_result.dart';
import 'client.dart';

class MinimaxVideoClient extends VideoClient {
  MinimaxVideoClient({
    required super.httpClient,
    required super.providerType,
    required super.endpoint,
    required super.apiKey,
    super.timeout,
  });
  @override
  String get createPath => 'v2/video_generation';
  @override
  String queryPath(String id) => 'v2/query/video_generation/$id';
  @override
  Map<String, dynamic> encode(
    VideoRequest request,
    List<VideoReference> references,
  ) {
    final priority =
        providerType == 'metaso' && request.modelId == 'MiniMax-H3-priority';
    return {
      'model': priority ? 'MiniMax-H3' : request.modelId,
      if (priority) 'fast_mode': true,
      'content': videoContent(request, references),
      'resolution': request.resolution,
      'duration': request.durationSeconds,
      'ratio': request.ratio,
    };
  }

  @override
  String submissionId(Map<String, dynamic> json) => switch (json['task_id']) {
    final String id => id,
    final int id when id > 0 => id.toString(),
    _ => throw const FormatException('Invalid MiniMax task ID'),
  };
  @override
  VideoTaskResult decodeResult(Map<String, dynamic> json) {
    final task = json['task'] as Map;
    return videoResult(
      task['status'] as String,
      (task['content'] as Map?)?['url'],
    );
  }
}

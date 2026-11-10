// 职责: 编解码 OpenRouter 视频任务，并限定内容下载的凭据发送范围。
// 关联文件:
//   lib/shared/services/ai/video/client.dart
//   lib/shared/services/ai/video/task_service.dart
//   lib/shared/models/video/request.dart
//   lib/shared/models/video/task_result.dart
import 'package:http/http.dart' as http;
import '../../../models/video/request.dart';
import '../../../models/video/task_result.dart';
import 'client.dart';

class OpenRouterVideoClient extends VideoClient {
  OpenRouterVideoClient({
    required super.httpClient,
    required super.providerType,
    required super.apiKey,
    super.timeout,
  }) : super(endpoint: Uri.parse('https://openrouter.ai/api/v1'));

  @override
  Future<http.StreamedResponse> download(
    http.Client transport,
    Uri url,
    VideoSubmission task,
  ) => downloadOpenRouterVideo(
    transport,
    url,
    taskId: task.taskId,
    apiKey: apiKey,
  );

  @override
  String get createPath => 'videos';
  @override
  String queryPath(String id) => 'videos/$id';
  @override
  Map<String, dynamic> encode(
    VideoRequest request,
    List<VideoReference> references,
  ) => {
    'model': request.modelId,
    'prompt': request.prompt,
    'duration': request.durationSeconds,
    'resolution': request.resolution,
    'aspect_ratio': request.ratio,
    if (request.audio != null) 'generate_audio': request.audio,
    if (references.any(
      (r) =>
          r.role == VideoInputRole.first_frame ||
          r.role == VideoInputRole.last_frame,
    ))
      'frame_images': [
        for (final r in references)
          if (r.role == VideoInputRole.first_frame ||
              r.role == VideoInputRole.last_frame)
            {
              'type': 'image_url',
              'image_url': {'url': r.url},
              'frame_type': r.role.name,
            },
      ],
    if (references.any((r) => r.role == VideoInputRole.reference_image))
      'input_references': [
        for (final r in references)
          if (r.role == VideoInputRole.reference_image)
            {
              'type': 'image_url',
              'image_url': {'url': r.url},
            },
      ],
  };
  @override
  String submissionId(Map<String, dynamic> json) => json['id'] as String;
  @override
  VideoTaskResult decodeResult(Map<String, dynamic> json) {
    final status = json['status'] as String;
    return videoResult(
      switch (status) {
        'pending' => 'queued',
        'in_progress' => 'running',
        'completed' => 'succeeded',
        _ => status,
      },
      status == 'completed'
          ? url(
              'videos/${Uri.encodeComponent(json['id'] as String)}/content',
            ).toString()
          : null,
    );
  }
}

/// Only the canonical content endpoint receives the account key. Redirected
/// object storage downloads never inherit provider authentication.
Future<http.StreamedResponse> downloadOpenRouterVideo(
  http.Client client,
  Uri url, {
  required String taskId,
  required String apiKey,
}) async {
  final expected = Uri.parse(
    'https://openrouter.ai/api/v1/videos/${Uri.encodeComponent(taskId)}/content',
  );
  if (url != expected || apiKey.trim().isEmpty) {
    throw const VideoException(VideoErrorCode.configuration_required);
  }
  var target = url;
  for (var redirects = 0; redirects <= 5; redirects++) {
    final request = http.Request('GET', target)..followRedirects = false;
    if (redirects == 0) {
      request.headers['Authorization'] = 'Bearer $apiKey';
    }
    final response = await client.send(request);
    if (!{301, 302, 303, 307, 308}.contains(response.statusCode)) {
      return response;
    }
    final location = response.headers['location'];
    await response.stream.drain<void>();
    if (location == null) {
      break;
    }
    target = target.resolve(location);
    if (target.scheme != 'https' ||
        target.host.isEmpty ||
        target.userInfo.isNotEmpty) {
      break;
    }
  }
  throw const VideoException(VideoErrorCode.invalid_response);
}

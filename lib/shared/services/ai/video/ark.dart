// 职责: 将 Seedance 请求与回执转换为 Ark 视频协议。
// 关联文件:
//   lib/shared/models/video/catalog.dart
//   lib/shared/services/ai/video/client.dart
//   lib/shared/models/video/request.dart
//   lib/shared/models/video/task_result.dart

import '../../../models/video/channels.dart';
import '../../../models/video/request.dart';
import '../../../models/video/task_result.dart';
import 'client.dart';

class ArkVideoClient extends VideoClient {
  ArkVideoClient({
    required super.httpClient,
    required super.providerType,
    required super.endpoint,
    required super.apiKey,
    super.timeout,
  });
  @override
  String get createPath => 'contents/generations/tasks';
  @override
  String queryPath(String id) => '$createPath/$id';

  @override
  Map<String, dynamic> encodeSubmission(
    VideoRequest request,
    List<VideoReference> references, {
    bool draft = false,
    String? draftId,
  }) {
    if (!draft && draftId == null) {
      return super.encodeSubmission(request, references);
    }
    final supportsDraft =
        lookupVideoChannelModel(
          providerType,
          request.modelId,
        )?.capabilities.draft !=
        null;
    if (!supportsDraft || (draft && draftId != null)) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'draft',
      );
    }
    if (draftId != null) {
      if (draftId.trim().isEmpty ||
          references.isNotEmpty ||
          request.resolution != '1080p') {
        throw const VideoException(
          VideoErrorCode.invalid_request,
          field: 'draft',
        );
      }
      // Ark reuses the draft inputs and rejects them if sent again.
      return {
        'model': request.modelId,
        'content': [
          {
            'type': 'draft_task',
            'draft_task': {'id': draftId},
          },
        ],
        'resolution': '1080p',
        'output_format': 'mp4',
      };
    }
    if (request.resolution != '480p') {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'resolution',
      );
    }
    return {
      ...super.encodeSubmission(request, references),
      'draft': true,
      'output_format': 'mp4',
    };
  }

  @override
  Map<String, dynamic> encode(
    VideoRequest request,
    List<VideoReference> references,
  ) => {
    'model': request.modelId,
    'content': videoContent(request, references),
    'resolution': request.resolution,
    'duration': request.durationSeconds,
    'ratio': request.ratio,
    'generate_audio': request.audio,
    if (request.mode == VideoMode.reference &&
        (lookupVideoChannelModel(
              providerType,
              request.modelId,
            )?.protocolOptions.supportsOmniReferenceTaskType ??
            false))
      'omni_reference_task_type': 'reference',
  };
  @override
  String submissionId(Map<String, dynamic> json) => json['id'] as String;
  @override
  VideoTaskResult decodeResult(Map<String, dynamic> json) => videoResult(
    json['status'] as String,
    (json['content'] as Map?)?['video_url'],
  );
}

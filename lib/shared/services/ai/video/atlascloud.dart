// 职责: 将 AtlasCloud 视频生成模式编码为模型路由，并解析预测任务回执。
// 关联文件:
//   lib/shared/services/ai/video/client.dart
//   lib/shared/models/video/channels.dart
//   lib/shared/models/video/task_result.dart
//   lib/shared/services/ai/video/task_service.dart

import '../../../models/video/channels.dart';
import '../../../models/video/request.dart';
import '../../../models/video/task_result.dart';
import '../../../logger/app_logger.dart';
import '../media_diagnostics.dart';
import 'client.dart';

final _log = AppLogger.forModule('AtlasCloudVideo');

class AtlasCloudVideoClient extends VideoClient {
  AtlasCloudVideoClient({
    required super.httpClient,
    required super.providerType,
    required super.apiKey,
    super.timeout,
  }) : super(endpoint: Uri.parse('https://api.atlascloud.ai/api/v1/model'));

  @override
  String get createPath => 'generateVideo';
  @override
  String queryPath(String id) => 'prediction/$id';

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
        )?.protocolOptions.supportsDraft ==
        true;
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
      return {
        'model': '${request.modelId}/draft-complete',
        'draft_id': draftId,
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
  ) {
    final channel = lookupVideoChannelModel(providerType, request.modelId);
    final options = channel?.protocolOptions;
    if (options is AtlasCloudVideoOptions) {
      return _encodeRoute(options, request, references);
    }
    final suffix = switch (request.mode) {
      VideoMode.text => 'text-to-video',
      VideoMode.first_frame || VideoMode.first_last_frame => 'image-to-video',
      VideoMode.reference => 'reference-to-video',
    };
    return {
      'model': '${request.modelId}/$suffix',
      'prompt': request.prompt,
      'duration': request.durationSeconds,
      'resolution': request.resolution,
      'ratio': request.ratio,
      'generate_audio': request.audio,
      for (final ref in references)
        if (ref.role == VideoInputRole.first_frame)
          'image': ref.url
        else if (ref.role == VideoInputRole.last_frame)
          'last_image': ref.url,
      for (final (role, key) in [
        (VideoInputRole.reference_image, 'reference_images'),
        (VideoInputRole.reference_video, 'reference_videos'),
        (VideoInputRole.reference_audio, 'reference_audios'),
      ])
        if (references.any((ref) => ref.role == role))
          key: [
            for (final ref in references.where((ref) => ref.role == role))
              ref.url,
          ],
      if (request.mode == VideoMode.reference &&
          (channel?.protocolOptions.supportsOmniReferenceTaskType ?? false))
        'omni_reference_task_type': 'reference',
    };
  }

  Map<String, dynamic> _encodeRoute(
    AtlasCloudVideoOptions options,
    VideoRequest request,
    List<VideoReference> references,
  ) {
    final route = options.routeFor(request.mode);
    void require(bool valid, String field) {
      if (!valid) {
        throw VideoException(VideoErrorCode.invalid_request, field: field);
      }
    }

    if (route == null) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'references',
      );
    }
    require(route.resolutions.contains(request.resolution), 'resolution');
    require(route.ratios.contains(request.ratio), 'ratio');
    require(route.durations.contains(request.durationSeconds), 'duration');
    require(
      !route.eightSecondResolutions.contains(request.resolution) ||
          request.durationSeconds == 8,
      'duration',
    );
    for (final kind in VideoMediaKind.values) {
      final count = references.where((ref) => ref.role.kind == kind).length;
      if (request.mode == VideoMode.reference) {
        require(
          count <= (route.referenceCounts[kind] ?? 0),
          '${kind.name}_count',
        );
      }
    }
    final values = <String, Object?>{
      'duration': request.durationSeconds,
      'resolution': request.resolution,
      'ratio': request.ratio,
      'audio': request.audio,
      'prompt_extend': request.promptExtend,
    };
    final body = <String, dynamic>{
      'model': route.modelId,
      'prompt': request.prompt,
      for (final entry in route.fields.entries)
        if (values[entry.key] != null) entry.value: values[entry.key],
    };
    if (route.sizes.isNotEmpty) {
      final size = route.sizes['${request.resolution}/${request.ratio}'];
      require(size != null, 'ratio');
      body['size'] = size;
    }
    if (route.mixedReferences) {
      body['refers'] = [
        for (final ref in references)
          {'url': ref.url, 'type': ref.role.kind.name},
      ];
    } else {
      for (final ref in references) {
        require(route.mediaFields.containsKey(ref.role), 'references');
      }
      for (final entry in route.mediaFields.entries) {
        final refs = references.where((ref) => ref.role == entry.key).toList();
        if (refs.isEmpty) {
          continue;
        }
        if (entry.key == VideoInputRole.first_frame ||
            entry.key == VideoInputRole.last_frame ||
            (entry.key == VideoInputRole.reference_audio &&
                entry.value == 'audio')) {
          require(refs.length == 1, 'references');
          body[entry.value] = refs.single.url.toString();
        } else {
          body[entry.value] = [
            for (final ref in refs)
              if (route.objectImages &&
                  entry.key == VideoInputRole.reference_image)
                {'image': ref.url}
              else
                ref.url,
          ];
        }
      }
    }
    return body;
  }

  Map<String, dynamic> _prediction(Map<String, dynamic> json) {
    if (json['error'] != null ||
        (json['code'] != null && json['code'] != 200)) {
      throw FormatException('AtlasCloud rejected prediction: $json');
    }
    return json['data'] == null ? json : json['data'] as Map<String, dynamic>;
  }

  @override
  String submissionId(Map<String, dynamic> json) =>
      _prediction(json)['id'] as String;

  @override
  VideoTaskResult decodeResult(Map<String, dynamic> json) {
    final prediction = _prediction(json);
    final status = prediction['status'] as String;
    if (status == 'failed') {
      _log.warning(
        'prediction failed endpoint=$endpoint '
        'response=${safeMediaDiagnostic(prediction, apiKey)}',
      );
    }
    final outputs = prediction['outputs'];
    return videoResult(switch (status) {
      'created' || 'starting' => 'queued',
      'processing' => 'running',
      'completed' => 'succeeded',
      _ => status,
    }, outputs is List && outputs.isNotEmpty ? outputs.first : null);
  }
}

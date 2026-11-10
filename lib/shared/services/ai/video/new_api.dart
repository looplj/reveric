// 职责: 编解码 New API 视频任务并限定成片下载的鉴权边界。
// 关联文件:
//   lib/shared/services/ai/video/client.dart
//   lib/shared/models/video/channels.dart
//   lib/shared/services/ai/new_api.dart
import 'package:http/http.dart' as http;
import '../../../logger/app_logger.dart';
import '../media_diagnostics.dart';
import '../../../models/video/channels.dart';
import '../../../models/video/request.dart';
import '../../../models/video/task_result.dart';
import 'client.dart';

final _log = AppLogger.forModule('NewApiVideo');

class NewApiVideoClient extends VideoClient {
  NewApiVideoClient({
    required super.httpClient,
    required super.providerType,
    required super.endpoint,
    required super.apiKey,
    super.timeout,
  });

  @override
  String get createPath => 'videos';
  @override
  String queryPath(String id) => 'videos/$id';
  @override
  String submissionId(Map<String, dynamic> json) => json['id'] as String;

  @override
  Future<Map<String, dynamic>> prepareSubmission(
    VideoRequest request,
    List<VideoReference> references, {
    bool draft = false,
    String? draftId,
  }) async {
    final body = encodeSubmission(
      request,
      references,
      draft: draft,
      draftId: draftId,
    );
    final catalogId =
        lookupVideoChannelModel(providerType, request.modelId)?.catalogId ??
        request.modelId;
    if (catalogId.startsWith('veo-') && references.isNotEmpty) {
      final ref = references.single;
      final referenceUrl = Uri.parse(ref.url);
      if (referenceUrl.scheme != 'data') {
        if (!{'http', 'https'}.contains(referenceUrl.scheme) ||
            referenceUrl.host.isEmpty ||
            referenceUrl.userInfo.isNotEmpty) {
          throw const VideoException(
            VideoErrorCode.invalid_request,
            field: 'references',
          );
        }
        try {
          final bytes = await (() async {
            final response = await httpClient.send(
              http.Request('GET', referenceUrl),
            );
            if (response.statusCode != 200) {
              await response.stream.drain<void>();
              throw StateError(
                'Reference download HTTP ${response.statusCode}',
              );
            }
            final bytes = <int>[];
            await for (final chunk in response.stream) {
              if (bytes.length + chunk.length > 20 * 1024 * 1024) {
                throw const FormatException('Veo reference exceeds 20 MB');
              }
              bytes.addAll(chunk);
            }
            if (bytes.isEmpty) {
              throw const FormatException('Empty Veo reference');
            }
            return bytes;
          })().timeout(timeout);
          body['images'] = [
            Uri.dataFromBytes(bytes, mimeType: ref.mimeType).toString(),
          ];
        } catch (error) {
          _log.warning(
            'reference GET ${referenceUrl.origin}${referenceUrl.path} '
            'type=${error.runtimeType} message=${safeMediaDiagnostic(error, apiKey)}',
          );
          throw const VideoException(VideoErrorCode.unavailable);
        }
      }
    }
    return body;
  }

  @override
  Map<String, dynamic> encode(
    VideoRequest request,
    List<VideoReference> references,
  ) {
    final catalogId =
        lookupVideoChannelModel(providerType, request.modelId)?.catalogId ??
        request.modelId;
    if (request.prompt.trim().isEmpty || request.durationSeconds <= 0) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'prompt',
      );
    }
    if (catalogId.startsWith('doubao-seedance-')) {
      if (request.promptExtend != null) {
        throw const VideoException(
          VideoErrorCode.invalid_request,
          field: 'prompt_extend',
        );
      }
      return {
        'model': request.modelId,
        'prompt': request.prompt,
        'seconds': request.durationSeconds.toString(),
        'metadata': {
          'content': videoContent(request, references),
          'resolution': request.resolution,
          'ratio': request.ratio,
          if (request.audio != null) 'generate_audio': request.audio,
          if (request.mode == VideoMode.reference &&
              lookupVideoChannelModel(
                    providerType,
                    request.modelId,
                  )?.protocolOptions.supportsOmniReferenceTaskType ==
                  true)
            'omni_reference_task_type': 'reference',
        },
      };
    }
    if ((request.mode != VideoMode.text &&
            request.mode != VideoMode.first_frame) ||
        references.length > 1 ||
        references.any((ref) => ref.role != VideoInputRole.first_frame) ||
        (request.mode == VideoMode.text && references.isNotEmpty) ||
        (request.mode == VideoMode.first_frame && references.length != 1)) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'references',
      );
    }
    if (request.audio != null || request.promptExtend != null) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'audio',
      );
    }
    return {
      'model': request.modelId,
      'prompt': request.prompt,
      'seconds': request.durationSeconds.toString(),
      'size': _size(request.resolution, request.ratio),
      if (references.isNotEmpty)
        if (catalogId.startsWith('veo-'))
          'images': [references.single.url]
        else
          'input_reference': references.single.url,
      if (catalogId.startsWith('veo-'))
        'metadata': {
          'resolution': request.resolution.toLowerCase(),
          'aspectRatio': request.ratio,
        },
    };
  }

  String _size(String resolution, String ratio) {
    final height = switch (resolution.toLowerCase()) {
      '480p' => 480,
      '720p' => 720,
      '1080p' => 1080,
      '4k' => 2160,
      _ => throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'resolution',
      ),
    };
    final parts = ratio.split(':').map(int.tryParse).toList();
    if (parts.length != 2 ||
        parts.any((value) => value == null || value <= 0)) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'ratio',
      );
    }
    final a = parts[0]!, b = parts[1]!;
    final long = (height * (a > b ? a / b : b / a) / 2).round() * 2;
    return a >= b ? '${long}x$height' : '${height}x$long';
  }

  @override
  VideoTaskResult decodeResult(Map<String, dynamic> json) {
    final status = json['status'] as String;
    return videoResult(
      switch (status) {
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

  @override
  Future<http.StreamedResponse> download(
    http.Client transport,
    Uri url,
    VideoSubmission task,
  ) async {
    var target = url;
    final expected = this.url(
      'videos/${Uri.encodeComponent(task.taskId)}/content',
    );
    if (target != expected) {
      throw const VideoException(VideoErrorCode.configuration_required);
    }
    for (var redirects = 0; redirects <= 5; redirects++) {
      final request = http.Request('GET', target)..followRedirects = false;
      if (redirects == 0) {
        request.headers['Authorization'] = 'Bearer $apiKey';
      }
      final response = await transport.send(request);
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
}

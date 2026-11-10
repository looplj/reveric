// 职责: 在收费提交前按渠道登记的能力校验视频模型的模式、规格和参考媒体限制。
// 关联文件:
//   lib/shared/models/video/catalog.dart
//   lib/shared/models/video/request.dart
//   lib/shared/models/video/task_result.dart
//   lib/shared/services/ai/video/client.dart

import 'catalog.dart';
import 'channels.dart';
import 'request.dart';
import 'task_result.dart';

/// 只校验登记了能力的型号；未登记型号原样提交，是否允许使用由业务层决定。
class VideoCapabilities {
  const VideoCapabilities(this.providerType);
  final String providerType;

  static const ratios = videoRatios;

  /// 校验无需读取媒体文件的参数，供编辑器与提交前校验共用。
  void validateParameters(VideoRequest request, List<VideoInputRole> roles) {
    final channel = lookupVideoChannelModel(providerType, request.modelId);
    if (channel == null) {
      _check(request.prompt.trim().isNotEmpty, 'prompt');
      _check(!roles.contains(VideoInputRole.middle_frame), 'references');
      return;
    }
    _validateParameters(channel, request, roles);
  }

  void _validateParameters(
    VideoChannelModel channel,
    VideoRequest request,
    List<VideoInputRole> roles,
  ) {
    final model = channel.capabilities;
    final requiredMode = channel.protocolOptions.requiredMode;
    _check(requiredMode == null || request.mode == requiredMode, 'references');
    _check(request.prompt.trim().isNotEmpty, 'prompt');
    if (model.maxPromptCharacters != null) {
      _check(
        request.prompt.runes.length <= model.maxPromptCharacters!,
        'prompt',
      );
    }
    _check(channel.resolutions.contains(request.resolution), 'resolution');
    _check(
      channel
          .durationsForResolution(request.resolution)
          .contains(request.durationSeconds),
      'duration',
    );
    _check(
      roles
          .where(
            (r) =>
                r == VideoInputRole.first_frame ||
                r == VideoInputRole.last_frame ||
                r == VideoInputRole.middle_frame,
          )
          .every(channel.frameRoles.contains),
      'references',
    );
    final middleCount = roles
        .where((r) => r == VideoInputRole.middle_frame)
        .length;
    _check(middleCount <= model.maxMiddleFrames, 'middle_frame_count');
    _check(channel.ratios.contains(request.ratio), 'ratio');
    _check((request.audio != null) == channel.requiresAudio, 'audio');
    _check(
      (request.promptExtend != null) == channel.requiresPromptExtend,
      'prompt_extend',
    );
    switch (request.mode) {
      case VideoMode.text:
        _check(roles.isEmpty, 'references');
        _check(
          channel.supportsAdaptiveTextRatio || request.ratio != 'adaptive',
          'ratio',
        );
      case VideoMode.first_frame:
        _check(
          roles.length == 1 && roles.single == VideoInputRole.first_frame,
          'references',
        );
        _check(
          !channel.protocolOptions.framesRequireAdaptiveRatio ||
              request.ratio == 'adaptive',
          'ratio',
        );
      case VideoMode.first_last_frame:
        _check(
          (middleCount > 0 &&
                  roles.every(channel.frameRoles.contains) &&
                  roles.where((r) => r == VideoInputRole.first_frame).length ==
                      1 &&
                  roles.where((r) => r == VideoInputRole.last_frame).length <=
                      1) ||
              (roles.length == 2 &&
                  roles.toSet().containsAll({
                    VideoInputRole.first_frame,
                    VideoInputRole.last_frame,
                  })) ||
              (model.supportsLastFrameOnly &&
                  roles.length == 1 &&
                  roles.single == VideoInputRole.last_frame),
          'references',
        );
        _check(
          !channel.protocolOptions.framesRequireAdaptiveRatio ||
              request.ratio == 'adaptive',
          'ratio',
        );
      case VideoMode.reference:
        _check(channel.capabilities.allowsReferenceMode, 'references');
        _check(
          roles.isNotEmpty &&
              !roles.contains(VideoInputRole.first_frame) &&
              !roles.contains(VideoInputRole.last_frame) &&
              !roles.contains(VideoInputRole.middle_frame),
          'references',
        );
        _check(
          model.supportsAudioOnlyReference ||
              roles.any((role) => role.kind != VideoMediaKind.audio),
          'audio_reference',
        );
    }
    for (final kind in VideoMediaKind.values) {
      _check(
        roles.where((role) => role.kind == kind).length <=
            (model.references[kind]?.maxCount ?? 0),
        '${kind.name}_count',
      );
    }
    _check(roles.length <= model.maxReferences, 'reference_count');
  }

  void validate(VideoRequest request, List<VideoReference> references) {
    for (final ref in references) {
      if (providerType == 'purefox_media' && isPurefoxUploadKey(ref.url)) {
        continue;
      }
      if (ref.url.startsWith('data:')) {
        _check(isVideoInlineReference(ref), 'reference_url');
      } else if (ref.url.startsWith('mm_file://')) {
        _check(
          providerType == 'metaso' && ref.url.length > 'mm_file://'.length,
          'reference_url',
        );
      } else {
        final uri = Uri.tryParse(ref.url);
        _check(
          uri != null &&
              {'http', 'https', 'asset'}.contains(uri.scheme) &&
              uri.host.isNotEmpty &&
              uri.userInfo.isEmpty,
          'reference_url',
        );
      }
    }
    validateLocal(request, references);
  }

  /// 上传之前只校验本地媒体属性，不要求已有远端地址。
  void validateLocal(VideoRequest request, List<VideoReference> references) {
    if (providerType == 'purefox_media') {
      for (final ref in references) {
        final limit = switch (ref.role.kind) {
          VideoMediaKind.image => 20,
          VideoMediaKind.audio => 25,
          VideoMediaKind.video => 64,
        };
        _check(
          ref.fileSize > 0 && ref.fileSize <= limit * 1024 * 1024,
          'file_size',
        );
      }

      _check(
        references.fold<int>(0, (sum, ref) => sum + ref.fileSize) <=
            128 * 1024 * 1024,
        'file_size',
      );
    }
    final channel = lookupVideoChannelModel(providerType, request.modelId);
    if (channel == null) {
      validateParameters(request, references.map((r) => r.role).toList());
      return;
    }
    final model = channel.capabilities;
    final roles = references.map((r) => r.role).toList();
    _validateParameters(channel, request, roles);
    final durations = <VideoMediaKind, int>{};
    final sizes = <VideoMediaKind, int>{};
    for (final ref in references) {
      final kind = ref.role.kind;
      final limits = model.references[kind]!;
      sizes[kind] = (sizes[kind] ?? 0) + ref.fileSize;
      final info = ref.mediaInfo;
      final maxBytes = limits.maxSizeMb == null
          ? null
          : limits.maxSizeMb! * 1024 * 1024;
      _check(
        ref.fileSize > 0 &&
            (maxBytes == null ||
                (limits.exclusiveMaxSize
                    ? ref.fileSize < maxBytes
                    : ref.fileSize <= maxBytes)),
        'file_size',
      );
      _check(
        limits.mimeTypes == null || limits.mimeTypes!.contains(ref.mimeType),
        'mime_type',
      );
      if (kind != VideoMediaKind.audio) {
        final width = info.width ?? 0;
        final height = info.height ?? 0;
        _check(
          _within(width, limits.minDimension, limits.maxDimension) &&
              _within(height, limits.minDimension, limits.maxDimension),
          'dimensions',
        );
        _check(
          _within(width / height, limits.minRatio, limits.maxRatio),
          'input_ratio',
        );
        _check(
          _within(width * height, limits.minPixels, limits.maxPixels),
          'dimensions',
        );
      }
      if (kind != VideoMediaKind.image) {
        final duration = info.durationMs ?? 0;
        _check(
          _within(duration, limits.minDurationMs, limits.maxDurationMs),
          'input_duration',
        );
        durations[kind] = (durations[kind] ?? 0) + duration;
        if (kind == VideoMediaKind.video) {
          final fps = info.frameRate ?? 0;
          _check(
            fps.isFinite &&
                _within(fps, limits.minFrameRate, limits.maxFrameRate),
            'frame_rate',
          );
        }
      }
    }
    for (final kind in VideoMediaKind.values) {
      final limits = model.references[kind];
      if (limits == null) {
        continue;
      }
      final maxBytes = limits.maxTotalSizeMb;
      if (maxBytes != null) {
        final total = sizes[kind] ?? 0;
        _check(
          limits.exclusiveMaxSize
              ? total < maxBytes * 1024 * 1024
              : total <= maxBytes * 1024 * 1024,
          '${kind.name}_size',
        );
      }
      _check(
        _within(
          durations[kind] ?? 0,
          durations.containsKey(kind) ? limits.minTotalDurationMs : null,
          limits.maxTotalDurationMs,
        ),
        '${kind.name}_duration',
      );
    }
    if (model.maxInputOutputDurationMs != null &&
        durations.containsKey(VideoMediaKind.video)) {
      _check(
        durations[VideoMediaKind.video]! + request.durationSeconds * 1000 <=
            model.maxInputOutputDurationMs!,
        'total_duration',
      );
    }
  }

  static bool _within(num value, num? min, num? max) =>
      (min == null || value >= min) && (max == null || value <= max);

  static void _check(bool condition, String field) {
    if (!condition) {
      throw VideoException(VideoErrorCode.invalid_request, field: field);
    }
  }
}

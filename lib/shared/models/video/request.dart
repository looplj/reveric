// 职责: 定义可持久化的视频请求、任务输入和即时参考媒体值对象。
// 关联文件:
//   lib/shared/models/video/capabilities.dart
//   lib/shared/services/ai/video/client.dart

enum VideoProtocol {
  ark_video,
  minimax_video_v2,
  wan_video,
  agnes_video,
  openrouter_video,
  new_api_video,
  atlascloud_video,
}

enum VideoMode { text, first_frame, first_last_frame, reference }

enum VideoInputRole {
  first_frame,
  last_frame,
  middle_frame,
  reference_image,
  reference_video,
  reference_audio,
}

enum VideoMediaKind { image, video, audio }

extension VideoInputRoleKind on VideoInputRole {
  VideoMediaKind get kind => switch (this) {
    VideoInputRole.reference_video => VideoMediaKind.video,
    VideoInputRole.reference_audio => VideoMediaKind.audio,
    _ => VideoMediaKind.image,
  };
}

class VideoRequest {
  const VideoRequest({
    required this.modelId,
    required this.prompt,
    required this.mode,
    required this.resolution,
    required this.ratio,
    this.durationSeconds = 5,
    this.audio,
    this.promptExtend,
    this.originalPrompt,
    this.referenceSlots = const [],
  });

  final String? originalPrompt;
  final List<VideoReferenceSlot> referenceSlots;
  final String modelId;
  final String prompt;
  final VideoMode mode;
  final String resolution;
  final String ratio;
  final int durationSeconds;

  /// null means this model does not expose this option.
  final bool? audio;
  final bool? promptExtend;

  VideoRequest withResolution(String value) => VideoRequest(
    modelId: modelId,
    prompt: prompt,
    mode: mode,
    resolution: value,
    ratio: ratio,
    durationSeconds: durationSeconds,
    audio: audio,
    promptExtend: promptExtend,
    originalPrompt: originalPrompt,
    referenceSlots: List.unmodifiable(referenceSlots),
  );

  VideoRequest withPrompt(String value) => VideoRequest(
    modelId: modelId,
    prompt: value,
    mode: mode,
    resolution: resolution,
    ratio: ratio,
    durationSeconds: durationSeconds,
    audio: audio,
    promptExtend: promptExtend,
    originalPrompt: originalPrompt,
    referenceSlots: List.unmodifiable(referenceSlots),
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'model_id': modelId,
    if (originalPrompt != null) 'original_prompt': originalPrompt,
    if (referenceSlots.isNotEmpty)
      'reference_slots': referenceSlots.map((s) => s.toJson()).toList(),
    'prompt': prompt,
    'mode': mode.name,
    'resolution': resolution,
    'ratio': ratio,
    'duration_seconds': durationSeconds,
    if (audio != null) 'audio': audio,
    if (promptExtend != null) 'prompt_extend': promptExtend,
  };

  factory VideoRequest.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported video request version');
    }
    return VideoRequest(
      modelId: json['model_id'] as String,
      originalPrompt: json['original_prompt'] as String?,
      referenceSlots: (json['reference_slots'] as List? ?? [])
          .map((s) => VideoReferenceSlot.fromJson(s as Map<String, dynamic>))
          .toList(),
      prompt: json['prompt'] as String,
      mode: VideoMode.values.byName(json['mode'] as String),
      resolution: json['resolution'] as String,
      ratio: json['ratio'] as String,
      durationSeconds: json['duration_seconds'] as int,
      audio: json['audio'] as bool?,
      promptExtend: json['prompt_extend'] as bool?,
    );
  }
}

class VideoInput {
  const VideoInput({
    required this.role,
    required this.assetId,
    required this.mimeType,
  });
  final VideoInputRole role;

  /// 参考素材；提交时从资产解析文件。
  final String assetId;
  final String mimeType;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'role': role.name,
    'asset_id': assetId,
    'mime_type': mimeType,
  };

  factory VideoInput.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported video input version');
    }
    return VideoInput(
      role: VideoInputRole.values.byName(json['role'] as String),
      assetId: json['asset_id'] as String,
      mimeType: json['mime_type'] as String,
    );
  }
}

/// Locally probed properties of the reference file.
class VideoMediaInfo {
  const VideoMediaInfo({
    this.width,
    this.height,
    this.durationMs,
    this.frameRate,
  });
  final int? width;
  final int? height;
  final int? durationMs;
  final double? frameRate;

  factory VideoMediaInfo.fromJson(Map<String, dynamic> json) => VideoMediaInfo(
    width: json['width'] as int?,
    height: json['height'] as int?,
    durationMs: json['duration_ms'] as int?,
    frameRate: (json['frame_rate'] as num?)?.toDouble(),
  );
}

/// Temporary read URLs deliberately have no persistence serializer.
class VideoReference {
  const VideoReference({
    required this.role,
    required this.url,
    required this.mimeType,
    required this.fileSize,
    required this.mediaInfo,
  });
  final VideoInputRole role;
  final Uri url;
  final String mimeType;
  final int fileSize;
  final VideoMediaInfo mediaInfo;
}

class VideoReferenceSlot {
  const VideoReferenceSlot(
    this.assetId,
    this.role,
    this.slot, {
    this.clipId,
    this.inputId,
  });
  final String assetId;
  final VideoInputRole role;
  final String slot;
  final String? clipId;
  final String? inputId;
  Map<String, dynamic> toJson() => {
    'asset_id': assetId,
    'role': role.name,
    'slot': slot,
    if (clipId != null) 'clip_id': clipId,
    if (inputId != null) 'input_id': inputId,
  };
  factory VideoReferenceSlot.fromJson(Map<String, dynamic> json) =>
      VideoReferenceSlot(
        json['asset_id'] as String,
        VideoInputRole.values.byName(json['role'] as String),
        json['slot'] as String,
        clipId: json['clip_id'] as String?,
        inputId: json['input_id'] as String?,
      );
}

// 职责: 合并音频请求默认值、保存不可变请求快照并校验模型与渠道能力。
// 关联文件:
//   lib/shared/models/audio/catalog.dart
//   lib/shared/models/audio/exception.dart
//   lib/shared/models/audio/channels.dart
//   lib/shared/services/production/audio_generate_orchestrator.dart
import '../ai_provider.dart';
import 'exception.dart';
import 'catalog.dart';
import 'channels.dart';
export 'config.dart' show AudioRequestDefaults, ConfigValue;

class AudioReference {
  const AudioReference({
    required this.assetId,
    required this.kind,
    required this.mimeType,
    required this.bytes,
    this.durationMs,
    this.clipId,
    this.inputId,
  });
  final String assetId, kind, mimeType;
  final int bytes;
  final int? durationMs;
  final String? clipId;
  final String? inputId;
  Map<String, dynamic> toJson() => {
    'asset_id': assetId,
    'kind': kind,
    'mime_type': mimeType,
    'bytes': bytes,
    'duration_ms': durationMs,
    'clip_id': clipId,
    'input_id': inputId,
  };
  factory AudioReference.fromJson(Map<String, dynamic> json) => AudioReference(
    assetId: json['asset_id'] as String,
    kind: json['kind'] as String,
    mimeType: json['mime_type'] as String,
    bytes: json['bytes'] as int,
    durationMs: json['duration_ms'] as int?,
    clipId: json['clip_id'] as String?,
    inputId: json['input_id'] as String?,
  );
}

class AudioRequest {
  AudioRequest({
    required this.providerId,
    required this.modelId,
    required this.prompt,
    required this.originalPrompt,
    this.parameters = const AudioRequestDefaults(),
    List<AudioReference> references = const [],
  }) : references = List.unmodifiable(references);
  final String providerId, modelId, prompt, originalPrompt;
  final List<AudioReference> references;
  final AudioRequestDefaults parameters;

  AudioRequest withDefaults(AudioRequestDefaults defaults) => AudioRequest(
    providerId: providerId,
    modelId: modelId,
    prompt: prompt,
    originalPrompt: originalPrompt,
    references: references,
    parameters: defaults.merge(parameters),
  );
  Map<String, dynamic> toJson() => {
    'provider_id': providerId,
    'model_id': modelId,
    'prompt': prompt,
    'original_prompt': originalPrompt,
    'parameters': parameters.toJson(),
    'references': references.map((r) => r.toJson()).toList(),
  };
  factory AudioRequest.fromJson(Map<String, dynamic> json) => AudioRequest(
    providerId: json['provider_id'] as String,
    modelId: json['model_id'] as String,
    prompt: json['prompt'] as String,
    originalPrompt: json['original_prompt'] as String,
    parameters: AudioRequestDefaults.fromJson(
      json['parameters'] as Map<String, dynamic>,
    ),
    references: (json['references'] as List)
        .map((v) => AudioReference.fromJson(v as Map<String, dynamic>))
        .toList(),
  );
}

class AudioCapabilities {
  const AudioCapabilities(this.modelId, {this.providerType});
  factory AudioCapabilities.forProvider(String modelId, AiProvider provider) {
    if (!supports(provider)) {
      throw const AudioException('invalid_config');
    }
    return AudioCapabilities(modelId, providerType: provider.type);
  }
  final String modelId;

  /// 为 null 时只按目录型号校验，不叠加渠道覆盖。
  final String? providerType;
  AudioModelCapabilities get model {
    if (providerType != null) {
      return lookupAudioChannelModel(providerType!, modelId)?.capabilities ??
          (throw const AudioException('invalid_config'));
    }
    return lookupAudioModel(modelId)?.capabilities ??
        (throw const AudioException('invalid_config'));
  }

  static bool supports(AiProvider provider) =>
      provider.typeConfig.audioProtocol != null;
  bool supportsProvider(AiProvider provider) =>
      lookupAudioChannelModel(provider.type, modelId) != null;

  void validateSelection(Iterable<String> kinds) {
    final counts = <String, int>{};
    for (final kind in kinds) {
      counts.update(kind, (n) => n + 1, ifAbsent: () => 1);
    }
    if (!model.allowsMixedReferences && counts.length > 1) {
      throw const AudioException('audio_reference_mixed');
    }
    if (counts.entries.any(
      (e) => e.value > (model.references[e.key]?.maxCount ?? 0),
    )) {
      throw const AudioException('audio_reference_count');
    }
  }

  bool accepts(Iterable<String> kinds) {
    try {
      validateSelection(kinds);
      return true;
    } on AudioException {
      return false;
    }
  }

  void validateReference(AudioReference ref) {
    final limit = model.references[ref.kind];
    if (limit == null || !limit.mimeTypes.contains(ref.mimeType)) {
      throw const AudioException('audio_reference_format');
    }
    if (ref.bytes <= 0 || ref.bytes > limit.maxBytes) {
      throw const AudioException('audio_reference_size');
    }
    if (limit.maxDurationMs != null &&
        (ref.durationMs == null ||
            ref.durationMs! <= 0 ||
            ref.durationMs! > limit.maxDurationMs!)) {
      throw const AudioException('audio_reference_duration');
    }
  }

  void validate(AudioRequest request) {
    if (request.modelId != modelId ||
        request.prompt.trim().isEmpty ||
        request.prompt.runes.length > model.maxPromptCharacters) {
      throw const AudioException('audio_prompt_length');
    }
    if (model.requiresVoice &&
        request.references.isEmpty &&
        (request.parameters.voice?.trim().isEmpty ?? true)) {
      throw const AudioException('audio_voice_required');
    }
    if (model.requiresInstructions &&
        (request.parameters.instructions?.trim().isEmpty ?? true)) {
      throw const AudioException('invalid_config');
    }
    if ((request.parameters.instructions?.isNotEmpty ?? false) &&
        !model.supportsInstructions) {
      throw const AudioException('invalid_config');
    }
    if ((request.parameters.voice?.isNotEmpty ?? false) &&
        request.references.isNotEmpty) {
      throw const AudioException('invalid_reference');
    }
    validateSelection(request.references.map((r) => r.kind));
    for (final ref in request.references) {
      validateReference(ref);
    }
    if (!model.supportsAudioReferencePlaceholders) {
      return;
    }
    for (final match in RegExp(
      r'@(?:Audio|音频)(\d+)',
    ).allMatches(request.prompt)) {
      final ordinal = int.parse(match.group(1)!);
      if (ordinal < 1 ||
          ordinal > request.references.length ||
          request.references[ordinal - 1].kind != 'audio') {
        throw const AudioException('invalid_reference');
      }
    }
    if (providerType != null &&
        lookupAudioChannelModel(
              providerType!,
              modelId,
            )?.protocolOptions.requiresAllAudioReferencesMentioned ==
            true &&
        request.references.length > 1) {
      for (var i = 1; i <= request.references.length; i++) {
        if (!RegExp('@Audio$i(?![0-9])').hasMatch(request.prompt)) {
          throw const AudioException('invalid_reference');
        }
      }
    }
  }
}

/// 合并渠道登记的请求默认值并校验能力；型号未登记时报 invalid_config。
AudioRequest resolveAudioRequest(String providerType, AudioRequest request) {
  final channel = lookupAudioChannelModel(providerType, request.modelId);
  if (channel == null) {
    throw const AudioException('invalid_config');
  }
  final resolved = request.withDefaults(channel.requestDefaults);
  AudioCapabilities(
    request.modelId,
    providerType: providerType,
  ).validate(resolved);
  if (resolved.parameters.responseFormat == null ||
      (resolved.parameters.sampleRate != null &&
          resolved.parameters.sampleRate! <= 0) ||
      (resolved.parameters.bitrate != null &&
          resolved.parameters.bitrate! <= 0)) {
    throw const AudioException('invalid_config');
  }
  return resolved;
}

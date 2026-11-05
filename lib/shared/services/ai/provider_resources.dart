// 职责: 将实际配置的供应商及聊天、媒体模型投影为不含凭据的 Run 查询结果。
// 关联文件:
//   lib/shared/models/ai_provider.dart
//   lib/shared/models/production/image_request.dart
//   lib/shared/models/video/channels.dart
//   lib/shared/models/audio/channels.dart
//   lib/shared/services/ai/providers_run_command_handler.dart
import '../../models/ai_provider.dart';
import '../../models/image/channels.dart';
import '../../models/production/image_request.dart';
import '../../models/video/channels.dart';
import '../../models/video/request.dart';
import '../../models/audio/channels.dart';
import 'assets/certification.dart';

Map<String, dynamic> providerResource(AiProvider provider) => {
  'id': provider.id,
  'name': provider.name,
  'type': provider.type,
  'enabled': provider.enabled,
  'configured': provider.hasCredentialConfiguration && provider.hasBaseUrl,
  'asset_certification': providerSupportsAssetCertification(provider),
};

List<String> configuredProviderModels(AiProvider provider, String kind) {
  final models = switch (kind) {
    'chat' => provider.models,
    'image' => provider.imageModels,
    'video' => provider.videoModels,
    'audio' => provider.audioModels,
    _ => const <String>[],
  };
  return models
      .map((id) => id.trim())
      .where((id) => id.isNotEmpty)
      .toSet()
      .toList();
}

Map<String, dynamic> providerModelResource(
  AiProvider provider,
  String kind,
  String model,
) {
  final capabilities = switch (kind) {
    'image' => _image(provider, model),
    'video' => _video(provider, model),
    'audio' => _audio(provider, model),
    _ => null,
  };
  final modelKind = AiModelKind.values.byName(kind);
  final adapterSupportsModel = kind == 'chat'
      ? provider.supportsModelKind(AiModelKind.chat)
      : kind == 'image'
      ? ProductionImageCapabilities(provider, model).isSupported
      : capabilities != null;
  final reason = !provider.enabled
      ? 'provider_disabled'
      : !provider.isPlatformSupported
      ? 'unsupported_platform'
      : !provider.hasCredentialConfiguration || !provider.hasBaseUrl
      ? 'configuration_required'
      : !provider.supportsModel(model, kind: modelKind)
      ? 'model_disabled_or_unsupported'
      : !adapterSupportsModel
      ? 'model_unsupported_by_adapter'
      : null;
  return {
    'id': model,
    'provider_id': provider.id,
    'kind': kind,
    'available': reason == null,
    'capabilities_known': capabilities != null,
    'unavailable_reason': reason,
    if (capabilities == null)
      'capabilities_reason':
          'No verified model and adapter capability mapping.',
    'capabilities': capabilities?['capabilities'],
    'defaults': capabilities?['defaults'],
    'availability_scope':
        'local_configuration; remote access and quota are not probed',
  };
}

Map<String, dynamic>? _image(AiProvider provider, String model) {
  final effective = ProductionImageCapabilities(
    provider,
    model,
  ).verifiedCapabilities;
  if (effective == null) {
    return null;
  }
  final channel = lookupImageChannelModel(provider.type, model);
  final defaults = channel?.requestDefaults;
  return {
    'capabilities': {
      'modes': [
        if (effective.minReferences == 0) 'text',
        if (effective.maxReferences > 0) 'reference',
      ],
      'ratios': effective.ratios.toList(),
      'resolutions': effective.resolutions.toList(),
      'sizes': effective.sizes,
      'min_references': effective.minReferences,
      'max_references': effective.maxReferences,
      'min_pixels': effective.minPixels,
      'max_pixels': effective.maxPixels,
      'max_edit_pixels': effective.maxEditPixels,
      'max_aspect_ratio': effective.maxAspectRatio,
      'complexity': effective.complexityLevels.toList(),
    },
    // Only channel defaults actually consumed by the adapter are advertised.
    'defaults': {
      if (defaults != null) ...{
        'size': defaults.size,
        'response_format': defaults.responseFormat,
        'output_format': defaults.outputFormat,
        'quality': defaults.quality,
        'watermark': defaults.watermark,
        'prompt_extend': defaults.promptExtend,
        'prompt_optimization': defaults.promptOptimization,
        'complexity': defaults.complexity,
      },
    },
  };
}

Map<String, dynamic>? _video(AiProvider provider, String model) {
  final channel = lookupVideoChannelModel(provider.type, model);
  if (channel == null) {
    return null;
  }
  final caps = channel.capabilities;
  final kinds = caps.references.keys.toSet();
  return {
    'capabilities': {
      'modes': [
        if (channel.protocolOptions.requiredMode == null ||
            channel.protocolOptions.requiredMode == VideoMode.text)
          'text',
        if (caps.frameRoles.contains(VideoInputRole.first_frame)) 'first_frame',
        if (caps.frameRoles.contains(VideoInputRole.first_frame) &&
            caps.frameRoles.contains(VideoInputRole.last_frame))
          'first_last_frame',
        if (caps.allowsReferenceMode && kinds.isNotEmpty) 'reference',
      ],
      'ratios': channel.ratios.toList(),
      'resolutions': channel.resolutions.toList(),
      'durations': channel.durations.toList(),
      if (channel.maxDurationByResolution.isNotEmpty)
        'max_duration_by_resolution': channel.maxDurationByResolution,
      'supports_draft': channel.protocolOptions.supportsDraft,
      if (channel.protocolOptions.supportsDraft)
        'draft': {
          'resolution': '480p',
          'completion_resolution': '1080p',
          'validity_days': 7,
          'output_formats': ['mp4'],
        },
      'reference_roles': [
        ...caps.frameRoles.map((role) => role.name),
        if (caps.allowsReferenceMode)
          ...kinds.map((kind) => 'reference_${kind.name}'),
      ],
      'max_middle_frames': caps.maxMiddleFrames,
      'max_references': caps.maxReferences,
      'max_prompt_characters': caps.maxPromptCharacters,
      'supports_audio_only_reference': caps.supportsAudioOnlyReference,
      'supports_last_frame_only': caps.supportsLastFrameOnly,
      'supports_adaptive_text_ratio': channel.supportsAdaptiveTextRatio,
      'frames_require_adaptive_ratio':
          channel.protocolOptions.framesRequireAdaptiveRatio,
      'requires_audio': channel.requiresAudio,
      'requires_prompt_extend': channel.requiresPromptExtend,
      'max_input_output_duration_ms': caps.maxInputOutputDurationMs,
      'references': {
        for (final entry in caps.references.entries)
          if (kinds.contains(entry.key))
            entry.key.name: {
              'max_count': entry.value.maxCount,
              'mime_types': entry.value.mimeTypes?.toList(),
              'max_size_mb': entry.value.maxSizeMb,
              'exclusive_max_size': entry.value.exclusiveMaxSize,
              'min_dimension': entry.value.minDimension,
              'max_dimension': entry.value.maxDimension,
              'min_ratio': entry.value.minRatio,
              'max_ratio': entry.value.maxRatio,
              'min_duration_ms': entry.value.minDurationMs,
              'max_duration_ms': entry.value.maxDurationMs,
              'min_total_duration_ms': entry.value.minTotalDurationMs,
              'max_total_duration_ms': entry.value.maxTotalDurationMs,
              'max_total_size_mb': entry.value.maxTotalSizeMb,
              'min_frame_rate': entry.value.minFrameRate,
              'max_frame_rate': entry.value.maxFrameRate,
              'min_pixels': entry.value.minPixels,
              'max_pixels': entry.value.maxPixels,
            },
      },
    },
    'defaults': {
      'audio': channel.requestDefaults.audio,
      'prompt_extend': channel.requestDefaults.promptExtend,
    },
  };
}

Map<String, dynamic>? _audio(AiProvider provider, String model) {
  final channel = lookupAudioChannelModel(provider.type, model);
  if (channel == null) {
    return null;
  }
  final caps = channel.capabilities;
  return {
    'capabilities': {
      'input_types': ['text', ...caps.references.keys],
      'max_prompt_characters': caps.maxPromptCharacters,
      'max_output_duration_ms': caps.maxOutputDurationMs,
      'allows_mixed_references': caps.allowsMixedReferences,
      'supports_audio_reference_placeholders':
          caps.supportsAudioReferencePlaceholders,
      'requires_all_audio_references_mentioned':
          channel.protocolOptions.requiresAllAudioReferencesMentioned,
      'output_formats': switch (provider.typeConfig.audioProtocol!) {
        AudioProtocol.seed_audio || AudioProtocol.qwen_tts => ['wav'],
        AudioProtocol.atlascloud_audio => [
          channel.requestDefaults.responseFormat!,
        ],
        AudioProtocol.minimax_music => ['mp3'],
        AudioProtocol.openrouter_speech => ['pcm', 'mp3'],
        AudioProtocol.new_api_speech =>
          channel.catalogId.contains('gemini-') ? ['wav'] : ['mp3', 'wav'],
      },
      'references': {
        for (final entry in caps.references.entries)
          entry.key: {
            'max_count': entry.value.maxCount,
            'mime_types': entry.value.mimeTypes.toList(),
            'max_bytes': entry.value.maxBytes,
            'max_duration_ms': entry.value.maxDurationMs,
          },
      },
    },
    'defaults': channel.requestDefaults.toJson(),
  };
}

// 职责: 组合音频渠道的型号映射、能力覆盖、请求默认值与协议要求，并按 provider 类型查找渠道型号。
// 关联文件:
//   lib/shared/models/audio/catalog.dart
//   lib/shared/models/audio/config.dart
//   lib/shared/models/audio/request.dart
//   lib/shared/models/ai_provider.dart

import '../ai_provider.dart' show ModelIdSource, aiProviderTypeConfigFor;
import 'catalog.dart';
import 'speech.dart';
import 'atlascloud.dart';

enum AudioProtocol {
  seed_audio,
  minimax_music,
  openrouter_speech,
  new_api_speech,
  qwen_tts,
  atlascloud_audio,
}

class AudioProtocolOptions {
  const AudioProtocolOptions({
    this.requiresAllAudioReferencesMentioned = false,
    this.qwenUsesSpeechSynthesizer = false,
  });
  final bool requiresAllAudioReferencesMentioned;
  final bool qwenUsesSpeechSynthesizer;
}

class AudioChannelModel {
  const AudioChannelModel({
    required this.catalogId,
    this._capabilities = const AudioModelCapabilities(),
    this._requestDefaults = const AudioRequestDefaults(),
    this.protocolOptions = const AudioProtocolOptions(),
  });
  final String catalogId;
  final AudioModelCapabilities _capabilities;
  final AudioRequestDefaults _requestDefaults;
  final AudioProtocolOptions protocolOptions;
  AudioModelCatalogEntry get model => audioModelsCatalog[catalogId]!;
  AudioModelCapabilities get capabilities =>
      model.capabilities.merge(_capabilities);
  AudioRequestDefaults get requestDefaults =>
      model.requestDefaults.merge(_requestDefaults);
}

final audioChannelModels = <AudioProtocol, Map<String, AudioChannelModel>>{
  AudioProtocol.new_api_speech: {
    for (final id in ['tts-1', 'tts-1-hd', 'gpt-4o-mini-tts'])
      id: AudioChannelModel(catalogId: id),
    for (final id in [
      'gemini-2.5-flash-tts',
      'gemini-2.5-pro-tts',
      'gemini-3.1-flash-tts',
      'gemini-3.8-flash-tts',
    ])
      id: AudioChannelModel(
        catalogId: 'google/$id',
        requestDefaults: AudioRequestDefaults(
          voice: ConfigValue('Kore'),
          responseFormat: ConfigValue('wav'),
        ),
      ),
  },
  AudioProtocol.atlascloud_audio: {
    'bytedance/seed-audio-1.0': AudioChannelModel(catalogId: 'seed-audio-1.0'),
    'minimax/music-3.0': AudioChannelModel(catalogId: 'music-3.0'),
    'minimax/music-2.6': AudioChannelModel(catalogId: 'music-2.6'),
    for (final id in atlasCloudSpeechModels.keys)
      id: AudioChannelModel(catalogId: id),
  },
  AudioProtocol.qwen_tts: {
    for (final id in [
      'qwen-audio-3.1-tts-plus',
      'qwen-audio-3.0-tts-flash',
      'qwen-audio-3.1-tts-next',
    ])
      id: AudioChannelModel(
        catalogId: id,
        protocolOptions: AudioProtocolOptions(qwenUsesSpeechSynthesizer: true),
      ),
  },
  AudioProtocol.seed_audio: {
    'seed-audio-1.0': AudioChannelModel(catalogId: 'seed-audio-1.0'),
  },
  AudioProtocol.minimax_music: {
    'speech-2.8-hd': const AudioChannelModel(
      catalogId: 'minimax/speech-2.8-hd',
      requestDefaults: AudioRequestDefaults(
        sampleRate: ConfigValue(32000),
        bitrate: ConfigValue(128000),
      ),
    ),
    'music-3.0': AudioChannelModel(catalogId: 'music-3.0'),
    'music-2.6': AudioChannelModel(catalogId: 'music-2.6'),
  },
  AudioProtocol.openrouter_speech: {
    for (final id in speechModels.keys)
      id: AudioChannelModel(
        catalogId: id,
        requestDefaults: id == 'heygen/heygen-voice-1-turbo:free'
            ? const AudioRequestDefaults(responseFormat: ConfigValue('pcm'))
            : const AudioRequestDefaults(),
      ),
    'bytedance-seed/seed-audio-1-0': AudioChannelModel(
      catalogId: 'seed-audio-1.0',
      capabilities: AudioModelCapabilities(
        references: {
          'audio': AudioReferenceLimits(
            mimeTypes: {'audio/wav', 'audio/x-wav', 'audio/mpeg', 'audio/ogg'},
          ),
        },
      ),
      // PCM rate and channels come from response headers, not a request option.
      requestDefaults: AudioRequestDefaults(
        responseFormat: ConfigValue('pcm'),
        sampleRate: ConfigValue(null),
      ),
      protocolOptions: AudioProtocolOptions(
        requiresAllAudioReferencesMentioned: true,
      ),
    ),
  },
};

/// 按 provider 类型查找渠道型号：先精确匹配渠道 ID；可接中转站的渠道再从 ID
/// 中识别目录型号。找不到时返回 null，是否允许使用由业务层决定。
AudioChannelModel? lookupAudioChannelModel(
  String providerType,
  String? modelId,
) {
  final config = aiProviderTypeConfigFor(providerType);
  final models = audioChannelModels[config?.audioProtocol];
  if (config == null || models == null) {
    return null;
  }
  final exact = models[modelId?.trim()];
  if (exact != null || config.modelIdSource == ModelIdSource.registered) {
    return exact;
  }
  final catalogId = recognizeAudioModel(modelId);
  return models.values
      .where((channel) => channel.catalogId == catalogId)
      .firstOrNull;
}

List<String> audioModelsForProvider(String providerType) =>
    audioChannelModels[aiProviderTypeConfigFor(providerType)?.audioProtocol]
        ?.keys
        .toList(growable: false) ??
    const [];

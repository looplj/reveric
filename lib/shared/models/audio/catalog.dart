// 职责: 维护独立于渠道的音频型号、能力与共用请求默认值。
// 关联文件:
//   lib/shared/models/audio/config.dart
//   lib/shared/models/audio/channels.dart

import '../model_config.dart' show ModelIdRecognizer;
import 'config.dart';
import 'speech.dart';
import 'atlascloud.dart';
export 'config.dart';

class AudioModelCatalogEntry {
  const AudioModelCatalogEntry({
    required this.capabilities,
    required this.requestDefaults,
    this.aliases = const {},
  });
  final AudioModelCapabilities capabilities;
  final AudioRequestDefaults requestDefaults;
  final Set<String> aliases;
}

const _minimaxMusicModel = AudioModelCatalogEntry(
  capabilities: AudioModelCapabilities(maxPromptCharacters: 2000),
  requestDefaults: AudioRequestDefaults(
    responseFormat: ConfigValue('mp3'),
    sampleRate: ConfigValue(44100),
    bitrate: ConfigValue(256000),
  ),
);

// https://docs.byteplus.com/en/docs/byteplusvoice/seedaudio-01
// https://platform.minimax.io/docs/api-reference/music-generation
final audioModelsCatalog = <String, AudioModelCatalogEntry>{
  // https://platform.moss.cn/docs/reference/speech/
  for (final id in ['moss-tts-1.5-flash', 'moss-tts-1.0-pro'])
    id: AudioModelCatalogEntry(
      capabilities: AudioModelCapabilities(
        speech: true,
        maxPromptCharacters: 4000,
        voices: ['94aa4989-c7e9-5007-ae42-ab401823e6c9'],
      ),
      requestDefaults: AudioRequestDefaults(responseFormat: ConfigValue('mp3')),
    ),
  'moss-voice-generator-1.0': AudioModelCatalogEntry(
    capabilities: AudioModelCapabilities(
      speech: true,
      requiresVoice: false,
      requiresInstructions: true,
      supportsInstructions: true,
      maxPromptCharacters: 4000,
    ),
    requestDefaults: AudioRequestDefaults(responseFormat: ConfigValue('mp3')),
  ),
  for (final id in ['tts-1', 'tts-1-hd', 'gpt-4o-mini-tts'])
    id: AudioModelCatalogEntry(
      capabilities: AudioModelCapabilities(
        speech: true,
        maxPromptCharacters: 4000,
        supportsInstructions: id == 'gpt-4o-mini-tts',
        voices: ['alloy', 'echo', 'fable', 'onyx', 'nova', 'shimmer'],
      ),
      requestDefaults: AudioRequestDefaults(
        voice: ConfigValue('alloy'),
        responseFormat: ConfigValue('mp3'),
      ),
    ),
  // https://platform.qianwenai.com/docs/api-reference/speech-synthesis/qwen-audio-tts/python-sdk
  // https://platform.qianwenai.com/docs/developer-guides/speech/voice-list/qwen-audio-tts
  'qwen-audio-3.1-tts-plus': AudioModelCatalogEntry(
    capabilities: AudioModelCapabilities(
      speech: true,
      supportsInstructions: true,
      maxPromptCharacters: 20000,
      voices: [
        'longanhuan_v3.1',
        'longanlingxin_v3.1',
        'xunanchuan_v3.1',
        'longanfengyue_v3.1',
      ],
    ),
    requestDefaults: AudioRequestDefaults(
      voice: ConfigValue('longanhuan_v3.1'),
      responseFormat: ConfigValue('wav'),
      sampleRate: ConfigValue(24000),
    ),
  ),
  'qwen-audio-3.0-tts-flash': AudioModelCatalogEntry(
    capabilities: AudioModelCapabilities(
      speech: true,
      supportsInstructions: true,
      maxPromptCharacters: 20000,
      voices: [
        'longanhuan_v3.6',
        'longanfengyue',
        'longanyuanfei',
        'longanlingxi',
        'longanxiaoxin',
        'longjielidou_v3.6',
        'longpaopao_v3.6',
        'longhuohuo_v3.6',
        'longchuanshu_v3.6',
        'loongmary',
        'loongeva_v3.6',
        'loongjohn',
      ],
    ),
    requestDefaults: AudioRequestDefaults(
      voice: ConfigValue('longanhuan_v3.6'),
      responseFormat: ConfigValue('wav'),
      sampleRate: ConfigValue(24000),
    ),
  ),
  // https://platform.qianwenai.com/docs/api-reference/audio-generation
  'qwen-audio-3.1-tts-next': AudioModelCatalogEntry(
    capabilities: AudioModelCapabilities(
      maxPromptCharacters: 3000,
      maxOutputDurationMs: ConfigValue(240000),
      supportsAudioReferencePlaceholders: true,
      references: {
        'audio': AudioReferenceLimits(
          maxCount: 3,
          maxBytes: 10 * 1024 * 1024,
          maxDurationMs: ConfigValue(30000),
          mimeTypes: {'audio/wav', 'audio/x-wav', 'audio/mpeg', 'audio/ogg'},
        ),
      },
    ),
    requestDefaults: AudioRequestDefaults(
      responseFormat: ConfigValue('wav'),
      sampleRate: ConfigValue(48000),
    ),
  ),
  'seed-audio-1.0': AudioModelCatalogEntry(
    capabilities: AudioModelCapabilities(
      maxPromptCharacters: 3000,
      maxOutputDurationMs: ConfigValue(120000),
      supportsAudioReferencePlaceholders: true,
      references: {
        'audio': AudioReferenceLimits(
          maxCount: 3,
          maxBytes: 10 * 1024 * 1024,
          maxDurationMs: ConfigValue(30000),
          mimeTypes: {
            'audio/wav',
            'audio/x-wav',
            'audio/mpeg',
            'audio/pcm',
            'audio/ogg',
          },
        ),
        'image': AudioReferenceLimits(
          maxCount: 1,
          maxBytes: 10 * 1024 * 1024,
          mimeTypes: {'image/jpeg', 'image/png', 'image/webp'},
        ),
      },
    ),
    requestDefaults: AudioRequestDefaults(
      responseFormat: ConfigValue('wav'),
      sampleRate: ConfigValue(24000),
    ),
  ),
  for (final entry in speechModels.entries)
    entry.key: AudioModelCatalogEntry(
      capabilities: entry.value,
      requestDefaults: AudioRequestDefaults(responseFormat: ConfigValue('mp3')),
    ),
  for (final entry in atlasCloudSpeechModels.entries)
    entry.key: AudioModelCatalogEntry(
      capabilities: entry.value,
      requestDefaults: AudioRequestDefaults(
        voice: ConfigValue(entry.value.voices.first),
        responseFormat: ConfigValue(
          entry.key.startsWith('google/') ? 'wav' : 'mp3',
        ),
      ),
    ),
  'music-3.0': _minimaxMusicModel,
  'music-2.6': _minimaxMusicModel,
};

final _audioModelRecognizer = ModelIdRecognizer({
  for (final entry in audioModelsCatalog.entries)
    entry.key: entry.value.aliases,
});

/// 渠道型号 ID 对应的目录 ID；规则见 [ModelIdRecognizer]。
String? recognizeAudioModel(String? modelId) =>
    _audioModelRecognizer.recognize(modelId);

AudioModelCatalogEntry? lookupAudioModel(String? modelId) =>
    audioModelsCatalog[recognizeAudioModel(modelId)];

// 职责: 登记支持分段时间戳的转写渠道、模型和上传边界。
// 关联文件:
//   lib/shared/services/ai/transcription/client.dart
//   lib/shared/models/ai_provider_config.dart

enum TranscriptionProtocol {
  openai_multipart,
  dashscope_file,
  volcengine_standard,
  atlascloud,
}

class TranscriptionModel {
  const TranscriptionModel(
    this.id,
    this.protocol,
    this.maxBytes,
    this.formats, {
    this.maxDuration,
  });

  final String id;
  final TranscriptionProtocol protocol;
  final int maxBytes;
  final Set<String> formats;
  final Duration? maxDuration;

  bool get requiresSourceUrl =>
      protocol == TranscriptionProtocol.dashscope_file ||
      protocol == TranscriptionProtocol.volcengine_standard;
}

const _asrChannelModels = <String, List<TranscriptionModel>>{
  'qwen': [
    TranscriptionModel(
      'qwen3-asr-flash-filetrans',
      TranscriptionProtocol.dashscope_file,
      100 * 1000 * 1000,
      {'mp3', 'wav', 'm4a'},
    ),
  ],
  'doubao_audio': [
    TranscriptionModel(
      'volc.seedasr.auc',
      TranscriptionProtocol.volcengine_standard,
      512 * 1000 * 1000 - 1,
      {'mp3', 'wav'},
    ),
    TranscriptionModel(
      'volc.bigasr.auc',
      TranscriptionProtocol.volcengine_standard,
      512 * 1000 * 1000 - 1,
      {'mp3', 'wav'},
    ),
  ],
  // Atlas accepts inline audio. Bound the raw input before allocating Base64 and JSON.
  'atlascloud': [
    TranscriptionModel(
      'bytedance/seed-asr-2.0',
      TranscriptionProtocol.atlascloud,
      25 * 1000 * 1000,
      {'mp3', 'wav', 'ogg'},
    ),
  ],
};

bool supportsAsrForProvider(String type) =>
    type == 'openrouter' || _asrChannelModels.containsKey(type);

List<String> asrModelsForProvider(String type) => [
  for (final model in _asrChannelModels[type] ?? const <TranscriptionModel>[])
    model.id,
];

TranscriptionModel? lookupAsrModel(String type, String id) =>
    type == 'openrouter'
    ? TranscriptionModel(
        id,
        TranscriptionProtocol.openai_multipart,
        25 * 1000 * 1000,
        const {'mp3', 'wav', 'm4a'},
      )
    : _asrChannelModels[type]?.where((model) => model.id == id).firstOrNull;

// 职责: 将语音文本或声音指令提交给 MOSS，并解析同步音频下载回执。
// 关联文件:
//   lib/shared/services/ai/audio/client.dart
//   lib/shared/models/audio/request.dart
//   lib/shared/providers/production_audio.dart
import 'dart:typed_data';
import '../../../models/audio/exception.dart';
import '../../../models/audio/request.dart';
import 'client.dart';

class MossAudioClient extends AudioClient {
  MossAudioClient(super.client, super.apiKey, {super.timeout})
    : super(providerType: 'moss');

  @override
  Uri get requestUrl => Uri.parse('https://api.mosi.cn/v1/audio/speech');

  @override
  Uri submissionUrl(AudioRequest request) =>
      request.modelId == 'moss-voice-generator-1.0'
      ? Uri.parse('https://api.mosi.cn/v1/audio/voice/generations')
      : requestUrl;

  @override
  AudioRequestDefaults get unlistedModelDefaults =>
      const AudioRequestDefaults(responseFormat: ConfigValue('mp3'));

  @override
  Map<String, String> get headers => {'Authorization': 'Bearer $apiKey'};

  @override
  Map<String, dynamic> encode(
    AudioRequest request, {
    List<Uint8List> references = const [],
  }) {
    final design = request.modelId == 'moss-voice-generator-1.0';
    final parameters = request.parameters;
    if (!{
          'moss-tts-1.5-flash',
          'moss-tts-1.0-pro',
          'moss-voice-generator-1.0',
        }.contains(request.modelId) ||
        references.isNotEmpty ||
        request.references.isNotEmpty ||
        !{'mp3', 'wav'}.contains(parameters.responseFormat) ||
        parameters.sampleRate != null ||
        parameters.bitrate != null ||
        (design && (parameters.instructions?.trim().isEmpty ?? true)) ||
        (design && (parameters.voice?.isNotEmpty ?? false)) ||
        (!design && (parameters.voice?.trim().isEmpty ?? true))) {
      throw const AudioException('invalid_config');
    }
    return {
      'model': request.modelId,
      'input': request.prompt,
      if (design)
        'instruction': parameters.instructions
      else
        'voice_id': parameters.voice,
      'response_format': parameters.responseFormat,
      'delivery_method': 'url',
    };
  }

  @override
  AudioGenerationResult decodeResult(Map<String, dynamic> json) {
    final url = Uri.tryParse(json['url'] as String? ?? '');
    final mime = json['content_type'] as String?;
    if (json['status'] != 'SUCCESS' ||
        url == null ||
        url.scheme != 'https' ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        !{'audio/mpeg', 'audio/wav', 'audio/x-wav'}.contains(mime)) {
      throw const AudioException('invalid_result');
    }
    return AudioGenerationResult(Uint8List(0), url: url, mimeType: mime);
  }
}

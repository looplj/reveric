// 职责: 调用豆包语音合成的单向 SSE 接口并拼接 MP3 音频片段。
// 关联文件:
//   lib/shared/services/ai/audio/client.dart
//   lib/shared/models/audio/speech.dart
//   lib/shared/providers/production_audio.dart

import 'dart:convert';
import 'dart:typed_data';

import '../../../models/audio/exception.dart';
import '../../../models/audio/request.dart';
import '../media_diagnostics.dart';
import 'client.dart';

class DoubaoTtsClient extends AudioClient {
  DoubaoTtsClient(
    super.client,
    super.apiKey, {
    required super.providerType,
    required this.resourceId,
  });

  static final _endpoint = Uri.parse(
    'https://openspeech.bytedance.com/api/v3/tts/unidirectional/sse',
  );

  final String resourceId;

  @override
  Uri get requestUrl => _endpoint;

  @override
  Map<String, String> get headers => {
    'X-Api-Key': apiKey,
    'X-Api-Resource-Id': resourceId,
  };

  @override
  AudioRequestDefaults get unlistedModelDefaults =>
      const AudioRequestDefaults();

  @override
  Map<String, dynamic> encode(
    AudioRequest request, {
    List<Uint8List> references = const [],
  }) {
    if (request.modelId != resourceId ||
        request.parameters.responseFormat != 'mp3' ||
        request.parameters.voice?.isNotEmpty != true ||
        references.isNotEmpty) {
      throw const AudioException('invalid_config');
    }
    return {
      'user': {'uid': request.providerId},
      'req_params': {
        'text': request.prompt,
        'speaker': request.parameters.voice,
        'audio_params': {
          'format': 'mp3',
          'sample_rate': ?request.parameters.sampleRate,
          'bit_rate': ?request.parameters.bitrate,
        },
      },
    };
  }

  @override
  AudioGenerationResult? decodeBinaryResult(
    Uint8List bytes,
    Map<String, String> headers,
    AudioRequest request,
  ) {
    if (headers['content-type']?.split(';').first != 'text/event-stream') {
      return null;
    }
    final audio = BytesBuilder(copy: false);
    for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
      if (!line.startsWith('data:')) {
        continue;
      }
      final event = jsonDecode(line.substring(5)) as Map<String, dynamic>;
      final code = event['code'];
      if (code == 20000000 && audio.isNotEmpty) {
        return AudioGenerationResult(audio.takeBytes());
      }
      if (code != 0) {
        return decodeResult(event);
      }
      final data = event['data'];
      if (data is String && data.isNotEmpty) {
        audio.add(base64Decode(data));
      }
    }
    throw const FormatException('Incomplete Doubao speech response');
  }

  @override
  AudioGenerationResult decodeResult(Map<String, dynamic> json) {
    final code = json['code'];
    if (code is! int || code == 0 || code == 20000000) {
      throw const FormatException('Expected Doubao speech audio events');
    }
    final message = json['message'] as String?;
    throw AudioException(
      'rejected',
      providerCode: code,
      providerMessage: message,
      detail: providerErrorDetail('$code', message, apiKey),
    );
  }
}

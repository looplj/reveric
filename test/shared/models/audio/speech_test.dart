// 职责: 验证语音模型的音色参数、文本与演绎分离、参考音频边界和原生 MiniMax 请求。
// 关联文件:
//   lib/shared/models/audio/speech.dart
//   lib/shared/services/ai/audio/openrouter.dart
//   lib/shared/services/ai/audio/minimax.dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/models/audio/request.dart';
import 'package:reveric/shared/models/audio/speech.dart';
import 'package:reveric/shared/models/audio/exception.dart';
import 'package:reveric/shared/services/ai/audio/openrouter.dart';
import 'package:reveric/shared/services/ai/audio/minimax.dart';
import 'package:reveric/shared/services/production/audio_generate_orchestrator.dart';
import 'package:reveric/shared/models/storyboard/prompt.dart';

void main() {
  for (final entry in speechModels.entries) {
    test(
      '${entry.key} sends voice and decodes its default audio format',
      () async {
        final voice = entry.value.voices.firstOrNull ?? 'custom-voice';
        final pcm = entry.key == 'heygen/heygen-voice-1-turbo:free';
        var calls = 0;
        final api = OpenRouterAudioClient(
          MockClient((r) async {
            calls++;
            expect(r.url.path, '/api/v1/audio/speech');
            final json = jsonDecode(r.body) as Map;
            expect(json['input'], '我们出发吧。');
            expect(json['voice'], voice);
            expect(
              json['instructions'],
              entry.value.supportsInstructions ? '平静、温暖' : null,
            );
            expect(json['response_format'], pcm ? 'pcm' : 'mp3');
            return http.Response.bytes(
              [73, 68, 51, 1, 2, 3],
              200,
              headers: {
                'content-type': pcm
                    ? 'audio/pcm;rate=44100;channels=1'
                    : 'audio/mpeg',
              },
            );
          }),
          'key',
          providerType: 'openrouter',
        );
        final request = AudioRequest(
          providerId: 'p',
          modelId: entry.key,
          prompt: '我们出发吧。',
          originalPrompt: '我们出发吧。',
          parameters: AudioRequestDefaults(
            voice: ConfigValue(voice),
            instructions: ConfigValue(
              entry.value.supportsInstructions ? '平静、温暖' : null,
            ),
          ),
        );
        final restored = AudioRequest.fromJson(request.toJson());
        expect(restored.parameters.voice, voice);
        final bytes = (await api.generate(restored)).bytes;
        if (pcm) {
          expect(ascii.decode(bytes.sublist(0, 4)), 'RIFF');
          expect(
            ByteData.sublistView(bytes).getUint32(24, Endian.little),
            44100,
          );
          expect(bytes.sublist(44), [73, 68, 51, 1, 2, 3]);
        } else {
          expect(bytes, [73, 68, 51, 1, 2, 3]);
        }
        expect(calls, 1);
      },
    );
  }

  test('speech requires a voice and rejects unsupported instructions', () {
    AudioRequest request(AudioRequestDefaults p) => AudioRequest(
      providerId: 'p',
      modelId: 'qwen/qwen-audio-3.0-tts-plus',
      prompt: 'Hello',
      originalPrompt: 'Hello',
      parameters: p,
    );
    expect(
      () => resolveAudioRequest(
        'openrouter',
        request(const AudioRequestDefaults()),
      ),
      throwsA(
        isA<AudioException>().having(
          (e) => e.code,
          'code',
          'audio_voice_required',
        ),
      ),
    );
    expect(
      () => resolveAudioRequest(
        'openrouter',
        request(
          const AudioRequestDefaults(
            voice: ConfigValue('longanlingxin'),
            instructions: ConfigValue('calm'),
          ),
        ),
      ),
      throwsA(isA<AudioException>()),
    );
  });

  test('Fish clones one recording without speaking reference placeholders', () {
    final references = [
      const AudioReference(
        assetId: 'audio',
        kind: 'audio',
        mimeType: 'audio/wav',
        bytes: 44,
        inputId: 'ref',
      ),
    ];
    final text = compileAudioPrompt(
      '${StoryboardPrompt.reference('ref', 'voice')}你好。',
      references,
      placeholders: false,
    );
    expect(text, '你好。');
    final request = resolveAudioRequest(
      'openrouter',
      AudioRequest(
        providerId: 'p',
        modelId: 'fish-audio/s2.1-pro',
        prompt: text,
        originalPrompt: text,
        references: references,
      ),
    );
    final api = OpenRouterAudioClient(
      MockClient((_) async => throw StateError('encode only')),
      'key',
      providerType: 'openrouter',
    );
    final wire = api.encode(request, references: [Uint8List(44)]);
    expect(wire.containsKey('voice'), isFalse);
    expect((wire['input_references'] as List).single['type'], 'input_audio');
    expect(
      () => AudioCapabilities(
        'fish-audio/s2.1-pro',
        providerType: 'openrouter',
      ).validateSelection(['audio', 'audio']),
      throwsA(isA<AudioException>()),
    );
    expect(
      () => AudioCapabilities(
        'minimax/speech-2.8-hd',
        providerType: 'openrouter',
      ).validateSelection(['audio']),
      throwsA(isA<AudioException>()),
    );
  });

  test(
    'native MiniMax speech uses t2a_v2 with voice_setting, not the music route',
    () async {
      final api = MinimaxAudioClient(
        MockClient((r) async {
          expect(r.url.toString(), 'https://example.test/proxy/v1/t2a_v2');
          final body = jsonDecode(r.body) as Map;
          expect(body['text'], '你好');
          expect(body['voice_setting']['voice_id'], 'custom-id');
          expect(body.containsKey('is_instrumental'), isFalse);
          expect(body.containsKey('prompt'), isFalse);
          return http.Response(
            jsonEncode({
              'base_resp': {'status_code': 0},
              'data': {'status': 2, 'audio': '494433010203'},
            }),
            200,
          );
        }),
        'key',
        providerType: 'minimax',
        endpoint: Uri.parse('https://example.test/proxy/v1'),
      );
      final result = await api.generate(
        AudioRequest(
          providerId: 'p',
          modelId: 'speech-2.8-hd',
          prompt: '你好',
          originalPrompt: '你好',
          parameters: const AudioRequestDefaults(
            voice: ConfigValue('custom-id'),
          ),
        ),
      );
      expect(result.bytes, [73, 68, 51, 1, 2, 3]);
    },
  );
}

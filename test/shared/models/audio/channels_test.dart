// 职责: 验证音频模型共享、渠道覆盖及完整请求默认值的合并与冻结。
// 关联文件:
//   lib/shared/models/audio/catalog.dart
//   lib/shared/models/audio/channels.dart
//   lib/shared/models/audio/request.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/audio/catalog.dart';
import 'package:reveric/shared/models/audio/channels.dart';
import 'package:reveric/shared/models/audio/request.dart';
import 'package:reveric/shared/models/audio/exception.dart';
import '../../../helpers/media_provider_types.dart';

void main() {
  const nativeId = 'seed-audio-1.0';
  const routerId = 'bytedance-seed/seed-audio-1-0';
  AudioRequest request(
    String id, {
    AudioRequestDefaults parameters = const AudioRequestDefaults(),
  }) => AudioRequest(
    providerId: 'p',
    modelId: id,
    prompt: 'Rain',
    originalPrompt: 'Rain',
    parameters: parameters,
  );

  test(
    'Seed channels share capabilities but select different wire defaults',
    () {
      final native = lookupAudioChannelModel(
        audioProviderType(AudioProtocol.seed_audio),
        nativeId,
      )!;
      final router = lookupAudioChannelModel(
        audioProviderType(AudioProtocol.openrouter_speech),
        routerId,
      )!;
      expect(native.model, same(router.model));
      expect(lookupAudioModel(routerId), same(lookupAudioModel(nativeId)));
      expect(native.requestDefaults.responseFormat, 'wav');
      expect(native.requestDefaults.sampleRate, 24000);
      expect(router.requestDefaults.responseFormat, 'pcm');
      expect(router.requestDefaults.sampleRate, isNull);
      expect(
        native.capabilities.references['audio']!.mimeTypes,
        contains('audio/pcm'),
      );
      expect(
        router.capabilities.references['audio']!.mimeTypes,
        isNot(contains('audio/pcm')),
      );
      expect(router.capabilities.references['audio']!.maxCount, 3);
      expect(
        router.capabilities.references['audio']!.maxBytes,
        10 * 1024 * 1024,
      );
      expect(router.capabilities.references['image']!.maxCount, 1);
      expect(
        audioModelsForProvider('openrouter'),
        containsAll([
          routerId,
          'minimax/speech-2.8-hd',
          'qwen/qwen-audio-3.0-tts-plus',
        ]),
      );
      expect(audioModelsForProvider('doubao_audio'), [
        nativeId,
        'seed-tts-2.0',
        'seed-tts-1.0',
      ]);
    },
  );

  test(
    'overrides replace values, preserve false and clear explicit limits',
    () {
      const channel = AudioChannelModel(
        catalogId: nativeId,
        capabilities: AudioModelCapabilities(
          maxPromptCharacters: 5000,
          maxOutputDurationMs: ConfigValue(null),
          supportsAudioReferencePlaceholders: false,
          references: {
            'audio': AudioReferenceLimits(maxCount: 0, mimeTypes: {}),
          },
        ),
      );
      final c = channel.capabilities;
      expect(c.maxPromptCharacters, 5000);
      expect(c.maxOutputDurationMs, isNull);
      expect(c.supportsAudioReferencePlaceholders, isFalse);
      expect(c.references['audio']!.maxCount, 0);
      expect(c.references['audio']!.mimeTypes, isEmpty);
      expect(c.references['audio']!.maxDurationMs, 30000);
      expect(c.references['image']!.maxCount, 1);
      expect(channel.model.capabilities.maxPromptCharacters, 3000);
      expect(
        c.merge(const AudioModelCapabilities(references: {})).references,
        isEmpty,
      );
    },
  );

  test(
    'model then channel then request merge preserves IDs and explicit nulls',
    () {
      final raw = request(routerId);
      final resolved = resolveAudioRequest(
        audioProviderType(AudioProtocol.openrouter_speech),
        raw,
      );
      expect(raw.parameters.responseFormat, isNull);
      expect(resolved.modelId, routerId);
      expect(resolved.parameters.responseFormat, 'pcm');
      expect(resolved.parameters.sampleRate, isNull);
      final restored = AudioRequest.fromJson(resolved.toJson());
      expect(restored.toJson(), resolved.toJson());
      expect(
        restored
            .withDefaults(
              const AudioRequestDefaults(
                responseFormat: ConfigValue('mp3'),
                sampleRate: ConfigValue(44100),
              ),
            )
            .parameters
            .sampleRate,
        isNull,
      );
      expect(
        restored
            .withDefaults(
              const AudioRequestDefaults(responseFormat: ConfigValue('mp3')),
            )
            .parameters
            .responseFormat,
        'pcm',
      );
      final selected = resolveAudioRequest(
        audioProviderType(AudioProtocol.seed_audio),
        request(
          nativeId,
          parameters: const AudioRequestDefaults(
            sampleRate: ConfigValue(48000),
          ),
        ),
      );
      expect(selected.parameters.responseFormat, 'wav');
      expect(selected.parameters.sampleRate, 48000);
      final music = resolveAudioRequest(
        audioProviderType(AudioProtocol.minimax_music),
        request('music-3.0'),
      );
      expect(music.parameters.toJson(), {
        'response_format': 'mp3',
        'sample_rate': 44100,
        'bitrate': 256000,
      });
    },
  );

  test('known models never authorize an unsupported channel', () {
    for (final (protocol, id) in [
      (AudioProtocol.openrouter_speech, nativeId),
      (AudioProtocol.seed_audio, routerId),
      (AudioProtocol.minimax_music, nativeId),
      (AudioProtocol.openrouter_speech, '$routerId-fast'),
    ]) {
      expect(
        () => resolveAudioRequest(audioProviderType(protocol), request(id)),
        throwsA(
          isA<AudioException>().having((e) => e.code, 'code', 'invalid_config'),
        ),
      );
    }
  });

  test(
    'channel reference restrictions are enforced independently of model',
    () {
      const reference = AudioReference(
        assetId: 'sample.pcm',
        kind: 'audio',
        mimeType: 'audio/pcm',
        bytes: 2,
        durationMs: 1,
      );
      AudioCapabilities(
        nativeId,
        providerType: audioProviderType(AudioProtocol.seed_audio),
      ).validateReference(reference);
      expect(
        () => AudioCapabilities(
          routerId,
          providerType: audioProviderType(AudioProtocol.openrouter_speech),
        ).validateReference(reference),
        throwsA(
          isA<AudioException>().having(
            (e) => e.code,
            'code',
            'audio_reference_format',
          ),
        ),
      );
    },
  );
}

// 职责: 验证音频渠道按类型固定路由、共用凭据且不改写提示词。
// 关联文件:
//   lib/shared/providers/production_audio.dart
//   lib/shared/services/ai/audio/seed.dart
//   lib/shared/services/ai/audio/doubao_tts.dart
//   lib/shared/models/audio/request.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/audio/exception.dart';
import 'package:reveric/shared/models/audio/request.dart';
import 'package:reveric/shared/providers/production_audio.dart';

void main() {
  test(
    'OpenRouter audio factory shares the channel key and fixed endpoint',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final provider = aiProviderBuiltinById('doubao')!.copyWith(
        type: 'openrouter',
        apiKey: 'shared-key',
        baseUrl: 'https://ignored.invalid',
      );
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final result = await http.runWithClient(
        () => container.read(productionAudioInvokeProvider)(
          provider,
          AudioRequest(
            providerId: provider.id,
            modelId: 'bytedance-seed/seed-audio-1-0',
            prompt: 'rain',
            originalPrompt: 'rain',
          ),
          [],
          Completer<void>().future,
        ),
        () => MockClient((r) async {
          expect(r.url.toString(), 'https://openrouter.ai/api/v1/audio/speech');
          expect(r.headers['Authorization'], 'Bearer shared-key');
          expect((jsonDecode(r.body) as Map)['response_format'], 'pcm');
          return http.Response.bytes(
            bytes,
            200,
            headers: {'content-type': 'audio/pcm;rate=24000;channels=1'},
          );
        }),
      );
      expect(result.bytes.sublist(44), bytes);
    },
  );

  for (final (baseUrl, endpoint) in [
    (
      'https://dashscope.aliyuncs.com/compatible-mode/v1',
      'https://dashscope.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer',
    ),
    (
      'https://proxy.example/qwen/compatible-mode/v1/',
      'https://proxy.example/qwen/api/v1/services/audio/tts/SpeechSynthesizer',
    ),
    (
      'https://proxy.example/qwen/',
      'https://proxy.example/qwen/api/v1/services/audio/tts/SpeechSynthesizer',
    ),
  ]) {
    test(
      'Qwen audio uses its own key and configured endpoint $baseUrl',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final provider = aiProviderBuiltinById(
          'openai',
        )!.copyWith(type: 'qwen', apiKey: 'qwen-key', baseUrl: baseUrl);
        var calls = 0;
        final result = await http.runWithClient(
          () => container.read(productionAudioInvokeProvider)(
            provider,
            AudioRequest(
              providerId: provider.id,
              modelId: 'qwen-audio-3.1-tts-plus',
              prompt: 'Hello',
              originalPrompt: 'Hello',
              parameters: const AudioRequestDefaults(
                voice: ConfigValue('longanhuan_v3.1'),
              ),
            ),
            [],
            Completer<void>().future,
          ),
          () => MockClient((r) async {
            calls++;
            expect(r.method, 'POST');
            expect(r.url.toString(), endpoint);
            expect(r.headers['Authorization'], 'Bearer qwen-key');
            expect(jsonDecode(r.body), {
              'model': 'qwen-audio-3.1-tts-plus',
              'input': {
                'text': 'Hello',
                'voice': 'longanhuan_v3.1',
                'format': 'wav',
                'sample_rate': 24000,
              },
            });
            return http.Response(
              '{"output":{"audio":{"url":"https://output.test/result.wav"}}}',
              200,
            );
          }),
        );
        expect(calls, 1);
        expect(result.url.toString(), 'https://output.test/result.wav');
        expect(result.bytes, isEmpty);
      },
    );
  }
  for (final model in [
    'qwen-audio-3.1-tts-plus',
    'qwen-audio-3.0-tts-flash',
    'qwen-audio-3.1-tts-next',
  ]) {
    test('Qwen factory selects SpeechSynthesizer for $model', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final provider = aiProviderBuiltinById('openai')!.copyWith(
        type: 'qwen',
        apiKey: 'qwen-key',
        baseUrl: 'https://proxy.example/qwen/compatible-mode/v1/',
      );
      var calls = 0;
      await http.runWithClient(
        () => container.read(productionAudioInvokeProvider)(
          provider,
          AudioRequest(
            providerId: provider.id,
            modelId: model,
            prompt: 'Hello',
            originalPrompt: 'Hello',
          ),
          [],
          Completer<void>().future,
        ),
        () => MockClient((r) async {
          calls++;
          expect(
            r.url.toString(),
            'https://proxy.example/qwen/api/v1/services/audio/tts/SpeechSynthesizer',
          );
          expect(r.headers['Authorization'], 'Bearer qwen-key');
          expect(r.headers['X-DashScope-SSE'], isNull);
          final body = jsonDecode(r.body) as Map;
          expect(body['model'], model);
          expect(body['input']['format'], 'wav');
          expect(
            body['input'][model.endsWith('-next') ? 'text_prompt' : 'text'],
            'Hello',
          );
          return http.Response(
            '{"output":{"audio":{"url":"https://output.test/result.wav"}}}',
            200,
          );
        }),
      );
      expect(calls, 1);
    });
  }
  test(
    'AtlasCloud factory submits and queries with the channel key and fixed routes',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final provider = aiProviderBuiltinById('openai')!.copyWith(
        type: 'atlascloud',
        apiKey: 'atlas-key',
        baseUrl: 'https://ignored.invalid',
      );
      final calls = <String>[];
      await http.runWithClient(
        () async {
          final receipt = await container.read(productionAudioInvokeProvider)(
            provider,
            AudioRequest(
              providerId: provider.id,
              modelId: 'bytedance/seed-audio-1.0',
              prompt: 'Hello',
              originalPrompt: 'Hello',
            ),
            [],
            Completer<void>().future,
          );
          expect(receipt.isPending, isTrue);
          final result = await container.read(productionAudioQueryProvider)(
            provider,
            receipt.providerTaskId!,
            Completer<void>().future,
          );
          expect(result.url.toString(), 'https://cdn.example/audio.wav');
        },
        () => MockClient((r) async {
          calls.add('${r.method} ${r.url}');
          expect(r.headers['Authorization'], 'Bearer atlas-key');
          return http.Response(
            jsonEncode({
              'code': 200,
              'data': {
                'id': 'pred',
                'status': r.method == 'POST' ? 'processing' : 'completed',
                if (r.method == 'GET')
                  'outputs': ['https://cdn.example/audio.wav'],
              },
            }),
            200,
          );
        }),
      );
      expect(calls, [
        'POST https://api.atlascloud.ai/api/v1/model/generateAudio',
        'GET https://api.atlascloud.ai/api/v1/model/prediction/pred',
      ]);
    },
  );

  for (final (model, voice) in [
    ('seed-tts-1.0', 'zh_female_meilinvyou_moon_bigtts'),
    ('seed-tts-2.0', 'zh_female_vv_uranus_bigtts'),
  ]) {
    test('Doubao $model sends the version and joins speech events', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final provider = aiProviderBuiltinById('openai')!.copyWith(
        type: 'doubao_audio',
        apiKey: 'speech-key',
        audioModels: [model],
      );
      final result = await http.runWithClient(
        () => container.read(productionAudioInvokeProvider)(
          provider,
          AudioRequest(
            providerId: provider.id,
            modelId: model,
            prompt: '你好',
            originalPrompt: '你好',
          ),
          [],
          Completer<void>().future,
        ),
        () => MockClient((request) async {
          expect(request.method, 'POST');
          expect(
            request.url.toString(),
            'https://openspeech.bytedance.com/api/v3/tts/unidirectional/sse',
          );
          expect(request.headers['x-api-key'], 'speech-key');
          expect(request.headers['x-api-resource-id'], model);
          expect(jsonDecode(utf8.decode(request.bodyBytes)), {
            'user': {'uid': provider.id},
            'req_params': {
              'text': '你好',
              'speaker': voice,
              'audio_params': {'format': 'mp3'},
            },
          });
          return http.Response(
            'event: 352\ndata: {"code":0,"data":"SUQz"}\n\n'
            'event: 351\ndata: {"code":0,"data":null,"sentence":{}}\n\n'
            'event: 352\ndata: {"code":0,"data":"AQI="}\n\n'
            'event: 152\ndata: {"code":20000000,"data":null}\n\n',
            200,
            headers: {'content-type': 'text/event-stream; charset=utf-8'},
          );
        }),
      );
      expect(result.bytes, [0x49, 0x44, 0x33, 1, 2]);
    });
  }

  test('Doubao does not publish partial speech after an SSE error', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    const model = 'seed-tts-2.0';
    final provider = aiProviderBuiltinById('openai')!.copyWith(
      type: 'doubao_audio',
      apiKey: 'speech-key',
      audioModels: [model],
    );
    await expectLater(
      http.runWithClient(
        () => container.read(productionAudioInvokeProvider)(
          provider,
          AudioRequest(
            providerId: provider.id,
            modelId: model,
            prompt: 'Hello',
            originalPrompt: 'Hello',
          ),
          [],
          Completer<void>().future,
        ),
        () => MockClient(
          (_) async => http.Response(
            'event: 352\ndata: {"code":0,"data":"SUQz"}\n\n'
            'event: 153\ndata: {"code":45000000,"message":"speaker permission denied"}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        ),
      ),
      throwsA(
        isA<AudioException>()
            .having((error) => error.code, 'code', 'rejected')
            .having((error) => error.providerCode, 'provider code', 45000000),
      ),
    );
  });

  final wav = Uint8List(44)
    ..setRange(0, 4, ascii.encode('RIFF'))
    ..setRange(8, 12, ascii.encode('WAVE'));

  for (final (type, host) in [('doubao_audio', 'openspeech.bytedance.com')]) {
    for (final status in [200, 401]) {
      test('$type routes audio to $host and handles HTTP $status', () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final provider = aiProviderBuiltinById('doubao')!.copyWith(
          type: type,
          baseUrl: 'https://override.example/v1',
          apiKey: 'shared-key',
          audioModels: ['seed-audio-1.0'],
        );
        const prompt = 'Let @Audio1 speak, then @音频1 laugh.';
        final request = AudioRequest(
          providerId: provider.id,
          modelId: 'seed-audio-1.0',
          originalPrompt: prompt,
          prompt: prompt,
          references: [
            AudioReference(
              assetId: 'voice.wav',
              kind: 'audio',
              mimeType: 'audio/wav',
              bytes: wav.length,
              durationMs: 1000,
            ),
          ],
        );
        var calls = 0;
        final pending = http.runWithClient(
          () => container.read(productionAudioInvokeProvider)(
            provider,
            request,
            [wav],
            Completer<void>().future,
          ),
          () => MockClient((r) async {
            calls++;
            expect(r.url.toString(), 'https://$host/api/v3/tts/create');
            expect(r.headers['X-Api-Key'], 'shared-key');
            expect(jsonDecode(r.body), {
              'model': 'seed-audio-1.0',
              'text_prompt': prompt,
              'references': [
                {'audio_data': base64Encode(wav)},
              ],
              'audio_config': {'format': 'wav', 'sample_rate': 24000},
            });
            return http.Response(
              jsonEncode(
                status == 200
                    ? {'audio': base64Encode(wav)}
                    : {'message': 'Unauthorized'},
              ),
              status,
            );
          }),
        );
        if (status == 200) {
          expect((await pending).bytes, wav);
        } else {
          await expectLater(
            pending,
            throwsA(
              isA<AudioException>().having(
                (e) => e.code,
                'code',
                'authentication',
              ),
            ),
          );
        }
        expect(calls, 1);
        expect(request.prompt, prompt);
      });
    }
  }
}

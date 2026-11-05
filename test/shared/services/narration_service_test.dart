// 职责: 验证朗读配置持久化、供应商可用性校验及角色音色到语音请求的映射。
// 关联文件:
//   lib/shared/services/screenplay/narration_service.dart
//   lib/shared/models/narration.dart

import 'dart:async';
import 'dart:typed_data';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/audio/exception.dart';
import 'package:reveric/shared/models/audio/request.dart';
import 'package:reveric/shared/models/audio/result.dart';
import 'package:reveric/shared/models/narration.dart';
import 'package:reveric/shared/services/screenplay/narration_service.dart';

const narrationModel = 'google/gemini-3.8-flash-tts';

Future<void> insertNarrationProvider(AppDatabase db) => db
    .into(db.aiProviders)
    .insert(
      AiProvidersCompanion.insert(
        id: 'speech',
        name: 'Speech',
        type: 'openrouter',
        enabled: const Value(true),
        apiKey: const Value('test-key'),
        audioModels: const Value([narrationModel]),
      ),
    )
    .then((_) {});

void main() {
  late AppDatabase db;
  late NarrationService service;
  late List<AudioRequest> requests;
  final settings = NarrationSettings(
    providerId: 'speech',
    modelId: narrationModel,
    narrator: 'Kore',
    voices: {'a': 'Puck'},
  );
  const segment = NarrationSegment(
    text: '别走。',
    voice: 'Puck',
    sceneId: 's',
    characterId: 'a',
    instructions: '轻声',
  );
  setUp(() async {
    db = AppDatabase.forTest(NativeDatabase.memory());
    await insertNarrationProvider(db);
    requests = [];
    service = NarrationService(
      database: db,
      invoke: (provider, request, references, abort) async {
        requests.add(request);
        expect(references, isEmpty);
        return AudioGenerationResult(Uint8List.fromList([1, 2]));
      },
    );
  });
  tearDown(() => db.close());

  for (final model in ['moss-tts-1.5-flash', 'moss-voice-generator-1.0']) {
    test(
      'narration only accepts MOSS models with a reusable voice: $model',
      () async {
        final provider = (await db.aiProviderDao.getById('speech'))!;
        await db.aiProviderDao.upsert(
          provider.copyWith(type: 'moss', audioModels: [model]),
        );
        final pending = service.requireProvider(
          NarrationSettings(providerId: 'speech', modelId: model),
        );
        if (model == 'moss-voice-generator-1.0') {
          await expectLater(pending, throwsA(isA<AudioException>()));
        } else {
          expect((await pending).type, 'moss');
        }
      },
    );
  }

  test(
    'playback uses the returned MIME rather than requested format',
    () async {
      final audio = Uint8List.fromList([1, 2, 3]);
      final service = NarrationService(
        database: db,
        invoke: (_, _, _, _) async =>
            AudioGenerationResult(audio, mimeType: 'audio/ogg'),
      );
      final result = await service.generate(
        settings,
        segment,
        Completer<void>().future,
      );
      expect(result.bytes, audio);
      expect(result.extension, 'ogg');
    },
  );

  for (final (model, voice, instructions) in [
    ('qwen-audio-3.1-tts-plus', 'longanhuan_v3.1', '轻声'),
    ('qwen-audio-3.0-tts-flash', 'longanhuan_v3.6', '轻声'),
    ('qwen-audio-3.1-tts-next', '', ''),
  ]) {
    test('Qwen narration accepts only speech models: $model', () async {
      final provider = (await db.aiProviderDao.getById('speech'))!;
      await db.aiProviderDao.upsert(
        provider.copyWith(type: 'qwen', audioModels: [model]),
      );
      final pending = service.generate(
        NarrationSettings(
          providerId: 'speech',
          modelId: model,
          narrator: voice,
        ),
        NarrationSegment(
          text: '别走。',
          voice: voice,
          sceneId: 's',
          instructions: instructions,
        ),
        Completer<void>().future,
      );
      if (model.endsWith('-next')) {
        await expectLater(
          pending,
          throwsA(
            isA<AudioException>().having(
              (e) => e.code,
              'code',
              'invalid_config',
            ),
          ),
        );
        expect(requests, isEmpty);
      } else {
        final audio = await pending;
        expect(audio.extension, 'wav');
        expect(requests.single.parameters.voice, voice);
        expect(requests.single.parameters.instructions, instructions);
        expect(requests.single.prompt, '别走。');
      }
    });
  }

  test(
    'AtlasCloud narration waits for prediction before returning audio',
    () async {
      const model = 'google/gemini-3.1-flash-tts';
      final provider = (await db.aiProviderDao.getById('speech'))!;
      await db.aiProviderDao.upsert(
        provider.copyWith(type: 'atlascloud', audioModels: [model]),
      );
      var submissions = 0;
      var polls = 0;
      final atlas = NarrationService(
        database: db,
        pollInterval: Duration.zero,
        invoke: (_, request, _, _) async {
          submissions++;
          expect(request.parameters.voice, 'Puck');
          return AudioGenerationResult.pending('narration-prediction');
        },
        query: (_, id, _) async {
          expect(id, 'narration-prediction');
          polls++;
          return polls == 1
              ? AudioGenerationResult.pending(id)
              : AudioGenerationResult(
                  Uint8List.fromList([1, 2]),
                  providerTaskId: id,
                );
        },
      );
      final audio = await atlas.generate(
        NarrationSettings(
          providerId: 'speech',
          modelId: model,
          narrator: 'Kore',
        ),
        const NarrationSegment(text: 'Hello', voice: 'Puck', sceneId: 'scene'),
        Completer<void>().future,
      );
      expect(audio.extension, 'wav');
      expect(audio.bytes, [1, 2]);
      expect(submissions, 1);
      expect(polls, 2);
    },
  );

  for (final asynchronous in [false, true]) {
    test(
      'narration downloads ${asynchronous ? 'polled' : 'immediate'} URL output without provider credentials',
      () async {
        final provider = (await db.aiProviderDao.getById('speech'))!;
        final model = asynchronous
            ? 'google/gemini-3.1-flash-tts'
            : 'qwen-audio-3.1-tts-plus';
        final voice = asynchronous ? 'Kore' : 'longanhuan_v3.1';
        await db.aiProviderDao.upsert(
          provider.copyWith(
            type: asynchronous ? 'atlascloud' : 'qwen',
            audioModels: [model],
          ),
        );
        var submissions = 0;
        var downloads = 0;
        final output = AudioGenerationResult(
          Uint8List(0),
          url: Uri.parse(
            'https://cdn.example/voice.wav?signature=signed-output',
          ),
        );
        final narrator = NarrationService(
          database: db,
          invoke: (_, _, _, _) async {
            submissions++;
            return asynchronous
                ? AudioGenerationResult.pending('prediction')
                : output;
          },
          query: (_, id, _) async {
            expect(id, 'prediction');
            return output;
          },
        );
        final audio = await http.runWithClient(
          () => narrator.generate(
            NarrationSettings(
              providerId: 'speech',
              modelId: model,
              narrator: voice,
            ),
            NarrationSegment(text: 'Hello', voice: voice, sceneId: 'scene'),
            Completer<void>().future,
          ),
          () => MockClient((request) async {
            downloads++;
            expect(request.method, 'GET');
            expect(request.url, output.url);
            expect(request.headers['Authorization'], isNull);
            expect(request.headers['X-Api-Key'], isNull);
            return http.Response.bytes([1, 2, 3], 200);
          }),
        );
        expect(audio.bytes, [1, 2, 3]);
        expect(audio.extension, 'wav');
        expect(submissions, 1);
        expect(downloads, 1);
      },
    );
  }

  test(
    'per-work configuration round trips without changing character data',
    () async {
      expect((await service.load('new')).modelId, isEmpty);
      await service.save('work', settings);
      final restored = await service.load('work');
      expect(restored.toJson(), settings.toJson());
      expect((await service.load('other')).modelId, isEmpty);
    },
  );

  test(
    'generation preserves dialogue and passes voice and direction separately',
    () async {
      final audio = await service.generate(
        settings,
        segment,
        Completer<void>().future,
      );
      expect(audio.extension, 'mp3');
      expect(requests.single.prompt, '别走。');
      expect(requests.single.parameters.voice, 'Puck');
      expect(requests.single.parameters.instructions, '轻声');
    },
  );

  test('disabled provider stops before billable invocation', () async {
    final provider = (await db.aiProviderDao.getById('speech'))!;
    await db.aiProviderDao.upsert(provider.copyWith(enabled: false));
    await expectLater(
      service.generate(settings, segment, Completer<void>().future),
      throwsA(isA<AudioException>()),
    );
    expect(requests, isEmpty);
  });

  test('already cancelled generation does not submit or retry', () async {
    final abort = Completer<void>()..complete();
    await expectLater(
      service.generate(settings, segment, abort.future),
      throwsA(isA<AudioException>().having((e) => e.code, 'code', 'cancelled')),
    );
    expect(requests, isEmpty);
  });
}

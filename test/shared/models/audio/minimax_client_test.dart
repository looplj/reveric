// 职责: 验证 MiniMax 音乐协议、模型隔离、业务错误和 MP3 回执。
// 关联文件:
//   lib/shared/services/ai/audio/minimax.dart
//   lib/shared/models/audio/channels.dart
//   lib/shared/models/audio/request.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/models/audio/channels.dart';
import 'package:reveric/shared/models/audio/request.dart';
import 'package:reveric/shared/models/audio/exception.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/services/ai/audio/minimax.dart';
import 'package:reveric/shared/localization/locale_keys.dart';

void main() {
  AudioRequest request({
    String model = 'music-3.0',
    String prompt = 'Gentle strings',
  }) => AudioRequest(
    providerId: 'minimax',
    modelId: model,
    prompt: prompt,
    originalPrompt: prompt,
  );
  Map<String, dynamic> receipt({
    Object? audio = '494433010203',
    Object? status = 2,
  }) => {
    'base_resp': {'status_code': 0, 'status_msg': 'success'},
    'data': {'audio': audio, 'status': status},
  };

  for (final model in ['music-3.0', 'music-2.6']) {
    test(
      '$model encodes instrumental music and decodes hex MP3 once',
      () async {
        var posts = 0;
        final api = MinimaxAudioClient(
          MockClient((r) async {
            posts++;
            expect(
              r.url.toString(),
              'https://example.test/proxy/v1/music_generation',
            );
            expect(r.headers['Authorization'], 'Bearer secret');
            expect(r.headers.containsKey('X-Api-Key'), isFalse);
            expect(r.followRedirects, isFalse);
            final body = jsonDecode(r.body) as Map;
            expect(body['model'], model);
            expect(body['stream'], isFalse);
            expect(body['output_format'], 'hex');
            expect(body['audio_setting'], {
              'format': 'mp3',
              'sample_rate': 44100,
              'bitrate': 256000,
            });
            expect(body['is_instrumental'], isTrue);
            expect(body.containsKey('lyrics_optimizer'), isFalse);
            expect(body.containsKey('lyrics'), isFalse);
            return http.Response(jsonEncode(receipt()), 200);
          }),
          'secret',
          endpoint: Uri.parse('https://example.test/proxy/v1/'),
          providerType: 'minimax',
        );
        final result = await api.generate(request(model: model));
        expect(result.bytes, [73, 68, 51, 1, 2, 3]);
        expect(posts, 1);
      },
    );
  }
  for (final (status, code, key) in [
    (1002, 'rate_limited', LocaleKeys.aiRateLimited),
    (1004, 'authentication', LocaleKeys.aiApiKeyInvalid),
    (2049, 'authentication', LocaleKeys.aiApiKeyInvalid),
    (1008, 'rejected', LocaleKeys.aiProviderPaymentRequired),
    (1026, 'rejected', LocaleKeys.aiContentRejected),
    (2013, 'rejected', LocaleKeys.aiBadRequest),
  ]) {
    test('HTTP 200 with MiniMax error $status is a known failure', () async {
      final api = MinimaxAudioClient(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'base_resp': {
                'status_code': status,
                'status_msg': 'private upstream error',
              },
            }),
            200,
          ),
        ),
        'key',
        endpoint: Uri.https('example.test'),
        providerType: 'minimax',
      );
      await expectLater(
        api.generate(request()),
        throwsA(
          isA<AudioException>()
              .having((e) => e.code, 'code', code)
              .having((e) => e.providerCode, 'providerCode', status)
              .having((e) => e.statusCode, 'HTTP', 200)
              .having((e) => e.messageKey, 'message', key)
              .having(
                (e) => e.providerMessage,
                'original message',
                'private upstream error',
              )
              .having(
                (e) => e.detail,
                'agent detail',
                '$status: private upstream error',
              )
              .having(
                (e) => e.toString(),
                'safe exception',
                isNot(contains('private')),
              ),
        ),
      );
    });
  }
  test('invalid receipts stay uncertain and never regenerate', () async {
    for (final body in [
      <String, dynamic>{},
      receipt(audio: 'zz'),
      receipt(audio: '494'),
      receipt(audio: '01020304'),
      receipt(status: 1),
      receipt(audio: null),
    ]) {
      var posts = 0;
      final api = MinimaxAudioClient(
        MockClient((_) async {
          posts++;
          return http.Response(jsonEncode(body), 200);
        }),
        'key',
        endpoint: Uri.https('example.test'),
        providerType: 'minimax',
      );
      await expectLater(
        api.generate(request()),
        throwsA(
          isA<AudioException>().having(
            (e) => e.code,
            'code',
            'audio_submission_unknown',
          ),
        ),
      );
      expect(posts, 1);
    }
  });
  test('MiniMax prompt limits and provider catalog', () async {
    const c = AudioCapabilities('music-3.0');
    c.validate(request(prompt: 'a' * 2000));
    expect(
      () => c.validate(request(prompt: '')),
      throwsA(isA<AudioException>()),
    );
    expect(
      () => c.validate(request(prompt: 'a' * 2001)),
      throwsA(isA<AudioException>()),
    );
    expect(
      () => c.validateSelection(['audio']),
      throwsA(isA<AudioException>()),
    );
    final provider = aiProviderBuiltinById('openai')!.copyWith(type: 'minimax');
    expect(c.supportsProvider(provider), isTrue);
    expect(
      AudioCapabilities('seed-audio-1.0').supportsProvider(provider),
      isFalse,
    );
    expect(audioModelsForProvider('minimax'), [
      'speech-2.8-hd',
      'music-3.0',
      'music-2.6',
    ]);
    expect(audioModelsForProvider('doubao_audio'), contains('seed-audio-1.0'));
  });
}

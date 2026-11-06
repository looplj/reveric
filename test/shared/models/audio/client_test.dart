// 职责: 验证官方音频协议、模型边界和超时不重复提交。
// 关联文件:
//   lib/shared/models/audio/catalog.dart
//   lib/shared/services/ai/audio/client.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/io_client.dart';
import 'package:reveric/shared/models/audio/exception.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/models/audio/catalog.dart';
import 'package:reveric/shared/models/audio/request.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/services/ai/audio/client.dart';
import 'package:reveric/shared/services/ai/audio/seed.dart';

void main() {
  test(
    'audio output uses provider proxy for HTTPS and honors refusal',
    () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      final requests = <(String, String?, String?)>[];
      proxy.listen((r) async {
        requests.add((
          r.method,
          r.headers.value(HttpHeaders.proxyAuthorizationHeader),
          r.headers.value(HttpHeaders.authorizationHeader),
        ));
        r.response.statusCode = 403;
        await r.response.close();
      });
      final provider = aiProviderBuiltinById('openai')!.copyWith(
        apiKey: 'provider-secret',
        proxyUrl: 'http://127.0.0.1:${proxy.port}',
        proxyUsername: 'user',
        proxyPassword: 'secret',
      );
      var bypasses = 0;
      await expectLater(
        http.runWithClient(
          () => downloadAudioOutput(
            Uri.https('output.invalid', '/audio.wav'),
            provider: provider,
            retryDelay: Duration.zero,
          ),
          () => MockClient((_) async {
            bypasses++;
            return http.Response.bytes([1, 2, 3], 200);
          }),
        ),
        throwsA(isA<AudioException>()),
      );
      expect(bypasses, 0);
      expect(requests, isNotEmpty);
      for (final request in requests) {
        expect(request, (
          'CONNECT',
          'Basic ${base64Encode(utf8.encode('user:secret'))}',
          null,
        ));
      }
    },
  );
  AudioRequest request({String text = 'Hello'}) => AudioRequest(
    providerId: 'audio',
    modelId: 'seed-audio-1.0',
    prompt: text,
    originalPrompt: text,
  );
  test(
    'structured moderation errors survive opaque audio response messages',
    () async {
      final client = SeedAudioClient(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {
                'code': 'InputAudioSensitiveContentDetected',
                'message': 'Request failed',
              },
            }),
            400,
          ),
        ),
        'test-key',
        providerType: 'volcengine',
      );
      await expectLater(
        client.generate(request()),
        throwsA(
          isA<AudioException>()
              .having(
                (e) => e.messageKey,
                'safe key',
                LocaleKeys.aiInputAudioRejected,
              )
              .having(
                (e) => e.providerMessage,
                'original message',
                'Request failed',
              ),
        ),
      );
    },
  );

  test(
    'request parameters override defaults and explicit null omits the wire field',
    () {
      final client = SeedAudioClient(
        MockClient((_) async => throw StateError('encode only')),
        'key',
        providerType: 'volcengine',
      );
      final selected = AudioRequest(
        providerId: 'audio',
        modelId: 'seed-audio-1.0',
        prompt: 'Hello',
        originalPrompt: 'Hello',
        parameters: const AudioRequestDefaults(
          responseFormat: ConfigValue('wav'),
          sampleRate: ConfigValue(48000),
        ),
      );
      expect(
        (client.encode(selected)['audio_config'] as Map)['sample_rate'],
        48000,
      );
      final omitted = AudioRequest(
        providerId: 'audio',
        modelId: 'seed-audio-1.0',
        prompt: 'Hello',
        originalPrompt: 'Hello',
        parameters: const AudioRequestDefaults(
          responseFormat: ConfigValue('wav'),
          sampleRate: ConfigValue(null),
        ),
      );
      expect(
        (client.encode(omitted)['audio_config'] as Map).containsKey(
          'sample_rate',
        ),
        isFalse,
      );
    },
  );
  final wav = Uint8List(44)
    ..setRange(0, 4, ascii.encode('RIFF'))
    ..setRange(8, 12, ascii.encode('WAVE'));
  for (final status in [401, 403, 429, 503]) {
    for (final brokenBody in [false, true]) {
      test(
        'HTTP $status survives body ${brokenBody ? "failure" : "timeout"}',
        () async {
          final stream = StreamController<List<int>>();
          final transport = MockClient.streaming((_, _) async {
            if (brokenBody) {
              stream.addError(const SocketException('interrupted'));
            }
            return http.StreamedResponse(stream.stream, status);
          });
          final api = SeedAudioClient(
            transport,
            'key',
            timeout: const Duration(milliseconds: 30),
            providerType: 'volcengine',
          );
          await expectLater(
            api.generate(request()),
            throwsA(
              isA<AudioException>()
                  .having((e) => e.statusCode, 'status', status)
                  .having((e) => e.code, 'code', switch (status) {
                    401 || 403 => 'authentication',
                    429 => 'rate_limited',
                    _ => 'unavailable',
                  }),
            ),
          );
          await stream.close();
          transport.close();
        },
      );
    }
  }
  test(
    'provider diagnostics redact credentials, retain URLs and localize known errors',
    () async {
      final lines = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) {
          lines.add(message);
        }
      };
      addTearDown(() => debugPrint = originalDebugPrint);
      final client = SeedAudioClient(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'message':
                  'No available channel secret Bearer upstream-token sk-private-key https://signed.example/?token=private-token\nnext line',
            }),
            503,
          ),
        ),
        'secret',
        providerType: 'volcengine',
      );
      await expectLater(
        client.generate(request()),
        throwsA(
          isA<AudioException>().having(
            (e) => e.messageKey,
            'safe message',
            LocaleKeys.aiProviderChannelUnavailable,
          ),
        ),
      );
      final log = lines.join('\n');
      expect(log, contains('status=503'));
      expect(log, contains('provider=volcengine'));
      expect(log, contains('No available channel'));
      expect(log, contains('https://signed.example/?token=private-token'));
      expect(log, contains('[redacted]'));
      for (final sensitive in [
        'secret',
        'upstream-token',
        'sk-private-key',
        '\nnext line',
      ]) {
        expect(log, isNot(contains(sensitive)));
      }
      expect(
        lines.where((line) => line.contains('[WARN] [AudioClient]')),
        hasLength(1),
      );
    },
  );
  for (final streaming in [false, true]) {
    test(
      'cancellation aborts real HTTP ${streaming ? "response body" : "request"}',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final received = Completer<void>();
        var posts = 0;
        server.listen((incoming) async {
          posts++;
          await incoming.drain<void>();
          if (streaming) {
            incoming.response.write('{"audio":"');
            await incoming.response.flush();
          }
          received.complete();
        });
        final transport = _LocalClient(server.port);
        addTearDown(() async {
          transport.close();
          await server.close(force: true);
        });
        final abort = Completer<void>();
        final pending = SeedAudioClient(
          transport,
          'key',
          providerType: 'volcengine',
        ).generate(request(), abortTrigger: abort.future);
        final result = expectLater(
          pending.timeout(const Duration(seconds: 2)),
          throwsA(
            isA<AudioException>().having((e) => e.code, 'code', 'cancelled'),
          ),
        );
        await received.future.timeout(const Duration(seconds: 2));
        abort.complete();
        await result;
        expect(posts, 1);
      },
    );
  }
  test(
    'timeout aborts the HTTP transport instead of only abandoning its future',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((incoming) async => incoming.drain<void>());
      final transport = _LocalClient(server.port);
      addTearDown(() async {
        transport.close();
        await server.close(force: true);
      });
      final client = SeedAudioClient(
        transport,
        'key',
        timeout: const Duration(milliseconds: 100),
        providerType: 'volcengine',
      );
      await expectLater(
        client.generate(request()),
        throwsA(
          isA<AudioException>().having(
            (e) => e.code,
            'code',
            'audio_submission_unknown',
          ),
        ),
      );
      await transport.aborted.future.timeout(const Duration(seconds: 2));
    },
  );
  for (final (status, code) in [
    (401, 'authentication'),
    (429, 'rate_limited'),
  ]) {
    test('non-JSON HTTP $status retains the known failure', () async {
      var posts = 0;
      final client = SeedAudioClient(
        MockClient((_) async {
          posts++;
          return http.Response('<html>gateway error</html>', status);
        }),
        'key',
        providerType: 'volcengine',
      );
      await expectLater(
        client.generate(request()),
        throwsA(isA<AudioException>().having((e) => e.code, 'code', code)),
      );
      expect(posts, 1);
    });
  }
  test('official ID and prompt boundaries are explicit', () {
    expect(lookupAudioModel('seed-audio-1.0-fast'), isNull);
    final c = AudioCapabilities('seed-audio-1.0');
    c.validate(request(text: List.filled(3000, '音').join()));
    expect(
      () => c.validate(request(text: List.filled(3001, '音').join())),
      throwsA(isA<AudioException>()),
    );
    expect(
      () => c.validate(request(text: ' ')),
      throwsA(isA<AudioException>()),
    );
  });
  test(
    'official request has separate key, fixed WAV settings and top-level audio',
    () async {
      final client = SeedAudioClient(
        MockClient((r) async {
          expect(r.url, SeedAudioClient.endpoint);
          expect(r.headers['X-Api-Key'], 'secret');
          expect(r.headers.containsKey('Authorization'), false);
          expect(jsonDecode(r.body), {
            'model': 'seed-audio-1.0',
            'text_prompt': 'Hello',
            'audio_config': {'format': 'wav', 'sample_rate': 24000},
          });
          return http.Response(
            jsonEncode({'audio': base64Encode(wav), 'duration': 1}),
            200,
          );
        }),
        'secret',
        providerType: 'volcengine',
      );
      expect((await client.generate(request())).bytes, wav);
      expect(
        () => SeedAudioClient.decode({
          'audio': base64Encode([1, 2]),
        }),
        throwsFormatException,
      );
    },
  );
  test('timeout and malformed success never trigger another POST', () async {
    for (final timeout in [true, false]) {
      var calls = 0;
      final client = SeedAudioClient(
        MockClient((_) async {
          calls++;
          if (timeout) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          return http.Response('{}', 200);
        }),
        'key',
        timeout: const Duration(milliseconds: 1),
        providerType: 'volcengine',
      );
      await expectLater(
        client.generate(request()),
        throwsA(isA<AudioException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(calls, 1);
    }
  });
  test('already cancelled generation never sends a request', () async {
    var posts = 0;
    final client = SeedAudioClient(
      MockClient((_) async {
        posts++;
        return http.Response('{}', 200);
      }),
      'key',
      providerType: 'volcengine',
    );
    final abort = Completer<void>()..complete();
    await expectLater(
      client.generate(request(), abortTrigger: abort.future),
      throwsA(isA<AudioException>().having((e) => e.code, 'code', 'cancelled')),
    );
    expect(posts, 0);
  });
  test(
    'program errors retain their identity rather than becoming submission failures',
    () async {
      final bug = StateError('unexpected program error');
      final client = SeedAudioClient(
        MockClient((_) async => throw bug),
        'key',
        providerType: 'volcengine',
      );
      await expectLater(client.generate(request()), throwsA(same(bug)));
    },
  );
  test(
    'catalog applies count, mixing, MIME, size, duration and numbering limits',
    () {
      const c = AudioCapabilities('seed-audio-1.0');
      AudioReference audio({
        int size = 10 * 1024 * 1024,
        int? duration = 30000,
        String mime = 'audio/wav',
      }) => AudioReference(
        assetId: 'media/a.wav',
        kind: 'audio',
        mimeType: mime,
        bytes: size,
        durationMs: duration,
      );
      const image = AudioReference(
        assetId: 'images/a.png',
        kind: 'image',
        mimeType: 'image/png',
        bytes: 1,
      );
      AudioRequest withRefs(
        List<AudioReference> refs, {
        String prompt = 'Hello',
      }) => AudioRequest(
        providerId: 'p',
        modelId: 'seed-audio-1.0',
        prompt: prompt,
        originalPrompt: prompt,
        references: refs,
      );
      c.validate(
        withRefs([audio(), audio(), audio()], prompt: '@Audio3 speaks'),
      );
      c.validate(withRefs([audio()], prompt: '@音频1 speaks'));
      c.validate(withRefs([image]));
      for (final invalid in [
        withRefs([audio(), audio(), audio(), audio()]),
        withRefs([image, image]),
        withRefs([audio(), image]),
        withRefs([audio(size: 10 * 1024 * 1024 + 1)]),
        withRefs([audio(duration: 30001)]),
        withRefs([audio(duration: null)]),
        withRefs([audio(mime: 'audio/flac')]),
        withRefs([audio()], prompt: '@Audio2'),
        withRefs([image], prompt: '@Audio1'),
        withRefs([audio()], prompt: '@音频2'),
        withRefs([image], prompt: '@音频1'),
      ]) {
        expect(() => c.validate(invalid), throwsA(isA<AudioException>()));
      }
    },
  );
  test(
    'result download carries no credentials and expired URLs do not retry',
    () async {
      var gets = 0;
      final client = MockClient((r) async {
        gets++;
        expect(r.method, 'GET');
        expect(r.headers.containsKey('X-Api-Key'), false);
        expect(r.headers.containsKey('Authorization'), false);
        return http.Response('expired', 403);
      });
      await expectLater(
        downloadAudioOutput(
          Uri.https('outputs.example', '/expired'),
          httpClient: client,
        ),
        throwsA(
          isA<AudioException>().having(
            (e) => e.code,
            'code',
            'audio_output_unavailable',
          ),
        ),
      );
      expect(gets, 1);
      await expectLater(
        downloadAudioOutput(
          Uri.parse('http://outputs.example/file'),
          httpClient: client,
        ),
        throwsA(isA<AudioException>()),
      );
      expect(gets, 1);
    },
  );
  test(
    'audio download retries transient TLS failures and logs safe stages',
    () async {
      final lines = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) {
          lines.add(message);
        }
      };
      addTearDown(() => debugPrint = original);
      var gets = 0;
      final result = await downloadAudioOutput(
        Uri.parse('https://outputs.example/audio.wav?token=private-signature'),
        retryDelay: Duration.zero,
        httpClient: MockClient((r) async {
          gets++;
          expect(r.headers.containsKey('Authorization'), false);
          if (gets < 3) {
            throw const HandshakeException(
              'Connection terminated during handshake https://outputs.example/audio.wav?token=private-signature',
            );
          }
          return http.Response.bytes(wav, 200);
        }),
      );
      expect(result, wav);
      expect(gets, 3);
      final log = lines.join('\n');
      expect(log, contains('phase=download'));
      expect(log, contains('host=outputs.example'));
      expect(log, contains('attempt=3/3'));
      expect(log, contains('HandshakeException'));
      expect(log, contains('bytes=44'));
      expect(
        log,
        contains('https://outputs.example/audio.wav?token=private-signature'),
      );
    },
  );

  test('audio download retries 503 but stops after three attempts', () async {
    var gets = 0;
    await expectLater(
      downloadAudioOutput(
        Uri.parse('https://outputs.example/audio.wav'),
        retryDelay: Duration.zero,
        httpClient: MockClient((_) async {
          gets++;
          return http.Response('busy', 503);
        }),
      ),
      throwsA(
        isA<AudioException>().having(
          (e) => e.code,
          'code',
          'audio_output_unavailable',
        ),
      ),
    );
    expect(gets, 3);
  });

  test('cancelling download backoff stops further attempts', () async {
    final abort = Completer<void>();
    var gets = 0;
    final received = Completer<void>();
    final pending = downloadAudioOutput(
      Uri.parse('https://outputs.example/audio.wav'),
      abortTrigger: abort.future,
      retryDelay: const Duration(minutes: 1),
      httpClient: MockClient((_) async {
        gets++;
        received.complete();
        throw const SocketException('reset');
      }),
    );
    final checked = expectLater(
      pending,
      throwsA(isA<AudioException>().having((e) => e.code, 'code', 'cancelled')),
    );
    await received.future;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    abort.complete();
    await checked.timeout(const Duration(seconds: 1));
    expect(gets, 1);
  });

  test('download timeout aborts each transport before retrying', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((incoming) async {
      requests++;
      await incoming.drain<void>();
    });
    final transport = _LocalClient(server.port);
    addTearDown(() async {
      transport.close();
      await server.close(force: true);
    });
    await expectLater(
      downloadAudioOutput(
        Uri.parse('https://outputs.example/audio.wav'),
        httpClient: transport,
        timeout: const Duration(milliseconds: 50),
        retryDelay: Duration.zero,
      ),
      throwsA(
        isA<AudioException>().having(
          (e) => e.code,
          'code',
          'audio_output_unavailable',
        ),
      ),
    );
    await transport.aborted.future.timeout(const Duration(seconds: 1));
    expect(requests, 3);
  });
}

/// Keep the production endpoint fixed while exercising the real IO transport.
class _LocalClient extends http.BaseClient {
  _LocalClient(this.port);
  final int port;
  final _inner = IOClient(HttpClient()..findProxy = (_) => 'DIRECT');
  final aborted = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final source = request as http.AbortableRequest;
    final local = http.AbortableRequest(
      source.method,
      Uri.http('127.0.0.1:$port', source.url.path),
      abortTrigger: source.abortTrigger,
    )..bodyBytes = source.bodyBytes;
    try {
      return await _inner.send(local);
    } on http.RequestAbortedException {
      if (!aborted.isCompleted) {
        aborted.complete();
      }
      rethrow;
    }
  }

  @override
  void close() => _inner.close();
}

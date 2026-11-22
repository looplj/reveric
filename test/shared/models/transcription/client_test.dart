// 职责: 校验 DashScope 和豆包标准版异步转写的 HTTP 请求与回执。
// 关联文件:
//   lib/shared/services/ai/transcription/client.dart
//   lib/shared/models/transcription/catalog.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/transcription/catalog.dart';
import 'package:reveric/shared/models/transcription/result.dart';
import 'package:reveric/shared/services/ai/transcription/client.dart';

void main() {
  late Directory root;
  late File audio;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('transcription-client-');
    audio = await File.fromUri(
      root.uri.resolve('input.mp3'),
    ).writeAsBytes([1, 2, 3]);
  });
  tearDown(() async => root.delete(recursive: true));

  test('ASR lists use the configured model and clear a removed default', () {
    const modelId = 'volc.seedasr.auc';
    final provider = aiProviderBuiltinById('openai')!.copyWith(
      type: 'doubao_audio',
      models: const [],
      imageModels: const [],
      audioModels: const [],
      videoModels: const [],
      apiKey: 'fixture-speech-key',
      asrModels: const [modelId],
      enabled: true,
    );
    expect(provider.isValid, true);
    expect(provider.modelsForKind(AiModelKind.asr), [modelId]);
    final optionId = '${provider.id}::$modelId';
    final settings = AiSettings(
      providers: [provider],
    ).setDefaultOptionId(AiModelKind.asr, optionId);
    expect(AiSettings.fromJson(settings.toJson()).defaultAsrModelId, optionId);
    final afterRemoval = settings.updateConfig(
      provider.copyWith(asrModels: const []),
    );
    expect(afterRemoval.defaultAsrModelId, isNull);
  });

  test(
    'DashScope uses the ASR endpoint and downloads results without bearer credentials',
    () async {
      final provider = aiProviderBuiltinById('openai')!.copyWith(
        type: 'qwen',
        apiKey: 'fixture-key',
        baseUrl: 'https://test.cn-beijing.maas.aliyuncs.com/compatible-mode/v1',
      );
      final client = MockClient((request) async {
        switch (request.url.path) {
          case '/api/v1/services/audio/asr/transcription':
            expect(request.headers['x-dashscope-async'], 'enable');
            expect(
              jsonDecode(request.body)['input']['file_url'],
              'https://example.com/input.mp3',
            );
            return http.Response('{"output":{"task_id":"fixture-task"}}', 200);
          case '/api/v1/tasks/fixture-task':
            expect(request.headers['authorization'], 'Bearer fixture-key');
            expect(request.headers['x-dashscope-async'], isNull);
            return http.Response(
              '{"output":{"task_id":"fixture-task","task_status":"SUCCEEDED","result":{"transcription_url":"https://example.com/result.json"}}}',
              200,
            );
          case '/result.json':
            expect(request.headers['authorization'], isNull);
            return http.Response(
              '{"transcripts":[{"text":"hello","sentences":[{"begin_time":500,"end_time":750,"text":"hello"}]}]}',
              200,
            );
          default:
            fail('Unexpected request ${request.url}');
        }
      });
      addTearDown(client.close);
      final adapter = TranscriptionClient(
        client,
        provider,
        lookupAsrModel('qwen', 'qwen3-asr-flash-filetrans')!,
      );
      final receipt = await adapter.submit(
        audio,
        'mp3',
        sourceUrl: Uri.parse('https://example.com/input.mp3'),
      );
      final result = await adapter.query(receipt.remoteId!);
      expect(result?.segments.single.startUs, 500000);
    },
  );

  for (final modelId in ['volc.seedasr.auc', 'volc.bigasr.auc']) {
    test('Doubao submits and queries standard ASR with $modelId', () async {
      final provider = aiProviderBuiltinById(
        'openai',
      )!.copyWith(type: 'doubao_audio', apiKey: 'fixture-speech-key');
      final sourceUrl = Uri.parse(
        'https://storage.example/audio.mp3?signature=example',
      );
      String? taskId;
      var queries = 0;
      final client = MockClient((request) async {
        expect(request.url.host, 'openspeech.bytedance.com');
        expect(request.method, 'POST');
        expect(request.headers['x-api-key'], 'fixture-speech-key');
        expect(request.headers['x-api-resource-id'], modelId);
        final body = jsonDecode(request.body);
        switch (request.url.path) {
          case '/api/v3/auc/bigmodel/submit':
            taskId = request.headers['x-api-request-id'];
            expect(taskId, isNotEmpty);
            expect(request.headers['x-api-sequence'], '-1');
            expect(body['user'], {'uid': provider.id});
            expect(body['audio'], {
              'url': sourceUrl.toString(),
              'format': 'mp3',
            });
            expect(body['request']['model_name'], 'bigmodel');
            expect(body['request']['show_utterances'], true);
            return http.Response(
              '',
              200,
              headers: {'x-api-status-code': '20000000'},
            );
          case '/api/v3/auc/bigmodel/query':
            expect(request.headers['x-api-request-id'], taskId);
            expect(request.headers, isNot(contains('x-api-sequence')));
            expect(body, isEmpty);
            return switch (queries++) {
              0 => http.Response(
                '',
                200,
                headers: {'x-api-status-code': '20000002'},
              ),
              1 => http.Response('service unavailable', 503),
              2 => http.Response(
                '',
                200,
                headers: {'x-api-status-code': '20000001'},
              ),
              _ => http.Response(
                '{"result":{"text":"hello","utterances":[{"text":"hello","start_time":125,"end_time":600}]}}',
                200,
                headers: {'x-api-status-code': '20000000'},
              ),
            };
          default:
            fail('Unexpected request ${request.url}');
        }
      });
      addTearDown(client.close);
      final adapter = TranscriptionClient(
        client,
        provider,
        lookupAsrModel('doubao_audio', modelId)!,
      );
      await expectLater(
        adapter.submit(audio, 'mp3'),
        throwsA(
          isA<TranscriptionException>().having(
            (e) => e.code,
            'code',
            'object_storage_required',
          ),
        ),
      );
      final receipt = await adapter.submit(audio, 'mp3', sourceUrl: sourceUrl);
      expect(receipt.remoteId, taskId);
      expect(receipt.transcript, isNull);
      final id = receipt.remoteId!;
      expect(await adapter.query(id), isNull);
      await expectLater(
        adapter.query(id),
        throwsA(
          isA<TranscriptionException>().having(
            (e) => e.code,
            'code',
            'unavailable',
          ),
        ),
      );
      expect(await adapter.query(id), isNull);
      expect((await adapter.query(id))?.segments.single.startUs, 125000);
    });
  }
}

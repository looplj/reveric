// 职责: 校验 DashScope 异步转写和豆包极速版的实际 HTTP 请求形状。
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
    const modelId = 'volc.bigasr.auc_turbo';
    final provider = aiProviderBuiltinById('openai')!.copyWith(
      type: 'volcengine',
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

  test(
    'Doubao uses the configured provider key and normalizes millisecond utterances',
    () async {
      final provider = aiProviderBuiltinById(
        'openai',
      )!.copyWith(type: 'volcengine', apiKey: 'fixture-speech-key');
      final client = MockClient((request) async {
        expect(request.url.path, '/api/v3/auc/bigmodel/recognize/flash');
        expect(request.headers['x-api-key'], 'fixture-speech-key');
        expect(request.headers['x-api-resource-id'], 'volc.bigasr.auc_turbo');
        expect(
          jsonDecode(request.body)['audio']['data'],
          base64Encode([1, 2, 3]),
        );
        return http.Response(
          '{"result":{"text":"hello","utterances":[{"text":"hello","start_time":125,"end_time":600}]}}',
          200,
          headers: {'x-api-status-code': '20000000'},
        );
      });
      addTearDown(client.close);
      final result = await TranscriptionClient(
        client,
        provider,
        lookupAsrModel('volcengine', 'volc.bigasr.auc_turbo')!,
      ).submit(audio, 'mp3');
      expect(result.transcript?.segments.single.startUs, 125000);
      expect(result.remoteId, isNull);
    },
  );
}

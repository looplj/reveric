// 职责: 用真实插件、本地平台及磁盘数据库验证图片恢复状态、下载鉴权与候选幂等。
// 关联文件:
//   lib/shared/services/production/image_service.dart
//   lib/shared/services/ai/image/plugin.dart
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fjs/fjs.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/database/app_database.dart' as db;
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/generation/task.dart';
import 'package:reveric/shared/models/generation/provider_result.dart';
import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/services/ai/image.dart';
import 'package:reveric/shared/services/ai/image/output.dart';
import 'package:reveric/shared/services/image_library_service.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/services/production/image_service.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await LibFjs.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['FJS_PROBE_LIBRARY']!,
      ),
    );
  });
  test(
    'disk restart refreshes only pending candidate and preserves query state without resubmission',
    () async {
      HttpOverrides.global = null;
      final root = await Directory.systemTemp.createTemp('image-recovery-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => root.path,
          );
      await RevericPaths.initialize();
      var database = db.AppDatabase.forTest(
        NativeDatabase(File('${root.path}/tasks.sqlite')),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      final a = img.encodePng(
        img.Image(width: 2, height: 2)..setPixelRgb(0, 0, 255, 0, 0),
      );
      final b = img.encodePng(
        img.Image(width: 2, height: 2)..setPixelRgb(0, 0, 0, 255, 0),
      );
      final requests = <String>[];
      final queryStates = <String>[];
      final downloadEntered = Completer<void>();
      var holdDownload = true;
      server.listen((request) async {
        requests.add(request.uri.path);
        if (request.uri.path == '/query') {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          expect(body['remoteTaskId'], 'remote-1');
          final cursor = body['state']['cursor'] as String;
          queryStates.add(cursor);
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(
              cursor == 'initial'
                  ? {
                      'status': 'running',
                      'state': {'cursor': 'next'},
                    }
                  : {
                      'status': 'succeeded',
                      'outputs': [
                        {
                          'kind': 'url',
                          'url': '$origin/a-fresh',
                          'headers': {'X-Result': 'fresh-a'},
                        },
                        {
                          'kind': 'url',
                          'url': '$origin/b-fresh',
                          'headers': {'X-Result': 'fresh-b'},
                        },
                      ],
                    },
            ),
          );
        } else if (request.uri.path == '/a-old') {
          // Download headers are memory-only; recovered URLs are fetched without them.
          expect(request.headers.value('x-result'), isNull);
          request.response.add(a);
        } else if (request.uri.path == '/b-old' ||
            request.uri.path == '/expired') {
          request.response.statusCode = 403;
        } else if (request.uri.path == '/b-fresh') {
          expect(request.headers.value('x-result'), 'fresh-b');
          final row = await database.generationTaskDao.getById('task');
          expect(row!.imageOutputs!.items[0].path, isNotNull);
          request.response.add(b);
        } else if (request.uri.path == '/hold-download') {
          if (holdDownload) {
            downloadEntered.complete();
            return;
          }
          request.response.add(a);
        } else if (request.uri.path == '/legacy') {
          request.response.add(a);
        } else {
          fail(
            'Unexpected request including resubmit or completed candidate: ${request.uri}',
          );
        }
        await request.response.close();
      });
      PluginHostService hostFor(String version) {
        final manifest = PluginManifest.fromJson({
          'id': 'test.recovery',
          'name': 'Recovery',
          'version': version,
          'pluginApiVersion': '^1',
          'main': 'dist/index.js',
          'provider': {'name': 'Recovery'},
        });
        return PluginHostService(
          dao: database.pluginDao,
          registry: PluginRegistry(hostToolNames: {}),
          platform: 'macos',
          packages: () async => [
            PluginPackage(
              'memory',
              manifest,
              """var __revericPlugin={apply(setup){setup.provider.register({async listModels(){return [];},image:{async submit(){throw new Error('RESUBMIT FORBIDDEN');},async query(input,context){const response=await context.http.fetch('$origin/query',{method:'POST',body:JSON.stringify(input)});return JSON.parse(response.body);}}});}};""",
            ),
          ],
        );
      }

      var host = hostFor('1.0.0');
      ImageTaskService service() => ImageTaskService(
        database: database,
        images: buildImageLibraryService(database),
        pluginHost: host,
        invoke: (_, _, _, _, _, cancellation) async =>
            throw StateError('RESUBMIT FORBIDDEN'),
        beforeCreate: (_, _, _) async {},
        beforeSubmit: (_) async {},
        recoverSources: () async {},
      );
      var jobs = service();
      addTearDown(() async {
        await jobs.shutdown();
        await host.dispose();
        await database.close();
        await server.close(force: true);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              null,
            );
        await root.delete(recursive: true);
      });
      await host.start();
      await host.setEnabled('test.recovery', true);
      final provider = aiProviderBuiltinById('openai')!.copyWith(
        id: 'plugin-instance',
        type: 'plugin:test.recovery',
        enabled: true,
        apiKey: '',
        baseUrl: '',
      );
      final legacy = aiProviderBuiltinById(
        'openai',
      )!.copyWith(id: 'legacy-instance', enabled: true, apiKey: 'synthetic');
      await database.aiProviderDao.upsert(provider);
      await database.aiProviderDao.upsert(legacy);
      Future<void> create(String id, AiProvider selected, {String? url}) =>
          database.generationTaskDao.create(
            db.GenerationTasksCompanion.insert(
              id: id,
              kind: GenerationKind.image,
              novelId: 'novel',
              sourceType: 'production_clip',
              sourceId: id,
              providerId: selected.id,
              providerType: selected.type,
              modelId: 'workflow',
              requestJson: ImageGenerationRequest(
                ProductionImageRequest(
                  providerId: selected.id,
                  modelId: 'workflow',
                  originalPrompt: 'original',
                  prompt: 'final',
                  ratio: 'auto',
                  resolution: 'auto',
                  size: null,
                ),
              ),
              status: url == null
                  ? GenerationTaskStatus.running
                  : GenerationTaskStatus.action_required,
              outputUrl: Value(url),
            ),
          );
      await create('task', provider);
      await jobs.recordSubmission(
        'task',
        ProviderSubmitted('remote-1', state: {'cursor': 'initial'}),
      );
      await jobs.recordRemoteOutputs(
        'task',
        ProviderSucceeded([
          ProviderUrlOutput('$origin/a-old', headers: {'X-Result': 'old-a'}),
          ProviderUrlOutput('$origin/b-old', headers: {'X-Result': 'old-b'}),
        ]),
        ImageOutputContext(provider, taskId: 'task'),
      );
      Future<void> restart(String version) async {
        await jobs.shutdown();
        await host.dispose();
        await database.close();
        database = db.AppDatabase.forTest(
          NativeDatabase(File('${root.path}/tasks.sqlite')),
        );
        host = hostFor(version);
        await host.start();
        jobs = service();
        await jobs.recover();
      }

      await restart('1.0.0');
      expect((await jobs.requireRun('task')).providerState, {
        'cursor': 'initial',
      });
      final firstRetry = jobs.retrySaveOutput('task');
      final repeatedRetry = jobs.retrySaveOutput('task');
      expect(identical(firstRetry, repeatedRetry), isTrue);
      await Future.wait([
        expectLater(firstRetry, throwsA(isA<AiImageFetchException>())),
        expectLater(repeatedRetry, throwsA(isA<AiImageFetchException>())),
      ]);
      final partial = await jobs.requireRun('task');
      expect(partial.providerState, {'cursor': 'next'});
      expect(partial.imageOutputs!.items[0].path, isNotNull);
      expect(partial.imageOutputs!.items[1].url, '$origin/b-old');
      final firstPath = partial.imageOutputs!.items[0].path;
      await host.setEnabled('test.recovery', false);
      await expectLater(
        jobs.retrySaveOutput('task'),
        throwsA(isA<AiImageFetchException>()),
      );
      expect(queryStates, ['initial']);
      expect((await jobs.requireRun('task')).providerTaskId, 'remote-1');
      expect((await jobs.requireRun('task')).providerState, {'cursor': 'next'});
      await host.setEnabled('test.recovery', true);

      await restart('2.0.0');
      await jobs.retrySaveOutput('task');
      final finished = await jobs.requireRun('task');
      expect(finished.status, GenerationTaskStatus.completed);
      expect(finished.imageOutputs!.items, hasLength(2));
      expect(
        finished.imageOutputs!.items.every((item) => item.assetId != null),
        isTrue,
      );
      expect(queryStates, ['initial', 'next']);
      expect(requests.where((value) => value == '/a-old'), hasLength(1));
      expect(requests.where((value) => value == '/a-fresh'), isEmpty);
      expect(
        await File(RevericPaths.resolveStored(firstPath)!).readAsBytes(),
        a,
      );
      expect(await database.select(database.assets).get(), hasLength(2));
      await jobs.retrySaveOutput('task');
      expect(await database.select(database.assets).get(), hasLength(2));
      await create('legacy', legacy, url: '$origin/legacy');
      await jobs.retrySaveOutput('legacy');
      expect(
        (await jobs.requireRun('legacy')).status,
        GenerationTaskStatus.completed,
      );
      expect(await database.select(database.assets).get(), hasLength(2));
      await create('unrefreshable', legacy, url: '$origin/expired');
      await expectLater(
        jobs.retrySaveOutput('unrefreshable'),
        throwsA(isA<AiImageFetchException>()),
      );
      expect(
        (await jobs.requireRun('unrefreshable')).errorCode,
        'output_reference_unrefreshable',
      );
      expect(queryStates, ['initial', 'next']);
      await create('known-id-error', provider);
      await jobs.recordSubmission(
        'known-id-error',
        ProviderSubmitted('remote-error', state: {'cursor': 'kept'}),
      );
      await jobs.recordFailure(
        'known-id-error',
        StateError('query interrupted'),
        StackTrace.current,
      );
      expect(
        (await jobs.requireRun('known-id-error')).status,
        GenerationTaskStatus.action_required,
      );
      await jobs.recordFailure(
        'known-id-error',
        const AiImageTerminalException('expired', status: 'expired'),
        StackTrace.current,
      );
      expect(
        (await jobs.requireRun('known-id-error')).status,
        GenerationTaskStatus.expired,
      );
      await create('cancelled-known', provider);
      await jobs.cancel('cancelled-known');
      await jobs.recordSubmission(
        'cancelled-known',
        ProviderSubmitted('late-id', state: {'cursor': 'accepted'}),
      );
      final cancelled = await jobs.requireRun('cancelled-known');
      expect(cancelled.status, GenerationTaskStatus.action_required);
      expect(cancelled.providerTaskId, 'late-id');
      expect(cancelled.providerState, {'cursor': 'accepted'});
      await create('cancel-download', legacy, url: '$origin/hold-download');
      final pendingDownload = jobs.retrySaveOutput('cancel-download');
      final stoppedDownload = expectLater(
        pendingDownload,
        throwsA(isA<AiImageFetchException>()),
      );
      await downloadEntered.future.timeout(const Duration(seconds: 5));
      await jobs.cancel('cancel-download');
      await stoppedDownload.timeout(const Duration(seconds: 2));
      expect(
        (await jobs.requireRun('cancel-download')).status,
        GenerationTaskStatus.action_required,
      );
      expect(queryStates, ['initial', 'next']);
      holdDownload = false;
      await jobs.retrySaveOutput('cancel-download');
      expect(
        (await jobs.requireRun('cancel-download')).status,
        GenerationTaskStatus.completed,
      );
      expect(await database.select(database.assets).get(), hasLength(2));
    },
  );
}

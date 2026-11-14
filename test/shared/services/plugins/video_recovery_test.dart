// 职责: 以真实插件、本地平台及磁盘重启验证视频单次提交、查询状态和下载凭据恢复。
// 关联文件:
//   lib/shared/services/ai/video/task_service.dart
//   lib/shared/services/ai/video/plugin.dart
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fjs/fjs.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart' as db;
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/generation/task.dart';
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/services/ai/video/reference_storage_service.dart';
import 'package:reveric/shared/services/ai/video/task_service.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import '../../../helpers/fake_object_storage.dart';

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
    'POST query and disk restart refresh URL plus headers without resubmission',
    () async {
      HttpOverrides.global = null;
      final root = await Directory.systemTemp.createTemp(
        'video-plugin-recovery-',
      );
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
      var submits = 0;
      var queries = 0;
      var querySuccess = false;
      var omitState = false;
      var fresh = false;
      var downloads = 0;
      var malformed = false;
      var invalidDetail = false;
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/submit') {
          expect(request.method, 'POST');
          submits++;
          final input =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          expect(input['request']['defaults']['custom'], {'node': 42});
          expect(input['references'], isEmpty);
          final row = await database.generationTaskDao.getById('task');
          expect(row!.status, GenerationTaskStatus.submitting);
          request.response.write(
            jsonEncode({
              'status': 'submitted',
              'remoteTaskId': 'remote',
              'state': {'cursor': 'submitted', 'replaceMe': true},
            }),
          );
        } else if (request.uri.path == '/query') {
          expect(request.method, 'POST');
          queries++;
          final input =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          expect(input['remoteTaskId'], 'remote');
          expect(input['state'], {
            'cursor': queries == 1 ? 'submitted' : 'running',
            if (queries == 1) 'replaceMe': true,
          });
          request.response.write(
            jsonEncode(
              invalidDetail
                  ? {
                      'status': 'failed',
                      'error': {
                        'code': 'upstream_failed',
                        'message': 'failed',
                        'detail': 123,
                      },
                    }
                  : !querySuccess
                  ? {
                      'status': 'running',
                      if (!omitState) 'state': {'cursor': 'running'},
                    }
                  : {
                      'status': 'succeeded',
                      'outputs': [
                        if (malformed) {'kind': 'url', 'url': '$origin/extra'},
                        {
                          'kind': 'url',
                          'url': '$origin/${fresh ? 'redirect' : 'expired'}',
                          if (!fresh) 'headers': {'X-Output': 'old'},
                        },
                      ],
                    },
            ),
          );
        } else if (request.uri.path == '/expired') {
          downloads++;
          expect(request.headers.value('x-output'), 'old');
          final row = await database.generationTaskDao.getById('task');
          expect(row!.status, GenerationTaskStatus.saving);
          expect(row.outputUrl, '$origin/expired');
          request.response.statusCode = 403;
        } else if (request.uri.path == '/redirect') {
          downloads++;
          expect(request.headers.value('x-output'), isNull);
          final row = await database.generationTaskDao.getById('task');
          expect(row!.outputUrl, '$origin/redirect');
          request.response.statusCode = 302;
          request.response.headers.set('location', '$origin/result');
        } else if (request.uri.path == '/result') {
          expect(request.headers.value('authorization'), isNull);
          expect(request.headers.value('x-output'), isNull);
          request.response.add([1, 2, 3, 4]);
        } else {
          fail('Unexpected request: ${request.uri}');
        }
        await request.response.close();
      });
      final model = {
        'id': 'workflow',
        'kind': 'video',
        'capabilities': {
          'ratios': ['16:9'],
          'resolutions': ['720p'],
          'durations': [5],
          'modes': ['text'],
          'frameRoles': [],
          'maxMiddleFrames': 0,
          'maxReferences': 0,
          'references': {},
          'supportsAudioOnlyReference': false,
          'supportsAdaptiveTextRatio': false,
          'supportsLastFrameOnly': false,
          'framesRequireAdaptiveRatio': false,
          'supportsCertifiedAssets': false,
          'draft': null,
        },
        'requestDefaults': {
          'custom': {'node': 42},
        },
      };
      PluginHostService makeHost(String version) => PluginHostService(
        dao: database.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        platform: 'macos',
        packages: () async => [
          PluginPackage(
            'memory',
            PluginManifest.fromJson({
              'id': 'test.video',
              'name': 'Video',
              'version': version,
              'pluginApiVersion': '^1',
              'main': 'dist/index.js',
              'provider': {'name': 'Video'},
            }),
            """var __revericPlugin={apply(setup){setup.provider.register({async listModels(){return ${version == '1.0.0' ? jsonEncode([model]) : '[]'};},video:{async submit(input,ctx){const r=await ctx.video.request('$origin/submit',{method:'POST',body:{kind:'json',value:input},response:{kind:'json'}});return r.body;},async query(input,ctx){const r=await ctx.video.request('$origin/query',{method:'POST',body:{kind:'json',value:input},response:{kind:'json'}});return r.body;}}});}};""",
          ),
        ],
      );
      var host = makeHost('1.0.0');
      final referenceServices = <ReferenceStorageService>[];
      VideoTaskService makeService() {
        final refs = ReferenceStorageService(
          database: database,
          pluginHost: host,
          storage: FakeObjectStorage(database, null),
          probe: (_, {cancellation}) async =>
              throw StateError('No input references'),
        );
        referenceServices.add(refs);
        return VideoTaskService(
          database: database,
          rootDirectory: root,
          references: refs,
          pluginHost: host,
          probeResult: (_) async => const MediaInfo(
            duration: Duration(seconds: 5),
            hasVideo: true,
            hasAudio: false,
            width: 1280,
            height: 720,
          ),
        );
      }

      var jobs = makeService();
      addTearDown(() async {
        await jobs.shutdown();
        for (final refs in referenceServices) {
          refs.dispose();
        }
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
      await host.setEnabled('test.video', true);
      var provider = aiProviderBuiltinById('openai')!.copyWith(
        id: 'instance',
        type: 'plugin:test.video',
        enabled: true,
        apiKey: '',
        baseUrl: '',
      );
      await database.aiProviderDao.upsert(provider);
      provider = await host.saveProviderModels(
        await host.discoverProviderModels(provider),
        {(AiModelKind.video, 'workflow')},
        saveProvider: database.aiProviderDao.upsert,
      );
      await jobs.create(
        id: 'task',
        novelId: 'novel',
        sourceType: 'production_clip',
        sourceId: 'clip',
        providerId: provider.id,
        request: const VideoRequest(
          modelId: 'workflow',
          prompt: 'bird',
          mode: VideoMode.text,
          resolution: '720p',
          ratio: '16:9',
        ),
      );
      await jobs.submit('task');
      expect((await jobs.getTask('task'))!.providerState, {
        'cursor': 'submitted',
        'replaceMe': true,
      });
      await jobs.refresh('task');
      omitState = true;
      await jobs.refresh('task');
      expect(
        (await jobs.getTask('task'))!.providerState,
        {'cursor': 'running'},
        reason: 'Absent query state retains the previous state',
      );
      querySuccess = true;
      expect((await jobs.getTask('task'))!.providerState, {
        'cursor': 'running',
      });
      await jobs.refresh('task');
      expect((await jobs.getTask('task'))!.status, GenerationTaskStatus.saving);
      await jobs.shutdown();
      await host.dispose();
      await database.close();
      database = db.AppDatabase.forTest(
        NativeDatabase(File('${root.path}/tasks.sqlite')),
      );
      host = makeHost('2.0.0');
      await host.start();
      jobs = makeService();
      fresh = true;
      await jobs.refresh('task');
      final result = (await jobs.getTask('task'))!;
      expect(result.status, GenerationTaskStatus.completed);
      expect(result.resultAssetId, isNotNull);
      expect(result.pollingUrl, isNull);
      expect(await File('${root.path}/${result.path}').readAsBytes(), [
        1,
        2,
        3,
        4,
      ]);
      await jobs.refresh('task');
      expect(submits, 1);
      expect(queries, 4);
      expect(downloads, 2);
      malformed = true;
      await database.generationTaskDao.create(
        db.GenerationTasksCompanion.insert(
          id: 'invalid',
          kind: GenerationKind.video,
          novelId: 'novel',
          sourceType: 'production_clip',
          sourceId: 'invalid',
          providerId: provider.id,
          providerType: provider.type,
          modelId: 'workflow',
          status: GenerationTaskStatus.running,
          requestJson: result.requestJson,
          providerTaskId: const Value('remote'),
          providerState: const Value({'cursor': 'running'}),
        ),
      );
      await jobs.refresh('invalid');
      expect(
        (await jobs.getTask('invalid'))!.status,
        GenerationTaskStatus.reconciliation_required,
      );
      expect((await jobs.getTask('invalid'))!.providerTaskId, 'remote');
      final beforeQueries = queries;
      await jobs.refreshDue();
      expect(
        queries,
        beforeQueries,
        reason: 'Malformed success stops automatic polling',
      );
      expect(submits, 1);
      await host.setEnabled('test.video', false);
      await jobs.refresh('invalid');
      expect(
        (await jobs.getTask('invalid'))!.status,
        GenerationTaskStatus.action_required,
      );
      expect((await jobs.getTask('invalid'))!.providerTaskId, 'remote');
      await host.setEnabled('test.video', true);
      malformed = false;
      await jobs.resumeAfterConfigurationFixed('invalid');
      expect(
        (await jobs.getTask('invalid'))!.status,
        GenerationTaskStatus.completed,
      );
      expect(submits, 1);
      invalidDetail = true;
      await database.generationTaskDao.create(
        db.GenerationTasksCompanion.insert(
          id: 'invalid-detail',
          kind: GenerationKind.video,
          novelId: 'novel',
          sourceType: 'production_clip',
          sourceId: 'invalid-detail',
          providerId: provider.id,
          providerType: provider.type,
          modelId: 'workflow',
          status: GenerationTaskStatus.running,
          requestJson: result.requestJson,
          providerTaskId: const Value('remote'),
          providerState: const Value({'cursor': 'running'}),
        ),
      );
      await jobs.refresh('invalid-detail');
      final invalid = (await jobs.getTask('invalid-detail'))!;
      expect(invalid.status, GenerationTaskStatus.reconciliation_required);
      expect(invalid.errorCode, 'invalid_response');
      expect(invalid.errorDetail, contains('error.detail'));
      expect(invalid.providerTaskId, 'remote');
      expect(invalid.providerState, {'cursor': 'running'});
      expect(invalid.nextPollAt, isNull);
      final afterInvalid = queries;
      await jobs.refreshDue();
      expect(queries, afterInvalid);
      expect(submits, 1);
    },
  );
}

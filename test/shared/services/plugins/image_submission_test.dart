// 职责: 用本地已受理断线与真实 FJS 验证提交不确定、明确拒绝和畸形回执的持久化分类。
// 关联文件:
//   lib/shared/services/ai/image.dart
//   lib/shared/services/production/image_service.dart
//   lib/shared/providers/production_images.dart
import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:image/image.dart' as img;
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/providers/video_tasks.dart';
import 'package:reveric/shared/services/ai/video/reference_storage_service.dart';
import '../../../helpers/fake_object_storage.dart';
import 'package:drift/native.dart';
import 'package:fjs/fjs.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/plugin_providers.dart';
import 'package:reveric/shared/providers/production_images.dart';
import 'package:reveric/shared/services/image_library_service.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/services/production/image_service.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(
    () async => LibFjs.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['FJS_PROBE_LIBRARY']!,
      ),
    ),
  );
  test(
    'submit failure category survives facade and task storage without resubmit',
    () async {
      HttpOverrides.global = null;
      final root = await Directory.systemTemp.createTemp('image-submission-');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => root.path,
      );
      await RevericPaths.initialize();
      final db = AppDatabase.forTest(NativeDatabase.memory());
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      final calls = <String, int>{};
      String? editScenario;
      server.listen((request) async {
        if (request.uri.path == '/images/edits') {
          final body = utf8.decode(
            await request.fold<List<int>>(
              [],
              (all, chunk) => all..addAll(chunk),
            ),
            allowMalformed: true,
          );
          expect(request.method, 'POST');
          expect(body, contains('name="image[]"'));
          expect(body, contains('filename="reference.png"'));
          final scenario = editScenario!;
          calls[scenario] = (calls[scenario] ?? 0) + 1;
          request.response.headers.contentType = ContentType.json;
          request.response.write(scenario == 'edit-null' ? 'null' : '');
          await request.response.close();
          return;
        }
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final scenario = body['prompt'] as String;
        calls[scenario] = (calls[scenario] ?? 0) + 1;
        if (scenario.endsWith('drop')) {
          (await request.response.detachSocket()).destroy();
          return;
        }
        request.response.headers.contentType = ContentType.json;
        if (scenario.endsWith('rejected')) {
          request.response.statusCode = 400;
          request.response.write('{"error":{"message":"explicit rejection"}}');
        } else if (scenario.endsWith('server-error')) {
          request.response.statusCode = 500;
          request.response.write('{}');
        } else if (scenario.endsWith('malformed-bytes')) {
          request.response.write('{"data":[{"b64_json":"AQID"}]}');
        } else if (scenario.endsWith('invalid-id')) {
          request.response.write('{"status":"submitted","remoteTaskId":""}');
        } else if (scenario.endsWith('receipt')) {
          request.response.write(
            '{"status":"submitted","remoteTaskId":"accepted","state":{"cursor":7}}',
          );
        } else {
          request.response.write(
            scenario.startsWith('plugin')
                ? '{"status":"succeeded","outputs":[]}'
                : '{"data":[]}',
          );
        }
        await request.response.close();
      });
      final manifest = PluginManifest.fromJson({
        'id': 'test.submission',
        'name': 'Submission',
        'version': '1.0.0',
        'pluginApiVersion': '^1',
        'main': 'dist/index.js',
        'provider': {'name': 'Submission'},
      });
      final host = PluginHostService(
        dao: db.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        platform: 'macos',
        packages: () async => [
          PluginPackage(
            'memory',
            manifest,
            '''var __revericPlugin={apply(setup){setup.provider.register({
      async listModels(){return [{kind:'image',id:'workflow',capabilities:{ratios:['auto'],resolutions:['auto'],minReferences:0,maxReferences:0,unlimitedReferences:false,referenceTransport:'file'},requestDefaults:{}}];},
      image:{async submit(input,context){if(input.prompt.endsWith('configuration')){const e=new Error('missing configuration');e.code='configuration_required';throw e;}const response=await context.http.fetch('$origin/submit',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({prompt:input.prompt})});if(response.status===400){const e=new Error('explicit rejection');e.code='rejected';throw e;}return JSON.parse(response.body);},async query(){throw new Error('query unavailable');}}
    });}};''',
          ),
        ],
      );
      await host.start();
      await host.setEnabled(manifest.id, true);
      var plugin = aiProviderBuiltinById('openai')!.copyWith(
        id: 'plugin',
        type: 'plugin:test.submission',
        enabled: true,
        apiKey: '',
        baseUrl: '',
      );
      await db.aiProviderDao.upsert(plugin);
      plugin = await host.saveProviderModels(
        await host.discoverProviderModels(plugin),
        {(AiModelKind.image, 'workflow')},
        saveProvider: db.aiProviderDao.upsert,
      );
      final native = aiProviderBuiltinById('openai')!.copyWith(
        id: 'native',
        enabled: true,
        apiKey: 'synthetic',
        baseUrl: origin,
      );
      await db.aiProviderDao.upsert(native);
      final references = ReferenceStorageService(
        database: db,
        storage: FakeObjectStorage(db, null),
        probe: (_, {cancellation}) async => const MediaInfo(
          duration: Duration.zero,
          hasVideo: true,
          hasAudio: false,
          width: 2,
          height: 2,
        ),
      );
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          pluginHostServiceProvider.overrideWithValue(host),
          referenceStorageServiceProvider.overrideWithValue(references),
        ],
      );
      final jobs = ImageTaskService(
        database: db,
        images: buildImageLibraryService(db),
        pluginHost: host,
        invoke: container.read(productionImageInvokeProvider),
        beforeCreate: (_, _, _) async {},
        beforeSubmit: (_) async {},
        recoverSources: () async {},
      );
      addTearDown(() async {
        await jobs.shutdown();
        references.dispose();
        container.dispose();
        await host.dispose();
        await db.close();
        await server.close(force: true);
        messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        await root.delete(recursive: true);
      });
      for (final provider in [plugin, native]) {
        for (final scenario in [
          'drop',
          'malformed',
          'rejected',
          if (!provider.isPluginProvider) ...[
            'malformed-bytes',
            'server-error',
          ],
          'configuration',
          if (provider.isPluginProvider) ...['invalid-id', 'receipt'],
        ]) {
          final id = '${provider.id}-$scenario';
          if (scenario == 'configuration' && !provider.isPluginProvider) {
            await db.aiProviderDao.upsert(provider.copyWith(apiKey: ''));
          }
          await jobs.submit(
            taskId: id,
            novelId: 'novel',
            sourceType: 'production_clip',
            sourceId: id,
            request: ProductionImageRequest(
              providerId: provider.id,
              modelId: provider.isPluginProvider ? 'workflow' : 'gpt-image-2',
              originalPrompt: id,
              prompt: id,
              ratio: provider.isPluginProvider ? 'auto' : '1:1',
              resolution: provider.isPluginProvider ? 'auto' : '2K',
              size: null,
            ),
          );
          final row = (await db.generationTaskDao.getById(id))!;
          expect(
            calls[id],
            scenario == 'configuration' ? isNull : 1,
            reason: id,
          );
          final reconcile =
              scenario == 'malformed' ||
              scenario == 'malformed-bytes' ||
              scenario == 'receipt';
          expect(
            row.status,
            reconcile
                ? GenerationTaskStatus.action_required
                : GenerationTaskStatus.failed,
            reason: id,
          );
          expect(row.errorCode, switch (scenario) {
            'malformed' || 'malformed-bytes' => 'invalid_outputs',
            'rejected' => 'rejected',
            'receipt' => 'result_fetch_failed',
            'configuration' => 'generation_failed',
            _ => 'submission_unknown',
          }, reason: id);
          if (scenario == 'rejected' && provider.isPluginProvider) {
            expect(row.errorMessage, 'explicit rejection', reason: id);
          }
          if (scenario == 'receipt') {
            expect(row.providerTaskId, 'accepted');
            expect(row.providerState, {'cursor': 7});
          }
        }
      }
      await db.aiProviderDao.upsert(native);
      final referenceFile = await File(
        '${root.path}/reference.png',
      ).writeAsBytes(img.encodePng(img.Image(width: 2, height: 2)));
      await db.assetDao.insertAsset(
        AssetsCompanion.insert(
          id: 'reference',
          type: 'image',
          purpose: 'reference',
          path: Value(referenceFile.path),
          content: const Value(ImageAssetContent(mimeType: 'image/png')),
        ),
      );
      for (final scenario in ['edit-null', 'edit-empty']) {
        editScenario = scenario;
        await jobs.submit(
          taskId: scenario,
          novelId: 'novel',
          sourceType: 'production_clip',
          sourceId: scenario,
          request: ProductionImageRequest(
            providerId: native.id,
            modelId: 'gpt-image-2',
            originalPrompt: scenario,
            prompt: scenario,
            ratio: '1:1',
            resolution: '2K',
            size: null,
            references: const [ProductionImageReference(assetId: 'reference')],
          ),
        );
        final task = (await db.generationTaskDao.getById(scenario))!;
        expect(calls[scenario], 1);
        expect(
          task.status,
          GenerationTaskStatus.action_required,
          reason: scenario,
        );
        expect(task.errorCode, 'invalid_outputs', reason: scenario);
      }
    },
  );
}

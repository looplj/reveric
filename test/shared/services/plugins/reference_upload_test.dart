// 职责: 用真实插件与本地上传端验证图片参考选路、跨任务缓存和实例上下文隔离。
// 关联文件:
//   lib/shared/services/ai/video/reference_storage_service.dart
//   lib/shared/services/plugins/host.dart
import 'dart:io';
import 'dart:async';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/image/config.dart';
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/models/provider_asset.dart';
import 'package:reveric/shared/services/ai/video/reference_storage_service.dart';
import 'package:reveric/shared/services/plugins/files.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';
import '../../../helpers/fake_object_storage.dart';

void main() {
  setUpAll(() async {
    final path = Platform.environment['FJS_PROBE_LIBRARY'];
    if (path == null) {
      throw StateError('Set FJS_PROBE_LIBRARY');
    }
    await LibFjs.init(externalLibrary: ExternalLibrary.open(path));
  });
  test(
    'file/url/uploaded preserve identity and cache respects instance configuration and version',
    () async {
      final database = AppDatabase.forTest(NativeDatabase.memory());
      final directory = await Directory.systemTemp.createTemp(
        'reference-plugin-test-',
      );
      final png = img.encodePng(img.Image(width: 2, height: 3));
      final file = await File(
        '${directory.path}/reference.png',
      ).writeAsBytes(png);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var uploads = 0;
      Completer<void>? uploadEntered;
      Completer<void>? uploadRelease;
      var ossUploads = 0;
      var reject = false;
      server.listen((request) async {
        expect(await request.fold<List<int>>([], (a, b) => a..addAll(b)), png);
        uploads++;
        final release = uploadRelease;
        uploadRelease = null;
        uploadEntered?.complete();
        uploadEntered = null;
        if (release != null) {
          await release.future;
        }
        request.response.statusCode = reject ? 500 : 200;
        request.response.write('remote-$uploads');
        await request.response.close();
      });
      final provider = aiProviderBuiltinById('openai')!.copyWith(
        id: 'instance-a',
        type: 'plugin:test.upload',
        enabled: true,
        apiKey: '',
        baseUrl: '',
      );
      final other = provider.copyWith(id: 'instance-b');
      await database.aiProviderDao.upsert(provider);
      await database.aiProviderDao.upsert(other);
      PluginHostService createHost(
        String version, {
        bool supportsUpload = true,
      }) {
        final manifest = PluginManifest.fromJson({
          'id': 'test.upload',
          'name': 'Upload',
          'version': version,
          'pluginApiVersion': '^1',
          'main': 'dist/index.js',
          'provider': {
            'name': 'Upload',
            'settings': {
              'fields': {
                'project': {'type': 'string', 'title': 'Project'},
                'token': {'type': 'secret', 'title': 'Token'},
              },
            },
          },
        });
        return PluginHostService(
          dao: database.pluginDao,
          registry: PluginRegistry(hostToolNames: {}),
          platform: 'macos',
          packages: () async => [
            PluginPackage(
              'memory',
              manifest,
              """var __revericPlugin={apply(setup){setup.provider.register({
        async listModels(){return [];},
${supportsUpload ? "async uploadReference(input, context){const response=await context.files.upload(input.file.handle,{kind:'raw',method:'PUT',url:'http://127.0.0.1:${server.port}/upload'});if(response.status!==200)throw new Error('upload failed');return {ref:response.body};}," : ''}
        image:{async submit(){return {status:'succeeded',outputs:[]};}}
      });}};""",
            ),
          ],
        );
      }

      var host = createHost('1.0.0');
      final services = <ReferenceStorageService>[];
      final objectStorage = FakeObjectStorage(database, ({
        required file,
        required sha256,
        required mimeType,
        required fileSize,
      }) async {
        ossUploads++;
        return (url: 'https://storage.example/image', expiresAt: null);
      });
      ReferenceStorageService service() {
        final value = ReferenceStorageService(
          database: database,
          pluginHost: host,
          storage: objectStorage,
          probe: (_, {cancellation}) async => const MediaInfo(
            duration: Duration.zero,
            hasAudio: false,
            hasVideo: true,
            width: 2,
            height: 3,
          ),
        );
        services.add(value);
        return value;
      }

      addTearDown(() async {
        for (final value in services) {
          value.dispose();
        }
        await host.dispose();
        await database.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
      });
      await host.start();
      await host.setEnabled('test.upload', true);
      var task = 0;
      Future<List<Map<String, dynamic>>> prepare(
        ReferenceStorageService storage,
        ImageReferenceTransport transport, {
        AiProvider? instance,
        String mime = 'image/png',
        String assetId = 'asset',
        AgentCancellationToken? cancellation,
      }) {
        final selected = instance ?? provider;
        final taskId = 'task-${task++}';
        final scope = PluginFileScope(
          pluginId: 'test.upload',
          providerId: selected.id,
          taskId: taskId,
        );
        return storage.prepareImages(
          [
            (
              ProductionImageReference(
                assetId: assetId,
                clipId: 'clip',
                inputId: 'input',
              ),
              file,
              mime,
            ),
          ],
          provider: selected,
          transport: transport,
          files: scope,
          taskId: taskId,
          cancellation: cancellation,
        );
      }

      for (final cancelFirst in [true, false]) {
        final shared = service();
        final first = AgentCancellationController();
        final second = AgentCancellationController();
        final entered = Completer<void>();
        final release = Completer<void>();
        uploadEntered = entered;
        uploadRelease = release;
        final submitted = <String>[];
        Future<void> generate(String id, AgentCancellationToken token) async {
          await prepare(
            shared,
            ImageReferenceTransport.uploaded,
            assetId: 'concurrent-$cancelFirst',
            cancellation: token,
          );
          submitted.add(id);
        }

        final one = generate('first', first.token);
        final oneResult = one.then<Object?>(
          (_) => null,
          onError: (Object e) => e,
        );
        await entered.future;
        final two = generate('second', second.token);
        final twoResult = two.then<Object?>(
          (_) => null,
          onError: (Object e) => e,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        (cancelFirst ? first : second).cancel();
        final cancelled = await (cancelFirst ? oneResult : twoResult).timeout(
          const Duration(seconds: 1),
        );
        expect(
          cancelled,
          isNotNull,
          reason: 'cancelled caller must exit before held upload finishes',
        );
        release.complete();
        expect(
          await (cancelFirst ? twoResult : oneResult),
          isNull,
          reason: 'independent caller must survive the other cancellation',
        );
        expect(submitted, [cancelFirst ? 'second' : 'first']);
      }
      uploads = 0;
      final initial = service();
      final local = (await prepare(
        initial,
        ImageReferenceTransport.file,
      )).single;
      expect(local['source']['kind'], 'file');
      expect(local['assetId'], 'asset');
      expect(local['clipId'], 'clip');
      expect(local['inputId'], 'input');
      expect(uploads, 0);
      expect(ossUploads, 0);
      expect(objectStorage.loads, 0);
      expect(
        (await prepare(initial, ImageReferenceTransport.url)).single['source'],
        {'kind': 'url', 'url': 'https://storage.example/image'},
      );
      expect(uploads, 0);
      expect(ossUploads, 1);
      expect(
        (await prepare(
          initial,
          ImageReferenceTransport.uploaded,
        )).single['source'],
        {'kind': 'uploaded', 'ref': 'remote-1'},
      );
      expect(uploads, 1);
      expect(ossUploads, 1);
      expect(
        (await prepare(
          service(),
          ImageReferenceTransport.uploaded,
        )).single['source']['ref'],
        'remote-1',
      );
      expect(uploads, 1);
      await prepare(initial, ImageReferenceTransport.uploaded, instance: other);
      expect(uploads, 2);
      await host.saveProviderConfig(
        provider,
        settings: {'project': 'changed'},
        secrets: {},
      );
      await prepare(initial, ImageReferenceTransport.uploaded);
      expect(uploads, 3);
      await host.saveProviderConfig(
        provider,
        settings: {},
        secrets: {'token': 'new-secret'},
      );
      await prepare(initial, ImageReferenceTransport.uploaded);
      expect(uploads, 4);
      await prepare(
        initial,
        ImageReferenceTransport.uploaded,
        mime: 'image/jpeg',
      );
      expect(uploads, 5);
      final row = await database.providerAssetDao.find(
        'asset',
        provider.id,
        kind: ProviderAssetKind.upload,
      );
      expect(row!.remoteUrl, 'remote-5');
      expect(row.remoteId, isNull);
      await database.providerAssetDao.write(
        row.id,
        ProviderAssetsCompanion(
          expiresAt: Value(DateTime.now().subtract(const Duration(seconds: 1))),
        ),
      );
      await prepare(
        initial,
        ImageReferenceTransport.uploaded,
        mime: 'image/jpeg',
      );
      expect(uploads, 6);
      await host.dispose();
      host = createHost('2.0.0');
      await host.start();
      await prepare(
        service(),
        ImageReferenceTransport.uploaded,
        mime: 'image/jpeg',
      );
      expect(uploads, 7);
      reject = true;
      await host.saveProviderConfig(
        provider,
        settings: {'project': 'reject'},
        secrets: {},
      );
      await expectLater(
        prepare(service(), ImageReferenceTransport.uploaded),
        throwsA(isA<PluginExecutionError>()),
      );
      expect(uploads, 8);
      expect(ossUploads, 1);
      expect(
        (await database.providerAssetDao.find(
          'asset',
          provider.id,
          kind: ProviderAssetKind.upload,
        ))!.status,
        ProviderAssetStatus.failed,
      );
      await host.dispose();
      host = createHost('3.0.0', supportsUpload: false);
      await host.start();
      await expectLater(
        prepare(service(), ImageReferenceTransport.uploaded),
        throwsA(
          isA<PluginHostError>().having(
            (e) => e.code,
            'code',
            'configuration_required',
          ),
        ),
      );
      expect(uploads, 8);
      expect(ossUploads, 1);
    },
  );
}

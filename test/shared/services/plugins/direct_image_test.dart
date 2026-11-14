// 职责: 验证直达图片入口使用同一声明与上传链，匿名引用按内容隔离缓存且保留参数和身份。
// 关联文件:
//   lib/shared/services/ai/image.dart
//   lib/shared/services/ai/video/reference_storage_service.dart
import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/models/image/config.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/providers/production_images.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/plugin_providers.dart';
import 'package:reveric/shared/providers/video_tasks.dart';
import 'package:drift/native.dart';
import 'package:fjs/fjs.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/database/app_database.dart' as db;
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/provider_model.dart';
import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/services/ai/image.dart';
import 'package:reveric/shared/services/ai/video/reference_storage_service.dart';
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
    'direct file/url/uploaded calls share metadata and content-based anonymous cache',
    () async {
      HttpOverrides.global = null;
      final root = await Directory.systemTemp.createTemp('direct-image-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => root.path,
          );
      await RevericPaths.initialize();
      final database = db.AppDatabase.forTest(NativeDatabase.memory());
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      final a = img.encodePng(
        img.Image(width: 2, height: 2)..setPixelRgb(0, 0, 255, 0, 0),
      );
      final b = img.encodePng(
        img.Image(width: 2, height: 2)..setPixelRgb(0, 0, 0, 255, 0),
      );
      final uploads = <List<int>>[];
      final generated = <Map<String, dynamic>>[];
      server.listen((request) async {
        if (request.uri.path == '/upload') {
          uploads.add(
            await request.fold<List<int>>([], (a, b) => a..addAll(b)),
          );
          request.response.write('platform-${uploads.length}');
        } else {
          expect(request.uri.path, '/generate');
          generated.add(
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>,
          );
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'image': base64Encode(a)}));
        }
        await request.response.close();
      });
      final models = [
        for (final transport in ['file', 'url', 'uploaded'])
          {
            'kind': 'image',
            'id': transport,
            'capabilities': {
              'ratios': ['9:13'],
              'resolutions': ['custom'],
              'sizes': {
                'custom': {'9:13': '900x1300'},
              },
              'minReferences': 1,
              'maxReferences': 1,
              'unlimitedReferences': false,
              'referenceTransport': transport,
            },
            'requestDefaults': {
              'workflow': {'node': transport},
              'seed': 123,
            },
          },
      ];
      final manifest = PluginManifest.fromJson({
        'id': 'test.direct',
        'name': 'Direct',
        'version': '1.0.0',
        'pluginApiVersion': '^1',
        'main': 'dist/index.js',
        'provider': {'name': 'Direct'},
      });
      final code =
          """var __revericPlugin={apply(setup){setup.provider.register({
      async listModels(){return ${jsonEncode(models)};},
      async uploadReference(input,context){if(!input.file.name.endsWith('.png'))throw new Error('file name lost MIME extension');const response=await context.files.upload(input.file.handle,{kind:'raw',method:'PUT',url:'$origin/upload'});return {ref:response.body};},
      image:{async submit(input,context){const ref=input.references[0];const source=ref.source;const response=await context.image.request('$origin/generate',{method:'POST',body:{kind:'json',value:{model:input.modelId,parameters:input.parameters,asset:ref.assetId,clip:ref.clipId??null,input:ref.inputId??null,kind:source.kind,reference:source.kind==='file'?null:(source.ref??source.url)},files:source.kind==='file'?[{pointer:'/reference',handle:source.handle,encoding:'data_uri'}]:[]},response:{kind:'json',images:[{pointer:'/image',encoding:'base64'}]}});return {status:'succeeded',outputs:[response.body.image]};}}
    });}};""";
      final host = PluginHostService(
        dao: database.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        platform: 'macos',
        packages: () async => [PluginPackage('memory', manifest, code)],
      );
      var stored = 0;
      final references = ReferenceStorageService(
        database: database,
        pluginHost: host,
        storage: FakeObjectStorage(database, ({
          required file,
          required sha256,
          required mimeType,
          required fileSize,
        }) async {
          stored++;
          return (url: '$origin/object/$sha256.png', expiresAt: null);
        }),
        probe: (_, {cancellation}) async => const MediaInfo(
          duration: Duration.zero,
          hasAudio: false,
          hasVideo: true,
          width: 2,
          height: 2,
        ),
      );
      addTearDown(() async {
        references.dispose();
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
      await host.setEnabled(manifest.id, true);
      var provider = aiProviderBuiltinById('openai')!.copyWith(
        id: 'direct-instance',
        type: 'plugin:test.direct',
        enabled: true,
        apiKey: '',
        baseUrl: '',
      );
      await database.aiProviderDao.upsert(provider);
      provider = await host.saveProviderModels(
        await host.discoverProviderModels(provider),
        {
          for (final id in ['file', 'url', 'uploaded']) (AiModelKind.image, id),
        },
        saveProvider: database.aiProviderDao.upsert,
      );
      Future<void> generate(
        String model,
        List<int> bytes, {
        String ratio = '9:13',
        List<ProductionImageReference>? identities,
      }) async {
        final declaration = resolveImageModel(provider, model)!;
        final service = await resolveDirectImageService(
          provider,
          model,
          host: host,
          references: references,
        );
        final result = await service.editImages(
          'prompt',
          imageData: ['data:image/png;base64,${base64Encode(bytes)}'],
          size: '900x1300',
          options: ImageInvocationOptions(
            aspectRatio: ratio,
            resolution: 'custom',
            capabilities: declaration.capabilities,
            defaults: declaration.rawDefaults,
            references: identities,
          ),
        );
        expect(await File(result.localFilePath!).readAsBytes(), a);
        await result.disposeTemporary();
      }

      await generate(
        'file',
        a,
        identities: const [
          ProductionImageReference(
            assetId: 'known',
            clipId: 'clip',
            inputId: 'input',
          ),
        ],
      );
      expect(generated.last['asset'], 'known');
      expect(generated.last['clip'], 'clip');
      expect(generated.last['input'], 'input');
      expect(
        generated.last['reference'],
        'data:image/png;base64,${base64Encode(a)}',
      );
      await generate('uploaded', a);
      final firstId = generated.last['asset'];
      await generate('uploaded', a);
      expect(generated.last['asset'], firstId);
      expect(generated.last['reference'], 'platform-1');
      await generate('uploaded', b);
      expect(generated.last['asset'], isNot(firstId));
      expect(generated.last['reference'], 'platform-2');
      expect(uploads, [a, b]);
      expect(stored, 0);
      await generate('url', a);
      expect(generated.last['kind'], 'url');
      expect(generated.last['reference'], startsWith('$origin/object/'));
      expect(stored, 1);
      expect(generated.last['parameters'], {
        'ratio': '9:13',
        'resolution': 'custom',
        'size': '900x1300',
        'defaults': {
          'workflow': {'node': 'url'},
          'seed': 123,
        },
      });
      await expectLater(
        generate('uploaded', a, ratio: '1:1'),
        throwsA(isA<AiImageGenerationException>()),
      );
      expect(uploads, hasLength(2));
      expect(generated, hasLength(5));
      final service = await resolveDirectImageService(
        provider,
        'file',
        host: host,
        references: references,
      );
      await service.editImages(
        'portrait',
        imageData: ['data:image/png;base64,${base64Encode(a)}'],
        options: const ImageInvocationOptions(preferredRatio: '1:1'),
      );
      expect((generated.last['parameters'] as Map)['ratio'], '9:13');
      expect((generated.last['parameters'] as Map)['resolution'], 'custom');
      expect((generated.last['parameters'] as Map)['size'], '900x1300');
      for (final invalid in ['complexity', 'quality']) {
        await expectLater(
          service.editImages(
            'invalid',
            imageData: ['data:image/png;base64,${base64Encode(a)}'],
            complexity: invalid == 'complexity' ? 'unsupported' : null,
            quality: invalid == 'quality' ? 'unsupported' : null,
          ),
          throwsA(isA<AiImageGenerationException>()),
        );
      }
      expect(generated, hasLength(6));
      final assetFile = await File('${root.path}/frozen.png').writeAsBytes(b);
      await database.assetDao.insertAsset(
        db.AssetsCompanion.insert(
          id: 'frozen-reference',
          type: 'image',
          purpose: 'reference',
          path: Value(assetFile.path),
          content: const Value(ImageAssetContent(mimeType: 'image/png')),
        ),
      );
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          pluginHostServiceProvider.overrideWithValue(host),
          referenceStorageServiceProvider.overrideWithValue(references),
        ],
      );
      addTearDown(container.dispose);
      final frozen = resolveImageModel(provider, 'uploaded')!.capabilities
          .merge(const ImageModelCapabilities(complexityLevels: {'fine'}));
      Future<void> production(String complexity) async {
        await container.read(productionImageInvokeProvider)(
          'frozen-$complexity',
          provider,
          ProductionImageRequest(
            providerId: provider.id,
            modelId: 'uploaded',
            originalPrompt: 'cover',
            prompt: 'cover',
            ratio: '9:13',
            resolution: 'custom',
            size: '900x1300',
            complexity: complexity,
            capabilities: frozen,
            requestDefaults: const {'frozen': true},
            references: const [
              ProductionImageReference(assetId: 'frozen-reference'),
            ],
          ),
          (_) async {},
          (_, _) async {},
          AgentCancellationController().token,
        );
      }

      await expectLater(production('unsupported'), throwsA(anything));
      expect(
        uploads,
        hasLength(2),
        reason: 'invalid frozen complexity must not upload',
      );
      expect(
        generated,
        hasLength(6),
        reason: 'invalid frozen complexity must not submit',
      );
      await production('fine');
      expect(uploads, hasLength(3));
      expect((generated.last['parameters'] as Map)['complexity'], 'fine');
      expect((generated.last['parameters'] as Map)['defaults'], {
        'frozen': true,
      });
      await database.aiProviderDao.upsert(provider.copyWith(enabled: false));
      await expectLater(generate('file', a), throwsA(anything));
      expect(generated, hasLength(7));
    },
  );
}

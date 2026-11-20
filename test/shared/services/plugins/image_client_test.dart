// 职责: 用真实 FJS 与本地工作流接口验证统一图片输入、同步/异步结果及文件归属拒绝。
// 关联文件:
//   lib/shared/services/ai/image/plugin.dart
//   lib/shared/services/plugins/media_files.dart
import 'dart:convert';
import 'dart:io';
import 'package:reveric/shared/models/image/config.dart';
import 'package:drift/native.dart';
import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/image/request.dart';
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/services/ai/image.dart';
import 'package:reveric/shared/services/ai/image/output.dart';
import 'package:reveric/shared/services/plugins/files.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/media_files.dart';
import 'package:reveric/shared/services/plugins/registry.dart';

void main() {
  setUpAll(() async {
    final path = Platform.environment['FJS_PROBE_LIBRARY'];
    if (path == null) {
      throw StateError('Set FJS_PROBE_LIBRARY');
    }
    await LibFjs.init(externalLibrary: ExternalLibrary.open(path));
  });
  test(
    'workflow consumes common input and query uses fresh file ownership without resubmit',
    () async {
      final database = AppDatabase.forTest(NativeDatabase.memory());
      final directory = await Directory.systemTemp.createTemp(
        'plugin-image-client-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final png = img.encodePng(img.Image(width: 3, height: 2));
      final requests = <Map<String, dynamic>>[];
      server.listen((request) async {
        expect(request.headers.value('authorization'), isNull);
        requests.add(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>,
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'result': base64Encode(png)}));
        await request.response.close();
      });
      final manifest = PluginManifest.fromJson({
        'id': 'test.image',
        'name': 'Workflow',
        'version': '1.0.0',
        'pluginApiVersion': '^1',
        'main': 'dist/index.js',
        'provider': {'name': 'Workflow'},
      });
      final code =
          """var __revericPlugin={apply(setup){setup.provider.register({
      async listModels(){return [];},
      image:{
        async submit(input,context){
          if(input.prompt==='async')return {status:'submitted',remoteTaskId:'job',state:{node:input.parameters.defaults.customNode}};
          if(input.prompt==='forged')return {status:'succeeded',outputs:[{kind:'file',handle:input.references[0].source.handle,mimeType:'image/png',byteLength:${png.length}}]};
          const reference=input.references[0];
          const response=await context.image.request('http://127.0.0.1:${server.port}/generate',{
            method:'POST',body:{kind:'json',value:{node:input.parameters.defaults.customNode,ratio:input.parameters.ratio,task:context.taskId,asset:reference.assetId,clip:reference.clipId,input:reference.inputId,image:null},files:[{pointer:'/image',handle:reference.source.handle,encoding:'data_uri'}]},response:{kind:'json',images:[{pointer:'/result',encoding:'base64'}]}
          });
          if(input.prompt==='tampered')response.body.result.byteLength++;
          return {status:'succeeded',outputs:[response.body.result]};
        },
        async query(input,context){
          if(input.remoteTaskId!=='job'||input.state.node!=='custom-node')throw new Error('query state lost');
          const response=await context.image.request('http://127.0.0.1:${server.port}/query',{method:'POST',body:{kind:'json',value:{query:input.remoteTaskId,node:input.state.node,task:context.taskId}},response:{kind:'json',images:[{pointer:'/result',encoding:'base64'}]}});
          return {status:'succeeded',outputs:[response.body.result]};
        }
      }
    });}};""";
      final host = PluginHostService(
        dao: database.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        platform: 'macos',
        packages: () async => [PluginPackage('memory', manifest, code)],
      );
      addTearDown(() async {
        await host.dispose();
        await database.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
      });
      await host.start();
      await host.setEnabled(manifest.id, true);
      final provider = aiProviderBuiltinById('openai')!.copyWith(
        id: 'workflow-instance',
        type: 'plugin:test.image',
        enabled: true,
        apiKey: '',
        baseUrl: '',
      );
      await database.aiProviderDao.upsert(provider);
      final file = await File('${directory.path}/input.png').writeAsBytes(png);
      var sequence = 0;
      final submitted = <String>[];
      Future<AiImageGenerationResult> generate(String prompt) async {
        final taskId = 'task-${sequence++}';
        final scope = PluginFileScope(
          pluginId: manifest.id,
          providerId: provider.id,
          taskId: taskId,
        );
        final info = await scope.register(
          file,
          name: 'input.png',
          mimeType: 'image/png',
        );
        final context = ImageOutputContext(
          provider,
          files: PluginMediaFiles(
            directory: Directory('${directory.path}/outputs'),
            scope: scope,
          ),
        );
        return AiImageGenerationService(
          provider,
          model: 'gpt-image-2',
          pluginHost: host,
        ).generatePrepared(
          SubmitImageInput(
            prompt: prompt,
            modelId: 'gpt-image-2',
            aspectRatio: '9:13',
            resolution: 'custom',
            defaults: const {'customNode': 'custom-node'},
            references: [
              PreparedImageReference(
                assetId: 'asset-a',
                clipId: 'clip-a',
                inputId: 'input-a',
                mimeType: 'image/png',
                source: ImageFileReference(info['handle'] as String),
              ),
            ],
          ),
          context: context,
          capabilities: const ImageModelCapabilities(
            ratios: {'9:13'},
            resolutions: {'custom'},
            maxReferences: 1,
          ),
          onSubmitted: (id) async {
            submitted.add(id.remoteTaskId);
          },
        );
      }

      final synchronous = await generate('sync');
      expect(await File(synchronous.localFilePath!).readAsBytes(), png);
      expect(synchronous.imageBase64, isNull);
      expect(requests.single, {
        'node': 'custom-node',
        'ratio': '9:13',
        'task': 'task-0',
        'asset': 'asset-a',
        'clip': 'clip-a',
        'input': 'input-a',
        'image': 'data:image/png;base64,${base64Encode(png)}',
      });
      final asynchronous = await generate('async');
      expect(await File(asynchronous.localFilePath!).readAsBytes(), png);
      expect(submitted, ['job']);
      expect(requests.last, {
        'query': 'job',
        'node': 'custom-node',
        'task': 'task-1',
      });
      expect(requests, hasLength(2));
      await expectLater(
        generate('forged'),
        throwsA(
          isA<AiImageGenerationException>().having(
            (error) => error.debugMessage,
            'ownership rejection',
            contains('Output handle was not created by this invocation'),
          ),
        ),
      );
      expect(requests, hasLength(2));
      await expectLater(
        generate('tampered'),
        throwsA(
          isA<AiImageGenerationException>().having(
            (error) => error.debugMessage,
            'metadata rejection',
            contains('Output metadata does not match'),
          ),
        ),
      );
      expect(requests, hasLength(3));
    },
  );
}

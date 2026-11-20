// 职责: 用真实插件和挂起的本地请求验证任务取消断网、保留已知回执及拒绝迟到 Host 调用。
// 关联文件:
//   lib/shared/services/production/image_service.dart
//   lib/shared/services/ai/image/plugin.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:reveric/shared/models/image/config.dart';
import 'package:drift/native.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:fjs/fjs.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/models/generation/provider_result.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart' as db;
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/generation/task.dart';
import 'package:reveric/shared/models/image/request.dart';
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
  for (final phase in ['submit', 'query', 'receipt']) {
    test(
      'cancels $phase transport and rejects handler calls after cancellation',
      () async {
        HttpOverrides.global = null;
        final root = await Directory.systemTemp.createTemp('image-cancel-');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async => root.path,
            );
        await RevericPaths.initialize();
        final database = db.AppDatabase.forTest(NativeDatabase.memory());
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final entered = Completer<void>();
        final paths = <String>[];
        final png = img.encodePng(img.Image(width: 2, height: 2));
        server.listen((request) async {
          paths.add(request.uri.path);
          await request.drain<void>();
          if (request.uri.path == '/hold') {
            if (!entered.isCompleted) {
              entered.complete();
            }
            return;
          }
          if (request.uri.path == '/result') {
            request.response.add(png);
          } else {
            request.response.write('late');
          }
          await request.response.close();
        });
        final declaration = {
          'kind': 'image',
          'id': 'workflow',
          'capabilities': {
            'ratios': ['auto'],
            'resolutions': ['auto'],
            'minReferences': 0,
            'maxReferences': 0,
            'unlimitedReferences': false,
            'referenceTransport': 'file',
          },
          'requestDefaults': {'node': 'frozen'},
        };
        final manifest = PluginManifest.fromJson({
          'id': 'test.cancel',
          'name': 'Cancel',
          'version': '1.0.0',
          'pluginApiVersion': '^1',
          'main': 'dist/index.js',
          'provider': {'name': 'Cancel'},
        });
        final code =
            """var __revericPlugin={apply(setup){
        const hold=async(context)=>{try{await context.image.request('http://127.0.0.1:${server.port}/hold',{method:'POST',body:{kind:'json',value:{}},response:{kind:'file'}});}catch(error){await context.http.fetch('http://127.0.0.1:${server.port}/late');}};
        setup.provider.register({async listModels(){return [${jsonEncode(declaration)}];},image:{
          async submit(input,context){if('$phase'==='submit')await hold(context);if('$phase'==='receipt')await context.http.fetch('http://127.0.0.1:${server.port}/submit');return {status:'submitted',remoteTaskId:'accepted-id',state:{node:input.prompt==='remote-cancelled'?'remote-cancelled':input.parameters.defaults.node}};},
          async query(input,context){if(input.state.node==='remote-cancelled')return {status:'cancelled'};if('$phase'==='receipt')return {status:'succeeded',outputs:[{kind:'url',url:'http://127.0.0.1:${server.port}/result'}]};await hold(context);return {status:'unknown',reason:'late'};}
        }});
      }};""";
        final host = PluginHostService(
          dao: database.pluginDao,
          registry: PluginRegistry(hostToolNames: {}),
          platform: 'macos',
          packages: () async => [PluginPackage('memory', manifest, code)],
        );
        await host.start();
        await host.setEnabled(manifest.id, true);
        var provider = aiProviderBuiltinById('openai')!.copyWith(
          id: 'instance',
          type: 'plugin:test.cancel',
          enabled: true,
          apiKey: '',
          baseUrl: '',
        );
        await database.aiProviderDao.upsert(provider);
        provider = await host.saveProviderModels(
          await host.discoverProviderModels(provider),
          {(AiModelKind.image, 'workflow')},
          saveProvider: database.aiProviderDao.upsert,
        );
        final jobs = _ReceiptGate(
          gate: phase == 'receipt',
          database: database,
          images: buildImageLibraryService(database),
          pluginHost: host,
          beforeCreate: (_, _, _) async {},
          beforeSubmit: (_) async {},
          recoverSources: () async {},
          invoke:
              (id, selected, request, onSubmitted, onOutputs, cancellation) =>
                  AiImageGenerationService(
                    selected,
                    model: request.modelId,
                    pluginHost: host,
                  ).generatePrepared(
                    SubmitImageInput(
                      prompt: request.prompt,
                      modelId: request.modelId,
                      aspectRatio: request.ratio,
                      resolution: request.resolution,
                      defaults: request.requestDefaults!,
                    ),
                    capabilities: request.capabilities!,
                    context: ImageOutputContext(selected, taskId: id),
                    onSubmitted: onSubmitted,
                    onOutputs: onOutputs,
                    cancellation: cancellation,
                  ),
        );
        addTearDown(() async {
          if (!jobs.release.isCompleted) {
            jobs.release.complete();
          }
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
        final running = jobs.submit(
          taskId: 'task',
          novelId: 'novel',
          sourceType: 'production_clip',
          sourceId: 'node',
          request: ProductionImageRequest(
            providerId: provider.id,
            modelId: 'workflow',
            originalPrompt: 'original',
            prompt: 'final',
            ratio: 'auto',
            resolution: 'auto',
            size: null,
          ),
        );
        if (phase == 'receipt') {
          await jobs.received.future.timeout(const Duration(seconds: 5));
        } else {
          await entered.future.timeout(const Duration(seconds: 5));
        }
        final before = await jobs.requireRun('task');
        if (phase == 'query') {
          expect(before.providerTaskId, 'accepted-id');
          expect(before.providerState, {'node': 'frozen'});
        } else {
          expect(before.providerTaskId, isNull);
        }
        await jobs.cancel('task');
        if (phase == 'receipt') {
          expect((await jobs.requireRun('task')).providerTaskId, isNull);
          jobs.release.complete();
        }
        await running.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final cancelled = await jobs.requireRun('task');
        expect(
          cancelled.status,
          phase != 'submit'
              ? GenerationTaskStatus.action_required
              : GenerationTaskStatus.cancelled,
        );
        expect(
          cancelled.providerTaskId,
          phase != 'submit' ? 'accepted-id' : null,
        );
        expect(
          cancelled.providerState,
          phase != 'submit' ? {'node': 'frozen'} : null,
        );
        expect(paths, phase == 'receipt' ? ['/submit'] : ['/hold']);
        expect(await database.select(database.assets).get(), isEmpty);
        if (phase == 'receipt') {
          await jobs.retrySaveOutput('task');
          expect(
            (await jobs.requireRun('task')).status,
            GenerationTaskStatus.completed,
          );
          expect(paths, ['/submit', '/result']);
          expect(await database.select(database.assets).get(), hasLength(1));
          await jobs.submit(
            taskId: 'remote-task',
            novelId: 'novel',
            sourceType: 'production_clip',
            sourceId: 'remote-node',
            request: ProductionImageRequest(
              providerId: provider.id,
              modelId: 'workflow',
              originalPrompt: 'remote-cancelled',
              prompt: 'remote-cancelled',
              ratio: 'auto',
              resolution: 'auto',
              size: null,
            ),
          );
          final remote = await jobs.requireRun('remote-task');
          expect(remote.status, GenerationTaskStatus.cancelled);
          expect(remote.errorCode, 'cancelled');
        }
      },
    );
  }
  test(
    'native image submit closes its active transport on cancellation',
    () async {
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final entered = Completer<void>();
      var calls = 0;
      server.listen((request) async {
        calls++;
        expect(request.uri.path, '/v1/images/generations');
        await request.drain<void>();
        entered.complete();
      });
      addTearDown(() => server.close(force: true));
      final provider = aiProviderBuiltinById('openai')!.copyWith(
        apiKey: 'synthetic',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
      );
      final cancellation = AgentCancellationController();
      final pending = AiImageGenerationService(provider, model: 'gpt-image-2')
          .generatePrepared(
            const SubmitImageInput(
              prompt: 'local test',
              modelId: 'gpt-image-2',
            ),
            capabilities: const ImageModelCapabilities(),
            context: ImageOutputContext(provider, taskId: 'native'),
            cancellation: cancellation.token,
          );
      final failed = expectLater(
        pending,
        throwsA(isA<AiImageGenerationException>()),
      );
      await entered.future.timeout(const Duration(seconds: 5));
      cancellation.cancel();
      await failed.timeout(const Duration(seconds: 2));
      expect(calls, 1);
    },
  );
}

class _ReceiptGate extends ImageTaskService {
  _ReceiptGate({
    required this.gate,
    required super.database,
    required super.images,
    required super.invoke,
    required super.beforeCreate,
    required super.beforeSubmit,
    required super.recoverSources,
    super.pluginHost,
  });
  bool gate;
  final received = Completer<ProviderSubmitted>();
  final release = Completer<void>();
  @override
  Future<void> recordSubmission(String id, ProviderSubmitted result) async {
    if (gate) {
      gate = false;
      received.complete(result);
      await release.future;
    }
    await super.recordSubmission(id, result);
  }
}

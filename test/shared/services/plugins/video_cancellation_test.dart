// 职责: 用真实插件精确覆盖视频回执落库前取消与无回执取消，确保只恢复查询。
// 关联文件:
//   lib/shared/services/ai/video/task_service.dart
//   lib/shared/services/ai/video/plugin.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:reveric/shared/models/plugin/provider.dart';
import 'package:reveric/shared/models/plugin/provider_registry.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:fjs/fjs.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart' as db;
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/generation/task.dart';
import 'package:reveric/shared/models/generation/provider_result.dart';
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/services/ai/video/reference_storage_service.dart';
import 'package:reveric/shared/services/ai/video/task_service.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import '../../../helpers/fake_object_storage.dart';

class _ReceiptGate extends VideoTaskService {
  _ReceiptGate({
    required super.database,
    required super.rootDirectory,
    required super.references,
    required super.pluginHost,
    required super.probeResult,
    super.now,
    required this.gate,
  });
  final bool gate;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> recordSubmission(String id, ProviderSubmitted receipt) async {
    if (gate) {
      entered.complete();
      await release.future;
    }
    await super.recordSubmission(id, receipt);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await LibFjs.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['FJS_PROBE_LIBRARY']!,
      ),
    );
  });
  for (final phase in [
    'receipt',
    'submitting',
    'draft',
    'invalidreceipt',
    'synchronous',
    'invalidstate',
    'reference',
  ]) {
    test(
      switch (phase) {
        'draft' =>
          'plugin draft completion uses frozen capabilities and original receipt',
        'reference' =>
          'plugin binds file references while preserving asset and slot identity',
        'invalidreceipt' || 'invalidstate' || 'synchronous' =>
          'invalid $phase preserves recoverable identity and never resubmits',
        _ =>
          'cancellation is rejected while the $phase submission is in flight',
      },
      () async {
        HttpOverrides.global = null;
        final root = await Directory.systemTemp.createTemp(
          'video-cancellation-',
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async => root.path,
            );
        await RevericPaths.initialize();
        final database = db.AppDatabase.forTest(NativeDatabase.memory());
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final origin = 'http://127.0.0.1:${server.port}';
        final entered = Completer<void>();
        final releaseHold = Completer<void>();
        final paths = <String>[];
        server.listen((r) async {
          paths.add(r.uri.path);
          final body = await utf8.decoder.bind(r).join();
          if (r.uri.path == '/hold') {
            entered.complete();
            await releaseHold.future;
            r.response.write('{}');
            await r.response.close();
            return;
          }
          if (r.uri.path == '/result') {
            r.response.add([1, 2, 3]);
          } else if (r.uri.path == '/reference') {
            final input = jsonDecode(body) as Map;
            expect(input['reference'], 'data:image/png;base64,AQID');
            expect(input['asset'], 'source');
            expect(input['slot'], {
              'assetId': 'source',
              'role': 'first_frame',
              'slot': 'first',
              'clipId': 'clip',
              'inputId': 'input',
            });
            r.response.write('{"id":"received-id"}');
          } else if (r.uri.path == '/submit') {
            r.response.write('ok');
          } else {
            fail('Unexpected outbound path ${r.uri.path}');
          }
          await r.response.close();
        });
        final model = {
          'id': 'workflow',
          'kind': 'video',
          'capabilities': {
            'ratios': ['16:9'],
            'resolutions': phase == 'draft'
                ? ['360p', 'ultra', 'other']
                : ['720p'],
            'durations': [5],
            'modes': phase == 'reference' ? ['first_frame'] : ['text'],
            'frameRoles': phase == 'reference' ? ['first_frame'] : [],
            'maxMiddleFrames': 0,
            'maxReferences': phase == 'reference' ? 1 : 0,
            'references': phase == 'reference'
                ? {
                    'image': {'maxCount': 1},
                  }
                : {},
            'supportsAudioOnlyReference': false,
            'supportsAdaptiveTextRatio': false,
            'supportsLastFrameOnly': false,
            'framesRequireAdaptiveRatio': false,
            'supportsCertifiedAssets': false,
            'draft': phase == 'draft'
                ? {
                    'resolution': '360p',
                    'completionResolution': 'ultra',
                    'ttlHours': 2,
                  }
                : null,
          },
          'requestDefaults': {},
        };
        final host = PluginHostService(
          dao: database.pluginDao,
          registry: PluginRegistry(hostToolNames: {}),
          platform: 'macos',
          packages: () async => [
            PluginPackage(
              'memory',
              PluginManifest.fromJson({
                'id': 'test.cancelvideo',
                'name': 'Video',
                'version': '1.0.0',
                'pluginApiVersion': '^1',
                'main': 'dist/index.js',
                'provider': {'name': 'Video'},
              }),
              """var __revericPlugin={apply(setup){setup.provider.register({async listModels(){return [${jsonEncode(model)}];},video:{async submit(input,ctx){if('$phase'==='submitting'){try{await ctx.video.request('$origin/hold',{method:'POST',body:{kind:'json',value:{}},response:{kind:'json'}});}catch(e){await ctx.http.fetch('$origin/late');}}else if('$phase'==='reference'){const ref=input.references[0];if(ref.source.kind!=='file')throw new Error('wrong source');await ctx.video.request('$origin/reference',{method:'POST',body:{kind:'json',value:{reference:null,asset:ref.assetId,slot:input.request.referenceSlots[0]},files:[{pointer:'/reference',handle:ref.source.handle,encoding:'data_uri'}]},response:{kind:'json'}});}else{await ctx.http.fetch('$origin/submit');}if('$phase'==='draft'){if(input.draftOf){if(input.draftOf.remoteTaskId!=='received-id'||input.draftOf.state.node!=='frozen'||input.references.length!==0||input.request.resolution!=='ultra')throw new Error('wrong completion');}else if(!input.request.draft||input.request.resolution!=='360p'){throw new Error('wrong draft');}}if('$phase'==='invalidreceipt')return {status:'submitted',remoteTaskId:''};if('$phase'==='synchronous')return {status:'succeeded',outputs:[{kind:'url',url:'$origin/result'}]};if('$phase'==='invalidstate')return {status:'submitted',remoteTaskId:'received-id',state:[]};return {status:'submitted',remoteTaskId:input.draftOf?'final-id':'received-id',state:{node:'frozen'}};},async query(input,ctx){if(!['received-id','final-id'].includes(input.remoteTaskId)||('$phase'!=='invalidstate' && input.state.node!=='frozen'))throw new Error('lost receipt');return {status:'succeeded',outputs:[{kind:'url',url:'$origin/result'}]};}}});}};""",
            ),
          ],
        );
        final refs = ReferenceStorageService(
          database: database,
          pluginHost: host,
          storage: FakeObjectStorage(database, null),
          probe: (_, {cancellation}) async => throw StateError('No references'),
        );
        var clockNow = DateTime.now();
        final jobs = _ReceiptGate(
          now: () => clockNow,
          database: database,
          rootDirectory: root,
          references: refs,
          pluginHost: host,
          gate: phase == 'receipt',
          probeResult: (_) async => const MediaInfo(
            duration: Duration(seconds: 5),
            hasVideo: true,
            hasAudio: false,
            width: 1280,
            height: 720,
          ),
        );
        addTearDown(() async {
          if (!jobs.release.isCompleted) {
            jobs.release.complete();
          }
          await jobs.shutdown();
          refs.dispose();
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
        await host.setEnabled('test.cancelvideo', true);
        var provider = aiProviderBuiltinById('openai')!.copyWith(
          id: 'instance',
          type: 'plugin:test.cancelvideo',
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
        final sourceFile = File('${root.path}/source.png');
        if (phase == 'reference') {
          await sourceFile.writeAsBytes([1, 2, 3]);
          await database.assetDao.insertAsset(
            db.AssetsCompanion.insert(
              id: 'source',
              type: 'image',
              purpose: 'production_output',
              path: const Value('source.png'),
              content: const Value(ImageAssetContent(mimeType: 'image/png')),
            ),
          );
        }
        await jobs.create(
          id: 'task',
          novelId: 'novel',
          sourceType: 'production_clip',
          sourceId: 'clip',
          providerId: provider.id,
          inputs: phase == 'reference'
              ? [
                  VideoSourceInput(
                    file: sourceFile,
                    assetId: 'source',
                    role: VideoInputRole.first_frame,
                    mimeType: 'image/png',
                  ),
                ]
              : [],
          draft: phase == 'draft',
          request: VideoRequest(
            modelId: 'workflow',
            prompt: 'bird',
            mode: phase == 'reference' ? VideoMode.first_frame : VideoMode.text,
            referenceSlots: phase == 'reference'
                ? [
                    const VideoReferenceSlot(
                      'source',
                      VideoInputRole.first_frame,
                      'first',
                      clipId: 'clip',
                      inputId: 'input',
                    ),
                  ]
                : [],
            resolution: phase == 'draft' ? '360p' : '720p',
            ratio: '16:9',
          ),
        );
        if (phase == 'reference') {
          await jobs.submit('task', acknowledgeReferenceUpload: true);
          await jobs.refresh('task');
          expect(
            (await jobs.getTask('task'))!.status,
            GenerationTaskStatus.completed,
          );
          expect(paths, ['/reference', '/result']);
          return;
        }
        if ({'invalidreceipt', 'synchronous', 'invalidstate'}.contains(phase)) {
          await expectLater(
            jobs.submit('task'),
            throwsA(isA<VideoException>()),
          );
          final stopped = (await jobs.getTask('task'))!;
          expect(
            stopped.status,
            phase == 'invalidstate'
                ? GenerationTaskStatus.reconciliation_required
                : GenerationTaskStatus.submission_unknown,
          );
          expect(
            stopped.providerTaskId,
            phase == 'invalidstate' ? 'received-id' : null,
          );
          await jobs.start();
          await jobs.refreshDue();
          if (phase == 'invalidstate') {
            expect(
              (await jobs.getTask('task'))!.status,
              GenerationTaskStatus.completed,
            );
            expect(paths, ['/submit', '/result']);
          } else {
            expect(paths, ['/submit']);
          }
          return;
        }
        if (phase == 'draft') {
          await jobs.submit('task');
          await jobs.refresh('task');
          final source = (await jobs.getTask('task'))!;
          expect(source.status, GenerationTaskStatus.completed);
          pluginProviderModels.replace(
            provider,
            parsePluginProviderModels([
              {
                ...model,
                'capabilities': {
                  ...(model['capabilities'] as Map),
                  'draft': {
                    'resolution': '360p',
                    'completionResolution': 'other',
                    'ttlHours': 1,
                  },
                },
              },
            ]),
          );
          final completion = await jobs.createDraftCompletion('task');
          expect(
            (await jobs.getTask(completion))!.videoRequest.resolution,
            'ultra',
          );
          await expectLater(
            jobs.createDraftCompletion('task'),
            throwsA(isA<VideoException>()),
          );
          await jobs.submit(completion);
          await jobs.refresh(completion);
          expect(
            (await jobs.getTask(completion))!.status,
            GenerationTaskStatus.completed,
          );
          expect((await jobs.getTask(completion))!.providerTaskId, 'final-id');
          clockNow = clockNow.add(const Duration(hours: 3));
          await expectLater(
            jobs.inspectDraftCompletion('task'),
            throwsA(
              isA<VideoException>().having(
                (e) => e.field,
                'expired',
                'draft_expired',
              ),
            ),
          );
          await database
              .into(database.generationTasks)
              .insert(
                db.GenerationTasksCompanion.insert(
                  id: 'legacy',
                  kind: GenerationKind.video,
                  novelId: 'novel',
                  sourceType: 'production_clip',
                  sourceId: 'legacy',
                  providerId: provider.id,
                  providerType: provider.type,
                  modelId: 'workflow',
                  status: GenerationTaskStatus.completed,
                  draft: const Value(true),
                  requestJson: db.VideoGenerationRequest(
                    source.videoRequest,
                    inputs: [],
                  ),
                  providerTaskId: const Value('old'),
                  submittedAt: Value(clockNow),
                  resultAssetId: Value(source.resultAssetId),
                ),
              );
          await expectLater(
            jobs.inspectDraftCompletion('legacy'),
            throwsA(isA<VideoException>()),
          );
          expect(
            (await jobs.getTask('legacy'))!.resultAssetId,
            source.resultAssetId,
          );
          expect(paths, ['/submit', '/result', '/submit', '/result']);
          return;
        }
        final pending = jobs
            .submit('task')
            .then<Object?>((_) => null, onError: (Object e) => e);
        await (phase == 'receipt' ? jobs.entered.future : entered.future)
            .timeout(const Duration(seconds: 5));
        expect((await jobs.getTask('task'))!.providerTaskId, isNull);
        // Aborting an in-flight submission cannot undo upstream billing; it would only lose the receipt.
        expect(
          await database.generationTaskDao.requestCancellation('task'),
          isFalse,
        );
        if (phase == 'receipt') {
          jobs.release.complete();
        } else {
          releaseHold.complete();
        }
        expect(await pending.timeout(const Duration(seconds: 5)), isNull);
        final submitted = (await jobs.getTask('task'))!;
        expect(submitted.status, GenerationTaskStatus.running);
        expect(submitted.cancelRequestedAt, isNull);
        expect(submitted.providerTaskId, 'received-id');
        expect(submitted.providerState, {'node': 'frozen'});
        await jobs.refresh('task');
        expect(
          (await jobs.getTask('task'))!.status,
          GenerationTaskStatus.completed,
        );
        expect(paths, [phase == 'receipt' ? '/submit' : '/hold', '/result']);
      },
    );
  }
}

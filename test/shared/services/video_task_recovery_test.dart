// 职责: 以隔离数据库和模拟上游验证视频生成并发防护、任务重启与下载恢复。
// 关联文件:
//   lib/shared/services/ai/media/production.dart
//   lib/shared/services/ai/video/task_service.dart
//   lib/shared/database/daos/generation_task_dao.dart
//   lib/shared/services/ai/video/reference_storage_service.dart

import 'package:reveric/shared/models/production/media.dart';
import 'dart:async';
import 'package:reveric/shared/database/novel_content_database.dart' as content;
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/agent/tool_approval.dart';
import 'package:reveric/shared/models/tool_permission.dart';
import 'package:reveric/shared/services/ai/media/production.dart';
import 'package:reveric/shared/services/ai/tool_operations.dart';
import 'package:reveric/shared/services/production/audio_service.dart';
import 'package:reveric/shared/services/production/image_service.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/result_service.dart';
import 'package:reveric/shared/services/production/generate_orchestrator.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/services/tool_permission_gate.dart';
import 'package:reveric/shared/services/tool_permissions.dart';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:reveric/shared/database/daos/generation_task_dao.dart';
import 'package:reveric/shared/database/daos/asset_dao.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/provider_asset.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:reveric/shared/services/ai/video/task_service.dart';
import 'package:reveric/shared/services/ai/video/reference_storage_service.dart';
import 'package:reveric/shared/services/object_storage/service.dart';

const request = VideoRequest(
  modelId: 'doubao-seedance-2-5-260628',
  prompt: 'bird',
  mode: VideoMode.text,
  resolution: '720p',
  ratio: '16:9',
  audio: true,
);

void main() {
  late Directory root;
  late _RecoveryDatabase db;
  late AiProvider provider;
  final services = <VideoTaskService>[];
  var posts = 0;
  var queries = 0;
  final uploads = <http.BaseRequest>[];
  var probeFails = false;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('video-recovery-');
    db = _RecoveryDatabase(NativeDatabase(File('${root.path}/app.sqlite')));
    provider = aiProviderBuiltinById(
      'doubao',
    )!.copyWith(enabled: true, apiKey: 'key', videoModels: [request.modelId]);
    await db.aiProviderDao.upsert(provider);
    posts = 0;
    queries = 0;
    uploads.clear();
    probeFails = false;
  });
  tearDown(() async {
    for (final service in services) {
      service.dispose();
    }
    services.clear();
    await db.close();
    await root.delete(recursive: true);
  });
  VideoTaskService make({
    Future<http.Response> Function(http.Request)? respond,
    Future<http.Response> Function(http.Request)? download,
    Future<void> Function(String, String, String)? beforeCreate,
    Future<void> Function(GenerationTask)? beforeSubmit,
    Future<void> Function()? recoverSources,
    DateTime Function()? now,
    bool useDefaultDownloadTransport = false,
  }) {
    final service = VideoTaskService(
      beforeCreate: beforeCreate,
      beforeSubmit: beforeSubmit,
      now: now,
      recoverSources: recoverSources,
      probeResult: (_) async {
        if (probeFails) {
          throw const MediaException(MediaFailure.invalid_media);
        }
        return const MediaInfo(
          duration: Duration(seconds: 5),
          hasAudio: true,
          hasVideo: true,
          width: 1280,
          height: 720,
        );
      },

      database: db,
      rootDirectory: root,
      references: ReferenceStorageService(
        database: db,
        storage: ObjectStorageService(database: db),
        probe: (_) => throw StateError('no references expected'),
        uploadClient: (_) => MockClient((r) async {
          uploads.add(r);
          return http.Response('', 401);
        }),
      ),
      providerTransport: (_) => MockClient((r) async {
        if (r.method == 'POST') {
          posts++;
        } else {
          queries++;
        }
        if (respond != null) {
          return respond(r);
        }
        return http.Response(
          jsonEncode(
            r.method == 'POST'
                ? {'id': 'original'}
                : {
                    'status': 'succeeded',
                    'content': {'video_url': 'https://results.test/result.mp4'},
                  },
          ),
          200,
        );
      }),
      downloadTransport: useDefaultDownloadTransport
          ? null
          : (_) => MockClient(
              download ?? ((_) async => http.Response.bytes([1, 2, 3, 4], 200)),
            ),
    );
    services.add(service);
    return service;
  }

  test(
    'video downloads use current provider proxy and authentication',
    () async {
      final requests = <(int, String?, String?)>[];
      final servers = <HttpServer>[];
      for (var index = 0; index < 3; index++) {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        servers.add(server);
        addTearDown(() => server.close(force: true));
        server.listen((r) async {
          requests.add((
            index,
            r.headers.value(HttpHeaders.proxyAuthorizationHeader),
            r.headers.value(HttpHeaders.authorizationHeader),
          ));
          r.response.add([index, 2, 3, 4]);
          await r.response.close();
        });
      }
      final service = make(
        useDefaultDownloadTransport: true,
        respond: (r) async => http.Response(
          jsonEncode(
            r.method == 'POST'
                ? {'id': 'original'}
                : {
                    'status': 'succeeded',
                    'content': {
                      'video_url':
                          'http://127.0.0.1:${servers[2].port}/result.mp4',
                    },
                  },
          ),
          200,
        ),
      );
      for (var index = 0; index < 2; index++) {
        await db.aiProviderDao.upsert(
          provider.copyWith(
            proxyUrl: 'http://127.0.0.1:${servers[index].port}',
            proxyUsername: 'user',
            proxyPassword: 'secret$index',
          ),
        );
        final id = await service.create(
          providerId: provider.id,
          novelId: 'work',
          sourceType: 'production_clip',
          sourceId: 'proxy$index',
          request: request,
        );
        await service.submit(id);
        await service.refresh(id);
        final task = (await service.getTask(id))!;
        expect(task.status, GenerationTaskStatus.completed);
        expect(await File('${root.path}/${task.path}').readAsBytes(), [
          index,
          2,
          3,
          4,
        ]);
      }
      expect(requests, [
        for (var i = 0; i < 2; i++)
          (i, 'Basic ${base64Encode(utf8.encode('user:secret$i'))}', null),
      ]);
    },
  );

  test(
    'video download rejects cancellation and still registers its result',
    () async {
      final entered = Completer<void>();
      final downloaded = Completer<http.Response>();
      final service = make(
        download: (_) {
          entered.complete();
          return downloaded.future;
        },
      );
      final id = await service.create(
        providerId: provider.id,
        novelId: 'work',
        sourceType: 'production_clip',
        sourceId: 'clip',
        request: request,
      );
      await service.submit(id);
      final pending = service.refresh(id);
      await entered.future;
      try {
        expect(
          (await service.getTask(id))!.status,
          GenerationTaskStatus.saving,
        );
        expect(await db.generationTaskDao.requestCancellation(id), isFalse);
        expect((await service.getTask(id))!.cancelRequestedAt, isNull);
      } finally {
        downloaded.complete(http.Response.bytes([1, 2, 3, 4], 200));
      }
      await pending;
      final task = (await service.getTask(id))!;
      expect(task.status, GenerationTaskStatus.completed);
      expect(task.resultAssetId, isNotNull);
    },
  );

  test('Volcengine draft survives restart and completes through Ark', () async {
    provider = provider.copyWith(type: 'volcengine');
    await db.aiProviderDao.upsert(provider);
    final bodies = <Map<String, dynamic>>[];
    Future<http.Response> respond(http.Request r) async {
      expect(r.url.host, 'ark.cn-beijing.volces.com');
      if (r.method == 'POST') {
        bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
        return http.Response('{"id":"remote-${bodies.length}"}', 200);
      }
      return http.Response(
        jsonEncode({
          'status': 'succeeded',
          'content': {
            'video_url': 'https://results.test/${r.url.pathSegments.last}.mp4',
          },
        }),
        200,
      );
    }

    final first = make(respond: respond);
    final draftId = await first.create(
      providerId: provider.id,
      novelId: 'work',
      sourceType: 'production_clip',
      sourceId: 'clip',
      request: request.withResolution('480p'),
      draft: true,
    );
    await first.submit(draftId);
    await first.refresh(draftId);
    final draft = (await first.getTask(draftId))!;
    expect(draft.status, GenerationTaskStatus.completed);
    expect(draft.draft, true);
    expect(bodies.single['draft'], true);
    expect(bodies.single['resolution'], '480p');
    await first.shutdown();

    final restarted = make(respond: respond);
    await restarted.start();
    final hdId = await restarted.createDraftCompletion(draftId);
    await Future.wait([restarted.submit(hdId), restarted.submit(hdId)]);
    expect(bodies, hasLength(2));
    expect(bodies.last, {
      'model': request.modelId,
      'content': [
        {
          'type': 'draft_task',
          'draft_task': {'id': 'remote-1'},
        },
      ],
      'resolution': '1080p',
      'output_format': 'mp4',
    });
    await restarted.refresh(hdId);
    final hd = (await restarted.getTask(hdId))!;
    expect(hd.status, GenerationTaskStatus.completed);
    expect(hd.draft, false);
    expect(hd.draftTaskId, draftId);
    expect(hd.providerType, 'volcengine');
    expect(hd.videoRequest.prompt, draft.videoRequest.prompt);
    expect(hd.resultAssetId, isNot(draft.resultAssetId));
    expect(await db.assetDao.getAsset(draft.resultAssetId!), isNotNull);
    expect(await db.assetDao.getAsset(hd.resultAssetId!), isNotNull);
  });

  test('certified references are sent as asset URIs without upload', () async {
    provider = provider.copyWith(type: 'volcengine');
    await db.aiProviderDao.upsert(provider);
    final file = File('${root.path}/media/hero.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3, 4]);
    await db
        .into(db.assets)
        .insert(
          AssetsCompanion.insert(
            id: 'hero',
            type: 'image',
            purpose: 'production_output',
            path: const Value('media/hero.png'),
            deletedAt: Value(notDeletedSentinel),
          ),
        );
    final certified = await db.providerAssetDao.start('hero', provider.id);
    await db.providerAssetDao.write(
      certified.id,
      const ProviderAssetsCompanion(
        remoteId: Value('asset-20260224185115-hnjhb'),
        status: Value(ProviderAssetStatus.active),
      ),
    );
    final bodies = <Map<String, dynamic>>[];
    final tasks = make(
      respond: (r) async {
        if (r.method == 'POST') {
          bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
          return http.Response('{"id":"remote"}', 200);
        }
        return http.Response('{"status":"running"}', 200);
      },
    );
    final id = await tasks.create(
      providerId: provider.id,
      novelId: 'work',
      sourceType: 'production_clip',
      sourceId: 'clip',
      request: const VideoRequest(
        modelId: 'doubao-seedance-2-5-260628',
        prompt: '图片1 里的女孩',
        mode: VideoMode.reference,
        resolution: '720p',
        ratio: '16:9',
        audio: true,
      ),
      inputs: [
        VideoSourceInput(
          file: file,
          assetId: 'hero',
          role: VideoInputRole.reference_image,
          mimeType: 'image/png',
        ),
      ],
    );
    await tasks.submit(id, acknowledgeReferenceUpload: true);
    expect(bodies.single['content'], [
      {'type': 'text', 'text': '图片1 里的女孩'},
      {
        'type': 'image_url',
        'image_url': {'url': 'asset://asset-20260224185115-hnjhb'},
        'role': 'reference_image',
      },
    ]);
  });

  Future<File> certifiedHero() async {
    final file = File('${root.path}/media/hero.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3, 4]);
    await db
        .into(db.assets)
        .insert(
          AssetsCompanion.insert(
            id: 'hero',
            type: 'image',
            purpose: 'production_output',
            path: const Value('media/hero.png'),
            deletedAt: Value(notDeletedSentinel),
          ),
        );
    final certified = await db.providerAssetDao.start('hero', provider.id);
    await db.providerAssetDao.write(
      certified.id,
      const ProviderAssetsCompanion(
        remoteId: Value('asset-20261022-atlas'),
        remoteTaskId: Value('42'),
        status: Value(ProviderAssetStatus.active),
      ),
    );
    return file;
  }

  test('AtlasCloud Seedance sends certified assets as URIs', () async {
    const atlasRequest = VideoRequest(
      modelId: 'bytedance/seedance-2.5',
      prompt: '图片1 里的女孩',
      mode: VideoMode.reference,
      resolution: '720p',
      ratio: '16:9',
      audio: true,
    );
    provider = provider.copyWith(
      type: 'atlascloud',
      videoModels: [atlasRequest.modelId],
    );
    await db.aiProviderDao.upsert(provider);
    final file = await certifiedHero();
    final bodies = <Map<String, dynamic>>[];
    final tasks = make(
      respond: (r) async {
        if (r.method == 'POST') {
          bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
          return http.Response('{"code":200,"data":{"id":"remote"}}', 200);
        }
        return http.Response(
          '{"code":200,"data":{"status":"processing"}}',
          200,
        );
      },
    );
    final id = await tasks.create(
      providerId: provider.id,
      novelId: 'work',
      sourceType: 'production_clip',
      sourceId: 'clip',
      request: atlasRequest,
      inputs: [
        VideoSourceInput(
          file: file,
          assetId: 'hero',
          role: VideoInputRole.reference_image,
          mimeType: 'image/png',
        ),
      ],
    );
    await tasks.submit(id, acknowledgeReferenceUpload: true);
    expect(bodies.single['reference_images'], ['asset://asset-20261022-atlas']);
  });

  test(
    'non-Seedance models on the same provider still upload certified assets',
    () async {
      const vanRequest = VideoRequest(
        modelId: 'atlascloud/van-2.5',
        prompt: 'girl',
        mode: VideoMode.first_frame,
        resolution: '720p',
        ratio: '16:9',
        promptExtend: false,
      );
      provider = provider.copyWith(
        type: 'atlascloud',
        videoModels: [vanRequest.modelId],
      );
      await db.aiProviderDao.upsert(provider);
      final file = await certifiedHero();
      final tasks = make();
      final id = await tasks.create(
        providerId: provider.id,
        novelId: 'work',
        sourceType: 'production_clip',
        sourceId: 'clip',
        request: vanRequest,
        inputs: [
          VideoSourceInput(
            file: file,
            assetId: 'hero',
            role: VideoInputRole.first_frame,
            mimeType: 'image/png',
          ),
        ],
      );
      // 未配置云存储时走渠道上传，说明没有换成 asset://。
      await expectLater(
        tasks.submit(id, acknowledgeReferenceUpload: true),
        throwsA(
          isA<VideoException>()
              .having((e) => e.code, 'code', VideoErrorCode.authentication)
              .having((e) => e.field, 'field', 'reference_upload'),
        ),
      );
      expect(uploads.single.url.path, '/api/v1/model/uploadMedia');
      expect(posts, 0);
    },
  );

  group('Seedance draft completion', () {
    const draftRequest = VideoRequest(
      modelId: 'bytedance/seedance-2.5',
      prompt: 'original scene',
      mode: VideoMode.text,
      resolution: '480p',
      ratio: '16:9',
      audio: true,
    );
    late DateTime time;
    final bodies = <Map<String, dynamic>>[];
    setUp(() async {
      time = DateTime(2026, 10, 20);
      bodies.clear();
      provider = provider.copyWith(
        type: 'atlascloud',
        videoModels: [draftRequest.modelId],
      );
      await db.aiProviderDao.upsert(provider);
    });
    Future<http.Response> respond(http.Request r) async {
      if (r.method == 'POST') {
        bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'code': 200,
            'data': {'id': 'remote-${bodies.length}'},
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'code': 200,
          'data': {
            'status': 'completed',
            'outputs': ['https://results.test/${r.url.pathSegments.last}.mp4'],
          },
        }),
        200,
      );
    }

    VideoTaskService service() => make(respond: respond, now: () => time);
    Future<String> completePreview(VideoTaskService tasks) async {
      final id = await tasks.create(
        providerId: provider.id,
        novelId: 'work',
        sourceType: 'production_clip',
        sourceId: 'clip',
        request: draftRequest,
        draft: true,
      );
      await tasks.submit(id);
      await tasks.refresh(id);
      expect((await tasks.getTask(id))!.status, GenerationTaskStatus.completed);
      return id;
    }

    test(
      'production preview is one-shot and HD adopts automatically without losing the draft',
      () async {
        final contentDb = content.NovelContentDatabase.forTest(
          NativeDatabase.memory(),
        );
        final canvas = ProductionCanvasService(
          StoryboardService(contentDb),
          MediaLibraryService(db, MediaService(FfmpegRunner()), root),
          'work',
        );
        final results = ProductionResultService(db, (_) async => canvas);
        final tasks = make(
          now: () => time,
          respond: respond,
          beforeCreate: results.beforeCreate,
          beforeSubmit: results.beforeSubmit,
          recoverSources: results.recover,
        );
        try {
          final episode = (await ScreenplayService(
            contentDb,
          ).createInitialStructure()).episodeId;
          final clip = await canvas.shots.createVideo(
            episode,
            values: {
              'provider_id': provider.id,
              'model_id': draftRequest.modelId,
              'prompt': 'original scene',
              'resolution': '720p',
              'ratio': '16:9',
              'duration_ms': 5000,
            },
          );
          final node = await canvas.ensureShotNode(clip.id);
          final operation = ProductionGenerateOrchestrator();
          final preview = await operation.preview(canvas, node.id, draft: true);
          expect(preview.draft, isTrue);
          expect(preview.request.resolution, '480p');
          final normal = await operation.preview(canvas, node.id);
          expect(normal.draft, isFalse);
          expect(normal.request.resolution, '720p');
          expect((await canvas.shots.getShot(clip.id))!.resolution, '720p');
          final draftId = await operation.submit(
            canvas,
            tasks,
            preview,
            acknowledgeReferenceUpload: false,
          );
          await tasks.refresh(draftId);
          await results.recover();
          final draft = (await tasks.getTask(draftId))!;
          expect(
            (await canvas.shots.getShot(clip.id))!.adoptedAssetId,
            draft.resultAssetId,
          );
          await (contentDb.update(
            contentDb.productionClips,
          )..where((t) => t.id.equals(clip.id))).write(
            const content.ProductionClipsCompanion(
              prompt: Value('edited later'),
              modelId: Value('different-model'),
            ),
          );
          final hdId = await operation.completeDraft(canvas, tasks, draftId);
          expect(
            (await canvas.shots.getShot(clip.id))!.adoptedAssetId,
            draft.resultAssetId,
          );
          final hd = (await tasks.getTask(hdId))!;
          expect(hd.videoRequest.prompt, draft.videoRequest.prompt);
          expect(hd.modelId, draft.modelId);
          await tasks.refresh(hdId);
          await results.recover();
          expect(
            (await canvas.shots.getShot(clip.id))!.adoptedAssetId,
            (await tasks.getTask(hdId))!.resultAssetId,
          );
          await canvas.adoptGenerated(node.id, draftId);
          await results.recover();
          expect(
            (await canvas.shots.getShot(clip.id))!.adoptedAssetId,
            draft.resultAssetId,
          );
          expect(bodies, hasLength(2));
        } finally {
          await tasks.shutdown();
          await contentDb.close();
        }
      },
    );

    test(
      'draft and HD survive restart with separate assets and exactly one HD POST',
      () async {
        final first = service();
        final draftId = await completePreview(first);
        final draft = (await first.getTask(draftId))!;
        expect(draft.draft, isTrue);
        expect(bodies.single['draft'], isTrue);
        expect(bodies.single['resolution'], '480p');
        final hdId = await first.createDraftCompletion(draftId);
        final hd = (await first.getTask(hdId))!;
        expect(hd.draftTaskId, draftId);
        expect(hd.draft, isFalse);
        expect(hd.videoRequest.prompt, draftRequest.prompt);
        expect(hd.videoRequest.resolution, '1080p');
        await first.shutdown();
        final restarted = service();
        await restarted.start();
        expect(bodies, hasLength(1));
        await Future.wait([restarted.submit(hdId), restarted.submit(hdId)]);
        expect(bodies, hasLength(2));
        expect(bodies.last, {
          'model': 'bytedance/seedance-2.5/draft-complete',
          'draft_id': 'remote-1',
          'output_format': 'mp4',
        });
        await restarted.refresh(hdId);
        final completed = (await restarted.getTask(hdId))!;
        expect(completed.status, GenerationTaskStatus.completed);
        expect(completed.resultAssetId, isNot(draft.resultAssetId));
        expect(
          (await restarted.getTask(draftId))!.resultAssetId,
          draft.resultAssetId,
        );
        expect(await db.assetDao.getAsset(draft.resultAssetId!), isNotNull);
        expect(await db.assetDao.getAsset(completed.resultAssetId!), isNotNull);
      },
    );

    test(
      'two services cannot create competing HD tasks, including unknown submissions',
      () async {
        final first = service();
        final draftId = await completePreview(first);
        final second = service();
        Future<Object> attempt(VideoTaskService tasks) async {
          try {
            return await tasks.createDraftCompletion(draftId);
          } catch (error) {
            return error;
          }
        }

        final attempts = await Future.wait([attempt(first), attempt(second)]);
        expect(attempts.whereType<String>(), hasLength(1));
        expect(attempts.whereType<VideoException>(), hasLength(1));
        final hdId = attempts.whereType<String>().single;
        final uncertain = make(
          now: () => time,
          respond: (_) async => throw const SocketException('lost receipt'),
        );
        await expectLater(
          uncertain.submit(hdId),
          throwsA(isA<VideoException>()),
        );
        expect(
          (await first.getTask(hdId))!.status,
          GenerationTaskStatus.submission_unknown,
        );
        await expectLater(
          first.createDraftCompletion(draftId),
          throwsA(isA<VideoException>()),
        );
        expect(posts, 2);
      },
    );

    test(
      'expiry is checked both at creation and again before paid submission',
      () async {
        final tasks = service();
        final draftId = await completePreview(tasks);
        time = time
            .add(const Duration(days: 7))
            .subtract(const Duration(seconds: 1));
        final hdId = await tasks.createDraftCompletion(draftId);
        time = time.add(const Duration(seconds: 1));
        await expectLater(
          tasks.submit(hdId),
          throwsA(
            isA<VideoException>().having(
              (e) => e.field,
              'field',
              'draft_expired',
            ),
          ),
        );
        expect(
          (await tasks.getTask(hdId))!.status,
          GenerationTaskStatus.expired,
        );
        await expectLater(
          tasks.createDraftCompletion(draftId),
          throwsA(
            isA<VideoException>().having(
              (e) => e.field,
              'field',
              'draft_expired',
            ),
          ),
        );
        expect(bodies, hasLength(1));
        expect(
          (await tasks.getTask(draftId))!.status,
          GenerationTaskStatus.completed,
        );
      },
    );

    test('HD does not read or upload the original reference files', () async {
      await db
          .into(db.generationTasks)
          .insert(
            GenerationTasksCompanion.insert(
              id: 'draft-with-reference',
              kind: GenerationKind.video,
              novelId: 'work',
              sourceType: 'production_clip',
              sourceId: 'clip',
              providerId: provider.id,
              providerType: provider.type,
              modelId: draftRequest.modelId,
              draft: const Value(true),
              status: GenerationTaskStatus.completed,
              providerTaskId: const Value('original-remote-draft'),
              submittedAt: Value(time),
              requestJson: VideoGenerationRequest(
                VideoRequest(
                  modelId: draftRequest.modelId,
                  prompt: 'original @Image1',
                  originalPrompt: 'original input',
                  mode: VideoMode.reference,
                  resolution: '480p',
                  ratio: '16:9',
                  audio: true,
                  referenceSlots: const [
                    VideoReferenceSlot(
                      'missing-file',
                      VideoInputRole.reference_image,
                      '@Image1',
                    ),
                  ],
                ),
                inputs: const [
                  VideoInput(
                    role: VideoInputRole.reference_image,
                    assetId: 'missing-file',
                    mimeType: 'image/png',
                  ),
                ],
              ),
            ),
          );
      final tasks = service();
      final id = await tasks.createDraftCompletion('draft-with-reference');
      await tasks.submit(id);
      expect(bodies.single, {
        'model': 'bytedance/seedance-2.5/draft-complete',
        'draft_id': 'original-remote-draft',
        'output_format': 'mp4',
      });
      final saved = (await tasks.getTask(id))!;
      expect(saved.videoInputs.single.assetId, 'missing-file');
      expect(saved.videoRequest.referenceSlots.single.slot, '@Image1');
      expect(saved.videoRequest.originalPrompt, 'original input');
    });

    test(
      'unsupported channels and changed provider types fail before creating a paid task',
      () async {
        final tasks = service();
        final draftId = await completePreview(tasks);
        provider = provider.copyWith(type: 'openrouter');
        await db.aiProviderDao.upsert(provider);
        await expectLater(
          tasks.createDraftCompletion(draftId),
          throwsA(isA<VideoException>()),
        );
        await expectLater(
          tasks.create(
            providerId: provider.id,
            novelId: 'work',
            sourceType: 'production_clip',
            sourceId: 'other',
            request: draftRequest,
            draft: true,
          ),
          throwsA(isA<VideoException>()),
        );
        expect(await db.select(db.generationTasks).get(), hasLength(1));
      },
    );
  });

  test(
    'production video generates task IDs and blocks concurrent submissions',
    () async {
      final contentDb = content.NovelContentDatabase.forTest(
        NativeDatabase.memory(),
      );
      final approvals = AiToolApprovalController();
      final registry = ToolOperationRegistry();
      final submitted = Completer<void>();
      final response = Completer<http.Response>();
      final failedRun = Completer<void>();
      final video = make(
        respond: (_) async {
          if (!submitted.isCompleted) {
            submitted.complete();
          }
          return response.future;
        },
      );
      final operations = ToolOperationManager(
        ownerSessionId: 'session',
        registry: registry,
        gate: () => ToolPermissionGate(
          ToolPermissionService(db, episodeExists: (_, _) async => true),
          approvals,
          enabled: false,
        ),
        onChanged: (state) {
          if (!failedRun.isCompleted && state.runs.any((run) => run.terminal)) {
            failedRun.complete();
          }
        },
        onRecord: (_) {},
      );
      try {
        final episode = (await ScreenplayService(
          contentDb,
        ).createInitialStructure()).episodeId;
        final canvas = ProductionCanvasService(
          StoryboardService(contentDb),
          MediaLibraryService(db, MediaService(FfmpegRunner()), root),
          'work',
        );
        await canvas.ensureCanvas(episode);
        final clip = await canvas.shots.createVideo(
          episode,
          values: {
            'provider_id': provider.id,
            'model_id': request.modelId,
            'prompt': request.prompt,
            'ratio': request.ratio,
            'resolution': request.resolution,
            'duration_ms': 5000,
          },
        );
        await canvas.ensureShotNode(clip.id);
        final host = ProductionToolHost(
          canvas: canvas,
          images: _UnusedImages(),
          audio: _UnusedAudio(),
          video: () async => video,
          results: ProductionResultService(db, (_) async => canvas),
        );
        final context = ToolExecutionContext(
          sessionId: 'session',
          sourceTurnId: 'turn',
        );
        Future<Map<String, dynamic>> generate(String callId) => host.run(
          const RunCommandSpec(
            'production',
            'generate-video',
            RunPermission.required('generation.video'),
          ),
          {'clip_id': clip.id},
          context,
          operations,
          callId,
        );
        final receipts = await Future.wait([generate('one'), generate('two')]);
        await Future.wait([
          submitted.future,
          failedRun.future,
        ]).timeout(const Duration(seconds: 10));
        expect(receipts[0]['run_id'], isNot(receipts[1]['run_id']));
        expect(posts, 1);
        final tasks = await db.select(db.generationTasks).get();
        expect(tasks, hasLength(1));
        expect(tasks.single.id, matches(r'^gen_[A-Z0-9]{6}$'));
        expect(
          operations.state.runs.singleWhere((run) => !run.terminal).taskId,
          tasks.single.id,
        );
        expect(tasks.single.sourceId, clip.id);
        expect(tasks.single.status, GenerationTaskStatus.submitting);
        expect(
          operations.state.runs.where(
            (run) => run.status == ToolOperationStatus.failed,
          ),
          hasLength(1),
        );
        response.complete(
          http.Response(
            '{"error":{"code":"InvalidParameter","message":"test rejection"}}',
            400,
          ),
        );
        await Future.wait([
          for (final receipt in receipts)
            operations.wait(receipt['run_id'] as String, context),
        ]).timeout(const Duration(seconds: 10));
        final retry = await generate('retry-after-failure');
        await operations
            .wait(retry['run_id'] as String, context)
            .timeout(const Duration(seconds: 10));
        expect(posts, 2);
        final history = await db.select(db.generationTasks).get();
        expect(history, hasLength(2));
        expect(history.map((task) => task.id).toSet(), hasLength(2));
        expect(
          history.map((task) => task.id),
          everyElement(matches(r'^gen_[A-Z0-9]{6}$')),
        );
      } finally {
        if (!response.isCompleted) {
          response.complete(http.Response('{}', 400));
        }
        await video.shutdown();
        operations.dispose();
        registry.dispose();
        approvals.dispose();
        await contentDb.close();
      }
    },
  );

  test(
    'terminal output review failure is persisted without resubmission',
    () async {
      final service = make(
        respond: (r) async => http.Response(
          jsonEncode(
            r.method == 'POST'
                ? {'id': 'original'}
                : {
                    'status': 'failed',
                    'error': {
                      'code':
                          'OutputVideoSensitiveContentDetected.PolicyViolation',
                      'message': 'private diagnostic',
                    },
                  },
          ),
          200,
        ),
      );
      final id = await service.create(
        id: 'output-review',
        novelId: 'work',
        sourceType: 'production_clip',
        sourceId: 'clip',
        providerId: provider.id,
        request: request,
      );
      await service.submit(id);
      await service.refresh(id);
      final task = (await service.getTask(id))!;
      expect(task.status, GenerationTaskStatus.failed);
      expect(task.errorCode, 'upstream_failed');
      expect(task.errorMessage, LocaleKeys.aiOutputCopyrightRejected);
      expect(
        task.errorDetail,
        'OutputVideoSensitiveContentDetected.PolicyViolation: private diagnostic',
      );
      await service.refresh(id);
      expect(posts, 1);
      expect(queries, 1);
    },
  );

  test(
    'persisted cancellation prevents uploading task resubmission after database reopen',
    () async {
      final first = make();
      final id = await first.create(
        id: 'cancelled-request',
        novelId: 'work',
        sourceType: 'production_clip',
        sourceId: 'clip',
        providerId: provider.id,
        request: request,
      );
      await db.generationTaskDao.transition(
        id,
        {GenerationTaskStatus.prepared},
        GenerationTasksCompanion(
          status: const Value(GenerationTaskStatus.uploading),
          cancelRequestedAt: Value(DateTime.now()),
        ),
      );
      first.dispose();
      await db.close();
      db = _RecoveryDatabase(NativeDatabase(File('${root.path}/app.sqlite')));
      final restarted = make();
      await restarted.start();
      expect(
        (await restarted.getTask(id))!.status,
        GenerationTaskStatus.cancelled,
      );
      expect(
        await restarted.create(
          id: id,
          novelId: 'work',
          sourceType: 'production_clip',
          sourceId: 'clip',
          providerId: provider.id,
          request: request,
        ),
        id,
      );
      await expectLater(
        restarted.create(
          id: id,
          novelId: 'work',
          sourceType: 'production_clip',
          sourceId: 'clip',
          providerId: provider.id,
          request: VideoRequest.fromJson({
            ...request.toJson(),
            'prompt': 'changed after restart',
          }),
        ),
        throwsA(isA<VideoException>()),
      );
      await restarted.submit(id);
      expect(posts, 0);
      expect((await restarted.getTask(id))!.resultAssetId, isNull);
      expect((await restarted.getTask(id))!.cancelRequestedAt, isNotNull);
    },
  );
  test(
    'persisted cancellation between uploading and submit prevents POST',
    () async {
      final service = make();
      final id = await service.create(
        id: 'cancel-upload',
        novelId: 'work',
        sourceType: 'production_clip',
        sourceId: 'clip',
        providerId: provider.id,
        request: request,
      );
      db.generationTaskDao.afterUploading = () =>
          db.generationTaskDao.requestCancellation(id);
      await service.submit(id);
      expect(posts, 0);
      expect(
        (await service.getTask(id))!.status,
        GenerationTaskStatus.cancelled,
      );
    },
  );

  test(
    'OpenRouter resumes polling and authenticated download without resubmitting',
    () async {
      const openRouterRequest = VideoRequest(
        modelId: 'google/veo-3.1',
        prompt: 'bird',
        mode: VideoMode.text,
        resolution: '720p',
        ratio: '16:9',
        durationSeconds: 6,
        audio: true,
      );
      provider = provider.copyWith(
        type: 'openrouter',
        baseUrl: 'https://ignored.invalid',
        videoModels: [openRouterRequest.modelId],
      );
      await db.aiProviderDao.upsert(provider);
      final submitting = make(
        respond: (r) async {
          expect(r.url.toString(), 'https://openrouter.ai/api/v1/videos');
          return http.Response('{"id":"router-job","status":"pending"}', 202);
        },
      );
      final id = await submitting.create(
        novelId: 'work',
        sourceType: 'storyboard_shot',
        sourceId: 'shot',
        providerId: provider.id,
        request: openRouterRequest,
      );
      await submitting.submit(id);
      submitting.dispose();
      final restarted = make(
        respond: (r) async {
          expect(r.method, 'GET');
          expect(
            r.url.toString(),
            'https://openrouter.ai/api/v1/videos/router-job',
          );
          return http.Response('{"id":"router-job","status":"completed"}', 200);
        },
        download: (r) async {
          expect(
            r.url.toString(),
            'https://openrouter.ai/api/v1/videos/router-job/content',
          );
          expect(r.headers['Authorization'], 'Bearer key');
          expect(r.followRedirects, false);
          return http.Response.bytes([1, 2, 3, 4], 200);
        },
      );
      await restarted.refresh(id);
      expect(
        (await restarted.getTask(id))!.status,
        GenerationTaskStatus.completed,
      );
      expect(posts, 1);
      expect(queries, 1);
    },
  );

  test(
    'Volcengine submits and resumes video jobs through the fixed Ark route',
    () async {
      provider = provider.copyWith(
        type: 'volcengine',
        baseUrl: 'https://override.example/v1',
      );
      await db.aiProviderDao.upsert(provider);
      final service = make(
        respond: (r) async {
          expect(r.method, 'POST');
          expect(
            r.url.toString(),
            'https://ark.cn-beijing.volces.com/api/v3/contents/generations/tasks',
          );
          expect(r.headers['Authorization'], 'Bearer key');
          expect((jsonDecode(r.body) as Map)['model'], request.modelId);
          return http.Response('{"id":"domestic-task"}', 200);
        },
      );
      final id = await service.create(
        novelId: 'work',
        sourceType: 'storyboard_shot',
        sourceId: 'shot',
        providerId: provider.id,
        request: request,
      );
      await service.submit(id);
      service.dispose();
      final restarted = make(
        respond: (r) async {
          expect(r.method, 'GET');
          expect(
            r.url.toString(),
            'https://ark.cn-beijing.volces.com/api/v3/contents/generations/tasks/domestic-task',
          );
          expect(r.headers['Authorization'], 'Bearer key');
          return http.Response(
            '{"status":"succeeded","content":{"video_url":"https://results.test/result.mp4"}}',
            200,
          );
        },
      );
      await restarted.refresh(id);
      expect(
        (await restarted.getTask(id))!.status,
        GenerationTaskStatus.completed,
      );
      expect(posts, 1);
      expect(queries, 1);
    },
  );

  test(
    'AtlasCloud restores the original prediction and downloads without resubmitting',
    () async {
      const atlasRequest = VideoRequest(
        modelId: 'bytedance/seedance-2.5',
        prompt: 'bird',
        mode: VideoMode.text,
        resolution: '720p',
        ratio: '16:9',
        audio: true,
      );
      provider = provider.copyWith(
        type: 'atlascloud',
        videoModels: [atlasRequest.modelId],
      );
      await db.aiProviderDao.upsert(provider);
      final service = make(
        respond: (r) async {
          expect(r.method, 'POST');
          expect(
            r.url.toString(),
            'https://api.atlascloud.ai/api/v1/model/generateVideo',
          );
          expect(
            (jsonDecode(r.body) as Map)['model'],
            'bytedance/seedance-2.5/text-to-video',
          );
          return http.Response(
            '{"code":200,"data":{"id":"atlas-task","status":"processing"}}',
            200,
          );
        },
      );
      final id = await service.create(
        novelId: 'work',
        sourceType: 'storyboard_shot',
        sourceId: 'shot',
        providerId: provider.id,
        request: atlasRequest,
      );
      await service.submit(id);
      service.dispose();
      final restarted = make(
        respond: (r) async {
          expect(r.method, 'GET');
          expect(
            r.url.toString(),
            'https://api.atlascloud.ai/api/v1/model/prediction/atlas-task',
          );
          expect(r.headers['Authorization'], 'Bearer key');
          return http.Response(
            '{"code":200,"data":{"id":"atlas-task","status":"completed","outputs":["https://results.test/result.mp4"]}}',
            200,
          );
        },
        download: (r) async {
          expect(r.headers.containsKey('Authorization'), false);
          return http.Response.bytes([1, 2, 3, 4], 200);
        },
      );
      await restarted.refresh(id);
      final task = (await restarted.getTask(id))!;
      expect(task.status, GenerationTaskStatus.completed);
      expect(task.providerTaskId, 'atlas-task');
      expect(posts, 1);
      expect(queries, 1);
    },
  );

  test('Agnes restores video ID and model polling query after restart', () async {
    const agnesRequest = VideoRequest(
      modelId: 'agnes-video-2.5-flash',
      prompt: 'bird',
      mode: VideoMode.text,
      resolution: '720P',
      ratio: '16:9',
    );
    provider = provider.copyWith(
      type: 'agnes',
      baseUrl: agnesDefaultBaseUrl,
      videoModels: [agnesRequest.modelId],
    );
    await db.aiProviderDao.upsert(provider);
    final service = make(
      respond: (r) async {
        expect(r.method, 'POST');
        expect(r.url.toString(), '$agnesDefaultBaseUrl/videos');
        expect((jsonDecode(r.body) as Map)['model'], agnesRequest.modelId);
        return http.Response('{"id":"task-id","video_id":"video-id"}', 200);
      },
    );
    final id = await service.create(
      novelId: 'work',
      sourceType: 'storyboard_shot',
      sourceId: 'shot',
      providerId: provider.id,
      request: agnesRequest,
    );
    await service.submit(id);
    service.dispose();
    final restarted = make(
      respond: (r) async {
        expect(r.method, 'GET');
        expect(r.url.path, '/agnesapi');
        expect(r.url.queryParameters, {
          'video_id': 'video-id',
          'model_name': agnesRequest.modelId,
        });
        return http.Response(
          '{"status":"completed","internal_status":"pending","url":"https://results.test/result.mp4"}',
          200,
        );
      },
    );
    await restarted.refresh(id);
    final task = (await restarted.getTask(id))!;
    expect(task.status, GenerationTaskStatus.completed);
    expect(task.providerTaskId, 'video-id');
    expect(posts, 1);
    expect(queries, 1);
  });

  test(
    'source state failure preserves prepared identity and requires explicit submission after restart',
    () async {
      final service = make(
        beforeSubmit: (_) async {
          throw StateError('content database offline');
        },
      );
      final id = await service.create(
        id: 'source-state',
        novelId: 'work',
        sourceType: 'storyboard_shot',
        sourceId: 'shot',
        providerId: provider.id,
        request: request,
      );
      await expectLater(service.submit(id), throwsStateError);
      expect(posts, 0);
      expect(
        (await service.getTask(id))!.status,
        GenerationTaskStatus.prepared,
      );
      expect((await service.getTask(id))!.errorCode, 'source_state_pending');
      var recovered = 0;
      final restarted = make(
        beforeSubmit: (_) async {},
        recoverSources: () async {
          recovered++;
        },
      );
      restarted.setOnline(false);
      await restarted.start();
      expect(recovered, 1);
      expect(posts, 0);
      expect((await restarted.getTask(id))!.errorCode, 'source_state_pending');
      restarted.setOnline(true);
      await restarted.submit(id);
      expect(posts, 1);
      expect((await restarted.getTask(id))!.providerTaskId, 'original');
    },
  );

  test(
    'configuration pause between uploading write and reread blocks POST',
    () async {
      final service = make();
      final id = await service.create(
        novelId: 'test-novel',
        sourceType: 'storyboard_shot',
        sourceId: 'test-shot',
        id: 'upload-race',
        providerId: provider.id,
        request: request,
      );
      db.generationTaskDao.afterUploading = () async {
        await db.aiProviderDao.upsert(provider.copyWith(apiKey: 'replacement'));
      };
      await service.submit(id);
      expect(posts, 0);
      expect(
        (await service.getTask(id))!.status,
        GenerationTaskStatus.action_required,
      );
      await service.resumeAfterConfigurationFixed(id);
      expect((await service.getTask(id))!.status, GenerationTaskStatus.running);
      expect(posts, 1);
    },
  );

  for (final status in [400, 401, 409, 429]) {
    test(
      'retry after HTTP $status rejection submits without confirmation',
      () async {
        var reject = true;
        final service = make(
          respond: (_) async => reject
              ? http.Response(
                  '{"error":{"message":"request rejected"}}',
                  status,
                )
              : http.Response('{"id":"retried"}', 200),
        );
        final id = await service.create(
          novelId: 'test-novel',
          sourceType: 'storyboard_shot',
          sourceId: 'test-shot',
          providerId: provider.id,
          request: request,
        );
        await expectLater(service.submit(id), throwsA(isA<VideoException>()));
        expect(
          (await service.getTask(id))!.status,
          GenerationTaskStatus.action_required,
        );
        expect(posts, 1);

        reject = false;
        await Future.wait([
          service.resumeAfterConfigurationFixed(id),
          service.resumeAfterConfigurationFixed(id),
        ]);
        final task = (await service.getTask(id))!;
        expect(task.status, GenerationTaskStatus.running);
        expect(task.providerTaskId, 'retried');
        expect(task.errorCode, isNull);
        expect(
          posts,
          2,
          reason: 'one explicit retry must create only one new request',
        );
      },
    );
  }

  for (final hasSubmissionTime in [false, true]) {
    test(
      'retry preserves unknown submission with timestamp=$hasSubmissionTime',
      () async {
        final service = make();
        final id = await service.create(
          novelId: 'test-novel',
          sourceType: 'storyboard_shot',
          sourceId: 'test-shot',
          providerId: provider.id,
          request: request,
        );
        await db.generationTaskDao.transition(
          id,
          {GenerationTaskStatus.prepared},
          GenerationTasksCompanion(
            status: const Value(GenerationTaskStatus.action_required),
            submittedAt: Value(hasSubmissionTime ? DateTime.now() : null),
            errorCode: Value(
              hasSubmissionTime
                  ? 'unavailable'
                  : 'provider_configuration_changed',
            ),
          ),
        );
        await service.resumeAfterConfigurationFixed(id);
        expect(
          (await service.getTask(id))!.status,
          GenerationTaskStatus.submission_unknown,
        );
        expect(posts, 0);
      },
    );
  }

  for (final anomaly in ['{"status":"succeeded"}', '{"status":"UNKNOWN"}']) {
    test('explicit refresh reconciles original ID after $anomaly', () async {
      var anomalous = true;
      final service = make(
        respond: (r) async {
          if (r.method == 'POST') {
            return http.Response('{"id":"original"}', 200);
          }
          expect(r.url.path, endsWith('/original'));
          return http.Response(
            anomalous
                ? anomaly
                : '{"status":"succeeded","content":{"video_url":"https://results.test/result.mp4"}}',
            200,
          );
        },
      );
      final id = await service.create(
        novelId: 'test-novel',
        sourceType: 'storyboard_shot',
        sourceId: 'test-shot',
        id: 'reconcile',
        providerId: provider.id,
        request: request,
      );
      await service.submit(id);
      await service.refresh(id);
      expect(
        (await service.getTask(id))!.status,
        GenerationTaskStatus.reconciliation_required,
      );
      anomalous = false;
      await service.refresh(id);
      expect(
        (await service.getTask(id))!.status,
        GenerationTaskStatus.completed,
      );
      expect((await service.getTask(id))!.providerTaskId, 'original');
      expect(posts, 1);
      expect(queries, 2);
    });
  }

  test(
    'resume while POST pending preserves pause and accepted receipt',
    () async {
      final pending = Completer<http.Response>();
      final started = Completer<void>();
      final service = make(
        respond: (r) async {
          if (r.method == 'POST') {
            started.complete();
            return pending.future;
          }
          expect(r.url.path, endsWith('/original'));
          return http.Response(
            '{"status":"succeeded","content":{"video_url":"https://results.test/result.mp4"}}',
            200,
          );
        },
      );
      final id = await service.create(
        novelId: 'test-novel',
        sourceType: 'storyboard_shot',
        sourceId: 'test-shot',
        id: 'resume-race',
        providerId: provider.id,
        request: request,
      );
      final submission = service.submit(id);
      await started.future;
      await db.aiProviderDao.upsert(provider.copyWith(apiKey: 'replacement'));
      await db.aiProviderDao.upsert(provider);
      await service.resumeAfterConfigurationFixed(id);
      pending.complete(http.Response('{"id":"original"}', 200));
      await submission;
      final task = (await service.getTask(id))!;
      expect(task.providerTaskId, 'original');
      expect(task.status, GenerationTaskStatus.action_required);
      expect(task.nextPollAt, isNull);
      await service.resumeAfterConfigurationFixed(id);
      expect(
        (await service.getTask(id))!.status,
        GenerationTaskStatus.completed,
      );
      expect(posts, 1);
      expect(queries, 1);
    },
  );

  test(
    'query missing result fields pauses reconciliation rather than polling forever',
    () async {
      final service = make(
        respond: (r) async => http.Response(
          r.method == 'POST' ? '{"id":"original"}' : '{"status":"succeeded"}',
          200,
        ),
      );
      final id = await service.create(
        novelId: 'test-novel',
        sourceType: 'storyboard_shot',
        sourceId: 'test-shot',
        id: 'missing-fields',
        providerId: provider.id,
        request: request,
      );
      await service.submit(id);
      await service.refresh(id);
      final task = (await service.getTask(id))!;
      expect(task.status, GenerationTaskStatus.reconciliation_required);
      expect(task.nextPollAt, isNull);
      expect(posts, 1);
    },
  );

  test(
    'Wan UNKNOWN after its documented query window becomes expired',
    () async {
      final qwen = provider.copyWith(
        id: 'qwen-test',
        type: 'qwen',
        baseUrl: qwenDefaultBaseUrl,
        videoModels: ['wan3.0-video'],
      );
      await db.aiProviderDao.upsert(qwen);
      const wanRequest = VideoRequest(
        modelId: 'wan3.0-video',
        prompt: 'bird',
        mode: VideoMode.text,
        resolution: '720P',
        ratio: '16:9',
        audio: true,
        promptExtend: true,
      );
      await db.generationTaskDao.create(
        GenerationTasksCompanion.insert(
          novelId: 'test-novel',
          sourceType: 'storyboard_shot',
          sourceId: 'test-shot',
          id: 'expired',
          providerId: qwen.id,
          providerType: 'qwen',
          modelId: wanRequest.modelId,
          status: GenerationTaskStatus.running,
          requestJson: VideoGenerationRequest(wanRequest, inputs: []),
          providerTaskId: const Value('original'),
          pollingUrl: const Value(
            'https://maas.qianwenaiapi.com/api/v1/tasks/original',
          ),
          submittedAt: Value(DateTime.now().subtract(const Duration(days: 2))),
          kind: GenerationKind.video,
        ),
      );
      final service = make(
        respond: (_) async => http.Response(
          '{"output":{"task_id":"original","task_status":"UNKNOWN"}}',
          200,
        ),
      );
      await service.refresh('expired');
      expect(
        (await service.getTask('expired'))!.status,
        GenerationTaskStatus.expired,
      );
      expect(posts, 0);
    },
  );

  test(
    'two service starts query same ID and complete local result without a second POST',
    () async {
      final first = make();
      final id = await first.create(
        novelId: 'test-novel',
        sourceType: 'storyboard_shot',
        sourceId: 'test-shot',
        id: 'restart',
        providerId: provider.id,
        request: request,
      );
      await first.submit(id);
      first.dispose();
      await db.close();
      db = _RecoveryDatabase(NativeDatabase(File('${root.path}/app.sqlite')));
      final second = make();
      await second.start();
      await second.refresh(id);
      final task = (await second.getTask(id))!;
      expect(task.status, GenerationTaskStatus.completed);
      expect(task.providerTaskId, 'original');
      expect(posts, 1);
      expect(queries, 1);
      expect(await File('${root.path}/${task.path}').readAsBytes(), [
        1,
        2,
        3,
        4,
      ]);
    },
  );
  test(
    'HTTP 503 fails the submission and never resubmits after restart',
    () async {
      final lines = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) {
          lines.add(message);
        }
      };
      addTearDown(() => debugPrint = originalDebugPrint);
      final service = make(
        respond: (_) async =>
            http.Response('{"error":{"message":"No available channel"}}', 503),
      );
      final id = await service.create(
        novelId: 'test-novel',
        sourceType: 'storyboard_shot',
        sourceId: 'test-shot',
        providerId: provider.id,
        request: request,
      );
      await expectLater(service.submit(id), throwsA(isA<VideoException>()));
      final task = (await service.getTask(id))!;
      expect(task.status, GenerationTaskStatus.failed);
      expect(task.errorCode, 'unavailable');
      expect(
        lines.where((line) => line.contains('[VideoClient]')),
        hasLength(1),
      );
      final taskLogs = lines
          .where((line) => line.contains('[VideoTasks]'))
          .toList();
      expect(taskLogs, hasLength(1));
      expect(taskLogs.single, contains('id=$id'));
      expect(taskLogs.single, contains('[WARN]'));
      expect(lines.join('\n'), isNot(contains('[ERROR]')));

      expect(task.errorMessage, LocaleKeys.aiProviderChannelUnavailable);
      expect(task.errorDetail, contains('No available channel'));
      expect(task.providerTaskId, isNull);
      expect(GenerationTaskDao.blocksSource(task), false);
      service.dispose();
      final restarted = make();
      await restarted.start();
      await restarted.submit(id);
      await restarted.refresh(id);
      expect(
        (await restarted.getTask(id))!.status,
        GenerationTaskStatus.failed,
      );
      expect(posts, 1);
      expect(queries, 0);
    },
  );
  test(
    'polling HTTP 503 retains the receipt and clears the error after recovery',
    () async {
      var unavailable = true;
      final service = make(
        respond: (r) async {
          if (r.method == 'POST') {
            return http.Response('{"id":"original"}', 200);
          }
          return unavailable
              ? http.Response(
                  '{"error":{"message":"No available channel"}}',
                  503,
                  headers: {'retry-after': '120'},
                )
              : http.Response('{"status":"running"}', 200);
        },
      );
      final id = await service.create(
        novelId: 'test-novel',
        sourceType: 'storyboard_shot',
        sourceId: 'test-shot',
        providerId: provider.id,
        request: request,
      );
      await service.submit(id);
      final before = DateTime.now();
      await service.refresh(id);
      final task = (await service.getTask(id))!;
      expect(task.status, GenerationTaskStatus.running);
      expect(task.providerTaskId, 'original');
      expect(task.errorMessage, LocaleKeys.aiProviderChannelUnavailable);
      expect(task.errorDetail, contains('No available channel'));
      expect(
        task.nextPollAt!.difference(before).inSeconds,
        greaterThanOrEqualTo(119),
      );
      unavailable = false;
      await service.refresh(id);
      final recovered = (await service.getTask(id))!;
      expect(recovered.errorCode, isNull);
      expect(recovered.errorMessage, isNull);
      expect(posts, 1);
      expect(queries, 2);
    },
  );
  test(
    'uncertain submission stays unknown after restart but allows a new generation',
    () async {
      final service = make(
        respond: (_) => throw TimeoutException('lost response'),
      );
      final id = await service.create(
        novelId: 'test-novel',
        sourceType: 'storyboard_shot',
        sourceId: 'test-shot',
        id: 'unknown',
        providerId: provider.id,
        request: request,
      );
      await expectLater(service.submit(id), throwsA(isA<VideoException>()));
      expect(
        (await service.getTask(id))!.status,
        GenerationTaskStatus.submission_unknown,
      );
      service.dispose();
      final restored = make();
      await restored.start();
      await restored.submit(id);
      await restored.refresh(id);
      expect(posts, 1);
      expect(queries, 0);
      final redo = await restored.create(
        novelId: 'test-novel',
        sourceType: 'storyboard_shot',
        sourceId: 'test-shot',
        providerId: provider.id,
        request: request,
      );
      await restored.submit(redo);
      expect(posts, 2);
      expect(
        (await restored.getTask(redo))!.status,
        GenerationTaskStatus.running,
      );
      expect(
        (await restored.getTask(id))!.status,
        GenerationTaskStatus.submission_unknown,
      );
    },
  );
  test('crash in submitting before receipt never regenerates', () async {
    final service = make();
    final id = await service.create(
      novelId: 'test-novel',
      sourceType: 'storyboard_shot',
      sourceId: 'test-shot',
      id: 'crash',
      providerId: provider.id,
      request: request,
    );
    await db.generationTaskDao.transition(
      id,
      {GenerationTaskStatus.prepared},
      const GenerationTasksCompanion(
        status: Value(GenerationTaskStatus.submitting),
      ),
    );
    await service.start();
    expect(
      (await service.getTask(id))!.status,
      GenerationTaskStatus.submission_unknown,
    );
    expect(posts, 0);
  });
  test(
    'final file after atomic rename is registered without any HTTP',
    () async {
      final service = make();
      final id = await service.create(
        novelId: 'test-novel',
        sourceType: 'storyboard_shot',
        sourceId: 'test-shot',
        id: 'rename',
        providerId: provider.id,
        request: request,
      );
      await service.submit(id);
      await db.generationTaskDao.transition(
        id,
        {GenerationTaskStatus.running},
        const GenerationTasksCompanion(
          status: Value(GenerationTaskStatus.saving),
          outputHash: Value('obsolete-output-hash'),
        ),
      );
      final result = File(
        '${root.path}/file_workspaces/test-novel/videos/$id.mp4',
      );
      await result.parent.create(recursive: true);
      await result.writeAsBytes([4, 3, 2, 1]);
      await service.start();
      expect(
        (await service.getTask(id))!.status,
        GenerationTaskStatus.completed,
      );
      expect(queries, 0);
    },
  );
  test(
    'changed models preserve tasks; key change pauses; explicit resume queries original',
    () async {
      final service = make();
      final id = await service.create(
        novelId: 'test-novel',
        sourceType: 'storyboard_shot',
        sourceId: 'test-shot',
        id: 'config',
        providerId: provider.id,
        request: request,
      );
      await service.submit(id);
      await db.aiProviderDao.upsert(
        provider.copyWith(models: ['another'], videoModels: []),
      );
      expect((await service.getTask(id))!.status, GenerationTaskStatus.running);
      await db.aiProviderDao.upsert(provider.copyWith(apiKey: 'replacement'));
      expect(
        (await service.getTask(id))!.status,
        GenerationTaskStatus.action_required,
      );
      await service.refresh(id);
      expect(queries, 0);
      await service.resumeAfterConfigurationFixed(id);
      expect(queries, 1);
      expect(posts, 1);
      expect((await service.getTask(id))!.providerTaskId, 'original');
    },
  );

  test(
    'normalizing a legacy Qwen default does not pause an unchanged endpoint',
    () async {
      final qwen = provider.copyWith(
        id: 'legacy-qwen',
        type: 'qwen',
        baseUrl: 'https://dashscope.aliyuncs.com/apps/anthropic',
      );
      await db.aiProviderDao.upsert(qwen);
      await db.generationTaskDao.create(
        GenerationTasksCompanion.insert(
          novelId: 'test-novel',
          sourceType: 'storyboard_shot',
          sourceId: 'test-shot',
          id: 'legacy-url',
          providerId: qwen.id,
          providerType: qwen.type,
          modelId: request.modelId,
          status: GenerationTaskStatus.running,
          requestJson: VideoGenerationRequest(request, inputs: []),
          kind: GenerationKind.video,
        ),
      );
      await db.aiProviderDao.upsert(
        qwen.copyWith(baseUrl: qwenDefaultBaseUrl, models: ['new-default']),
      );
      expect(
        (await db.generationTaskDao.getById('legacy-url'))!.status,
        GenerationTaskStatus.running,
      );
    },
  );
  test(
    'only action_required tasks that may exist upstream block the source',
    () async {
      Future<bool> blocks(
        String id, {
        String? providerTaskId,
        String? errorCode,
      }) async {
        await db.generationTaskDao.create(
          GenerationTasksCompanion.insert(
            novelId: 'test-novel',
            sourceType: 'storyboard_shot',
            sourceId: id,
            id: id,
            providerId: provider.id,
            providerType: provider.type,
            modelId: request.modelId,
            status: GenerationTaskStatus.action_required,
            requestJson: VideoGenerationRequest(request, inputs: []),
            kind: GenerationKind.video,
            providerTaskId: Value(providerTaskId),
            errorCode: Value(errorCode),
          ),
        );
        return GenerationTaskDao.blocksSource(
          (await db.generationTaskDao.getById(id))!,
        );
      }

      expect(await blocks('unsent', errorCode: 'unavailable'), false);
      expect(
        await blocks('in-flight', errorCode: 'provider_configuration_changed'),
        true,
      );
      expect(await blocks('submitted', providerTaskId: 'original'), true);
    },
  );
  test(
    'in-flight receipt records identity but cannot overwrite configuration pause',
    () async {
      final pending = Completer<http.Response>();
      final started = Completer<void>();
      final service = make(
        respond: (r) {
          started.complete();
          return pending.future;
        },
      );
      final id = await service.create(
        novelId: 'test-novel',
        sourceType: 'storyboard_shot',
        sourceId: 'test-shot',
        id: 'race',
        providerId: provider.id,
        request: request,
      );
      final submission = service.submit(id);
      await started.future;
      await db.aiProviderDao.upsert(
        provider.copyWith(baseUrl: 'https://another.example/api/v3'),
      );
      pending.complete(http.Response('{"id":"original"}', 200));
      await submission;
      final task = (await service.getTask(id))!;
      expect(task.status, GenerationTaskStatus.action_required);
      expect(task.providerTaskId, 'original');
      expect(task.nextPollAt, isNull);
      expect(task.pollingUrl, contains('ark.cn-beijing.volces.com'));
    },
  );
  test(
    'overlapping refreshes are single flight and rate limits retain nextPollAt',
    () async {
      final gate = Completer<http.Response>();
      final started = Completer<void>();
      final service = make(
        respond: (r) async {
          if (r.method == 'POST') {
            return http.Response('{"id":"original"}', 200);
          }
          started.complete();
          return gate.future;
        },
      );
      final id = await service.create(
        novelId: 'test-novel',
        sourceType: 'storyboard_shot',
        sourceId: 'test-shot',
        id: 'poll',
        providerId: provider.id,
        request: request,
      );
      await service.submit(id);
      final first = service.refresh(id);
      await started.future;
      await service.refresh(id);
      gate.complete(http.Response('{}', 429, headers: {'retry-after': '120'}));
      await first;
      expect(queries, 1);
      final task = (await service.getTask(id))!;
      expect(
        task.nextPollAt!.difference(DateTime.now()).inSeconds,
        greaterThanOrEqualTo(118),
      );
      expect(posts, 1);
    },
  );
  test(
    'interrupted download leaves saving; explicit retry never submits',
    () async {
      final service = make(
        download: (_) => throw const SocketException('interrupted'),
      );
      final id = await service.create(
        novelId: 'test-novel',
        sourceType: 'storyboard_shot',
        sourceId: 'test-shot',
        id: 'download',
        providerId: provider.id,
        request: request,
      );
      await service.submit(id);
      await service.refresh(id);
      expect((await service.getTask(id))!.status, GenerationTaskStatus.saving);
      expect(
        await File(
          '${root.path}/file_workspaces/test-novel/videos/$id.mp4.part',
        ).exists(),
        false,
      );
      expect(
        await File(
          '${root.path}/file_workspaces/test-novel/videos/$id.mp4',
        ).exists(),
        false,
      );
      service.dispose();
      final restored = make();
      await restored.retryDownload(id);
      expect(
        (await restored.getTask(id))!.status,
        GenerationTaskStatus.completed,
      );
      expect(posts, 1);
    },
  );
  test('database failure during creation leaves nothing to recover', () async {
    final service = make();
    db.generationTaskDao.failCreateOnce = true;
    await expectLater(
      service.create(
        id: 'receipt-source',
        providerId: provider.id,
        novelId: 'work',
        sourceType: 'canvas_node',
        sourceId: 'original-node',
        request: request,
      ),
      throwsStateError,
    );
    expect(await service.getTask('receipt-source'), isNull);
    await service.shutdown();
    final restored = make();
    await restored.start();
    expect(await restored.getTask('receipt-source'), isNull);
    expect(posts, 0);
  });

  test(
    'source identity is mandatory and the same task ID cannot change source',
    () async {
      final service = make();
      for (final missing in ['novel', 'type', 'id']) {
        await expectLater(
          service.create(
            id: 'invalid-$missing',
            providerId: provider.id,
            novelId: missing == 'novel' ? '' : 'work',
            sourceType: missing == 'type' ? ' ' : 'storyboard_shot',
            sourceId: missing == 'id' ? '' : 'shot',
            request: request,
          ),
          throwsA(isA<VideoException>()),
        );
      }
      await service.create(
        id: 'fixed',
        providerId: provider.id,
        novelId: 'work',
        sourceType: 'storyboard_shot',
        sourceId: 'shot',
        request: request,
      );
      await expectLater(
        service.create(
          id: 'fixed',
          providerId: provider.id,
          novelId: 'other',
          sourceType: 'storyboard_shot',
          sourceId: 'shot',
          request: request,
        ),
        throwsA(isA<VideoException>()),
      );
      expect((await db.select(db.generationTasks).get()).length, 1);
      expect(posts, 0);
    },
  );

  test(
    'concurrent same-source creation keeps one task and independent sources stay isolated',
    () async {
      final service = make();
      final otherService = make();
      Future<Object> create(
        String id,
        String novel,
        String type,
        String source,
      ) async {
        try {
          return await (id == 'two' ? otherService : service).create(
            id: id,
            providerId: provider.id,
            novelId: novel,
            sourceType: type,
            sourceId: source,
            request: request,
          );
        } catch (error) {
          return error;
        }
      }

      final results = await Future.wait([
        create('one', 'work', 'storyboard_shot', 'shot'),
        create('two', 'work', 'storyboard_shot', 'shot'),
      ]);
      expect(results.whereType<String>(), hasLength(1));
      expect(results.whereType<VideoException>(), hasLength(1));
      await create('other-work', 'other', 'storyboard_shot', 'shot');
      await create('other-type', 'work', 'canvas_node', 'shot');
      await create('other-source', 'work', 'storyboard_shot', 'other');
      final history = await service
          .watchSource(
            novelId: 'work',
            sourceType: 'storyboard_shot',
            sourceId: 'shot',
          )
          .first;
      expect(history.single.id, results.whereType<String>().single);
      expect(await db.select(db.generationTasks).get(), hasLength(4));
      final rejected = results.whereType<String>().single == 'one'
          ? 'two'
          : 'one';
      expect(
        await File(
          '${root.path}/video/tasks/$rejected/preparation.json',
        ).exists(),
        false,
      );
      expect(posts, 0);
    },
  );

  test(
    'probe failure retains downloaded result and retries registration offline',
    () async {
      final service = make();
      final id = await service.create(
        id: 'probe-retry',
        providerId: provider.id,
        novelId: 'work',
        sourceType: 'canvas_node',
        sourceId: 'node',
        request: request,
      );
      probeFails = true;
      await service.submit(id);
      await service.refresh(id);
      final pending = (await service.getTask(id))!;
      expect(pending.status, GenerationTaskStatus.action_required);
      expect(pending.resultAssetId, isNull);
      expect(pending.errorCode, 'asset_registration_failed');
      expect(await File('${root.path}/${pending.path}').length(), 4);
      probeFails = false;
      service.setOnline(false);
      await service.retryDownload(id);
      final completed = (await service.getTask(id))!;
      final asset = (await db.assetDao.getAsset(completed.resultAssetId!))!;
      expect(asset.id, matches(r'^ast_[A-Za-z0-9]{16}$'));
      expect(asset.durationMs, 5000);
      expect(posts, 1);
      expect(queries, 1);
    },
  );

  test(
    'result registration rolls back atomically and recovers offline after restart',
    () async {
      final service = make();
      final id = await service.create(
        id: 'registration',
        providerId: provider.id,
        novelId: 'work',
        sourceType: 'storyboard_shot',
        sourceId: 'shot',
        request: request,
      );
      db.assetDao.failAfterInsert = true;
      await service.submit(id);
      await service.refresh(id);
      final pending = (await service.getTask(id))!;
      expect(pending.status, GenerationTaskStatus.action_required);
      expect(pending.path, isNotNull);
      expect(pending.resultAssetId, isNull);
      expect(pending.errorCode, 'asset_registration_failed');
      expect(await db.select(db.assets).get(), isEmpty);
      expect(await File('${root.path}/${pending.path}').readAsBytes(), [
        1,
        2,
        3,
        4,
      ]);
      await expectLater(
        service.create(
          id: 'too-early',
          providerId: provider.id,
          novelId: 'work',
          sourceType: 'storyboard_shot',
          sourceId: 'shot',
          request: request,
        ),
        throwsA(isA<VideoException>()),
      );
      await service.shutdown();
      await db.close();
      db = _RecoveryDatabase(NativeDatabase(File('${root.path}/app.sqlite')));
      final restored = make()..setOnline(false);
      await restored.start();
      final result = (await restored.getTask(id))!;
      final asset = (await db.assetDao.getAsset(result.resultAssetId!))!;
      expect(asset.id, matches(r'^ast_[A-Za-z0-9]{16}$'));
      expect(asset.type, 'video');
      expect(asset.width, 1280);
      expect(asset.height, 720);
      expect(asset.durationMs, 5000);
      expect(asset.novelId, 'work');
      expect(asset.path, result.path);
      expect(asset.batchId, isNull);
      expect(asset.prompt, isNull);
      expect(result.errorCode, isNull);
      await Future.wait([
        restored.retryResultRegistration(id),
        restored.retryResultRegistration(id),
      ]);
      expect(await db.select(db.assets).get(), hasLength(1));
      expect(posts, 1);
      expect(queries, 1);
    },
  );

  test(
    'success failure redo retain independent assets and immutable source history',
    () async {
      final service = make();
      Future<String> create(String id) => service.create(
        id: id,
        providerId: provider.id,
        novelId: 'work',
        sourceType: 'storyboard_shot',
        sourceId: 'shot',
        request: request,
      );
      final first = await create('t1');
      await service.submit(first);
      await service.refresh(first);
      final failed = await create('t2');
      await db.generationTaskDao.transition(
        failed,
        {GenerationTaskStatus.prepared},
        const GenerationTasksCompanion(
          status: Value(GenerationTaskStatus.failed),
        ),
      );
      final third = await create('t3');
      await service.submit(third);
      await service.refresh(third);
      final history = await service
          .watchSource(
            novelId: 'work',
            sourceType: 'storyboard_shot',
            sourceId: 'shot',
          )
          .first;
      expect(history, hasLength(3));
      expect(history.singleWhere((t) => t.id == failed).resultAssetId, isNull);
      final assets = await db.select(db.assets).get();
      expect(assets, hasLength(2));
      expect(assets.map((a) => a.id).toSet(), hasLength(2));
      for (final asset in assets) {
        expect(await File('${root.path}/${asset.path}').readAsBytes(), [
          1,
          2,
          3,
          4,
        ]);
      }
      expect(history.every((t) => t.videoRequest.prompt == 'bird'), true);
      expect(posts, 2);
    },
  );
}

class _RecoveryDatabase extends AppDatabase {
  _RecoveryDatabase(super.executor) : super.forTest();

  late final _RecoveryDao _recoveryDao = _RecoveryDao(this);

  late final _FailingAssetDao _assetDao = _FailingAssetDao(this);

  @override
  _FailingAssetDao get assetDao => _assetDao;

  @override
  _RecoveryDao get generationTaskDao => _recoveryDao;
}

class _RecoveryDao extends GenerationTaskDao {
  _RecoveryDao(super.db);
  Future<void> Function()? afterUploading;
  bool failRecoveryOnce = false;
  bool failCreateOnce = false;

  @override
  Future<void> create(GenerationTasksCompanion task) async {
    if (failCreateOnce) {
      failCreateOnce = false;
      throw StateError('simulated task insert failure');
    }
    return super.create(task);
  }

  @override
  Future<List<GenerationTask>> recoverable({
    required GenerationKind kind,
  }) async {
    if (failRecoveryOnce) {
      failRecoveryOnce = false;
      throw StateError('transient recovery read failure');
    }
    return super.recoverable(kind: kind);
  }

  @override
  Future<bool> transition(
    String id,
    Set<GenerationTaskStatus> expected,
    GenerationTasksCompanion values,
  ) async {
    final changed = await super.transition(id, expected, values);
    if (changed &&
        values.status.present &&
        values.status.value == GenerationTaskStatus.uploading) {
      final callback = afterUploading;
      afterUploading = null;
      await callback?.call();
    }
    return changed;
  }
}

class _FailingAssetDao extends AssetDao {
  _FailingAssetDao(super.db);
  bool failAfterInsert = false;

  @override
  Future<void> insertAsset(AssetsCompanion asset) async {
    await super.insertAsset(asset);
    if (failAfterInsert) {
      failAfterInsert = false;
      throw StateError(
        'simulated interruption between asset and result pointer',
      );
    }
  }
}

class _UnusedImages implements ImageTaskService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedAudio implements AudioTaskService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

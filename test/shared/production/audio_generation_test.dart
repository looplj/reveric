// 职责: 验证音频生成、保存恢复、取消和历史采用，不调用外部供应商。
// 关联文件:
//   lib/shared/services/production/audio_service.dart
//   lib/shared/services/production/audio_generate_orchestrator.dart
//   lib/shared/services/backup_service.dart
import 'dart:async';
import 'package:reveric/shared/services/production/voices.dart';
import 'package:reveric/shared/services/ai/video/client.dart' show videoContent;
import 'package:reveric/shared/models/video/task_result.dart';
import 'dart:convert';
import 'package:reveric/shared/models/audio/exception.dart';
import 'package:reveric/shared/models/audio/request.dart';
import 'package:reveric/shared/models/audio/channels.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:archive/archive_io.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:reveric/shared/services/backup_service.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'dart:typed_data';
import 'package:reveric/shared/services/ai/audio/openrouter.dart';
import 'package:reveric/shared/services/ai/audio/seed.dart';
import 'package:reveric/shared/models/storyboard/prompt.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/services/production/generate_orchestrator.dart';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/generation/task.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/services/production/audio_service.dart';
import 'package:reveric/shared/services/production/audio_generate_orchestrator.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/result_service.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import '../../helpers/media_provider_types.dart';

class _Media extends MediaService {
  _Media() : super(FfmpegRunner());
  bool fail = false;
  Duration duration = const Duration(seconds: 3);
  String audioCodec = 'pcm_s16le';
  @override
  Future<MediaInfo> probe(
    String path, {
    MediaCancellation? cancellation,
  }) async {
    if (fail) {
      throw StateError('probe unavailable');
    }
    if (path.endsWith('.png')) {
      return const MediaInfo(
        duration: Duration.zero,
        hasAudio: false,
        hasVideo: true,
        videoCodec: 'png',
        width: 512,
        height: 512,
      );
    }
    return MediaInfo(
      duration: duration,
      hasAudio: true,
      hasVideo: false,
      formatName: path.endsWith('.mp3') ? 'mp3' : 'wav',
      audioCodec: audioCodec,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late app.AppDatabase appDb;
  late NovelContentDatabase db;
  late ProductionCanvasService canvas;
  late CanvasNode node;
  late _Media media;
  final bytes = Uint8List.fromList(List.generate(64, (i) => i));
  AudioTaskService jobs(
    ProductionAudioInvoke invoke, {
    Future<Uint8List> Function(app.AiProvider, Uri)? download,
    ProductionAudioQuery? query,
    Duration pollInterval = Duration.zero,
  }) {
    final results = ProductionResultService(appDb, (_) async => canvas);
    return AudioTaskService(
      database: appDb,
      library: canvas.library,
      invoke: invoke,
      query: query,
      pollInterval: pollInterval,
      download: download ?? (_, _) async => bytes,
      beforeCreate: results.beforeCreate,
      beforeSubmit: results.beforeSubmit,
      recoverSources: results.recover,
    );
  }

  Future<ProductionAudioPreview> preview() =>
      ProductionAudioGenerateOrchestrator().preview(canvas, node.id);
  Future<ProductionAudioPreview> atlasPreview() async {
    final provider = (await appDb.aiProviderDao.getById('audio'))!;
    await appDb.aiProviderDao.upsert(
      provider.copyWith(
        type: 'atlascloud',
        audioModels: ['bytedance/seed-audio-1.0'],
      ),
    );
    final clip = (await canvas.shots.getShot(node.clipId!))!;
    await canvas.shots.apply(clip.id, {
      ...canvas.shots.snapshot(clip),
      'model_id': 'bytedance/seed-audio-1.0',
    });
    return preview();
  }

  Future<String> submit(AudioTaskService service, ProductionAudioPreview p) =>
      service.submit(
        novelId: p.novelId,
        sourceType: p.sourceType,
        sourceId: p.sourceId,
        request: p.request,
      );
  Future<app.GenerationTask> running() async {
    for (var i = 0; i < 100; i++) {
      final rows = await appDb.select(appDb.generationTasks).get();
      if (rows.isNotEmpty && rows.last.status == GenerationTaskStatus.running) {
        return rows.last;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    throw StateError('No running request');
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('production-audio-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await RevericPaths.initialize();
    appDb = app.AppDatabase.forTest(NativeDatabase.memory());
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    await appDb
        .into(appDb.aiProviders)
        .insert(
          app.AiProvidersCompanion.insert(
            id: 'audio',
            name: 'Audio',
            type: 'volcengine',
            enabled: const Value(true),
            apiKey: const Value('test'),
            audioModels: const Value(['seed-audio-1.0']),
          ),
        );
    final episode = (await ScreenplayService(
      db,
    ).createInitialStructure()).episodeId;
    media = _Media();
    canvas = ProductionCanvasService(
      StoryboardService(db),
      MediaLibraryService(appDb, media, root),
      'work',
    );
    node = await canvas.addAudio((await canvas.ensureCanvas(episode)).id);
    final clip = (await canvas.shots.getShot(node.clipId!))!;
    await canvas.shots.apply(clip.id, {
      ...canvas.shots.snapshot(clip),
      'prompt': 'Hello',
      'provider_id': 'audio',
      'model_id': 'seed-audio-1.0',
    });
  });
  tearDown(() async {
    await db.close();
    await appDb.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await root.delete(recursive: true);
  });
  test(
    'saved audio uses the actual MIME and preserves returned bytes',
    () async {
      final p = await preview();
      final service = jobs(
        (_, _, _, _) async =>
            AudioGenerationResult(bytes, mimeType: 'audio/mpeg'),
      );
      addTearDown(service.shutdown);
      final task = await service.requireRun(await submit(service, p));
      expect(task.status, GenerationTaskStatus.completed);
      expect(task.path, endsWith('.mp3'));
      expect(
        await File(canvas.library.resolvePath(task.path!)).readAsBytes(),
        bytes,
      );
    },
  );

  test(
    'AtlasCloud persists prediction before polling and saves one completed output',
    () async {
      final p = await atlasPreview();
      var submits = 0;
      var polls = 0;
      final service = jobs(
        (_, _, _, _) async {
          submits++;
          return AudioGenerationResult.pending('atlas-prediction');
        },
        query: (provider, id, abort) async {
          final row = await running();
          expect(row.providerTaskId, id);
          expect(provider.type, 'atlascloud');
          polls++;
          return polls == 1
              ? AudioGenerationResult.pending(id)
              : AudioGenerationResult(
                  Uint8List(0),
                  url: Uri.parse('https://cdn.example/audio.wav'),
                  providerTaskId: id,
                );
        },
      );
      addTearDown(service.shutdown);
      final task = await service.requireRun(await submit(service, p));
      expect(submits, 1);
      expect(polls, 2);
      expect(task.providerTaskId, 'atlas-prediction');
      expect(task.status, GenerationTaskStatus.completed);
      expect(task.resultAssetId, isNotNull);
    },
  );

  test(
    'AtlasCloud restart resumes saved prediction without another submission',
    () async {
      final p = await atlasPreview();
      var submits = 0;
      final queried = Completer<void>();
      final first = jobs(
        (_, _, _, _) async {
          submits++;
          return AudioGenerationResult.pending('saved-prediction');
        },
        query: (_, id, abort) async {
          queried.complete();
          await abort;
          throw const AudioException('cancelled');
        },
      );
      final submitted = submit(first, p);
      await queried.future;
      final row = await running();
      expect(row.providerTaskId, 'saved-prediction');
      await first.shutdown();
      await submitted;
      var polls = 0;
      final restarted = jobs(
        (_, _, _, _) async {
          fail('Recovery must never POST');
        },
        query: (_, id, abort) async {
          expect(id, 'saved-prediction');
          polls++;
          return AudioGenerationResult(
            Uint8List(0),
            url: Uri.parse('https://cdn.example/recovered.wav'),
            providerTaskId: id,
          );
        },
      );
      addTearDown(restarted.shutdown);
      await restarted.recover();
      final completed = await appDb.generationTaskDao
          .watchTask(row.id)
          .firstWhere((task) => task!.status.isTerminal)
          .timeout(const Duration(seconds: 5));
      expect(completed!.status, GenerationTaskStatus.completed);
      expect(submits, 1);
      expect(polls, 1);
    },
  );

  test('AtlasCloud query failure can retry the same prediction', () async {
    final p = await atlasPreview();
    var submits = 0;
    var polls = 0;
    final service = jobs(
      (_, _, _, _) async {
        submits++;
        return AudioGenerationResult.pending('retry-prediction');
      },
      query: (_, id, abort) async {
        if (++polls == 1) {
          throw const AudioException('unavailable');
        }
        return AudioGenerationResult(bytes, providerTaskId: id);
      },
    );
    addTearDown(service.shutdown);
    final id = await submit(service, p);
    expect(
      (await service.requireRun(id)).status,
      GenerationTaskStatus.action_required,
    );
    await service.retrySaveOutput(id);
    expect(
      (await service.requireRun(id)).status,
      GenerationTaskStatus.completed,
    );
    expect(submits, 1);
    expect(polls, 2);
  });

  test(
    'AtlasCloud URL-only output download failure retries saving without generating',
    () async {
      final p = await atlasPreview();
      var downloads = 0;
      var submits = 0;
      final service = jobs(
        (_, _, _, _) async {
          submits++;
          return AudioGenerationResult.pending('download-prediction');
        },
        query: (_, id, abort) async => AudioGenerationResult(
          Uint8List(0),
          url: Uri.parse('https://cdn.example/audio.wav'),
          providerTaskId: id,
        ),
        download: (_, _) async {
          if (++downloads == 1) {
            throw const AudioException('audio_output_unavailable');
          }
          return bytes;
        },
      );
      addTearDown(service.shutdown);
      final id = await submit(service, p);
      final failed = await service.requireRun(id);
      expect(failed.status, GenerationTaskStatus.action_required);
      expect(failed.outputHash, isNull);
      expect(failed.outputUrl, isNotNull);
      await service.retrySaveOutput(id);
      expect(
        (await service.requireRun(id)).status,
        GenerationTaskStatus.completed,
      );
      expect(submits, 1);
      expect(downloads, 2);
    },
  );

  test(
    'AtlasCloud cancellation wakes polling delay and never registers an output',
    () async {
      final p = await atlasPreview();
      final queried = Completer<void>();
      var polls = 0;
      final service = jobs(
        (_, _, _, _) async =>
            AudioGenerationResult.pending('cancel-prediction'),
        pollInterval: const Duration(minutes: 1),
        query: (_, id, abort) async {
          polls++;
          queried.complete();
          return AudioGenerationResult.pending(id);
        },
      );
      addTearDown(service.shutdown);
      final submitted = submit(service, p);
      await queried.future;
      final row = await running();
      await service.cancel(row.id);
      await submitted.timeout(const Duration(seconds: 2));
      final task = await service.requireRun(row.id);
      expect(task.status, GenerationTaskStatus.cancelled);
      expect(task.resultAssetId, isNull);
      expect(polls, 1);
    },
  );

  test(
    'AtlasCloud terminal failure does not become a resumable query',
    () async {
      final p = await atlasPreview();
      final service = jobs(
        (_, _, _, _) async =>
            AudioGenerationResult.pending('failed-prediction'),
        query: (_, id, abort) async => throw const AudioException('rejected'),
      );
      addTearDown(service.shutdown);
      final task = await service.requireRun(await submit(service, p));
      expect(task.status, GenerationTaskStatus.failed);
    },
  );
  test(
    'success registers audio, adopts history, and provider audio model survives roundtrip',
    () async {
      final provider = (await appDb.aiProviderDao.getById('audio'))!;
      await appDb.aiProviderDao.upsert(provider);
      expect((await appDb.aiProviderDao.getById('audio'))!.audioModels, [
        'seed-audio-1.0',
      ]);
      final service = jobs((_, _, _, _) async => AudioGenerationResult(bytes));
      final p = await preview();
      final first = await service.requireRun(await submit(service, p));
      expect(first.status, GenerationTaskStatus.completed);
      final asset = (await appDb.assetDao.getAsset(first.resultAssetId!))!;
      expect(asset.id, matches(r'^ast_[A-Za-z0-9]{16}$'));
      expect(await File('${root.path}/${asset.path}.part').exists(), false);
      expect(asset.source, 'generated');
      expect(asset.novelId, 'work');
      expect(asset.prompt, 'Hello');
      expect(
        (await appDb.assetDao.getAsset(first.resultAssetId!))!.type,
        'audio',
      );
      expect(
        (await canvas.shots.getShot(node.clipId!))!.adoptedAssetId,
        first.resultAssetId,
      );
      await service.recover();
      expect(await appDb.select(appDb.assets).get(), hasLength(1));
      expect((await service.requireRun(first.id)).resultAssetId, asset.id);
      final secondService = jobs(
        (_, _, _, _) async =>
            AudioGenerationResult(Uint8List.fromList([...bytes, 1])),
      );
      final second = await secondService.requireRun(
        await submit(secondService, p),
      );
      expect(second.status, GenerationTaskStatus.completed);
      await canvas.adoptGenerated(node.id, first.id);
      expect(
        (await canvas.shots.getShot(node.clipId!))!.adoptedAssetId,
        first.resultAssetId,
      );
      expect(
        (await appDb.generationTaskDao.getById(
          first.id,
        ))!.audioRequest.toJson(),
        p.request.toJson(),
      );
    },
  );
  test(
    'save failure retries local output without calling supplier again',
    () async {
      var calls = 0;
      media.fail = true;
      final service = jobs((_, _, _, _) async {
        calls++;
        return AudioGenerationResult(bytes);
      });
      final id = await submit(service, await preview());
      expect(
        (await service.requireRun(id)).status,
        GenerationTaskStatus.action_required,
      );
      media.fail = false;
      await service.retrySaveOutput(id);
      expect(
        (await service.requireRun(id)).status,
        GenerationTaskStatus.completed,
      );
      expect(calls, 1);
    },
  );

  test(
    'OpenRouter freezes PCM defaults and stores a WAV containing the original samples',
    () async {
      final provider = (await appDb.aiProviderDao.getById('audio'))!;
      const model = 'bytedance-seed/seed-audio-1-0';
      await appDb.aiProviderDao.upsert(
        provider.copyWith(type: 'openrouter', audioModels: [model]),
      );
      final clip = (await canvas.shots.getShot(node.clipId!))!;
      await canvas.shots.apply(clip.id, {
        ...canvas.shots.snapshot(clip),
        'model_id': model,
      });
      final frozen = await preview();
      expect(frozen.request.parameters.responseFormat, 'pcm');
      expect(frozen.request.parameters.sampleRate, isNull);
      final pcm = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      var posts = 0;
      final client = OpenRouterAudioClient(
        MockClient((r) async {
          posts++;
          expect((jsonDecode(r.body) as Map)['response_format'], 'pcm');
          return http.Response.bytes(
            pcm,
            200,
            headers: {'content-type': 'audio/pcm;rate=44100;channels=2'},
          );
        }),
        'key',
        providerType: 'openrouter',
      );
      final service = jobs(
        (provider, request, references, abort) => client.generate(
          request,
          references: references,
          abortTrigger: abort,
        ),
      );
      final task = await service.requireRun(await submit(service, frozen));
      expect(task.status, GenerationTaskStatus.completed);
      expect(task.path, endsWith('.wav'));
      expect(task.audioRequest.parameters.responseFormat, 'pcm');
      final saved = await File(
        canvas.library.resolvePath(task.path!),
      ).readAsBytes();
      expect(saved.sublist(44), pcm);
      expect(ByteData.sublistView(saved).getUint32(24, Endian.little), 44100);
      final asset = (await appDb.assetDao.getAsset(task.resultAssetId!))!;
      expect((asset.content as AudioAssetContent).mimeType, 'audio/wav');
      expect(posts, 1);
    },
  );

  test('MiniMax draft freezes the request and saves long MP3 output', () async {
    final provider = (await appDb.aiProviderDao.getById('audio'))!;
    await appDb.aiProviderDao.upsert(
      provider.copyWith(type: 'minimax', audioModels: ['music-3.0']),
    );
    final clip = (await canvas.shots.getShot(node.clipId!))!;
    await canvas.shots.apply(clip.id, {
      ...canvas.shots.snapshot(clip),
      'model_id': 'music-3.0',
    });
    final frozen = await preview();
    final frozenPrompt = frozen.request.prompt;
    await canvas.shots.apply(clip.id, {
      ...canvas.shots.snapshot((await canvas.shots.getShot(clip.id))!),
      'prompt': 'New draft',
    });
    media.duration = const Duration(minutes: 4);
    final service = jobs((provider, request, references, abort) async {
      expect(provider.type, 'minimax');
      expect(request.prompt, frozenPrompt);
      expect(references, isEmpty);
      return AudioGenerationResult(bytes);
    });
    final task = await service.requireRun(await submit(service, frozen));
    expect(task.status, GenerationTaskStatus.completed);
    expect(task.path, endsWith('.mp3'));
    expect(task.audioRequest.prompt, frozenPrompt);
    final asset = (await appDb.assetDao.getAsset(task.resultAssetId!))!;
    expect((asset.content as AudioAssetContent).mimeType, 'audio/mpeg');
  });
  test('unknown supplier outcome is not resubmitted on recovery', () async {
    var calls = 0;
    final service = jobs((_, _, _, _) async {
      calls++;
      throw const AudioException('audio_submission_unknown');
    });
    final id = await submit(service, await preview());
    expect(
      (await service.requireRun(id)).errorCode,
      'audio_submission_unknown',
    );
    await jobs((_, _, _, _) async {
      calls++;
      return AudioGenerationResult(bytes);
    }).recover();
    expect(calls, 1);
  });
  test('cancelled late response cannot adopt output', () async {
    final pending = Completer<AudioGenerationResult>();
    final service = jobs((_, _, _, _) => pending.future);
    final future = submit(service, await preview());
    final task = await running();
    await service.cancel(task.id);
    pending.complete(AudioGenerationResult(bytes));
    await future;
    expect(
      (await service.requireRun(task.id)).status,
      GenerationTaskStatus.cancelled,
    );
    expect((await canvas.shots.getShot(node.clipId!))!.adoptedAssetId, isNull);
  });
  test(
    'audio download rejects cancellation and still saves and adopts',
    () async {
      final entered = Completer<void>();
      final downloaded = Completer<Uint8List>();
      final service = jobs(
        (_, _, _, _) async => AudioGenerationResult(
          Uint8List(0),
          url: Uri.https('outputs.example', '/result.wav'),
        ),
        download: (_, _) {
          entered.complete();
          return downloaded.future;
        },
      );
      final pending = submit(service, await preview());
      await entered.future;
      try {
        final task = (await appDb.select(appDb.generationTasks).get()).single;
        expect(task.status, GenerationTaskStatus.saving);
        await service.cancel(task.id);
        final results = ProductionResultService(appDb, (_) async => canvas);
        expect((await results.requestCancellation(task.id)).accepted, isFalse);
        final saving = await service.requireRun(task.id);
        expect(saving.status, GenerationTaskStatus.saving);
        expect(saving.cancelRequestedAt, isNull);
      } finally {
        downloaded.complete(bytes);
      }
      final id = await pending;
      final completed = await service.requireRun(id);
      expect(completed.status, GenerationTaskStatus.completed);
      expect(completed.resultAssetId, isNotNull);
      expect(
        (await canvas.shots.getShot(node.clipId!))!.adoptedAssetId,
        completed.resultAssetId,
      );
    },
  );
  for (final shutdown in [false, true]) {
    test(
      '${shutdown ? "shutdown" : "cancel"} signals the active audio request',
      () async {
        final entered = Completer<void>();
        final aborted = Completer<void>();
        final service = jobs((_, _, _, abortTrigger) async {
          entered.complete();
          await abortTrigger;
          aborted.complete();
          throw const AudioException('cancelled');
        });
        final pending = submit(service, await preview());
        await entered.future;
        final task = await running();
        if (shutdown) {
          await service.shutdown().timeout(const Duration(seconds: 2));
        } else {
          await service.cancel(task.id);
        }
        await aborted.future.timeout(const Duration(seconds: 2));
        await pending.timeout(const Duration(seconds: 2));
        if (!shutdown) {
          expect(
            (await service.requireRun(task.id)).status,
            GenerationTaskStatus.cancelled,
          );
        }
        expect(
          (await canvas.shots.getShot(node.clipId!))!.adoptedAssetId,
          isNull,
        );
      },
    );
  }
  test(
    'known audio HTTP failures persist a safe reason without regeneration',
    () async {
      var calls = 0;
      final service = jobs((_, _, _, _) async {
        calls++;
        throw const AudioException(
          'authentication',
          statusCode: 401,
          messageKey: LocaleKeys.aiApiKeyInvalid,
          providerMessage: 'Provider rejected this voice: custom-voice',
        );
      });
      final task = await service.requireRun(
        await submit(service, await preview()),
      );
      expect(task.status, GenerationTaskStatus.failed);
      expect(task.errorCode, 'authentication');
      expect(task.errorMessage, 'Provider rejected this voice: custom-voice');
      await service.recover();
      expect(calls, 1);
    },
  );
  test(
    'restart fails running request and restores saved output despite an obsolete hash without POST',
    () async {
      final p = await preview();
      final file = File('${root.path}/file_workspaces/work/audio/pending.wav');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      for (final saving in [false, true]) {
        await appDb
            .into(appDb.generationTasks)
            .insert(
              app.GenerationTasksCompanion.insert(
                id: saving ? 'saved' : 'interrupted',
                kind: GenerationKind.audio,
                novelId: 'work',
                sourceType: 'production_clip',
                sourceId: node.clipId!,
                providerId: 'audio',
                providerType: 'volcengine',
                modelId: p.request.modelId,
                requestJson: AudioGenerationRequest(p.request),
                status: saving
                    ? GenerationTaskStatus.saving
                    : GenerationTaskStatus.running,
                path: Value(saving ? file.path : null),
                outputHash: Value(saving ? 'obsolete-output-hash' : null),
              ),
            );
      }
      final service = jobs(
        (_, _, _, _) async => throw StateError('Do not POST'),
      );
      await service.recover();
      expect(
        (await service.requireRun('interrupted')).errorCode,
        'interrupted',
      );
      expect(
        (await service.requireRun('saved')).status,
        GenerationTaskStatus.completed,
      );
    },
  );
  Future<CanvasNode> source(String id, String kind) async {
    final path =
        'file_workspaces/work/${kind == 'audio' ? 'audio' : 'images'}/$id.${kind == 'audio' ? 'wav' : 'png'}';
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsBytes([...bytes, id.length]);
    await appDb.assetDao.insertAsset(
      app.AssetsCompanion.insert(
        id: id,
        type: kind,
        purpose: kind == 'image' ? 'upload' : 'general',
        path: Value(path),
        content: Value(
          kind == 'audio'
              ? const AudioAssetContent(mimeType: 'audio/wav')
              : const ImageAssetContent(mimeType: 'image/png'),
        ),
      ),
    );
    final source = kind == 'audio'
        ? await canvas.addAudio(node.canvasId)
        : await canvas.addImage(node.canvasId);
    await canvas.adopt(source.id, id);
    return source;
  }

  Future<void> connect(CanvasNode source, int order) async {
    final inputs = [...await canvas.inputs(node.id)];
    inputs.insert(
      order,
      ProductionInput(
        id: source.clipId!,
        refType: ProductionInputType.node,
        refId: source.id,
        role: source.type == 'audio'
            ? VideoInputRole.reference_audio
            : VideoInputRole.reference_image,
      ),
    );
    await canvas.shots.restoreInputs(
      node.clipId!,
      inputs.map((i) => i.toJson()).toList(),
    );
  }

  test(
    'audio references freeze paths and numbering across reorder and upstream replacement',
    () async {
      final first = await source('one', 'audio');
      final second = await source('second', 'audio');
      await connect(first, 0);
      await connect(second, 1);
      final clip = (await canvas.shots.getShot(node.clipId!))!;
      await canvas.shots.apply(clip.id, {
        ...canvas.shots.snapshot(clip),
        'prompt':
            'Use ${StoryboardPrompt.reference(first.clipId!, 'One')} then ${StoryboardPrompt.reference(second.clipId!, 'Two')}',
      });
      final frozen = await preview();
      expect(frozen.request.prompt, 'Use @Audio1 then @Audio2');
      expect(frozen.request.references.map((r) => r.assetId), [
        'one',
        'second',
      ]);
      await canvas.shots.restoreInputs(
        node.clipId!,
        (await canvas.inputs(node.id)).reversed.map((i) => i.toJson()).toList(),
      );
      expect((await preview()).request.prompt, 'Use @Audio2 then @Audio1');
      await canvas.adopt(first.id, 'second');
      expect(frozen.request.references.first.assetId, 'one');
      final client = SeedAudioClient(
        MockClient((_) async => throw StateError('encode only')),
        'key',
        providerType: 'volcengine',
      );
      final operation = ProductionAudioGenerateOrchestrator();
      final prepared = await operation.prepareReferences(
        frozen.request,
        canvas.library,
        providerType: audioProviderType(AudioProtocol.seed_audio),
      );
      final encoded = client.encode(frozen.request, references: prepared);
      expect((encoded['references'] as List).first, {
        'audio_data': base64Encode(
          await File(
            '${root.path}/file_workspaces/work/audio/one.wav',
          ).readAsBytes(),
        ),
      });
      var calls = 0;
      final service = jobs((_, r, prepared, _) async {
        calls++;
        expect(r.references.first.assetId, 'one');
        expect(
          prepared.first,
          await File(
            '${root.path}/file_workspaces/work/audio/one.wav',
          ).readAsBytes(),
        );
        return AudioGenerationResult(bytes);
      });
      final task = await service.requireRun(await submit(service, frozen));
      expect(task.audioRequest.references.first.assetId, 'one');
      await File(
        '${root.path}/file_workspaces/work/audio/one.wav',
      ).writeAsBytes(List.filled(65, 7));
      final current = await operation.prepareReferences(
        frozen.request,
        canvas.library,
        providerType: audioProviderType(AudioProtocol.seed_audio),
      );
      expect(current.first, List.filled(65, 7));
      expect(calls, 1);
      await expectLater(
        canvas.requireAcyclic(node.id, first.id, node.canvasId),
        throwsA(isA<StoryboardException>()),
      );
    },
  );
  test(
    'image mode emits image_data and rejects mixing before task creation',
    () async {
      final picture = await source('image', 'image');
      await connect(picture, 0);
      final p = await preview();
      expect(p.request.references.single.kind, 'image');
      expect(p.request.prompt, 'Hello');
      final encoded =
          SeedAudioClient(
            MockClient((_) async => throw StateError('encode only')),
            'key',
            providerType: 'volcengine',
          ).encode(
            p.request,
            references: await ProductionAudioGenerateOrchestrator()
                .prepareReferences(
                  p.request,
                  canvas.library,
                  providerType: audioProviderType(AudioProtocol.seed_audio),
                ),
          );
      expect((encoded['references'] as List).single.keys, ['image_data']);
      final audio = await source('voice', 'audio');
      await connect(audio, 1);
      await expectLater(
        preview(),
        throwsA(
          isA<AudioException>().having(
            (e) => e.code,
            'code',
            'audio_reference_mixed',
          ),
        ),
      );
      expect(await appDb.select(appDb.generationTasks).get(), isEmpty);
    },
  );
  test(
    'preview rejects oversized and overlong references before invoking AI',
    () async {
      final voice = await source('voice', 'audio');
      await connect(voice, 0);
      media.duration = const Duration(milliseconds: 30001);
      await expectLater(
        preview(),
        throwsA(
          isA<AudioException>().having(
            (e) => e.code,
            'code',
            'audio_reference_duration',
          ),
        ),
      );
      final file = File('${root.path}/file_workspaces/work/audio/voice.wav');
      final handle = await file.open(mode: FileMode.write);
      await handle.truncate(10 * 1024 * 1024 + 1);
      await handle.close();
      await expectLater(
        preview(),
        throwsA(
          isA<AudioException>().having(
            (e) => e.code,
            'code',
            'audio_reference_size',
          ),
        ),
      );
    },
  );
  test(
    'adopted audio output can feed video references using video model limits',
    () async {
      final service = jobs((_, _, _, _) async => AudioGenerationResult(bytes));
      await submit(service, await preview());
      await appDb
          .into(appDb.aiProviders)
          .insert(
            app.AiProvidersCompanion.insert(
              id: 'video',
              name: 'Video',
              type: 'doubao',
              enabled: const Value(true),
              videoModels: const Value(['doubao-seedance-2-5-260628']),
            ),
          );
      final clip = (await canvas.shots.getShot(node.clipId!))!;
      final video = await canvas.shots.createVideo(
        clip.episodeId,
        values: {
          'prompt': 'Use the sound',
          'duration_ms': 6000,
          'provider_id': 'video',
          'model_id': 'doubao-seedance-2-5-260628',
          'resolution': '720p',
          'ratio': '16:9',
        },
      );
      final target = await canvas.ensureShotNode(video.id);
      await canvas.shots.restoreInputs(target.clipId!, [
        ProductionInput.node(node.id, VideoInputRole.reference_audio).toJson(),
      ]);
      final p = await ProductionGenerateOrchestrator().preview(
        canvas,
        target.id,
      );
      expect(
        p.request.referenceSlots.single.role,
        VideoInputRole.reference_audio,
      );
      expect(
        p.inputs.single.file.path,
        canvas.library.resolve(
          await canvas.requireAsset(
            (await canvas.shots.getShot(node.clipId!))!.adoptedAssetId!,
          ),
        ),
      );
    },
  );
  test(
    'character voices expand into stable video slots and preserve submitted snapshots',
    () async {
      await source('hero-photo', 'image');
      await source('other-photo', 'image');
      await source('hero-voice', 'audio');
      await source('other-voice', 'audio');
      await source('music', 'audio');
      await db
          .into(db.characterProfiles)
          .insert(
            CharacterProfilesCompanion.insert(
              id: 'hero',
              name: 'Hero',
              photos: const Value([SubjectPhoto(assetId: 'hero-photo')]),
            ),
          );
      await db
          .into(db.characterProfiles)
          .insert(
            CharacterProfilesCompanion.insert(
              id: 'other',
              name: 'Other',
              photos: const Value([SubjectPhoto(assetId: 'other-photo')]),
            ),
          );
      await canvas.addCharacterVoice('hero', 'hero-voice');
      await canvas.addCharacterVoice('other', 'other-voice');
      final hero = await canvas.addSubject(node.canvasId, characterId: 'hero');
      final other = await canvas.addSubject(
        node.canvasId,
        characterId: 'other',
      );
      await appDb
          .into(appDb.aiProviders)
          .insert(
            app.AiProvidersCompanion.insert(
              id: 'video',
              name: 'Video',
              type: 'doubao',
              enabled: const Value(true),
              videoModels: const Value(['doubao-seedance-2-5-260628']),
            ),
          );
      final episode = (await canvas.shots.getShot(node.clipId!))!.episodeId;
      final first = ProductionInput.node(
        hero.id,
        VideoInputRole.reference_image,
      ).withVoice('hero-voice');
      final second = ProductionInput.node(
        other.id,
        VideoInputRole.reference_image,
      ).withVoice('other-voice');
      final music = ProductionInput.asset(
        'music',
        VideoInputRole.reference_audio,
      );
      final video = await canvas.shots.createVideo(
        episode,
        values: {
          'prompt': 'A conversation',
          'duration_ms': 6000,
          'provider_id': 'video',
          'model_id': 'doubao-seedance-2-5-260628',
          'resolution': '720p',
          'ratio': '16:9',
        },
      );
      final target = await canvas.ensureShotNode(video.id);
      Future<ProductionPreview> videoPreview(
        List<ProductionInput> inputs,
      ) async {
        await canvas.shots.restoreInputs(
          video.id,
          inputs.map((i) => i.toJson()).toList(),
        );
        return ProductionGenerateOrchestrator().preview(canvas, target.id);
      }

      final frozen = await videoPreview([music, first, second]);
      expect(frozen.inputs.map((i) => i.assetId), [
        'music',
        'hero-photo',
        'hero-voice',
        'other-photo',
        'other-voice',
      ]);
      expect(frozen.request.prompt, contains('图片1 中的角色使用 音频2 的音色'));
      expect(frozen.request.prompt, contains('图片2 中的角色使用 音频3 的音色'));
      final reordered = await videoPreview([second, first, music]);
      expect(reordered.request.prompt, contains('图片1 中的角色使用 音频1 的音色'));
      expect(reordered.request.referenceSlots[1].assetId, 'other-voice');
      expect(reordered.request.referenceSlots[3].assetId, 'hero-voice');
      final wire = videoContent(reordered.request, [
        for (final input in reordered.inputs)
          VideoReference(
            role: input.role,
            url: Uri.https('media.example', '/${input.assetId}').toString(),
            mimeType: input.mimeType,
            fileSize: 64,
            mediaInfo: const VideoMediaInfo(durationMs: 3000),
          ),
      ]);
      expect(wire[2], {
        'type': 'audio_url',
        'audio_url': {'url': 'https://media.example/other-voice'},
        'role': 'reference_audio',
      });
      await canvas.removeCharacterVoice('hero', 'hero-voice');
      await videoPreview([first]);
      expect(frozen.request.referenceSlots[2].assetId, 'hero-voice');
      expect(frozen.request.prompt, contains('音频2'));
      await appDb
          .into(appDb.aiProviders)
          .insert(
            app.AiProvidersCompanion.insert(
              id: 'unsupported-video',
              name: 'No audio',
              type: 'openrouter',
              enabled: const Value(true),
              videoModels: const Value(['bytedance/seedance-2.0']),
            ),
          );
      await canvas.shots.apply(video.id, {
        ...canvas.shots.snapshot((await canvas.shots.getShot(video.id))!),
        'provider_id': 'unsupported-video',
        'model_id': 'bytedance/seedance-2.0',
      });
      await expectLater(
        videoPreview([first]),
        throwsA(
          isA<VideoException>().having((e) => e.field, 'field', 'audio_count'),
        ),
      );
      await canvas.shots.apply(video.id, {
        ...canvas.shots.snapshot((await canvas.shots.getShot(video.id))!),
        'provider_id': 'video',
        'model_id': 'doubao-seedance-2-5-260628',
      });
      media.duration = const Duration(minutes: 10);
      await expectLater(videoPreview([first]), throwsA(isA<VideoException>()));
      media.duration = const Duration(seconds: 3);
      await canvas.shots.apply(video.id, {
        ...canvas.shots.snapshot((await canvas.shots.getShot(video.id))!),
        'reference_mode': 'first_last_frame',
      });
      await expectLater(
        videoPreview([first.withRole(VideoInputRole.first_frame)]),
        throwsA(
          isA<VideoException>().having((e) => e.field, 'field', 'voice_mode'),
        ),
      );
    },
  );

  test(
    'initial file write failure persists receipt and restart downloads without generating',
    () async {
      await Directory(
        '${root.path}/file_workspaces/work',
      ).create(recursive: true);
      final obstruction = await File(
        '${root.path}/file_workspaces/work/audio',
      ).writeAsString('blocked');
      var posts = 0;
      final service = jobs((_, _, _, _) async {
        posts++;
        return AudioGenerationResult(
          bytes,
          url: Uri.https('outputs.example', '/result.wav'),
        );
      });
      final id = await submit(service, await preview());
      final failed = await service.requireRun(id);
      expect(failed.status, GenerationTaskStatus.action_required);
      expect(failed.outputUrl, 'https://outputs.example/result.wav');
      expect(failed.path, isNull);
      service.dispose();
      await obstruction.delete();
      var downloads = 0;
      final restarted = jobs(
        (_, _, _, _) async => throw StateError('Never regenerate'),
        download: (_, url) async {
          downloads++;
          expect(url, Uri.https('outputs.example', '/result.wav'));
          return bytes;
        },
      );
      await restarted.recover();
      expect(
        (await restarted.requireRun(id)).status,
        GenerationTaskStatus.completed,
      );
      expect(posts, 1);
      expect(downloads, 1);
    },
  );
  for (final providerType in ['qwen']) {
    test(
      '$providerType Qwen audio passes preparation and saves the result',
      () async {
        const providerId = 'audio';
        final provider = (await appDb.aiProviderDao.getById('audio'))!;
        await appDb.aiProviderDao.upsert(
          provider.copyWith(
            id: providerId,
            type: providerType,
            audioModels: ['qwen-audio-3.1-tts-plus'],
          ),
        );
        var posts = 0;
        final service = jobs((_, request, references, _) async {
          posts++;
          expect(request.parameters.responseFormat, 'wav');
          expect(request.parameters.voice, 'longanhuan_v3.1');
          expect(references, isEmpty);
          return AudioGenerationResult(
            Uint8List(0),
            url: Uri.https('outputs.example', '/qwen.wav'),
          );
        });
        addTearDown(service.shutdown);
        final id = await service.submit(
          novelId: 'work',
          sourceType: 'production_clip',
          sourceId: node.clipId!,
          request: AudioRequest(
            providerId: providerId,
            modelId: 'qwen-audio-3.1-tts-plus',
            prompt: 'Hello',
            originalPrompt: 'Hello',
            parameters: const AudioRequestDefaults(
              voice: ConfigValue('longanhuan_v3.1'),
            ),
          ),
        );
        final task = await service.requireRun(id);
        expect(task.status, GenerationTaskStatus.completed);
        expect(task.resultAssetId, isNotNull);
        expect(posts, 1);
      },
    );
  }

  test(
    'URL-only audio receipt downloads and saves without another generation',
    () async {
      var posts = 0;
      var downloads = 0;
      final service = jobs(
        (_, request, _, _) async {
          posts++;
          return AudioGenerationResult(
            Uint8List(0),
            url: Uri.https('outputs.example', '/qwen.wav'),
          );
        },
        download: (_, url) async {
          downloads++;
          expect(url.path, '/qwen.wav');
          return bytes;
        },
      );
      final id = await submit(service, await preview());
      expect(
        (await service.requireRun(id)).status,
        GenerationTaskStatus.completed,
      );
      expect(posts, 1);
      expect(downloads, 1);
    },
  );

  test('audio output retry reads the current provider proxy', () async {
    final provider = (await appDb.aiProviderDao.getById('audio'))!;
    await appDb.aiProviderDao.upsert(
      provider.copyWith(
        proxyUrl: 'http://127.0.0.1:8001',
        proxyUsername: 'user',
        proxyPassword: 'first',
      ),
    );
    final routes = <(String, String, String)>[];
    final service = jobs(
      (_, _, _, _) async => AudioGenerationResult(
        Uint8List(0),
        url: Uri.https('outputs.example', '/audio.wav'),
      ),
      download: (config, url) async {
        routes.add((
          config.proxyUrl,
          config.proxyUsername,
          config.proxyPassword,
        ));
        expect(url, Uri.https('outputs.example', '/audio.wav'));
        if (routes.length == 1) {
          throw const AudioException('audio_output_unavailable');
        }
        return bytes;
      },
    );
    addTearDown(service.shutdown);
    final id = await submit(service, await preview());
    expect(
      (await service.requireRun(id)).status,
      GenerationTaskStatus.action_required,
    );
    await appDb.aiProviderDao.upsert(
      provider.copyWith(
        proxyUrl: 'socks5://127.0.0.1:8002',
        proxyUsername: 'user',
        proxyPassword: 'second',
      ),
    );
    await service.retrySaveOutput(id);
    expect(
      (await service.requireRun(id)).status,
      GenerationTaskStatus.completed,
    );
    expect(routes, [
      ('http://127.0.0.1:8001', 'user', 'first'),
      ('socks5://127.0.0.1:8002', 'user', 'second'),
    ]);
  });

  test(
    'expired output remains explicitly recoverable and does not regenerate',
    () async {
      final p = await preview();
      await appDb
          .into(appDb.generationTasks)
          .insert(
            app.GenerationTasksCompanion.insert(
              id: 'expired-output',
              kind: GenerationKind.audio,
              novelId: 'work',
              sourceType: 'production_clip',
              sourceId: node.clipId!,
              providerId: 'audio',
              providerType: 'volcengine',
              modelId: p.request.modelId,
              requestJson: AudioGenerationRequest(p.request),
              status: GenerationTaskStatus.saving,
              outputHash: Value(sha256.convert(bytes).toString()),
              outputUrl: const Value('https://outputs.example/expired.wav'),
            ),
          );
      final service = jobs(
        (_, _, _, _) async => throw StateError('Never regenerate'),
        download: (_, _) async =>
            throw const AudioException('audio_output_unavailable'),
      );
      await service.recover();
      expect(
        (await service.requireRun('expired-output')).status,
        GenerationTaskStatus.action_required,
      );
      expect(
        (await service.requireRun('expired-output')).errorCode,
        'audio_output_unavailable',
      );
      expect((await appDb.select(appDb.generationTasks).get()).length, 1);
    },
  );
  Future<Directory> snapshotForBackup() async {
    await appDb
        .into(appDb.novels)
        .insert(
          app.NovelsCompanion.insert(
            id: 'work',
            title: 'Audio work',
            description: '',
            contentDatabasePath: const Value('novel_workspaces/work.sqlite'),
          ),
        );
    await Directory('${root.path}/novel_workspaces').create(recursive: true);
    await db.customStatement('VACUUM INTO ?', [
      '${root.path}/novel_workspaces/work.sqlite',
    ]);
    await appDb.customStatement('VACUUM INTO ?', [
      '${root.path}/reveric.sqlite',
    ]);
    return Directory('${root.path}/backups')..createSync();
  }

  for (final partial in [false, true]) {
    for (final cancelled in [false, true]) {
      for (final mode in RestoreMode.values) {
        test(
          'pending audio receipt survives ${partial ? 'partial' : 'missing'} output ${cancelled ? 'cancelled' : 'retryable'} ${mode.name} backup restore',
          () async {
            final reference = await source('required-reference', 'audio');
            await connect(reference, 0);
            final p = await preview();
            const id = 'pending-output';
            final taskService = jobs(
              (_, _, _, _) async => throw StateError('No POST during backup'),
            );
            await appDb.generationTaskDao.create(
              app.GenerationTasksCompanion.insert(
                id: id,
                kind: GenerationKind.audio,
                novelId: 'work',
                sourceType: 'production_clip',
                sourceId: node.clipId!,
                providerId: 'audio',
                providerType: 'volcengine',
                modelId: p.request.modelId,
                requestJson: AudioGenerationRequest(p.request),
                status: GenerationTaskStatus.running,
              ),
            );
            await taskService.recordOutput(
              id,
              AudioGenerationResult(
                bytes,
                url: Uri.https('outputs.example', '/result.wav'),
              ),
            );
            final pendingFile = File(
              '${root.path}/file_workspaces/work/audio/$id.wav.part',
            );
            if (partial) {
              await pendingFile.parent.create(recursive: true);
              await pendingFile.writeAsBytes(bytes.take(7).toList());
            }
            if (cancelled) {
              // 保留旧版本已取消任务的备份恢复覆盖。
              await appDb.generationTaskDao.transition(
                id,
                {GenerationTaskStatus.saving},
                const app.GenerationTasksCompanion(
                  status: Value(GenerationTaskStatus.cancelled),
                ),
              );
            } else {
              await taskService.recordFailure(
                id,
                StateError('interrupted file write'),
                StackTrace.current,
              );
            }
            final before = await taskService.requireRun(id);
            final output = await snapshotForBackup();
            final service = BackupService();
            final backup = await service.backupToZip(
              outputDirectory: output.path,
            );
            expect(
              backup.success,
              isTrue,
              reason: 'A pending destination is not a required backup artifact',
            );
            expect(
              (await service.inspectBackup(backup.backupPath!)).success,
              isTrue,
            );
            // Restore must replace these fields from the archive, not preserve the current row.
            final current = sqlite.sqlite3.open('${root.path}/reveric.sqlite');
            current.execute(
              "UPDATE generation_tasks SET output_url='https://current.example/file', output_hash='current-hash' WHERE id=?",
              [id],
            );
            current.close();
            if (partial) {
              await pendingFile.delete();
            }
            final restored = await service.restoreFromZip(
              backup.backupPath!,
              mode: mode,
              novelIds: mode == RestoreMode.selectedNovels
                  ? {'work'}
                  : const <String>{},
            );
            expect(restored.success, isTrue);
            final restoredDb = sqlite.sqlite3.open(
              '${root.path}/reveric.sqlite',
              mode: sqlite.OpenMode.readOnly,
            );
            try {
              final row = restoredDb.select(
                'SELECT * FROM generation_tasks WHERE id=?',
                [id],
              ).single;
              expect(
                row['status'],
                cancelled ? 'cancelled' : 'action_required',
              );
              expect(row['path'], isNull);
              expect(row['output_url'], before.outputUrl);
              expect(row['output_hash'], before.outputHash);
              expect(
                GenerationRequest.fromJson(
                  jsonDecode(row['request_json'] as String)
                      as Map<String, dynamic>,
                ).toJson(),
                before.requestJson.toJson(),
              );
              expect(
                await File(
                  '${root.path}/file_workspaces/work/audio/required-reference.wav',
                ).exists(),
                isTrue,
              );
              if (mode == RestoreMode.selectedNovels) {
                expect(await pendingFile.exists(), isFalse);
              }
            } finally {
              restoredDb.close();
              taskService.dispose();
            }
          },
        );
      }
    }
  }

  test(
    'audio backup preserves asset identity and edited media across restore',
    () async {
      final reference = await source('required-reference', 'audio');
      await connect(reference, 0);
      final service = jobs((_, _, _, _) async => AudioGenerationResult(bytes));
      final completed = await service.requireRun(
        await submit(service, await preview()),
      );
      expect(completed.status, GenerationTaskStatus.completed);
      final output = await snapshotForBackup();
      final backupService = BackupService();
      final backup = await backupService.backupToZip(
        outputDirectory: output.path,
      );
      expect(backup.success, isTrue);
      final archive = ZipDecoder().decodeBytes(
        await File(backup.backupPath!).readAsBytes(),
      );
      const referencePath = 'file_workspaces/work/audio/required-reference.wav';
      expect(
        archive.files.map((entry) => entry.name),
        containsAll([completed.path!, referencePath]),
      );
      final edited = Archive();
      final missingReference = Archive();
      for (final entry in archive.files) {
        edited.addFile(
          entry.name == completed.path
              ? ArchiveFile.bytes(entry.name, [99])
              : entry,
        );
        if (entry.name != referencePath) {
          missingReference.addFile(entry);
        }
      }
      final editedZip = await File(
        '${output.path}/edited.zip',
      ).writeAsBytes(ZipEncoder().encode(edited));
      final missingZip = await File(
        '${output.path}/missing-reference.zip',
      ).writeAsBytes(ZipEncoder().encode(missingReference));
      // Directory backups accept edited or missing media independently of DB hashes.
      expect(
        (await backupService.inspectBackup(editedZip.path)).success,
        isTrue,
      );
      expect(
        (await backupService.inspectBackup(missingZip.path)).success,
        isTrue,
      );
      for (final mode in RestoreMode.values) {
        final restored = await backupService.restoreFromZip(
          editedZip.path,
          mode: mode,
          novelIds: mode == RestoreMode.selectedNovels ? {'work'} : const {},
        );
        expect(restored.success, isTrue);
        expect(await File('${root.path}/${completed.path}').readAsBytes(), [
          99,
        ]);
        final restoredDb = sqlite.sqlite3.open(
          '${root.path}/reveric.sqlite',
          mode: sqlite.OpenMode.readOnly,
        );
        try {
          final task = restoredDb.select(
            'SELECT result_asset_id FROM generation_tasks WHERE id=?',
            [completed.id],
          ).single;
          expect(task['result_asset_id'], completed.resultAssetId);
          final asset = restoredDb.select(
            'SELECT path FROM assets WHERE id=?',
            [completed.resultAssetId],
          ).single;
          expect(asset['path'], completed.path);
        } finally {
          restoredDb.close();
        }
      }
      await File(
        canvas.library.resolvePath(completed.path!),
      ).writeAsBytes([99]);
      expect(
        (await backupService.backupToZip(outputDirectory: output.path)).success,
        isTrue,
      );
      service.dispose();
    },
  );
}

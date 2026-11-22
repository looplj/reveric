// 职责: 持久化转写任务、恢复异步回执并向素材或画布交付转录结果。
// 关联文件:
//   lib/shared/models/generation/task.dart
//   lib/shared/services/ai/transcription/client.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/providers/transcription.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../agent/agent_tool_dispatcher.dart';
import '../../database/app_database.dart';
import '../../logger/app_logger.dart';
import '../../models/ai_provider.dart';
import '../../models/production/media.dart';
import '../../models/transcription/catalog.dart';
import '../../models/transcription/result.dart';
import '../../utils/storage_paths.dart';
import '../ai/transcription/client.dart';
import '../ai/files/session_files.dart';
import '../ai/files/command_paths.dart';
import '../object_storage/service.dart';
import 'canvas_service.dart';
import 'ffmpeg_runner.dart';
import 'library_service.dart';
import 'media_service.dart';
import '../storyboard/service.dart';

final _log = AppLogger.forModule('Transcription');
typedef TranscriptionSelection = ({
  AiProvider provider,
  TranscriptionModel model,
});
typedef TranscriptionOutput = ({
  String taskId,
  String path,
  String? nodeId,
  int segmentCount,
});

class TranscriptionService {
  TranscriptionService({
    required this.database,
    required this.library,
    required this.storage,
    required this.canvasForWork,
    required this.defaultAsrModelId,
    this.pollDelay = const Duration(seconds: 2),
    this.createClient,
  });

  final AppDatabase database;
  final MediaLibraryService library;
  final ObjectStorageService storage;
  final Future<ProductionCanvasService> Function(String) canvasForWork;
  final Future<String?> Function() defaultAsrModelId;
  final Duration pollDelay;
  final http.Client Function(AiProvider)? createClient;
  final _recoveryCancellation = AgentCancellationController();

  void dispose() => _recoveryCancellation.cancel();

  Future<TranscriptionSelection> selection({
    String? providerId,
    String? modelId,
  }) async {
    if (providerId == null && modelId == null) {
      final selected = await defaultAsrModelId();
      final delimiter = selected?.indexOf('::') ?? -1;
      if (selected != null && delimiter > 0) {
        providerId = selected.substring(0, delimiter);
        modelId = selected.substring(delimiter + 2);
      }
    }
    final provider = providerId == null
        ? null
        : await database.aiProviderDao.getById(providerId);
    final model = provider == null || modelId == null
        ? null
        : lookupAsrModel(provider.type, modelId);
    if (provider == null ||
        !provider.enabled ||
        model == null ||
        !provider.availableAsrModels.contains(model.id)) {
      throw const TranscriptionException(
        'transcription_model_required',
        'Configure an enabled default transcription model in AI provider settings.',
      );
    }
    if (!provider.hasApiKey) {
      throw const TranscriptionException('authentication');
    }
    return (provider: provider, model: model);
  }

  static String _fingerprint(AiProvider provider) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            provider.type,
            provider.effectiveBaseUrl,
            provider.effectiveApiKey,
          ]),
        ),
      )
      .toString();

  Future<TranscriptionOutput> run({
    required ProductionCanvasService canvas,
    required String assetId,
    required TranscriptionSelection selection,
    required AgentCancellationToken cancellation,
    String? nodeId,
    void Function(String)? onTask,
  }) async {
    final mediaCancellation = MediaCancellation();
    final unlink = cancellation.onCancel(
      () => unawaited(mediaCancellation.cancel()),
    );
    EncodedMedia? prepared;
    String? id;
    try {
      _checkCancelled(cancellation);
      final asset = await canvas.requireAsset(assetId);
      if (!{'audio', 'video'}.contains(asset.type)) {
        throw const TranscriptionException('invalid_media');
      }
      final files = SessionFiles(
        root: library.root.path,
        novelId: canvas.novelId,
      );
      final source = await files.resolve(
        library.relativePath(library.resolve(asset)),
      );
      final sourceInfo = await library.media.probe(
        source.path,
        cancellation: mediaCancellation,
      );
      if (!sourceInfo.hasAudio) {
        throw const TranscriptionException('no_audio');
      }
      final model = selection.model;
      if (model.maxDuration case final limit?
          when sourceInfo.duration > limit) {
        throw const TranscriptionException('audio_too_long');
      }
      var format = p.extension(source.path).replaceFirst('.', '').toLowerCase();
      var file = source;
      // An audio-only copy makes provider timestamps relative to the first
      // decoded sample. The caller restores the media container's time origin.
      if (asset.type == 'video' || !model.formats.contains(format)) {
        prepared = await library.media.prepareTranscriptionAudio(
          source.path,
          cancellation: mediaCancellation,
        );
        file = prepared.file;
        format = 'mp3';
      }
      final length = await file.length();
      if (length <= 0 || length > model.maxBytes) {
        throw const TranscriptionException('invalid_audio_size');
      }
      _checkCancelled(cancellation);

      final provider = selection.provider;
      if (_fingerprint(provider) !=
          _fingerprint(
            await database.aiProviderDao.getById(provider.id) ??
                (throw const TranscriptionException('invalid_config')),
          )) {
        throw const TranscriptionException('invalid_config');
      }
      Uri? sourceUrl;
      if (model.requiresSourceUrl) {
        final config = await storage.load();
        if (!config.isConfigured) {
          throw const TranscriptionException('object_storage_required');
        }
        final digest = await sha256.bind(file.openRead()).first;
        final upload = await storage.upload(
          config,
          forcePresigned: true,
          file: file,
          sha256: digest.toString(),
          mimeType: switch (format) {
            'mp3' => 'audio/mpeg',
            'm4a' => 'audio/mp4',
            _ => 'audio/wav',
          },
          fileSize: length,
          cancellation: cancellation,
        );
        sourceUrl = upload.url;
      }
      _checkCancelled(cancellation);
      final taskId = const Uuid().v4();
      final request = TranscriptionGenerationRequest(
        modelId: model.id,
        assetId: assetId,
        nodeId: nodeId,
        audioOffsetUs: prepared == null ? 0 : sourceInfo.audioOffsetUs,
        channelFingerprint: _fingerprint(provider),
      );
      await database.generationTaskDao.create(
        GenerationTasksCompanion.insert(
          id: taskId,
          kind: GenerationKind.transcription,
          novelId: canvas.novelId,
          sourceType: 'transcription',
          sourceId: nodeId ?? assetId,
          providerId: provider.id,
          providerType: provider.type,
          modelId: model.id,
          status: GenerationTaskStatus.submitting,
          requestJson: request,
        ),
      );
      id = taskId;
      onTask?.call(taskId);
      final abort = Completer<void>();
      final unlinkHttp = cancellation.onCancel(() {
        if (!abort.isCompleted) {
          abort.complete();
        }
      });
      final httpClient = _transport(provider);
      try {
        final receipt = await TranscriptionClient(
          httpClient,
          provider,
          model,
          abort: abort.future,
        ).submit(file, format, sourceUrl: sourceUrl);
        final remoteId = receipt.remoteId;
        if (remoteId != null) {
          await _move(
            taskId,
            GenerationTaskStatus.submitting,
            GenerationTasksCompanion(
              status: const Value(GenerationTaskStatus.running),
              providerTaskId: Value(remoteId),
              submittedAt: Value(DateTime.now()),
            ),
          );
        }
        await _disposeTemporary(prepared);
        prepared = null;
        final transcript =
            receipt.transcript ??
            await _poll(provider, model, remoteId!, cancellation);
        _checkCancelled(cancellation);
        return await _save(
          canvas,
          taskId,
          request,
          transcript.shift(request.audioOffsetUs),
          from: remoteId == null
              ? GenerationTaskStatus.submitting
              : GenerationTaskStatus.running,
        );
      } finally {
        unlinkHttp();
        httpClient.close();
      }
    } catch (error, stack) {
      final failure = await _fail(id, error, stack, cancellation);
      throw failure;
    } finally {
      unlink();
      await _disposeTemporary(prepared);
    }
  }

  Future<void> _disposeTemporary(EncodedMedia? temporary) async {
    try {
      await temporary?.dispose();
    } on FileSystemException catch (error, stack) {
      _log.error(
        'cannot remove temporary transcription audio',
        error: error,
        stackTrace: stack,
      );
    }
  }

  http.Client _transport(AiProvider provider) =>
      createClient?.call(provider) ??
      provider.createProxyClient() ??
      http.Client();

  static void _checkCancelled(AgentCancellationToken token) {
    if (token.isCancellationRequested) {
      throw const TranscriptionException('cancelled');
    }
  }

  Future<Transcript> _poll(
    AiProvider provider,
    TranscriptionModel model,
    String remoteId,
    AgentCancellationToken cancellation,
  ) async {
    final abort = Completer<void>();
    final unlink = cancellation.onCancel(() => abort.complete());
    final deadline = DateTime.now().add(const Duration(hours: 6));
    var failures = 0;
    try {
      while (DateTime.now().isBefore(deadline)) {
        _checkCancelled(cancellation);
        final httpClient = _transport(provider);
        try {
          final transcript = await TranscriptionClient(
            httpClient,
            provider,
            model,
            abort: abort.future,
          ).query(remoteId);
          if (transcript != null) {
            return transcript;
          }
          failures = 0;
        } catch (error) {
          _checkCancelled(cancellation);
          final temporary =
              error is IOException ||
              error is http.ClientException ||
              (error is TranscriptionException &&
                  {'unavailable', 'rate_limited'}.contains(error.code));
          if (!temporary) {
            rethrow;
          }
          if (++failures == 4) {
            throw const TranscriptionException('polling_interrupted');
          }
        } finally {
          httpClient.close();
        }
        await Future.any([Future<void>.delayed(pollDelay), abort.future]);
      }
      throw const TranscriptionException('polling_interrupted');
    } finally {
      unlink();
    }
  }

  Future<void> _move(
    String id,
    GenerationTaskStatus from,
    GenerationTasksCompanion values,
  ) async {
    if (!await database.generationTaskDao.transition(id, {from}, values)) {
      throw const TranscriptionException('invalid_task_state');
    }
  }

  String _resultPath(String novelId, String id) => p.posix.join(
    RevericPaths.fileWorkspaceDirectory(novelId),
    'transcriptions',
    '$id.json',
  );

  Future<TranscriptionOutput> _save(
    ProductionCanvasService canvas,
    String id,
    TranscriptionGenerationRequest request,
    Transcript transcript, {
    required GenerationTaskStatus from,
  }) async {
    final relative = _resultPath(canvas.novelId, id);
    final files = SessionFiles(
      root: library.root.path,
      novelId: canvas.novelId,
    );
    await CommandPaths(files).checkRelative(relative);
    final file = File(library.resolvePath(relative));
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.partial');
    try {
      await temp.writeAsString(jsonEncode(transcript.toJson()), flush: true);
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) {
        await temp.delete();
      }
    }
    await _move(
      id,
      from,
      GenerationTasksCompanion(
        status: const Value(GenerationTaskStatus.saving),
        path: Value(relative),
      ),
    );
    return _deliver(canvas, id, request, relative, transcript);
  }

  Future<TranscriptionOutput> _deliver(
    ProductionCanvasService canvas,
    String id,
    TranscriptionGenerationRequest request,
    String relative,
    Transcript transcript,
  ) async {
    final sourceNodeId = request.nodeId;
    final source = await database.assetDao.getAsset(request.assetId);
    final node = sourceNodeId == null
        ? null
        : await canvas.addTranscription(
            sourceNodeId,
            taskId: id,
            title: source?.name ?? request.assetId,
            content: transcript.toMarkdown(),
          );
    if (!await database.generationTaskDao.completeTranscription(
      id,
      nodeId: node?.id,
      segmentCount: transcript.segments.length,
    )) {
      throw const TranscriptionException('invalid_task_state');
    }
    return (
      taskId: id,
      path: relative,
      nodeId: node?.id,
      segmentCount: transcript.segments.length,
    );
  }

  Future<TranscriptionException> _fail(
    String? id,
    Object error,
    StackTrace stack,
    AgentCancellationToken cancellation,
  ) async {
    _log.error(
      'transcription failed task=${id ?? ""} type=${error.runtimeType}',
      error: error,
      stackTrace: stack,
    );
    final failure = cancellation.isCancellationRequested
        ? const TranscriptionException('cancelled')
        : switch (error) {
            TranscriptionException() => error,
            MediaException() => TranscriptionException(error.reason.name),
            StoryboardException() => TranscriptionException(
              error.code,
              error.detail,
            ),
            FormatException() ||
            TypeError() => const TranscriptionException('invalid_response'),
            IOException() || http.ClientException() =>
              const TranscriptionException('unavailable'),
            _ => const TranscriptionException('transcription_failed'),
          };
    final task = id == null
        ? null
        : await database.generationTaskDao.getById(id);
    if (task == null || task.status.isTerminal) {
      return failure;
    }
    if ((task.status == GenerationTaskStatus.saving &&
            error is! StoryboardException) ||
        (task.status == GenerationTaskStatus.running &&
            cancellation == _recoveryCancellation.token &&
            cancellation.isCancellationRequested)) {
      return failure;
    }
    final unknown =
        task.status == GenerationTaskStatus.submitting &&
        {
          'submission_unknown',
          'unavailable',
          'cancelled',
        }.contains(failure.code);
    final status = unknown
        ? GenerationTaskStatus.submission_unknown
        : failure.code == 'polling_interrupted'
        ? GenerationTaskStatus.running
        : failure.code == 'cancelled'
        ? GenerationTaskStatus.cancelled
        : GenerationTaskStatus.failed;
    await _move(
      task.id,
      task.status,
      GenerationTasksCompanion(
        status: Value(status),
        errorCode: Value(unknown ? 'submission_unknown' : failure.code),
      ),
    );
    return unknown
        ? const TranscriptionException('submission_unknown')
        : failure;
  }

  Future<void> recover() async {
    for (final task in await database.generationTaskDao.recoverable(
      kind: GenerationKind.transcription,
    )) {
      if ({
        GenerationTaskStatus.submitting,
        GenerationTaskStatus.running,
        GenerationTaskStatus.saving,
      }.contains(task.status)) {
        unawaited(_recover(task));
      }
    }
  }

  Future<void> _recover(GenerationTask task) async {
    final cancellation = _recoveryCancellation.token;
    try {
      _checkCancelled(cancellation);
      final relative = _resultPath(task.novelId, task.id);
      final file = File(library.resolvePath(relative));
      final hasResult = await file.exists();
      if (task.status == GenerationTaskStatus.submitting && !hasResult) {
        await _move(
          task.id,
          task.status,
          const GenerationTasksCompanion(
            status: Value(GenerationTaskStatus.submission_unknown),
            errorCode: Value('submission_unknown'),
          ),
        );
        return;
      }
      final request = task.requestJson as TranscriptionGenerationRequest;
      final canvas = await canvasForWork(task.novelId);
      if (hasResult || task.status == GenerationTaskStatus.saving) {
        final files = SessionFiles(
          root: library.root.path,
          novelId: task.novelId,
        );
        final result = await files.resolve(relative);
        final transcript = Transcript.fromJson(
          jsonDecode(await result.readAsString()) as Map<String, dynamic>,
        );
        if (task.status != GenerationTaskStatus.saving) {
          await _move(
            task.id,
            task.status,
            GenerationTasksCompanion(
              status: const Value(GenerationTaskStatus.saving),
              path: Value(relative),
            ),
          );
        }
        await _deliver(canvas, task.id, request, relative, transcript);
        return;
      }
      final provider = await database.aiProviderDao.getById(task.providerId);
      if (provider == null ||
          _fingerprint(provider) != request.channelFingerprint) {
        throw const TranscriptionException('invalid_config');
      }
      final model = lookupAsrModel(provider.type, request.modelId);
      if (model == null || task.providerTaskId == null) {
        throw const TranscriptionException('invalid_task_state');
      }
      final transcript = await _poll(
        provider,
        model,
        task.providerTaskId!,
        cancellation,
      );
      _checkCancelled(cancellation);
      await _save(
        canvas,
        task.id,
        request,
        transcript.shift(request.audioOffsetUs),
        from: task.status,
      );
    } catch (error, stack) {
      try {
        await _fail(task.id, error, stack, cancellation);
      } catch (failure, failureStack) {
        _log.error(
          'transcription recovery failed task=${task.id}',
          error: failure,
          stackTrace: failureStack,
        );
      }
    }
  }
}

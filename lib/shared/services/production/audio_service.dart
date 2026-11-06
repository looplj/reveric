// 职责: 管理音频任务、预测轮询、取消和不重复生成的输出恢复登记。
// 关联文件:
//   lib/shared/database/daos/generation_task_dao.dart
//   lib/shared/services/production/audio_generate_orchestrator.dart
//   lib/shared/services/production/library_service.dart
//   lib/shared/providers/production_audio.dart
//   lib/shared/models/audio/exception.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/error-handling.md
import 'dart:io';
import 'dart:async';
import '../../utils/storage_paths.dart';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'package:collection/collection.dart';
import 'package:easy_localization/easy_localization.dart';
import '../../models/audio/exception.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import '../../database/app_database.dart';
import '../../database/daos/generation_task_dao.dart';
import '../../logger/app_logger.dart';
import '../../models/audio/request.dart';
import '../../models/ai_provider.dart';
import '../../models/audio/channels.dart';
import '../../utils/short_entity_id.dart';
import '../../utils/random_id.dart';
import '../../utils/short_entity_id_allocator.dart';
import 'library_service.dart';
import '../../models/production/asset_content.dart';
import '../storyboard/service.dart';
import 'audio_generate_orchestrator.dart';

final _log = AppLogger.forModule('AudioTasks');

class AudioTaskService {
  AudioTaskService({
    required this.database,
    required this.library,
    required this.invoke,
    required this.download,
    required this.beforeCreate,
    required this.beforeSubmit,
    required this.recoverSources,
    this.query,
    this.pollInterval = const Duration(seconds: 2),
  });
  final AppDatabase database;
  final MediaLibraryService library;
  final ProductionAudioInvoke invoke;
  final ProductionAudioQuery? query;
  final Duration pollInterval;
  final Future<Uint8List> Function(AiProvider provider, Uri url) download;
  final _outputs = <String, AudioGenerationResult>{};
  final Future<void> Function(String novelId, String type, String id)
  beforeCreate;
  final Future<void> Function(GenerationTask task) beforeSubmit;
  final Future<void> Function() recoverSources;
  final _active = <String, ProductionAudioGenerateOrchestrator>{};
  final _pending = <Future<Object?>>{};
  final _saving = <String, Future<void>>{};
  Future<void>? _recovery;
  bool _disposed = false;

  Stream<List<GenerationTask>> watchSource({
    required String novelId,
    required String sourceType,
    required String sourceId,
  }) => database.generationTaskDao.watchSource(
    novelId: novelId,
    sourceType: sourceType,
    sourceId: sourceId,
  );

  Future<GenerationTask> requireRun(String id) async {
    final task = await database.generationTaskDao.getById(id);
    if (task == null || task.kind != GenerationKind.audio) {
      throw const StoryboardException('source_missing');
    }
    return task;
  }

  Future<void> recover() => _recovery ??= _recover().catchError((Object error) {
    _recovery = null;
    throw error;
  });

  Future<void> _recover() async {
    final rows = await database.generationTaskDao.recoverable(
      kind: GenerationKind.audio,
    );
    for (final row in rows) {
      if (_disposed) {
        return;
      }
      if (row.providerTaskId != null &&
          row.outputUrl == null &&
          {
            GenerationTaskStatus.running,
            GenerationTaskStatus.action_required,
          }.contains(row.status)) {
        unawaited(_track(_resumePrediction(row)));
        continue;
      }
      if ({
        GenerationTaskStatus.prepared,
        GenerationTaskStatus.running,
      }.contains(row.status)) {
        await database.generationTaskDao.transition(
          row.id,
          {row.status},
          GenerationTasksCompanion(
            status: const Value(GenerationTaskStatus.failed),
            errorCode: const Value('interrupted'),
          ),
        );
      } else if ({
        GenerationTaskStatus.saving,
        GenerationTaskStatus.action_required,
      }.contains(row.status)) {
        try {
          await saveOutput(row.id);
        } catch (error, stack) {
          await recordFailure(row.id, error, stack);
        }
      }
    }
    if (!_disposed) {
      await recoverSources();
    }
  }

  Future<void> _resumePrediction(GenerationTask task) async {
    if (_disposed || _active.containsKey(task.id)) {
      return;
    }
    final operation = ProductionAudioGenerateOrchestrator();
    _active[task.id] = operation;
    try {
      final provider = await database.aiProviderDao.getById(task.providerId);
      if (provider == null ||
          provider.type != task.providerType ||
          !provider.enabled) {
        throw const AudioException('invalid_config');
      }
      if (!await database.generationTaskDao.transition(
            task.id,
            {
              GenerationTaskStatus.running,
              GenerationTaskStatus.action_required,
            },
            const GenerationTasksCompanion(
              status: Value(GenerationTaskStatus.running),
              errorCode: Value(null),
              errorMessage: Value(null),
              errorDetail: Value(null),
            ),
          ) ||
          _disposed ||
          operation.cancelled) {
        return;
      }
      await operation.poll(this, task.id, provider, task.providerTaskId!);
    } catch (error, stack) {
      await recordFailure(task.id, error, stack);
    } finally {
      operation.cancel();
      _active.remove(task.id);
    }
  }

  Future<void> recordPrediction(String id, String predictionId) async {
    if (_disposed) {
      return;
    }
    await database.generationTaskDao.transition(id, {
      GenerationTaskStatus.running,
    }, GenerationTasksCompanion(providerTaskId: Value(predictionId)));
  }

  Future<String> submit({
    required String novelId,
    required String sourceType,
    required String sourceId,
    required AudioRequest request,
    String? taskId,
    Future<void> Function(String)? onPrepared,
  }) {
    _requireActive();
    final future = _submit(
      novelId,
      sourceType,
      sourceId,
      request,
      taskId,
      onPrepared,
    );
    return _track(future);
  }

  Future<String> _submit(
    String novelId,
    String sourceType,
    String sourceId,
    AudioRequest request,
    String? taskId,
    Future<void> Function(String)? onPrepared,
  ) async {
    await recover();
    _requireActive();
    if (taskId != null) {
      final existing = await database.generationTaskDao.getById(taskId);
      if (existing != null) {
        if (existing.novelId != novelId ||
            existing.sourceType != sourceType ||
            existing.sourceId != sourceId ||
            !const DeepCollectionEquality().equals(
              existing.requestJson.toJson(),
              AudioGenerationRequest(request).toJson(),
            )) {
          throw const StoryboardException('request_conflict');
        }
        await onPrepared?.call(taskId);
        return taskId;
      }
    }
    await beforeCreate(novelId, sourceType, sourceId);
    final provider = await database.aiProviderDao.getById(request.providerId);
    if (provider == null) {
      throw const StoryboardException('invalid_config');
    }
    if (!AudioCapabilities(request.modelId).supportsProvider(provider) ||
        !provider.enabled ||
        !provider.availableAudioModels.contains(request.modelId)) {
      throw const StoryboardException('invalid_config');
    }
    request = resolveAudioRequest(provider.type, request);
    _requireActive();
    GenerationTasksCompanion row(String id) => GenerationTasksCompanion.insert(
      id: id,
      kind: GenerationKind.audio,
      novelId: novelId,
      sourceType: sourceType,
      sourceId: sourceId,
      providerId: provider.id,
      providerType: provider.type,
      modelId: request.modelId,
      requestJson: AudioGenerationRequest(request),
      status: GenerationTaskStatus.prepared,
    );
    final id =
        taskId ??
        await insertWithShortEntityId(
          type: ShortEntityIdType.generationTask,
          tableName: 'generation_tasks',
          idExists: database.generationTaskDao.idExists,
          insert: (id) => database.generationTaskDao.create(row(id)),
        );
    if (taskId != null) {
      await database.generationTaskDao.create(row(taskId));
    }
    final operation = ProductionAudioGenerateOrchestrator();
    _active[id] = operation;
    try {
      await onPrepared?.call(id);
      _requireActive();
      final prepared = await requireRun(id);
      if (prepared.cancelRequestedAt != null ||
          prepared.status == GenerationTaskStatus.cancelled) {
        await database.generationTaskDao.transition(
          id,
          {GenerationTaskStatus.prepared},
          const GenerationTasksCompanion(
            status: Value(GenerationTaskStatus.cancelled),
          ),
        );
        return id;
      }
      await beforeSubmit(prepared);
      _requireActive();
      final started = await database.generationTaskDao.transition(
        id,
        {GenerationTaskStatus.prepared},
        GenerationTasksCompanion(
          status: const Value(GenerationTaskStatus.running),
          submittedAt: Value(DateTime.now()),
        ),
      );
      if (started && !_disposed) {
        await operation.run(this, id, request, provider);
      }
      return id;
    } catch (error, stack) {
      await recordFailure(id, error, stack);
      rethrow;
    } finally {
      _active.remove(id);
    }
  }

  Future<T> _track<T>(Future<T> future) {
    _pending.add(future);
    return future.whenComplete(() {
      _pending.remove(future);
    });
  }

  Future<void> cancel(String id) {
    _requireActive();
    return _track(_cancel(id));
  }

  Future<void> _cancel(String id) async {
    final cancelled = await database.transaction(() async {
      final task = await requireRun(id);
      if (!GenerationTaskDao.canRequestCancellation(task)) {
        return false;
      }
      return database.generationTaskDao.transition(
        id,
        {task.status},
        const GenerationTasksCompanion(
          status: Value(GenerationTaskStatus.cancelled),
        ),
      );
    });
    if (cancelled) {
      _active[id]?.cancel();
      _outputs.remove(id);
    }
  }

  Future<void> recordOutput(String id, AudioGenerationResult result) async {
    if (_disposed) {
      return;
    }
    if (result.bytes.isNotEmpty) {
      _outputs[id] = result;
    }
    final saved = await database.generationTaskDao.transition(
      id,
      {GenerationTaskStatus.running},
      GenerationTasksCompanion(
        status: const Value(GenerationTaskStatus.saving),
        providerTaskId: result.providerTaskId == null
            ? const Value.absent()
            : Value(result.providerTaskId),
        outputUrl: Value(result.url?.toString()),
        outputHash: Value(
          result.bytes.isEmpty ? null : sha256.convert(result.bytes).toString(),
        ),
      ),
    );
    if (!saved) {
      _outputs.remove(id);
    }
  }

  Future<void> retrySaveOutput(String id) {
    _requireActive();
    return _track(_retrySaveOutput(id));
  }

  Future<void> _retrySaveOutput(String id) async {
    final task = await requireRun(id);
    if (task.status != GenerationTaskStatus.action_required) {
      return;
    }
    final latest = await database.generationTaskDao
        .watchSource(
          novelId: task.novelId,
          sourceType: task.sourceType,
          sourceId: task.sourceId,
        )
        .first;
    if (latest.firstOrNull?.id == id) {
      await beforeSubmit(task);
    }
    if (task.providerTaskId != null && task.outputUrl == null) {
      await _resumePrediction(task);
      return;
    }
    try {
      await saveOutput(id);
    } catch (error, stack) {
      await recordFailure(id, error, stack);
      rethrow;
    }
  }

  Future<void> saveOutput(String id) {
    _requireActive();
    return _saving[id] ??= _saveOutput(id).whenComplete(() {
      _saving.remove(id);
    });
  }

  Future<Uint8List> _downloadOutput(GenerationTask task) async {
    final provider = await database.aiProviderDao.getById(task.providerId);
    if (provider == null || provider.type != task.providerType) {
      throw const AudioException('invalid_config');
    }
    return download(provider, Uri.parse(task.outputUrl!));
  }

  Future<void> _saveOutput(String id) async {
    final task = await requireRun(id);
    if (!{
      GenerationTaskStatus.saving,
      GenerationTaskStatus.action_required,
    }.contains(task.status)) {
      return;
    }
    // A receipt reserves no local artifact: backups only require paths published
    // after a complete write. The deterministic destination also supports restart.
    final channel = lookupAudioChannelModel(task.providerType, task.modelId);
    if (channel == null) {
      throw const AudioException('invalid_config');
    }
    final model = channel.capabilities;
    final outputFormat = audioOutputFileFormat(
      task.path == null
          ? task.audioRequest.parameters.responseFormat
          : task.path!.split('.').last,
      mimeType: _outputs[id]?.mimeType,
    );
    final outputPath = RevericPaths.mediaPath(
      task.novelId,
      'audio',
      '$id.$outputFormat',
    );
    final path = task.path ?? outputPath;
    final file = File(library.resolvePath(path));
    final intact = await file.exists() && await file.length() > 0;
    if (!intact) {
      // Only the output allocated for this task may be rewritten on recovery.
      if (path != outputPath) {
        throw const StoryboardException('invalid_result');
      }
      final bytes =
          _outputs[id]?.bytes ??
          (task.outputUrl == null
              ? throw const AudioException('audio_output_unavailable')
              : await _downloadOutput(task));
      if (_disposed ||
          (await requireRun(id)).status == GenerationTaskStatus.cancelled) {
        return;
      }
      await file.parent.create(recursive: true);
      final partial = File('${file.path}.part');

      try {
        await partial.writeAsBytes(bytes, flush: true);

        await partial.rename(file.path);
      } finally {
        if (await partial.exists()) {
          await partial.delete();
        }
      }
    }
    if (_disposed) {
      return;
    }
    // Cancellation during a write leaves the destination unreferenced. Once this
    // transition succeeds, path always names a complete file.
    if (!await database.generationTaskDao.transition(id, {
      GenerationTaskStatus.saving,
      GenerationTaskStatus.action_required,
    }, GenerationTasksCompanion(path: Value(path)))) {
      return;
    }
    _outputs.remove(id);
    final info = await library.media.probe(file.path);
    if (!info.hasAudio ||
        info.hasVideo ||
        info.formatName != outputFormat ||
        info.duration <= Duration.zero ||
        (model.maxOutputDurationMs != null &&
            info.duration.inMilliseconds > model.maxOutputDurationMs!)) {
      throw const StoryboardException('invalid_result');
    }
    if (_disposed) {
      return;
    }
    await database.generationTaskDao.registerResult(
      id,
      AssetsCompanion.insert(
        id: buildRandomId('ast'),
        type: 'audio',
        purpose: AssetPurpose.production_generated.value,
        name: Value(id),
        novelId: Value(task.novelId),
        source: const Value('generated'),
        path: Value(path),
        sha256: Value((await sha256.bind(file.openRead()).first).toString()),
        content: Value(
          AudioAssetContent(
            mimeType: outputFormat == 'mp3' ? 'audio/mpeg' : 'audio/wav',
            bytes: await file.length(),
            durationMs: info.duration.inMilliseconds,
            generation: AssetGeneration(
              prompt: task.audioRequest.prompt,
              model: task.modelId,
            ),
          ),
        ),
      ),
    );
    if (!_disposed) {
      await recoverSources();
    }
  }

  Future<void> recordFailure(String id, Object error, StackTrace stack) async {
    if (_disposed) {
      return;
    }
    final task = await requireRun(id);
    if (task.status.isTerminal) {
      return;
    }
    final code = switch (error) {
      AudioException(:final code) || StoryboardException(:final code) => code,
      _ => null,
    };
    if (code != null) {
      _log.warning('run failed id=$id type=${error.runtimeType} code=$code');
    } else {
      _log.error('run failed id=$id', error: error, stackTrace: stack);
    }
    final hasOutput = task.outputHash != null || task.outputUrl != null;
    final canResumePrediction =
        task.providerTaskId != null && !hasOutput && code != 'rejected';
    await database.generationTaskDao.transition(
      id,
      {task.status},
      GenerationTasksCompanion(
        status: Value(
          hasOutput || canResumePrediction
              ? GenerationTaskStatus.action_required
              : GenerationTaskStatus.failed,
        ),
        errorMessage: Value(
          !hasOutput && error is AudioException
              ? error.providerMessage ??
                    (error.messageKey == null ? null : tr(error.messageKey!))
              : null,
        ),
        errorDetail: Value(
          !hasOutput && error is AudioException ? error.detail : null,
        ),
        errorCode: Value(
          !hasOutput
              ? code ?? 'audio_submission_unknown'
              : code == 'audio_output_unavailable'
              ? code
              : 'result_save_failed',
        ),
      ),
    );
  }

  void _requireActive() {
    if (_disposed) {
      throw StateError('Audio task service disposed');
    }
  }

  void dispose() {
    _disposed = true;
    _outputs.clear();
    for (final operation in _active.values) {
      operation.cancel();
    }
  }

  Future<void> shutdown() async {
    dispose();
    await Future.wait([
      ?_recovery,
      ..._pending.map((future) => future.then<void>((_) {})),
      ..._saving.values,
    ]);
  }
}

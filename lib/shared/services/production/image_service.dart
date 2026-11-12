// 职责: 在全局数据库管理图片任务执行、取消与已落盘输出的恢复登记。
// 关联文件:
//   lib/shared/database/daos/generation_task_dao.dart
//   lib/shared/services/production/image_generate_orchestrator.dart
//   lib/shared/services/image_library_service.dart
//   lib/shared/providers/production_images.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/error-handling.md
import 'dart:io';
import 'package:easy_localization/easy_localization.dart';
import '../../localization/locale_keys.dart';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import '../../database/app_database.dart';
import '../../logger/app_logger.dart';
import '../../models/production/image_request.dart';
import '../../utils/short_entity_id.dart';
import '../../utils/short_entity_id_allocator.dart';
import '../../utils/storage_paths.dart';
import '../ai/image.dart';
import '../ai/media_diagnostics.dart';
import '../image_library_service.dart';
import '../storyboard/service.dart';
import 'image_generate_orchestrator.dart';

final _log = AppLogger.forModule('ImageTasks');

class ImageTaskService {
  ImageTaskService({
    required this.database,
    required this.images,
    required this.invoke,
    required this.beforeCreate,
    required this.beforeSubmit,
    required this.recoverSources,
    this.sourceName,
    this.fetchResult = _fetchResult,
  });
  final AppDatabase database;
  final ImageLibraryService images;
  final ProductionImageInvoke invoke;
  final Future<void> Function(String novelId, String type, String id)
  beforeCreate;
  final Future<void> Function(GenerationTask task) beforeSubmit;
  final Future<void> Function() recoverSources;

  /// 结果入库时的资产名（不含扩展名）；为 null 或返回 null 时用文件名。
  final Future<String?> Function(GenerationTask task)? sourceName;

  /// 取回上游已受理但未落地的结果：有输出地址时重新下载，否则按上游任务 ID 查询。
  final Future<AiImageGenerationResult> Function(
    AiProvider provider,
    GenerationTask task,
  )
  fetchResult;
  final _active = <String, ProductionImageGenerateOrchestrator>{};
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
    if (task == null || task.kind != GenerationKind.image) {
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
      kind: GenerationKind.image,
    );
    for (final row in rows) {
      if (_disposed) {
        return;
      }
      if (row.status == GenerationTaskStatus.running &&
          (row.providerTaskId != null || row.imageOutputs != null)) {
        // 上游已受理：保留任务 ID，由作者重新获取结果，不阻塞恢复。
        await database.generationTaskDao.transition(
          row.id,
          {row.status},
          const GenerationTasksCompanion(
            status: Value(GenerationTaskStatus.action_required),
            errorCode: Value('result_fetch_failed'),
          ),
        );
      } else if ({
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
          }.contains(row.status) &&
          !_refetchable(row)) {
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

  Future<String> submit({
    required String novelId,
    required String sourceType,
    required String sourceId,
    required ProductionImageRequest request,
    String? taskId,
    Future<void> Function(String)? onPrepared,
    void Function(String diagnostic, String? code)? onFailure,
  }) {
    _requireActive();
    final future = _submit(
      novelId,
      sourceType,
      sourceId,
      request,
      taskId,
      onPrepared,
      onFailure,
    );
    return _track(future);
  }

  Future<String> _submit(
    String novelId,
    String sourceType,
    String sourceId,
    ProductionImageRequest request,
    String? taskId,
    Future<void> Function(String)? onPrepared,
    void Function(String diagnostic, String? code)? onFailure,
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
              ImageGenerationRequest(request).toJson(),
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
    ProductionImageCapabilities(provider, request.modelId).validate(
      prompt: request.prompt,
      ratio: request.ratio,
      resolution: request.resolution,
      references: request.references.length,
    );
    _requireActive();
    GenerationTasksCompanion row(String id) => GenerationTasksCompanion.insert(
      id: id,
      kind: GenerationKind.image,
      novelId: novelId,
      sourceType: sourceType,
      sourceId: sourceId,
      providerId: provider.id,
      providerType: provider.type,
      modelId: request.modelId,
      requestJson: ImageGenerationRequest(request),
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
    void reportFailure(Object error, StackTrace stack) {
      final diagnostic = error is AiImageGenerationException
          ? error.debugMessage ?? error.userMessage
          : error;
      final code = error is AiImageGenerationException
          ? error.code?.name
          : error is StoryboardException
          ? error.code
          : null;
      onFailure?.call(safeMediaDiagnostic(diagnostic, provider.apiKey), code);
    }

    final operation = ProductionImageGenerateOrchestrator();
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
        await operation.run(
          this,
          id,
          request,
          provider,
          onFailure: reportFailure,
        );
      }
      return id;
    } catch (error, stack) {
      reportFailure(error, stack);
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
    await requireRun(id);
    _active[id]?.cancel();
    await database.generationTaskDao.transition(
      id,
      {
        GenerationTaskStatus.prepared,
        GenerationTaskStatus.running,
        GenerationTaskStatus.saving,
        GenerationTaskStatus.action_required,
      },
      const GenerationTasksCompanion(
        status: Value(GenerationTaskStatus.cancelled),
      ),
    );
  }

  /// 上游受理后立即落库任务 ID，崩溃或重启后仍可按它取回结果。
  Future<void> recordSubmission(String id, String providerTaskId) async {
    await database.generationTaskDao.transition(id, {
      GenerationTaskStatus.running,
    }, GenerationTasksCompanion(providerTaskId: Value(providerTaskId)));
  }

  Future<void> recordRemoteOutputs(String id, List<String> urls) async {
    await database.generationTaskDao.transition(
      id,
      {GenerationTaskStatus.running},
      GenerationTasksCompanion(
        imageOutputs: Value(
          ImageTaskOutputs(urls.map((url) => ImageTaskOutput(url: url))),
        ),
      ),
    );
  }

  Future<void> recordResult(String id, AiImageGenerationResult result) async {
    try {
      await _recordResult(id, result);
    } catch (error) {
      final task = await requireRun(id);
      if (result.additionalImages.isNotEmpty && task.providerTaskId != null) {
        throw AiImageFetchException(
          tr(LocaleKeys.aiImageCandidatesFetchFailed),
          providerTaskId: task.providerTaskId,
          debugMessage: 'Candidate staging failed: $error',
        );
      }
      rethrow;
    }
  }

  Future<void> _recordResult(String id, AiImageGenerationResult result) async {
    if (result.additionalImages.isEmpty) {
      final path = result.localFilePath;
      if (path == null || !await File(path).exists()) {
        throw const StoryboardException('invalid_result');
      }
      await recordOutput(
        id,
        path,
        (await sha256.bind(File(path).openRead()).first).toString(),
      );
      return;
    }
    final task = await requireRun(id);
    if (task.status.isTerminal || _disposed) {
      return;
    }
    final outputs = <ImageTaskOutput>[];
    for (final (index, image) in result.images.indexed) {
      final path = image.localFilePath;
      if (path == null || !await File(path).exists()) {
        throw const StoryboardException('invalid_result');
      }
      final hash = (await sha256.bind(File(path).openRead()).first).toString();
      final relative = RevericPaths.mediaPath(
        task.novelId,
        'image',
        '$id-$index.${image.mimeSubtype}',
      );
      final target = File(p.join(RevericPaths.fileWorkspaceParent, relative));
      await target.parent.create(recursive: true);
      if (await target.exists()) {
        if ((await sha256.bind(target.openRead()).first).toString() != hash) {
          throw const StoryboardException('invalid_result');
        }
      } else {
        // Keep the client's temporary file until every candidate is staged.
        final staged = File('${target.path}.part');
        try {
          await File(path).openRead().pipe(staged.openWrite());
          await staged.rename(target.path);
        } finally {
          if (await staged.exists()) {
            await staged.delete();
          }
        }
      }
      outputs.add(ImageTaskOutput(path: relative, hash: hash));
    }
    await database.generationTaskDao.transition(
      id,
      {GenerationTaskStatus.running, GenerationTaskStatus.action_required},
      GenerationTasksCompanion(
        status: const Value(GenerationTaskStatus.saving),
        path: Value(outputs.first.path),
        outputHash: Value(outputs.first.hash),
        imageOutputs: Value(ImageTaskOutputs(outputs)),
      ),
    );
  }

  Future<void> recordOutput(String id, String path, String hash) async {
    if (_disposed) {
      return;
    }
    final task = await requireRun(id);
    final root = Directory(RevericPaths.fileWorkspaceParent);
    final imagePart = RevericPaths.isImageResultPart(root, path);
    final extension = p.extension(imagePart ? p.withoutExtension(path) : path);
    final relative = RevericPaths.mediaPath(
      task.novelId,
      'image',
      '$id$extension',
    );
    final target = File(p.join(RevericPaths.fileWorkspaceParent, relative));
    await target.parent.create(recursive: true);
    if (await target.exists()) {
      if ((await sha256.bind(target.openRead()).first).toString() != hash) {
        throw const StoryboardException('invalid_result');
      }
    } else {
      await target.create(exclusive: true);
      if (imagePart) {
        await File(path).rename(target.path);
      } else {
        await File(path).openRead().pipe(target.openWrite());
      }
    }
    await database.generationTaskDao.transition(
      id,
      {GenerationTaskStatus.running, GenerationTaskStatus.action_required},
      GenerationTasksCompanion(
        status: const Value(GenerationTaskStatus.saving),
        path: Value(relative),
        outputHash: Value(hash),
      ),
    );
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
    if (!_refetchable(task)) {
      await saveOutput(id);
      return;
    }
    try {
      await _refetch(task);
      await saveOutput(id);
    } catch (error, stack) {
      await recordFailure(id, error, stack);
      rethrow;
    }
  }

  /// 上游已受理、结果没取回的任务可以重新获取，不重新计费出图。
  static bool _refetchable(GenerationTask task) => task.imageOutputs != null
      ? task.imageOutputs!.items.any(
          (item) => item.path == null && item.assetId == null,
        )
      : task.path == null &&
            (task.outputUrl != null || task.providerTaskId != null);

  Future<void> _refetch(GenerationTask task) async {
    final provider = await database.aiProviderDao.getById(task.providerId);
    if (provider == null) {
      throw const StoryboardException('invalid_result');
    }
    final result = await fetchResult(provider, task);
    try {
      await recordResult(task.id, result);
    } finally {
      await result.disposeTemporary();
    }
  }

  Future<void> saveOutput(String id) {
    _requireActive();
    return _saving[id] ??= _saveOutput(id).whenComplete(() {
      _saving.remove(id);
    });
  }

  Future<void> _saveOutput(String id) async {
    final task = await requireRun(id);
    if (!{
      GenerationTaskStatus.saving,
      GenerationTaskStatus.action_required,
    }.contains(task.status)) {
      return;
    }
    if (task.imageOutputs != null) {
      final outputs = task.imageOutputs!.items;
      for (final output in outputs) {
        if (output.path == null ||
            output.hash == null ||
            (await sha256
                        .bind(
                          File(
                            RevericPaths.resolveStored(output.path)!,
                          ).openRead(),
                        )
                        .first)
                    .toString() !=
                output.hash) {
          throw const StoryboardException('invalid_result');
        }
      }
      await database.generationTaskDao.completeImageResults(id, () async {
        final assets = <AssetRow>[];
        final title = await sourceName?.call(task);
        for (final (index, output) in outputs.indexed) {
          assets.add(
            await images.importGenerated(
              AiImageGenerationResult(
                localFilePath: RevericPaths.resolveStored(output.path),
              ),
              novelId: task.novelId,
              purpose: AssetPurpose.production_generated,
              name: title == null
                  ? null
                  : '$title-${index + 1}${p.extension(output.path!)}',
              prompt: task.imageRequest.prompt,
              model: task.modelId,
            ),
          );
        }
        return assets;
      });
      if (!_disposed) {
        await recoverSources();
      }
      return;
    }
    if (task.path == null ||
        task.outputHash == null ||
        (await sha256
                    .bind(
                      File(RevericPaths.resolveStored(task.path)!).openRead(),
                    )
                    .first)
                .toString() !=
            task.outputHash) {
      throw const StoryboardException('invalid_result');
    }
    if (_disposed) {
      return;
    }
    final title = await sourceName?.call(task);
    await database.generationTaskDao.completeResult(
      id,
      () => images.importGenerated(
        AiImageGenerationResult(
          localFilePath: RevericPaths.resolveStored(task.path),
        ),
        novelId: task.novelId,
        name: title == null ? null : '$title${p.extension(task.path!)}',
        prompt: task.imageRequest.prompt,
        model: task.modelId,
        purpose: AssetPurpose.production_generated,
      ),
    );
    if (!_disposed) {
      await recoverSources();
    }
  }

  /// 失败仅属于本次 taskId；同 source 的其他任务（包括活动任务）不能被改写。
  /// 无法建立失败记录时向调用方抛错，由批量编排汇总反馈。
  Future<void> recordSubmissionFailure(
    ProductionImagePreview preview,
    String providerType,
    Object error,
    StackTrace stack, {
    required String taskId,
  }) async {
    final existing = await database.generationTaskDao.getById(taskId);
    if (existing != null) {
      if (existing.novelId != preview.novelId ||
          existing.sourceType != preview.sourceType ||
          existing.sourceId != preview.sourceId ||
          !const DeepCollectionEquality().equals(
            existing.requestJson.toJson(),
            ImageGenerationRequest(preview.request).toJson(),
          )) {
        throw const StoryboardException('request_conflict');
      }
      await recordFailure(taskId, error, stack);
      return;
    }
    // DAO 的 source-active 校验仍然适用：拒绝记录也不能破坏另一个活动任务。
    await database.generationTaskDao.create(
      GenerationTasksCompanion.insert(
        id: taskId,
        kind: GenerationKind.image,
        novelId: preview.novelId,
        sourceType: preview.sourceType,
        sourceId: preview.sourceId,
        providerId: preview.request.providerId,
        providerType: providerType,
        modelId: preview.request.modelId,
        requestJson: ImageGenerationRequest(preview.request),
        status: GenerationTaskStatus.failed,
        errorCode: const Value('generation_failed'),
      ),
    );
  }

  Future<void> recordFailure(String id, Object error, StackTrace stack) async {
    _log.error('run failed id=$id', error: error, stackTrace: stack);
    if (_disposed) {
      return;
    }
    final task = await requireRun(id);
    if (task.status.isTerminal) {
      return;
    }
    // 上游已受理只是结果没取回：保留地址或任务 ID，之后重新获取而不必重新生成。
    final fetch = task.path == null && error is AiImageFetchException
        ? error
        : null;
    await database.generationTaskDao.transition(
      id,
      {task.status},
      GenerationTasksCompanion(
        status: Value(
          task.path == null && fetch == null && task.imageOutputs == null
              ? GenerationTaskStatus.failed
              : GenerationTaskStatus.action_required,
        ),
        errorCode: Value(
          task.path != null
              ? 'result_save_failed'
              : fetch?.url != null
              ? 'download_failed'
              : fetch != null || task.imageOutputs != null
              ? 'result_fetch_failed'
              : 'generation_failed',
        ),
        errorMessage: Value(
          task.path == null && error is AiImageGenerationException
              ? error.userMessage
              : null,
        ),
        imageOutputs: fetch != null && fetch.urls.isNotEmpty
            ? Value(
                ImageTaskOutputs(
                  fetch.urls.map((url) => ImageTaskOutput(url: url)),
                ),
              )
            : const Value.absent(),
        outputUrl: Value.absentIfNull(fetch?.url),
        providerTaskId: Value.absentIfNull(fetch?.providerTaskId),
      ),
    );
  }

  void _requireActive() {
    if (_disposed) {
      throw StateError('Image task service disposed');
    }
  }

  void dispose() {
    _disposed = true;
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

Future<AiImageGenerationResult> _fetchResult(
  AiProvider provider,
  GenerationTask task,
) {
  final service = AiImageGenerationService(provider, model: task.modelId);
  if (task.imageOutputs != null &&
      task.imageOutputs!.items.every((item) => item.url != null)) {
    return service.downloadResults(
      task.imageOutputs!.items.map((item) => item.url!).toList(),
    );
  }
  return task.outputUrl != null
      ? service.downloadResult(task.outputUrl!)
      : service.resumeResult(task.providerTaskId!);
}

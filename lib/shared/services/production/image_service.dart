// 职责: 在全局数据库管理图片任务执行、取消与已落盘输出的恢复登记。
// 关联文件:
//   lib/shared/database/daos/generation_task_dao.dart
//   lib/shared/services/production/image_generate_orchestrator.dart
//   lib/shared/services/image_library_service.dart
//   lib/shared/providers/production_images.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/error-handling.md
import '../../models/provider_model.dart';
import '../../agent/agent_tool_dispatcher.dart';
import '../plugins/host.dart';
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
import '../ai/image/output.dart';
import '../ai/image/staging.dart';
import '../../models/generation/provider_result.dart';
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
    this.fetchResult,
    this.pluginHost,
  });
  final PluginHostService? pluginHost;
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
  )?
  fetchResult;
  final _active = <String, ProductionImageGenerateOrchestrator>{};
  final _recovering = <String, AgentCancellationController>{};
  final _pending = <Future<Object?>>{};
  final _saving = <String, Future<void>>{};
  final _retrying = <String, Future<void>>{};
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
    for (var row in rows) {
      if (_disposed) {
        return;
      }
      try {
        final staged = await readImageStaging(
          taskId: row.id,
          providerId: row.providerId,
          providerType: row.providerType,
          existing: row.imageOutputs?.items,
        );
        if (staged.outputs != null) {
          await _stageReceipt(row.id, staged.outputs!);
          row = await requireRun(row.id);
        } else if (staged.hasUnconfirmed &&
            row.imageOutputs == null &&
            row.path == null) {
          await database.generationTaskDao.transition(
            row.id,
            {row.status},
            GenerationTasksCompanion(
              status: const Value(GenerationTaskStatus.action_required),
              errorCode: const Value('unconfirmed_output'),
              errorMessage: Value(tr(LocaleKeys.aiImageStagedUnconfirmed)),
            ),
          );
          continue;
        }
      } catch (error, stack) {
        _log.error(
          'Staged output reconciliation failed task=${row.id}',
          error: error,
          stackTrace: stack,
        );
        await database.generationTaskDao.transition(
          row.id,
          {row.status},
          const GenerationTasksCompanion(
            status: Value(GenerationTaskStatus.action_required),
            errorCode: Value('invalid_staged_output'),
          ),
        );
        continue;
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
        if (existing.requestJson case ImageGenerationRequest(
          request: final persisted,
        )) {
          request = request.withModelSnapshot(
            request.capabilities ?? persisted.capabilities,
            request.requestDefaults ?? persisted.requestDefaults,
          );
        }

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
    final capabilities = ProductionImageCapabilities(
      provider,
      request.modelId,
      capabilities: request.capabilities,
    );
    capabilities.validate(
      prompt: request.prompt,
      ratio: request.ratio,
      resolution: request.resolution,
      references: request.references.length,
    );
    request = request.withModelSnapshot(
      request.capabilities ?? capabilities.effectiveCapabilities,
      request.requestDefaults ??
          resolveImageModel(provider, request.modelId)?.rawDefaults ??
          {},
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
    await database.transaction(() async {
      final task = await requireRun(id);
      final retrievable =
          task.providerTaskId != null ||
          task.imageOutputs != null ||
          task.outputUrl != null ||
          task.path != null;
      await database.generationTaskDao.transition(
        id,
        {
          GenerationTaskStatus.prepared,
          GenerationTaskStatus.running,
          GenerationTaskStatus.saving,
          GenerationTaskStatus.action_required,
        },
        GenerationTasksCompanion(
          status: Value(
            retrievable
                ? GenerationTaskStatus.action_required
                : GenerationTaskStatus.cancelled,
          ),
          cancelRequestedAt: Value(DateTime.now()),
          errorCode: const Value('local_wait_cancelled'),
          errorMessage: Value(tr(LocaleKeys.productionImageWaitCancelled)),
        ),
      );
    });
    _active[id]?.cancel();
    _recovering[id]?.cancel();
  }

  /// Received identity/state and local cancellation have one observable database order.
  Future<void> recordSubmission(String id, ProviderSubmitted submission) async {
    await database.transaction(() async {
      final task = await requireRun(id);
      final stoppedLocally =
          task.status == GenerationTaskStatus.cancelled &&
          task.errorCode == 'local_wait_cancelled';
      await database.generationTaskDao.transition(
        id,
        {
          GenerationTaskStatus.running,
          GenerationTaskStatus.action_required,
          GenerationTaskStatus.cancelled,
        },
        GenerationTasksCompanion(
          providerTaskId: Value(submission.remoteTaskId),
          providerState: Value(submission.state),
          status: stoppedLocally
              ? const Value(GenerationTaskStatus.action_required)
              : const Value.absent(),
        ),
      );
    });
  }

  Future<void> recordRemoteOutputs(
    String id,
    ProviderSucceeded result,
    ImageOutputContext context,
  ) async {
    var task = await requireRun(id);
    if ((task.status.isTerminal &&
            !(task.status == GenerationTaskStatus.cancelled &&
                task.errorCode == 'local_wait_cancelled')) ||
        _disposed) {
      return;
    }
    if (context.inputScope.taskId != id ||
        context.inputScope.providerId != task.providerId) {
      throw const StoryboardException('invalid_result');
    }
    final previous = task.imageOutputs?.items;
    if (previous != null && previous.length != result.outputs.length) {
      throw const StoryboardException('invalid_result');
    }
    final receipt = <ImageTaskOutput>[];
    for (final (index, output) in result.outputs.indexed) {
      final existing = previous == null ? null : previous[index];
      if (existing?.path != null || existing?.assetId != null) {
        receipt.add(existing!);
        continue;
      }
      if (output is ProviderUrlOutput) {
        receipt.add(ImageTaskOutput(url: output.url));
      } else {
        final file = context.outputFile((output as ProviderFileOutput).handle);
        final path =
            RevericPaths.toRelative(file.path) ??
            (throw const StoryboardException('invalid_result'));
        receipt.add(
          ImageTaskOutput(
            path: path,
            hash: (await sha256.bind(file.openRead()).first).toString(),
          ),
        );
      }
    }
    await _stageReceipt(id, receipt);
  }

  Future<void> _stageReceipt(String id, List<ImageTaskOutput> receipt) async {
    var task = await requireRun(id);
    final stoppedLocally =
        task.status == GenerationTaskStatus.cancelled &&
        task.errorCode == 'local_wait_cancelled';
    if ((task.status.isTerminal && !stoppedLocally) || _disposed) {
      return;
    }
    final accepted = await database.generationTaskDao.transition(
      id,
      {task.status},
      GenerationTasksCompanion(
        imageOutputs: Value(ImageTaskOutputs(receipt)),
        status: stoppedLocally
            ? const Value(GenerationTaskStatus.action_required)
            : const Value.absent(),
        outputUrl: const Value(null),
      ),
    );
    if (!accepted) {
      return;
    }
    // The complete receipt exists before any download; local candidates advance independently.
    for (var index = 0; index < receipt.length; index++) {
      final output = receipt[index];
      if (output.path == null || output.assetId != null) {
        continue;
      }
      final source = File(RevericPaths.resolveStored(output.path)!);
      final part = RevericPaths.isImageResultPart(
        Directory(RevericPaths.fileWorkspaceParent),
        source.path,
      );
      final extension = p.extension(
        part ? p.withoutExtension(source.path) : source.path,
      );
      final relative = RevericPaths.mediaPath(
        task.novelId,
        'image',
        '$id-$index$extension',
      );
      final target = File(p.join(RevericPaths.fileWorkspaceParent, relative));
      if (!p.equals(source.path, target.path)) {
        await target.parent.create(recursive: true);
        if (await target.exists()) {
          if ((await sha256.bind(target.openRead()).first).toString() !=
              output.hash) {
            throw const StoryboardException('invalid_result');
          }
        } else {
          final staging = File('${target.path}.part');
          try {
            await source.openRead().pipe(staging.openWrite());
            await staging.rename(target.path);
          } finally {
            if (await staging.exists()) {
              await staging.delete();
            }
          }
        }
        if ((await sha256.bind(target.openRead()).first).toString() !=
            output.hash) {
          throw const StoryboardException('invalid_result');
        }
        receipt[index] = ImageTaskOutput(path: relative, hash: output.hash);
        task = await requireRun(id);
        if (task.status.isTerminal) {
          return;
        }
        await database.generationTaskDao.transition(
          id,
          {task.status},
          GenerationTasksCompanion(
            imageOutputs: Value(ImageTaskOutputs(receipt)),
          ),
        );
      }
    }
    if (receipt.every(
      (output) => output.path != null || output.assetId != null,
    )) {
      await database.generationTaskDao.transition(
        id,
        {
          GenerationTaskStatus.running,
          GenerationTaskStatus.action_required,
          GenerationTaskStatus.saving,
        },
        GenerationTasksCompanion(
          status: Value(
            task.cancelRequestedAt != null &&
                    task.errorCode == 'local_wait_cancelled'
                ? GenerationTaskStatus.action_required
                : GenerationTaskStatus.saving,
          ),
          path: Value(receipt.first.path),
          outputHash: Value(receipt.first.hash),
        ),
      );
    }
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
    final persisted = await requireRun(id);
    if (persisted.status.isTerminal) {
      return;
    }
    if (persisted.imageOutputs?.items.every(
          (item) => item.path != null || item.assetId != null,
        ) ==
        true) {
      return;
    }
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
    return _retrying[id] ??= _track(
      _retrySaveOutput(id).whenComplete(() {
        _retrying.remove(id);
      }),
    );
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
    if (provider.type != task.providerType) {
      throw const StoryboardException('invalid_config');
    }
    final fetch = fetchResult;
    if (fetch != null) {
      final result = await fetch(provider, task);
      try {
        await recordResult(task.id, result);
      } finally {
        await result.disposeTemporary();
      }
      return;
    }
    final service = AiImageGenerationService(
      provider,
      model: task.modelId,
      pluginHost: pluginHost,
    );
    final context = ImageOutputContext(provider, taskId: task.id);
    final cancellation = AgentCancellationController();
    _recovering[task.id] = cancellation;
    Future<void> received(
      ProviderSucceeded result,
      ImageOutputContext context,
    ) async {
      await recordRemoteOutputs(task.id, result, context);
      for (final (index, output) in result.outputs.indexed) {
        if (output is ProviderFileOutput) {
          context.preserve(index, output);
        }
      }
    }

    Future<void> submitted(ProviderSubmitted result) =>
        recordSubmission(task.id, result);
    final outputs = <ProviderOutput>[];
    final stored =
        task.imageOutputs?.items ??
        (task.outputUrl == null
            ? <ImageTaskOutput>[]
            : [ImageTaskOutput(url: task.outputUrl)]);
    try {
      for (final (index, output) in stored.indexed) {
        if (output.url != null) {
          outputs.add(
            ProviderUrlOutput(output.url!),
          );
        } else {
          final asset = output.assetId == null
              ? null
              : await database.assetDao.getAsset(output.assetId!);
          final path = RevericPaths.resolveStored(output.path ?? asset?.path);
          if (path == null) {
            throw const StoryboardException('invalid_result');
          }
          final file = File(path);
          if (output.hash != null &&
              (await sha256.bind(file.openRead()).first).toString() !=
                  output.hash) {
            throw const StoryboardException('invalid_result');
          }
          final recovered = await context.restoreFile(file);
          outputs.add(recovered);
          context.preserve(index, recovered);
        }
      }
      AiImageGenerationResult result;
      if (outputs.isNotEmpty) {
        try {
          result = await service.downloadPrepared(
            ProviderSucceeded(outputs),
            context: context,
            onOutputs: received,
            cancellation: cancellation.token,
          );
        } on AiImageFetchException {
          if (cancellation.token.isCancellationRequested) {
            rethrow;
          }
          if (task.providerTaskId == null) {
            throw AiImageFetchException(
              tr(LocaleKeys.aiImageReferenceUnrefreshable),
              debugMessage: 'output_reference_unrefreshable',
            );
          }
          result = await service.queryPrepared(
            ProviderQueryInput(task.providerTaskId!, state: task.providerState),
            context: context,
            onSubmitted: submitted,
            onOutputs: received,
            cancellation: cancellation.token,
          );
        }
      } else {
        if (task.providerTaskId == null) {
          throw const StoryboardException('invalid_result');
        }
        result = await service.queryPrepared(
          ProviderQueryInput(task.providerTaskId!, state: task.providerState),
          context: context,
          onSubmitted: submitted,
          onOutputs: received,
          cancellation: cancellation.token,
        );
      }
      try {
        await recordResult(task.id, result);
      } finally {
        await result.disposeTemporary();
      }
    } finally {
      _recovering.remove(task.id);
      context.cancel();
      await context.disposeInputs();
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
        if (output.assetId != null) {
          final asset = await database.assetDao.getAsset(output.assetId!);
          if (asset == null || asset.type != 'image') {
            throw const StoryboardException('invalid_result');
          }
          continue;
        }
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
          if (output.assetId != null) {
            assets.add((await database.assetDao.getAsset(output.assetId!))!);
            continue;
          }
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
      await _cleanupRegistered(id);
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
    await _cleanupRegistered(id);
    if (!_disposed) {
      await recoverSources();
    }
  }

  Future<void> _cleanupRegistered(String id) async {
    try {
      final task = await requireRun(id);
      if (task.status != GenerationTaskStatus.completed) {
        return;
      }
      final ids =
          task.imageOutputs?.items
              .map((item) => item.assetId)
              .whereType<String>() ??
          [if (task.resultAssetId != null) task.resultAssetId!];
      final hashes = <String>{};
      for (final assetId in ids) {
        final asset = await database.assetDao.getAsset(assetId);
        if (asset?.sha256 != null) {
          hashes.add(asset!.sha256!);
        }
      }
      await cleanupRegisteredImageStaging(
        taskId: id,
        providerId: task.providerId,
        providerType: task.providerType,
        registeredHashes: hashes,
      );
    } catch (error, stack) {
      _log.error(
        'Registered image temporary cleanup failed task=$id',
        error: error,
        stackTrace: stack,
      );
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
    if (error is AiImageTerminalException) {
      await database.generationTaskDao.transition(
        id,
        {task.status},
        GenerationTasksCompanion(
          status: Value(GenerationTaskStatus.values.byName(error.status)),
          errorCode: Value(error.failureCode ?? error.status),
          errorMessage: Value(error.userMessage),
        ),
      );
      return;
    }
    if (task.errorCode == 'local_wait_cancelled' &&
        task.cancelRequestedAt != null) {
      return;
    }
    final submission = error is AiImageSubmissionException ? error : null;
    // 上游已受理只是结果没取回：保留地址或任务 ID，之后重新获取而不必重新生成。
    final fetch = task.path == null && error is AiImageFetchException
        ? error
        : null;
    await database.generationTaskDao.transition(
      id,
      {task.status},
      GenerationTasksCompanion(
        status: Value(
          submission?.requiresReconciliation != true &&
                  task.path == null &&
                  fetch == null &&
                  task.imageOutputs == null &&
                  task.providerTaskId == null
              ? GenerationTaskStatus.failed
              : GenerationTaskStatus.action_required,
        ),
        errorCode: Value(
          submission?.failureCode ??
              (fetch?.debugMessage == 'output_reference_unrefreshable'
                  ? 'output_reference_unrefreshable'
                  : task.path != null
                  ? 'result_save_failed'
                  : fetch?.url != null
                  ? 'download_failed'
                  : fetch != null ||
                        task.imageOutputs != null ||
                        task.providerTaskId != null
                  ? 'result_fetch_failed'
                  : 'generation_failed'),
        ),
        errorMessage: Value(
          task.path == null && error is AiImageGenerationException
              ? error.userMessage
              : null,
        ),
        imageOutputs:
            task.imageOutputs == null && fetch != null && fetch.urls.isNotEmpty
            ? Value(
                ImageTaskOutputs(
                  fetch.providerOutputs
                          .whereType<ProviderUrlOutput>()
                          .isNotEmpty
                      ? fetch.providerOutputs
                            .whereType<ProviderUrlOutput>()
                            .map((output) => ImageTaskOutput(url: output.url))
                      : fetch.urls.map((url) => ImageTaskOutput(url: url)),
                ),
              )
            : const Value.absent(),
        outputUrl: Value.absentIfNull(fetch?.url),
        providerTaskId: Value.absentIfNull(fetch?.providerTaskId),
        providerState: Value.absentIfNull(fetch?.providerState),
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
    for (final operation in _recovering.values) {
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

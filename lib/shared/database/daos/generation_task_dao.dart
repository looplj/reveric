// 职责: 持久化生成任务、校验草稿关系、隔离来源并原子登记结果资产。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/services/ai/video/task_service.dart
//   lib/shared/models/video/task_result.dart
//   lib/shared/models/generation/task.dart
//   lib/shared/services/production/image_service.dart

import 'package:drift/drift.dart';

import '../../logger/app_logger.dart';
import '../../models/video/task_result.dart';
import '../app_database.dart';

part 'generation_task_dao.drift.dart';

final _log = AppLogger.forModule('GenerationTaskDao');

@DriftAccessor(tables: [GenerationTasks])
class GenerationTaskDao extends DatabaseAccessor<AppDatabase>
    with _$GenerationTaskDaoMixin {
  GenerationTaskDao(super.db);

  Future<GenerationTask?> getById(String id) =>
      (select(generationTasks)..where(
            (t) => t.id.equals(id) & t.deletedAt.equals(notDeletedSentinel),
          ))
          .getSingleOrNull();

  /// 包含软删除行，供短 ID 分配排除全部历史身份。
  Future<bool> idExists(String id) async =>
      await (selectOnly(generationTasks)
            ..addColumns([generationTasks.id])
            ..where(generationTasks.id.equals(id))
            ..limit(1))
          .getSingleOrNull() !=
      null;
  Stream<GenerationTask?> watchTask(String id) =>
      (select(generationTasks)..where(
            (t) => t.id.equals(id) & t.deletedAt.equals(notDeletedSentinel),
          ))
          .watchSingleOrNull();
  Future<List<GenerationTask>> recoverable({required GenerationKind kind}) =>
      (select(generationTasks)..where(
            (t) =>
                t.kind.equalsValue(kind) &
                t.deletedAt.equals(notDeletedSentinel) &
                t.status.isNotInValues({
                  GenerationTaskStatus.completed,
                  GenerationTaskStatus.failed,
                  GenerationTaskStatus.cancelled,
                  GenerationTaskStatus.expired,
                }),
          ))
          .get();

  static bool blocksSource(GenerationTask task) =>
      task.kind != GenerationKind.video
      ? {
          GenerationTaskStatus.prepared,
          GenerationTaskStatus.running,
          GenerationTaskStatus.saving,
        }.contains(task.status)
      : !task.status.isTerminal &&
            task.status != GenerationTaskStatus.submission_unknown &&
            !_neverSubmitted(task);

  /// 卡在提交前的待处理任务上游必然没有作业，新生成不会重复计费；
  /// 判定与 resumeAfterConfigurationFixed 退回 prepared 的条件一致。
  static bool _neverSubmitted(GenerationTask task) =>
      task.status == GenerationTaskStatus.action_required &&
      task.providerTaskId == null &&
      task.submittedAt == null &&
      task.errorCode != 'provider_configuration_changed';

  /// 音视频一旦拿到输出便继续下载和保存，避免丢弃已经生成的结果。
  static bool canRequestCancellation(GenerationTask task) =>
      !task.status.isTerminal &&
      (task.kind == GenerationKind.image ||
          (task.status != GenerationTaskStatus.saving &&
              task.outputUrl == null &&
              task.outputHash == null &&
              task.path == null &&
              task.resultAssetId == null));

  Future<bool> requestCancellation(String id) async {
    try {
      return await transaction(() async {
        final task = await getById(id);
        if (task == null || !canRequestCancellation(task)) {
          return false;
        }
        await (update(
          generationTasks,
        )..where((t) => t.id.equals(id) & t.cancelRequestedAt.isNull())).write(
          GenerationTasksCompanion(
            cancelRequestedAt: Value(DateTime.now()),
            updatedAt: Value(DateTime.now()),
          ),
        );
        return true;
      });
    } catch (error, stack) {
      _log.error(
        '[DB] generation_tasks UPDATE cancellation id=$id',
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  Future<void> create(GenerationTasksCompanion task) async {
    try {
      if (task.status.value == GenerationTaskStatus.completed) {
        throw ArgumentError('Complete tasks through result registration');
      }
      final request = task.requestJson.value;
      if (request.kind != task.kind.value ||
          request.modelId != task.modelId.value ||
          (request is AudioGenerationRequest &&
              request.request.providerId != task.providerId.value) ||
          (request is ImageGenerationRequest &&
              request.request.providerId != task.providerId.value)) {
        throw ArgumentError('Generation request does not match task');
      }
      GenerationRequest.fromJson(request.toJson());
      validateSource(
        task.novelId.value,
        task.sourceType.value,
        task.sourceId.value,
      );
      await transaction(() async {
        await _validateDraft(task);
        await ensureSourceAvailable(
          task.novelId.value,
          task.sourceType.value,
          task.sourceId.value,
        );
        await into(generationTasks).insert(task);
      });
    } catch (error, stack) {
      _log.error(
        '[DB] generation_tasks INSERT id=${task.id.value}',
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  Future<void> _validateDraft(GenerationTasksCompanion task) async {
    final draftTaskId = task.draftTaskId.value;
    if (draftTaskId == null) {
      return;
    }
    if ((task.draft.present && task.draft.value) ||
        draftTaskId == task.id.value) {
      throw ArgumentError('A draft cannot complete another draft or itself');
    }
    final draft = await getById(draftTaskId);
    if (draft == null ||
        !draft.draft ||
        draft.status != GenerationTaskStatus.completed ||
        draft.kind != task.kind.value ||
        draft.novelId != task.novelId.value ||
        draft.sourceType != task.sourceType.value ||
        draft.sourceId != task.sourceId.value ||
        draft.providerId != task.providerId.value ||
        draft.providerType != task.providerType.value ||
        draft.modelId != task.modelId.value) {
      throw ArgumentError(
        'Draft completion must reference a completed draft '
        'with the same source, provider and model',
      );
    }
  }

  Future<void> ensureSourceAvailable(
    String novelId,
    String sourceType,
    String sourceId,
  ) async {
    validateSource(novelId, sourceType, sourceId);
    final rows =
        await (select(generationTasks)..where(
              (t) =>
                  t.novelId.equals(novelId) &
                  t.sourceType.equals(sourceType) &
                  t.sourceId.equals(sourceId) &
                  t.deletedAt.equals(notDeletedSentinel) &
                  t.status.isNotInValues({
                    GenerationTaskStatus.completed,
                    GenerationTaskStatus.failed,
                    GenerationTaskStatus.cancelled,
                    GenerationTaskStatus.expired,
                  }),
            ))
            .get();
    final active = rows.where(blocksSource).firstOrNull;
    if (active != null) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'source_active_task',
      );
    }
  }

  static void validateSource(
    String novelId,
    String sourceType,
    String sourceId,
  ) {
    for (final value in [novelId, sourceType, sourceId]) {
      if (value.trim().isEmpty || value != value.trim()) {
        throw const VideoException(
          VideoErrorCode.invalid_request,
          field: 'task_source',
        );
      }
    }
  }

  Stream<List<GenerationTask>> watchSource({
    required String novelId,
    required String sourceType,
    required String sourceId,
  }) {
    validateSource(novelId, sourceType, sourceId);
    return (select(generationTasks)
          ..where(
            (t) =>
                t.novelId.equals(novelId) &
                t.sourceType.equals(sourceType) &
                t.sourceId.equals(sourceId) &
                t.deletedAt.equals(notDeletedSentinel),
          )
          ..orderBy([
            (t) => OrderingTerm.desc(const CustomExpression<int>('rowid')),
          ]))
        .watch();
  }

  /// 资产登记和任务完成共用事务；失败回滚，取消后的迟到结果不会入库。
  Future<String?> completeResult(
    String id,
    Future<AssetRow> Function() register,
  ) async {
    try {
      return await transaction(() async {
        final task = await getById(id);
        if (task == null || task.status.isTerminal) {
          return task?.resultAssetId;
        }
        if (!{
              GenerationTaskStatus.saving,
              GenerationTaskStatus.action_required,
            }.contains(task.status) ||
            task.path == null) {
          throw StateError('Generation output is not locally complete');
        }
        final asset = await register();
        if (asset.type != task.kind.name ||
            (asset.novelId != null && asset.novelId != task.novelId)) {
          throw ArgumentError('Generation result asset does not match task');
        }
        await (update(generationTasks)..where((t) => t.id.equals(id))).write(
          GenerationTasksCompanion(
            status: const Value(GenerationTaskStatus.completed),
            resultAssetId: Value(asset.id),
            path: Value(asset.path),
            completedAt: Value(DateTime.now()),
            errorCode: const Value(null),
            errorMessage: const Value(null),
            errorDetail: const Value(null),
            nextPollAt: const Value(null),
            updatedAt: Value(DateTime.now()),
          ),
        );
        return asset.id;
      });
    } catch (error, stack) {
      _log.error(
        '[DB] assets INSERT / generation_tasks UPDATE result id=$id',
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  /// 同一次任务的所有候选原子登记；列表保留顺序，即使两个候选复用同一资产。
  Future<String?> completeImageResults(
    String id,
    Future<List<AssetRow>> Function() register,
  ) => completeResult(id, () async {
    final task = (await getById(id))!;
    if (task.kind != GenerationKind.image) {
      throw ArgumentError('Only image tasks have candidates');
    }
    final assets = await register();
    if (assets.isEmpty ||
        assets.length != task.imageOutputs?.items.length ||
        assets.any(
          (asset) =>
              asset.type != 'image' ||
              (asset.novelId != null && asset.novelId != task.novelId),
        )) {
      throw ArgumentError('Candidate assets do not match task');
    }
    await (update(generationTasks)..where((t) => t.id.equals(id))).write(
      GenerationTasksCompanion(
        imageOutputs: Value(
          ImageTaskOutputs(
            assets.map((asset) => ImageTaskOutput(assetId: asset.id)),
          ),
        ),
      ),
    );
    return assets.first;
  });

  Future<String?> registerResult(String id, AssetsCompanion asset) =>
      completeResult(id, () async {
        await attachedDatabase.assetDao.insertAsset(asset);
        return (await attachedDatabase.assetDao.getAsset(asset.id.value))!;
      });

  // Image requests capture their provider at submission; saving their local
  // output needs no credentials. Only recoverable remote video tasks are paused.
  Future<void> pauseForProvider(String providerId) async {
    final tasks =
        await (select(generationTasks)..where(
              (t) =>
                  t.kind.equalsValue(GenerationKind.video) &
                  t.providerId.equals(providerId) &
                  t.deletedAt.equals(notDeletedSentinel) &
                  t.status.isNotInValues({
                    GenerationTaskStatus.completed,
                    GenerationTaskStatus.failed,
                    GenerationTaskStatus.cancelled,
                    GenerationTaskStatus.expired,
                  }),
            ))
            .get();
    for (final task in tasks) {
      await transition(
        task.id,
        {task.status},
        GenerationTasksCompanion(
          status: const Value(GenerationTaskStatus.action_required),
          errorCode: Value(
            {
                  GenerationTaskStatus.prepared,
                  GenerationTaskStatus.uploading,
                }.contains(task.status)
                ? 'provider_configuration_changed_before_submission'
                : 'provider_configuration_changed',
          ),
          errorMessage: const Value(null),
          errorDetail: const Value(null),
          nextPollAt: const Value(null),
        ),
      );
    }
  }

  Future<bool> transition(
    String id,
    Set<GenerationTaskStatus> expected,
    GenerationTasksCompanion values,
  ) async {
    try {
      if (values.id.present ||
          values.kind.present ||
          values.draft.present ||
          values.draftTaskId.present ||
          values.novelId.present ||
          values.sourceType.present ||
          values.sourceId.present ||
          values.providerId.present ||
          values.providerType.present ||
          values.modelId.present ||
          values.requestJson.present) {
        throw ArgumentError('Generation identity and request are immutable');
      }
      if (values.status.present &&
          values.status.value == GenerationTaskStatus.completed) {
        throw ArgumentError('Complete tasks through result registration');
      }
      return await (update(generationTasks)..where(
                (t) =>
                    t.id.equals(id) &
                    t.deletedAt.equals(notDeletedSentinel) &
                    t.status.isInValues(expected),
              ))
              .write(values.copyWith(updatedAt: Value(DateTime.now()))) ==
          1;
    } catch (error, stack) {
      _log.error(
        '[DB] generation_tasks UPDATE id=$id',
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
  }
}

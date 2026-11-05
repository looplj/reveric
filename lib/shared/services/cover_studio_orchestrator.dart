// 职责: 封面生成批次编排 — 管理逐张请求、格子状态、图片入库和不可取消的在途请求。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/services/image_library_service.dart
//   lib/shared/services/ai/image.dart
//   lib/shared/services/ai/tools.dart
//   lib/desktop/features/cover_studio/studio_page.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/error-handling.md

import 'package:drift/drift.dart' show Value;
import 'package:reveric/shared/models/asset_purpose.dart';

import '../database/app_database.dart';
import '../logger/app_logger.dart';
import '../utils/random_id.dart';
import 'ai/image.dart';
import 'ai/tools.dart';
import 'image_library_service.dart';

final _log = AppLogger.forModule('CoverStudioOrchestrator');

class CoverStudioBatchResult {
  const CoverStudioBatchResult({
    required this.batchId,
    required this.assetPaths,
    required this.status,
  });

  final String batchId;
  final List<String> assetPaths;
  final String status;
}

/// 单张重出的结果。失败不抛异常 —— 重出失败只是那一格换了个错误码，
/// 不该让调用方用 try/catch 表达一个正常的业务分支。
class CoverStudioSlotResult {
  const CoverStudioSlotResult({required this.succeeded, this.assetPath});

  final bool succeeded;
  final String? assetPath;
}

class CoverStudioOrchestrator {
  var _stopRequested = false;

  void stop() {
    _stopRequested = true;
  }

  Future<CoverStudioBatchResult> generateBatch({
    required AppDatabase database,
    required ImageLibraryService imageLibrary,
    required AiImageGenerationCallback callback,
    required String novelId,
    required String prompt,
    required int requestedCount,
    required String? model,
    String? size,
    String? quality,
    String? complexity,
    String? paramsJson,
    List<String> references = const [],
    void Function(int completedCount)? onProgress,
  }) async {
    // 编排器可被复用；每个批次从未请求停止状态开始。
    _stopRequested = false;
    final batchId = 'image_batch_${DateTime.now().microsecondsSinceEpoch}';
    await database.imageAssetDao.insertBatch(
      ImageBatchesCompanion.insert(
        id: batchId,
        novelId: Value(novelId),
        status: const Value(imageBatchStatusRunning),
        prompt: prompt,
        paramsJson: Value(paramsJson),
        model: Value(model),
        requestedCount: Value(requestedCount),
      ),
    );
    // 格子先按请求张数占满：胶片条要在第一张画出来之前就有 4 个位置，
    // 失败的那一格也才有地方落错误码。
    await database.imageAssetDao.insertSlots([
      for (var index = 0; index < requestedCount; index++)
        ImageBatchSlotsCompanion.insert(
          id: buildRandomId('image_slot'),
          batchId: batchId,
          ordinal: index,
          status: const Value(imageBatchSlotStatusPending),
        ),
    ]);

    final paths = <String>[];
    var failedCount = 0;
    var stopped = false;
    var abortRemaining = false;
    for (var index = 0; index < requestedCount; index++) {
      if (_stopRequested) {
        stopped = true;
        break;
      }
      // 当前 await 请求不会被取消；完成后仍然写入、计费，再检查 stop。
      final outcome = await _generateOne(
        database: database,
        imageLibrary: imageLibrary,
        callback: callback,
        batchId: batchId,
        ordinal: index,
        novelId: novelId,
        prompt: prompt,
        model: model,
        size: size,
        quality: quality,
        complexity: complexity,
        references: references,
      );
      if (outcome.path == null) {
        // 单张失败不中断整批：其余方案照常出图，作者只需重出这一张。
        // 供应商额度耗尽例外：后续格子必然同样 402，提前停掉避免空跑。
        failedCount++;
        if (outcome.errorCode == AiImageErrorCode.credit) {
          abortRemaining = true;
          break;
        }
      } else {
        paths.add(outcome.path!);
        onProgress?.call(paths.length);
      }
      await database.imageAssetDao.updateBatch(
        id: batchId,
        status: _stopRequested
            ? imageBatchStatusStopping
            : imageBatchStatusRunning,
        completedCount: paths.length,
      );
    }
    if (_stopRequested) {
      stopped = true;
    }

    final status = _resolveBatchStatus(
      succeeded: paths.length,
      failed: failedCount,
      stopped: stopped,
    );
    await database.imageAssetDao.updateBatch(
      id: batchId,
      status: status,
      completedCount: paths.length,
    );
    // 停止或供应商额度耗尽时，后面那些还没发出去的格子永远不会有结果，留着 pending
    // 会让胶片条一直转圈。收敛时一并落成 canceled 语义的空格子。
    if (stopped || abortRemaining) {
      await _cancelPendingSlots(database, batchId);
    }
    return CoverStudioBatchResult(
      batchId: batchId,
      assetPaths: paths,
      status: status,
    );
  }

  /// 单张重出：沿用同批参数，只重跑指定格子。原来那张落到 previousAssetId，
  /// 溯源的「重出自」靠它。
  Future<CoverStudioSlotResult> regenerateSlot({
    required AppDatabase database,
    required ImageLibraryService imageLibrary,
    required AiImageGenerationCallback callback,
    required String batchId,
    required int ordinal,
    required String novelId,
    required String prompt,
    required String? model,
    String? size,
    String? quality,
    String? complexity,
    List<String> references = const [],
  }) async {
    final slots = await database.imageAssetDao.getSlots(batchId);
    final target = slots.where((slot) => slot.ordinal == ordinal).firstOrNull;
    final previousAssetId = target?.assetId;

    await database.imageAssetDao.updateSlot(
      batchId: batchId,
      ordinal: ordinal,
      status: imageBatchSlotStatusPending,
      previousAssetId: previousAssetId,
    );
    final outcome = await _generateOne(
      database: database,
      imageLibrary: imageLibrary,
      callback: callback,
      batchId: batchId,
      ordinal: ordinal,
      novelId: novelId,
      prompt: prompt,
      model: model,
      size: size,
      quality: quality,
      complexity: complexity,
      references: references,
      previousAssetId: previousAssetId,
    );

    // 重出改变了批次的成败构成，状态要跟着重算：全失败的批次重出成功一张后
    // 不能还挂着 failed。
    await _refreshBatchStatus(database, batchId);
    return CoverStudioSlotResult(
      succeeded: outcome.path != null,
      assetPath: outcome.path,
    );
  }

  /// 出一张图并落格子。成功时 [path] 为资产相对路径；失败时错误已写进格子，
  /// [errorCode] 供批次决定是否因供应商额度耗尽提前停掉。
  Future<({String? path, AiImageErrorCode? errorCode})> _generateOne({
    required AppDatabase database,
    required ImageLibraryService imageLibrary,
    required AiImageGenerationCallback callback,
    required String batchId,
    required int ordinal,
    required String novelId,
    required String prompt,
    required String? model,
    required String? size,
    required String? quality,
    required String? complexity,
    required List<String> references,
    String? previousAssetId,
  }) async {
    try {
      final result = await callback(
        prompt,
        size: size,
        model: model,
        quality: quality,
        complexity: complexity,
      );
      final asset = await imageLibrary.importGenerated(
        result,
        novelId: novelId,
        prompt: prompt,
        model: model,
        batchId: batchId,
        purpose: AssetPurpose.cover,
      );
      if (references.isNotEmpty) {
        await database.imageAssetDao.insertReferences(
          references.indexed.map(
            (entry) => ImageAssetReferencesCompanion.insert(
              id: buildRandomId('image_reference'),
              assetId: asset.id,
              batchId: batchId,
              referenceAssetId: Value(entry.$2),
              ordinal: entry.$1,
              purpose: 'cover',
            ),
          ),
        );
      }
      await database.imageAssetDao.updateSlot(
        batchId: batchId,
        ordinal: ordinal,
        status: imageBatchSlotStatusSucceeded,
        assetId: asset.id,
        previousAssetId: previousAssetId,
      );
      return (path: asset.path, errorCode: null);
    } catch (error, stackTrace) {
      final code = error is AiImageGenerationException ? error.code : null;
      if (code != null) {
        // 已分类的业务失败（供应商额度不足、鉴权、限流等）不打堆栈。
        _log.warning(
          'batch=$batchId slot=$ordinal generation failed code=${code.name} '
          'message=$error',
        );
      } else {
        _log.error(
          'batch=$batchId slot=$ordinal generation failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
      await database.imageAssetDao.updateSlot(
        batchId: batchId,
        ordinal: ordinal,
        status: imageBatchSlotStatusFailed,
        previousAssetId: previousAssetId,
        errorCode: code?.name,
        errorMessage: error is AiImageGenerationException
            ? error.userMessage
            : error.toString(),
      );
      return (path: null, errorCode: code);
    }
  }

  Future<void> _cancelPendingSlots(AppDatabase database, String batchId) async {
    final slots = await database.imageAssetDao.getSlots(batchId);
    for (final slot in slots) {
      if (slot.status != imageBatchSlotStatusPending) continue;
      await database.imageAssetDao.updateSlot(
        batchId: batchId,
        ordinal: slot.ordinal,
        status: imageBatchSlotStatusFailed,
        errorCode: coverSlotErrorCanceled,
      );
    }
  }

  Future<void> _refreshBatchStatus(AppDatabase database, String batchId) async {
    final slots = await database.imageAssetDao.getSlots(batchId);
    final succeeded = slots
        .where((slot) => slot.status == imageBatchSlotStatusSucceeded)
        .length;
    final canceled = slots
        .where((slot) => slot.errorCode == coverSlotErrorCanceled)
        .length;
    final failed = slots
        .where(
          (slot) =>
              slot.status == imageBatchSlotStatusFailed &&
              slot.errorCode != coverSlotErrorCanceled,
        )
        .length;
    await database.imageAssetDao.updateBatch(
      id: batchId,
      status: _resolveBatchStatus(
        succeeded: succeeded,
        failed: failed,
        stopped: canceled > 0,
      ),
      completedCount: succeeded,
    );
  }

  String _resolveBatchStatus({
    required int succeeded,
    required int failed,
    required bool stopped,
  }) {
    if (succeeded == 0) {
      // 停止且零产物记成「取消」而不是「失败」：结果是作者自己叫停的，
      // 哪怕已经发出的那张也失败了，主因仍然是取消。
      return stopped ? imageBatchStatusCanceled : imageBatchStatusFailed;
    }
    if (stopped || failed > 0) {
      return imageBatchStatusPartial;
    }
    return imageBatchStatusCompleted;
  }
}

/// 作者叫停导致没发出去的格子。不是模型的错，UI 上与真失败区分显示。
const String coverSlotErrorCanceled = 'canceled';

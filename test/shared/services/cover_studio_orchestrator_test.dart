// 职责: 测试封面批次编排 — 验证停止、格子状态机、单张失败不中断整批与单张重出。
// 关联文件:
//   lib/shared/services/cover_studio_orchestrator.dart
//   lib/shared/services/image_library_service.dart
//   lib/shared/database/app_database.dart

import 'dart:convert';
import 'dart:io';
import 'package:reveric/shared/models/asset_purpose.dart';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/services/ai/image.dart';
import 'package:reveric/shared/services/cover_studio_orchestrator.dart';
import 'package:reveric/shared/services/image_library_service.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory supportDir;
  late AppDatabase database;
  late File source;

  setUp(() async {
    supportDir = await Directory.systemTemp.createTemp('reveric_image_batch_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? supportDir.path
              : null,
        );
    await RevericPaths.initialize();
    database = AppDatabase.forTest(NativeDatabase.memory());
    source = File('${supportDir.path}/source.png')..writeAsBytesSync(_png);
  });

  tearDown(() async {
    await database.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (await supportDir.exists()) await supportDir.delete(recursive: true);
  });

  // 每次调用都换一份字节：ImageLibraryService 按 sha256 去重，四张一模一样的
  // 图会被折成一条资产，格子就验不出来了。
  AiImageGenerationCallbackStub okCallback() => AiImageGenerationCallbackStub();

  Future<List<ImageBatchSlotRow>> slotsOf(String batchId) =>
      database.imageAssetDao.getSlots(batchId);

  test(
    'stop waits for the in-flight request and skips later requests',
    () async {
      final referenceSource = File('${supportDir.path}/reference.png')
        ..writeAsBytesSync(<int>[..._png, 0]);
      final imageLibrary = buildImageLibraryService(database);
      final reference = await imageLibrary.importFile(
        referenceSource.path,
        novelId: 'novel_test',
        purpose: AssetPurpose.reference,
      );
      var calls = 0;
      final orchestrator = CoverStudioOrchestrator();
      final future = orchestrator.generateBatch(
        database: database,
        imageLibrary: imageLibrary,
        callback: (prompt, {model, size, quality, complexity}) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return AiImageGenerationResult(localFilePath: source.path);
        },
        novelId: 'novel_test',
        prompt: 'draw title',
        requestedCount: 4,
        model: 'image-model',
        paramsJson: '{"style":"ink"}',
        references: [reference.id],
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      orchestrator.stop();
      final result = await future;

      expect(calls, 1);
      expect(result.status, imageBatchStatusPartial);
      expect(result.assetPaths, hasLength(1));

      final batches = await database.select(database.imageBatches).get();
      expect(batches.single.paramsJson, '{"style":"ink"}');
      final references = await database
          .select(database.imageAssetReferences)
          .get();
      expect(references.single.referenceAssetId, reference.id);
      expect(references.single.role, 'reference');

      // 4 个格子从一开始就占好；停止后没发出去的三个收敛成 canceled，不留 pending。
      final slots = await slotsOf(result.batchId);
      expect(slots, hasLength(4));
      expect(slots.first.status, imageBatchSlotStatusSucceeded);
      expect(slots.first.assetId, isNotNull);
      expect(
        slots.skip(1).map((slot) => slot.errorCode),
        everyElement(coverSlotErrorCanceled),
      );
    },
  );

  test('stopping with zero products settles the batch as canceled', () async {
    // 在途那一张不可取消，所以「零产物的停止」只可能是：唯一发出去的那张也失败了。
    // 主因仍是作者叫停，收敛成 canceled 而不是 failed。
    final orchestrator = CoverStudioOrchestrator();
    final result = await orchestrator.generateBatch(
      database: database,
      imageLibrary: buildImageLibraryService(database),
      callback: (prompt, {model, size, quality, complexity}) async {
        orchestrator.stop();
        throw const AiImageGenerationException(
          '图片生成请求过于频繁，请稍后再试。',
          code: AiImageErrorCode.rate_limit,
        );
      },
      novelId: 'novel_test',
      prompt: 'draw title',
      requestedCount: 4,
      model: 'image-model',
    );

    expect(result.assetPaths, isEmpty);
    expect(result.status, imageBatchStatusCanceled);
    final slots = await slotsOf(result.batchId);
    expect(slots.first.errorCode, AiImageErrorCode.rate_limit.name);
    expect(
      slots.skip(1).map((slot) => slot.errorCode),
      everyElement(coverSlotErrorCanceled),
    );
  });

  test('one failed image does not abort the rest of the batch', () async {
    final stub = okCallback();
    final result = await CoverStudioOrchestrator().generateBatch(
      database: database,
      imageLibrary: buildImageLibraryService(database),
      callback: (prompt, {model, size, quality, complexity}) async {
        if (stub.calls++ == 1) {
          throw const AiImageGenerationException(
            '提示词或图片内容未通过审核，请调整后重试。',
            code: AiImageErrorCode.moderation,
          );
        }
        return AiImageGenerationResult(
          localFilePath: stub.nextSource(supportDir).path,
        );
      },
      novelId: 'novel_test',
      prompt: 'draw title',
      requestedCount: 4,
      model: 'image-model',
    );

    expect(stub.calls, 4, reason: '第 2 张失败后仍要继续跑完第 3、4 张');
    expect(result.assetPaths, hasLength(3));
    expect(result.status, imageBatchStatusPartial);

    final slots = await slotsOf(result.batchId);
    expect(slots[1].status, imageBatchSlotStatusFailed);
    expect(slots[1].errorCode, AiImageErrorCode.moderation.name);
    expect(slots[1].assetId, isNull);
    expect(slots[0].status, imageBatchSlotStatusSucceeded);
    expect(slots[3].status, imageBatchSlotStatusSucceeded);
  });

  test('a batch where every image fails settles as failed', () async {
    final result = await CoverStudioOrchestrator().generateBatch(
      database: database,
      imageLibrary: buildImageLibraryService(database),
      callback: (prompt, {model, size, quality, complexity}) async =>
          throw const AiImageGenerationException(
            '图片生成请求过于频繁，请稍后再试。',
            code: AiImageErrorCode.rate_limit,
          ),
      novelId: 'novel_test',
      prompt: 'draw title',
      requestedCount: 4,
      model: 'image-model',
    );

    expect(result.assetPaths, isEmpty);
    expect(result.status, imageBatchStatusFailed);
    final slots = await slotsOf(result.batchId);
    expect(
      slots.map((slot) => slot.errorCode),
      everyElement(AiImageErrorCode.rate_limit.name),
    );
  });

  test(
    'provider balance exhaustion aborts remaining slots without marking the batch canceled',
    () async {
      var calls = 0;
      final result = await CoverStudioOrchestrator().generateBatch(
        database: database,
        imageLibrary: buildImageLibraryService(database),
        callback: (prompt, {model, size, quality, complexity}) async {
          calls++;
          throw const AiImageGenerationException(
            'AI 供应商余额不足，请检查供应商账户后重试。',
            code: AiImageErrorCode.credit,
          );
        },
        novelId: 'novel_test',
        prompt: 'draw title',
        requestedCount: 4,
        model: 'image-model',
      );

      expect(calls, 1, reason: '供应商余额不足后不应继续请求后续格子');
      expect(result.assetPaths, isEmpty);
      expect(result.status, imageBatchStatusFailed);
      final slots = await slotsOf(result.batchId);
      expect(slots.first.errorCode, AiImageErrorCode.credit.name);
      expect(
        slots.skip(1).map((slot) => slot.errorCode),
        everyElement(coverSlotErrorCanceled),
      );
    },
  );

  test(
    'regenerating a failed slot records lineage and re-settles the batch',
    () async {
      final stub = okCallback();
      final orchestrator = CoverStudioOrchestrator();
      final imageLibrary = buildImageLibraryService(database);
      final batch = await orchestrator.generateBatch(
        database: database,
        imageLibrary: imageLibrary,
        callback: (prompt, {model, size, quality, complexity}) async {
          if (stub.calls++ == 1) {
            throw const AiImageGenerationException(
              '提示词或图片内容未通过审核，请调整后重试。',
              code: AiImageErrorCode.moderation,
            );
          }
          return AiImageGenerationResult(
            localFilePath: stub.nextSource(supportDir).path,
          );
        },
        novelId: 'novel_test',
        prompt: 'draw title',
        requestedCount: 4,
        model: 'image-model',
      );
      expect(batch.status, imageBatchStatusPartial);

      final reworked = await orchestrator.regenerateSlot(
        database: database,
        imageLibrary: imageLibrary,
        callback: (prompt, {model, size, quality, complexity}) async =>
            AiImageGenerationResult(
              localFilePath: stub.nextSource(supportDir).path,
            ),
        batchId: batch.batchId,
        ordinal: 1,
        novelId: 'novel_test',
        prompt: 'draw title again',
        model: 'image-model',
      );

      expect(reworked.succeeded, isTrue);
      final slots = await slotsOf(batch.batchId);
      expect(slots[1].status, imageBatchSlotStatusSucceeded);
      expect(slots[1].assetId, isNotNull);
      expect(slots[1].errorCode, isNull);
      // 原来那一格是失败的，没有资产可以当「重出自」。
      expect(slots[1].previousAssetId, isNull);

      final batchRow = await database.imageAssetDao.getBatch(batch.batchId);
      expect(batchRow!.status, imageBatchStatusCompleted);
      expect(batchRow.completedCount, 4);
    },
  );

  test(
    'regenerating a succeeded slot keeps the replaced asset as lineage',
    () async {
      final stub = okCallback();
      final orchestrator = CoverStudioOrchestrator();
      final imageLibrary = buildImageLibraryService(database);
      final batch = await orchestrator.generateBatch(
        database: database,
        imageLibrary: imageLibrary,
        callback: (prompt, {model, size, quality, complexity}) async =>
            AiImageGenerationResult(
              localFilePath: stub.nextSource(supportDir).path,
            ),
        novelId: 'novel_test',
        prompt: 'draw title',
        requestedCount: 2,
        model: 'image-model',
      );
      expect(batch.status, imageBatchStatusCompleted);
      final before = await slotsOf(batch.batchId);
      final replacedAssetId = before[0].assetId;

      await orchestrator.regenerateSlot(
        database: database,
        imageLibrary: imageLibrary,
        callback: (prompt, {model, size, quality, complexity}) async =>
            AiImageGenerationResult(
              localFilePath: stub.nextSource(supportDir).path,
            ),
        batchId: batch.batchId,
        ordinal: 0,
        novelId: 'novel_test',
        prompt: 'draw title again',
        model: 'image-model',
      );

      final after = await slotsOf(batch.batchId);
      expect(after[0].previousAssetId, replacedAssetId);
      expect(after[0].assetId, isNot(replacedAssetId));
    },
  );

  test(
    'a failed rework leaves the slot failed and the batch partial',
    () async {
      final stub = okCallback();
      final orchestrator = CoverStudioOrchestrator();
      final imageLibrary = buildImageLibraryService(database);
      final batch = await orchestrator.generateBatch(
        database: database,
        imageLibrary: imageLibrary,
        callback: (prompt, {model, size, quality, complexity}) async {
          if (stub.calls++ == 1) {
            throw const AiImageGenerationException(
              '登录已过期。',
              code: AiImageErrorCode.auth,
            );
          }
          return AiImageGenerationResult(
            localFilePath: stub.nextSource(supportDir).path,
          );
        },
        novelId: 'novel_test',
        prompt: 'draw title',
        requestedCount: 2,
        model: 'image-model',
      );

      final reworked = await orchestrator.regenerateSlot(
        database: database,
        imageLibrary: imageLibrary,
        callback: (prompt, {model, size, quality, complexity}) async =>
            throw const AiImageGenerationException(
              '登录已过期。',
              code: AiImageErrorCode.auth,
            ),
        batchId: batch.batchId,
        ordinal: 1,
        novelId: 'novel_test',
        prompt: 'draw title again',
        model: 'image-model',
      );

      expect(reworked.succeeded, isFalse);
      final slots = await slotsOf(batch.batchId);
      expect(slots[1].status, imageBatchSlotStatusFailed);
      expect(slots[1].errorCode, AiImageErrorCode.auth.name);
      final batchRow = await database.imageAssetDao.getBatch(batch.batchId);
      expect(batchRow!.status, imageBatchStatusPartial);
    },
  );
}

/// 出图桩：每次给一份内容不同的 PNG，避开 ImageLibraryService 的 sha256 去重。
class AiImageGenerationCallbackStub {
  int calls = 0;
  int _seq = 0;

  File nextSource(Directory dir) {
    _seq++;
    return File('${dir.path}/generated_$_seq.png')
      ..writeAsBytesSync(<int>[..._png, _seq]);
  }
}

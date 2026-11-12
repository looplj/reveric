// 职责: 装配应用级图片任务执行器及启动恢复入口。
// 关联文件:
//   lib/shared/services/production/image_service.dart
//   lib/shared/services/ai/image.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/providers/video_tasks.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../utils/storage_paths.dart';
import '../services/ai/image.dart';
import '../services/production/image_service.dart';
import '../services/production/image_generate_orchestrator.dart';
import 'novel_providers.dart';
import 'video_tasks.dart';

final productionImageInvokeProvider = Provider<ProductionImageInvoke>(
  (ref) => (provider, request, onSubmitted, onOutputs) async {
    final image = AiImageGenerationService(provider, model: request.modelId);
    final database = ref.read(appDatabaseProvider);
    final imageData = <String>[];
    for (final reference in request.references) {
      final asset = reference.assetId.isEmpty
          ? null
          : await database.assetDao.getAsset(reference.assetId);
      imageData.add(
        RevericPaths.resolveStored(asset?.path) ??
            (throw StateError('Image reference ${reference.assetId} missing')),
      );
    }
    return request.references.isEmpty
        ? image.generateImage(
            request.prompt,
            size: request.size,
            aspectRatio: request.ratio,
            resolution: request.resolution,
            complexity: request.complexity,
            onSubmitted: onSubmitted,
            onOutputs: onOutputs,
          )
        : image.editImages(
            request.prompt,
            imageData: imageData,
            size: request.size,
            aspectRatio: request.ratio,
            resolution: request.resolution,
            complexity: request.complexity,
            onSubmitted: onSubmitted,
            onOutputs: onOutputs,
          );
  },
);

// One application instance owns in-flight image requests; pages only watch DB streams.
final imageTaskServiceProvider = Provider<ImageTaskService>((ref) {
  final results = ref.watch(productionResultServiceProvider);
  final service = ImageTaskService(
    database: ref.watch(appDatabaseProvider),
    images: ref.watch(imageLibraryServiceProvider),
    invoke: ref.watch(productionImageInvokeProvider),
    beforeCreate: results.beforeCreate,
    beforeSubmit: results.beforeSubmit,
    recoverSources: results.recover,
    sourceName: results.sourceName,
  );
  ref.onDispose(service.dispose);
  return service;
});

final imageTaskRecoveryProvider = FutureProvider<void>(
  (ref) => ref.watch(imageTaskServiceProvider).recover(),
);

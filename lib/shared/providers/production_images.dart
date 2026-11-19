// 职责: 装配应用级图片任务执行器及启动恢复入口。
// 关联文件:
//   lib/shared/services/production/image_service.dart
//   lib/shared/services/ai/image.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/providers/video_tasks.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/app_database.dart';
import '../models/image/request.dart';
import '../models/production/image_request.dart';
import '../services/ai/image/output.dart';
import '../utils/storage_paths.dart';
import '../services/ai/image.dart';
import '../services/production/image_service.dart';
import '../services/production/image_generate_orchestrator.dart';
import 'novel_providers.dart';
import 'video_tasks.dart';
import 'plugin_providers.dart';
import 'trace_providers.dart';

final productionImageInvokeProvider = Provider<ProductionImageInvoke>((ref) {
  final database = ref.watch(appDatabaseProvider);
  final pluginHost = ref.watch(pluginHostServiceProvider);
  final referenceStorage = ref.watch(referenceStorageServiceProvider);
  return (
    taskId,
    provider,
    request,
    onSubmitted,
    onOutputs,
    cancellation,
  ) async {
    final capabilities = request.capabilities;
    final defaults = request.requestDefaults;
    if (capabilities == null || defaults == null) {
      throw StateError('Image task requires frozen model declarations');
    }
    capabilities.size(request.ratio, request.resolution);
    if (request.complexity != null &&
        !capabilities.complexityLevels.contains(request.complexity)) {
      throw const FormatException('Unsupported image complexity');
    }
    capabilities.validateReferences(request.references.length);
    capabilities.validateSize(
      request.size,
      references: request.references.length,
    );
    final context = ImageOutputContext(provider, taskId: taskId);
    final unlink = cancellation.onCancel(context.cancel);
    try {
      final files = <(ProductionImageReference, File, String)>[];
      for (final reference in request.references) {
        final asset = await database.assetDao.getAsset(reference.assetId);
        final path = RevericPaths.resolveStored(asset?.path);
        final mime = asset?.mimeType;
        if (path == null || mime == null) {
          throw StateError('Image reference ${reference.assetId} missing');
        }
        files.add((reference, File(path), mime));
      }
      final prepared = await referenceStorage.prepareImages(
        files,
        provider: provider,
        transport: capabilities.referenceTransport,
        files: context.inputScope,
        taskId: taskId,
        cancellation: cancellation,
      );
      final input = SubmitImageInput(
        prompt: request.prompt,
        modelId: request.modelId,
        size: request.size,
        aspectRatio: request.ratio,
        resolution: request.resolution,
        complexity: request.complexity,
        references: prepared.map(PreparedImageReference.fromJson).toList(),
        defaults: defaults,
      );
      return await AiImageGenerationService(
        provider,
        model: request.modelId,
        pluginHost: pluginHost,
      ).generatePrepared(
        input,
        context: context,
        capabilities: capabilities,
        onSubmitted: onSubmitted,
        onOutputs: onOutputs,
        cancellation: cancellation,
      );
    } finally {
      unlink();
      context.cancel();
      await context.disposeInputs();
    }
  };
});

// One application instance owns in-flight image requests; pages only watch DB streams.
final imageTaskServiceProvider = Provider<ImageTaskService>((ref) {
  final results = ref.watch(productionResultServiceProvider);
  final service = ImageTaskService(
    database: ref.watch(appDatabaseProvider),
    pluginHost: ref.watch(pluginHostServiceProvider),
    images: ref.watch(imageLibraryServiceProvider),
    invoke: ref.watch(productionImageInvokeProvider),
    beforeCreate: results.beforeCreate,
    beforeSubmit: results.beforeSubmit,
    recoverSources: results.recover,
    sourceName: results.sourceName,
    onGenerationAttempt: ref
        .watch(traceReporterServiceProvider)
        .onMediaGenerationAttempt,
  );
  ref.onDispose(service.dispose);
  return service;
});

final imageTaskRecoveryProvider = FutureProvider<void>(
  (ref) => ref.watch(imageTaskServiceProvider).recover(),
);

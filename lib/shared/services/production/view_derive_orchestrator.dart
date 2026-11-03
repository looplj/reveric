// 职责: 校验派生图片的来源和模型规格，建立草稿并通过现有图片任务提交。
// 关联文件:
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/production/image_generate_orchestrator.dart
//   lib/shared/models/production/view_presets.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/ai-calling.md
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import '../../database/novel_content_database.dart';
import '../../models/ai_provider.dart';
import '../../models/production/image_request.dart';
import '../../models/production/view_presets.dart';
import '../../models/video/request.dart';
import '../storyboard/service.dart';
import 'canvas_service.dart';
import 'image_generate_orchestrator.dart';
import 'image_service.dart';
import 'node_source.dart';
import 'ffmpeg_runner.dart';
import '../../models/production/media.dart';

class ViewDeriveOrchestrator {
  /// 入口只创建草稿；模型、用户提示词及任务提交留给图片编辑器。
  Future<CanvasNode> createDraft({
    required ProductionCanvasService service,
    required String sourceNodeId,
    required ImageGenerationMethod method,
    required String title,
    MediaCancellation? cancellation,
  }) async {
    if (cancellation?.cancelled == true) {
      throw const MediaException(MediaFailure.cancelled);
    }

    final source = await service.requireNode(sourceNodeId);
    final clip = source.clipId == null
        ? null
        : await service.shots.getShot(source.clipId!);
    if (cancellation?.cancelled == true) {
      throw const MediaException(MediaFailure.cancelled);
    }
    return service.addDerivedImage(
      sourceNodeId: sourceNodeId,
      input: ProductionInput.node(sourceNodeId, VideoInputRole.reference_image),
      draft: ProductionImageDraft(
        title: title,
        prompt: '',
        modelId: '',
        ratio: method == ImageGenerationMethod.panorama
            ? '2:1'
            : clip?.ratio ?? '1:1',
        resolution: clip?.resolution ?? '1K',
        preset: ImageGenerationPreset(method: method),
      ),
    );
  }

  Future<CanvasNode> create({
    required ProductionCanvasService service,
    required String sourceNodeId,
    required ViewPreset preset,
    required ViewPresetArgs args,
    required AiModelOption? model,
    required String title,
    ProductionNodeSource? inputSource,
    MediaCancellation? cancellation,
    void Function(ProductionImagePreview preview)? onPreview,
  }) async {
    if (cancellation?.cancelled == true) {
      throw const MediaException(MediaFailure.cancelled);
    }

    if (model == null || model.kind != AiModelKind.image) {
      throw const StoryboardException('invalid_config');
    }
    final provider = await service.library.database.aiProviderDao.getById(
      model.providerId,
    );
    if (provider == null) {
      throw const StoryboardException('invalid_config');
    }
    final capabilities = ProductionImageCapabilities(provider, model.model);
    final source = await service.requireNode(sourceNodeId);
    if (!{canvasNodeTypeImage, canvasNodeTypeMedia}.contains(source.type)) {
      throw const StoryboardException('invalid_reference');
    }
    final input = ProductionInput.node(
      source.id,
      VideoInputRole.reference_image,
    );
    final asset = inputSource?.asset ?? await service.inputAsset(input);
    final clip = source.clipId == null
        ? null
        : await service.shots.getShot(source.clipId!);
    final String ratio;
    var resolution = clip?.resolution ?? '1K';
    if (preset == ViewPreset.panorama) {
      ratio = '2:1';
      // 未登记型号的规格未经验证，交给服务端默认分辨率，不自动挑最高档。
      final resolutions = capabilities.verifiedCapabilities == null
          ? const ['auto']
          : ([...capabilities.resolutions]..sort(
              (a, b) => (double.tryParse(b.replaceAll('K', '')) ?? 0).compareTo(
                double.tryParse(a.replaceAll('K', '')) ?? 0,
              ),
            ));
      resolution = resolutions.firstWhere((candidate) {
        try {
          capabilities.validate(
            prompt: 'panorama',
            ratio: ratio,
            resolution: candidate,
            references: 1,
          );
          return true;
        } on FormatException {
          return false;
        }
      }, orElse: () => throw const StoryboardException('invalid_config'));
    } else if (clip != null) {
      ratio = clip.ratio;
    } else {
      final buffer = await ui.ImmutableBuffer.fromFilePath(
        inputSource?.path ?? service.library.resolve(asset),
      );
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          ratio = nearestImageRatio(
            descriptor.width,
            descriptor.height,
            capabilities.ratios,
          );
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
    }
    final prompt = expandViewPreset(preset, args, input.id);
    capabilities.validate(
      prompt: prompt,
      ratio: ratio,
      resolution: resolution,
      references: 1,
    );
    if (cancellation?.cancelled == true) {
      throw const MediaException(MediaFailure.cancelled);
    }
    return service.write(source.id, () async {
      final node = await service.addDerivedImage(
        sourceNodeId: source.id,
        input: input,
        panorama: preset == ViewPreset.panorama,
        draft: ProductionImageDraft(
          prompt: prompt,
          modelId: model.model,
          providerId: provider.id,
          ratio: ratio,
          resolution: resolution,
          title: title,
        ),
      );
      if (onPreview != null) {
        onPreview(
          await ProductionImageGenerateOrchestrator().preview(service, node.id),
        );
      }
      return node;
    });
  }

  Future<CanvasNode> run({
    required ProductionCanvasService service,
    required ImageTaskService jobs,
    required String sourceNodeId,
    required ViewPreset preset,
    ViewPresetArgs args = const ViewPresetArgs(),
    required AiModelOption? model,
    required String title,
  }) async {
    final node = await create(
      service: service,
      sourceNodeId: sourceNodeId,
      preset: preset,
      args: args,
      model: model,
      title: title,
    );
    final preview = await ProductionImageGenerateOrchestrator().preview(
      service,
      node.id,
    );
    // 任务行建好、节点开始显示生成状态就返回；后续生成和失败记录交给任务本身。
    final prepared = Completer<void>();
    final job = jobs.submit(
      novelId: preview.novelId,
      sourceType: preview.sourceType,
      sourceId: preview.sourceId,
      request: preview.request,
      onPrepared: (_) async => prepared.complete(),
    );
    await Future.any([prepared.future, job]);
    unawaited(job.then<void>((_) {}, onError: (Object _) {}));
    return node;
  }
}

String nearestImageRatio(int width, int height, List<String> ratios) {
  if (width <= 0 || height <= 0) {
    throw const FormatException('Invalid image dimensions');
  }
  final options = ratios.where((r) => r.contains(':')).toList();
  if (options.isEmpty) {
    if (ratios.contains('auto')) {
      return 'auto';
    }
    throw const FormatException('No supported image ratio');
  }
  double distance(String ratio) {
    final parts = ratio.split(':').map(double.parse).toList();
    return math.log((parts[0] / parts[1]) / (width / height)).abs();
  }

  options.sort((a, b) => distance(a).compareTo(distance(b)));
  return options.first;
}

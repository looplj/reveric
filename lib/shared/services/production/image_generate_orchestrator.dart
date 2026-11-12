// 职责: 组装图片节点的生成请求，调用生图服务并编排输出登记和采用。
// 关联文件:
//   lib/shared/services/production/image_service.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/ai/image.dart
//   lib/shared/models/production/image_request.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/ai-calling.md
import '../../database/novel_content_database.dart';
import '../../models/generation/task.dart';
import '../../models/ai_provider.dart';
import '../../models/production/image_request.dart';
import '../../models/production/view_presets.dart';
import '../../models/storyboard/prompt.dart';
import '../../models/video/request.dart';
import '../ai/image.dart';
import '../storyboard/service.dart';
import 'canvas_service.dart';
import 'image_service.dart';

class ProductionImagePreview {
  const ProductionImagePreview(
    this.novelId,
    this.nodeId,
    this.sourceId,
    this.request,
  );
  final String nodeId;
  final String novelId;
  final String sourceId;
  String get sourceType => 'production_clip';
  final ProductionImageRequest request;
}

typedef ProductionImageInvoke =
    Future<AiImageGenerationResult> Function(
      AiProvider provider,
      ProductionImageRequest request,
      ImageSubmitted onSubmitted,
      ImageOutputsReceived onOutputs,
    );

class ProductionImageGenerateOrchestrator {
  bool cancelled = false;
  void cancel() => cancelled = true;

  Future<ProductionImagePreview> preview(
    ProductionCanvasService service,
    String nodeId,
  ) async {
    final node = await service.requireNode(nodeId);
    if (node.type != canvasNodeTypeImage || node.clipId == null) {
      throw const StoryboardException('invalid_config');
    }
    final clip = (await service.shots.getShot(node.clipId!))!;
    final provider = clip.providerId == null
        ? null
        : await service.library.database.aiProviderDao.getById(
            clip.providerId!,
          );
    if (provider == null || clip.modelId == null) {
      throw const StoryboardException('invalid_config');
    }
    final references = <ProductionImageReference>[];
    final allInputs = await service.draftInputs(nodeId);
    final textInputs = await service.promptTexts(allInputs);
    final draft = allInputs.where((input) => !input.isPrompt).toList();
    for (final input in draft) {
      if (input.role != VideoInputRole.reference_image) {
        throw const StoryboardException('invalid_reference');
      }
      if (input.sourceNodeId != null) {
        await service.requireAcyclic(
          input.sourceNodeId!,
          node.id,
          node.canvasId,
        );
      }
      final sourceAsset = await service.inputAsset(input);
      await service.requireFile(sourceAsset.path!, type: input.role.kind.name);
      references.add(
        ProductionImageReference(assetId: sourceAsset.id, inputId: input.id),
      );
    }
    final preset = ImageGenerationPreset.fromStyle(node.style);
    if (preset.method == ImageGenerationMethod.panorama &&
        clip.ratio != '2:1') {
      throw const StoryboardException('invalid_config');
    }
    final originalPrompt = preset.assemble(clip.prompt, draft.firstOrNull?.id);
    final parsed = StoryboardPrompt.parse(originalPrompt);
    final text = parsed.render(
      textInputs: textInputs,
      reference: (part) {
        final index = references.indexWhere((r) => r.inputId == part.inputId);
        if (index < 0) {
          throw const StoryboardException('invalid_reference');
        }
        return '图片${index + 1}';
      },
    );
    final style = await service.effectiveStyle(clip);
    final prompt = style?.assemble(text) ?? text;
    final capabilities = ProductionImageCapabilities(provider, clip.modelId!);
    capabilities.validate(
      prompt: prompt,
      ratio: clip.ratio,
      resolution: clip.resolution,
      references: references.length,
    );
    return ProductionImagePreview(
      service.novelId,
      node.id,
      clip.id,
      ProductionImageRequest(
        providerId: provider.id,
        modelId: clip.modelId!,
        originalPrompt: parsed.render(
          textInputs: textInputs,
          reference: (part) => part.text,
        ),
        prompt: prompt,
        ratio: clip.ratio,
        resolution: clip.resolution,
        size: capabilities.size(clip.ratio, clip.resolution),
        complexity: preset.complexity,
        references: references,
      ),
    );
  }

  Future<void> run(
    ImageTaskService jobs,
    String id,
    ProductionImageRequest request,
    AiProvider provider, {
    void Function(Object error, StackTrace stack)? onFailure,
  }) async {
    try {
      if (cancelled ||
          (await jobs.requireRun(id)).status != GenerationTaskStatus.running) {
        return;
      }
      final result = await jobs.invoke(
        provider,
        request,
        (providerTaskId) => jobs.recordSubmission(id, providerTaskId),
        (urls) => jobs.recordRemoteOutputs(id, urls),
      );
      try {
        if (cancelled) {
          return;
        }
        await jobs.recordResult(id, result);
        if (!cancelled) {
          await jobs.saveOutput(id);
        }
      } finally {
        await result.disposeTemporary();
      }
    } catch (error, stack) {
      onFailure?.call(error, stack);
      await jobs.recordFailure(id, error, stack);
    }
  }
}

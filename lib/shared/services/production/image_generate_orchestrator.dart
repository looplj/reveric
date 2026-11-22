// 职责: 组装图片节点的生成请求，调用生图服务并编排输出登记和采用。
// 关联文件:
//   lib/shared/services/production/image_service.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/ai/image.dart
//   lib/shared/models/production/image_request.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/ai-calling.md
import '../../models/provider_model.dart';
import '../../agent/agent_tool_dispatcher.dart';
import '../../database/novel_content_database.dart';
import '../../logger/app_logger.dart';
import '../../models/generation/task.dart';
import '../../models/ai_provider.dart';
import '../../models/image/channels.dart' show imageComplexityFor;
import '../../models/production/image_request.dart';
import '../../models/production/view_presets.dart';
import '../../models/storyboard/prompt.dart';
import '../../models/video/request.dart';
import '../ai/image.dart';
import '../ai/media_diagnostics.dart';
import '../storyboard/service.dart';
import 'canvas_service.dart';
import 'image_service.dart';

final _log = AppLogger.forModule('ProductionImage');

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
      String taskId,
      AiProvider provider,
      ProductionImageRequest request,
      ImageSubmitted onSubmitted,
      ImageOutputsReceived onOutputs,
      AgentCancellationToken cancellation,
    );

class ProductionImageGenerateOrchestrator {
  bool cancelled = false;
  final _cancellation = AgentCancellationController();
  void cancel() {
    cancelled = true;
    _cancellation.cancel();
  }

  Future<ProductionImagePreview> preview(
    ProductionCanvasService service,
    String nodeId,
  ) async {
    final node = await service.requireNode(nodeId);
    if (node.type != canvasNodeTypeImage || node.clipId == null) {
      _log.warning(
        'Image preview rejected nodeId=$nodeId '
        'code=invalid_config reason=invalid_image_node',
      );
      throw const StoryboardException('invalid_config');
    }
    final clip = (await service.shots.getShot(node.clipId!))!;
    final provider = clip.providerId == null
        ? null
        : await service.library.database.aiProviderDao.getById(
            clip.providerId!,
          );
    final modelId = clip.modelId;
    if (provider == null || modelId == null) {
      final reason = switch (provider) {
        null when clip.providerId == null => 'provider_not_selected',
        null => 'provider_not_found',
        _ => 'model_not_selected',
      };
      _logPreviewRejection(clip, provider, reason);
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
      _logPreviewRejection(clip, provider, 'invalid_panorama_ratio');
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
    final capabilities = ProductionImageCapabilities(provider, modelId);
    try {
      capabilities.validate(
        prompt: prompt,
        ratio: clip.ratio,
        resolution: clip.resolution,
        references: references.length,
      );
    } on FormatException {
      final reason = switch (provider) {
        AiProvider(enabled: false) => 'provider_disabled',
        _ when modelId.isEmpty => 'model_not_selected',
        _ when !capabilities.isSupported => 'model_not_supported',
        _ when !provider.availableImageModels.contains(modelId) =>
          'model_not_configured',
        _ when prompt.trim().isEmpty => 'prompt_empty',
        _ => 'invalid_image_parameters',
      };
      _logPreviewRejection(clip, provider, reason);
      rethrow;
    }
    return ProductionImagePreview(
      service.novelId,
      node.id,
      clip.id,
      ProductionImageRequest(
        providerId: provider.id,
        modelId: modelId,
        originalPrompt: parsed.render(
          textInputs: textInputs,
          reference: (part) => part.text,
        ),
        prompt: prompt,
        ratio: clip.ratio,
        resolution: clip.resolution,
        size: capabilities.size(clip.ratio, clip.resolution),
        complexity: imageComplexityFor(provider, modelId, preset.complexity),
        references: references,
        capabilities: capabilities.effectiveCapabilities,
        requestDefaults:
            resolveImageModel(provider, modelId)?.rawDefaults ?? {},
      ),
    );
  }

  void _logPreviewRejection(
    ProductionClipRow clip,
    AiProvider? provider,
    String reason,
  ) {
    final model = safeMediaDiagnostic(
      clip.modelId ?? '',
      provider?.effectiveApiKey ?? '',
    );
    _log.warning(
      'Image preview rejected clipId=${clip.id} providerId=${clip.providerId} '
      'providerType=${provider?.type} modelId=$model '
      'code=invalid_config reason=$reason',
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
        id,
        provider,
        request,
        (submission) => jobs.recordSubmission(id, submission),
        (outputs, context) => jobs.recordRemoteOutputs(id, outputs, context),
        _cancellation.token,
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

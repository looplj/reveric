// 职责: 冻结音频请求、校验参考文件，并编排可取消的生成和结果保存。
// 关联文件:
//   lib/shared/services/production/audio_service.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/models/audio/request.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../../database/novel_content_database.dart';
import '../../models/ai_provider.dart';
import '../../models/audio/request.dart';
import '../../models/audio/settings.dart';
import '../../models/generation/task.dart';
import '../../models/storyboard/prompt.dart';
import '../../models/video/request.dart';
import '../../models/audio/result.dart';
import '../../models/audio/exception.dart';
import '../../logger/app_logger.dart';
export '../../models/audio/result.dart';
import '../storyboard/service.dart';
import 'audio_service.dart';
import 'canvas_service.dart';
import 'library_service.dart';

final _log = AppLogger.forModule('AudioTasks');

typedef ProductionAudioInvoke =
    Future<AudioGenerationResult> Function(
      AiProvider provider,
      AudioRequest request,
      List<Uint8List> references,
      Future<void> abortTrigger,
    );

typedef ProductionAudioQuery =
    Future<AudioGenerationResult> Function(
      AiProvider provider,
      String predictionId,
      Future<void> abortTrigger,
    );

class ProductionAudioPreview {
  const ProductionAudioPreview(
    this.novelId,
    this.nodeId,
    this.sourceId,
    this.request,
  );
  final String novelId, nodeId, sourceId;
  final AudioRequest request;
  String get sourceType => 'production_clip';
}

class ProductionAudioGenerateOrchestrator {
  bool cancelled = false;
  final _abort = Completer<void>();
  void cancel() {
    cancelled = true;
    if (!_abort.isCompleted) {
      _abort.complete();
    }
  }

  Future<List<Uint8List>> prepareReferences(
    AudioRequest request,
    MediaLibraryService library, {
    required String providerType,
  }) async {
    AudioCapabilities(
      request.modelId,
      providerType: providerType,
    ).validate(request);
    final references = <Uint8List>[];
    for (final ref in request.references) {
      if (cancelled) {
        throw const AudioException('cancelled');
      }
      final asset = await library.database.assetDao.getAsset(ref.assetId);
      if (asset?.path == null) {
        throw const AudioException('invalid_reference');
      }
      try {
        references.add(await File(library.resolve(asset!)).readAsBytes());
      } on FileSystemException catch (error, stack) {
        _log.error(
          'reference read failed type=${error.runtimeType} code=${error.osError?.errorCode}',
          stackTrace: stack,
        );
        throw const AudioException('invalid_reference');
      }
    }
    if (cancelled) {
      throw const AudioException('cancelled');
    }
    return references;
  }

  Future<ProductionAudioPreview> preview(
    ProductionCanvasService service,
    String nodeId,
  ) async {
    final node = await service.requireNode(nodeId);
    if (node.type != canvasNodeTypeAudio || node.clipId == null) {
      throw const StoryboardException('invalid_config');
    }
    final clip = (await service.shots.getShot(node.clipId!))!;
    final provider = clip.providerId == null
        ? null
        : await service.library.database.aiProviderDao.getById(
            clip.providerId!,
          );
    if (provider == null ||
        !provider.enabled ||
        !AudioCapabilities(clip.modelId ?? '').supportsProvider(provider) ||
        !provider.availableAudioModels.contains(clip.modelId)) {
      throw const StoryboardException('invalid_config');
    }
    final allInputs = await service.draftInputs(node.id);
    final textInputs = await service.promptTexts(allInputs);
    final inputs = allInputs.where((input) => !input.isPrompt).toList();
    for (final input in inputs) {
      if (input.sourceNodeId != null) {
        await service.requireAcyclic(
          input.sourceNodeId!,
          node.id,
          node.canvasId,
        );
      }
    }
    final references = await resolveAudioReferences(
      service,
      clip.modelId!,
      inputs,
      providerId: provider.id,
    );
    final capability = AudioCapabilities.forProvider(clip.modelId!, provider);
    final prompt = compileAudioPrompt(
      clip.prompt,
      references,
      placeholders: capability.model.supportsAudioReferencePlaceholders,
      textInputs: textInputs,
    );
    final parameters = audioParametersFromStyle(
      node.style,
      clip.providerId,
      clip.modelId,
    );
    final request = resolveAudioRequest(
      provider.type,
      AudioRequest(
        providerId: provider.id,
        modelId: clip.modelId!,
        prompt: prompt,
        originalPrompt: StoryboardPrompt.parse(
          clip.prompt,
        ).render(textInputs: textInputs, reference: (part) => part.text),
        references: references,
        parameters: parameters,
      ),
    );
    return ProductionAudioPreview(service.novelId, node.id, clip.id, request);
  }

  Future<void> run(
    AudioTaskService jobs,
    String id,
    AudioRequest request,
    AiProvider provider,
  ) async {
    try {
      final task = await jobs.requireRun(id);
      if (cancelled || task.status != GenerationTaskStatus.running) {
        return;
      }
      final references = await prepareReferences(
        request,
        jobs.library,
        providerType: provider.type,
      );
      if (cancelled) {
        return;
      }
      final result = await jobs.invoke(
        provider,
        request,
        references,
        _abort.future,
      );
      if (cancelled) {
        return;
      }
      if (result.isPending) {
        await jobs.recordPrediction(id, result.providerTaskId!);
        await poll(jobs, id, provider, result.providerTaskId!);
        return;
      }
      await jobs.recordOutput(id, result);
      if (!cancelled) {
        await jobs.saveOutput(id);
      }
    } catch (error, stack) {
      if (!cancelled) {
        await jobs.recordFailure(id, error, stack);
      }
    } finally {
      if (!_abort.isCompleted) {
        _abort.complete();
      }
    }
  }

  Future<void> poll(
    AudioTaskService jobs,
    String id,
    AiProvider provider,
    String predictionId,
  ) async {
    final query = jobs.query;
    if (query == null) {
      throw const AudioException('invalid_config');
    }
    final result = await waitForAudioPrediction(
      query,
      provider,
      predictionId,
      _abort.future,
      interval: jobs.pollInterval,
    );
    if (!cancelled) {
      await jobs.recordOutput(id, result);
      if (!cancelled) {
        await jobs.saveOutput(id);
      }
    }
  }
}

/// Poll an accepted task without submitting another charged request.
Future<AudioGenerationResult> waitForAudioPrediction(
  ProductionAudioQuery query,
  AiProvider provider,
  String predictionId,
  Future<void> abort, {
  Duration interval = const Duration(seconds: 2),
}) async {
  var cancelled = false;
  unawaited(abort.then((_) => cancelled = true));
  final deadline = DateTime.now().add(const Duration(minutes: 30));
  while (true) {
    await Future<void>.value();
    if (cancelled) {
      throw const AudioException('cancelled');
    }
    if (DateTime.now().isAfter(deadline)) {
      throw const AudioException('unavailable');
    }
    final result = await query(provider, predictionId, abort);
    if (cancelled) {
      throw const AudioException('cancelled');
    }
    if (!result.isPending) {
      return result;
    }
    final wait = Completer<void>();
    final timer = Timer(interval, wait.complete);
    try {
      await Future.any([wait.future, abort]);
    } finally {
      timer.cancel();
    }
  }
}

/// Resolve and validate the exact files before task creation or upload.
Future<List<AudioReference>> resolveAudioReferences(
  ProductionCanvasService service,
  String modelId,
  List<ProductionInput> inputs, {
  required String? providerId,
}) async {
  final provider = providerId == null
      ? null
      : await service.library.database.aiProviderDao.getById(providerId);
  if (provider == null) {
    throw const AudioException('invalid_config');
  }
  final capabilities = AudioCapabilities.forProvider(modelId, provider);
  final mediaInputs = inputs.where((input) => !input.isPrompt).toList();
  capabilities.validateSelection(mediaInputs.map((r) => r.role.kind.name));
  if (inputs.map((r) => r.identity).toSet().length != inputs.length) {
    throw const AudioException('invalid_reference');
  }
  final references = <AudioReference>[];
  for (final input in mediaInputs) {
    if (!{'reference_audio', 'reference_image'}.contains(input.role.name)) {
      throw const AudioException('audio_reference_format');
    }
    final sourceAsset = await service.inputAsset(input);
    final asset = await service.requireFile(
      sourceAsset.path!,
      type: input.role.kind.name,
    );
    final file = File(service.library.resolvePath(asset.path));
    final size = await file.length();
    final limits = capabilities.model.references[asset.type]!;
    if (size <= 0 || size > limits.maxBytes) {
      throw const AudioException('audio_reference_size');
    }
    final info = await service.library.probePath(asset.path);
    if ((asset.type == 'audio' &&
            (!info.hasAudio ||
                info.hasVideo ||
                (asset.mimeType == 'audio/ogg' &&
                    info.audioCodec != 'opus'))) ||
        (asset.type == 'image' &&
            (!info.hasVideo ||
                !{'png', 'mjpeg', 'webp'}.contains(info.videoCodec)))) {
      throw const AudioException('audio_reference_format');
    }
    final reference = AudioReference(
      assetId: sourceAsset.id,
      kind: asset.type,
      mimeType: asset.mimeType,
      bytes: size,
      durationMs: asset.type == 'audio' ? info.duration.inMilliseconds : null,
      inputId: input.id,
    );
    capabilities.validateReference(reference);
    references.add(reference);
  }
  return references;
}

String compileAudioPrompt(
  String source,
  List<AudioReference> references, {
  bool placeholders = true,
  Map<String, String> textInputs = const {},
}) {
  final parsed = StoryboardPrompt.parse(source);
  final text = parsed.render(
    textInputs: textInputs,
    reference: (part) {
      final index = references.indexWhere((r) => r.inputId == part.inputId);
      if (index < 0 || references[index].kind != 'audio') {
        throw const AudioException('invalid_reference');
      }
      return placeholders ? '@Audio${index + 1}' : '';
    },
  );
  return text;
}

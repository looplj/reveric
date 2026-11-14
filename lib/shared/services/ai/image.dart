// 职责: 按 Provider 分发图片提交与查询，在 Host 调度轮询、输出处理及兼容业务结果。
// 关联文件:
//   lib/shared/models/ai_provider.dart
//   lib/shared/models/image/channels.dart
//   lib/shared/services/ai/image/client.dart
//   lib/shared/services/ai/codex/image_client.dart
//   lib/shared/services/ai/image/output.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/video/task_result.dart' show VideoException;
import 'package:http/http.dart' as http;

import '../../models/ai_provider.dart';
import '../../agent/agent_tool_dispatcher.dart';
import '../../models/provider_model.dart';
import '../../models/production/image_request.dart'
    show ProductionImageReference;
import 'video/reference_storage_service.dart';
import '../../utils/storage_paths.dart';
import '../../models/image/channels.dart';
import '../../models/image/choices.dart';
import 'codex/image_client.dart';
import 'image/agnes.dart';
import 'image/plugin.dart';
import '../plugins/host.dart';
import '../plugins/runtime.dart' show PluginExecutionError, PluginHostError;
import 'image/minimax.dart';
import 'image/moss.dart';
import 'image/ark.dart';
import 'image/atlascloud.dart';
import 'image/midjourney.dart';
import 'image/client.dart';
import 'image/codex.dart';
import 'image/gemini.dart';
import 'image/openai.dart';
import 'image/openrouter.dart';
import 'image/purefox.dart';
import 'new_api.dart';
import 'image/qwen.dart';

/// Direct entries pass complete model parameters without creating a resumable task.
class ImageInvocationOptions {
  const ImageInvocationOptions({
    this.aspectRatio,
    this.preferredRatio,
    this.resolution,
    this.capabilities,
    this.defaults,
    this.references,
    this.cancellation,
  });
  final String? aspectRatio, resolution;

  /// Internal UI preference; explicit aspectRatio/size always remain strict.
  final String? preferredRatio;
  final ImageModelCapabilities? capabilities;
  final Map<String, dynamic>? defaults;
  final List<ProductionImageReference>? references;
  final AgentCancellationToken? cancellation;
  bool get frozen => capabilities != null && defaults != null;
  ImageInvocationOptions withReferences(
    List<ProductionImageReference> values,
  ) => ImageInvocationOptions(
    aspectRatio: aspectRatio,
    preferredRatio: preferredRatio,
    resolution: resolution,
    capabilities: capabilities,
    defaults: defaults,
    references: values,
    cancellation: cancellation,
  );
}

/// Resolve the same saved instance immediately before a new direct request.
Future<AiImageGenerationService> resolveDirectImageService(
  AiProvider selected,
  String model, {
  required PluginHostService host,
  required ReferenceStorageService references,
}) async {
  final current = await references.database.aiProviderDao.getById(selected.id);
  if (current == null || !current.enabled || current.type != selected.type) {
    throw AiImageGenerationException(
      tr(LocaleKeys.aiConfigureImageModel),
      debugMessage: 'Image provider instance is unavailable',
    );
  }
  return AiImageGenerationService(
    current,
    model: model,
    pluginHost: host,
    referenceStorage: references,
  );
}

/// 出图失败的分类。封面工作台按它决定那一格显示哪句「下一步怎么办」，
/// 所以分类逻辑只能有这一份，不要在调用方重写关键字匹配。
enum AiImageErrorCode {
  /// 提示词或图片内容未过审。
  moderation,

  /// 网关限流。
  rate_limit,

  /// 供应商凭据无效或已过期。
  auth,

  /// 该模型出不了这个尺寸 / 比例。
  size,

  /// 模型不支持请求里的某个参数（例如参考图张数超限）。
  param,

  /// 供应商或网关余额不足（HTTP 402、credit.insufficient）。
  credit,

  /// 供应商或网关限制当前凭据访问该模型（HTTP 403、model.forbidden）。
  model_forbidden,
}

/// 从服务端返回的原始错误文案里认出 [AiImageErrorCode]；认不出返回 null。
AiImageErrorCode? classifyAiImageError(String? serverMessage) {
  final normalized = serverMessage?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  final lower = normalized.toLowerCase();
  if (lower.contains('model forbidden for user') ||
      lower.contains('model.forbidden')) {
    return AiImageErrorCode.model_forbidden;
  }
  if (lower.contains('api key') ||
      lower.contains('unauthorized') ||
      lower.contains('authentication')) {
    return AiImageErrorCode.auth;
  }
  if (lower.contains('credit.insufficient') ||
      lower.contains('insufficient_quota') ||
      lower.contains('insufficient credit') ||
      lower.contains('payment required')) {
    return AiImageErrorCode.credit;
  }
  if (lower.contains('size') ||
      lower.contains('resolution') ||
      lower.contains('aspect ratio')) {
    return AiImageErrorCode.size;
  }
  if (lower.contains('content') ||
      lower.contains('safety') ||
      lower.contains('moderation') ||
      lower.contains('review')) {
    return AiImageErrorCode.moderation;
  }
  if (lower.contains('rate limit') || lower.contains('too many requests')) {
    return AiImageErrorCode.rate_limit;
  }
  if (lower.contains('model') && lower.contains('not support')) {
    return AiImageErrorCode.param;
  }
  return null;
}

class AiImageGenerationException implements Exception {
  const AiImageGenerationException(
    this.userMessage, {
    this.debugMessage,
    this.code,
  });

  final String userMessage;
  final String? debugMessage;

  /// 认得出的失败分类；认不出时为 null，调用方按「未知错误」处理。
  final AiImageErrorCode? code;

  @override
  String toString() => userMessage;
}

/// Preserves submission certainty through the facade and task persistence.
class AiImageSubmissionException extends AiImageGenerationException {
  const AiImageSubmissionException(
    super.userMessage, {
    required this.failureCode,
    super.debugMessage,
    super.code,
  });
  final String failureCode;
  bool get requiresReconciliation => failureCode == 'invalid_outputs';
}

AiImageSubmissionException invalidImageOutputs([Object? detail]) =>
    AiImageSubmissionException(
      tr(LocaleKeys.aiImageInvalidOutputs),
      failureCode: 'invalid_outputs',
      debugMessage: detail?.toString(),
    );

class AiImageTerminalException extends AiImageGenerationException {
  const AiImageTerminalException(
    super.userMessage, {
    required this.status,
    this.failureCode,
    super.debugMessage,
    super.code,
  });
  final String status;
  final String? failureCode;
}

/// 回报完整候选回执及逐项落盘进度；调用方持久化后才处理下一候选。
typedef ImageOutputsReceived =
    Future<void> Function(ProviderSucceeded result, ImageOutputContext context);

/// 回报任务 ID 与完整查询状态；调用方原子落库后才继续查询。
typedef ImageSubmitted = Future<void> Function(ProviderSubmitted result);

/// 上游已受理，但结果没取回本地：有 [url] 时重新下载，
/// 否则凭 [providerTaskId] 继续查询上游任务。
class AiImageFetchException extends AiImageGenerationException {
  const AiImageFetchException(
    super.userMessage, {
    this.url,
    this.providerTaskId,
    this.urls = const [],
    this.providerOutputs = const [],
    this.providerState,
    super.debugMessage,
  });

  final String? url;
  final String? providerTaskId;
  final List<String> urls;
  final List<ProviderOutput> providerOutputs;
  final Map<String, dynamic>? providerState;
}

class AiImageGenerationResult {
  final List<AiImageGenerationResult> additionalImages;
  List<AiImageGenerationResult> get images => [this, ...additionalImages];
  factory AiImageGenerationResult.group(List<AiImageGenerationResult> images) {
    final first = images.first;
    return AiImageGenerationResult(
      imageUrl: first.imageUrl,
      imageBase64: first.imageBase64,
      localFilePath: first.localFilePath,
      revisedPrompt: first.revisedPrompt,
      mimeSubtype: first.mimeSubtype,
      assetId: first.assetId,
      outputHandle: first.outputHandle,
      additionalImages: List.unmodifiable(images.skip(1)),
    );
  }

  final String? imageUrl;
  final String? imageBase64;
  final String? revisedPrompt;
  final String? localFilePath;

  /// 图片入库后取得的资产 ID；尚未入库的客户端结果为空。
  final String? assetId;
  final String? outputHandle;

  /// MIME subtype detected from the actual image bytes (e.g. 'png', 'jpeg').
  /// Used to build correct data-URI prefixes instead of hardcoding 'png'.
  final String mimeSubtype;

  const AiImageGenerationResult({
    this.imageUrl,
    this.imageBase64,
    this.revisedPrompt,
    this.localFilePath,
    this.assetId,
    this.outputHandle,
    this.mimeSubtype = 'png',
    this.additionalImages = const [],
  });

  /// 只清理图片客户端在 media 根目录创建的未登记 .part 结果。
  Future<void> disposeTemporary() async {
    for (final image in additionalImages) {
      await image.disposeTemporary();
    }
    final path = localFilePath;
    if (path == null) {
      return;
    }
    final root = Directory(RevericPaths.fileWorkspaceParent);
    if (!RevericPaths.isImageResultPart(root, path)) {
      return;
    }

    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
    final handle = outputHandle;
    if (handle != null && RegExp(r'^[a-f0-9-]{36}$').hasMatch(handle)) {
      final record = File('${root.path}/file_workspaces/$handle.json');
      if (await record.exists()) {
        await record.delete();
      }
    }
  }

  bool get hasImage =>
      imageUrl != null || imageBase64 != null || localFilePath != null;

  String? get effectiveSource {
    if (localFilePath != null) return localFilePath;
    if (imageBase64 != null) {
      return 'data:image/$mimeSubtype;base64,$imageBase64';
    }
    if (imageUrl != null) return imageUrl;
    return null;
  }
}

/// 按 provider 的图片协议选择客户端，统一错误分类与日志。
class AiImageGenerationService {
  AiImageGenerationService(
    this._config, {
    required this._model,
    this._codexImageClientFactory,
    this.pluginHost,
    this.referenceStorage,
  });

  final PluginHostService? pluginHost;
  final ReferenceStorageService? referenceStorage;
  final AiProvider _config;
  final String _model;
  final CodexImageClient Function()? _codexImageClientFactory;

  ImageClient? _client([String? model]) {
    if (_config.pluginId != null) {
      final host = pluginHost;
      if (host == null) {
        throw const ProviderFailure(
          code: 'configuration_required',
          message: 'Plugin Host is required for image generation',
        );
      }
      return PluginImageClient(_config, host);
    }
    final options = lookupImageChannelModel(
      _config.type,
      model ?? _model,
    )?.protocolOptions;
    if (options is MidjourneyImageOptions) {
      return MidjourneyImageClient(_config, options.protocol);
    }
    return switch (_config.typeConfig.imageProtocol) {
      ImageProtocol.moss_image => MossImageClient(_config),
      ImageProtocol.agnes_image => AgnesImageClient(_config),
      ImageProtocol.qwen_image => QwenImageClient(_config),
      ImageProtocol.ark_image => ArkImageClient(_config),
      ImageProtocol.openrouter_image => OpenRouterImageClient(_config),
      ImageProtocol.atlascloud_image => AtlasCloudImageClient(_config),
      ImageProtocol.new_api_images => NewApiClient(_config).image(),
      ImageProtocol.openai_images => OpenAiImageClient(_config),
      ImageProtocol.codex_image => CodexImageGenerationClient(
        _config,
        clientFactory: _codexImageClientFactory,
      ),
      ImageProtocol.gemini_image => GeminiImageClient(_config),
      ImageProtocol.purefox_media => PurefoxImageClient(_config),
      ImageProtocol.minimax_image => MinimaxImageClient(_config),
      null => null,
    };
  }

  Future<AiImageGenerationResult> generateImage(
    String prompt, {
    String? model,
    String? size,
    String? quality,
    String? complexity,
    String? aspectRatio,
    String? resolution,
    ImageInvocationOptions? options,
    ImageSubmitted? onSubmitted,
    ImageOutputsReceived? onOutputs,
  }) => _run(() async {
    final client =
        _client(model) ??
        (throw AiImageGenerationException('${_config.displayName} 当前不支持生图。'));
    final resolvedModel = model ?? _model;
    final preference = options?.preferredRatio;
    final choices = preference == null
        ? null
        : ImageModelChoices(_config, resolvedModel);
    final selectedRatio =
        options?.aspectRatio ??
        aspectRatio ??
        choices?.defaultRatio(preference!);
    final selectedResolution =
        options?.resolution ?? resolution ?? choices?.defaultResolution('1K');
    final selectedSize =
        size ?? choices?.size(selectedRatio!, selectedResolution!);
    return _execute(
      client,
      SubmitImageInput(
        prompt: prompt,
        modelId: resolvedModel,
        size: selectedSize,
        quality: quality,
        complexity:
            complexity ?? imageComplexityFor(_config, resolvedModel, null),
        aspectRatio: selectedRatio,
        resolution: selectedResolution,
        defaults: options?.defaults ?? const {},
      ),
      onSubmitted: onSubmitted,
      onOutputs: onOutputs,
      frozen: options?.frozen ?? false,
      capabilities: options?.capabilities,
      referenceIdentities: options?.references,
      cancellation: options?.cancellation,
    );
  });

  Future<AiImageGenerationResult> editImage(
    String prompt, {
    required String imageData,
    String? model,
    String? size,
    String? quality,
    String? complexity,
    String? aspectRatio,
    String? resolution,
    ImageInvocationOptions? options,
  }) {
    return editImages(
      prompt,
      imageData: [imageData],
      model: model,
      size: size,
      quality: quality,
      complexity: complexity,
      aspectRatio: aspectRatio,
      resolution: resolution,
      options: options,
    );
  }

  /// 按上游任务 ID 继续查询并取回结果，不重新出图。
  Future<AiImageGenerationResult> resumeResult(String providerTaskId) => _run(
    () async {
      final client =
          _client() ??
          (throw AiImageGenerationException('${_config.displayName} 当前不支持生图。'));
      return _execute(
        client,
        SubmitImageInput(prompt: '', modelId: _model),
        resume: ProviderQueryInput(providerTaskId),
      );
    },
  );

  /// 重试已知下载引用，不重新提交生成。
  Future<AiImageGenerationResult> downloadResults(List<String> urls) =>
      _run(() async {
        final outputs = ImageOutputContext(_config);
        try {
          return await outputs.materialize(
            await outputs.nativeImages([
              for (final url in urls) {'url': url},
            ]),
          );
        } finally {
          outputs.cancel();
        }
      });

  Future<AiImageGenerationResult> downloadResult(String url) =>
      downloadResults([url]);

  /// OpenAI Images API 多参考图编辑契约。
  Future<AiImageGenerationResult> editImages(
    String prompt, {
    required List<String> imageData,
    String? model,
    String? size,
    String? quality,
    String? complexity,
    String? aspectRatio,
    String? resolution,
    ImageInvocationOptions? options,
    ImageSubmitted? onSubmitted,
    ImageOutputsReceived? onOutputs,
  }) => _run(() async {
    if (imageData.isEmpty) {
      throw const AiImageGenerationException('缺少待编辑的图片内容。');
    }
    final client = _client(model);
    if (client == null || !client.supportsEdit) {
      throw AiImageGenerationException('${_config.displayName} 当前不支持图片编辑。');
    }
    final resolvedModel = model ?? _model;
    final preference = options?.preferredRatio;
    final choices = preference == null
        ? null
        : ImageModelChoices(_config, resolvedModel);
    final selectedRatio =
        options?.aspectRatio ??
        aspectRatio ??
        choices?.defaultRatio(preference!);
    final selectedResolution =
        options?.resolution ?? resolution ?? choices?.defaultResolution('1K');
    final selectedSize =
        size ?? choices?.size(selectedRatio!, selectedResolution!);
    return _execute(
      client,
      SubmitImageInput(
        prompt: prompt,
        modelId: resolvedModel,
        size: selectedSize,
        quality: quality,
        complexity:
            complexity ?? imageComplexityFor(_config, resolvedModel, null),
        aspectRatio: selectedRatio,
        resolution: selectedResolution,
        defaults: options?.defaults ?? const {},
      ),
      rawImages: imageData,
      onSubmitted: onSubmitted,
      onOutputs: onOutputs,
      frozen: options?.frozen ?? false,
      capabilities: options?.capabilities,
      referenceIdentities: options?.references,
      cancellation: options?.cancellation,
    );
  });

  Future<AiImageGenerationResult> generatePrepared(
    SubmitImageInput input, {
    required ImageOutputContext context,
    required ImageModelCapabilities capabilities,
    ImageSubmitted? onSubmitted,
    ImageOutputsReceived? onOutputs,
    AgentCancellationToken? cancellation,
  }) => _run(() async {
    final client = _client(input.modelId);
    if (client == null) {
      throw const ProviderFailure(
        code: 'configuration_required',
        message: 'Image provider is unavailable',
      );
    }
    return _execute(
      client,
      input,
      context: context,
      frozen: true,
      capabilities: capabilities,
      onSubmitted: onSubmitted,
      onOutputs: onOutputs,
      cancellation: cancellation,
    );
  });

  Future<AiImageGenerationResult> downloadPrepared(
    ProviderSucceeded result, {
    required ImageOutputContext context,
    ImageOutputsReceived? onOutputs,
    AgentCancellationToken? cancellation,
  }) => _run(() async {
    final unlink = cancellation?.onCancel(context.cancel);
    try {
      if (cancellation?.isCancellationRequested == true) {
        throw const ProviderFailure(
          code: 'cancelled',
          message: 'Image wait cancelled',
        );
      }
      await context.confirm(result);
      await onOutputs?.call(result, context);
      final current = result.outputs.toList();
      return await context.materialize(
        result,
        onCandidate: (index, file) async {
          current[index] = file;
          await context.confirm(ProviderSucceeded(current));
          await onOutputs?.call(ProviderSucceeded(current), context);
        },
      );
    } finally {
      unlink?.call();
    }
  });

  Future<AiImageGenerationResult> queryPrepared(
    ProviderQueryInput input, {
    required ImageOutputContext context,
    ImageSubmitted? onSubmitted,
    ImageOutputsReceived? onOutputs,
    AgentCancellationToken? cancellation,
  }) => _run(() async {
    final client = _client();
    if (client == null) {
      throw const ProviderFailure(
        code: 'configuration_required',
        message: 'Image provider is unavailable',
      );
    }
    return _execute(
      client,
      SubmitImageInput(prompt: '', modelId: _model),
      context: context,
      frozen: true,
      resume: input,
      singleQuery: true,
      onSubmitted: onSubmitted,
      onOutputs: onOutputs,
      cancellation: cancellation,
    );
  });

  Future<AiImageGenerationResult> _execute(
    ImageClient client,
    SubmitImageInput request, {
    ImageSubmitted? onSubmitted,
    ImageOutputsReceived? onOutputs,
    ProviderQueryInput? resume,
    List<String> rawImages = const [],
    ImageOutputContext? context,
    bool frozen = false,
    bool singleQuery = false,
    ImageModelCapabilities? capabilities,
    List<ProductionImageReference>? referenceIdentities,
    AgentCancellationToken? cancellation,
  }) async {
    final declaration = frozen
        ? null
        : resolveImageModel(_config, request.model);
    final defaults = frozen
        ? request.nativeDefaults
        : declaration?.requestDefaults;
    final outputs = context ?? ImageOutputContext(_config);
    String? remoteId = resume?.remoteTaskId;
    Map<String, dynamic>? state = resume?.state;
    final stopped = Completer<void>();
    final unlink = cancellation?.onCancel(() {
      client.cancel();
      outputs.cancel();
      if (!stopped.isCompleted) {
        stopped.complete();
      }
    });
    void checkCancellation() {
      if (cancellation?.isCancellationRequested == true) {
        throw AiImageFetchException(
          tr(LocaleKeys.aiImageCandidatesFetchFailed),
          providerTaskId: remoteId,
          providerState: state,
          debugMessage:
              'Local image wait cancelled; remote outcome is unchanged',
        );
      }
    }

    try {
      checkCancellation();
      final count = rawImages.isEmpty
          ? request.references.length
          : rawImages.length;
      final effectiveCapabilities = capabilities ?? declaration?.capabilities;
      if (effectiveCapabilities != null) {
        if (request.complexity != null &&
            !effectiveCapabilities.complexityLevels.contains(
              request.complexity,
            )) {
          throw invalidImageParameter();
        }
        if (request.quality != null &&
            (effectiveCapabilities.qualityLevels.isNotEmpty
                ? !effectiveCapabilities.qualityLevels.contains(request.quality)
                : _config.isPluginProvider &&
                      request.quality != defaults?.quality)) {
          throw invalidImageParameter();
        }
        final providerValidatesRatio =
            client is PurefoxImageClient &&
            effectiveCapabilities.ratios.length == 1 &&
            effectiveCapabilities.ratios.contains('auto');
        if ((request.aspectRatio != null &&
                !providerValidatesRatio &&
                !effectiveCapabilities.ratios.contains(request.aspectRatio)) ||
            (request.resolution != null &&
                !effectiveCapabilities.resolutions.contains(
                  request.resolution,
                ))) {
          throw invalidImageParameter();
        }
        try {
          effectiveCapabilities.validateReferences(count);
        } on FormatException {
          throw invalidImageParameter();
        }
        try {
          effectiveCapabilities.validateSize(
            request.size ?? defaults?.size,
            references: count,
          );
        } on FormatException {
          throw AiImageGenerationException(
            imageErrorMessage(AiImageErrorCode.size),
            code: AiImageErrorCode.size,
          );
        }
      }
      List<PreparedImageReference> references = request.references;
      if (rawImages.isNotEmpty) {
        final transport =
            effectiveCapabilities?.referenceTransport ??
            ImageReferenceTransport.file;
        if (transport != ImageReferenceTransport.file &&
            referenceStorage == null) {
          throw const ProviderFailure(
            code: 'configuration_required',
            message: 'Reference storage is required for this image transport',
          );
        }
        if (transport == ImageReferenceTransport.uploaded &&
            (_config.pluginId != null
                ? pluginHost?.providerHasMethod(
                        _config.pluginId!,
                        'uploadReference',
                      ) !=
                      true
                : _config.typeConfig.uploadProtocol == null)) {
          throw AiImageGenerationException(
            tr(LocaleKeys.aiImageReferenceUploadUnavailable),
          );
        }
        final files = await outputs.importReferenceFiles(
          rawImages,
          identities: referenceIdentities,
        );
        final storage = referenceStorage;
        if (storage != null) {
          references = (await storage.prepareImages(
            files,
            provider: _config,
            transport: transport,
            files: outputs.inputScope,
            taskId: outputs.inputScope.taskId,
            cancellation: cancellation,
          )).map(PreparedImageReference.fromJson).toList();
        } else {
          references = [];
          for (final (identity, file, mime) in files) {
            final info = await outputs.inputScope.register(
              file,
              name: file.uri.pathSegments.last,
              mimeType: mime,
            );
            references.add(
              PreparedImageReference(
                assetId: identity.assetId,
                clipId: identity.clipId,
                inputId: identity.inputId,
                mimeType: mime,
                source: ImageFileReference(info['handle'] as String),
              ),
            );
          }
        }
      }
      final normalized = SubmitImageInput(
        prompt: request.prompt,
        modelId: request.modelId,
        size: request.size ?? defaults?.size,
        quality: request.quality ?? defaults?.quality,
        complexity: request.complexity ?? defaults?.complexity,
        aspectRatio: request.aspectRatio,
        resolution: request.resolution,
        references: references,
        defaults: frozen
            ? request.defaults
            : declaration?.rawDefaults ?? const {},
      );
      if (_config.pluginId == null) {
        outputs.claimInputs();
      }
      ProviderSucceeded? completed;
      if (resume == null) {
        checkCancellation();
        late final ProviderSubmitResult submission;
        try {
          submission = await client
              .submit(normalized, outputs)
              .timeout(const Duration(minutes: 5));
        } on AiImageGenerationException {
          rethrow;
        } catch (error) {
          final code = switch (error) {
            ProviderFailure() => error.code,
            PluginHostError() => error.code,
            PluginExecutionError() => error.code,
            _ => null,
          };
          if (const {
            'configuration_required',
            'invalid_request',
            'authentication',
            'rate_limited',
            'unavailable',
          }.contains(code)) {
            throw AiImageGenerationException(
              tr(LocaleKeys.aiImageGenerationFailed),
              debugMessage: '$error',
            );
          }
          throw AiImageSubmissionException(
            tr(
              code == 'rejected'
                  ? LocaleKeys.aiImageGenerationFailed
                  : LocaleKeys.aiImageSubmissionUnknown,
            ),
            failureCode: code == 'rejected' ? 'rejected' : 'submission_unknown',
            debugMessage: '$error',
          );
        }
        switch (submission) {
          case ProviderSubmitted():
            remoteId = submission.remoteTaskId;
            state = submission.state;
            try {
              await onSubmitted?.call(submission);
            } catch (error) {
              throw AiImageFetchException(
                tr(LocaleKeys.aiImageCandidatesFetchFailed),
                providerTaskId: remoteId,
                providerState: state,
                debugMessage: '$error',
              );
            }
          case ProviderSucceeded():
            completed = submission;
        }
      }
      checkCancellation();
      final elapsed = Stopwatch()..start();
      while (completed == null) {
        checkCancellation();
        if (elapsed.elapsed >= const Duration(minutes: 10)) {
          throw AiImageFetchException(
            tr(LocaleKeys.aiImageCandidatesFetchFailed),
            providerTaskId: remoteId,
            providerState: state,
            debugMessage: 'Image polling exceeded ten minutes',
          );
        }
        final ProviderQueryResult queried;
        try {
          final remaining = const Duration(minutes: 10) - elapsed.elapsed;
          queried = await client
              .query(ProviderQueryInput(remoteId!, state: state), outputs)
              .timeout(
                remaining < const Duration(seconds: 30)
                    ? remaining
                    : const Duration(seconds: 30),
              );
        } catch (error) {
          throw AiImageFetchException(
            tr(LocaleKeys.aiImageCandidatesFetchFailed),
            providerTaskId: remoteId,
            providerState: state,
            debugMessage: '$error',
          );
        }
        switch (queried) {
          case ProviderSucceeded():
            completed = queried;
          case ProviderPending():
            if (queried.state != null) {
              state = queried.state;
              await onSubmitted?.call(
                ProviderSubmitted(remoteId, state: state),
              );
            }
            checkCancellation();
            if (singleQuery) {
              throw AiImageFetchException(
                tr(LocaleKeys.aiImageCandidatesFetchFailed),
                providerTaskId: remoteId,
                providerState: state,
                debugMessage: 'Image task is still running',
              );
            }
            final remaining = const Duration(minutes: 10) - elapsed.elapsed;
            if (remaining > Duration.zero) {
              final nextPoll = Completer<void>();
              final timer = Timer(
                remaining < const Duration(seconds: 2)
                    ? remaining
                    : const Duration(seconds: 2),
                nextPoll.complete,
              );
              try {
                await Future.any([nextPoll.future, stopped.future]);
              } finally {
                timer.cancel();
              }
            }
          case ProviderFailed(:final error):
            throw AiImageTerminalException(
              error.message,
              status: 'failed',
              failureCode: error.code,
              debugMessage: error.detail,
              code: AiImageErrorCode.values
                  .where((value) => value.name == error.code)
                  .firstOrNull,
            );
          case ProviderStopped():
            throw AiImageTerminalException(
              tr(LocaleKeys.aiImageCandidatesFetchFailed),
              status: queried.cancelled ? 'cancelled' : 'expired',
            );
          case ProviderUnknown():
            throw AiImageFetchException(
              tr(LocaleKeys.aiImageCandidatesFetchFailed),
              providerTaskId: remoteId,
              providerState: state,
              debugMessage: queried.reason,
            );
        }
      }
      if (cancellation?.isCancellationRequested == true &&
          !outputs.hasGrid(completed)) {
        await outputs.confirm(completed);
        await onOutputs?.call(completed, outputs);
      }
      checkCancellation();
      var confirmed = completed;
      try {
        confirmed = await outputs.mergePreserved(
          await outputs.expand(confirmed),
        );
        await outputs.confirm(confirmed);
        await onOutputs?.call(confirmed, outputs);
        final current = confirmed.outputs.toList();
        return await outputs.materialize(
          confirmed,
          onCandidate: (index, file) async {
            current[index] = file;
            await outputs.confirm(ProviderSucceeded(current));
            await onOutputs?.call(ProviderSucceeded(current), outputs);
          },
        );
      } on AiImageFetchException catch (error) {
        throw AiImageFetchException(
          error.userMessage,
          providerTaskId: remoteId,
          providerState: state,
          url: error.url,
          urls: error.urls,
          providerOutputs: outputs.hasGrid(confirmed)
              ? const []
              : confirmed.outputs,
          debugMessage: error.debugMessage,
        );
      } catch (error) {
        throw AiImageFetchException(
          tr(LocaleKeys.aiImageCandidatesFetchFailed),
          providerOutputs: outputs.hasGrid(confirmed)
              ? const []
              : confirmed.outputs,
          urls: outputs.hasGrid(confirmed)
              ? const []
              : confirmed.outputs
                    .whereType<ProviderUrlOutput>()
                    .map((output) => output.url)
                    .toList(),
          providerTaskId: remoteId,
          providerState: state,
          debugMessage: '$error',
        );
      }
    } finally {
      unlink?.call();
      client.cancel();
      outputs.cancel();
      await outputs.disposeInputs();
    }
  }

  Future<AiImageGenerationResult> _run(
    Future<AiImageGenerationResult> Function() action,
  ) async {
    try {
      return await action();
    } on AiImageGenerationException catch (error, stackTrace) {
      _logGenerationError(error, stackTrace);
      rethrow;
    } catch (error, stackTrace) {
      _logGenerationError(error, stackTrace);
      throw switch (error) {
        VideoException(:final messageKey, :final detail)
            when messageKey != null =>
          AiImageGenerationException(
            tr(messageKey),
            debugMessage: detail ?? error.toString(),
          ),
        DioException() => imageExceptionFromDio(error, providerId: _config.id),
        UnsupportedError() => AiImageGenerationException(
          error.message ?? '当前模型不支持生图。',
        ),
        SocketException() ||
        HandshakeException() ||
        http.ClientException() ||
        TimeoutException() => AiImageGenerationException(
          '无法连接到图片生成服务，请检查网络或服务地址。',
          debugMessage: '$error',
        ),
        _ => AiImageGenerationException(
          '图片生成失败，请稍后重试。',
          debugMessage: '$error',
        ),
      };
    }
  }

  void _logGenerationError(Object error, StackTrace stackTrace) {
    writeImageLog(
      '[AiImageGeneration] provider=${_config.id} model=$_model '
      'baseUrl=${_config.effectiveBaseUrl} error=$error',
    );
    if (error is DioException) {
      writeImageLog(
        '[AiImageGeneration] dio type=${error.type} '
        'status=${error.response?.statusCode} '
        'uri=${safeImageUriForLog(error.requestOptions.uri)}',
      );
      final responseData = error.response?.data;
      if (responseData != null) {
        writeImageLog(
          '[AiImageGeneration] response=${safeImageSerializeForLog(responseData)}',
        );
      }
    } else if (error is AiImageGenerationException &&
        error.debugMessage != null &&
        error.debugMessage!.isNotEmpty) {
      writeImageLog('[AiImageGeneration] detail=${error.debugMessage}');
    }
    // 已分类的业务失败（402/鉴权/限流等）堆栈没有排查价值，只保留摘要。
    final knownCode = error is AiImageGenerationException ? error.code : null;
    if (knownCode == null) {
      writeImageLog(stackTrace.toString());
    }
  }
}

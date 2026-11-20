// 职责: AI 图片生成 handler — GenerateAvatar/GeneratePhoto 的处理逻辑（slash 命令 / UI 按钮驱动）。
// 关联文件:
//   lib/shared/agent/tools.dart
//   lib/shared/services/ai/image.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md
part of 'tools.dart';

mixin _AiToolManagerImageMixin on _AiToolManagerBase {
  Future<Map<String, dynamic>> _handleGenerateAvatar(
    Map<String, dynamic> input, {
    String? referenceImagePath,
  }) async {
    if (imageGenerationCallback == null) {
      return {
        'success': false,
        'error': tr(LocaleKeys.aiNoImageModelConfigured),
        '_noImageModel': true,
        'error_code': ToolErrorCode.unavailable.name,
      };
    }
    final prompt = _parseStringArgument(input['prompt']);
    if (prompt.isEmpty) {
      return {
        'success': false,
        'error': tr(LocaleKeys.aiImagePromptEmpty),
        'error_code': ToolErrorCode.invalid_argument.name,
      };
    }
    final characterId = _parseStringArgument(input['character_id']);
    final imagePath = referenceImagePath ?? '';
    try {
      final result = imagePath.isNotEmpty
          ? await _handleGenerateAvatarFromSource(prompt, imagePath: imagePath)
          : await imageGenerationCallback!(
              prompt,
              options: const ImageInvocationOptions(preferredRatio: '1:1'),
            );
      if (result.assetId == null || result.assetId!.isEmpty) {
        throw StateError('Image callback returned no registered asset ID');
      }
      return {
        'success': true,
        'asset_id': result.assetId,
        'local_path':
            RevericPaths.toRelative(result.localFilePath) ??
            result.localFilePath!,
        'character_id': characterId,
      };
    } catch (error, stackTrace) {
      return _imageFailure(
        operation:
            'GenerateAvatar characterId=$characterId '
            'hasReference=${imagePath.isNotEmpty}',
        error: error,
        stackTrace: stackTrace,
        userMessage: tr(LocaleKeys.aiAvatarGenRetry),
      );
    }
  }

  Future<AiImageGenerationResult> _handleGenerateAvatarFromSource(
    String prompt, {
    required String imagePath,
  }) async {
    if (imageEditCallback == null) {
      throw AiImageGenerationException(tr(LocaleKeys.aiImageEditUnavailable));
    }
    if (imagePath.isEmpty) {
      throw AiImageGenerationException(tr(LocaleKeys.aiImagePathEmpty));
    }
    return imageEditCallback!(
      prompt,
      imageData: imagePath,
      options: const ImageInvocationOptions(preferredRatio: '1:1'),
    );
  }

  Future<Map<String, dynamic>> _handleGeneratePhoto(
    Map<String, dynamic> input, {
    String? referenceImagePath,
  }) async {
    if (imageGenerationCallback == null) {
      return {
        'success': false,
        'error': tr(LocaleKeys.aiNoImageModelConfigured),
        '_noImageModel': true,
        'error_code': ToolErrorCode.unavailable.name,
      };
    }
    final prompt = _parseStringArgument(input['prompt']);
    if (prompt.isEmpty) {
      return {
        'success': false,
        'error': tr(LocaleKeys.aiImagePromptEmpty),
        'error_code': ToolErrorCode.invalid_argument.name,
      };
    }
    final characterId = _parseStringArgument(input['character_id']);
    final itemId = _parseStringArgument(input['item_id']);
    final imagePath = referenceImagePath ?? '';
    try {
      final result = imagePath.isNotEmpty
          ? await _handleGeneratePhotoFromSource(prompt, imagePath: imagePath)
          : await imageGenerationCallback!(
              prompt,
              options: const ImageInvocationOptions(preferredRatio: '9:16'),
            );
      if (result.assetId == null || result.assetId!.isEmpty) {
        throw StateError('Image callback returned no registered asset ID');
      }
      return {
        'success': true,
        'asset_id': result.assetId,
        'local_path':
            RevericPaths.toRelative(result.localFilePath) ??
            result.localFilePath!,
        if (characterId.isNotEmpty) 'character_id': characterId,
        if (itemId.isNotEmpty) 'item_id': itemId,
      };
    } catch (error, stackTrace) {
      return _imageFailure(
        operation:
            'GeneratePhoto characterId=$characterId itemId=$itemId '
            'hasReference=${imagePath.isNotEmpty}',
        error: error,
        stackTrace: stackTrace,
        userMessage: tr(LocaleKeys.aiPhotoGenRetry),
      );
    }
  }

  Map<String, dynamic> _imageFailure({
    required String operation,
    required Object error,
    required StackTrace stackTrace,
    required String userMessage,
  }) {
    final detail = safeMediaDiagnostic(
      error is AiImageGenerationException
          ? error.debugMessage ?? error.userMessage
          : error,
      '',
    );
    final type = safeErrorTypeName(error);
    final imageCode = error is AiImageGenerationException ? error.code : null;
    _log.error(
      '$operation failed workId=$workId '
      'callId=${_activeRunCallId ?? _currentToolExecutionContext?.approvalHostCallId} '
      'exceptionType=$type imageErrorCode=${imageCode?.name}',
      error: detail,
      stackTrace: stackTrace,
    );
    return {
      'success': false,
      'error': error is AiImageGenerationException
          ? error.userMessage
          : userMessage,
      'error_code': ToolErrorCode.internal.name,
      'exception_type': type,
      'exception_message': detail,
      'stack_top': sanitizeStackTop(stackTrace),
      if (imageCode != null) 'image_error_code': imageCode.name,
    };
  }

  Future<AiImageGenerationResult> _handleGeneratePhotoFromSource(
    String prompt, {
    required String imagePath,
  }) async {
    if (imageEditCallback == null) {
      throw AiImageGenerationException(tr(LocaleKeys.aiImageEditUnavailable));
    }
    if (imagePath.isEmpty) {
      throw AiImageGenerationException(tr(LocaleKeys.aiImagePathEmpty));
    }
    return imageEditCallback!(
      prompt,
      imageData: imagePath,
      options: const ImageInvocationOptions(preferredRatio: '9:16'),
    );
  }
}

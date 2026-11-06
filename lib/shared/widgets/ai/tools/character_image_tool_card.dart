// 职责: GenerateAvatar/GeneratePhoto 工具卡片 — 展示生成状态、预览，提供「设为头像」/「添加照片」操作按钮。
// 关联文件:
//   lib/shared/models/ai_message_block.dart
//   lib/shared/services/ai/tools_image.dart
//   lib/shared/widgets/ai/chat/chat_message_view.dart
//   lib/shared/utils/storage_paths.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/en/tool.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/zh-CN/tool.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:reveric/shared/components/reveric_spinner.dart';
import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/ai_message_block.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

class AiCharacterImageToolCard extends StatefulWidget {
  const AiCharacterImageToolCard({
    super.key,
    required this.block,
    this.onSetAsAvatar,
    this.onAddPhoto,
    this.onConfigureImageModel,
  });

  final AiImageBlock block;

  /// Receives the registered image asset ID.
  final Future<void> Function(String assetId)? onSetAsAvatar;
  final Future<void> Function(String assetId)? onAddPhoto;
  final VoidCallback? onConfigureImageModel;

  @override
  State<AiCharacterImageToolCard> createState() =>
      _AiCharacterImageToolCardState();
}

class _AiCharacterImageToolCardState extends State<AiCharacterImageToolCard> {
  bool _applying = false;
  bool? _expandedOverride;
  File? _localImageFile;

  AiImageBlock get block => widget.block;

  bool get _isAvatarTool => block.toolName == 'GenerateAvatar';

  bool get _defaultExpanded => true;

  bool get _isExpanded => _expandedOverride ?? _defaultExpanded;

  bool get _hasRenderableImage =>
      _localImageFile != null ||
      block.imageBase64 != null ||
      block.imageUrl != null;

  bool get _canToggle =>
      _hasRenderableImage || block.status != AiImageStatus.generating;

  bool get _canApplyAction =>
      block.status == AiImageStatus.success &&
      block.assetId != null &&
      block.assetId!.isNotEmpty &&
      (_isAvatarTool
          ? widget.onSetAsAvatar != null
          : widget.onAddPhoto != null);

  @override
  void initState() {
    super.initState();
    _localImageFile = _resolveLocalImageFile(block.localFilePath);
  }

  @override
  void didUpdateWidget(AiCharacterImageToolCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.block.localFilePath != block.localFilePath) {
      _localImageFile = _resolveLocalImageFile(block.localFilePath);
    }
  }

  void _toggleExpanded() {
    if (!_canToggle) {
      return;
    }
    setState(() {
      _expandedOverride = !_isExpanded;
    });
  }

  String get _toolTitle {
    if (_isAvatarTool) {
      return context.t(LocaleKeys.toolNameGenerateAvatar);
    }
    return context.t(LocaleKeys.toolNameGeneratePhoto);
  }

  String get _applyLabel {
    if (_isAvatarTool) {
      return context.t(LocaleKeys.workspaceCharacterSetAsAvatar);
    }
    return context.t(LocaleKeys.workspaceCharacterAddPhoto);
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final status = block.status;
    final expanded = _isExpanded;

    return Container(
      margin: const EdgeInsets.only(bottom: RevericSpacing.sm),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(RevericRadius.large),
            onTap: _canToggle ? _toggleExpanded : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.md,
                vertical: RevericSpacing.sm,
              ),
              child: Row(
                children: [
                  _statusIcon(colors, status),
                  const SizedBox(width: RevericSpacing.sm),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            _toolTitle,
                            style: typo.uiSemibold.copyWith(
                              color: colors.textPrimary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: RevericSpacing.xs),
                        _statusBadge(context, colors, typo, status),
                      ],
                    ),
                  ),
                  if (_canToggle)
                    RevericIcon(
                      expanded
                          ? RevericIcons.expand_less_rounded
                          : RevericIcons.expand_more_rounded,
                      size: 18,
                      color: colors.textMuted,
                    ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            if (_hasRenderableImage) _buildImageArea(colors),
            if (status == AiImageStatus.generating && !_hasRenderableImage)
              _buildPromptPreview(colors, typo),
            if (status == AiImageStatus.error && block.errorMessage != null)
              _buildErrorMessage(colors, typo),
            if (_canApplyAction) _buildApplyAction(context, colors, typo),
          ],
        ],
      ),
    );
  }

  Widget _buildPromptPreview(RevericColors colors, RevericTypography typo) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.md,
        0,
        RevericSpacing.md,
        RevericSpacing.md,
      ),
      child: Text(
        block.prompt,
        style: typo.uiSmall.copyWith(
          color: colors.textSubtle,
          fontStyle: FontStyle.italic,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildErrorMessage(RevericColors colors, RevericTypography typo) {
    final hasConfigureAction = widget.onConfigureImageModel != null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.md,
        0,
        RevericSpacing.md,
        RevericSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(RevericSpacing.sm),
            decoration: BoxDecoration(
              color: colors.deletionBg,
              borderRadius: BorderRadius.circular(RevericRadius.medium),
            ),
            child: Text(
              block.errorMessage!,
              style: typo.uiSmall.copyWith(color: colors.deletionBorder),
            ),
          ),
          if (hasConfigureAction) ...[
            const SizedBox(height: RevericSpacing.sm),
            OutlinedButton.icon(
              onPressed: widget.onConfigureImageModel,
              icon: const RevericIcon(RevericIcons.settings_outlined, size: 14),
              label: Text(context.t(LocaleKeys.aiConfigureImageModel)),
              style: OutlinedButton.styleFrom(
                foregroundColor: colors.accent,
                side: BorderSide(color: colors.accent),
                minimumSize: const Size(0, RevericSizes.buttonHeightSm),
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.md,
                ),
                textStyle: typo.uiSmall,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusIcon(RevericColors colors, AiImageStatus status) {
    return switch (status) {
      AiImageStatus.generating => SizedBox(
        width: 14,
        height: 14,
        child: RevericSpinner(strokeWidth: 2, color: colors.accent),
      ),
      AiImageStatus.success => RevericIcon(
        RevericIcons.check_circle_rounded,
        size: 16,
        color: colors.additionBorder,
      ),
      AiImageStatus.error => RevericIcon(
        RevericIcons.error_outline_rounded,
        size: 16,
        color: colors.deletionBorder,
      ),
    };
  }

  Widget _statusBadge(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo,
    AiImageStatus status,
  ) {
    final (label, color) = switch (status) {
      AiImageStatus.generating => (
        context.t(LocaleKeys.toolRunning),
        colors.accent,
      ),
      AiImageStatus.success => (
        context.t(LocaleKeys.toolSuccess),
        colors.additionBorder,
      ),
      AiImageStatus.error => (
        context.t(LocaleKeys.toolError),
        colors.deletionBorder,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.xs,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(RevericRadius.pill),
      ),
      child: Text(
        label,
        style: typo.uiSmall.copyWith(color: color, fontSize: 10),
      ),
    );
  }

  Widget _buildApplyAction(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.md,
        0,
        RevericSpacing.md,
        RevericSpacing.md,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          OutlinedButton.icon(
            onPressed: _applying
                ? null
                : () async {
                    final callback = _isAvatarTool
                        ? widget.onSetAsAvatar
                        : widget.onAddPhoto;
                    if (callback == null) {
                      return;
                    }
                    setState(() => _applying = true);
                    try {
                      await callback(block.assetId!);
                    } finally {
                      if (mounted) {
                        setState(() => _applying = false);
                      }
                    }
                  },
            icon: _applying
                ? SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(colors.accent),
                    ),
                  )
                : RevericIcon(
                    _isAvatarTool
                        ? RevericIcons.person_outline
                        : RevericIcons.add,
                    size: 16,
                  ),
            label: Text(_applyLabel),
            style: OutlinedButton.styleFrom(
              foregroundColor: colors.accent,
              side: BorderSide(color: colors.accent),
              minimumSize: const Size(0, RevericSizes.buttonHeightSm),
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.md,
              ),
              textStyle: typo.uiSmall,
            ),
          ),
        ],
      ),
    );
  }

  ImageProvider? get _imageProvider {
    final file = _localImageFile;
    if (file != null) {
      return FileImage(file);
    }
    final imageBase64 = block.imageBase64;
    if (imageBase64 != null) {
      try {
        return MemoryImage(base64Decode(imageBase64));
      } on FormatException {
        return null;
      }
    }
    final imageUrl = block.imageUrl;
    if (imageUrl != null) {
      return NetworkImage(imageUrl);
    }
    return null;
  }

  Widget _buildImageArea(RevericColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.md,
        0,
        RevericSpacing.md,
        RevericSpacing.md,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(RevericRadius.medium),
            child: ColoredBox(
              color: colors.surfaceDim,
              child: _buildImage(colors),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImage(RevericColors colors) {
    final provider = _imageProvider;
    if (provider == null) {
      return _buildImagePlaceholder(colors);
    }

    return Image(
      image: provider,
      fit: BoxFit.contain,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (!wasSynchronouslyLoaded && frame == null) {
          return _buildLoadingPlaceholder(colors, null);
        }
        if (wasSynchronouslyLoaded) {
          return child;
        }
        return AnimatedOpacity(
          duration: const Duration(milliseconds: 250),
          opacity: 1,
          curve: Curves.linearToEaseOut,
          child: child,
        );
      },
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) {
          return child;
        }
        return _buildLoadingPlaceholder(colors, loadingProgress);
      },
      errorBuilder: (_, _, _) => _buildImagePlaceholder(colors),
    );
  }

  Widget _buildLoadingPlaceholder(
    RevericColors colors,
    ImageChunkEvent? loadingProgress,
  ) {
    final value = loadingProgress?.expectedTotalBytes != null
        ? loadingProgress!.cumulativeBytesLoaded /
              loadingProgress.expectedTotalBytes!
        : null;
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: Container(
        color: colors.surfaceDim,
        alignment: Alignment.center,
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            strokeCap: StrokeCap.round,
            valueColor: AlwaysStoppedAnimation(colors.textSubtle),
            value: value,
          ),
        ),
      ),
    );
  }

  Widget _buildImagePlaceholder(RevericColors colors) {
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: Container(
        color: colors.surfaceDim,
        child: Center(
          child: RevericIcon(
            RevericIcons.broken_image_outlined,
            color: colors.textSubtle,
            size: 32,
          ),
        ),
      ),
    );
  }

  File? _resolveLocalImageFile(String? path) {
    final resolved = RevericPaths.resolveStored(path);
    return resolved == null ? null : File(resolved);
  }
}

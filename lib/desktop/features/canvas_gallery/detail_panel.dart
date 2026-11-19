// 职责: 画布画廊详情页的只读对话浮窗、只读输入区、选中节点操作条与只读生成配置浮层。
// 关联文件:
//   lib/desktop/features/canvas_gallery/detail.dart
//   lib/desktop/features/canvas_gallery/gallery_frame.dart
//   lib/desktop/widgets/ai/chat/header.dart
//   lib/desktop/widgets/ai/chat/composer.dart
//   lib/desktop/features/production/composer_toolbar.dart
//   lib/desktop/features/production/input_preview.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/hooks.md
//   .agents/rules/i18n.md
//   .agents/rules/icons.md
//   .agents/rules/widget-decomposition.md

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_button.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/audio/settings.dart';
import '../../../shared/models/video/request.dart';
import '../../../shared/providers/ai_providers.dart'
    show AiChatRuntimeState, AiChatSessionState;
import '../../../shared/services/production/canvas_package.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/utils/image_clipboard.dart';
import '../../../shared/widgets/ai/chat/chat_message_view.dart';
import '../../../shared/widgets/ai/chat/ui_message.dart';
import '../../../shared/widgets/app_background.dart';
import '../../widgets/ai/chat/header.dart';
import '../../widgets/ai/chat/session_switcher.dart';
import '../canvas/widgets/glass.dart';
import '../editing/canvas_shell.dart' show CanvasEditingScope;
import '../production/composer_toolbar.dart';
import '../production/editing_node.dart' show previewProductionEditing;
import '../production/input_preview.dart';
import '../production/popover.dart';
import '../production/prompt_controller.dart';
import '../production/prompt_field.dart';
import '../production/spec_panel.dart';
import '../production/style_button.dart';
import '../production/support.dart';
import '../production/view/panorama_actions.dart';
import 'gallery_frame.dart';

/// 复用普通画布聊天外观的只读对话面板，放进 `FloatingAiChat(readOnly: true)`。
/// 底部保留与 `ChatComposer` 相同的输入区，但不连接会话，不能输入或发送。
class GalleryFloatingChatPanel extends HookConsumerWidget {
  const GalleryFloatingChatPanel({
    super.key,
    required this.conversations,
    required this.onClose,
  });

  final List<ProductionCanvasPackageConversation> conversations;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final appBackgroundActive = ref.watch(appBackgroundActiveProvider);
    final selectedId = useState<String?>(conversations.firstOrNull?.summary.id);

    useEffect(() {
      final ids = {for (final c in conversations) c.summary.id};
      if (selectedId.value == null || !ids.contains(selectedId.value)) {
        selectedId.value = conversations.firstOrNull?.summary.id;
      }
      return null;
    }, [conversations]);

    final active =
        conversations
            .where((c) => c.summary.id == selectedId.value)
            .firstOrNull ??
        conversations.first;
    final summary = active.summary;
    final messages = groupMessagesForUi(active.messages);
    final switcherItems = [
      for (final c in conversations)
        ReadOnlyChatSessionItem(
          id: c.summary.id,
          title: c.summary.title,
          updatedAt: c.summary.updatedAt,
          subtitle: [
            galleryDate(context, c.summary.updatedAt),
            context.t(
              LocaleKeys.productionGalleryConversationContents,
              namedArgs: {
                'messages': '${c.summary.messageCount}',
                'files': '${c.summary.fileCount}',
              },
            ),
          ].join(' · '),
        ),
    ];

    return Container(
      color: appChromeBackgroundColor(
        colors,
        appBackgroundActive,
        colors.surfaceContainerHigh,
      ),
      child: Column(
        children: [
          ChatHeader(
            sessionState: AiChatSessionState(
              sessionId: summary.id,
              title: summary.title,
              model: summary.model,
              agentSlug: summary.agentSlug,
            ),
            runtimeState: const AiChatRuntimeState(),
            readOnly: true,
            readOnlySessions: switcherItems,
            activeSessionId: summary.id,
            onSelectSession: (id) async {
              if (id != null) {
                selectedId.value = id;
              }
            },
            onClose: onClose,
            avoidWindowCaption: false,
            floating: true,
          ),
          Divider(height: 1, color: colors.border),
          Expanded(
            child: ListView.builder(
              key: ValueKey(summary.id),
              padding: const EdgeInsets.only(
                top: RevericSpacing.x2l,
                bottom: RevericSpacing.lg,
              ),
              itemCount: messages.length,
              itemBuilder: (context, index) => ChatMessageView(
                message: messages[index],
                activeSessionId: null,
                readOnly: true,
              ),
            ),
          ),
          _GalleryReadOnlyComposer(
            model: summary.model,
            appBackgroundActive: appBackgroundActive,
          ),
        ],
      ),
    );
  }
}

/// 画廊只读对话的输入区。外观对齐 `ChatComposer`，没有会话控制器，因此不接收输入。
class _GalleryReadOnlyComposer extends StatelessWidget {
  const _GalleryReadOnlyComposer({
    required this.model,
    required this.appBackgroundActive,
  });

  final String? model;
  final bool appBackgroundActive;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final modelName = model?.trim();
    final showModel = modelName != null && modelName.isNotEmpty;
    final composerInputColor = appElevatedBackgroundColor(
      colors,
      appBackgroundActive,
      colors.surface,
    );

    return ExcludeFocus(
      child: Container(
        key: const Key('gallery-read-only-composer'),
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(
          RevericSpacing.x2l,
          RevericSpacing.sm,
          RevericSpacing.x2l,
          RevericSpacing.x2l,
        ),
        decoration: BoxDecoration(
          color: appBackgroundActive
              ? null
              : colors.surfaceContainerHigh.withValues(alpha: 0.92),
          border: appBackgroundActive
              ? Border(top: BorderSide(color: colors.border))
              : null,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: appBackgroundActive ? composerInputColor : colors.surface,
            borderRadius: BorderRadius.circular(RevericRadius.x2l),
            border: Border.all(color: colors.borderSubtle),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  RevericSpacing.lg,
                  RevericSpacing.md,
                  RevericSpacing.lg,
                  0,
                ),
                child: OutlinedButton.icon(
                  onPressed: null,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, RevericSizes.buttonHeightSm),
                    padding: const EdgeInsets.symmetric(
                      horizontal: RevericSizes.buttonPaddingHSm,
                    ),
                    foregroundColor: colors.textMuted,
                    disabledForegroundColor: colors.textMuted,
                    side: BorderSide(color: colors.borderSubtle),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(RevericRadius.button),
                    ),
                  ),
                  icon: RevericIcon(
                    RevericIcons.attachment,
                    size: 16,
                    color: colors.textMuted,
                  ),
                  label: Text(
                    context.t(LocaleKeys.aiAttachFile),
                    style: typo.uiSmall.copyWith(color: colors.textMuted),
                  ),
                ),
              ),
              TextField(
                enabled: false,
                readOnly: true,
                showCursor: false,
                enableInteractiveSelection: false,
                canRequestFocus: false,
                minLines: 1,
                maxLines: 6,
                style: typo.ui.copyWith(color: colors.textMuted),
                decoration: InputDecoration(
                  filled: false,
                  border: InputBorder.none,
                  hintText: context.t(
                    LocaleKeys.productionGalleryComposerReadOnly,
                  ),
                  hintStyle: typo.ui.copyWith(color: colors.textMuted),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.xl,
                    vertical: RevericSpacing.lg,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  RevericSpacing.sm,
                  0,
                  RevericSpacing.sm,
                  RevericSpacing.sm,
                ),
                child: Row(
                  children: [
                    if (showModel)
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: RevericSpacing.sm,
                          ),
                          child: Row(
                            children: [
                              RevericIcon(
                                RevericIcons.auto_awesome,
                                size: 15,
                                color: colors.textMuted,
                              ),
                              const SizedBox(width: RevericSpacing.sm),
                              Flexible(
                                child: Text(
                                  modelName,
                                  style: typo.uiSmall.copyWith(
                                    color: colors.textMuted,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                    const SizedBox(width: RevericSpacing.sm),
                    IconButton(
                      onPressed: null,
                      icon: RevericIcon(
                        RevericIcons.arrow_upward_rounded,
                        color: colors.textMuted,
                        size: 18,
                      ),
                      style: IconButton.styleFrom(
                        backgroundColor: colors.textMuted.withValues(
                          alpha: 0.12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 选中节点上沿的只读毛玻璃工具条，外观与交互语义对齐 `ProductionNodeBar`。
class GallerySelectedNodeBar extends HookWidget {
  const GallerySelectedNodeBar({
    super.key,
    required this.service,
    required this.node,
    required this.clip,
    required this.onPreviewText,
    this.onOpenDirector,
  });

  final ProductionCanvasService service;
  final CanvasNode node;
  final ProductionClipRow? clip;
  final ValueChanged<CanvasNode> onPreviewText;
  final ValueChanged<CanvasNode>? onOpenDirector;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final assetId = node.isGenerationNode
        ? clip?.adoptedAssetId
        : node.type == canvasNodeTypeMedia
        ? node.mediaAssetId
        : null;
    final asset = useProductionAsset(service, assetId);

    Widget button(String icon, String label, VoidCallback? onPressed) =>
        RevericButton.text(
          icon: icon,
          label: label,
          size: RevericButtonSize.compact,
          onPressed: onPressed,
        );

    Widget separator() => Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: RevericSpacing.xxs),
      color: colors.borderSubtle,
    );

    final primaryGroup = <Widget>[];
    final copyGroup = <Widget>[];

    if (node.type == canvasNodeTypeText) {
      primaryGroup.add(
        button(
          RevericIcons.visibility_outlined,
          context.t(LocaleKeys.commonView),
          () => onPreviewText(node),
        ),
      );
      if (node.content.trim().isNotEmpty) {
        copyGroup.add(
          button(RevericIcons.copy, context.t(LocaleKeys.commonCopy), () {
            Clipboard.setData(ClipboardData(text: node.content));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.t(LocaleKeys.commonCopied))),
            );
          }),
        );
      }
    } else if (node.type == canvasNodeTypeStaging &&
        node.stagingId != null &&
        onOpenDirector != null) {
      primaryGroup.add(
        button(
          RevericIcons.cube,
          context.t(LocaleKeys.productionOpenDirector),
          () => onOpenDirector!(node),
        ),
      );
    } else if (node.type == canvasNodeTypeEditing && node.editingId != null) {
      final openEditing = CanvasEditingScope.maybeOf(context)?.open;
      if (openEditing != null) {
        primaryGroup.add(
          button(
            RevericIcons.arrow_square_out,
            context.t(LocaleKeys.commonOpen),
            () => productionRun(context, () => openEditing(node.id)),
          ),
        );
      }
      primaryGroup.add(
        button(
          RevericIcons.play_arrow,
          context.t(LocaleKeys.productionPreviewAdopted),
          () => productionRun(
            context,
            () => previewProductionEditing(context, service, node),
          ),
        ),
      );
    } else if (asset != null && asset.type != 'audio') {
      final isPanorama =
          asset.type == 'image' && node.style?['panorama'] != null;
      if (isPanorama) {
        primaryGroup.add(
          ProductionPanoramaActions(
            service: service,
            node: node,
            assetId: asset.id,
            readOnly: true,
          ),
        );
      } else {
        final isVideo = asset.type == 'video';
        primaryGroup.add(
          button(
            isVideo
                ? RevericIcons.play_arrow
                : RevericIcons.visibility_outlined,
            context.t(isVideo ? LocaleKeys.commonPlay : LocaleKeys.commonView),
            () => productionRun(
              context,
              () => previewProductionAsset(context, service, asset.id),
            ),
          ),
        );
      }
      if (asset.type == 'image' && asset.path != null) {
        copyGroup.add(
          button(
            RevericIcons.copy,
            context.t(LocaleKeys.commonCopy),
            () => productionRun(context, () async {
              await copyImageToClipboard(
                File(service.library.resolve(asset)),
                name: asset.name,
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.t(LocaleKeys.commonCopied))),
                );
              }
            }),
          ),
        );
      }
    }

    final groups = [
      if (primaryGroup.isNotEmpty) primaryGroup,
      if (copyGroup.isNotEmpty) copyGroup,
    ];
    if (groups.isEmpty) {
      return const SizedBox.shrink();
    }

    return Material(
      type: MaterialType.transparency,
      child: CanvasGlass(
        raised: true,
        padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.xs),
        child: SizedBox(
          height: 40,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < groups.length; i++) ...[
                if (i > 0) separator(),
                ...groups[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 选中生成节点下沿的只读配置浮层，复用真实画布 Composer 的玻璃外壳、参考素材条、提示词与底部规格栏。
class GalleryReadOnlyComposer extends HookWidget {
  const GalleryReadOnlyComposer({
    super.key,
    required this.service,
    required this.node,
    required this.clip,
    required this.generation,
    required this.onPreviewText,
  });

  final ProductionCanvasService service;
  final CanvasNode node;
  final ProductionClipRow? clip;
  final ProductionCanvasPackageGeneration? generation;
  final ValueChanged<CanvasNode> onPreviewText;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final expanded = useState(false);
    final copied = useState(false);

    final loadedInputs = useFuture(
      useMemoized(() => service.draftInputs(node.id), [service, node.id]),
    );
    final inputs = loadedInputs.data ?? const <ProductionInput>[];

    final promptSource = clip?.prompt ?? '';
    final prompt = useMemoized(() => ProductionPromptController(promptSource), [
      node.id,
      promptSource,
    ]);
    useEffect(() => prompt.dispose, [prompt]);

    prompt.inputIds = inputs.map((input) => input.id).toSet();
    prompt.onPreview = (inputId) => productionRun(context, () async {
      final input = inputs.where((item) => item.id == inputId).firstOrNull;
      if (input == null) {
        return;
      }
      if (input.isPrompt) {
        final textNode = await service.db.canvasDao.getNodeById(input.refId);
        if (textNode != null && context.mounted) {
          onPreviewText(textNode);
        }
        return;
      }
      final asset = await service.inputAsset(input);
      if (context.mounted) {
        await previewProductionAsset(context, service, asset.id);
      }
    });

    final isVideo = node.type == canvasNodeTypeVideo;
    final isImage = node.type == canvasNodeTypeImage;
    final isAudio = node.type == canvasNodeTypeAudio;
    final params = generation?.parameters ?? const <String, Object?>{};
    final modelName = generation?.model?.trim();
    final rawMode = params['reference_mode'] as String? ?? clip?.referenceMode;
    final videoMode = isVideo && rawMode != null
        ? VideoMode.values.where((m) => m.name == rawMode).firstOrNull
        : null;
    final ratio = (params['ratio'] as String?) ?? clip?.ratio ?? '';
    final resolution =
        (params['resolution'] as String?) ?? clip?.resolution ?? '';
    final durationMs = (params['duration_ms'] as int?) ?? clip?.durationMs;
    final generateAudio =
        (params['generate_audio'] as bool?) ?? clip?.generateAudio;
    final audioParams = isAudio
        ? audioParametersFromStyle(node.style, null, null)
        : null;
    final audioVoice = audioParams?.voice?.trim();
    final audioInstructions = audioParams?.instructions?.trim();
    final plainPrompt = prompt.plainText.trim();
    final hasPrompt = plainPrompt.isNotEmpty;

    final toolbarItems = <Widget>[
      if ((isVideo || isImage) && node.clipId != null)
        ProductionStylePill(
          service: service,
          clipId: node.clipId!,
          readOnly: true,
        ),
      if (modelName != null && modelName.isNotEmpty)
        ProductionPill(
          onTap: null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RevericIcon(
                RevericIcons.auto_awesome,
                size: 15,
                color: colors.textMuted,
              ),
              const SizedBox(width: RevericSpacing.xs),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  modelName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.uiSmall.copyWith(color: colors.textPrimary),
                ),
              ),
            ],
          ),
        ),
      if ((isVideo || isImage) && (ratio.isNotEmpty || resolution.isNotEmpty))
        ProductionPill(
          onTap: null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                [
                      if (ratio.isNotEmpty)
                        productionRatioLabel(context, ratio),
                      if (resolution.isNotEmpty)
                        productionResolutionLabel(resolution),
                    ].join(' · ') +
                    (isVideo && generateAudio != null ? ' · ' : ''),
                style: typo.uiSmall.copyWith(
                  color: colors.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (isVideo && generateAudio != null)
                Tooltip(
                  message: context.t(
                    generateAudio
                        ? LocaleKeys.productionAudioOn
                        : LocaleKeys.productionAudioOff,
                  ),
                  child: RevericIcon(
                    generateAudio
                        ? RevericIcons.speaker_high
                        : RevericIcons.speaker_slash,
                    size: 14,
                    color: generateAudio
                        ? colors.textPrimary
                        : colors.textMuted,
                  ),
                ),
            ],
          ),
        ),
      if (isVideo && durationMs != null && durationMs > 0)
        ProductionPill(
          onTap: null,
          child: Text(
            '${(durationMs / 1000).toStringAsFixed(durationMs % 1000 == 0 ? 0 : 1)}s',
            style: typo.uiSmall.copyWith(
              color: colors.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      if (videoMode != null)
        ProductionPill(
          onTap: null,
          child: Text(
            context.t(switch (videoMode) {
              VideoMode.text => LocaleKeys.productionTextVideo,
              VideoMode.first_frame => LocaleKeys.productionFirstFrame,
              VideoMode.first_last_frame => LocaleKeys.storyboardFirstLastFrame,
              VideoMode.reference => LocaleKeys.storyboardReference,
            }),
            style: typo.uiSmall.copyWith(color: colors.textPrimary),
          ),
        ),
      if (isAudio && audioVoice != null && audioVoice.isNotEmpty)
        ProductionPill(
          onTap: null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RevericIcon(
                RevericIcons.music_notes,
                size: 14,
                color: colors.textMuted,
              ),
              const SizedBox(width: RevericSpacing.xs),
              Text(
                audioVoice,
                style: typo.uiSmall.copyWith(color: colors.textPrimary),
              ),
            ],
          ),
        ),
    ];

    if (!hasPrompt &&
        inputs.isEmpty &&
        toolbarItems.isEmpty &&
        (audioInstructions == null || audioInstructions.isEmpty)) {
      return const SizedBox.shrink();
    }

    return Material(
      type: MaterialType.transparency,
      child: CanvasGlass(
        raised: true,
        radius: RevericRadius.canvasNode,
        padding: const EdgeInsets.fromLTRB(
          RevericSpacing.lg,
          RevericSpacing.lg,
          RevericSpacing.lg,
          RevericSpacing.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasPrompt)
              ProductionComposerTools(
                expanded: expanded.value,
                onExpand: () => expanded.value = !expanded.value,
                children: [
                  ProductionToolChip(
                    icon: copied.value
                        ? RevericIcons.check
                        : RevericIcons.copy_outlined,
                    label: context.t(
                      copied.value
                          ? LocaleKeys.commonCopied
                          : LocaleKeys.commonCopy,
                    ),
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: plainPrompt));
                      copied.value = true;
                      Future<void>.delayed(const Duration(seconds: 2), () {
                        if (context.mounted) {
                          copied.value = false;
                        }
                      });
                    },
                  ),
                ],
              ),
            if (inputs.isNotEmpty) ...[
              if (hasPrompt) const SizedBox(height: RevericSpacing.sm),
              Wrap(
                spacing: RevericSpacing.sm,
                runSpacing: RevericSpacing.sm,
                children: [
                  for (var i = 0; i < inputs.length; i++)
                    if (isAudio &&
                        !inputs[i].isPrompt &&
                        inputs[i].role == VideoInputRole.reference_audio)
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            context.t(
                              LocaleKeys.productionAudioReferenceLabel,
                              namedArgs: {'index': '${i + 1}'},
                            ),
                            style: typo.uiTiny.copyWith(
                              color: colors.textMuted,
                            ),
                          ),
                          ProductionInputTile(
                            service: service,
                            input: inputs[i],
                            valid: true,
                            onRole: null,
                            onMove: null,
                            onRemove: null,
                            readOnly: true,
                            onPreviewText: onPreviewText,
                          ),
                        ],
                      )
                    else
                      ProductionInputTile(
                        service: service,
                        input: inputs[i],
                        valid: true,
                        mode: videoMode,
                        middleFrameIndex: isVideo
                            ? inputs[i].middleFrameIndex(inputs)
                            : null,
                        onRole: null,
                        onMove: null,
                        onRemove: null,
                        readOnly: true,
                        onPreviewText: onPreviewText,
                      ),
                ],
              ),
            ],
            if (hasPrompt) ...[
              const SizedBox(height: RevericSpacing.sm),
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: expanded.value ? 200 : 60,
                    maxHeight: expanded.value ? 360 : 140,
                  ),
                  child: SingleChildScrollView(
                    child: ProductionPromptField(
                      controller: prompt,
                      readOnly: true,
                      footer: false,
                      maxLines: null,
                    ),
                  ),
                ),
              ),
            ],
            if (audioInstructions != null && audioInstructions.isNotEmpty) ...[
              const SizedBox(height: RevericSpacing.sm),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.md,
                  vertical: RevericSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceDim,
                  borderRadius: BorderRadius.circular(RevericRadius.large),
                ),
                child: SelectableText(
                  audioInstructions,
                  style: typo.uiSmall.copyWith(
                    color: colors.textSecondary,
                    height: 1.5,
                  ),
                ),
              ),
            ],
            if (toolbarItems.isNotEmpty) ...[
              const SizedBox(height: RevericSpacing.sm),
              ProductionComposerToolbar(children: toolbarItems),
            ],
          ],
        ),
      ),
    );
  }
}

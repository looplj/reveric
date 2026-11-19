// 职责: 以只读交互画布形式展示画廊作品，支持缩放浏览、节点预览、查看附带对话并复制到书架。
// 关联文件:
//   lib/desktop/features/canvas_gallery/gallery_frame.dart
//   lib/desktop/features/canvas_gallery/detail_panel.dart
//   lib/desktop/features/production/board.dart
//   lib/desktop/features/production/package_actions.dart
//   lib/desktop/widgets/ai/chat/floating.dart
//   lib/shared/services/canvas_gallery/orchestrator.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/desktop-window-frame.md
//   .agents/rules/hooks.md
//   .agents/rules/icons.md
//   .agents/rules/widget-decomposition.md

import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_badge.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_dialog.dart';
import '../../../shared/components/reveric_placeholder.dart';
import '../../../shared/components/reveric_surfaces.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/providers/canvas_gallery_providers.dart';
import '../../../shared/providers/production_media.dart';
import '../../../shared/services/canvas_gallery/orchestrator.dart';
import '../../../shared/services/canvas_gallery/service.dart';
import '../../../shared/services/production/canvas_package.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/md/reveric_markdown_editor.dart';
import '../../../shared/widgets/screenplay/director_host.dart';
import '../../../shared/widgets/screenplay/director_workspace_host.dart';
import '../../widgets/ai/chat/floating.dart';
import '../editing/canvas_shell.dart';
import '../editing/host.dart';
import '../editing/region.dart';
import '../production/board.dart';
import '../production/package_actions.dart';
import '../production/spec_panel.dart';
import '../production/style_button.dart';
import 'detail_panel.dart';
import 'gallery_frame.dart';

final _log = AppLogger.forModule('CanvasGalleryDetail');

class CanvasGalleryDetailPage extends HookConsumerWidget {
  const CanvasGalleryDetailPage({super.key, required this.item});

  final CanvasGalleryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(canvasGalleryServiceProvider);
    final refresh = useState(0);
    final token = useMemoized(CancelToken.new, [item.id, refresh.value]);
    useEffect(() => token.cancel, [token]);
    final request = useMemoized(() => service.detail(item.id, cancel: token), [
      service,
      item.id,
      token,
    ]);
    final detail = useFuture(request, preserveState: false);
    final cached = useState<bool?>(null);
    final probe = useMemoized(CanvasGalleryArchiveOrchestrator.new, [item.id]);
    useEffect(() {
      var active = true;
      probe
          .hasAnyReadyPackage(item.id)
          .then(
            (ready) {
              if (active && context.mounted) {
                cached.value = ready;
              }
            },
            onError: (Object error, StackTrace _) {
              _log.warning(
                'Gallery cache probe failed id=${item.id} error=$error',
              );
              if (active && context.mounted) {
                cached.value = false;
              }
            },
          );
      return () {
        active = false;
        unawaited(probe.close());
      };
    }, [probe, item.id]);

    return switch (detail) {
      AsyncSnapshot(data: final CanvasGalleryDetail data) =>
        _GalleryCanvasWorkspace(item: data),
      AsyncSnapshot(hasError: true) => GalleryFrame(
        title: item.title,
        body: Center(
          child: RevericPlaceholder.error(
            title: context.t(LocaleKeys.productionGalleryLoadFailed),
            action: RevericButton.secondary(
              label: context.t(LocaleKeys.commonRetry),
              onPressed: () => refresh.value++,
            ),
          ),
        ),
      ),
      _ => GalleryFrame(
        title: item.title,
        body: cached.value == false
            ? _GalleryOpeningStage(
                cover: item.cover,
                title: item.title,
                description: item.description,
                progressLabel: context.t(LocaleKeys.productionGalleryOpening),
                progress: null,
              )
            : const SizedBox.shrink(),
      ),
    };
  }
}

class _GalleryCanvasWorkspace extends HookConsumerWidget {
  const _GalleryCanvasWorkspace({required this.item});

  final CanvasGalleryDetail item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(canvasGalleryServiceProvider);
    final media = ref.watch(mediaServiceProvider);
    final archive = useMemoized(CanvasGalleryArchiveOrchestrator.new, [
      item.id,
    ]);
    final progress = useState<double?>(0);
    final stage = useState(CanvasGalleryLoadStage.downloading);
    final failure = useState<String?>(null);
    final copying = useState(false);
    final preview = useState<ProductionCanvasPackagePreview?>(null);
    final retryTick = useState(0);
    final cached = useState<bool?>(null);

    useEffect(() {
      var active = true;
      archive
          .hasReadyPackage(item)
          .then(
            (ready) {
              if (active && context.mounted) {
                cached.value = ready;
              }
            },
            onError: (Object error, StackTrace _) {
              _log.warning(
                'Gallery cache probe failed id=${item.id} error=$error',
              );
              if (active && context.mounted) {
                cached.value = false;
              }
            },
          );
      return () => active = false;
    }, [archive, item.id, item.version, item.size]);

    useEffect(() {
      return () => unawaited(
        archive.close().catchError((Object error, StackTrace stack) {
          _log.error('Archive cleanup failed', error: error, stackTrace: stack);
        }),
      );
    }, [archive]);

    void report(double value) {
      if (context.mounted &&
          (progress.value == null ||
              value >= 1 ||
              (value - progress.value!).abs() >= 0.01)) {
        progress.value = value;
      }
    }

    useEffect(() {
      var active = true;
      Future<void> openCanvas() async {
        failure.value = null;
        progress.value = 0;
        try {
          final opened = await archive.preview(
            service: service,
            item: item,
            media: media,
            onStage: (next) {
              if (active && context.mounted) {
                stage.value = next;
              }
            },
            onProgress: (value) {
              if (active) {
                report(value);
              }
            },
          );
          if (!active || !context.mounted) {
            return;
          }
          preview.value = opened;
          progress.value = null;
        } on CanvasGalleryFailure catch (error) {
          if (active && context.mounted && error.code != 'cancelled') {
            failure.value = switch (error.code) {
              'unsupported_package' =>
                LocaleKeys.productionGalleryImportUpgrade,
              'package_too_large' =>
                LocaleKeys.productionGalleryPackageTooLarge,
              _ => LocaleKeys.productionGalleryDownloadFailed,
            };
            progress.value = null;
          }
        } catch (error, stackTrace) {
          _log.error(
            'Gallery canvas open failed id=${item.id}',
            error: error,
            stackTrace: stackTrace,
          );
          if (active && context.mounted) {
            failure.value = LocaleKeys.productionGalleryPreviewFailed;
            progress.value = null;
          }
        }
      }

      unawaited(Future.microtask(openCanvas));
      return () => active = false;
    }, [archive, service, media, item.id, retryTick.value]);

    Future<void> copyToShelf() async {
      if (copying.value) {
        return;
      }
      copying.value = true;
      failure.value = null;
      try {
        final cacheDir =
            preview.value?.cacheDirectory ??
            await archive.prepareCache(
              service: service,
              item: item,
              media: media,
              onProgress: preview.value == null ? report : null,
            );
        if (!context.mounted) {
          return;
        }
        await importObtainedCanvasCache(context, cacheDir);
      } on CanvasGalleryFailure catch (error) {
        if (context.mounted && error.code != 'cancelled') {
          failure.value = switch (error.code) {
            'unsupported_package' => LocaleKeys.productionGalleryImportUpgrade,
            'package_too_large' => LocaleKeys.productionGalleryPackageTooLarge,
            _ => LocaleKeys.productionGalleryDownloadFailed,
          };
        }
      } catch (error, stackTrace) {
        _log.error(
          'Gallery copy failed id=${item.id}',
          error: error,
          stackTrace: stackTrace,
        );
        if (context.mounted) {
          failure.value = LocaleKeys.productionGalleryDownloadFailed;
        }
      } finally {
        if (context.mounted) {
          copying.value = false;
        }
      }
    }

    final colors = RevericTheme.colorsOf(context);
    final opened = preview.value;
    final currentProgress = progress.value;
    final progressLabel = stage.value == CanvasGalleryLoadStage.downloading
        ? context.t(LocaleKeys.productionGalleryDownloading)
        : context.t(LocaleKeys.productionGalleryOpening);

    return GalleryFrame(
      title: item.title,
      titleTrailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RevericBadge(
            label: context.t(LocaleKeys.commonReadOnly),
            color: colors.textMuted,
          ),
          if (item.pinned) ...[
            const SizedBox(width: RevericSpacing.xs),
            RevericBadge(
              label: context.t(LocaleKeys.productionGalleryPinned),
              color: colors.accent,
            ),
          ],
        ],
      ),
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (opened?.canvas case final canvasService?) ...[
            ProductionScreenplayStyle(service: canvasService, readOnly: true),
            Container(
              width: 1,
              height: RevericSpacing.x2l,
              margin: const EdgeInsets.symmetric(horizontal: RevericSpacing.sm),
              color: colors.borderSubtle,
            ),
            ProductionReadOnlySpecChip(service: canvasService),
            Container(
              width: 1,
              height: RevericSpacing.x2l,
              margin: const EdgeInsets.symmetric(horizontal: RevericSpacing.sm),
              color: colors.borderSubtle,
            ),
          ],
          RevericButton.primary(
            size: RevericButtonSize.compact,
            icon: RevericIcons.download,
            label: context.t(LocaleKeys.productionGalleryCopy),
            loading: copying.value,
            onPressed: copying.value ? null : copyToShelf,
          ),
        ],
      ),
      body: opened?.canvas != null && opened?.canvasId != null
          ? _ReadOnlyCanvasStage(preview: opened!)
          : failure.value == null && cached.value != false
          ? const SizedBox.shrink()
          : _GalleryOpeningStage(
              cover: item.cover,
              title: item.title,
              description: item.description,
              item: item,
              progressLabel: progressLabel,
              progress: failure.value == null ? currentProgress : null,
              error: failure.value == null ? null : context.t(failure.value!),
              onRetry: () => retryTick.value++,
            ),
    );
  }
}

class _ReadOnlyCanvasStage extends HookWidget {
  const _ReadOnlyCanvasStage({required this.preview});

  final ProductionCanvasPackagePreview preview;

  @override
  Widget build(BuildContext context) {
    final service = preview.canvas!;
    final canvasId = preview.canvasId!;
    final camera = useMemoized(ProductionBoardCamera.new, [service, canvasId]);
    final selectedNode = useState<CanvasNode?>(null);
    final openedEditingId = useState<String?>(null);
    final openedStagingId = useState<String?>(null);
    final hasConversations = preview.conversations.isNotEmpty;
    final chatOpen = useState(hasConversations);

    useEffect(() {
      openedEditingId.value = null;
      openedStagingId.value = null;
      return null;
    }, [service, canvasId]);

    Future<void> openEditing(String nodeId) async {
      final project = await service.requireEditingNode(nodeId);
      if (context.mounted) {
        openedStagingId.value = null;
        openedEditingId.value = project.id;
      }
    }

    void openDirector(CanvasNode node) {
      final stagingId = node.stagingId;
      if (stagingId == null) {
        return;
      }
      openedEditingId.value = null;
      openedStagingId.value = stagingId;
    }

    final selected = selectedNode.value;
    final selectedClip = useStream(
      useMemoized(
        () => selected?.clipId == null
            ? const Stream<ProductionClipRow?>.empty()
            : (service.db.select(service.db.productionClips)..where(
                    (t) =>
                        t.id.equals(selected!.clipId!) &
                        t.deletedAt.equals(notDeletedSentinel),
                  ))
                  .watchSingleOrNull(),
        [service, selected?.clipId],
      ),
    ).data;

    final selectedGeneration = selected == null
        ? null
        : preview.generationsByNodeId[selected.id];
    final subpageOpen =
        openedEditingId.value != null || openedStagingId.value != null;

    return CanvasEditingScope(
      open: openEditing,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeFocus(
            excluding: subpageOpen,
            child: TickerMode(
              enabled: !subpageOpen,
              child: Offstage(
                offstage: subpageOpen,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final panelWidth = math.max(
                      0.0,
                      math.min(
                        RevericSizes.chatPanelWidth,
                        constraints.maxWidth - RevericSpacing.x2l * 2,
                      ),
                    );
                    final trailingInset = hasConversations && chatOpen.value
                        ? panelWidth + RevericSpacing.x2l
                        : 0.0;

                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        ProductionBoard(
                          service: service,
                          canvasId: canvasId,
                          readOnly: true,
                          selected: selected?.id,
                          segments: const [],
                          segmentLabels: const {},
                          sceneLabels: const {},
                          camera: camera,
                          composerTrailingInset: trailingInset,
                          onSelect: (node) => selectedNode.value = node,
                          onClear: () => selectedNode.value = null,
                          onConnect: (_, _, _) {},
                          onOpenDirector: openDirector,
                          onPreviewText: (node) =>
                              unawaited(_showReadOnlyTextDialog(context, node)),
                          bar: selected == null
                              ? null
                              : GallerySelectedNodeBar(
                                  service: service,
                                  node: selected,
                                  clip: selectedClip,
                                  onPreviewText: (node) => unawaited(
                                    _showReadOnlyTextDialog(context, node),
                                  ),
                                  onOpenDirector: openDirector,
                                ),
                          composer:
                              selected != null && selected.isGenerationNode
                              ? GalleryReadOnlyComposer(
                                  service: service,
                                  node: selected,
                                  clip: selectedClip,
                                  generation: selectedGeneration,
                                  onPreviewText: (node) => unawaited(
                                    _showReadOnlyTextDialog(context, node),
                                  ),
                                )
                              : null,
                        ),
                        if (hasConversations)
                          Positioned.fill(
                            child: FloatingAiChat(
                              open: chatOpen.value,
                              onOpenChanged: (open) => chatOpen.value = open,
                              sessionId: null,
                              readOnly: true,
                              panel: GalleryFloatingChatPanel(
                                conversations: preview.conversations,
                                onClose: () => chatOpen.value = false,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          if (openedEditingId.value case final editingId?)
            _ReadOnlyEditingOverlay(
              key: ValueKey((service, editingId)),
              service: service,
              editingId: editingId,
              onClose: () => openedEditingId.value = null,
            ),
          if (openedStagingId.value case final stagingId?)
            _ReadOnlyDirectorOverlay(
              key: ValueKey((service, stagingId)),
              service: service,
              stagingId: stagingId,
              onClose: () => openedStagingId.value = null,
            ),
        ],
      ),
    );
  }
}

class _ReadOnlyDirectorOverlay extends HookWidget {
  const _ReadOnlyDirectorOverlay({
    super.key,
    required this.service,
    required this.stagingId,
    required this.onClose,
  });

  final ProductionCanvasService service;
  final String stagingId;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final host = useMemoized(
      () => GalleryDirectorWorkspaceHost(canvas: service, stagingId: stagingId),
      [service, stagingId],
    );
    useEffect(
      () => () {
        unawaited(host.dispose());
      },
      [host],
    );
    return ScreenplayDirectorHost.hosted(host: host, onClose: onClose);
  }
}

class _ReadOnlyEditingOverlay extends HookWidget {
  const _ReadOnlyEditingOverlay({
    super.key,
    required this.service,
    required this.editingId,
    required this.onClose,
  });

  final ProductionCanvasService service;
  final String editingId;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final host = useMemoized(() => GalleryEditingHost(service), [service]);
    useEffect(
      () => () {
        unawaited(host.dispose());
      },
      [host],
    );
    return EditingRegion.hosted(
      host: host,
      editingId: editingId,
      onClose: onClose,
    );
  }
}

class _GalleryOpeningStage extends StatelessWidget {
  const _GalleryOpeningStage({
    required this.cover,
    required this.title,
    required this.description,
    this.item,
    required this.progressLabel,
    required this.progress,
    this.error,
    this.onRetry,
  });

  final Uri cover;
  final String title;
  final String description;
  final CanvasGalleryDetail? item;
  final String progressLabel;
  final double? progress;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    String count(String key, int value) =>
        context.t(key, namedArgs: {'count': '$value'});

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(RevericSpacing.x4l),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: RevericElevatedCard(
            fallback: colors.surface,
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: GalleryCover(uri: cover),
                ),
                Padding(
                  padding: const EdgeInsets.all(RevericSpacing.x3l),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        title,
                        style: typo.heading2.copyWith(
                          fontSize: 18,
                          color: colors.textPrimary,
                        ),
                      ),
                      if (description.isNotEmpty) ...[
                        const SizedBox(height: RevericSpacing.xs),
                        Text(
                          description,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: typo.uiSmall.copyWith(
                            color: colors.textMuted,
                            height: 1.5,
                          ),
                        ),
                      ],
                      if (item case final detail?) ...[
                        const SizedBox(height: RevericSpacing.md),
                        Wrap(
                          spacing: RevericSpacing.md,
                          runSpacing: RevericSpacing.xs,
                          children: [
                            for (final meta in [
                              count(
                                LocaleKeys.productionGalleryNodeCount,
                                detail.nodeCount,
                              ),
                              count(
                                LocaleKeys.productionGalleryAssetCount,
                                detail.assetCount,
                              ),
                              if (detail.conversationCount > 0)
                                count(
                                  LocaleKeys.productionGalleryConversationCount,
                                  detail.conversationCount,
                                ),
                              gallerySize(context, detail.size),
                            ])
                              Text(
                                meta,
                                style: typo.uiTiny.copyWith(
                                  color: colors.textSubtle,
                                ),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: RevericSpacing.x2l),
                      if (error != null)
                        GalleryNoticeBanner(
                          message: error!,
                          action: onRetry == null
                              ? null
                              : RevericButton.secondary(
                                  size: RevericButtonSize.compact,
                                  label: context.t(LocaleKeys.commonRetry),
                                  onPressed: onRetry,
                                ),
                        )
                      else
                        GalleryProgressBar(
                          label: progressLabel,
                          progress: progress,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _showReadOnlyTextDialog(BuildContext context, CanvasNode node) {
  final colors = RevericTheme.colorsOf(context);
  final typo = RevericTheme.typographyOf(context);
  return showRevericDialog<void>(
    context: context,
    builder: (context) => RevericDialog.panel(
      title: Text(
        node.title.trim().isEmpty
            ? context.t(LocaleKeys.productionText)
            : node.title,
      ),
      width: 640,
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: math.min(520, MediaQuery.sizeOf(context).height * 0.65),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: RevericSpacing.xs),
          child: RevericMarkdownPreview(
            data: node.content,
            style: typo.bodySmall.copyWith(color: colors.textPrimary),
            selectable: true,
          ),
        ),
      ),
      actions: [
        RevericButton.secondary(
          label: context.t(LocaleKeys.commonClose),
          onPressed: Navigator.of(context).pop,
        ),
      ],
    ),
  );
}

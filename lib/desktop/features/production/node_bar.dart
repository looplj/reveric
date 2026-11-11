// 职责: 选中画布节点时浮在节点上方的工具条：制作状态与样片转成片、结果弹层、预览与导出、作为参考、视频处理与截帧、导演台、跳转，以及「…」里的加入资产库、Seedance 合规校验、复制与删除。
// 关联文件:
//   lib/desktop/features/production/region.dart
//   lib/desktop/features/production/board.dart
//   lib/desktop/features/storyboard/inline_editor.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md

import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'dart:io';
import 'text_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/components/reveric_popover.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_context_menu.dart';
import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/video/request.dart' show VideoInputRole;
import '../../../shared/providers/production_media.dart';
import '../../../shared/providers/video_tasks.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/services/production/video_tool_orchestrator.dart';
import '../../../shared/theme/theme.dart';
import '../asset/library_menu_item.dart';
import '../canvas/widgets/glass.dart';
import 'certification.dart';
import 'history.dart';
import 'draft_completion.dart';
import 'grid/group_bar.dart';
import 'grid/session.dart';
import 'grid/split_bar.dart';
import 'view/actions.dart';
import 'view/region.dart';
import 'view/panorama_actions.dart';
import 'inline_media.dart';
import 'trim_dialog.dart';
import 'depth_dialog.dart';
import 'editing_node.dart' show previewProductionEditing;
import '../editing/canvas_shell.dart' show CanvasEditingScope;
import 'image_history.dart';
import 'audio_history.dart';
import 'node_card.dart' show ProductionSegmentTag;
import 'popover.dart';
import 'upload.dart';
import 'subject_picker.dart';
import 'voices.dart';
import 'support.dart';

class ProductionNodeBar extends HookConsumerWidget {
  const ProductionNodeBar({
    super.key,
    required this.service,
    required this.path,
    required this.node,
    required this.clip,
    required this.segmentLabels,
    required this.onPreview,
    required this.onSource,
    required this.onToSegments,
    required this.onCopy,
    required this.onDelete,
    required this.onOpenDirector,
    required this.onSelectNode,
    required this.onExport,
    this.placeDerived,
    this.openResults = false,
    this.menuRequest,
  });
  final ProductionCanvasService service;
  final String path;
  final CanvasNode node;

  /// 视频节点对应的片段 / 视频；素材节点为 null。
  final ProductionClipRow? clip;

  /// 片段 id → 「段 x-y」，给「作为参考」列表里的下游节点打标签。
  final Map<String, String> segmentLabels;

  /// 预览采用的视频或素材本身；没有可预览的内容时为 null。
  final VoidCallback? onPreview;
  final VoidCallback? onSource;
  final VoidCallback? onToSegments;
  final VoidCallback? onCopy;
  final VoidCallback onDelete;

  /// 打开某个导演台节点对应的调度。
  final ValueChanged<CanvasNode> onOpenDirector;
  final ValueChanged<CanvasNode> onSelectNode;

  /// 导演台节点导出静帧（true）或预演（false），完成后结果节点出现在右侧。
  final Future<void> Function(bool still) onExport;

  /// 视频处理产物的落点和让位移动，由画布按实际布局计算；null 时服务层自己找空位。
  final ProductionNodePlacement? Function(
    String sourceId, {
    required bool audio,
    Size? size,
  })?
  placeDerived;

  /// 挂载时直接展开「结果」（失败提醒上的「查看原因」）。
  final bool openResults;

  /// 节点右键：在 [at]（全局坐标）打开「…」菜单；n 变化即一次新请求。
  final ({Offset at, int n})? menuRequest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final node = ProductionViewNode.maybeOf(context) ?? this.node;
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final video = node.isGenerationNode;
    final segment = clip?.sceneId != null;
    final director = node.type == canvasNodeTypeStaging;
    // 导演台节点看出边（它的导出结果），素材节点看入边（导出它的导演台）。
    final db = service.db;
    final linked =
        useStream(
          useMemoized(
            () =>
                (db.select(db.canvasEdges)..where(
                      (t) =>
                          t.type.equals(canvasEdgeTypeStagingOutput) &
                          (director
                              ? t.sourceNodeId.equals(node.id)
                              : t.targetNodeId.equals(node.id)),
                    ))
                    .watch()
                    .asyncMap((edges) async {
                      final nodes = <CanvasNode>[];
                      for (final edge in edges) {
                        final other = await db.canvasDao.getNodeById(
                          director ? edge.targetNodeId : edge.sourceNodeId,
                        );
                        if (other != null) {
                          nodes.add(other);
                        }
                      }
                      return nodes
                        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
                    }),
            [db, node.id, director],
          ),
        ).data ??
        const <CanvasNode>[];
    // 调度还没保存过就没有可导出的内容。
    final saved =
        useStream(
          useMemoized(
            () => node.stagingId == null
                ? Stream.value(false)
                : (db.select(db.videoStagings)
                        ..where((t) => t.id.equals(node.stagingId!)))
                      .watchSingleOrNull()
                      .map((row) => row?.document != null),
            [db, node.stagingId],
          ),
        ).data ??
        false;
    final exporting = useState<bool?>(null);
    Future<void> export(bool still) async {
      exporting.value = still;
      try {
        await onExport(still);
      } finally {
        if (context.mounted) {
          exporting.value = null;
        }
      }
    }

    final taskCount = useStream(
      useMemoized(
        () => node.clipId == null
            ? Stream.value(0)
            : service.library.database.generationTaskDao
                  .watchSource(
                    novelId: service.novelId,
                    sourceType: 'production_clip',
                    sourceId: node.clipId!,
                  )
                  .map((tasks) => tasks.length),
        [service, node.clipId],
      ),
    ).data;
    // 以这个节点的采用结果作为输入的下游节点。
    final uses =
        useStream(
          useMemoized(
            () => service.watchContent(node.canvasId).map((content) {
              final byId = {for (final row in content.nodes) row.id: row};
              return <(ProductionConnection, CanvasNode)>[
                for (final edge in content.edges)
                  if (edge.type == canvasEdgeTypeInput &&
                      edge.sourceNodeId == node.id &&
                      byId.containsKey(edge.targetNodeId))
                    (edge, byId[edge.targetNodeId]!),
              ];
            }),
            [service, node.id, node.canvasId],
          ),
        ).data ??
        const <(ProductionConnection, CanvasNode)>[];

    // 视频节点的采用结果或视频素材：能截帧、分离音轨、静音和裁剪。
    final sourceAsset = useProductionAsset(service, switch (node.type) {
      canvasNodeTypeVideo => clip?.adoptedAssetId,
      canvasNodeTypeMedia => node.mediaAssetId,
      _ => null,
    });
    final sourceVideo = sourceAsset?.type == 'video' ? sourceAsset : null;
    // 生成节点的采用结果或素材节点的资产：「…」里可加入或移出资产库。
    final libraryAssetId = node.isGenerationNode
        ? clip?.adoptedAssetId
        : node.type == canvasNodeTypeMedia
        ? node.mediaAssetId
        : null;
    final libraryAsset = useProductionAsset(service, libraryAssetId);
    final appDatabase = service.library.database;
    final certifyProviders = useCertificationProviders(appDatabase);
    final certifications = useCertifications(
      appDatabase,
      libraryAsset?.type == 'image' ? libraryAsset!.id : null,
    );
    final downstreamProviders = useDownstreamVideoProviders(service, node);
    // 「…」菜单；节点右键也打开同一份。
    void openMenu(Offset position) => showRevericContextMenu(
      context: context,
      position: position,
      entries: [
        if (libraryAsset != null)
          assetLibraryMenuItem(
            context,
            asset: libraryAsset,
            onToggle: () => productionRun(
              context,
              () => service.library.database.assetDao.setInLibrary(
                libraryAsset.id,
                !libraryAsset.inLibrary,
              ),
            ),
          ),
        if (libraryAsset?.type == 'image' && libraryAsset!.path != null)
          ...productionCertifyMenuItems(
            context,
            service: service,
            certification: ref.read(providerAssetServiceProvider),
            asset: libraryAsset,
            providers: certifyProviders ?? const [],
            records: certifications ?? const [],
            downstream: downstreamProviders ?? const {},
          ),
        if (onCopy != null)
          RevericMenuItem(
            icon: RevericIcons.copy,
            label: context.t(LocaleKeys.commonCopy),
            onTap: onCopy,
          ),
        RevericMenuItem(
          icon: RevericIcons.delete_outline,
          label: context.t(LocaleKeys.commonDelete),
          iconColor: colors.error,
          labelColor: colors.error,
          onTap: onDelete,
        ),
      ],
    );
    // 右键请求：等片段、资产和认证状态都读到再弹，免得菜单少项；同一请求只弹一次。
    final menuReady =
        (!node.isGenerationNode || clip != null) &&
        (libraryAssetId == null || libraryAsset != null) &&
        certifyProviders != null &&
        certifications != null &&
        downstreamProviders != null;
    final openedMenu = useRef<int?>(null);
    useEffect(() {
      final request = menuRequest;
      if (request == null || !menuReady || openedMenu.value == request.n) {
        return null;
      }
      openedMenu.value = request.n;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          openMenu(request.at);
        }
      });
      return null;
    }, [menuRequest?.n, menuReady]);
    // 探测不出来时不预先禁用，交给处理时报错。
    final hasAudio =
        useFuture(
          useMemoized(
            () => sourceVideo?.path == null
                ? null
                : service.library.probePath(sourceVideo!.path!),
            [service, sourceVideo?.path],
          ),
        ).data?.hasAudio ??
        true;
    final processing = useState(false);
    void process(
      Future<CanvasNode> Function(
        VideoToolOrchestrator tools,
        ProductionNodePlacement? Function()? place,
      )
      action, {
      bool audio = false,
    }) => productionRun(context, () async {
      processing.value = true;
      final place = placeDerived;
      try {
        await action(
          VideoToolOrchestrator(),
          place == null ? null : () => place(node.id, audio: audio),
        );
      } finally {
        if (context.mounted) {
          processing.value = false;
        }
      }
    });
    void captureFrame(VideoFramePosition position) => process(
      (tools, place) => tools.frame(service, node.id, position, place: place),
    );
    Future<void> trim() async {
      final range = await showProductionTrimDialog(
        context,
        path: sourceVideo!.path!,
      );
      if (range != null) {
        process(
          (tools, place) => tools.trim(
            service,
            node.id,
            range.start,
            range.end,
            place: place,
          ),
        );
      }
    }

    // 下拉按钮：点开在按钮下方弹出菜单。
    Widget menuButton(
      String icon,
      String label,
      List<RevericMenuItem> Function() entries,
    ) => Builder(
      builder: (context) => _BarButton(
        icon: icon,
        label: label,
        dropdown: true,
        onTap: processing.value
            ? null
            : () {
                final box = context.findRenderObject()! as RenderBox;
                showRevericContextMenu(
                  context: context,
                  position: box.localToGlobal(
                    Offset(0, box.size.height + RevericSpacing.xs),
                  ),
                  entries: entries(),
                );
              },
      ),
    );

    final image = node.type == canvasNodeTypeImage;
    final openEditing = CanvasEditingScope.maybeOf(context)?.open;
    final adopted = clip?.adoptedAssetId;
    void upload() => productionRun(
      context,
      () => uploadProductionResult(context, service, node),
    );
    void pickAdopted() => productionRun(context, () async {
      final asset = await pickProductionAsset(
        context,
        service,
        types: {node.type},
        confirmLabel: context.t(LocaleKeys.productionAdopt),
      );
      if (asset != null) {
        await service.adopt(node.id, asset.id);
      }
    });
    Widget separator() => Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: RevericSpacing.xxs),
      color: colors.borderSubtle,
    );
    Widget button(String icon, String label, VoidCallback? onPressed) =>
        RevericButton.text(
          icon: icon,
          label: label,
          size: RevericButtonSize.compact,
          onPressed: onPressed,
        );
    final split = ProductionGridSession.maybeOf(context);
    if (split?.active == true && split!.nodeId == node.id) {
      return ProductionSplitBar(
        service: service,
        node: node,
        onCreated: onSelectNode,
        place: (size) => placeDerived!(node.id, audio: false, size: size)!,
      );
    }
    if (node.type == canvasNodeTypeGroup) {
      return ProductionGroupBar(
        service: service,
        node: node,
        onCreated: onSelectNode,
        place: placeDerived == null
            ? null
            : (size) => placeDerived!(node.id, audio: false, size: size)!,
      );
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
              if (node.style?['panorama'] != null && libraryAsset != null)
                ProductionPanoramaActions(
                  service: service,
                  node: node,
                  assetId: libraryAsset.id,
                )
              else
                for (final (index, group) in [
                  // 当前内容：状态、结果和查看。
                  [
                    if (segment)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: RevericSpacing.sm,
                        ),
                        child: Text(
                          context.t(
                            clip!.adoptedAssetId == null
                                ? LocaleKeys.productionUnselected
                                : LocaleKeys.productionSelected,
                          ),
                          style: typo.uiSmallSemibold,
                        ),
                      ),
                    if (video && clip?.kind == 'video')
                      ProductionDraftBadge(service: service, clip: clip!),
                    if (video) ...[
                      RevericPopover(
                        initiallyOpen: openResults,
                        trigger: (context, open, toggle) => _BarButton(
                          icon: RevericIcons.movie_outlined,
                          label: context.t(
                            LocaleKeys.productionResults,
                            namedArgs: {'count': '${taskCount ?? 0}'},
                          ),
                          open: open,
                          onTap: toggle,
                        ),
                        panel: (_, close) => image
                            ? ProductionImageHistory(
                                service: service,
                                node: node,
                                path: path,
                                onUpload: () {
                                  close();
                                  upload();
                                },
                                onPick: () {
                                  close();
                                  pickAdopted();
                                },
                                onAdopted: close,
                              )
                            : node.type == canvasNodeTypeAudio
                            ? ProductionAudioHistory(
                                service: service,
                                node: node,
                                path: path,
                                onUpload: () {
                                  close();
                                  upload();
                                },
                                onPick: () {
                                  close();
                                  pickAdopted();
                                },
                                onAdopted: close,
                              )
                            : ProductionHistory(
                                service: service,
                                node: node,
                                onUpload: () {
                                  close();
                                  upload();
                                },
                                onPick: () {
                                  close();
                                  pickAdopted();
                                },
                                onAdopted: close,
                              ),
                      ),
                      // 图片查看大图，视频在弹窗播放；音频保留卡片内播放。
                      if (image || node.type == canvasNodeTypeVideo)
                        _BarButton(
                          icon: image
                              ? RevericIcons.visibility_outlined
                              : RevericIcons.play_arrow,
                          label: context.t(
                            image
                                ? LocaleKeys.commonView
                                : LocaleKeys.commonPlay,
                          ),
                          onTap: onPreview,
                        ),
                      if (clip?.characterId != null)
                        _BarButton(
                          icon: RevericIcons.music_notes,
                          label: context.t(LocaleKeys.productionVoices),
                          onTap: () => showProductionVoices(
                            context,
                            service,
                            clip!.characterId!,
                          ),
                        ),
                      if (clip?.hasSubject == true)
                        _BarButton(
                          icon: RevericIcons.text_snippet_outlined,
                          label: context.t(LocaleKeys.productionSubjectProfile),
                          onTap: () => productionRun(context, () async {
                            final selected = await showProductionSubjectProfile(
                              context,
                              service,
                              clip!,
                            );
                            if (selected != null) {
                              await service.adopt(node.id, selected);
                            }
                          }),
                        ),
                    ],
                    if (director)
                      button(
                        RevericIcons.cube,
                        context.t(LocaleKeys.productionOpenDirector),
                        () => onOpenDirector(node),
                      )
                    else if (node.type == canvasNodeTypeText)
                      // 文本没有媒体可播，「查看」在弹窗里放大正文。
                      button(
                        RevericIcons.visibility_outlined,
                        context.t(LocaleKeys.commonView),
                        node.content.trim().isEmpty
                            ? null
                            : () => showProductionTextView(context, node),
                      )
                    else if (node.type == canvasNodeTypeEditing) ...[
                      // 剪辑节点没有现成文件：打开进剪辑工程，预览先渲染再弹窗播放。
                      button(
                        RevericIcons.arrow_square_out,
                        context.t(LocaleKeys.commonOpen),
                        openEditing == null || node.editingId == null
                            ? null
                            : () => productionRun(
                                context,
                                () => openEditing(node.id),
                              ),
                      ),
                      button(
                        RevericIcons.play_arrow,
                        context.t(LocaleKeys.productionPreviewAdopted),
                        node.editingId == null
                            ? null
                            : () => productionRun(
                                context,
                                () => previewProductionEditing(
                                  context,
                                  service,
                                  node,
                                ),
                              ),
                      ),
                    ] else if (!video && sourceAsset?.type != 'audio')
                      button(
                        RevericIcons.play_arrow,
                        context.t(
                          node.mediaAssetId == null
                              ? LocaleKeys.productionPreviewAdopted
                              : sourceAsset?.type == 'video'
                              ? LocaleKeys.commonPlay
                              : LocaleKeys.commonView,
                        ),
                        onPreview,
                      ),
                  ],
                  // 基于当前内容再创作。
                  [
                    if (image || sourceAsset?.type == 'image')
                      ProductionViewActions(
                        onCreated: onSelectNode,
                        service: service,
                        node: node,
                        assetId: libraryAsset?.id,
                      ),
                    if (sourceVideo != null) ...[
                      menuButton(
                        RevericIcons.tune,
                        context.t(LocaleKeys.productionVideoTools),
                        () => [
                          RevericMenuItem(
                            icon: RevericIcons.speaker_slash,
                            label: context.t(LocaleKeys.productionMute),
                            tooltip: hasAudio
                                ? null
                                : context.t(LocaleKeys.productionVideoNoAudio),
                            enabled: hasAudio,
                            onTap: () => process(
                              (tools, place) =>
                                  tools.mute(service, node.id, place: place),
                            ),
                          ),
                          RevericMenuItem(
                            icon: RevericIcons.scissors_outlined,
                            label: context.t(LocaleKeys.productionTrim),
                            onTap: trim,
                          ),
                          if (Platform.isMacOS || Platform.isWindows)
                            RevericMenuItem(
                              icon: RevericIcons.layers_outlined,
                              label: context.t(
                                LocaleKeys.productionDepthCapture,
                              ),
                              onTap: () => showDepthDialog(
                                context,
                                novelId: service.novelId,
                                nodeId: node.id,
                              ),
                            ),
                        ],
                      ),
                      Tooltip(
                        message: hasAudio
                            ? ''
                            : context.t(LocaleKeys.productionVideoNoAudio),
                        child: _BarButton(
                          icon: RevericIcons.waveform,
                          label: context.t(LocaleKeys.productionSeparateAudio),
                          onTap: processing.value || !hasAudio
                              ? null
                              : () => process(
                                  (tools, place) => tools.separateAudio(
                                    service,
                                    node.id,
                                    place: place,
                                  ),
                                  audio: true,
                                ),
                        ),
                      ),
                      menuButton(
                        RevericIcons.image_outlined,
                        context.t(LocaleKeys.productionCaptureFrame),
                        () {
                          // 卡片里正在播放（或停在某处）才有「当前帧」。
                          final current = productionInlinePosition(
                            ref.read(playbackServiceProvider),
                            node.id,
                          );
                          return [
                            RevericMenuItem(
                              label: context.t(
                                LocaleKeys.productionCaptureCurrent,
                              ),
                              tooltip: current == null
                                  ? context.t(
                                      LocaleKeys.productionCaptureCurrentHint,
                                    )
                                  : null,
                              enabled: current != null,
                              onTap: () =>
                                  captureFrame((at: current, last: false)),
                            ),
                            RevericMenuItem(
                              label: context.t(
                                LocaleKeys.productionCaptureFirst,
                              ),
                              onTap: () =>
                                  captureFrame((at: null, last: false)),
                            ),
                            RevericMenuItem(
                              label: context.t(
                                LocaleKeys.productionCaptureLast,
                              ),
                              onTap: () => captureFrame((at: null, last: true)),
                            ),
                          ];
                        },
                      ),
                      if (processing.value)
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: RevericSpacing.sm,
                          ),
                          child: SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                    ],
                  ],
                  // 与其他节点、剧本的关联。
                  [
                    if (video)
                      RevericPopover(
                        trigger: (context, open, toggle) => _BarButton(
                          icon: RevericIcons.flow_arrow,
                          label: context.t(
                            LocaleKeys.productionUsedAsReference,
                            namedArgs: {'count': '${uses.length}'},
                          ),
                          open: open,
                          onTap: toggle,
                        ),
                        panel: (_, close) => ProductionPopoverPanel(
                          width: RevericSizes.productionResultsWidth,
                          maxHeight: RevericSizes.productionResultsMaxHeight,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ProductionPopoverHead(
                                title: clip?.title.isNotEmpty == true
                                    ? clip!.title
                                    : node.title,
                                detail: context.t(
                                  LocaleKeys.productionUsedAsReferenceHint,
                                ),
                              ),
                              if (uses.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: RevericSpacing.xs,
                                    vertical: RevericSpacing.md,
                                  ),
                                  child: Text(
                                    context.t(
                                      LocaleKeys.productionUsedAsReferenceEmpty,
                                    ),
                                    style: typo.uiSmall.copyWith(
                                      color: colors.textMuted,
                                    ),
                                  ),
                                ),
                              Flexible(
                                child: SingleChildScrollView(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      for (final (edge, target) in uses)
                                        ProductionPopoverItem(
                                          leading: ProductionSegmentTag(
                                            label: segmentLabels[target.clipId],
                                            image:
                                                target.type ==
                                                canvasNodeTypeImage,
                                          ),
                                          label: target.title,
                                          meta: switch (VideoInputRole.values
                                              .asNameMap()[edge.role]) {
                                            final role? => productionRole(
                                              context,
                                              role,
                                              middleFrameIndex:
                                                  edge.middleFrameIndex,
                                            ),
                                            null => null,
                                          },
                                          onTap: () {
                                            close();
                                            onSelectNode(target);
                                          },
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (director)
                      Builder(
                        builder: (context) => button(
                          RevericIcons.movie_outlined,
                          context.t(
                            LocaleKeys.productionDirectorOutputs,
                            namedArgs: {'count': '${linked.length}'},
                          ),
                          linked.isEmpty
                              ? null
                              : () {
                                  final box =
                                      context.findRenderObject()! as RenderBox;
                                  showRevericContextMenu(
                                    context: context,
                                    position: box.localToGlobal(
                                      Offset(
                                        0,
                                        box.size.height + RevericSpacing.xs,
                                      ),
                                    ),
                                    entries: [
                                      for (final output in linked.reversed)
                                        RevericMenuItem(
                                          label: output.title,
                                          onTap: () => onSelectNode(output),
                                        ),
                                    ],
                                  );
                                },
                        ),
                      ),
                    if (!director && linked.isNotEmpty)
                      button(
                        RevericIcons.cube,
                        context.t(LocaleKeys.productionOpenDirector),
                        () => onOpenDirector(linked.first),
                      ),
                    if (segment) ...[
                      _BarButton(
                        icon: RevericIcons.file_text,
                        label: context.t(LocaleKeys.storyboardSource),
                        onTap: onSource,
                      ),
                      _BarButton(
                        icon: RevericIcons.format_list_numbered,
                        label: context.t(LocaleKeys.productionToSegments),
                        onTap: onToSegments,
                      ),
                    ],
                  ],
                  // 导出产物。
                  [
                    if (video)
                      _BarButton(
                        icon: RevericIcons.download_simple,
                        label: context.t(LocaleKeys.commonExport),
                        onTap: adopted == null
                            ? null
                            : () => productionRun(
                                context,
                                () => exportProductionAsset(service, adopted),
                              ),
                      ),
                    if (director)
                      for (final still in [true, false])
                        RevericButton.text(
                          icon: still
                              ? RevericIcons.image_outlined
                              : RevericIcons.movie_outlined,
                          label: context.t(
                            still
                                ? LocaleKeys.productionExportStill
                                : LocaleKeys.productionExportMotion,
                          ),
                          size: RevericButtonSize.compact,
                          loading: exporting.value == still,
                          onPressed: saved && exporting.value == null
                              ? () => export(still)
                              : null,
                        ),
                  ],
                ].where((group) => group.isNotEmpty).indexed) ...[
                  if (index > 0) separator(),
                  ...group,
                ],
              Builder(
                builder: (context) => RevericIconButton(
                  icon: RevericIcons.more_horiz,
                  tooltip: context.t(LocaleKeys.commonMoreActions),
                  onPressed: () {
                    final box = context.findRenderObject()! as RenderBox;
                    openMenu(
                      box.localToGlobal(
                        Offset(0, box.size.height + RevericSpacing.xs),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 工具条上的图标 + 文字按钮；带弹层的按钮展开时保持 hover 底色。
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.open = false,
    this.dropdown = false,
  });
  final String icon;
  final String label;
  final VoidCallback? onTap;
  final bool open;

  /// 点开是菜单，标签后面带下拉箭头。
  final bool dropdown;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final color = onTap == null
        ? colors.textSubtle
        : open
        ? colors.textPrimary
        : colors.textSecondary;
    return ProductionPill(
      open: open,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RevericIcon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: typo.uiSmall.copyWith(
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (dropdown) ...[
            const SizedBox(width: 3),
            RevericIcon(RevericIcons.caret_down, size: 10, color: color),
          ],
        ],
      ),
    );
  }
}

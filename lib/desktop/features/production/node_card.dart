// 职责: 渲染制作画布节点：卡片即画面，类型与名称画在卡片外左上角，空画面给出上传 / 资产库入口。
// 关联文件:
//   lib/desktop/features/production/board.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/desktop/features/production/task_status.dart
//   lib/desktop/features/production/upload.dart
//   lib/shared/services/director/file_output.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/assets.json
//   assets/translations/zh-CN/assets.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md

import 'dart:io';
import 'dart:math' as math;
import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/database/app_database.dart' show AssetRow;
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
export '../../../shared/models/production/group_layout.dart'
    show productionAspect;
import '../../../shared/models/storyboard/prompt.dart';
import '../../../shared/providers/production_media.dart';
import '../../../shared/services/director/file_output.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/theme/canvas_colors.dart';
import '../../../shared/theme/theme.dart';
import '../canvas/widgets/glass.dart';
import 'task_status.dart';
export '../../../shared/services/production/derived_placement.dart'
    show productionNodeSize, productionAudioNodeSize;
import 'grid/split_overlay.dart';
import 'view/panorama_node.dart';
import 'image_node.dart';
import 'inline_media.dart';
import 'audio_node.dart';
import 'upload.dart';
import 'certification.dart';
import 'support.dart';
import 'node_title.dart';
import 'text_node.dart';
import 'editing_node.dart';

/// 节点有哪些连线口；flow 端口和卡片上的悬停提示点共用这一份判断。
/// [derived]：有来源连线的产物节点（导演台导出、视频处理结果），左侧带一个只接来源连线的入口。
({bool input, bool output}) productionNodePorts(
  CanvasNode node, {
  required bool derived,
}) => (
  input: node.isGenerationNode || derived || node.type == canvasNodeTypeGroup,
  output:
      node.isGenerationNode ||
      node.mediaAssetId != null ||
      node.type == canvasNodeTypeStaging ||
      node.type == canvasNodeTypeGroup ||
      node.type == canvasNodeTypeText,
);

/// 端口直径；端口由 flow 画在卡片左右边上。
const double productionPortSize = 12;

/// 制作画布的最大缩放；卡片里的图片按这个倍数留解码余量。
const double productionCanvasMaxZoom = 2;

/// 画布缩放低于这个值时卡片只画骨架：空画面只留类型图标，提示词和上传 / 资产按钮这么小已读不清也点不准。
const double productionCompactZoom = .2;

/// 卡片是否按骨架绘制，由 [ProductionNodeCard] 随缩放提供给画面内容。
class ProductionCardCompact extends InheritedWidget {
  const ProductionCardCompact({
    super.key,
    required this.compact,
    required super.child,
  });
  final bool compact;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ProductionCardCompact>()
          ?.compact ??
      false;

  @override
  bool updateShouldNotify(ProductionCardCompact old) => old.compact != compact;
}

/// 节点的类型与名称画在卡片外的左上方，占用卡片上沿之上的这段高度。
const double productionNodeHeaderExtent = productionCardHeaderExtent;

/// 卡片外标题按画布缩放反向放大的倍数：缩小看全局时标题仍读得出，但不超过 1.6 倍，
/// 免得压到上方的场次标题。
double productionHeaderScale(double zoom) =>
    zoom <= 0 ? 1 : (1 / zoom).clamp(1.0, 1.6);

class ProductionNodeCard extends HookWidget {
  const ProductionNodeCard({
    super.key,
    required this.service,
    required this.node,
    required this.selected,
    this.headerScale,
    this.compact,
    this.segmentLabel,
    this.fromDirector = false,
    this.derived = false,
    this.storyboardCell = false,
    this.storyboardNumber,
    this.onOpenDirector,
    this.taskActions,
    this.textTitle,
  });
  final ProductionCanvasService service;
  final CanvasNode node;
  final bool selected;

  /// 读卡片外标题的放大倍数（MobX observable，见 [productionHeaderScale]）；null 时标题不缩放。
  final double Function()? headerScale;

  /// 读卡片是否按骨架绘制（MobX observable，见 [productionCompactZoom]）；null 时总是完整绘制。
  final bool Function()? compact;

  /// 素材节点是导演台导出的结果（有 staging_output 入边）。
  final bool fromDirector;

  /// 素材节点是视频处理的产物（有 derived_output 入边）。
  final bool derived;
  final bool storyboardCell;
  final int? storyboardNumber;
  final VoidCallback? onOpenDirector;
  final ProductionTaskActions? taskActions;

  /// 卡片外标题的改名状态，由画布持有；正在改这个节点的标题时卡片收起自己的标题。
  final ProductionNodeTitle? textTitle;

  /// 片段节点的「段 x-y」；null 表示自由视频节点。
  final String? segmentLabel;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final hovered = useState(false);
    final clip = useStream(
      useMemoized(
        () => node.clipId == null
            ? const Stream<ProductionClipRow?>.empty()
            : (service.db.select(service.db.productionClips)..where(
                    (t) =>
                        t.id.equals(node.clipId!) &
                        t.deletedAt.equals(notDeletedSentinel),
                  ))
                  .watchSingleOrNull(),
        [service, node.clipId],
      ),
    ).data;
    final staging = useStream(
      useMemoized(
        () => node.stagingId == null
            ? const Stream<VideoStagingRow?>.empty()
            : (service.db.select(service.db.videoStagings)
                    ..where((t) => t.id.equals(node.stagingId!)))
                  .watchSingleOrNull(),
        [service, node.stagingId],
      ),
    ).data;
    final media = useStream(
      useMemoized(
        () => node.mediaAssetId == null
            ? const Stream<String?>.empty()
            : service.library.database.assetDao
                  .watchAssets(novelId: service.novelId)
                  .map(
                    (assets) => assets
                        .where((a) => a.id == node.mediaAssetId)
                        .firstOrNull
                        ?.type,
                  ),
        [service, node.mediaAssetId],
      ),
    ).data;
    final titleEditing = useListenableSelector(
      textTitle?.editing,
      () => textTitle?.editing.value == node.id,
    );
    final editing = useStream(
      useMemoized(
        () => node.editingId == null
            ? const Stream<VideoEditingRow?>.empty()
            : (service.db.select(service.db.videoEditings)..where(
                    (t) =>
                        t.id.equals(node.editingId!) &
                        t.deletedAt.equals(notDeletedSentinel),
                  ))
                  .watchSingleOrNull(),
        [service, node.editingId],
      ),
    );
    final ports = productionNodePorts(node, derived: fromDirector || derived);
    final radius = BorderRadius.circular(
      storyboardCell ? 0 : RevericRadius.canvasNode,
    );
    final lit = hovered.value || selected;
    final ring = canvasNodeSelectionRing(colors, colors.accent);
    final body = switch (node.type) {
      canvasNodeTypeEditing => ProductionEditingNode(
        service: service,
        node: node,
        editing: editing,
      ),
      canvasNodeTypeText => ProductionTextNode(
        service: service,
        node: node,
        selected: selected,
        title: textTitle,
      ),
      canvasNodeTypeAudio => ProductionAudioNode(
        service: service,
        node: node,
        clip: clip,
        selected: selected,
        taskActions: taskActions,
      ),
      canvasNodeTypeImage => ProductionImageNode(
        selected: selected,
        service: service,
        node: node,
        clip: clip,
        taskActions: taskActions,
      ),
      canvasNodeTypeVideo => _VideoBody(
        service: service,
        node: node,
        clip: clip,
        segment: segmentLabel != null,
        selected: selected,
        taskActions: taskActions,
      ),
      canvasNodeTypeStaging => _DirectorBody(
        novelId: service.novelId,
        node: node,
        showOpen: hovered.value || selected,
        onOpen: onOpenDirector,
      ),
      _ => _MediaBody(service: service, node: node, selected: selected),
    };
    // 卡片是浮在点阵上的半透明层：悬停时底色变实、描边变亮，选中时外加强调色环，
    // 全部做成短过渡，不硬切。
    final card = MouseRegion(
      onEnter: (_) => hovered.value = true,
      onExit: (_) => hovered.value = false,
      child: AnimatedContainer(
        duration: CanvasMotion.hover,
        curve: CanvasMotion.curve,
        decoration: BoxDecoration(
          color: canvasGlassFill(colors, raised: lit),
          borderRadius: radius,
          boxShadow: [
            ...canvasGlassNodeShadows(colors, hovered: lit),
            // 选中环是状态提示，不是投影；未选中时保留透明环，过渡才连续。
            BoxShadow(
              color: ring.color.withValues(alpha: selected ? ring.color.a : 0),
              spreadRadius: ring.spreadRadius,
            ),
          ],
        ),
        // 边框画在画面之上，否则铺满的图片会把它盖住。
        foregroundDecoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(
            color: selected
                ? colors.accent
                : canvasGlassBorder(colors, strong: hovered.value),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: compact == null
              ? body
              : Observer(
                  builder: (_) =>
                      ProductionCardCompact(compact: compact!(), child: body),
                ),
        ),
      ),
    );
    // flow 节点外层不裁剪，标题和端口提示可以画在节点矩形之外；它们不接收点击，拖动仍落在卡片上。
    return ProductionGridOverlay(
      nodeId: node.id,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: card),
          if (storyboardNumber != null)
            Positioned(
              left: RevericSpacing.sm,
              top: RevericSpacing.sm,
              child: IgnorePointer(
                child: _FrameBadge(text: '$storyboardNumber'),
              ),
            ),
          if (storyboardCell && node.type == canvasNodeTypeImage)
            Positioned(
              right: RevericSpacing.sm,
              bottom: RevericSpacing.sm,
              child: IgnorePointer(
                child: _FrameBadge(
                  text: context.t(LocaleKeys.productionGroupAi),
                ),
              ),
            ),
          if (!storyboardCell)
            Positioned(
              left: RevericSpacing.xxs,
              right: 0,
              top: -productionNodeHeaderExtent,
              height: productionNodeHeaderExtent,
              child: IgnorePointer(
                child: _HeaderMotion(
                  scale: headerScale,
                  lifted: lit,
                  child: _NodeHeader(
                    node: (
                      row: editing.data == null
                          ? node
                          : node.copyWith(title: editing.data!.title),
                      mediaType: media,
                    ),
                    clip: clip,
                    staging: staging,
                    segmentLabel: segmentLabel,
                    fromDirector: fromDirector,
                    lit: lit,
                    editing: titleEditing,
                    certification: switch ((node.type, media)) {
                      (canvasNodeTypeImage, _) ||
                      (
                        canvasNodeTypeMedia,
                        'image',
                      ) => ProductionCertificationMark(
                        database: service.library.database,
                        assetId: node.mediaAssetId ?? clip?.adoptedAssetId,
                      ),
                      _ => null,
                    },
                  ),
                ),
              ),
            ),
          for (final (enabled, alignment, dx) in [
            (ports.input, Alignment.centerLeft, -productionPortSize / 2),
            (ports.output, Alignment.centerRight, productionPortSize / 2),
          ])
            if (enabled && !storyboardCell)
              Positioned.fill(
                child: IgnorePointer(
                  child: Align(
                    alignment: alignment,
                    child: Transform.translate(
                      offset: Offset(dx, 0),
                      child: AnimatedSwitcher(
                        duration: CanvasMotion.fast,
                        switchInCurve: CanvasMotion.curve,
                        switchOutCurve: CanvasMotion.curve,
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(
                            scale: Tween(
                              begin: .4,
                              end: 1.0,
                            ).animate(animation),
                            child: child,
                          ),
                        ),
                        child: lit
                            ? const _PortHint(key: ValueKey(true))
                            : const SizedBox.square(
                                key: ValueKey(false),
                                dimension: productionPortSize,
                              ),
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// 卡片外标题的动效：按画布缩放反向放大（锚在左下角，向上长），悬停或选中时轻轻上浮。
class _HeaderMotion extends StatelessWidget {
  const _HeaderMotion({
    required this.scale,
    required this.lifted,
    required this.child,
  });
  final double Function()? scale;
  final bool lifted;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    Widget scaled(double scale) => LayoutBuilder(
      builder: (context, box) => Transform.scale(
        scale: scale,
        alignment: Alignment.bottomLeft,
        // 先按放大倍数收窄再放大，省略号仍落在卡片宽度以内。
        child: Align(
          alignment: Alignment.bottomLeft,
          child: SizedBox(
            width: box.maxWidth / scale,
            height: box.maxHeight,
            child: child,
          ),
        ),
      ),
    );
    final read = scale;
    return AnimatedSlide(
      offset: Offset(0, lifted ? -.16 : 0),
      duration: CanvasMotion.hover,
      curve: CanvasMotion.curve,
      child: read == null ? child : Observer(builder: (_) => scaled(read())),
    );
  }
}

/// 悬停或选中时才露出的连线口外观；真正可拖的端口是 flow 画在同一位置的透明端口。
class _PortHint extends StatelessWidget {
  const _PortHint({super.key});
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Container(
      width: productionPortSize,
      height: productionPortSize,
      decoration: BoxDecoration(
        color: canvasGlassFill(colors, raised: true),
        shape: BoxShape.circle,
        border: Border.all(
          color: canvasGlassBorder(colors, strong: true),
          width: 1.5,
        ),
      ),
      child: Center(
        child: Container(
          width: 4,
          height: 4,
          decoration: BoxDecoration(
            color: colors.textSecondary,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

/// 卡片外左上角的标题：有名字只写名字，没有名字写类型；场内片段前面带「段 x-y」。
class _NodeHeader extends StatelessWidget {
  const _NodeHeader({
    required this.node,
    required this.clip,
    required this.staging,
    required this.segmentLabel,
    required this.fromDirector,
    required this.lit,
    this.editing = false,
    this.certification,
  });
  final ({CanvasNode row, String? mediaType}) node;

  /// 图片素材的 Seedance 合规校验标记。
  final Widget? certification;
  final ProductionClipRow? clip;
  final VideoStagingRow? staging;
  final String? segmentLabel;
  final bool fromDirector;

  /// 卡片悬停或选中时名字提亮一级。
  final bool lit;

  /// 正在改标题：输入框叠在名字原位（画布之上的浮层），这里只留类型图标。
  final bool editing;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final (icon, type) = switch (node.row.type) {
      canvasNodeTypeImage when clip?.characterId != null => (
        RevericIcons.person,
        LocaleKeys.productionCharacter,
      ),
      canvasNodeTypeImage when clip?.locationId != null => (
        RevericIcons.location_on,
        LocaleKeys.productionLocation,
      ),
      canvasNodeTypeImage when clip?.itemId != null => (
        RevericIcons.inventory_2,
        LocaleKeys.workspaceSidebarCompendium,
      ),
      canvasNodeTypeText => (RevericIcons.file_text, LocaleKeys.productionText),
      canvasNodeTypeEditing => (
        RevericIcons.movie_outlined,
        LocaleKeys.editingTitle,
      ),
      canvasNodeTypeImage => (RevericIcons.image, LocaleKeys.productionImage),
      canvasNodeTypeAudio => (RevericIcons.waveform, LocaleKeys.mediaAudio),
      canvasNodeTypeVideo when segmentLabel != null => (
        RevericIcons.movie_outlined,
        LocaleKeys.productionVideoTag,
      ),
      canvasNodeTypeVideo => (
        RevericIcons.video_camera,
        LocaleKeys.productionVideoTag,
      ),
      canvasNodeTypeStaging => (RevericIcons.cube, LocaleKeys.directorTitle),
      _ => switch ((fromDirector, node.mediaType)) {
        (true, 'video') => (
          RevericIcons.cube,
          LocaleKeys.productionDirectorMotion,
        ),
        (true, _) => (RevericIcons.cube, LocaleKeys.productionDirectorStill),
        (_, 'video') => (
          RevericIcons.movie_outlined,
          LocaleKeys.productionVideoTag,
        ),
        (_, 'audio') => (RevericIcons.waveform, LocaleKeys.mediaAudio),
        _ => (RevericIcons.image, LocaleKeys.productionImage),
      },
    };
    final name =
        (node.row.type == canvasNodeTypeStaging
                ? staging?.title ?? node.row.title
                : clip?.title ?? node.row.title)
            .trim();
    final muted = typo.uiSmall.copyWith(
      color: colors.textMuted,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Align(
      alignment: Alignment.topLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RevericIcon(icon, size: 12, color: colors.textMuted),
          const SizedBox(width: RevericSpacing.xxs),
          if (editing)
            const SizedBox.shrink()
          else ...[
            if (segmentLabel != null) ...[
              Text(segmentLabel!, maxLines: 1, style: muted),
              if (name.isNotEmpty) const SizedBox(width: RevericSpacing.xs),
            ],
            if (name.isNotEmpty)
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.uiSmall.copyWith(
                    color: lit ? colors.textPrimary : colors.textSecondary,
                  ),
                ),
              )
            else if (segmentLabel == null)
              Text(context.t(type), maxLines: 1, style: muted),
            ?certification,
          ],
        ],
      ),
    );
  }
}

class _VideoBody extends StatelessWidget {
  const _VideoBody({
    required this.service,
    required this.node,
    required this.clip,
    required this.segment,
    required this.selected,
    required this.taskActions,
  });
  final ProductionCanvasService service;
  final CanvasNode node;
  final ProductionClipRow? clip;
  final bool segment;
  final bool selected;
  final ProductionTaskActions? taskActions;
  @override
  Widget build(BuildContext context) {
    final prompt = StoryboardPrompt.parse(clip?.prompt ?? '').plainText.trim();
    return ProductionNodeFrame(
      service: service,
      node: node,
      taskActions: taskActions,
      frame: ProductionAdoptedFrame(
        service: service,
        assetId: clip?.adoptedAssetId,
        node: node,
        borderRadius: 0,
        well: true,
        playing: selected,
        emptyIcon: segment
            ? RevericIcons.movie_outlined
            : RevericIcons.video_camera,
        hint: prompt.isEmpty ? null : prompt,
      ),
    );
  }
}

/// 生成节点的卡片内容：画面铺满，任务反馈叠在画面上（生成中盖住画面，其余在左下角）。
class ProductionNodeFrame extends StatelessWidget {
  const ProductionNodeFrame({
    super.key,
    required this.service,
    required this.node,
    required this.frame,
    this.taskActions,
  });
  final ProductionCanvasService service;
  final CanvasNode node;
  final Widget frame;
  final ProductionTaskActions? taskActions;
  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        frame,
        Positioned.fill(
          child: ProductionTaskStatus(
            shots: service.shots,
            database: service.library.database,
            novelId: service.novelId,
            clipId: node.clipId!,
            actions: taskActions,
            compact: true,
            floating: true,
          ),
        ),
      ],
    );
  }
}

/// 「段 x-y」「视频」或「图片」小标签。
class ProductionSegmentTag extends StatelessWidget {
  const ProductionSegmentTag({
    super.key,
    required this.label,
    this.image = false,
  });
  final String? label;
  final bool image;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final free = label == null;
    final color = free ? colors.textSecondary : colors.accentWarm;
    return Container(
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.xs),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: free ? colors.surfaceContainerHigh : colors.selected,
        borderRadius: BorderRadius.circular(RevericRadius.small),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (image) ...[
            RevericIcon(RevericIcons.image_outlined, size: 10, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            label ??
                context.t(
                  image
                      ? LocaleKeys.productionImage
                      : LocaleKeys.productionVideoTag,
                ),
            style: typo.uiTinySemibold.copyWith(
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// 采用结果的画面；没有结果时给出「上传 / 资产库」入口（仅生成节点）。
class ProductionAdoptedFrame extends HookWidget {
  const ProductionAdoptedFrame({
    super.key,
    required this.service,
    required this.assetId,
    this.node,
    this.badge,
    this.emptyIcon,
    this.hint,
    this.borderRadius = RevericRadius.medium,
    this.well = false,
    this.playing,
  });
  final ProductionCanvasService service;

  /// 采用的结果或素材节点引用的资产；null 显示空画面。
  final String? assetId;
  final CanvasNode? node;

  /// 画布卡片里的空画面：内缩一圈画成画面槽，不铺底色，让卡片的半透明层露出来。
  final bool well;

  /// 非 null 时视频可在卡片里就地播放，值为节点是否选中（取消选中即停）；需要 [node]。
  final bool? playing;

  /// 左上角角标，比如上传或从资产库选来的结果标「导入」；null 不显示。
  final String? badge;

  /// 空画面中央的图标；null 按节点类型取图片 / 视频图标。
  final String? emptyIcon;

  /// 空画面里的提示文字，比如已写好的提示词摘要。
  final String? hint;
  final double borderRadius;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final radius = BorderRadius.circular(borderRadius);
    final filePath = useProductionAsset(service, assetId)?.path;
    if (filePath == null) {
      final empty = _EmptyFrame(
        service: service,
        node: node?.isGenerationNode == true ? node : null,
        icon:
            emptyIcon ??
            (node?.type == canvasNodeTypeImage
                ? RevericIcons.image
                : RevericIcons.movie_outlined),
        hint: hint,
      );
      if (well) {
        return ProductionNodeWell(child: empty);
      }
      return ClipRRect(
        borderRadius: radius,
        child: ColoredBox(color: colors.surfaceDim, child: empty),
      );
    }
    return ClipRRect(
      borderRadius: radius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (node?.style?['panorama'] != null &&
              productionMediaFormat(filePath)?.$1 == 'image')
            ProductionPanoramaNode(
              service: service,
              node: node!,
              path: filePath,
              selected: playing ?? false,
            )
          else if (productionMediaFormat(filePath)?.$1 == 'audio')
            _AudioBody(
              service: service,
              filePath: filePath,
              nodeId: playing == null ? null : node?.id,
              selected: playing ?? false,
            )
          else if (productionMediaFormat(filePath)?.$1 == 'video' &&
              playing != null &&
              node != null)
            ProductionInlineVideo(
              service: service,
              nodeId: node!.id,
              filePath: filePath,
              selected: playing!,
            )
          else
            ProductionAssetThumb(service: service, filePath: filePath),
          if (badge != null)
            Positioned(
              left: RevericSpacing.sm,
              top: RevericSpacing.sm,
              child: _FrameBadge(text: badge!),
            ),
          if (productionMediaFormat(filePath)?.$1 == 'video' &&
              (playing == null || node == null))
            const Center(child: ProductionPlayMark()),
        ],
      ),
    );
  }
}

/// 画布卡片里的画面槽：比卡片内缩 [RevericSpacing.xs]，圆角与卡片同心。
class ProductionNodeWell extends StatelessWidget {
  const ProductionNodeWell({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(RevericSpacing.xs),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: canvasNodeWell(RevericTheme.colorsOf(context)),
          borderRadius: BorderRadius.circular(
            RevericRadius.canvasNode - RevericSpacing.xs,
          ),
        ),
        child: child,
      ),
    );
  }
}

class _EmptyFrame extends StatelessWidget {
  const _EmptyFrame({
    required this.service,
    required this.node,
    required this.icon,
    required this.hint,
  });
  final ProductionCanvasService service;

  /// 有值时才给入口；素材缩略等只读场景传 null。
  final CanvasNode? node;
  final String icon;
  final String? hint;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final target = node;
    if (ProductionCardCompact.of(context)) {
      return Center(
        child: RevericIcon(icon, size: 22, color: colors.textSubtle),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        final width = math.max(0.0, box.maxWidth - RevericSpacing.lg * 2);
        final actions = target == null
            ? const <Widget>[]
            : [
                RevericButton.text(
                  icon: RevericIcons.upload,
                  label: context.t(LocaleKeys.commonUpload),
                  size: RevericButtonSize.compact,
                  onPressed: () => productionRun(
                    context,
                    () => uploadProductionResult(context, service, target),
                  ),
                ),
                RevericButton.text(
                  icon: RevericIcons.folder_outlined,
                  label: context.t(LocaleKeys.productionAssets),
                  size: RevericButtonSize.compact,
                  onPressed: () => productionRun(
                    context,
                    () => pickProductionResult(context, service, target),
                  ),
                ),
              ];
        // 小格子里整体等比缩小，不溢出也不折行出错。
        return Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RevericIcon(icon, size: 22, color: colors.textSubtle),
                if (hint != null && width > 0) ...[
                  const SizedBox(height: RevericSpacing.xs),
                  SizedBox(
                    width: width,
                    child: Text(
                      hint!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: typo.uiSmall.copyWith(color: colors.textMuted),
                    ),
                  ),
                ],
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: RevericSpacing.sm),
                  if (box.maxWidth < 200)
                    Column(mainAxisSize: MainAxisSize.min, children: actions)
                  else
                    Row(mainAxisSize: MainAxisSize.min, children: actions),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 视频画面中央的播放标记；[onTap] 为 null 时只是类型提示。
class ProductionPlayMark extends StatelessWidget {
  const ProductionPlayMark({super.key, this.onTap});
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final mark = Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: colors.textPrimary.withValues(alpha: .5),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: RevericIcon(
          RevericIcons.play_arrow,
          size: 13,
          color: colors.onAccent,
        ),
      ),
    );
    if (onTap == null) {
      return mark;
    }
    return Tooltip(
      message: context.t(LocaleKeys.commonPlay),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: onTap, child: mark),
      ),
    );
  }
}

class _FrameBadge extends StatelessWidget {
  const _FrameBadge({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.xs),
      decoration: BoxDecoration(
        color: colors.textPrimary.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(RevericRadius.small),
      ),
      child: Text(
        text,
        style: typo.uiTinySemibold.copyWith(color: colors.onAccent),
      ),
    );
  }
}

/// 资产缩略：图片读文件，视频和音频画类型图标占位。
class ProductionAssetThumb extends HookWidget {
  const ProductionAssetThumb({
    super.key,
    required this.service,
    this.asset,
    this.assetId,
    this.filePath,
  });
  final ProductionCanvasService service;
  final AssetRow? asset;

  /// 只有资产 id 时按 id 监听资产。
  final String? assetId;
  final String? filePath;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final watched = useProductionAsset(service, assetId);
    final path = filePath ?? asset?.path ?? watched?.path;
    final type = path == null ? null : productionMediaFormat(path)?.$1;
    final absolute = path == null ? null : service.library.resolvePath(path);
    if (absolute != null && !File(absolute).existsSync()) {
      return Tooltip(
        message: context.t(LocaleKeys.productionFileMissing),
        child: Center(
          child: RevericIcon(
            RevericIcons.broken_image_outlined,
            color: colors.error,
          ),
        ),
      );
    }
    if (type == 'image' && absolute != null) {
      // 按显示尺寸解码，不把原图整张解成纹理；留出画布最大缩放的余量，放大后仍清晰。
      return LayoutBuilder(
        builder: (context, box) {
          final ImageProvider file = FileImage(File(absolute));
          final side =
              math.max(box.maxWidth, box.maxHeight) *
              productionCanvasMaxZoom *
              MediaQuery.devicePixelRatioOf(context);
          return Image(
            image: side.isFinite && side > 0
                ? ResizeImage(
                    file,
                    width: side.ceil(),
                    height: side.ceil(),
                    policy: ResizeImagePolicy.fit,
                  )
                : file,
            fit: BoxFit.cover,
            errorBuilder: (_, error, stack) => ColoredBox(
              color: colors.surfaceDim,
              child: Center(
                child: RevericIcon(
                  RevericIcons.broken_image_outlined,
                  size: 16,
                  color: colors.error,
                ),
              ),
            ),
          );
        },
      );
    }
    // 视频没有缩略帧，和图片一样用低一级的底色 + 类型图标占位。不能借文字色当底：
    // 深色主题的 textSecondary 是浅灰，会在画布上亮出一整块。
    return ColoredBox(
      color: colors.surfaceDim,
      child: Center(
        child: RevericIcon(
          switch (type) {
            'video' => RevericIcons.movie_outlined,
            'audio' => RevericIcons.waveform,
            _ => RevericIcons.image_outlined,
          },
          size: 18,
          color: colors.textSubtle,
        ),
      ),
    );
  }
}

/// 素材节点：图片 / 视频铺满画面，视频可就地播放；音频是一条波形和时长，也可就地播放。
class _MediaBody extends HookWidget {
  const _MediaBody({
    required this.service,
    required this.node,
    required this.selected,
  });
  final ProductionCanvasService service;
  final CanvasNode node;
  final bool selected;
  @override
  Widget build(BuildContext context) {
    final result = useStream(
      useMemoized(
        () => service.library.database.assetDao
            .watchAssets(novelId: service.novelId)
            .map(
              (assets) =>
                  assets.where((a) => a.id == node.mediaAssetId).firstOrNull,
            ),
        [service, node.mediaAssetId],
      ),
    );
    final asset = result.hasError ? null : result.data;
    if (asset == null) {
      return Center(child: Text(context.t(LocaleKeys.productionFileMissing)));
    }
    if (asset.type == 'audio') {
      return _AudioBody(
        service: service,
        filePath: asset.path!,
        nodeId: node.id,
        selected: selected,
      );
    }
    if (asset.type == 'video') {
      return ProductionInlineVideo(
        service: service,
        nodeId: node.id,
        filePath: asset.path!,
        selected: selected,
      );
    }
    if (asset.type == 'image' && node.style?['panorama'] != null) {
      return ProductionPanoramaNode(
        service: service,
        node: node,
        path: asset.path!,
        selected: selected,
      );
    }
    return ProductionAssetThumb(service: service, filePath: asset.path);
  }
}

class _AudioBody extends HookConsumerWidget {
  const _AudioBody({
    required this.service,
    required this.filePath,
    this.nodeId,
    this.selected = false,
  });
  final ProductionCanvasService service;
  final String filePath;

  /// 非 null 时可在卡片里就地播放，[selected] 为 false 即停。
  final String? nodeId;
  final bool selected;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final playback = ref.watch(playbackServiceProvider);
    final metadata = useFuture(
      useMemoized(() => service.library.probePath(filePath), [
        service.library,
        filePath,
      ]),
    );
    final inline = useProductionInlinePlayback(
      context,
      playback,
      service: service,
      nodeId: nodeId,
      filePath: filePath,
      selected: selected,
    );
    final info = metadata.data;
    final spec = info == null
        ? (metadata.hasError
              ? context.t(LocaleKeys.productionMediaUnavailable)
              : '…')
        : context.t(
            LocaleKeys.productionSeconds,
            namedArgs: {
              'seconds': (info.duration.inMilliseconds / 1000).toStringAsFixed(
                1,
              ),
            },
          );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.lg),
      child: Row(
        children: [
          RevericIcon(RevericIcons.waveform, size: 22, color: colors.accent),
          const SizedBox(width: RevericSpacing.md),
          Expanded(
            child: inline.active
                ? ProductionInlineControls(
                    player: playback.player,
                    overlay: false,
                  )
                : Text(
                    spec,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.uiSmall.copyWith(color: colors.textMuted),
                  ),
          ),
          if (nodeId != null && !inline.active) ...[
            const SizedBox(width: RevericSpacing.sm),
            if (inline.opening)
              const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              ProductionPlayMark(onTap: info == null ? null : inline.start),
          ],
        ],
      ),
    );
  }
}

/// 导演台节点：画面是调度保存时渲染的预览静帧；悬停或选中时右下角给出「打开导演台」。
class _DirectorBody extends HookWidget {
  const _DirectorBody({
    required this.node,
    required this.novelId,
    required this.showOpen,
    required this.onOpen,
  });
  final CanvasNode node;
  final String novelId;
  final bool showOpen;
  final VoidCallback? onOpen;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final stagingId = node.stagingId!;
    final previewUpdate = useStream(
      useMemoized(() => DirectorFileOutput.previewUpdates(stagingId), [
        stagingId,
      ]),
    ).data;
    // 文档编辑期间保留上次生成的图片，生成完成后再刷新。
    final preview = useFuture(
      useMemoized(
        () => DirectorFileOutput.readPreview(stagingId, novelId: novelId),
        [stagingId, novelId, previewUpdate],
      ),
    ).data;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (preview == null)
          ProductionNodeWell(
            child: Center(
              child: RevericIcon(
                RevericIcons.cube,
                size: 22,
                color: colors.textSubtle,
              ),
            ),
          )
        else
          Image.memory(preview, fit: BoxFit.cover, gaplessPlayback: true),
        if (onOpen != null)
          Positioned(
            right: RevericSpacing.sm,
            bottom: RevericSpacing.sm,
            child: AnimatedSwitcher(
              duration: CanvasMotion.fast,
              switchInCurve: CanvasMotion.curve,
              child: showOpen
                  ? DecoratedBox(
                      key: const ValueKey(true),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(
                          RevericRadius.button,
                        ),
                      ),
                      child: RevericButton.secondary(
                        label: context.t(LocaleKeys.productionOpenDirector),
                        icon: RevericIcons.arrow_square_out,
                        size: RevericButtonSize.compact,
                        onPressed: onOpen,
                      ),
                    )
                  : const SizedBox.shrink(key: ValueKey(false)),
            ),
          ),
      ],
    );
  }
}

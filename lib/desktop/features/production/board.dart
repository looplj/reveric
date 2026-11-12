// 职责: 把制作画布的节点和输入连线挂到 flow 画布上，同步回库，并把工具条、输入框贴在选中节点上。
// 关联文件:
//   lib/shared/services/production/canvas_service.dart
//   lib/desktop/features/production/node_card.dart
//   lib/desktop/features/production/region.dart
//   lib/desktop/features/canvas/widgets/canvas_board.dart
//   lib/desktop/features/canvas/widgets/floating_cluster.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
//   assets/translations/en/canvas.json
//   assets/translations/zh-CN/canvas.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/performance.md

import '../../../shared/hooks/use_ai_providers.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:mobx/mobx.dart' show Computed, ObservableMap, runInAction;
import 'package:reveric/third/flow/vyuh_node_flow/lib/src/editor/element_scope.dart';
import 'package:reveric/third/flow/vyuh_node_flow/lib/src/editor/drag_session.dart';
// layer_provider / unbounded_widgets 未在库 barrel 导出，直接引 src(与 canvas_ai_focus_layer.dart 同一先例)。
import 'package:reveric/third/flow/vyuh_node_flow/lib/src/editor/unbounded_widgets.dart';
import 'package:reveric/third/flow/vyuh_node_flow/lib/src/plugins/layer_provider.dart';
import '../../../shared/components/dotted_border_box.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/video/request.dart';
import '../../../shared/models/audio/request.dart';
import '../../../shared/models/audio/channels.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/services/production/generate_orchestrator.dart';
import '../../../shared/services/production/tidy_layout.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/app_background.dart';
import '../../../third/flow/vyuh_node_flow.dart' as flow;
import '../canvas/canvas_palette.dart';
import '../canvas/widgets/floating_cluster.dart';
import '../canvas/widgets/glass.dart';
import '../canvas/widgets/zoom_control.dart';
import 'connection_flow.dart';
import 'connection_style.dart';
import '../../../shared/services/production/derived_placement.dart';
export '../../../shared/services/production/derived_placement.dart'
    show productionSceneBand, productionScenePositions;
import 'interaction.dart';
import 'grid/group_node.dart';
import 'grid/cell.dart';
import 'grid/outlet.dart';
import 'grid/group_titles.dart';
import 'grid/session.dart';
import 'node_card.dart';
import 'node_title.dart';
import 'selection_layer.dart';
import 'selection_actions.dart';
import 'view/region.dart';
import 'support.dart';
import 'history_region.dart';
import 'task_status.dart' show ProductionTaskActions;

const double _minZoom = .15;
const double _maxZoom = productionCanvasMaxZoom;
const double _zoomStep = 1.25;

/// 视频节点左侧的输入口、所有可输出节点右侧的输出口。
const _portIn = 'in';
const _portOut = 'out';

/// flow 节点只带 DB 节点 id；渲染时按 id 取最新的库内容。
typedef _BoardController = flow.NodeFlowController<String, String>;

/// 让外部读到当前镜头和布局：新建节点放在视口中心，视频处理产物按画布上的实际布局落位。
class ProductionBoardCamera {
  Offset? Function()? _center;
  ProductionNodePlacement? Function(
    String sourceId, {
    required bool audio,
    Size? size,
  })?
  _placeDerived;

  /// 视口中心对应的画布坐标（与节点 x / y 同一坐标系）；画布还没布局时为 null。
  Offset? get center => _center?.call();

  /// 源节点下一个视频处理产物的落点和让位移动，见 [productionDerivedPlacement]；
  /// 画布没挂载或源节点不在画布上时为 null，由服务层自己找空位。
  ProductionNodePlacement? placeDerived(
    String sourceId, {
    required bool audio,
    Size? size,
  }) => _placeDerived?.call(sourceId, audio: audio, size: size);
}

class ProductionBoard extends HookConsumerWidget {
  const ProductionBoard({
    super.key,
    required this.service,
    required this.canvasId,
    required this.selected,
    this.revealed,
    required this.segments,
    required this.segmentLabels,
    required this.sceneLabels,
    this.onAddSegment,
    required this.onSelect,
    this.onContextMenu,
    required this.onClear,
    this.beforeRemoveSelection,
    required this.onConnect,
    this.onDisconnect,
    this.onCreateGroupReference,
    required this.onOpenDirector,
    required this.camera,
    this.bar,
    this.composer,
    this.composerTrailingInset = 0,
    this.composerBottomInset = 0,
    this.tools,
    this.topInset = 0,
    this.controls = const [],
    this.empty,
    this.taskActions,
  });
  final ProductionCanvasService service;
  final String canvasId;
  final String? selected;

  /// 只平移到这个节点、不选中（第二栏点场次时）；[selected] 优先。
  final String? revealed;

  /// 本集片段（成片顺序），用来画场次色带。
  final List<ProductionClipRow> segments;

  /// 片段 id → 「段 x-y」。
  final Map<String, String> segmentLabels;

  /// 场次 id → 色带标题；按场次顺序，包含还没有片段的场次。
  final Map<String, String> sceneLabels;

  /// 场次色带底部的「分镜」：在这一场末尾新建片段。为 null 时不显示。
  final ValueChanged<String>? onAddSegment;
  final ValueChanged<CanvasNode> onSelect;

  /// 节点右键：节点已选中，[at] 是全局坐标。
  final void Function(CanvasNode node, Offset at)? onContextMenu;

  /// 点画布空白处。
  final VoidCallback onClear;
  final Future<bool> Function()? beforeRemoveSelection;

  /// 连线松手、且有可用用途时调用；[at] 是落点的全局坐标。
  final void Function(CanvasNode source, CanvasNode target, Offset at)
  onConnect;
  final void Function(String groupId, bool video, Offset at)?
  onCreateGroupReference;
  final Future<void> Function(String inputId, String targetNodeId)?
  onDisconnect;

  /// 导演台节点卡片上的「打开导演台」。
  final ValueChanged<CanvasNode> onOpenDirector;
  final ProductionBoardCamera camera;
  final Widget? empty;

  /// 贴在选中节点上沿的工具条。
  final Widget? bar;

  /// 贴在选中视频节点下沿的生成输入框。
  final Widget? composer;

  /// 画布右侧被浮层占住的宽度（展开的 AI 浮窗），输入框不进这块。
  final double composerTrailingInset;

  /// 画布底部浮动控件占用的高度；节点下方的输入区不压到它们上面。
  final double composerBottomInset;

  /// 左下角工具簇里夹在「适应视图」和缩放百分比之间的画布工具；右下角留给 AI 悬浮球。
  final Widget? tools;

  /// 画布上沿被悬浮工具条占住的高度，贴节点的浮层不进这块。
  final double topInset;

  /// 画布四角的其他浮动控件（已用 [Positioned] 定位）。
  final List<Widget> controls;

  /// 节点卡片上失败提醒的动作。
  final ProductionTaskActions? taskActions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ProductionHistoryScope.maybeOf(context)?.history;
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final appBackgroundActive = ref.watch(appBackgroundActiveProvider);
    final fontFamily = Theme.of(context).textTheme.bodyMedium?.fontFamily;
    // NodeFlowTheme 按引用比较；每次 build 新建会让 editor 换主题，所有节点和连线跟着重建。
    final flowTheme = useMemoized(
      () => _flowTheme(
        canvasFlowTheme(
          colors,
          typo,
          appBackgroundActive,
          fontFamily: fontFamily,
        ),
        colors,
      ),
      [colors, typo, appBackgroundActive, fontFamily],
    );
    final content = useStream(
      useMemoized(() => service.watchContent(canvasId), [service, canvasId]),
    );
    final bands = useMemoized(_BandLayer.new, const []);
    final controller = useMemoized(
      () => _BoardController(
        config: flow.NodeFlowConfig(
          minZoom: _minZoom,
          maxZoom: _maxZoom,
          showAttribution: false,
          scrollToZoom: false,
          plugins: [
            // 与构思画布同款：节点主题全透明、视觉全靠 nodeBuilder，默认 LOD
            // 缩小后关掉节点内容会让卡片整片消失，只放开 showNodeContent。
            ...flow.NodeFlowConfig.defaultPlugins().where(
              (plugin) => plugin is! flow.LodPlugin,
            ),
            flow.LodPlugin(
              minVisibility: flow.DetailVisibility.minimal.copyWith(
                showNodeContent: true,
              ),
            ),
            bands,
            ProductionGroupTitles(),
            ProductionSelectionLayer(groupBounds: bands.selectedBounds),
            ProductionConnectionFlow(colors),
          ],
        ),
      ),
      [bands],
    );
    useEffect(() => controller.dispose, [controller]);
    final textTitle = useMemoized(ProductionNodeTitle.new);
    useEffect(() => textTitle.dispose, [textTitle]);
    // 平移也会换掉 viewport 值；标题只跟放大倍数走，倍数不变时不让每张卡片的标题重建。
    final headerScale = useMemoized(
      () => Computed(
        () => productionHeaderScale(controller.viewportObservable.value.zoom),
      ),
      [controller],
    );
    final compact = useMemoized(
      () => Computed(
        () => controller.viewportObservable.value.zoom < productionCompactZoom,
      ),
      [controller],
    );

    // 场次节点不进 flow：色带图层负责绘制与拖动，已删除场次的场次节点不显示。
    final allNodes = content.data?.nodes ?? const <CanvasNode>[];
    final nodes = [
      for (final n in allNodes)
        if (n.type != canvasNodeTypeScene) n,
    ];
    final sceneNodes = [
      for (final n in allNodes)
        if (sceneLabels.containsKey(n.sceneId)) n,
    ];
    final edges = content.data?.edges ?? const <ProductionConnection>[];
    final byId = {for (final n in nodes) n.id: n};
    final membersByParent = <String, List<CanvasNode>>{};
    for (final node in nodes) {
      final parentId = node.parentId;
      if (parentId != null) {
        (membersByParent[parentId] ??= []).add(node);
      }
    }
    // 拖线时同步判断落点：视频节点的生成方式随库更新，素材类型不会变、查一次即可。
    // 片段比例同一条 stream 带出，卡片尺寸跟着画面比例走。
    final clipIds = nodes.map((n) => n.clipId).nonNulls.toList()..sort();
    final clipInfo = useStream(
      useMemoized(
        () =>
            (service.db.select(
              service.db.productionClips,
            )..where((t) => t.id.isIn(clipIds))).watch().map(
              (rows) => {
                for (final r in rows)
                  r.id: (
                    mode: VideoMode.values.byName(r.referenceMode),
                    aspect: productionAspect(r.ratio),
                    modelId: r.modelId,
                    providerId: r.providerId,
                    adoptedAssetId: r.adoptedAssetId,
                  ),
              },
            ),
        [service, clipIds.join('|')],
      ),
    ).data;
    final modes = clipInfo;
    final audioProviders = useAiProviders(service.library.database).data;
    final audioProviderTypes = {
      for (final p in audioProviders ?? []) p.id: p.type,
    };
    // 素材卡片按入库宽高布局，与 Agent 落点、分组转换共用同一尺寸来源。
    final assets =
        useStream(
          useMemoized(
            () => service.library.database.assetDao.watchAssets(
              novelId: service.novelId,
            ),
            [service],
          ),
        ).data ??
        [];
    final assetsById = {for (final asset in assets) asset.id: asset};
    Size sizeOf(CanvasNode node) {
      final clip = clipInfo == null ? null : clipInfo[node.clipId];
      final parent = byId[node.parentId];
      final layout = parent?.type == canvasNodeTypeGroup
          ? ProductionGroupLayout.fromStyle(parent!.style)
          : null;
      return productionNodeSize(
        node,
        groupCellSize: layout is StoryboardGroupLayout ? layout.cellSize : null,
        mediaType: assetsById[node.mediaAssetId]?.type,
        aspect: node.clipId != null
            ? clip?.aspect
            : productionMediaAspect(assetsById[node.mediaAssetId]?.content),
      );
    }

    // 点未选中节点的标题：先由画布完成选中（可能被未保存的编辑拦下），选中落定后再进入标题编辑。
    final titleRequest = useRef<({String id, DateTime at})?>(null);
    useEffect(() {
      final request = titleRequest.value;
      titleRequest.value = null;
      if (request == null ||
          request.id != selected ||
          DateTime.now().difference(request.at) > const Duration(seconds: 1)) {
        return null;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          textTitle.starters[request.id]?.call();
        }
      });
      return null;
    }, [selected]);
    controller.resolvePlugin<ProductionGroupTitles>()!
      ..headerScale = (() => headerScale.value)
      ..onTitleTap = ((id) => titleRequest.value = (id: id, at: DateTime.now()))
      ..labels = {
        for (final (index, group)
            in nodes.where((n) => n.type == canvasNodeTypeGroup).indexed)
          group.id:
              ProductionGroupLayout.fromStyle(group.style)
                  is StoryboardGroupLayout
              ? context.t(
                  LocaleKeys.productionGroupCount,
                  namedArgs: {
                    'title': group.title.isEmpty
                        ? context.t(LocaleKeys.productionGroupStoryboard)
                        : group.title,
                    'count': '${membersByParent[group.id]?.length ?? 0}',
                  },
                )
              : group.title.isEmpty
              ? '${context.t(LocaleKeys.productionGroupFree)} ${index + 1}'
              : group.title,
      };

    final sizeKey = nodes
        .map((n) {
          final size = sizeOf(n);
          return '${size.width}x${size.height}';
        })
        .join('|');
    final sceneKey = sceneNodes.map((n) => n.id).join('|');
    final scenePositions = useMemoized(
      () =>
          productionScenePositions([...nodes, ...sceneNodes], segments, sizeOf),
      [content.data, segments, sizeKey, sceneKey],
    );
    final latestScenePositions = useRef(scenePositions)..value = scenePositions;
    // 画布打开期间新加的场次：补上场次节点，色带随 stream 出现。
    final anchoredScenes = {for (final n in allNodes) ?n.sceneId};
    final missingScenes = [
      for (final id in sceneLabels.keys)
        if (!anchoredScenes.contains(id)) id,
    ].join('|');
    useEffect(() {
      if (content.hasData && missingScenes.isNotEmpty) {
        productionRun(context, () => service.ensureSceneNodes(canvasId));
      }
      return null;
    }, [content.hasData, missingScenes]);
    // nodeBuilder / 事件回调里按 id 取最新快照，不随 stream 重建回调。
    final latest = useRef(byId)..value = byId;
    // 选中、拖动开始和 z 序变化都会让 flow 对每个节点重跑 nodeBuilder；
    // 输入没变就交回同一个 widget，只重建真正变了的卡片。
    final nodeWidgets = useMemoized(
      () => <String, ({Object inputs, Widget widget})>{},
      [controller],
    );
    nodeWidgets.removeWhere((id, _) => !byId.containsKey(id));
    final latestOnOpenDirector = useRef(onOpenDirector)..value = onOpenDirector;
    final latestOnContextMenu = useRef(onContextMenu)..value = onContextMenu;
    final latestTaskActions = useRef(taskActions)..value = taskActions;
    final hasTaskActions = taskActions != null;
    // 上层每次 build 都会新建 taskActions；卡片只拿转发到最新值的稳定实例，缓存才能命中。
    final cardTaskActions = useMemoized(
      () => hasTaskActions
          ? ProductionTaskActions(
              openResults: (clipId) =>
                  latestTaskActions.value!.openResults(clipId),
              retrySave: (task) => latestTaskActions.value!.retrySave(task),
            )
          : null,
      [hasTaskActions],
    );
    final interaction = useMemoized(
      () => ProductionBoardInteraction(controller),
      [controller],
    );
    final sceneForClip = {
      for (final segment in segments) segment.id: ?segment.sceneId,
    };
    interaction.sceneForNode = {
      for (final node in nodes) node.id: ?sceneForClip[node.clipId],
    };
    interaction.storyboardParents = {
      for (final node in nodes)
        if (byId[node.parentId] case final parent?)
          if (parent.type == canvasNodeTypeGroup &&
              ProductionGroupLayout.fromStyle(parent.style)
                  is StoryboardGroupLayout)
            node.id: parent.id,
    };
    controller.resolvePlugin<ProductionGroupTitles>()!.titled = {
      for (final node in nodes)
        if (node.type != canvasNodeTypeGroup &&
            !interaction.storyboardParents.containsKey(node.id))
          node.id,
    };
    final edgeIds = {for (final e in edges) e.id};
    // 导演台导出结果：有 staging_output 入边的素材节点。
    final outputIds = {
      for (final e in edges)
        if (e.type == canvasEdgeTypeStagingOutput) e.targetNodeId,
    };
    // 视频处理产物：有 derived_output 入边的素材节点。
    final derivedIds = {
      for (final e in edges)
        if (e.type == canvasEdgeTypeDerivedOutput) e.targetNodeId,
    };
    final latestEdgeIds = useRef(edgeIds)..value = edgeIds;
    final latestEdges = useRef(edges)..value = edges;
    final assetTypes = {for (final asset in assets) asset.id: asset.type};
    final latestModes = useRef(modes)..value = modes;
    final latestAudioProviderTypes = useRef(audioProviderTypes)
      ..value = audioProviderTypes;
    final latestAssetTypes = useRef(assetTypes)..value = assetTypes;
    final previewing = useRef(false);
    // 点节点选中时不移动镜头；只有从外部（列表、第二栏）选中才定位。
    final tapped = useRef<String?>(null);
    final fitted = useRef(false);

    // 分组外框和成员都映射到外框 id，整组一起移动。
    Map<String, String> groupOf() => {
      for (final node in latest.value.values)
        if (node.type == canvasNodeTypeGroup)
          node.id: node.id
        else if (latest.value[node.parentId]?.type == canvasNodeTypeGroup)
          node.id: node.parentId!,
    };

    // 落点与整理用的布局：flow 里此刻的节点，加上各场的场次节点。有片段的场次节点
    // 跟着片段走（片段最左、最上的位置），空场次取色带当前的位置；场次节点随所在场次一起移动。
    ({Map<String, Rect> rects, Map<String, String> sceneOf}) layout() {
      final rects = {
        for (final node in controller.nodes.values)
          node.id: node.position.value & node.size.value,
      };
      final sceneOf = {...interaction.sceneForNode};
      for (final MapEntry(key: sceneId, value: anchor)
          in bands.anchors.entries) {
        final members = [
          for (final entry in interaction.sceneForNode.entries)
            if (entry.value == sceneId) ?rects[entry.key],
        ];
        rects[anchor.id] = members.isEmpty
            ? productionSceneAnchorRect(bands.anchorAt(sceneId), empty: true)
            : productionSceneAnchorRect(
                Offset(
                  members.map((r) => r.left).reduce(math.min),
                  members.map((r) => r.top).reduce(math.min),
                ),
                empty: false,
              );
        sceneOf[anchor.id] = sceneId;
      }
      return (rects: rects, sceneOf: sceneOf);
    }

    camera._center = () {
      final bounds = controller.visibleGraphBounds;
      return bounds.isEmpty ? null : bounds.center;
    };
    // 用 flow 里此刻的位置和渲染尺寸（含拖动中、场次重排后的位置），不读库里的坐标。
    camera._placeDerived = (sourceId, {required audio, Size? size}) {
      final source = controller.getNode(sourceId);
      if (source == null) {
        return null;
      }
      final (:rects, :sceneOf) = layout();
      return productionDerivedPlacement(
        sourceId: sourceId,
        size: size ?? (audio ? productionAudioNodeSize : source.size.value),
        nodes: rects,
        groupOf: groupOf(),
        sceneOf: sceneOf,
        siblings: [
          for (final edge in latestEdges.value)
            if (edge.type == canvasEdgeTypeDerivedOutput &&
                edge.sourceNodeId == sourceId)
              edge.targetNodeId,
        ],
      );
    };

    // 库内容按 id 增量对齐到 flow：只增删节点和连线、挪位置，不整图重载，
    // 视口和选中态原地不动；节点内容变化由 nodeBuilder 读最新快照。
    useEffect(() {
      if (!content.hasData) {
        return null;
      }
      for (final id in controller.nodes.keys.toList()) {
        if (!byId.containsKey(id)) {
          controller.removeNode(id);
        }
      }
      for (final node in nodes) {
        final position = scenePositions[node.id] ?? Offset(node.x, node.y);
        final existing = controller.getNode(node.id);
        final size = sizeOf(node);
        // 尺寸变了要整节点重建：端口 offset 在建节点时按高度算好。
        if (existing == null ||
            existing.size.value != size ||
            existing.locked !=
                interaction.storyboardParents.containsKey(node.id)) {
          controller.addNode(
            _flowNode(
                node,
                colors,
                size: size,
                locked: interaction.storyboardParents.containsKey(node.id),
                derived:
                    outputIds.contains(node.id) || derivedIds.contains(node.id),
                headerScale: () => headerScale.value,
              )
              ..position.value = position
              ..selected.value = existing?.selected.value ?? false
              ..zIndex.value = existing?.zIndex.value ?? 0,
          );
        } else if (existing.position.value != position &&
            !existing.dragging.value) {
          controller.setNodePosition(node.id, position);
        }
      }
      for (final row in nodes.where((n) => n.type == canvasNodeTypeGroup)) {
        final group = controller.getNode(row.id) as ProductionFlowGroup;
        final groupMembers = membersByParent[row.id] ?? const <CanvasNode>[];
        group.layout = ProductionGroupLayout.fromStyle(row.style);
        group.slots = {
          for (final member in groupMembers) member.sortOrder: member.id,
        };
        final members = {for (final member in groupMembers) member.id};
        for (final id in group.nodeIds.difference(members)) {
          group.removeNode(id);
        }
        for (final id in members.difference(group.nodeIds)) {
          group.addNode(id);
        }
      }
      for (final connection in controller.connections.toList()) {
        if (!edgeIds.contains(connection.id)) {
          controller.removeConnection(connection.id);
        }
      }
      for (final edge in edges) {
        if (controller.getConnection(edge.id) == null &&
            byId.containsKey(edge.sourceNodeId) &&
            byId.containsKey(edge.targetNodeId)) {
          controller.addConnection(
            flow.Connection<String>(
              id: edge.id,
              sourceNodeId: edge.sourceNodeId,
              sourcePortId: _portOut,
              targetNodeId: edge.targetNodeId,
              targetPortId: _portIn,
              // 导演台导出和视频处理产物是实线，生成输入是虚线。
              dashPattern:
                  edge.type == canvasEdgeTypeStagingOutput ||
                      edge.type == canvasEdgeTypeDerivedOutput
                  ? null
                  : const [4, 5],
              startPoint: flow.ConnectionEndPoint.none,
              endPoint: flow.ConnectionEndPoint.none,
            ),
          );
        }
      }
      return null;
    }, [content.data, scenePositions, sizeKey]);

    // 用途文案在 build 里取：effect 首次执行时不能读 InheritedWidget。
    // 标签以最新输入和目标视频模式为准，不缓存进不可变的 Connection.data。
    final connectionLabels = {
      for (final edge in edges)
        if (edge.role case final role?)
          edge.id: role == 'prompt'
              ? context.t(LocaleKeys.productionText)
              : productionRole(
                  context,
                  VideoInputRole.values.byName(role),
                  mode: clipInfo?[byId[edge.targetNodeId]?.clipId]?.mode,
                  middleFrameIndex: edge.middleFrameIndex,
                ),
    };
    useEffect(
      () {
        controller.resolvePlugin<ProductionConnectionFlow>()!.configure(
          colors: colors,
          connectionLabels: connectionLabels,
          animate: !reduceMotion,
        );
        return null;
      },
      [
        controller,
        colors,
        reduceMotion,
        connectionLabels.entries.map((e) => '${e.key}:${e.value}').join('|'),
      ],
    );

    useEffect(() {
      if (content.hasData) {
        interaction.syncFocus(selected);
      }
      return null;
    });

    // 带边距看全所有节点和色带。
    void fitAll() {
      final screen = controller.screenSize;
      Rect? all;
      for (final node in controller.nodes.values) {
        final r = node.position.value & node.size.value;
        all = all == null ? r : all.expandToInclude(r);
      }
      for (final band in bands.rects()) {
        all = all == null ? band.rect : all.expandToInclude(band.rect);
      }
      if (all != null && !screen.isEmpty) {
        _setView(controller, all.inflate(40));
      }
    }

    // 按 flow 里此刻的位置排；多选时只整理选区。先挪 flow 再走拖动同一条保存路径，失败时回退。
    void tidy() {
      final scope = controller.selectedNodeIds.toSet();
      final (:rects, :sceneOf) = layout();
      final positions = productionTidyLayout(
        nodes: rects,
        sceneOf: sceneOf,
        groupOf: groupOf(),
        edges: [
          for (final edge in latestEdges.value)
            (edge.sourceNodeId, edge.targetNodeId),
        ],
        sceneOrder: [...bands.sceneLabels.keys],
        scope: scope,
      );
      if (positions.isEmpty) {
        return;
      }
      for (final entry in positions.entries) {
        if (controller.getNode(entry.key) != null) {
          controller.setNodePosition(entry.key, entry.value);
        }
      }
      bands.place(positions);
      bands.onMove?.call(positions);
      fitAll();
    }

    // 外部选中或第二栏点场次：把节点连同上方工具条、下方输入框一起放进视口。
    useEffect(
      () {
        final target = selected ?? revealed;
        if (!content.hasData) {
          return null;
        }
        if (target != null && target == tapped.value) {
          tapped.value = null;
          return null;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted || controller.screenSize.isEmpty) {
            return;
          }
          if (target == null) {
            if (!fitted.value) {
              fitted.value = true;
              fitAll();
            }
            return;
          }
          final node = controller.getNode(target);
          if (node == null) {
            return;
          }
          fitted.value = true;
          final rect = node.position.value & node.size.value;
          final zoom = controller.viewport.zoom;
          // 已经完整在视口里（比如刚在视口中心新建的节点）就不动镜头。
          final safe = controller.visibleGraphBounds.deflate(
            RevericSpacing.x6l / zoom,
          );
          if (safe.contains(rect.topLeft) && safe.contains(rect.bottomRight)) {
            return;
          }
          _setView(
            controller,
            Rect.fromLTRB(
              rect.left - 200,
              rect.top - 120,
              rect.right + 200,
              rect.bottom + 300,
            ),
          );
        });
        return null;
      },
      [
        selected,
        revealed,
        content.hasData,
        byId.containsKey(selected ?? revealed),
      ],
    );

    final events = useMemoized(
      () => flow.NodeFlowEvents<String, String>(
        onSelectionChange: (_) => interaction.selectionChanged(),
        node: flow.NodeEvents<String>(
          onDoubleTap: (node) {
            final row = latest.value[node.id];
            if (row == null) {
              return;
            }
            final clip = latestModes.value?[row.clipId];
            final assetId = row.isGenerationNode
                ? clip?.adoptedAssetId
                : row.mediaAssetId;
            final type = row.isGenerationNode
                ? row.type
                : latestAssetTypes.value[assetId];
            if (assetId == null ||
                (type != 'image' && type != 'video') ||
                previewing.value) {
              return;
            }
            previewing.value = true;
            productionRun(context, () async {
              try {
                await previewProductionAsset(context, service, assetId);
              } finally {
                previewing.value = false;
              }
            });
          },
          onTap: (node) {
            final row = latest.value[node.id];
            if (row != null &&
                controller.selectedNodeIds.length == 1 &&
                controller.selectedNodeIds.contains(node.id)) {
              interaction.pendingFocus = node.id;
              tapped.value = node.id;
              onSelect(row);
            }
          },
          // 按下任意键时 flow 已按点选处理过；只有多选里右键时才收成单选。
          // 分镜格没有工具条，不响应。
          onContextMenu: (node, position) {
            final row = latest.value[node.id];
            final open = latestOnContextMenu.value;
            if (row == null ||
                open == null ||
                interaction.storyboardParents.containsKey(row.id)) {
              return;
            }
            if (controller.selectedNodeIds.length != 1 ||
                !controller.selectedNodeIds.contains(node.id)) {
              controller.selectNode(node.id);
              interaction.pendingFocus = node.id;
              tapped.value = node.id;
              onSelect(row);
            }
            open(row, position.offset);
          },
          onDragStart: (_) => interaction.startDrag(),
          onDrag: (_) => interaction.restoreFixedMembers(),
          onDragStop: (_) {
            final positions = interaction.finishDrag();
            if (positions.isNotEmpty) {
              bands.onMove?.call(positions);
            }
          },
          onDragCancel: (_) => interaction.cancelDrag(),
          // 删除只走工具条菜单；键盘删除会让 flow 和库对不上。
          onBeforeDelete: (_) async => false,
        ),
        connection: flow.ConnectionEvents<String, String>(
          onBeforeDelete: (connection) async {
            final inputId = latestEdges.value
                .where((edge) => edge.id == connection.id)
                .firstOrNull
                ?.inputId;
            if (inputId != null && onDisconnect != null) {
              await onDisconnect!(inputId, connection.targetNodeId);
            }
            // 持久化后的输入快照负责移除投影连线。
            return false;
          },
          onBeforeComplete: (context) {
            final source = latest.value[context.sourceNode.id];
            final target = latest.value[context.targetNode.id];
            final targetInfo = latestModes.value?[target?.clipId];
            final mode = targetInfo?.mode;
            // 视频节点的输出按视频素材算。
            final kind = source?.mediaAssetId == null
                ? source?.type
                : latestAssetTypes.value[source!.mediaAssetId];
            final existingKinds = <String>[
              for (final edge in controller.connections)
                if (edge.targetNodeId == target?.id &&
                    edge.sourceNodeId != source?.id)
                  if (latest.value[edge.sourceNodeId] case final existing?
                      when existing.type != canvasNodeTypeText)
                    existing.isGenerationNode
                        ? existing.type
                        : latestAssetTypes.value[existing.mediaAssetId] ?? '',
            ];
            final audioAllowed =
                target?.type == canvasNodeTypeAudio &&
                kind != null &&
                lookupAudioChannelModel(
                      latestAudioProviderTypes.value[targetInfo?.providerId] ??
                          '',
                      targetInfo?.modelId,
                    ) !=
                    null &&
                AudioCapabilities(
                  targetInfo?.modelId ?? '',
                  providerType:
                      latestAudioProviderTypes.value[targetInfo?.providerId],
                ).accepts([...existingKinds, kind]);
            final allowed =
                !context.isSelfConnection &&
                source?.type != canvasNodeTypeStaging &&
                source?.type != canvasNodeTypeGroup &&
                context.targetPort.id == _portIn &&
                target?.isGenerationNode == true &&
                mode != null &&
                (source?.type == canvasNodeTypeText ||
                    audioAllowed ||
                    (target?.type == canvasNodeTypeImage
                            ? const [VideoInputRole.reference_image]
                            : target?.type == canvasNodeTypeAudio
                            ? const <VideoInputRole>[]
                            : productionRoles(mode))
                        .any((r) => r.kind.name == kind));
            return allowed
                ? const flow.ConnectionValidationResult.allow()
                : const flow.ConnectionValidationResult.deny();
          },
          // 库在落点处先建一条乐观连线；撤掉它，交给外部选用途后写库、经 stream 回流。
          onCreated: (connection) {
            // 从库里同步进来的连线 addConnection 也会触发这里。
            if (latestEdgeIds.value.contains(connection.id)) {
              return;
            }
            final pointer = controller.pointerPosition?.offset;
            controller.removeConnection(connection.id);
            final source = latest.value[connection.sourceNodeId];
            final target = latest.value[connection.targetNodeId];
            final box =
                controller.canvasKey.currentContext?.findRenderObject()
                    as RenderBox?;
            if (source != null &&
                target != null &&
                pointer != null &&
                box != null) {
              onConnect(source, target, box.localToGlobal(pointer));
            }
          },
        ),
        viewport: flow.ViewportEvents(
          onCanvasTap: (_) {
            if (interaction.focused != null) {
              interaction.pendingFocus = interaction.focused;
              onClear();
            }
          },
        ),
      ),
      [controller, service],
    );

    bands
      ..segments = segments
      ..sceneLabels = sceneLabels
      ..nodeForClip = {
        for (final n in nodes)
          if (n.clipId != null) n.clipId!: n.id,
      }
      ..onAdd = onAddSegment
      ..sync({
        for (final n in sceneNodes)
          n.sceneId!: (
            id: n.id,
            at: scenePositions[n.id] ?? Offset(n.x, n.y),
            stored: Offset(n.x, n.y),
          ),
      });
    bands.onMove = (moved) => productionRun(context, () async {
      // 场次节点是场次位置的真源：片段整场移动时，场次节点一起移到片段最左、最上的位置，
      // 并进入同一条撤销记录。
      final positions = {...moved};
      for (final MapEntry(key: sceneId, value: anchor)
          in bands.anchors.entries) {
        final members = [
          for (final entry in interaction.sceneForNode.entries)
            if (entry.value == sceneId) ?positions[entry.key],
        ];
        if (members.isNotEmpty && !positions.containsKey(anchor.id)) {
          positions[anchor.id] = Offset(
            members.map((at) => at.dx).reduce(math.min),
            members.map((at) => at.dy).reduce(math.min),
          );
        }
      }
      try {
        await recordProductionChange(
          context,
          {
            ...positions.keys,
            for (final group
                in controller.nodes.values.whereType<ProductionFlowGroup>())
              if (group.layout is FreeGroupLayout &&
                  (positions.containsKey(group.id) ||
                      group.nodeIds.any(positions.containsKey)))
                group.id,
          },
          () => service.write(canvasId, () async {
            await service.moveNodes(canvasId, {
              for (final entry in positions.entries)
                entry.key: (x: entry.value.dx, y: entry.value.dy),
            });
            for (final group
                in controller.nodes.values.whereType<ProductionFlowGroup>()) {
              if (group.layout is FreeGroupLayout &&
                  (positions.containsKey(group.id) ||
                      group.nodeIds.any(positions.containsKey))) {
                await service.groups.resizeFree(
                  group.id,
                  group.constrain(group.position.value & group.size.value),
                );
              }
            }
          }),
        );
      } catch (_) {
        for (final id in positions.keys) {
          final row = latest.value[id];
          if (row != null) {
            controller.setNodePosition(
              id,
              latestScenePositions.value[id] ?? Offset(row.x, row.y),
            );
          }
        }
        bands.forget(positions.keys);
        rethrow;
      }
    });

    if (content.hasError) {
      return Center(child: Text(context.t(LocaleKeys.productionFailed)));
    }
    if (!content.hasData) {
      return const Center(child: CircularProgressIndicator());
    }

    return ProductionGridWorkspace(
      nodeId: selected,
      child: ProductionViewWorkspace(
        nodeId: selected,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: appChromeBackgroundColor(
              colors,
              appBackgroundActive,
              colors.canvas,
            ),
          ),
          child: ClipRect(
            child: Stack(
              children: [
                Positioned.fill(
                  child: flow.NodeFlowEditor<String, String>(
                    controller: controller,
                    connectionAnimationFrameRate: 30,
                    theme: flowTheme,
                    behavior: flow.NodeFlowBehavior.design,
                    marqueeSelectionOnDrag: true,
                    selectionBounds: () => controller
                        .getPlugin<ProductionSelectionLayer>()!
                        .bounds,
                    events: events,
                    nodeBuilder: (context, node) {
                      final row = latest.value[node.id];
                      if (row != null && node is ProductionFlowGroup) {
                        return ProductionGroupNode(
                          group: node,
                          onFill: (slot) => productionRun(context, () async {
                            final asset = await pickProductionAsset(
                              context,
                              service,
                              types: {'image'},
                              confirmLabel: context.t(LocaleKeys.commonAdd),
                            );
                            if (asset != null) {
                              await service.fillStoryboardSlot(
                                row.id,
                                slot,
                                asset.id,
                                history: history,
                              );
                            }
                          }),
                          onResize: (frame) => service.groups.resizeFree(
                            row.id,
                            frame,
                            history: history,
                          ),
                        );
                      }
                      final parent = controller.getNode(row?.parentId ?? '');
                      final layout = parent is ProductionFlowGroup
                          ? parent.layout
                          : null;
                      if (row == null) {
                        return const SizedBox.shrink();
                      }
                      final storyboardNumber =
                          layout is StoryboardGroupLayout && layout.numbered
                          ? row.sortOrder + 1
                          : null;
                      final storyboardCell = interaction.storyboardParents
                          .containsKey(row.id);
                      final segmentLabel = segmentLabels[row.clipId];
                      final fromDirector = outputIds.contains(row.id);
                      final derived = derivedIds.contains(row.id);
                      final inputs = (
                        row,
                        node,
                        service,
                        parent,
                        layout,
                        storyboardNumber,
                        storyboardCell,
                        segmentLabel,
                        fromDirector,
                        derived,
                        cardTaskActions,
                      );
                      final cached = nodeWidgets[row.id];
                      if (cached != null && cached.inputs == inputs) {
                        return cached.widget;
                      }
                      final widget = Observer(
                        builder: (_) {
                          final card = ProductionNodeCard(
                            service: service,
                            node: row,
                            storyboardNumber: storyboardNumber,
                            storyboardCell: storyboardCell,
                            headerScale: () => headerScale.value,
                            compact: () => compact.value,
                            selected: node.selected.value,
                            segmentLabel: segmentLabel,
                            fromDirector: fromDirector,
                            derived: derived,
                            onOpenDirector: () =>
                                latestOnOpenDirector.value(row),
                            taskActions: cardTaskActions,
                            textTitle: textTitle,
                          );
                          return parent is ProductionFlowGroup &&
                                  layout is StoryboardGroupLayout
                              ? ProductionStoryboardCell(
                                  group: parent,
                                  controller: controller,
                                  service: service.groups,
                                  memberId: row.id,
                                  child: card,
                                )
                              : card;
                        },
                      );
                      nodeWidgets[row.id] = (inputs: inputs, widget: widget);
                      return widget;
                    },
                  ),
                ),
                if (nodes.isEmpty && sceneNodes.isEmpty)
                  empty ??
                      Center(
                        child: IgnorePointer(
                          child: Text(
                            context.t(LocaleKeys.productionEmpty),
                            style: typo.ui.copyWith(color: colors.textMuted),
                          ),
                        ),
                      ),
                Positioned.fill(
                  child: ProductionGroupOutlet(
                    controller: controller,
                    onCreate: onCreateGroupReference,
                    onConnect: (groupId, targetId, at) {
                      final source = latest.value[groupId];
                      final target = latest.value[targetId];
                      if (source != null && target != null) {
                        onConnect(source, target, at);
                      }
                    },
                  ),
                ),
                // 浮层必须在编辑器之外：编辑器根 Listener 会把其内部点击当成点画布空白。
                if (selected != null && byId[selected] != null)
                  _Anchored(
                    controller: controller,
                    nodeId: selected!,
                    topInset: topInset,
                    trailingInset: composerTrailingInset,
                    bottomInset: composerBottomInset,
                    headerExtent: productionNodeHeaderExtent,
                    // 文本节点的标题随正文一起编辑、一起保存；其余节点只改标题。
                    title: switch (byId[selected]!.type) {
                      canvasNodeTypeGroup => const SizedBox.shrink(),
                      canvasNodeTypeText => ProductionNodeTitleField(
                        key: ValueKey('title/$selected'),
                        title: textTitle,
                        nodeId: selected!,
                      ),
                      _ =>
                        interaction.storyboardParents.containsKey(selected)
                            ? const SizedBox.shrink()
                            : ProductionNodeTitleField(
                                key: ValueKey('title/$selected'),
                                title: textTitle,
                                nodeId: selected!,
                                load: () => service.nodeTitle(selected!),
                                commit: (text) => service.renameNode(
                                  selected!,
                                  text,
                                  history: history,
                                ),
                              ),
                    },
                    bar:
                        bar == null ||
                            interaction.storyboardParents.containsKey(selected)
                        ? null
                        // 窄窗口下整条缩小，不折行也不溢出。
                        : CanvasEnter(
                            key: ValueKey('bar/$selected'),
                            slideFrom: const Offset(0, .12),
                            child: ProductionViewNode(
                              node: byId[selected]!,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: bar!,
                              ),
                            ),
                          ),
                    composer: CanvasEnter(
                      key: ValueKey('composer/$selected'),
                      slideFrom: const Offset(0, -.04),
                      child: ProductionViewComposer(
                        service: service,
                        node: byId[selected]!,
                        child: composer,
                      ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: RevericSpacing.x4l,
                  child: Center(
                    child: ProductionSelectionActions(
                      service: service,
                      controller: controller,
                      beforeDelete: beforeRemoveSelection,
                      onDeleted: onClear,
                    ),
                  ),
                ),
                ...controls,
                Positioned(
                  left: RevericSpacing.x2l,
                  bottom: RevericSpacing.x2l,
                  child: CanvasFloatingCluster(
                    axis: Axis.horizontal,
                    children: [
                      CanvasFloatingButton(
                        icon: RevericIcons.frame_corners,
                        tooltip: context.t(LocaleKeys.canvasFitToView),
                        onTap: fitAll,
                      ),
                      CanvasFloatingButton(
                        icon: RevericIcons.account_tree,
                        tooltip: context.t(LocaleKeys.productionTidyCanvas),
                        onTap: tidy,
                      ),
                      ?tools,
                      CanvasZoomControl(
                        zoom: () => controller.viewportObservable.value.zoom,
                        onZoomOut: () => controller.zoomBy(
                          controller.viewport.zoom * (1 / _zoomStep - 1),
                        ),
                        onZoomIn: () => controller.zoomBy(
                          controller.viewport.zoom * (_zoomStep - 1),
                        ),
                        onFit: fitAll,
                        // zoomBy 以视口中心为锚，zoomTo 会绕左上角缩放。
                        onZoomTo: (target) => controller.zoomBy(
                          target - controller.viewport.zoom,
                        ),
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

/// 制作画布在共用画布主题上换成细密点阵和柔和连线：这里的节点是成片画面，
/// 底纹和连线都要退到画面后面。
flow.NodeFlowTheme _flowTheme(flow.NodeFlowTheme base, RevericColors colors) {
  return base.copyWith(
    gridTheme: base.gridTheme.copyWith(
      color: canvasFineDotColor(colors),
      size: 16,
      thickness: .75,
    ),
    connectionTheme: base.connectionTheme.copyWith(
      style: const ProductionConnectionStyle(),
      color: canvasSoftEdgeColor(colors),
      strokeWidth: 1.6,
      selectedStrokeWidth: 2,
    ),
    temporaryConnectionTheme: base.temporaryConnectionTheme.copyWith(
      style: const ProductionConnectionStyle(),
    ),
  );
}

/// 把镜头对准 [focus]（画布坐标），最多放大到 100%。
void _setView(_BoardController controller, Rect focus) {
  final screen = controller.screenSize;
  final zoom = math
      .min(
        math.min(screen.width / focus.width, screen.height / focus.height),
        1.0,
      )
      .clamp(_minZoom, _maxZoom);
  controller.setViewport(
    flow.GraphViewport(
      x: screen.width / 2 - focus.center.dx * zoom,
      y: screen.height / 2 - focus.center.dy * zoom,
      zoom: zoom,
    ),
  );
}

/// [derived] 见 [productionNodePorts]。
flow.Node<String> _flowNode(
  CanvasNode node,
  RevericColors colors, {
  required Size size,
  required bool derived,
  bool locked = false,
  double Function()? headerScale,
}) {
  final ports = productionNodePorts(node, derived: derived);
  // 常态端口透明，悬停 / 选中时由卡片画出提示点；拖线时可落的端口和端口自身悬停仍用强调色。
  final hidden = colors.surface.withValues(alpha: 0);
  final interactive = !locked && node.type != canvasNodeTypeGroup;
  final theme = flow.NodeFlowTheme.light.portTheme.copyWith(
    size: const Size.square(productionPortSize),
    shape: flow.MarkerShapes.circle,
    color: hidden,
    connectedColor: hidden,
    highlightColor: interactive ? colors.accent : hidden,
    borderColor: hidden,
    highlightBorderColor: interactive ? colors.accent : hidden,
    borderWidth: 1.5,
  );
  // 矩形节点必须显式给 offset，否则连接点会落在节点角上。
  final middle = Offset(0, size.height / 2);
  final nodePorts = <flow.Port>[
    if (ports.input)
      flow.Port(
        id: _portIn,
        name: '',
        type: flow.PortType.input,
        position: flow.PortPosition.left,
        offset: middle,
        multiConnections: true,
        isConnectable: interactive,
        size: const Size.square(productionPortSize),
        theme: theme,
      ),
    if (ports.output)
      flow.Port(
        id: _portOut,
        name: '',
        type: flow.PortType.output,
        position: flow.PortPosition.right,
        offset: middle,
        multiConnections: true,
        isConnectable: interactive,
        size: const Size.square(productionPortSize),
        theme: theme,
      ),
  ];
  if (node.type == canvasNodeTypeGroup) {
    return ProductionFlowGroup(
      id: node.id,
      position: Offset(node.x, node.y),
      size: size,
      ports: nodePorts,
    );
  }
  if (!locked && headerScale != null) {
    return _TitledNode(
      id: node.id,
      type: node.type,
      position: Offset(node.x, node.y),
      size: size,
      ports: nodePorts,
      headerScale: headerScale,
    );
  }
  return flow.Node<String>(
    id: node.id,
    type: node.type,
    position: Offset(node.x, node.y),
    size: size,
    data: node.id,
    locked: locked,
    ports: nodePorts,
  );
}

/// 卡片外上方画着标题的节点。标题也要进 flow 的空间命中范围：否则在标题上按下会被
/// 画布当成点空白开始框选，拖标题时选区被清掉，只有这张卡片在动、同场其他片段留在原地。
class _TitledNode extends flow.Node<String> {
  _TitledNode({
    required super.id,
    required super.type,
    required super.position,
    required super.size,
    required super.ports,
    required this.headerScale,
  }) : super(data: id);

  /// 标题随画布缩放反向放大，见 [productionHeaderScale]。
  final double Function() headerScale;

  Rect _withHeader(double scale) {
    final card = super.getBounds();
    return Rect.fromLTRB(
      card.left,
      card.top - productionCardHeaderExtent * scale,
      card.right,
      card.bottom,
    );
  }

  // 空间索引只在节点变动时取一次范围，按标题最大放大倍数算；具体命中按当前倍数判断。
  @override
  Rect getBounds() => _withHeader(productionHeaderScale(0.01));

  @override
  bool containsPoint(Offset point) =>
      _withHeader(headerScale()).contains(point);
}

/// 场次色带：一场的片段节点外框，左上角写场次，底部是「分镜」入口。画在网格之上、连线之下，
/// 随节点拖动实时跟随。空场次没有片段节点，色带由场次节点定位，拖动时只挪色带。
class _BandLayer extends flow.NodeFlowPlugin implements LayerProvider {
  _BandLayer();

  /// 由 board 每次 rebuild 同步。
  List<ProductionClipRow> segments = const [];
  Map<String, String> sceneLabels = const {};

  /// 片段 id → 节点 id。
  Map<String, String> nodeForClip = const {};

  /// 场次 id → 场次节点：[at] 是排位后的位置，[stored] 是库里的坐标。由 [sync] 更新。
  Map<String, ({String id, Offset at, Offset stored})> anchors = const {};
  ValueChanged<String>? onAdd;
  Future<void> Function(Map<String, Offset>)? onMove;
  bool _dragging = false;

  /// 空场次拖动中、或已提交但库里还没写回的位置，按场次节点 id 存。
  final _moved = ObservableMap<String, Offset>();
  String? _draggingAnchor;

  void sync(Map<String, ({String id, Offset at, Offset stored})> next) {
    anchors = next;
    final stale = [
      for (final MapEntry(key: id, value: at) in _moved.entries)
        if (id != _draggingAnchor &&
            !next.values.any((a) => a.id == id && a.stored != at))
          id,
    ];
    if (stale.isNotEmpty) {
      // 库里已写回（或场次已不在画布上）：交回排位结果。
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => runInAction(() => stale.forEach(_moved.remove)),
      );
    }
  }

  /// 空场次色带此刻的位置。
  Offset anchorAt(String sceneId) {
    final anchor = anchors[sceneId]!;
    return _moved[anchor.id] ?? anchor.at;
  }

  /// 整理画布后先把空场次挪到新位置，不等库写回。
  void place(Map<String, Offset> positions) => runInAction(() {
    for (final anchor in anchors.values) {
      if (positions[anchor.id] case final at?) {
        _moved[anchor.id] = at;
      }
    }
  });

  /// 保存失败时放弃这些场次节点的本地位置。
  void forget(Iterable<String> ids) =>
      runInAction(() => ids.forEach(_moved.remove));

  void startDrag(String sceneId) {
    final controller = _controller!;
    if (HardwareKeyboard.instance.isLogicalKeyPressed(
      LogicalKeyboardKey.space,
    )) {
      return;
    }
    final members = [
      for (final segment in segments.where((s) => s.sceneId == sceneId))
        if (nodeForClip[segment.id] case final id?)
          if (controller.getNode(id) != null) id,
    ];
    if (members.isEmpty) {
      final anchor = anchors[sceneId];
      if (anchor != null) {
        _draggingAnchor = anchor.id;
        runInAction(() => _moved[anchor.id] = anchorAt(sceneId));
      }
      return;
    }
    controller.interaction.finishSelection();
    controller.interaction.update(canvasLocked: true);
    // 已处于多选中的场次跟随外层整组；否则直接拖动这一场。
    if (!members.any(controller.selectedNodeIds.contains)) {
      controller.selectNodes(members);
    }
    _dragging = true;
    controller.startNodeDrag(
      members.firstWhere(controller.selectedNodeIds.contains),
    );
  }

  void drag(Offset delta) {
    if (_draggingAnchor case final id?) {
      runInAction(() => _moved[id] = _moved[id]! + delta);
      return;
    }
    if (_dragging) {
      _controller!.moveNodeDrag(delta);
    }
  }

  void endDrag({bool cancel = false}) {
    if (_draggingAnchor case final id?) {
      _draggingAnchor = null;
      if (cancel) {
        forget([id]);
      } else {
        onMove?.call({id: _moved[id]!});
      }
      return;
    }
    final controller = _controller;
    if (controller == null || !_dragging) {
      return;
    }
    _dragging = false;
    if (cancel) {
      controller.cancelNodeDrag(
        Map<String, Offset>.from(controller.interaction.dragStartPositions),
      );
      controller.interaction.clearDragStartPositions();
    } else {
      controller.endNodeDrag();
    }
  }

  _BoardController? _controller;

  @override
  String get id => 'production_band_layer';

  @override
  void attach(flow.NodeFlowController controller) {
    _controller = controller as _BoardController;
  }

  @override
  void detach() {
    _controller = null;
  }

  @override
  void onEvent(flow.GraphEvent event) {}

  @override
  LayerPosition get layerPosition => NodeFlowLayer.grid.after;

  /// 每场色带的画布坐标；读节点位置，放在 Observer 里会随拖动刷新。
  List<({String sceneId, Rect rect})> rects() {
    final controller = _controller;
    if (controller == null) {
      return const [];
    }
    final result = <({String sceneId, Rect rect})>[];
    final scenes = <String>{
      for (final s in segments)
        if (s.sceneId != null) s.sceneId!,
      ...anchors.keys,
    };
    for (final sceneId in scenes) {
      Rect? rect;
      for (final s in segments.where((s) => s.sceneId == sceneId)) {
        final id = nodeForClip[s.id];
        final node = id == null ? null : controller.getNode(id);
        if (node != null) {
          final r = node.position.value & node.size.value;
          rect = rect == null ? r : rect.expandToInclude(r);
        }
      }
      if (rect == null && anchors.containsKey(sceneId)) {
        rect = productionSceneAnchorRect(anchorAt(sceneId), empty: true);
      }
      if (rect != null) {
        result.add((sceneId: sceneId, rect: productionSceneBand(rect)));
      }
    }
    return result;
  }

  Iterable<Rect> selectedBounds() {
    final controller = _controller;
    if (controller == null) {
      return const [];
    }
    final scenes = {
      for (final segment in segments)
        if (controller.selectedNodeIds.contains(nodeForClip[segment.id]))
          ?segment.sceneId,
    };
    return rects()
        .where((band) => scenes.contains(band.sceneId))
        .map((band) => band.rect);
  }

  @override
  Widget? buildLayer(BuildContext context) {
    if (_controller == null) {
      return null;
    }
    final add = onAdd;
    return UnboundedPositioned.fill(
      child: Observer(
        builder: (_) => UnboundedStack(
          clipBehavior: Clip.none,
          children: [
            for (final band in rects())
              UnboundedPositioned(
                key: ValueKey(band.sceneId),
                left: band.rect.left,
                top: band.rect.top,
                width: band.rect.width,
                height: band.rect.height,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ElementScope(
                        createSession: () => _controller!.createSession(
                          DragSessionType.nodeDrag,
                        ),
                        cursor: SystemMouseCursors.grab,
                        onDragStart: (_) => startDrag(band.sceneId),
                        onDragUpdate: (details) => drag(details.delta),
                        onDragEnd: (_) => endDrag(),
                        onDragCancel: () => endDrag(cancel: true),
                        child: Tooltip(
                          message: context.t(LocaleKeys.productionMoveScene),
                          child: _Band(label: sceneLabels[band.sceneId] ?? ''),
                        ),
                      ),
                    ),
                    if (add != null)
                      Positioned(
                        left: _bandInset,
                        right: _bandInset,
                        bottom: RevericSpacing.lg,
                        height: productionSceneAddHeight,
                        child: _BandAdd(onTap: () => add(band.sceneId)),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 色带左右比卡片多出的宽度，与 [productionSceneBand] 一致。
const double _bandInset = 28;

/// 场次色带外观。
class _Band extends StatelessWidget {
  const _Band({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    // 色带比节点卡低一层：同一套半透明底，但更淡；圆角比卡片大一圈，包住卡片不显得生硬。
    return DecoratedBox(
      decoration: BoxDecoration(
        color: canvasGlassFill(colors).withValues(alpha: .4),
        borderRadius: BorderRadius.circular(
          RevericRadius.canvasNode + RevericSpacing.sm,
        ),
        border: Border.all(color: canvasGlassBorder(colors)),
      ),
      child: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.xl,
            RevericSpacing.md,
            RevericSpacing.xl,
            0,
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // 场次标题比卡片外的段标题重一级。
            style: typo.uiSemibold.copyWith(color: colors.textSecondary),
          ),
        ),
      ),
    );
  }
}

/// 色带底部的虚线入口：在这一场末尾新建片段。平时退在色带里，悬停时加深。
class _BandAdd extends StatefulWidget {
  const _BandAdd({required this.onTap});
  final VoidCallback onTap;
  @override
  State<_BandAdd> createState() => _BandAddState();
}

class _BandAddState extends State<_BandAdd> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final foreground = _hovered ? colors.textSecondary : colors.textMuted;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: DottedBorderBox(
          color: canvasGlassBorder(colors, strong: _hovered),
          borderRadius: RevericRadius.canvasNode,
          child: AnimatedContainer(
            duration: CanvasMotion.hover,
            curve: CanvasMotion.curve,
            decoration: BoxDecoration(
              color: _hovered
                  ? canvasGlassFill(colors)
                  : canvasGlassFill(colors).withValues(alpha: 0),
              borderRadius: BorderRadius.circular(RevericRadius.canvasNode),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                RevericIcon(RevericIcons.add, size: 14, color: foreground),
                const SizedBox(width: RevericSpacing.xs),
                Text(
                  context.t(LocaleKeys.productionAddSegment),
                  style: typo.ui.copyWith(color: foreground),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _AnchorSlot { bar, composer, title }

/// 按视口把工具条贴在节点上沿、输入框贴在下沿，并夹在视口内。
/// 两者一起排版：输入框被视口底边顶上去时，工具条随之上移停在输入框上方，两者不重叠。
class _Anchored extends StatelessWidget {
  const _Anchored({
    required this.controller,
    required this.nodeId,
    required this.composer,
    required this.title,
    this.bar,
    this.topInset = 0,
    this.trailingInset = 0,
    this.bottomInset = 0,
    this.headerExtent = 0,
  });
  final _BoardController controller;
  final String nodeId;
  final Widget? bar;
  final Widget composer;

  /// 叠在节点标题原位的可输入标题（文本节点编辑时）；不可见时不占命中。
  final Widget title;
  final double topInset;
  final double trailingInset;
  final double bottomInset;

  /// 节点上沿之外的标题高度（画布坐标），工具条要让过它。
  final double headerExtent;
  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Observer(
        builder: (context) {
          final node = controller.getNode(nodeId);
          if (node == null ||
              controller.selectedNodeIds.length != 1 ||
              !controller.selectedNodeIds.contains(nodeId)) {
            return const SizedBox.shrink();
          }
          final viewport = controller.viewportObservable.value;
          final topLeft = viewport
              .toScreen(flow.GraphPosition(node.position.value))
              .offset;
          // 标题按缩放反向放大过，工具条要让过放大后的高度。
          final scale = viewport.zoom * productionHeaderScale(viewport.zoom);
          final header = headerExtent * scale;
          return CustomMultiChildLayout(
            delegate: _AnchorLayout(
              Rect.fromLTRB(
                topLeft.dx,
                topLeft.dy,
                topLeft.dx + node.size.value.width * viewport.zoom,
                topLeft.dy + node.size.value.height * viewport.zoom,
              ),
              header,
              topInset,
              trailingInset,
              bottomInset,
              viewport.zoom,
            ),
            children: [
              LayoutId(
                id: _AnchorSlot.title,
                // 与卡片标题同一套缩放：按未缩放尺寸排版，再整体放大到屏幕尺寸。
                child: Transform.scale(
                  scale: scale,
                  alignment: Alignment.topLeft,
                  child: title,
                ),
              ),
              if (bar != null) LayoutId(id: _AnchorSlot.bar, child: bar!),
              LayoutId(
                id: _AnchorSlot.composer,
                // 拖动节点时先收起下方输入区，Offstage 保留其中的编辑状态。
                child: Offstage(offstage: node.dragging.value, child: composer),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AnchorLayout extends MultiChildLayoutDelegate {
  _AnchorLayout(
    this.rect,
    this.header,
    this.topInset,
    this.trailingInset,
    this.bottomInset,
    this.zoom,
  );
  final double zoom;
  final Rect rect;
  final double header;
  final double topInset;
  final double trailingInset;
  final double bottomInset;
  static const double _margin = RevericSpacing.lg;

  /// 让出右侧浮层后也不再压窄，宁可和浮层叠一点。
  static const double _minWidth = 320;

  @override
  void performLayout(Size size) {
    // 标题落在卡片标题原位（含选中时的上浮），尺寸是缩放前的画布尺寸。
    final scale = header / productionNodeHeaderExtent;
    final inset = RevericSpacing.xxs * zoom;
    layoutChild(
      _AnchorSlot.title,
      BoxConstraints.tight(
        Size(
          math.max(0, (rect.width - inset) / scale),
          productionNodeHeaderExtent,
        ),
      ),
    );
    positionChild(
      _AnchorSlot.title,
      Offset(
        rect.left + inset,
        rect.top - header - productionNodeHeaderExtent * zoom * .16,
      ),
    );
    final top = topInset + _margin;
    final maxHeight = math.max(
      0.0,
      size.height - _margin * 2 - topInset - bottomInset,
    );
    Size? bar;
    if (hasChild(_AnchorSlot.bar)) {
      bar = layoutChild(
        _AnchorSlot.bar,
        BoxConstraints.loose(
          Size(math.max(0, size.width - _margin * 2), maxHeight),
        ),
      );
    }
    // 输入框最高只到视口顶部留出工具条之后的位置；工具条再按输入框上沿让位。
    final floor = bar == null ? top : top + bar.height + RevericSpacing.sm;
    final width = math.max(
      0.0,
      math.max(
        math.min(_minWidth, size.width - _margin * 2),
        size.width - _margin * 2 - trailingInset,
      ),
    );
    final composer = layoutChild(
      _AnchorSlot.composer,
      BoxConstraints.loose(
        Size(width, math.max(0, size.height - floor - _margin - bottomInset)),
      ),
    );
    final y = math.max(
      floor,
      math.min(
        rect.bottom + RevericSpacing.xl,
        size.height - composer.height - _margin - bottomInset,
      ),
    );
    positionChild(
      _AnchorSlot.composer,
      Offset(_x(size, composer.width, trailingInset), y),
    );
    if (bar != null) {
      // 平时贴在节点上方；输入框被视口底边顶上来时，工具条停在输入框上方，压在节点上。
      final barY = math.max(
        top,
        math.min(
          rect.top - header - bar.height - RevericSpacing.md,
          y - RevericSpacing.sm - bar.height,
        ),
      );
      positionChild(_AnchorSlot.bar, Offset(_x(size, bar.width, 0), barY));
    }
  }

  double _x(Size size, double width, double trailing) =>
      (rect.center.dx - width / 2)
          .clamp(
            _margin,
            math.max(_margin, size.width - width - _margin - trailing),
          )
          .toDouble();

  @override
  bool shouldRelayout(_AnchorLayout old) =>
      old.rect != rect ||
      old.header != header ||
      old.zoom != zoom ||
      old.topInset != topInset ||
      old.trailingInset != trailingInset ||
      old.bottomInset != bottomInset;
}

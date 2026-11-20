// 职责: 在分组外框和节点卡片上方提供可点击及拖动的标题命中层。
// 关联文件:
//   lib/desktop/features/production/board.dart
//   lib/desktop/features/production/grid/group_node.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:reveric/third/flow/vyuh_node_flow/lib/src/editor/element_scope.dart';
import 'package:reveric/third/flow/vyuh_node_flow/lib/src/editor/drag_session.dart';
import 'package:reveric/third/flow/vyuh_node_flow/lib/src/editor/unbounded_widgets.dart';
import 'package:reveric/third/flow/vyuh_node_flow/lib/src/plugins/layer_provider.dart';
import '../../../../shared/theme/theme.dart';
import '../../../../shared/models/production/group_layout.dart';
import '../../../../third/flow/vyuh_node_flow.dart' as flow;
import 'group_node.dart';

class ProductionGroupTitles extends flow.NodeFlowPlugin
    implements LayerProvider {
  Map<String, String> labels = const {};

  /// 卡片外带标题的普通节点。标题由卡片自己画，这里只补一条透明命中区：
  /// 节点矩形之外的点击本来会被画布当成点空白。
  Set<String> titled = const {};

  /// 读卡片外标题的放大倍数，命中区跟着标题一起放大。
  double Function()? headerScale;

  /// 点了普通节点的标题；随后该节点会被选中。
  void Function(String nodeId)? onTitleTap;
  Offset? _down;
  flow.NodeFlowController<String, String>? _controller;
  @override
  String get id => 'production-group-titles';
  @override
  LayerPosition get layerPosition => NodeFlowLayer.middleNodes.before;
  @override
  void attach(flow.NodeFlowController controller) =>
      _controller = controller as flow.NodeFlowController<String, String>;
  @override
  void detach() => _controller = null;
  @override
  void onEvent(flow.GraphEvent event) {}
  @override
  Widget? buildLayer(BuildContext context) {
    final controller = _controller!;
    final typo = RevericTheme.typographyOf(context);
    final colors = RevericTheme.colorsOf(context);
    Widget hit(flow.Node<String> node, {VoidCallback? onTap, Widget? child}) =>
        ElementScope(
          createSession: () =>
              controller.createSession(DragSessionType.nodeDrag),
          onDragStart: (_) => controller.startNodeDrag(node.id),
          onDragUpdate: (details) => controller.moveNodeDrag(details.delta),
          onDragEnd: (_) => controller.endNodeDrag(),
          onTap: onTap,
          cursor: SystemMouseCursors.grab,
          child: child ?? const SizedBox.expand(),
        );
    void select(flow.Node<String> node) {
      controller.selectNode(node.id);
      controller.events.node?.onTap?.call(node);
    }

    // 普通节点的标题不在 flow 的空间命中范围内，根 Listener 会在同一次抬手时
    // 把它当成点空白并清空选中；等这次事件分发完再选中。
    Widget title(flow.Node<String> node) => Listener(
      onPointerDown: (event) => _down = event.position,
      onPointerUp: (event) {
        final down = _down;
        _down = null;
        if (down == null || (event.position - down).distance > 5) {
          return;
        }
        scheduleMicrotask(() {
          if (_controller?.getNode(node.id) == null) {
            return;
          }
          onTitleTap?.call(node.id);
          select(node);
        });
      },
      child: hit(node),
    );
    return UnboundedPositioned.fill(
      child: Observer(
        builder: (_) {
          final scale = headerScale?.call() ?? 1;
          return UnboundedStack(
            clipBehavior: Clip.none,
            children: [
              for (final node in controller.nodes.values)
                if (titled.contains(node.id))
                  UnboundedPositioned(
                    key: ValueKey('node-title/${node.id}'),
                    left: node.visualPosition.value.dx,
                    top:
                        node.visualPosition.value.dy -
                        productionCardHeaderExtent * scale,
                    width: node.size.value.width,
                    height: productionCardHeaderExtent * scale,
                    child: title(node),
                  ),
              for (final group
                  in controller.nodes.values.whereType<ProductionFlowGroup>())
                UnboundedPositioned(
                  left: group.visualPosition.value.dx,
                  top:
                      group.visualPosition.value.dy -
                      productionCardHeaderExtent,
                  width: group.size.value.width,
                  height: productionCardHeaderExtent,
                  child: hit(
                    group,
                    onTap: () => select(group),
                    child: Text(
                      labels[group.id] ?? '',
                      key: ValueKey('group-title/${group.id}'),
                      style: typo.uiSmallSemibold.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

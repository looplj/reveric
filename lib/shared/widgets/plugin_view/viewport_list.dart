// 职责: 虚拟化插件只读列表，按可见行范围通知原生运行时创建与回收行 owner。
// 关联文件:
//   lib/shared/models/plugin/ui_tree.dart
//   lib/shared/widgets/plugin_view/input.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/performance.md
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../models/plugin/ui_tree.dart';
import 'input.dart';

class PluginUiViewportList extends HookWidget {
  const PluginUiViewportList({
    super.key,
    required this.node,
    required this.onEvent,
    required this.buildNode,
  });
  final PluginUiNode node;
  final PluginUiEventCallback onEvent;
  final Widget Function(int id) buildNode;
  @override
  Widget build(BuildContext context) {
    final controller = useScrollController();
    final last = useRef<(int, int)?>(null);
    final latest = useRef(node);
    latest.value = node;
    final callback = useRef(onEvent);
    callback.value = onEvent;
    // Rows render one screen ahead and behind; a new window is requested only
    // when the visible screen gets within half a screen of the window edge.
    void notify({bool force = false}) {
      final props = latest.value.props;
      final extent = (props['itemExtent'] as num).toDouble(),
          height = (props['height'] as num).toDouble();
      final total = (props['itemCount'] as num).toInt();
      final page = math.max(1, (height / extent).ceil());
      final visible = math.min(
        total,
        ((controller.hasClients ? controller.offset : 0) / extent).floor(),
      );
      final previous = force ? null : last.value;
      if (previous case (final first, final count)) {
        final margin = (page / 2).ceil(), end = first + count;
        if ((first == 0 || visible >= first + margin) &&
            (end >= total || visible + page <= end - margin)) {
          return;
        }
      }
      final first = math.max(0, visible - page);
      final count = math.min(total, visible + 2 * page) - first;
      if (last.value == (first, count)) {
        return;
      }
      last.value = (first, count);
      callback.value(latest.value, 'viewport', {
        'first': first,
        'count': count,
      });
    }

    useOnListenableChange(controller, notify);
    useEffect(
      () {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            notify(force: true);
          }
        });
        return null;
      },
      [node.props['itemExtent'], node.props['height'], node.props['itemCount']],
    );
    final rows = node.slots['children'] ?? const <int>[];
    final start = (node.props['firstIndex'] as num).toInt();
    return SizedBox(
      height: (node.props['height'] as num).toDouble(),
      child: ListView.builder(
        controller: controller,
        itemCount: (node.props['itemCount'] as num).toInt(),
        itemExtent: (node.props['itemExtent'] as num).toDouble(),
        itemBuilder: (context, index) =>
            index >= start && index < start + rows.length
            ? buildNode(rows[index - start])
            : const SizedBox.shrink(),
      ),
    );
  }
}

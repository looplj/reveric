// 职责: 为制作画布提供原生拖放入口、拖入反馈和导入生命周期管理。
// 关联文件:
//   lib/desktop/features/production/board.dart
//   lib/desktop/features/production/drop_orchestrator.dart
//   lib/desktop/features/production/support.dart
import 'package:flutter/material.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart' as drop;
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/theme/theme.dart';
import '../../../third/flow/vyuh_node_flow.dart' as flow;
import 'drop_orchestrator.dart';
import 'history_region.dart';
import 'support.dart';

class ProductionDropRegion extends StatefulWidget {
  const ProductionDropRegion({
    super.key,
    required this.service,
    required this.canvasId,
    required this.controller,
    required this.child,
  });
  final ProductionCanvasService service;
  final String canvasId;
  final flow.NodeFlowController<String, String> controller;
  final Widget child;

  @override
  State<ProductionDropRegion> createState() => _ProductionDropRegionState();
}

class _ProductionDropRegionState extends State<ProductionDropRegion> {
  bool _hovering = false;
  bool _importing = false;

  void _hover(bool value) {
    if (mounted && _hovering != value) {
      setState(() => _hovering = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final history = ProductionHistoryScope.maybeOf(context)?.history;
    return drop.DropRegion(
      formats: ProductionDropOrchestrator.formats,
      onDropOver: (event) {
        final accept =
            !_importing &&
            event.session.allowedOperations.contains(drop.DropOperation.copy) &&
            event.session.items.any(
              (item) => ProductionDropOrchestrator.formats.any(item.canProvide),
            );
        _hover(accept);
        return accept ? drop.DropOperation.copy : drop.DropOperation.none;
      },
      onDropLeave: (_) => _hover(false),
      onDropEnded: (_) => _hover(false),
      onPerformDrop: (event) async {
        _hover(false);
        if (_importing) {
          return;
        }
        setState(() => _importing = true);
        final service = widget.service;
        final canvasId = widget.canvasId;
        final position = widget.controller
            .globalToGraph(flow.ScreenPosition(event.position.global))
            .offset;
        try {
          for (final (index, item) in event.session.items.indexed) {
            if (!mounted || widget.canvasId != canvasId) {
              break;
            }
            await productionRun(context, () async {
              final reader = item.dataReader;
              if (reader == null) {
                throw const FormatException('Dropped data is unavailable');
              }
              await ProductionDropOrchestrator().run(
                reader: reader,
                service: service,
                canvasId: canvasId,
                position: position + Offset(index * 48, index * 48),
                history: history,
              );
            });
          }
        } finally {
          if (mounted) {
            setState(() => _importing = false);
          }
        }
      },
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          if (_hovering)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: colors.accent, width: 2),
                  ),
                ),
              ),
            ),
          if (_importing)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(child: LinearProgressIndicator()),
            ),
        ],
      ),
    );
  }
}

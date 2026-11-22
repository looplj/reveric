// 职责: 为制作画布提供原生拖放入口、拖入反馈和素材导入进度。
// 关联文件:
//   lib/desktop/features/production/board.dart
//   lib/desktop/features/production/drop_orchestrator.dart
//   lib/desktop/features/production/support.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
import 'dart:io';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart' as drop;
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
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
    this.importProgress,
  });

  /// `super_drag_and_drop` 在 `flutter test` 环境缺少原生 DropManager/DragManager 实现；
  /// 仅当测试专门验证拖入区域本身时再显式开启。
  @visibleForTesting
  static bool enableInTests = false;

  final ProductionCanvasService service;
  final String canvasId;
  final flow.NodeFlowController<String, String> controller;
  final Widget child;

  /// null 表示空闲，0 表示正在读取首个素材，其余值表示已处理文件的比例。
  final ValueListenable<double?>? importProgress;

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
    final progress = widget.importProgress;
    Widget indicator(BuildContext context, double? value, Widget? child) {
      if (value == null && !_importing) {
        return const SizedBox.shrink();
      }
      return LinearProgressIndicator(
        value: value == 0 ? null : value,
        semanticsLabel: context.t(LocaleKeys.libraryImportingTxt),
      );
    }

    final colors = RevericTheme.colorsOf(context);
    final child = Stack(
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
        if (_importing || progress != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: progress == null
                  ? indicator(context, null, null)
                  : ValueListenableBuilder(
                      valueListenable: progress,
                      builder: indicator,
                    ),
            ),
          ),
      ],
    );
    if (Platform.environment.containsKey('FLUTTER_TEST') &&
        !ProductionDropRegion.enableInTests) {
      return child;
    }
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
      child: child,
    );
  }
}

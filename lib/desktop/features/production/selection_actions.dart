// 职责: 为制作画布的多选节点提供确认软删除入口，并在删除前关闭当前编辑会话。
// 关联文件:
//   lib/desktop/features/production/board.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'history_region.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/confirm_dialog.dart';
import '../../../third/flow/vyuh_node_flow.dart' as flow;
import '../canvas/widgets/glass.dart';
import 'support.dart';

class ProductionSelectionActions extends HookWidget {
  const ProductionSelectionActions({
    super.key,
    required this.service,
    required this.controller,
    required this.onDeleted,
    this.beforeDelete,
  });
  final ProductionCanvasService service;
  final flow.NodeFlowController<String, String> controller;
  final VoidCallback onDeleted;
  final Future<bool> Function()? beforeDelete;
  @override
  Widget build(BuildContext context) {
    final history = ProductionHistoryScope.maybeOf(context)?.history;
    final busy = useState(false);
    return Observer(
      builder: (_) {
        final selected = controller.selectedNodeIds.toSet();
        if (selected.length < 2 || controller.isDrawingSelection) {
          return const SizedBox.shrink();
        }
        return Material(
          type: MaterialType.transparency,
          child: CanvasGlass(
            raised: true,
            child: RevericButton.text(
              key: const ValueKey('production-delete-selection'),
              label: context.t(LocaleKeys.commonDelete),
              icon: RevericIcons.delete,
              size: RevericButtonSize.compact,
              onPressed: busy.value
                  ? null
                  : () => productionRun(context, () async {
                      busy.value = true;
                      try {
                        if (beforeDelete != null && !await beforeDelete!()) {
                          return;
                        }
                        final roots = [
                          for (final id in selected)
                            await service.requireNode(id),
                        ];
                        final expanded = {...selected};
                        for (final node in roots) {
                          if (node.type == canvasNodeTypeGroup) {
                            expanded.addAll(
                              (await service.groups.members(
                                node.id,
                              )).map((n) => n.id),
                            );
                          }
                        }
                        if (!context.mounted) {
                          return;
                        }
                        final confirmed = await showConfirmDialog(
                          context,
                          title: context.t(LocaleKeys.commonDelete),
                          message: context.t(
                            LocaleKeys.productionSelectionDeleteConfirm,
                            namedArgs: {'count': '${expanded.length}'},
                          ),
                          confirmLabel: context.t(LocaleKeys.commonDelete),
                          variant: ConfirmDialogVariant.error,
                        );
                        if (confirmed) {
                          await service.removeNodes(
                            roots.first.canvasId,
                            selected,
                            history: history,
                          );
                          if (context.mounted) {
                            onDeleted();
                          }
                        }
                      } finally {
                        if (context.mounted) {
                          busy.value = false;
                        }
                      }
                    }),
            ),
          ),
        );
      },
    );
  }
}

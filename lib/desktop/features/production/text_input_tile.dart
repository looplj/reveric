// 职责: 显示文本提示词输入的两行摘要，仅提供排序与断开操作。
// 关联文件:
//   lib/desktop/features/production/input_preview.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/components/reveric_context_menu.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/theme/theme.dart';

class ProductionTextInputTile extends HookWidget {
  const ProductionTextInputTile({
    super.key,
    required this.service,
    required this.input,
    required this.onMove,
    required this.onRemove,
  });
  final ProductionCanvasService service;
  final ProductionInput input;
  final ValueChanged<int>? onMove;
  final VoidCallback onRemove;
  @override
  Widget build(BuildContext context) {
    final node = useStream(
      useMemoized(() => service.db.canvasDao.watchNodeById(input.refId), [
        service,
        input.refId,
      ]),
    );
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Tooltip(
      message: node.data?.title ?? input.refId,
      child: Material(
        color: colors.surfaceDim,
        borderRadius: BorderRadius.circular(RevericRadius.xl),
        child: InkWell(
          borderRadius: BorderRadius.circular(RevericRadius.xl),
          onTap: () {
            final box = context.findRenderObject()! as RenderBox;
            showRevericContextMenu(
              context: context,
              position: box.localToGlobal(Offset.zero),
              entries: [
                RevericMenuItem(
                  icon: RevericIcons.arrow_upward_rounded,
                  label: context.t(LocaleKeys.storyboardUp),
                  enabled: onMove != null,
                  onTap: () => onMove?.call(-1),
                ),
                RevericMenuItem(
                  icon: RevericIcons.arrow_downward_rounded,
                  label: context.t(LocaleKeys.storyboardDown),
                  enabled: onMove != null,
                  onTap: () => onMove?.call(1),
                ),
                RevericMenuItem(
                  icon: RevericIcons.link_off,
                  label: context.t(LocaleKeys.productionUnlink),
                  onTap: onRemove,
                ),
              ],
            );
          },
          child: SizedBox(
            width: RevericSizes.productionTextInputWidth,
            height: RevericSizes.productionInputTileSize,
            child: Padding(
              padding: const EdgeInsets.all(RevericSpacing.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.t(LocaleKeys.productionText),
                    style: typo.uiTiny.copyWith(color: colors.textMuted),
                  ),
                  Expanded(
                    child: Text(
                      node.hasError ||
                              node.connectionState == ConnectionState.active &&
                                  node.data == null
                          ? context.t(
                              LocaleKeys.productionGenerateReferenceMissing,
                            )
                          : node.data?.content ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSmall.copyWith(color: colors.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

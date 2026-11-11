// 职责: 生成输入框上排的一格输入缩略图：角标写用途，点开改用途、调顺序、断开或预览。
// 关联文件:
//   lib/desktop/features/production/composer.dart
//   lib/desktop/features/production/node_card.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/localization/locale_keys.dart
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
import '../../../shared/models/video/request.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/services/production/generate_orchestrator.dart';
import '../../../shared/theme/theme.dart';
import 'node_card.dart';
import 'support.dart';
import 'text_input_tile.dart';
import '../../../shared/database/app_database.dart' show AssetRow;

/// 输入格边长。
const double productionInputTileSize = RevericSizes.productionInputTileSize;

class ProductionInputTile extends HookWidget {
  const ProductionInputTile({
    super.key,
    required this.service,
    required this.input,
    required this.valid,
    this.mode,
    this.supportsMiddleFrames = false,
    this.middleFrameIndex,
    required this.onRole,
    required this.onMove,
    required this.onRemove,
  });
  final ProductionCanvasService service;
  final ProductionInput input;

  /// 用途在当前生成方式下可用。
  final bool valid;
  final VideoMode? mode;
  final bool supportsMiddleFrames;
  final int? middleFrameIndex;
  final ValueChanged<VideoInputRole>? onRole;

  /// -1 前移，1 后移；到头时为 null。
  final void Function(int delta)? onMove;
  final VoidCallback onRemove;
  @override
  Widget build(BuildContext context) {
    final asset = useStream(
      useMemoized(
        () => input.isPrompt
            ? const Stream<AssetRow>.empty()
            : service.watchInputAsset(input),
        [service, input.id, input.refType, input.refId, input.roleName],
      ),
    );
    final assetId = asset.hasError ? null : asset.data?.id;
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final name = asset.hasError
        ? context.t(LocaleKeys.productionGenerateReferenceMissing)
        : asset.data?.name ?? input.refId;
    final hovered = useState(false);
    if (input.isPrompt) {
      return ProductionTextInputTile(
        service: service,
        input: input,
        onMove: onMove,
        onRemove: onRemove,
      );
    }

    void menu() {
      final box = context.findRenderObject()! as RenderBox;
      showRevericContextMenu(
        context: context,
        position: box.localToGlobal(const Offset(0, -RevericSpacing.sm)),
        anchor: Alignment.bottomLeft,
        minWidth: 200,
        entries: [
          if (assetId != null) ...[
            RevericMenuItem(
              icon: RevericIcons.play_arrow,
              label: context.t(LocaleKeys.productionPreviewAdopted),
              onTap: () => productionRun(
                context,
                () => previewProductionAsset(context, service, assetId),
              ),
            ),
            const RevericMenuDivider(),
          ],
          if (onRole != null)
            for (final role in VideoInputRole.values.where(
              (r) =>
                  r.kind == input.role.kind &&
                  (r != VideoInputRole.middle_frame || supportsMiddleFrames),
            ))
              RevericMenuItem(
                label: productionRole(context, role, mode: mode),
                trailing: role == input.role
                    ? RevericIcon(
                        RevericIcons.check,
                        size: 12,
                        color: colors.accent,
                      )
                    : null,
                onTap: () => onRole?.call(role),
              ),
          const RevericMenuDivider(),
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
            description: context.t(LocaleKeys.productionUnlinkHint),
            iconColor: colors.error,
            labelColor: colors.error,
            onTap: onRemove,
          ),
        ],
      );
    }

    return Tooltip(
      message: [
        '$name · ${productionRole(context, input.role, mode: mode, middleFrameIndex: middleFrameIndex)}',
        if (mode != null &&
            productionSubmitRole(mode!, input.role) != input.role)
          context.t(LocaleKeys.productionFrameReferenceHint),
      ].join('\n'),
      constraints: const BoxConstraints(maxWidth: 320),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => hovered.value = true,
        onExit: (_) => hovered.value = false,
        child: GestureDetector(
          onTap: menu,
          child: Container(
            width: productionInputTileSize,
            height: productionInputTileSize,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: colors.surfaceDim,
              borderRadius: BorderRadius.circular(RevericRadius.xl),
              border: Border.all(
                color: !valid || asset.hasError
                    ? colors.error
                    : hovered.value
                    ? colors.accent
                    : colors.borderSubtle,
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ProductionAssetThumb(
                  service: service,
                  asset: asset.hasError ? null : asset.data,
                ),
                Positioned(
                  left: 3,
                  bottom: 3,
                  right: 3,
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: colors.textPrimary.withValues(alpha: .55),
                        borderRadius: BorderRadius.circular(
                          RevericRadius.small,
                        ),
                      ),
                      child: Text(
                        productionRole(
                          context,
                          input.role,
                          mode: mode,
                          middleFrameIndex: middleFrameIndex,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.uiTinySemibold.copyWith(
                          color: colors.onAccent,
                        ),
                      ),
                    ),
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

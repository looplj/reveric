// 职责: 制作画布的浮动控件：左下工具簇里的资产库 / 导入，与底部居中的「＋」添加节点菜单。
// 关联文件:
//   lib/desktop/features/production/region.dart
//   lib/desktop/features/production/board.dart
//   lib/desktop/features/canvas/widgets/floating_cluster.dart
//   lib/shared/components/reveric_context_menu.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/canvas.json
//   assets/translations/zh-CN/canvas.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/assets.json
//   assets/translations/zh-CN/assets.json
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md

import 'package:flutter/material.dart';
import '../../../shared/components/reveric_context_menu.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/theme/theme.dart';
import '../canvas/widgets/floating_cluster.dart';
import '../canvas/widgets/glass.dart';
import 'history_region.dart';
import 'history_actions.dart';

/// 「＋」菜单里的节点类型。素材类先从资产库选内容再落到画布；分镜从场次色带底部添加。
enum ProductionAddKind {
  video,
  image,
  character,
  location,
  compendium,
  audio,
  director,
  editing,
  text,
}

/// 左下角工具簇里跟在缩放后面的一组：从资产库放素材、导入文件。
class ProductionCanvasTools extends StatelessWidget {
  const ProductionCanvasTools({
    super.key,
    required this.onAssets,
    required this.onImport,
  });
  final VoidCallback? onAssets;
  final VoidCallback? onImport;
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (ProductionHistoryScope.maybeOf(context)?.history
            case final history?)
          ListenableBuilder(
            listenable: history,
            builder: (context, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CanvasFloatingButton(
                  icon: RevericIcons.undo,
                  tooltip: context.t(LocaleKeys.commonUndo),
                  onTap: history.canUndo
                      ? () => Actions.invoke(
                          context,
                          const ProductionUndoIntent(),
                        )
                      : null,
                  divider: true,
                ),
                CanvasFloatingButton(
                  icon: RevericIcons.redo,
                  tooltip: context.t(LocaleKeys.commonRedo),
                  onTap: history.canRedo
                      ? () => Actions.invoke(
                          context,
                          const ProductionRedoIntent(),
                        )
                      : null,
                ),
              ],
            ),
          ),
        CanvasFloatingButton(
          icon: RevericIcons.folder_outlined,
          tooltip: context.t(LocaleKeys.productionAssets),
          onTap: onAssets,
          divider: true,
        ),
        CanvasFloatingButton(
          icon: RevericIcons.upload,
          tooltip: context.t(LocaleKeys.commonImport),
          onTap: onImport,
        ),
      ],
    );
  }
}

/// 底部居中的添加按钮；点开向上弹出添加节点菜单。
class ProductionAddDock extends StatefulWidget {
  /// 按钮加玻璃外圈的高度；画布浮层据此让出底部空间。
  static const double extent = 46 + RevericSpacing.xs * 2;

  const ProductionAddDock({
    super.key,
    required this.enabled,
    required this.onAdd,
    required this.onImport,
    this.canvasWork = false,
  });

  final bool canvasWork;

  /// 各类型当前是否可建。
  final bool Function(ProductionAddKind kind) enabled;
  final ValueChanged<ProductionAddKind> onAdd;
  final VoidCallback onImport;
  @override
  State<ProductionAddDock> createState() => _ProductionAddDockState();
}

class _ProductionAddDockState extends State<ProductionAddDock> {
  bool _open = false;
  bool _hovered = false;

  Future<void> _show() async {
    final colors = RevericTheme.colorsOf(context);
    final box = context.findRenderObject()! as RenderBox;
    final anchor = box.localToGlobal(Offset(box.size.width / 2, -12));
    final items = [
      (
        ProductionAddKind.video,
        RevericIcons.video_camera,
        LocaleKeys.productionFreeVideo,
        LocaleKeys.productionAddVideoHint,
      ),
      (
        ProductionAddKind.image,
        RevericIcons.image,
        LocaleKeys.mediaImages,
        LocaleKeys.productionAddImageHint,
      ),
      (
        ProductionAddKind.character,
        RevericIcons.person,
        LocaleKeys.productionCharacter,
        LocaleKeys.productionAddCharacterHint,
      ),
      (
        ProductionAddKind.location,
        RevericIcons.location_on,
        LocaleKeys.productionLocation,
        LocaleKeys.productionAddLocationHint,
      ),
      (
        ProductionAddKind.compendium,
        RevericIcons.inventory_2,
        LocaleKeys.workspaceSidebarCompendium,
        LocaleKeys.productionAddCompendiumHint,
      ),
      (
        ProductionAddKind.audio,
        RevericIcons.waveform,
        LocaleKeys.mediaAudio,
        LocaleKeys.productionAddAudioHint,
      ),
      (
        ProductionAddKind.director,
        RevericIcons.person_simple_walk,
        LocaleKeys.directorTitle,
        LocaleKeys.productionAddDirectorHint,
      ),
      (
        ProductionAddKind.text,
        RevericIcons.file_text,
        LocaleKeys.productionText,
        LocaleKeys.productionAddTextHint,
      ),
    ];
    if (widget.canvasWork) {
      items.removeWhere(
        (item) => const {
          ProductionAddKind.character,
          ProductionAddKind.location,
          ProductionAddKind.compendium,
        }.contains(item.$1),
      );
      items.add((
        ProductionAddKind.editing,
        RevericIcons.scissors_outlined,
        LocaleKeys.editingTitle,
        LocaleKeys.productionAddEditingHint,
      ));
    }
    setState(() => _open = true);
    await showRevericContextMenu(
      context: context,
      position: anchor,
      anchor: Alignment.bottomCenter,
      minWidth: 300,
      maxWidth: 320,
      entries: [
        for (final (kind, icon, label, hint) in items)
          RevericMenuItem(
            label: context.t(label),
            description: context.t(hint),
            enabled: widget.enabled(kind),
            leading: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(RevericRadius.xl),
              ),
              child: Center(
                child: RevericIcon(icon, size: 18, color: colors.textSecondary),
              ),
            ),
            onTap: () => widget.onAdd(kind),
          ),
        const RevericMenuDivider(),
        RevericMenuItem(
          icon: RevericIcons.upload,
          label: context.t(LocaleKeys.commonImport),
          description: context.t(LocaleKeys.productionImportHint),
          onTap: widget.onImport,
        ),
      ],
    );
    if (mounted) {
      setState(() => _open = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final lifted = _hovered && !_open;
    return CanvasGlass(
      circle: true,
      padding: const EdgeInsets.all(RevericSpacing.xs),
      child: Tooltip(
        message: context.t(LocaleKeys.productionAddNode),
        child: AnimatedScale(
          scale: lifted ? 1.06 : 1,
          duration: CanvasMotion.hover,
          curve: CanvasMotion.curve,
          child: Material(
            color: _open ? colors.accentWarm : colors.accent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _open ? null : _show,
              onHover: (value) => setState(() => _hovered = value),
              child: SizedBox(
                width: 46,
                height: 46,
                child: Center(
                  // 「＋」转 45° 成「×」，菜单开合有方向感。
                  child: AnimatedRotation(
                    turns: _open ? .125 : 0,
                    duration: CanvasMotion.hover,
                    curve: CanvasMotion.curve,
                    child: RevericIcon(
                      RevericIcons.add,
                      size: 20,
                      color: colors.onAccent,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

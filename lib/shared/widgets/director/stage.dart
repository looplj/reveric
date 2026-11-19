// 职责: 组合导演视口、视角下拉、悬浮机位预览、方向球、撤销重做与编辑工具条和布景历史。
// 关联文件:
//   lib/shared/widgets/director/viewport.dart
//   lib/shared/widgets/director/history_panel.dart
//   lib/shared/widgets/director/camera_preview.dart
//   lib/shared/services/director/session.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../components/reveric_button.dart';
import '../../components/reveric_icon_button.dart';
import '../../components/reveric_select.dart';
import '../../services/director/session.dart';
import '../../theme/theme.dart';
import 'camera_preview.dart';
import 'history_panel.dart';
import 'orientation.dart';
import 'strings.dart';
import 'viewport.dart';

class DirectorStage extends HookWidget {
  const DirectorStage({
    super.key,
    required this.session,
    required this.view,
    this.viewportBuilder,
    this.showPreview = true,
    this.showViewMode = true,
  });
  final DirectorSession session;
  final ViewState view;

  /// 宽布局在视口右上角悬浮机位预览；窄屏空间不够时不显示。
  final bool showPreview;

  /// 没有顶栏承载视角下拉时，悬浮在视口顶部居中。
  final bool showViewMode;
  final Widget Function(DirectorSession, ViewState)? viewportBuilder;

  @override
  Widget build(BuildContext context) {
    useListenable(view);
    useListenableSelector(
      session,
      () => (
        session.tool,
        session.history.canUndo,
        session.history.canRedo,
        session.hasPendingInput,
        session.cameraMode,
        session.viewCameraId,
        session.history.document.activeCameras.length,
      ),
    );
    final historyOpen = useState(false);
    final measured = useRef<(DirectorSession, Size)?>(null);
    final colors = RevericTheme.colorsOf(context);
    Widget stage(Size size) => ColoredBox(
      color: colors.canvas,
      child: Stack(
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child:
                  viewportBuilder?.call(session, view) ??
                  DirectorViewport(session: session, view: view),
            ),
          ),
          if (showViewMode)
            Positioned(
              top: RevericSpacing.lg,
              left: RevericSpacing.lg,
              right: RevericSpacing.lg,
              child: Align(
                alignment: Alignment.topCenter,
                child: DirectorViewModeSelect(session: session, view: view),
              ),
            ),
          if (!view.output && showPreview)
            Positioned(
              // 视口放不下居中的视角下拉和预览窗时，预览窗下移避让。
              top:
                  !showViewMode ||
                      size.width >=
                          RevericSizes.directorModeSwitchWidth +
                              2 *
                                  (RevericSizes.directorPreviewWidth +
                                      2 * RevericSpacing.lg)
                  ? RevericSpacing.lg
                  : 2 * RevericSpacing.lg + RevericSizes.fieldHeightSm,
              right: RevericSpacing.lg,
              width: RevericSizes.directorPreviewWidth,
              child: DirectorCameraPreview(
                session: session,
                viewportBuilder: viewportBuilder,
              ),
            ),
          if (!view.output)
            Positioned(
              right: RevericSpacing.lg,
              bottom: RevericSpacing.lg,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  DirectorOrientation(view: view),
                  const SizedBox(height: RevericSpacing.sm),
                  RevericButton.secondary(
                    label: tr(context, 'reset_view'),
                    icon: RevericIcons.arrow_counter_clockwise,
                    size: RevericButtonSize.compact,
                    onPressed: view.home,
                  ),
                ],
              ),
            ),
          if (!session.readOnly)
            Positioned(
              left: RevericSpacing.lg,
              right: RevericSpacing.lg,
              bottom: RevericSpacing.lg,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (session.versions != null && historyOpen.value) ...[
                    DirectorHistoryPanel(
                      session: session,
                      onClose: () => historyOpen.value = false,
                    ),
                    const SizedBox(height: RevericSpacing.sm),
                  ],
                  Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Dock(session: session),
                        if (session.versions != null) ...[
                          const SizedBox(width: RevericSpacing.sm),
                          _RoundButton(
                            icon: RevericIcons.history_outlined,
                            tooltip: tr(context, 'history'),
                            selected: historyOpen.value,
                            onPressed: () =>
                                historyOpen.value = !historyOpen.value,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final measurement = (session, size);
        if (size.isFinite && !size.isEmpty && measured.value != measurement) {
          measured.value = measurement;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted && measured.value == measurement) {
              session.history.updateViewportSize(size.width, size.height);
            }
          });
        }
        return stage(size);
      },
    );
  }
}

class _Dock extends StatelessWidget {
  const _Dock({required this.session});
  final DirectorSession session;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Container(
      height: RevericSizes.directorDockHeight,
      padding: const EdgeInsets.all(RevericSpacing.xxs),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(RevericRadius.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RevericIconButton(
            key: const ValueKey('director-undo'),
            icon: RevericIcons.undo,
            tooltip: tr(context, 'undo'),
            onPressed: session.history.canUndo && !session.hasPendingInput
                ? () => session.attempt(session.history.undo)
                : null,
          ),
          RevericIconButton(
            key: const ValueKey('director-redo'),
            icon: RevericIcons.redo,
            tooltip: tr(context, 'redo'),
            onPressed: session.history.canRedo && !session.hasPendingInput
                ? () => session.attempt(session.history.redo)
                : null,
          ),
          VerticalDivider(
            width: RevericSpacing.lg,
            indent: RevericSpacing.xs,
            endIndent: RevericSpacing.xs,
            color: colors.borderSubtle,
          ),
          for (final tool in [
            ('select', RevericIcons.cursor),
            ('rotate', RevericIcons.arrows_clockwise),
          ])
            Semantics(
              selected: session.tool == tool.$1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: session.tool == tool.$1
                      ? colors.selected
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(RevericRadius.x2l),
                ),
                child: RevericIconButton(
                  key: ValueKey('director-tool:${tool.$1}'),
                  icon: tool.$2,
                  tooltip: tr(context, tool.$1),
                  onPressed: () => session.setTool(tool.$1),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onPressed,
  });
  final String icon, tooltip;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Container(
      width: RevericSizes.directorDockHeight,
      height: RevericSizes.directorDockHeight,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: selected ? colors.selected : colors.surface,
        shape: CircleBorder(side: BorderSide(color: colors.border)),
      ),
      child: RevericIconButton(
        icon: icon,
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }
}

/// 视角下拉：导演视角、按切镜输出，或固定某个机位输出；与机位预览共用机位选择。
class DirectorViewModeSelect extends StatelessWidget {
  const DirectorViewModeSelect({
    super.key,
    required this.session,
    required this.view,
  });
  final DirectorSession session;
  final ViewState view;

  static const _director = '', _sequence = '\u0000sequence';

  @override
  Widget build(BuildContext context) {
    final value = !view.output
        ? _director
        : session.cameraMode == 'sequence'
        ? _sequence
        : session.viewCameraId;
    return SizedBox(
      width: RevericSizes.directorModeSwitchWidth,
      child: RevericSelect<String>(
        key: const ValueKey('director-view-mode'),
        value: value,
        height: RevericSizes.fieldHeightSm,
        items: [
          RevericSelectItem(value: _director, label: tr(context, 'edit_view')),
          RevericSelectItem(
            value: _sequence,
            label: tr(context, 'sequence'),
            icon: RevericIcons.video_camera,
          ),
          for (final camera in session.history.document.activeCameras)
            RevericSelectItem(
              value: camera['id'] as String,
              label: camera['name'],
              icon: RevericIcons.video_camera,
            ),
        ],
        onChanged: (next) {
          if (next != _director) {
            session.viewCamera(next == _sequence ? null : next);
          }
          view.update(() => view.output = next != _director);
        },
      ),
    );
  }
}

// 职责: 锚定在触发器上方或下方的桌面弹层，放不下时翻转并收回窗口内，点外部关闭。
// 关联文件:
//   lib/desktop/features/production/popover.dart
//   lib/desktop/features/production/spec_panel.dart
//   lib/desktop/features/canvas/widgets/zoom_control.dart
// 遵循的 Rules:
//   .agents/rules/design-system.md

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// 锚定弹层：点触发器在它上方或下方展开面板；点面板外关闭。
///
/// 桌面端用；移动端的弹出选择走 bottom sheet（见 design-system.md）。
class RevericPopover extends StatefulWidget {
  const RevericPopover({
    super.key,
    required this.trigger,
    required this.panel,
    this.up = false,
    this.alignEnd = false,
    this.initiallyOpen = false,
    this.open,
    this.onOpenChanged,
  });

  final Widget Function(BuildContext context, bool open, VoidCallback toggle)
  trigger;
  final Widget Function(BuildContext context, VoidCallback close) panel;

  /// 优先向上展开，比如触发器贴在窗口或画布底部。
  final bool up;

  /// 面板右沿与触发器右沿对齐，比如触发器靠右排列。
  final bool alignEnd;

  /// 挂载后直接展开（从别处跳过来查看这个面板）。
  final bool initiallyOpen;

  /// Optional external open state; omitted callers retain local control.
  final bool? open;
  final ValueChanged<bool>? onOpenChanged;

  @override
  State<RevericPopover> createState() => _RevericPopoverState();
}

class _RevericPopoverState extends State<RevericPopover> {
  final _controller = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    if (widget.open ?? widget.initiallyOpen) {
      // 等触发器完成布局，面板才有可跟随的锚点。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_controller.isShowing) {
          setState(_controller.show);
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant RevericPopover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open != null && widget.open != oldWidget.open) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _setOpen(widget.open!);
        }
      });
    }
  }

  void _setOpen(bool open) {
    if (!mounted || _controller.isShowing == open) {
      return;
    }
    setState(open ? _controller.show : _controller.hide);
  }

  void _toggle() {
    final next = !_controller.isShowing;
    _setOpen(next);
    widget.onOpenChanged?.call(next);
  }

  void _close() {
    if (_controller.isShowing) {
      _setOpen(false);
      widget.onOpenChanged?.call(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _controller,
      overlayChildBuilder: (context, info) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
            ),
          ),
          CustomSingleChildLayout(
            delegate: _PopoverLayout(
              anchor: MatrixUtils.transformRect(
                info.childPaintTransform,
                Offset.zero & info.childSize,
              ),
              up: widget.up,
              alignEnd: widget.alignEnd,
            ),
            child: widget.panel(context, _close),
          ),
        ],
      ),
      child: widget.trigger(context, _controller.isShowing, _toggle),
    );
  }
}

/// 优先保持展开方向；放不下时翻转，再把整个面板移回窗口内。
class _PopoverLayout extends SingleChildLayoutDelegate {
  const _PopoverLayout({
    required this.anchor,
    required this.up,
    required this.alignEnd,
  });

  final Rect anchor;
  final bool up;
  final bool alignEnd;
  static const _gap = RevericSpacing.sm;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.max(0, constraints.maxWidth - _gap * 2),
        maxHeight: math.max(0, constraints.maxHeight - _gap * 2),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final above = anchor.top - _gap - childSize.height;
    final below = anchor.bottom + _gap;
    final fitsAbove = above >= _gap;
    final fitsBelow = below + childSize.height <= size.height - _gap;
    final showAbove = up ? fitsAbove || !fitsBelow : !fitsBelow && fitsAbove;
    final left = alignEnd ? anchor.right - childSize.width : anchor.left;
    return Offset(
      left.clamp(_gap, math.max(_gap, size.width - childSize.width - _gap)),
      (showAbove ? above : below).clamp(
        _gap,
        math.max(_gap, size.height - childSize.height - _gap),
      ),
    );
  }

  @override
  bool shouldRelayout(_PopoverLayout oldDelegate) =>
      anchor != oldDelegate.anchor ||
      up != oldDelegate.up ||
      alignEnd != oldDelegate.alignEnd;
}

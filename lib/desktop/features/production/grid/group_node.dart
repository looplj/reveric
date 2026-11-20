// 职责: 渲染制作分组外框并约束普通组的四角缩放与成员外接范围。
// 关联文件:
//   lib/desktop/features/production/board.dart
//   lib/shared/models/production/group_layout.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../support.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:mobx/mobx.dart' show Observable, runInAction;
import '../../../../shared/models/production/group_layout.dart';
import '../../../../shared/theme/theme.dart';
import '../../../../shared/components/reveric_icon_button.dart';
import '../../../../shared/localization/app_localization.dart';
import '../../../../shared/localization/locale_keys.dart';
import '../../../../third/flow/vyuh_node_flow.dart' as flow;

class ProductionFlowGroup extends flow.GroupNode<String> {
  ProductionFlowGroup({
    required super.id,
    required super.position,
    required super.size,
    required super.ports,
  }) : super(
         title: '',
         data: id,
         behavior: flow.GroupBehavior.parent,
         preserveWhenEmpty: true,
       );

  ProductionGroupLayout layout = const FreeGroupLayout();
  Map<int, String> slots = const {};
  bool savingFrame = false;
  final dropSlot = Observable<int?>(null);

  void highlightSlot(int? slot) => runInAction(() => dropSlot.value = slot);

  /// 最近一次换位前各成员的画布坐标；格子据此从旧位置滑到新格位。
  final landing = Observable<Map<String, Offset>>(const {});

  // 标题虽画在外框上方，也必须进入 flow 的空间命中范围，避免根 Listener
  // 在标题选中后把同一次点击当作画布空白并清空选中。
  @override
  Rect getBounds() {
    final frame = super.getBounds();
    return Rect.fromLTRB(
      frame.left,
      frame.top - productionCardHeaderExtent,
      frame.right,
      frame.bottom,
    );
  }

  @override
  bool containsPoint(Offset point) => getBounds().contains(point);

  // 制作分组只提供四角，避免 flow 默认八个手柄绕过成员边界约束。
  @override
  bool get isResizable => false;
  @override
  Widget? buildWidget(BuildContext context) => null;

  Rect get memberBounds => freeGroupMinFrame([
    for (final id in nodeIds)
      if (groupContext?.getNode(id) case final member?)
        member.position.value & member.size.value,
  ]);

  Rect constrain(Rect frame) =>
      memberBounds.isEmpty ? frame : frame.expandToInclude(memberBounds);

  void setFrame(Rect frame) => runInAction(() {
    position.value = frame.topLeft;
    setVisualPosition(frame.topLeft);
    size.value = frame.size;
  });

  @override
  void onChildResized(String nodeId, Size newSize) =>
      onChildMoved(nodeId, Offset.zero);

  @override
  void onChildMoved(String nodeId, Offset newPosition) {
    if (layout is FreeGroupLayout && !dragging.value) {
      setFrame(constrain(position.value & size.value));
    }
  }
}

class ProductionGroupNode extends StatelessWidget {
  const ProductionGroupNode({
    super.key,
    required this.group,
    required this.onResize,
    required this.onFill,
    this.readOnly = false,
  });
  final ProductionFlowGroup group;
  final Future<void> Function(Rect) onResize;
  final ValueChanged<int> onFill;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final storyboard = group.layout is StoryboardGroupLayout;
    return Observer(
      builder: (_) => Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceDim,
                border: Border.all(
                  color: group.isSelected ? colors.accent : colors.borderSubtle,
                ),
                borderRadius: BorderRadius.circular(
                  storyboard ? 0 : RevericRadius.canvasNode,
                ),
              ),
            ),
          ),
          if (group.layout case final StoryboardGroupLayout layout)
            for (var slot = 0; slot < layout.capacity; slot++)
              if (!group.slots.containsKey(slot))
                Positioned.fromRect(
                  rect: layout.cellOffset(slot) & layout.cellSize,
                  child: Stack(
                    children: [
                      if (!readOnly)
                        Center(
                          child: RevericIconButton(
                            key: ValueKey('group-empty/${group.id}/$slot'),
                            icon: RevericIcons.add,
                            tooltip: context.t(LocaleKeys.commonAdd),
                            onPressed: () => onFill(slot),
                          ),
                        ),
                      if (layout.numbered)
                        Positioned(
                          left: RevericSpacing.sm,
                          top: RevericSpacing.sm,
                          child: Text(
                            '${slot + 1}',
                            style: RevericTheme.typographyOf(
                              context,
                            ).uiSmallSemibold,
                          ),
                        ),
                    ],
                  ),
                ),
          if (!readOnly && !storyboard && group.isSelected)
            for (final corner in [
              Alignment.topLeft,
              Alignment.topRight,
              Alignment.bottomLeft,
              Alignment.bottomRight,
            ])
              Align(
                alignment: corner,
                child: _Corner(
                  group: group,
                  corner: corner,
                  onResize: onResize,
                ),
              ),
          if (group.layout case final StoryboardGroupLayout layout)
            if (group.dropSlot.value case final slot?)
              Positioned.fromRect(
                rect: layout.cellOffset(slot) & layout.cellSize,
                child: IgnorePointer(
                  child: DecoratedBox(
                    key: ValueKey('group-drop/${group.id}/$slot'),
                    decoration: BoxDecoration(
                      color: colors.accent.withValues(alpha: .15),
                      border: Border.all(color: colors.accent, width: 2),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _Corner extends HookWidget {
  const _Corner({
    required this.group,
    required this.corner,
    required this.onResize,
  });
  final ProductionFlowGroup group;
  final Alignment corner;
  final Future<void> Function(Rect) onResize;
  @override
  Widget build(BuildContext context) {
    final start = useRef<Rect?>(null);
    useEffect(
      () => () {
        if (start.value case final frame?) {
          group.setFrame(frame);
        }
      },
      [group],
    );
    final colors = RevericTheme.colorsOf(context);
    void cancel() {
      if (start.value case final frame?) {
        group.setFrame(frame);
      }
      start.value = null;
    }

    return Listener(
      onPointerCancel: (_) => cancel(),
      child: GestureDetector(
        key: ValueKey('group-resize/${group.id}/$corner'),
        supportedDevices: productionPointerDragDevices,
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) {
          if (!group.savingFrame) {
            start.value = group.position.value & group.size.value;
          }
        },
        onPanCancel: cancel,
        onPanUpdate: (details) {
          if (start.value == null) {
            return;
          }
          final frame = group.position.value & group.size.value;
          final delta = details.delta;
          final next = Rect.fromLTRB(
            corner.x < 0 ? frame.left + delta.dx : frame.left,
            corner.y < 0 ? frame.top + delta.dy : frame.top,
            corner.x > 0 ? frame.right + delta.dx : frame.right,
            corner.y > 0 ? frame.bottom + delta.dy : frame.bottom,
          );
          if (next.width >= 100 && next.height >= 60) {
            group.setFrame(group.constrain(next));
          }
        },
        onPanEnd: (_) {
          final original = start.value;
          start.value = null;
          if (original == null) {
            return;
          }
          group.savingFrame = true;
          productionRun(context, () async {
            try {
              await onResize(group.position.value & group.size.value);
            } catch (_) {
              group.setFrame(original);
              rethrow;
            } finally {
              group.savingFrame = false;
            }
          });
        },
        child: SizedBox.square(
          dimension: RevericSpacing.lg,
          child: Center(
            child: Container(
              width: RevericSpacing.sm,
              height: RevericSpacing.sm,
              color: colors.accent,
            ),
          ),
        ),
      ),
    );
  }
}

// 职责: 在分镜组内拖拽成员到目标格位，提交交换或移入空位并处理取消，拖起与落位带动效。
// 关联文件:
//   lib/desktop/features/production/board.dart
//   lib/desktop/features/production/grid/group_node.dart
//   lib/shared/services/production/group_service.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import '../history_region.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:mobx/mobx.dart' show reaction, runInAction;
import '../../../../shared/theme/canvas_colors.dart';
import '../../../../shared/theme/theme.dart';
import '../../../../shared/services/production/group_service.dart';
import '../../../../shared/models/production/group_layout.dart';
import '../../../../third/flow/vyuh_node_flow.dart' as flow;
import '../support.dart';
import 'group_node.dart';

class ProductionStoryboardCell extends HookWidget {
  const ProductionStoryboardCell({
    super.key,
    required this.group,
    required this.controller,
    required this.service,
    required this.memberId,
    required this.child,
  });
  final ProductionFlowGroup group;
  final flow.NodeFlowController<String, String> controller;
  final ProductionGroupService service;
  final String memberId;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final history = ProductionHistoryScope.maybeOf(context)?.history;
    final colors = RevericTheme.colorsOf(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final saving = useState(false);
    final cancelled = useRef(false);
    // 拖动位移和落位补间都在格子自身坐标系（即画布坐标）里，画布缩放不影响跟手。
    final drag = useValueNotifier(Offset.zero);
    final dragStart = useRef(Offset.zero);
    final lift = useAnimationController(
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 140),
    );
    final settle = useAnimationController(
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 180),
      initialValue: 1,
    );
    final settleFrom = useRef(Offset.zero);
    void land(Offset from) {
      settleFrom.value = from;
      drag.value = Offset.zero;
      settle.forward(from: 0);
      lift.reverse();
    }

    useEffect(
      () =>
          () => group.highlightSlot(null),
      [group],
    );
    // 换位后从换位前的位置滑进新格位；被换走的那格同样由这里接住。
    useEffect(
      () => reaction((_) => group.landing.value, (landing) {
        final from = landing[memberId];
        final node = controller.getNode(memberId);
        if (from != null && node != null) {
          land(from - node.position.value);
        }
      }).call,
      [group, memberId],
    );
    void cancel() {
      cancelled.value = true;
      group.highlightSlot(null);
      land(drag.value);
    }

    void hover(Offset global) {
      final box =
          controller.canvasKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) {
        return;
      }
      final local =
          controller
              .screenToGraph(flow.ScreenPosition(box.globalToLocal(global)))
              .offset -
          group.position.value;
      final layout = group.layout as StoryboardGroupLayout;
      int? slot;
      for (var i = 0; i < layout.capacity; i++) {
        if ((layout.cellOffset(i) & layout.cellSize).contains(local)) {
          slot = i;
          break;
        }
      }
      group.highlightSlot(slot);
    }

    return Listener(
      onPointerCancel: (_) => cancel(),
      child: GestureDetector(
        key: ValueKey('storyboard-cell/$memberId'),
        supportedDevices: productionPointerDragDevices,
        behavior: HitTestBehavior.opaque,
        // 从按下处算位移，越过拖动阈值时卡片不会落后指针一截。
        dragStartBehavior: DragStartBehavior.down,
        onPanStart: saving.value
            ? null
            : (details) {
                cancelled.value = false;
                dragStart.value = details.localPosition;
                controller.bringNodeToFront(memberId);
                lift.forward();
                hover(details.globalPosition);
              },
        onPanUpdate: saving.value
            ? null
            : (details) {
                drag.value = details.localPosition - dragStart.value;
                hover(details.globalPosition);
              },
        onPanCancel: cancel,
        onPanEnd: (_) {
          final slot = group.dropSlot.value;
          group.highlightSlot(null);
          final layout = group.layout as StoryboardGroupLayout;
          final slots = group.slots;
          final from = slots.entries
              .where((e) => e.value == memberId)
              .firstOrNull
              ?.key;
          if (cancelled.value ||
              slot == null ||
              saving.value ||
              from == null ||
              from == slot) {
            if (!cancelled.value) {
              land(drag.value);
            }
            return;
          }
          // 先在画布上换位，库提交后的刷新只做核对，松手不必等整轮读写。
          void place(Map<int, String> next, {Offset carried = Offset.zero}) {
            group.slots = next;
            final landing = <String, Offset>{};
            for (final MapEntry(key: at, value: id) in next.entries) {
              final target = group.position.value + layout.cellOffset(at);
              final current = controller.getNode(id)?.position.value;
              if (current != null && current != target) {
                landing[id] = id == memberId ? current + carried : current;
                controller.setNodePosition(id, target);
              }
            }
            runInAction(() => group.landing.value = landing);
          }

          final next = Map.of(slots)..remove(from);
          if (slots[slot] case final other?) {
            next[from] = other;
          }
          place(next..[slot] = memberId, carried: drag.value);
          saving.value = true;
          productionRun(context, () async {
            try {
              await service.swapSlot(
                group.id,
                memberId,
                slot,
                history: history,
              );
            } catch (_) {
              if (identical(group.layout, layout)) {
                place(slots);
              }
              rethrow;
            } finally {
              if (context.mounted) {
                saving.value = false;
              }
            }
          });
        },
        child: MouseRegion(
          cursor: saving.value
              ? SystemMouseCursors.progress
              : SystemMouseCursors.grab,
          child: AnimatedBuilder(
            animation: Listenable.merge([drag, lift, settle]),
            builder: (_, child) {
              final lifted = Curves.easeOut.transform(lift.value);
              final settling = 1 - Curves.easeOutCubic.transform(settle.value);
              return Transform.translate(
                offset: drag.value + settleFrom.value * settling,
                child: Transform.scale(
                  scale: 1 + .04 * lifted,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      boxShadow: lifted == 0
                          ? null
                          : [
                              for (final shadow in canvasGlassShadows(colors))
                                BoxShadow.lerp(null, shadow, lifted)!,
                            ],
                    ),
                    child: child,
                  ),
                ),
              );
            },
            child: Observer(
              builder: (_) => DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  border: group.slots[group.dropSlot.value] == memberId
                      ? Border.all(color: colors.accent, width: 2)
                      : null,
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

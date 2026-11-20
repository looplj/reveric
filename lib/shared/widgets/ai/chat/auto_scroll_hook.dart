// 职责: 聊天列表滚动 hook — 流式跟随、用户上滑暂停、ask-user 首次揭示、会话切换重置、审批卡定位揭示
// 关联文件:
//   lib/shared/widgets/ai/chat/ui_message.dart
//   lib/shared/models/ai_message_block.dart
//   lib/shared/widgets/ai/tool_approval_card.dart
//   lib/desktop/widgets/ai/chat/panel.dart
//   lib/mobile/pages/chat_session_page.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../../models/ai_message_block.dart';
import '../tool_approval_card.dart';
import 'ui_message.dart';

/// 管理聊天列表的自动贴底滚动，返回应挂到 ListView 的 [ScrollController]。
///
/// 行为：
/// - 流式输出时每帧 `jumpTo` 贴底（丝滑跟随，避免动画 fighting）；
/// - 上下文压缩等尾部活动状态出现时贴底，确保用户能立即看到状态提示；
/// - 用户手动上滑后停止自动滚动（[userScrolledUp] 被置 true）；
/// - ask-user pending 首次出现时滚到底展示问题，之后尊重用户上滑；
/// - [sessionId] 变化时重置 [userScrolledUp]，新会话默认贴底。
///
/// 调用方传入自己的 [userScrolledUp]：桌面复用 `AiChatPanelState.userScrolledUp`
/// （与 composer / agent_factory 的 `resetScroll` 耦合保持不变），移动端自建一个。
ScrollController useChatAutoScroll({
  required List<UIMessage> uiMessages,
  required ObjectRef<bool> userScrolledUp,
  required String? sessionId,
  bool hasTrailingActivity = false,
}) {
  final context = useContext();
  final scrollController = useScrollController(keepScrollOffset: false);
  final isAutoScrolling = useRef(false);
  final revealedPendingAskUserKey = useRef<String?>(null);

  String? pendingAskUserKey() {
    final callIds = <String>[];
    for (final m in uiMessages) {
      for (final b in m.blocks) {
        if (b is AiAskUserBlock && b.isPending) {
          callIds.add(b.callId);
        }
      }
    }
    if (callIds.isEmpty) {
      return null;
    }
    return callIds.join('|');
  }

  // lazy 项布局后 maxScrollExtent 可能增长，跨帧重复贴底直到收敛。
  void convergeJumpToBottom(int attempt) {
    if (!scrollController.hasClients || !context.mounted) return;
    if (userScrolledUp.value) return; // 用户上滑 → 停止收敛
    if (attempt >= 6) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!scrollController.hasClients || !context.mounted) return;
      if (userScrolledUp.value) return;
      final pos = scrollController.position;
      if (!pos.hasContentDimensions) {
        return;
      }
      if (pos.pixels < pos.maxScrollExtent - 0.5) {
        isAutoScrolling.value = true;
        scrollController.jumpTo(pos.maxScrollExtent);
        isAutoScrolling.value = false;
        convergeJumpToBottom(attempt + 1);
      }
    });
  }

  void jumpToBottom({bool converge = false}) {
    if (!scrollController.hasClients) return;
    final pos = scrollController.position;
    if (!pos.hasContentDimensions) {
      return;
    }
    if (pos.maxScrollExtent <= 0) return;
    // 流式每帧 jumpTo 会同步触发滚动监听；置 isAutoScrolling 让监听器忽略本次程序滚动，
    // 避免把用户上滑时刚置位的 userScrolledUp 又冲回 false（移动端流式无法上滑的根因）。
    isAutoScrolling.value = true;
    scrollController.jumpTo(pos.maxScrollExtent);
    isAutoScrolling.value = false;
    if (converge) convergeJumpToBottom(0);
  }

  Future<void> animateToBottom() async {
    if (!scrollController.hasClients) return;
    final pos = scrollController.position;
    if (!pos.hasContentDimensions) {
      return;
    }
    if (pos.maxScrollExtent <= 0) return;
    if (pos.pixels >= pos.maxScrollExtent - 1) {
      userScrolledUp.value = false;
      return;
    }
    isAutoScrolling.value = true;
    try {
      await scrollController.animateTo(
        pos.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      if (!context.mounted) return;
      userScrolledUp.value = false;
    } finally {
      isAutoScrolling.value = false;
    }
  }

  void maybeAutoScroll() {
    if (!scrollController.hasClients) return;
    final pos = scrollController.position;
    if (!pos.hasContentDimensions) {
      return;
    }
    // ask-user pending：新问题出现时贴底一次以展示问题；之后尊重用户上滑，
    // 避免 pending 期间持续滚底导致回看困难、点击卡片时滚动抖动和高 CPU。
    final askUserKey = pendingAskUserKey();
    if (askUserKey != null) {
      if (revealedPendingAskUserKey.value != askUserKey) {
        revealedPendingAskUserKey.value = askUserKey;
        userScrolledUp.value = false;
        final distance = pos.maxScrollExtent - pos.pixels;
        if (distance > pos.viewportDimension * 1.5) {
          jumpToBottom(converge: true);
        } else {
          animateToBottom();
        }
      }
      return;
    }
    revealedPendingAskUserKey.value = null;

    // 用户手动上滑 → 不自动滚动。
    if (userScrolledUp.value) return;
    final streaming =
        hasTrailingActivity ||
        (uiMessages.isNotEmpty &&
            (uiMessages.last.isStreaming || uiMessages.last.isStreamingTail));
    if (streaming) {
      // 已贴底时不重复 jumpTo：messages 仅因非高度字段（状态/分组 identity）变化
      // 触发本 effect 时，maxScrollExtent 未增长，jumpTo 是 no-op 却仍会通知滚动监听
      // 并驱动整棵消息列表重排重绘。仅在真正有新增内容（pixels 落后于 max）时跳。
      if (pos.pixels < pos.maxScrollExtent - 0.5) {
        jumpToBottom();
      }
      return;
    }
    // 非流式：新消息插入或会话加载。距离远则瞬切（会话切换/长跳），近则平滑滑动。
    final distance = pos.maxScrollExtent - pos.pixels;
    if (distance > pos.viewportDimension * 1.5) {
      jumpToBottom(converge: true);
      userScrolledUp.value = false;
    } else if (distance > 1) {
      animateToBottom();
    }
  }

  // 监听滚动位置 → 维护 userScrolledUp（用户上滑标记）。
  useEffect(() {
    void listener() {
      if (!scrollController.hasClients) return;
      final pos = scrollController.position;
      if (!pos.hasContentDimensions) return; // viewport 尚未应用 content dimensions
      // 用户主动上滑（forward = 朝列表顶部；手指拖动 / 滚轮 / 触控板都会经
      // updateUserScrollDirection 置位）→ 立刻暂停自动跟随。程序 jumpTo/animateTo
      // 走 ballistic/idle，userScrollDirection 不会是 forward，故只会捕获真实用户操作，
      // 避免流式 jumpTo 把用户的拖动手势打断后又被误判回贴底。
      if (pos.userScrollDirection == ScrollDirection.forward) {
        userScrolledUp.value = true;
        return;
      }
      final atBottom = pos.pixels >= pos.maxScrollExtent - 48;
      // 程序滚动（流式 jumpTo / 贴底动画）期间一律忽略：既不误判为「用户上滑」，
      // 也不把用户上滑刚置位的 userScrolledUp 在贴底瞬间冲回 false。
      if (isAutoScrolling.value) return;
      if (atBottom) {
        // 回到底部 → 恢复自动跟随。
        if (userScrolledUp.value) userScrolledUp.value = false;
      } else {
        // 离开底部但非 forward 来源（如拖动滚动条）→ 也暂停跟随。
        if (!userScrolledUp.value) userScrolledUp.value = true;
      }
    }

    scrollController.addListener(listener);
    return () => scrollController.removeListener(listener);
  }, [scrollController]);

  // 会话切换 → 重置上滑标记，让新会话默认贴底。
  useEffect(() {
    userScrolledUp.value = false;
    return null;
  }, [sessionId]);

  // 消息列表变化（流式/新消息/ask-user）→ 按需自动贴底。
  useEffect(() {
    if (uiMessages.isEmpty) return null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      maybeAutoScroll();
    });
    return null;
  }, [uiMessages, hasTrailingActivity]);

  return scrollController;
}

/// 揭示审批卡最多滚动的帧数；首帧按比例估算，之后每帧移动一屏。
const _maxRevealSteps = 40;

/// 让运行条能定位到滚出懒加载范围的审批卡，返回包装列表项的函数。
///
/// 列表项必须经返回的函数包装，hook 据此得知当前构建了哪些消息：目标消息不在
/// 构建范围时先按比例跳一次，再朝目标方向逐屏跳，消息建出来后交给
/// [ToolApprovalLocator.focus] 精确滚到卡片并高亮。程序跳转会让
/// [useChatAutoScroll] 置位上滑标记，不会被贴底逻辑拉回。
Widget Function(int index, Widget child) useApprovalReveal({
  required ToolApprovalLocator locator,
  required ScrollController controller,
  required List<UIMessage> uiMessages,
}) {
  final built = useMemoized(() => <int>{});
  final messages = useRef(uiMessages);
  messages.value = uiMessages;

  useEffect(() {
    Future<void> reveal(String approvalId, String hostCallId) async {
      final target = messages.value.indexWhere(
        (message) => message.blocks.any(
          (block) => switch (block) {
            AiToolCallBlock(:final callId) => callId == hostCallId,
            AiImageBlock(:final id) => id == 'img_$hostCallId',
            _ => false,
          },
        ),
      );
      if (target < 0) {
        return;
      }
      for (var step = 0; step < _maxRevealSteps; step++) {
        if (!controller.hasClients || built.isEmpty) {
          return;
        }
        final pos = controller.position;
        if (!pos.hasContentDimensions) {
          return;
        }
        final first = built.reduce(math.min);
        final last = built.reduce(math.max);
        if (target >= first && target <= last) {
          locator.focus(approvalId);
          return;
        }
        final count = messages.value.length;
        final next = step == 0 && count > 1
            ? pos.maxScrollExtent * target / (count - 1)
            : target < first
            ? pos.pixels - pos.viewportDimension
            : pos.pixels + pos.viewportDimension;
        controller.jumpTo(
          next.clamp(pos.minScrollExtent, pos.maxScrollExtent).toDouble(),
        );
        await WidgetsBinding.instance.endOfFrame;
      }
    }

    locator.addRevealer(reveal);
    return () => locator.removeRevealer(reveal);
  }, [locator, controller]);

  return (index, child) =>
      _RevealSlot(index: index, built: built, child: child);
}

/// 挂载期间把自己的消息下标登记进 [built]。
class _RevealSlot extends StatefulWidget {
  const _RevealSlot({
    required this.index,
    required this.built,
    required this.child,
  });

  final int index;
  final Set<int> built;
  final Widget child;

  @override
  State<_RevealSlot> createState() => _RevealSlotState();
}

class _RevealSlotState extends State<_RevealSlot> {
  @override
  void initState() {
    super.initState();
    widget.built.add(widget.index);
  }

  @override
  void didUpdateWidget(_RevealSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index || oldWidget.built != widget.built) {
      oldWidget.built.remove(oldWidget.index);
      widget.built.add(widget.index);
    }
  }

  @override
  void dispose() {
    widget.built.remove(widget.index);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 聊天列表滚动通知处理：用户一开始触摸拖动就立即暂停自动跟随。
///
/// 移动端流式每帧 `jumpTo` 贴底会触发 `goIdle()`，进而**取消正在进行的触摸拖动手势**，
/// 导致「流式时无法上滑」。仅靠 ScrollController 监听器在拖出方向后才置位 [userScrolledUp]
/// 太晚——手势可能已被下一帧 jumpTo 取消。这里在拖动起点（[ScrollStartNotification] 带
/// [dragDetails]）抢先置位，后续 jumpTo 即被 `maybeAutoScroll` 跳过，手势得以存活。
///
/// 桌面滚轮/触控板走 pointer-scroll，不产生带 dragDetails 的 drag 通知，故不受影响。
/// 返回 false：不拦截通知，继续向上冒泡。
bool handleChatUserDragNotification(
  ScrollNotification notification,
  ObjectRef<bool> userScrolledUp,
) {
  if (notification is ScrollStartNotification &&
      notification.dragDetails != null) {
    userScrolledUp.value = true;
  }
  return false;
}

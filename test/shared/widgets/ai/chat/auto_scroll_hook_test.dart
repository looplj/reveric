// 职责: 测试聊天滚动 hook 的贴底跟随、AskUser 首次揭示与审批卡定位揭示
// 关联文件:
//   lib/shared/widgets/ai/chat/auto_scroll_hook.dart
//   lib/shared/widgets/ai/chat/ui_message.dart
//   lib/shared/models/ai_message_block.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/widgets/ai/chat/auto_scroll_hook.dart';
import 'package:reveric/shared/widgets/ai/chat/ui_message.dart';
import 'package:reveric/shared/widgets/ai/tool_approval_card.dart';

void main() {
  testWidgets(
    'pending AskUser is revealed once and does not fight user scrollback',
    (tester) async {
      final messages = _messagesWithPendingAskUser();

      await tester.pumpWidget(_wrap(_AutoScrollHarness(uiMessages: messages)));
      await tester.pumpAndSettle();

      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      final position = scrollable.position;
      expect(position.pixels, position.maxScrollExtent);

      await tester.drag(find.byType(ListView), const Offset(0, 260));
      await tester.pump();

      final scrolledBackOffset = position.pixels;
      expect(scrolledBackOffset, lessThan(position.maxScrollExtent));

      await tester.pumpWidget(
        _wrap(_AutoScrollHarness(uiMessages: _messagesWithPendingAskUser())),
      );
      await tester.pumpAndSettle();

      expect(position.pixels, scrolledBackOffset);
    },
  );

  testWidgets(
    'streaming follow still triggers when content grows past the viewport',
    (tester) async {
      // 意图：流式贴底必须在新内容真正增长（pixels 落后于 max）时仍然 jumpTo。
      // 若「已贴底就跳过」的 guard 误伤真增长，本测试失败。
      var messages = _streamingMessages(tailHeight: 480);

      await tester.pumpWidget(_wrap(_AutoScrollHarness(uiMessages: messages)));
      await tester.pumpAndSettle();

      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      expect(position.pixels, position.maxScrollExtent);

      // 流式继续：尾部增高（maxScrollExtent 增长），但仍是同一条 streaming 消息的新 identity。
      messages = _streamingMessages(tailHeight: 720);
      await tester.pumpWidget(_wrap(_AutoScrollHarness(uiMessages: messages)));
      await tester.pumpAndSettle();

      expect(position.pixels, position.maxScrollExtent);
    },
  );

  testWidgets(
    'compaction activity reveals its trailing status without a message update',
    (tester) async {
      final messages = _staticMessages();

      await tester.pumpWidget(
        _wrap(
          _AutoScrollHarness(uiMessages: messages, hasTrailingActivity: false),
        ),
      );
      await tester.pumpAndSettle();

      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      expect(position.pixels, position.maxScrollExtent);

      // Compact 开始不会新增普通消息；仍必须滚到新增的瞬态状态行。
      await tester.pumpWidget(
        _wrap(
          _AutoScrollHarness(uiMessages: messages, hasTrailingActivity: true),
        ),
      );
      await tester.pumpAndSettle();

      expect(position.pixels, position.maxScrollExtent);
    },
  );

  testWidgets('locating an approval card scrolls it back into the lazy list', (
    tester,
  ) async {
    // 意图：审批卡所在消息滚出懒加载范围后未挂载，运行条定位仍须把它滚出来并高亮。
    final locator = ToolApprovalLocator();
    addTearDown(locator.dispose);
    final messages = _messagesWithApprovalHost(hostIndex: 2);

    await tester.pumpWidget(
      _wrap(_RevealHarness(uiMessages: messages, locator: locator)),
    );
    await tester.pumpAndSettle();
    expect(find.text('approval card'), findsNothing);

    locator.locate('run_1', hostCallId: 'host_call');
    await tester.pumpAndSettle();

    expect(find.text('approval card'), findsOneWidget);
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(
      scrollable.position.pixels,
      lessThan(scrollable.position.maxScrollExtent),
    );
    await tester.pump(const Duration(seconds: 2));
  });
}

List<UIMessage> _messagesWithApprovalHost({required int hostIndex}) {
  return [
    for (var i = 0; i < 40; i++)
      UIMessage(
        id: 'message_$i',
        role: AiMessageRole.assistant,
        type: AiMessageType.text,
        content: 'message $i',
        blocks: [
          if (i == hostIndex)
            const AiToolCallBlock(
              id: 'host_block',
              callId: 'host_call',
              toolName: 'Batch',
              arguments: {},
            ),
        ],
        isStreaming: false,
        isStreamingTail: false,
        sourceIds: ['message_$i'],
      ),
  ];
}

class _RevealHarness extends HookWidget {
  const _RevealHarness({required this.uiMessages, required this.locator});

  final List<UIMessage> uiMessages;
  final ToolApprovalLocator locator;

  @override
  Widget build(BuildContext context) {
    final userScrolledUp = useRef(false);
    final controller = useChatAutoScroll(
      uiMessages: uiMessages,
      userScrolledUp: userScrolledUp,
      sessionId: 'session_1',
    );
    final revealSlot = useApprovalReveal(
      locator: locator,
      controller: controller,
      uiMessages: uiMessages,
    );
    return ListView.builder(
      controller: controller,
      itemCount: uiMessages.length,
      itemBuilder: (context, index) => revealSlot(
        index,
        uiMessages[index].blocks.isEmpty
            ? SizedBox(height: 160, child: Text('message $index'))
            : _FakeApprovalCard(locator: locator),
      ),
    );
  }
}

class _FakeApprovalCard extends HookWidget {
  const _FakeApprovalCard({required this.locator});

  final ToolApprovalLocator locator;

  @override
  Widget build(BuildContext context) {
    final anchor = useMemoized(GlobalKey.new);
    useEffect(() {
      locator.register('run_1', anchor);
      return () => locator.release('run_1', anchor);
    }, const []);
    return SizedBox(
      key: anchor,
      height: 160,
      child: const Text('approval card'),
    );
  }
}

List<UIMessage> _streamingMessages({required double tailHeight}) {
  // 用 content 长度近似驱动 tail 高度，让流式消息超过视口（320）以产生可滚动空间。
  final tail = List.generate(tailHeight ~/ 24, (i) => 'line $i').join(' ');
  return [
    UIMessage(
      id: 'streaming_message',
      role: AiMessageRole.assistant,
      type: AiMessageType.text,
      content: tail,
      blocks: const [],
      isStreaming: true,
      isStreamingTail: false,
      sourceIds: ['streaming_message'],
    ),
  ];
}

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(body: SizedBox(width: 360, height: 320, child: child)),
  );
}

class _AutoScrollHarness extends HookWidget {
  const _AutoScrollHarness({
    required this.uiMessages,
    this.hasTrailingActivity = false,
  });

  final List<UIMessage> uiMessages;
  final bool hasTrailingActivity;

  @override
  Widget build(BuildContext context) {
    final userScrolledUp = useRef(false);
    final controller = useChatAutoScroll(
      uiMessages: uiMessages,
      userScrolledUp: userScrolledUp,
      sessionId: 'session_1',
      hasTrailingActivity: hasTrailingActivity,
    );

    return ListView.builder(
      controller: controller,
      itemCount: uiMessages.length + (hasTrailingActivity ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == uiMessages.length) {
          return const SizedBox(height: 96, child: Text('compacting'));
        }
        return SizedBox(height: 96, child: Text('message $index'));
      },
    );
  }
}

List<UIMessage> _messagesWithPendingAskUser() {
  return [
    for (var i = 0; i < 12; i++)
      UIMessage(
        id: 'message_$i',
        role: AiMessageRole.assistant,
        type: AiMessageType.text,
        content: 'message $i',
        blocks: const [],
        isStreaming: false,
        isStreamingTail: false,
        sourceIds: ['message_$i'],
      ),
    const UIMessage(
      id: 'ask_user_message',
      role: AiMessageRole.assistant,
      type: AiMessageType.text,
      content: '',
      blocks: [
        AiAskUserBlock(
          id: 'ask_user_block',
          callId: 'ask_user_call',
          questions: [
            {
              'id': 'q1',
              'question': 'Pick one',
              'options': [
                {'label': 'A'},
                {'label': 'B'},
              ],
            },
          ],
        ),
      ],
      isStreaming: false,
      isStreamingTail: false,
      sourceIds: ['ask_user_message'],
    ),
  ];
}

List<UIMessage> _staticMessages() {
  return [
    for (var i = 0; i < 12; i++)
      UIMessage(
        id: 'static_$i',
        role: AiMessageRole.assistant,
        type: AiMessageType.text,
        content: 'message $i',
        blocks: const [],
        isStreaming: false,
        isStreamingTail: false,
        sourceIds: ['static_$i'],
      ),
  ];
}

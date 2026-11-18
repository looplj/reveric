// 职责: 为双端选择当前回合的建议并回传用户选择。
// 关联文件:
//   lib/shared/heuristic/chat_next_action.dart
//   lib/shared/providers/ai_providers.dart
//   lib/shared/widgets/ai/chat/next_action_bar.dart

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../heuristic/chat_next_action.dart';
import '../../../providers/ai_providers.dart';
import 'next_action_bar.dart';

class SessionNextActionBar extends ConsumerWidget {
  const SessionNextActionBar({
    super.key,
    required this.sessionId,
    required this.enabled,
    required this.onPick,
    this.showFeatureActions = true,
  });

  final String? sessionId;
  final bool enabled;
  final bool showFeatureActions;
  final ValueChanged<ChatNextAction> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!enabled) {
      return const SizedBox.shrink();
    }
    final selection = ref.watch(
      aiChatSessionProvider(sessionId).select(
        (session) => (
          sessionId: session.sessionId,
          turn: latestSuggestNextActionTurn(session.messages),
        ),
      ),
    );
    final turn = selection.turn;
    if (turn == null) {
      return const SizedBox.shrink();
    }
    return NextActionBar(
      key: ValueKey((
        selection.sessionId,
        turn.userMessageId,
        turn.block.callId,
      )),
      actions: [
        for (final raw in turn.block.suggestions)
          if (showFeatureActions || raw['kind'] != 'feature')
            ?deserializeChatNextAction(raw),
      ],
      onPick: onPick,
    );
  }
}

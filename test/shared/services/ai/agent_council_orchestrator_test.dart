// 职责: 验证 Agent Council 的会话标题生成不阻塞讨论，且在取消/失败时落点正确
// 关联文件:
//   lib/shared/services/ai/agent_council_orchestrator.dart
//   lib/shared/models/agent_council_models.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/services/ai/chat.dart

import '../../../helpers/plugin_host.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/agent_council_models.dart';
import 'package:reveric/shared/agent/agent_hook.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/services/ai/agent_council_orchestrator.dart';
import 'package:reveric/shared/services/ai/chat.dart';

/// 标题生成走 [AiClient.chatCompletionDetached]（独占 ProviderClient），
/// 这里替换掉它，让测试能精确控制标题何时返回。
class _FakeTitleAiClient extends AiClient {
  _FakeTitleAiClient(this.title)
    : super(aiProviderBuiltinDefaults.first, chatModel: 'test-model');

  final Completer<String> title;
  int detachedCalls = 0;

  @override
  Future<String> chatCompletionDetached(
    List<AiMessage> messages, {
    required Duration timeout,
    AiSessionContext? context,
    List<AgentHook> hooks = const [],
  }) {
    detachedCalls += 1;
    return title.future;
  }
}

Future<AgentCouncilSession> _start(
  AgentCouncilOrchestrator orchestrator,
  _FakeTitleAiClient client, {
  void Function(AgentCouncilSession)? onPhaseChanged,
}) {
  return orchestrator.startDiscussion(
    novelId: 'novel',
    context: const AiSessionContext(),
    topic: 'Discuss the opening scene',
    participants: const [],
    aiService: client,
    config: const AgentCouncilConfig(maxRounds: 0, autoSummarize: false),
    onPhaseChanged: onPhaseChanged,
  );
}

void main() {
  test('discussion starts without waiting for the generated title', () async {
    // 标题是旁路请求，不能挡住首轮输出 —— 否则用户要盯着空白等一整个标题
    // 往返才看到第一个字。
    final title = Completer<String>();
    final client = _FakeTitleAiClient(title);
    final phases = <CouncilPhase>[];

    final discussion = _start(
      (AgentCouncilOrchestrator()..pluginHost = emptyPluginHost()),
      client,
      onPhaseChanged: (session) => phases.add(session.phase),
    );
    await Future<void>.delayed(Duration.zero);

    expect(phases, [CouncilPhase.discussing]);

    title.complete('Opening scene review');
    final session = await discussion;

    expect(session.title, 'Opening scene review');
    expect(client.detachedCalls, 1);
  });

  test('cancelled discussion still keeps the generated title', () async {
    // 标题请求在讨论开始前就发出了，取消时它多半已经回来。丢掉它的话，会话
    // 会永久停在 provider 的兜底标题上，没有任何补偿路径。
    final title = Completer<String>();
    final client = _FakeTitleAiClient(title);
    final orchestrator = (AgentCouncilOrchestrator()
      ..pluginHost = emptyPluginHost());

    final discussion = _start(orchestrator, client);
    await Future<void>.delayed(Duration.zero);
    orchestrator.cancel();
    title.complete('Opening scene review');

    final session = await discussion;

    expect(session.title, 'Opening scene review');
    // 取消不推进阶段，收尾仍停在 discussing。
    expect(session.phase, CouncilPhase.discussing);
  });

  test(
    'title failure leaves the title empty for the provider fallback',
    () async {
      // 超时/报错时 orchestrator 不自己编标题，留空交给 provider 的
      // councilSessionTitleFmt 兜底，保证兜底文案只有一个来源。
      final title = Completer<String>();
      final client = _FakeTitleAiClient(title);

      final discussion = _start(
        (AgentCouncilOrchestrator()..pluginHost = emptyPluginHost()),
        client,
      );
      title.completeError(
        TimeoutException('chatCompletionDetached', const Duration(seconds: 20)),
      );

      final session = await discussion;

      expect(session.title, isEmpty);
      expect(session.phase, CouncilPhase.completed);
    },
  );
}

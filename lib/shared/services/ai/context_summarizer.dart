// 职责: 上下文压缩 summarizer 共享工厂 — 复用主请求前缀并生成滚动摘要
// 关联文件:
//   lib/shared/agent/agent.dart
//   lib/shared/agent/agent_context_manager.dart
//   lib/shared/agent/client.dart
//   lib/shared/agent/message.dart
//   lib/shared/services/ai/chat_turn_runner.dart
//   lib/shared/services/ai/spawn_agent_handler.dart
//   lib/shared/services/ai/prompt_template.dart
//   lib/shared/models/todo.dart
//   assets/prompts/system/context_compaction.md
import 'dart:convert';

import '../../agent/agent.dart';
import '../../agent/agent_config.dart';
import '../../agent/agent_context_manager.dart';
import '../../agent/agent_hook.dart';
import '../../agent/agent_tool_dispatcher.dart';
import '../../agent/client.dart';
import '../../agent/message.dart';
import '../../models/todo.dart';
import 'prompt_template.dart';

const _todoContextSupplementHeader = '[当前结构化 Todo 真源]';

/// 将当前活跃 Todo 格式化为压缩摘要末尾的结构化真源块。
String formatTodoContextSupplement(Iterable<Todo> todos) {
  final list = [
    for (final todo in todos)
      if (todo.content.trim().isNotEmpty &&
          (todo.isPending || todo.isInProgress))
        todo,
  ];
  final payload = [
    for (final todo in list)
      {
        'id': todo.id,
        'content': todo.content,
        'status': todo.status,
        'priority': todo.priority,
      },
  ];
  return '$_todoContextSupplementHeader\n${jsonEncode(payload)}';
}

AgentMessage buildTodoContextSupplementMessage(Iterable<Todo> todos) {
  return AgentMessage.user(
    id: 'ctx_todos',
    content: formatTodoContextSupplement(todos),
  );
}

/// 构建默认上下文压缩 summarizer。
///
/// 压缩请求复用主 Agent 的 system / memory / tools，并携带完整消息历史
/// （Codex 式全量交接而非仅溢出部分），使支持 prefix caching 的供应商
/// 能够读取主请求已写入的缓存，摘要模型也能结合最新进度写作。模型返回
/// 摘要后，运行时才把结构化 supplement 追加到结果末尾；工具 schema 保留，
/// 但 [Agent.rejectToolCalls] 会拒绝模型返回的任何工具调用。
AgentSummarizer buildDefaultContextSummarizer({
  required String agentId,
  required String systemPrompt,
  required List<String>? allowedTools,
  required ProviderClient client,
  String? providerId,
  required AgentConfig config,
  required AgentToolDispatcher toolManager,
  Future<List<AgentMessage>> Function()? contextSupplement,
  List<AgentHook> hooks = const [],
}) {
  return ({required messages, previousSummary, cancellationToken}) async {
    final compactionPrompt = PromptTemplateService.instance.rawAsset(
      'assets/prompts/system/context_compaction',
    );
    final summarizer = Agent.custom(
      id: agentId,
      systemPrompt: systemPrompt,
      client: client,
      providerId: providerId,
      config: config,
      toolManager: toolManager,
      allowedTools: allowedTools,
      initialMessages: [
        if (previousSummary != null && previousSummary.isNotEmpty)
          AgentMessage.user(
            id: 'ctx_summary',
            content: previousSummary,
            type: AgentMessageType.compact_summary,
          ),
        ...messages,
      ],
      hooks: hooks,
      emitToolEvents: false,
      rejectToolCalls: true,
    );
    final result = await summarizer.processText(
      compactionPrompt,
      toolExecutionContext: ToolExecutionContext(
        cancellationToken: cancellationToken,
      ),
    );
    final supplement = await contextSupplement?.call() ?? const [];
    return [
      result.trim(),
      ...supplement
          .map((message) => message.content.trim())
          .where((content) => content.isNotEmpty),
    ].join('\n\n');
  };
}

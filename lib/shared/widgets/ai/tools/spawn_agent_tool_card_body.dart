// 职责: SpawnAgent 工具卡片体 — 展示任务描述、执行结果与子会话详情入口。
// 关联文件:
//   lib/shared/widgets/ai/agent_round_detail_dialog.dart
//   lib/shared/widgets/ai/tools/tool_card_common.dart
//   lib/shared/widgets/ai/tools/spawn_agent_identity.dart
//   lib/shared/models/ai_message_block.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/en/tool.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/zh-CN/tool.json
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:reveric/shared/agent/agent_run_state.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/spawn_agent_run_providers.dart';
import 'package:reveric/shared/components/reveric_button.dart';
import 'package:reveric/shared/components/reveric_icon_button.dart';
import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/services/ai/tool_result_payloads.dart';
import 'package:reveric/shared/theme/theme.dart';
import '../agent_round_detail_dialog.dart';
import 'spawn_agent_identity.dart';
import 'tool_card_common.dart';

class SpawnAgentToolCardBody extends ConsumerWidget {
  const SpawnAgentToolCardBody({
    super.key,
    required this.block,
    this.novelId,
    this.databasePath,
  });

  final AiToolCallBlock block;
  final String? novelId;
  final String? databasePath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = _resolveArg(block.arguments, [
      'task',
      'task_description',
      'mission',
      'description',
      'prompt',
    ]);
    final output = (block.result?['output'] as String? ?? '').trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (task.isNotEmpty)
          AiToolKeyValueList(entries: [(context.t(LocaleKeys.toolTask), task)]),
        if (output.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.sm),
          AiToolPreviewBlock(
            label: context.t(LocaleKeys.toolExecutionResult),
            text: output,
            maxLines: 6,
          ),
        ],
        if (spawnAgentCanOpenDetail(
          block: block,
          novelId: novelId,
          databasePath: databasePath,
        )) ...[
          const SizedBox(height: RevericSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: SpawnAgentDetailButton(
              block: block,
              novelId: novelId,
              databasePath: databasePath,
            ),
          ),
        ],
      ],
    );
  }
}

class SpawnAgentDetailButton extends ConsumerWidget {
  const SpawnAgentDetailButton({
    super.key,
    required this.block,
    this.novelId,
    this.databasePath,
    this.compact = false,
    this.iconOnly = false,
  });

  final AiToolCallBlock block;
  final String? novelId;
  final String? databasePath;
  final bool compact;

  /// true 时只留图标；后台任务条一行放不下「详情」二字。
  final bool iconOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subSessionId = _subSessionIdForBlock(block);
    if (!spawnAgentCanOpenDetail(
      block: block,
      novelId: novelId,
      databasePath: databasePath,
    )) {
      return const SizedBox.shrink();
    }
    if (iconOnly) {
      return RevericIconButton(
        icon: RevericIcons.open_in_full_rounded,
        tooltip: context.t(LocaleKeys.aiDetails),
        onPressed: () => _showDetail(context, ref, subSessionId),
      );
    }
    if (compact) {
      return RevericButton.text(
        onPressed: () => _showDetail(context, ref, subSessionId),
        size: RevericButtonSize.compact,
        icon: RevericIcons.open_in_full_rounded,
        label: context.t(LocaleKeys.aiDetails),
      );
    }
    return RevericButton.secondary(
      onPressed: () => _showDetail(context, ref, subSessionId),
      icon: RevericIcons.open_in_full_rounded,
      label: context.t(LocaleKeys.aiDetails),
    );
  }

  Future<void> _showDetail(
    BuildContext context,
    WidgetRef ref,
    String subSessionId,
  ) async {
    final nid = novelId;
    final dbPath = databasePath;
    if (nid == null || nid.isEmpty || dbPath == null || dbPath.isEmpty) {
      return;
    }
    final live = ref.read(spawnAgentActiveRunProvider(block.callId));
    if (live != null) {
      await AgentRoundDetailDialog.show(
        context,
        runState: live,
        title: _agentName(context),
        databasePath: dbPath,
        novelId: nid,
      );
      return;
    }
    final persistence = ref.read(
      aiSessionPersistenceServiceProvider(novelId: nid, databasePath: dbPath),
    );
    final novelDb = ref.read(novelContentDatabaseProvider(dbPath));
    final session = await persistence.getSession(subSessionId);
    final persisted = await persistence.loadSessionMessages(
      sessionId: subSessionId,
      novelDatabase: novelDb,
    );
    if (!context.mounted) {
      return;
    }
    await AgentRoundDetailDialog.show(
      context,
      runState: _toRunState(
        agentName: session?.title ?? _agentName(context),
        messages: persisted.messages,
      ),
      title: session?.title ?? _agentName(context),
      databasePath: dbPath,
      novelId: nid,
    );
  }

  String _agentName(BuildContext context) {
    final identity = spawnAgentIdentity(block);
    final name = identity.penName ?? identity.typeName;
    return name.isEmpty ? context.t(LocaleKeys.toolNameSpawnAgent) : name;
  }

  AgentRunState _toRunState({
    required String agentName,
    required List<AiMessage> messages,
  }) {
    var text = '';
    // 有序保留推理与工具块，还原子会话「推理/工具/推理」的真实时序。
    final orderedBlocks = <AiMessageBlock>[];
    final toolResults = _toolResultsByCallId(messages);
    for (final message in messages) {
      if (message.role == AiMessageRole.assistant) {
        final content = message.effectiveText;
        if (content.trim().isNotEmpty) {
          text = content;
        }
      }
      for (final block in message.blocks) {
        switch (block) {
          case final AiThinkingBlock thinkingBlock:
            if (thinkingBlock.text.trim().isNotEmpty) {
              orderedBlocks.add(thinkingBlock);
            }
          case final AiToolCallBlock toolBlock:
            final toolResult = toolResults[toolBlock.callId];
            final effectiveError =
                toolBlock.errorMessage ?? toolResult?.errorMessage;
            // 结构化 result 优先；缺失时回退到子会话 tool_result 文本摘要。
            final resolvedResult =
                (toolBlock.result != null && toolBlock.result!.isNotEmpty)
                ? toolBlock.result
                : (toolResult?.summary.trim().isNotEmpty == true
                      ? {'summary': toolResult!.summary}
                      : null);
            orderedBlocks.add(
              toolBlock.copyWith(
                arguments: _argumentsForRunDetail(
                  toolBlock.toolName,
                  toolBlock.arguments,
                  toolBlock.result,
                ),
                status: _resolvedToolStatus(
                  blockStatus: toolBlock.status,
                  blockResult: toolBlock.result,
                  toolResult: toolResult,
                ),
                result: resolvedResult,
                errorMessage: effectiveError,
              ),
            );
          case AiAttachmentBlock():
          case AiTextBlock():
          case AiImageBlock():
          case AiAskUserBlock():
          case AiSuggestNextActionBlock():
            break;
        }
      }
    }
    return AgentRunState(
      agentId: block.callId,
      agentName: agentName,
      round: 1,
      accumulatedText: text,
      blocks: orderedBlocks,
      isComplete: true,
    );
  }

  AiToolCallStatus _resolvedToolStatus({
    required AiToolCallStatus blockStatus,
    required Map<String, dynamic>? blockResult,
    required _SubAgentToolResult? toolResult,
  }) {
    if (toolResult != null) {
      return toolResult.status;
    }
    if (blockStatus == AiToolCallStatus.success ||
        blockStatus == AiToolCallStatus.error ||
        blockStatus == AiToolCallStatus.rejected ||
        blockStatus == AiToolCallStatus.cancelled) {
      return blockStatus;
    }
    if (blockResult != null && blockResult.isNotEmpty) {
      return aiToolResultStatus(blockResult);
    }
    return blockStatus;
  }

  Map<String, dynamic> _argumentsForRunDetail(
    String toolName,
    Map<String, dynamic> arguments,
    Map<String, dynamic>? result,
  ) {
    if (toolName != 'Run') {
      return arguments;
    }
    final merged = Map<String, dynamic>.from(arguments);
    final argCommand = merged['command']?.toString().trim() ?? '';
    final resultCommand = result?['command']?.toString().trim() ?? '';
    if (argCommand.isEmpty && resultCommand.isNotEmpty) {
      merged['command'] = resultCommand;
    }
    return merged;
  }

  Map<String, _SubAgentToolResult> _toolResultsByCallId(
    List<AiMessage> messages,
  ) {
    final results = <String, _SubAgentToolResult>{};
    for (final message in messages) {
      if (message.type != AiMessageType.tool_result) {
        continue;
      }
      final metadata = message.metadata ?? const <String, dynamic>{};
      final callId = metadata['tool_call_id'] as String?;
      if (callId == null || callId.isEmpty) {
        continue;
      }
      final isError = metadata['is_error'] == true;
      results[callId] = _SubAgentToolResult(
        status: isError ? AiToolCallStatus.error : AiToolCallStatus.success,
        summary: message.content,
        errorMessage: isError ? message.content : null,
      );
    }
    return results;
  }
}

/// 运行中读取实时快照，结束后读取已保存子会话；建立身份后即可打开详情。
bool spawnAgentCanOpenDetail({
  required AiToolCallBlock block,
  required String? novelId,
  required String? databasePath,
}) {
  // 只有 SpawnAgent 持有子运行的实时快照；传话、停止等回执也带 session_id，
  // 但运行中子会话尚未落库，从它们打开只会是空白详情。
  return block.toolName == 'SpawnAgent' &&
      _subSessionIdForBlock(block).isNotEmpty &&
      novelId != null &&
      novelId.isNotEmpty &&
      databasePath != null &&
      databasePath.isNotEmpty;
}

String _subSessionIdForBlock(AiToolCallBlock block) {
  return (block.result?['session_id'] as String? ?? '').trim();
}

class _SubAgentToolResult {
  const _SubAgentToolResult({
    required this.status,
    required this.summary,
    this.errorMessage,
  });

  final AiToolCallStatus status;
  final String summary;
  final String? errorMessage;
}

String _resolveArg(Map<String, dynamic> args, List<String> keys) {
  for (final key in keys) {
    final v = args[key] as String?;
    if (v != null && v.trim().isNotEmpty) {
      return v.trim();
    }
  }
  return '';
}

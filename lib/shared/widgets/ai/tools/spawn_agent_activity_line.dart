// 职责: SpawnAgent 工具行第二行 — 展示子 Agent 的实时动态（工具调用 / 推理）与结束后的结果摘要
// 关联文件:
//   lib/shared/providers/spawn_agent_run_providers.dart
//   lib/shared/widgets/ai/tool_activity_group.dart
//   lib/shared/widgets/ai/tools/tool_card_descriptor.dart
//   lib/shared/widgets/ai/tools/tool_resource_resolver.dart
//   lib/shared/services/ai/tool_result_payloads.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/en/tool.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/zh-CN/tool.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:reveric/shared/agent/agent_run_state.dart';
import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/ai_message_block.dart';
import 'package:reveric/shared/providers/spawn_agent_run_providers.dart';
import 'package:reveric/shared/services/ai/tool_result_payloads.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/utils/utf16_safe_text.dart';
import 'tool_card_descriptor.dart';
import 'tool_resource_resolver.dart';

/// 尾部片段最多显示的字符数；超出时从末尾截取并加省略前缀。
const _activityTailMaxChars = 60;

/// SpawnAgent 行的第二行：运行中跟随子 Agent 的工具调用与推理滚动，
/// 结束后回落到已落库的 tool result（输出首行 / 错误 / 已取消），重开 app 依然可见。
class SpawnAgentActivityLine extends ConsumerWidget {
  const SpawnAgentActivityLine({
    super.key,
    required this.block,
    this.databasePath,
    this.novelId,
    this.inline = false,
  });

  final AiToolCallBlock block;
  final String? databasePath;
  final String? novelId;

  /// true 时只返回文本，由调用方排版；后台任务条把它放在同一行的名字右侧。
  final bool inline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final isActive =
        aiToolCallStatusIsActive(block.status) &&
        !(block.status == AiToolCallStatus.pending &&
            block.result?['status'] == 'running');
    // 只有运行中才订阅实时状态，历史消息不会因为子 Agent provider 变化而重建。
    final liveRun = isActive
        ? ref.watch(spawnAgentActiveRunProvider(block.callId))
        : null;
    final stopping =
        block.metadata?['background_run'] is Map &&
        block.metadata?['background_run']['status'] == 'stopping';
    final text = isActive && stopping
        ? context.t(LocaleKeys.aiBackgroundStopping)
        : block.result?['status'] == 'running' &&
              block.status == AiToolCallStatus.pending
        ? context.t(LocaleKeys.aiBackgroundNotRunning)
        : isActive
        ? (_liveText(context, ref, liveRun) ??
              context.t(LocaleKeys.toolRunning))
        : _settledText(context);
    if (text.isEmpty) {
      return const SizedBox.shrink();
    }
    if (inline) {
      return Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: typo.uiSmall.copyWith(color: colors.textMuted),
      );
    }
    return Padding(
      // 26 = 状态点 18 + 间距 8，与第一行标题左对齐。
      padding: const EdgeInsets.only(left: 26, bottom: 6),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: typo.uiSmall.copyWith(color: colors.textMuted),
      ),
    );
  }

  /// 事件流里工具块与推理块有序，最终输出文本单独累积；因此按
  /// 「最后一个块是工具 → 工具动作；是推理 → 推理尾部；尚无块 → 输出尾部」取最新动态。
  String? _liveText(BuildContext context, WidgetRef ref, AgentRunState? run) {
    if (run == null) {
      return null;
    }
    final lastBlock = run.blocks.isNotEmpty ? run.blocks.last : null;
    if (lastBlock is AiToolCallBlock) {
      final verb = toolActionVerb(context, lastBlock);
      final target = toolRowTarget(
        context,
        lastBlock,
        _resolvedResource(ref, lastBlock),
      );
      return target == null || target.isEmpty ? verb : '$verb $target';
    }
    if (lastBlock is AiThinkingBlock) {
      final thinking = _tail(lastBlock.text);
      return thinking.isEmpty ? context.t(LocaleKeys.aiThinking) : thinking;
    }
    final output = _tail(run.accumulatedText);
    return output.isEmpty ? null : output;
  }

  /// 把子 Agent 操作的路径解析成用户可读名称（「第 12 章『雨夜』」而非 `chapter_12/content`）。
  /// 见 tool_call_card：用 `.value` 保留上一帧，避免树重发时标签闪烁。
  AiToolResolvedResource? _resolvedResource(
    WidgetRef ref,
    AiToolCallBlock toolBlock,
  ) {
    final workId = novelId;
    final dbPath = databasePath;
    final path = toolPrimaryPath(toolBlock);
    if (workId == null ||
        workId.isEmpty ||
        dbPath == null ||
        dbPath.isEmpty ||
        path == null ||
        path.isEmpty) {
      return null;
    }
    if (!shouldUseResolvedResourceForToolCard(toolBlock)) {
      return null;
    }
    return ref
        .watch(
          toolResolvedResourceProvider((
            novelId: workId,
            databasePath: dbPath,
            path: path,
          )),
        )
        .value;
  }

  String _settledText(BuildContext context) {
    if (block.status == AiToolCallStatus.cancelled ||
        block.result?['cancelled'] == true) {
      return context.t(LocaleKeys.toolCancelled);
    }
    final error =
        block.errorMessage?.trim() ??
        (block.result?['error'] as String? ?? '').trim();
    if (error.isNotEmpty) {
      return _firstLine(error);
    }
    return _firstLine((block.result?['output'] as String? ?? ''));
  }

  String _tail(String raw) {
    final normalized = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= _activityTailMaxChars) {
      return normalized;
    }
    var start = normalized.length - _activityTailMaxChars;
    if (splitsSurrogatePair(normalized, start)) {
      start += 1;
    }
    return '…${normalized.substring(start)}';
  }

  String _firstLine(String raw) {
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) {
        return trimmed;
      }
    }
    return '';
  }
}

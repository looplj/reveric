// 职责: Agent Round 细节对话框 — 展示单次 agent run 的完整过程（thinking、工具调用、最终输出），可被 Council/Theater/Monologue/Chat 复用
// 关联文件:
//   lib/shared/agent/agent_run_state.dart
//   lib/shared/models/ai_message_block.dart
//   lib/shared/widgets/ai/tool_activity_group.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:reveric/shared/agent/agent_run_state.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'markdown_code_block.dart';
import 'tool_activity_group.dart';

class AgentRoundDetailDialog extends ConsumerStatefulWidget {
  final AgentRunState runState;
  final String? title;
  final String? databasePath;
  final String? novelId;

  /// 内容自持滚动时复用对话框的滚动条与控制器。
  final Widget Function(ScrollController controller)? scrollContentBuilder;

  const AgentRoundDetailDialog({
    super.key,
    required this.runState,
    this.title,
    this.databasePath,
    this.novelId,
    this.scrollContentBuilder,
  });

  static Future<void> show(
    BuildContext context, {
    required AgentRunState runState,
    String? title,
    String? databasePath,
    String? novelId,
    Widget Function(ScrollController controller)? scrollContentBuilder,
  }) {
    return showDialog(
      context: context,
      builder: (_) => AgentRoundDetailDialog(
        runState: runState,
        title: title,
        databasePath: databasePath,
        novelId: novelId,
        scrollContentBuilder: scrollContentBuilder,
      ),
    );
  }

  @override
  ConsumerState<AgentRoundDetailDialog> createState() =>
      _AgentRoundDetailDialogState();
}

class _AgentRoundDetailDialogState
    extends ConsumerState<AgentRoundDetailDialog> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final screenSize = MediaQuery.sizeOf(context);
    final dialogWidth = screenSize.width > 760
        ? 680.0
        : screenSize.width * 0.88;
    // Dialog shrink-wraps content up to this cap; short content => short dialog.
    final maxDialogHeight = (screenSize.height * 0.72).clamp(360.0, 560.0);
    // 推理块与工具块按真实时序交错（推理/工具/推理/…），最终输出单独置于末尾。
    final processBlocks = widget.runState.blocks;
    final hasProcess = processBlocks.isNotEmpty;
    final hasOutput = widget.runState.accumulatedText.isNotEmpty;

    return AlertDialog(
      backgroundColor: colors.surfaceContainerHigh,
      title: Row(
        children: [
          RevericIcon(
            RevericIcons.checklist_rounded,
            size: 18,
            color: colors.accent,
          ),
          const SizedBox(width: RevericSpacing.sm),
          Expanded(
            child: Text(
              widget.title ??
                  '${widget.runState.agentName} · Round ${widget.runState.round}',
              style: typo.uiSemibold.copyWith(color: colors.textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: dialogWidth,
          maxHeight: maxDialogHeight,
        ),
        child: SizedBox(
          width: dialogWidth,
          child: Scrollbar(
            controller: _scrollController,
            thumbVisibility: true,
            child: widget.scrollContentBuilder != null
                ? widget.scrollContentBuilder!(_scrollController)
                : SingleChildScrollView(
                    controller: _scrollController,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (hasProcess)
                          // 与主对话「执行过程」同一套步骤行，推理与工具按时序交错。
                          AiToolStepList(
                            blocks: processBlocks,
                            databasePath: widget.databasePath,
                            novelId: widget.novelId,
                            isStreamingTail: !widget.runState.isComplete,
                          ),
                        if (hasOutput) ...[
                          if (hasProcess)
                            const SizedBox(height: RevericSpacing.x2l),
                          _sectionHeader(
                            icon: RevericIcons.text_snippet_outlined,
                            label: context.t(
                              widget.runState.isComplete
                                  ? LocaleKeys.aiFinalOutputSection
                                  : LocaleKeys.aiCurrentOutputSection,
                            ),
                            colors: colors,
                            typo: typo,
                          ),
                          const SizedBox(height: RevericSpacing.sm),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(RevericSpacing.md),
                            decoration: BoxDecoration(
                              color: colors.surface,
                              borderRadius: BorderRadius.circular(
                                RevericRadius.large,
                              ),
                            ),
                            child: SelectionArea(
                              child: GptMarkdown(
                                widget.runState.accumulatedText,
                                style: typo.ui.copyWith(
                                  color: colors.textPrimary,
                                  height: 1.6,
                                ),
                                codeBuilder: buildMarkdownCodeBlock,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            context.t(LocaleKeys.commonClose),
            style: typo.uiSemibold.copyWith(color: colors.accent),
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader({
    required String icon,
    required String label,
    required RevericColors colors,
    required RevericTypography typo,
  }) {
    return Row(
      children: [
        RevericIcon(icon, size: 15, color: colors.accent),
        const SizedBox(width: RevericSpacing.xs),
        Text(label, style: typo.uiSemibold.copyWith(color: colors.textPrimary)),
      ],
    );
  }
}

// 职责: AI 工具详情内容 — 复用各 tool body、diff、错误与取消状态展示。
// 关联文件:
//   lib/shared/widgets/ai/tool_activity_group.dart
//   lib/shared/widgets/ai/tools/tool_resource_resolver.dart
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

import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/ai_message_block.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/ai/run_command_parser.dart';
import 'package:reveric/shared/services/ai/tool_result_payloads.dart';
import 'package:reveric/shared/theme/theme.dart';
import '../diff/diff_detail_dialog.dart';
import '../diff/diff_view.dart';
import 'create_tool_card_body.dart';
import 'edit_tool_card_body.dart';
import 'generic_tool_card_body.dart';
import 'mcp_tool_card_body.dart';
import 'glob_grep_tool_card_body.dart';
import 'graph_search_tool_card_body.dart';
import 'read_tool_card_body.dart';
import 'run_tool_card_body.dart';
import 'search_tool_card_body.dart';
import 'skill_tool_card_body.dart';
import 'spawn_agent_tool_card_body.dart';
import 'tool_card_descriptor.dart';
import 'tool_resource_resolver.dart';
import 'plugin_tool_card_body.dart';
import 'plugin_tool_display.dart';
import 'write_tool_card_body.dart';

Widget? aiToolBodyFor(
  BuildContext context,
  AiToolCallBlock block, {
  AiToolResolvedResource? resource,
  String? novelId,
  String? databasePath,
}) {
  if (isPluginToolBlock(block)) {
    return PluginToolCardBody(block: block);
  }
  if (block.source == 'mcp') {
    return McpToolCardBody(block: block);
  }
  final toolName = block.toolName;
  if (toolName == 'Read') {
    return ReadToolCardBody(block: block, resource: resource);
  }
  if (toolName == 'Search') {
    return SearchToolCardBody(block: block);
  }
  if (toolName == 'Glob') {
    return GlobToolCardBody(block: block);
  }
  if (toolName == 'Grep') {
    return GrepToolCardBody(block: block);
  }
  if (toolName == 'GraphSearch') {
    return GraphSearchToolCardBody(block: block);
  }
  if (toolName == 'Write') {
    return WriteToolCardBody(block: block, resource: resource);
  }
  if (toolName == 'Remove') {
    return GenericToolCardBody(block: block, resource: resource);
  }
  if (toolName == 'Edit' ||
      toolName == 'EditOutline' ||
      toolName == 'EditBeat') {
    return EditToolCardBody(block: block, resource: resource);
  }
  if (toolName == 'Create' ||
      toolName == 'CreateChapter' ||
      toolName == 'CreateCharacter' ||
      toolName == 'CreateForeshadowing' ||
      toolName == 'CreateLocation' ||
      toolName == 'CreateOutline' ||
      toolName == 'CreateBeat' ||
      toolName == 'CreateVolume') {
    return CreateToolCardBody(block: block, resource: resource);
  }
  if (toolName == 'AgentSkill') {
    return SkillToolCardBody(block: block);
  }
  if (toolName == 'SpawnAgent') {
    return SpawnAgentToolCardBody(
      block: block,
      novelId: novelId,
      databasePath: databasePath,
    );
  }
  if (toolName == 'Run') {
    if (!isRunToolCallReadyForDisplay(block)) {
      return const RunCommandLoadingBody();
    }
    return RunToolCardBody(block: block);
  }
  return GenericToolCardBody(block: block, resource: resource);
}

class AiToolDetailBody extends ConsumerWidget {
  const AiToolDetailBody({
    super.key,
    required this.block,
    this.databasePath,
    this.novelId,
    this.showDiff = true,
  });

  final AiToolCallBlock block;
  final String? databasePath;
  final String? novelId;
  final bool showDiff;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final block = aiToolOperationDisplayBlock(this.block);
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final debugMode = ref.watch(appDebugModeProvider);
    final hasError =
        block.status == AiToolCallStatus.error || block.errorMessage != null;
    final isIncompleteToolCall = isIncompleteAiToolCall(block);
    final operation = aiToolOperationResult(block);
    final errorMessage = operation == null
        ? block.errorMessage
        : switch (operation['error_code']) {
            'file_unavailable' => context.t(
              LocaleKeys.aiOperationFileUnavailable,
            ),
            'internal' => context.t(LocaleKeys.aiOperationFailedHint),
            _ when !debugMode && operation['native_session_id'] != null =>
              context.t(LocaleKeys.aiOperationFailedHint),
            _ => block.errorMessage,
          };
    final showErrorDetails =
        hasError &&
        block.source != 'mcp' &&
        (debugMode ||
            isIncompleteToolCall ||
            aiToolOperationResult(block) != null);
    final isRejected = block.status == AiToolCallStatus.rejected;
    final isCancelled = block.status == AiToolCallStatus.cancelled;
    final path = toolPrimaryPath(block);
    final resourceAsync =
        novelId == null ||
            novelId!.isEmpty ||
            databasePath == null ||
            databasePath!.isEmpty ||
            path == null ||
            path.isEmpty
        ? const AsyncValue<AiToolResolvedResource?>.data(null)
        : ref.watch(
            toolResolvedResourceProvider((
              novelId: novelId!,
              databasePath: databasePath!,
              path: path,
            )),
          );
    // .value（而非 asData?.value）保留上一帧，避免树重发时标签闪烁。
    final resource = resourceAsync.value;
    final effectiveResource = shouldUseResolvedResourceForToolCard(block)
        ? resource
        : null;
    final toolBody = aiToolBodyFor(
      context,
      block,
      resource: effectiveResource,
      novelId: novelId,
      databasePath: databasePath,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ?toolBody,
        if (showDiff && block.hasDiff && !isRejected) ...[
          const SizedBox(height: RevericSpacing.sm),
          Stack(
            children: [
              AiDiffView(
                oldText: block.diffOldText ?? '',
                newText: block.diffNewText ?? '',
              ),
              Positioned(
                top: 4,
                right: 4,
                child: Tooltip(
                  message: context.t(LocaleKeys.aiViewDiffDetail),
                  child: Material(
                    color: colors.surface.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(RevericRadius.medium),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(RevericRadius.medium),
                      onTap: () => DiffDetailDialog.show(
                        context,
                        oldText: block.diffOldText ?? '',
                        newText: block.diffNewText ?? '',
                        title: block.targetPath,
                        label: localizedToolName(context, block.toolName),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: RevericIcon(
                          RevericIcons.open_in_full_rounded,
                          size: 14,
                          color: colors.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
        if (showErrorDetails && errorMessage != null)
          Container(
            margin: const EdgeInsets.only(top: RevericSpacing.sm),
            padding: const EdgeInsets.all(RevericSpacing.sm),
            decoration: BoxDecoration(
              color: colors.deletionBg,
              borderRadius: BorderRadius.circular(RevericRadius.medium),
            ),
            child: Text(
              errorMessage,
              style: typo.uiSmall.copyWith(color: colors.deletionBorder),
            ),
          ),
        if (isCancelled)
          Container(
            margin: const EdgeInsets.only(top: RevericSpacing.sm),
            padding: const EdgeInsets.all(RevericSpacing.sm),
            decoration: BoxDecoration(
              color: colors.surfaceContainer,
              borderRadius: BorderRadius.circular(RevericRadius.medium),
            ),
            child: Text(
              context.t(LocaleKeys.toolCancelled),
              style: typo.uiSmall.copyWith(color: colors.textMuted),
            ),
          ),
      ],
    );
  }
}

// 职责: AI 工具执行过程时间线 — 将连续 thinking 与 tool call 合并为紧凑步骤组并打开详情面板。
// 关联文件:
//   lib/shared/widgets/ai/chat/chat_message_view.dart
//   lib/shared/widgets/ai/chat/compaction_card.dart
//   lib/shared/widgets/ai/tools/tool_detail_body.dart
//   lib/shared/widgets/ai/tools/tool_card_descriptor.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/en/tool.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/zh-CN/tool.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
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
import 'package:reveric/shared/widgets/stable_selection_area.dart';
import 'chat/compaction_card.dart';
import 'chat/typing_indicator.dart';
import 'tools/codemode_detail_dialog.dart';
import 'tools/spawn_agent_activity_line.dart';
import 'tools/spawn_agent_display.dart';
import 'tools/spawn_agent_identity.dart';
import 'tools/spawn_agent_tool_card_body.dart';
import 'tools/tool_card_common.dart';
import 'tools/tool_card_descriptor.dart';
import 'tools/tool_detail_body.dart';
import 'tools/tool_resource_resolver.dart';

class AiToolActivityGroup extends ConsumerStatefulWidget {
  const AiToolActivityGroup({
    super.key,
    required this.blocks,
    this.databasePath,
    this.novelId,
    this.isStreamingTail = false,
    this.isCompactingContext = false,
  });

  /// 连续的 thinking 与 tool call 块。thinking 与 tool call 同属一个活动组，
  /// 仅当 LLM 返回 text 时才会在外层切组（见 chat_message_view）。
  final List<AiMessageBlock> blocks;
  final String? databasePath;
  final String? novelId;

  /// 该组是否位于仍在 streaming 的消息尾部（组后无 text）。用于驱动尾部
  /// thinking 的 running 态与 tool 全部成功后的「继续思考」指示。
  final bool isStreamingTail;

  /// 正在整理上下文时，以压缩状态替换尾部的「思考中」指示。
  final bool isCompactingContext;

  @override
  ConsumerState<AiToolActivityGroup> createState() =>
      _AiToolActivityGroupState();
}

class _AiToolActivityGroupState extends ConsumerState<AiToolActivityGroup> {
  var _expanded = true;

  @override
  Widget build(BuildContext context) {
    final debugMode = ref.watch(appDebugModeProvider);
    final visibleBlocks = debugMode
        ? widget.blocks
        : widget.blocks
              .where(
                (block) =>
                    block is! AiToolCallBlock || !isIncompleteAiToolCall(block),
              )
              .toList(growable: false);
    if (visibleBlocks.isEmpty) {
      return const SizedBox.shrink();
    }

    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final lastBlock = visibleBlocks.last;
    final thinkingTailRunning =
        widget.isStreamingTail && lastBlock is AiThinkingBlock;
    final anyRunning =
        visibleBlocks.any(
          (block) =>
              block is AiToolCallBlock &&
              aiToolCallStatusIsActive(aiDisplayStatus(block)),
        ) ||
        thinkingTailRunning ||
        widget.isCompactingContext;

    return Container(
      margin: const EdgeInsets.only(bottom: RevericSpacing.sm),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        border: Border.all(color: colors.borderSubtle),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () {
              setState(() {
                _expanded = !_expanded;
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.md,
                vertical: RevericSpacing.sm,
              ),
              child: Row(
                children: [
                  RevericIcon(
                    RevericIcons.auto_fix_high_outlined,
                    size: 15,
                    color: colors.accent,
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  Expanded(
                    child: Text(
                      context.t(LocaleKeys.toolProcessTitle),
                      style: typo.uiMedium.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                  _CountPill(count: visibleBlocks.length, running: anyRunning),
                  const SizedBox(width: RevericSpacing.sm),
                  RevericIcon(
                    _expanded
                        ? RevericIcons.expand_less_rounded
                        : RevericIcons.expand_more_rounded,
                    size: 15,
                    color: colors.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                RevericSpacing.md,
                0,
                RevericSpacing.md,
                RevericSpacing.sm,
              ),
              child: AiToolStepList(
                blocks: visibleBlocks,
                databasePath: widget.databasePath,
                novelId: widget.novelId,
                isStreamingTail: widget.isStreamingTail,
                isCompactingContext: widget.isCompactingContext,
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(
                RevericSpacing.md,
                0,
                RevericSpacing.md,
                RevericSpacing.md,
              ),
              child: Text(
                visibleBlocks
                    .map(
                      (block) => block is AiToolCallBlock
                          // 有笔名时折叠摘要直接点名是谁在干活，比「委派任务」具体。
                          ? spawnAgentPenName(block) ??
                                localizedToolCallTitle(context, block)
                          : context.t(LocaleKeys.aiReasoningSection),
                    )
                    .join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typo.uiSmall.copyWith(color: colors.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.count, required this.running});

  final int count;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final color = running ? colors.accent : colors.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: running
            ? colors.accent.withValues(alpha: 0.14)
            : colors.surfaceDim,
        borderRadius: BorderRadius.circular(RevericRadius.pill),
      ),
      child: Text(
        running
            ? context.t(LocaleKeys.toolRunning)
            : context.t(
                LocaleKeys.toolProcessCountFmt,
                namedArgs: {'count': '$count'},
              ),
        style: typo.uiTinySemibold.copyWith(color: color, height: 1),
      ),
    );
  }
}

/// 推理与工具调用的步骤列表（左侧时间线 + 可就地展开的步骤行）。
/// 主对话在 [AiToolActivityGroup] 里使用，详情弹窗直接复用。
class AiToolStepList extends ConsumerWidget {
  static const _timelineLeft = 8.25;
  static const _timelineEndInset = 17.0;
  static const _timelineWidth = 1.5;

  const AiToolStepList({
    super.key,
    required this.blocks,
    this.databasePath,
    this.novelId,
    this.isStreamingTail = false,
    this.isCompactingContext = false,
  }) : _nestedCalls = const [],
       scrollController = null,
       footer = null;

  AiToolStepList.codemode({
    super.key,
    required AiToolCallBlock block,
    this.databasePath,
    this.novelId,
    this.scrollController,
    this.footer,
  }) : blocks = codemodeNestedBlocks(block),
       _nestedCalls = block.nestedCalls,
       isStreamingTail =
           block.status == AiToolCallStatus.pending ||
           block.status == AiToolCallStatus.running,
       isCompactingContext = false;

  final ScrollController? scrollController;
  final Widget? footer;
  final List<AiNestedToolCall> _nestedCalls;
  final List<AiMessageBlock> blocks;
  final String? databasePath;
  final String? novelId;
  final bool isStreamingTail;
  final bool isCompactingContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final lastIndex = blocks.length - 1;
    final lastBlock = blocks.isEmpty ? null : blocks[lastIndex];
    // 仅当尾部是已成功的 tool call 时显示「继续思考」loading —— 此时 LLM 已
    // 完成全部工具，正在产出后续 text/thinking。尾部为 thinking 时由该步骤
    // 自身的 running 态表达，不重复显示。
    final showContinuation =
        !isCompactingContext &&
        isStreamingTail &&
        lastBlock is AiToolCallBlock &&
        aiDisplayStatus(lastBlock) == AiToolCallStatus.success;
    final showTailStatus = showContinuation || isCompactingContext;

    if (scrollController != null) {
      return ListView.builder(
        shrinkWrap: true,
        controller: scrollController,
        padding: EdgeInsets.zero,
        itemCount:
            blocks.length +
            (showContinuation ? 1 : 0) +
            (footer == null ? 0 : 1),
        itemBuilder: (context, index) {
          if (index == blocks.length && showContinuation) {
            return _buildContinuation(context);
          }
          if (index >= blocks.length) {
            return Padding(
              padding: const EdgeInsets.only(top: RevericSpacing.lg),
              child: footer,
            );
          }
          final block = blocks[index];
          return Stack(
            key: ValueKey(block.id),
            children: [
              if (blocks.length > 1)
                Positioned(
                  left: _timelineLeft,
                  top: index == 0 ? _timelineEndInset : 0,
                  bottom: index == lastIndex ? _timelineEndInset : 0,
                  child: Container(
                    width: _timelineWidth,
                    color: colors.borderSubtle,
                  ),
                ),
              _buildStepRow(
                block,
                isLast: index == lastIndex,
                nestedCall: _nestedCalls[index],
              ),
            ],
          );
        },
      );
    }
    if (blocks.isEmpty) {
      return const SizedBox.shrink();
    }

    return Stack(
      children: [
        if (blocks.length > 1)
          Positioned(
            left: _timelineLeft,
            top: _timelineEndInset,
            bottom: showTailStatus ? 50 : _timelineEndInset,
            child: Container(width: _timelineWidth, color: colors.borderSubtle),
          ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var index = 0; index < blocks.length; index++)
              _buildStepRow(
                blocks[index],
                isLast: index == lastIndex,
                nestedCall: _nestedCalls.isEmpty ? null : _nestedCalls[index],
              ),
            if (showContinuation) _buildContinuation(context),
            if (isCompactingContext)
              Container(
                margin: const EdgeInsets.only(top: RevericSpacing.xs),
                constraints: const BoxConstraints(minHeight: 32),
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.only(left: 26),
                child: const CompactingContextIndicator(),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildContinuation(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      margin: const EdgeInsets.only(top: RevericSpacing.xs),
      constraints: const BoxConstraints(minHeight: 32),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 26),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AiTypingIndicator(colors: colors),
          const SizedBox(width: RevericSpacing.sm),
          Text(
            context.t(LocaleKeys.aiThinking),
            style: typo.uiSmall.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildStepRow(
    AiMessageBlock block, {
    required bool isLast,
    AiNestedToolCall? nestedCall,
  }) {
    if (block is AiThinkingBlock) {
      return _ThinkingStepRow(
        block: block,
        isRunning: isStreamingTail && isLast,
      );
    }
    if (block is AiToolCallBlock) {
      return _ToolStepRow(
        block: block,
        databasePath: databasePath,
        novelId: novelId,
        nestedCall: nestedCall,
      );
    }
    return const SizedBox.shrink();
  }
}

/// 工具调用步骤行 — 内联展开查看工具详情（参数 / diff / 错误），与 thinking 步骤
/// 一致就地展开，替代原来的弹窗。
class _ToolStepRow extends ConsumerStatefulWidget {
  const _ToolStepRow({
    required this.block,
    required this.databasePath,
    required this.novelId,
    this.nestedCall,
  });

  final AiNestedToolCall? nestedCall;
  final AiToolCallBlock block;
  final String? databasePath;
  final String? novelId;

  @override
  ConsumerState<_ToolStepRow> createState() => _ToolStepRowState();
}

class _ToolStepRowState extends ConsumerState<_ToolStepRow> {
  bool _expanded = false;
  AiToolCallBlock? _expandedBlock;
  bool _restoredExpansion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_restoredExpansion && widget.nestedCall != null) {
      _restoredExpansion = true;
      _expanded =
          PageStorage.maybeOf(
            context,
          )?.readState(context, identifier: widget.block.id) ==
          true;
      _expandedBlock = _expanded ? _loadNestedDetails() : null;
    }
  }

  AiToolCallBlock? _loadNestedDetails() {
    final call = widget.nestedCall;
    return call == null ? null : codemodeNestedDetails(widget.block, call);
  }

  @override
  void didUpdateWidget(covariant _ToolStepRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_expanded &&
        (oldWidget.nestedCall != widget.nestedCall ||
            oldWidget.block != widget.block)) {
      _expandedBlock = _loadNestedDetails();
    }
  }

  @override
  void dispose() {
    _expandedBlock = null;
    super.dispose();
  }

  void _toggleExpanded() {
    setState(() {
      _expanded = !_expanded;
      _expandedBlock = _expanded ? _loadNestedDetails() : null;
      if (widget.nestedCall != null) {
        PageStorage.maybeOf(
          context,
        )?.writeState(context, _expanded, identifier: widget.block.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final block = aiToolOperationDisplayBlock(
      spawnAgentDisplayBlock(ref, _expandedBlock ?? widget.block),
    );
    final databasePath = widget.databasePath;
    final novelId = widget.novelId;
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final awaitingRunSubcommand =
        block.toolName == 'Run' && !isRunToolCallReadyForDisplay(block);
    final displayStatus = awaitingRunSubcommand
        ? AiToolCallStatus.running
        : aiDisplayStatus(block);
    final debugMode = ref.watch(appDebugModeProvider);
    final isIncompleteToolCall = isIncompleteAiToolCall(block);
    final showStatus =
        !isUntrackedBackgroundSpawn(block) &&
        (isIncompleteToolCall ||
            aiToolOperationResult(block) != null ||
            shouldShowAiToolStatus(displayStatus, debugMode: debugMode));
    final path = toolPrimaryPath(block);
    final resourceAsync =
        novelId == null ||
            novelId.isEmpty ||
            databasePath == null ||
            databasePath.isEmpty ||
            path == null ||
            path.isEmpty
        ? const AsyncValue<AiToolResolvedResource?>.data(null)
        : ref.watch(
            toolResolvedResourceProvider((
              novelId: novelId,
              databasePath: databasePath,
              path: path,
            )),
          );
    // 见 tool_call_card：.value 保留上一帧，避免树重发时标签闪烁。
    final resource = resourceAsync.value;
    final effectiveResource = shouldUseResolvedResourceForToolCard(block)
        ? resource
        : null;
    final relationEndpoints =
        isRelationCreateBlock(block) &&
            databasePath != null &&
            databasePath.isNotEmpty
        ? ref
              .watch(
                toolRelationEndpointLabelsProvider((
                  databasePath: databasePath,
                  sourceType: relationCreateArg(block, 'source_type'),
                  sourceId: relationCreateArg(block, 'source_id'),
                  targetType: relationCreateArg(block, 'target_type'),
                  targetId: relationCreateArg(block, 'target_id'),
                )),
              )
              .asData
              ?.value
        : null;
    final target = awaitingRunSubcommand
        ? null
        : toolRowTarget(
            context,
            block,
            effectiveResource,
            relationEndpoints: relationEndpoints,
          );
    final title = awaitingRunSubcommand
        ? context.t(LocaleKeys.aiRunAwaitingSubcommand)
        : localizedToolCallTitle(context, block);
    final canOpen = !awaitingRunSubcommand;
    final isCodemode = block.toolName == 'Codemode';
    final isSpawnAgent = block.toolName == 'SpawnAgent';
    // SpawnAgent 的笔名作为主语，职能与模型信息放在身份 chip 中。
    final persona = isSpawnAgent ? spawnAgentIdentity(block) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: !canOpen
              ? null
              : isCodemode
              ? () => showCodemodeDetail(
                  context,
                  block: block,
                  databasePath: databasePath,
                  novelId: novelId,
                )
              : _toggleExpanded,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                if (isSpawnAgent)
                  Tooltip(
                    message: context.t(LocaleKeys.toolNameSpawnAgent),
                    child: SpawnAgentAvatar(
                      block: block,
                      status: displayStatus,
                      novelId: novelId,
                    ),
                  )
                else if (showStatus)
                  AiToolStatusDot(status: displayStatus)
                else
                  const SizedBox(width: 18, height: 18),
                const SizedBox(width: RevericSpacing.sm),
                if (persona != null && persona.hasPersona)
                  Expanded(
                    child: SpawnAgentPersonaLabel(
                      penName: persona.penName!,
                      roleLabel: spawnAgentRoleLabel(block),
                    ),
                  )
                else ...[
                  Flexible(
                    flex: 0,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSemibold.copyWith(
                        color: canOpen
                            ? colors.textPrimary
                            : colors.textSecondary,
                      ),
                    ),
                  ),
                  if (target != null && target.isNotEmpty) ...[
                    const SizedBox(width: RevericSpacing.sm),
                    Expanded(
                      child: Text(
                        target,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.uiSmall.copyWith(color: colors.textMuted),
                      ),
                    ),
                  ] else
                    const Spacer(),
                ],
                if (canOpen)
                  RevericIcon(
                    isCodemode
                        ? RevericIcons.chevron_right
                        : _expanded
                        ? RevericIcons.expand_less_rounded
                        : RevericIcons.expand_more_rounded,
                    size: 15,
                    color: colors.textSubtle,
                  ),
              ],
            ),
          ),
        ),
        if (block.toolName == 'SpawnAgent')
          SpawnAgentActivityLine(
            block: block,
            databasePath: databasePath,
            novelId: novelId,
          ),
        if (isIncompleteToolCall && !_expanded)
          Padding(
            padding: const EdgeInsets.only(left: 26, bottom: RevericSpacing.sm),
            child: Text(
              context.t(LocaleKeys.toolCallIncomplete),
              style: typo.uiSmall.copyWith(color: colors.deletionBorder),
            ),
          ),
        if (canOpen && _expanded)
          Padding(
            padding: const EdgeInsets.only(left: 26, bottom: RevericSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: RevericSpacing.sm),
                  child: Row(
                    children: [
                      if (showStatus)
                        AiToolStatusBadge(status: displayStatus)
                      else
                        const SizedBox(height: 18),
                      const Spacer(),
                      if (spawnAgentCanOpenDetail(
                        block: block,
                        novelId: novelId,
                        databasePath: databasePath,
                      ))
                        SpawnAgentDetailButton(
                          block: block,
                          novelId: novelId,
                          databasePath: databasePath,
                          compact: true,
                        ),
                    ],
                  ),
                ),
                AiToolDetailBody(
                  block: block,
                  databasePath: databasePath,
                  novelId: novelId,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// thinking 步骤行 — 内联展开查看推理内容，[isRunning] 时显示进行中状态。
class _ThinkingStepRow extends ConsumerStatefulWidget {
  const _ThinkingStepRow({required this.block, required this.isRunning});

  final AiThinkingBlock block;
  final bool isRunning;

  @override
  ConsumerState<_ThinkingStepRow> createState() => _ThinkingStepRowState();
}

class _ThinkingStepRowState extends ConsumerState<_ThinkingStepRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final title = widget.isRunning
        ? context.t(LocaleKeys.aiThinking)
        : context.t(LocaleKeys.aiReasoningSection);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                AiToolStatusDot(
                  status: widget.isRunning
                      ? AiToolCallStatus.running
                      : AiToolCallStatus.success,
                ),
                const SizedBox(width: RevericSpacing.sm),
                Flexible(
                  flex: 0,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.uiSemibold.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
                const Spacer(),
                RevericIcon(
                  _expanded
                      ? RevericIcons.expand_less_rounded
                      : RevericIcons.expand_more_rounded,
                  size: 15,
                  color: colors.textSubtle,
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(left: 26, bottom: RevericSpacing.sm),
            // isRunning 期间 thinking 文本仍在增长，禁用选区避免框架选区索引失稳崩溃。
            child: StableSelectionArea(
              selectable: !widget.isRunning,
              child: Text(
                widget.block.text.trim(),
                style: typo.uiSmall.copyWith(
                  color: colors.textMuted,
                  height: 1.5,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

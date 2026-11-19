// 职责: 跨平台单条 AI 聊天消息渲染 — 用户气泡(引用/handoff chip + 正文)、AI 头像轨道、文本/思考/工具卡/图片/AskUser block。
// 关联文件:
//   lib/shared/widgets/ai/chat/chat_message_parts.dart
//   lib/shared/widgets/ai/chat/compaction_card.dart
//   lib/shared/widgets/ai/chat/ui_message.dart
//   lib/shared/widgets/ai/tool_activity_group.dart
//   lib/shared/widgets/ai/tools/ask_user_card.dart
//   lib/shared/models/ai_chat_models.dart
//   lib/shared/providers/ai_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
import '../tool_operation_activity.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:reveric/shared/components/reveric_spinner.dart';
import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/agent_profile.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/ai_session_mode.dart';
import 'package:reveric/shared/models/ask_user_models.dart';
import 'package:reveric/shared/models/queued_chat_message.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/ai/pending_ask_user.dart';
import 'package:reveric/shared/services/ai/tools.dart'
    show suggestNextActionToolName;
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:reveric/shared/widgets/agent_avatar.dart';
import 'package:reveric/shared/widgets/stable_selection_area.dart';

import '../tool_activity_group.dart';
import '../tools/ask_user_card.dart';
import '../tools/character_image_tool_card.dart';
import '../tools/todo_tool_card.dart';
import 'chat_message_parts.dart';
import 'attachment_body.dart';
import 'compaction_card.dart';
import 'typing_indicator.dart';
import 'ui_message.dart';

/// 对侧头像占用的水平沟槽（头像 + 与气泡间距），与用户/AI 行内沟槽对称。
const _kChatOppositeAvatarGutter = RevericSizes.aiAvatarMd + RevericSpacing.md;

/// 渲染单条 [UIMessage]（可能由多条 assistant 消息合并而来）。
/// 桌面与移动端共用;各自的列表/输入壳在外层。
class ChatMessageView extends ConsumerWidget {
  const ChatMessageView({
    super.key,
    required this.message,
    required this.activeSessionId,
    this.databasePath,
    this.novelId,
    this.onRetry,
    this.onFeedback,
    this.onFork,
    this.onRollbackTurn,
    this.onConfigureImageModel,
    this.onSetAsAvatar,
    this.onAddPhoto,
    this.onOpenSessionReference,
    this.readOnly = false,
    this.isCompactingContext = false,
    this.isWaitingForResponse = false,
    this.retryProgress = '',
  });

  final UIMessage message;

  /// 当前会话 id — 用于 AskUser completer 查找(`aiChatRuntimeProvider`,family 接受 null)。
  final String? activeSessionId;
  final String? databasePath;
  final String? novelId;
  final bool readOnly;

  /// 无 blocks 的 assistant 纯文本消息可重试时由宿主注入;为 null 不显示重试。
  final VoidCallback? onRetry;

  /// 桌面端上传诊断反馈;移动端为 null 时不显示。
  final VoidCallback? onFeedback;

  /// 分叉会话：从此 assistant 消息切出一条新 chat session。仅在 assistant 消息上渲染。
  final VoidCallback? onFork;

  /// 回退本轮 AI 改动并重发。仅在 user 消息上生效。
  final Future<String?> Function(String messageId)? onRollbackTurn;

  /// 打开图片模型设置（移动端可为 null）。
  final VoidCallback? onConfigureImageModel;

  final Future<void> Function(String assetId, String characterId)?
  onSetAsAvatar;
  final Future<void> Function(
    String assetId, {
    String? characterId,
    String? itemId,
  })?
  onAddPhoto;
  final Future<void> Function(String sessionId, AiSessionMode mode)?
  onOpenSessionReference;

  /// 当前 assistant 回合正在整理上下文。该状态替换而非叠加普通打字指示。
  final bool isCompactingContext;

  /// 当前 assistant 回合在网络重试退避期间等待下一次响应。
  /// 复用「思考中」状态，不把重试原因或次数写入消息内容。
  final bool isWaitingForResponse;
  final String retryProgress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    if (message.type == AiMessageType.compact_summary) {
      return CompactionCard(
        summary: message.content,
        metadata: message.metadata,
        loadInlineImages: !readOnly,
      );
    }
    final isSentByMe = message.role == AiMessageRole.user;
    final isStreaming = message.isStreaming;

    if (isSentByMe) {
      final presentation = parseUserMessagePresentation(message.content);
      // 本轮 slash chip（skill 直接加载 / subagent 软偏好）名（发送时写入 metadata）。
      final skillNames = skillNamesFromMessageMetadata(message.metadata);
      final subagentNames = subagentNamesFromMessageMetadata(message.metadata);
      final hasSlashChips = skillNames.isNotEmpty || subagentNames.isNotEmpty;
      final bubble = Container(
        decoration: BoxDecoration(
          color: colors.surfaceDim,
          borderRadius: BorderRadius.circular(RevericSizes.chatBubbleRadius),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.xl,
          vertical: RevericSpacing.md,
        ),
        child: SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (presentation.handoff != null)
                Padding(
                  padding: EdgeInsets.only(
                    bottom:
                        presentation.references.isNotEmpty ||
                            hasSlashChips ||
                            presentation.text.isNotEmpty
                        ? RevericSpacing.sm
                        : 0,
                  ),
                  child: AgentHandoffChip(
                    handoff: presentation.handoff!,
                    onOpenSession: onOpenSessionReference,
                  ),
                ),
              if (presentation.references.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(
                    bottom: hasSlashChips || presentation.text.isNotEmpty
                        ? RevericSpacing.sm
                        : 0,
                  ),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: RevericSpacing.xs,
                    runSpacing: RevericSpacing.xs,
                    children: [
                      for (final ref in presentation.references)
                        UserRemindChip(
                          reference: ref,
                          onOpenSession: onOpenSessionReference,
                        ),
                    ],
                  ),
                ),
              if (hasSlashChips)
                Padding(
                  padding: EdgeInsets.only(
                    bottom: presentation.text.isEmpty ? 0 : RevericSpacing.sm,
                  ),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: RevericSpacing.xs,
                    runSpacing: RevericSpacing.xs,
                    children: [
                      for (final name in skillNames) SkillUsedChip(name: name),
                      for (final name in subagentNames)
                        SubagentUsedChip(name: name),
                    ],
                  ),
                ),
              if (message.blocks.any((b) => b is AiAttachmentBlock))
                ChatAttachmentBody(blocks: message.blocks, readOnly: readOnly)
              else if (presentation.text.isNotEmpty)
                Text(
                  presentation.text,
                  style: typo.ui.copyWith(color: colors.textPrimary),
                ),
            ],
          ),
        ),
      );

      // 操作按钮（回退常驻 + 复制 hover）放在气泡左侧，与气泡一起靠右对齐；
      // 气泡用 Flexible 在窄屏可收缩。对齐 designs/desktop/ChatPanel.jsx。
      return HoverRegion(
        builder: (context, hovered) => Padding(
          // 左侧留白：为对侧 AI 头像沟槽让位，并避免宽消息贴住面板左缘。
          padding: const EdgeInsets.only(
            left: RevericSpacing.x2l + _kChatOppositeAvatarGutter,
            bottom: RevericSpacing.x2l,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      UserBubbleActions(
                        copyText: userMessageCopyText(presentation),
                        showCopy: hovered,
                        onRollbackTurn: onRollbackTurn != null
                            ? () => onRollbackTurn!(message.id)
                            : null,
                      ),
                      const SizedBox(width: RevericSpacing.sm),
                      Flexible(child: bubble),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: RevericSpacing.md),
              _userAvatar(context, ref, colors, RevericSizes.aiAvatarMd),
              const SizedBox(width: RevericSpacing.x2l),
            ],
          ),
        ),
      );
    }

    // AI 消息 — 根据是否有结构化 blocks 选择渲染策略
    final hasBlocks = message.blocks.isNotEmpty;

    // 不用 LayoutBuilder 包裹：原为配合下方 Positioned 的 Stack 布局而包了一层，
    // 但 LayoutBuilder 在 AI streaming 每帧 layout invalidate 时都会重建 builder，
    // 而 builder 内并未使用 constraints。直接 return Stack 等价且避免无用重建。
    // 用 Stack 让「内容」决定整行高度，左侧头像沟槽以 Positioned(top:0,bottom:0)
    // 撑满该高度——供 sticky 头像在轮次内贴顶滑动。
    // 不能用 Row + CrossAxisAlignment.stretch：本行是无界高度的 ListView item，
    // stretch 会以 tightFor(height: infinity) 强制所有子项无限高，导致 sliver
    // 布局抛错、paint 阶段 child.geometry! 崩溃。
    final assistantContent = hasBlocks
        ? _buildBlocksColumn(
            context,
            ref,
            colors,
            isStreaming,
            isCompactingContext: isCompactingContext,
            isWaitingForResponse: isWaitingForResponse,
          )
        : _buildPlainTextBubble(
            context,
            colors,
            typo,
            isStreaming,
            isCompactingContext: isCompactingContext,
            isWaitingForResponse: isWaitingForResponse,
            onRetry: onRetry,
          );

    return Stack(
      children: [
        // 内容（决定整行高度）；左侧让出头像沟槽宽度。
        Padding(
          // 右侧为用户头像沟槽留白，内容可拉满列宽但不越过头像。
          padding: const EdgeInsets.only(
            left: RevericSpacing.x2l + _kChatOppositeAvatarGutter,
            right: RevericSpacing.x2l + _kChatOppositeAvatarGutter,
          ),
          child: assistantContent,
        ),
        // 头像沟槽：贴左、top/bottom 撑满内容高度（有界），sticky 头像在其内滑动。
        Positioned(
          left: RevericSpacing.x2l,
          top: 0,
          bottom: 0,
          width: RevericSizes.aiAvatarMd,
          child: _StickyMessageAvatar(
            avatarSize: RevericSizes.aiAvatarMd,
            avatar: _aiAvatar(context, ref, colors, RevericSizes.aiAvatarMd),
          ),
        ),
      ],
    );
  }

  Widget _buildPlainTextBubble(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo,
    bool isStreaming, {
    bool isCompactingContext = false,
    bool isWaitingForResponse = false,
    VoidCallback? onRetry,
  }) {
    final hasText = message.content.trim().isNotEmpty;

    if (isStreaming && !hasText) {
      return Padding(
        padding: const EdgeInsets.only(
          left: RevericSpacing.sm,
          top: RevericSpacing.lg,
          bottom: RevericSpacing.lg,
        ),
        child: isCompactingContext
            ? const CompactingContextIndicator()
            : isWaitingForResponse
            ? _buildThinkingIndicator(
                context,
                colors,
                RevericTheme.typographyOf(context),
              )
            : AiTypingIndicator(colors: colors),
      );
    }

    final bubble = Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.xl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(RevericSpacing.lg),
            // 流式期间内容持续增长，禁用选区避免框架选区索引失稳崩溃。
            child: StableSelectionArea(
              selectable: !isStreaming,
              child: Text(
                message.content,
                style: typo.ui.copyWith(color: colors.textPrimary, height: 1.5),
              ),
            ),
          ),
          if (isStreaming)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                RevericSpacing.lg,
                0,
                0,
                RevericSpacing.lg,
              ),
              child: SizedBox(
                width: 12,
                height: 12,
                child: RevericSpinner(strokeWidth: 2, color: colors.accent),
              ),
            ),
          if (onRetry != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                RevericSpacing.sm,
                0,
                RevericSpacing.sm,
                RevericSpacing.sm,
              ),
              child: TextButton.icon(
                onPressed: onRetry,
                icon: RevericIcon(
                  RevericIcons.redo,
                  size: 14,
                  color: colors.accent,
                ),
                label: Text(context.t(LocaleKeys.aiRetry)),
                style: TextButton.styleFrom(
                  foregroundColor: colors.accent,
                  textStyle: typo.uiSmall,
                  padding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.sm,
                    vertical: RevericSpacing.xs,
                  ),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
        ],
      ),
    );

    if (isStreaming) {
      return bubble;
    }

    return HoverableCopyWrapper(
      text: message.content,
      alignment: Alignment.centerLeft,
      rightPadding: 0,
      onFeedback: onFeedback,
      onFork: onFork,
      child: bubble,
    );
  }

  Widget _buildBlocksColumn(
    BuildContext context,
    WidgetRef ref,
    RevericColors colors,
    bool isStreaming, {
    bool isCompactingContext = false,
    bool isWaitingForResponse = false,
  }) {
    final typo = RevericTheme.typographyOf(context);
    final showThinkingIndicator =
        !isCompactingContext &&
        isStreaming &&
        _shouldShowStreamingIndicator(message);
    final isImageGenConfigured =
        !readOnly && ref.watch(isImageGenerationConfiguredProvider);

    final children = <Widget>[];
    final activities = <AiMessageBlock>[];
    var activitiesLastIndex = -1;
    var compactionRenderedInActivityGroup = false;

    void flushActivities() {
      if (activities.isEmpty) {
        return;
      }
      final runBlocks = List<AiMessageBlock>.of(activities);
      // 该组位于仍在 streaming 的消息尾部：组内最后一块即整条消息最后一块
      // （其后无 text）。thinking 与 tool call 同组，仅 text 切组。
      final isStreamingTail =
          message.isStreamingTail &&
          activitiesLastIndex == message.blocks.length - 1;
      final isCompactingActivityTail = isCompactingContext && isStreamingTail;
      children.add(
        AiToolActivityGroup(
          blocks: runBlocks,
          databasePath: databasePath,
          novelId: novelId,
          isStreamingTail: isStreamingTail,
          isCompactingContext: isCompactingActivityTail,
        ),
      );
      if (activeSessionId != null) {
        children.add(
          ToolOperationActivity(sessionId: activeSessionId!, blocks: runBlocks),
        );
      }
      if (isCompactingActivityTail) {
        compactionRenderedInActivityGroup = true;
      }
      activities.clear();
      activitiesLastIndex = -1;
    }

    final imageBlockIds = {
      for (final block in message.blocks)
        if (block is AiImageBlock) block.id,
    };
    for (var index = 0; index < message.blocks.length; index++) {
      final block = message.blocks[index];
      if (block is AiTextBlock) {
        // 仅当 LLM 返回 text 时才切组，开启下一个 card。
        flushActivities();
        if (block.text.isEmpty) continue;
        // 消息仍在流式时，最后一个文本块会持续增长；期间禁用选区。
        final isGrowingTail = isStreaming && index == message.blocks.length - 1;
        children.add(
          _buildTextBubble(
            context,
            colors,
            typo,
            block.text,
            selectable: !isGrowingTail,
          ),
        );
      } else if (block is AiThinkingBlock) {
        // thinking 作为活动项并入当前活动组，不切组。
        if (block.text.isEmpty) continue;
        activities.add(block);
        activitiesLastIndex = index;
      } else if (block is AiToolCallBlock) {
        // AskUser 工具调用由 AiAskUserBlock 渲染交互框，tool call block 仅用于
        // 数据回传（序列化给下一轮请求），UI 层跳过，不进入工具活动组。
        if (block.toolName == 'AskUser') {
          continue;
        }
        // SuggestNextAction 同理：建议由 panel 提升到 composer 上方的
        // NextActionBar 统一渲染，消息流里不出现工具卡。
        if (block.toolName == suggestNextActionToolName) {
          continue;
        }
        // 生图调用由同一 callId 的图片卡展示，工具块只用于历史回放。
        if (imageBlockIds.contains('img_${block.callId}')) {
          continue;
        }
        // TodoWrite 工具使用专门的简洁卡片
        if (block.toolName == 'TodoWrite' &&
            block.status == AiToolCallStatus.success) {
          flushActivities();
          children.add(TodoToolCard(block: block));
        } else {
          activities.add(block);
          activitiesLastIndex = index;
        }
      } else if (block is AiImageBlock) {
        flushActivities();
        final assetId = block.assetId;
        final isCharImage =
            block.toolName == 'GenerateAvatar' ||
            block.toolName == 'GeneratePhoto';
        final hasErrorNoModel =
            block.status == AiImageStatus.error && !isImageGenConfigured;
        if (isCharImage || readOnly) {
          final setAsAvatar = onSetAsAvatar;
          final addPhoto = onAddPhoto;
          final characterId = block.characterId;
          final itemId = block.itemId;
          final hasPhotoTarget =
              (characterId != null && characterId.isNotEmpty) ||
              (itemId != null && itemId.isNotEmpty);
          children.add(
            AiCharacterImageToolCard(
              block: block,
              readOnly: readOnly,
              onSetAsAvatar:
                  (setAsAvatar != null &&
                      block.toolName == 'GenerateAvatar' &&
                      block.status == AiImageStatus.success &&
                      assetId != null &&
                      assetId.isNotEmpty &&
                      characterId != null &&
                      characterId.isNotEmpty)
                  ? (id) => setAsAvatar(id, characterId)
                  : null,
              onAddPhoto:
                  (addPhoto != null &&
                      block.toolName == 'GeneratePhoto' &&
                      block.status == AiImageStatus.success &&
                      assetId != null &&
                      assetId.isNotEmpty &&
                      hasPhotoTarget)
                  ? (id) =>
                        addPhoto(id, characterId: characterId, itemId: itemId)
                  : null,
              onConfigureImageModel: hasErrorNoModel
                  ? onConfigureImageModel
                  : null,
            ),
          );
          // 人物 / 物品生图的审批卡挂在图片卡下面，原工具卡已被图片卡替换。
          if (activeSessionId != null) {
            children.add(
              ToolOperationActivity(
                sessionId: activeSessionId!,
                blocks: [block],
              ),
            );
          }
        }
      } else if (block is AiAttachmentBlock && readOnly) {
        flushActivities();
        children.add(ChatAttachmentBody(blocks: [block], readOnly: true));
      } else if (block is AiAskUserBlock) {
        flushActivities();
        PendingAskUser? findLiveRequest() {
          final provider = aiChatRuntimeProvider(activeSessionId);
          // 历史 pending 卡片可能没有运行时；只查询已有实例，避免渲染创建它。
          if (readOnly || !block.isPending || !ref.exists(provider)) {
            return null;
          }
          final pending = ref
              .read(provider.notifier)
              .pendingAskUserRequests[block.callId];
          return pending != null &&
                  pending.blockId == block.id &&
                  !pending.isCompleted
              ? pending
              : null;
        }

        children.add(
          AskUserCard(
            key: ValueKey(block.id),
            block: block,
            isLive: () => findLiveRequest() != null,
            canSubmit: () {
              final pending = findLiveRequest();
              if (pending == null) {
                return false;
              }
              pending.checkDeadline();
              return !pending.isCompleted;
            },
            onSubmit: (result) => findLiveRequest()?.complete(result),
            onCancel: () => findLiveRequest()?.complete(
              const AskUserResult(ok: false, cancelled: true),
            ),
          ),
        );
      }
    }
    flushActivities();

    if (showThinkingIndicator) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(
            left: RevericSpacing.sm,
            bottom: RevericSpacing.md,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: RevericSpinner(strokeWidth: 2, color: colors.accent),
              ),
              const SizedBox(width: RevericSpacing.xs),
              Text(
                context.t(LocaleKeys.aiThinking),
                style: typo.uiSmall.copyWith(color: colors.textMuted),
              ),
            ],
          ),
        ),
      );
    }

    // 流式尾部停在文本气泡（已写完一段、下一轮 block 未到）时，就地补一个打字指示，
    // 替代被移除的「请求中底部独立 loading 气泡」，避免 text→tool 空窗看起来卡住。
    // 与上面 showThinkingIndicator（全空 text 分支）、活动卡内 showContinuation
    // （tool 尾）互斥：尾块为非空文本时三者只命中此一处。
    final lastBlock = message.blocks.isEmpty ? null : message.blocks.last;
    if (!isCompactingContext &&
        message.isStreamingTail &&
        lastBlock is AiTextBlock &&
        lastBlock.text.trim().isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(
            left: RevericSpacing.sm,
            top: RevericSpacing.xs,
            bottom: RevericSpacing.md,
          ),
          child: isWaitingForResponse
              ? _buildThinkingIndicator(context, colors, typo)
              : AiTypingIndicator(colors: colors),
        ),
      );
    }

    final hasExistingThinkingStatus =
        lastBlock is AiThinkingBlock ||
        (lastBlock is AiToolCallBlock &&
            lastBlock.status == AiToolCallStatus.success &&
            lastBlock.toolName != 'TodoWrite');
    if (isWaitingForResponse &&
        isStreaming &&
        message.isStreamingTail &&
        !showThinkingIndicator &&
        !hasExistingThinkingStatus &&
        !(lastBlock is AiTextBlock && lastBlock.text.trim().isNotEmpty)) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(
            left: RevericSpacing.sm,
            bottom: RevericSpacing.md,
          ),
          child: _buildThinkingIndicator(context, colors, typo),
        ),
      );
    }

    if (isCompactingContext && !compactionRenderedInActivityGroup) {
      children.add(
        Padding(
          padding: EdgeInsets.only(
            left: RevericSpacing.sm,
            top: children.isEmpty ? RevericSpacing.lg : RevericSpacing.xs,
            bottom: RevericSpacing.md,
          ),
          child: const CompactingContextIndicator(),
        ),
      );
    }

    if (!isStreaming && (onFeedback != null || onFork != null)) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(
            top: RevericSpacing.xs,
            bottom: RevericSpacing.x2l,
          ),
          child: MessageActionBar(onFeedback: onFeedback, onFork: onFork),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _buildThinkingIndicator(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AiTypingIndicator(colors: colors),
        const SizedBox(width: RevericSpacing.sm),
        Flexible(
          child: Text(
            isWaitingForResponse && retryProgress.isNotEmpty
                ? context.t(
                    LocaleKeys.aiRetryingResponse,
                    namedArgs: {'progress': retryProgress},
                  )
                : context.t(LocaleKeys.aiThinking),
            style: typo.uiSmall.copyWith(color: colors.textMuted),
          ),
        ),
      ],
    );
  }

  Widget _buildTextBubble(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo,
    String text, {
    bool selectable = true,
  }) {
    // 复制按钮 hover 淡入、悬浮在文本块右上角（覆盖在正文之上，故自带底色与描边
    // 以免压住文字）；不占布局空间，块间距仍由外层 margin 提供。
    return Container(
      margin: const EdgeInsets.only(bottom: RevericSpacing.sm),
      child: HoverRegion(
        builder: (context, hovered) => Stack(
          children: [
            CollapsibleTextBlock(
              content: text,
              textStyle: typo.ui,
              selectable: selectable,
              loadInlineImages: !readOnly,
            ),
            Positioned(
              top: RevericSpacing.xs,
              right: RevericSpacing.xs,
              child: AnimatedOpacity(
                opacity: hovered ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 150),
                child: IgnorePointer(
                  ignoring: !hovered,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surfaceContainer,
                      borderRadius: BorderRadius.circular(RevericRadius.medium),
                      border: Border.all(color: colors.borderSubtle),
                    ),
                    child: CopyIconButton(text: text),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _shouldShowStreamingIndicator(UIMessage aiMessage) {
    if (!aiMessage.isStreaming) {
      return false;
    }
    if (aiMessage.blocks.isEmpty) {
      return true;
    }

    for (final block in aiMessage.blocks) {
      if (block is AiToolCallBlock ||
          block is AiThinkingBlock ||
          block is AiImageBlock) {
        return false;
      }
    }

    return aiMessage.blocks.every(
      (block) => block is! AiTextBlock || block.text.trim().isEmpty,
    );
  }

  Widget _aiAvatar(
    BuildContext context,
    WidgetRef ref,
    RevericColors colors,
    double size,
  ) {
    final avatarPath = ref.watch(aiAgentAvatarPathProvider);
    return AgentAvatar(
      avatarPath: avatarPath.isNotEmpty ? avatarPath : null,
      slug: builtinAgentSlugOrchestrator,
      size: size,
      backgroundColor: colors.surfaceContainer,
      border: Border.all(color: colors.borderSubtle),
    );
  }

  Widget _userAvatar(
    BuildContext context,
    WidgetRef ref,
    RevericColors colors,
    double size,
  ) {
    final settings = ref.watch(appSettingsProvider).asData?.value;
    // 存储值可能是相对/旧绝对路径，统一过 resolveStored 兜底。
    final resolvedAvatar = RevericPaths.resolveStored(
      settings?.avatarPath.trim(),
    );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colors.surfaceContainer,
        border: Border.all(color: colors.borderSubtle),
      ),
      child: ClipOval(
        child: resolvedAvatar != null
            ? Image.file(
                File(resolvedAvatar),
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => RevericIcon(
                  RevericIcons.person,
                  size: size * 0.55,
                  color: colors.textMuted,
                ),
              )
            : RevericIcon(
                RevericIcons.person,
                size: size * 0.55,
                color: colors.textMuted,
              ),
      ),
    );
  }
}

/// AI 消息左侧头像沟槽：把头像 sticky 贴在滚动 viewport 顶部，并 clamp 在所属消息
/// （整轮）的垂直范围内，长轮次滚动时头像始终可见。无 Scrollable 祖先（如非列表
/// 场景）时退回顶部对齐，保持旧行为。
class _StickyMessageAvatar extends StatelessWidget {
  const _StickyMessageAvatar({required this.avatar, required this.avatarSize});

  final Widget avatar;
  final double avatarSize;

  @override
  Widget build(BuildContext context) {
    final scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) {
      return Align(alignment: Alignment.topLeft, child: avatar);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        return AnimatedBuilder(
          animation: scrollable.position,
          child: avatar,
          builder: (context, child) {
            final top = _stickyTop(context, scrollable);
            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  top: top,
                  left: 0,
                  width: avatarSize,
                  height: avatarSize,
                  child: child!,
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 头像在沟槽内的纵向偏移：让其顶边贴 viewport 顶，并 clamp 在沟槽内
  /// （[0, 沟槽高 - 头像高]）。几何取上一帧布局，快速滚动时可能滞后一帧，可接受。
  double _stickyTop(BuildContext context, ScrollableState scrollable) {
    final box = context.findRenderObject() as RenderBox?;
    final viewport = scrollable.context.findRenderObject() as RenderBox?;
    if (box == null ||
        viewport == null ||
        !_hasLaidOutAncestorChain(box, viewport)) {
      return 0;
    }
    final maxTop = box.size.height - avatarSize;
    if (maxTop <= 0) {
      return 0;
    }
    // 必须带 ancestor: viewport。无 ancestor 的 localToGlobal/globalToLocal
    // 会走到 root，途经页面过渡等尚未 layout 的 RenderTransform 时抛
    // "RenderBox was not laid out: RenderTransform"。
    final gutterTopInViewport = box
        .localToGlobal(Offset.zero, ancestor: viewport)
        .dy;
    final desired = -gutterTopInViewport;
    return desired.clamp(0.0, maxTop);
  }

  /// 坐标转换会经过 box→viewport 之间的所有 render ancestor；任一层（例如滚动中的
  /// RenderFractionalTranslation / 带 alignment 的 RenderTransform）尚未 layout
  /// 时，直接读取几何会抛异常。
  bool _hasLaidOutAncestorChain(RenderBox renderBox, RenderBox viewport) {
    RenderObject? current = renderBox;
    while (current != null) {
      if (current is RenderBox && !current.hasSize) {
        return false;
      }
      if (identical(current, viewport)) {
        return true;
      }
      current = current.parent;
    }
    return false;
  }
}

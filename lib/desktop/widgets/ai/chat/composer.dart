// 职责: AI 聊天面板输入组件 — 处理文本输入、Slash 命令（subagent/skill 选中落 chip）、附件引用、额度耗尽反馈和发送逻辑
// 关联文件:
//   lib/desktop/widgets/ai/chat/panel.dart
//   lib/desktop/widgets/ai/chat/state.dart
//   lib/desktop/widgets/ai/chat/slash_commands.dart
//   lib/shared/models/slash_entry.dart
//   lib/shared/services/ai/chat_prompt_builder.dart
//   lib/shared/localization/locale_keys.dart
//   lib/shared/services/ai/chat_session_controller.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../shared/hooks/use_chat_composer_hint.dart';
import '../../../../shared/localization/app_localization.dart';
import '../../../../shared/localization/locale_keys.dart';
import '../../../../shared/models/ai_provider.dart';
import '../../../../shared/models/subagent.dart';
import '../../../../shared/models/slash_entry.dart';
import '../../../../shared/models/novel_workspace.dart';
import '../../../../shared/providers/ai_providers.dart';
import '../../../../shared/widgets/ai/chat/attachment_input.dart';
import '../../../../shared/services/ai/chat_prompt_builder.dart';
import '../../../../shared/theme/theme.dart';
import '../../../../shared/widgets/ai/chat/composer_notice.dart';
import '../../../../shared/widgets/app_background.dart';
import '../../../../shared/widgets/ai/chat/chat_message_parts.dart';
import 'state.dart';
import '../model/model_selector.dart';
import 'slash_commands.dart';

typedef SendMessageCallback = void Function(String text);
typedef CancelRequestCallback = void Function();
typedef SelectModelCallback = void Function(AiModelOption option);
typedef RemoveReferenceCallback = void Function(AiContextReference ref);
typedef ClearHandoffCallback = void Function();

enum DesktopChatComposerAction { disabled, send, queue, stop }

/// 解析桌面聊天输入区当前主按钮动作，供点击与 Enter 键共用。
@visibleForTesting
DesktopChatComposerAction resolveDesktopChatComposerAction({
  required bool isConfigured,
  required bool isRequestInFlight,
  required String draftText,
  required bool hasPendingHandoff,
  required bool queueOccupied,
}) {
  final hasSendableContent = draftText.trim().isNotEmpty || hasPendingHandoff;
  if (!isConfigured) {
    return DesktopChatComposerAction.disabled;
  }
  if (isRequestInFlight) {
    if (hasSendableContent && !queueOccupied) {
      return DesktopChatComposerAction.queue;
    }
    return DesktopChatComposerAction.stop;
  }
  if (!hasSendableContent) {
    return DesktopChatComposerAction.disabled;
  }
  return DesktopChatComposerAction.send;
}

class ChatComposer extends HookConsumerWidget {
  const ChatComposer({
    super.key,
    required this.state,
    required this.sessionId,
    required this.isConfigured,
    required this.sessionState,
    required this.runtimeState,
    required this.availableModels,
    required this.availableSubAgents,
    required this.promptBuilder,
    this.databasePath,
    this.composerHint,

    this.onRequestNewSession,
    required this.onSendMessage,
    required this.onCancelRequest,
    required this.onSelectModel,
    this.onSelectModelWithEffort,
    required this.onRemoveReference,
    required this.onClearHandoff,
    this.onOpenHandoff,
    required this.onSendQueuedMessageNow,
    required this.onClearQueuedMessage,
  });

  final AiChatPanelState state;
  final String? sessionId;
  final bool isConfigured;
  final AiChatSessionState sessionState;
  final AiChatRuntimeState runtimeState;
  final List<AiModelOption> availableModels;
  final List<SubAgent> availableSubAgents;
  final ChatPromptBuilder promptBuilder;
  final String? databasePath;
  final String? composerHint;
  final VoidCallback? onRequestNewSession;
  final SendMessageCallback onSendMessage;
  final CancelRequestCallback onCancelRequest;
  final SelectModelCallback onSelectModel;
  final void Function(AiModelOption, String)? onSelectModelWithEffort;
  final RemoveReferenceCallback onRemoveReference;
  final ClearHandoffCallback onClearHandoff;
  final VoidCallback? onOpenHandoff;
  final VoidCallback onSendQueuedMessageNow;
  final VoidCallback onClearQueuedMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final appBackgroundActive = ref.watch(appBackgroundActiveProvider);
    final defaultHint = useChatComposerHint(context);
    final effectiveComposerHint = composerHint ?? defaultHint;
    const composerPadding = EdgeInsets.fromLTRB(
      RevericSpacing.x2l,
      RevericSpacing.sm,
      RevericSpacing.x2l,
      RevericSpacing.x2l,
    );
    final queuedMessage = state.queuedMessages.forSession(sessionId);

    // 选中 slash 条目 → 落成 chip（去重），清空 `/` token 并关闭菜单。
    void selectSlashEntry(SlashEntry entry) {
      final reference = entry.toReference();
      final current = state.attachedReferences.value;
      if (!current.contains(reference)) {
        state.attachedReferences.value = [...current, reference];
      }
      state.composerController.clear();
      state.slashMatches.value = const [];
      state.slashIndex.value = 0;
      state.composerFocusNode.requestFocus();
    }

    KeyEventResult handleComposerKey(FocusNode node, KeyEvent event) {
      if (event is! KeyDownEvent) {
        return KeyEventResult.ignored;
      }

      final composingRange = state.composerController.value.composing;
      final isImeComposing =
          composingRange.isValid && !composingRange.isCollapsed;
      if (isImeComposing) {
        return KeyEventResult.ignored;
      }

      if (state.slashMatches.value.isNotEmpty) {
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          state.slashIndex.value =
              (state.slashIndex.value + 1) % state.slashMatches.value.length;
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          state.slashIndex.value =
              (state.slashIndex.value - 1 + state.slashMatches.value.length) %
              state.slashMatches.value.length;
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          state.slashMatches.value = const [];
          state.slashIndex.value = 0;
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.enter) {
          selectSlashEntry(state.slashMatches.value[state.slashIndex.value]);
          return KeyEventResult.handled;
        }
      }

      if (event.logicalKey != LogicalKeyboardKey.enter) {
        return KeyEventResult.ignored;
      }

      if (HardwareKeyboard.instance.isShiftPressed) {
        final selection = state.composerController.selection;
        final text = state.composerController.text;
        final start = selection.isValid ? selection.start : text.length;
        final end = selection.isValid ? selection.end : text.length;
        final newText = text.replaceRange(start, end, '\n');
        state.composerController.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: start + 1),
        );
        return KeyEventResult.handled;
      }

      // 与发送按钮共用动作判定：空闲空内容禁用，in-flight 空内容走停止。

      final queueOccupied =
          state.queuedMessages.forSession(sessionId) != null ||
          runtimeState.isPreparingQueuedMessage;
      final action = resolveDesktopChatComposerAction(
        isConfigured: isConfigured,

        isRequestInFlight: runtimeState.isRequestInFlight,
        draftText: state.composerController.text,
        hasPendingHandoff: state.pendingHandoff.value != null,
        queueOccupied: queueOccupied,
      );
      if (action == DesktopChatComposerAction.disabled) {
        return KeyEventResult.handled;
      }
      if (action == DesktopChatComposerAction.stop) {
        onCancelRequest();
        return KeyEventResult.handled;
      }

      state.userScrolledUp.value = false;
      state.composerNotice.value = null;
      onSendMessage(state.composerController.text);
      return KeyEventResult.handled;
    }

    final visibleComposerNotice = state.composerNotice.value;
    // 请求、工具执行或排队期间不展示模型选择；选择仅暂存，随下一条发送提交。
    final canSelectModel =
        !runtimeState.isEditing &&
        queuedMessage == null &&
        availableModels.isNotEmpty;
    final composerBarColor = colors.surfaceContainerHigh.withValues(
      alpha: 0.92,
    );
    final composerInputGlassColor = appElevatedBackgroundColor(
      colors,
      appBackgroundActive,
      colors.surface,
    );

    return DragTarget<AiContextReference>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) {
        final ref = details.data;
        final current = state.attachedReferences.value;
        if (!current.contains(ref)) {
          state.attachedReferences.value = [...current, ref];
        }
        state.composerFocusNode.requestFocus();
      },
      builder: (context, candidateData, rejectedData) {
        final isDragOver = candidateData.isNotEmpty;
        return Container(
          width: double.infinity,
          padding: composerPadding,
          decoration: BoxDecoration(
            color: appBackgroundActive ? null : composerBarColor,
            border: appBackgroundActive
                ? Border(top: BorderSide(color: colors.border))
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (visibleComposerNotice != null)
                Padding(
                  padding: const EdgeInsets.only(
                    left: RevericSpacing.xs,
                    right: RevericSpacing.xs,
                    bottom: RevericSpacing.sm,
                  ),
                  child: _ComposerNoticeCard(
                    colors: colors,
                    typo: typo,
                    notice: visibleComposerNotice,
                    onNewSession: onRequestNewSession,
                    onDismiss: () {
                      state.composerNotice.value = null;
                    },
                  ),
                ),
              if (queuedMessage != null)
                Padding(
                  padding: const EdgeInsets.only(
                    left: RevericSpacing.xs,
                    right: RevericSpacing.xs,
                    bottom: RevericSpacing.sm,
                  ),
                  child: _QueuedMessagePreview(
                    colors: colors,
                    typo: typo,
                    queuedMessage: queuedMessage,
                    onSendNow: onSendQueuedMessageNow,
                    onClear: onClearQueuedMessage,
                  ),
                ),

              CompositedTransformTarget(
                link: state.composerInputLink,
                child: OverlayPortal.overlayChildLayoutBuilder(
                  controller: state.slashMenuController,
                  overlayChildBuilder: (context, layoutInfo) {
                    if (state.slashMatches.value.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    final overlaySize = layoutInfo.overlaySize;
                    final composerTopLeft = MatrixUtils.transformPoint(
                      layoutInfo.childPaintTransform,
                      Offset.zero,
                    );
                    final composerBottom =
                        composerTopLeft.dy + layoutInfo.childSize.height;
                    final availableAbove = math.max(
                      0.0,
                      composerTopLeft.dy - 16,
                    );
                    final availableBelow = math.max(
                      0.0,
                      overlaySize.height - composerBottom - 16,
                    );
                    final showBelow =
                        availableAbove < 160 && availableBelow > availableAbove;
                    final maxMenuHeight = math.max(
                      0.0,
                      math.min(
                        showBelow ? availableBelow : availableAbove,
                        240.0,
                      ),
                    );
                    final maxMenuWidth = math.max(
                      240.0,
                      math.min(
                        500.0,
                        overlaySize.width - composerTopLeft.dx - 16,
                      ),
                    );

                    return Positioned(
                      left: composerTopLeft.dx,
                      top: showBelow ? composerBottom + 8 : null,
                      bottom: showBelow
                          ? null
                          : overlaySize.height - composerTopLeft.dy + 8,
                      child: Material(
                        color: Colors.transparent,
                        child: Builder(
                          builder: (context) {
                            final entries = state.slashMatches.value;
                            SlashCommandItem toItem(SlashEntry entry) =>
                                SlashCommandItem(
                                  id: entry.id,
                                  command: entry.command,
                                  description: entry.description,
                                  insertText: '',
                                  icon: entry.icon,
                                );
                            return SlashCommands(
                              maxWidth: maxMenuWidth,
                              maxHeight: maxMenuHeight,
                              sections: [
                                SlashCommandSection(
                                  id: 'subagents',
                                  title: context.t(LocaleKeys.aiSlashExperts),
                                  items: [
                                    for (final entry in entries)
                                      if (entry.kind == SlashEntryKind.subagent)
                                        toItem(entry),
                                  ],
                                ),
                                SlashCommandSection(
                                  id: 'skills',
                                  title: context.t(
                                    LocaleKeys.agentSkillSlashSection,
                                  ),
                                  items: [
                                    for (final entry in entries)
                                      if (entry.kind == SlashEntryKind.skill)
                                        toItem(entry),
                                  ],
                                ),
                              ],
                              selectedItemId: entries.isEmpty
                                  ? null
                                  : entries[state.slashIndex.value].id,
                              onSelect: (item) {
                                final entry = entries.firstWhere(
                                  (e) => e.id == item.id,
                                );
                                selectSlashEntry(entry);
                              },
                            );
                          },
                        ),
                      ),
                    );
                  },
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: appBackgroundActive
                          ? composerInputGlassColor
                          : colors.surface,
                      borderRadius: BorderRadius.circular(RevericRadius.x2l),
                      border: Border.all(
                        color: isDragOver
                            ? colors.accent
                            : appBackgroundActive
                            ? colors.borderSubtle
                            : colors.borderInput,
                        width: isDragOver ? 1.5 : 1.0,
                      ),
                    ),
                    child: _buildInputColumn(
                      context: context,
                      composerHint: effectiveComposerHint,
                      isConfigured: isConfigured,
                      canSelectModel: canSelectModel,
                      disabledRevericModelIds: const <String>{},

                      colors: colors,
                      typo: typo,
                      handleComposerKey: handleComposerKey,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInputColumn({
    required BuildContext context,
    required String composerHint,
    required bool isConfigured,
    required bool canSelectModel,
    required Set<String> disabledRevericModelIds,
    required RevericColors colors,
    required RevericTypography typo,
    required KeyEventResult Function(FocusNode, KeyEvent) handleComposerKey,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.lg,
            RevericSpacing.md,
            RevericSpacing.lg,
            0,
          ),
          child: OutlinedButton.icon(
            onPressed: isConfigured ? () => _selectContextFile(context) : null,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, RevericSizes.buttonHeightSm),
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSizes.buttonPaddingHSm,
              ),
              foregroundColor: colors.textSecondary,
              side: BorderSide(color: colors.borderInput),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(RevericRadius.button),
              ),
            ),
            icon: RevericIcon(
              RevericIcons.attachment,
              size: 16,
              color: isConfigured ? colors.textSecondary : colors.textMuted,
            ),
            label: Text(
              context.t(LocaleKeys.aiAttachFile),
              style: typo.uiSmall,
            ),
          ),
        ),
        if (state.pendingHandoff.value != null ||
            state.attachedReferences.value.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.lg,
              RevericSpacing.md,
              RevericSpacing.lg,
              0,
            ),
            child: Wrap(
              spacing: RevericSpacing.xs,
              runSpacing: RevericSpacing.xs,
              children: [
                if (state.pendingHandoff.value?.isSessionContinuation == true)
                  SessionContinuationDraftChip(
                    title: state.pendingHandoff.value!.label,
                    onRemove: onClearHandoff,
                    onOpen: onOpenHandoff,
                  )
                else if (state.pendingHandoff.value != null)
                  _HandoffDraftChip(
                    colors: colors,
                    typo: typo,
                    handoff: state.pendingHandoff.value!,
                    onRemove: onClearHandoff,
                  ),
                for (final ref in state.attachedReferences.value)
                  _ReferenceChip(
                    colors: colors,
                    typo: typo,
                    reference: ref,
                    onRemove: () => onRemoveReference(ref),
                  ),
              ],
            ),
          ),
        Focus(
          onKeyEvent: (node, event) => handleComposerKey(node, event),
          child: ChatAttachmentInput(
            controller: state.composerController,
            focusNode: state.composerFocusNode,
            enabled: isConfigured,
            child: TextField(
              contextMenuBuilder: chatAttachmentContextMenu,
              focusNode: state.composerFocusNode,
              controller: state.composerController,
              enabled: isConfigured,
              minLines: 1,
              maxLines: 6,
              textInputAction: TextInputAction.newline,
              style: typo.ui.copyWith(color: colors.textPrimary),
              decoration: InputDecoration(
                filled: false,
                border: InputBorder.none,
                hintText: composerHint,
                hintStyle: typo.ui.copyWith(color: colors.textSubtle),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.xl,
                  vertical: RevericSpacing.lg,
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.sm,
            0,
            RevericSpacing.sm,
            RevericSpacing.sm,
          ),
          child: Row(
            children: [
              if (canSelectModel)
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return Align(
                        alignment: Alignment.centerRight,
                        child: CompositedTransformTarget(
                          link: state.modelSelectorLink,
                          child: Builder(
                            builder: (context) {
                              final pendingSelection =
                                  state.pendingModelSelection.value;
                              final resolvedId = pendingSelection != null
                                  ? '${pendingSelection.providerId}::${pendingSelection.model}'
                                  : sessionState.providerId != null &&
                                        sessionState.model != null
                                  ? '${sessionState.providerId}::${sessionState.model}'
                                  : '';
                              final currentOption = availableModels.firstWhere(
                                (item) => item.id == resolvedId,
                                orElse: () => availableModels.first,
                              );
                              return ModelSelector.compact(
                                colors: colors,
                                typo: typo,
                                modelName: currentOption.displayModelName,
                                compactMaxWidth: constraints.maxWidth,
                                resolvedId: resolvedId,
                                availableModels: availableModels,

                                selectedEffort:
                                    pendingSelection?.reasoningEffort ??
                                    sessionState.reasoningEffort,
                                onSelect: onSelectModel,
                                onSelectWithEffort: onSelectModelWithEffort,
                                autoOpenTrigger: state.modelSelectorOpenTrigger,
                                onMenuVisibilityChanged: (visible) {
                                  state.modelMenuVisible.value = visible;
                                },
                              );
                            },
                          ),
                        ),
                      );
                    },
                  ),
                )
              else
                const Spacer(),
              const SizedBox(width: RevericSpacing.sm),
              ValueListenableBuilder<Map<String?, QueuedChatMessage>>(
                valueListenable: state.queuedMessages.notifier,
                builder: (context, queues, _) {
                  final queued = queues[sessionId];
                  return ValueListenableBuilder<TextEditingValue>(
                    valueListenable: state.composerController,
                    builder: (context, value, child) {
                      final hasDraftText = value.text.trim().isNotEmpty;
                      final hasSendableContent =
                          hasDraftText || state.pendingHandoff.value != null;
                      final queueOccupied =
                          queued != null ||
                          runtimeState.isPreparingQueuedMessage;
                      final action = resolveDesktopChatComposerAction(
                        isConfigured: isConfigured,

                        isRequestInFlight: runtimeState.isRequestInFlight,
                        draftText: value.text,
                        hasPendingHandoff: state.pendingHandoff.value != null,
                        queueOccupied: queueOccupied,
                      );
                      final showStop = action == DesktopChatComposerAction.stop;
                      final buttonColor = showStop
                          ? colors.warningText
                          : colors.accent;
                      final allowAction =
                          action != DesktopChatComposerAction.disabled;
                      return IconButton(
                        onPressed: allowAction
                            ? () {
                                if (showStop) {
                                  onCancelRequest();
                                  return;
                                }
                                state.composerNotice.value = null;
                                state.userScrolledUp.value = false;
                                onSendMessage(state.composerController.text);
                              }
                            : null,
                        tooltip:
                            runtimeState.isRequestInFlight &&
                                hasSendableContent &&
                                queued != null
                            ? context.t(LocaleKeys.aiQueuedMessageOccupied)
                            : null,
                        icon: RevericIcon(
                          showStop
                              ? RevericIcons.stop_rounded
                              : RevericIcons.arrow_upward_rounded,
                          color: allowAction ? buttonColor : colors.textMuted,
                          size: 18,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor:
                              (allowAction ? buttonColor : colors.textMuted)
                                  .withValues(alpha: 0.12),
                        ),
                      );
                    },
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _selectContextFile(BuildContext context) async {
    await pickChatAttachments(context, state.composerController);
    if (context.mounted) {
      state.composerFocusNode.requestFocus();
    }
  }
}

class _QueuedMessagePreview extends StatelessWidget {
  const _QueuedMessagePreview({
    required this.colors,
    required this.typo,
    required this.queuedMessage,
    required this.onSendNow,
    required this.onClear,
  });

  final RevericColors colors;
  final RevericTypography typo;
  final QueuedChatMessage queuedMessage;
  final VoidCallback onSendNow;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final sendingNext = queuedMessage.sendOnNextTurn;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.md,
        vertical: RevericSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        border: Border.all(color: colors.accent.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          RevericIcon(
            RevericIcons.pending_actions_rounded,
            size: 16,
            color: colors.accent,
          ),
          const SizedBox(width: RevericSpacing.sm),
          Text(
            context.t(
              sendingNext
                  ? LocaleKeys.aiQueuedMessageSendingNext
                  : LocaleKeys.aiQueuedMessageTitle,
            ),
            style: typo.uiSmall.copyWith(color: colors.accent),
          ),
          const SizedBox(width: RevericSpacing.sm),
          Expanded(
            child: Text(
              queuedMessage.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: typo.uiSmall.copyWith(color: colors.textPrimary),
            ),
          ),
          if (!sendingNext)
            IconButton(
              onPressed: onSendNow,
              tooltip: context.t(LocaleKeys.aiQueuedMessageSendNow),
              icon: RevericIcon(
                RevericIcons.send_rounded,
                size: 14,
                color: colors.accent,
              ),
              style: IconButton.styleFrom(
                minimumSize: const Size(28, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: EdgeInsets.zero,
              ),
            ),
          IconButton(
            onPressed: onClear,
            tooltip: context.t(LocaleKeys.aiQueuedMessageRemove),
            icon: RevericIcon(
              RevericIcons.close_rounded,
              size: 14,
              color: colors.textMuted,
            ),
            style: IconButton.styleFrom(
              minimumSize: const Size(28, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }
}

class _ComposerNoticeCard extends StatelessWidget {
  const _ComposerNoticeCard({
    required this.colors,
    required this.typo,
    required this.notice,
    required this.onDismiss,
    this.onNewSession,
  });

  final RevericColors colors;
  final RevericTypography typo;
  final ComposerNotice notice;
  final VoidCallback onDismiss;
  final VoidCallback? onNewSession;

  @override
  Widget build(BuildContext context) {
    final action = resolveComposerNoticeAction(
      context,
      notice.message,
      onNewSession: onNewSession == null
          ? null
          : () {
              onDismiss();
              onNewSession!();
            },
    );
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.md,
        vertical: RevericSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.warningBg.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        border: Border.all(color: colors.warningText.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: RevericIcon(
              RevericIcons.warning_circle,
              size: 16,
              color: colors.warningText,
            ),
          ),
          const SizedBox(width: RevericSpacing.sm),
          Expanded(
            child: Text(
              notice.message,
              style: typo.uiSmall.copyWith(color: colors.warningText),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: RevericSpacing.sm),
            FilledButton.tonal(
              onPressed: action.onTap,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.md,
                ),
                visualDensity: VisualDensity.compact,
              ),
              child: Text(action.label, style: typo.uiTiny),
            ),
          ],
          const SizedBox(width: RevericSpacing.sm),
          IconButton(
            onPressed: onDismiss,
            icon: RevericIcon(
              RevericIcons.close_rounded,
              size: 14,
              color: colors.warningText,
            ),
            style: IconButton.styleFrom(
              minimumSize: const Size(28, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReferenceChip extends StatelessWidget {
  const _ReferenceChip({
    required this.colors,
    required this.typo,
    required this.reference,
    required this.onRemove,
  });

  final RevericColors colors;
  final RevericTypography typo;
  final AiContextReference reference;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final icon = switch (reference.section) {
      _ when reference.kind == AiContextReferenceKind.file =>
        RevericIcons.description_outlined,
      _ when reference.kind == AiContextReferenceKind.selection =>
        RevericIcons.format_quote,
      _ when reference.kind == AiContextReferenceKind.skill =>
        RevericIcons.lightning,
      _ when reference.kind == AiContextReferenceKind.subagent =>
        RevericIcons.smart_toy_outlined,
      _ when reference.kind == AiContextReferenceKind.agent_rule =>
        RevericIcons.rule_outlined,
      NovelWorkspaceSection.chapters => RevericIcons.menu_book_outlined,
      NovelWorkspaceSection.characters => RevericIcons.person_outline,
      NovelWorkspaceSection.lore => RevericIcons.public_outlined,
      NovelWorkspaceSection.foreshadowings => RevericIcons.lightbulb_outline,
      NovelWorkspaceSection.screenplay_script => RevericIcons.movie_outlined,
      NovelWorkspaceSection.screenplay_outline =>
        RevericIcons.list_alt_outlined,
      NovelWorkspaceSection.screenplay_scenes => RevericIcons.category_outlined,
      _ => RevericIcons.description_outlined,
    };

    return Container(
      padding: const EdgeInsets.only(
        left: RevericSpacing.sm,
        right: RevericSpacing.xxs,
        top: RevericSpacing.xxs,
        bottom: RevericSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(RevericRadius.pill),
        border: Border.all(color: colors.accent.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RevericIcon(icon, size: 13, color: colors.accent),
          const SizedBox(width: RevericSpacing.xxs),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              reference.label,
              style: typo.uiSmall.copyWith(color: colors.accent),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 2),
          InkWell(
            borderRadius: BorderRadius.circular(RevericRadius.pill),
            onTap: onRemove,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: RevericIcon(
                RevericIcons.close,
                size: 12,
                color: colors.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HandoffDraftChip extends StatelessWidget {
  const _HandoffDraftChip({
    required this.colors,
    required this.typo,
    required this.handoff,
    required this.onRemove,
  });

  final RevericColors colors;
  final RevericTypography typo;
  final PendingChatHandoff handoff;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(
        left: RevericSpacing.sm,
        right: RevericSpacing.xxs,
        top: RevericSpacing.xxs,
        bottom: RevericSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: colors.accentWarm.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(RevericRadius.pill),
        border: Border.all(color: colors.accentWarm.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RevericIcon(
            RevericIcons.swap_horiz_rounded,
            size: 13,
            color: colors.accentWarm,
          ),
          const SizedBox(width: RevericSpacing.xxs),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              handoff.label,
              style: typo.uiSmall.copyWith(color: colors.accentWarm),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 2),
          InkWell(
            borderRadius: BorderRadius.circular(RevericRadius.pill),
            onTap: onRemove,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: RevericIcon(
                RevericIcons.close,
                size: 12,
                color: colors.accentWarm,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

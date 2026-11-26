// 职责: AI 聊天面板 — 构造共享 ChatSessionController（注入作用域/host/composer store），桌面发送编排薄包装委托它。
// 关联文件:
//   lib/desktop/widgets/ai/chat/panel.dart
//   lib/shared/services/ai/chat_session_controller.dart
//   lib/shared/services/ai/chat_turn_runner.dart
part of 'panel.dart';

/// 适配 panel-scoped 的 [AiChatPanelState] notifier 到共享 [ChatComposerStore]。
/// 队列按发起会话隔离，避免面板切换会话时覆盖仍在后台运行的 Agent 的待发送消息。
class _PanelComposerStore implements ChatComposerStore {
  _PanelComposerStore(this.state, this.sessionId);

  final AiChatPanelState state;
  final String? sessionId;

  @override
  List<AiContextReference> get attachedReferences =>
      state.attachedReferences.value;
  @override
  set attachedReferences(List<AiContextReference> value) =>
      state.attachedReferences.value = value;

  @override
  PendingChatHandoff? get pendingHandoff => state.pendingHandoff.value;
  @override
  set pendingHandoff(PendingChatHandoff? value) =>
      state.pendingHandoff.value = value;

  @override
  QueuedChatMessage? get queuedMessage =>
      state.queuedMessages.forSession(sessionId);
  @override
  set queuedMessage(QueuedChatMessage? value) =>
      state.queuedMessages.setForSession(sessionId, value);

  @override
  QueuedChatMessage? queuedMessageForSession(String? targetSessionId) =>
      state.queuedMessages.forSession(targetSessionId);

  @override
  void setQueuedMessageForSession(
    String? targetSessionId,
    QueuedChatMessage? message,
  ) {
    state.queuedMessages.setForSession(targetSessionId, message);
  }

  @override
  DateTime? get sendGuardUntil => state.sendGuardUntil.value;
  @override
  set sendGuardUntil(DateTime? value) => state.sendGuardUntil.value = value;
}

extension _AiChatPanelAgentFactory on AiChatPanel {
  AiSessionContext _buildPanelContext() {
    return AiSessionContext(
      databasePath: databasePath,
      currentSeasonId: currentSeasonId,
      currentEpisodeId: currentEpisodeId,
      hasMultipleSeasons: hasMultipleSeasons,
    ).withWork(this.novel);
  }

  /// 组装一份 [ChatSessionController]：作用域取自 widget 字段，真正触碰 UI 的副作用
  /// 接成 [ChatHost]，编排输入态通过 [_PanelComposerStore] 注入（存储仍 panel-scoped，
  /// 桌面行为逐字不变）。聊天面板与移动端共用同一份发送编排（见 chat_session_controller.dart）。
  ChatSessionController _buildChatSessionController({
    required BuildContext context,
    required ProviderContainer container,
    required AiChatPanelState state,
    required List<SubAgent> availableSubAgents,
    required AiPromptService aiPromptService,
    required AiSessionContext promptContext,
    required ChatPromptBuilder promptBuilder,
  }) {
    final submittedText = state.composerController.text;
    return ChatSessionController(
      container: container,
      scope: ChatScope(
        activeSessionId: activeSessionId,
        novel: this.novel,
        databasePath: databasePath,
        workspaceSection: workspaceSection,
        workspaceItemId: workspaceItemId,
        workspaceTitle: workspaceTitle,
      ),
      host: ChatHost(
        encodeComposerBlocks: state.composerController.encodeBlocks,
        clearComposer: () {
          if (context.mounted &&
              state.composerController.text == submittedText) {
            state.composerController.clear();
          }
        },
        focusComposer: () => state.composerFocusNode.requestFocus(),
        openModelSelector: () => state.modelSelectorOpenTrigger.value++,
        resetScroll: () => state.userScrolledUp.value = false,
        isMounted: () => context.mounted,
        onActiveSessionIdChanged: onActiveSessionIdChanged,
        onComposerWarning: (message) {
          if (!context.mounted) {
            return;
          }
          state.composerNotice.value = ComposerNotice.warning(message: message);
        },
        restoreComposerText: (text) {
          // 原先是 `.text=` 再 `.selection=` 两次赋值，等于两次 setEditingState；
          // 现在合并成一次组词安全的原子写入。
          writeControllerTextAfterComposing(
            state.composerController,
            (currentText) => currentText.isEmpty ? text : '$currentText\n$text',
          );
          state.composerFocusNode.requestFocus();
        },
        onContextCompacted: (agent) =>
            _syncPersistedContextState(container, agent),
        onContextSettled: (agent) =>
            _syncPersistedContextState(container, agent),
      ),
      store: _PanelComposerStore(state, activeSessionId),
      promptBuilder: promptBuilder,
      availableSubAgents: availableSubAgents,
      aiPromptService: aiPromptService,
      promptContext: promptContext,

      nextActionEnvironment: _resolveNextActionEnvironment(container),
      supportsNextActionSuggestions: _supportsNextActionSuggestions,
    );
  }

  /// 工具层只需要开关：空态卡片额外用到的作品状态
  /// （hasCover / metadataReady / setupDone）由 UI 层单独解析，不进工具层。
  ChatNextActionEnvironment _resolveNextActionEnvironment(
    ProviderContainer container,
  ) {
    return ChatNextActionEnvironment(
      suggestionsEnabled: container.read(aiAgentNextActionSuggestionsProvider),
    );
  }
}

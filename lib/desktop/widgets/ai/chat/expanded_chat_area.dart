// 职责: 展开模式 AI 聊天区域 — 聊天面板 + 右侧 TODO/待处理变更面板
// 关联文件:
//   lib/desktop/widgets/ai/chat/panel.dart
//   lib/shared/services/ai/chat_session_controller.dart
//   lib/desktop/widgets/ai/chat/chat_side_panel.dart
//   lib/desktop/widgets/desktop_window_frame.dart
//   lib/desktop/pages/novel_editor.dart
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../../shared/database/app_database.dart' show Novel;

import '../../../../shared/database/novel_content_database.dart'
    show WorkingChange;
import '../../../../shared/models/novel_workspace.dart';
import '../../../../shared/models/ai_session_mode.dart';
import '../../../../shared/models/feature_id.dart';
import '../../../../shared/providers/ai_providers.dart'
    show aiChatSessionProvider;
import '../../../../shared/providers/todo_providers.dart'
    show sessionTodosProvider;
import '../../../../shared/theme/theme.dart';
import 'panel.dart';
import 'chat_side_panel.dart';

const _expandedChatMotionDuration = Duration(milliseconds: 220);
const _expandedChatCollapseDuration = Duration(milliseconds: 160);

/// 展开聊天显示右侧面板时，左侧聊天正文区需保留的最小可读宽度。
const double kExpandedChatMinWidthWithSidePanel = 500;

/// 右侧 Todo / 变更面板的最小与目标比例宽度（上限为 [RevericSizes.chatPanelWidth]）。
const double kExpandedChatSidePanelMinWidth = 260;
const double kExpandedChatSidePanelWidthFraction = 0.30;

/// 根据展开区域可用宽度与内容状态计算右侧面板宽度。
///
/// 无 Todo 且无待处理变更时返回 `null`（不渲染空面板）；有内容但可用宽度不足以
/// 同时保证聊天列 ≥ 500px 与侧栏 ≥ 260px 时同样返回 `null`，由 [AiChatPanel]
/// 自动回退为内嵌展示。
double? resolveExpandedChatSidePanelWidth(
  double availableWidth, {
  required bool hasSidePanelContent,
}) {
  if (!hasSidePanelContent) {
    return null;
  }
  final minTotalWidth =
      kExpandedChatMinWidthWithSidePanel +
      kExpandedChatSidePanelMinWidth +
      RevericSizes.dividerThickness;
  if (availableWidth < minTotalWidth) {
    return null;
  }
  final preferred = availableWidth * kExpandedChatSidePanelWidthFraction;
  final maxByChatBudget =
      availableWidth -
      kExpandedChatMinWidthWithSidePanel -
      RevericSizes.dividerThickness;
  final upperBound = maxByChatBudget < RevericSizes.chatPanelWidth
      ? maxByChatBudget
      : RevericSizes.chatPanelWidth;
  return preferred.clamp(kExpandedChatSidePanelMinWidth, upperBound);
}

typedef _ExpandedChatContentBuilder =
    Widget Function(BuildContext context, VoidCallback onCollapse);

class ExpandedChatArea extends ConsumerWidget {
  const ExpandedChatArea({
    super.key,
    required this.novel,
    this.chapterId,
    this.chapterTitle,
    this.chapterNumber,
    this.databasePath,
    this.workspaceSection,
    this.workspaceItemId,
    this.workspaceTitle,
    this.workspaceContent,
    this.workspaceMetaTitle,
    this.workspaceMetaContent,
    this.onApplyGeneratedContent,
    this.onSetAsAvatar,
    this.onAddPhoto,
    this.composerHint,
    this.draftMessage,
    this.handoffDraft,
    this.onRequestHandoff,
    this.shortcutDraft,
    this.onHandoffDraftConsumed,
    this.onShortcutDraftConsumed,
    this.activeSessionId,
    this.onRequestNewSession,
    this.onEditingStateChanged,
    this.onSessionRestored,
    this.onActiveSessionIdChanged,
    this.onOpenSessionReference,
    this.onOpenFeature,
    this.headerActionsGestureExclusionKey,
    required this.pendingAiChanges,
    required this.onCollapse,
  });

  final Novel novel;
  final String? chapterId;
  final String? chapterTitle;
  final int? chapterNumber;
  final String? databasePath;
  final NovelWorkspaceSection? workspaceSection;
  final String? workspaceItemId;
  final String? workspaceTitle;
  final String? workspaceContent;
  final String? workspaceMetaTitle;
  final String? workspaceMetaContent;
  final Future<void> Function(String content)? onApplyGeneratedContent;
  final Future<void> Function(String assetId, String characterId)?
  onSetAsAvatar;
  final Future<void> Function(
    String assetId, {
    String? characterId,
    String? itemId,
  })?
  onAddPhoto;
  final String? composerHint;
  final AiChatDraftMessage? draftMessage;
  final AiChatHandoffDraft? handoffDraft;
  final ValueChanged<AiChatHandoffDraft>? onRequestHandoff;
  final AiChatShortcutDraft? shortcutDraft;
  final ValueChanged<String>? onHandoffDraftConsumed;
  final ValueChanged<String>? onShortcutDraftConsumed;
  final String? activeSessionId;
  final Future<void> Function()? onRequestNewSession;
  final ValueChanged<bool>? onEditingStateChanged;
  final ValueChanged<String>? onSessionRestored;
  final Future<void> Function(String?)? onActiveSessionIdChanged;
  final Future<void> Function(String sessionId, AiSessionMode mode)?
  onOpenSessionReference;

  /// 透传给 [AiChatPanel]：跳到圆桌 / 小剧场 / 封面工作台。
  final void Function(FeatureId feature, String? seedText)? onOpenFeature;

  /// 注册在页面根 [DesktopWindowFrame.titleBarGestureExclusionKeys] 中的 key，
  /// 防止双击聊天顶栏操作按钮触发窗口最大化。
  final GlobalKey? headerActionsGestureExclusionKey;
  final List<WorkingChange> pendingAiChanges;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final persistedSessionId = ref.watch(
      aiChatSessionProvider(
        activeSessionId,
      ).select((session) => session.sessionId),
    );
    final effectiveSessionId = persistedSessionId ?? activeSessionId;
    final hasTodos = ref.watch(
      sessionTodosProvider(
        effectiveSessionId,
      ).select((async) => async.asData?.value.isNotEmpty ?? false),
    );
    final hasChanges = databasePath != null && pendingAiChanges.isNotEmpty;
    final hasSidePanelContent = hasTodos || hasChanges;

    return _ExpandedChatMotion(
      onCollapse: onCollapse,
      builder: (context, animatedCollapse) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final sidePanelWidth = resolveExpandedChatSidePanelWidth(
              constraints.maxWidth,
              hasSidePanelContent: hasSidePanelContent,
            );
            final showSidePanel = sidePanelWidth != null;

            return Row(
              children: [
                Expanded(
                  child: RepaintBoundary(
                    child: AiChatPanel(
                      isExpanded: showSidePanel,
                      avoidWindowCaption: false,
                      clearWindowCaptionTrailing: !showSidePanel,
                      onCollapse: animatedCollapse,
                      headerActionsGestureExclusionKey:
                          headerActionsGestureExclusionKey,
                      novel: novel,
                      chapterId: chapterId,
                      chapterTitle: chapterTitle,
                      chapterNumber: chapterNumber,
                      databasePath: databasePath,
                      workspaceSection: workspaceSection,
                      workspaceItemId: workspaceItemId,
                      workspaceTitle: workspaceTitle,
                      workspaceContent: workspaceContent,
                      workspaceMetaTitle: workspaceMetaTitle,
                      workspaceMetaContent: workspaceMetaContent,
                      onApplyGeneratedContent: onApplyGeneratedContent,
                      onSetAsAvatar: onSetAsAvatar,
                      onAddPhoto: onAddPhoto,
                      composerHint: composerHint,
                      draftMessage: draftMessage,
                      handoffDraft: handoffDraft,
                      onRequestHandoff: onRequestHandoff,
                      shortcutDraft: shortcutDraft,
                      onHandoffDraftConsumed: onHandoffDraftConsumed,
                      onShortcutDraftConsumed: onShortcutDraftConsumed,
                      activeSessionId: activeSessionId,
                      onRequestNewSession: onRequestNewSession,
                      onEditingStateChanged: onEditingStateChanged,
                      onSessionRestored: onSessionRestored,
                      onActiveSessionIdChanged: onActiveSessionIdChanged,
                      onOpenSessionReference: onOpenSessionReference,
                      onOpenFeature: onOpenFeature,
                    ),
                  ),
                ),
                if (showSidePanel) ...[
                  Container(
                    width: RevericSizes.dividerThickness,
                    color: colors.border,
                  ),
                  SizedBox(
                    width: sidePanelWidth,
                    child: RepaintBoundary(
                      child: ChatSidePanel(
                        novelId: novel.id,
                        databasePath: databasePath,
                        changes: pendingAiChanges,
                        sessionId: effectiveSessionId,
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }
}

class _ExpandedChatMotion extends StatefulWidget {
  const _ExpandedChatMotion({required this.onCollapse, required this.builder});

  final VoidCallback onCollapse;
  final _ExpandedChatContentBuilder builder;

  @override
  State<_ExpandedChatMotion> createState() => _ExpandedChatMotionState();
}

class _ExpandedChatMotionState extends State<_ExpandedChatMotion>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curvedAnimation;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _slideAnimation;
  bool _isCollapsing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: _expandedChatMotionDuration,
      reverseDuration: _expandedChatCollapseDuration,
      vsync: this,
    );
    _curvedAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _fadeAnimation = _curvedAnimation;
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0.025, 0),
      end: Offset.zero,
    ).animate(_curvedAnimation);
    _controller.forward();
  }

  @override
  void dispose() {
    _curvedAnimation.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _collapse() async {
    if (_isCollapsing) {
      return;
    }
    _isCollapsing = true;
    await _controller.reverse();
    if (!mounted) {
      return;
    }
    widget.onCollapse();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: widget.builder(context, _collapse),
      ),
    );
  }
}

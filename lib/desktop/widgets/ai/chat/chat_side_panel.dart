// 职责: 展开模式右侧面板 — TODO 任务列表 + 待处理变更摘要
// 关联文件:
//   lib/shared/widgets/ai/chat/todo_panel.dart
//   lib/desktop/widgets/ai/diff/pending_changes_summary_card.dart
//   lib/desktop/widgets/ai/chat/expanded_chat_area.dart
//   lib/desktop/widgets/desktop_window_frame.dart
// 遵循的 Rules:
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../shared/database/novel_content_database.dart'
    show WorkingChange;
import '../../../../shared/localization/app_localization.dart';
import '../../../../shared/localization/locale_keys.dart';
import '../../../../shared/theme/theme.dart';
import '../../../../shared/widgets/app_background.dart';
import '../../../../shared/widgets/ai/chat/todo_panel.dart';
import '../../desktop_window_frame.dart';
import '../diff/pending_changes_summary_card.dart';

class ChatSidePanel extends HookConsumerWidget {
  const ChatSidePanel({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.changes,
    required this.onCollapse,
    this.sessionId,
    this.headerTrailingInset = 0,
  });

  final String? databasePath;
  final String novelId;
  final List<WorkingChange> changes;
  final VoidCallback onCollapse;
  final String? sessionId;

  /// Extra right padding so header actions clear Windows caption buttons
  /// (and any collapsed AI rail outside this panel).
  final double headerTrailingInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);

    return Container(
      color: appChromeBackgroundColor(
        colors,
        ref.watch(appBackgroundActiveProvider),
        colors.surfaceContainerHigh,
      ),
      child: Column(
        children: [
          Container(
            height: DesktopWindowFrame.titleBarHeight,
            padding: EdgeInsets.only(
              left: RevericSpacing.md,
              right: RevericSpacing.md + headerTrailingInset,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: context.t(LocaleKeys.aiChatCollapse),
                  onPressed: onCollapse,
                  iconSize: 16,
                  padding: const EdgeInsets.all(RevericSpacing.xs),
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  icon: RevericIcon(
                    RevericIcons.close_fullscreen_rounded,
                    size: 16,
                    color: colors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: RevericSizes.dividerThickness, color: colors.border),
          Expanded(
            flex: 1,
            child: RepaintBoundary(
              child: TodoPanel(initialExpanded: true, sessionId: sessionId),
            ),
          ),
          Divider(height: RevericSizes.dividerThickness, color: colors.border),
          Expanded(
            flex: 1,
            child: RepaintBoundary(
              child: databasePath != null && changes.isNotEmpty
                  ? PendingChangesSummaryCard(
                      novelId: novelId,
                      databasePath: databasePath!,
                      changes: changes,
                      initialExpanded: true,
                      // 这里卡片直接贴分隔线，顶部补回一格外边距。
                      margin: const EdgeInsets.fromLTRB(
                        RevericSpacing.lg,
                        RevericSpacing.lg,
                        RevericSpacing.lg,
                        RevericSpacing.sm,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}

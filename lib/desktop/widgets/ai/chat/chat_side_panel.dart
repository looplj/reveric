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
import '../../../../shared/providers/todo_providers.dart';
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
    this.sessionId,
  });

  final String? databasePath;
  final String novelId;
  final List<WorkingChange> changes;
  final String? sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final hasTodos = ref.watch(
      sessionTodosProvider(
        sessionId,
      ).select((async) => async.asData?.value.isNotEmpty ?? false),
    );
    final hasChanges = databasePath != null && changes.isNotEmpty;

    return Container(
      color: appChromeBackgroundColor(
        colors,
        ref.watch(appBackgroundActiveProvider),
        colors.surfaceContainerHigh,
      ),
      child: Column(
        children: [
          // 与左侧 ChatHeader 等高，避让 Windows 窗口按钮并保持顶部分割线齐平。
          const SizedBox(height: DesktopWindowFrame.titleBarHeight),
          Divider(height: RevericSizes.dividerThickness, color: colors.border),
          if (hasTodos)
            Expanded(
              child: RepaintBoundary(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: TodoPanel(initialExpanded: true, sessionId: sessionId),
                ),
              ),
            ),
          if (hasTodos && hasChanges)
            Divider(
              height: RevericSizes.dividerThickness,
              color: colors.border,
            ),
          if (hasChanges)
            Expanded(
              child: RepaintBoundary(
                child: SingleChildScrollView(
                  child: PendingChangesSummaryCard(
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
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

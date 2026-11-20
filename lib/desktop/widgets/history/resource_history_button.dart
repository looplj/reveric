// 职责: 资源级修改历史入口按钮 — 打开仅展示该资源历史的轻量弹窗。
// 关联文件:
//   lib/shared/providers/novel_providers.dart
//   lib/desktop/widgets/history/change_history_panel.dart
//   lib/shared/services/working_change_summary.dart
import 'package:flutter/material.dart';

import '../../../shared/components/dialog_feedback.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/theme/theme.dart';
import 'change_history_panel.dart';

class ResourceHistoryButton extends StatelessWidget {
  const ResourceHistoryButton({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.resourceId,
    required this.resourceLabel,
  });

  final String databasePath;
  final String novelId;
  final String resourceId;
  final String resourceLabel;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return IconButton(
      tooltip: context.t(LocaleKeys.historyOpenForResource),
      icon: RevericIcon(
        RevericIcons.history_rounded,
        size: 18,
        color: colors.textMuted,
      ),
      onPressed: () => showResourceHistoryDialog(
        context,
        databasePath: databasePath,
        novelId: novelId,
        resourceId: resourceId,
        resourceLabel: resourceLabel,
      ),
    );
  }
}

Future<void> showResourceHistoryDialog(
  BuildContext context, {
  required String databasePath,
  required String novelId,
  required String resourceId,
  required String resourceLabel,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(RevericSpacing.x3l),
        child: SizedBox(
          width: 1080,
          height: 720,
          child: DialogFeedback(
            builder: (context) => ChangeHistoryPanel(
              novelId: novelId,
              databasePath: databasePath,
              resourceId: resourceId,
              resourceLabel: resourceLabel,
              onClose: () => Navigator.of(dialogContext).pop(),
            ),
          ),
        ),
      );
    },
  );
}

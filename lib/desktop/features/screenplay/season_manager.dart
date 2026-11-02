// 职责: 在桌面 dialog 中打开季管理。
// 关联文件:
//   lib/desktop/features/screenplay/context_panel.dart
//   lib/shared/widgets/screenplay/season_manager.dart

import 'package:flutter/material.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/screenplay/season_manager.dart';

Future<void> showScreenplaySeasonManager(
  BuildContext context, {
  required String novelId,
  required String databasePath,
  required String screenplayId,
  required Future<bool> Function() onFlush,
  String? editSeasonId,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: RevericTheme.colorsOf(context).surface,
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: SizedBox(
          width: RevericSizes.screenplaySeasonManagerWidth,
          child: ScreenplaySeasonManager(
            novelId: novelId,
            databasePath: databasePath,
            screenplayId: screenplayId,
            onFlush: onFlush,
            editSeasonId: editSeasonId,
          ),
        ),
      ),
    ),
  );
}

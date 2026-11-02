// 职责: 在移动端 bottom sheet 中打开季管理并避让键盘。
// 关联文件:
//   lib/mobile/features/screenplay/episode_picker_sheet.dart
//   lib/shared/widgets/screenplay/season_manager.dart

import 'package:flutter/material.dart';
import '../../../shared/database/app_database.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/screenplay/season_manager.dart';

Future<void> showMobileScreenplaySeasonManager(
  BuildContext context, {
  required Novel novel,
  required String screenplayId,
  required Future<bool> Function() onFlush,
  String? editSeasonId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.78,
    ),
    backgroundColor: RevericTheme.colorsOf(context).canvas,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(RevericRadius.x2l),
      ),
    ),
    clipBehavior: Clip.antiAlias,
    // 高度上限只由外层 constraints 定一次；键盘顶起来靠 viewInsets，
    // 清开 home indicator 靠 SafeArea + x5l，三者各管一段，不再互相叠加。
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(bottom: RevericSpacing.x5l),
          child: ScreenplaySeasonManager(
            novelId: novel.id,
            databasePath: novel.contentDatabasePath!,
            screenplayId: screenplayId,
            onFlush: onFlush,
            editSeasonId: editSeasonId,
          ),
        ),
      ),
    ),
  );
}

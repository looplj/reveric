// 职责: 视频生成输入框的发送按钮：按是否选了样片提示「生成样片」或「生成」，被挡住时提示原因。
// 关联文件:
//   lib/desktop/features/production/composer.dart
//   lib/desktop/features/production/spec_panel.dart
//   lib/desktop/features/production/popover.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json

import 'package:flutter/material.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/theme/theme.dart';
import 'popover.dart';

class ProductionGenerateButton extends StatelessWidget {
  const ProductionGenerateButton({
    super.key,
    required this.onGenerate,
    required this.blocked,
    required this.draft,
    required this.repeat,
  });
  final VoidCallback onGenerate;
  final String? blocked;

  /// 这次提交出样片；样片在「比例 · 分辨率」里选择。
  final bool draft;
  final bool repeat;

  @override
  Widget build(BuildContext context) => ProductionSendButton(
    icon: repeat
        ? RevericIcons.arrow_clockwise
        : RevericIcons.arrow_upward_rounded,
    tooltip:
        blocked ??
        context.t(
          draft
              ? LocaleKeys.productionGenerateDraft
              : LocaleKeys.productionGenerate,
        ),
    onPressed: blocked == null ? onGenerate : null,
  );
}

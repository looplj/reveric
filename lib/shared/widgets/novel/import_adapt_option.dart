// 职责: TXT 导入表单里的「导入后改编为剧本」勾选行 — 整行可点，两端共用。
// 关联文件:
//   lib/desktop/widgets/novel_import_dialog.dart
//   lib/mobile/pages/novel_import_page.dart
//   lib/shared/components/reveric_checkbox.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
// 遵循的 Rules:
//   .agents/rules/design-system.md

import 'package:flutter/material.dart';

import '../../components/reveric_checkbox.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../theme/theme.dart';

class NovelImportAdaptOption extends StatelessWidget {
  const NovelImportAdaptOption({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;

  /// 为 null 时禁用（导入进行中）。
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final onChanged = this.onChanged;
    // 整行点击和复选框是同一操作，由行内文字提供读屏标签。
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        onTap: onChanged == null ? null : () => onChanged(!value),
        child: Row(
          children: [
            RevericCheckbox(value: value, onChanged: onChanged),
            Expanded(
              child: Text(
                context.t(LocaleKeys.libraryAdaptAfterImport),
                style: typo.ui.copyWith(color: colors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

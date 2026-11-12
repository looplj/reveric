// 职责: 在桌面侧栏底部提供直达关于页的新版本入口。
// 关联文件:
//   lib/shared/providers/update_providers.dart
//   lib/desktop/widgets/settings/settings_dialog.dart
//   lib/desktop/pages/home.dart
//   lib/desktop/widgets/sidebar/sidebar.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/providers/update_providers.dart';
import '../../shared/theme/theme.dart';
import 'settings/settings_dialog.dart';

class DesktopUpdateEntry extends ConsumerWidget {
  const DesktopUpdateEntry({super.key, this.iconOnly = false});

  final bool iconOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(availableUpdateProvider);
    if (info == null) {
      return const SizedBox.shrink();
    }
    final colors = RevericTheme.colorsOf(context);
    final label = context.t(
      LocaleKeys.settingsUpdateEntry,
      namedArgs: {'version': info.version},
    );
    void open() {
      showSettingsSectionDialog(context, 'about');
    }

    if (iconOnly) {
      return IconButton(
        tooltip: label,
        onPressed: open,
        icon: RevericIcon(
          RevericIcons.system_update_outlined,
          color: colors.accent,
        ),
      );
    }
    return Tooltip(
      message: label,
      child: TextButton(
        onPressed: open,
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: RevericTheme.typographyOf(
            context,
          ).uiSmall.copyWith(color: colors.accent),
        ),
      ),
    );
  }
}

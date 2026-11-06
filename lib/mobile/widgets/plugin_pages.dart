// 职责: 移动端插件页面入口 — 书库中的插件分区按钮。
// 关联文件:
//   lib/shared/widgets/plugin_view/navigation.dart
//   lib/shared/widgets/plugin_view/page.dart
//   lib/mobile/pages/library_page.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import '../../shared/components/reveric_button.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/plugin_view/navigation.dart';
import '../../shared/widgets/plugin_view/page.dart';

/// 书库中的插件分区：分区标题与书库其他分区对齐，入口横向换行排列。
class MobilePluginPageShelf extends StatelessWidget {
  const MobilePluginPageShelf({super.key});

  @override
  Widget build(BuildContext context) {
    return PluginPageNavigation(
      builder: (context, views) {
        final colors = RevericTheme.colorsOf(context);
        final typo = RevericTheme.typographyOf(context);
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.x3l,
            0,
            RevericSpacing.x3l,
            RevericSpacing.x3l,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.t(LocaleKeys.settingsPlugins),
                style: typo.uiSmallSemibold.copyWith(color: colors.textMuted),
              ),
              const SizedBox(height: RevericSpacing.md),
              Wrap(
                spacing: RevericSpacing.sm,
                runSpacing: RevericSpacing.sm,
                children: [
                  for (final view in views)
                    RevericButton.secondary(
                      label: view.title.resolve(
                        Localizations.localeOf(context),
                      ),
                      icon: pluginPageIcon,
                      onPressed: () => openPluginPage(context, view),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

// 职责: 移动端插件页面入口 — 书库分区按钮与编辑器标题栏的插件选择 sheet。
// 关联文件:
//   lib/shared/widgets/plugin_view/navigation.dart
//   lib/shared/widgets/plugin_view/page.dart
//   lib/mobile/widgets/sheet.dart
//   lib/mobile/pages/library_page.dart
//   lib/mobile/pages/novel_editor_page.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import '../../shared/components/reveric_button.dart';
import '../../shared/components/reveric_icon_button.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/models/plugin/view.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/plugin_view/navigation.dart';
import '../../shared/widgets/plugin_view/page.dart';
import 'sheet.dart';

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

/// 编辑器标题栏的插件入口：只有一个页面时直接打开，否则先选择。
class MobilePluginPageButton extends StatelessWidget {
  const MobilePluginPageButton({super.key, required this.workId});

  final String workId;

  @override
  Widget build(BuildContext context) {
    return PluginPageNavigation(
      builder: (context, views) => RevericIconButton(
        icon: pluginPageIcon,
        tooltip: context.t(LocaleKeys.settingsPlugins),
        onPressed: () async {
          final selected = views.length == 1
              ? views.single
              : await _pickView(context, views);
          if (selected != null && context.mounted) {
            await openPluginPage(context, selected, workId: workId);
          }
        },
      ),
    );
  }

  Future<PluginView?> _pickView(BuildContext context, List<PluginView> views) {
    return showMobileSheet<PluginView>(
      context: context,
      builder: (sheet) {
        final colors = RevericTheme.colorsOf(sheet);
        final typo = RevericTheme.typographyOf(sheet);
        return MobileSheetScaffold(
          header: MobileSheetHeader(title: sheet.t(LocaleKeys.settingsPlugins)),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final view in views)
                  ListTile(
                    leading: RevericIcon(
                      pluginPageIcon,
                      size: 20,
                      color: colors.textSecondary,
                    ),
                    title: Text(
                      view.title.resolve(Localizations.localeOf(sheet)),
                      style: typo.ui.copyWith(color: colors.textPrimary),
                    ),
                    onTap: () => Navigator.of(sheet).pop(view),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

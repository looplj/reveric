// 职责: 展示插件列表与安装入口，并把详情、安装预览交给平台外壳打开。
// 关联文件:
//   lib/shared/widgets/settings/plugins/row.dart
//   lib/shared/widgets/settings/plugins/install_button.dart
//   lib/shared/widgets/settings/plugins/navigation.dart
//   lib/shared/providers/plugin_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/en/plugin.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/zh-CN/plugin.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../components/reveric_placeholder.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../providers/plugin_providers.dart';
import '../../../theme/theme.dart';
import '../settings_section_widgets.dart';
import 'install_button.dart';
import 'navigation.dart';
import 'overview.dart';
import 'row.dart';

class PluginsSettingsSection extends HookConsumerWidget {
  const PluginsSettingsSection({super.key, this.onOpen});

  /// 桌面外壳注入就地打开；为空时推入全屏子页面。
  final ValueChanged<PluginSettingsTarget>? onOpen;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plugins = ref.watch(pluginStatusesProvider);
    final installFailed = useState(false);
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    void open(PluginSettingsTarget target) {
      installFailed.value = false;
      if (onOpen case final onOpen?) {
        onOpen(target);
      } else {
        pushPluginSettingsPage(context, target);
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(RevericSpacing.x4l),
      child: SettingsSection(
        titleKey: LocaleKeys.settingsPlugins,
        descriptionKey: LocaleKeys.pluginDescription,
        trailing: PluginInstallButton(
          onPicked: (archive) => open(PluginPreviewTarget(archive)),
          onFailed: () => installFailed.value = true,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (installFailed.value) ...[
              PluginNotice(message: context.t(LocaleKeys.pluginPackageInvalid)),
              const SizedBox(height: RevericSpacing.lg),
            ],
            plugins.when(
              loading: () => const LinearProgressIndicator(),
              error: (_, _) => Text(
                context.t(LocaleKeys.pluginLoadFailed),
                style: typo.ui.copyWith(color: colors.warningText),
              ),
              data: (items) => items.isEmpty
                  ? SettingsCard(
                      children: [
                        Center(
                          child: RevericPlaceholder.empty(
                            icon: RevericIcons.layers_outlined,
                            description: context.t(LocaleKeys.pluginEmpty),
                          ),
                        ),
                      ],
                    )
                  : SettingsCard(
                      padding: EdgeInsets.zero,
                      children: [
                        for (final (index, item) in items.indexed) ...[
                          if (index > 0) const SettingsRowDivider(),
                          PluginSettingsRow(
                            key: ValueKey(item.id),
                            status: item,
                            onOpen: () => open(PluginDetailTarget(item.id)),
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

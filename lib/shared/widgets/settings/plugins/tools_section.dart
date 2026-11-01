// 职责: 以默认折叠的分区展示插件提供的工具名称与描述，供详情与安装预览共用。
// 关联文件:
//   lib/shared/widgets/settings/plugins/detail_page.dart
//   lib/shared/widgets/settings/plugins/preview_page.dart
//   lib/shared/services/plugins/registry.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/plugin.json
//   assets/translations/zh-CN/plugin.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../services/plugins/registry.dart';
import '../../../theme/theme.dart';
import '../settings_section_widgets.dart';

class PluginToolsSection extends HookWidget {
  const PluginToolsSection({
    super.key,
    required this.tools,
    required this.emptyText,
    this.overriddenBy,
  });

  final List<PluginTool> tools;
  final String emptyText;

  /// 同名工具当前由其他插件提供时返回该插件名称。
  final String? Function(PluginTool tool)? overriddenBy;

  @override
  Widget build(BuildContext context) {
    // 工具描述写给模型看，篇幅长且偏技术，默认只露出数量。
    final expanded = useState(false);
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(RevericRadius.small),
          onTap: tools.isEmpty ? null : () => expanded.value = !expanded.value,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: RevericSpacing.xs),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    context.t(
                      LocaleKeys.pluginToolsCount,
                      namedArgs: {'count': '${tools.length}'},
                    ),
                    style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                  ),
                ),
                if (tools.isNotEmpty)
                  Tooltip(
                    message: context.t(
                      expanded.value
                          ? LocaleKeys.commonCollapse
                          : LocaleKeys.commonExpand,
                    ),
                    child: RevericIcon(
                      expanded.value
                          ? RevericIcons.expand_less_rounded
                          : RevericIcons.expand_more,
                      size: RevericSizes.buttonIconSize,
                      color: colors.textMuted,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: RevericSpacing.sm),
        if (tools.isEmpty)
          Text(emptyText, style: typo.uiSmall.copyWith(color: colors.textMuted))
        else if (expanded.value)
          SettingsCard(
            padding: EdgeInsets.zero,
            children: [
              for (final (index, tool) in tools.indexed) ...[
                if (index > 0) const SettingsRowDivider(),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.lg,
                    vertical: RevericSpacing.md,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(switch (overriddenBy?.call(tool)) {
                        null => tool.name,
                        final plugin =>
                          '${tool.name} · ${context.t(LocaleKeys.pluginOverridden, namedArgs: {'plugin': plugin})}',
                      }, style: typo.ui.copyWith(color: colors.textPrimary)),
                      const SizedBox(height: RevericSpacing.xxs),
                      Text(
                        tool.toolDef.description,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: typo.uiSmall.copyWith(color: colors.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
      ],
    );
  }
}

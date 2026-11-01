// 职责: 把插件权限标识转换为能力说明，并在安装预览与插件详情中统一展示。
// 关联文件:
//   lib/shared/widgets/settings/plugins/detail_page.dart
//   lib/shared/widgets/settings/plugins/preview_page.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/plugin.json
//   assets/translations/zh-CN/plugin.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import '../../../components/reveric_badge.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../theme/theme.dart';
import '../settings_section_widgets.dart';

/// 宿主认识的权限及其标题、说明；未列出的标识按未知权限提示。
const _permissionKeys = {
  'ai.generateText': (
    LocaleKeys.pluginPermissionAiTitle,
    LocaleKeys.pluginAiPermission,
  ),
  'chapters.read': (
    LocaleKeys.pluginPermissionChaptersReadTitle,
    LocaleKeys.pluginPermissionChaptersRead,
  ),
  'chapters.write': (
    LocaleKeys.pluginPermissionChaptersWriteTitle,
    LocaleKeys.pluginPermissionChaptersWrite,
  ),
  'characters.read': (
    LocaleKeys.pluginPermissionCharactersReadTitle,
    LocaleKeys.pluginPermissionCharactersRead,
  ),
  'characters.write': (
    LocaleKeys.pluginPermissionCharactersWriteTitle,
    LocaleKeys.pluginPermissionCharactersWrite,
  ),
};

/// 权限列表卡片。[highlighted] 中的权限标为「新增」，其余淡化显示。
class PluginPermissionList extends StatelessWidget {
  const PluginPermissionList({
    super.key,
    required this.permissions,
    this.highlighted,
  });

  final Iterable<String> permissions;

  /// 为 null 时不区分新增与已授权。
  final Set<String>? highlighted;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final ordered = [
      ...permissions.where((item) => highlighted?.contains(item) ?? true),
      ...permissions.where((item) => !(highlighted?.contains(item) ?? true)),
    ];
    return SettingsCard(
      padding: EdgeInsets.zero,
      children: [
        for (final (index, permission) in ordered.indexed) ...[
          if (index > 0) const SettingsRowDivider(),
          Builder(
            builder: (context) {
              final keys = _permissionKeys[permission];
              final isNew = highlighted?.contains(permission) ?? false;
              final granted =
                  highlighted != null && !highlighted!.contains(permission);
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.lg,
                  vertical: RevericSpacing.md,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: RevericSpacing.xxs),
                      child: RevericIcon(
                        keys == null
                            ? RevericIcons.warning_circle
                            : RevericIcons.check_circle,
                        size: RevericSizes.buttonIconSize,
                        color: keys == null
                            ? colors.warningText
                            : granted
                            ? colors.textSubtle
                            : colors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: RevericSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  context.t(
                                    keys?.$1 ??
                                        LocaleKeys.pluginPermissionUnknownTitle,
                                  ),
                                  style: typo.uiSemibold.copyWith(
                                    color: granted
                                        ? colors.textMuted
                                        : colors.textPrimary,
                                  ),
                                ),
                              ),
                              if (isNew) ...[
                                const SizedBox(width: RevericSpacing.sm),
                                RevericBadge(
                                  label: context.t(
                                    LocaleKeys.pluginPermissionNew,
                                  ),
                                  color: colors.accent,
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: RevericSpacing.xxs),
                          Text(
                            keys == null
                                ? context.t(
                                    LocaleKeys.pluginPermissionUnknown,
                                    namedArgs: {'permission': permission},
                                  )
                                : context.t(keys.$2),
                            style: typo.uiSmall.copyWith(
                              color: keys == null
                                  ? colors.warningText
                                  : colors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}

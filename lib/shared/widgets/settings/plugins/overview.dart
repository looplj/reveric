// 职责: 展示插件身份信息头（名称、版本、来源、作者、状态与描述），供详情与安装预览共用。
// 关联文件:
//   lib/shared/widgets/settings/plugins/detail_page.dart
//   lib/shared/widgets/settings/plugins/preview_page.dart
//   lib/shared/models/plugin/manifest.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/plugin.json
//   assets/translations/zh-CN/plugin.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../models/plugin/manifest.dart';
import '../../../theme/theme.dart';
import '../settings_section_widgets.dart';

class PluginOverview extends StatelessWidget {
  const PluginOverview({
    super.key,
    required this.manifest,
    required this.local,
    this.previousVersion,
    this.badge,
    this.trailing,
    this.notices = const [],
  });

  final PluginManifest manifest;

  /// 本地安装的插件；否则为内置插件。
  final bool local;

  /// 升级预览时已安装的版本，显示为「旧版本 → 新版本」。
  final String? previousVersion;
  final Widget? badge;

  /// 标题行右侧的控件，如启停开关。
  final Widget? trailing;

  /// 描述下方需要用户处理的提示。
  final List<Widget> notices;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final locale = Localizations.localeOf(context);
    final author = manifest.author;
    final meta = [
      previousVersion == null
          ? manifest.version
          : context.t(
              LocaleKeys.pluginVersionUpgrade,
              namedArgs: {'from': previousVersion!, 'to': manifest.version},
            ),
      context.t(local ? LocaleKeys.pluginLocal : LocaleKeys.pluginBundled),
      if (author != null && author.isNotEmpty)
        context.t(LocaleKeys.pluginAuthor, namedArgs: {'author': author}),
    ].join(' · ');
    final description = manifest.description?.resolve(locale);
    return SettingsCard(
      padding: const EdgeInsets.all(RevericSpacing.lg),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: RevericSpacing.sm,
                    runSpacing: RevericSpacing.xxs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        manifest.name.resolve(locale),
                        style: typo.heading2.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                      ?badge,
                    ],
                  ),
                  const SizedBox(height: RevericSpacing.xxs),
                  Text(
                    meta,
                    style: typo.uiSmall.copyWith(color: colors.textMuted),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: RevericSpacing.lg),
              trailing!,
            ],
          ],
        ),
        if (description != null && description.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.md),
          Text(
            description,
            style: typo.ui.copyWith(color: colors.textSecondary),
          ),
        ],
        for (final notice in notices) ...[
          const SizedBox(height: RevericSpacing.md),
          notice,
        ],
      ],
    );
  }
}

/// 需要用户处理的提示行，可附带一个操作按钮。
class PluginNotice extends StatelessWidget {
  const PluginNotice({super.key, required this.message, this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        RevericIcon(
          RevericIcons.warning_circle,
          size: RevericSizes.buttonIconSize,
          color: colors.warningText,
        ),
        const SizedBox(width: RevericSpacing.sm),
        Expanded(
          child: Text(
            message,
            style: typo.uiSmall.copyWith(color: colors.warningText),
          ),
        ),
        if (action != null) ...[
          const SizedBox(width: RevericSpacing.md),
          action!,
        ],
      ],
    );
  }
}

// 职责: 在插件列表中展示单个插件的状态与待处理提示，提供启停开关并进入详情。
// 关联文件:
//   lib/shared/widgets/settings/plugins/section.dart
//   lib/shared/widgets/settings/plugins/status.dart
//   lib/shared/widgets/settings/plugins/enable_switch.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/plugin.json
//   assets/translations/zh-CN/plugin.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../components/reveric_badge.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../providers/settings_providers.dart';
import '../../../services/plugins/host.dart';
import '../../../theme/theme.dart';
import 'enable_switch.dart';
import 'status.dart';

/// 插件显示名；清单读取失败时退回包路径中的目录名。
String pluginDisplayName(PluginStatus status, Locale locale) =>
    status.manifest?.name.resolve(locale) ??
    status.path
        .split('/')
        .where((part) => part.isNotEmpty)
        .skip(2)
        .firstOrNull ??
    status.id;

class PluginSettingsRow extends HookConsumerWidget {
  const PluginSettingsRow({
    super.key,
    required this.status,
    required this.onOpen,
  });
  final PluginStatus status;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saveFailed = useState(false);
    final manifest = status.manifest;
    final colors = RevericTheme.colorsOf(context),
        typo = RevericTheme.typographyOf(context);
    final locale = Localizations.localeOf(context);
    final mobile = defaultTargetPlatform == TargetPlatform.android;
    final name = pluginDisplayName(status, locale);
    final (statusKey, statusColor) = pluginStatusBadge(status, colors);
    final unavailableModels = pluginUnavailableModelFields(
      status,
      ref.watch(aiSettingsProvider),
      locale,
    );
    // 列表只露出一条最需要处理的提示，细节在详情页展开。
    final issue = saveFailed.value
        ? context.t(LocaleKeys.pluginSaveFailed)
        : status.state == 'failed'
        ? context.t(pluginFailureKey(status.error))
        : status.state == 'needs_permission'
        ? context.t(LocaleKeys.pluginPermissionRequired)
        : status.needsConfig
        ? context.t(LocaleKeys.pluginConfigRequired)
        : unavailableModels.isNotEmpty
        ? context.t(
            LocaleKeys.pluginModelUnavailable,
            namedArgs: {'fields': unavailableModels.join(', ')},
          )
        : switch (status.promptDiagnostic) {
            null => null,
            final diagnostic => context.t(
              LocaleKeys.pluginPromptSkipped,
              namedArgs: {'requestId': diagnostic.requestId},
            ),
          };

    final description = manifest?.description?.resolve(locale) ?? '';
    // 卡片自带底色，水波纹需要画在行自己的 Material 上才看得见。
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: ValueKey('plugin-details-${status.id}'),
        onTap: onOpen,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: RevericSpacing.lg,
            vertical: mobile ? RevericSpacing.lg : RevericSpacing.md,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: typo.uiSemibold.copyWith(
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: RevericSpacing.sm),
                        RevericBadge(
                          label: context.t(statusKey),
                          color: statusColor,
                        ),
                      ],
                    ),
                    if (description.isNotEmpty) ...[
                      const SizedBox(height: RevericSpacing.xxs),
                      Text(
                        description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.uiSmall.copyWith(color: colors.textMuted),
                      ),
                    ],
                    if (issue != null) ...[
                      const SizedBox(height: RevericSpacing.xxs),
                      Text(
                        issue,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: typo.uiSmall.copyWith(color: colors.warningText),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: RevericSpacing.md),
              // 必填配置未填写时不能开启，直接带用户去详情页填写。
              PluginEnableSwitch(
                status: status,
                semanticLabel: name,
                onNeedsConfig: onOpen,
                onSaveFailed: (failed) => saveFailed.value = failed,
              ),
              const SizedBox(width: RevericSpacing.sm),
              RevericIcon(
                RevericIcons.chevron_right,
                size: RevericSizes.buttonIconSize,
                color: colors.textSubtle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

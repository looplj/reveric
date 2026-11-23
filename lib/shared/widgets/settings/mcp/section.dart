// 职责: 展示跨平台 MCP 设置列表并打开配置编辑入口。
// 关联文件:
//   lib/shared/widgets/settings/mcp/server_row.dart
//   lib/shared/widgets/settings/mcp/server_editor.dart
//   lib/shared/widgets/settings/mcp/notice.dart
//   lib/shared/providers/mcp_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/reveric_button.dart';
import '../../../components/reveric_placeholder.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../models/mcp/config.dart';
import '../../../providers/mcp_providers.dart';
import '../../../theme/theme.dart';
import '../settings_section_widgets.dart';
import 'notice.dart';
import 'server_editor.dart';
import 'server_row.dart';

class McpSettingsSection extends ConsumerWidget {
  const McpSettingsSection({super.key, this.onEdit});

  /// 桌面外壳注入就地编辑；为空时推入全屏编辑页。参数为空表示新建。
  final ValueChanged<McpServerConfig?>? onEdit;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(mcpSettingsProvider);
    void open(McpServerConfig? config) {
      if (onEdit case final onEdit?) {
        onEdit(config);
      } else {
        showMcpServerEditor(context, config: config);
      }
    }

    final callbackExpired =
        ref.watch(mcpSettingsServiceProvider).callbacks.lastError != null;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(RevericSpacing.x4l),
      child: SettingsSection(
        titleKey: LocaleKeys.settingsMcp,
        descriptionKey: LocaleKeys.settingsMcpDescription,
        trailing: RevericButton.primary(
          icon: RevericIcons.add,
          label: context.t(LocaleKeys.commonAdd),
          onPressed: settings.hasValue ? () => open(null) : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (callbackExpired) ...[
              McpNotice(
                message: context.t(LocaleKeys.settingsMcpCallbackExpired),
              ),
              const SizedBox(height: RevericSpacing.lg),
            ],
            settings.when(
              loading: () => const SettingsCard(
                children: [
                  Center(
                    child: Padding(
                      padding: EdgeInsets.all(RevericSpacing.x4l),
                      child: SizedBox.square(
                        dimension: RevericSizes.buttonIconSize,
                        child: CircularProgressIndicator(
                          strokeWidth: RevericSizes.buttonProgressStroke,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              error: (_, _) => SettingsCard(
                children: [
                  Center(
                    child: RevericPlaceholder.error(
                      title: context.t(LocaleKeys.settingsMcpInvalid),
                    ),
                  ),
                ],
              ),
              data: (value) {
                final servers = value.servers;
                if (servers.isEmpty) {
                  return SettingsCard(
                    children: [
                      Center(
                        child: RevericPlaceholder.empty(
                          icon: RevericIcons.link,
                          description: context.t(LocaleKeys.settingsMcpEmpty),
                        ),
                      ),
                    ],
                  );
                }
                return SettingsCard(
                  padding: EdgeInsets.zero,
                  children: [
                    for (final (index, server) in servers.indexed) ...[
                      if (index > 0) const SettingsRowDivider(),
                      McpServerRow(
                        key: ValueKey(server.name),
                        config: server,
                        onEdit: () => open(server),
                      ),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

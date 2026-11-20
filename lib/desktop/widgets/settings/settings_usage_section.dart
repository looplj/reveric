// 职责: 桌面端设置页用量统计入口 — 委托给共享 UsageSettingsSection，注入桌面端 UsagePage。
// 关联文件:
//   lib/desktop/widgets/settings/settings_dialog.dart
//   lib/shared/widgets/settings/usage_settings_section.dart
//   lib/desktop/pages/settings/usage_page.dart
part of 'settings_dialog.dart';

class _UsageSettingsSection extends StatelessWidget {
  const _UsageSettingsSection();

  @override
  Widget build(BuildContext context) {
    return UsageSettingsSection(bodyBuilder: () => const UsagePage());
  }
}

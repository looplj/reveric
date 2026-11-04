// 职责: 桌面端设置对话框 — 承载回收站设置区。
// 关联文件:
//   lib/desktop/widgets/settings/settings_dialog.dart
//   lib/shared/widgets/settings/trash_settings_section.dart
// 遵循的 Rules:
//   .agents/rules/directory-structure.md
part of 'settings_dialog.dart';

class _TrashSettingsSection extends StatelessWidget {
  const _TrashSettingsSection();

  @override
  Widget build(BuildContext context) => const TrashSettingsSection();
}

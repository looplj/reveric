// 职责: 桌面端设置对话框 — 组织设置导航与各设置分区入口（分区实现委托给共享 section widget）。
// 关联文件:
//   lib/shared/widgets/settings/general_settings_section.dart
//   lib/shared/widgets/settings/appearance_settings_section.dart
//   lib/shared/widgets/settings/editor_settings_section.dart
//   lib/shared/widgets/settings/reading_settings_section.dart
//   lib/shared/widgets/settings/usage_settings_section.dart
//   lib/shared/widgets/settings/about_settings_section.dart
//   lib/shared/widgets/settings/debug_settings_section.dart
//   lib/shared/providers/settings_providers.dart
//   lib/desktop/pages/settings/usage_page.dart
//   lib/desktop/widgets/settings/settings_storage_section.dart
//   lib/shared/widgets/settings/backup_settings_section.dart
//   lib/shared/widgets/settings/trash_settings_section.dart
//   lib/shared/widgets/settings/leave_guard.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/directory-structure.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/dialog_feedback.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/settings_providers.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/settings/about_settings_section.dart';
import '../../../shared/widgets/settings/appearance_settings_section.dart';
import '../../../shared/widgets/settings/debug_settings_section.dart';
import '../../../shared/widgets/settings/editor_settings_section.dart';
import '../../../shared/widgets/reading/reading_settings_controls.dart';
import '../../../shared/widgets/settings/reading_settings_section.dart';
import '../../../shared/widgets/settings/general_settings_section.dart';
import '../../../shared/widgets/settings/leave_guard.dart';
import '../../../shared/widgets/settings/backup_settings_section.dart';
import '../../../shared/widgets/settings/remote_bridge_settings_section.dart';
import '../../../shared/widgets/settings/trash_settings_section.dart';
import '../../../shared/widgets/settings/usage_settings_section.dart';
import '../../pages/settings/usage_page.dart';
import 'settings_storage_section.dart';

part 'settings_general_section.dart';
part 'settings_appearance_section.dart';
part 'settings_remote_section.dart';
part 'settings_usage_section.dart';
part 'settings_editor_section.dart';
part 'settings_reading_section.dart';
part 'settings_backup_section.dart';
part 'settings_trash_section.dart';
part 'settings_about_section.dart';
part 'settings_debug_section.dart';

/// 打开设置对话框并定位到「套餐」页 — 各功能门禁升级引导的统一跳转目标。

/// 设置对话框导航项
class _SettingsNavItem {
  final String id;
  final String labelKey;
  final String icon;

  const _SettingsNavItem({
    required this.id,
    required this.labelKey,
    required this.icon,
  });
}

/// 桌面端设置对话框
class SettingsDialog extends HookConsumerWidget {
  final String initialNavId;
  final String? initialUsageSessionId;

  const SettingsDialog({
    super.key,
    this.initialNavId = 'general',
    this.initialUsageSessionId,
  });

  static const _baseNavItems = [
    _SettingsNavItem(
      id: 'general',
      labelKey: LocaleKeys.settingsGeneral,
      icon: RevericIcons.settings_outlined,
    ),
    _SettingsNavItem(
      id: 'appearance',
      labelKey: LocaleKeys.settingsAppearance,
      icon: RevericIcons.palette_outlined,
    ),
    _SettingsNavItem(
      id: 'editor',
      labelKey: LocaleKeys.settingsFonts,
      icon: RevericIcons.text_fields_outlined,
    ),
    _SettingsNavItem(
      id: 'reading',
      labelKey: LocaleKeys.settingsReading,
      icon: RevericIcons.book_open,
    ),
    _SettingsNavItem(
      id: 'usage',
      labelKey: LocaleKeys.settingsUsage,
      icon: RevericIcons.bar_chart_outlined,
    ),
    _SettingsNavItem(
      id: 'remote',
      labelKey: LocaleKeys.settingsRemote,
      icon: RevericIcons.qr_code,
    ),
    _SettingsNavItem(
      id: 'storage',
      labelKey: LocaleKeys.settingsStorage,
      icon: RevericIcons.cloud,
    ),
    _SettingsNavItem(
      id: 'backup',
      labelKey: LocaleKeys.settingsBackup,
      icon: RevericIcons.archive_outlined,
    ),
    _SettingsNavItem(
      id: 'trash',
      labelKey: LocaleKeys.settingsTrash,
      icon: RevericIcons.delete_outline,
    ),
    _SettingsNavItem(
      id: 'about',
      labelKey: LocaleKeys.settingsAbout,
      icon: RevericIcons.help_outline,
    ),
  ];

  /// Agent 导航只接受正常展示的分区，排除调试入口。
  static Set<String> get navigableSections => {
    for (final item in _baseNavItems) item.id,
  };

  static const _debugNavItem = _SettingsNavItem(
    id: 'debug',
    labelKey: LocaleKeys.settingsDebug,
    icon: RevericIcons.bug_beetle_outlined,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final selectedNavId = useState(initialNavId);
    final aboutTapCount = useState(0);
    final debugMode = ref.watch(appDebugModeProvider);
    final debugPageUnlocked = ref.watch(appDebugPageUnlockedProvider);
    final debugUnlocked = useState(
      debugMode || debugPageUnlocked || initialNavId == 'debug',
    );
    final leave = useMemoized(SettingsLeaveController.new);
    final navItems = [
      ..._baseNavItems,
      if (debugUnlocked.value || debugMode) _debugNavItem,
    ];

    useEffect(() {
      if (debugMode) {
        debugUnlocked.value = true;
      }
      return null;
    }, [debugMode]);

    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RevericRadius.x2l),
      ),
      child: Container(
        width: 860,
        height: 620,
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(RevericRadius.x2l),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(RevericRadius.x2l),
          child: SettingsLeaveScope(
            controller: leave,
            child: DialogFeedback(
              builder: (context) => Row(
                children: [
                  _buildSidebar(
                    context,
                    colors,
                    navItems,
                    selectedNavId.value,
                    (id) async {
                      if (id != selectedNavId.value &&
                          !await leave.confirmLeave()) {
                        return;
                      }
                      if (!context.mounted) {
                        return;
                      }
                      if (id == 'about') {
                        aboutTapCount.value++;
                        if (aboutTapCount.value >= 10) {
                          debugUnlocked.value = true;
                          ref
                              .read(appSettingsProvider.notifier)
                              .setDebugPageUnlocked(true);
                          selectedNavId.value = 'debug';
                          return;
                        }
                      } else {
                        aboutTapCount.value = 0;
                      }
                      selectedNavId.value = id;
                    },
                  ),
                  Container(
                    width: RevericSizes.dividerThickness,
                    color: colors.border,
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        _buildHeader(context, colors, leave),
                        Expanded(
                          child: _buildContent(
                            context,
                            selectedNavId.value,
                            () {
                              debugUnlocked.value = false;
                              selectedNavId.value = 'general';
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    RevericColors colors,
    SettingsLeaveController leave,
  ) {
    final typo = RevericTheme.typographyOf(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.x4l,
        vertical: RevericSpacing.lg,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Text(
            context.t(LocaleKeys.settingsTitle),
            style: typo.heading2.copyWith(color: colors.textPrimary),
          ),
          const Spacer(),
          IconButton(
            onPressed: () async {
              if (await leave.confirmLeave() && context.mounted) {
                Navigator.of(context).pop();
              }
            },
            icon: RevericIcon(RevericIcons.close, color: colors.textSubtle),
            hoverColor: colors.hover,
          ),
        ],
      ),
    );
  }

  static const double _sidebarWidth = 160;

  Widget _buildSidebar(
    BuildContext context,
    RevericColors colors,
    List<_SettingsNavItem> navItems,
    String selectedId,
    ValueSetter<String> onSelect,
  ) {
    return Container(
      width: _sidebarWidth,
      color: colors.surfaceDim,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: RevericSpacing.x2l),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.sm,
                vertical: RevericSpacing.md,
              ),
              children: [
                for (final item in navItems)
                  _buildNavItem(
                    context: context,
                    item: item,
                    isSelected: selectedId == item.id,
                    onTap: () => onSelect(item.id),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem({
    required BuildContext context,
    required _SettingsNavItem item,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Material(
      color: isSelected ? colors.selected : Colors.transparent,
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: InkWell(
        onTap: onTap,
        hoverColor: colors.hover,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.lg,
            vertical: RevericSpacing.sm,
          ),
          child: Row(
            children: [
              RevericIcon(
                item.icon,
                size: 18,
                color: isSelected ? colors.textPrimary : colors.textSecondary,
              ),
              const SizedBox(width: RevericSpacing.sm),
              Expanded(
                child: Text(
                  context.t(item.labelKey),
                  style: (isSelected ? typo.uiSemibold : typo.ui).copyWith(
                    color: isSelected
                        ? colors.textPrimary
                        : colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    String selectedId,
    VoidCallback onCloseDebugSection,
  ) {
    return switch (selectedId) {
      'general' => const _GeneralSettingsSection(),
      'appearance' => const _AppearanceSettingsSection(),
      'remote' => _RemoteSettingsSection(),
      'usage' => _UsageSettingsSection(initialSessionId: initialUsageSessionId),
      'editor' => const _EditorSettingsSection(),
      'reading' => const _ReadingSettingsSection(),
      'storage' => const StorageSettingsSection(),
      'backup' => const _BackupSettingsSection(),
      'trash' => const _TrashSettingsSection(),
      'about' => const _AboutSettingsSection(),
      'debug' => _DebugSettingsSection(onClose: onCloseDebugSection),
      _ => const SizedBox.shrink(),
    };
  }
}

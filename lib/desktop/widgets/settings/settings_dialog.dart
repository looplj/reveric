// 职责: 桌面端设置页 — 组织设置导航与各设置分区入口（分区实现委托给共享 section widget），首页内嵌展示并提供独立弹窗入口。
// 关联文件:
//   lib/desktop/pages/home.dart
//   lib/desktop/widgets/agent_management/home_management_cards.dart
//   lib/desktop/widgets/agent_management/page_dialog.dart
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
import '../agent_management/home_management_cards.dart';
import '../agent_management/page_dialog.dart';
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

/// 首页之外的入口（关于菜单、更新提示、编辑器、Agent 跳转）只需某一分区，
/// 以独立弹窗单独展示该分区，不带设置导航。
Future<void> showSettingsSectionDialog(BuildContext context, String section) {
  final item = SettingsRegion._navItemOf(section);
  return showManagementPageDialog(
    context,
    builder: (headerKey, closeButton) => HomeManagementScaffold(
      headerGestureExclusionKey: headerKey,
      secondaryAction: closeButton,
      icon: item.icon,
      titleKey: item.labelKey,
      child: Builder(
        builder: (context) => SettingsRegion._sectionContent(
          section,
          onCloseDebugSection: () => Navigator.of(context).pop(),
        ),
      ),
    ),
  );
}

/// 设置导航项
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

/// 桌面端设置页：在首页主区域展示全部分区。
class DesktopSettingsPage extends StatelessWidget {
  const DesktopSettingsPage({
    super.key,
    required this.headerGestureExclusionKey,
    this.headerTrailingInset = 0,
    this.headerAction,
  });

  final GlobalKey headerGestureExclusionKey;
  final double headerTrailingInset;
  final Widget? headerAction;

  @override
  Widget build(BuildContext context) {
    return HomeManagementScaffold(
      headerGestureExclusionKey: headerGestureExclusionKey,
      headerTrailingInset: headerTrailingInset,
      secondaryAction: headerAction,
      icon: RevericIcons.settings_outlined,
      titleKey: LocaleKeys.librarySettings,
      child: const SettingsRegion(),
    );
  }
}

/// 设置分区导航与内容区；切换分区前询问外层 [SettingsLeaveScope] 中的编辑守卫。
class SettingsRegion extends HookConsumerWidget {
  const SettingsRegion({super.key});

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

  static _SettingsNavItem _navItemOf(String id) =>
      [..._baseNavItems, _debugNavItem].firstWhere((item) => item.id == id);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final selectedNavId = useState('general');
    final aboutTapCount = useState(0);
    final debugMode = ref.watch(appDebugModeProvider);
    final debugPageUnlocked = ref.watch(appDebugPageUnlockedProvider);
    final debugUnlocked = useState(debugMode || debugPageUnlocked);
    final leave = SettingsLeaveScope.maybeOf(context);
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

    // 拉伸到满高：内容区的滚动视图在宽松约束下会收缩并被垂直居中。
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSidebar(context, colors, navItems, selectedNavId.value, (
          id,
        ) async {
          if (id != selectedNavId.value &&
              leave != null &&
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
              ref.read(appSettingsProvider.notifier).setDebugPageUnlocked(true);
              selectedNavId.value = 'debug';
              return;
            }
          } else {
            aboutTapCount.value = 0;
          }
          selectedNavId.value = id;
        }),
        Container(width: RevericSizes.dividerThickness, color: colors.border),
        Expanded(
          child: _sectionContent(
            selectedNavId.value,
            onCloseDebugSection: () {
              debugUnlocked.value = false;
              selectedNavId.value = 'general';
            },
          ),
        ),
      ],
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

  static Widget _sectionContent(
    String selectedId, {
    required VoidCallback onCloseDebugSection,
  }) {
    return switch (selectedId) {
      'general' => const _GeneralSettingsSection(),
      'appearance' => const _AppearanceSettingsSection(),
      'remote' => _RemoteSettingsSection(),
      'usage' => const _UsageSettingsSection(),
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

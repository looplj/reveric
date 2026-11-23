// 职责: 移动端设置页面 — 顶部用户资料卡 + 分组列表（偏好/管理/数据/社区/系统，行右侧显示当前值），路由到共享 section；含 10 次点击关于解锁调试。
// 关联文件:
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/widgets/user_profile_edit_dialog.dart
//   lib/shared/widgets/community_links.dart
//   lib/shared/utils/storage_paths.dart
//   lib/shared/widgets/settings/general_settings_section.dart
//   lib/shared/widgets/settings/appearance_settings_section.dart
//   lib/shared/widgets/settings/editor_settings_section.dart
//   lib/shared/widgets/settings/reading_settings_section.dart
//   lib/shared/widgets/settings/ai_agents_settings_section.dart
//   lib/shared/widgets/settings/ai_providers_section.dart
//   lib/shared/widgets/settings/usage_settings_section.dart
//   lib/shared/widgets/settings/usage_view.dart
//   lib/shared/widgets/settings/backup_settings_section.dart
//   lib/shared/widgets/settings/trash_settings_section.dart
//   lib/shared/widgets/settings/about_settings_section.dart
//   lib/shared/widgets/settings/debug_settings_section.dart
//   lib/shared/app_config.dart
//   lib/shared/providers/settings_providers.dart
//   lib/mobile/widgets/detail_scaffold.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/zh-CN/provider.json
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md

import '../../shared/widgets/settings/mcp/section.dart';
import '../../shared/widgets/settings/plugins/section.dart';
import '../../shared/widgets/community_links.dart';
import '../../shared/widgets/user_avatar.dart';
import '../../shared/widgets/user_profile_edit_dialog.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/app_config.dart' show appVersion;
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/providers/update_providers.dart';
import '../../shared/theme/theme.dart';
import '../../shared/utils/storage_paths.dart';

import '../../shared/widgets/settings/about_settings_section.dart';
import '../../shared/widgets/settings/ai_agents_settings_section.dart';
import '../../shared/widgets/settings/ai_providers_section.dart';
import 'agent_model_settings_page.dart';
import '../../shared/widgets/settings/appearance_settings_section.dart';
import '../../shared/widgets/settings/debug_settings_section.dart';
import '../../shared/widgets/settings/editor_settings_section.dart';
import '../../shared/widgets/reading/reading_settings_controls.dart';
import '../../shared/widgets/settings/reading_settings_section.dart';
import '../../shared/widgets/settings/general_settings_section.dart';
import '../../shared/widgets/settings/backup_settings_section.dart';
import '../../shared/widgets/settings/trash_settings_section.dart';
import '../../shared/widgets/settings/usage_settings_section.dart';
import '../../shared/widgets/settings/usage_view.dart';
import '../../shared/components/reveric_dialog.dart';
import '../../shared/components/reveric_icon_button.dart';
import '../widgets/detail_scaffold.dart';

/// 从更新提醒直达现有关于详情页。
Future<void> showMobileAboutPage(BuildContext context) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => const _SettingsDetailPage(item: SettingsPage._aboutItem),
    ),
  );
}

/// 打开移动端已有设置分区；不增加隐藏的桌面入口或调试入口。
Future<void> showMobileSettingsPage(BuildContext context, String section) {
  final item = SettingsPage._navigableItems.firstWhere(
    (item) => item.id == section,
  );
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => _SettingsDetailPage(item: item)),
  );
}

/// 设置页面导航项
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

String _themeNameKey(AppTheme theme) {
  return switch (theme) {
    AppTheme.reveric => LocaleKeys.settingsThemeReveric,
    AppTheme.classic => LocaleKeys.settingsThemeClassic,
    AppTheme.ivory => LocaleKeys.settingsThemeIvory,
  };
}

String _themeModeKey(AppThemeMode mode) {
  return switch (mode) {
    AppThemeMode.light => LocaleKeys.settingsThemeModeLight,
    AppThemeMode.dark => LocaleKeys.settingsThemeModeDark,
    AppThemeMode.system => LocaleKeys.settingsThemeModeSystem,
  };
}

/// 移动端设置页面（底部 Tab 根页）：分组列表，点行进入对应子设置页。
class SettingsPage extends HookConsumerWidget {
  const SettingsPage({super.key});

  static const _generalItem = _SettingsNavItem(
    id: 'general',
    labelKey: LocaleKeys.settingsGeneral,
    icon: RevericIcons.settings_outlined,
  );
  static const _appearanceItem = _SettingsNavItem(
    id: 'appearance',
    labelKey: LocaleKeys.settingsAppearance,
    icon: RevericIcons.palette_outlined,
  );
  static const _editorItem = _SettingsNavItem(
    id: 'editor',
    labelKey: LocaleKeys.settingsFonts,
    icon: RevericIcons.text_fields_outlined,
  );
  static const _readingItem = _SettingsNavItem(
    id: 'reading',
    labelKey: LocaleKeys.settingsReading,
    icon: RevericIcons.book_open,
  );
  static const _providersItem = _SettingsNavItem(
    id: 'providers',
    labelKey: LocaleKeys.providerTitle,
    icon: RevericIcons.hub_outlined,
  );
  static const _aiAgentsItem = _SettingsNavItem(
    id: 'ai_agents',
    labelKey: LocaleKeys.settingsAiAgents,
    icon: RevericIcons.smart_toy_outlined,
  );
  static const _usageItem = _SettingsNavItem(
    id: 'usage',
    labelKey: LocaleKeys.settingsUsage,
    icon: RevericIcons.bar_chart_outlined,
  );
  static const _mcpItem = _SettingsNavItem(
    id: 'mcp',
    labelKey: LocaleKeys.settingsMcp,
    icon: RevericIcons.link,
  );
  static const _pluginsItem = _SettingsNavItem(
    id: 'plugins',
    labelKey: LocaleKeys.settingsPlugins,
    icon: RevericIcons.layers_outlined,
  );
  static const _backupItem = _SettingsNavItem(
    id: 'backup',
    labelKey: LocaleKeys.settingsBackup,
    icon: RevericIcons.archive_outlined,
  );
  static const _trashItem = _SettingsNavItem(
    id: 'trash',
    labelKey: LocaleKeys.settingsTrash,
    icon: RevericIcons.delete_outline,
  );
  static const _aboutItem = _SettingsNavItem(
    id: 'about',
    labelKey: LocaleKeys.settingsAbout,
    icon: RevericIcons.help_outline,
  );
  static const _navigableItems = [
    _generalItem,
    _appearanceItem,
    _editorItem,
    _readingItem,
    _providersItem,
    _aiAgentsItem,
    _usageItem,
    _mcpItem,
    _pluginsItem,
    _backupItem,
    _trashItem,
    _aboutItem,
  ];

  static Set<String> get navigableSections => {
    for (final item in _navigableItems) item.id,
  };

  static const _debugNavItem = _SettingsNavItem(
    id: 'debug',
    labelKey: LocaleKeys.settingsDebug,
    icon: RevericIcons.bug_beetle_outlined,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final debugMode = ref.watch(appDebugModeProvider);
    final debugPageUnlocked = ref.watch(appDebugPageUnlockedProvider);
    final settings = ref.watch(appSettingsProvider).asData?.value;

    final aboutTapCount = useState(0);
    final showDebugNav = debugMode || debugPageUnlocked;

    void unlockDebug() {
      ref.read(appSettingsProvider.notifier).setDebugPageUnlocked(true);
    }

    void openDetail(_SettingsNavItem item) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _SettingsDetailPage(
            item: item,
            aboutTapCount: item.id == 'about' ? aboutTapCount : null,
            debugNavItem: _debugNavItem,
            onDebugUnlocked: unlockDebug,
          ),
        ),
      );
    }

    void handleTap(_SettingsNavItem item) {
      if (item.id == 'about') {
        aboutTapCount.value++;
        if (aboutTapCount.value >= 10) {
          unlockDebug();
          aboutTapCount.value = 0;
          openDetail(_debugNavItem);
          return;
        }
        openDetail(item);
        return;
      }
      aboutTapCount.value = 0;
      openDetail(item);
    }

    // ── 行右侧当前值 ──────────────────────────────────────────────
    final isZh = context.locale.languageCode.toLowerCase().startsWith('zh');
    final languageValue = context.t(
      isZh ? LocaleKeys.settingsChineseSimplified : LocaleKeys.settingsEnglish,
    );
    final themeValue = settings == null
        ? null
        : '${context.t(_themeNameKey(settings.theme))} · '
              '${context.t(_themeModeKey(settings.themeMode))}';
    final editorValue = settings == null
        ? null
        : '${settings.editorFontFamily} · ${settings.editorFontSize}px';
    final readingValue = settings == null
        ? null
        : '${settings.readingFontFamily} · ${settings.readingFontSize}px';
    final hasUpdate = ref.watch(availableUpdateProvider) != null;
    final aboutValue = hasUpdate
        ? context.t(LocaleKeys.settingsAboutUpdateAvailable)
        : 'v$appVersion';

    Widget navRow(_SettingsNavItem item, {String? value}) {
      return MobileDetailNavRow(
        icon: item.icon,
        label: context.t(item.labelKey),
        value: value,
        onTap: () => handleTap(item),
      );
    }

    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.x4l,
            RevericSpacing.lg,
            RevericSpacing.x4l,
            RevericSpacing.x5l,
          ),
          children: [
            Text(
              context.t(LocaleKeys.settingsTitle),
              style: typo.display.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: RevericSpacing.x3l),
            _buildProfileCard(
              context,
              colors,
              typo,
              settings?.username ?? '',
              settings?.avatarPath ?? '',

              onTap: () => showRevericDialog<void>(
                context: context,
                builder: (_) => const UserProfileEditDialog(),
              ),
            ),
            const SizedBox(height: RevericSpacing.x2l),
            _buildGroup(context, LocaleKeys.settingsGroupPreferences, [
              navRow(_generalItem, value: languageValue),
              navRow(_appearanceItem, value: themeValue),
              navRow(_editorItem, value: editorValue),
              navRow(_readingItem, value: readingValue),
            ]),
            const SizedBox(height: RevericSpacing.x2l),
            _buildGroup(context, LocaleKeys.settingsGroupManagement, [
              navRow(_usageItem),
              navRow(_pluginsItem),
            ]),
            const SizedBox(height: RevericSpacing.x2l),
            _buildGroup(context, LocaleKeys.settingsGroupData, [
              navRow(_backupItem),
              navRow(_trashItem),
            ]),
            const SizedBox(height: RevericSpacing.x2l),
            _buildGroup(context, LocaleKeys.settingsGroupCommunity, [
              MobileDetailNavRow(
                icon: RevericIcons.qq_logo,
                label: context.t(LocaleKeys.settingsAboutJoinQqGroup),
                trailing: RevericIconButton(
                  icon: RevericIcons.copy,
                  tooltip: context.t(LocaleKeys.commonCopy),
                  onPressed: () => copyQqGroupNumber(context),
                ),
                onTap: () => openQqGroup(context),
              ),
              MobileDetailNavRow(
                icon: RevericIcons.github_logo,
                label: context.t(LocaleKeys.settingsAboutGithubRepository),
                onTap: () => openGitHubRepo(context),
              ),
            ]),
            const SizedBox(height: RevericSpacing.x2l),
            _buildGroup(context, LocaleKeys.settingsGroupSystem, [
              navRow(_aboutItem, value: aboutValue),
              if (showDebugNav) navRow(_debugNavItem),
            ]),
            const SizedBox(height: RevericSpacing.x3l),
            Center(
              child: Text(
                context.t(LocaleKeys.settingsTaglineFooter),
                textAlign: TextAlign.center,
                style: typo.bodyItalic.copyWith(color: colors.textSubtle),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部用户资料卡：头像 + 用户名 + 副标题，点击打开共享的资料编辑对话框。
  Widget _buildProfileCard(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo,
    String username,
    String avatarPath, {
    VoidCallback? onTap,
  }) {
    final displayName = username.isNotEmpty ? username : 'Reveric';
    final resolvedAvatar = RevericPaths.resolveStored(avatarPath);
    const avatarSize = 52.0;

    return Container(
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(RevericRadius.x2l),
        border: Border.all(color: colors.accent.withValues(alpha: 0.12)),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.xl,
            vertical: RevericSpacing.lg,
          ),
          child: Row(
            children: [
              UserAvatar(
                username: displayName,
                imagePath: resolvedAvatar,
                size: avatarSize,
              ),
              const SizedBox(width: RevericSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      style: typo.heading2.copyWith(color: colors.textPrimary),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: RevericSpacing.xxs),
                    Text(
                      context.t(LocaleKeys.settingsProfileSubtitle),
                      style: typo.uiSmall.copyWith(color: colors.textMuted),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              RevericIcon(
                RevericIcons.keyboard_arrow_right,
                size: 18,
                color: colors.textSubtle,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGroup(BuildContext context, String titleKey, List<Widget> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MobileDetailSectionLabel(text: context.t(titleKey)),
        MobileDetailFieldList(children: rows),
      ],
    );
  }
}

/// 设置子页（从分组列表下钻），承载对应 section。
class _SettingsDetailPage extends StatelessWidget {
  const _SettingsDetailPage({
    required this.item,
    this.aboutTapCount,
    this.debugNavItem,
    this.onDebugUnlocked,
  });

  final _SettingsNavItem item;
  final ValueNotifier<int>? aboutTapCount;
  final _SettingsNavItem? debugNavItem;
  final VoidCallback? onDebugUnlocked;

  void _handleAboutTap(BuildContext context) {
    final counter = aboutTapCount;
    if (counter == null) {
      return;
    }
    counter.value++;
    if (counter.value < 10) {
      return;
    }
    counter.value = 0;
    onDebugUnlocked?.call();
    final debugItem = debugNavItem;
    if (debugItem == null || !context.mounted) {
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => _SettingsDetailPage(item: debugItem),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final title = context.t(item.labelKey);

    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.surfaceDim,
        elevation: 0,
        leading: IconButton(
          icon: RevericIcon(RevericIcons.arrow_back, color: colors.textPrimary),
          // maybePop 才能让子树 PopScope先拦截返回。
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: item.id == 'about' && aboutTapCount != null
            ? GestureDetector(
                onTap: () => _handleAboutTap(context),
                behavior: HitTestBehavior.opaque,
                child: Text(
                  title,
                  style: typo.heading2.copyWith(color: colors.textPrimary),
                ),
              )
            : Text(
                title,
                style: typo.heading2.copyWith(color: colors.textPrimary),
              ),
      ),
      body: switch (item.id) {
        'general' => const GeneralSettingsSection(),
        'appearance' => const AppearanceSettingsSection(),
        'editor' => const EditorSettingsSection(),
        'reading' => const ReadingSettingsSection(
          platform: ReadingSettingsPlatform.mobile,
        ),
        'ai_agents' => const AiAgentsSettingsSection(showPermissions: false),
        'providers' => AiProvidersSection(
          onOpenModelSettings: () => openMobileAgentModelSettingsPage(context),
        ),
        'usage' => UsageSettingsSection(
          bodyBuilder: () => const UsageView(showHeader: false),
        ),
        'backup' => const BackupSettingsSection(compact: true),
        'trash' => const TrashSettingsSection(compact: true),
        'mcp' => const McpSettingsSection(),
        'plugins' => const PluginsSettingsSection(),
        'about' => const AboutSettingsSection(compact: true),
        'debug' => DebugSettingsSection(
          onClose: () => Navigator.of(context).pop(),
        ),
        _ => const SizedBox.shrink(),
      },
    );
  }
}

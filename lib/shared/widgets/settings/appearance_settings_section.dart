// 职责: 共享外观设置区 — 主题模式、主题选择、全局应用背景（颜色 / 内置图 / 自定义图）。
// 关联文件:
//   lib/shared/providers/settings_providers.dart
//   lib/shared/widgets/app_background.dart
//   lib/shared/localization/locale_keys.dart
//   lib/shared/theme/theme.dart
//   lib/shared/logger/app_logger.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../components/dialog_feedback.dart';
import '../../components/reveric_segmented_control.dart';
import '../../components/reveric_select.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../logger/app_logger.dart';
import '../../providers/settings_providers.dart';
import '../../theme/theme.dart';
import '../../widgets/app_background.dart';
import 'custom_themes_section.dart';

final _log = AppLogger.forModule('Settings');

const _appBackgroundThemes = [
  (AppTheme.reveric, LocaleKeys.settingsThemeReveric),
  (AppTheme.classic, LocaleKeys.settingsThemeClassic),
  (AppTheme.ivory, LocaleKeys.settingsThemeIvory),
];

const _appBackgroundImages = [
  (
    'assets/images/background/bg.webp',
    LocaleKeys.settingsAppBackgroundBuiltinPaper,
  ),
  (
    'assets/images/background/distant_mountains.webp',
    LocaleKeys.settingsAppBackgroundBuiltinDistantMountains,
  ),
  (
    'assets/images/background/starry_sky.webp',
    LocaleKeys.settingsAppBackgroundBuiltinStarrySky,
  ),
  (
    'assets/images/background/magnificent.webp',
    LocaleKeys.settingsAppBackgroundBuiltinMagnificent,
  ),
  (
    'assets/images/background/withered_tree.webp',
    LocaleKeys.settingsAppBackgroundBuiltinWitheredTree,
  ),
  (
    'assets/images/background/plum_blossom.webp',
    LocaleKeys.settingsAppBackgroundBuiltinPlumBlossom,
  ),
  (
    'assets/images/background/solitary_boat.webp',
    LocaleKeys.settingsAppBackgroundBuiltinSolitaryBoat,
  ),
];

/// 外观设置 section：主题模式 + 主题 + 应用背景。
class AppearanceSettingsSection extends HookConsumerWidget {
  const AppearanceSettingsSection({super.key});

  static const _themes = [
    (AppTheme.reveric, LocaleKeys.settingsThemeReveric),
    (AppTheme.classic, LocaleKeys.settingsThemeClassic),
    (AppTheme.ivory, LocaleKeys.settingsThemeIvory),
  ];

  static const _themeModes = [
    (AppThemeMode.light, LocaleKeys.settingsThemeModeLight),
    (AppThemeMode.dark, LocaleKeys.settingsThemeModeDark),
    (AppThemeMode.system, LocaleKeys.settingsThemeModeSystem),
  ];

  /// 界面文字缩放档位；值同时是持久化值，改动需同步分段控件展示。
  static const _uiTextScalePresets = <(double, String)>[
    (0.9, LocaleKeys.settingsUiTextScaleSmall),
    (1.0, LocaleKeys.settingsUiTextScaleStandard),
    (1.15, LocaleKeys.settingsUiTextScaleLarge),
    (1.3, LocaleKeys.settingsUiTextScaleExtraLarge),
  ];

  /// 手改数据库等途径可能产生档位外的值，回吸到最近档位保证控件选中态有效。
  static double _nearestUiTextScalePreset(double scale) {
    var nearest = _uiTextScalePresets.first.$1;
    for (final (value, _) in _uiTextScalePresets) {
      if ((scale - value).abs() < (scale - nearest).abs()) {
        nearest = value;
      }
    }
    return nearest;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentTheme = ref.watch(currentThemeTypeProvider);
    final customThemeActive = ref.watch(
      appSettingsProvider.select(
        (settings) => settings.asData?.value.customTheme != null,
      ),
    );
    final currentThemeMode = ref.watch(currentThemeModeProvider);
    final uiTextScale = ref.watch(uiTextScaleProvider);
    final backgroundImagePath = ref.watch(appBackgroundImagePathProvider);
    final backgroundFit = ref.watch(appBackgroundFitProvider);
    final backgroundTheme = ref.watch(appBackgroundThemeProvider);
    final settingsNotifier = ref.read(appSettingsProvider.notifier);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(RevericSpacing.x4l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader(
            context: context,
            titleKey: LocaleKeys.settingsThemeModeSection,
            descriptionKey: LocaleKeys.settingsThemeModeDescription,
          ),
          const SizedBox(height: RevericSpacing.xl),
          for (final (mode, labelKey) in _themeModes) ...[
            _buildThemeModeCard(
              context: context,
              mode: mode,
              labelKey: labelKey,
              isSelected: currentThemeMode == mode,
              onTap: () => settingsNotifier.setThemeMode(mode),
            ),
            const SizedBox(height: RevericSpacing.md),
          ],
          const SizedBox(height: RevericSpacing.xl),
          _buildSectionHeader(
            context: context,
            titleKey: LocaleKeys.settingsUiTextScaleSection,
            descriptionKey: LocaleKeys.settingsUiTextScaleDescription,
          ),
          const SizedBox(height: RevericSpacing.md),
          RevericSegmentedControl<double>(
            segments: [
              for (final (scale, labelKey) in _uiTextScalePresets)
                RevericSegment<double>(
                  value: scale,
                  label: context.t(labelKey),
                ),
            ],
            selected: _nearestUiTextScalePreset(uiTextScale),
            onChanged: (scale) => settingsNotifier.setUiTextScale(scale),
          ),
          const SizedBox(height: RevericSpacing.xl),
          const CustomThemesSection(),
          _buildSectionHeader(
            context: context,
            titleKey: LocaleKeys.settingsThemeSection,
            descriptionKey: LocaleKeys.settingsThemeDescription,
          ),
          const SizedBox(height: RevericSpacing.xl),
          for (final (theme, labelKey) in _themes) ...[
            _buildThemeCard(
              context: context,
              theme: theme,
              labelKey: labelKey,
              isSelected: !customThemeActive && currentTheme == theme,
              onTap: () => settingsNotifier.setTheme(theme),
            ),
            const SizedBox(height: RevericSpacing.md),
          ],
          if (defaultTargetPlatform != TargetPlatform.iOS &&
              defaultTargetPlatform != TargetPlatform.android) ...[
            const SizedBox(height: RevericSpacing.xl),
            _AppBackgroundSettings(
              imagePath: backgroundImagePath,
              fit: backgroundFit,
              theme: backgroundTheme,
              onImagePathChanged: settingsNotifier.setAppBackgroundImagePath,
              onFitChanged: settingsNotifier.setAppBackgroundFit,
              onThemeChanged: settingsNotifier.setAppBackgroundTheme,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader({
    required BuildContext context,
    required String titleKey,
    required String descriptionKey,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t(titleKey),
          style: typo.uiSemibold.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: RevericSpacing.xs),
        Text(
          context.t(descriptionKey),
          style: typo.ui.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }

  Widget _buildThemeModeCard({
    required BuildContext context,
    required AppThemeMode mode,
    required String labelKey,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final icon = switch (mode) {
      AppThemeMode.light => RevericIcons.light_mode_outlined,
      AppThemeMode.dark => RevericIcons.dark_mode_outlined,
      AppThemeMode.system => RevericIcons.brightness_auto_outlined,
    };
    return Material(
      color: isSelected ? colors.selected : colors.canvas,
      borderRadius: BorderRadius.circular(RevericRadius.large),
      child: InkWell(
        onTap: onTap,
        hoverColor: colors.hover,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(RevericSpacing.lg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(RevericRadius.large),
            border: Border.all(
              color: isSelected ? colors.accent : colors.borderInput,
            ),
          ),
          child: Row(
            children: [
              RevericIcon(
                icon,
                size: 24,
                color: isSelected ? colors.accent : colors.textSecondary,
              ),
              const SizedBox(width: RevericSpacing.lg),
              Expanded(
                child: Text(
                  context.t(labelKey),
                  style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                ),
              ),
              if (isSelected)
                RevericIcon(
                  RevericIcons.check_circle,
                  color: colors.accent,
                  size: 20,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThemeCard({
    required BuildContext context,
    required AppTheme theme,
    required String labelKey,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Material(
      color: isSelected ? colors.selected : colors.canvas,
      borderRadius: BorderRadius.circular(RevericRadius.large),
      child: InkWell(
        onTap: onTap,
        hoverColor: colors.hover,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(RevericSpacing.lg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(RevericRadius.large),
            border: Border.all(
              color: isSelected ? colors.accent : colors.borderInput,
            ),
          ),
          child: Row(
            children: [
              _buildThemePreview(theme, colors),
              const SizedBox(width: RevericSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.t(labelKey),
                      style: typo.uiSemibold.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: RevericSpacing.xxs),
                    Text(
                      _getThemeDescription(context, theme),
                      style: typo.uiSmall.copyWith(color: colors.textMuted),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                RevericIcon(
                  RevericIcons.check_circle,
                  color: colors.accent,
                  size: 20,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThemePreview(AppTheme theme, RevericColors colors) {
    final previewColors = switch (theme) {
      AppTheme.reveric => (
        canvas: const Color(0xFFFEFCF9),
        surface: const Color(0xFFFBFAF7),
        accent: const Color(0xFF283C5F),
        text: const Color(0xFF1F2A3D),
      ),
      AppTheme.classic => (
        canvas: const Color(0xFFFFFFFF),
        surface: const Color(0xFFFAFAFA),
        accent: const Color(0xFF000000),
        text: const Color(0xFF000000),
      ),
      AppTheme.ivory => (
        canvas: const Color(0xFFF5F5F0),
        surface: const Color(0xFFFAFAF9),
        accent: const Color(0xFFA2AF9B),
        text: const Color(0xFF333333),
      ),
    };
    return Container(
      width: 64,
      height: 48,
      decoration: BoxDecoration(
        color: previewColors.canvas,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Column(
        children: [
          Container(height: 16, color: previewColors.accent),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: previewColors.surface,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: previewColors.text.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _getThemeDescription(BuildContext context, AppTheme theme) {
    return switch (theme) {
      AppTheme.reveric => context.t(LocaleKeys.settingsThemeRevericDescription),
      AppTheme.classic => context.t(LocaleKeys.settingsThemeClassicDescription),
      AppTheme.ivory => context.t(LocaleKeys.settingsThemeIvoryDescription),
    };
  }
}

class _AppBackgroundSettings extends StatelessWidget {
  const _AppBackgroundSettings({
    required this.imagePath,
    required this.fit,
    required this.theme,
    required this.onImagePathChanged,
    required this.onFitChanged,
    required this.onThemeChanged,
  });

  final String imagePath;
  final AppBackgroundFit fit;
  final AppTheme? theme;
  final ValueChanged<String> onImagePathChanged;
  final ValueChanged<AppBackgroundFit> onFitChanged;
  final ValueChanged<AppTheme?> onThemeChanged;

  Future<void> _pickImage(BuildContext context) async {
    final result = await openFile(
      acceptedTypeGroups: [
        // iOS 要求 type group 提供 UTI，否则 file_selector 抛 Invalid argument。
        const XTypeGroup(
          label: 'images',
          extensions: ['png', 'jpg', 'jpeg', 'webp'],
          uniformTypeIdentifiers: ['public.image'],
        ),
      ],
    );
    final sourcePath = result?.path;
    if (sourcePath == null) {
      return;
    }

    try {
      final source = File(sourcePath);
      final appDir = await getApplicationSupportDirectory();
      final backgroundDir = Directory(p.join(appDir.path, 'app_backgrounds'));
      if (!await backgroundDir.exists()) {
        await backgroundDir.create(recursive: true);
      }
      final ext = p.extension(source.path);
      final dest = File(
        p.join(
          backgroundDir.path,
          'app_background_${DateTime.now().millisecondsSinceEpoch}$ext',
        ),
      );
      await source.copy(dest.path);
      onImagePathChanged(dest.path);
    } catch (error, stackTrace) {
      _log.error(
        'Failed to pick app background: $error',
        error: error,
        stackTrace: stackTrace,
      );
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: DialogToast(
            variant: DialogToastVariant.error,
            child: Text(context.t(LocaleKeys.settingsAppBackgroundFailed)),
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final file = File(imagePath);
    final hasAssetImage = theme == null && isAppBackgroundAsset(imagePath);
    final hasCustomImage =
        theme == null && imagePath.isNotEmpty && file.existsSync();
    final hasImage = hasAssetImage || hasCustomImage;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          context: context,
          titleKey: LocaleKeys.settingsAppBackground,
          descriptionKey: LocaleKeys.settingsAppBackgroundDescription,
        ),
        const SizedBox(height: RevericSpacing.lg),
        Container(
          decoration: BoxDecoration(
            color: colors.canvas,
            borderRadius: BorderRadius.circular(RevericRadius.large),
            border: Border.all(color: colors.borderInput),
          ),
          padding: const EdgeInsets.all(RevericSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.t(LocaleKeys.settingsAppBackgroundColor),
                style: typo.uiSmallSemibold.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: RevericSpacing.sm),
              Wrap(
                spacing: RevericSpacing.sm,
                runSpacing: RevericSpacing.sm,
                children: [
                  _AppBackgroundThemeChip(
                    label: context.t(LocaleKeys.settingsAppBackgroundNone),
                    color: colors.surfaceDim,
                    selected: theme == null && imagePath.isEmpty,
                    onTap: () => onThemeChanged(null),
                  ),
                  for (final (optionTheme, labelKey) in _appBackgroundThemes)
                    _AppBackgroundThemeChip(
                      label: context.t(labelKey),
                      color: appBackgroundColorForTheme(
                        optionTheme,
                        brightness: colors.brightness,
                      ),
                      selected: theme == optionTheme,
                      onTap: () => onThemeChanged(optionTheme),
                    ),
                ],
              ),
              const SizedBox(height: RevericSpacing.lg),
              Container(
                height: RevericSizes.dividerThickness,
                color: colors.borderSubtle,
              ),
              const SizedBox(height: RevericSpacing.lg),
              Text(
                context.t(LocaleKeys.settingsAppBackgroundImage),
                style: typo.uiSmallSemibold.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: RevericSpacing.sm),
              RevericSelect<AppBackgroundFit>(
                label: context.t(LocaleKeys.settingsAppBackgroundFit),
                value: fit,
                items: [
                  RevericSelectItem(
                    value: AppBackgroundFit.cover,
                    label: context.t(LocaleKeys.settingsAppBackgroundFitCover),
                  ),
                  RevericSelectItem(
                    value: AppBackgroundFit.contain,
                    label: context.t(
                      LocaleKeys.settingsAppBackgroundFitContain,
                    ),
                  ),
                  RevericSelectItem(
                    value: AppBackgroundFit.fill,
                    label: context.t(LocaleKeys.settingsAppBackgroundFitFill),
                  ),
                ],
                onChanged: onFitChanged,
              ),
              const SizedBox(height: RevericSpacing.lg),
              Text(
                context.t(LocaleKeys.settingsAppBackgroundBuiltin),
                style: typo.uiSmall.copyWith(color: colors.textMuted),
              ),
              const SizedBox(height: RevericSpacing.sm),
              Wrap(
                spacing: RevericSpacing.md,
                runSpacing: RevericSpacing.md,
                children: [
                  for (final (assetPath, labelKey) in _appBackgroundImages)
                    _AppBackgroundImageTile(
                      label: context.t(labelKey),
                      imageProvider: AssetImage(assetPath),
                      selected: theme == null && imagePath == assetPath,
                      onTap: () => onImagePathChanged(assetPath),
                    ),
                ],
              ),
              const SizedBox(height: RevericSpacing.lg),
              Text(
                context.t(LocaleKeys.settingsAppBackgroundCustom),
                style: typo.uiSmall.copyWith(color: colors.textMuted),
              ),
              const SizedBox(height: RevericSpacing.sm),
              Row(
                children: [
                  Container(
                    width: 104,
                    height: 68,
                    decoration: BoxDecoration(
                      color: colors.surfaceDim,
                      borderRadius: BorderRadius.circular(RevericRadius.medium),
                      border: Border.all(color: colors.borderSubtle),
                      image: hasImage
                          ? DecorationImage(
                              image: imageProviderForAppBackground(imagePath),
                              fit: boxFitForAppBackground(fit),
                            )
                          : null,
                    ),
                    child: hasImage
                        ? null
                        : Center(
                            child: RevericIcon(
                              RevericIcons.image_outlined,
                              size: 22,
                              color: colors.textSubtle,
                            ),
                          ),
                  ),
                  const SizedBox(width: RevericSpacing.lg),
                  Expanded(
                    child: Text(
                      theme != null
                          ? context.t(
                              LocaleKeys.settingsAppBackgroundImageInactive,
                            )
                          : hasAssetImage
                          ? context.t(
                              LocaleKeys.settingsAppBackgroundBuiltinActive,
                            )
                          : hasImage
                          ? context.t(
                              LocaleKeys.settingsAppBackgroundCustomActive,
                            )
                          : context.t(LocaleKeys.settingsAppBackgroundEmpty),
                      overflow: TextOverflow.ellipsis,
                      style: typo.ui.copyWith(color: colors.textMuted),
                    ),
                  ),
                  const SizedBox(width: RevericSpacing.lg),
                  OutlinedButton(
                    onPressed: () => _pickImage(context),
                    child: Text(
                      context.t(LocaleKeys.settingsAppBackgroundSelect),
                    ),
                  ),
                  if (imagePath.isNotEmpty) ...[
                    const SizedBox(width: RevericSpacing.sm),
                    TextButton(
                      onPressed: () => onImagePathChanged(''),
                      child: Text(
                        context.t(LocaleKeys.settingsAppBackgroundRemove),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader({
    required BuildContext context,
    required String titleKey,
    required String descriptionKey,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t(titleKey),
          style: typo.uiSemibold.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: RevericSpacing.xs),
        Text(
          context.t(descriptionKey),
          style: typo.ui.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}

class _AppBackgroundThemeChip extends StatelessWidget {
  const _AppBackgroundThemeChip({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Material(
      color: selected ? colors.selected : colors.surface,
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        hoverColor: colors.hover,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(RevericRadius.medium),
            border: Border.all(
              color: selected ? colors.accent : colors.borderSubtle,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(RevericRadius.small),
                  border: Border.all(color: colors.borderSubtle),
                ),
              ),
              const SizedBox(width: RevericSpacing.sm),
              Text(
                label,
                style: typo.uiSmall.copyWith(
                  color: selected ? colors.accent : colors.textSecondary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppBackgroundImageTile extends StatelessWidget {
  const _AppBackgroundImageTile({
    required this.label,
    required this.imageProvider,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final ImageProvider imageProvider;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Material(
      color: selected ? colors.selected : colors.surface,
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        hoverColor: colors.hover,
        child: Container(
          width: 112,
          padding: const EdgeInsets.all(RevericSpacing.xs),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(RevericRadius.medium),
            border: Border.all(
              color: selected ? colors.accent : colors.borderSubtle,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(RevericRadius.small),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image(
                    image: imageProvider,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => ColoredBox(
                      color: colors.surfaceDim,
                      child: Center(
                        child: RevericIcon(
                          RevericIcons.image_outlined,
                          size: 18,
                          color: colors.textSubtle,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: RevericSpacing.xs),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: typo.uiSmall.copyWith(
                  color: selected ? colors.accent : colors.textSecondary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

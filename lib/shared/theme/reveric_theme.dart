// 职责: 将 Reveric 颜色、排版和间距 token 组合成 Flutter ThemeData 与可继承主题上下文。
// 关联文件:
//   lib/shared/theme/reveric_colors.dart
//   lib/shared/theme/reveric_typography.dart
//   lib/shared/theme/reveric_spacing.dart
//   designs/SYSTEM.md
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'reveric_colors.dart';
import 'reveric_typography.dart';
import 'reveric_spacing.dart';

class RevericThemeData {
  final Brightness brightness;
  final RevericColors colors;
  final RevericTypography typography;

  const RevericThemeData({
    required this.brightness,
    required this.colors,
    required this.typography,
  });

  /// Reveric — 玉白 · 墨玉.
  static const reveric = RevericThemeData(
    brightness: Brightness.light,
    colors: RevericColors.reveric,
    typography: RevericTypography.desktop,
  );

  static const revericDark = RevericThemeData(
    brightness: Brightness.dark,
    colors: RevericColors.revericDark,
    typography: RevericTypography.desktop,
  );

  static const classic = RevericThemeData(
    brightness: Brightness.light,
    colors: RevericColors.classic,
    typography: RevericTypography.desktop,
  );

  static const classicDark = RevericThemeData(
    brightness: Brightness.dark,
    colors: RevericColors.classicDark,
    typography: RevericTypography.desktop,
  );

  static const ivory = RevericThemeData(
    brightness: Brightness.light,
    colors: RevericColors.ivory,
    typography: RevericTypography.desktop,
  );

  static const ivoryDark = RevericThemeData(
    brightness: Brightness.dark,
    colors: RevericColors.ivoryDark,
    typography: RevericTypography.desktop,
  );

  RevericThemeData copyWith({RevericTypography? typography}) {
    return RevericThemeData(
      brightness: brightness,
      colors: colors,
      typography: typography ?? this.typography,
    );
  }

  /// System UI overlay for mobile status/navigation bars — matches canvas/surface.
  SystemUiOverlayStyle get systemUiOverlayStyle {
    final isDark = brightness == Brightness.dark;
    final iconBrightness = isDark ? Brightness.light : Brightness.dark;
    final transparentStatusBar =
        defaultTargetPlatform == TargetPlatform.android;
    return SystemUiOverlayStyle(
      statusBarColor: transparentStatusBar ? Colors.transparent : colors.canvas,
      statusBarIconBrightness: iconBrightness,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: transparentStatusBar
          ? Colors.transparent
          : colors.surface,
      systemNavigationBarIconBrightness: iconBrightness,
      systemNavigationBarContrastEnforced: false,
    );
  }

  /// Build a Flutter [ThemeData] from this design system theme.
  ThemeData toThemeData({String? fontFamily}) {
    final isDark = brightness == Brightness.dark;
    final overlayStyle = systemUiOverlayStyle;
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: colors.canvas,
      appBarTheme: AppBarTheme(
        backgroundColor: colors.canvas,
        foregroundColor: colors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: overlayStyle,
      ),
      fontFamily: fontFamily,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: colors.accent,
        secondary: colors.accentAmber,
        surface: colors.surface,
        surfaceDim: colors.surfaceDim,
        surfaceContainerLowest: colors.canvas,
        surfaceContainerLow: colors.surface,
        surfaceContainer: colors.surfaceContainer,
        surfaceContainerHigh: colors.surfaceContainerHigh,
        surfaceContainerHighest: colors.surfaceContainerHigh,
        error: colors.deletionBorder,
        onPrimary: isDark ? colors.canvas : Colors.white,
        onSecondary: isDark ? colors.canvas : Colors.white,
        onSurface: colors.textPrimary,
        onSurfaceVariant: colors.textSecondary,
        onError: isDark ? colors.canvas : Colors.white,
        outline: colors.border,
        outlineVariant: colors.borderSubtle,
      ),
      dividerColor: colors.border,
      dividerTheme: DividerThemeData(
        color: colors.border,
        thickness: RevericSizes.dividerThickness,
        space: RevericSizes.dividerThickness,
      ),
      textTheme: TextTheme(
        displayLarge: typography.display.copyWith(color: colors.textPrimary),
        headlineMedium: typography.heading2.copyWith(color: colors.textPrimary),
        // 输入框、ListTile 等 Material 组件默认取 bodyLarge，属于界面元素，
        // 沿用正文尺寸但不继承正文衬线字体；正文排版直接使用 typography.body。
        bodyLarge: TextStyle(
          fontSize: typography.body.fontSize,
          fontWeight: typography.body.fontWeight,
          height: typography.body.height,
          color: colors.textPrimary,
        ),
        bodyMedium: typography.ui.copyWith(color: colors.textSecondary),
        bodySmall: typography.uiSmall.copyWith(color: colors.textMuted),
        labelLarge: typography.uiSemibold.copyWith(color: colors.textSecondary),
        labelMedium: typography.uiSmall.copyWith(color: colors.textSubtle),
        labelSmall: typography.uiTiny.copyWith(color: colors.textSubtle),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colors.accent,
          foregroundColor: colors.onAccent,
          disabledBackgroundColor: colors.accent.withValues(alpha: 0.4),
          disabledForegroundColor: colors.onAccent.withValues(alpha: 0.7),
          minimumSize: const Size(0, RevericSizes.buttonHeight),
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSizes.buttonPaddingH,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(RevericRadius.button),
          ),
          textStyle: typography.uiSemibold,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: colors.accent,
          foregroundColor: colors.onAccent,
          disabledBackgroundColor: colors.accent.withValues(alpha: 0.4),
          disabledForegroundColor: colors.onAccent.withValues(alpha: 0.7),
          elevation: 0,
          minimumSize: const Size(0, RevericSizes.buttonHeight),
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSizes.buttonPaddingH,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(RevericRadius.button),
          ),
          textStyle: typography.uiSemibold,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.textSecondary,
          side: BorderSide(color: colors.borderInput),
          minimumSize: const Size(0, RevericSizes.buttonHeight),
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSizes.buttonPaddingH,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(RevericRadius.button),
          ),
          textStyle: typography.uiSemibold,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colors.textSecondary,
          minimumSize: const Size(0, RevericSizes.buttonHeight),
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSizes.buttonPaddingHSm,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(RevericRadius.button),
          ),
          textStyle: typography.uiSemibold,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: colors.textSecondary,
          disabledForegroundColor: colors.textSubtle,
          minimumSize: const Size(
            RevericSizes.iconButtonSize,
            RevericSizes.iconButtonSize,
          ),
          padding: const EdgeInsets.all(RevericSizes.iconButtonPadding),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(RevericRadius.iconButton),
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colors.onAccent;
          }
          return colors.textSecondary;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colors.accent;
          }
          return colors.borderSubtle;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          return Colors.transparent;
        }),
        splashRadius: 0,
      ),
      // 选中段使用主题 accent，避免默认走 colorScheme.secondary（accentAmber）导致与主题不符。
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return colors.accent;
            }
            return Colors.transparent;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return colors.onAccent;
            }
            return colors.textSecondary;
          }),
          side: WidgetStateProperty.all(BorderSide(color: colors.borderInput)),
          textStyle: WidgetStateProperty.all(typography.uiSemibold),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        hintStyle: typography.ui.copyWith(
          color: colors.textSecondary.withValues(alpha: 0.35),
        ),
      ),
    );
  }
}

class RevericTheme extends InheritedWidget {
  final RevericThemeData data;

  const RevericTheme({super.key, required this.data, required super.child});

  static RevericThemeData of(BuildContext context) {
    final widget = context.dependOnInheritedWidgetOfExactType<RevericTheme>();
    assert(widget != null, 'No RevericTheme found in context');
    return widget!.data;
  }

  /// Convenience accessor for colors.
  static RevericColors colorsOf(BuildContext context) => of(context).colors;

  /// Convenience accessor for typography.
  static RevericTypography typographyOf(BuildContext context) =>
      of(context).typography;

  @override
  bool updateShouldNotify(RevericTheme oldWidget) => data != oldWidget.data;
}

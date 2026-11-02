import 'package:flutter/material.dart';

class RevericColors {
  final Brightness brightness;

  // Surfaces
  final Color canvas;
  final Color surface;
  final Color surfaceDim;
  final Color surfaceContainer;
  final Color surfaceContainerHigh;

  // Borders
  final Color border;
  final Color borderSubtle;
  final Color borderInput;

  // Text
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color textSubtle;

  // Accent
  final Color accent;
  final Color accentWarm;
  final Color accentAmber;

  // States
  final Color selected;
  final Color hover;

  // Semantic
  final Color deletionBg;
  final Color deletionBorder;
  final Color additionBg;
  final Color additionBorder;
  final Color warningBg;
  final Color warningText;
  final Color success;
  final Color error;

  // Blockquote
  final Color blockquoteBorder;

  // Accent contrast (text/icon on accent background)
  final Color onAccent;

  // Text
  final Color textTertiary;

  const RevericColors({
    required this.brightness,
    required this.canvas,
    required this.surface,
    required this.surfaceDim,
    required this.surfaceContainer,
    required this.surfaceContainerHigh,
    required this.border,
    required this.borderSubtle,
    required this.borderInput,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.textSubtle,
    required this.accent,
    required this.accentWarm,
    required this.accentAmber,
    required this.selected,
    required this.hover,
    required this.deletionBg,
    required this.deletionBorder,
    required this.additionBg,
    required this.additionBorder,
    required this.warningBg,
    required this.warningText,
    required this.success,
    required this.error,
    required this.blockquoteBorder,
    required this.onAccent,
    required this.textTertiary,
  });

  bool get isDark => brightness == Brightness.dark;

  /// 默认用户头像的底色候选：青、黛、赭、藕、苍。按昵称哈希取一个，
  /// 使用时与 [surface] / [textPrimary] 混合，因此所有主题和深浅模式共用一组。
  /// Reveric 主色几乎都是墨绿，只用语义色会让不同昵称的头像难以区分。
  static const avatarTones = [
    Color(0xFF4F8C7C),
    Color(0xFF56688C),
    Color(0xFFA7714F),
    Color(0xFF93708A),
    Color(0xFF76875A),
  ];

  /// Reveric — 玉白 · 墨玉：薄荷冷白底托起纯白卡片，近黑墨玉担主操作，
  /// 翡翠（accentAmber）只做 AI、状态与小面积点缀，不做正文色。
  /// The default theme for creative writing.
  static const reveric = RevericColors(
    brightness: Brightness.light,
    canvas: Color(0xFFF2F6F4),
    surface: Color(0xFFFFFFFF),
    surfaceDim: Color(0xFFEAF0ED),
    surfaceContainer: Color(0xFFF6F9F7),
    surfaceContainerHigh: Color(0xFFFFFFFF),
    border: Color(0xFFE0E8E4),
    borderSubtle: Color(0xFFEAF0ED),
    borderInput: Color(0xFFD8E1DD),
    textPrimary: Color(0xFF141A18),
    textSecondary: Color(0xFF3D4643),
    textMuted: Color(0xFF646E6A),
    textSubtle: Color(0xFFA2ACA8),
    accent: Color(0xFF1C2623),
    accentWarm: Color(0xFF2D3A36),
    accentAmber: Color(0xFF2A9C78),
    selected: Color(0xFFE1F1EA),
    hover: Color(0xFFEDF3F0),
    deletionBg: Color(0xFFFCE9E7),
    deletionBorder: Color(0xFFC2392B),
    additionBg: Color(0xFFE1F2E9),
    additionBorder: Color(0xFF1F8A68),
    warningBg: Color(0xFFFCF1DC),
    warningText: Color(0xFFB4690E),
    blockquoteBorder: Color(0xFF8ED0B8),
    textTertiary: Color(0xFF646E6A),
    success: Color(0xFF1F8A68),
    error: Color(0xFFC2392B),
    onAccent: Color(0xFFFFFFFF),
  );

  /// 深色下主操作反转为玉白，翡翠提亮。
  static const revericDark = RevericColors(
    brightness: Brightness.dark,
    canvas: Color(0xFF0F1412),
    surface: Color(0xFF161C1A),
    surfaceDim: Color(0xFF1A211E),
    surfaceContainer: Color(0xFF1D2422),
    surfaceContainerHigh: Color(0xFF232B28),
    border: Color(0xFF2A3330),
    borderSubtle: Color(0xFF212926),
    borderInput: Color(0xFF333D39),
    textPrimary: Color(0xFFE8EEEB),
    textSecondary: Color(0xFFBEC8C4),
    textMuted: Color(0xFF85918C),
    textSubtle: Color(0xFF5A6561),
    accent: Color(0xFFE4ECE8),
    accentWarm: Color(0xFFC9D5D0),
    accentAmber: Color(0xFF4CC49C),
    selected: Color(0xFF1B302A),
    hover: Color(0xFF1F2724),
    deletionBg: Color(0xFF3A2120),
    deletionBorder: Color(0xFFE04A3F),
    additionBg: Color(0xFF173126),
    additionBorder: Color(0xFF4CC49C),
    warningBg: Color(0xFF3A2F1C),
    warningText: Color(0xFFE8A657),
    blockquoteBorder: Color(0xFF2F7D63),
    textTertiary: Color(0xFF85918C),
    success: Color(0xFF4CC49C),
    error: Color(0xFFEB6B5E),
    onAccent: Color(0xFF0F1412),
  );

  /// Classic black & white theme — minimal, timeless, high contrast.
  static const classic = RevericColors(
    brightness: Brightness.light,
    canvas: Color(0xFFFFFFFF),
    surface: Color(0xFFFAFAFA),
    surfaceDim: Color(0xFFF0F0F0),
    surfaceContainer: Color(0xFFF5F5F5),
    surfaceContainerHigh: Color(0xFFFFFFFF),
    border: Color(0xFFE0E0E0),
    borderSubtle: Color(0xFFEEEEEE),
    borderInput: Color(0xFFD0D0D0),
    textPrimary: Color(0xFF000000),
    textSecondary: Color(0xFF333333),
    textMuted: Color(0xFF666666),
    textSubtle: Color(0xFF999999),
    accent: Color(0xFF000000),
    accentWarm: Color(0xFF333333),
    accentAmber: Color(0xFF666666),
    selected: Color(0xFFE8E8E8),
    hover: Color(0xFFF2F2F2),
    deletionBg: Color(0xFFFEE2E2),
    deletionBorder: Color(0xFFDC2626),
    additionBg: Color(0xFFD1FAE5),
    additionBorder: Color(0xFF059669),
    warningBg: Color(0xFFFEF9C3),
    warningText: Color(0xFFA16207),
    blockquoteBorder: Color(0xFFCCCCCC),
    textTertiary: Color(0xFF666666),
    success: Color(0xFF059669),
    error: Color(0xFFDC2626),
    onAccent: Color(0xFFFFFFFF),
  );

  static const classicDark = RevericColors(
    brightness: Brightness.dark,
    canvas: Color(0xFF000000),
    surface: Color(0xFF0A0A0A),
    surfaceDim: Color(0xFF141414),
    surfaceContainer: Color(0xFF1A1A1A),
    surfaceContainerHigh: Color(0xFF242424),
    border: Color(0xFF2A2A2A),
    borderSubtle: Color(0xFF1F1F1F),
    borderInput: Color(0xFF333333),
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0xFFCCCCCC),
    textMuted: Color(0xFF888888),
    textSubtle: Color(0xFF666666),
    accent: Color(0xFFFFFFFF),
    accentWarm: Color(0xFFCCCCCC),
    accentAmber: Color(0xFF888888),
    selected: Color(0xFF2A2A2A),
    hover: Color(0xFF333333),
    deletionBg: Color(0xFF2A1414),
    deletionBorder: Color(0xFFEF4444),
    additionBg: Color(0xFF142A1C),
    additionBorder: Color(0xFF10B981),
    warningBg: Color(0xFF2A2614),
    warningText: Color(0xFFFBBF24),
    blockquoteBorder: Color(0xFF444444),
    textTertiary: Color(0xFF888888),
    success: Color(0xFF10B981),
    error: Color(0xFFEF4444),
    onAccent: Color(0xFF000000),
  );

  /// Ivory — warm and gentle, like aged paper and cream.
  static const ivory = RevericColors(
    brightness: Brightness.light,
    canvas: Color(0xFFF8F8F0),
    surface: Color(0xFFFAFAF3),
    surfaceDim: Color(0xFFEBECDC),
    surfaceContainer: Color(0xFFF1F2E5),
    surfaceContainerHigh: Color(0xFFF5F6EC),
    border: Color(0xFFDADBC4),
    borderSubtle: Color(0xFFECEDDC),
    borderInput: Color(0xFFDEDFCA),
    textPrimary: Color(0xFF2E3026),
    textSecondary: Color(0xFF555848),
    textMuted: Color(0xFF767866),
    textSubtle: Color(0xFF92957F),
    accent: Color(0xFFA2AF9B),
    accentWarm: Color(0xFF8B9A8A),
    accentAmber: Color(0xFFC4956A),
    selected: Color(0xFFE2E3CD),
    hover: Color(0xFFEBECDC),
    deletionBg: Color(0xFFFDE8E8),
    deletionBorder: Color(0xFFC53030),
    additionBg: Color(0xFFE8FDE8),
    additionBorder: Color(0xFF2F855A),
    warningBg: Color(0xFFFEF3C7),
    warningText: Color(0xFFD97706),
    blockquoteBorder: Color(0xFFD4A574),
    textTertiary: Color(0xFF767866),
    success: Color(0xFF2F855A),
    error: Color(0xFFC53030),
    onAccent: Color(0xFF2E3026),
  );

  static const ivoryDark = RevericColors(
    brightness: Brightness.dark,
    canvas: Color(0xFF141410),
    surface: Color(0xFF1C1C16),
    surfaceDim: Color(0xFF252520),
    surfaceContainer: Color(0xFF2A2A24),
    surfaceContainerHigh: Color(0xFF34342E),
    border: Color(0xFF3E3E36),
    borderSubtle: Color(0xFF323228),
    borderInput: Color(0xFF484840),
    textPrimary: Color(0xFFEBECDC),
    textSecondary: Color(0xFFB8B8A6),
    textMuted: Color(0xFF7A7A68),
    textSubtle: Color(0xFF5A5A48),
    accent: Color(0xFFA2AF9B),
    accentWarm: Color(0xFF8B9A8A),
    accentAmber: Color(0xFFC4956A),
    selected: Color(0xFF3E3E36),
    hover: Color(0xFF484840),
    deletionBg: Color(0xFF3D1F1F),
    deletionBorder: Color(0xFFE53E3E),
    additionBg: Color(0xFF1F3D2A),
    additionBorder: Color(0xFF48BB78),
    warningBg: Color(0xFF3D331F),
    warningText: Color(0xFFF6AD55),
    blockquoteBorder: Color(0xFFA2AF9B),
    textTertiary: Color(0xFF7A7A68),
    success: Color(0xFF48BB78),
    error: Color(0xFFE53E3E),
    onAccent: Color(0xFF141410),
  );
}

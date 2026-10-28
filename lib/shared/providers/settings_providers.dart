// 职责: 应用设置、AI Provider、主题、记忆等全局配置的状态管理与持久化
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/theme/theme.dart
//   lib/shared/logger/app_logger.dart
//   lib/shared/services/auto_backup_scheduler.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:easy_localization/easy_localization.dart';

import '../../third/form/flutter_hook_form.dart';
import '../localization/locale_keys.dart';
import '../database/app_database.dart';
import '../models/ai_provider.dart';
import '../models/network_proxy.dart';
import '../models/app_settings_aggregate_data.dart';
import '../models/editor_settings_data.dart';
import '../models/webdav_backup_config.dart';
import '../services/auto_backup_scheduler.dart';
import '../services/themes_orchestrator.dart';
import '../services/backup_orchestrator.dart';
import '../services/backup_service.dart';
import '../services/storage_cleanup_service.dart';
import '../theme/theme.dart';
import '../logger/app_logger.dart';
import 'novel_maintenance_providers.dart';
import 'ai_mode_processing.dart';

import 'webdav_backup_providers.dart';
import '../services/debug/debug_ai_provider.dart';

export '../services/auto_backup_scheduler.dart' show BackupFrequency;

part 'settings_providers.g.dart';

final _log = AppLogger.forModule('Settings');

/// 主题类型枚举
enum AppTheme { reveric, classic, ivory }

/// 主题模式枚举
enum AppThemeMode { light, dark, system }

/// 搜索引擎枚举
enum SearchEngine { duckduckgo }

/// 应用全局背景图片填充模式。
enum AppBackgroundFit { cover, contain, fill }

/// 编辑器中线条样式。
enum EditorLineStyle { solid, sparseDashed, denseDashed }

/// 自动排版时段落之间的空行规则。
enum EditorParagraphSpacing { none, one_blank_line }

/// 阅读模式背景主题。
enum ReadingBackgroundTheme { white, sepia, cream, eye_care, dark, night }

/// 阅读模式翻页方式。
enum ReadingPageTransition { scroll, horizontal, fade }

/// 桌面端阅读模式。
enum DesktopReadingMode { chapter, continuous_scroll }

/// 移动端阅读模式。
enum MobileReadingMode { vertical_scroll, horizontal_page }

/// 桌面小说编辑器的三栏宽度偏好。
class NovelEditorPaneLayout {
  const NovelEditorPaneLayout({
    required this.railWidth,
    required this.sidebarWidth,
    required this.aiPanelWidth,
  });

  static const defaults = NovelEditorPaneLayout(
    railWidth: 132,
    sidebarWidth: 340,
    aiPanelWidth: 360,
  );

  final double railWidth;
  final double sidebarWidth;
  final double aiPanelWidth;

  NovelEditorPaneLayout copyWith({
    double? railWidth,
    double? sidebarWidth,
    double? aiPanelWidth,
  }) {
    return NovelEditorPaneLayout(
      railWidth: railWidth ?? this.railWidth,
      sidebarWidth: sidebarWidth ?? this.sidebarWidth,
      aiPanelWidth: aiPanelWidth ?? this.aiPanelWidth,
    );
  }
}

final novelEditorPaneLayoutProvider =
    AsyncNotifierProvider<NovelEditorPaneLayoutNotifier, NovelEditorPaneLayout>(
      NovelEditorPaneLayoutNotifier.new,
    );

class NovelEditorPaneLayoutNotifier
    extends AsyncNotifier<NovelEditorPaneLayout> {
  static const _layoutKey = 'novel_editor_pane_layout';

  @override
  Future<NovelEditorPaneLayout> build() async {
    final database = ref.read(appSettingsDatabaseProvider);
    final rawLayout = await database.appSettingsDao.get(_layoutKey);
    if (rawLayout == null || rawLayout.isEmpty) {
      return NovelEditorPaneLayout.defaults;
    }

    try {
      final json = jsonDecode(rawLayout) as Map<String, dynamic>;
      return NovelEditorPaneLayout(
        railWidth:
            (json['railWidth'] as num?)?.toDouble() ??
            NovelEditorPaneLayout.defaults.railWidth,
        sidebarWidth:
            (json['sidebarWidth'] as num?)?.toDouble() ??
            NovelEditorPaneLayout.defaults.sidebarWidth,
        aiPanelWidth:
            (json['aiPanelWidth'] as num?)?.toDouble() ??
            NovelEditorPaneLayout.defaults.aiPanelWidth,
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] Failed to read novel editor pane layout',
        error: error,
        stackTrace: stackTrace,
      );
      return NovelEditorPaneLayout.defaults;
    }
  }

  Future<void> save(NovelEditorPaneLayout layout) async {
    final previous = state.value ?? NovelEditorPaneLayout.defaults;
    state = AsyncData(layout);

    try {
      final database = ref.read(appSettingsDatabaseProvider);
      await database.appSettingsDao.set(
        key: _layoutKey,
        value: jsonEncode({
          'railWidth': layout.railWidth,
          'sidebarWidth': layout.sidebarWidth,
          'aiPanelWidth': layout.aiPanelWidth,
        }),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] Failed to persist novel editor pane layout',
        error: error,
        stackTrace: stackTrace,
      );
      state = AsyncData(previous);
    }
  }
}

Color appBackgroundColorForTheme(
  AppTheme theme, {
  Brightness brightness = Brightness.light,
}) {
  final colors = switch ((theme, brightness)) {
    (AppTheme.reveric, Brightness.dark) => RevericColors.revericDark,
    (AppTheme.reveric, _) => RevericColors.reveric,
    (AppTheme.classic, Brightness.dark) => RevericColors.classicDark,
    (AppTheme.classic, _) => RevericColors.classic,
    (AppTheme.ivory, Brightness.dark) => RevericColors.ivoryDark,
    (AppTheme.ivory, _) => RevericColors.ivory,
  };
  return colors.canvas;
}

enum AppSettingsFormField<T> implements FieldSchema {
  theme<AppTheme>(),
  language<String>();

  const AppSettingsFormField();

  @override
  List<Validator<dynamic>>? get validators => switch (this) {
    AppSettingsFormField.language => <Validator<dynamic>>[
      RequiredValidator<String>(
            message: tr(LocaleKeys.settingsValidationSelectLanguage),
          )
          as Validator<dynamic>,
    ],
    _ => null,
  };
}

const _unset = Object();

const defaultAiAgentIdentity = defaultAiAgentIdentityText;
const defaultAiAgentSoul = defaultAiAgentSoulText;

/// 应用设置状态
class AppSettings {
  final AppTheme theme;
  final CustomTheme? customTheme;
  final AppThemeMode themeMode;
  final String language;
  final AiSettings aiSettings;

  /// 搜索引擎选择，默认使用 DuckDuckGo
  final SearchEngine searchEngine;

  // ---- Storage ----

  /// 变更记录保留天数，默认 30 天。到期后由 StorageCleanupService 清理
  /// working_changes、change_commits、AI 聊天，以及 superseded 小说状态快照。
  final int changeRecordRetentionDays;

  // ---- Backup ----

  /// 备份目录路径
  final String backupDirectory;

  /// 备份频率
  final BackupFrequency backupFrequency;

  /// 周备份执行日，使用 ISO weekday 集合（周一为 1，周日为 7）。
  final List<int> backupWeekdays;

  /// 月备份执行日（1–28）。
  final int backupDayOfMonth;

  /// 自动备份执行小时（本地时间，0–23）。
  final int backupHour;

  /// 自动备份执行分钟（本地时间，0–59）。
  final int backupMinute;

  /// 上次备份时间
  final DateTime? lastBackupTime;

  /// 可选的 WebDAV 远程备份配置。密码单独保存在系统安全存储中。
  final WebDavBackupConfig webDavBackupConfig;

  // ---- Memory ----

  /// 是否启用自动从对话中提取记忆。
  final bool memoryAutoExtract;

  /// 记忆提取间隔（分钟），默认 60。
  final int memoryExtractionIntervalMinutes;

  /// AI 助手身份设定。
  final String aiAgentIdentity;

  /// AI 助手长期人格、价值观和边界设定。
  final String aiAgentSoul;

  /// AI 助手头像图片路径（本地文件路径），为空则使用默认头像。
  final String aiAgentAvatarPath;

  /// 是否允许 AI 在回合结束时挂下一步建议。关闭后工具不下发，空态推荐区也不渲染。
  final bool aiAgentNextActionSuggestions;

  // ---- Editor ----

  /// 编辑器字体，默认值随当前应用语言变化。
  final String editorFontFamily;

  /// 编辑器字号，默认 16。
  final int editorFontSize;

  /// 编辑器字体颜色，空字符串表示跟随当前主题。
  final String editorFontColorHex;

  /// 编辑器字间距，默认 0。
  final double editorLetterSpacing;

  /// 编辑器行高，默认 1.8。
  final double editorLineHeight;

  /// 桌面章节编辑器是否显示 minimap，默认关闭。
  final bool editorMinimapEnabled;

  /// 章节正文编辑器是否显示行号，默认关闭。
  final bool editorLineNumbersEnabled;

  /// 章节树是否按倒序（章节号从大到小）排列，默认正序。
  final bool chapterSortDescending;

  /// 是否启用编辑器线条标注。
  final bool editorLineEnabled;

  /// 编辑器线条风格。
  final EditorLineStyle editorLineStyle;

  /// 编辑器线条颜色（十六进制 ARGB 字符串，如 '#FFFF0000'）。
  final String editorLineColorHex;

  /// 是否启用章节正文实体识别。
  final bool editorEntityRecognitionEnabled;

  /// 实体识别标记是否使用斜体。
  final bool editorEntityItalic;

  /// 实体识别标记是否使用高亮背景。
  final bool editorEntityHighlight;

  /// 实体识别标记高亮颜色（十六进制 ARGB 字符串）。
  final String editorEntityHighlightColorHex;

  /// 实体识别标记文字颜色，空字符串表示继承正文颜色。
  final String editorEntityTextColorHex;

  /// 实体识别标记是否使用划线。
  final bool editorEntityUnderline;

  /// 实体识别标记是否使用粗体。
  final bool editorEntityBold;

  /// 自动排版时段首缩进的全角空格数量，默认 2。
  final int editorFormatIndentCount;

  /// 自动排版时段落之间的空行规则，默认空一行。
  final EditorParagraphSpacing editorFormatParagraphSpacing;

  /// 自动排版时正文是否保留已有空格（false 时去除所有空格），默认 true。
  final bool editorFormatAllowSpaces;

  // ---- Reading ----

  /// 阅读模式字体，默认值随当前应用语言变化。
  final String readingFontFamily;

  /// 阅读模式字号，默认 18。
  final int readingFontSize;

  /// 阅读模式字间距，默认 0。
  final double readingLetterSpacing;

  /// 阅读模式行高，默认 1.8。
  final double readingLineHeight;

  /// 阅读模式段落间距倍数，默认 1.0。
  final double readingParagraphSpacing;

  /// 阅读模式左右页边距，默认 24。
  final double readingMargin;

  /// 阅读模式背景主题，默认 white。
  final ReadingBackgroundTheme readingBackgroundTheme;

  /// 阅读模式翻页方式，默认 scroll。
  final ReadingPageTransition readingPageTransition;

  /// 桌面端阅读模式，默认按章节阅读。
  final DesktopReadingMode desktopReadingMode;

  /// 移动端阅读模式，默认上下连续滚动。
  final MobileReadingMode mobileReadingMode;

  /// 阅读模式是否启用字体加粗。
  final bool readingBold;

  // ---- Appearance ----

  /// 全局背景图片路径，空字符串表示无背景图。
  final String appBackgroundImagePath;

  /// 全局背景图片填充模式。
  final AppBackgroundFit appBackgroundFit;

  /// 全局纯色背景来源主题，null 表示不启用纯色背景。
  final AppTheme? appBackgroundTheme;

  /// 界面文字全局缩放倍率，1.0 表示不缩放。
  final double uiTextScale;

  // ---- User Profile ----

  /// 用户显示名称
  final String username;

  /// 用户头像图片路径（本地文件路径），为空则使用默认头像。
  final String avatarPath;

  final NetworkProxy networkProxy;

  // ---- Auto Update ----

  /// 是否启动时检查更新，默认 true。
  final bool checkForUpdates;

  /// 自动检查更新间隔（小时），默认 24。
  final int updateCheckIntervalHours;

  /// 上次检查更新时间
  final DateTime? lastUpdateCheckTime;

  // ---- Debug ----

  /// 是否开启调试模式。开启后 UI 会展示面向排查的信息。
  final bool debugMode;

  /// 调试设置页是否已解锁（持久化）。解锁后无需每次重新点击即可在设置中看到调试页。
  final bool debugPageUnlocked;

  static const defaultEditorFontFamily = 'Literata';
  static const defaultEditorFontSize = EditorSettingsData.defaultFontSize;
  static const defaultEditorLetterSpacing =
      EditorSettingsData.defaultLetterSpacing;
  static const defaultEditorLineHeight = EditorSettingsData.defaultLineHeight;
  static const defaultEditorFormatIndentCount =
      EditorSettingsData.defaultFormatIndentCount;
  static const defaultEditorFormatParagraphSpacing =
      EditorParagraphSpacing.one_blank_line;
  static const defaultEditorFormatAllowSpaces = true;

  static const defaultReadingFontFamily = 'Literata';
  static const defaultReadingFontSize = 18;
  static const defaultReadingLetterSpacing = 0.0;
  static const defaultReadingLineHeight = 1.8;
  static const defaultReadingParagraphSpacing = 1.0;
  static const defaultReadingMargin = 24.0;
  static const defaultReadingBackgroundTheme = ReadingBackgroundTheme.white;
  static const defaultReadingPageTransition = ReadingPageTransition.scroll;
  static const defaultDesktopReadingMode = DesktopReadingMode.chapter;
  static const defaultMobileReadingMode = MobileReadingMode.vertical_scroll;
  static const defaultReadingBold = false;

  static const bundledFontFamilies = <String>['LXGWWenKai', 'Literata'];

  static String defaultFontFamilyForLanguage(String language) {
    return EditorSettingsData.defaultsForLanguage(language).fontFamily;
  }

  const AppSettings({
    required this.theme,
    this.customTheme,
    required this.themeMode,
    required this.language,
    required this.aiSettings,
    this.searchEngine = SearchEngine.duckduckgo,
    this.changeRecordRetentionDays = 30,
    this.backupDirectory = '',
    this.backupFrequency = BackupFrequency.manual,
    this.backupWeekdays = const <int>[DateTime.monday],
    this.backupDayOfMonth = 1,
    this.backupHour = 2,
    this.backupMinute = 0,
    this.lastBackupTime,
    this.webDavBackupConfig = const WebDavBackupConfig(),
    this.memoryAutoExtract = true,
    this.memoryExtractionIntervalMinutes = 60,
    this.aiAgentIdentity = defaultAiAgentIdentity,
    this.aiAgentSoul = defaultAiAgentSoul,
    this.aiAgentAvatarPath = '',
    this.aiAgentNextActionSuggestions = true,
    this.editorFontFamily = defaultEditorFontFamily,
    this.editorFontSize = defaultEditorFontSize,
    this.editorFontColorHex = '',
    this.editorLetterSpacing = defaultEditorLetterSpacing,
    this.editorLineHeight = defaultEditorLineHeight,
    this.editorMinimapEnabled = false,
    this.editorLineNumbersEnabled = false,
    this.chapterSortDescending = false,
    this.editorLineEnabled = false,
    this.editorLineStyle = EditorLineStyle.solid,
    this.editorLineColorHex = '#FFFF0000',
    this.editorEntityRecognitionEnabled = true,
    this.editorEntityItalic = false,
    this.editorEntityHighlight = false,
    this.editorEntityHighlightColorHex = '#33FFD54F',
    this.editorEntityTextColorHex = '',
    this.editorEntityUnderline = false,
    this.editorEntityBold = false,
    this.editorFormatIndentCount = defaultEditorFormatIndentCount,
    this.editorFormatParagraphSpacing = defaultEditorFormatParagraphSpacing,
    this.editorFormatAllowSpaces = defaultEditorFormatAllowSpaces,
    this.readingFontFamily = defaultReadingFontFamily,
    this.readingFontSize = defaultReadingFontSize,
    this.readingLetterSpacing = defaultReadingLetterSpacing,
    this.readingLineHeight = defaultReadingLineHeight,
    this.readingParagraphSpacing = defaultReadingParagraphSpacing,
    this.readingMargin = defaultReadingMargin,
    this.readingBackgroundTheme = defaultReadingBackgroundTheme,
    this.readingPageTransition = defaultReadingPageTransition,
    this.desktopReadingMode = defaultDesktopReadingMode,
    this.mobileReadingMode = defaultMobileReadingMode,
    this.readingBold = defaultReadingBold,
    this.appBackgroundImagePath = '',
    this.appBackgroundFit = AppBackgroundFit.cover,
    this.appBackgroundTheme,
    this.uiTextScale = 1.0,
    this.username = '',
    this.avatarPath = '',
    this.networkProxy = const NetworkProxy(),
    this.checkForUpdates = true,
    this.updateCheckIntervalHours = 24,
    this.lastUpdateCheckTime,
    this.debugMode = false,
    this.debugPageUnlocked = false,
  });

  AppSettings copyWith({
    AppTheme? theme,
    Object? customTheme = _unset,
    AppThemeMode? themeMode,
    String? language,
    AiSettings? aiSettings,
    SearchEngine? searchEngine,
    int? changeRecordRetentionDays,
    NetworkProxy? networkProxy,
    bool? checkForUpdates,
    int? updateCheckIntervalHours,
    Object? lastUpdateCheckTime = _unset,
    bool? debugMode,
    bool? debugPageUnlocked,
    String? backupDirectory,
    BackupFrequency? backupFrequency,
    List<int>? backupWeekdays,
    int? backupDayOfMonth,
    int? backupHour,
    int? backupMinute,
    DateTime? lastBackupTime,
    WebDavBackupConfig? webDavBackupConfig,
    bool? memoryAutoExtract,
    int? memoryExtractionIntervalMinutes,
    String? aiAgentIdentity,
    String? aiAgentSoul,
    String? aiAgentAvatarPath,
    bool? aiAgentNextActionSuggestions,
    String? editorFontFamily,
    int? editorFontSize,
    String? editorFontColorHex,
    double? editorLetterSpacing,
    double? editorLineHeight,
    bool? editorMinimapEnabled,
    bool? editorLineNumbersEnabled,
    bool? chapterSortDescending,
    bool? editorLineEnabled,
    EditorLineStyle? editorLineStyle,
    String? editorLineColorHex,
    bool? editorEntityRecognitionEnabled,
    bool? editorEntityItalic,
    bool? editorEntityHighlight,
    String? editorEntityHighlightColorHex,
    String? editorEntityTextColorHex,
    bool? editorEntityUnderline,
    bool? editorEntityBold,
    int? editorFormatIndentCount,
    EditorParagraphSpacing? editorFormatParagraphSpacing,
    bool? editorFormatAllowSpaces,
    String? readingFontFamily,
    int? readingFontSize,
    double? readingLetterSpacing,
    double? readingLineHeight,
    double? readingParagraphSpacing,
    double? readingMargin,
    ReadingBackgroundTheme? readingBackgroundTheme,
    ReadingPageTransition? readingPageTransition,
    DesktopReadingMode? desktopReadingMode,
    MobileReadingMode? mobileReadingMode,
    bool? readingBold,
    String? appBackgroundImagePath,
    AppBackgroundFit? appBackgroundFit,
    Object? appBackgroundTheme = _unset,
    double? uiTextScale,
    String? username,
    String? avatarPath,
  }) {
    return AppSettings(
      theme: theme ?? this.theme,
      customTheme: customTheme == _unset
          ? this.customTheme
          : customTheme as CustomTheme?,
      themeMode: themeMode ?? this.themeMode,
      language: language ?? this.language,
      aiSettings: aiSettings ?? this.aiSettings,
      searchEngine: searchEngine ?? this.searchEngine,
      changeRecordRetentionDays:
          changeRecordRetentionDays ?? this.changeRecordRetentionDays,
      networkProxy: networkProxy ?? this.networkProxy,
      checkForUpdates: checkForUpdates ?? this.checkForUpdates,
      updateCheckIntervalHours:
          updateCheckIntervalHours ?? this.updateCheckIntervalHours,
      lastUpdateCheckTime: lastUpdateCheckTime == _unset
          ? this.lastUpdateCheckTime
          : lastUpdateCheckTime as DateTime?,
      debugMode: debugMode ?? this.debugMode,
      debugPageUnlocked: debugPageUnlocked ?? this.debugPageUnlocked,
      backupDirectory: backupDirectory ?? this.backupDirectory,
      backupFrequency: backupFrequency ?? this.backupFrequency,
      backupWeekdays: backupWeekdays ?? this.backupWeekdays,
      backupDayOfMonth: backupDayOfMonth ?? this.backupDayOfMonth,
      backupHour: backupHour ?? this.backupHour,
      backupMinute: backupMinute ?? this.backupMinute,
      lastBackupTime: lastBackupTime ?? this.lastBackupTime,
      webDavBackupConfig: webDavBackupConfig ?? this.webDavBackupConfig,
      memoryAutoExtract: memoryAutoExtract ?? this.memoryAutoExtract,
      memoryExtractionIntervalMinutes:
          memoryExtractionIntervalMinutes ??
          this.memoryExtractionIntervalMinutes,
      aiAgentIdentity: aiAgentIdentity ?? this.aiAgentIdentity,
      aiAgentSoul: aiAgentSoul ?? this.aiAgentSoul,
      aiAgentAvatarPath: aiAgentAvatarPath ?? this.aiAgentAvatarPath,
      aiAgentNextActionSuggestions:
          aiAgentNextActionSuggestions ?? this.aiAgentNextActionSuggestions,
      editorFontFamily: editorFontFamily ?? this.editorFontFamily,
      editorFontSize: editorFontSize ?? this.editorFontSize,
      editorFontColorHex: editorFontColorHex ?? this.editorFontColorHex,
      editorLetterSpacing: editorLetterSpacing ?? this.editorLetterSpacing,
      editorLineHeight: editorLineHeight ?? this.editorLineHeight,
      editorMinimapEnabled: editorMinimapEnabled ?? this.editorMinimapEnabled,
      editorLineNumbersEnabled:
          editorLineNumbersEnabled ?? this.editorLineNumbersEnabled,
      chapterSortDescending:
          chapterSortDescending ?? this.chapterSortDescending,
      editorLineEnabled: editorLineEnabled ?? this.editorLineEnabled,
      editorLineStyle: editorLineStyle ?? this.editorLineStyle,
      editorLineColorHex: editorLineColorHex ?? this.editorLineColorHex,
      editorEntityRecognitionEnabled:
          editorEntityRecognitionEnabled ?? this.editorEntityRecognitionEnabled,
      editorEntityItalic: editorEntityItalic ?? this.editorEntityItalic,
      editorEntityHighlight:
          editorEntityHighlight ?? this.editorEntityHighlight,
      editorEntityHighlightColorHex:
          editorEntityHighlightColorHex ?? this.editorEntityHighlightColorHex,
      editorEntityTextColorHex:
          editorEntityTextColorHex ?? this.editorEntityTextColorHex,
      editorEntityUnderline:
          editorEntityUnderline ?? this.editorEntityUnderline,
      editorEntityBold: editorEntityBold ?? this.editorEntityBold,
      editorFormatIndentCount:
          editorFormatIndentCount ?? this.editorFormatIndentCount,
      editorFormatParagraphSpacing:
          editorFormatParagraphSpacing ?? this.editorFormatParagraphSpacing,
      editorFormatAllowSpaces:
          editorFormatAllowSpaces ?? this.editorFormatAllowSpaces,
      readingFontFamily: readingFontFamily ?? this.readingFontFamily,
      readingFontSize: readingFontSize ?? this.readingFontSize,
      readingLetterSpacing: readingLetterSpacing ?? this.readingLetterSpacing,
      readingLineHeight: readingLineHeight ?? this.readingLineHeight,
      readingParagraphSpacing:
          readingParagraphSpacing ?? this.readingParagraphSpacing,
      readingMargin: readingMargin ?? this.readingMargin,
      readingBackgroundTheme:
          readingBackgroundTheme ?? this.readingBackgroundTheme,
      readingPageTransition:
          readingPageTransition ?? this.readingPageTransition,
      desktopReadingMode: desktopReadingMode ?? this.desktopReadingMode,
      mobileReadingMode: mobileReadingMode ?? this.mobileReadingMode,
      readingBold: readingBold ?? this.readingBold,
      appBackgroundImagePath:
          appBackgroundImagePath ?? this.appBackgroundImagePath,
      appBackgroundFit: appBackgroundFit ?? this.appBackgroundFit,
      appBackgroundTheme: appBackgroundTheme == _unset
          ? this.appBackgroundTheme
          : appBackgroundTheme as AppTheme?,
      uiTextScale: uiTextScale ?? this.uiTextScale,
      username: username ?? this.username,
      avatarPath: avatarPath ?? this.avatarPath,
    );
  }

  RevericThemeData themeDataForBrightness(Brightness brightness) {
    final useDark =
        themeMode == AppThemeMode.dark ||
        (themeMode == AppThemeMode.system && brightness == Brightness.dark);
    return resolveThemePalette(
      baseTheme: customTheme?.baseTheme ?? theme.name,
      brightness: useDark ? Brightness.dark : Brightness.light,
      overrides:
          (useDark
              ? customTheme?.darkOverrides
              : customTheme?.lightOverrides) ??
          const {},
    );
  }

  RevericThemeData get themeData {
    return themeDataForBrightness(Brightness.light);
  }
}

EditorSettingsData _editorSettingsDataFromAppSettings(AppSettings settings) {
  return EditorSettingsData(
    fontFamily: settings.editorFontFamily,
    fontSize: settings.editorFontSize,
    fontColorHex: settings.editorFontColorHex,
    letterSpacing: settings.editorLetterSpacing,
    lineHeight: settings.editorLineHeight,
    minimapEnabled: settings.editorMinimapEnabled,
    lineNumbersEnabled: settings.editorLineNumbersEnabled,
    lineEnabled: settings.editorLineEnabled,
    lineStyle: switch (settings.editorLineStyle) {
      EditorLineStyle.solid => 'solid',
      EditorLineStyle.sparseDashed => 'sparseDashed',
      EditorLineStyle.denseDashed => 'denseDashed',
    },
    lineColorHex: settings.editorLineColorHex,
    entityRecognitionEnabled: settings.editorEntityRecognitionEnabled,
    entityItalic: settings.editorEntityItalic,
    entityHighlight: settings.editorEntityHighlight,
    entityHighlightColorHex: settings.editorEntityHighlightColorHex,
    entityTextColorHex: settings.editorEntityTextColorHex,
    entityUnderline: settings.editorEntityUnderline,
    entityBold: settings.editorEntityBold,
    formatIndentCount: settings.editorFormatIndentCount,
    formatParagraphSpacing: switch (settings.editorFormatParagraphSpacing) {
      EditorParagraphSpacing.none => 'none',
      EditorParagraphSpacing.one_blank_line => 'one_blank_line',
    },
    formatAllowSpaces: settings.editorFormatAllowSpaces,
  );
}

ReadingSettingsData _readingSettingsDataFromAppSettings(AppSettings settings) {
  return ReadingSettingsData(
    fontFamily: settings.readingFontFamily,
    fontSize: settings.readingFontSize,
    letterSpacing: settings.readingLetterSpacing,
    lineHeight: settings.readingLineHeight,
    paragraphSpacing: settings.readingParagraphSpacing,
    margin: settings.readingMargin,
    backgroundTheme: switch (settings.readingBackgroundTheme) {
      ReadingBackgroundTheme.white => 'white',
      ReadingBackgroundTheme.sepia => 'sepia',
      ReadingBackgroundTheme.cream => 'cream',
      ReadingBackgroundTheme.eye_care => 'eye_care',
      ReadingBackgroundTheme.dark => 'dark',
      ReadingBackgroundTheme.night => 'night',
    },
    pageTransition: switch (settings.readingPageTransition) {
      ReadingPageTransition.scroll => 'scroll',
      ReadingPageTransition.horizontal => 'horizontal',
      ReadingPageTransition.fade => 'fade',
    },
    desktopMode: switch (settings.desktopReadingMode) {
      DesktopReadingMode.chapter => 'chapter',
      DesktopReadingMode.continuous_scroll => 'continuous_scroll',
    },
    mobileMode: switch (settings.mobileReadingMode) {
      MobileReadingMode.vertical_scroll => 'vertical_scroll',
      MobileReadingMode.horizontal_page => 'horizontal_page',
    },
    bold: settings.readingBold,
  );
}

AppearanceSettingsData _appearanceSettingsDataFromAppSettings(
  AppSettings settings,
) {
  String themeToString(AppTheme theme) {
    return switch (theme) {
      AppTheme.reveric => 'reveric',
      AppTheme.classic => 'classic',
      AppTheme.ivory => 'ivory',
    };
  }

  return AppearanceSettingsData(
    theme: themeToString(settings.theme),
    customThemeId: settings.customTheme?.id,
    themeMode: switch (settings.themeMode) {
      AppThemeMode.light => 'light',
      AppThemeMode.dark => 'dark',
      AppThemeMode.system => 'system',
    },
    backgroundImagePath: settings.appBackgroundImagePath,
    backgroundFit: switch (settings.appBackgroundFit) {
      AppBackgroundFit.cover => 'cover',
      AppBackgroundFit.contain => 'contain',
      AppBackgroundFit.fill => 'fill',
    },
    backgroundTheme: settings.appBackgroundTheme == null
        ? null
        : themeToString(settings.appBackgroundTheme!),
    uiTextScale: settings.uiTextScale,
  );
}

MemorySettingsData _memorySettingsDataFromAppSettings(AppSettings settings) {
  return MemorySettingsData(
    autoExtract: settings.memoryAutoExtract,
    extractionIntervalMinutes: settings.memoryExtractionIntervalMinutes,
  );
}

AiAgentSettingsData _aiAgentSettingsDataFromAppSettings(AppSettings settings) {
  return AiAgentSettingsData(
    identity: settings.aiAgentIdentity,
    soul: settings.aiAgentSoul,
    avatarPath: settings.aiAgentAvatarPath,
    nextActionSuggestions: settings.aiAgentNextActionSuggestions,
  );
}

StorageSettingsData _storageSettingsDataFromAppSettings(AppSettings settings) {
  return StorageSettingsData(
    changeRecordRetentionDays: settings.changeRecordRetentionDays,
    backupDirectory: settings.backupDirectory,
    backupFrequency: switch (settings.backupFrequency) {
      BackupFrequency.manual => 'manual',
      BackupFrequency.daily => 'daily',
      BackupFrequency.weekly => 'weekly',
      BackupFrequency.monthly => 'monthly',
    },
    backupWeekdays: settings.backupWeekdays,
    backupDayOfMonth: settings.backupDayOfMonth,
    backupHour: settings.backupHour,
    backupMinute: settings.backupMinute,
    webDavEnabled: settings.webDavBackupConfig.enabled,
    webDavServerUrl: settings.webDavBackupConfig.serverUrl,
    webDavUsername: settings.webDavBackupConfig.username,
    webDavPassword: settings.webDavBackupConfig.password,
    webDavRemoteDirectory: settings.webDavBackupConfig.remoteDirectory,
  );
}

LocalProfileSettingsData _localProfileDataFromAppSettings(
  AppSettings settings,
) {
  return LocalProfileSettingsData(
    username: settings.username,
    avatarPath: settings.avatarPath,
  );
}

DebugSettingsData _debugSettingsDataFromAppSettings(AppSettings settings) {
  return DebugSettingsData(
    debugMode: settings.debugMode,
    debugPageUnlocked: settings.debugPageUnlocked,
  );
}

InitialFieldValues<AppSettingsFormField, dynamic> _appSettingsFormValues(
  AppSettings settings,
) {
  return {
    AppSettingsFormField.theme: settings.theme,
    AppSettingsFormField.language: settings.language,
  };
}

InitialFieldValues<AiProviderFormField, dynamic> _aiProviderFormValues(
  AiProvider config,
) {
  return {
    AiProviderFormField.name: config.name,
    AiProviderFormField.type: config.type,
    AiProviderFormField.enabled: config.enabled,
    AiProviderFormField.apiKey: config.apiKey,
    AiProviderFormField.baseUrl: config.baseUrl,
    AiProviderFormField.models: config.availableModels,
    AiProviderFormField.temperature: config.temperature,
    AiProviderFormField.maxTurns: config.maxTurns,
    AiProviderFormField.reasoningEffort: config.reasoningEffort,
    AiProviderFormField.proxyUrl: config.proxyUrl,
    AiProviderFormField.proxyUsername: config.proxyUsername,
    AiProviderFormField.proxyPassword: config.proxyPassword,
  };
}

bool _stringListEquals(List<String> left, List<String> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) {
      return false;
    }
  }
  return true;
}

void _syncFieldValue<F extends FieldSchema, T>(
  FormFieldsController<F> form,
  F field,
  T value,
) {
  final currentValue = form.getValue<T>(field);
  if (currentValue is List<String> && value is List<String>) {
    if (_stringListEquals(currentValue, value)) {
      return;
    }
  } else if (currentValue == value) {
    return;
  }

  form.updateValue<T>(field, value, notify: false);
}

void _syncAppSettingsForm(
  FormFieldsController<AppSettingsFormField> form,
  AppSettings settings,
) {
  _syncFieldValue(form, AppSettingsFormField.theme, settings.theme);
  _syncFieldValue(form, AppSettingsFormField.language, settings.language);
}

void _syncAiProviderForm(
  FormFieldsController<AiProviderFormField> form,
  AiProvider config,
) {
  _syncFieldValue(form, AiProviderFormField.name, config.name);
  _syncFieldValue(form, AiProviderFormField.type, config.type);
  _syncFieldValue(form, AiProviderFormField.enabled, config.enabled);
  _syncFieldValue(form, AiProviderFormField.apiKey, config.apiKey);
  _syncFieldValue(form, AiProviderFormField.baseUrl, config.baseUrl);
  _syncFieldValue(form, AiProviderFormField.models, config.availableModels);
  _syncFieldValue(form, AiProviderFormField.temperature, config.temperature);
  _syncFieldValue(form, AiProviderFormField.maxTurns, config.maxTurns);
  _syncFieldValue(
    form,
    AiProviderFormField.reasoningEffort,
    config.reasoningEffort,
  );
  _syncFieldValue(form, AiProviderFormField.proxyUrl, config.proxyUrl);
  _syncFieldValue(
    form,
    AiProviderFormField.proxyUsername,
    config.proxyUsername,
  );
  _syncFieldValue(
    form,
    AiProviderFormField.proxyPassword,
    config.proxyPassword,
  );
}

@riverpod
FormFieldsController<AppSettingsFormField>? appSettingsForm(Ref ref) {
  final settings = ref.read(appSettingsProvider).asData?.value;
  if (settings == null) {
    return null;
  }

  final form = FormFieldsController<AppSettingsFormField>(
    GlobalKey<FormState>(debugLabel: 'AppSettingsForm'),
    initialValues: _appSettingsFormValues(settings),
  );

  ref.listen<AsyncValue<AppSettings>>(appSettingsProvider, (_, next) {
    final nextSettings = next.asData?.value;
    if (nextSettings == null || form.hasChanged) {
      return;
    }
    _syncAppSettingsForm(form, nextSettings);
  });

  ref.onDispose(form.dispose);
  return form;
}

@riverpod
FormFieldsController<AiProviderFormField>? aiProviderForm(
  Ref ref,
  String providerId,
) {
  final config = ref.read(aiSettingsProvider).findConfigById(providerId);
  if (config == null) {
    return null;
  }

  final form = FormFieldsController<AiProviderFormField>(
    GlobalKey<FormState>(debugLabel: 'AiProviderForm:$providerId'),
    initialValues: _aiProviderFormValues(config),
  );

  ref.listen<AiSettings>(aiSettingsProvider, (_, next) {
    final nextConfig = next.findConfigById(providerId);
    if (nextConfig == null || form.hasChanged) {
      return;
    }
    _syncAiProviderForm(form, nextConfig);
  });

  ref.onDispose(form.dispose);
  return form;
}

@Riverpod(keepAlive: true)
AppDatabase appSettingsDatabase(Ref ref) {
  final database = AppDatabase();
  ref.onDispose(database.close);
  return database;
}

@Riverpod(keepAlive: true)
class AppSettingsNotifier extends _$AppSettingsNotifier {
  static const _languageKey = 'app_language';
  static const _aiSettingsKey = 'ai_settings';
  static const _searchEngineKey = 'search_engine';
  static const _lastBackupTimeKey = 'last_backup_time';
  static const _readingSettingsKey = ReadingSettingsData.appSettingsKey;
  static const _appearanceSettingsKey = AppearanceSettingsData.appSettingsKey;
  static const _memorySettingsKey = MemorySettingsData.appSettingsKey;
  static const _aiAgentSettingsKey = AiAgentSettingsData.appSettingsKey;
  static const _storageSettingsKey = StorageSettingsData.appSettingsKey;
  static const _localProfileKey = LocalProfileSettingsData.appSettingsKey;
  static const _debugSettingsKey = DebugSettingsData.appSettingsKey;
  static const _editorSettingsKey = EditorSettingsData.appSettingsKey;
  static const _chapterSortDescendingKey = 'chapter_sort_descending';
  static const _checkForUpdatesKey = 'check_for_updates';
  static const _updateCheckIntervalKey = 'update_check_interval_hours';
  static const _lastUpdateCheckTimeKey = 'last_update_check_time';

  @override
  Future<AppSettings> build() async {
    // 不订阅模型目录同步，避免目录刷新触发全局设置重载。
    return _loadSettings();
  }

  T _loadAggregate<T>({
    required String key,
    required String? raw,
    required T Function(String raw) decode,
    required T defaults,
  }) {
    if (raw == null || raw.isEmpty) {
      return defaults;
    }
    try {
      return decode(raw);
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=app_settings operation=SELECT id=$key '
        'malformed aggregate',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<AppSettings> _loadSettings() async {
    _log.info('_loadSettings START');
    final database = ref.read(appSettingsDatabaseProvider);
    _log.info('database obtained');

    final allSettings = await database.appSettingsDao.getAll();
    _log.info('settings loaded from database count=${allSettings.length}');

    final language = allSettings[_languageKey];
    final aiSettingsJson = allSettings[_aiSettingsKey];
    final searchEngineString = allSettings[_searchEngineKey];

    final readingSettingsRaw = allSettings[_readingSettingsKey];
    final appearanceSettingsRaw = allSettings[_appearanceSettingsKey];
    final memorySettingsRaw = allSettings[_memorySettingsKey];
    final aiAgentSettingsRaw = allSettings[_aiAgentSettingsKey];
    final storageSettingsRaw = allSettings[_storageSettingsKey];
    final localProfileRaw = allSettings[_localProfileKey];
    final debugSettingsRaw = allSettings[_debugSettingsKey];
    final lastBackupTimeRaw = allSettings[_lastBackupTimeKey];
    final editorSettingsRaw = allSettings[_editorSettingsKey];
    final chapterSortDescendingRaw = allSettings[_chapterSortDescendingKey];
    final checkForUpdatesRaw = allSettings[_checkForUpdatesKey];
    final updateCheckIntervalRaw = allSettings[_updateCheckIntervalKey];
    final lastUpdateCheckTimeRaw = allSettings[_lastUpdateCheckTimeKey];

    AiSettings aiSettingsMeta;
    if (aiSettingsJson != null && aiSettingsJson.isNotEmpty) {
      try {
        aiSettingsMeta = AiSettings.fromJson(jsonDecode(aiSettingsJson));
      } catch (_) {
        aiSettingsMeta = AiSettings.defaults().copyWith(providers: const []);
      }
    } else {
      aiSettingsMeta = AiSettings.defaults().copyWith(providers: const []);
    }

    _log.info('loading AI provider configs');
    var providerConfigs = await database.aiProviderDao.getAll();
    _log.info('AI provider configs loaded count=${providerConfigs.length}');
    final merged = AiSettings.mergeWithRequiredProviders(providerConfigs);
    for (final provider in merged) {
      if (!providerConfigs.any((existing) => existing.id == provider.id)) {
        await database.aiProviderDao.upsert(provider);
        await database.aiProviderDao.restore(provider.id);
      }
    }
    providerConfigs = merged;

    final aiSettings = aiSettingsMeta.copyWith(providers: providerConfigs);
    final resolvedLanguage = language ?? 'zh_CN';
    final defaultEditorSettings = EditorSettingsData.defaultsForLanguage(
      resolvedLanguage,
    );
    final defaultReadingSettings = ReadingSettingsData.defaultsForLanguage(
      resolvedLanguage,
    );
    final editorSettings = _loadAggregate(
      key: _editorSettingsKey,
      raw: editorSettingsRaw,
      decode: (raw) =>
          EditorSettingsData.decode(raw, fallback: defaultEditorSettings),
      defaults: defaultEditorSettings,
    );
    final readingSettings = _loadAggregate(
      key: _readingSettingsKey,
      raw: readingSettingsRaw,
      decode: (raw) =>
          ReadingSettingsData.decode(raw, fallback: defaultReadingSettings),
      defaults: defaultReadingSettings,
    );
    final appearanceSettings = _loadAggregate(
      key: _appearanceSettingsKey,
      raw: appearanceSettingsRaw,
      decode: AppearanceSettingsData.decode,
      defaults: AppearanceSettingsData.defaults,
    );
    final memorySettings = _loadAggregate(
      key: _memorySettingsKey,
      raw: memorySettingsRaw,
      decode: MemorySettingsData.decode,
      defaults: MemorySettingsData.defaults,
    );
    final aiAgentSettings = _loadAggregate(
      key: _aiAgentSettingsKey,
      raw: aiAgentSettingsRaw,
      decode: AiAgentSettingsData.decode,
      defaults: AiAgentSettingsData.defaults,
    );
    final storageSettings = _loadAggregate(
      key: _storageSettingsKey,
      raw: storageSettingsRaw,
      decode: StorageSettingsData.decode,
      defaults: StorageSettingsData.defaults,
    );
    final localProfile = _loadAggregate(
      key: _localProfileKey,
      raw: localProfileRaw,
      decode: LocalProfileSettingsData.decode,
      defaults: LocalProfileSettingsData.defaults,
    );
    final debugSettings = _loadAggregate(
      key: _debugSettingsKey,
      raw: debugSettingsRaw,
      decode: DebugSettingsData.decode,
      defaults: DebugSettingsData.defaults,
    );

    final lastBackupTime = lastBackupTimeRaw != null
        ? DateTime.tryParse(lastBackupTimeRaw)
        : null;
    final checkForUpdates =
        checkForUpdatesRaw == null || checkForUpdatesRaw == 'true';
    final updateCheckIntervalHours =
        (int.tryParse(updateCheckIntervalRaw ?? '') ?? 24).clamp(1, 168);
    final lastUpdateCheckTime = lastUpdateCheckTimeRaw != null
        ? DateTime.tryParse(lastUpdateCheckTimeRaw)
        : null;
    final loaded = AppSettings(
      theme: _parseTheme(appearanceSettings.theme),
      customTheme: appearanceSettings.customThemeId == null
          ? null
          : await ThemesOrchestrator.readCustomTheme(
              database,
              appearanceSettings.customThemeId!,
            ),
      themeMode: _parseThemeMode(appearanceSettings.themeMode),
      uiTextScale: appearanceSettings.uiTextScale,
      language: resolvedLanguage,
      aiSettings: aiSettings,
      searchEngine: _parseSearchEngine(searchEngineString),
      changeRecordRetentionDays: storageSettings.changeRecordRetentionDays,
      backupDirectory: storageSettings.backupDirectory,
      backupFrequency: _parseBackupFrequency(storageSettings.backupFrequency),
      backupWeekdays: storageSettings.backupWeekdays,
      backupDayOfMonth: storageSettings.backupDayOfMonth,
      backupHour: storageSettings.backupHour,
      backupMinute: storageSettings.backupMinute,
      lastBackupTime: lastBackupTime,
      webDavBackupConfig: WebDavBackupConfig(
        enabled: storageSettings.webDavEnabled,
        serverUrl: storageSettings.webDavServerUrl,
        username: storageSettings.webDavUsername,
        password: storageSettings.webDavPassword,
        remoteDirectory: storageSettings.webDavRemoteDirectory,
      ).normalized(),
      memoryAutoExtract: memorySettings.autoExtract,
      memoryExtractionIntervalMinutes: memorySettings.extractionIntervalMinutes,
      aiAgentIdentity: aiAgentSettings.identity,
      aiAgentSoul: aiAgentSettings.soul,
      aiAgentAvatarPath: aiAgentSettings.avatarPath,
      aiAgentNextActionSuggestions: aiAgentSettings.nextActionSuggestions,
      editorFontFamily: editorSettings.fontFamily,
      editorFontSize: editorSettings.fontSize,
      editorFontColorHex: editorSettings.fontColorHex,
      editorLetterSpacing: editorSettings.letterSpacing,
      editorLineHeight: editorSettings.lineHeight,
      editorMinimapEnabled: editorSettings.minimapEnabled,
      editorLineNumbersEnabled: editorSettings.lineNumbersEnabled,
      chapterSortDescending: chapterSortDescendingRaw == 'true',
      editorLineEnabled: editorSettings.lineEnabled,
      editorLineStyle: _parseEditorLineStyle(editorSettings.lineStyle),
      editorLineColorHex: editorSettings.lineColorHex,
      editorEntityRecognitionEnabled: editorSettings.entityRecognitionEnabled,
      editorEntityItalic: editorSettings.entityItalic,
      editorEntityHighlight: editorSettings.entityHighlight,
      editorEntityHighlightColorHex: editorSettings.entityHighlightColorHex,
      editorEntityTextColorHex: editorSettings.entityTextColorHex,
      editorEntityUnderline: editorSettings.entityUnderline,
      editorEntityBold: editorSettings.entityBold,
      editorFormatIndentCount: editorSettings.formatIndentCount,
      editorFormatParagraphSpacing: _parseEditorParagraphSpacing(
        editorSettings.formatParagraphSpacing,
      ),
      editorFormatAllowSpaces: editorSettings.formatAllowSpaces,
      readingFontFamily: readingSettings.fontFamily,
      readingFontSize: readingSettings.fontSize,
      readingLetterSpacing: readingSettings.letterSpacing,
      readingLineHeight: readingSettings.lineHeight,
      readingParagraphSpacing: readingSettings.paragraphSpacing,
      readingMargin: readingSettings.margin,
      readingBackgroundTheme: _parseReadingBackgroundTheme(
        readingSettings.backgroundTheme,
      ),
      readingPageTransition: _parseReadingPageTransition(
        readingSettings.pageTransition,
      ),
      desktopReadingMode: _parseDesktopReadingMode(readingSettings.desktopMode),
      mobileReadingMode: _parseMobileReadingMode(readingSettings.mobileMode),
      readingBold: readingSettings.bold,
      appBackgroundImagePath: appearanceSettings.backgroundImagePath,
      appBackgroundFit: _parseAppBackgroundFit(
        appearanceSettings.backgroundFit,
      ),
      appBackgroundTheme: appearanceSettings.backgroundTheme == null
          ? null
          : _parseTheme(appearanceSettings.backgroundTheme),
      username: localProfile.username,
      avatarPath: localProfile.avatarPath,
      networkProxy: _loadAggregate(
        key: NetworkProxy.settingsKey,
        raw: allSettings[NetworkProxy.settingsKey],
        decode: NetworkProxy.decode,
        defaults: const NetworkProxy(),
      ),
      checkForUpdates: checkForUpdates,
      updateCheckIntervalHours: updateCheckIntervalHours,
      lastUpdateCheckTime: lastUpdateCheckTime,
      debugMode: debugSettings.debugMode,
      debugPageUnlocked: debugSettings.debugPageUnlocked,
    );

    if (allSettings.isEmpty) {
      _log.info('persisting default settings');
      await _persistFullSnapshot(loaded);
    }

    _log.info('_loadSettings COMPLETED');
    return loaded;
  }

  Future<void> _persistFullSnapshot(AppSettings settings) async {
    final database = ref.read(appSettingsDatabaseProvider);
    await _persistSettingsAggregate(
      database,
      key: _appearanceSettingsKey,
      value: _appearanceSettingsDataFromAppSettings(settings).encode(),
    );
    await _persistSettingsAggregate(
      database,
      key: _storageSettingsKey,
      value: _storageSettingsDataFromAppSettings(settings).encode(),
    );
    await _persistSettingsAggregate(
      database,
      key: _memorySettingsKey,
      value: _memorySettingsDataFromAppSettings(settings).encode(),
    );
    await _persistSettingsAggregate(
      database,
      key: _aiAgentSettingsKey,
      value: _aiAgentSettingsDataFromAppSettings(settings).encode(),
    );
    await _persistSettingsAggregate(
      database,
      key: _editorSettingsKey,
      value: _editorSettingsDataFromAppSettings(settings).encode(),
    );
    await _persistSettingsAggregate(
      database,
      key: _readingSettingsKey,
      value: _readingSettingsDataFromAppSettings(settings).encode(),
    );
    await _persistSettingsAggregate(
      database,
      key: _localProfileKey,
      value: _localProfileDataFromAppSettings(settings).encode(),
    );
    await _persistSettingsAggregate(
      database,
      key: _debugSettingsKey,
      value: _debugSettingsDataFromAppSettings(settings).encode(),
    );
    await _persistSettingsAggregate(
      database,
      key: NetworkProxy.settingsKey,
      value: settings.networkProxy.encode(),
    );
    await database.appSettingsDao.set(
      key: _languageKey,
      value: settings.language,
    );
    await database.appSettingsDao.set(
      key: _aiSettingsKey,
      value: jsonEncode(settings.aiSettings.toJson()),
    );
    await database.aiProviderDao.saveAll(settings.aiSettings.providers);
    await database.appSettingsDao.set(
      key: _searchEngineKey,
      value: _searchEngineToString(settings.searchEngine),
    );
    if (settings.lastBackupTime != null) {
      await database.appSettingsDao.set(
        key: _lastBackupTimeKey,
        value: settings.lastBackupTime!.toIso8601String(),
      );
    }
    await database.appSettingsDao.set(
      key: _chapterSortDescendingKey,
      value: settings.chapterSortDescending ? 'true' : 'false',
    );
    await database.appSettingsDao.set(
      key: _checkForUpdatesKey,
      value: settings.checkForUpdates ? 'true' : 'false',
    );
    await database.appSettingsDao.set(
      key: _updateCheckIntervalKey,
      value: settings.updateCheckIntervalHours.toString(),
    );
    if (settings.lastUpdateCheckTime != null) {
      await database.appSettingsDao.set(
        key: _lastUpdateCheckTimeKey,
        value: settings.lastUpdateCheckTime!.toIso8601String(),
      );
    }
  }

  Future<void> _persistSettingsAggregate(
    AppDatabase database, {
    required String key,
    required String value,
  }) async {
    try {
      await database.appSettingsDao.set(key: key, value: value);
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=app_settings operation=UPSERT id=$key failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> _persistPartial({
    String? language,
    AiSettings? aiSettings,
    List<AiProvider>? aiProviders,
    SearchEngine? searchEngine,
    AppSettings? appearanceSettings,
    AppSettings? storageSettings,
    DateTime? lastBackupTime,
    AppSettings? memorySettings,
    AppSettings? aiAgentSettings,
    AppSettings? editorSettings,
    bool? chapterSortDescending,
    AppSettings? readingSettings,
    AppSettings? localProfile,
    bool? checkForUpdates,
    int? updateCheckIntervalHours,
    DateTime? lastUpdateCheckTime,
    AppSettings? debugSettings,
  }) async {
    final database = ref.read(appSettingsDatabaseProvider);
    if (appearanceSettings != null) {
      await _persistSettingsAggregate(
        database,
        key: _appearanceSettingsKey,
        value: _appearanceSettingsDataFromAppSettings(
          appearanceSettings,
        ).encode(),
      );
    }
    if (storageSettings != null) {
      await _persistSettingsAggregate(
        database,
        key: _storageSettingsKey,
        value: _storageSettingsDataFromAppSettings(storageSettings).encode(),
      );
    }
    if (memorySettings != null) {
      await _persistSettingsAggregate(
        database,
        key: _memorySettingsKey,
        value: _memorySettingsDataFromAppSettings(memorySettings).encode(),
      );
    }
    if (aiAgentSettings != null) {
      await _persistSettingsAggregate(
        database,
        key: _aiAgentSettingsKey,
        value: _aiAgentSettingsDataFromAppSettings(aiAgentSettings).encode(),
      );
    }
    if (editorSettings != null) {
      await _persistSettingsAggregate(
        database,
        key: _editorSettingsKey,
        value: _editorSettingsDataFromAppSettings(editorSettings).encode(),
      );
    }
    if (readingSettings != null) {
      await _persistSettingsAggregate(
        database,
        key: _readingSettingsKey,
        value: _readingSettingsDataFromAppSettings(readingSettings).encode(),
      );
    }
    if (localProfile != null) {
      await _persistSettingsAggregate(
        database,
        key: _localProfileKey,
        value: _localProfileDataFromAppSettings(localProfile).encode(),
      );
    }
    if (debugSettings != null) {
      await _persistSettingsAggregate(
        database,
        key: _debugSettingsKey,
        value: _debugSettingsDataFromAppSettings(debugSettings).encode(),
      );
    }
    if (language != null) {
      await database.appSettingsDao.set(key: _languageKey, value: language);
    }
    if (aiSettings != null) {
      await database.appSettingsDao.set(
        key: _aiSettingsKey,
        value: jsonEncode(aiSettings.toJson()),
      );
    }
    if (aiProviders != null) {
      await database.aiProviderDao.saveAll(aiProviders);
    }
    if (searchEngine != null) {
      await database.appSettingsDao.set(
        key: _searchEngineKey,
        value: _searchEngineToString(searchEngine),
      );
    }
    if (lastBackupTime != null) {
      await database.appSettingsDao.set(
        key: _lastBackupTimeKey,
        value: lastBackupTime.toIso8601String(),
      );
    }
    if (chapterSortDescending != null) {
      await database.appSettingsDao.set(
        key: _chapterSortDescendingKey,
        value: chapterSortDescending ? 'true' : 'false',
      );
    }
    if (checkForUpdates != null) {
      await database.appSettingsDao.set(
        key: _checkForUpdatesKey,
        value: checkForUpdates ? 'true' : 'false',
      );
    }
    if (updateCheckIntervalHours != null) {
      await database.appSettingsDao.set(
        key: _updateCheckIntervalKey,
        value: updateCheckIntervalHours.toString(),
      );
    }
    if (lastUpdateCheckTime != null) {
      await database.appSettingsDao.set(
        key: _lastUpdateCheckTimeKey,
        value: lastUpdateCheckTime.toIso8601String(),
      );
    }
  }

  Future<AppSettings> _requireCurrentState(String source) async {
    final currentState = state.value;
    if (currentState != null) {
      return currentState;
    }

    return future;
  }

  FormFieldsController<AppSettingsFormField> createSettingsForm(
    AppSettings settings,
  ) {
    return FormFieldsController<AppSettingsFormField>(
      GlobalKey<FormState>(debugLabel: 'AppSettingsForm'),
      initialValues: _appSettingsFormValues(settings),
    );
  }

  FormFieldsController<AiProviderFormField> createAiProviderForm(
    AiProvider config,
  ) {
    return FormFieldsController<AiProviderFormField>(
      GlobalKey<FormState>(debugLabel: 'AiProviderForm:${config.id}'),
      initialValues: _aiProviderFormValues(config),
    );
  }

  Future<bool> saveSettingsForm(
    FormFieldsController<AppSettingsFormField> form,
  ) async {
    if (!form.validate()) {
      return false;
    }

    final currentState = await _requireCurrentState('SAVE_SETTINGS_FORM');
    final nextTheme =
        form.getValue<AppTheme>(AppSettingsFormField.theme) ??
        currentState.theme;
    final nextLanguage =
        (form.getValue<String>(AppSettingsFormField.language) ??
                currentState.language)
            .trim();

    final nextState = currentState.copyWith(
      theme: nextTheme,
      customTheme: nextTheme == currentState.theme
          ? currentState.customTheme
          : null,
      language: nextLanguage,
    );

    state = AsyncValue.data(nextState);
    await _persistPartial(
      appearanceSettings: nextState,
      language: nextLanguage,
    );
    return true;
  }

  Future<bool> saveAiProviderForm(
    String providerId,
    FormFieldsController<AiProviderFormField> form,
  ) async {
    if (!form.validate()) {
      return false;
    }

    final currentState = await _requireCurrentState('SAVE_AI_PROVIDER_FORM');
    final currentConfig = currentState.aiSettings.findConfigById(providerId);
    if (currentConfig == null) {
      return false;
    }

    final nextModels =
        (form.getValue<List<String>>(AiProviderFormField.models) ??
                currentConfig.availableModels)
            .map((model) => model.trim())
            .where((model) => model.isNotEmpty)
            .toList();

    final nextConfig = currentConfig.copyWith(
      name:
          (form.getValue<String>(AiProviderFormField.name) ??
                  currentConfig.name)
              .trim(),
      type:
          form.getValue<String>(AiProviderFormField.type) ?? currentConfig.type,
      enabled:
          form.getValue<bool>(AiProviderFormField.enabled) ??
          currentConfig.enabled,
      apiKey:
          (form.getValue<String>(AiProviderFormField.apiKey) ??
                  currentConfig.apiKey)
              .trim(),
      baseUrl:
          (form.getValue<String>(AiProviderFormField.baseUrl) ??
                  currentConfig.baseUrl)
              .trim(),
      models: nextModels,
      temperature:
          form.getValue<double>(AiProviderFormField.temperature) ??
          currentConfig.temperature,
      maxTurns:
          form.getValue<int>(AiProviderFormField.maxTurns) ??
          currentConfig.maxTurns,
      reasoningEffort: Value<String?>(
        form.getValue<String>(AiProviderFormField.reasoningEffort) ??
            currentConfig.reasoningEffort,
      ),
      proxyUrl:
          form.getValue<String>(AiProviderFormField.proxyUrl) ??
          currentConfig.proxyUrl,
      proxyUsername:
          form.getValue<String>(AiProviderFormField.proxyUsername) ??
          currentConfig.proxyUsername,
      proxyPassword:
          form.getValue<String>(AiProviderFormField.proxyPassword) ??
          currentConfig.proxyPassword,
    );

    if (nextConfig.enabled) {
      if (!nextConfig.hasApiKey) {
        form.setError(
          AiProviderFormField.apiKey,
          tr(LocaleKeys.settingsValidationApiKeyRequired),
        );
      }
      if (!nextConfig.hasBaseUrl) {
        form.setError(
          AiProviderFormField.baseUrl,
          tr(LocaleKeys.settingsValidationBaseUrlRequired),
        );
      }
      if (!nextConfig.hasModels) {
        form.setError(
          AiProviderFormField.models,
          tr(LocaleKeys.settingsValidationModelsRequired),
        );
      }
      if (nextConfig.enableValidationMessage != null) {
        return false;
      }
    }

    await setAiProviderConfig(nextConfig);
    return true;
  }

  AppTheme _parseTheme(String? value) {
    return switch (value) {
      'reveric' => AppTheme.reveric,
      'ivory' => AppTheme.ivory,
      _ => AppTheme.classic,
    };
  }

  AppThemeMode _parseThemeMode(String? value) {
    return switch (value) {
      'dark' => AppThemeMode.dark,
      'system' => AppThemeMode.system,
      _ => AppThemeMode.light,
    };
  }

  SearchEngine _parseSearchEngine(String? value) {
    return switch (value) {
      'duckduckgo' => SearchEngine.duckduckgo,
      _ => SearchEngine.duckduckgo,
    };
  }

  String _searchEngineToString(SearchEngine engine) {
    return switch (engine) {
      SearchEngine.duckduckgo => 'duckduckgo',
    };
  }

  BackupFrequency _parseBackupFrequency(String? value) {
    return switch (value) {
      'daily' => BackupFrequency.daily,
      'weekly' => BackupFrequency.weekly,
      'monthly' => BackupFrequency.monthly,
      _ => BackupFrequency.manual,
    };
  }

  AppBackgroundFit _parseAppBackgroundFit(String? value) {
    return switch (value) {
      'contain' => AppBackgroundFit.contain,
      'fill' => AppBackgroundFit.fill,
      _ => AppBackgroundFit.cover,
    };
  }

  EditorLineStyle _parseEditorLineStyle(String? value) {
    return switch (value) {
      'sparseDashed' => EditorLineStyle.sparseDashed,
      'denseDashed' => EditorLineStyle.denseDashed,
      _ => EditorLineStyle.solid,
    };
  }

  EditorParagraphSpacing _parseEditorParagraphSpacing(String? value) {
    return switch (value) {
      'none' => EditorParagraphSpacing.none,
      'one_blank_line' => EditorParagraphSpacing.one_blank_line,
      _ => AppSettings.defaultEditorFormatParagraphSpacing,
    };
  }

  ReadingBackgroundTheme _parseReadingBackgroundTheme(String? value) {
    return switch (value) {
      'sepia' => ReadingBackgroundTheme.sepia,
      'cream' => ReadingBackgroundTheme.cream,
      'eye_care' => ReadingBackgroundTheme.eye_care,
      'dark' => ReadingBackgroundTheme.dark,
      'night' => ReadingBackgroundTheme.night,
      _ => AppSettings.defaultReadingBackgroundTheme,
    };
  }

  ReadingPageTransition _parseReadingPageTransition(String? value) {
    return switch (value) {
      'horizontal' => ReadingPageTransition.horizontal,
      'fade' => ReadingPageTransition.fade,
      _ => AppSettings.defaultReadingPageTransition,
    };
  }

  DesktopReadingMode _parseDesktopReadingMode(String? value) {
    return switch (value) {
      'continuous_scroll' => DesktopReadingMode.continuous_scroll,
      _ => AppSettings.defaultDesktopReadingMode,
    };
  }

  MobileReadingMode _parseMobileReadingMode(String? value) {
    return switch (value) {
      'horizontal' || 'horizontal_page' => MobileReadingMode.horizontal_page,
      _ => AppSettings.defaultMobileReadingMode,
    };
  }

  Future<void> _themeCommandTail = Future<void>.value();

  Future<T> _withThemeChange<T>(Future<T> Function() action) {
    final operation = _themeCommandTail.then((_) => action());
    _themeCommandTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<Map<String, dynamic>> runThemeCommand(Map<String, dynamic> command) =>
      _withThemeChange(() => _runThemeCommand(command));

  Future<Map<String, dynamic>> _runThemeCommand(
    Map<String, dynamic> command,
  ) async {
    await _requireCurrentState('THEMES');
    final database = ref.read(appSettingsDatabaseProvider);
    final result = await ThemesOrchestrator().run(database, command);
    if (result['ok'] == true && !{'list', 'read'}.contains(command['action'])) {
      final appearance = await ThemesOrchestrator.readAppearance(database);
      final custom = appearance.customThemeId == null
          ? null
          : await ThemesOrchestrator.readCustomTheme(
              database,
              appearance.customThemeId!,
            );
      if (ref.mounted) {
        final current = state.requireValue;
        state = AsyncValue.data(
          current.copyWith(
            theme: _parseTheme(appearance.theme),
            themeMode: _parseThemeMode(appearance.themeMode),
            customTheme: custom,
          ),
        );
      }
    }
    return result;
  }

  Future<void> setTheme(AppTheme theme) async {
    final result = await runThemeCommand({
      'action': 'apply',
      'id': 'builtin:${theme.name}',
    });
    if (result['ok'] != true) {
      throw StateError('Unable to apply theme.');
    }
  }

  Future<void> setThemeMode(AppThemeMode themeMode) =>
      _withThemeChange(() async {
        final currentState = await _requireCurrentState('SET_THEME_MODE');
        if (currentState.themeMode == themeMode) {
          return;
        }

        final nextState = currentState.copyWith(themeMode: themeMode);
        await _persistPartial(appearanceSettings: nextState);
        if (ref.mounted) {
          state = AsyncValue.data(
            state.requireValue.copyWith(themeMode: themeMode),
          );
        }
      });

  Future<void> setUiTextScale(double scale) async {
    final currentState = await _requireCurrentState('SET_UI_TEXT_SCALE');
    final nextScale = scale.clamp(0.5, 2.0).toDouble();
    if (currentState.uiTextScale == nextScale) {
      return;
    }

    final nextState = currentState.copyWith(uiTextScale: nextScale);
    await _persistPartial(appearanceSettings: nextState);
    if (ref.mounted) {
      state = AsyncValue.data(nextState);
    }
  }

  Future<void> setLanguage(String language) async {
    final currentState = await _requireCurrentState('SET_LANGUAGE');
    if (currentState.language == language) {
      return;
    }

    final previousDefaultFont = AppSettings.defaultFontFamilyForLanguage(
      currentState.language,
    );
    final nextDefaultFont = AppSettings.defaultFontFamilyForLanguage(language);
    final updateEditorFont =
        currentState.editorFontFamily == previousDefaultFont;
    final updateReadingFont =
        currentState.readingFontFamily == previousDefaultFont;
    final nextState = currentState.copyWith(
      language: language,
      editorFontFamily: updateEditorFont ? nextDefaultFont : null,
      readingFontFamily: updateReadingFont ? nextDefaultFont : null,
    );
    state = AsyncValue.data(nextState);
    await _persistPartial(
      language: language,
      editorSettings: updateEditorFont ? nextState : null,
      readingSettings: updateReadingFont ? nextState : null,
    );
  }

  Future<void> setSearchEngine(SearchEngine searchEngine) async {
    final currentState = await _requireCurrentState('SET_SEARCH_ENGINE');
    if (currentState.searchEngine == searchEngine) return;

    final nextState = currentState.copyWith(searchEngine: searchEngine);
    state = AsyncValue.data(nextState);
    await _persistPartial(searchEngine: searchEngine);
  }

  Future<void> _setAiSettings(
    AppSettings currentState,
    AiSettings newAiSettings, {
    bool persistProviders = false,
    bool publishState = true,
  }) async {
    final nextState = currentState.copyWith(aiSettings: newAiSettings);

    if (publishState) {
      state = AsyncValue.data(nextState);
    }
    await _persistPartial(
      aiProviders: persistProviders
          ? newAiSettings.providers
                .where((provider) => !isDebugAiProviderId(provider.id))
                .toList()
          : null,
      aiSettings: newAiSettings.copyWith(providers: const []),
    );
  }

  Future<void> setAiProviderConfig(AiProvider config) async {
    final currentState = await _requireCurrentState('SET_AI_PROVIDER_CONFIG');

    final newAiSettings = currentState.aiSettings.updateConfig(config);
    await _setAiSettings(currentState, newAiSettings, persistProviders: true);
  }

  Future<void> toggleAiProviderEnabled(String providerId, bool enabled) async {
    final currentState = await _requireCurrentState('TOGGLE_AI_PROVIDER');
    final currentConfig = currentState.aiSettings.findConfigById(providerId);
    if (enabled && currentConfig?.enableValidationMessage != null) {
      return;
    }
    if (currentConfig == null || currentConfig.enabled == enabled) {
      return;
    }
    await setAiProviderConfig(currentConfig.copyWith(enabled: enabled));
    return;
  }

  Future<void> setDefaultAiModelForKind(
    AiModelKind kind,
    String? optionId,
  ) async {
    final currentState = await _requireCurrentState(
      'SET_DEFAULT_AI_MODEL_KIND',
    );
    final newAiSettings = currentState.aiSettings.setDefaultOptionId(
      kind,
      optionId,
    );
    await _setAiSettings(currentState, newAiSettings);
  }

  Future<void> setDefaultChatModelWithEffort(
    AiModelOption option,
    String effort,
  ) async {
    final currentState = await _requireCurrentState(
      'SET_DEFAULT_CHAT_MODEL_EFFORT',
    );
    final availableOption = currentState.aiSettings.findModelOptionById(
      kind: AiModelKind.chat,
      optionId: option.id,
    );
    if (availableOption == null ||
        availableOption.reasoningEfforts?.contains(effort) != true) {
      throw ArgumentError.value(
        effort,
        'effort',
        'Unsupported reasoning effort for chat model ${option.id}',
      );
    }
    final newAiSettings = currentState.aiSettings.copyWith(
      defaultChatModelId: availableOption.id,
      defaultChatReasoningEffort: effort,
    );
    await _setAiSettings(currentState, newAiSettings);
  }

  Future<void> setDefaultAiModelForRole(
    AiModelRole role,
    String? optionId,
  ) async {
    final currentState = await _requireCurrentState(
      'SET_DEFAULT_AI_MODEL_ROLE',
    );
    final newAiSettings = currentState.aiSettings.setDefaultOptionIdForRole(
      role,
      optionId,
    );
    await _setAiSettings(currentState, newAiSettings);
  }

  Future<String> addCustomProvider(AiProvider config) async {
    final currentState = await _requireCurrentState('ADD_CUSTOM_PROVIDER');
    final newAiSettings = currentState.aiSettings.addCustomConfig(config);
    await _setAiSettings(currentState, newAiSettings, persistProviders: true);
    return config.id;
  }

  Future<void> removeProvider(String id) async {
    final currentState = await _requireCurrentState('REMOVE_PROVIDER');
    final config = currentState.aiSettings.findConfigById(id);
    if (config == null || !config.canDelete) {
      return;
    }
    final database = ref.read(appSettingsDatabaseProvider);
    final newAiSettings = currentState.aiSettings.removeConfig(id);
    try {
      await database.transaction(() async {
        await database.aiProviderDao.softDelete(id);
        await _setAiSettings(currentState, newAiSettings, publishState: false);
      });
    } catch (error, stackTrace) {
      _log.error(
        '[DB] ai_providers/app_settings UPDATE removeProvider id=$id failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
    state = AsyncValue.data(currentState.copyWith(aiSettings: newAiSettings));
  }

  // ---- Storage setters ----

  Future<void> setChangeRecordRetentionDays(int days) async {
    final currentState = await _requireCurrentState(
      'SET_CHANGE_RECORD_RETENTION_DAYS',
    );
    final clamped = days.clamp(7, 365);
    if (currentState.changeRecordRetentionDays == clamped) return;
    final nextState = currentState.copyWith(changeRecordRetentionDays: clamped);
    state = AsyncValue.data(nextState);
    await _persistPartial(storageSettings: nextState);
  }

  // ---- Backup setters ----

  Future<void> setBackupDirectory(String directory) async {
    final currentState = await _requireCurrentState('SET_BACKUP_DIRECTORY');
    if (currentState.backupDirectory == directory) return;
    final nextState = currentState.copyWith(backupDirectory: directory);
    state = AsyncValue.data(nextState);
    await _persistPartial(storageSettings: nextState);
  }

  Future<void> setWebDavBackupConfig(WebDavBackupConfig config) async {
    final normalized = config.normalized();
    final issue = normalized.validate();
    if (issue != null) {
      throw ArgumentError.value(config, 'config', issue.name);
    }
    final currentState = await _requireCurrentState('SET_WEBDAV_BACKUP_CONFIG');
    final nextState = currentState.copyWith(webDavBackupConfig: normalized);
    state = AsyncValue.data(nextState);
    await _persistPartial(storageSettings: nextState);
  }

  Future<void> setBackupFrequency(BackupFrequency frequency) async {
    final currentState = await _requireCurrentState('SET_BACKUP_FREQUENCY');
    if (currentState.backupFrequency == frequency) return;
    final nextState = currentState.copyWith(backupFrequency: frequency);
    state = AsyncValue.data(nextState);
    await _persistPartial(storageSettings: nextState);
  }

  Future<void> setBackupWeekdays(Iterable<int> weekdays) async {
    final currentState = await _requireCurrentState('SET_BACKUP_WEEKDAYS');
    final normalized = _normalizeBackupWeekdays(weekdays);
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        weekdays,
        'weekdays',
        'At least one backup weekday is required.',
      );
    }
    if (listEquals(currentState.backupWeekdays, normalized)) {
      return;
    }
    final nextState = currentState.copyWith(backupWeekdays: normalized);
    state = AsyncValue.data(nextState);
    await _persistPartial(storageSettings: nextState);
  }

  Future<void> setBackupDayOfMonth(int day) async {
    final currentState = await _requireCurrentState('SET_BACKUP_DAY_OF_MONTH');
    final clamped = day.clamp(1, 28);
    if (currentState.backupDayOfMonth == clamped) {
      return;
    }
    final nextState = currentState.copyWith(backupDayOfMonth: clamped);
    state = AsyncValue.data(nextState);
    await _persistPartial(storageSettings: nextState);
  }

  Future<void> setBackupTime({required int hour, required int minute}) async {
    final currentState = await _requireCurrentState('SET_BACKUP_TIME');
    final clampedHour = hour.clamp(0, 23);
    final clampedMinute = minute.clamp(0, 59);
    if (currentState.backupHour == clampedHour &&
        currentState.backupMinute == clampedMinute) {
      return;
    }
    final nextState = currentState.copyWith(
      backupHour: clampedHour,
      backupMinute: clampedMinute,
    );
    state = AsyncValue.data(nextState);
    await _persistPartial(storageSettings: nextState);
  }

  Future<void> setLastBackupTime(DateTime time) async {
    final currentState = await _requireCurrentState('SET_LAST_BACKUP_TIME');
    final nextState = currentState.copyWith(lastBackupTime: time);
    state = AsyncValue.data(nextState);
    await _persistPartial(lastBackupTime: time);
  }

  // ---- Memory setters ----

  Future<void> setMemoryAutoExtract(bool value) async {
    final currentState = await _requireCurrentState('SET_MEMORY_AUTO_EXTRACT');
    if (currentState.memoryAutoExtract == value) return;
    final nextState = currentState.copyWith(memoryAutoExtract: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(memorySettings: nextState);
  }

  Future<void> setMemoryExtractionIntervalMinutes(int value) async {
    final currentState = await _requireCurrentState(
      'SET_MEMORY_EXTRACT_INTERVAL',
    );
    if (currentState.memoryExtractionIntervalMinutes == value) return;
    final nextState = currentState.copyWith(
      memoryExtractionIntervalMinutes: value,
    );
    state = AsyncValue.data(nextState);
    await _persistPartial(memorySettings: nextState);
  }

  Future<void> setAiAgentIdentity(String value) async {
    final currentState = await _requireCurrentState('SET_AI_AGENT_IDENTITY');
    if (currentState.aiAgentIdentity == value) {
      return;
    }
    final nextState = currentState.copyWith(aiAgentIdentity: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(aiAgentSettings: nextState);
  }

  Future<void> setAiAgentSoul(String value) async {
    final currentState = await _requireCurrentState('SET_AI_AGENT_SOUL');
    if (currentState.aiAgentSoul == value) {
      return;
    }
    final nextState = currentState.copyWith(aiAgentSoul: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(aiAgentSettings: nextState);
  }

  Future<void> setAiAgentAvatarPath(String value) async {
    final currentState = await _requireCurrentState('SET_AI_AGENT_AVATAR');
    if (currentState.aiAgentAvatarPath == value) {
      return;
    }
    final nextState = currentState.copyWith(aiAgentAvatarPath: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(aiAgentSettings: nextState);
  }

  Future<void> setAiAgentNextActionSuggestions(bool value) async {
    final currentState = await _requireCurrentState(
      'SET_AI_AGENT_NEXT_ACTION_SUGGESTIONS',
    );
    if (currentState.aiAgentNextActionSuggestions == value) {
      return;
    }
    final nextState = currentState.copyWith(
      aiAgentNextActionSuggestions: value,
    );
    state = AsyncValue.data(nextState);
    await _persistPartial(aiAgentSettings: nextState);
  }

  Future<void> setEditorFontFamily(String fontFamily) async {
    final currentState = await _requireCurrentState('SET_EDITOR_FONT_FAMILY');
    if (currentState.editorFontFamily == fontFamily) return;
    final nextState = currentState.copyWith(editorFontFamily: fontFamily);
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  Future<void> setEditorFontSize(int fontSize) async {
    final currentState = await _requireCurrentState('SET_EDITOR_FONT_SIZE');
    if (currentState.editorFontSize == fontSize) return;
    final nextState = currentState.copyWith(editorFontSize: fontSize);
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  Future<void> setEditorFontColorHex(String value) async {
    final text = value.trim();
    final match = RegExp(
      r'^#?([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$',
    ).firstMatch(text);
    if (text.isNotEmpty && match == null) {
      throw const FormatException('Invalid editor font color');
    }
    final normalized = text.isEmpty ? '' : '#${match!.group(1)!.toUpperCase()}';
    final currentState = await _requireCurrentState('SET_EDITOR_FONT_COLOR');
    if (currentState.editorFontColorHex == normalized) {
      return;
    }
    final nextState = currentState.copyWith(editorFontColorHex: normalized);
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  Future<void> setEditorLetterSpacing(double letterSpacing) async {
    final currentState = await _requireCurrentState(
      'SET_EDITOR_LETTER_SPACING',
    );
    final clamped = letterSpacing.clamp(0, 4).toDouble();
    if (currentState.editorLetterSpacing == clamped) {
      return;
    }
    final nextState = currentState.copyWith(editorLetterSpacing: clamped);
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  Future<void> setEditorLineHeight(double lineHeight) async {
    final currentState = await _requireCurrentState('SET_EDITOR_LINE_HEIGHT');
    final clamped = lineHeight.clamp(1.2, 2.4).toDouble();
    if (currentState.editorLineHeight == clamped) {
      return;
    }
    final nextState = currentState.copyWith(editorLineHeight: clamped);
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  Future<void> setEditorMinimapEnabled(bool value) async {
    final currentState = await _requireCurrentState(
      'SET_EDITOR_MINIMAP_ENABLED',
    );
    if (currentState.editorMinimapEnabled == value) {
      return;
    }
    final nextState = currentState.copyWith(editorMinimapEnabled: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  Future<void> setEditorLineNumbersEnabled(bool value) async {
    final currentState = await _requireCurrentState(
      'SET_EDITOR_LINE_NUMBERS_ENABLED',
    );
    if (currentState.editorLineNumbersEnabled == value) {
      return;
    }
    final nextState = currentState.copyWith(editorLineNumbersEnabled: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  Future<void> resetEditorTypography() async {
    final currentState = await _requireCurrentState('RESET_EDITOR_TYPOGRAPHY');
    final defaultFontFamily = AppSettings.defaultFontFamilyForLanguage(
      currentState.language,
    );
    if (currentState.editorFontFamily == defaultFontFamily &&
        currentState.editorFontSize == AppSettings.defaultEditorFontSize &&
        currentState.editorFontColorHex.isEmpty &&
        currentState.editorLetterSpacing ==
            AppSettings.defaultEditorLetterSpacing &&
        currentState.editorLineHeight == AppSettings.defaultEditorLineHeight) {
      return;
    }

    final nextState = currentState.copyWith(
      editorFontFamily: defaultFontFamily,
      editorFontSize: AppSettings.defaultEditorFontSize,
      editorFontColorHex: '',
      editorLetterSpacing: AppSettings.defaultEditorLetterSpacing,
      editorLineHeight: AppSettings.defaultEditorLineHeight,
    );
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  Future<void> setChapterSortDescending(bool value) async {
    final currentState = await _requireCurrentState(
      'SET_CHAPTER_SORT_DESCENDING',
    );
    if (currentState.chapterSortDescending == value) return;
    final nextState = currentState.copyWith(chapterSortDescending: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(chapterSortDescending: value);
  }

  Future<void> setEditorLineEnabled(bool value) async {
    final currentState = await _requireCurrentState('SET_EDITOR_LINE_ENABLED');
    if (currentState.editorLineEnabled == value) return;
    final nextState = currentState.copyWith(editorLineEnabled: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  Future<void> setEditorLineStyle(EditorLineStyle value) async {
    final currentState = await _requireCurrentState('SET_EDITOR_LINE_STYLE');
    if (currentState.editorLineStyle == value) return;
    final nextState = currentState.copyWith(editorLineStyle: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  Future<void> setEditorLineColorHex(String value) async {
    final currentState = await _requireCurrentState('SET_EDITOR_LINE_COLOR');
    if (currentState.editorLineColorHex == value) return;
    final nextState = currentState.copyWith(editorLineColorHex: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  Future<void> setEditorEntityRecognitionEnabled(bool value) async {
    final currentState = await _requireCurrentState(
      'SET_EDITOR_ENTITY_RECOGNITION_ENABLED',
    );
    if (currentState.editorEntityRecognitionEnabled == value) {
      return;
    }
    final nextState = currentState.copyWith(
      editorEntityRecognitionEnabled: value,
    );
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  Future<void> setEditorEntityItalic(bool value) async {
    final currentState = await _requireCurrentState('SET_EDITOR_ENTITY_ITALIC');
    if (currentState.editorEntityItalic == value) {
      return;
    }
    final nextState = currentState.copyWith(editorEntityItalic: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  Future<void> setEditorEntityHighlight(bool value) async {
    final currentState = await _requireCurrentState(
      'SET_EDITOR_ENTITY_HIGHLIGHT',
    );
    if (currentState.editorEntityHighlight == value) {
      return;
    }
    final nextState = currentState.copyWith(editorEntityHighlight: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  Future<void> setEditorEntityHighlightColorHex(String value) async {
    final currentState = await _requireCurrentState(
      'SET_EDITOR_ENTITY_HIGHLIGHT_COLOR',
    );
    if (currentState.editorEntityHighlightColorHex == value) {
      return;
    }
    final nextState = currentState.copyWith(
      editorEntityHighlightColorHex: value,
    );
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  Future<void> setEditorEntityTextColorHex(String value) async {
    final currentState = await _requireCurrentState(
      'SET_EDITOR_ENTITY_TEXT_COLOR',
    );
    if (currentState.editorEntityTextColorHex == value) {
      return;
    }
    final nextState = currentState.copyWith(editorEntityTextColorHex: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  Future<void> setEditorEntityUnderline(bool value) async {
    final currentState = await _requireCurrentState(
      'SET_EDITOR_ENTITY_UNDERLINE',
    );
    if (currentState.editorEntityUnderline == value) {
      return;
    }
    final nextState = currentState.copyWith(editorEntityUnderline: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  Future<void> setEditorEntityBold(bool value) async {
    final currentState = await _requireCurrentState('SET_EDITOR_ENTITY_BOLD');
    if (currentState.editorEntityBold == value) {
      return;
    }
    final nextState = currentState.copyWith(editorEntityBold: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  Future<void> setEditorFormatIndentCount(int value) async {
    final currentState = await _requireCurrentState(
      'SET_EDITOR_FORMAT_INDENT_COUNT',
    );
    final clamped = value.clamp(0, 8);
    if (currentState.editorFormatIndentCount == clamped) {
      return;
    }
    final nextState = currentState.copyWith(editorFormatIndentCount: clamped);
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  Future<void> setEditorFormatParagraphSpacing(
    EditorParagraphSpacing value,
  ) async {
    final currentState = await _requireCurrentState(
      'SET_EDITOR_FORMAT_PARAGRAPH_SPACING',
    );
    if (currentState.editorFormatParagraphSpacing == value) {
      return;
    }
    final nextState = currentState.copyWith(
      editorFormatParagraphSpacing: value,
    );
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  Future<void> setEditorFormatAllowSpaces(bool value) async {
    final currentState = await _requireCurrentState(
      'SET_EDITOR_FORMAT_ALLOW_SPACES',
    );
    if (currentState.editorFormatAllowSpaces == value) {
      return;
    }
    final nextState = currentState.copyWith(editorFormatAllowSpaces: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(editorSettings: nextState);
  }

  // ---- Reading setters ----

  Future<void> setReadingFontFamily(String fontFamily) async {
    final currentState = await _requireCurrentState('SET_READING_FONT_FAMILY');
    if (currentState.readingFontFamily == fontFamily) return;
    final nextState = currentState.copyWith(readingFontFamily: fontFamily);
    state = AsyncValue.data(nextState);
    await _persistPartial(readingSettings: nextState);
  }

  Future<void> setReadingFontSize(int fontSize) async {
    final currentState = await _requireCurrentState('SET_READING_FONT_SIZE');
    final clamped = fontSize.clamp(12, 36);
    if (currentState.readingFontSize == clamped) return;
    final nextState = currentState.copyWith(readingFontSize: clamped);
    state = AsyncValue.data(nextState);
    await _persistPartial(readingSettings: nextState);
  }

  Future<void> setReadingLetterSpacing(double letterSpacing) async {
    final currentState = await _requireCurrentState(
      'SET_READING_LETTER_SPACING',
    );
    final clamped = letterSpacing.clamp(-1, 4).toDouble();
    if (currentState.readingLetterSpacing == clamped) return;
    final nextState = currentState.copyWith(readingLetterSpacing: clamped);
    state = AsyncValue.data(nextState);
    await _persistPartial(readingSettings: nextState);
  }

  Future<void> setReadingLineHeight(double lineHeight) async {
    final currentState = await _requireCurrentState('SET_READING_LINE_HEIGHT');
    final clamped = lineHeight.clamp(1.2, 2.8).toDouble();
    if (currentState.readingLineHeight == clamped) return;
    final nextState = currentState.copyWith(readingLineHeight: clamped);
    state = AsyncValue.data(nextState);
    await _persistPartial(readingSettings: nextState);
  }

  Future<void> setReadingParagraphSpacing(double spacing) async {
    final currentState = await _requireCurrentState(
      'SET_READING_PARAGRAPH_SPACING',
    );
    final clamped = spacing.clamp(0.5, 3.0).toDouble();
    if (currentState.readingParagraphSpacing == clamped) return;
    final nextState = currentState.copyWith(readingParagraphSpacing: clamped);
    state = AsyncValue.data(nextState);
    await _persistPartial(readingSettings: nextState);
  }

  Future<void> setReadingMargin(double margin) async {
    final currentState = await _requireCurrentState('SET_READING_MARGIN');
    final clamped = margin.clamp(8, 96).toDouble();
    if (currentState.readingMargin == clamped) return;
    final nextState = currentState.copyWith(readingMargin: clamped);
    state = AsyncValue.data(nextState);
    await _persistPartial(readingSettings: nextState);
  }

  Future<void> setReadingBackgroundTheme(ReadingBackgroundTheme theme) async {
    final currentState = await _requireCurrentState(
      'SET_READING_BACKGROUND_THEME',
    );
    if (currentState.readingBackgroundTheme == theme) return;
    final nextState = currentState.copyWith(readingBackgroundTheme: theme);
    state = AsyncValue.data(nextState);
    await _persistPartial(readingSettings: nextState);
  }

  Future<void> setReadingPageTransition(
    ReadingPageTransition transition,
  ) async {
    final currentState = await _requireCurrentState(
      'SET_READING_PAGE_TRANSITION',
    );
    if (currentState.readingPageTransition == transition) return;
    final nextState = currentState.copyWith(readingPageTransition: transition);
    state = AsyncValue.data(nextState);
    await _persistPartial(readingSettings: nextState);
  }

  Future<void> setDesktopReadingMode(DesktopReadingMode mode) async {
    final currentState = await _requireCurrentState('SET_DESKTOP_READING_MODE');
    if (currentState.desktopReadingMode == mode) {
      return;
    }
    final nextState = currentState.copyWith(desktopReadingMode: mode);
    state = AsyncValue.data(nextState);
    await _persistPartial(readingSettings: nextState);
  }

  Future<void> setMobileReadingMode(MobileReadingMode mode) async {
    final currentState = await _requireCurrentState('SET_MOBILE_READING_MODE');
    if (currentState.mobileReadingMode == mode) {
      return;
    }
    final nextState = currentState.copyWith(mobileReadingMode: mode);
    state = AsyncValue.data(nextState);
    await _persistPartial(readingSettings: nextState);
  }

  Future<void> setReadingBold(bool value) async {
    final currentState = await _requireCurrentState('SET_READING_BOLD');
    if (currentState.readingBold == value) return;
    final nextState = currentState.copyWith(readingBold: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(readingSettings: nextState);
  }

  Future<void> resetReadingTypography() async {
    final currentState = await _requireCurrentState('RESET_READING_TYPOGRAPHY');
    final defaultFontFamily = AppSettings.defaultFontFamilyForLanguage(
      currentState.language,
    );
    final nextState = currentState.copyWith(
      readingFontFamily: defaultFontFamily,
      readingFontSize: AppSettings.defaultReadingFontSize,
      readingLetterSpacing: AppSettings.defaultReadingLetterSpacing,
      readingLineHeight: AppSettings.defaultReadingLineHeight,
      readingParagraphSpacing: AppSettings.defaultReadingParagraphSpacing,
    );
    state = AsyncValue.data(nextState);
    await _persistPartial(readingSettings: nextState);
  }

  Future<void> setAppBackgroundImagePath(String path) =>
      _withThemeChange(() async {
        final currentState = await _requireCurrentState(
          'SET_APP_BACKGROUND_IMAGE_PATH',
        );
        if (currentState.appBackgroundImagePath == path &&
            currentState.appBackgroundTheme == null) {
          return;
        }
        final nextState = currentState.copyWith(
          appBackgroundImagePath: path,
          appBackgroundTheme: null,
        );
        await _persistPartial(appearanceSettings: nextState);
        if (ref.mounted) {
          state = AsyncValue.data(
            state.requireValue.copyWith(
              appBackgroundImagePath: path,
              appBackgroundTheme: null,
            ),
          );
        }
      });

  Future<void> setAppBackgroundFit(AppBackgroundFit fit) => _withThemeChange(
    () async {
      final currentState = await _requireCurrentState('SET_APP_BACKGROUND_FIT');
      if (currentState.appBackgroundFit == fit) {
        return;
      }
      final nextState = currentState.copyWith(appBackgroundFit: fit);
      await _persistPartial(appearanceSettings: nextState);
      if (ref.mounted) {
        state = AsyncValue.data(
          state.requireValue.copyWith(appBackgroundFit: fit),
        );
      }
    },
  );

  Future<void> setAppBackgroundTheme(AppTheme? theme) =>
      _withThemeChange(() async {
        final currentState = await _requireCurrentState(
          'SET_APP_BACKGROUND_THEME',
        );
        if (currentState.appBackgroundTheme == theme &&
            currentState.appBackgroundImagePath.isEmpty) {
          return;
        }
        final nextState = currentState.copyWith(
          appBackgroundImagePath: '',
          appBackgroundTheme: theme,
        );
        await _persistPartial(appearanceSettings: nextState);
        if (ref.mounted) {
          state = AsyncValue.data(
            state.requireValue.copyWith(
              appBackgroundImagePath: '',
              appBackgroundTheme: theme,
            ),
          );
        }
      });

  Future<void> setUsername(String username) async {
    final currentState = await _requireCurrentState('SET_USERNAME');
    if (currentState.username == username) return;
    final nextState = currentState.copyWith(username: username);
    state = AsyncValue.data(nextState);
    await _persistPartial(localProfile: nextState);
  }

  Future<void> setAvatarPath(String avatarPath) async {
    final currentState = await _requireCurrentState('SET_AVATAR_PATH');
    if (currentState.avatarPath == avatarPath) return;
    final nextState = currentState.copyWith(avatarPath: avatarPath);
    state = AsyncValue.data(nextState);
    await _persistPartial(localProfile: nextState);
  }

  /// Batch apply onboarding defaults — single state emission + persist.
  Future<void> applyOnboardingDefaults({
    required AppTheme theme,
    required AppThemeMode themeMode,
    Map<AiModelRole, String>? defaultModelsForRoles,
    Map<AiModelKind, String>? defaultModelsForKinds,
  }) async {
    final currentState = await _requireCurrentState(
      'APPLY_ONBOARDING_DEFAULTS',
    );

    var nextState = currentState.copyWith(
      theme: theme,
      customTheme: null,
      themeMode: themeMode,
    );
    var nextAiSettings = nextState.aiSettings;

    if (defaultModelsForRoles != null) {
      for (final entry in defaultModelsForRoles.entries) {
        nextAiSettings = nextAiSettings.setDefaultOptionIdForRole(
          entry.key,
          entry.value,
        );
      }
    }
    if (defaultModelsForKinds != null) {
      for (final entry in defaultModelsForKinds.entries) {
        nextAiSettings = nextAiSettings.setDefaultOptionId(
          entry.key,
          entry.value,
        );
      }
    }

    nextState = nextState.copyWith(aiSettings: nextAiSettings);
    state = AsyncValue.data(nextState);
    await _persistPartial(
      appearanceSettings: nextState,
      aiSettings: nextAiSettings.copyWith(providers: const []),
    );
  }

  Future<void> setNetworkProxy(NetworkProxy config) async {
    if (!config.isValid) {
      throw const FormatException('Invalid network proxy configuration');
    }
    await _requireCurrentState('SET_NETWORK_PROXY');
    await _persistSettingsAggregate(
      ref.read(appSettingsDatabaseProvider),
      key: NetworkProxy.settingsKey,
      value: config.encode(),
    );
    if (ref.mounted) {
      state = AsyncData(state.requireValue.copyWith(networkProxy: config));
    }
  }

  // ---- Update setters ----

  Future<void> setCheckForUpdates(bool value) async {
    final currentState = await _requireCurrentState('SET_CHECK_FOR_UPDATES');
    if (currentState.checkForUpdates == value) return;
    final nextState = currentState.copyWith(checkForUpdates: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(checkForUpdates: value);
  }

  Future<void> setUpdateCheckIntervalHours(int value) async {
    final currentState = await _requireCurrentState(
      'SET_UPDATE_CHECK_INTERVAL',
    );
    final clamped = value.clamp(1, 168);
    if (currentState.updateCheckIntervalHours == clamped) return;
    final nextState = currentState.copyWith(updateCheckIntervalHours: clamped);
    state = AsyncValue.data(nextState);
    await _persistPartial(updateCheckIntervalHours: clamped);
  }

  Future<void> setLastUpdateCheckTime(DateTime value) async {
    final currentState = await _requireCurrentState(
      'SET_LAST_UPDATE_CHECK_TIME',
    );
    final nextState = currentState.copyWith(lastUpdateCheckTime: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(lastUpdateCheckTime: value);
  }

  // ---- Debug setters ----

  Future<void> setDebugMode(bool value) async {
    final currentState = await _requireCurrentState('SET_DEBUG_MODE');
    if (currentState.debugMode == value) {
      return;
    }
    final nextState = currentState.copyWith(debugMode: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(debugSettings: nextState);
  }

  Future<void> setDebugPageUnlocked(bool value) async {
    final currentState = await _requireCurrentState('SET_DEBUG_PAGE_UNLOCKED');
    if (currentState.debugPageUnlocked == value) {
      return;
    }
    final nextState = currentState.copyWith(debugPageUnlocked: value);
    state = AsyncValue.data(nextState);
    await _persistPartial(debugSettings: nextState);
  }
}

final editorFontFamilyProvider = Provider<String>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.editorFontFamily,
    orElse: () => 'Georgia',
  );
});

final editorFontSizeProvider = Provider<int>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.editorFontSize,
    orElse: () => 16,
  );
});

final editorFontColorHexProvider = Provider<String>((ref) {
  return ref
          .watch(appSettingsNotifierProvider)
          .asData
          ?.value
          .editorFontColorHex ??
      '';
});

/// null 表示由渲染处使用当前主题正文色。
final editorFontColorProvider = Provider<Color?>((ref) {
  final hex = ref.watch(editorFontColorHexProvider);
  if (hex.isEmpty) {
    return null;
  }
  final value = hex.replaceFirst('#', '');
  return Color(int.parse(value.length == 6 ? 'FF$value' : value, radix: 16));
});

final editorLetterSpacingProvider = Provider<double>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.editorLetterSpacing,
    orElse: () => 0,
  );
});

final editorLineHeightProvider = Provider<double>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.editorLineHeight,
    orElse: () => 1.8,
  );
});

final editorMinimapEnabledProvider = Provider<bool>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.editorMinimapEnabled,
    orElse: () => false,
  );
});

final editorLineNumbersEnabledProvider = Provider<bool>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.editorLineNumbersEnabled,
    orElse: () => false,
  );
});

final editorLineEnabledProvider = Provider<bool>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.editorLineEnabled,
    orElse: () => false,
  );
});

final chapterSortDescendingProvider = Provider<bool>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.chapterSortDescending,
    orElse: () => false,
  );
});

final editorLineStyleProvider = Provider<EditorLineStyle>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.editorLineStyle,
    orElse: () => EditorLineStyle.solid,
  );
});

final editorLineColorHexProvider = Provider<String>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.editorLineColorHex,
    orElse: () => '#FFFF0000',
  );
});

final editorEntityRecognitionEnabledProvider = Provider<bool>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.editorEntityRecognitionEnabled,
    orElse: () => false,
  );
});

final editorEntityItalicProvider = Provider<bool>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.editorEntityItalic,
    orElse: () => false,
  );
});

final editorEntityHighlightProvider = Provider<bool>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.editorEntityHighlight,
    orElse: () => false,
  );
});

final editorEntityHighlightColorHexProvider = Provider<String>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.editorEntityHighlightColorHex,
    orElse: () => '#33FFD54F',
  );
});

final editorEntityTextColorHexProvider = Provider<String>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.editorEntityTextColorHex,
    orElse: () => '',
  );
});

final editorEntityUnderlineProvider = Provider<bool>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.editorEntityUnderline,
    orElse: () => false,
  );
});

final editorEntityBoldProvider = Provider<bool>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.editorEntityBold,
    orElse: () => false,
  );
});

final editorFormatIndentCountProvider = Provider<int>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.editorFormatIndentCount,
    orElse: () => AppSettings.defaultEditorFormatIndentCount,
  );
});

final editorFormatParagraphSpacingProvider = Provider<EditorParagraphSpacing>((
  ref,
) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.editorFormatParagraphSpacing,
    orElse: () => AppSettings.defaultEditorFormatParagraphSpacing,
  );
});

final editorFormatAllowSpacesProvider = Provider<bool>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.editorFormatAllowSpaces,
    orElse: () => AppSettings.defaultEditorFormatAllowSpaces,
  );
});

// ---- Reading convenience providers ----

final readingFontFamilyProvider = Provider<String>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.readingFontFamily,
    orElse: () => AppSettings.defaultReadingFontFamily,
  );
});

final readingFontSizeProvider = Provider<int>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.readingFontSize,
    orElse: () => AppSettings.defaultReadingFontSize,
  );
});

final readingLetterSpacingProvider = Provider<double>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.readingLetterSpacing,
    orElse: () => AppSettings.defaultReadingLetterSpacing,
  );
});

final readingLineHeightProvider = Provider<double>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.readingLineHeight,
    orElse: () => AppSettings.defaultReadingLineHeight,
  );
});

final readingParagraphSpacingProvider = Provider<double>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.readingParagraphSpacing,
    orElse: () => AppSettings.defaultReadingParagraphSpacing,
  );
});

final readingMarginProvider = Provider<double>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.readingMargin,
    orElse: () => AppSettings.defaultReadingMargin,
  );
});

final readingBackgroundThemeProvider = Provider<ReadingBackgroundTheme>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.readingBackgroundTheme,
    orElse: () => AppSettings.defaultReadingBackgroundTheme,
  );
});

final readingPageTransitionProvider = Provider<ReadingPageTransition>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.readingPageTransition,
    orElse: () => AppSettings.defaultReadingPageTransition,
  );
});

final desktopReadingModeProvider = Provider<DesktopReadingMode>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (settings) => settings.desktopReadingMode,
    orElse: () => AppSettings.defaultDesktopReadingMode,
  );
});

final mobileReadingModeProvider = Provider<MobileReadingMode>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (settings) => settings.mobileReadingMode,
    orElse: () => AppSettings.defaultMobileReadingMode,
  );
});

final readingBoldProvider = Provider<bool>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.readingBold,
    orElse: () => AppSettings.defaultReadingBold,
  );
});

final appBackgroundImagePathProvider = Provider<String>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.appBackgroundImagePath,
    orElse: () => '',
  );
});

final appBackgroundFitProvider = Provider<AppBackgroundFit>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.appBackgroundFit,
    orElse: () => AppBackgroundFit.cover,
  );
});

final appBackgroundThemeProvider = Provider<AppTheme?>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.appBackgroundTheme,
    orElse: () => null,
  );
});

@riverpod
RevericThemeData currentTheme(Ref ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.when(
    data: (settings) => settings.themeData,
    loading: () => RevericThemeData.classic,
    error: (_, _) => RevericThemeData.classic,
  );
}

@riverpod
RevericThemeData currentThemeForBrightness(Ref ref, Brightness brightness) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.when(
    data: (settings) => settings.themeDataForBrightness(brightness),
    loading: () => RevericThemeData.classic,
    error: (_, _) => RevericThemeData.classic,
  );
}

@riverpod
AppTheme currentThemeType(Ref ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.when(
    data: (settings) => settings.theme,
    loading: () => AppTheme.classic,
    error: (_, _) => AppTheme.classic,
  );
}

@riverpod
AppThemeMode currentThemeMode(Ref ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.when(
    data: (settings) => settings.themeMode,
    loading: () => AppThemeMode.light,
    error: (_, _) => AppThemeMode.light,
  );
}

@riverpod
double uiTextScale(Ref ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.when(
    data: (settings) => settings.uiTextScale,
    loading: () => 1.0,
    error: (_, _) => 1.0,
  );
}

@riverpod
AiSettings aiSettings(Ref ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.when(
    data: (settings) => settings.aiSettings,
    loading: AiSettings.defaults,
    error: (_, _) => AiSettings.defaults(),
  );
}

@riverpod
List<AiModelOption> availableAiModels(Ref ref) {
  final settings = ref.watch(aiSettingsProvider);
  return settings.availableModelOptions;
}

@riverpod
List<AiModelOption> availableAiModelOptionsByKind(Ref ref, AiModelKind kind) {
  final settings = ref.watch(aiSettingsProvider);
  return settings.availableModelOptionsForKind(kind);
}

@riverpod
String? defaultAiModelOptionId(Ref ref, AiModelKind kind) {
  final settings = ref.watch(aiSettingsProvider);
  return settings.defaultOptionIdForKind(kind);
}

@riverpod
String? defaultAiModelOptionIdForRole(Ref ref, AiModelRole role) {
  final settings = ref.watch(aiSettingsProvider);
  return settings.defaultOptionIdForRole(role);
}

@riverpod
String? resolvedAiModelOptionIdForRole(
  Ref ref, {
  required AiModelRole role,
  String? databasePath,
}) {
  // databasePath 已废弃：小说级 AI 模型设置已移除，统一使用全局设置。
  return ref.watch(aiSettingsProvider).defaultOptionIdForRole(role);
}

@riverpod
String? resolvedAiModelOptionIdForKind(
  Ref ref, {
  required AiModelKind kind,
  String? databasePath,
}) {
  // databasePath 已废弃：小说级 AI 模型设置已移除，统一使用全局设置。
  return ref.watch(aiSettingsProvider).defaultOptionIdForKind(kind);
}

@riverpod
AiProvider? currentAiConfig(Ref ref, {String? providerId, String? model}) {
  final settings = ref.watch(aiSettingsProvider);
  if (providerId != null) {
    return settings.findConfigForSelection(
      providerId: providerId,
      model: model,
    );
  }
  final options = ref.watch(
    availableAiModelOptionsByKindProvider(AiModelKind.chat),
  );
  if (options.isEmpty) {
    return null;
  }
  final defaultId = settings.defaultOptionIdForKind(AiModelKind.chat);
  final preferredOption = options.firstWhere(
    (option) => option.id == defaultId,
    orElse: () => options.first,
  );
  final preferred = settings.findConfigForSelection(
    providerId: preferredOption.providerId,
    model: preferredOption.model,
  );
  return preferred;
}

@riverpod
AiModelOption? resolvedAiModelOptionForRole(
  Ref ref, {
  required AiModelRole role,
  String? databasePath,
}) {
  final options = ref.watch(
    availableAiModelOptionsByKindProvider(AiModelKind.chat),
  );
  if (options.isEmpty) {
    return null;
  }
  final optionId = ref.watch(
    resolvedAiModelOptionIdForRoleProvider(role: role),
  );
  return resolveSelectableModelOption(
    options: options,
    preferredOptionId: optionId,
  );
}

@riverpod
AiModelOption? resolvedAiModelOptionForKind(
  Ref ref, {
  required AiModelKind kind,
  String? databasePath,
}) {
  final options = ref.watch(availableAiModelOptionsByKindProvider(kind));
  if (options.isEmpty) {
    return null;
  }
  final optionId = ref.watch(
    resolvedAiModelOptionIdForKindProvider(kind: kind),
  );
  return resolveSelectableModelOption(
    options: options,
    preferredOptionId: optionId,
  );
}

@riverpod
bool isAiConfigured(Ref ref) {
  final options = ref.watch(availableAiModelsProvider);
  return options.isNotEmpty;
}

@riverpod
SearchEngine currentSearchEngine(Ref ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.when(
    data: (settings) => settings.searchEngine,
    loading: () => SearchEngine.duckduckgo,
    error: (_, _) => SearchEngine.duckduckgo,
  );
}

final appSettingsNotifierProvider = appSettingsProvider;

// ---- Memory convenience providers ----

@riverpod
bool memoryAutoExtract(Ref ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.memoryAutoExtract,
    orElse: () => true,
  );
}

@riverpod
int memoryExtractionIntervalMinutes(Ref ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.memoryExtractionIntervalMinutes,
    orElse: () => 60,
  );
}

final appDebugModeProvider = Provider<bool>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(data: (s) => s.debugMode, orElse: () => false);
});

final appDebugPageUnlockedProvider = Provider<bool>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.debugPageUnlocked,
    orElse: () => false,
  );
});

// auto-accept 强制常开：AI 改动落地即生效，回退由变更日志 + 轮次回退兜底。
// 已决策不提供关闭开关，详见 docs/solutions/chat-changes-rework.md。
final aiAgentAutoAcceptProvider = Provider<bool>((ref) => true);

final aiAutoAcceptFailedChangeIdsProvider =
    NotifierProvider.family<
      AiAutoAcceptFailedChangeIdsNotifier,
      Set<String>,
      String
    >(AiAutoAcceptFailedChangeIdsNotifier.new);

class AiAutoAcceptFailedChangeIdsNotifier extends Notifier<Set<String>> {
  AiAutoAcceptFailedChangeIdsNotifier(this.databasePath);

  final String databasePath;

  @override
  Set<String> build() => <String>{};

  void retainOnly(Set<String> pendingChangeIds) {
    final next = state.intersection(pendingChangeIds);
    if (next.length != state.length || !next.containsAll(state)) {
      state = next;
    }
  }

  void addFailedIds(Iterable<String> ids) {
    state = {...state, ...ids};
  }
}

final aiAgentIdentityProvider = Provider<String>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.aiAgentIdentity,
    orElse: () => defaultAiAgentIdentity,
  );
});

final aiAgentSoulProvider = Provider<String>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.aiAgentSoul,
    orElse: () => defaultAiAgentSoul,
  );
});

final aiAgentAvatarPathProvider = Provider<String>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.aiAgentAvatarPath,
    orElse: () => '',
  );
});

/// 下一步建议总开关。设置未就绪时取默认 true，与 [AiAgentSettingsData.defaults] 一致。
final aiAgentNextActionSuggestionsProvider = Provider<bool>((ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.aiAgentNextActionSuggestions,
    orElse: () => true,
  );
});

// ---- Storage convenience providers ----

@riverpod
int changeRecordRetentionDays(Ref ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.changeRecordRetentionDays,
    orElse: () => 30,
  );
}

// ---- Backup convenience providers ----

@riverpod
String backupDirectory(Ref ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.backupDirectory,
    orElse: () => '',
  );
}

@riverpod
BackupFrequency backupFrequency(Ref ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.backupFrequency,
    orElse: () => BackupFrequency.manual,
  );
}

@riverpod
DateTime? lastBackupTime(Ref ref) {
  final settingsAsync = ref.watch(appSettingsNotifierProvider);
  return settingsAsync.maybeWhen(
    data: (s) => s.lastBackupTime,
    orElse: () => null,
  );
}

@Riverpod(keepAlive: true)
BackupService backupService(Ref ref) {
  return BackupService();
}

@Riverpod(keepAlive: true)
AutoBackupScheduler autoBackupScheduler(Ref ref) {
  final backupService = ref.watch(backupServiceProvider);
  final webDavBackupService = ref.watch(webDavBackupServiceProvider);
  final initialSettings = ref.read(appSettingsNotifierProvider).asData?.value;
  final scheduler = AutoBackupScheduler(
    schedule: _autoBackupScheduleFromSettings(initialSettings),
    executeBackup: (directory) {
      final settings = ref.read(appSettingsNotifierProvider).asData?.value;
      return BackupOrchestrator(
        backupService: backupService,
        webDavBackupService: webDavBackupService,
      ).createBackup(
        outputDirectory: directory,
        webDavConfig:
            settings?.webDavBackupConfig ?? const WebDavBackupConfig(),
      );
    },
    onBackupCompleted: (completedAt) {
      return ref
          .read(appSettingsNotifierProvider.notifier)
          .setLastBackupTime(completedAt);
    },
  );

  ref.listen<AsyncValue<AppSettings>>(appSettingsNotifierProvider, (_, next) {
    scheduler.updateSchedule(
      _autoBackupScheduleFromSettings(next.asData?.value),
    );
  });

  scheduler.start();
  ref.onDispose(scheduler.dispose);
  return scheduler;
}

AutoBackupSchedule _autoBackupScheduleFromSettings(AppSettings? settings) {
  // 移动端只能写应用私有目录，备份必须由用户手动触发并另存，自动备份一律停用。
  final frequency = backupSupportsCustomDirectory()
      ? (settings?.backupFrequency ?? BackupFrequency.manual)
      : BackupFrequency.manual;
  return AutoBackupSchedule(
    directory: settings?.backupDirectory ?? '',
    frequency: frequency,
    weekdays: settings?.backupWeekdays ?? const <int>[DateTime.monday],
    dayOfMonth: settings?.backupDayOfMonth ?? 1,
    hour: settings?.backupHour ?? 2,
    minute: settings?.backupMinute ?? 0,
    lastBackupTime: settings?.lastBackupTime,
  );
}

List<int> _normalizeBackupWeekdays(Iterable<int> weekdays) {
  final normalized =
      weekdays
          .where(
            (weekday) =>
                weekday >= DateTime.monday && weekday <= DateTime.sunday,
          )
          .toSet()
          .toList()
        ..sort();
  return List<int>.unmodifiable(normalized);
}

// ---- Storage Cleanup convenience providers ----

@Riverpod(keepAlive: true)
StorageCleanupService storageCleanupScheduler(Ref ref) {
  final database = ref.read(appSettingsDatabaseProvider);
  final settingsAsync = ref.read(appSettingsNotifierProvider);
  final retentionDays = settingsAsync.maybeWhen(
    data: (s) => s.changeRecordRetentionDays,
    orElse: () => 30,
  );

  final scheduler = StorageCleanupService(
    coordinator: ref.watch(novelMaintenanceCoordinatorProvider),
    runningSessionIds: () => ref
        .read(aiModeProcessingTrackerProvider)
        .map((token) => token.substring(token.indexOf(':') + 1))
        .toSet(),
    appDatabase: database,
    retentionDays: retentionDays,
  );

  ref.listen<AsyncValue<AppSettings>>(appSettingsNotifierProvider, (_, next) {
    final days = next.maybeWhen(
      data: (s) => s.changeRecordRetentionDays,
      orElse: () => 30,
    );
    scheduler.updateConfig(retentionDays: days);
  });

  scheduler.start();
  ref.onDispose(scheduler.dispose);
  return scheduler;
}

// 职责: 编辑器设置持久化快照 — 定义聚合 AppSettings JSON 与默认值。
// 关联文件:
//   lib/shared/providers/settings_providers.dart
//   lib/shared/database/daos/app_settings_dao.dart
// 遵循的 Rules:
//   .agents/rules/json.md

import 'dart:convert';

/// 单个 `app_settings` 记录中保存的编辑器配置快照。
class EditorSettingsData {
  const EditorSettingsData({
    required this.fontFamily,
    required this.fontSize,
    this.fontColorHex = '',
    required this.letterSpacing,
    required this.lineHeight,
    required this.minimapEnabled,
    required this.lineNumbersEnabled,
    required this.dialogueHighlightEnabled,
    this.highlightColorHex = '',
    required this.lineEnabled,
    required this.lineStyle,
    required this.lineColorHex,
    required this.entityRecognitionEnabled,
    required this.entityItalic,
    required this.entityHighlight,
    required this.entityHighlightColorHex,
    required this.entityTextColorHex,
    required this.entityUnderline,
    required this.entityBold,
    required this.formatIndentCount,
    required this.formatParagraphSpacing,
    required this.formatAllowSpaces,
  });

  static const appSettingsKey = 'editor_settings';
  static const currentVersion = 4;

  static const defaultFontFamily = 'Literata';
  static const defaultChineseFontFamily = 'LXGWWenKai';
  static const defaultFontSize = 16;
  static const defaultLetterSpacing = 0.0;
  static const defaultLineHeight = 1.8;
  static const defaultLineStyle = 'solid';
  static const defaultLineColorHex = '#FFFF0000';
  static const defaultEntityHighlightColorHex = '#33FFD54F';
  static const defaultFormatIndentCount = 2;
  static const defaultFormatParagraphSpacing = 'one_blank_line';

  final String fontFamily;
  final int fontSize;
  final String fontColorHex;
  final double letterSpacing;
  final double lineHeight;
  final bool minimapEnabled;
  final bool lineNumbersEnabled;
  final bool dialogueHighlightEnabled;
  final String highlightColorHex;
  final bool lineEnabled;
  final String lineStyle;
  final String lineColorHex;
  final bool entityRecognitionEnabled;
  final bool entityItalic;
  final bool entityHighlight;
  final String entityHighlightColorHex;
  final String entityTextColorHex;
  final bool entityUnderline;
  final bool entityBold;
  final int formatIndentCount;
  final String formatParagraphSpacing;
  final bool formatAllowSpaces;

  factory EditorSettingsData.defaultsForLanguage(String language) {
    return EditorSettingsData(
      fontFamily: language.toLowerCase().startsWith('zh')
          ? defaultChineseFontFamily
          : defaultFontFamily,
      fontSize: defaultFontSize,
      letterSpacing: defaultLetterSpacing,
      lineHeight: defaultLineHeight,
      minimapEnabled: false,
      lineNumbersEnabled: false,
      dialogueHighlightEnabled: false,
      lineEnabled: false,
      lineStyle: defaultLineStyle,
      lineColorHex: defaultLineColorHex,
      entityRecognitionEnabled: true,
      entityItalic: false,
      entityHighlight: false,
      entityHighlightColorHex: defaultEntityHighlightColorHex,
      entityTextColorHex: '',
      entityUnderline: false,
      entityBold: false,
      formatIndentCount: defaultFormatIndentCount,
      formatParagraphSpacing: defaultFormatParagraphSpacing,
      formatAllowSpaces: true,
    );
  }

  factory EditorSettingsData.decode(
    String raw, {
    required EditorSettingsData fallback,
  }) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('editor_settings must be a JSON object');
    }
    final json = decoded.map((key, value) => MapEntry(key.toString(), value));
    return EditorSettingsData.fromJson(json, fallback: fallback);
  }

  factory EditorSettingsData.fromJson(
    Map<String, dynamic> json, {
    required EditorSettingsData fallback,
  }) {
    final lineStyle = _string(json['lineStyle'], fallback.lineStyle);
    final paragraphSpacing = _string(
      json['formatParagraphSpacing'],
      fallback.formatParagraphSpacing,
    );
    return EditorSettingsData(
      fontFamily: _string(json['fontFamily'], fallback.fontFamily),
      fontSize: _integer(json['fontSize'], fallback.fontSize),
      fontColorHex: _string(json['fontColorHex'], fallback.fontColorHex),
      letterSpacing: _double(json['letterSpacing'], fallback.letterSpacing),
      lineHeight: _double(json['lineHeight'], fallback.lineHeight),
      minimapEnabled: _boolean(json['minimapEnabled'], fallback.minimapEnabled),
      lineNumbersEnabled: _boolean(
        json['lineNumbersEnabled'],
        fallback.lineNumbersEnabled,
      ),
      dialogueHighlightEnabled: _boolean(
        json['dialogueHighlightEnabled'],
        fallback.dialogueHighlightEnabled,
      ),
      highlightColorHex: _string(
        json['highlightColorHex'],
        fallback.highlightColorHex,
      ),
      lineEnabled: _boolean(json['lineEnabled'], fallback.lineEnabled),
      lineStyle:
          const {'solid', 'sparseDashed', 'denseDashed'}.contains(lineStyle)
          ? lineStyle
          : fallback.lineStyle,
      lineColorHex: _string(json['lineColorHex'], fallback.lineColorHex),
      entityRecognitionEnabled: _boolean(
        json['entityRecognitionEnabled'],
        fallback.entityRecognitionEnabled,
      ),
      entityItalic: _boolean(json['entityItalic'], fallback.entityItalic),
      entityHighlight: _boolean(
        json['entityHighlight'],
        fallback.entityHighlight,
      ),
      entityHighlightColorHex: _string(
        json['entityHighlightColorHex'],
        fallback.entityHighlightColorHex,
      ),
      entityTextColorHex: _string(
        json['entityTextColorHex'],
        fallback.entityTextColorHex,
      ),
      entityUnderline: _boolean(
        json['entityUnderline'],
        fallback.entityUnderline,
      ),
      entityBold: _boolean(json['entityBold'], fallback.entityBold),
      formatIndentCount: _integer(
        json['formatIndentCount'],
        fallback.formatIndentCount,
      ),
      formatParagraphSpacing:
          const {'none', 'one_blank_line'}.contains(paragraphSpacing)
          ? paragraphSpacing
          : fallback.formatParagraphSpacing,
      formatAllowSpaces: _boolean(
        json['formatAllowSpaces'],
        fallback.formatAllowSpaces,
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'version': currentVersion,
      'fontFamily': fontFamily,
      'fontSize': fontSize,
      'fontColorHex': fontColorHex,
      'letterSpacing': letterSpacing,
      'lineHeight': lineHeight,
      'minimapEnabled': minimapEnabled,
      'lineNumbersEnabled': lineNumbersEnabled,
      'dialogueHighlightEnabled': dialogueHighlightEnabled,
      'highlightColorHex': highlightColorHex,
      'lineEnabled': lineEnabled,
      'lineStyle': lineStyle,
      'lineColorHex': lineColorHex,
      'entityRecognitionEnabled': entityRecognitionEnabled,
      'entityItalic': entityItalic,
      'entityHighlight': entityHighlight,
      'entityHighlightColorHex': entityHighlightColorHex,
      'entityTextColorHex': entityTextColorHex,
      'entityUnderline': entityUnderline,
      'entityBold': entityBold,
      'formatIndentCount': formatIndentCount,
      'formatParagraphSpacing': formatParagraphSpacing,
      'formatAllowSpaces': formatAllowSpaces,
    };
  }

  String encode() => jsonEncode(toJson());

  static String _string(Object? value, String fallback) {
    return value is String ? value : fallback;
  }

  static int _integer(Object? value, int fallback) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value) ?? fallback;
    }
    return fallback;
  }

  static double _double(Object? value, double fallback) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value) ?? fallback;
    }
    return fallback;
  }

  static bool _boolean(Object? value, bool fallback) {
    if (value is bool) {
      return value;
    }
    if (value == 'true') {
      return true;
    }
    if (value == 'false') {
      return false;
    }
    return fallback;
  }
}

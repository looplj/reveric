// 职责: 渲染 AI Markdown 正文、管理流式选区，并仅允许 HTTP(S) 链接打开系统浏览器。
// 关联文件:
//   lib/shared/widgets/stable_selection_area.dart
//   lib/shared/widgets/ai/chat/chat_message_parts.dart
//   lib/shared/widgets/ai/council/message_card.dart
//   lib/shared/widgets/ai/council/summary_card.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../logger/app_logger.dart';
import '../../theme/theme.dart';
import '../stable_selection_area.dart';
import 'markdown_code_block.dart';

final _log = AppLogger.forModule('AiMarkdown');

Future<void> _openWebLink(BuildContext context, String destination) async {
  final uri = Uri.tryParse(destination);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      !uri.hasAuthority ||
      uri.host.isEmpty) {
    return;
  }
  try {
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      return;
    }
    _log.warning('Web link launcher returned false');
  } catch (error) {
    // The destination may contain private query parameters; do not log it or
    // platform exception messages that may repeat it.
    _log.warning('Web link launcher failed type=${error.runtimeType}');
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.t(LocaleKeys.commonOpenLinkFailed))),
    );
  }
}

/// 把全角数字（U+FF10–FF19）归一化为半角，避免 Markdown 渲染时数字占满 CJK 字宽、
/// 看起来过宽过散。只转换数字，刻意保留中文全角标点（「」，。！？（）等正常排版）。
String _normalizeFullwidthDigits(String input) {
  return input.replaceAllMapped(
    RegExp(r'[０-９]'),
    (m) => String.fromCharCode(m.group(0)!.codeUnitAt(0) - 0xFF10 + 0x30),
  );
}

class AiMarkdownText extends StatelessWidget {
  const AiMarkdownText(
    this.content, {
    super.key,
    required this.style,
    this.selectable = true,
    this.loadInlineImages = true,
    this.maxLines,
    this.overflow,
  });

  final String content;
  final TextStyle style;

  /// false 时内容不可选中：内容仍在流式增长，框架选区索引会失稳崩溃。
  final bool selectable;
  final bool loadInlineImages;
  final int? maxLines;
  final TextOverflow? overflow;

  /// Markdown 表格单列内容宽度上限：短列保持紧凑，长文本列自动折行而非横向截断。
  static const double _maxTableColumnWidth = 260;

  @override
  Widget build(BuildContext context) {
    final markdown = GptMarkdownTheme(
      gptThemeData: _buildMarkdownTheme(context, style),
      child: GptMarkdown(
        _normalizeFullwidthDigits(content.trim()),
        textDirection: Directionality.of(context),
        style: style,
        maxLines: maxLines,
        overflow: overflow,
        codeBuilder: buildMarkdownCodeBlock,
        imageBuilder: loadInlineImages
            ? null
            : (_, _, _, _) => const SizedBox.shrink(),
        onLinkTap: (url, _) => unawaited(_openWebLink(context, url)),
      ),
    );
    return StableSelectionArea(selectable: selectable, child: markdown);
  }

  /// 按正文样式统一构造 Markdown 主题：
  /// 1. 标题与行内代码跟随正文颜色，并按正文字号等比缩放 h1–h6，避免默认 32px
  ///    headlineLarge 在窄聊天气泡里比例失调；
  /// 2. 表格表头底色、边框与文字显式绑定主题色，避免深色主题下退化为浅底白字，
  ///    并通过列宽上限让长文本折行而非横向硬截断。
  static GptMarkdownThemeData _buildMarkdownTheme(
    BuildContext context,
    TextStyle bodyStyle,
  ) {
    final base = GptMarkdownTheme.of(context);
    final revericColors = context
        .dependOnInheritedWidgetOfExactType<RevericTheme>()
        ?.data
        .colors;
    final textColor =
        bodyStyle.color ??
        revericColors?.textPrimary ??
        Theme.of(context).colorScheme.onSurface;
    // 浅色文字意味着深色背景，沿用 gpt_markdown 深色下更强的底色与描边透明度。
    final onDark =
        ThemeData.estimateBrightnessForColor(textColor) == Brightness.light;
    final matchedColors =
        revericColors != null && revericColors.isDark == onDark
        ? revericColors
        : null;
    final baseFontSize =
        bodyStyle.fontSize ??
        DefaultTextStyle.of(context).style.fontSize ??
        14.0;

    TextStyle heading(
      TextStyle? fallback, {
      required double scale,
      required FontWeight weight,
      required double height,
    }) {
      return (fallback ?? const TextStyle()).copyWith(
        color: textColor,
        fontSize: baseFontSize * scale,
        fontWeight: weight,
        height: height,
      );
    }

    final tableHeaderBg = matchedColors != null
        ? (matchedColors.isDark
              ? matchedColors.surfaceContainerHigh
              : matchedColors.surfaceDim)
        : textColor.withValues(alpha: onDark ? 0.12 : 0.08);
    final tableBorderColor =
        matchedColors?.border ??
        textColor.withValues(alpha: onDark ? 0.22 : 0.18);
    final dividerColor =
        matchedColors?.borderSubtle ??
        textColor.withValues(alpha: onDark ? 0.18 : 0.14);

    return base.copyWith(
      h1: heading(base.h1, scale: 1.45, weight: FontWeight.w700, height: 1.35),
      h2: heading(base.h2, scale: 1.30, weight: FontWeight.w700, height: 1.35),
      h3: heading(base.h3, scale: 1.15, weight: FontWeight.w600, height: 1.40),
      h4: heading(base.h4, scale: 1.05, weight: FontWeight.w600, height: 1.45),
      h5: heading(base.h5, scale: 1.00, weight: FontWeight.w600, height: 1.50),
      h6: heading(base.h6, scale: 0.95, weight: FontWeight.w600, height: 1.50),
      hrLineColor: dividerColor,
      autoAddDividerLineAfterH1: false,
      inlineCode: base.inlineCode.copyWith(
        color: textColor,
        backgroundColor: textColor.withValues(alpha: onDark ? 0.14 : 0.10),
        borderColor: textColor.withValues(alpha: onDark ? 0.34 : 0.28),
      ),
      styleSheet: base.styleSheet.copyWith(
        table: TableStyle(
          borderColor: tableBorderColor,
          borderWidth: RevericSizes.dividerThickness,
          borderRadius: const Radius.circular(RevericRadius.medium),
          cellPadding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.md,
            vertical: RevericSpacing.xs,
          ),
          headerBackground: tableHeaderBg,
          headerTextStyle: TextStyle(
            color: textColor,
            fontWeight: FontWeight.w600,
          ),
          columnWidth: const MinColumnWidth(
            CustomTableColumnWidth(),
            FixedColumnWidth(_maxTableColumnWidth),
          ),
        ),
      ),
    );
  }
}

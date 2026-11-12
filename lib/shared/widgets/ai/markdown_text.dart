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
    this.maxLines,
    this.overflow,
  });

  final String content;
  final TextStyle style;

  /// false 时内容不可选中：内容仍在流式增长，框架选区索引会失稳崩溃。
  final bool selectable;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    Widget markdown = GptMarkdown(
      _normalizeFullwidthDigits(content.trim()),
      textDirection: Directionality.of(context),
      style: style,
      maxLines: maxLines,
      overflow: overflow,
      codeBuilder: buildMarkdownCodeBlock,
      onLinkTap: (url, _) => unawaited(_openWebLink(context, url)),
    );
    final textColor = style.color;
    if (textColor != null) {
      markdown = GptMarkdownTheme(
        gptThemeData: _themeForTextColor(context, textColor),
        child: markdown,
      );
    }
    return StableSelectionArea(selectable: selectable, child: markdown);
  }

  /// 标题与行内代码默认取 Material Theme 的颜色，与调用方给正文的颜色来源不同；
  /// 统一改用正文颜色，避免两者不一致时在深色背景上看不清。
  static GptMarkdownThemeData _themeForTextColor(
    BuildContext context,
    Color textColor,
  ) {
    final base = GptMarkdownTheme.of(context);
    // 浅色文字意味着深色背景，沿用 gpt_markdown 深色下更强的底色与描边透明度。
    final onDark =
        ThemeData.estimateBrightnessForColor(textColor) == Brightness.light;
    TextStyle? heading(TextStyle? s) => s?.copyWith(color: textColor);
    return base.copyWith(
      h1: heading(base.h1),
      h2: heading(base.h2),
      h3: heading(base.h3),
      h4: heading(base.h4),
      h5: heading(base.h5),
      h6: heading(base.h6),
      inlineCode: base.inlineCode.copyWith(
        color: textColor,
        backgroundColor: textColor.withValues(alpha: onDark ? 0.14 : 0.10),
        borderColor: textColor.withValues(alpha: onDark ? 0.34 : 0.28),
      ),
    );
  }
}

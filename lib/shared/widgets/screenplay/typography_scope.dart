// 职责: 将编辑器字体设置响应式传给剧本正文，保持编辑会话与工具栏独立。
// 关联文件:
//   lib/shared/providers/settings_providers.dart
//   lib/shared/widgets/screenplay/document_editor.dart
//   lib/shared/widgets/screenplay/text_styles.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/settings_providers.dart';
import '../../theme/theme.dart';

class ScreenplayTypographyScope extends ConsumerWidget {
  const ScreenplayTypographyScope({super.key, required this.child});

  final Widget child;

  static TextStyle? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_Typography>()?.style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = RevericTheme.typographyOf(context).body.copyWith(
      fontFamily: ref.watch(editorFontFamilyProvider),
      fontSize: ref.watch(editorFontSizeProvider).toDouble(),
      color:
          ref.watch(editorFontColorProvider) ??
          RevericTheme.colorsOf(context).textPrimary,
      letterSpacing: ref.watch(editorLetterSpacingProvider),
      height: ref.watch(editorLineHeightProvider),
    );
    return _Typography(style: style, child: child);
  }
}

class _Typography extends InheritedWidget {
  const _Typography({required this.style, required super.child});

  final TextStyle style;

  @override
  bool updateShouldNotify(_Typography oldWidget) => style != oldWidget.style;
}

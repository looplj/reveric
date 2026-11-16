// 职责: 集中派生剧本正文与缩略图的排版样式，避免各处散落 copyWith 尺寸。
// 关联文件:
//   lib/desktop/features/screenplay/script_elements.dart
//   lib/desktop/features/screenplay/scenes.dart
//   lib/shared/theme/theme.dart
//   lib/shared/widgets/screenplay/typography_scope.dart
// 遵循的 Rules:
//   .agents/rules/design-system.md

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import 'typography_scope.dart';

/// 剧本正文使用编辑器字体设置，标题和辅助文字保留主题字号比例。
/// 非编辑器展示沿用主题排版，提示与警告仍使用语义颜色。
///
/// 括号提示刻意**不用** `FontStyle.italic`：中文字体没有 italic face，
/// macOS/iOS 会由 CoreText 合成错切，Android 可能直接忽略，同一份代码两端不一致。
/// 区分靠全角括号 + 缩进 + 更小字号 + 更浅颜色。
class ScreenplayTextStyles {
  const ScreenplayTextStyles({
    required this.sceneHeading,
    required this.sceneNumber,
    required this.sceneCondition,
    required this.sceneSeparator,
    required this.cast,
    required this.castNames,
    required this.action,
    required this.actionMarker,
    required this.character,
    required this.characterExtension,
    required this.parenthetical,
    required this.dialogue,
    required this.transition,
    required this.subtitle,
    required this.note,
    required this.notePrefix,
    required this.placeholder,
  });

  factory ScreenplayTextStyles.of(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final editor = ScreenplayTypographyScope.maybeOf(context);
    final body = editor ?? typo.body;
    final scale = (body.fontSize ?? 16) / (typo.body.fontSize ?? 16);
    final small = editor == null
        ? typo.bodySmall
        : body.copyWith(fontSize: typo.bodySmall.fontSize! * scale);
    final note = editor == null
        ? typo.ui
        : body.copyWith(fontSize: typo.ui.fontSize! * scale);
    final primary = editor?.color ?? colors.textPrimary;
    return ScreenplayTextStyles(
      sceneHeading: body.copyWith(
        fontSize: 17 * scale,
        fontWeight: FontWeight.w700,
        height: editor?.height ?? 1.5,
        color: primary,
      ),
      sceneNumber: body.copyWith(
        fontSize: 17 * scale,
        fontWeight: FontWeight.w700,
        height: editor?.height ?? 1.5,
        color: colors.textMuted,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      sceneCondition: body.copyWith(
        fontSize: 17 * scale,
        fontWeight: FontWeight.w700,
        height: editor?.height ?? 1.5,
        color: primary,
      ),
      sceneSeparator: body.copyWith(
        fontSize: 17 * scale,
        fontWeight: FontWeight.w400,
        height: editor?.height ?? 1.5,
        color: colors.textSubtle,
      ),
      cast: small.copyWith(
        height: editor?.height ?? 1.6,
        color: colors.textMuted,
      ),
      castNames: small.copyWith(
        height: editor?.height ?? 1.6,
        color: colors.textSecondary,
      ),
      action: body.copyWith(color: primary),
      actionMarker: body.copyWith(
        fontSize: 11 * scale,
        height: 1,
        color: colors.textSubtle,
      ),
      character: body.copyWith(
        fontWeight: FontWeight.w700,
        height: editor?.height ?? 1.6,
        color: primary,
      ),
      characterExtension: small.copyWith(
        height: editor?.height ?? 1.6,
        color: colors.textMuted,
      ),
      parenthetical: small.copyWith(
        height: editor?.height ?? 1.6,
        color: colors.textMuted,
      ),
      dialogue: body.copyWith(color: primary),
      transition: small.copyWith(
        fontWeight: FontWeight.w700,
        height: editor?.height ?? 1.6,
        letterSpacing: editor?.letterSpacing ?? 2,
        color: colors.textSecondary,
      ),
      subtitle: body.copyWith(
        fontWeight: FontWeight.w700,
        height: editor?.height ?? 1.7,
        letterSpacing: editor?.letterSpacing ?? 4,
        color: colors.textSecondary,
      ),
      note: note.copyWith(
        height: editor?.height ?? 1.7,
        color: colors.textMuted,
      ),
      notePrefix: note.copyWith(
        height: editor?.height ?? 1.7,
        fontWeight: FontWeight.w600,
        color: colors.blockquoteBorder,
      ),
      placeholder: body.copyWith(color: colors.textSubtle),
    );
  }

  final TextStyle sceneHeading;
  final TextStyle sceneNumber;
  final TextStyle sceneCondition;
  final TextStyle sceneSeparator;
  final TextStyle cast;
  final TextStyle castNames;
  final TextStyle action;
  final TextStyle actionMarker;
  final TextStyle character;
  final TextStyle characterExtension;
  final TextStyle parenthetical;
  final TextStyle dialogue;
  final TextStyle transition;
  final TextStyle subtitle;
  final TextStyle note;
  final TextStyle notePrefix;
  final TextStyle placeholder;
}

/// 场次卡顶部那块正文缩略的排版 —— 与正文同一套字体，只是压到 8.5px，
/// 让作者一眼认出「这一场长什么样」，而不是读它。
class ScreenplayPeekTextStyles {
  const ScreenplayPeekTextStyles({
    required this.line,
    required this.heading,
    required this.character,
    required this.parenthetical,
  });

  factory ScreenplayPeekTextStyles.of(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final base = typo.bodySmall.copyWith(fontSize: 8.5, height: 1.85);
    return ScreenplayPeekTextStyles(
      line: base.copyWith(color: colors.textMuted),
      heading: base.copyWith(
        fontWeight: FontWeight.w700,
        color: colors.textSecondary,
      ),
      character: base.copyWith(
        fontWeight: FontWeight.w700,
        color: colors.textSecondary,
      ),
      parenthetical: base.copyWith(color: colors.textSubtle),
    );
  }

  final TextStyle line;
  final TextStyle heading;
  final TextStyle character;
  final TextStyle parenthetical;
}

// 职责: 桌面端首页作品展示共用格式化与小部件 — 字数、状态角标与画布占位封面
// 关联文件:
//   lib/desktop/widgets/home/resume_section.dart
//   lib/desktop/widgets/novel_list.dart
//   lib/shared/localization/locale_keys.dart
//   lib/shared/widgets/novel/library_shelf_labels.dart
//   assets/translations/en/home.json
//   assets/translations/zh-CN/home.json
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json

import 'package:flutter/material.dart';

import '../../../shared/database/app_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/content_kind.dart';
import '../../../shared/models/content_status.dart';
import '../../../shared/models/novel_type.dart';
import '../../../shared/theme/canvas_colors.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/novel/library_shelf_labels.dart';

String homeNovelStatusText(
  BuildContext context,
  String status, {
  String? contentKind,
}) => libraryStatusText(context, status, contentKind: contentKind);

String homeNovelTypeText(BuildContext context, String type) {
  return switch (type) {
    novelTypeOriginal => context.t(LocaleKeys.libraryNovelTypeOriginal),
    novelTypeAdaptation => context.t(LocaleKeys.libraryNovelTypeAdaptation),
    novelTypeSequel => context.t(LocaleKeys.libraryNovelTypeSequel),
    novelTypeFanfic => context.t(LocaleKeys.libraryNovelTypeFanfic),
    novelTypeDerivative => context.t(LocaleKeys.libraryNovelTypeDerivative),
    novelTypeMaterial => context.t(LocaleKeys.libraryNovelTypeMaterial),
    _ => type,
  };
}

String homeNovelWordCountLabel(BuildContext context, int wordCount) {
  return formatHomeWordCountLabel(context, wordCount);
}

class HomeNovelStatusConfig {
  const HomeNovelStatusConfig({
    required this.color,
    required this.bgColor,
    required this.icon,
  });

  final Color color;
  final Color bgColor;
  final String icon;
}

HomeNovelStatusConfig homeNovelStatusConfig(
  String status,
  RevericColors colors,
) {
  return switch (status) {
    contentStatusFinished => HomeNovelStatusConfig(
      color: colors.accent,
      bgColor: colors.accent.withValues(alpha: 0.12),
      icon: RevericIcons.check_circle_outline,
    ),
    contentStatusAbandoned => HomeNovelStatusConfig(
      color: colors.textMuted,
      bgColor: colors.textMuted.withValues(alpha: 0.12),
      icon: RevericIcons.block_outlined,
    ),
    contentStatusArchived => HomeNovelStatusConfig(
      color: colors.accentAmber,
      bgColor: colors.accentAmber.withValues(alpha: 0.12),
      icon: RevericIcons.archive_outlined,
    ),
    _ => HomeNovelStatusConfig(
      color: colors.accentAmber,
      bgColor: colors.accentAmber.withValues(alpha: 0.12),
      icon: RevericIcons.edit_outlined,
    ),
  };
}

class HomeNovelStatusBadge extends StatelessWidget {
  const HomeNovelStatusBadge({super.key, required this.novel});

  final Novel novel;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final shownStatus =
        novel.contentKind == contentKindCanvas &&
            novel.status == contentStatusFinished
        ? contentStatusInProgress
        : novel.status;
    final statusCfg = novel.draft
        ? HomeNovelStatusConfig(
            color: colors.textMuted,
            bgColor: colors.textMuted.withValues(alpha: 0.12),
            icon: RevericIcons.inbox_outlined,
          )
        : homeNovelStatusConfig(shownStatus, colors);
    final label = novel.draft
        ? context.t(LocaleKeys.homeFilterDraft)
        : homeNovelStatusText(
            context,
            novel.status,
            contentKind: novel.contentKind,
          );
    return Container(
      decoration: BoxDecoration(
        color: colors.canvas.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(RevericRadius.small),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.sm,
        vertical: RevericSpacing.xxs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RevericIcon(statusCfg.icon, size: 12, color: statusCfg.color),
          const SizedBox(width: RevericSpacing.xxs),
          Text(
            label,
            style: typo.uiTinySemibold.copyWith(color: statusCfg.color),
          ),
        ],
      ),
    );
  }
}

/// 画布作品没有封面时的占位：一块点阵画布加类型图标，和书封区分开。
class HomeCanvasPlaceholder extends StatelessWidget {
  const HomeCanvasPlaceholder({super.key, this.iconSize = 32});

  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return ColoredBox(
      color: colors.surfaceDim,
      child: CustomPaint(
        painter: _CanvasDotsPainter(canvasFineDotColor(colors)),
        child: Center(
          child: RevericIcon(
            RevericIcons.flow_arrow,
            size: iconSize,
            color: colors.textSubtle,
          ),
        ),
      ),
    );
  }
}

class _CanvasDotsPainter extends CustomPainter {
  const _CanvasDotsPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const step = RevericSpacing.x2l;
    final paint = Paint()..color = color;
    for (var y = step / 2; y < size.height; y += step) {
      for (var x = step / 2; x < size.width; x += step) {
        canvas.drawCircle(Offset(x, y), .75, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_CanvasDotsPainter oldDelegate) =>
      oldDelegate.color != color;
}

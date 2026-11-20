// 职责: 移动端书脊封面块 — 有封面图则展示图片，否则降级为 serif 标题 + 书脊线占位（Home/书架共用）。
// 关联文件:
//   lib/shared/models/novel.dart
//   lib/shared/utils/storage_paths.dart
//   lib/shared/theme/theme.dart
import 'dart:io';

import 'package:flutter/material.dart';

import '../../shared/models/novel.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/media_asset_image.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 一组与设计稿一致的暖色封面底色，按标题稳定取色（无封面图时使用）。
const List<Color> _fallbackTints = [
  Color(0xFFB8835A),
  Color(0xFF5C6B7E),
  Color(0xFF5E7060),
  Color(0xFF243B5A),
  Color(0xFF5D4F3D),
  Color(0xFF7A4B57),
];

Color _tintForTitle(String title) {
  if (title.isEmpty) {
    return _fallbackTints.first;
  }
  return _fallbackTints[title.hashCode.abs() % _fallbackTints.length];
}

/// 移动端封面块。[fontSize] 控制标题字号，封面尺寸由外层约束（多用 AspectRatio / SizedBox）。
class MobileNovelCover extends ConsumerWidget {
  const MobileNovelCover({super.key, required this.novel, this.fontSize = 15});

  final Novel novel;
  final double fontSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typo = RevericTheme.typographyOf(context);
    final resolvedCoverPath = watchWorkCoverFile(ref, novel);
    final coverFile = resolvedCoverPath == null
        ? null
        : File(resolvedCoverPath);
    final hasCover = coverFile != null;

    final radius = BorderRadius.circular(RevericRadius.large);

    if (hasCover) {
      return ClipRRect(
        borderRadius: radius,
        child: Image.file(
          coverFile,
          fit: BoxFit.cover,
          cacheWidth: 480,
          errorBuilder: (_, _, _) => _fallback(typo),
        ),
      );
    }
    return _fallback(typo);
  }

  Widget _fallback(RevericTypography typo) {
    final tint = _tintForTitle(novel.title);
    return ClipRRect(
      borderRadius: BorderRadius.circular(RevericRadius.large),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : 120.0;
          final maxHeight = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : 160.0;
          final minSide = maxWidth < maxHeight ? maxWidth : maxHeight;
          final padding = (fontSize * 0.7).clamp(2.0, minSide * 0.15);
          final spineInset = (maxHeight * 0.12).clamp(2.0, 8.0);

          return Container(
            decoration: BoxDecoration(
              color: tint,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  tint,
                  Color.alphaBlend(Colors.black.withValues(alpha: 0.18), tint),
                ],
              ),
            ),
            padding: EdgeInsets.all(padding),
            child: Stack(
              clipBehavior: Clip.hardEdge,
              fit: StackFit.expand,
              children: [
                // 书脊线
                Positioned(
                  left: 0,
                  top: spineInset,
                  bottom: spineInset,
                  child: Container(
                    width: (padding * 0.45).clamp(1.5, 3.0),
                    color: Colors.black.withValues(alpha: 0.18),
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        novel.title,
                        maxLines: 4,
                        overflow: TextOverflow.clip,
                        style: typo.heading2.copyWith(
                          color: const Color(0xFFFBF6EE),
                          fontSize: fontSize,
                          height: 1.25,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    Text(
                      'REVERIC',
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: typo.uiTiny.copyWith(
                        color: const Color(0xFFFBF6EE).withValues(alpha: 0.72),
                        fontSize: 9,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

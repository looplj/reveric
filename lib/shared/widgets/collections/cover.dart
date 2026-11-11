// 职责: 使用作品的真实封面绘制作品选择缩略图。
// 关联文件:
//   lib/shared/models/novel.dart
//   lib/shared/utils/storage_paths.dart
import 'dart:io';
import 'package:flutter/material.dart';
import '../../models/novel.dart';
import '../../models/content_kind.dart';
import '../../theme/theme.dart';
import '../media_asset_image.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class CollectionWorkCover extends ConsumerWidget {
  const CollectionWorkCover({super.key, required this.work});
  final Novel work;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final path = watchMediaAssetFile(ref, work.coverAssetId);
    final placeholder = ColoredBox(
      color: colors.surfaceDim,
      child: Center(
        child: RevericIcon(
          work.contentKind == contentKindCanvas
              ? RevericIcons.flow_arrow
              : work.contentKind == contentKindScreenplay
              ? RevericIcons.movie_outlined
              : RevericIcons.menu_book_outlined,
          color: colors.textSubtle,
          size: 28,
        ),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: path == null
          ? placeholder
          : Image.file(
              File(path),
              fit: BoxFit.cover,
              cacheWidth: 320,
              errorBuilder: (_, _, _) => placeholder,
            ),
    );
  }
}

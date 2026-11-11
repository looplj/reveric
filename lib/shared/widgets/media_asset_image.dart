// 职责: 按资产 id 显示本地图片，资产或文件缺失时显示占位。
// 关联文件:
//   lib/shared/database/daos/asset_dao.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/utils/storage_paths.dart
//   lib/shared/widgets/character_avatar.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../models/content_kind.dart';
import '../models/novel.dart';
import '../providers/novel_providers.dart';
import '../utils/storage_paths.dart';

/// 资产对应的本地文件；资产不存在、已删除或文件缺失时为 null。
final mediaAssetFileProvider = StreamProvider.autoDispose
    .family<String?, String>(
      (ref, assetId) => ref
          .watch(appDatabaseProvider)
          .assetDao
          .watchAsset(assetId)
          .map((asset) => RevericPaths.resolveStored(asset?.path)),
    );

/// 在 build 中监听资产文件；[assetId] 为空时直接返回 null。
String? watchMediaAssetFile(WidgetRef ref, String? assetId) =>
    assetId == null || assetId.isEmpty
    ? null
    : ref.watch(mediaAssetFileProvider(assetId)).value;

/// 作品最近入库图片的本地文件；没有时为 null。
final latestWorkImageFileProvider = StreamProvider.autoDispose
    .family<String?, String>(
      (ref, novelId) => ref
          .watch(appDatabaseProvider)
          .assetDao
          .watchLatestImage(novelId)
          .map((asset) => RevericPaths.resolveStored(asset?.path)),
    );

/// 作品封面文件；画布没设封面时退到画布里最近的一张图，作为内容预览。
String? watchWorkCoverFile(WidgetRef ref, Novel work) =>
    watchMediaAssetFile(ref, work.coverAssetId) ??
    (work.contentKind == contentKindCanvas
        ? ref.watch(latestWorkImageFileProvider(work.id)).value
        : null);

class MediaAssetImage extends ConsumerWidget {
  const MediaAssetImage({
    super.key,
    required this.assetId,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.cacheWidth,
    this.placeholder = const SizedBox.shrink(),
  });

  final String? assetId;
  final BoxFit fit;
  final double? width;
  final double? height;
  final int? cacheWidth;

  /// 资产不存在、已删除或文件缺失时显示。
  final Widget placeholder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = watchMediaAssetFile(ref, assetId);
    if (path == null) {
      return placeholder;
    }
    return Image.file(
      File(path),
      fit: fit,
      width: width,
      height: height,
      cacheWidth: cacheWidth,
      errorBuilder: (_, _, _) => placeholder,
    );
  }
}

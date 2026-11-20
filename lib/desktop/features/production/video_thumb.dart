// 职责: 按可见状态按需异步加载并显示视频首帧缩略图，避免紧凑缩放和后台状态下重复抽帧。
// 关联文件:
//   lib/desktop/features/production/node_card.dart
//   lib/shared/services/production/library_service.dart
//   lib/shared/services/production/video_thumbnail_cache.dart
//   lib/shared/services/production/canvas_service.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/performance.md

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:path/path.dart' as p;
import '../../../shared/logger/app_logger.dart';
import '../../../shared/models/production/media.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/services/production/ffmpeg_runner.dart';
import '../../../shared/theme/theme.dart';

final _log = AppLogger.forModule('ProductionVideoThumb');

/// 按显示尺寸解码本地图片文件；留出画布最大缩放余量，失败或首帧未就绪时显示 [fallback]。
class ProductionCoverFileImage extends StatelessWidget {
  const ProductionCoverFileImage({
    super.key,
    required this.file,
    required this.maxZoom,
    required this.fallback,
    this.gaplessPlayback = false,
    this.placeholderUntilDecoded = false,
  });

  final File file;
  final double maxZoom;
  final Widget fallback;
  final bool gaplessPlayback;
  final bool placeholderUntilDecoded;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final ImageProvider provider = FileImage(file);
        final side =
            math.max(box.maxWidth, box.maxHeight) *
            maxZoom *
            MediaQuery.devicePixelRatioOf(context);
        return Image(
          image: side.isFinite && side > 0
              ? ResizeImage(
                  provider,
                  width: side.ceil(),
                  height: side.ceil(),
                  policy: ResizeImagePolicy.fit,
                )
              : provider,
          fit: BoxFit.cover,
          gaplessPlayback: gaplessPlayback,
          frameBuilder: placeholderUntilDecoded
              ? (context, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded || frame != null) {
                    return child;
                  }
                  return fallback;
                }
              : null,
          errorBuilder: (_, error, stack) => fallback,
        );
      },
    );
  }
}

/// 异步抽取并展示视频第 0 帧缩略图；不可见、极小缩放或抽取失败时保留轻量图标占位。
class ProductionVideoThumb extends HookWidget {
  const ProductionVideoThumb({
    super.key,
    required this.service,
    required this.filePath,
    required this.maxZoom,
    this.compact = false,
  });

  final ProductionCanvasService service;
  final String filePath;
  final double maxZoom;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final enabled = TickerMode.valuesOf(context).enabled;
    final active = enabled && !compact;
    final token = useMemoized(MediaCancellation.new, [
      service.library,
      filePath,
      active,
    ]);
    useEffect(() => () => unawaited(token.cancel()), [token]);
    final thumb = useFuture(
      useMemoized(() async {
        if (!active) {
          return null;
        }
        try {
          return await service.library.videoThumbnail(
            filePath,
            cancellation: token,
          );
        } on MediaException catch (error) {
          if (error.reason != MediaFailure.cancelled) {
            _log.warning(
              'video thumbnail failed name=${p.basename(filePath)}: $error',
            );
          }
          return null;
        } catch (error, stack) {
          _log.error(
            'video thumbnail failed name=${p.basename(filePath)}',
            error: error,
            stackTrace: stack,
          );
          return null;
        }
      }, [service.library, filePath, active, token]),
      preserveState: false,
    );
    final placeholder = ColoredBox(
      color: colors.surfaceDim,
      child: Center(
        child: RevericIcon(
          RevericIcons.movie_outlined,
          size: 18,
          color: colors.textSubtle,
        ),
      ),
    );
    final file = thumb.data;
    if (file == null) {
      return placeholder;
    }
    return ProductionCoverFileImage(
      key: ValueKey(file.path),
      file: file,
      maxZoom: maxZoom,
      fallback: placeholder,
      gaplessPlayback: true,
      placeholderUntilDecoded: true,
    );
  }
}

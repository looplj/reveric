// 职责: 预览单个媒体资产，并管理视频画面初始化与播放生命周期。
// 关联文件:
//   lib/desktop/features/asset/media_region.dart
//   lib/desktop/features/asset/playback_controls.dart
//   lib/shared/providers/production_media.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/assets.json
//   assets/translations/zh-CN/assets.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/file-access.md

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:video_player/video_player.dart';
import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/components/reveric_placeholder.dart';
import '../../../shared/database/app_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/providers/production_media.dart';
import '../../../shared/theme/theme.dart';
import 'playback_controls.dart';

final _log = AppLogger.forModule('MediaPreview');

class MediaPreviewDialog extends HookConsumerWidget {
  MediaPreviewDialog({super.key, required AssetRow asset})
    : path = asset.path!,
      type = asset.type,
      name = asset.name,
      autoplay = false,
      temporary = false;
  const MediaPreviewDialog.file({
    super.key,
    required this.path,
    required this.type,
    required this.name,
    this.autoplay = false,
    this.temporary = false,
  });
  final String path;
  final String type;
  final String name;
  final bool autoplay;

  /// 应用自己生成的临时文件（如剪辑预览渲染），不在素材库内，直接按绝对路径打开。
  final bool temporary;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(mediaLibraryServiceProvider);
    final playback = ref.watch(playbackServiceProvider);
    final owner = useMemoized(() => Object().hashCode.toString(), const []);
    final ready = useState(false);
    final failed = useState(false);
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    useEffect(() {
      var active = true;
      if (type != 'image') {
        Future<void>(() async {
          if (!active) {
            return;
          }
          try {
            await playback.open(
              owner: owner,
              path: temporary ? path : library.resolvePath(path),
              play: autoplay,
            );
            if (active) {
              ready.value = true;
            }
          } catch (error, stack) {
            _log.error(
              'open failed path=$path',
              error: error,
              stackTrace: stack,
            );
            if (active) {
              failed.value = true;
            }
          }
        });
      }
      return () {
        active = false;
        unawaited(playback.release(owner));
      };
    }, [path, playback, library, owner, autoplay, temporary]);
    useOnAppLifecycleStateChange((previous, current) {
      if (current != AppLifecycleState.resumed) {
        if (ready.value) {
          unawaited(playback.player.pause());
        }
      }
    });
    final isImage = type == 'image';
    const double? storedAspect = null;
    final imageFile = useMemoized(
      () => isImage ? FileImage(File(library.resolvePath(path))) : null,
      [path, library],
    );
    // Older images may lack stored dimensions; read the decoded size so the
    // stage still matches the picture instead of falling back to 16:9.
    final decodedSize = useState<Size?>(null);
    useEffect(() {
      if (imageFile == null || storedAspect != null) {
        return null;
      }
      final stream = imageFile.resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener((info, _) {
        decodedSize.value = Size(
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        );
        info.dispose();
      }, onError: (_, _) {});
      stream.addListener(listener);
      return () => stream.removeListener(listener);
    }, [imageFile, storedAspect]);
    final isVideo = type == 'video';
    final videoSize = ready.value ? playback.player.value.size : null;
    // Fit the stage to the media's own ratio so portrait clips are not
    // squeezed into a wide box with heavy letterboxing.
    final aspect =
        storedAspect ??
        _aspect(
          decodedSize.value?.width.round(),
          decodedSize.value?.height.round(),
        ) ??
        (ready.value
            ? _aspect(videoSize?.width.round(), videoSize?.height.round())
            : null) ??
        16 / 9;
    final screen = MediaQuery.sizeOf(context);
    final maxWidth = math.min(
      RevericSizes.mediaPreviewMaxWidth,
      screen.width * 0.8,
    );
    final maxHeight = math.min(
      RevericSizes.mediaPreviewMaxHeight,
      screen.height * 0.6,
    );
    var mediaHeight = isImage || isVideo
        ? maxHeight
        : RevericSizes.mediaPreviewAudioHeight;
    var mediaWidth = isImage || isVideo
        ? mediaHeight * aspect
        : RevericSizes.dialogWidth;
    if (mediaWidth > maxWidth) {
      mediaWidth = maxWidth;
      mediaHeight = maxWidth / aspect;
    }
    final stageWidth = math.max(mediaWidth, RevericSizes.dialogWidth);
    final Widget media = isImage
        ? Image(
            image: imageFile!,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => RevericPlaceholder.error(
              title: context.t(LocaleKeys.mediaPreviewFailed),
            ),
          )
        : failed.value
        ? RevericPlaceholder.error(
            title: context.t(LocaleKeys.mediaPreviewFailed),
          )
        : !ready.value
        ? const Center(child: CircularProgressIndicator())
        : isVideo
        ? GestureDetector(
            onTap: playback.playOrPause,
            child: VideoPlayer(playback.player),
          )
        : Center(
            child: RevericIcon(
              RevericIcons.play_circle_outline,
              size: 64,
              color: colors.accent,
            ),
          );
    return Dialog(
      child: SizedBox(
        width: stageWidth + RevericSpacing.x2l * 2,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.x2l,
            RevericSpacing.lg,
            RevericSpacing.x2l,
            RevericSpacing.x2l,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      style: typo.uiSemibold,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  RevericIconButton(
                    icon: RevericIcons.close,
                    tooltip: context.t(LocaleKeys.commonClose),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: RevericSpacing.md),
              ClipRRect(
                borderRadius: BorderRadius.circular(RevericRadius.x2l),
                child: ColoredBox(
                  color: colors.surfaceDim,
                  child: SizedBox(
                    height: mediaHeight,
                    child: Center(
                      child: SizedBox(
                        width: mediaWidth,
                        height: mediaHeight,
                        child: media,
                      ),
                    ),
                  ),
                ),
              ),
              if (ready.value && !failed.value) ...[
                const SizedBox(height: RevericSpacing.sm),
                PlaybackControls(player: playback.player),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

double? _aspect(int? width, int? height) =>
    width != null && height != null && width > 0 && height > 0
    ? width / height
    : null;

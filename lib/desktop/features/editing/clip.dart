// 职责: 时间线上的单个片段：按轨道角色绘制画面／包络／文字，拖动只在本地预览，松手提交一步命令。
// 关联文件:
//   lib/desktop/features/editing/timeline.dart
//   lib/desktop/features/editing/controller.dart
//   lib/shared/services/editing/commands.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/editing/document.dart';
import '../../../shared/services/editing/commands.dart';
import '../../../shared/theme/theme.dart';
import 'controller.dart';
import 'support.dart';

enum _Drag { move, reorder, left, right }

class EditingTimelineClip extends HookWidget {
  const EditingTimelineClip({
    super.key,
    required this.controller,
    required this.clip,
    required this.track,
    required this.framePx,
    required this.height,
    required this.trackAt,
  });
  final EditingController controller;
  final EditingClip clip;
  final EditingTrack track;
  final double framePx;
  final double height;
  final String Function(String from, double dy) trackAt;
  @override
  Widget build(BuildContext context) {
    final mode = useState<_Drag?>(null);
    final delta = useState(Offset.zero);
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final doc = controller.doc;
    final c = clip;
    final media = c.media;
    final source = media?.source;
    final video = c.content is EditingVideoContent
        ? c.content as EditingVideoContent
        : null;
    final text = c.content is EditingTextContent
        ? c.content as EditingTextContent
        : null;
    final selected = controller.session.selectedId == c.id;
    final locked = track.locked || controller.readOnly;

    // 源素材能提供的区间：左边最多拉回到源头，右边到源尾。
    final headroom = source == null || source.mediaType == 'image'
        ? null
        : media!.framesFromSourceStart;
    final tailroom = source == null || source.mediaType == 'image'
        ? null
        : media!.framesToSourceEnd - c.durationFrames;
    final neighbours = doc.clips.where(
      (o) => o.trackId == c.trackId && o.id != c.id,
    );
    final previousEnd = track.main
        ? 0
        : neighbours
              .where((o) => o.endFrame <= c.startFrame)
              .fold(0, (n, o) => math.max(n, o.endFrame));
    final nextStart = track.main
        ? null
        : neighbours
              .where((o) => o.startFrame >= c.endFrame)
              .fold<int?>(
                null,
                (n, o) => n == null ? o.startFrame : math.min(n, o.startFrame),
              );

    int snapped(int frame) {
      if (!controller.snap || HardwareKeyboard.instance.isAltPressed) {
        return frame;
      }
      return EditingCommands.snap(
        doc,
        frame,
        framePx,
        controller.playhead.value,
        excluding: {c.id},
      );
    }

    // 拖动中的帧偏移（已吸附、已夹在合法范围内）及是否顶到素材边缘。
    // 回调里按最新的拖动量现算，不读上一帧 build 的结果（松手和最后一次移动可能在同一帧）。
    ({int frames, bool atLimit, int? snapAt}) measure(_Drag? drag, double dx) {
      final raw = (dx / framePx).round();
      var frames = 0;
      var atLimit = false;
      int? snapAt;
      switch (drag) {
        case _Drag.move:
          final start = math.max(0, c.startFrame + raw);
          final a = snapped(start);
          final b = snapped(start + c.durationFrames) - c.durationFrames;
          final next = a != start
              ? a
              : b != start
              ? b
              : start;
          snapAt = a != start
              ? a
              : b != start
              ? b + c.durationFrames
              : null;
          frames = math.max(0, next) - c.startFrame;
        case _Drag.left:
          var lower = headroom == null ? -(1 << 30) : -headroom;
          if (!track.main) {
            lower = math.max(lower, previousEnd - c.startFrame);
          }
          final target = track.main
              ? raw
              : snapped(c.startFrame + raw) - c.startFrame;
          frames = target.clamp(lower, c.durationFrames - 1);
          atLimit = headroom != null && frames == -headroom;
          if (!track.main && target != raw) {
            snapAt = c.startFrame + frames;
          }
        case _Drag.right:
          final end = snapped(c.endFrame + raw);
          var upper = tailroom ?? 1 << 30;
          if (nextStart != null) {
            upper = math.min(upper, nextStart - c.endFrame);
          }
          frames = (end - c.endFrame).clamp(1 - c.durationFrames, upper);
          atLimit = tailroom != null && frames == tailroom;
          if (end != c.endFrame + raw) {
            snapAt = end;
          }
        case _Drag.reorder:
        case null:
          break;
      }
      return (frames: frames, atLimit: atLimit, snapAt: snapAt);
    }

    final (:frames, :atLimit, snapAt: _) = measure(mode.value, delta.value.dx);

    void begin(_Drag next) {
      controller.select(c.id);
      if (locked) {
        return;
      }
      mode.value = next;
      delta.value = Offset.zero;
    }

    void update(Offset d) {
      if (mode.value == null) {
        return;
      }
      delta.value += d;
      controller.snapLine.value = measure(mode.value, delta.value.dx).snapAt;
    }

    void cancel() {
      mode.value = null;
      delta.value = Offset.zero;
      controller.snapLine.value = null;
    }

    void end() {
      final current = mode.value;
      final dy = delta.value.dy;
      final moved = delta.value.distance > 3;
      final offset = measure(current, delta.value.dx).frames;
      final centre =
          c.startFrame + delta.value.dx / framePx + c.durationFrames / 2;
      cancel();
      if (current == null || !moved) {
        return;
      }
      editingRun(context, () {
        final next = switch (current) {
          _Drag.move => EditingCommands.move(
            doc,
            c.id,
            c.startFrame + offset,
            trackId: trackAt(c.trackId, dy),
          ),
          _Drag.reorder => EditingCommands.reorder(
            doc,
            c.id,
            EditingCommands.mainIndexAt(
              EditingCommands.remove(doc, c.id),
              centre.round(),
            ),
          ),
          _Drag.left => EditingCommands.trim(
            doc,
            c.id,
            c.startFrame + offset,
            c.endFrame,
          ),
          _Drag.right => EditingCommands.trim(
            doc,
            c.id,
            c.startFrame,
            c.endFrame + offset,
          ),
        };
        if (!identical(next, doc)) {
          controller.session.commit(next);
        }
      });
    }

    var left = c.startFrame * framePx;
    var width = c.durationFrames * framePx;
    var dy = 0.0;
    switch (mode.value) {
      case _Drag.move:
        left += frames * framePx;
        dy = delta.value.dy;
      case _Drag.reorder:
        left += delta.value.dx;
        dy = delta.value.dy.clamp(-6, 6);
      case _Drag.left:
        if (!track.main) {
          left += frames * framePx;
        }
        width -= frames * framePx;
      case _Drag.right:
        width += frames * framePx;
      case null:
        break;
    }
    final dragging = mode.value == _Drag.move || mode.value == _Drag.reorder;
    final trimming = mode.value == _Drag.left || mode.value == _Drag.right;
    final overlapping =
        mode.value == _Drag.move &&
        neighbours
            .where((o) => o.trackId == trackAt(c.trackId, dy))
            .any(
              (o) =>
                  o.startFrame < c.endFrame + frames &&
                  c.startFrame + frames < o.endFrame,
            );
    final tint = editingRoleColor(colors, track.role);
    final background = Color.lerp(colors.surface, tint, .16)!;
    final line = overlapping
        ? colors.error
        : selected
        ? colors.accent
        : Color.lerp(colors.surface, tint, .45)!;
    final ink = Color.lerp(colors.textPrimary, tint, .45)!;
    final visual = source != null && track.kind == 'video';

    Widget handle(_Drag side) => Positioned(
      left: side == _Drag.left ? 0 : null,
      right: side == _Drag.right ? 0 : null,
      top: 0,
      bottom: 0,
      width: selected ? 6 : 8,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: GestureDetector(
          dragStartBehavior: DragStartBehavior.down,
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) => begin(side),
          onHorizontalDragUpdate: (d) => update(Offset(d.delta.dx, 0)),
          onHorizontalDragEnd: (_) => end(),
          onHorizontalDragCancel: cancel,
          child: selected
              ? ColoredBox(
                  color: colors.accent,
                  child: Center(
                    child: Container(
                      width: 2,
                      height: 12,
                      decoration: BoxDecoration(
                        color: colors.onAccent,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                )
              : const SizedBox.expand(),
        ),
      ),
    );

    return Positioned(
      left: left,
      top: 4 + dy,
      width: math.max(4, width),
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Tooltip(
              message:
                  '${editingClipLabel(controller, c)} · ${editingDurationLabel(c.durationFrames)}',
              waitDuration: const Duration(milliseconds: 600),
              child: GestureDetector(
                dragStartBehavior: DragStartBehavior.down,
                onTap: () => controller.select(c.id),
                onPanStart: (_) =>
                    begin(track.main ? _Drag.reorder : _Drag.move),
                onPanUpdate: (d) => update(d.delta),
                onPanEnd: (_) => end(),
                onPanCancel: cancel,
                child: MouseRegion(
                  cursor: locked
                      ? SystemMouseCursors.basic
                      : dragging
                      ? SystemMouseCursors.grabbing
                      : SystemMouseCursors.grab,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 120),
                    opacity: track.hidden || track.muted ? .4 : 1,
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: background,
                        borderRadius: BorderRadius.circular(
                          RevericRadius.medium,
                        ),
                        border: Border.all(
                          color: line,
                          width: selected || overlapping ? 2 : 1,
                        ),
                        boxShadow: dragging
                            ? [
                                BoxShadow(
                                  color: colors.textPrimary.withValues(
                                    alpha: .18,
                                  ),
                                  blurRadius: 10,
                                  offset: const Offset(0, 3),
                                ),
                              ]
                            : null,
                      ),
                      child: Stack(
                        children: [
                          if (visual &&
                              source.mediaType == 'image' &&
                              controller.sourceFile(source) != null)
                            Positioned.fill(
                              child: _ImageStrip(
                                path: controller.sourceFile(source)!,
                                height: height,
                              ),
                            ),
                          if (track.kind == 'audio' ||
                              (visual &&
                                  !video!.audioDetached &&
                                  media!.gainDb != 0 &&
                                  source.hasAudio))
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _EnvelopePainter(
                                  color: tint,
                                  gainDb: media!.gainDb,
                                  fadeIn: media.fadeInFrames * framePx,
                                  fadeOut: media.fadeOutFrames * framePx,
                                ),
                              ),
                            ),
                          if (visual &&
                              (media!.fadeInFrames + media.fadeOutFrames) > 0)
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _FadePainter(
                                  color: colors.textPrimary.withValues(
                                    alpha: .3,
                                  ),
                                  fadeIn: media.fadeInFrames * framePx,
                                  fadeOut: media.fadeOutFrames * framePx,
                                ),
                              ),
                            ),
                          if (width > 20)
                            Positioned(
                              left: 6,
                              right: 6,
                              top: track.kind == 'text' ? 0 : 3,
                              bottom: track.kind == 'text' ? 0 : null,
                              child: Row(
                                children: [
                                  if (width > 32 &&
                                      visual &&
                                      source.mediaType == 'video')
                                    Padding(
                                      padding: const EdgeInsets.only(right: 4),
                                      child: RevericIcon(
                                        RevericIcons.movie_outlined,
                                        size: 11,
                                        color: ink,
                                      ),
                                    ),
                                  if (width > 32 && text?.style == 'title')
                                    Padding(
                                      padding: const EdgeInsets.only(right: 4),
                                      child: RevericIcon(
                                        RevericIcons.title,
                                        size: 11,
                                        color: ink,
                                      ),
                                    ),
                                  Flexible(
                                    child: Text(
                                      editingClipLabel(controller, c),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: typo.uiTinySemibold.copyWith(
                                        color: text != null
                                            ? colors.textPrimary
                                            : ink,
                                      ),
                                    ),
                                  ),
                                  if (width > 48 &&
                                      media != null &&
                                      media.speed != 1)
                                    Padding(
                                      padding: const EdgeInsets.only(left: 4),
                                      child: Text(
                                        editingSpeedLabel(media.speed),
                                        style: typo.uiTiny.copyWith(color: ink),
                                      ),
                                    ),
                                  if (width > 64 &&
                                      visual &&
                                      !track.main &&
                                      video!.opacity < 1)
                                    Padding(
                                      padding: const EdgeInsets.only(left: 4),
                                      child: Text(
                                        '${(video.opacity * 100).round()}%',
                                        style: typo.uiTiny.copyWith(color: ink),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          if (width > 56 && text == null)
                            Positioned(
                              right: 6,
                              bottom: 3,
                              child: Text(
                                editingDurationLabel(c.durationFrames),
                                style: typo.uiTiny.copyWith(
                                  color: ink,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (!locked) ...[handle(_Drag.left), handle(_Drag.right)],
          if (trimming)
            Positioned(
              left: mode.value == _Drag.left ? -40 : null,
              right: mode.value == _Drag.right ? -40 : null,
              top: -22,
              width: 80,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: atLimit ? colors.warningText : colors.textPrimary,
                    borderRadius: BorderRadius.circular(RevericRadius.small),
                  ),
                  child: Text(
                    atLimit
                        ? context.t(
                            LocaleKeys.editingSourceEdge,
                            namedArgs: {
                              'seconds': editingDurationLabel(
                                c.durationFrames +
                                    (mode.value == _Drag.left
                                        ? -frames
                                        : frames),
                              ),
                            },
                          )
                        : editingDurationLabel(
                            c.durationFrames +
                                (mode.value == _Drag.left ? -frames : frames),
                          ),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.visible,
                    style: typo.uiTinySemibold.copyWith(
                      color: colors.surface,
                      fontSize: 10,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 图片片段：沿片段宽度平铺缩略图。
class _ImageStrip extends StatelessWidget {
  const _ImageStrip({required this.path, required this.height});
  final String path;
  final double height;
  @override
  Widget build(BuildContext context) {
    final tile = math.max(18.0, height * 9 / 16);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          for (var x = 0.0; x < constraints.maxWidth; x += tile)
            SizedBox(
              width: math.min(tile, constraints.maxWidth - x),
              height: height,
              child: Image.file(
                File(path),
                fit: BoxFit.cover,
                alignment: Alignment.centerLeft,
                cacheHeight: (height * dpr).round(),
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
        ],
      ),
    );
  }
}

/// 音量包络：0 dB 在 30% 高度，-30 dB 贴底；淡入淡出从底部斜上。
class _EnvelopePainter extends CustomPainter {
  const _EnvelopePainter({
    required this.color,
    required this.gainDb,
    required this.fadeIn,
    required this.fadeOut,
  });
  final Color color;
  final double gainDb, fadeIn, fadeOut;
  @override
  void paint(Canvas canvas, Size size) {
    double y(double db) => (size.height * .3 + (-db / 30) * size.height * .65)
        .clamp(2, size.height - 2);
    final path = Path()..moveTo(0, y(gainDb - (fadeIn > 0 ? 30 : 0)));
    if (fadeIn > 0) {
      path.lineTo(fadeIn, y(gainDb));
    }
    if (fadeOut > 0) {
      path.lineTo(size.width - fadeOut, y(gainDb));
    }
    path.lineTo(size.width, y(gainDb - (fadeOut > 0 ? 30 : 0)));
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.25,
    );
  }

  @override
  bool shouldRepaint(_EnvelopePainter old) =>
      old.color != color ||
      old.gainDb != gainDb ||
      old.fadeIn != fadeIn ||
      old.fadeOut != fadeOut;
}

/// 画面淡入淡出：片段两端的三角暗角。
class _FadePainter extends CustomPainter {
  const _FadePainter({
    required this.color,
    required this.fadeIn,
    required this.fadeOut,
  });
  final Color color;
  final double fadeIn, fadeOut;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    if (fadeIn > 0) {
      canvas.drawPath(
        Path()
          ..moveTo(0, 0)
          ..lineTo(fadeIn, 0)
          ..lineTo(0, size.height)
          ..close(),
        paint,
      );
    }
    if (fadeOut > 0) {
      canvas.drawPath(
        Path()
          ..moveTo(size.width, 0)
          ..lineTo(size.width - fadeOut, 0)
          ..lineTo(size.width, size.height)
          ..close(),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_FadePainter old) =>
      old.color != color || old.fadeIn != fadeIn || old.fadeOut != fadeOut;
}

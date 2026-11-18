// 职责: 展示多轨时间线（工具条、刻度、轨道头、片段、播放头），把拖动、裁剪、拖入素材提交为单步命令。
// 关联文件:
//   lib/desktop/features/editing/controller.dart
//   lib/desktop/features/editing/clip.dart
//   lib/shared/services/editing/commands.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/performance.md
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/components/horizontal_wheel_scroll.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/editing/document.dart';
import '../../../shared/services/editing/commands.dart';
import '../../../shared/theme/theme.dart';
import 'clip.dart';
import 'controller.dart';
import 'support.dart';

const editingHeadWidth = 150.0;
const _rulerHeight = 38.0;
const _minPps = 6.0;
const _maxPps = 90.0;

double editingRowHeight(EditingTrack t) => t.main
    ? 64
    : t.kind == 'text'
    ? 32
    : t.kind == 'video'
    ? 46
    : 42;

/// 自上而下：字幕、视频（层级高的在上）、音频。
List<EditingTrack> editingOrderedTracks(EditingDocument doc) {
  int rank(EditingTrack t) => switch (t.kind) {
    'text' => 0,
    'video' => 1,
    _ => 2,
  };
  return [...doc.tracks]..sort(
    (a, b) => rank(a) != rank(b)
        ? rank(a).compareTo(rank(b))
        : a.kind == 'video'
        ? b.order.compareTo(a.order)
        : a.order.compareTo(b.order),
  );
}

/// 拖素材悬停在某条轨道上时的落点提示。
typedef _DropHint = ({String trackId, double x, double width, bool ok});

class EditingTimeline extends HookWidget {
  const EditingTimeline({super.key, required this.controller});
  final EditingController controller;
  @override
  Widget build(BuildContext context) {
    useListenable(controller);
    useListenable(controller.session);
    final pps = useState<double?>(null);
    final horizontal = useScrollController();
    final hint = useValueNotifier<_DropHint?>(null);
    final doc = controller.doc;
    final tracks = editingOrderedTracks(doc);
    final colors = RevericTheme.colorsOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = math.max(1.0, constraints.maxWidth - editingHeadWidth);
        double fit() => ((viewport - 8) / (doc.totalFrames / editingFps + 8))
            .clamp(_minPps, _maxPps);
        final secondPx = pps.value ?? fit();
        final framePx = secondPx / editingFps;
        final width = math.max(
          viewport,
          (doc.totalFrames / editingFps + 8) * secondPx,
        );
        double top(String trackId) {
          var y = 0.0;
          for (final t in tracks) {
            if (t.id == trackId) {
              return y;
            }
            y += editingRowHeight(t);
          }
          return y;
        }

        final lanesHeight = tracks.fold(0.0, (h, t) => h + editingRowHeight(t));
        // 拖动换轨：只能换到同类、非主轨、未锁定的轨道。
        String trackAt(String from, double dy) {
          final source = doc.track(from);
          final y = top(from) + editingRowHeight(source) / 2 + dy;
          var cursor = 0.0;
          for (final t in tracks) {
            final h = editingRowHeight(t);
            if (y >= cursor && y < cursor + h) {
              return t.kind == source.kind && !t.main && !t.locked
                  ? t.id
                  : from;
            }
            cursor += h;
          }
          return from;
        }

        return Column(
          children: [
            _Toolbar(
              controller: controller,
              pps: secondPx,
              onZoom: (v) => pps.value = v.clamp(_minPps, _maxPps),
              onFit: () => pps.value = fit(),
            ),
            Expanded(
              child: ColoredBox(
                color: colors.surfaceDim,
                child: SingleChildScrollView(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: editingHeadWidth,
                        child: Column(
                          children: [
                            _Corner(controller: controller),
                            for (final t in tracks)
                              _TrackHead(controller: controller, track: t),
                          ],
                        ),
                      ),
                      Expanded(
                        child: HorizontalWheelScroll(
                          controller: horizontal,
                          builder: (context, scroll) => Scrollbar(
                            controller: scroll,
                            child: SingleChildScrollView(
                              controller: scroll,
                              scrollDirection: Axis.horizontal,
                              child: _Follow(
                                controller: controller,
                                scroll: scroll,
                                framePx: framePx,
                                child: SizedBox(
                                  width: width,
                                  height: _rulerHeight + lanesHeight,
                                  child: Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      Positioned(
                                        left: 0,
                                        right: 0,
                                        top: 0,
                                        height: _rulerHeight,
                                        child: _Ruler(
                                          controller: controller,
                                          secondPx: secondPx,
                                        ),
                                      ),
                                      for (final t in tracks)
                                        Positioned(
                                          left: 0,
                                          right: 0,
                                          top: _rulerHeight + top(t.id),
                                          height: editingRowHeight(t),
                                          child: _Lane(
                                            controller: controller,
                                            track: t,
                                            framePx: framePx,
                                            hint: hint,
                                            trackAt: trackAt,
                                          ),
                                        ),
                                      _Playhead(
                                        controller: controller,
                                        framePx: framePx,
                                        height: lanesHeight,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.controller,
    required this.pps,
    required this.onZoom,
    required this.onFit,
  });
  final EditingController controller;
  final double pps;
  final ValueChanged<double> onZoom;
  final VoidCallback onFit;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final session = controller.session;
    // 窄宽度下带文字的按钮收成纯图标，缩放滑块让位。
    final narrow = MediaQuery.sizeOf(context).width < 900;
    Widget labeled(String icon, String label, VoidCallback? onPressed) => narrow
        ? RevericIconButton(icon: icon, tooltip: label, onPressed: onPressed)
        : RevericButton.text(
            icon: icon,
            label: label,
            size: RevericButtonSize.compact,
            onPressed: onPressed,
          );
    Widget separator() => Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: RevericSpacing.xs),
      color: colors.borderSubtle,
    );
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.md),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        border: Border(bottom: BorderSide(color: colors.borderSubtle)),
      ),
      child: Row(
        children: [
          RevericIconButton(
            icon: RevericIcons.undo,
            tooltip: context.t(LocaleKeys.editingUndo),
            onPressed: session.canUndo ? session.undo : null,
          ),
          RevericIconButton(
            icon: RevericIcons.redo,
            tooltip: context.t(LocaleKeys.editingRedo),
            onPressed: session.canRedo ? session.redo : null,
          ),
          separator(),
          ValueListenableBuilder<int>(
            valueListenable: controller.playhead,
            builder: (context, _, _) => labeled(
              RevericIcons.scissors_outlined,
              context.t(LocaleKeys.editingSplit),
              controller.splitTarget == null
                  ? null
                  : () => controller.split(context),
            ),
          ),
          labeled(
            RevericIcons.delete_outline,
            context.t(LocaleKeys.commonDelete),
            session.selected == null ? null : () => controller.remove(context),
          ),
          separator(),
          _Toggle(
            icon: RevericIcons.magnet,
            tooltip: context.t(
              controller.snap
                  ? LocaleKeys.editingSnapOn
                  : LocaleKeys.editingSnapOff,
            ),
            on: controller.snap,
            size: 28,
            onTap: controller.toggleSnap,
          ),
          labeled(
            RevericIcons.add,
            context.t(LocaleKeys.editingTextTrack),
            () => controller.addTextTrack(context),
          ),
          labeled(
            RevericIcons.add,
            context.t(LocaleKeys.editingAudioTrack),
            () => controller.addAudioTrack(context),
          ),
          const Spacer(),
          RevericIconButton(
            icon: RevericIcons.remove,
            tooltip: context.t(LocaleKeys.editingZoomOut),
            onPressed: () => onZoom(pps / 1.4),
          ),
          if (!narrow)
            SizedBox(
              width: 96,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  overlayShape: SliderComponentShape.noOverlay,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                  trackHeight: 3,
                ),
                child: Slider(
                  value: math
                      .log(pps)
                      .clamp(math.log(_minPps), math.log(_maxPps)),
                  min: math.log(_minPps),
                  max: math.log(_maxPps),
                  onChanged: (v) => onZoom(math.exp(v)),
                ),
              ),
            ),
          RevericIconButton(
            icon: RevericIcons.add,
            tooltip: context.t(LocaleKeys.editingZoomIn),
            onPressed: () => onZoom(pps * 1.4),
          ),
          RevericIconButton(
            icon: RevericIcons.arrows_in,
            tooltip: context.t(LocaleKeys.editingFit),
            onPressed: onFit,
          ),
        ],
      ),
    );
  }
}

/// 轨道头上的小开关（锁定、静音、隐藏），比普通图标按钮紧凑，开启时带选中底色。
class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.icon,
    required this.tooltip,
    required this.on,
    required this.onTap,
    this.size = 22,
  });
  final String icon, tooltip;
  final bool on;
  final VoidCallback? onTap;
  final double size;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: on ? colors.selected : Colors.transparent,
        borderRadius: BorderRadius.circular(RevericRadius.small),
        child: InkWell(
          borderRadius: BorderRadius.circular(RevericRadius.small),
          onTap: onTap,
          child: SizedBox.square(
            dimension: size,
            child: Center(
              child: RevericIcon(
                icon,
                size: size > 24 ? 15 : 12,
                color: on ? colors.accentWarm : colors.textSubtle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Corner extends StatelessWidget {
  const _Corner({required this.controller});
  final EditingController controller;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      height: _rulerHeight,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.md),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        border: Border(
          right: BorderSide(color: colors.border),
          bottom: BorderSide(color: colors.borderSubtle),
        ),
      ),
      child: ValueListenableBuilder<int>(
        valueListenable: controller.playhead,
        builder: (context, frame, _) => Text(
          editingTimecode(frame),
          style: typo.mono.copyWith(
            color: colors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _TrackHead extends StatelessWidget {
  const _TrackHead({required this.controller, required this.track});
  final EditingController controller;
  final EditingTrack track;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final t = track;
    return Container(
      height: editingRowHeight(t),
      padding: const EdgeInsets.only(left: RevericSpacing.md, right: 4),
      decoration: BoxDecoration(
        color: t.main ? colors.surfaceContainerHigh : colors.surface,
        border: Border(
          right: BorderSide(color: colors.border),
          bottom: BorderSide(color: colors.borderSubtle),
        ),
      ),
      child: Row(
        children: [
          RevericIcon(
            editingTrackIcon(t),
            size: 13,
            color: colors.textSecondary,
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    editingTrackName(context, t),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.uiSmallSemibold.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  editingTrackCode(t),
                  style: typo.uiTiny.copyWith(color: colors.textSubtle),
                ),
              ],
            ),
          ),
          if (t.main)
            Tooltip(
              message: context.t(LocaleKeys.editingMagnetHint),
              child: SizedBox(
                width: 20,
                child: RevericIcon(
                  RevericIcons.magnet,
                  size: 12,
                  color: colors.accent,
                ),
              ),
            ),
          if (t.kind == 'text')
            _Toggle(
              icon: RevericIcons.add,
              tooltip: context.t(
                t.role == EditingRole.subtitle
                    ? LocaleKeys.editingAddSubtitle
                    : LocaleKeys.editingAddText,
              ),
              on: false,
              onTap: t.locked ? null : () => controller.addText(context, t),
            ),
          if (t.role == EditingRole.audio || t.role == EditingRole.text)
            _Toggle(
              icon: RevericIcons.close,
              tooltip: context.t(LocaleKeys.editingRemoveTrack),
              on: false,
              onTap: t.locked
                  ? null
                  : () => editingRun(
                      context,
                      () => controller.session.commit(
                        EditingCommands.removeTrack(controller.doc, t.id),
                      ),
                    ),
            ),
          _Toggle(
            icon: RevericIcons.lock_simple,
            tooltip: context.t(
              t.locked ? LocaleKeys.editingUnlock : LocaleKeys.editingLock,
            ),
            on: t.locked,
            onTap: () =>
                controller.changeTrack(context, t.copyWith(locked: !t.locked)),
          ),
          if (t.kind == 'audio')
            _Toggle(
              icon: t.muted
                  ? RevericIcons.speaker_slash
                  : RevericIcons.speaker_high,
              tooltip: context.t(
                t.muted ? LocaleKeys.editingUnmute : LocaleKeys.editingMute,
              ),
              on: t.muted,
              onTap: t.locked
                  ? null
                  : () => controller.changeTrack(
                      context,
                      t.copyWith(muted: !t.muted),
                    ),
            )
          else
            _Toggle(
              icon: t.hidden
                  ? RevericIcons.visibility_off
                  : RevericIcons.visibility,
              tooltip: context.t(
                t.hidden ? LocaleKeys.editingShow : LocaleKeys.editingHide,
              ),
              on: t.hidden,
              onTap: t.locked
                  ? null
                  : () => controller.changeTrack(
                      context,
                      t.copyWith(hidden: !t.hidden),
                    ),
            ),
        ],
      ),
    );
  }
}

/// 播放头跑出可视区时把时间线翻过去跟上。
class _Follow extends HookWidget {
  const _Follow({
    required this.controller,
    required this.scroll,
    required this.framePx,
    required this.child,
  });
  final EditingController controller;
  final ScrollController scroll;
  final double framePx;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    useOnListenableChange(controller.playhead, () {
      if (!scroll.hasClients) {
        return;
      }
      final x = controller.playhead.value * framePx;
      final position = scroll.position;
      if (x > position.pixels + position.viewportDimension - 40 ||
          x < position.pixels) {
        scroll.jumpTo(
          (x - 40).clamp(position.minScrollExtent, position.maxScrollExtent),
        );
      }
    });
    return child;
  }
}

class _Ruler extends StatelessWidget {
  const _Ruler({required this.controller, required this.secondPx});
  final EditingController controller;
  final double secondPx;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final framePx = secondPx / editingFps;
    final labelEvery = secondPx < 9
        ? 10
        : secondPx < 20
        ? 5
        : secondPx < 45
        ? 2
        : 1;
    final tickEvery = labelEvery >= 5
        ? 1.0
        : labelEvery == 2
        ? .5
        : .25;
    void scrub(Offset local) => controller.seek((local.dx / framePx).round());
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => scrub(d.localPosition),
        onHorizontalDragUpdate: (d) => scrub(d.localPosition),
        child: MouseRegion(
          cursor: SystemMouseCursors.text,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceContainer,
              border: Border(bottom: BorderSide(color: colors.borderSubtle)),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _TickPainter(
                      color: colors.borderInput,
                      every: tickEvery * secondPx,
                    ),
                  ),
                ),
                for (
                  var s = 0;
                  s * secondPx < constraints.maxWidth;
                  s += labelEvery
                )
                  Positioned(
                    left: s * secondPx,
                    bottom: 6,
                    child: Container(
                      height: 10,
                      padding: const EdgeInsets.only(left: 3),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(color: colors.textSubtle),
                        ),
                      ),
                      child: Text(
                        '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}',
                        style: typo.uiTiny.copyWith(
                          color: colors.textSubtle,
                          fontSize: 10,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: controller.doc.totalFrames * framePx,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 1, color: colors.textMuted),
                ),
                ValueListenableBuilder<int>(
                  valueListenable: controller.playhead,
                  builder: (context, frame, _) => Positioned(
                    left: frame * framePx - 5.5,
                    bottom: 0,
                    child: CustomPaint(
                      size: const Size(11, 15),
                      painter: _KnobPainter(colors.accentWarm),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TickPainter extends CustomPainter {
  const _TickPainter({required this.color, required this.every});
  final Color color;
  final double every;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (var x = 0.0; x < size.width; x += every) {
      canvas.drawRect(Rect.fromLTWH(x, size.height - 5, 1, 5), paint);
    }
  }

  @override
  bool shouldRepaint(_TickPainter old) =>
      old.color != color || old.every != every;
}

class _KnobPainter extends CustomPainter {
  const _KnobPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height * .6)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(0, size.height * .6)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_KnobPainter old) => old.color != color;
}

class _Playhead extends StatelessWidget {
  const _Playhead({
    required this.controller,
    required this.framePx,
    required this.height,
  });
  final EditingController controller;
  final double framePx;
  final double height;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            ValueListenableBuilder<int>(
              valueListenable: controller.playhead,
              builder: (context, frame, _) => Positioned(
                left: frame * framePx,
                top: _rulerHeight,
                height: height,
                child: Container(width: 1, color: colors.accentWarm),
              ),
            ),
            ValueListenableBuilder<int?>(
              valueListenable: controller.snapLine,
              builder: (context, frame, _) => frame == null
                  ? const SizedBox.shrink()
                  : Positioned(
                      left: frame * framePx,
                      top: _rulerHeight,
                      height: height,
                      child: CustomPaint(
                        size: Size(1, height),
                        painter: _DashPainter(colors.warningText),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DashPainter extends CustomPainter {
  const _DashPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (var y = 0.0; y < size.height; y += 6) {
      canvas.drawRect(Rect.fromLTWH(0, y, 1, 3), paint);
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
}

class _Lane extends StatelessWidget {
  const _Lane({
    required this.controller,
    required this.track,
    required this.framePx,
    required this.hint,
    required this.trackAt,
  });
  final EditingController controller;
  final EditingTrack track;
  final double framePx;
  final ValueNotifier<_DropHint?> hint;
  final String Function(String from, double dy) trackAt;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final doc = controller.doc;
    final t = track;
    final clips = doc.clips.where((c) => c.trackId == t.id).toList();
    int frameAt(Offset global) {
      final box = context.findRenderObject()! as RenderBox;
      return math.max(0, (box.globalToLocal(global).dx / framePx).round());
    }

    return DragTarget<EditingMedia>(
      onWillAcceptWithDetails: (_) => true,
      onMove: (d) {
        final frame = frameAt(d.offset);
        hint.value = (
          trackId: t.id,
          x: frame * framePx,
          width: math.max(16, 3 * editingFps * framePx),
          ok: !t.locked && EditingController.accepts(t, d.data.type),
        );
      },
      onLeave: (_) {
        if (hint.value?.trackId == t.id) {
          hint.value = null;
        }
      },
      onAcceptWithDetails: (d) {
        hint.value = null;
        editingRun(
          context,
          () => controller.place(context, d.data, t.id, frameAt(d.offset)),
        );
      },
      builder: (context, _, _) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) {
          controller.select(null);
          controller.seek((d.localPosition.dx / framePx).round());
        },
        child: Container(
          decoration: BoxDecoration(
            color: t.main ? colors.surfaceContainer : null,
            border: Border(bottom: BorderSide(color: colors.borderSubtle)),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (t.locked)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _HatchPainter(colors.borderSubtle),
                  ),
                ),
              for (final c in clips)
                EditingTimelineClip(
                  key: ValueKey(c.id),
                  controller: controller,
                  clip: c,
                  track: t,
                  framePx: framePx,
                  height: editingRowHeight(t) - 8,
                  trackAt: trackAt,
                ),
              ValueListenableBuilder<_DropHint?>(
                valueListenable: hint,
                builder: (context, h, _) => h == null || h.trackId != t.id
                    ? const SizedBox.shrink()
                    : Positioned(
                        left: h.x,
                        top: 4,
                        bottom: 4,
                        width: h.width,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: (h.ok ? colors.accent : colors.error)
                                  .withValues(alpha: .12),
                              border: Border.all(
                                color: h.ok ? colors.accent : colors.error,
                              ),
                              borderRadius: BorderRadius.circular(
                                RevericRadius.medium,
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HatchPainter extends CustomPainter {
  const _HatchPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    canvas.clipRect(Offset.zero & size);
    for (var x = -size.height; x < size.width; x += 7) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_HatchPainter old) => old.color != color;
}

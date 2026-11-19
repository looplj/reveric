// 职责: 关键帧时间轴 — 播放控制、选区标尺，按对象分组展示运镜、朝向、位置、旋转与姿态轨。
// 关联文件:
//   lib/shared/services/director/session.dart
//   lib/shared/services/director/commands.dart
//   lib/shared/widgets/director/track_editor.dart
//   lib/shared/widgets/director/timeline_bar.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/performance.md
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../components/horizontal_wheel_scroll.dart';
import '../../models/director/document.dart';
import '../../models/director/sampling.dart';
import '../../services/director/session.dart';
import '../../theme/theme.dart';
import 'inspector/controls.dart';
import 'panels/common.dart';
import 'strings.dart';
import 'timeline_bar.dart';
import 'track_editor.dart';

enum ClipDragMode {
  move,
  // ignore: constant_identifier_names
  trim_start,
  // ignore: constant_identifier_names
  trim_end,
}

class ClipDrag {
  final int start, end, generation, pointer;
  final double downX, pixelsPerFrame;
  final ClipDragMode mode;
  bool moved = false, valid = true;
  ClipDrag({
    required Json clip,
    required PointerDownEvent event,
    required this.generation,
    required this.pixelsPerFrame,
    required this.mode,
  }) : start = clip['start_frame'],
       end = clip['end_frame'],
       downX = event.position.dx,
       pointer = event.pointer;

  (int, int) interval(double x) {
    final delta = ((x - downX) / pixelsPerFrame).round();
    return switch (mode) {
      ClipDragMode.move => (start + delta, end + delta),
      ClipDragMode.trim_start => (start + delta, end),
      ClipDragMode.trim_end => (start, end + delta),
    };
  }
}

/// 一行轨道：头行（对象）或子行（某个属性 / 片段列表）。
class _Lane {
  _Lane({
    required this.owner,
    required this.label,
    this.head = false,
    this.icon,
    this.color,
    this.open = false,
    this.track,
    this.segments,
    this.value,
    this.property,
  });
  final String owner, label;
  final bool head, open;
  final String? icon, color;
  final Json? track;

  /// 片段所在列表：motion_paths 或 camera_moves。
  final String? segments;

  /// 播放头处的读数。
  final String Function(FrameSample sample)? value;

  /// 可在行头打关键帧的属性。
  final String? property;
}

class DirectorTimeline extends HookWidget {
  final DirectorSession session;
  const DirectorTimeline({super.key, required this.session});
  @override
  Widget build(BuildContext context) {
    useListenable(session);
    final zoom = useState(1.0);
    final collapsed = useState(<String>{});
    final focus = useFocusNode();
    final ruler = useScrollController(), lanes = useScrollController();
    useEffect(() {
      var syncing = false;
      void link(ScrollController from, ScrollController to) {
        if (syncing || !to.hasClients || !from.hasClients) {
          return;
        }
        syncing = true;
        to.jumpTo(from.offset.clamp(0, to.position.maxScrollExtent));
        syncing = false;
      }

      void a() => link(lanes, ruler);
      void b() => link(ruler, lanes);
      lanes.addListener(a);
      ruler.addListener(b);
      return () {
        lanes.removeListener(a);
        ruler.removeListener(b);
      };
    }, [ruler, lanes]);
    final document = session.history.document;
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final tracks = document.tracks;
    Json? track(String id, String property) => tracks
        .where((t) => t['target_id'] == id && t['property'] == property)
        .firstOrNull;
    String deg(num rad) =>
        '${(((rad * 180 / math.pi).round() % 360) + 540) % 360 - 180}°';
    final rows = <_Lane>[
      _Lane(
        owner: document.id,
        label: tr(context, 'camera_cuts'),
        icon: RevericIcons.video_camera,
      ),
    ];
    for (final t in tracks.where((t) => t['target_id'] == document.id)) {
      rows.add(
        _Lane(
          owner: document.id,
          label: tr(context, t['property']),
          track: t,
          property: t['property'],
        ),
      );
    }
    for (final c in document.activeCameras) {
      final id = c['id'] as String, open = !collapsed.value.contains(id);
      rows.add(
        _Lane(
          owner: id,
          label: c['name'],
          head: true,
          icon: RevericIcons.video_camera,
          open: open,
          segments: open ? null : 'camera_moves',
        ),
      );
      if (!open) {
        continue;
      }
      rows.add(
        _Lane(
          owner: id,
          label: tr(context, 'camera_moves'),
          segments: 'camera_moves',
        ),
      );
      final heading = c['orientation_mode'] == 'free'
          ? 'rotation'
          : 'camera_target';
      rows.add(
        _Lane(
          owner: id,
          label: tr(context, 'heading'),
          track: track(id, heading),
          property: heading,
          value: (s) {
            final cam = s.cameras[id]!;
            final p = cam['position'] as List, t = cam['target'] as List;
            return deg(math.atan2(t[0] - p[0], t[2] - p[2]));
          },
        ),
      );
      for (final property in [
        'position',
        'focal_length_mm',
        'focus_distance_m',
        'aperture_fstop',
        if (c['orientation_mode'] == 'look_at') 'roll',
      ]) {
        final t = track(id, property);
        if (t != null) {
          rows.add(
            _Lane(
              owner: id,
              label: tr(
                context,
                property == 'focal_length_mm' ? 'focal' : property,
              ),
              track: t,
              property: property,
              value: (s) => property == 'position'
                  ? (s.cameras[id]!['position'] as List)
                        .map((v) => (v as num).toStringAsFixed(1))
                        .join(', ')
                  : '${(s.cameras[id]![property] as num).toStringAsFixed(1)}${switch (property) {
                      'roll' => '°',
                      'focus_distance_m' => 'm',
                      'aperture_fstop' => 'f',
                      _ => 'mm',
                    }}',
            ),
          );
        }
      }
    }
    for (final o in document.objects) {
      final id = o['id'] as String, open = !collapsed.value.contains(id);
      final actor = o['kind'] == 'actor';
      rows.add(
        _Lane(
          owner: id,
          label: o['name'],
          head: true,
          color: actor ? o['color'] : null,
          icon: actor ? null : RevericIcons.cube,
          open: open,
          segments: actor && !open ? 'motion_paths' : null,
        ),
      );
      if (!open) {
        continue;
      }
      Map<String, dynamic> at(FrameSample s) =>
          s.objects.firstWhere((x) => x['id'] == id);
      rows.add(
        _Lane(
          owner: id,
          label: tr(context, 'position'),
          track: track(id, 'position'),
          property: 'position',
          value: (s) {
            final p = at(s)['position'] as List;
            return p.map((v) => (v as num).toStringAsFixed(1)).join(', ');
          },
        ),
      );
      rows.add(
        _Lane(
          owner: id,
          label: tr(context, 'rotation'),
          track: track(id, 'rotation'),
          property: 'rotation',
          value: (s) => quaternionEuler(at(s)['rotation']).map(deg).join(', '),
        ),
      );
      for (final property in ['scale', 'color', 'visible', if (actor) 'pose']) {
        final value = track(id, property);
        if (value != null || property == 'pose') {
          rows.add(
            _Lane(
              owner: id,
              label: tr(context, property),
              track: value,
              property: property,
            ),
          );
        }
      }
      if (actor) {
        rows.add(
          _Lane(
            owner: id,
            label: tr(context, 'path'),
            segments: 'motion_paths',
          ),
        );
      }
    }
    final keyFrames = <int>{
      for (final t in tracks.where((t) => t['target_id'] == session.selected))
        for (final k in t['keys']) k['frame'] as int,
    }.toList()..sort();
    void jump(int direction) {
      final f = session.frame.value;
      final next = direction > 0
          ? keyFrames.where((k) => k > f).firstOrNull
          : keyFrames.reversed.where((k) => k < f).firstOrNull;
      if (next != null) {
        session.seek(next);
      }
    }

    double rowHeight(_Lane r) => r.head
        ? RevericSizes.directorTimelineHeadHeight
        : RevericSizes.directorTimelineRowHeight;
    final contentHeight = rows.fold<double>(0, (h, r) => h + rowHeight(r));
    final (rangeStart, rangeEnd) = session.range;
    return Focus(
      focusNode: focus,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          session.history.cancelGesture();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          border: Border(top: BorderSide(color: colors.border)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 700;
            final labelWidth = compact
                ? RevericSizes.directorTimelineCompactLabelWidth
                : RevericSizes.directorTimelineLabelWidth;
            // 标尺与轨道右侧留同样的空白，两边滚动范围一致才能对齐。
            const trailing = RevericSpacing.lg;
            final available = math.max(
              1.0,
              constraints.maxWidth - labelWidth - trailing,
            );
            final plotWidth = available * zoom.value;
            final scale = plotWidth / document.durationFrames;
            int frameAt(double x) =>
                (x / scale).round().clamp(0, document.durationFrames);
            final seconds = document.durationFrames / document.fps;
            final tickEvery = zoom.value >= 2 ? 1 : 2;
            Widget band(double top, double height, Color color) => Positioned(
              left: rangeStart * scale,
              width: math.max(1, (rangeEnd - rangeStart) * scale),
              top: top,
              height: height,
              child: IgnorePointer(child: ColoredBox(color: color)),
            );
            final bar = SizedBox(
              height: RevericSizes.directorTimelineRulerHeight,
              child: Row(
                children: [
                  SizedBox(width: labelWidth),
                  Expanded(
                    child: SingleChildScrollView(
                      controller: ruler,
                      scrollDirection: Axis.horizontal,
                      physics: const NeverScrollableScrollPhysics(),
                      child: _Ruler(
                        session: session,
                        width: plotWidth,
                        scale: scale,
                        frameAt: frameAt,
                        children: [
                          Positioned(
                            left: rangeStart * scale,
                            width: math.max(1, (rangeEnd - rangeStart) * scale),
                            top: RevericSpacing.xxs,
                            height: RevericSpacing.xs,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: colors.accent.withValues(alpha: 0.45),
                                  borderRadius: BorderRadius.circular(
                                    RevericRadius.small,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          for (var i = 0; i <= seconds.floor(); i++)
                            Positioned(
                              left: i * document.fps * scale,
                              top: RevericSpacing.md,
                              bottom: 0,
                              child: IgnorePointer(
                                child: Container(
                                  padding: const EdgeInsets.only(
                                    left: RevericSpacing.xxs,
                                  ),
                                  decoration: BoxDecoration(
                                    border: Border(
                                      left: BorderSide(
                                        color: colors.borderSubtle,
                                      ),
                                    ),
                                  ),
                                  child: Text(
                                    i % tickEvery == 0 ? '${i}s' : '',
                                    style: typo.uiTiny.copyWith(
                                      color: colors.textMuted,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          _Playline(session: session, scale: scale),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: trailing),
                ],
              ),
            );
            final labels = Column(
              children: [
                for (final r in rows)
                  _Label(
                    key: ValueKey('director-lane-label:${r.owner}:${r.label}'),
                    session: session,
                    lane: r,
                    width: labelWidth,
                    height: rowHeight(r),
                    onToggle: () {
                      final next = {...collapsed.value};
                      if (!next.remove(r.owner)) {
                        next.add(r.owner);
                      }
                      collapsed.value = next;
                    },
                  ),
              ],
            );
            final plot = Column(
              children: [
                for (final r in rows)
                  SizedBox(
                    key: r.owner == document.id && r.track == null
                        ? const ValueKey('director-cut-lane')
                        : r.head
                        ? ValueKey('clip-lane:${r.owner}')
                        : r.track != null
                        ? ValueKey('key-lane:${r.track!['id']}')
                        : r.segments != null
                        ? ValueKey('segment-lane:${r.owner}')
                        : null,
                    width: plotWidth,
                    height: rowHeight(r),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: r.head
                            ? colors.surfaceDim
                            : colors.surfaceContainer,
                        border: Border(
                          bottom: BorderSide(color: colors.borderSubtle),
                        ),
                      ),
                      child: Stack(
                        clipBehavior: Clip.hardEdge,
                        children: [
                          Positioned.fill(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapDown: (d) =>
                                  session.seek(frameAt(d.localPosition.dx)),
                            ),
                          ),
                          band(
                            0,
                            rowHeight(r),
                            colors.accent.withValues(alpha: 0.06),
                          ),
                          if (r.owner == document.id && r.track == null)
                            for (final cut in document.cuts)
                              Positioned(
                                left: (cut['frame'] as int) * scale,
                                top: 0,
                                bottom: 0,
                                child: Tooltip(
                                  message: document.camera(
                                    cut['camera_id'],
                                  )!['name'],
                                  child: InkWell(
                                    key: ValueKey(
                                      'director-cut-marker:${cut['id']}',
                                    ),
                                    onTap: () {
                                      session.seek(cut['frame']);
                                      session.select(null);
                                      session.viewCamera(null);
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: RevericSpacing.xxs,
                                      ),
                                      decoration: BoxDecoration(
                                        border: Border(
                                          left: BorderSide(
                                            color: colors.accent,
                                          ),
                                        ),
                                      ),
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        document.camera(
                                          cut['camera_id'],
                                        )!['name'],
                                        style: typo.uiTiny,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          if (r.segments != null)
                            for (final seg
                                in (r.segments == 'camera_moves'
                                        ? document.moves
                                        : document.paths)
                                    .where(
                                      (x) =>
                                          x[r.segments == 'camera_moves'
                                              ? 'camera_id'
                                              : 'target_id'] ==
                                          r.owner,
                                    ))
                              _ClipRegion(
                                key: ValueKey('clip-region:${seg['id']}'),
                                session: session,
                                clip: seg,
                                list: r.segments!,
                                scale: scale,
                                height: rowHeight(r) - 2 * 3,
                                focus: focus,
                              ),
                          if (r.track != null) ...[
                            Positioned(
                              left:
                                  (r.track!['keys'] as List).first['frame'] *
                                  scale,
                              width: math.max(
                                0,
                                ((r.track!['keys'] as List).last['frame'] -
                                        (r.track!['keys'] as List)
                                            .first['frame']) *
                                    scale,
                              ),
                              top: rowHeight(r) / 2 - 0.5,
                              height: 1,
                              child: IgnorePointer(
                                child: ColoredBox(
                                  color: colors.accent.withValues(alpha: 0.5),
                                ),
                              ),
                            ),
                            for (final keyframe in r.track!['keys'])
                              Positioned(
                                left:
                                    (keyframe['frame'] as int) * scale -
                                    RevericSizes.directorKeyButton / 2,
                                top:
                                    (rowHeight(r) -
                                        RevericSizes.directorKeyButton) /
                                    2,
                                child: GestureDetector(
                                  onTap: () => session.seek(keyframe['frame']),
                                  onDoubleTap: session.readOnly
                                      ? null
                                      : () => editTrackOrClip(
                                          context,
                                          session,
                                          r.track!,
                                        ),
                                  child: SizedBox.square(
                                    dimension: RevericSizes.directorKeyButton,
                                    child: Center(
                                      child: Transform.rotate(
                                        angle: math.pi / 4,
                                        child: Container(
                                          width: RevericSpacing.sm,
                                          height: RevericSpacing.sm,
                                          color: colors.accent,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                          _Playline(session: session, scale: scale),
                        ],
                      ),
                    ),
                  ),
              ],
            );
            final toolbar = DirectorTimelineBar(
              session: session,
              zoom: zoom.value,
              compact: compact,
              onJump: jump,
              onZoom: (value) => zoom.value = value.clamp(
                DirectorTimelineBar.minZoom,
                DirectorTimelineBar.maxZoom,
              ),
            );
            if (!session.history.timelineVisible) {
              return toolbar;
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                toolbar,
                Divider(height: 1, color: colors.borderSubtle),
                bar,
                Divider(height: 1, color: colors.borderSubtle),
                SizedBox(
                  height: math.min(
                    contentHeight,
                    RevericSizes.directorTimelineMaxHeight,
                  ),
                  child: SingleChildScrollView(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        labels,
                        Expanded(
                          child: HorizontalWheelScroll(
                            controller: lanes,
                            builder: (context, controller) =>
                                SingleChildScrollView(
                                  controller: controller,
                                  scrollDirection: Axis.horizontal,
                                  child: Padding(
                                    padding: const EdgeInsets.only(
                                      right: trailing,
                                    ),
                                    child: plot,
                                  ),
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 标尺：单击 / 拖动定位播放头，按住 Shift 拖动设置选区，双击清除选区。
class _Ruler extends HookWidget {
  const _Ruler({
    required this.session,
    required this.width,
    required this.scale,
    required this.frameAt,
    required this.children,
  });
  final DirectorSession session;
  final double width, scale;
  final int Function(double x) frameAt;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final anchor = useRef<int?>(null);
    return GestureDetector(
      key: const ValueKey('director-time-ruler'),
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => session.seek(frameAt(d.localPosition.dx)),
      onDoubleTap: session.readOnly ? null : () => session.setRange(0, 0),
      onHorizontalDragStart: (d) {
        anchor.value =
            !session.readOnly && HardwareKeyboard.instance.isShiftPressed
            ? frameAt(d.localPosition.dx)
            : null;
      },
      onHorizontalDragUpdate: (d) {
        final f = frameAt(d.localPosition.dx);
        if (anchor.value != null) {
          session.setRange(anchor.value!, f);
        } else {
          session.seek(f);
        }
      },
      child: SizedBox(
        width: width,
        height: RevericSizes.directorTimelineRulerHeight,
        child: Stack(clipBehavior: Clip.none, children: children),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label({
    super.key,
    required this.session,
    required this.lane,
    required this.width,
    required this.height,
    required this.onToggle,
  });
  final DirectorSession session;
  final _Lane lane;
  final double width, height;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final selected = lane.owner == session.selected;
    final style = lane.head
        ? typo.uiSmallSemibold.copyWith(
            color: selected ? colors.accentWarm : colors.textPrimary,
          )
        : typo.uiSmall.copyWith(color: colors.textSecondary);
    return Material(
      color: lane.head
          ? colors.surfaceDim
          : selected
          ? colors.selected.withValues(alpha: 0.5)
          : Colors.transparent,
      child: InkWell(
        onTap: () {
          if (lane.owner == session.history.document.id) {
            session.select(null);
            session.viewCamera(null);
          } else {
            session.select(lane.owner);
          }
        },
        child: Container(
          width: width,
          height: height,
          padding: EdgeInsets.only(
            left: lane.head
                ? RevericSpacing.xs
                : RevericSpacing.x5l + RevericSpacing.xxs,
            right: RevericSpacing.xs,
          ),
          decoration: BoxDecoration(
            border: Border(
              right: BorderSide(color: colors.borderSubtle),
              bottom: BorderSide(color: colors.borderSubtle),
            ),
          ),
          child: Row(
            children: [
              if (lane.head)
                InkWell(
                  onTap: onToggle,
                  child: Padding(
                    padding: const EdgeInsets.all(RevericSpacing.xxs),
                    child: RevericIcon(
                      lane.open
                          ? RevericIcons.caret_down
                          : RevericIcons.caret_right,
                      size: RevericSizes.directorSmallIcon,
                      color: colors.textMuted,
                    ),
                  ),
                ),
              if (lane.color != null) ...[
                Swatch(lane.color!),
                const SizedBox(width: RevericSpacing.xs),
              ],
              if (lane.icon != null) ...[
                RevericIcon(
                  lane.icon!,
                  size: RevericSizes.directorSmallIcon,
                  color: selected ? colors.accentWarm : colors.textMuted,
                ),
                const SizedBox(width: RevericSpacing.xs),
              ],
              Expanded(
                child: Text(
                  lane.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
              if (lane.value != null &&
                  width > RevericSizes.directorTimelineCompactLabelWidth)
                Expanded(
                  child: ValueListenableBuilder(
                    valueListenable: session.frame,
                    builder: (context, frame, _) {
                      String value;
                      try {
                        value = lane.value!(
                          sampleDocument(session.history.document, frame),
                        );
                      } on DocumentError catch (error) {
                        value = tr(context, '${error.path}: ${error.reason}');
                      }
                      return Tooltip(
                        message: value,
                        child: Text(
                          value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end,
                          style: typo.uiTiny.copyWith(
                            color: colors.textMuted,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              if (!session.readOnly && lane.property != null) ...[
                const SizedBox(width: RevericSpacing.xs),
                ValueListenableBuilder(
                  valueListenable: session.frame,
                  builder: (context, frame, _) => KeyButton(
                    key: ValueKey(
                      'director-lane-key:${lane.owner}:${lane.property}',
                    ),
                    state: keyState(session, lane.owner, lane.property!),
                    tooltip: tr(context, 'toggle_key'),
                    onPressed:
                        session.playing ||
                            session.history.controlled(
                              lane.owner,
                              lane.property!,
                              frame,
                            )
                        ? null
                        : () => session.attempt(
                            () => session.history.toggleKey(
                              lane.owner,
                              lane.property!,
                              frame,
                            ),
                          ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Playline extends StatelessWidget {
  const _Playline({required this.session, required this.scale});
  final DirectorSession session;
  final double scale;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: session.frame,
    builder: (context, frame, _) => Positioned(
      left: math.max(0, frame * scale - 1),
      top: 0,
      bottom: 0,
      child: IgnorePointer(
        child: ColoredBox(
          color: RevericTheme.colorsOf(context).accent,
          child: const SizedBox(width: 1),
        ),
      ),
    ),
  );
}

class _ClipRegion extends HookWidget {
  final DirectorSession session;
  final Json clip;

  /// 片段所在列表：motion_paths（人物路径）或 camera_moves（运镜）。
  final String list;
  final double scale, height;
  final FocusNode focus;
  const _ClipRegion({
    super.key,
    required this.session,
    required this.clip,
    required this.list,
    required this.scale,
    required this.height,
    required this.focus,
  });
  @override
  Widget build(BuildContext context) {
    useListenable(session.history);
    final owner = useMemoized(Object.new);
    final drag = useRef<ClipDrag?>(null),
        draft = useState<(int, int)?>(null),
        valid = useState(true);
    useEffect(() {
      if (drag.value != null &&
          drag.value!.generation != session.history.gestureGeneration) {
        drag.value = null;
        draft.value = null;
        valid.value = true;
      }
      return null;
    }, [session.history.gestureGeneration]);
    final start = draft.value?.$1 ?? clip['start_frame'] as int,
        end = draft.value?.$2 ?? clip['end_frame'] as int;
    final colors = RevericTheme.colorsOf(context),
        width = math.max(1.0, (end - start) * scale);
    void cancel() {
      drag.value = null;
      draft.value = null;
      valid.value = true;
      session.cancelEditGesture();
    }

    final move = list == 'camera_moves';
    final ownerId = clip[move ? 'camera_id' : 'target_id'] as String;
    final (rangeStart, rangeEnd) = session.range;
    final picked =
        rangeStart == clip['start_frame'] &&
        rangeEnd == clip['end_frame'] &&
        session.selected == ownerId;
    final tint = move ? colors.accentWarm : colors.accent;
    return Positioned(
      left: start * scale,
      top: 3,
      width: width,
      height: height,
      child: MouseRegion(
        cursor: session.readOnly
            ? SystemMouseCursors.click
            : SystemMouseCursors.grab,
        child: Listener(
          key: ValueKey('clip:${clip['id']}'),
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (session.readOnly) {
              session.pause();
              session.select(ownerId);
              if (!move) {
                session.pathEditor.select(clip['id']);
              }
              return;
            }
            if (session.hasPendingInput) {
              session.error = 'apply_pending';
              session.refresh();
              return;
            }
            if (!session.claimEditGesture(owner, event.pointer)) {
              return;
            }
            session.pause();
            session.select(ownerId);
            focus.requestFocus();
            final edge = math.min(
              width / 3,
              event.kind == PointerDeviceKind.touch ? 22.0 : 12.0,
            );
            final mode = event.localPosition.dx <= edge
                ? ClipDragMode.trim_start
                : event.localPosition.dx >= width - edge
                ? ClipDragMode.trim_end
                : ClipDragMode.move;
            drag.value = ClipDrag(
              clip: clip,
              event: event,
              generation: session.history.gestureGeneration,
              pixelsPerFrame: scale,
              mode: mode,
            );
            valid.value = true;
          },
          onPointerMove: (event) {
            final operation = drag.value;
            if (operation == null || operation.pointer != event.pointer) {
              return;
            }
            if (operation.generation != session.history.gestureGeneration) {
              drag.value = null;
              draft.value = null;
              return;
            }
            if (!operation.moved &&
                (event.position.dx - operation.downX).abs() < 4) {
              return;
            }
            operation.moved = true;
            final interval = operation.interval(event.position.dx);
            draft.value = interval;
            operation.valid = false;
            valid.value = false;
            session.attempt(() {
              session.history.previewControl(list, {
                ...clip,
                'start_frame': interval.$1,
                'end_frame': interval.$2,
              });
              operation.valid = true;
              valid.value = true;
            });
          },
          onPointerUp: (event) {
            session.releaseEditGesture(owner, event.pointer);
            final operation = drag.value;
            if (operation != null &&
                operation.pointer == event.pointer &&
                operation.generation == session.history.gestureGeneration) {
              if (operation.moved && operation.valid) {
                session.attempt(session.history.commitGesture);
              } else if (operation.moved) {
                session.history.cancelGesture();
              } else {
                // 未拖动的单击 = 选中片段，把它的区间设为选区。
                session.setRange(clip['start_frame'], clip['end_frame']);
                if (!move) {
                  session.select(clip['target_id']);
                  session.pathEditor.select(clip['id']);
                }
              }
            }
            drag.value = null;
            draft.value = null;
            valid.value = true;
          },
          onPointerCancel: (_) => cancel(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: session.readOnly ? null : (_) {},
            onPanUpdate: session.readOnly ? null : (_) {},
            onPanEnd: session.readOnly ? null : (_) {},
            onDoubleTap: session.readOnly
                ? null
                : () => editTrackOrClip(context, session, clip),
            child: DecoratedBox(
              key: ValueKey(
                '${valid.value ? 'clip-valid' : 'clip-invalid'}:${clip['id']}',
              ),
              decoration: BoxDecoration(
                color: valid.value
                    ? tint.withValues(alpha: picked ? 0.28 : 0.14)
                    : colors.deletionBg,
                border: Border.all(
                  color: valid.value
                      ? tint.withValues(alpha: picked ? 1 : 0.45)
                      : colors.error,
                  width: picked ? 1.5 : 1,
                ),
                borderRadius: BorderRadius.circular(RevericRadius.small),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.xs,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    tr(context, '${move ? 'move' : 'path'}_${clip['kind']}'),
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: RevericTheme.typographyOf(context).uiTiny.copyWith(
                      color: valid.value ? colors.textPrimary : colors.error,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

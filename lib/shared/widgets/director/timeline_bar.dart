// 职责: 导演时间轴底栏 — 时间轴开关、播放、当前时间、自动帧与横向缩放。
// 关联文件:
//   lib/shared/widgets/director/timeline.dart
//   lib/shared/services/director/session.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../components/reveric_icon_button.dart';
import '../../services/director/session.dart';
import '../../theme/theme.dart';
import 'strings.dart';

class DirectorTimelineBar extends StatelessWidget {
  const DirectorTimelineBar({
    super.key,
    required this.session,
    required this.zoom,
    required this.onZoom,
    required this.onJump,
    this.compact = false,
  });
  final DirectorSession session;
  final double zoom;
  final ValueChanged<double> onZoom;
  final ValueChanged<int> onJump;
  final bool compact;

  static const minZoom = 1.0, maxZoom = 8.0;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final document = session.history.document;
    final open = session.history.timelineVisible;
    final figures = typo.uiSmall.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    Widget divider() => VerticalDivider(
      width: RevericSpacing.lg,
      indent: RevericSpacing.sm,
      endIndent: RevericSpacing.sm,
      color: colors.borderSubtle,
    );
    return SizedBox(
      height: RevericSizes.directorTimelineBarHeight,
      child: Row(
        children: [
          const SizedBox(width: RevericSpacing.sm),
          _BarToggle(
            key: const ValueKey('director-show-timeline'),
            label: tr(context, 'show_timeline'),
            selected: open,
            trailing: RevericIcon(
              open ? RevericIcons.caret_down : RevericIcons.expand_less_rounded,
              size: RevericSizes.directorSmallIcon,
              color: colors.textMuted,
            ),
            onPressed: () {
              session.history.timelineVisible = !open;
              if (open) {
                session.pathEditor.cancel();
              }
              session.refresh();
            },
          ),
          if (!compact) divider(),
          if (open && !compact)
            RevericIconButton(
              icon: RevericIcons.skip_back,
              tooltip: tr(context, 'previous_key'),
              onPressed: () => onJump(-1),
            ),
          RevericIconButton(
            key: const ValueKey('director-play'),
            icon: session.playing
                ? RevericIcons.pause
                : RevericIcons.play_arrow,
            tooltip: tr(context, 'play'),
            onPressed: () => session.attempt(session.play),
          ),
          if (open && !compact)
            RevericIconButton(
              icon: RevericIcons.skip_forward,
              tooltip: tr(context, 'next_key'),
              onPressed: () => onJump(1),
            ),
          const SizedBox(width: RevericSpacing.sm),
          Flexible(
            child: ValueListenableBuilder(
              valueListenable: session.frame,
              builder: (context, frame, _) => Text(
                '${(frame / document.fps).toStringAsFixed(2)}s',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: figures.copyWith(color: colors.textPrimary),
              ),
            ),
          ),
          if (!compact)
            Text(
              ' / ${(document.durationFrames / document.fps).toStringAsFixed(2)}s',
              style: figures.copyWith(color: colors.textMuted),
            ),
          const Spacer(),
          if (open) ...[
            if (!session.readOnly)
              _BarToggle(
                key: const ValueKey('director-auto-key'),
                label: tr(context, 'auto_key'),
                selected: session.history.autoKey,
                leading: Transform.rotate(
                  angle: math.pi / 4,
                  child: Container(
                    width: RevericSpacing.xs,
                    height: RevericSpacing.xs,
                    decoration: BoxDecoration(
                      color: session.history.autoKey
                          ? colors.accent
                          : Colors.transparent,
                      border: Border.all(
                        color: session.history.autoKey
                            ? colors.accent
                            : colors.textMuted,
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
                onPressed: () {
                  session.history.autoKey = !session.history.autoKey;
                  session.refresh();
                },
              ),
            if (!compact) ...[
              if (!session.readOnly) divider(),
              RevericIconButton(
                icon: RevericIcons.remove,
                tooltip: tr(context, 'zoom_out'),
                onPressed: zoom <= minZoom ? null : () => onZoom(zoom / 2),
              ),
              SizedBox(
                width: RevericSpacing.x5l * 2,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    overlayShape: SliderComponentShape.noOverlay,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    trackHeight: 2,
                  ),
                  child: Slider(
                    key: const ValueKey('director-timeline-zoom'),
                    value: math.log(zoom) / math.ln2,
                    max: math.log(maxZoom) / math.ln2,
                    onChanged: (v) => onZoom(math.pow(2, v).toDouble()),
                  ),
                ),
              ),
              RevericIconButton(
                icon: RevericIcons.add,
                tooltip: tr(context, 'zoom_in'),
                onPressed: zoom >= maxZoom ? null : () => onZoom(zoom * 2),
              ),
              SizedBox(
                width: RevericSpacing.x5l,
                child: Text(
                  '${zoom.toStringAsFixed(zoom == zoom.roundToDouble() ? 0 : 1)}x',
                  textAlign: TextAlign.end,
                  style: figures.copyWith(color: colors.textMuted),
                ),
              ),
            ],
          ],
          const SizedBox(width: RevericSpacing.sm),
        ],
      ),
    );
  }
}

/// 底栏里的胶囊开关：选中时用选中底色和强调色。
class _BarToggle extends StatelessWidget {
  const _BarToggle({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.leading,
    this.trailing,
  });
  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final Widget? leading, trailing;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Semantics(
      button: true,
      toggled: selected,
      child: Material(
        color: selected ? colors.selected : Colors.transparent,
        shape: StadiumBorder(side: BorderSide(color: colors.border)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.md,
              vertical: RevericSpacing.xxs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (leading != null) ...[
                  leading!,
                  const SizedBox(width: RevericSpacing.xs),
                ],
                Text(
                  label,
                  style: typo.uiSmall.copyWith(
                    color: selected ? colors.accent : colors.textPrimary,
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: RevericSpacing.xs),
                  trailing!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// 职责: 右栏「属性」：未选中时显示工程概况，选中片段时按轨道类型编辑文字、倍速、音量、不透明度、大小、位置与淡入淡出。
// 关联文件:
//   lib/desktop/features/editing/controller.dart
//   lib/shared/services/editing/commands.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/text-input-ime.md
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_segmented_control.dart';
import '../../../shared/components/reveric_text_field.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/editing/document.dart';
import '../../../shared/services/editing/commands.dart';
import '../../../shared/theme/theme.dart';
import 'controller.dart';
import 'support.dart';

class EditingInspector extends StatelessWidget {
  const EditingInspector({
    super.key,
    required this.controller,
    required this.title,
    required this.spec,
  });
  final EditingController controller;

  /// 剧集名，用在未选中时的标题。
  final String title;

  /// 画面规格，如「9:16 · 1080P · 24 fps」。
  final String spec;
  @override
  Widget build(BuildContext context) {
    final clip = controller.session.selected;
    final doc = controller.doc;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.lg,
        0,
        RevericSpacing.lg,
        RevericSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: clip == null
            ? _overview(context, doc)
            : _clip(context, doc, clip),
      ),
    );
  }

  List<Widget> _overview(BuildContext context, EditingDocument doc) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    Widget key(String keyLabel, String action) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHigh,
            border: Border.all(color: colors.borderInput),
            borderRadius: BorderRadius.circular(RevericRadius.small),
          ),
          child: Text(
            keyLabel,
            style: typo.uiTiny.copyWith(color: colors.textSecondary),
          ),
        ),
        const SizedBox(width: 4),
        Text(action, style: typo.uiTiny.copyWith(color: colors.textSubtle)),
      ],
    );
    return [
      _Head(
        title: context.t(
          LocaleKeys.editingOverviewTitle,
          namedArgs: {'episode': title},
        ),
        subtitle: context.t(LocaleKeys.editingSelectHint),
      ),
      _Row(
        label: context.t(LocaleKeys.editingDuration),
        child: Text(
          editingTimecode(doc.totalFrames),
          style: typo.mono.copyWith(color: colors.textSecondary),
        ),
      ),
      _Row(
        label: context.t(LocaleKeys.editingPicture),
        child: Text(spec, style: typo.uiSmall),
      ),
      _Row(
        label: context.t(LocaleKeys.editingTracks),
        child: Text(
          context.t(
            LocaleKeys.editingTrackSummary,
            namedArgs: {
              'tracks': '${doc.tracks.length}',
              'clips': '${doc.clips.length}',
            },
          ),
          style: typo.uiSmall,
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: RevericSpacing.md),
        child: Wrap(
          spacing: RevericSpacing.lg,
          runSpacing: RevericSpacing.sm,
          children: [
            key(
              context.t(LocaleKeys.editingKeySpace),
              context.t(LocaleKeys.commonPlay),
            ),
            key('S', context.t(LocaleKeys.editingSplit)),
            key('⌫', context.t(LocaleKeys.commonDelete)),
            key(
              Platform.isMacOS ? '⌘Z' : 'Ctrl+Z',
              context.t(LocaleKeys.editingUndo),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _clip(BuildContext context, EditingDocument doc, EditingClip c) {
    final track = doc.track(c.trackId);
    final content = c.content;
    final locked = track.locked;
    void set(EditingClip next) => editingRun(
      context,
      () => controller.session.commit(EditingCommands.update(doc, next)),
    );
    void setContent(EditingContent next) => set(c.copyWith(content: next));
    String db(double v) => '${v > 0 ? '+' : ''}${v.round()} dB';
    String secs(double v) => '${v.toStringAsFixed(1)}s';
    int frames(double seconds) => (seconds * editingFps).round();
    double seconds(int frames) => frames / editingFps;
    final head = _Head(
      title: content is EditingTextContent
          ? context.t(
              content.style == 'title'
                  ? LocaleKeys.editingStyleTitle
                  : LocaleKeys.editingStyleSubtitle,
            )
          : editingClipLabel(controller, c),
      subtitle: context.t(
        LocaleKeys.editingClipPosition,
        namedArgs: {
          'track':
              '${editingTrackName(context, track)} ${editingTrackCode(track)}',
          'time': editingTimecode(c.startFrame),
          'seconds': editingDurationLabel(c.durationFrames),
        },
      ),
    );
    Widget fade(
      String label,
      int value,
      double cap,
      EditingClip Function(int) apply,
    ) {
      final max = math.min(cap, seconds(c.durationFrames) / 2);
      return _Row(
        label: label,
        child: _Range(
          value: math.min(seconds(value), max),
          min: 0,
          max: max,
          step: .1,
          format: secs,
          onCommit: locked ? null : (v) => set(apply(frames(v))),
        ),
      );
    }

    /// 九宫格按锚点贴边摆放，水平、垂直滑块再微调锚点所在的画面坐标。
    List<Widget> placement(
      EditingTransform t,
      double edgeY,
      void Function(EditingTransform) apply,
    ) {
      String percent(double v) => '${v.round()}%';
      return [
        _Row(
          label: context.t(LocaleKeys.editingPosition),
          child: _AnchorGrid(
            anchorX: t.anchorX,
            anchorY: t.anchorY,
            onSelect: locked
                ? null
                : (ax, ay) => apply(
                    t.copyWith(
                      anchorX: ax,
                      anchorY: ay,
                      x: .06 + ax * .88,
                      y: edgeY + ay * (1 - 2 * edgeY),
                    ),
                  ),
          ),
        ),
        _Row(
          label: context.t(LocaleKeys.editingHorizontal),
          child: _Range(
            value: t.x * 100,
            min: 0,
            max: 100,
            step: 1,
            format: percent,
            onCommit: locked ? null : (v) => apply(t.copyWith(x: v / 100)),
          ),
        ),
        _Row(
          label: context.t(LocaleKeys.editingVertical),
          child: _Range(
            value: t.y * 100,
            min: 0,
            max: 100,
            step: 1,
            format: percent,
            onCommit: locked ? null : (v) => apply(t.copyWith(y: v / 100)),
          ),
        ),
      ];
    }

    Widget opacity(double value, void Function(double) apply) => _Row(
      label: context.t(LocaleKeys.editingOpacity),
      child: _Range(
        value: value * 100,
        min: 0,
        max: 100,
        step: 1,
        format: (v) => '${v.round()}%',
        onCommit: locked ? null : (v) => apply(v / 100),
      ),
    );

    if (content is EditingTextContent) {
      return [
        head,
        _TextField(
          key: ValueKey('text:${c.id}'),
          label: context.t(LocaleKeys.editingText),
          value: content.text,
          enabled: !locked,
          onCommit: (text) => setContent(content.copyWith(text: text)),
        ),
        _Row(
          label: context.t(LocaleKeys.editingStyle),
          child: RevericSegmentedControl<String>(
            selected: content.style,
            segments: [
              RevericSegment(
                value: 'subtitle',
                label: context.t(LocaleKeys.editingStyleSubtitle),
              ),
              RevericSegment(
                value: 'title',
                label: context.t(LocaleKeys.editingStyleTitle),
              ),
            ],
            onChanged: (v) =>
                locked ? null : setContent(content.copyWith(style: v)),
          ),
        ),
        _Row(
          label: context.t(LocaleKeys.editingSize),
          child: _Range(
            value: content.transform.scale * 100,
            min: 20,
            max: 200,
            step: 5,
            format: (v) => '${v.round()}%',
            onCommit: locked
                ? null
                : (v) => setContent(
                    content.copyWith(
                      transform: content.transform.copyWith(scale: v / 100),
                    ),
                  ),
          ),
        ),
        opacity(
          content.opacity,
          (v) => setContent(content.copyWith(opacity: v)),
        ),
        ...placement(
          content.transform,
          .09,
          (t) => setContent(content.copyWith(transform: t)),
        ),
      ];
    }

    final media = content as EditingSourceContent;
    final source = media.source;
    final used = source.mediaType == 'image'
        ? null
        : context.t(
            LocaleKeys.editingSourceRange,
            namedArgs: {
              'from': secs(media.sourceInUs / 1000000),
              'to': secs(c.sourceEndUs! / 1000000),
              'total': secs(source.durationUs / 1000000),
            },
          );
    final volume = _Row(
      label: context.t(
        track.kind == 'audio'
            ? LocaleKeys.editingVolume
            : LocaleKeys.editingOriginalSound,
      ),
      hint: track.kind == 'video' && !source.hasAudio
          ? context.t(LocaleKeys.editingNoSound)
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Range(
            value: media.gainDb.clamp(-30, 6),
            min: -30,
            max: 6,
            step: 1,
            format: db,
            onCommit: locked || (track.kind == 'video' && !source.hasAudio)
                ? null
                : (v) => setContent(media.copyWith(gainDb: v)),
          ),
          if (media is EditingVideoContent &&
              source.hasAudio &&
              !media.audioDetached)
            RevericButton.text(
              key: const ValueKey('editing-detach-audio'),
              label: context.t(LocaleKeys.editingDetachAudio),
              size: RevericButtonSize.compact,
              onPressed: locked
                  ? null
                  : () => editingRun(
                      context,
                      () => controller.session.commit(
                        EditingCommands.extractAudio(doc, c.id),
                      ),
                    ),
            ),
        ],
      ),
    );
    final sourceRow = _SourceRow(
      controller: controller,
      source: source,
      name: c.name.isEmpty ? controller.sourceName(source) : c.name,
      detail: used,
    );
    final speed = source.mediaType == 'image'
        ? null
        : _Row(
            label: context.t(LocaleKeys.editingSpeed),
            child: _Range(
              value: media.speed,
              min: EditingSourceContent.minSpeed,
              max: EditingSourceContent.maxSpeed,
              step: .05,
              format: editingSpeedLabel,
              onCommit: locked
                  ? null
                  : (v) => editingRun(
                      context,
                      () => controller.session.commit(
                        EditingCommands.retime(
                          doc,
                          c.id,
                          (v * 100).round() / 100,
                        ),
                      ),
                    ),
            ),
          );
    if (media is EditingAudioContent) {
      return [
        head,
        sourceRow,
        ?speed,
        volume,
        fade(
          context.t(LocaleKeys.editingFadeIn),
          media.fadeInFrames,
          5,
          (f) => c.copyWith(content: media.copyWith(fadeInFrames: f)),
        ),
        fade(
          context.t(LocaleKeys.editingFadeOut),
          media.fadeOutFrames,
          5,
          (f) => c.copyWith(content: media.copyWith(fadeOutFrames: f)),
        ),
      ];
    }
    final video = media as EditingVideoContent;
    return [
      head,
      sourceRow,
      ?speed,
      if (!track.main) ...[
        opacity(video.opacity, (v) => setContent(video.copyWith(opacity: v))),
        _Row(
          label: context.t(LocaleKeys.editingSize),
          child: _Range(
            value: video.transform.scale * 100,
            min: 20,
            max: 100,
            step: 1,
            format: (v) => v.round() == 100
                ? context.t(LocaleKeys.editingFill)
                : '${v.round()}%',
            onCommit: locked
                ? null
                : (v) => setContent(
                    video.copyWith(
                      transform: video.transform.copyWith(scale: v / 100),
                    ),
                  ),
          ),
        ),
        ...placement(
          video.transform,
          .06,
          (t) => setContent(video.copyWith(transform: t)),
        ),
        fade(
          context.t(LocaleKeys.editingFadeIn),
          media.fadeInFrames,
          3,
          (f) => c.copyWith(content: media.copyWith(fadeInFrames: f)),
        ),
        fade(
          context.t(LocaleKeys.editingFadeOut),
          media.fadeOutFrames,
          3,
          (f) => c.copyWith(content: media.copyWith(fadeOutFrames: f)),
        ),
      ],
      if (source.mediaType == 'video' && !video.audioDetached) volume,
      if (track.main)
        Padding(
          padding: const EdgeInsets.only(top: RevericSpacing.md),
          child: Align(
            alignment: Alignment.centerLeft,
            child: RevericButton.secondary(
              icon: RevericIcons.arrows_clockwise,
              label: context.t(LocaleKeys.editingReplace),
              size: RevericButtonSize.compact,
              onPressed: locked ? null : () => controller.startReplace(c.id),
            ),
          ),
        ),
    ];
  }
}

class _Head extends StatelessWidget {
  const _Head({required this.title, required this.subtitle});
  final String title, subtitle;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      padding: const EdgeInsets.only(
        top: RevericSpacing.sm,
        bottom: RevericSpacing.md,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: typo.uiSemibold.copyWith(
              color: colors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 3),
          Text(subtitle, style: typo.uiSmall.copyWith(color: colors.textMuted)),
        ],
      ),
    );
  }
}

/// 一行属性：左侧 64px 标签，右侧控件，可带一行提示。
class _Row extends StatelessWidget {
  const _Row({required this.label, required this.child, this.hint});
  final String label;
  final Widget child;
  final String? hint;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: RevericSpacing.sm),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 64,
                child: Text(
                  label,
                  style: typo.uiSmall.copyWith(color: colors.textMuted),
                ),
              ),
              const SizedBox(width: RevericSpacing.md),
              Expanded(
                child: Align(alignment: Alignment.centerLeft, child: child),
              ),
            ],
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(left: 64 + RevericSpacing.md),
              child: Text(
                hint!,
                style: typo.uiTiny.copyWith(color: colors.textSubtle),
              ),
            ),
        ],
      ),
    );
  }
}

/// 锚点九宫格：选中格对应图层框上落在画面坐标处的那个点。
class _AnchorGrid extends StatelessWidget {
  const _AnchorGrid({
    required this.anchorX,
    required this.anchorY,
    required this.onSelect,
  });
  final double anchorX, anchorY;
  final void Function(double anchorX, double anchorY)? onSelect;
  static const _labels = [
    [
      LocaleKeys.editingPositionTopLeft,
      LocaleKeys.editingPositionTop,
      LocaleKeys.editingPositionTopRight,
    ],
    [
      LocaleKeys.editingPositionLeft,
      LocaleKeys.editingPositionCenter,
      LocaleKeys.editingPositionRight,
    ],
    [
      LocaleKeys.editingPositionBottomLeft,
      LocaleKeys.editingPositionBottom,
      LocaleKeys.editingPositionBottomRight,
    ],
  ];
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    Widget cell(int row, int column) {
      final ax = column / 2, ay = row / 2;
      final selected = ax == anchorX && ay == anchorY;
      return Tooltip(
        message: context.t(_labels[row][column]),
        child: InkWell(
          key: ValueKey('editing-anchor-$column-$row'),
          onTap: onSelect == null ? null : () => onSelect!(ax, ay),
          borderRadius: BorderRadius.circular(RevericRadius.small),
          child: SizedBox.square(
            dimension: 20,
            child: Center(
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: selected ? colors.accent : colors.surfaceContainerHigh,
                  border: Border.all(
                    color: selected ? colors.accent : colors.borderInput,
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        border: Border.all(color: colors.borderInput),
        borderRadius: BorderRadius.circular(RevericRadius.small),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var row = 0; row < 3; row++)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var column = 0; column < 3; column++) cell(row, column),
              ],
            ),
        ],
      ),
    );
  }
}

/// 滑块：拖动只改本地显示，松手提交一次（一次拖动 = 一步撤销）。
class _Range extends HookWidget {
  const _Range({
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.format,
    required this.onCommit,
  });
  final double value, min, max, step;
  final String Function(double) format;
  final ValueChanged<double>? onCommit;
  @override
  Widget build(BuildContext context) {
    final draft = useState(value);
    useEffect(() {
      draft.value = value;
      return null;
    }, [value]);
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final divisions = max <= min ? null : ((max - min) / step).round();
    return Row(
      children: [
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              overlayShape: SliderComponentShape.noOverlay,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              trackHeight: 3,
            ),
            child: Slider(
              value: draft.value.clamp(min, math.max(min, max)),
              min: min,
              max: math.max(min + .001, max),
              divisions: divisions == null || divisions < 1 ? null : divisions,
              onChanged: onCommit == null || max <= min
                  ? null
                  : (v) => draft.value = v,
              onChangeEnd: onCommit == null || max <= min
                  ? null
                  : (v) {
                      if (v != value) {
                        onCommit!(v);
                      }
                    },
            ),
          ),
        ),
        SizedBox(
          width: 46,
          child: Text(
            format(draft.value),
            textAlign: TextAlign.right,
            style: typo.uiTiny.copyWith(color: colors.textSecondary),
          ),
        ),
      ],
    );
  }
}

/// 字幕文字：输入期间只改本地 controller，失焦或回车时提交一次。
class _TextField extends HookWidget {
  const _TextField({
    super.key,
    required this.label,
    required this.value,
    required this.enabled,
    required this.onCommit,
  });
  final String label, value;
  final bool enabled;
  final ValueChanged<String> onCommit;
  @override
  Widget build(BuildContext context) {
    final controller = useTextEditingController(text: value);
    final focus = useFocusNode();
    void submit() {
      if (controller.text != value) {
        onCommit(controller.text);
      }
    }

    useEffect(() {
      void listener() {
        if (!focus.hasFocus) {
          submit();
        }
      }

      focus.addListener(listener);
      return () => focus.removeListener(listener);
    }, [focus, value]);
    useEffect(() {
      if (!focus.hasFocus && controller.text != value) {
        controller.text = value;
      }
      return null;
    }, [value]);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: RevericSpacing.sm),
      child: RevericTextField(
        controller: controller,
        focusNode: focus,
        label: label,
        enabled: enabled,
        multiline: true,
        minLines: 3,
        maxLines: 6,
        autocorrect: false,
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.controller,
    required this.source,
    required this.name,
    required this.detail,
  });
  final EditingController controller;
  final EditingSource source;
  final String name;
  final String? detail;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: RevericSpacing.md),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.borderSubtle)),
      ),
      child: Row(
        children: [
          EditingMediaThumb(
            path: controller.sourceFile(source),
            type: source.mediaType,
            size: const Size(30, 40),
          ),
          const SizedBox(width: RevericSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.uiSmallSemibold.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                if (detail != null)
                  Text(
                    detail!,
                    style: typo.uiTiny.copyWith(color: colors.textMuted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 素材缩略：图片读文件，视频和音频画类型图标。
class EditingMediaThumb extends StatelessWidget {
  const EditingMediaThumb({
    super.key,
    required this.path,
    required this.type,
    required this.size,
  });
  final String? path;
  final String type;
  final Size size;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(RevericRadius.small),
      child: SizedBox.fromSize(
        size: size,
        child: type == 'image' && path != null
            ? Image.file(
                File(path!),
                fit: BoxFit.cover,
                cacheHeight: (size.height * dpr).round(),
                errorBuilder: (_, _, _) => ColoredBox(color: colors.surfaceDim),
              )
            : ColoredBox(
                color: colors.surfaceDim,
                child: Center(
                  child: RevericIcon(
                    switch (type) {
                      'video' => RevericIcons.movie_outlined,
                      'audio' => RevericIcons.waveform,
                      _ => RevericIcons.image_outlined,
                    },
                    size: 14,
                    color: colors.textSubtle,
                  ),
                ),
              ),
      ),
    );
  }
}

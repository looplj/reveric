// 职责: 机位属性 — 变换（含逐项关键帧）、注视目标、镜头参数、当前运镜与导出版本。
// 关联文件:
//   lib/shared/services/director/commands.dart
//   lib/shared/services/director/session.dart
//   lib/shared/widgets/director/inspector/controls.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../../components/reveric_button.dart';
import '../../../services/director/session.dart';
import '../../../theme/theme.dart';
import '../panels/common.dart';
import '../strings.dart';
import 'controls.dart';
import 'direction.dart';
import 'property.dart';

class CameraInspector extends HookWidget {
  const CameraInspector({
    super.key,
    required this.session,
    required this.camera,
    required this.sampled,
    required this.onAlignToView,
    this.recovering = false,
  });
  final DirectorSession session;
  final Map<String, dynamic> camera, sampled;
  final VoidCallback onAlignToView;
  final bool recovering;

  @override
  Widget build(BuildContext context) {
    final id = camera['id'] as String;
    final outputCamera = session.cameraMode == 'sequence' ? null : id;
    final generation = useValueListenable(session.exportsRevision);
    final versions = useFuture(
      useMemoized(() => session.exportVersions?.call(outputCamera), [
        session,
        outputCamera,
        generation,
      ]),
    );
    final colors = RevericTheme.colorsOf(context);
    final document = session.history.document;
    final frame = session.frame.value;
    final p = [for (final v in sampled['position']) (v as num).toDouble()];
    final moves = document.moves.where((m) => m['camera_id'] == id).toList()
      ..sort((a, b) => (a['start_frame'] as int).compareTo(b['start_frame']));
    final current =
        moves
            .where((m) => frame >= m['start_frame'] && frame <= m['end_frame'])
            .firstOrNull ??
        moves.firstOrNull;
    void execute(void Function(Map<String, dynamic>) edit) =>
        session.history.execute(edit);
    bool enabled(String property) =>
        !session.readOnly &&
        !session.playing &&
        session.history.editBlock(id, property, frame) == null;
    const animatedLens = {
      'roll',
      'focal_length_mm',
      'focus_distance_m',
      'aperture_fstop',
    };
    Widget lensField(String property) => CommitField(
      fieldKey: ValueKey('director-field:$property'),
      session: session,
      value: (sampled[property] as num).toString(),
      suffix: property == 'roll'
          ? '°'
          : property == 'near' ||
                property == 'far' ||
                property == 'focus_distance_m'
          ? 'm'
          : property == 'aperture_fstop'
          ? 'f'
          : 'mm',
      enabled: animatedLens.contains(property)
          ? enabled(property)
          : !session.playing,
      onCommit: (text) {
        final value = double.tryParse(text);
        return value != null &&
            commitEdit(session, () {
              if (animatedLens.contains(property)) {
                session.history.editProperty(id, property, value, frame);
              } else {
                execute(
                  (j) => (j['cameras'] as List).firstWhere(
                    (c) => c['id'] == id,
                  )[property] = value,
                );
              }
            });
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            RevericIcon(
              RevericIcons.video_camera,
              size: RevericSizes.buttonIconSize,
              color: colors.textMuted,
            ),
            const SizedBox(width: RevericSpacing.sm),
            Expanded(
              child: CommitField(
                fieldKey: const ValueKey('director-field:camera_name'),
                session: session,
                numeric: false,
                value: camera['name'],
                onCommit: (text) => commitEdit(
                  session,
                  () => execute(
                    (j) => (j['cameras'] as List).firstWhere(
                      (c) => c['id'] == id,
                    )['name'] = text,
                  ),
                ),
              ),
            ),
          ],
        ),
        SectionTitle(tr(context, 'transform')),
        PropertyKeyControl(
          session: session,
          id: id,
          property: 'position',
          label: tr(context, 'position'),
          child: XyzInput(
            session: session,
            fieldKey: 'camera_position',
            values: p,
            enabled: List.filled(3, enabled('position')),
            onCommit: (axis, v) => session.history.setValue(
              id,
              'position',
              [...p]..[axis] = v,
              frame,
            ),
          ),
        ),
        CameraDirectionInspector(
          session: session,
          camera: camera,
          sampled: sampled,
          recovering: recovering,
        ),
        for (final property in [
          'focal_length_mm',
          'focus_distance_m',
          'aperture_fstop',
          if (camera['orientation_mode'] == 'look_at') 'roll',
          'sensor_height_mm',
          'near',
          'far',
        ]) ...[
          LabeledField(
            label: tr(
              context,
              property == 'focal_length_mm' ? 'focal' : property,
            ),
            child: animatedLens.contains(property)
                ? PropertyKeyControl(
                    session: session,
                    id: id,
                    property: property,
                    child: lensField(property),
                  )
                : lensField(property),
          ),
        ],
        LabeledField(
          label: tr(context, 'camera_moves'),
          child: RevericButton.secondary(
            key: const ValueKey('director-current-move'),
            label: current == null
                ? tr(context, 'no_move')
                : '${tr(context, 'move_${current['kind']}')}  ${seconds(session, current['start_frame'])}–${seconds(session, current['end_frame'])}s',
            icon: RevericIcons.alt_route_outlined,
            size: RevericButtonSize.compact,
            onPressed: session.readOnly
                ? null
                : () {
                    if (current != null) {
                      session.setRange(
                        current['start_frame'],
                        current['end_frame'],
                      );
                    }
                    session.setPanel('moves');
                  },
          ),
        ),
        if (!session.readOnly)
          RevericButton.secondary(
            label: tr(context, 'set_camera'),
            icon: RevericIcons.video_camera,
            size: RevericButtonSize.compact,
            onPressed: session.playing ? null : onAlignToView,
          ),
        if (versions.data?.isNotEmpty ?? false) ...[
          SectionTitle(tr(context, 'export_versions')),
          for (final v in versions.data!.reversed)
            PanelRow(
              title: trArgs(
                context,
                v['kind'] == 'motion' ? 'version_motion' : 'version_still',
                {'v': '${v['version']}'},
              ),
              icon: v['kind'] == 'motion'
                  ? RevericIcons.movie_outlined
                  : RevericIcons.image_outlined,
              subtitle:
                  '${tr(context, v['cameraMode'])} · ${DateTime.parse(v['at']).toLocal().toString().substring(0, 16)}',
              selected: false,
              onTap: () {},
            ),
        ],
      ],
    );
  }
}

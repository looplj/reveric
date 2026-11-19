// 职责: 角色与道具属性 — 名称、变换（含逐项关键帧）、运动轨迹、外观与完整姿态。
// 关联文件:
//   lib/shared/services/director/commands.dart
//   lib/shared/models/director/sampling.dart
//   lib/shared/widgets/director/inspector/controls.dart
//   lib/shared/widgets/director/paths/panel.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
// 遵循的 Rules: .agents/rules/design-system.md
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../components/reveric_checkbox.dart';
import '../../../components/reveric_segmented_control.dart';
import 'pose.dart';
import '../../../models/director/sampling.dart';
import '../../../services/director/session.dart';
import '../../../theme/theme.dart';
import '../panels/common.dart';
import '../paths/panel.dart';
import '../strings.dart';
import 'controls.dart';

class ObjectInspector extends StatelessWidget {
  const ObjectInspector({
    super.key,
    required this.session,
    required this.object,
    required this.sampled,
    this.section = 'properties',
    this.onSection,
  });
  final DirectorSession session;

  /// 工程里的原始对象与当前帧的采样结果。
  final Map<String, dynamic> object, sampled;

  /// 角色属性的分区：properties / pose / path；道具只有属性。
  final String section;
  final ValueChanged<String>? onSection;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final id = object['id'] as String, actor = object['kind'] == 'actor';
    final section =
        !actor || this.section == 'path' && !session.history.timelineVisible
        ? 'properties'
        : this.section;
    final frame = session.frame.value;
    final position = [
      for (final v in sampled['position']) (v as num).toDouble(),
    ];
    final rotation = quaternionEuler(sampled['rotation']);
    final scale = [for (final v in sampled['scale']) (v as num).toDouble()];
    bool enabled(String property) =>
        !session.readOnly &&
        !session.playing &&
        session.history.editBlock(id, property, frame) == null;
    void set(String property, dynamic value) =>
        session.history.setValue(id, property, value, frame);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (actor)
              Swatch(object['color'])
            else
              RevericIcon(
                RevericIcons.cube,
                size: RevericSizes.buttonIconSize,
                color: colors.textMuted,
              ),
            const SizedBox(width: RevericSpacing.sm),
            Expanded(
              child: CommitField(
                fieldKey: const ValueKey('director-field:name'),
                session: session,
                numeric: false,
                value: object['name'],
                onCommit: (text) => commitEdit(
                  session,
                  () => session.history.execute(
                    (j) => (j['objects'] as List).firstWhere(
                      (o) => o['id'] == id,
                    )['name'] = text,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (actor) ...[
          const SizedBox(height: RevericSpacing.sm),
          RevericSegmentedControl<String>(
            segments: [
              for (final segment in [
                'properties',
                'pose',
                if (session.history.timelineVisible) 'path',
              ])
                RevericSegment(value: segment, label: tr(context, segment)),
            ],
            height: RevericSizes.fieldHeightSm,
            selected: section,
            onChanged: (value) => onSection?.call(value),
          ),
        ],
        if (section == 'pose')
          PoseInspector(session: session, object: sampled)
        else if (section == 'path')
          DirectorPathSection(session: session, actorId: id)
        else ...[
          SectionTitle(tr(context, 'transform')),
          KeyRow(
            label: tr(context, 'position'),
            keyButton: session.readOnly
                ? null
                : KeyButton(
                    key: const ValueKey('director-key:position'),
                    state: keyState(session, id, 'position'),
                    tooltip: tr(context, 'toggle_key'),
                    onPressed:
                        session.playing || !session.history.timelineVisible
                        ? null
                        : () => session.attempt(
                            () => session.history.toggleKey(
                              id,
                              'position',
                              frame,
                            ),
                          ),
                  ),
            child: XyzInput(
              session: session,
              fieldKey: 'position',
              values: position,
              enabled: List.filled(3, enabled('position')),
              onCommit: (axis, v) {
                final next = [...position]..[axis] = v;
                set('position', next);
              },
            ),
          ),
          KeyRow(
            label: tr(context, 'rotation'),
            keyButton: session.readOnly
                ? null
                : KeyButton(
                    key: const ValueKey('director-key:rotation'),
                    state: keyState(session, id, 'rotation'),
                    tooltip: tr(context, 'toggle_key'),
                    onPressed:
                        session.playing || !session.history.timelineVisible
                        ? null
                        : () => session.attempt(
                            () => session.history.toggleKey(
                              id,
                              'rotation',
                              frame,
                            ),
                          ),
                  ),
            child: XyzInput(
              session: session,
              fieldKey: 'rotation',
              unit: '°',
              enabled: List.filled(3, enabled('rotation')),
              values: [for (final angle in rotation) angle * 180 / math.pi],
              onCommit: (axis, v) => set(
                'rotation',
                eulerQuaternion([...rotation]..[axis] = v * math.pi / 180),
              ),
            ),
          ),
          SectionTitle(tr(context, 'appearance')),
          KeyRow(
            label: tr(context, 'scale'),
            keyButton: session.readOnly
                ? null
                : KeyButton(
                    key: const ValueKey('director-key:scale'),
                    state: keyState(session, id, 'scale'),
                    tooltip: tr(context, 'toggle_key'),
                    onPressed:
                        session.playing || !session.history.timelineVisible
                        ? null
                        : () => session.attempt(
                            () => session.history.toggleKey(id, 'scale', frame),
                          ),
                  ),
            child: actor
                ? CommitField(
                    fieldKey: const ValueKey('director-field:scale'),
                    session: session,
                    value: scale.first.toStringAsFixed(2),
                    enabled: enabled('scale'),
                    onCommit: (text) {
                      final v = double.tryParse(text);
                      return v != null &&
                          commitEdit(session, () => set('scale', [v, v, v]));
                    },
                  )
                : XyzInput(
                    session: session,
                    fieldKey: 'scale',
                    values: scale,
                    enabled: List.filled(3, enabled('scale')),
                    onCommit: (axis, v) => set('scale', [...scale]..[axis] = v),
                  ),
          ),
          KeyRow(
            label: tr(context, 'color'),
            keyButton: session.readOnly
                ? null
                : KeyButton(
                    key: const ValueKey('director-key:color'),
                    state: keyState(session, id, 'color'),
                    tooltip: tr(context, 'toggle_key'),
                    onPressed:
                        session.playing || !session.history.timelineVisible
                        ? null
                        : () => session.attempt(
                            () => session.history.toggleKey(id, 'color', frame),
                          ),
                  ),
            child: CommitField(
              fieldKey: const ValueKey('director-field:color'),
              session: session,
              numeric: false,
              value: sampled['color'],
              enabled: enabled('color'),
              onCommit: (text) =>
                  RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(text) &&
                  commitEdit(session, () => set('color', text.toUpperCase())),
            ),
          ),
          KeyRow(
            label: tr(context, 'visible'),
            keyButton: session.readOnly
                ? null
                : KeyButton(
                    key: const ValueKey('director-key:visible'),
                    state: keyState(session, id, 'visible'),
                    tooltip: tr(context, 'toggle_key'),
                    onPressed:
                        session.playing || !session.history.timelineVisible
                        ? null
                        : () => session.attempt(
                            () =>
                                session.history.toggleKey(id, 'visible', frame),
                          ),
                  ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: RevericCheckbox(
                value: sampled['visible'],
                semanticLabel: tr(context, 'visible'),
                onChanged: enabled('visible')
                    ? (v) => session.attempt(() => set('visible', v))
                    : null,
              ),
            ),
          ),
          for (final property in [
            'position',
            'rotation',
            'scale',
            'color',
            'visible',
          ])
            if (session.history.editBlock(id, property, frame)
                case final reason?)
              Text(
                '${tr(context, property)}: ${tr(context, reason)}',
                style: RevericTheme.typographyOf(
                  context,
                ).uiTiny.copyWith(color: colors.textMuted),
              ),
        ],
      ],
    );
  }
}

// 职责: 编辑相机自由旋转与动态注视目标及参考上方向。
// 关联文件:
//   lib/shared/services/director/session.dart
//   lib/shared/models/director/pose.dart
//   lib/shared/models/director/sampling.dart
//   lib/shared/widgets/director/inspector/property.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
//   assets/translations/en/assets.json
//   assets/translations/zh-CN/assets.json
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../components/reveric_select.dart';
import '../../../models/director/document.dart';
import '../../../models/director/sampling.dart';
import '../../../services/director/session.dart';
import '../strings.dart';
import 'controls.dart';
import 'property.dart';

class CameraDirectionInspector extends StatelessWidget {
  const CameraDirectionInspector({
    super.key,
    required this.session,
    required this.camera,
    required this.sampled,
    this.recovering = false,
  });
  final DirectorSession session;
  final Json camera, sampled;
  final bool recovering;
  @override
  Widget build(BuildContext context) {
    final id = camera['id'] as String, frame = session.frame.value;
    final free = camera['orientation_mode'] == 'free';
    final property = free ? 'rotation' : 'camera_target';
    final enabled =
        !session.readOnly &&
        !session.playing &&
        session.history.editBlock(id, property, frame) == null;
    final target = free
        ? null
        : session.history.cameraTargetValue(id, frame, resolve: !recovering);
    final objects = session.history.document.objects;
    final actors = objects.where((o) => o['kind'] == 'actor').toList();
    void setTarget(Json value) =>
        session.history.editProperty(id, 'camera_target', value, frame);
    final rotation = free ? quaternionEuler(sampled['rotation']) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LabeledField(
          label: tr(context, 'orientation_mode'),
          child: RevericSelect<String>(
            key: const ValueKey('director-camera-mode'),
            value: camera['orientation_mode'],
            enabled: !session.readOnly && !session.playing,
            items: [
              for (final mode in ['free', 'look_at'])
                RevericSelectItem(value: mode, label: tr(context, mode)),
            ],
            onChanged: (mode) => session.attempt(
              () => session.history.setCameraMode(id, mode, frame),
            ),
          ),
        ),
        if (free)
          LabeledField(
            label: tr(context, 'rotation'),
            child: XyzInput(
              session: session,
              fieldKey: 'camera_rotation',
              values: [for (final r in rotation!) r * 180 / math.pi],
              unit: '°',
              enabled: List.filled(3, enabled),
              onCommit: (axis, v) => session.history.editProperty(
                id,
                'rotation',
                eulerQuaternion([...rotation]..[axis] = v * math.pi / 180),
                frame,
              ),
            ),
          )
        else ...[
          LabeledField(
            label: tr(context, 'camera_target'),
            child: RevericSelect<String>(
              key: const ValueKey('director-target-type'),
              value: target!['type'],
              enabled: enabled && !recovering,
              items: [
                for (final type in [
                  'point',
                  if (objects.isNotEmpty) 'object',
                  if (actors.isNotEmpty) 'bone',
                ])
                  RevericSelectItem(
                    value: type,
                    label: tr(context, 'target_$type'),
                  ),
              ],
              onChanged: (type) => session.attempt(
                () => setTarget(switch (type) {
                  'point' => {'type': type, 'position': sampled['target']},
                  'object' => {
                    'type': type,
                    'object_id': objects.first['id'],
                    'offset': [0, 0, 0],
                  },
                  _ => {
                    'type': type,
                    'actor_id': actors.first['id'],
                    'bone': 'chest',
                    'offset': [0, 0, 0],
                  },
                }),
              ),
            ),
          ),
          if (target['type'] != 'point') ...[
            RevericSelect<String>(
              key: const ValueKey('director-target-object'),
              value:
                  target[target['type'] == 'bone' ? 'actor_id' : 'object_id'],
              enabled: enabled,
              items: [
                for (final o in target['type'] == 'bone' ? actors : objects)
                  RevericSelectItem(value: o['id'], label: o['name']),
              ],
              onChanged: (value) => session.attempt(
                () => setTarget({
                  ...target,
                  target['type'] == 'bone' ? 'actor_id' : 'object_id': value,
                }),
              ),
            ),
            if (target['type'] == 'bone')
              LabeledField(
                label: tr(context, 'bone'),
                child: RevericSelect<String>(
                  key: const ValueKey('director-target-bone'),
                  value: target['bone'],
                  enabled: enabled,
                  items: [
                    for (final bone in humanoidBones)
                      RevericSelectItem(
                        value: bone,
                        label: tr(context, 'bone_$bone'),
                      ),
                  ],
                  onChanged: (value) => session.attempt(
                    () => setTarget({...target, 'bone': value}),
                  ),
                ),
              ),
          ],
          LabeledField(
            label: tr(
              context,
              target['type'] == 'point' ? 'position' : 'offset',
            ),
            child: XyzInput(
              session: session,
              fieldKey: 'camera_target',
              enabled: List.filled(3, enabled),
              values: [
                for (final v
                    in target[target['type'] == 'point'
                        ? 'position'
                        : 'offset'])
                  (v as num).toDouble(),
              ],
              onCommit: (axis, value) {
                final field = target['type'] == 'point' ? 'position' : 'offset';
                setTarget({
                  ...target,
                  field: [...target[field] as List]..[axis] = value,
                });
              },
            ),
          ),
          LabeledField(
            label: tr(context, 'reference_up'),
            child: XyzInput(
              session: session,
              fieldKey: 'reference_up',
              enabled: List.filled(3, !session.readOnly && !session.playing),
              values: [
                for (final v in camera['reference_up']) (v as num).toDouble(),
              ],
              onCommit: (axis, value) => session.history.execute(
                (j) =>
                    (j['cameras'] as List).firstWhere(
                      (c) => c['id'] == id,
                    )['reference_up'] = [...camera['reference_up'] as List]
                      ..[axis] = value,
              ),
            ),
          ),
        ],
        PropertyKeyControl(session: session, id: id, property: property),
      ],
    );
  }
}

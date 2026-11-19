// 职责: 精确编辑路径几何参数、路点与贝塞尔控制柄。
// 关联文件:
//   lib/shared/services/director/path_edit.dart
//   lib/shared/widgets/director/paths/panel.dart
//   lib/shared/widgets/director/inspector/controls.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../components/reveric_button.dart';
import '../../../models/director/sampling.dart';
import '../../../services/director/session.dart';
import '../inspector/controls.dart';
import '../strings.dart';
import 'panel.dart';

class PathGeometryEditor extends StatelessWidget {
  final DirectorSession session;
  const PathGeometryEditor({super.key, required this.session});
  @override
  Widget build(BuildContext context) {
    final editor = session.pathEditor, path = session.pathEditor.visible!;
    final g = path['geometry'], kind = path['kind'];
    Widget number(String field, {bool integer = false}) => LabeledField(
      label: tr(context, 'path_$field'),
      child: CommitField(
        session: session,
        value: '${g[field]}',
        fieldKey: ValueKey('director-path-$field'),
        onCommit: (text) {
          final value = double.tryParse(text);
          if (value == null ||
              !value.isFinite ||
              integer && value != value.roundToDouble()) {
            return false;
          }
          return commitEdit(
            session,
            () => editor.update(
              (p) => p['geometry'][field] = integer ? value.toInt() : value,
            ),
          );
        },
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (kind == 'circle') ...[number('radius'), number('start_angle')],
        if (kind == 'rectangle') ...[
          number('width'),
          number('depth'),
          number('start_corner', integer: true),
        ],
        if (kind == 'circle' || kind == 'rectangle') ...[
          LabeledField(
            label: tr(context, 'path_plane'),
            child: XyzInput(
              session: session,
              fieldKey: 'path-plane',
              unit: '°',
              values: quaternionEuler(
                g['plane_rotation'],
              ).map((n) => n * 180 / math.pi).toList(),
              onCommit: (axis, value) => editor.update((p) {
                final angles = quaternionEuler(p['geometry']['plane_rotation']);
                angles[axis] = value * math.pi / 180;
                p['geometry']['plane_rotation'] = eulerQuaternion(angles);
              }),
            ),
          ),
          PathCheck(
            label: tr(context, 'path_clockwise'),
            value: g['clockwise'],
            onChanged: session.readOnly
                ? null
                : (value) => session.attempt(
                    () => editor.update(
                      (p) => p['geometry']['clockwise'] = value,
                    ),
                  ),
          ),
        ],
        if (kind == 'pencil' || kind == 'pen')
          PathCheck(
            label: tr(context, 'path_closed'),
            value: g['closed'],
            onChanged: session.readOnly
                ? null
                : (value) => session.attempt(
                    () => editor.update((p) => p['geometry']['closed'] = value),
                  ),
          ),
        for (final handle in editor.handles()) ...[
          LabeledField(
            label: switch (handle.field) {
              'start' || 'end' => tr(context, handle.field),
              'center' => tr(context, 'path_center'),
              'in_handle' =>
                '${tr(context, 'path_in_handle')} ${handle.index + 1}',
              'out_handle' =>
                '${tr(context, 'path_out_handle')} ${handle.index + 1}',
              _ => '${tr(context, 'position')} ${handle.index + 1}',
            },
            child: XyzInput(
              session: session,
              values: handle.position,
              fieldKey: 'path-${handle.id}',
              onCommit: (axis, value) {
                final next = handle.position.toList();
                next[axis] = value;
                editor.moveHandle(handle, next);
              },
            ),
          ),
          if (kind == 'pen' && handle.field == 'position') ...[
            PathCheck(
              label: tr(context, 'path_smooth'),
              value: g['nodes'][handle.index]['smooth'],
              onChanged: session.readOnly
                  ? null
                  : (value) => session.attempt(
                      () => editor.update((p) {
                        final node = p['geometry']['nodes'][handle.index];
                        node['smooth'] = value;
                        if (value) {
                          final out =
                              node['out_handle'] ??
                              [
                                node['position'][0] + .5,
                                node['position'][1],
                                node['position'][2],
                              ];
                          node['out_handle'] = out;
                          node['in_handle'] = [
                            for (var i = 0; i < 3; i++)
                              2 * node['position'][i] - out[i],
                          ];
                        }
                      }),
                    ),
            ),
            if (!session.readOnly &&
                g['nodes'][handle.index]['out_handle'] == null)
              RevericButton.text(
                label: tr(context, 'path_add_handles'),
                size: RevericButtonSize.compact,
                onPressed: () => session.attempt(
                  () => editor.update((p) {
                    final node = p['geometry']['nodes'][handle.index],
                        position = node['position'];
                    node['in_handle'] = [
                      position[0] - .5,
                      position[1],
                      position[2],
                    ];
                    node['out_handle'] = [
                      position[0] + .5,
                      position[1],
                      position[2],
                    ];
                    node['smooth'] = true;
                  }),
                ),
              ),
          ],
          if (!session.readOnly &&
              ((kind == 'pencil' && handle.field == 'point') ||
                  (kind == 'pen' && handle.field == 'position')))
            RevericButton.text(
              key: ValueKey('director-path-remove-point:${handle.index}'),
              label: tr(context, 'delete'),
              size: RevericButtonSize.compact,
              onPressed: () => session.attempt(
                () => editor.update(
                  (p) =>
                      (p['geometry'][kind == 'pen' ? 'nodes' : 'points']
                              as List)
                          .removeAt(handle.index),
                ),
              ),
            ),
        ],
        if (!session.readOnly && (kind == 'pencil' || kind == 'pen'))
          RevericButton.text(
            key: const ValueKey('director-path-add-point'),
            label: tr(context, 'path_add_point'),
            size: RevericButtonSize.compact,
            onPressed: () => session.attempt(
              () => editor.update((p) {
                final points =
                    p['geometry'][kind == 'pen' ? 'nodes' : 'points'] as List;
                final last = points.isEmpty
                    ? [0.0, editor.height, 0.0]
                    : kind == 'pen'
                    ? points.last['position']
                    : points.last;
                final next = [last[0] + 1, last[1], last[2]];
                points.add(
                  kind == 'pen' ? {'position': next, 'smooth': false} : next,
                );
              }),
            ),
          ),
      ],
    );
  }
}

// 职责: 编辑场景灯光的基础值与稀疏属性关键帧。
// 关联文件:
//   lib/shared/models/director/sampling.dart
//   lib/shared/services/director/session.dart
//   lib/shared/widgets/director/inspector/property.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
import 'package:flutter/material.dart';
import '../../../models/director/sampling.dart';
import '../../../services/director/session.dart';
import '../strings.dart';
import 'controls.dart';
import 'property.dart';

class LightingInspector extends StatelessWidget {
  const LightingInspector({super.key, required this.session});
  final DirectorSession session;
  @override
  Widget build(BuildContext context) {
    final document = session.history.visible, frame = session.frame.value;
    final lighting = document.lighting;
    for (final track in document.propertyTracks.where(
      (t) => t.targetId == document.id,
    )) {
      final field = track.property.substring('lighting.'.length);
      lighting[field] = samplePropertyTrack(
        track,
        frame,
        base: lighting[field],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(tr(context, 'lighting')),
        for (final field in [
          'ambient_intensity',
          'key_intensity',
          'key_direction',
        ])
          LabeledField(
            label: tr(context, 'lighting.$field'),
            child: PropertyKeyControl(
              session: session,
              id: document.id,
              property: 'lighting.$field',
              child: field == 'key_direction'
                  ? XyzInput(
                      session: session,
                      fieldKey: 'lighting.$field',
                      values: [
                        for (final v in lighting[field]) (v as num).toDouble(),
                      ],
                      enabled: List.filled(
                        3,
                        !session.readOnly &&
                            !session.playing &&
                            session.history.editBlock(
                                  document.id,
                                  'lighting.$field',
                                  frame,
                                ) ==
                                null,
                      ),
                      onCommit: (axis, value) => session.history.editProperty(
                        document.id,
                        'lighting.$field',
                        [...lighting[field] as List]..[axis] = value,
                        frame,
                      ),
                    )
                  : CommitField(
                      fieldKey: ValueKey('director-field:lighting.$field'),
                      session: session,
                      value: (lighting[field] as num).toString(),
                      enabled:
                          !session.readOnly &&
                          !session.playing &&
                          session.history.editBlock(
                                document.id,
                                'lighting.$field',
                                frame,
                              ) ==
                              null,
                      onCommit: (text) {
                        final value = double.tryParse(text);
                        return value != null &&
                            commitEdit(
                              session,
                              () => session.history.editProperty(
                                document.id,
                                'lighting.$field',
                                value,
                                frame,
                              ),
                            );
                      },
                    ),
            ),
          ),
      ],
    );
  }
}

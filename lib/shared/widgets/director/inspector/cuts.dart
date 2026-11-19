// 职责: 编辑默认机位与全局切镜的时间和机位引用。
// 关联文件:
//   lib/shared/services/director/session.dart
//   lib/shared/services/director/commands.dart
//   lib/shared/widgets/director/timeline.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
import 'package:flutter/material.dart';
import '../../../components/reveric_button.dart';
import '../../../components/reveric_context_menu.dart';
import '../../../components/reveric_more_menu_button.dart';
import '../../../components/reveric_select.dart';
import '../../../services/director/session.dart';
import '../../../theme/theme.dart';
import '../strings.dart';
import 'controls.dart';

class CameraCutsInspector extends StatelessWidget {
  const CameraCutsInspector({super.key, required this.session});
  final DirectorSession session;
  @override
  Widget build(BuildContext context) {
    final document = session.history.document;
    final colors = RevericTheme.colorsOf(context);
    final items = [
      for (final c in document.activeCameras)
        RevericSelectItem<String>(value: c['id'], label: c['name']),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LabeledField(
          label: tr(context, 'opening_camera'),
          child: RevericSelect<String>(
            key: const ValueKey('director-default-camera'),
            value: document.defaultCameraId,
            items: items,
            enabled: !session.readOnly && !session.playing,
            onChanged: (id) =>
                session.attempt(() => session.history.setDefaultCamera(id)),
          ),
        ),
        if (session.history.timelineVisible) ...[
          SectionTitle(tr(context, 'camera_cuts')),
          if (!session.readOnly)
            RevericButton.secondary(
              key: const ValueKey('director-add-cut'),
              label: tr(context, 'add_cut'),
              size: RevericButtonSize.compact,
              onPressed: session.playing
                  ? null
                  : () => session.attempt(
                      () => session.history.setCut(
                        session.frame.value,
                        session.viewCameraId,
                      ),
                    ),
            ),
          for (final cut in document.cuts)
            Padding(
              key: ValueKey('director-cut:${cut['id']}'),
              padding: const EdgeInsets.only(top: RevericSpacing.xs),
              child: Row(
                children: [
                  Expanded(
                    child: CommitField(
                      fieldKey: ValueKey('director-cut-frame:${cut['id']}'),
                      session: session,
                      value: '${cut['frame']}',
                      enabled: !session.readOnly && !session.playing,
                      suffix: tr(context, 'frame'),
                      onCommit: (text) {
                        final frame = int.tryParse(text);
                        return frame != null &&
                            commitEdit(
                              session,
                              () => session.history.editCut(
                                cut['id'],
                                frame,
                                cut['camera_id'],
                              ),
                            );
                      },
                    ),
                  ),
                  const SizedBox(width: RevericSpacing.xs),
                  Expanded(
                    child: RevericSelect<String>(
                      key: ValueKey('director-cut-camera:${cut['id']}'),
                      value: cut['camera_id'],
                      items: items,
                      enabled: !session.readOnly && !session.playing,
                      onChanged: (id) => session.attempt(
                        () => session.history.editCut(
                          cut['id'],
                          cut['frame'],
                          id,
                        ),
                      ),
                    ),
                  ),
                  if (!session.readOnly)
                    RevericMoreMenuButton(
                      key: ValueKey('director-cut-more:${cut['id']}'),
                      entries: () => [
                        RevericMenuItem(
                          label: tr(context, 'delete'),
                          icon: RevericIcons.delete_outline,
                          labelColor: colors.error,
                          iconColor: colors.error,
                          enabled: !session.playing,
                          onTap: () => session.attempt(
                            () => session.history.removeCut(cut['id']),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

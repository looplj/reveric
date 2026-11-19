// 职责: 展示属性关键帧、过渡方式和共享编辑限制。
// 关联文件:
//   lib/shared/services/director/commands.dart
//   lib/shared/services/director/session.dart
//   lib/shared/widgets/director/inspector/controls.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
import 'package:flutter/material.dart';
import '../../../components/reveric_select.dart';
import '../../../services/director/session.dart';
import '../../../theme/theme.dart';
import '../strings.dart';
import 'controls.dart';

/// 属性关键帧控件。传入 [child] 时关键帧按钮跟在字段行尾、过渡方式放到下方；
/// [label] 同时给出时按 [KeyRow] 行内标签排布；都不传时按钮与过渡方式同一行。
class PropertyKeyControl extends StatelessWidget {
  const PropertyKeyControl({
    super.key,
    required this.session,
    required this.id,
    required this.property,
    this.child,
    this.label,
  });
  final DirectorSession session;
  final String id, property;
  final Widget? child;
  final String? label;
  @override
  Widget build(BuildContext context) {
    final frame = session.frame.value;
    final track = session.history.document.tracks
        .where((t) => t['target_id'] == id && t['property'] == property)
        .firstOrNull;
    final key = (track?['keys'] as List?)
        ?.where((k) => k['frame'] == frame)
        .firstOrNull;
    final block = session.history.editBlock(id, property, frame);
    final timeline = session.history.timelineVisible;
    final button = timeline && !session.readOnly
        ? KeyButton(
            key: ValueKey('director-key:camera:$property'),
            state: keyState(session, id, property),
            tooltip: tr(context, 'toggle_key'),
            onPressed:
                session.playing ||
                    session.history.controlled(id, property, frame)
                ? null
                : () => session.attempt(
                    () => session.history.toggleKey(id, property, frame),
                  ),
          )
        : null;
    final easing = timeline && key != null
        ? RevericSelect<String>(
            key: ValueKey('director-easing:$property'),
            value: key['easing'],
            height: RevericSizes.fieldHeightSm,
            enabled: !session.readOnly && !session.playing,
            items: [
              for (final e
                  in property == 'visible'
                      ? ['hold']
                      : ['linear', 'smoothstep', 'hold'])
                RevericSelectItem(value: e, label: tr(context, e)),
            ],
            onChanged: (e) => session.attempt(
              () => session.history.setKeyEasing(id, property, frame, e),
            ),
          )
        : null;
    final field = child;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (field == null) ...[
          if (button != null)
            Row(
              children: [
                button,
                if (easing != null) Expanded(child: easing),
              ],
            ),
        ] else ...[
          if (label != null)
            KeyRow(label: label!, keyButton: button, child: field)
          else
            Row(
              children: [
                Expanded(child: field),
                if (button != null) ...[
                  const SizedBox(width: RevericSpacing.xs),
                  button,
                ],
              ],
            ),
          if (easing != null) ...[
            if (label == null) const SizedBox(height: RevericSpacing.xxs),
            easing,
          ],
        ],
        if (block != null)
          Text(
            tr(context, block),
            style: RevericTheme.typographyOf(
              context,
            ).uiTiny.copyWith(color: RevericTheme.colorsOf(context).textMuted),
          ),
      ],
    );
  }
}

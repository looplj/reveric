// 职责: 编辑完整角色姿态，按自动帧规则提交角度、高度、预设和复制粘贴。
// 关联文件:
//   lib/shared/models/director/pose.dart
//   lib/shared/models/director/presets.dart
//   lib/shared/services/director/session.dart
//   lib/shared/widgets/director/inspector/controls.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../components/reveric_button.dart';
import '../../../models/director/document.dart';
import '../../../models/director/pose.dart';
import '../../../models/director/presets.dart';
import '../../../services/director/session.dart';
import '../../../theme/theme.dart';
import '../strings.dart';
import 'controls.dart';

class PoseInspector extends StatelessWidget {
  final DirectorSession session;
  final Json object;
  const PoseInspector({super.key, required this.session, required this.object});
  @override
  Widget build(BuildContext context) {
    final id = object['id'] as String, frame = session.frame.value;
    final pose = ActorPose.fromJson(object['pose']);
    final block = session.history.editBlock(id, 'pose', frame);
    final enabled = !session.readOnly && !session.playing && block == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!session.readOnly) ...[
          Row(
            children: [
              Expanded(child: SectionTitle(tr(context, 'pose_presets'))),
              if (session.history.timelineVisible)
                KeyButton(
                  key: const ValueKey('director-key:pose'),
                  state: keyState(session, id, 'pose'),
                  tooltip: tr(context, 'toggle_key'),
                  onPressed: session.playing
                      ? null
                      : () => session.attempt(
                          () => session.history.toggleKey(id, 'pose', frame),
                        ),
                ),
            ],
          ),
          if (block != null)
            Text(
              tr(context, block),
              style: RevericTheme.typographyOf(context).uiTiny.copyWith(
                color: RevericTheme.colorsOf(context).textMuted,
              ),
            ),
          LayoutBuilder(
            builder: (context, constraints) {
              const columns = 4;
              final width =
                  (constraints.maxWidth - (columns - 1) * RevericSpacing.xxs) /
                  columns;
              return Wrap(
                spacing: RevericSpacing.xxs,
                runSpacing: RevericSpacing.xxs,
                children: [
                  for (final preset in poseIds)
                    SizedBox(
                      width: width,
                      child: _PresetTile(
                        key: ValueKey('director-pose-preset:$preset'),
                        label: tr(context, 'pose_$preset'),
                        onPressed: enabled
                            ? () => session.attempt(
                                () => session.history.applyPose(
                                  id,
                                  preset,
                                  frame,
                                ),
                              )
                            : null,
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: RevericSpacing.xxs),
          Wrap(
            spacing: RevericSpacing.xxs,
            children: [
              RevericButton.text(
                label: tr(context, 'pose_copy'),
                size: RevericButtonSize.compact,
                onPressed: () {
                  session.poseClipboard = pose.toJson();
                  session.refresh();
                },
              ),
              RevericButton.text(
                label: tr(context, 'pose_paste'),
                size: RevericButtonSize.compact,
                onPressed: enabled && session.poseClipboard != null
                    ? () => session.attempt(
                        () => session.history.editProperty(
                          id,
                          'pose',
                          cloneJson(session.poseClipboard!),
                          frame,
                        ),
                      )
                    : null,
              ),
              RevericButton.text(
                label: tr(context, 'pose_reset'),
                size: RevericButtonSize.compact,
                onPressed: enabled
                    ? () => session.attempt(
                        () => session.history.editProperty(
                          id,
                          'pose',
                          ActorPose.standing().toJson(),
                          frame,
                        ),
                      )
                    : null,
              ),
            ],
          ),
        ],
        SectionTitle(tr(context, 'pose_adjust')),
        for (final (group, controls) in _poseGroups) ...[
          Padding(
            padding: const EdgeInsets.only(
              top: RevericSpacing.xs,
              bottom: RevericSpacing.xxs,
            ),
            child: Text(
              tr(context, 'pose_group_$group'),
              style: RevericTheme.typographyOf(context).uiSmallSemibold,
            ),
          ),
          for (final (parameterId, short) in controls)
            _PoseControl(
              key: ValueKey('pose-control:$parameterId'),
              session: session,
              object: object,
              label: tr(context, 'pose_short_$short'),
              parameter: poseParameters.firstWhere((p) => p.id == parameterId),
            ),
        ],
      ],
    );
  }
}

/// 姿态调节分组：每个参数配一个组内短标签，完整名称放在提示里。
final _poseGroups = [
  (
    'body',
    [
      ('body_pitch', 'lean'),
      ('body_yaw', 'turn'),
      ('body_roll', 'tilt'),
      ('root_offset_y', 'height'),
    ],
  ),
  (
    'torso',
    [('torso_pitch', 'lean'), ('torso_yaw', 'twist'), ('torso_roll', 'tilt')],
  ),
  (
    'head',
    [('head_pitch', 'nod'), ('head_yaw', 'look'), ('head_roll', 'tilt')],
  ),
  for (final side in ['left', 'right']) ...[
    (
      '${side}_arm',
      [
        ('${side}_shoulder_raise', 'raise'),
        ('${side}_shoulder_abduct', 'abduct'),
        ('${side}_shoulder_twist', 'twist'),
        ('${side}_elbow_bend', 'bend'),
      ],
    ),
  ],
  for (final side in ['left', 'right']) ...[
    (
      '${side}_leg',
      [
        ('${side}_hip_raise', 'lift'),
        ('${side}_hip_abduct', 'abduct'),
        ('${side}_hip_twist', 'twist'),
        ('${side}_knee_bend', 'bend'),
      ],
    ),
  ],
];

class _PresetTile extends StatelessWidget {
  const _PresetTile({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Material(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: InkWell(
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        onTap: onPressed,
        child: SizedBox(
          height: RevericSizes.directorActionHeight,
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RevericTheme.typographyOf(context).uiSmall.copyWith(
                color: onPressed == null
                    ? colors.textSubtle
                    : colors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PoseControl extends HookWidget {
  final DirectorSession session;
  final Json object;
  final PoseParameter parameter;
  final String label;
  const _PoseControl({
    super.key,
    required this.session,
    required this.object,
    required this.parameter,
    required this.label,
  });
  @override
  Widget build(BuildContext context) {
    final dragging = useRef(false),
        owner = useMemoized(Object.new),
        pointer = useRef<int?>(null);
    final baseline = useRef<Json?>(null);
    final current = (object['pose'][parameter.id] as num).toDouble();
    final id = object['id'] as String, frame = session.frame.value;
    final enabled =
        !session.readOnly &&
        !session.playing &&
        session.history.editBlock(id, 'pose', frame) == null;
    void cancel() {
      dragging.value = false;
      baseline.value = null;
      session.cancelEditGesture();
    }

    Json changed(double value) => {
      ...(baseline.value ?? object['pose'] as Json),
      parameter.id: value,
    };
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): cancel},
      child: Listener(
        onPointerDown: (event) {
          pointer.value = event.pointer;
        },
        onPointerCancel: (_) => cancel(),
        child: Padding(
          padding: const EdgeInsets.only(bottom: RevericSpacing.xxs),
          child: Row(
            children: [
              SizedBox(
                width: RevericSizes.directorPoseLabelWidth,
                child: Tooltip(
                  message: tr(context, 'pose_param_${parameter.id}'),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: RevericTheme.typographyOf(context).uiTiny.copyWith(
                      color: RevericTheme.colorsOf(context).textMuted,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    overlayShape: SliderComponentShape.noOverlay,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    trackHeight: 2,
                  ),
                  child: Slider(
                    key: ValueKey('director-pose-slider:${parameter.id}'),
                    value: current,
                    min: parameter.min,
                    max: parameter.max,
                    onChangeStart: enabled
                        ? (_) {
                            if (pointer.value != null &&
                                !session.claimEditGesture(
                                  owner,
                                  pointer.value!,
                                )) {
                              return;
                            }
                            dragging.value = true;
                            baseline.value = cloneJson(object['pose']);
                          }
                        : null,
                    onChanged: enabled
                        ? (value) {
                            if (dragging.value) {
                              session.attempt(
                                () => session.history.previewProperty(
                                  id,
                                  'pose',
                                  changed(value),
                                  frame,
                                ),
                              );
                            }
                          }
                        : null,
                    onChangeEnd: enabled
                        ? (_) {
                            if (dragging.value) {
                              dragging.value = false;
                              session.attempt(session.history.commitGesture);
                            }
                            if (pointer.value != null) {
                              session.releaseEditGesture(owner, pointer.value!);
                            }
                            baseline.value = null;
                          }
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: RevericSpacing.xs),
              SizedBox(
                width: RevericSizes.directorPoseValueWidth,
                child: CommitField(
                  fieldKey: ValueKey('director-pose-value:${parameter.id}'),
                  session: session,
                  value: current.toStringAsFixed(
                    parameter.id == 'root_offset_y' ? 3 : 1,
                  ),
                  suffix: parameter.id == 'root_offset_y' ? 'm' : '°',
                  enabled: enabled,
                  onCommit: (text) {
                    final value = double.tryParse(text);
                    return value != null &&
                        commitEdit(
                          session,
                          () => session.history.editProperty(id, 'pose', {
                            ...object['pose'] as Json,
                            parameter.id: value,
                          }, frame),
                        );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

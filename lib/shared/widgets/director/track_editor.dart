// 职责: 使用应用表单编辑运动区间和关键帧，原子校验后提交。
// 关联文件:
//   lib/shared/widgets/director/fields.dart
//   lib/shared/services/director/session.dart
//   lib/shared/models/director/sampling.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules: .agents/rules/hooks.md、.agents/rules/form.md、.agents/rules/text-input-ime.md
import 'dart:math' as math;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:reveric/shared/models/director/presets.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_dialog.dart';
import '../../../shared/components/reveric_select.dart';
import '../../../shared/form/hooked_text_form_field.dart';
import '../../../shared/models/director/document.dart';
import '../../../shared/models/director/sampling.dart';
import '../../../shared/services/director/session.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/utils/text_input_composing.dart';
import '../../../third/form/flutter_hook_form.dart';
import 'fields.dart';
import 'strings.dart';

Future<void> editTrackOrClip(
  BuildContext context,
  DirectorSession session,
  Json item,
) async {
  if (session.readOnly) {
    return;
  }
  if (session.hasPendingInput) {
    session.error = 'apply_pending';
    session.refresh();
    return;
  }
  session.pause();
  if (item.containsKey('geometry')) {
    session.select(item['target_id']);
    session.pathEditor.select(item['id']);
    return;
  }
  if (item['keys'] != null) {
    final selected = await showRevericDialog<int>(
      context: context,
      builder: (c) => RevericDialog(
        title: tr(c, 'keys'),
        content: SizedBox(
          height: 280,
          child: ListView(
            children: [
              for (final key in (item['keys'] as List).indexed)
                ListTile(
                  title: Text('${key.$2['frame']} · ${key.$2['value']}'),
                  subtitle: Text(tr(c, key.$2['easing'])),
                  onTap: () => Navigator.pop(c, key.$1),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && context.mounted) {
      await _editKey(context, session, item, selected);
    }
    return;
  }
  await showRevericDialog<void>(
    context: context,
    builder: (_) => HookBuilder(
      builder: (c) {
        final form = useForm<DirectorField>(listen: false),
            start = useTextEditingController(text: '${item['start_frame']}'),
            end = useTextEditingController(text: '${item['end_frame']}');
        final kind = useState(item['kind'] as String), error = useState(false);
        final move = item.containsKey('camera_id');
        return RevericDialog(
          title: tr(c, 'edit'),
          content: HookedForm(
            form: form,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  HookedTextFormField<DirectorField>(
                    fieldHook: DirectorField.start,
                    controller: start,
                    label: tr(c, 'start'),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: RevericSpacing.lg),
                  HookedTextFormField<DirectorField>(
                    fieldHook: DirectorField.end,
                    controller: end,
                    label: tr(c, 'end'),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: RevericSpacing.lg),
                  RevericSelect<String>(
                    value: kind.value,
                    items: [
                      for (final v in moveKinds)
                        RevericSelectItem(
                          value: v,
                          label: tr(c, move ? 'move_$v' : 'path_$v'),
                        ),
                    ],
                    onChanged: (v) => kind.value = v,
                  ),
                  if (error.value) Text(tr(c, 'invalid')),
                ],
              ),
            ),
          ),
          actions: [
            RevericButton.secondary(
              label: tr(c, 'cancel'),
              onPressed: () => Navigator.pop(c),
            ),
            RevericButton.primary(
              label: tr(c, 'apply'),
              onPressed: () {
                syncFormFieldsFromControllersBeforeValidate(
                  form: form,
                  fields: {DirectorField.start: start, DirectorField.end: end},
                );
                if (!form.validate()) {
                  return;
                }
                try {
                  session.history.upsertMove({
                    ...item,
                    'start_frame': int.parse(start.text),
                    'end_frame': int.parse(end.text),
                    'kind': kind.value,
                  });
                  Navigator.pop(c);
                } catch (e, st) {
                  session.report(e, st);
                  error.value = true;
                }
              },
            ),
          ],
        );
      },
    ),
  );
}

Future<void> _editKey(
  BuildContext context,
  DirectorSession session,
  Json track,
  int index,
) async {
  final key = (track['keys'] as List)[index] as Json;
  await showRevericDialog<void>(
    context: context,
    builder: (_) => HookBuilder(
      builder: (c) {
        final form = useForm<DirectorField>(listen: false),
            frame = useTextEditingController(text: '${key['frame']}');
        final rotation = track['property'] == 'rotation';
        final initialValue = rotation
            ? quaternionEuler(
                key['value'],
              ).map((v) => v * 180 / math.pi).join(', ')
            : key['value'] is List
            ? (key['value'] as List).join(', ')
            : key['value'] is Map
            ? jsonEncode(key['value'])
            : '${key['value']}';
        final value = useTextEditingController(text: initialValue);
        final easing = useState(key['easing'] as String),
            error = useState(false);
        return RevericDialog(
          title: tr(c, 'keys'),
          content: HookedForm(
            form: form,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  HookedTextFormField<DirectorField>(
                    fieldHook: DirectorField.frame,
                    controller: frame,
                    label: tr(c, 'frame'),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: RevericSpacing.lg),
                  HookedTextFormField<DirectorField>(
                    fieldHook: DirectorField.value,
                    fieldKey: const ValueKey('director-key-value'),
                    controller: value,
                    label: tr(c, rotation ? 'rotation' : 'value'),
                    helperText: rotation ? 'X°, Y°, Z°' : null,
                  ),
                  const SizedBox(height: RevericSpacing.lg),
                  RevericSelect<String>(
                    value: easing.value,
                    items: ['linear', 'smoothstep', 'hold']
                        .map(
                          (v) => RevericSelectItem(value: v, label: tr(c, v)),
                        )
                        .toList(),
                    onChanged: (v) => easing.value = v,
                  ),
                  if (error.value) Text(tr(c, 'invalid')),
                ],
              ),
            ),
          ),
          actions: [
            RevericButton.secondary(
              label: tr(c, 'cancel'),
              onPressed: () => Navigator.pop(c),
            ),
            RevericButton.text(
              label: tr(c, 'delete'),
              onPressed: () {
                try {
                  session.history.execute((j) {
                    final t = (j['tracks'] as List).firstWhere(
                      (e) => e['id'] == track['id'],
                    );
                    (t['keys'] as List).removeAt(index);
                    if ((t['keys'] as List).isEmpty) {
                      (j['tracks'] as List).remove(t);
                    }
                  });
                  Navigator.pop(c);
                } catch (e, st) {
                  session.report(e, st);
                  error.value = true;
                }
              },
            ),
            RevericButton.primary(
              label: tr(c, 'apply'),
              onPressed: () {
                syncFormFieldsFromControllersBeforeValidate(
                  form: form,
                  fields: {
                    DirectorField.frame: frame,
                    DirectorField.value: value,
                  },
                );
                if (!form.validate()) {
                  return;
                }
                try {
                  dynamic nextValue = key['value'];
                  if (value.text != initialValue) {
                    if (rotation || key['value'] is List) {
                      final components = value.text
                          .trim()
                          .split(RegExp(r'[ ,，]+'))
                          .map(double.parse)
                          .toList();
                      if (rotation) {
                        if (components.length != 3 ||
                            components.any((v) => !v.isFinite)) {
                          invalid('rotation', 'expected_euler3');
                        }
                        nextValue = eulerQuaternion([
                          for (final v in components) v * math.pi / 180,
                        ]);
                      } else {
                        nextValue = components;
                      }
                    } else if (key['value'] is Map || key['value'] is bool) {
                      nextValue = jsonDecode(value.text);
                    } else if (key['value'] is String) {
                      nextValue = value.text;
                    } else {
                      nextValue = double.parse(value.text);
                    }
                  }
                  session.history.execute((j) {
                    final t = (j['tracks'] as List).firstWhere(
                      (e) => e['id'] == track['id'],
                    );
                    final keys = t['keys'] as List;
                    keys[index] = {
                      'frame': int.parse(frame.text),
                      'value': nextValue,
                      'easing': easing.value,
                    };
                    keys.sort(
                      (a, b) => (a['frame'] as int).compareTo(b['frame']),
                    );
                  });
                  Navigator.pop(c);
                } catch (e, st) {
                  session.report(e, st);
                  error.value = true;
                }
              },
            ),
          ],
        );
      },
    ),
  );
}

// 职责: 角色属性中的运动轨迹分区 — 列出路径，提供五种路径的创建、区间、几何编辑与转换入口。
// 关联文件:
//   lib/shared/services/director/path_edit.dart
//   lib/shared/widgets/director/paths/geometry.dart
//   lib/shared/widgets/director/inspector/controls.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules: .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../components/reveric_button.dart';
import '../../../components/reveric_checkbox.dart';
import '../../../components/reveric_select.dart';
import '../../../models/director/path.dart';
import '../../../services/director/session.dart';
import '../../../theme/theme.dart';
import '../inspector/controls.dart';
import '../strings.dart';
import 'geometry.dart';

/// 角色属性里的「运动轨迹」分区：列出该角色的路径、新建路径并编辑选中的一条。
class DirectorPathSection extends HookWidget {
  final DirectorSession session;
  final String actorId;
  const DirectorPathSection({
    super.key,
    required this.session,
    required this.actorId,
  });
  @override
  Widget build(BuildContext context) {
    final editor = session.pathEditor;
    useListenable(editor);
    useListenable(session.history);
    useListenable(session);
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final path = editor.visible;
    final paths = session.history.document.paths
        .where((p) => p['target_id'] == actorId)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(tr(context, 'path')),
        for (final p in paths)
          Padding(
            padding: const EdgeInsets.only(bottom: RevericSpacing.xxs),
            child: Material(
              color: p['id'] == editor.selectedId
                  ? colors.selected
                  : colors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(RevericRadius.medium),
              child: InkWell(
                key: ValueKey('director-path:${p['id']}'),
                borderRadius: BorderRadius.circular(RevericRadius.medium),
                onTap: session.playing
                    ? null
                    : () => editor.select(
                        p['id'] == editor.selectedId ? null : p['id'],
                      ),
                child: SizedBox(
                  height: RevericSizes.directorRowHeight,
                  child: Row(
                    children: [
                      const SizedBox(width: RevericSpacing.sm),
                      RevericIcon(
                        RevericIcons.alt_route_outlined,
                        size: RevericSizes.directorSmallIcon,
                        color: p['id'] == editor.selectedId
                            ? colors.accent
                            : colors.textMuted,
                      ),
                      const SizedBox(width: RevericSpacing.xs),
                      Expanded(
                        child: Text(
                          tr(context, 'path_${p['kind']}'),
                          style: typo.uiSmall.copyWith(
                            color: p['id'] == editor.selectedId
                                ? colors.accent
                                : colors.textPrimary,
                          ),
                        ),
                      ),
                      Text(
                        '${p['start_frame']}–${p['end_frame']}',
                        style: typo.uiTiny.copyWith(
                          color: colors.textMuted,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(width: RevericSpacing.sm),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (paths.isEmpty && !editor.creating)
          Padding(
            padding: const EdgeInsets.only(bottom: RevericSpacing.xs),
            child: Text(
              tr(context, 'path_hint'),
              style: typo.uiTiny.copyWith(color: colors.textMuted),
            ),
          ),
        if (!session.readOnly && !editor.creating) ...[
          const SizedBox(height: RevericSpacing.xxs),
          Wrap(
            spacing: RevericSpacing.xxs,
            runSpacing: RevericSpacing.xxs,
            children: [
              for (final kind in pathKinds)
                RevericButton.secondary(
                  key: ValueKey('director-path-create:$kind'),
                  label: tr(context, 'path_$kind'),
                  size: RevericButtonSize.compact,
                  onPressed: session.playing
                      ? null
                      : () => session.attempt(
                          () => editor.begin(
                            actorId,
                            kind,
                            session.range,
                            session.frame.value,
                          ),
                        ),
                ),
            ],
          ),
        ],
        if (path != null)
          Container(
            margin: const EdgeInsets.only(top: RevericSpacing.sm),
            padding: const EdgeInsets.all(RevericSpacing.sm),
            decoration: BoxDecoration(
              border: Border.all(color: colors.border),
              borderRadius: BorderRadius.circular(RevericRadius.large),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tr(context, 'path_${path['kind']}'),
                  style: typo.uiSmallSemibold,
                ),
                const SizedBox(height: RevericSpacing.sm),
                Row(
                  children: [
                    for (final field in ['start', 'end']) ...[
                      if (field == 'end')
                        const SizedBox(width: RevericSpacing.xs),
                      Expanded(
                        child: LabeledField(
                          label: tr(context, field),
                          child: CommitField(
                            session: session,
                            value: '${path['${field}_frame']}',
                            fieldKey: ValueKey('director-path-$field'),
                            onCommit: (text) {
                              final number = int.tryParse(text);
                              if (number == null) {
                                return false;
                              }
                              return commitEdit(
                                session,
                                () => editor.update(
                                  (p) => p['${field}_frame'] = number,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                LabeledField(
                  label: tr(context, 'path_easing'),
                  child: RevericSelect<String>(
                    key: const ValueKey('director-path-easing'),
                    value: path['easing'],
                    height: RevericSizes.fieldHeightSm,
                    enabled: !session.readOnly,
                    items: [
                      for (final easing in ['linear', 'smoothstep', 'hold'])
                        RevericSelectItem(
                          value: easing,
                          label: tr(context, easing),
                        ),
                    ],
                    onChanged: (v) => session.attempt(
                      () => editor.update((p) => p['easing'] = v),
                    ),
                  ),
                ),
                PathCheck(
                  label: tr(context, 'path_orient'),
                  value: path['orient_to_path'],
                  onChanged: session.readOnly
                      ? null
                      : (v) => session.attempt(
                          () => editor.update((p) => p['orient_to_path'] = v),
                        ),
                ),
                if (!session.readOnly)
                  PathCheck(
                    label: tr(context, 'path_replace'),
                    value: editor.replace,
                    onChanged: (v) {
                      editor.replace = v;
                      session.refresh();
                    },
                  ),
                const SizedBox(height: RevericSpacing.xs),
                PathGeometryEditor(session: session),
                if (!session.readOnly && editor.drawing)
                  LabeledField(
                    label: tr(context, 'path_height'),
                    child: CommitField(
                      session: session,
                      value: editor.height.toStringAsFixed(2),
                      fieldKey: const ValueKey('director-path-height'),
                      onCommit: (text) {
                        final value = double.tryParse(text);
                        if (value == null ||
                            !value.isFinite ||
                            value.abs() > 50) {
                          return false;
                        }
                        editor.height = value;
                        return true;
                      },
                    ),
                  ),
                const SizedBox(height: RevericSpacing.xs),
                Wrap(
                  spacing: RevericSpacing.xxs,
                  runSpacing: RevericSpacing.xxs,
                  children: [
                    if (!session.readOnly && editor.creating)
                      RevericButton.primary(
                        key: const ValueKey('director-path-finish'),
                        label: tr(
                          context,
                          editor.drawing ? 'path_finish' : 'apply',
                        ),
                        size: RevericButtonSize.compact,
                        onPressed: () => session.attempt(editor.finish),
                      ),
                    if (!session.readOnly && !editor.creating)
                      RevericButton.secondary(
                        key: const ValueKey('director-path-bake'),
                        label: tr(context, 'bake'),
                        size: RevericButtonSize.compact,
                        onPressed: () => session.attempt(editor.bake),
                      ),
                    if (!session.readOnly)
                      RevericButton.text(
                        key: const ValueKey('director-path-delete'),
                        label: tr(context, 'delete'),
                        size: RevericButtonSize.compact,
                        onPressed: () => session.attempt(editor.remove),
                      ),
                    RevericButton.text(
                      key: const ValueKey('director-path-cancel'),
                      label: tr(context, session.readOnly ? 'close' : 'cancel'),
                      size: RevericButtonSize.compact,
                      onPressed: editor.cancel,
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class PathCheck extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  const PathCheck({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Row(
      children: [
        RevericCheckbox(
          value: value,
          onChanged: onChanged,
          semanticLabel: label,
        ),
        Expanded(
          child: Text(label, style: RevericTheme.typographyOf(context).uiSmall),
        ),
      ],
    ),
  );
}

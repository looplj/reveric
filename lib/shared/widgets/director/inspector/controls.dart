// 职责: 属性栏的输入件 — 回车或失焦即提交的数值框、三轴输入行与逐项关键帧按钮。
// 关联文件:
//   lib/shared/services/director/session.dart
//   lib/shared/services/director/commands.dart
//   lib/shared/widgets/director/inspector.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/text-input-ime.md
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../../components/reveric_input_decoration.dart';
import '../../../services/director/session.dart';
import '../../../theme/theme.dart';

/// 单个即时提交字段：输入期只改本地 controller；回车或失焦时交给 [onCommit]，
/// 返回 false 表示输入非法，字段保持错误态并继续占住会话的待提交标记。
/// Esc 撤回到 [value]。未聚焦时跟随 [value] 刷新显示。
class CommitField extends HookWidget {
  const CommitField({
    super.key,
    required this.session,
    required this.value,
    required this.onCommit,
    this.prefix,
    this.suffix,
    this.enabled = true,
    this.numeric = true,
    this.fieldKey,
  });
  final DirectorSession session;
  final String value;
  final bool Function(String text) onCommit;
  final String? prefix, suffix;
  final bool enabled, numeric;
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) {
    final controller = useTextEditingController(text: value);
    final focus = useFocusNode();
    final error = useState(false);
    final dirty = useRef(false);
    final commit = useRef(onCommit);
    commit.value = onCommit;

    final canEdit = enabled && !session.readOnly;

    void setPending(bool pending) {
      if (session.hasPendingInput == pending) {
        return;
      }
      session.hasPendingInput = pending;
      // 父级会因为待提交标记变化而重建；放到帧后避免输入中途失焦。
      WidgetsBinding.instance.addPostFrameCallback((_) => session.refresh());
    }

    void submit() {
      if (!canEdit || !dirty.value) {
        return;
      }
      final ok = commit.value(controller.text.trim());
      error.value = !ok;
      if (ok) {
        dirty.value = false;
        setPending(false);
      }
    }

    useEffect(() {
      void changed() {
        if (!focus.hasFocus) {
          submit();
        }
      }

      focus.addListener(changed);
      return () => focus.removeListener(changed);
    }, [focus]);
    useEffect(() {
      if (!focus.hasFocus && !dirty.value && controller.text != value) {
        controller.text = value;
      }
      return null;
    }, [value]);

    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return SizedBox(
      height: RevericSizes.directorRowHeight,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            controller.text = value;
            dirty.value = false;
            error.value = false;
            setPending(false);
            focus.unfocus();
          },
        },
        child: TextField(
          key: fieldKey,
          controller: controller,
          focusNode: focus,
          enabled: canEdit,
          keyboardType: numeric
              ? const TextInputType.numberWithOptions(
                  signed: true,
                  decimal: true,
                )
              : TextInputType.text,
          textInputAction: TextInputAction.done,
          style: typo.uiSmall.copyWith(
            color: canEdit ? colors.textPrimary : colors.textMuted,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          onChanged: (_) {
            if (!canEdit || controller.value.composing.isValid) {
              return;
            }
            dirty.value = true;
            setPending(true);
          },
          onSubmitted: (_) => submit(),
          // 三轴小格需要轴名前缀与单位后缀，RevericTextField 没有前缀槽，
          // 这里直接用设计系统的输入装饰。
          decoration: revericInputDecoration(
            context,
            radius: RevericRadius.medium,
            // 非法输入用错误底色提示，不额外占一行错误文案。
            fillColor: error.value
                ? colors.deletionBg
                : colors.surfaceContainerHigh,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.xs,
            ),
            prefixIcon: prefix == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(
                      left: RevericSpacing.xs,
                      right: RevericSpacing.xxs,
                    ),
                    child: Text(
                      prefix!,
                      style: typo.uiTiny.copyWith(color: colors.textMuted),
                    ),
                  ),
            prefixIconConstraints: const BoxConstraints(),
            suffixText: suffix,
            suffixStyle: typo.uiTiny.copyWith(color: colors.textMuted),
          ),
        ),
      ),
    );
  }
}

/// 逐项关键帧按钮：on = 当前帧有关键帧；anim = 有动画但当前不在关键帧；off = 无动画。
class KeyButton extends StatelessWidget {
  const KeyButton({
    super.key,
    required this.state,
    required this.onPressed,
    required this.tooltip,
  });
  final String state, tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final color = onPressed == null
        ? colors.textSubtle
        : state == 'off'
        ? colors.textMuted
        : colors.accent;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(RevericRadius.small),
        child: SizedBox.square(
          dimension: RevericSizes.directorKeyButton,
          child: Center(
            child: Transform.rotate(
              angle: 0.785398,
              child: Container(
                width: RevericSpacing.sm,
                height: RevericSpacing.sm,
                decoration: BoxDecoration(
                  color: state == 'on' ? color : Colors.transparent,
                  border: Border.all(color: color, width: 1.5),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String keyState(DirectorSession session, String id, String property) {
  final track = session.history.document.tracks
      .where((t) => t['target_id'] == id && t['property'] == property)
      .firstOrNull;
  if (track == null) {
    return 'off';
  }
  return (track['keys'] as List).any((k) => k['frame'] == session.frame.value)
      ? 'on'
      : 'anim';
}

/// 「标签 + 内容 + 关键帧按钮」一行，对齐 mockup 的 30px / 1fr / 22px 栅格。
class KeyRow extends StatelessWidget {
  const KeyRow({
    super.key,
    required this.label,
    required this.child,
    this.keyButton,
  });
  final String label;
  final Widget child;
  final Widget? keyButton;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: RevericSpacing.xs),
      child: Row(
        children: [
          SizedBox(
            width: RevericSpacing.x5l + RevericSpacing.xxs,
            child: Text(
              label,
              style: typo.uiTiny.copyWith(color: colors.textMuted),
            ),
          ),
          Expanded(child: child),
          const SizedBox(width: RevericSpacing.xs),
          SizedBox(width: RevericSizes.directorKeyButton, child: keyButton),
        ],
      ),
    );
  }
}

/// 三格数值输入；[enabled] 逐格控制可编辑状态。
class XyzInput extends StatelessWidget {
  const XyzInput({
    super.key,
    required this.session,
    required this.values,
    required this.onCommit,
    required this.fieldKey,
    this.enabled = const [true, true, true],
    this.unit,
  });
  final DirectorSession session;
  final List<double> values;
  final void Function(int axis, double value) onCommit;
  final List<bool> enabled;
  final String? unit, fieldKey;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (var i = 0; i < 3; i++) ...[
        if (i > 0) const SizedBox(width: RevericSpacing.xxs),
        Expanded(
          child: CommitField(
            fieldKey: ValueKey('director-field:$fieldKey:$i'),
            session: session,
            prefix: 'XYZ'[i],
            suffix: unit,
            value: values[i].toStringAsFixed(unit == null ? 2 : 0),
            enabled: enabled[i] && !session.playing,
            onCommit: (text) {
              final v = double.tryParse(text);
              if (v == null || !v.isFinite) {
                return false;
              }
              return commitEdit(session, () => onCommit(i, v));
            },
          ),
        ),
      ],
    ],
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.only(
        top: RevericSpacing.lg,
        bottom: RevericSpacing.sm,
      ),
      child: Text(
        text,
        style: typo.uiTiny.copyWith(
          color: colors.textMuted,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 字段标签 + 控件的竖排块。
class LabeledField extends StatelessWidget {
  const LabeledField({super.key, required this.label, required this.child});
  final String label;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: RevericSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: typo.uiTiny.copyWith(color: colors.textMuted)),
          const SizedBox(height: RevericSpacing.xxs),
          child,
        ],
      ),
    );
  }
}

/// 提交属性修改；失败时 session.error 由 attempt 写入，返回 false 让字段保持错误态。
/// 字段自身的提交要绕过「有待提交输入时拒绝编辑」的保护，所以走 submitForm。
bool commitEdit(DirectorSession session, void Function() edit) {
  session.attempt(() => session.submitForm(edit));
  return session.error == null;
}

String fmt(num v, [int digits = 1]) => v.toStringAsFixed(digits);

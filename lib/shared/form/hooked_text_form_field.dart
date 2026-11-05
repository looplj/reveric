// 职责: 基于 RevericTextField 的 flutter_hook_form 文本输入集成组件
// 关联文件:
//   lib/shared/components/reveric_text_field.dart
//   lib/shared/utils/text_input_composing.dart
//   lib/third/form/flutter_hook_form.dart
// 遵循的 Rules:
//   .agents/rules/form.md
//   .agents/rules/text-input-ime.md
//   .agents/rules/design-system.md

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../third/form/flutter_hook_form.dart';
import '../components/reveric_text_field.dart';
import '../theme/theme.dart';
import '../utils/text_input_composing.dart';

/// 基于 [RevericTextField] 的 [flutter_hook_form] 文本输入组件。
///
/// 结合了 [RevericTextField] 的视觉样式与稳定树结构（IME 友好），
/// 并与 [FormFieldsController] 的校验、初始值和错误展示机制完全打通。
class HookedTextFormField<F extends FieldSchema> extends HookWidget {
  /// 创建从当前 [HookedForm] 上下文中获取表单控制器的 [HookedTextFormField]。
  const HookedTextFormField({
    super.key,
    required this.fieldHook,
    this.controller,
    this.fieldKey,
    this.label,
    this.hintText,
    this.helperText,
    this.errorMaxLines = 2,
    this.enabled = true,
    this.readOnly = false,
    this.obscureText = false,
    this.multiline = false,
    this.minLines = 4,
    this.maxLines = 8,
    this.height = RevericSizes.fieldHeight,
    this.fillColor,
    this.suffixIcon,
    this.suffixIconConstraints,
    this.autofocus = false,
    this.focusNode,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.onChanged,
    this.onFieldSubmitted,
    this.style,
    this.textAlign = TextAlign.start,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.autofillHints,
    this.initialValue,
    this.validator,
    this.forceErrorText,
    this.autovalidateMode,
    this.onSaved,
    this.restorationId,
    this.notifyOnChange = false,
  }) : _form = null;

  /// 显式传入 [FormFieldsController] 的构造函数。
  const HookedTextFormField.explicit({
    super.key,
    required this.fieldHook,
    required this._form,
    this.controller,
    this.fieldKey,
    this.label,
    this.hintText,
    this.helperText,
    this.errorMaxLines = 2,
    this.enabled = true,
    this.readOnly = false,
    this.obscureText = false,
    this.multiline = false,
    this.minLines = 4,
    this.maxLines = 8,
    this.height = RevericSizes.fieldHeight,
    this.fillColor,
    this.suffixIcon,
    this.suffixIconConstraints,
    this.autofocus = false,
    this.focusNode,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.onChanged,
    this.onFieldSubmitted,
    this.style,
    this.textAlign = TextAlign.start,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.autofillHints,
    this.initialValue,
    this.validator,
    this.forceErrorText,
    this.autovalidateMode,
    this.onSaved,
    this.restorationId,
    this.notifyOnChange = false,
  });

  final FormFieldsController<F>? _form;

  /// 表单 Schema 中声明的字段枚举。
  final F fieldHook;

  /// 外部传入的文本控制器（可选）。
  /// 未提供时由组件内部自动管理控制器与初始值同步。
  final TextEditingController? controller;

  /// 透传给内部 [RevericTextField] / [TextField] 的 Key，便于测试定位输入框本体。
  final Key? fieldKey;

  /// 字段上方的标签文案。
  final String? label;

  /// 占位提示文案。
  final String? hintText;

  /// 字段下方的辅助说明文案。
  final String? helperText;

  /// 错误文案最大行数。
  final int errorMaxLines;

  final bool enabled;
  final bool readOnly;
  final bool obscureText;
  final bool multiline;
  final int minLines;
  final int? maxLines;
  final double height;
  final Color? fillColor;
  final Widget? suffixIcon;
  final BoxConstraints? suffixIconConstraints;
  final bool autofocus;
  final FocusNode? focusNode;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final List<TextInputFormatter>? inputFormatters;

  /// 文本变动回调；在 form 值写入之后触发，回调内可直接读 `form.getValue`。
  final ValueChanged<String>? onChanged;

  /// 提交完成回调。
  final ValueChanged<String>? onFieldSubmitted;

  final TextStyle? style;
  final TextAlign textAlign;
  final bool autocorrect;
  final bool enableSuggestions;
  final Iterable<String>? autofillHints;

  /// 显式覆盖的初始值（优先使用 form.getInitialValue）。
  final String? initialValue;

  /// 显式覆盖的校验器（默认使用 FieldSchema 中声明的 validators）。
  final String? Function(String?)? validator;

  /// 强制错误文案。
  final String? forceErrorText;

  final AutovalidateMode? autovalidateMode;
  final void Function(String?)? onSaved;
  final String? restorationId;

  /// 文本变动时是否通知表单监听器触发 rebuild，默认为 false。
  final bool notifyOnChange;

  @override
  Widget build(BuildContext context) {
    final form = _form ?? useFormContext<FieldSchema>(context);

    // 外部 controller 自带文本、而 form 没有给这个字段初始值时，把 controller 首帧的
    // 文本当作基线——否则 form 的 value 一直是 null，界面上明明显示着内容，
    // getValue / hasChanged / validate 却全都读不到（Flutter 的 TextFormField 同理，
    // 它用 `controller != null ? controller.text : initialValue` 兜这一层）。
    //
    // 只 memo 这份 fallback，不能把 form 的初始值一起冻住：常驻编辑面板会用
    // `useForm(keys: [id, updatedAt])` 在保存后重建控制器，baseline 必须跟着更新
    // （form.md「常驻编辑面板的 keys」）。controller 实例换了才重新取一次。
    //
    // 首次挂载时优先沿用 form 已登记的基线：字段离屏回收后重新挂载，controller
    // 里已是编辑后的文本，不能当成新基线。同一次挂载内换了 controller 才用新文本。
    final seeded = useRef(false);
    final controllerSeed = useMemoized(() {
      final registered = seeded.value
          ? null
          : form.getRegisteredInitialValue<String>(fieldHook);
      seeded.value = true;
      return registered ?? controller?.text;
    }, [controller]);
    final effectiveInitialValue =
        form.getInitialValue<String>(fieldHook) ??
        initialValue ??
        controllerSeed;

    return _RevericFormField(
      key: form.fieldKey(fieldHook),
      controller: controller,
      initialValue: effectiveInitialValue,
      editingValue: form.registerField<String>(
        fieldHook,
        initialValue: effectiveInitialValue,
      ),
      validator:
          validator ??
          form.validators(fieldHook)?.resolveMessage<String>(context),
      forceErrorText:
          forceErrorText ??
          form
              .getFieldForcedError(fieldHook)
              .localize(context, form.getValue(fieldHook)),
      autovalidateMode: autovalidateMode,
      enabled: enabled,
      onSaved: onSaved,
      restorationId: restorationId,
      builder: (state) {
        // 与 Flutter 的 TextFormField 一致：restorationId 同时给 FormField 和内部
        // TextField，靠 UnmanagedRestorationScope 把两者挂到同一个 bucket，否则
        // 两处用同一个 id 会在恢复时撞车。
        return UnmanagedRestorationScope(
          bucket: state.bucket,
          child: RevericTextField(
            controller: state.effectiveController,
            fieldKey: fieldKey,
            label: label,
            hintText: hintText,
            helperText: helperText,
            errorText: state.errorText,
            errorMaxLines: errorMaxLines,
            enabled: enabled,
            readOnly: readOnly,
            obscureText: obscureText,
            multiline: multiline,
            minLines: minLines,
            maxLines: maxLines,
            height: height,
            fillColor: fillColor,
            suffixIcon: suffixIcon,
            suffixIconConstraints: suffixIconConstraints,
            autofocus: autofocus,
            focusNode: focusNode,
            keyboardType: keyboardType,
            textInputAction: textInputAction,
            inputFormatters: inputFormatters,
            style: style,
            textAlign: textAlign,
            autocorrect: autocorrect,
            enableSuggestions: enableSuggestions,
            autofillHints: autofillHints,
            restorationId: restorationId,
            onChanged: (value) {
              // updateValue 内部就会通过 form.fieldKey 拿到这个 FormFieldState 并
              // 调用 didChange，不需要再额外调一次；先写 form 再回调，调用方在
              // onChanged 里读 form.getValue 才拿得到新值。
              form.updateValue(fieldHook, value, notify: notifyOnChange);
              onChanged?.call(value);
            },
            onSubmitted: onFieldSubmitted,
          ),
        );
      },
    );
  }
}

typedef _RevericFormFieldBuilder =
    Widget Function(_RevericFormFieldState state);

class _RevericFormField extends FormField<String> {
  _RevericFormField({
    super.key,
    this.controller,
    required this.editingValue,
    super.initialValue,
    super.validator,
    super.autovalidateMode,
    super.enabled = true,
    super.onSaved,
    super.restorationId,
    super.forceErrorText,
    required _RevericFormFieldBuilder builder,
  }) : super(builder: (state) => builder(state as _RevericFormFieldState));

  final TextEditingController? controller;
  final String? editingValue;

  @override
  FormFieldState<String> createState() => _RevericFormFieldState();
}

class _RevericFormFieldState extends FormFieldState<String> {
  TextEditingController? _localController;
  TextEditingController get effectiveController =>
      (_textFormField.controller ?? _localController)!;

  _RevericFormField get _textFormField => widget as _RevericFormField;

  @override
  void initState() {
    super.initState();
    // Keep widget.initialValue as the reset baseline; only a fresh state
    // restores the current edit after leaving a lazy list's cache.
    setValue(_textFormField.controller?.text ?? _textFormField.editingValue);
    if (_textFormField.controller == null) {
      _localController = TextEditingController(text: value ?? '');
    } else {
      _textFormField.controller!.addListener(_handleControllerChanged);
    }
  }

  @override
  void didUpdateWidget(_RevericFormField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_textFormField.controller != oldWidget.controller) {
      oldWidget.controller?.removeListener(_handleControllerChanged);
      if (_textFormField.controller != null) {
        _localController?.dispose();
        _localController = null;
        _textFormField.controller!.addListener(_handleControllerChanged);
        setValue(_textFormField.controller!.text);
      } else {
        _localController = TextEditingController(text: value ?? '');
      }
    }
  }

  @override
  void didChange(String? value) {
    super.didChange(value);
    _writeController(value ?? '');
  }

  @override
  void reset() {
    // 与 Flutter 的 TextFormField 保持一致：先把文本写回 controller，再走
    // super.reset()。super.reset() 会触发 Form._fieldDidChange，那时 controller
    // 必须已经是复位后的内容。
    _writeController(widget.initialValue ?? '');
    super.reset();
  }

  /// 把 [text] 写回 controller。
  ///
  /// 走 [writeControllerTextAfterComposing] 而不是裸赋值：裸赋值会把 composing 清成
  /// [TextRange.empty]，等于通知平台「组词结束」，macOS embedder 随即
  /// discardMarkedText，用户正在打的拼音被丢掉（text-input-ime.md）。
  /// 外部通过 `form.updateValue` / `form.reset()` 写入时就可能撞上组词中。
  void _writeController(String text) {
    if (effectiveController.text == text) {
      return;
    }
    writeControllerTextAfterComposing(effectiveController, (_) => text);
  }

  void _handleControllerChanged() {
    if (effectiveController.text != value) {
      didChange(effectiveController.text);
    }
  }

  @override
  void dispose() {
    _textFormField.controller?.removeListener(_handleControllerChanged);
    _localController?.dispose();
    super.dispose();
  }
}

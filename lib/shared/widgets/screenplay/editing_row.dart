// 职责: 将标题和正文的本地选区映射到文档选区，并绘制跨元素选择的高亮。
// 关联文件:
//   lib/shared/widgets/screenplay/editing_scope.dart
//   lib/shared/widgets/screenplay/editing_controller.dart
//   lib/shared/models/screenplay_element.dart
//   lib/shared/theme/theme.dart
// 遵循的 Rules:
//   .agents/rules/text-input-ime.md
//   .agents/rules/design-system.md

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../../models/screenplay_element.dart';
import '../../theme/theme.dart';
import 'editing_scope.dart';

class ScreenplayEditingRow extends StatefulWidget {
  const ScreenplayEditingRow({
    super.key,
    required this.index,
    required this.child,
  });
  final int index;
  final Widget child;
  @override
  State<ScreenplayEditingRow> createState() => ScreenplayEditingRowState();
}

// 元素类型变化会替换输入框，State 在布局后重新绑定真实节点并在卸载时解除监听。
class ScreenplayEditingRowState extends State<ScreenplayEditingRow> {
  late ScreenplayEditingScopeState _scope;
  EditableTextState? _editable;
  EditableTextState? get editable =>
      _editable?.mounted == true ? _editable : null;
  RenderParagraph? _characterText;
  FocusNode? _focus;
  TextEditingController? _controller;
  TextEditingValue _previous = TextEditingValue.empty;
  bool _syncing = false;
  bool _scheduled = false;
  int? _pendingRevealOffset;
  bool _pendingFocus = false;
  TextSelection? _paintSelection;
  ScreenplayElement? _paintElement;
  int get index => widget.index;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scope = ScreenplayEditingScope.of(context);
    _bindAfterFrame();
  }

  @override
  void didUpdateWidget(ScreenplayEditingRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _bindAfterFrame();
  }

  void _bindAfterFrame() {
    if (_scheduled) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) {
        return;
      }
      if (index >= _scope.controller.value.length) {
        _unbindInput();
        _scope.unregister(this);
        _pendingRevealOffset = null;
        _pendingFocus = false;
        return;
      }
      EditableTextState? found;
      RenderParagraph? characterText;
      FocusNode? roleFocus;
      void visit(Element element) {
        if (element is StatefulElement && element.state is EditableTextState) {
          found = element.state as EditableTextState;
          return;
        }
        if (element.widget case Focus(focusNode: final FocusNode node)) {
          roleFocus ??= node;
        }
        if (element is RenderObjectElement &&
            element.renderObject is RenderParagraph) {
          characterText ??= element.renderObject as RenderParagraph;
        }
        element.visitChildren(visit);
      }

      if (!_scope.controller.value[index].isHeading) {
        context.visitChildElements(visit);
      }
      _characterText = characterText;
      final nextFocus = found?.widget.focusNode ?? roleFocus;
      final nextController = found?.widget.controller;
      if (nextFocus != _focus || nextController != _controller) {
        _focus?.removeListener(_focusChanged);
        _controller?.removeListener(_inputChanged);
        _focus = nextFocus;
        _controller = nextController;
        _previous = nextController?.value ?? TextEditingValue.empty;
        _focus?.addListener(_focusChanged);
        _controller?.addListener(_inputChanged);
      }
      // 同一个 controller/focus 也可能被新的 EditableTextState 复用。
      _editable = found;
      _scope.register(this);
      if (_pendingFocus) {
        _pendingFocus = false;
        _syncing = true;
        _focus?.requestFocus();
        scheduleMicrotask(() {
          if (mounted) {
            _syncing = false;
          }
        });
      }
      final offset = _pendingRevealOffset;
      _pendingRevealOffset = null;
      if (offset != null) {
        _revealAfterLayout(offset);
      }
    });
  }

  void _inputChanged() {
    final input = _controller;
    if (input == null || index >= _scope.controller.value.length) {
      return;
    }
    final next = input.value;
    if (!_syncing && _scope.selectingWithMouse && next.text == _previous.text) {
      // 鼠标还在同一字符内移动时整场选区不会通知，仍须恢复原生输入框的局部高亮。
      synchronize();
      return;
    }
    if (!_syncing && (_focus?.hasFocus ?? false)) {
      _scope.resetHorizontalAnchor();
      _scope.controller.observeInput(index, next, _previous);
    }
    _previous = next;
  }

  void _focusChanged() {
    if (!(_focus?.hasFocus ?? false) ||
        _syncing ||
        index >= _scope.controller.value.length) {
      return;
    }
    if (_controller != null) {
      _inputChanged();
    } else {
      final start = _scope.controller.startOf(index);
      _scope.controller.select(
        TextSelection.collapsed(offset: start + 1),
        requestFocus: false,
      );
    }
  }

  void synchronize() {
    if (!mounted || index >= _scope.controller.value.length) {
      return;
    }
    final editor = _scope.controller;
    final input = _controller;
    final node = editor.value[index];
    final rowStart = editor.startOf(index);
    final length = editor.textOf(node).length;
    final localSelection = TextSelection(
      baseOffset: (editor.selection.baseOffset - rowStart).clamp(0, length),
      extentOffset: (editor.selection.extentOffset - rowStart).clamp(0, length),
    );
    final paintChanged =
        !identical(_paintElement, node) || _paintSelection != localSelection;
    if (!paintChanged &&
        (input == null ||
            (input.text == node.text && input.selection == localSelection))) {
      return;
    }
    _paintElement = node;
    _paintSelection = localSelection;
    if (input != null && !input.value.isComposingRangeValid) {
      final element = editor.value[index];
      final start = editor.startOf(index);
      final selected = editor.selection;
      final local = TextSelection(
        baseOffset: (selected.baseOffset - start).clamp(0, element.text.length),
        extentOffset: (selected.extentOffset - start).clamp(
          0,
          element.text.length,
        ),
        affinity: selected.affinity,
      );
      _syncing = true;
      input.value = TextEditingValue(text: element.text, selection: local);
      _previous = input.value;
      _syncing = false;
    }
    if (paintChanged) {
      setState(() {});
    }
  }

  void focusAt(int offset) {
    _pendingFocus = true;
    reveal(offset);
  }

  void reveal(int offset) {
    if (!mounted) {
      return;
    }
    _pendingRevealOffset = offset;
    // 先等待本帧替换/卸载完成并重新绑定，不能使用上一帧缓存的输入框。
    _bindAfterFrame();
    WidgetsBinding.instance.scheduleFrame();
  }

  void _revealAfterLayout(int offset) {
    final field = editable;
    if (field != null) {
      final render = field.renderEditable;
      if (!render.attached || !render.hasSize) {
        return;
      }
      field.bringIntoView(
        TextPosition(
          offset: offset.clamp(0, field.widget.controller.text.length),
        ),
      );
    } else {
      final render = context.findRenderObject();
      if (render is RenderBox && render.attached && render.hasSize) {
        render.showOnScreen();
      }
    }
  }

  void _unbindInput() {
    _focus?.removeListener(_focusChanged);
    _controller?.removeListener(_inputChanged);
    _focus = null;
    _controller = null;
    _editable = null;
    _characterText = null;
  }

  @override
  Widget build(BuildContext context) {
    final editor = _scope.controller;
    final color = RevericTheme.colorsOf(context).accent.withValues(alpha: 0.22);
    final valid = index < editor.value.length;
    final start = valid ? editor.startOf(index) : 0;
    final selected = editor.selection;
    final hasSelection =
        valid &&
        !selected.isCollapsed &&
        selected.end > start &&
        selected.start <= start + editor.textOf(editor.value[index]).length;
    return CustomPaint(
      foregroundPainter: hasSelection
          ? _SelectionPainter(this, color, editor.value[index].isObject)
          : null,
      child: widget.child,
    );
  }

  @override
  void dispose() {
    _scope.unregister(this);
    _unbindInput();
    super.dispose();
  }
}

class _SelectionPainter extends CustomPainter {
  const _SelectionPainter(this.row, this.color, this.character);
  final ScreenplayEditingRowState row;
  final Color color;
  final bool character;
  @override
  void paint(Canvas canvas, Size size) {
    final root = row.context.findRenderObject();
    if (root is! RenderBox) {
      return;
    }
    if (character && row._scope.controller.value[row.index].isHeading) {
      canvas.drawRect(Offset.zero & size, Paint()..color = color);
      return;
    }
    if (character) {
      final text = row._characterText;
      if (text == null || !text.attached) {
        return;
      }
      final origin = text.localToGlobal(Offset.zero, ancestor: root);
      for (final box in text.getBoxesForSelection(
        TextSelection(
          baseOffset: 0,
          extentOffset: text.text.toPlainText().length,
        ),
      )) {
        canvas.drawRect(box.toRect().shift(origin), Paint()..color = color);
      }
      return;
    }
    final editable = row.editable;
    if (editable == null || editable.widget.focusNode.hasFocus) {
      return;
    }
    final render = editable.renderEditable;
    final origin = render.localToGlobal(Offset.zero, ancestor: root);
    final editor = row._scope.controller;
    final start = editor.startOf(row.index);
    final length = editable.widget.controller.text.length;
    final selection = TextSelection(
      baseOffset: (editor.selection.baseOffset - start).clamp(0, length),
      extentOffset: (editor.selection.extentOffset - start).clamp(0, length),
    );
    for (final box in render.getBoxesForSelection(selection)) {
      canvas.drawRect(box.toRect().shift(origin), Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_SelectionPainter oldDelegate) => true;
}

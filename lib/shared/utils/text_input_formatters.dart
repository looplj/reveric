// 职责: 通用正文输入工具 — 段首缩进、Tab 键写入与粘贴大小限制
// 关联文件:
//   lib/shared/widgets/md/reveric_markdown_editor.dart
//   lib/desktop/widgets/workspace/chapter_editor.dart
//   lib/mobile/pages/chapter_editor_page.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 正文回车缩进 formatter — 首字符补齐默认段首缩进，新行继承上一行行首空白。
class ChapterParagraphIndentFormatter extends TextInputFormatter {
  static const String _defaultIndent = '\u3000\u3000';

  String? _firstCompositionText;

  static bool _isIndentCharacter(String character) {
    return character == ' ' || character == '\t' || character == '\u3000';
  }

  static String _leadingIndent(String text, int lineEnd) {
    // lineEnd 为 0（如空文本按 Enter、或行首插入换行）时，
    // lastIndexOf('\n', -1) 会抛 RangeError；行首本身无缩进可继承。
    if (lineEnd <= 0) {
      return '';
    }
    final lineStart = text.lastIndexOf('\n', lineEnd - 1) + 1;
    var indentEnd = lineStart;
    while (indentEnd < lineEnd &&
        _isIndentCharacter(text.substring(indentEnd, indentEnd + 1))) {
      indentEnd++;
    }
    return text.substring(lineStart, indentEnd);
  }

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final continuesFirstComposition =
        !oldValue.composing.isCollapsed &&
        oldValue.text == _firstCompositionText;
    if (!newValue.composing.isCollapsed) {
      // 分段上屏后，组词范围会移到剩余拼音，正文已不再为空。
      _firstCompositionText = oldValue.text.isEmpty || continuesFirstComposition
          ? newValue.text
          : null;
      return newValue;
    }
    _firstCompositionText = null;

    // 首段组词上屏可能只清除组词范围，或用更短的词替换拼音。
    if ((!continuesFirstComposition &&
            newValue.text.length != oldValue.text.length + 1) ||
        !newValue.selection.isCollapsed) {
      return newValue;
    }

    final cursor = newValue.selection.baseOffset;
    if (cursor <= 0 || cursor > newValue.text.length) {
      return newValue;
    }

    if (oldValue.text.isEmpty || continuesFirstComposition) {
      if (newValue.text.startsWith('\n') ||
          newValue.text.startsWith(_defaultIndent)) {
        return newValue;
      }
      return TextEditingValue(
        text: _defaultIndent + newValue.text,
        selection: TextSelection.collapsed(
          offset: cursor + _defaultIndent.length,
        ),
      );
    }

    final inserted = newValue.text.substring(cursor - 1, cursor);
    if (inserted != '\n') {
      return newValue;
    }

    // 继承插入点所在行的行首缩进，让新段首与上一行对齐。
    final indent = _leadingIndent(newValue.text, cursor - 1);
    if (indent.isEmpty) {
      return newValue;
    }

    // 紧跟新段首已经是同样的缩进，不重复添加。
    final after = newValue.text.substring(cursor);
    if (after.startsWith(indent)) {
      return newValue;
    }

    final patched = newValue.text.substring(0, cursor) + indent + after;
    return TextEditingValue(
      text: patched,
      selection: TextSelection.collapsed(offset: cursor + indent.length),
    );
  }
}

/// 在正文编辑器中把未被修饰的 Tab 键写入当前选区，而不是触发焦点遍历。
KeyEventResult handleChapterTabKeyEvent({
  required TextEditingController controller,
  required KeyEvent event,
  VoidCallback? onChanged,
}) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }
  if (event.logicalKey != LogicalKeyboardKey.tab) {
    return KeyEventResult.ignored;
  }

  final keyboard = HardwareKeyboard.instance;
  if (keyboard.isShiftPressed ||
      keyboard.isControlPressed ||
      keyboard.isAltPressed ||
      keyboard.isMetaPressed) {
    return KeyEventResult.ignored;
  }

  final selection = controller.selection;
  if (!selection.isValid) {
    return KeyEventResult.ignored;
  }
  final start = selection.start.clamp(0, controller.text.length);
  final end = selection.end.clamp(start, controller.text.length);
  controller.value = TextEditingValue(
    text: controller.text.replaceRange(start, end, '\t'),
    selection: TextSelection.collapsed(offset: start + 1),
  );
  onChanged?.call();
  return KeyEventResult.handled;
}

/// Rejects edits that add more than [maxLength] characters in a single
/// operation (paste, bulk insert). Allows normal typing through unchanged.
/// Calls [onRejected] with the actual character count when a paste is rejected.
class PasteSizeLimitTextInputFormatter extends TextInputFormatter {
  const PasteSizeLimitTextInputFormatter({
    this.maxLength = 10000,
    this.onRejected,
  });

  final int maxLength;
  final void Function(int actualLength)? onRejected;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.length > oldValue.text.length) {
      final added = newValue.text.length - oldValue.text.length;
      if (added > maxLength) {
        onRejected?.call(added);
        return oldValue;
      }
    }
    return newValue;
  }
}

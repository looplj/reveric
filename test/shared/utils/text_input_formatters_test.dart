// 职责: 验证正文缩进 formatter 的边界输入不再抛 RangeError，且缩进继承语义不变
// 关联文件:
//   lib/shared/utils/text_input_formatters.dart
//   lib/desktop/widgets/workspace/chapter_editor.dart
//   lib/mobile/pages/chapter_editor_page.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/utils/text_input_formatters.dart';

void main() {
  late ChapterParagraphIndentFormatter formatter;

  setUp(() {
    formatter = ChapterParagraphIndentFormatter();
  });

  TextEditingValue apply(TextEditingValue old, TextEditingValue next) {
    return formatter.formatEditUpdate(old, next);
  }

  group('ChapterParagraphIndentFormatter 首段缩进', () {
    test('单字符直接上屏时补齐缩进', () {
      final result = apply(
        TextEditingValue.empty,
        const TextEditingValue(
          text: 'A',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );

      expect(result.text, '\u3000\u3000A');
      expect(result.selection.baseOffset, 3);
    });

    test('组词更新保持原样，上屏后补一次缩进', () {
      const firstUpdate = TextEditingValue(
        text: 'n',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      );
      const secondUpdate = TextEditingValue(
        text: 'ni',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      );
      const committed = TextEditingValue(
        text: '你',
        selection: TextSelection.collapsed(offset: 1),
      );

      expect(apply(TextEditingValue.empty, firstUpdate), firstUpdate);
      expect(apply(firstUpdate, secondUpdate), secondUpdate);
      final result = apply(secondUpdate, committed);
      expect(
        result,
        const TextEditingValue(
          text: '\u3000\u3000你',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );

      final next = result.copyWith(
        text: '\u3000\u3000你好',
        selection: const TextSelection.collapsed(offset: 4),
      );
      expect(apply(result, next), next);
    });

    test('组成词和上屏词相同时仍然补齐缩进', () {
      const committed = TextEditingValue(
        text: '你好',
        selection: TextSelection.collapsed(offset: 2),
      );
      final composing = committed.copyWith(
        composing: const TextRange(start: 0, end: 2),
      );

      expect(apply(TextEditingValue.empty, composing), composing);
      final result = apply(composing, committed);

      expect(result.text, '\u3000\u3000你好');
      expect(result.selection.baseOffset, 4);
    });

    for (final prefix in ['', '已有正文']) {
      test('分段上屏后只缩进从空正文开始的组词（前缀为「$prefix」）', () {
        var value = TextEditingValue(
          text: prefix,
          selection: TextSelection.collapsed(offset: prefix.length),
        );

        void updateComposition(String text, int composingStart) {
          final next = TextEditingValue(
            text: prefix + text,
            selection: TextSelection.collapsed(
              offset: prefix.length + text.length,
            ),
            composing: TextRange(
              start: prefix.length + composingStart,
              end: prefix.length + text.length,
            ),
          );
          value = apply(value, next);
          expect(value, next);
        }

        updateComposition('nihao', 0);
        updateComposition('你hao', 1);
        const committedText = '你好';
        final committed = TextEditingValue(
          text: '$prefix$committedText',
          selection: TextSelection.collapsed(
            offset: prefix.length + committedText.length,
          ),
        );
        final expected = prefix.isEmpty
            ? const TextEditingValue(
                text: '\u3000\u3000你好',
                selection: TextSelection.collapsed(offset: 4),
              )
            : committed;

        expect(apply(value, committed), expected);
      });
    }

    test('取消空正文的组词时保留空正文', () {
      const composing = TextEditingValue(
        text: 'n',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      );
      const cleared = TextEditingValue(
        selection: TextSelection.collapsed(offset: 0),
      );

      expect(apply(TextEditingValue.empty, composing), composing);
      expect(apply(composing, cleared), cleared);
    });

    test('输入法重新标记整段已有正文时保留当前段首', () {
      const committed = TextEditingValue(
        text: '已有正文',
        selection: TextSelection.collapsed(offset: 4),
      );
      final composing = committed.copyWith(
        composing: const TextRange(start: 0, end: 4),
      );

      expect(apply(committed, composing), composing);
      expect(apply(composing, committed), committed);
    });
  });

  group('ChapterParagraphIndentFormatter 换行插入点在行首', () {
    // 线上 1.2.1/1.2.2 崩溃：
    // RangeError: Invalid value: Not in inclusive range 0..N: -1
    //（空文本按 Enter → _leadingIndent lineEnd=0 → lastIndexOf('\n', -1)）
    test('空文本按 Enter 不抛 RangeError', () {
      final result = apply(
        const TextEditingValue(text: ''),
        const TextEditingValue(
          text: '\n',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      expect(result.text, '\n');
    });

    test('行首按 Enter 不抛 RangeError', () {
      final result = apply(
        const TextEditingValue(text: '第一段'),
        const TextEditingValue(
          text: '\n第一段',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      expect(result.text, '\n第一段');
    });
  });

  test('段尾按 Enter 继承上一行行首缩进', () {
    final result = apply(
      const TextEditingValue(text: '\u3000\u3000第一段'),
      const TextEditingValue(
        text: '\u3000\u3000第一段\n',
        selection: TextSelection.collapsed(offset: 6),
      ),
    );
    expect(result.text, '\u3000\u3000第一段\n\u3000\u3000');
    expect(result.selection.baseOffset, 8);
  });
}

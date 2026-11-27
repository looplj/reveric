// 职责: 在章节正文的 TextSpan 中绘制对白高亮与选区标记。
// 关联文件:
//   lib/desktop/widgets/workspace/chapter_editor.dart
//   lib/mobile/pages/chapter_editor_page.dart

import 'dart:collection';

import 'package:flutter/widgets.dart';

import '../../database/novel_content_database.dart';
import '../../utils/chapter_highlight_anchor.dart';

typedef _LocatedHighlight = ({
  ChapterHighlight mark,
  ChapterHighlightRange range,
});
typedef _PaintRange = ({int start, int end, int? colorArgb});

class ChapterDialogueHighlightController extends TextEditingController {
  ChapterDialogueHighlightController({super.text});

  static final _pairedQuotes = RegExp(r'“[^“”]*”');

  bool dialogueHighlightEnabled = false;
  late Color highlightBackground;
  String? _matchedText;
  List<_PaintRange> _dialogueRanges = const [];
  List<ChapterHighlight> _marks = const [];
  ChapterHighlightText? _savedBody;
  String? _locatedFor;
  List<_LocatedHighlight> _locatedMarks = const [];
  List<_PaintRange> _manualRanges = const [];

  void configureManualHighlights({
    required List<ChapterHighlight> marks,
    required String savedBody,
  }) {
    if (!identical(marks, _marks) || _savedBody?.value != savedBody) {
      _marks = marks;
      _savedBody = ChapterHighlightText(savedBody);
      _locatedFor = null;
    }
  }

  /// 多条标记都覆盖选区时，操作当前绘制在最上层的那条。
  ChapterHighlight? highlightAt(TextSelection selection) {
    _locateManualHighlights();
    _LocatedHighlight? best;
    for (final mark in _locatedMarks) {
      final range = mark.range;
      if (range.start <= selection.start &&
          range.end >= selection.end &&
          (best == null || _compareHighlights(mark, best) < 0)) {
        best = mark;
      }
    }
    return best?.mark;
  }

  void _locateManualHighlights() {
    if (_marks.isEmpty) {
      _locatedMarks = const [];
      _manualRanges = const [];
      return;
    }
    final text = value.text;
    if (_locatedFor == text) {
      return;
    }
    final saved = _savedBody!;
    final current = text == saved.value ? saved : ChapterHighlightText(text);
    final edit = identical(saved, current)
        ? null
        : ChapterHighlightEdit(saved.value, text);
    final located = <_LocatedHighlight>[];
    for (final mark in _marks) {
      final oldRange = edit == null ? null : saved.resolve(mark);
      final range =
          (oldRange == null ? null : edit!.move(oldRange)) ??
          current.resolve(mark);
      if (range != null && current.isValidRange(range)) {
        located.add((mark: mark, range: range));
      }
    }
    _locatedFor = text;
    _locatedMarks = located;
    _manualRanges = _paintRangesFor(located);
  }

  static int _compareHighlights(_LocatedHighlight a, _LocatedHighlight b) {
    final newestFirst = b.mark.sortOrder.compareTo(a.mark.sortOrder);
    return newestFirst == 0 ? a.mark.id.compareTo(b.mark.id) : newestFirst;
  }

  List<_PaintRange> _paintRangesFor(List<_LocatedHighlight> marks) {
    if (marks.isEmpty) {
      return const [];
    }
    final boundaries = [
      for (final mark in marks) ...[
        (offset: mark.range.start, opens: true, mark: mark),
        (offset: mark.range.end, opens: false, mark: mark),
      ],
    ]..sort((a, b) => a.offset.compareTo(b.offset));
    // 后加的标记画在最上层，与选区菜单的优先顺序一致。
    final active = SplayTreeSet<_LocatedHighlight>(_compareHighlights);
    final ranges = <_PaintRange>[];
    var start = boundaries.first.offset;
    for (final boundary in boundaries) {
      final end = boundary.offset;
      if (start < end && active.isNotEmpty) {
        final colorArgb = active.first.mark.colorArgb;
        if (ranges.isNotEmpty &&
            ranges.last.end == start &&
            ranges.last.colorArgb == colorArgb) {
          ranges.last = (
            start: ranges.last.start,
            end: end,
            colorArgb: colorArgb,
          );
        } else {
          ranges.add((start: start, end: end, colorArgb: colorArgb));
        }
      }
      if (boundary.opens) {
        active.add(boundary.mark);
      } else {
        active.remove(boundary.mark);
      }
      start = end;
    }
    return ranges;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final span = super.buildTextSpan(
      context: context,
      style: style,
      withComposing: withComposing,
    );
    if (!dialogueHighlightEnabled && _marks.isEmpty) {
      return span;
    }
    // Flutter 返回纯文本或按 IME 组合区切分的 TextSpan，保留其下划线。
    final spans =
        span.children?.cast<TextSpan>() ?? [TextSpan(text: span.text)];
    final highlighted = applyChapterHighlights(spans);
    return identical(highlighted, spans)
        ? span
        : TextSpan(style: span.style, children: highlighted);
  }

  /// 在覆盖完整正文的文本片段上叠加底色，保留片段的其他样式。
  @protected
  List<TextSpan> applyChapterHighlights(List<TextSpan> spans) {
    final dialogueSpans = _applyDialogueHighlight(spans);
    _locateManualHighlights();
    return _applyBackground(dialogueSpans, _manualRanges);
  }

  List<TextSpan> _applyDialogueHighlight(List<TextSpan> spans) {
    if (!dialogueHighlightEnabled) {
      return spans;
    }
    final text = value.text;
    if (text != _matchedText) {
      _matchedText = text;
      _dialogueRanges = [
        for (final match in _pairedQuotes.allMatches(text))
          (start: match.start, end: match.end, colorArgb: null),
      ];
    }
    return _applyBackground(spans, _dialogueRanges);
  }

  List<TextSpan> _applyBackground(
    List<TextSpan> spans,
    List<_PaintRange> ranges,
  ) {
    if (ranges.isEmpty) {
      return spans;
    }
    final highlighted = <TextSpan>[];
    var spanStart = 0;
    var rangeIndex = 0;
    for (final span in spans) {
      final segment = span.text ?? '';
      final spanEnd = spanStart + segment.length;
      if (segment.isEmpty ||
          rangeIndex == ranges.length ||
          ranges[rangeIndex].start >= spanEnd) {
        highlighted.add(span);
        spanStart = spanEnd;
        continue;
      }

      var cursor = 0;
      while (rangeIndex < ranges.length && ranges[rangeIndex].start < spanEnd) {
        final range = ranges[rangeIndex];
        final start = range.start.clamp(spanStart, spanEnd) - spanStart;
        final end = range.end.clamp(spanStart, spanEnd) - spanStart;
        if (cursor < start) {
          highlighted.add(
            TextSpan(text: segment.substring(cursor, start), style: span.style),
          );
        }
        cursor = end;
        final colorArgb = range.colorArgb;
        final highlightStyle = (span.style ?? const TextStyle()).copyWith(
          backgroundColor: colorArgb == null
              ? highlightBackground
              : Color(colorArgb),
        );
        highlighted.add(
          TextSpan(text: segment.substring(start, end), style: highlightStyle),
        );
        if (range.end > spanEnd) {
          break;
        }
        rangeIndex++;
      }
      if (cursor < segment.length) {
        highlighted.add(
          TextSpan(text: segment.substring(cursor), style: span.style),
        );
      }
      spanStart = spanEnd;
    }
    return highlighted;
  }
}

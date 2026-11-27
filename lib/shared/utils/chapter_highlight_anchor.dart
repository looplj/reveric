// 职责: 定位章节高亮，并在正文编辑后计算更新后的选区。
// 关联文件:
//   lib/shared/database/novel_content_daos/chapter_dao.dart
//   lib/shared/widgets/chapter/dialogue_highlight_controller.dart

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../database/novel_content_database.dart';

typedef ChapterHighlightRange = ({int start, int end});

class ChapterHighlightText {
  ChapterHighlightText(this.value);

  static const _contextLength = 16;
  final String value;
  late final String hash = sha256.convert(utf8.encode(value)).toString();

  String prefixAt(int offset) {
    var start = max(0, offset - _contextLength);
    if (_splitsSurrogatePair(start)) {
      start--;
    }
    return value.substring(start, offset);
  }

  String suffixAt(int offset) {
    var end = min(value.length, offset + _contextLength);
    if (_splitsSurrogatePair(end)) {
      end++;
    }
    return value.substring(offset, end);
  }

  bool _splitsSurrogatePair(int offset) {
    if (offset <= 0 || offset >= value.length) {
      return false;
    }
    final unit = value.codeUnitAt(offset);
    return unit >= 0xdc00 && unit <= 0xdfff;
  }

  bool isValidRange(ChapterHighlightRange range) =>
      range.start >= 0 &&
      range.end > range.start &&
      range.end <= value.length &&
      !_splitsSurrogatePair(range.start) &&
      !_splitsSurrogatePair(range.end);

  ChapterHighlightRange? resolve(ChapterHighlight highlight) {
    final original = (start: highlight.startOffset, end: highlight.endOffset);
    if (highlight.contentHash == hash &&
        isValidRange(original) &&
        value.substring(original.start, original.end) == highlight.quote) {
      return original;
    }
    if (highlight.quote.isEmpty) {
      return null;
    }

    ChapterHighlightRange? best;
    var bestScore = 0;
    var start = value.indexOf(highlight.quote);
    while (start >= 0) {
      final end = start + highlight.quote.length;
      final prefixStart = start - highlight.prefix.length;
      final prefixMatches = highlight.prefix.isEmpty
          ? start == 0
          : prefixStart >= 0 && value.startsWith(highlight.prefix, prefixStart);
      final suffixMatches = highlight.suffix.isEmpty
          ? end == value.length
          : value.startsWith(highlight.suffix, end);
      final score = (prefixMatches ? 1 : 0) + (suffixMatches ? 1 : 0);
      if (score > bestScore) {
        best = (start: start, end: end);
        bestScore = score;
      } else if (score == bestScore) {
        best = null;
      }
      start = value.indexOf(highlight.quote, start + 1);
    }
    return best;
  }
}

/// 将一次正文修改表示为首尾公共文本之间的替换。
class ChapterHighlightEdit {
  ChapterHighlightEdit(String before, String after) {
    var prefix = 0;
    final limit = min(before.length, after.length);
    while (prefix < limit &&
        before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
      prefix++;
    }
    var beforeEnd = before.length;
    var afterEnd = after.length;
    while (beforeEnd > prefix &&
        afterEnd > prefix &&
        before.codeUnitAt(beforeEnd - 1) == after.codeUnitAt(afterEnd - 1)) {
      beforeEnd--;
      afterEnd--;
    }
    _start = prefix;
    _end = beforeEnd;
    _lengthChange = afterEnd - beforeEnd;
  }

  late final int _start;
  late final int _end;
  late final int _lengthChange;

  ChapterHighlightRange? move(ChapterHighlightRange range) {
    if (_end <= range.start) {
      return (
        start: range.start + _lengthChange,
        end: range.end + _lengthChange,
      );
    }
    if (_start >= range.end) {
      return range;
    }
    if (_start >= range.start &&
        _end <= range.end &&
        (_start > range.start || _end < range.end)) {
      return (start: range.start, end: range.end + _lengthChange);
    }
    return null;
  }
}

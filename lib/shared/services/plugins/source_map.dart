// 职责: 按视图 source map 把插件运行时错误栈中的产物位置改写为 TSX 源码位置。
// 关联文件:
//   lib/shared/services/plugins/ui_session.dart
//   lib/shared/services/plugins/host.dart
//   plugins/build.mjs
import 'dart:convert';

typedef _Segment = ({int column, int source, int line, int sourceColumn});

class PluginSourceMap {
  PluginSourceMap._(this._sources, this._lines);

  /// Throws [FormatException] for a malformed version 3 source map.
  factory PluginSourceMap.parse(String text) {
    final map = jsonDecode(text);
    if (map is! Map<String, dynamic> ||
        map['version'] != 3 ||
        map['sources'] is! List ||
        map['mappings'] is! String) {
      throw const FormatException('Invalid source map');
    }
    final sources = [
      for (final source in map['sources'] as List)
        (source as String).replaceFirst(RegExp(r'^(\.\./)+'), ''),
    ];
    final lines = <List<_Segment>>[];
    var source = 0, line = 0, sourceColumn = 0;
    for (final group in (map['mappings'] as String).split(';')) {
      final segments = <_Segment>[];
      var column = 0;
      for (final raw in group.split(',')) {
        if (raw.isEmpty) {
          continue;
        }
        final values = _decode(raw);
        if (![1, 4, 5].contains(values.length)) {
          throw const FormatException('Invalid source map segment');
        }
        column += values[0];
        if (values.length >= 4) {
          source += values[1];
          line += values[2];
          sourceColumn += values[3];
          if (source < 0 || source >= sources.length) {
            throw const FormatException('Source map index out of range');
          }
          segments.add((
            column: column,
            source: source,
            line: line,
            sourceColumn: sourceColumn,
          ));
        }
      }
      lines.add(segments);
    }
    return PluginSourceMap._(sources, lines);
  }

  final List<String> _sources;
  final List<List<_Segment>> _lines;

  /// Maps a 1-based generated line and column to its 1-based source position.
  String? lookup(int line, int column) {
    if (line < 1 || line > _lines.length) {
      return null;
    }
    _Segment? match;
    for (final segment in _lines[line - 1]) {
      if (segment.column > column - 1) {
        break;
      }
      match = segment;
    }
    match ??= _lines[line - 1].firstOrNull;
    if (match == null) {
      return null;
    }
    return '${_sources[match.source]}:${match.line + 1}:${match.sourceColumn + 1}';
  }

  /// Rewrites `filename:line:column` stack positions that the map covers.
  String rewrite(String text, String filename) => text.replaceAllMapped(
    RegExp('${RegExp.escape(filename)}:(\\d+):(\\d+)'),
    (match) => lookup(int.parse(match[1]!), int.parse(match[2]!)) ?? match[0]!,
  );

  static const _alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  static List<int> _decode(String segment) {
    final values = <int>[];
    var value = 0, shift = 0;
    for (final char in segment.split('')) {
      final digit = _alphabet.indexOf(char);
      if (digit < 0) {
        throw const FormatException('Invalid source map mapping');
      }
      value += (digit & 31) << shift;
      if (digit & 32 == 0) {
        values.add(value & 1 == 1 ? -(value >> 1) : value >> 1);
        value = 0;
        shift = 0;
      } else {
        shift += 5;
      }
    }
    if (shift != 0) {
      throw const FormatException('Truncated source map mapping');
    }
    return values;
  }
}

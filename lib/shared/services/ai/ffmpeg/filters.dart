// 职责: 校验滤镜参数的文件访问边界，解析文件依赖并按 FFmpeg 两层转义规则改写文件路径。
// 关联文件:
//   lib/shared/services/ai/ffmpeg/options.dart
//   lib/shared/services/ai/ffmpeg/arguments.dart
//   lib/shared/services/ai/ffmpeg/inputs.dart
import '../../../models/tool_permission.dart';
import 'options.dart';

/// Only quotes and escapes protect separators, matching FFmpeg tokenization.
List<String> ffmpegSplit(String text, String delimiters) {
  final parts = <String>[];
  var start = 0;
  var quoted = false, escaped = false;
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char == r'\' && !quoted) {
      escaped = true;
      continue;
    }
    if (char == "'") {
      quoted = !quoted;
      continue;
    }
    if (quoted) {
      continue;
    }
    if (delimiters.contains(char)) {
      parts.add(text.substring(start, i));
      parts.add(char);
      start = i + 1;
    }
  }
  if (quoted || escaped) {
    throw const FormatException('Unterminated FFmpeg quoting.');
  }
  parts.add(text.substring(start));
  return parts;
}

/// FFmpeg av_get_token removes one layer of single quotes and escapes.
String ffmpegUnquote(String value) {
  final result = StringBuffer();
  var quoted = false;
  for (var i = 0; i < value.length; i++) {
    final char = value[i];
    if (char == "'") {
      quoted = !quoted;
    } else if (char == r'\' && !quoted) {
      if (++i == value.length) {
        throw const FormatException('Incomplete FFmpeg escape.');
      }
      result.write(value[i]);
    } else {
      result.write(char);
    }
  }
  if (quoted) {
    throw const FormatException('Unterminated FFmpeg quote.');
  }
  return result.toString();
}

String _escape(String value, String characters) => value.split('').map((c) {
  return characters.contains(c) ? '\\$c' : c;
}).join();

String ffmpegFilterValue(String value) =>
    _escape(_escape(value, "\\':"), "\\'[],;");

const _positionalFiles = {
  'subtitles': 'filename',
  'ass': 'filename',
  'lut3d': 'file',
  'lut1d': 'file',
};

class FfmpegFilterGraph {
  FfmpegFilterGraph(this.text) {
    final parts = ffmpegSplit(text, ',;');
    for (var i = 0; i < parts.length; i += 2) {
      final segment = parts[i];
      final match = RegExp(
        r'^\s*((?:\[[A-Za-z0-9_:]+\]\s*)*)([A-Za-z0-9_]+)(@[A-Za-z0-9_]+)?(?==|\[|\s*$)',
      ).firstMatch(segment);
      if (match == null || !ffmpegFilters.contains(match.group(2))) {
        throw const ToolOperationException(
          'unsupported',
          'Unsupported filter.',
        );
      }
      final name = match.group(2)!;
      final rest = segment.substring(match.end).trim();
      final labels = RegExp(r'(?:\[[A-Za-z0-9_:]+\]\s*)+$').firstMatch(rest);
      final raw = labels == null ? rest : rest.substring(0, labels.start);
      final values = raw.startsWith('=')
          ? ffmpegSplit(ffmpegUnquote(raw.substring(1)), ':')
          : <String>[];
      // FFmpeg resolves /option=file after decoding graph-level escaping.
      // Check option names only: values may legitimately contain /option= text.
      for (var n = 0; n < values.length; n += 2) {
        final item = values[n];
        final equal = item.indexOf('=');
        if (equal > 0 && item.substring(0, equal).trim().startsWith('/')) {
          throw const ToolOperationException(
            'unsupported',
            'Use explicit filter file options.',
          );
        }
      }
      if (!ffmpegFilterFileOptions.containsKey(name)) {
        continue;
      }
      final options = <(String, String)>[];
      if (raw.startsWith('=')) {
        for (var n = 0; n < values.length; n += 2) {
          final item = values[n];
          final equal = item.indexOf('=');
          String key, value;
          if (equal < 0 && n == 0 && _positionalFiles.containsKey(name)) {
            key = _positionalFiles[name]!;
            value = ffmpegUnquote(item);
          } else if (equal > 0) {
            key = item.substring(0, equal);
            value = ffmpegUnquote(item.substring(equal + 1));
          } else {
            throw const FormatException('Use named filter options.');
          }
          if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key) ||
              key == 'fontsdir' ||
              (name == 'curves' && key == 'plot')) {
            throw const ToolOperationException(
              'unsupported',
              'Use explicit fontfile or named filter options.',
            );
          }
          options.add((key, value));
          if (ffmpegFilterFileOptions[name]!.contains(key)) {
            if (value.isEmpty) {
              throw const FormatException('Filter dependency cannot be empty.');
            }
            dependencies.add(value);
          }
        }
      }
      _rewrites[i] = (
        prefix: segment.substring(0, match.end),
        suffix: labels?.group(0) ?? '',
        name: name,
        options: options,
      );
    }
    _parts = parts;
  }
  final String text;
  final dependencies = <String>{};

  /// 未指定 fontfile 的 drawtext 由 [rewrite] 补上内置字体，AI 不必猜本机字体路径。
  bool get usesDefaultFont =>
      _rewrites.values.any((spec) => _needsFont(spec.name, spec.options));
  static bool _needsFont(String name, List<(String, String)> options) =>
      name == 'drawtext' && !options.any((option) => option.$1 == 'fontfile');
  late final List<String> _parts;
  final _rewrites =
      <
        int,
        ({
          String prefix,
          String suffix,
          String name,
          List<(String, String)> options,
        })
      >{};

  String rewrite(Map<String, String> paths, {String? defaultFont}) {
    final parts = _parts.toList();
    for (final entry in _rewrites.entries) {
      final spec = entry.value;
      final needsFont = _needsFont(spec.name, spec.options);
      if (needsFont && defaultFont == null) {
        throw StateError('Missing default drawtext font');
      }
      final options =
          [if (needsFont) ('fontfile', defaultFont!), ...spec.options]
              .map((option) {
                final (key, value) = option;
                final injected = needsFont && key == 'fontfile';
                final path =
                    !injected &&
                    ffmpegFilterFileOptions[spec.name]!.contains(key);
                if (path && !paths.containsKey(value)) {
                  throw StateError('Missing resolved filter dependency');
                }
                return '$key=${ffmpegFilterValue(path ? paths[value]! : value)}';
              })
              .join(':');
      parts[entry.key] =
          '${spec.prefix}${options.isEmpty ? '' : '=$options'}${spec.suffix}';
    }
    return parts.join();
  }
}

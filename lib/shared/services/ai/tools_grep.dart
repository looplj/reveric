// 职责: AI Grep 工具，负责在 Read 可见资源文本字段中查找正则匹配。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_read.dart
//   lib/shared/services/ai/tools_resource_search_support.dart
// 遵循的 Rules:
//   .agents/rules/tools_path.md
// ignore_for_file: unused_element
part of 'tools.dart';

const _resourceGrepMaxMatches = 32;
const _resourceGrepMaxPerFile = 16;
const _resourceGrepDefaultMaxLineLen = 1024;
const _resourceGrepSearchFileBudget = 1000;

const _grepDescription = '''在作品工作区资源文本字段中查找正则匹配。

它会搜索章节正文、剧本标题／集大纲／节拍说明／场次梗概／元素正文、角色资料和世界观文档等文本字段。
剧本搜索省略季集筛选时覆盖全剧本。
优先提供 `path` 或 `glob` 限定搜索范围；根路径搜索可能被扫描预算截断。

返回：
- text：与 grep 命令类似的文本结果。
- truncated：是否因匹配过多、搜索文件过多或扫描预算被截断。
- scanned_paths：已扫描的资源路径数。
- searched_files：已读取并搜索的文本字段数。
- scan_truncated：是否命中路径扫描预算。

示例：
- {"pattern": "伏笔", "path": "chapters"} → 默认返回 `path:line:content`，类似 grep -n。
- {"pattern": "主角", "glob": "characters/*/{summary,description}"}
- {"pattern": "第[一二三]次", "path": "outlines"}
- {"pattern": "线索", "path": "scenes?episode_id=episode_1"}
- 查找包含某关键词的角色资料：{"pattern": "关键词", "glob": "characters/*/{name,summary,description}", "output_mode": "content"}''';

final _grepInputSchema = const {
  'type': 'object',
  'properties': {
    'pattern': {
      'type': 'string',
      'description': '正则表达式；literal=true 时按普通文本匹配。',
    },
    'path': {'type': 'string', 'description': '起始资源路径，默认当前作品根目录。'},
    'glob': {'type': 'string', 'description': '限制搜索资源路径的 glob 模式。'},
    'output_mode': {
      'type': 'string',
      'enum': ['files_with_matches', 'content', 'count'],
      'description': '输出模式，默认 content。',
    },
    'before': {
      'type': 'integer',
      'minimum': 0,
      'description': 'content 模式下匹配行之前返回的上下文行数。',
    },
    'after': {
      'type': 'integer',
      'minimum': 0,
      'description': 'content 模式下匹配行之后返回的上下文行数。',
    },
    'context': {
      'type': 'integer',
      'minimum': 0,
      'description': 'content 模式下匹配行前后各返回的上下文行数。',
    },
    'line_number': {
      'type': 'boolean',
      'description': 'content 模式下是否显示行号，默认 true。',
    },
    'ignore_case': {'type': 'boolean', 'description': '忽略大小写，默认 false。'},
    'literal': {
      'type': 'boolean',
      'description': '把 pattern 当普通文本而非正则匹配，默认 false。',
    },
    'head_limit': {
      'type': 'integer',
      'minimum': 0,
      'description': '最多返回多少条结果。',
    },
    'offset': {'type': 'integer', 'minimum': 0, 'description': '跳过开头多少条结果。'},
    'max_line_len': {
      'type': 'integer',
      'minimum': 0,
      'description': '单行超过该长度时截断。',
    },
  },
  'required': ['pattern'],
  'additionalProperties': false,
};

mixin _AiToolManagerGrepMixin on _AiToolManagerResourceSearchSupportMixin {
  Future<Map<String, dynamic>> _handleGrep(Map<String, dynamic> input) async {
    final patternArg = _parseStringArgument(input['pattern']);
    if (patternArg.isEmpty) {
      return {
        'ok': false,
        'error': 'Grep requires pattern',
        'error_code': ToolErrorCode.invalid_argument.name,
      };
    }

    final literal = _parseBoolArgument(input['literal']);
    final pattern = literal ? RegExp.escape(patternArg) : patternArg;
    final RegExp regex;
    try {
      regex = RegExp(
        pattern,
        caseSensitive: !_parseBoolArgument(input['ignore_case']),
        multiLine: true,
      );
    } catch (error) {
      return {
        'ok': false,
        'error': 'Invalid grep pattern: $error',
        'error_code': ToolErrorCode.invalid_argument.name,
      };
    }
    final outputMode = _parseStringArgument(
      input['output_mode'],
      defaultValue: 'content',
      trim: true,
    );
    if (!{'files_with_matches', 'content', 'count'}.contains(outputMode)) {
      return {
        'ok': false,
        'error': 'output_mode must be files_with_matches, content, or count',
        'error_code': ToolErrorCode.invalid_argument.name,
      };
    }

    final root = _parseStringArgument(
      input['path'],
      defaultValue: '/',
      trim: true,
    );
    final glob = _parseStringArgument(input['glob'], trim: true);
    _CompiledResourceGlob? compiledGlob;
    if (glob.isNotEmpty) {
      final compiled = _compileResourceGlob(glob);
      if (compiled.error != null) {
        return {
          'ok': false,
          'error': compiled.error,
          'error_code': ToolErrorCode.invalid_argument.name,
        };
      }
      compiledGlob = compiled.glob!;
    }
    final paths = await _collectResourcePaths(root, glob: compiledGlob);
    if (paths.error != null) {
      return paths.error!;
    }
    final searchable = paths.entries.where((entry) => entry.searchable).toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final results = <String>[];
    var totalEntries = 0;
    var matchTruncated = false;
    var searchTruncated = false;
    var searchedFiles = 0;
    for (final entry in searchable) {
      if (searchedFiles >= _resourceGrepSearchFileBudget) {
        searchTruncated = true;
        break;
      }
      if (totalEntries >= _resourceGrepMaxMatches) {
        matchTruncated = true;
        break;
      }

      final read = await _readResourceString(entry.target);
      if (read.error != null) {
        return read.error!;
      }
      final text = read.text;
      if (text == null) {
        continue;
      }
      searchedFiles += 1;

      final matches = _grepResourceText(
        path: _resourceReferencePath(entry.path),
        text: text,
        regex: regex,
        input: input,
        outputMode: outputMode,
      );
      final entries = matches.entries;
      matchTruncated = matchTruncated || matches.truncated;
      if (entries.isEmpty) {
        continue;
      }

      final remaining = _resourceGrepMaxMatches - totalEntries;
      final visibleEntries = entries.length > remaining
          ? entries.sublist(0, remaining)
          : entries;
      results.addAll(visibleEntries);
      totalEntries += visibleEntries.length;
      if (entries.length > remaining) {
        matchTruncated = true;
      }
    }

    final paged = _applyGrepPagination(results, input);
    final offset = (_parseIntArgument(input['offset']) ?? 0).clamp(
      0,
      results.length,
    );
    final nextOffset = offset + paged.length;
    final hasMore = nextOffset < results.length;
    final truncated =
        hasMore || matchTruncated || searchTruncated || paths.truncated;
    final pagination = <String, dynamic>{
      'has_more': hasMore,
      if (hasMore) 'next_offset': nextOffset,
    };
    if (paged.isEmpty) {
      return {
        'ok': true,
        'text': 'No results found.',
        'truncated': truncated,
        ...pagination,
        'scanned_paths': paths.scannedPaths,
        'scan_limit': _resourcePathScanBudget,
        'scan_truncated': paths.truncated,
        'searched_files': searchedFiles,
        'search_file_limit': _resourceGrepSearchFileBudget,
        'search_truncated': searchTruncated,
        if (_targetsRelations([root, glob]))
          'hint': _relationsNotSearchableHint,
      };
    }

    var text = '${paged.join('\n')}\n';
    if (matchTruncated && _parseIntArgument(input['head_limit']) == null) {
      text += '... (truncated)\n';
    }
    return {
      'ok': true,
      'text': text,
      'truncated': truncated,
      ...pagination,
      'scanned_paths': paths.scannedPaths,
      'scan_limit': _resourcePathScanBudget,
      'scan_truncated': paths.truncated,
      'searched_files': searchedFiles,
      'search_file_limit': _resourceGrepSearchFileBudget,
      'search_truncated': searchTruncated,
    };
  }

  ({List<String> entries, bool truncated}) _grepResourceText({
    required String path,
    required String text,
    required RegExp regex,
    required Map<String, dynamic> input,
    required String outputMode,
  }) {
    final lines = text.isEmpty
        ? <String>[]
        : const LineSplitter().convert(text);
    if (outputMode == 'count') {
      var count = 0;
      for (final line in lines) {
        if (regex.hasMatch(line)) {
          count += 1;
        }
      }
      return (
        entries: count == 0 ? const <String>[] : ['$path:$count'],
        truncated: false,
      );
    }

    final matchIndexes = <int>[];
    var truncated = false;
    for (var i = 0; i < lines.length; i += 1) {
      if (regex.hasMatch(lines[i])) {
        if (outputMode == 'files_with_matches') {
          return (entries: [path], truncated: false);
        }
        if (matchIndexes.length >= _resourceGrepMaxPerFile) {
          truncated = true;
          break;
        }
        matchIndexes.add(i);
      }
    }
    return (
      entries: _formatGrepContentMatches(path, lines, matchIndexes, input),
      truncated: truncated,
    );
  }

  List<String> _formatGrepContentMatches(
    String path,
    List<String> lines,
    List<int> matchIndexes,
    Map<String, dynamic> input,
  ) {
    var before = _parseIntArgument(input['context']) ?? 0;
    var after = _parseIntArgument(input['context']) ?? 0;
    before = _parseIntArgument(input['before']) ?? before;
    after = _parseIntArgument(input['after']) ?? after;
    if (before < 0) {
      before = 0;
    }
    if (after < 0) {
      after = 0;
    }
    final hasContext = before > 0 || after > 0;
    final lineNumber = _parseBoolArgument(
      input['line_number'],
      defaultValue: true,
    );
    final maxLineLen =
        _parseIntArgument(input['max_line_len']) ??
        _resourceGrepDefaultMaxLineLen;

    final indexes = <int>{};
    for (final matchIndex in matchIndexes) {
      var start = matchIndex - before;
      if (start < 0) {
        start = 0;
      }
      var end = matchIndex + after;
      if (end >= lines.length) {
        end = lines.length - 1;
      }
      for (var i = start; i <= end; i += 1) {
        indexes.add(i);
      }
    }
    final sortedIndexes = indexes.toList()..sort();

    final out = <String>[];
    var previous = -2;
    for (final index in sortedIndexes) {
      if (hasContext && previous >= 0 && index > previous + 1) {
        out.add('--');
      }
      previous = index;
      final isMatch = matchIndexes.contains(index);
      final line = _truncateGrepLine(lines[index], maxLineLen);
      if (lineNumber) {
        final sep = hasContext && !isMatch ? '-' : ':';
        out.add('$path:${index + 1}$sep$line');
      } else {
        out.add('$path:$line');
      }
    }
    return out;
  }
}

List<String> _applyGrepPagination(
  List<String> entries,
  Map<String, dynamic> input,
) {
  final offset = _parseIntArgument(input['offset']) ?? 0;
  final limit = _parseIntArgument(input['head_limit']) ?? 0;
  var out = entries;
  if (offset > 0) {
    if (offset >= out.length) {
      return const [];
    }
    out = out.sublist(offset);
  }
  if (limit > 0 && limit < out.length) {
    out = out.sublist(0, limit);
  }
  return out;
}

String _truncateGrepLine(String value, int maxLen) {
  if (maxLen <= 0 || value.length <= maxLen) {
    return value;
  }
  return '${value.substring(0, maxLen)}...';
}

// 职责: AI Replace 工具 — 在 Read 可见资源文本字段中批量正则替换，复用 Edit 落库管线。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_grep.dart
//   lib/shared/services/ai/tools_edit.dart
//   lib/shared/services/ai/tools_resource_search_support.dart
// 遵循的 Rules:
//   .agents/rules/tools_path.md
part of 'tools.dart';

const _resourceReplaceVariantLimit = 1000;
const _resourceReplaceFailedPathLimit = 5;

const _replaceDescription = r'''在作品工作区资源文本字段中批量正则替换。

改单处文本用 Edit；跨多个资源改同一模式用本工具，典型场景是角色改名、称谓统一、标点规范化。

必须提供 `path` 或 `glob` 之一限定范围。
先空跑看命中，确认无误再传 `dry_run: false` 执行。
中文没有词边界，`\b` 对汉字不生效；排除误伤要用负向断言，如 `李明(?!月)` 避开「李明月」。
一次处理范围内全部命中，不分页、不截断。
剧本只替换场次 synopsis、非 character 元素的 text 和集大纲；标题跳过。

返回：
- 空跑：matched_fields、total_matches、samples（全部命中变体，每条 `"匹配串+后2字 次数"`）。
- 实际替换：applied_fields、total_replacements、failed（按 error_code 分组，每组含 count 和 sample_paths）。
- 两者都可能返回 skipped_fields（范围内不可编辑的字段数）。

示例：
- 空跑看命中：{"pattern": "李明", "replacement": "李泽明", "glob": "chapters/*/content"}
- 指定集预览：{"pattern": "李明", "replacement": "李泽明", "path": "scenes?episode_id=episode_1"}
- 排除误伤后执行：{"pattern": "李明(?!月)", "replacement": "李泽明", "glob": "chapters/*/content", "dry_run": false}
- 引号成对转换：{"pattern": "'([^']*)'", "replacement": "\"$1\"", "glob": "chapters/*/content"}''';

final _replaceInputSchema = const {
  'type': 'object',
  'properties': {
    'pattern': {
      'type': 'string',
      'description': '正则表达式；literal=true 时按普通文本匹配。',
    },
    'replacement': {
      'type': 'string',
      'description':
          r'替换文本。可用 $1、${1} 引用捕获组，$$ 表示字面 $。'
          r'$N 只取一位数字，两位以上的组号必须写 ${10}（$10 会被当成第 1 组后面跟字面 0）。'
          r'literal=true 时整串按字面写入。空字符串表示删除匹配内容。',
    },
    'path': {'type': 'string', 'description': '起始资源路径，限定替换范围。'},
    'glob': {'type': 'string', 'description': '限制资源路径的 glob 模式。'},
    'dry_run': {'type': 'boolean', 'description': '只返回命中预览、不写入，默认 true。'},
    'ignore_case': {'type': 'boolean', 'description': '忽略大小写，默认 false。'},
    'literal': {
      'type': 'boolean',
      'description': '把 pattern 当普通文本而非正则匹配，默认 false。',
    },
  },
  'required': ['pattern', 'replacement'],
  'additionalProperties': false,
};

mixin _AiToolManagerReplaceMixin
    on
        _AiToolManagerBase,
        _AiToolManagerReadMixin,
        _AiToolManagerResourceSearchSupportMixin,
        _AiToolManagerEditMixin {
  Future<Map<String, dynamic>> _handleReplace(
    Map<String, dynamic> input,
  ) async {
    if (!input.containsKey('pattern') || !input.containsKey('replacement')) {
      return {
        'ok': false,
        'error': 'Replace requires pattern and replacement',
        'error_code': ToolErrorCode.invalid_argument.name,
      };
    }

    final patternArg = _parseStringArgument(input['pattern']);
    if (patternArg.isEmpty) {
      return {
        'ok': false,
        'error': 'Replace requires a non-empty pattern',
        'error_code': ToolErrorCode.invalid_argument.name,
      };
    }
    final path = _parseStringArgument(input['path'], trim: true);
    final glob = _parseStringArgument(input['glob'], trim: true);
    if (path.isEmpty && glob.isEmpty) {
      return {
        'ok': false,
        'error': 'Replace requires path or glob',
        'error_code': ToolErrorCode.invalid_argument.name,
      };
    }

    final literal = _parseBoolArgument(input['literal']);
    final RegExp regex;
    try {
      regex = RegExp(
        literal ? RegExp.escape(patternArg) : patternArg,
        caseSensitive: !_parseBoolArgument(input['ignore_case']),
        multiLine: true,
      );
    } catch (error) {
      return {
        'ok': false,
        'error': 'Invalid replace pattern: $error',
        'error_code': ToolErrorCode.invalid_argument.name,
      };
    }

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

    // 不设扫描预算：Replace 的返回体积（计数 + 变体 + failed 分组）与扫了多少
    // 字段无关，截断只会让长篇改不完还静默漏掉后半部。
    final paths = await _collectResourcePaths(
      path.isEmpty ? '/' : path,
      glob: compiledGlob,
      budget: null,
    );
    if (paths.error != null) {
      return paths.error!;
    }
    var skippedNotEditable = 0;
    final targets = <_ResourcePathEntry>[];
    for (final entry in paths.entries) {
      if (!entry.readableText) {
        continue;
      }
      if (!entry.target.canEditField) {
        skippedNotEditable += 1;
        continue;
      }
      if (entry.searchable) {
        targets.add(entry);
      }
    }
    targets.sort((a, b) => a.path.compareTo(b.path));

    final dryRun = _parseBoolArgument(input['dry_run'], defaultValue: true);
    final replacement = _parseTextArgument(input['replacement']);
    final variants = <String, int>{};
    final failures = <String, _ReplaceFailure>{};
    var matchedFields = 0;
    var totalMatches = 0;
    var totalReplacements = 0;
    var appliedFields = 0;
    var patternTooBroad = false;

    for (final entry in targets) {
      final target = entry.path;
      final read = await _readResourceString(entry.target);
      if (read.error != null) {
        if (dryRun) {
          return read.error!;
        }
        _recordReplaceFailure(
          failures,
          _parseStringArgument(read.error!['error_code']),
          target,
        );
        continue;
      }
      final text = read.text;
      if (text == null) {
        continue;
      }
      final matches = regex.allMatches(text).toList(growable: false);
      if (matches.isEmpty) {
        continue;
      }

      matchedFields += 1;
      totalMatches += matches.length;
      if (dryRun) {
        for (final match in matches) {
          // 变体 = 匹配串 + 后 2 字，用来暴露同前缀误伤（`李明` 命中「李明月」）。
          final end = (match.end + 2).clamp(0, text.length).toInt();
          final variant = text.substring(match.start, end);
          if (!variants.containsKey(variant) &&
              variants.length >= _resourceReplaceVariantLimit) {
            patternTooBroad = true;
            continue;
          }
          variants[variant] = (variants[variant] ?? 0) + 1;
        }
        continue;
      }

      final next = literal
          ? text.replaceAll(regex, replacement)
          : text.replaceAllMapped(
              regex,
              (match) => _expandReplacement(match, replacement),
            );
      // 单个字段写失败不能中断整批：stageTextChange 会抛，异常降级成 failed 一条，
      // 否则前面已落库的字段在异常里全部丢失。
      final Map<String, dynamic> result;
      try {
        result = await runZoned(
          () => _applyEditToPath(entry.target, text, next, false),
          zoneValues: {_stagingToolNameZoneKey: 'Replace'},
        );
      } catch (error, stackTrace) {
        _log.error(
          'Replace apply failed path=$target',
          error: error,
          stackTrace: stackTrace,
        );
        _recordReplaceFailure(failures, ToolErrorCode.internal.name, target);
        continue;
      }
      final errorCode = _parseStringArgument(result['error_code']);
      if (errorCode.isNotEmpty || result.containsKey('error')) {
        _recordReplaceFailure(failures, errorCode, target);
        continue;
      }
      appliedFields += 1;
      totalReplacements += matches.length;
    }

    final common = <String, dynamic>{
      'ok': true,
      'dry_run': dryRun,
      if (skippedNotEditable > 0)
        'skipped_fields': {'not_editable': skippedNotEditable},
    };
    if (dryRun) {
      if (patternTooBroad) {
        return {
          'ok': false,
          'error':
              'Pattern matched more than $_resourceReplaceVariantLimit distinct '
              'variants. Narrow the pattern and dry run again.',
          'error_code': ToolErrorCode.resource_exhausted.name,
          'matched_fields': matchedFields,
          'total_matches': totalMatches,
        };
      }
      return {
        ...common,
        'matched_fields': matchedFields,
        'total_matches': totalMatches,
        'samples': _formatReplaceVariants(variants),
      };
    }
    return {
      ...common,
      'applied_fields': appliedFields,
      'total_replacements': totalReplacements,
      if (failures.isNotEmpty)
        'failed': {
          for (final entry in failures.entries) entry.key: entry.value.toJson(),
        },
    };
  }
}

String _expandReplacement(Match match, String template) {
  if (!template.contains(r'$')) {
    return template;
  }
  final buffer = StringBuffer();
  var index = 0;
  while (index < template.length) {
    final character = template[index];
    if (character != r'$' || index + 1 >= template.length) {
      buffer.write(character);
      index += 1;
      continue;
    }
    final next = template[index + 1];
    if (next == r'$') {
      buffer.write(r'$');
      index += 2;
      continue;
    }
    if (next == '{') {
      final end = template.indexOf('}', index + 2);
      final group = end > index + 2
          ? int.tryParse(template.substring(index + 2, end))
          : null;
      if (group == null || group == 0 || group > match.groupCount) {
        buffer.write(character);
        index += 1;
      } else {
        buffer.write(match.group(group) ?? '');
        index = end + 1;
      }
      continue;
    }
    final group = int.tryParse(next);
    if (group == null || group == 0 || group > match.groupCount) {
      buffer.write(character);
      index += 1;
      continue;
    }
    buffer.write(match.group(group) ?? '');
    index += 2;
  }
  return buffer.toString();
}

/// 变体按出现次数倒序，每条 `"匹配串+后2字 次数"`。
List<String> _formatReplaceVariants(Map<String, int> variants) {
  final entries = variants.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return entries
      .map((entry) => '${entry.key} ${entry.value}')
      .toList(growable: false);
}

void _recordReplaceFailure(
  Map<String, _ReplaceFailure> failures,
  String errorCode,
  String path,
) {
  final code = errorCode.isEmpty ? ToolErrorCode.internal.name : errorCode;
  final failure = failures.putIfAbsent(code, _ReplaceFailure.new);
  failure.count += 1;
  if (failure.samplePaths.length < _resourceReplaceFailedPathLimit) {
    failure.samplePaths.add(_resourceReferencePath(path));
  }
}

class _ReplaceFailure {
  var count = 0;
  final samplePaths = <String>[];

  Map<String, dynamic> toJson() => {
    'count': count,
    'sample_paths': samplePaths,
  };
}

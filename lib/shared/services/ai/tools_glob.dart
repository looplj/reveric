// 职责: AI Glob 工具，负责按 glob 模式列出 Read 可见的资源路径。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_read.dart
//   lib/shared/services/ai/tools_resource_search_support.dart
// 遵循的 Rules:
//   .agents/rules/tools_path.md
// ignore_for_file: unused_element
part of 'tools.dart';

const _resourceGlobMaxResults = 200;

const _globDescription = '''按路径模式列出作品工作区资源。

Glob 基于 Read 工具可访问的资源路径工作。用它快速发现可读取路径，再用 Read 或 Grep 查看内容。
优先提供 `path` 限定遍历范围；根路径遍历可能被扫描预算截断。
Glob 只匹配资源路径，不读取字段值；要按字段值查找，使用 Grep。

返回：
- matches：匹配的资源路径，最多 200 条。
- truncated：是否因结果过多或扫描预算被截断。
- scanned_paths：已扫描的资源路径数。
- scan_truncated：是否命中扫描预算。

示例：
- {"pattern": "chapters/*/content"}
- {"pattern": "scenes/*/elements/*/text"}
- {"path": "scenes?episode_id=episode_1", "pattern": "**/text"} → 在指定集发现正文元素路径。
- {"pattern": "{lore,materials}/**/content"}
- {"pattern": "**/summary"}
- {"pattern": "characters/*/name"} → 列出所有角色 name 字段路径；不会过滤 name 值。
- {"pattern": "lore/**/魔法系统/content"} → 按 lore 标题路径匹配。''';

final _globInputSchema = const {
  'type': 'object',
  'properties': {
    'pattern': {
      'type': 'string',
      'description':
          '资源路径 glob 模式，如 "chapters/*/content"。'
          '支持 `*`、`?`、`[...]`、`**` 和简单 brace expansion（如 `{chapters,materials}`）。',
    },
    'path': {'type': 'string', 'description': '起始资源路径，默认当前作品根目录。用于限制遍历范围。'},
  },
  'required': ['pattern'],
  'additionalProperties': false,
};

mixin _AiToolManagerGlobMixin on _AiToolManagerResourceSearchSupportMixin {
  Future<Map<String, dynamic>> _handleGlob(Map<String, dynamic> input) async {
    final pattern = _parseStringArgument(input['pattern'], trim: true);
    if (pattern.isEmpty) {
      return {
        'ok': false,
        'error': 'Glob requires pattern',
        'error_code': ToolErrorCode.invalid_argument.name,
      };
    }
    final compiled = _compileResourceGlob(pattern);
    if (compiled.error != null) {
      return {
        'ok': false,
        'error': compiled.error,
        'error_code': ToolErrorCode.invalid_argument.name,
      };
    }

    final root = _parseStringArgument(
      input['path'],
      defaultValue: '/',
      trim: true,
    );
    final paths = await _collectResourcePaths(root, glob: compiled.glob);
    if (paths.error != null) {
      return paths.error!;
    }
    final matches = paths.entries.map((entry) => entry.path).toList()..sort();
    final outputTruncated = matches.length > _resourceGlobMaxResults;
    final visible = outputTruncated
        ? matches.sublist(0, _resourceGlobMaxResults)
        : matches;

    return {
      'ok': true,
      'matches': visible.map(_resourceReferencePath).toList(),
      'total': matches.length,
      'truncated': outputTruncated || paths.truncated,
      'scanned_paths': paths.scannedPaths,
      'scan_limit': _resourcePathScanBudget,
      'scan_truncated': paths.truncated,
      if (matches.isEmpty && _targetsRelations([pattern, root]))
        'hint': _relationsNotSearchableHint
      else if (matches.isEmpty &&
          paths.scannedPaths <= 1 &&
          _normalizeResourceDisplayPath(root) != '/')
        'hint': _noListableChildrenHint(root),
    };
  }
}

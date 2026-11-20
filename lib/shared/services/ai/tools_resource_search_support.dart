// 职责: 按公共资源目标读取原值供搜索与预览使用，并遍历 Read 可见路径。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_read.dart
//   lib/shared/services/ai/tools_glob.dart
//   lib/shared/services/ai/tools_grep.dart
//   lib/shared/services/ai/tools_screenplay.dart
// 遵循的 Rules:
//   .agents/rules/tools_path.md
//   .agents/rules/error-handling.md
// ignore_for_file: unused_element
part of 'tools.dart';

const _resourcePathScanBudget = 5000;

/// relations 不在资源树里，Glob/Grep 打过去只会得到空结果。空结果本身不说明
/// 「没有关系」，所以点明正确入口，避免模型据此判定关系不存在。
const String _relationsNotSearchableHint =
    'Use GraphSearch to search relations.';

/// Grep 没有读到文本字段时，根据搜索范围给出下一步。
String _noSearchableFieldsHint(String rootPath, {required bool hasGlob}) {
  if (hasGlob) {
    return 'No text fields were searched with this glob. Broaden or remove the glob and retry.';
  }
  final ref = _resourceReferencePath(_normalizeResourceDisplayPath(rootPath));
  return 'No text fields were searched under this path. '
      'Read $ref to inspect the resource directly.';
}

/// Glob 在路径下没有任何可列出的子路径时，提示改用 Read 查看资源本身。
String _noListableChildrenHint(String rootPath) {
  final ref = _resourceReferencePath(_normalizeResourceDisplayPath(rootPath));
  return 'No listable child paths exist under this path. '
      'Read $ref to inspect the resource directly.';
}

/// 调用是否冲着 relations 去的：只看调用方显式给的 path / pattern / glob，
/// `**` 这类全局模式不算。
bool _targetsRelations(Iterable<String?> inputs) {
  for (final raw in inputs) {
    if (raw == null) {
      continue;
    }
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    final normalized = trimmed.startsWith('/') ? trimmed.substring(1) : trimmed;
    if (normalized == 'relations' || normalized.startsWith('relations/')) {
      return true;
    }
  }
  return false;
}

class _ResourcePathCollection {
  const _ResourcePathCollection({
    required this.entries,
    required this.truncated,
    required this.scannedPaths,
    this.error,
  });

  final List<_ResourcePathEntry> entries;
  final bool truncated;
  final int scannedPaths;
  final Map<String, dynamic>? error;
}

class _ResourcePathEntry {
  const _ResourcePathEntry(this.target);

  final ParsedPath target;
  String get path => target.displayPath;
  _ResourceField? get field => target._resource?.schema.fields[target.field];
  bool get readableText =>
      field?.readPath == true && field!.type == _ValueType.string;
  bool get searchable => readableText && field!.search.isNotEmpty;
}

mixin _AiToolManagerResourceSearchSupportMixin
    on _AiToolManagerBase, _AiToolManagerReadMixin {
  /// 遍历 [rootPath] 下 Read 可见的资源路径。
  ///
  /// [glob] 非空时只收集匹配的路径。过滤下推到遍历里，预算才不会花在调用方随后
  /// 就要丢掉的字段路径上 —— `/chapters/*/content` 每章从 13 个名额降到 1 个。
  ///
  /// [budget] 为 null 表示不限收集条数，供 Replace 这类「返回体积与扫描量无关」
  /// 的调用方使用；Glob / Grep 要把命中原样返回，仍然受预算约束。
  Future<_ResourcePathCollection> _collectResourcePaths(
    String rootPath, {
    _CompiledResourceGlob? glob,
    int? budget = _resourcePathScanBudget,
  }) async {
    final normalizedRoot = _normalizeResourceDisplayPath(rootPath);
    final root = ParsedPath.parse(
      normalizedRoot,
      schemaLookup: _getCollectionSchema,
    );
    final gate =
        _contentKindGate(root) ??
        (root.isRoot ? null : _resourceOperationGate(root, _ResourceTool.read));
    if (gate != null) {
      return _ResourcePathCollection(
        entries: const [],
        truncated: false,
        scannedPaths: 0,
        error: gate,
      );
    }
    bool targets(String collection) =>
        (root.isRoot || root.collection == collection) &&
        (glob == null ||
            glob.patterns.any(
              (pattern) =>
                  pattern.segments.isNotEmpty &&
                  (pattern.segments.first.recursive ||
                      pattern.segments.first.matches(collection)),
            ));
    if (root.isRoot && glob != null) {
      // 对明确限定为另一种作品资源的模式报错；宽泛模式只遍历本类型可见资源。
      final candidates = _resourceDefinitions.keys.where(targets).toList();
      if (candidates.isNotEmpty &&
          candidates.every(
            (name) =>
                _contentKindGate(
                  ParsedPath.parse(
                    canonicalResourcePath(name),
                    schemaLookup: _getCollectionSchema,
                  ),
                ) !=
                null,
          )) {
        final error = _contentKindGate(
          ParsedPath.parse(
            canonicalResourcePath(candidates.first),
            schemaLookup: _getCollectionSchema,
          ),
        );
        return _ResourcePathCollection(
          entries: const [],
          truncated: false,
          scannedPaths: 0,
          error: error,
        );
      }
    }

    final workId = root.isRoot && novelReader != null
        ? root.targetWorkId
        : null;
    final workPath = workId == null ? null : '/works/$workId';
    // 主目录的元数据用绝对路径返回，glob 也能按相对作品根的字段名匹配。
    final basePath = root.isRoot ? workPath : root.displayPath;
    final relativeBase = basePath == null
        ? null
        : '${_normalizeResourceMatchPath(basePath)}/';
    bool globMatches(String path) {
      if (glob!.matches(path)) {
        return true;
      }
      final normalizedPath = _normalizeResourceMatchPath(path);
      return relativeBase != null &&
          normalizedPath.length > relativeBase.length &&
          normalizedPath.startsWith(relativeBase) &&
          glob.matches(normalizedPath.substring(relativeBase.length));
    }

    final visited = <String>{};
    final out = <_ResourcePathEntry>[];
    var truncated = false;
    Map<String, dynamic>? scanError;

    Future<void> visit(
      ParsedPath parsed, {
      bool isLeaf = false,
      bool collectSelf = true,
      Map<String, dynamic>? resource,
    }) async {
      if (scanError != null || truncated) {
        return;
      }
      final normalized = parsed.displayPath;
      if (!visited.add(normalized)) {
        return;
      }
      if (_contentKindGate(parsed) != null ||
          (!parsed.isRoot &&
              _resourceOperationGate(parsed, _ResourceTool.read) != null)) {
        return;
      }
      // relations 有独立图查询，不展开关系树；作品发现也不属于本作品搜索。
      if (parsed.collection == 'relations' || parsed.isWorksListing) {
        return;
      }
      final queryError = _validateResourceQuery(parsed);
      if (!parsed.isRoot && queryError != null) {
        scanError = queryError;
        return;
      }
      final matched = parsed._resource;
      Map<String, dynamic>? result = resource;
      if (!isLeaf) {
        result = matched?.listing == true
            ? await _readSearchListing(parsed)
            : await _readRawResource(parsed);
        if (result.containsKey('error')) {
          if (matched?.schema.optionalChild == true &&
              normalized != root.displayPath &&
              result['error_code'] == 'not_found') {
            return;
          }
          scanError = {'path': normalized, ...result};
          return;
        }
      }
      if (collectSelf && (glob == null || globMatches(normalized))) {
        if (budget != null && out.length >= budget) {
          truncated = true;
          return;
        }
        out.add(_ResourcePathEntry(parsed));
      }
      if (parsed.hasField) {
        return;
      }
      if (parsed.isRoot) {
        if (workPath != null &&
            (glob == null ||
                _worksDefinition.readFields.any(
                  (field) => globMatches('$workPath/$field'),
                ))) {
          // 扫描起点已代表作品根，直接展开元数据字段，避免重复返回同一个根。
          await visit(parseAiToolPath(workPath), collectSelf: false);
        }
        for (final entry in (result!['entries'] as List)) {
          final path = _collectionPathFromRootEntry(entry);
          if (path == null) {
            continue;
          }
          final child = parseAiToolPath(path);
          if (targets(child.collection)) {
            await visit(child);
          }
        }
        return;
      }
      final isFolder =
          result?['is_folder'] == true || result?['type'] == 'folder';
      if (matched!.listing || isFolder) {
        for (final entry in (result!['entries'] as List).cast<Map>()) {
          final child = parseAiToolPath(entry['path'] as String);
          await visit(
            child,
            isLeaf: entry['is_folder'] != true,
            resource: Map<String, dynamic>.from(entry),
          );
          if (truncated || scanError != null) {
            break;
          }
        }
        return;
      }
      for (final field in matched.schema.readFieldsFor(result!)) {
        await visit(parseAiToolPath('$normalized/$field'), isLeaf: true);
      }
      for (final child in matched.schema.children) {
        if (!child.discoverable) {
          continue;
        }
        await visit(parseAiToolPath('$normalized/${child.segment}'));
      }
    }

    await visit(root);
    return _ResourcePathCollection(
      entries: out,
      truncated: truncated,
      // 遍历过的路径数，不是收集到的 —— glob 下推后 out 只装匹配项，用 out.length
      // 会让 Glob 的 scanned_paths 退化成 total 的副本。
      scannedPaths: visited.length,
      error: scanError,
    );
  }

  /// 按资源定义的父级关联展开完整 listing，不经过 Read 的展示分页。
  Future<Map<String, dynamic>> _readSearchListing(ParsedPath parsed) async {
    final definition = parsed._resource!.schema;
    final parentKey = definition.listing?.parentQuery;
    if (parentKey == null || parsed.queryParameters.containsKey(parentKey)) {
      return _readRawResource(parsed);
    }
    final parentCollection =
        definition.fields[parentKey]!.value.referenceTarget!;
    final parents = await _readSearchListing(parseAiToolPath(parentCollection));
    if (parents.containsKey('error')) {
      return parents;
    }
    final entries = <Map<String, dynamic>>[];
    for (final parent in (parents['entries'] as List).cast<Map>()) {
      final target = parseAiToolPath(
        Uri(
          path: parsed.displayPath,
          queryParameters: {
            ...parsed.queryParameters,
            parentKey: parent['id'] as String,
          },
        ).toString(),
      );
      final result = await _readRawResource(target);
      if (result.containsKey('error')) {
        return result;
      }
      entries.addAll((result['entries'] as List).cast<Map<String, dynamic>>());
    }
    return {'type': 'listing', 'entries': entries};
  }

  Future<Map<String, dynamic>> _readRawResource(ParsedPath parsed) async {
    try {
      return await _readRawResourceUnchecked(parsed);
    } catch (error, stackTrace) {
      _log.error(
        'Resource search read failed path=${parsed.displayPath}',
        error: error,
        stackTrace: stackTrace,
      );
      return {
        'ok': false,
        'error':
            'Resource could not be read. Retry the read before searching again.',
        'error_code': ToolErrorCode.internal.name,
        'path': parsed.displayPath,
      };
    }
  }

  Future<Map<String, dynamic>> _readRawResourceUnchecked(
    ParsedPath parsed,
  ) async {
    if (parsed.isRoot) {
      return _handleRead({'path': '/'});
    }
    final gate = _contentKindGate(parsed);
    if (gate != null) {
      return gate;
    }
    final operationError = _resourceOperationGate(parsed, _ResourceTool.read);
    if (operationError != null) {
      return operationError;
    }
    if (isScreenplayPath(parsed)) {
      return _attachReadResourcePath(
        parsed,
        await _executeScreenplay(
          parsed,
          parsed._resource!.operation(_ResourceTool.read)!,
        ),
      );
    }
    if (isCanvasPath(parsed)) {
      final result = await _executeCanvas(
        parsed,
        parsed._resource!.operation(_ResourceTool.read)!,
      );
      return _attachReadResourcePath(
        parsed,
        _applyListingFilters(result, parsed.queryParameters),
      );
    }
    final result = await _readResource(parsed);
    return _attachReadResourcePath(
      parsed,
      _applyListingFilters(result, parsed.queryParameters),
    );
  }

  Future<({String? text, Map<String, dynamic>? error})> _readResourceString(
    ParsedPath parsed,
  ) async {
    final result = await _readRawResource(parsed);
    if (result.containsKey('error')) {
      return (text: null, error: {'path': parsed.displayPath, ...result});
    }
    final value = result['value'];
    if (value is String) {
      return (text: value, error: null);
    }
    return (text: null, error: null);
  }
}

class _CompiledResourceGlob {
  const _CompiledResourceGlob(this.patterns);

  final List<_CompiledResourceGlobPattern> patterns;

  bool matches(String path) {
    final normalizedPath = _normalizeResourceMatchPath(path);
    final pathSegments = normalizedPath.split('/');
    for (final pattern in patterns) {
      if (pattern.matches(pathSegments)) {
        return true;
      }
    }
    return false;
  }
}

class _CompiledResourceGlobPattern {
  const _CompiledResourceGlobPattern(this.segments);

  final List<_CompiledResourceGlobSegment> segments;

  bool matches(List<String> path) {
    return _matchCompiledGlobSegments(segments, path);
  }
}

class _CompiledResourceGlobSegment {
  const _CompiledResourceGlobSegment.recursive()
    : recursive = true,
      regex = null;

  const _CompiledResourceGlobSegment.pattern(this.regex) : recursive = false;

  final bool recursive;
  final RegExp? regex;

  bool matches(String value) => regex!.hasMatch(value);
}

class _ResourceGlobCompileResult {
  const _ResourceGlobCompileResult({this.glob, this.error});

  final _CompiledResourceGlob? glob;
  final String? error;
}

_ResourceGlobCompileResult _compileResourceGlob(String pattern) {
  if (RegExp(
    r'^/?(?:works/[^/]+/)?(?:novel(?:/|$)|screenplay/(?:seasons|episodes|beats|scenes)(?:/|$))',
  ).hasMatch(pattern)) {
    return const _ResourceGlobCompileResult(
      error: 'Unsupported resource path. Read /_schema for current paths.',
    );
  }
  final compiledPatterns = <_CompiledResourceGlobPattern>[];
  for (final expanded in _expandResourceGlob(pattern)) {
    final normalizedPattern = _normalizeResourceMatchPath(expanded);
    final segments = <_CompiledResourceGlobSegment>[];
    for (final segment in normalizedPattern.split('/')) {
      if (segment == '**') {
        segments.add(const _CompiledResourceGlobSegment.recursive());
        continue;
      }
      final compiled = _compileResourceGlobSegment(segment);
      if (compiled.error != null) {
        return _ResourceGlobCompileResult(error: compiled.error);
      }
      segments.add(_CompiledResourceGlobSegment.pattern(compiled.regex!));
    }
    compiledPatterns.add(_CompiledResourceGlobPattern(segments));
  }
  return _ResourceGlobCompileResult(
    glob: _CompiledResourceGlob(compiledPatterns),
  );
}

({RegExp? regex, String? error}) _compileResourceGlobSegment(String pattern) {
  final buffer = StringBuffer('^');
  for (var i = 0; i < pattern.length; i += 1) {
    final ch = pattern[i];
    if (ch == '*') {
      buffer.write('[^/]*');
    } else if (ch == '?') {
      buffer.write('[^/]');
    } else if (ch == '[') {
      final end = pattern.indexOf(']', i + 1);
      if (end > i) {
        buffer.write(pattern.substring(i, end + 1));
        i = end;
      } else {
        buffer.write(RegExp.escape(ch));
      }
    } else {
      buffer.write(RegExp.escape(ch));
    }
  }
  buffer.write(r'$');
  final source = buffer.toString();
  try {
    return (regex: RegExp(source), error: null);
  } catch (error) {
    return (regex: null, error: 'Invalid glob pattern "$pattern": $error');
  }
}

bool _matchCompiledGlobSegments(
  List<_CompiledResourceGlobSegment> pattern,
  List<String> path,
) {
  if (pattern.isEmpty) {
    return path.isEmpty;
  }
  final head = pattern.first;
  final rest = pattern.sublist(1);
  if (head.recursive) {
    if (rest.isEmpty) {
      return true;
    }
    for (var i = 0; i <= path.length; i += 1) {
      if (_matchCompiledGlobSegments(rest, path.sublist(i))) {
        return true;
      }
    }
    return false;
  }
  if (path.isEmpty) {
    return false;
  }
  if (!head.matches(path.first)) {
    return false;
  }
  return _matchCompiledGlobSegments(rest, path.sublist(1));
}

List<String> _expandResourceGlob(String pattern) {
  final start = pattern.indexOf('{');
  if (start < 0) {
    return [pattern];
  }
  final end = pattern.indexOf('}', start + 1);
  if (end < 0) {
    return [pattern];
  }
  final prefix = pattern.substring(0, start);
  final suffix = pattern.substring(end + 1);
  final body = pattern.substring(start + 1, end);
  final out = <String>[];
  for (final alt in body.split(',')) {
    out.addAll(_expandResourceGlob('$prefix${alt.trim()}$suffix'));
  }
  return out;
}

String _normalizeResourceDisplayPath(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty || trimmed == '/') {
    return '/';
  }
  return canonicalResourcePath(ParsedPath._normalizePath(trimmed));
}

String _normalizeResourceMatchPath(String path) {
  final normalized = ParsedPath._normalizePath(path);
  return normalized.isEmpty ? '/' : normalized;
}

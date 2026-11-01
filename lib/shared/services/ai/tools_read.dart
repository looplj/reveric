// 职责: 按已解析目标读取 AI 资源原值，供 Read、搜索与变更预览共享。
// 关联文件:
//   lib/shared/agent/tools.dart
//   lib/shared/services/ai/tools_support.dart
//   lib/shared/services/working_overlay.dart
// 遵循的 Rules:
//   .agents/rules/json.md
//   .agents/rules/tools_path.md
// ignore_for_file: unused_element
part of 'tools.dart';

const _readDescription = '''读取作品资源或全局只读资源契约。

已知标题、名称、性别或关系条件时，把条件写进 path 的 query 直接读过滤后的 listing，不要读完整集合再筛。用户说「第一章」「第 N 章」用 `?chapter_num=N`；不要写 `?search=第一章`。没有可用 query 时用 Glob 找路径；在长文本里找特定文字用 Grep，再 Read。

长文本按行分页；has_more 为 true 时用返回的 next_offset 继续，不要用很小的窗口反复切片。

示例：{"path": "chapters?chapter_num=1"} → 过滤后的 listing；{"path": "<复制的章节 path>/content", "offset": 0, "limit": 200} → 分页读正文
''';

final _readInputSchema = {
  'type': 'object',
  'properties': {
    'path': {
      'type': 'string',
      'description': '集合根路径、明确支持的 listing query、资源路径或字段路径。',
    },
    'offset': {
      'type': 'integer',
      'minimum': 0,
      'description': '支持分页的列表跳过的条目数或文本字段跳过的行数，默认 0。',
    },
    'limit': {
      'type': 'integer',
      'minimum': 1,
      'description':
          '支持分页的列表最大返回条目数或文本字段最大返回行数。'
          '列表默认 $_defaultReadListLimit、最大 $_maxReadListLimit；'
          '长文本字段默认 $_defaultReadTextLineLimit 行、最大 $_maxReadTextLineLimit 行。',
    },
    'sort': {
      'type': 'string',
      'description':
          '仅用于列表。按字段名排序，如 "title"、"name"、"chapter_num"、"id"；'
          '默认升序，加 "-" 前缀为降序。'
          '省略时章节按 chapter_num 倒序，其余列表保持用户定义的排序。',
    },
  },
  'required': ['path'],
  'additionalProperties': false,
};

const _defaultReadListLimit = 50;
const _maxReadListLimit = 200;
const _defaultReadTextLineLimit = 200;
const _maxReadTextLineLimit = 500;

const _longTextReadFields = {
  'content',
  'description',
  'appearance',
  'biography',
  'personality',
  'current_state',
  'outline',
  'synopsis',
  'text',
  'setup',
  'payoff',
};

Map<String, dynamic> _applyListingFilters(
  Map<String, dynamic> result,
  Map<String, String> queryParameters,
) {
  // 'folder' 是 lore/materials 读文件夹的返回形状（`_readDocument`），entries 是它的
  // 直属子节点。query 在这里的语义就是「过滤直属 children」，与集合根的 listing 一致。
  if (result.containsKey('error') ||
      (result['type'] != 'listing' && result['type'] != 'folder')) {
    return result;
  }

  final rawEntries = result['entries'];
  if (rawEntries is! List) {
    return result;
  }

  // 提前 lower 查询值,避免 per-entry 闭包内重算。
  // 非 String 的 entryValue 与 String 的 query value 比较时不再 lower。
  final lowercasedParams = <String, String>{
    for (final e in queryParameters.entries) e.key: e.value.toLowerCase(),
  };

  final filtered = rawEntries.whereType<Map>().where((entry) {
    for (final param in queryParameters.entries) {
      if (param.key == _listingSearchQueryParam) {
        if (!_listingEntryMatchesSearch(entry, param.value)) {
          return false;
        }
        continue;
      }
      if (!entry.containsKey(param.key)) {
        return false;
      }
      final entryValue = entry[param.key];
      // 精准匹配（字符串比较不区分大小写）
      if (entryValue is String) {
        if (entryValue.toLowerCase() != lowercasedParams[param.key]) {
          return false;
        }
      } else if (entryValue is Iterable) {
        final hasMatch = entryValue.whereType<String>().any(
          (value) => value.toLowerCase() == lowercasedParams[param.key],
        );
        if (!hasMatch) {
          return false;
        }
      } else {
        if (entryValue.toString() != param.value) {
          return false;
        }
      }
    }
    return true;
  }).toList();

  return <String, dynamic>{...result, 'entries': filtered};
}

/// listing 上参与 `search` 包含匹配的短文本键。
///
/// 只扫 listing 行里已经有的字段：角色的 biography 等长文本不进 listing，
/// 也就搜不到 —— 那些用 Grep。`description` 只覆盖画布 listing 那种短说明。
const _listingSearchStringKeys = [
  'title',
  'name',
  'identity',
  'description',
  'label',
];

/// `search` 对 listing 短文本标识做不区分大小写的包含匹配。
bool _listingEntryMatchesSearch(Map<dynamic, dynamic> entry, String rawNeedle) {
  final needle = rawNeedle.trim().toLowerCase();
  if (needle.isEmpty) {
    return false;
  }
  for (final key in _listingSearchStringKeys) {
    final value = entry[key];
    if (value is String && value.toLowerCase().contains(needle)) {
      return true;
    }
  }
  final aliases = entry['aliases'];
  if (aliases is Iterable) {
    for (final alias in aliases.whereType<String>()) {
      if (alias.toLowerCase().contains(needle)) {
        return true;
      }
    }
  }
  final tags = entry['tags'];
  if (tags is Iterable) {
    for (final tag in tags.whereType<String>()) {
      if (tag.toLowerCase().contains(needle)) {
        return true;
      }
    }
  }
  return false;
}

Map<String, dynamic> _applyReadOptions(
  Map<String, dynamic> result, {
  int? offset,
  int? limit,
  String? sort,
  String entriesKey = 'entries',
}) {
  if (result.containsKey('error')) return result;
  if (offset != null && offset < 0) {
    return {
      'ok': false,
      'error': 'offset must be >= 0',
      'error_code': ToolErrorCode.invalid_argument.name,
    };
  }
  if (limit != null && limit < 1) {
    return {
      'ok': false,
      'error': 'limit must be >= 1',
      'error_code': ToolErrorCode.invalid_argument.name,
    };
  }

  final rawEntries = result[entriesKey];
  if (rawEntries is List) {
    final entries = rawEntries
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    if (sort != null && sort.isNotEmpty) {
      final desc = sort.startsWith('-');
      final field = desc ? sort.substring(1) : sort;
      if (field.isNotEmpty) {
        entries.sort((a, b) {
          final cmp = _compareSortValues(a[field], b[field]);
          return desc ? -cmp : cmp;
        });
      }
    }

    final total = entries.length;
    final start = (offset ?? 0).clamp(0, total);
    final rawLimit = limit ?? _defaultReadListLimit;
    final effectiveLimit = rawLimit > _maxReadListLimit
        ? _maxReadListLimit
        : rawLimit;
    final end = (start + effectiveLimit).clamp(start, total);
    final sliced = entries.sublist(start, end);

    final out = <String, dynamic>{
      ...result,
      entriesKey: sliced,
      'total': total,
    };
    out['limit'] = effectiveLimit;
    if (rawLimit != effectiveLimit) out['requested_limit'] = rawLimit;
    out['has_more'] = end < total;
    if (end < total) {
      out['next_offset'] = end;
    }
    return out;
  }

  final value = result['value'];
  final selfPath = _toolResultResourcePath(result);
  final shouldPageText =
      value is String &&
      (offset != null || limit != null || _isLongTextReadPath(selfPath));
  if (value is String && shouldPageText) {
    final lineSpans = _splitLineSpans(value);
    final totalLines = lineSpans.length;
    final start = (offset ?? 0).clamp(0, totalLines);
    final rawLimit = limit ?? _defaultReadTextLineLimit;
    final effectiveLimit = rawLimit > _maxReadTextLineLimit
        ? _maxReadTextLineLimit
        : rawLimit;
    final end = (start + effectiveLimit).clamp(start, totalLines);
    // 按原串 offset 切片，而不是 split + join('\n')：后者会把 CRLF 归一化成 LF、
    // 吞掉末尾换行，模型照抄返回的文本再 Edit 就会 old_text_not_found。
    final sliced = start >= end
        ? ''
        : value.substring(lineSpans[start].start, lineSpans[end - 1].end);

    final out = <String, dynamic>{
      ...result,
      'value': sliced,
      'total_lines': totalLines,
      'start_line': start < totalLines ? start + 1 : 0,
      'end_line': end,
      'limit': effectiveLimit,
      'has_more': end < totalLines,
    };
    if (end < totalLines) out['next_offset'] = end;
    if (rawLimit != effectiveLimit) out['requested_limit'] = rawLimit;
    return out;
  }

  return result;
}

const _readOptionQueryParams = {'offset', 'limit', 'sort'};

class _ReadPathOptions {
  const _ReadPathOptions({
    required this.path,
    this.offset,
    this.limit,
    this.sort,
  });

  final String path;
  final int? offset;
  final int? limit;
  final String? sort;
}

String _safeDecodeReadQueryComponent(String input) {
  try {
    return Uri.decodeComponent(input);
  } catch (_) {
    return input;
  }
}

_ReadPathOptions _splitReadOptionsFromPath(String rawPath) {
  final queryStart = rawPath.indexOf('?');
  if (queryStart < 0) {
    return _ReadPathOptions(path: rawPath);
  }

  final pathPart = rawPath.substring(0, queryStart);
  final queryPart = rawPath.substring(queryStart + 1);
  final params = <String, String>{};
  for (final pair in queryPart.split('&')) {
    if (pair.isEmpty) {
      continue;
    }
    final eqIndex = pair.indexOf('=');
    if (eqIndex > 0) {
      final key = _safeDecodeReadQueryComponent(pair.substring(0, eqIndex));
      final value = _safeDecodeReadQueryComponent(pair.substring(eqIndex + 1));
      if (key.isNotEmpty) {
        params[key] = value;
      }
    } else {
      params[_safeDecodeReadQueryComponent(pair)] = '';
    }
  }

  int? offset;
  int? limit;
  String? sort;
  for (final key in _readOptionQueryParams) {
    if (!params.containsKey(key)) {
      continue;
    }
    final value = params.remove(key)!;
    switch (key) {
      case 'offset':
        offset = int.tryParse(value);
      case 'limit':
        limit = int.tryParse(value);
      case 'sort':
        sort = value;
    }
  }

  if (params.isEmpty) {
    return _ReadPathOptions(
      path: pathPart,
      offset: offset,
      limit: limit,
      sort: sort,
    );
  }

  final rebuiltQuery = params.entries
      .map(
        (entry) =>
            '${Uri.encodeComponent(entry.key)}=${Uri.encodeComponent(entry.value)}',
      )
      .join('&');
  return _ReadPathOptions(
    path: '$pathPart?$rebuiltQuery',
    offset: offset,
    limit: limit,
    sort: sort,
  );
}

bool _isLongTextReadPath(Object? path) {
  if (path is! String || path.isEmpty) return false;
  final segments = path.split('/').where((segment) => segment.isNotEmpty);
  if (segments.isEmpty) return false;
  return _longTextReadFields.contains(segments.last);
}

/// 一行在原串中的 offset 区间：[start, end) 不含行尾换行符。
class _LineSpan {
  const _LineSpan(this.start, this.end);

  final int start;
  final int end;
}

/// 按 CRLF / CR / LF 切出每行在原串中的 offset 区间。
///
/// 与 `LineSplitter` 的区别：调用方可以用 `substring` 取回**原始子串**，
/// 保留 CRLF 与行尾换行。分页读取必须走这条路径，否则模型拿到的是被归一化过的
/// 文本，照抄回来做 Edit 会 `old_text_not_found`。
List<_LineSpan> _splitLineSpans(String value) {
  if (value.isEmpty) {
    return const <_LineSpan>[];
  }
  final spans = <_LineSpan>[];
  var lineStart = 0;
  var i = 0;
  while (i < value.length) {
    final char = value.codeUnitAt(i);
    // 13 = \r, 10 = \n
    if (char == 13) {
      spans.add(_LineSpan(lineStart, i));
      // CRLF 作为一个换行整体跳过。
      i += (i + 1 < value.length && value.codeUnitAt(i + 1) == 10) ? 2 : 1;
      lineStart = i;
      continue;
    }
    if (char == 10) {
      spans.add(_LineSpan(lineStart, i));
      i += 1;
      lineStart = i;
      continue;
    }
    i += 1;
  }
  // 末尾若有换行，LineSplitter 不会产出空尾行，这里保持一致。
  if (lineStart < value.length) {
    spans.add(_LineSpan(lineStart, value.length));
  }
  return spans;
}

int _compareSortValues(Object? a, Object? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  if (a is num && b is num) return a.compareTo(b);
  if (a is bool && b is bool) {
    return (a ? 1 : 0).compareTo(b ? 1 : 0);
  }
  return a.toString().toLowerCase().compareTo(b.toString().toLowerCase());
}

mixin _AiToolManagerReadMixin
    on
        _AiToolManagerBase,
        _AiToolManagerPathHintsMixin,
        _AiToolManagerCanvasMixin,
        _AiToolManagerOutlineMixin {
  Future<Map<String, dynamic>> _handleRead(Map<String, dynamic> input) async {
    final rawPath = _parseStringArgument(
      input['path'],
      defaultValue: '/',
      trim: true,
    );
    final pathOptions = _splitReadOptionsFromPath(rawPath);

    final parsed = ParsedPath.parse(
      pathOptions.path,
      schemaLookup: _getCollectionSchema,
    );
    final offset = _parseIntArgument(input['offset']) ?? pathOptions.offset;
    final limit = _parseIntArgument(input['limit']) ?? pathOptions.limit;
    // sort 是字段名查找键：带空白会查到 null 而静默不排序。
    final inputSort = _parseStringArgument(input['sort'], trim: true);
    final sort = inputSort.isNotEmpty ? inputSort : pathOptions.sort;

    if (parsed.isRoot) {
      return _attachReadResourcePath(parsed, {
        'type': 'directory',
        'entries': _workspaceRootEntries(),
      });
    }

    final contentKindError = _contentKindGate(parsed);
    if (contentKindError != null) {
      return contentKindError;
    }
    final operationError = _resourceOperationGate(parsed, _ResourceTool.read);
    if (operationError != null) {
      return operationError;
    }

    final queryError = _validateResourceQuery(parsed);
    if (queryError != null) {
      return queryError;
    }

    // 画布执行器消费公共匹配的目标与操作；响应继续走公共结果适配。
    // listing（`/canvas`、nodes、edges）走与其他集合相同的 search 过滤；
    // `/canvas/{name}` 不是 listing，query 忽略。过滤必须在 offset/limit 之前。
    if (isCanvasPath(parsed)) {
      var canvasResult = await _executeCanvas(
        parsed,
        parsed._resource!.operation(_ResourceTool.read)!,
      );
      if (parsed.hasQuery &&
          !canvasResult.containsKey('error') &&
          canvasResult['type'] == 'listing') {
        canvasResult = _applyListingFilters(
          canvasResult,
          parsed.queryParameters,
        );
      }
      return _applyReadOptions(
        _attachReadResourcePath(parsed, canvasResult),
        offset: offset,
        limit: limit,
        sort: sort,
      );
    }

    if (isScreenplayPath(parsed)) {
      final result = await _executeScreenplay(
        parsed,
        parsed._resource!.operation(_ResourceTool.read)!,
      );
      return _applyReadOptions(
        _attachReadResourcePath(parsed, result),
        offset: offset,
        limit: limit,
        sort: sort,
        entriesKey: parsed.field == 'cast' ? 'value' : 'entries',
      );
    }

    if (parsed.collection == 'relations') {
      final result = await _readRelation(parsed);
      final enriched = await _enrichNotFoundError(parsed, result);
      return _applyReadOptions(
        _attachReadResourcePath(parsed, enriched),
        offset: offset,
        limit: limit,
        sort: sort,
      );
    }

    // 有查询参数时，如果集合支持查询，先读完整列表再过滤；带 id 的路径忽略查询。
    // 例外：lore/materials 的文件夹路径（`/lore/{folder}?search=`）也过滤，它返回的
    // entries 就是该文件夹的直属 children —— 过滤语义与集合根一致。
    // 上方 hasQuery 校验已保证 parsed.collection 非空且 schema.isQueryable,此处! 安全。
    var result = await _readResource(parsed);
    final schema = _getCollectionSchema(parsed.collection)!;
    final filtersFolderListing =
        schema.usesNamePath && result['is_folder'] == true;
    if (parsed.hasQuery &&
        (!parsed.hasId || filtersFolderListing) &&
        schema.isQueryable &&
        !result.containsKey('error') &&
        (result['type'] == 'listing' || filtersFolderListing)) {
      result = _applyListingFilters(result, parsed.queryParameters);
    }
    final enriched = await _enrichNotFoundError(parsed, result);
    return _applyReadOptions(
      _attachReadResourcePath(parsed, enriched),
      offset: offset,
      limit: limit,
      sort: sort,
    );
  }

  /// Read、搜索和预览共用已解析目标的执行分发。
  Future<Map<String, dynamic>> _readResource(ParsedPath parsed) {
    switch (parsed.collection) {
      case 'story_state':
        return _readStoryState(parsed);
      case 'profile':
        return _readProfile(parsed);
      case 'outlines':
        return _readOutline(parsed);
      case 'lore':
      case 'materials':
        return _readDocument(parsed);
      case 'foreshadowing':
        return _readForeshadowing(parsed);
      case 'relations':
        return _readRelation(parsed);
      case 'characters':
        return _readCharacter(parsed);
      case 'chapters':
        return _readChapter(parsed);
      case 'volumes':
        return _readVolume(parsed);
      case 'locations':
        return _readLocation(parsed);
      case 'skills':
      case 'items':
      case 'factions':
      case 'creatures':
        return _readItem(parsed);
      default:
        return Future.value({
          'error': 'Unknown collection: ${parsed.collection}',
          'error_code': ToolErrorCode.invalid_argument.name,
          'path': parsed.displayPath,
        });
    }
  }

  Future<Map<String, dynamic>> _readProfile(ParsedPath parsed) async {
    final field = parsed.field;
    if (novelReader == null) {
      return AiToolManager._structuredWriteError(
        path: 'profile',
        errorCode: ToolErrorCode.unavailable,
        message: 'Work profile is unavailable in this AI session',
        operation: 'read',
      );
    }
    final novel = await novelReader!.call();
    if (novel == null) {
      return AiToolManager._structuredWriteError(
        path: 'profile',
        errorCode: ToolErrorCode.unavailable,
        message: 'Work profile is unavailable in this AI session',
        operation: 'read',
      );
    }

    if (field != null) {
      final rawTags = novel['tags'];
      final value = switch (field) {
        'title' ||
        'author_name' ||
        'description' ||
        'category' => novel[field] as String? ?? '',
        'tags' => rawTags is List ? rawTags.join(', ') : rawTags as String?,
        _ => novel[field],
      };
      return {'path': 'profile/$field', 'value': value};
    }

    final rawTags = novel['tags'];
    final novelFields = Map<String, dynamic>.from(novel)..remove('word_count');
    return {
      'path': 'profile',
      ...novelFields,
      'title': novel['title'] as String?,
      'author_name': novel['author_name'] as String? ?? '',
      'description': novel['description'] as String? ?? '',
      'category': novel['category'] as String? ?? '',
      'tags': rawTags is List ? rawTags.join(', ') : rawTags as String?,
    };
  }

  /// `story_state` —— 当前作品的累积叙事状态快照。
  ///
  /// 只暴露「当前那一份」：历史版本留在库里供人工排查，不给 AI 路径，
  /// 否则模型会去翻旧快照，反而把已经被修正过的状态读回来。
  /// 还没有任何快照时按空字段返回而非报错，与其他可写字段的读语义一致；
  /// 模型探测该路径不再产生 not_found 噪音。
  ///
  /// 与其他多字段资源一样平铺返回，读回来改几个字就能写回去。
  /// 快照要整份读写，所以不分页（`_applyReadOptions` 只分页 `value`）。
  Future<Map<String, dynamic>> _readStoryState(ParsedPath parsed) async {
    final field = parsed.field;
    final snapshot = await _contentService.getCurrentStateSnapshot();
    if (snapshot == null) {
      final empty = <String, dynamic>{'path': 'story_state', 'content': ''};
      return field == null
          ? empty
          : {'path': 'story_state/$field', 'value': empty[field]};
    }

    final state = <String, dynamic>{
      'path': 'story_state',
      'content': snapshot.content,
    };
    return field == null
        ? state
        : {'path': 'story_state/$field', 'value': state[field]};
  }

  Future<Map<String, dynamic>> _readChapter(ParsedPath parsed) async {
    final id = parsed.id;
    final field = parsed.field;
    if (id == null) {
      final nodes = await _contentService.getChapters();
      final chapters = nodes.where((c) => c.isChapter).toList()
        ..sort((a, b) => (b.chapterNum ?? 0).compareTo(a.chapterNum ?? 0));

      return {
        'type': 'listing',
        'entries': chapters
            .map(
              (c) => {
                'id': c.id,
                'title': c.title ?? '',
                'chapter_num': c.chapterNum,
                'word_count': c.wordCount,
                'status': c.stat,
                // 张力/情绪进 listing：全书节奏一眼可见，不必逐章读详情。
                // events 是重字段，只在单章详情返回，否则 listing 会被撑爆。
                'tension': c.tension,
                'emotion': c.emotion ?? <String>[],
                'volume_id': c.parentId,
              },
            )
            .toList(),
      };
    }

    final chapter = await _contentService.getChapterById(id);
    if (chapter == null || !chapter.isChapter) {
      return AiToolManager._structuredWriteError(
        path: 'chapters/$id',
        errorCode: ToolErrorCode.not_found,
        message: 'Chapter not found: $id',
        operation: 'read',
      );
    }

    if (field == 'relations') {
      final relations = await _contentService.entityRelationsService
          .getRelationsForChapterEvidence(id);
      return {
        'path': parsed.displayPath,
        'value': relations.map(_relationToJson).toList(),
      };
    }

    final values = <String, dynamic>{
      'id': chapter.id,
      'title': chapter.title ?? '',
      'chapter_num': chapter.chapterNum,
      'outline': chapter.outline,
      'brief': chapter.brief,
      'content': chapter.content,
      'word_count': chapter.wordCount,
      'status': chapter.stat,
      'tension': chapter.tension,
      'emotion': chapter.emotion ?? <String>[],
      'events': chapter.events ?? <Map<String, dynamic>>[],
      'volume_id': chapter.parentId,
    };
    if (field == null) {
      return values;
    }
    return {
      'path': parsed.displayPath,
      'value': field == 'emotion' || field == 'events'
          ? values[field] ?? []
          : values[field],
    };
  }

  Future<Map<String, dynamic>> _readVolume(ParsedPath parsed) async {
    final id = parsed.id;
    final field = parsed.field;
    if (id == null) {
      final nodes = await _contentService.getChapters();
      final volumes = nodes.where((c) => c.isVolume).toList();
      return {
        'type': 'listing',
        'entries': volumes
            .map(
              (v) => {
                'id': v.id,
                'title': v.title ?? '',
                'volume_num': v.volumeNum,
              },
            )
            .toList(),
      };
    }

    final volume = await _contentService.getChapterById(id);
    if (volume == null || !volume.isVolume) {
      return AiToolManager._structuredWriteError(
        path: 'volumes/$id',
        errorCode: ToolErrorCode.not_found,
        message: 'Volume not found: $id',
        operation: 'read',
      );
    }

    final values = <String, dynamic>{
      'id': volume.id,
      'title': volume.title ?? '',
      'outline': volume.outline,
      'volume_num': volume.volumeNum,
    };
    return field == null
        ? values
        : {'path': parsed.displayPath, 'value': values[field]};
  }

  Future<Map<String, dynamic>> _readCharacter(ParsedPath parsed) async {
    final id = parsed.id;
    final field = parsed.field;
    if (id == null) {
      final entries = await _contentService.getCharacterProfiles();
      return {
        'type': 'listing',
        'entries': entries
            .map(
              (e) => {
                'id': e.id,
                'name': e.name,
                'role': e.role,
                'aliases': e.aliases,
                'tags': e.tags,
                'identity': e.identity,
                'gender': e.gender,
                'age': e.age,
              },
            )
            .toList(),
      };
    }

    final entry = await _contentService.getCharacterProfileById(id);
    if (entry == null) {
      return AiToolManager._structuredWriteError(
        path: 'characters/$id',
        errorCode: ToolErrorCode.not_found,
        message: 'Not found: $id',
        operation: 'read',
      );
    }

    final values = _characterProfileValues(entry);
    if (field == null || field == 'skills') {
      values['skills'] = await _readCharacterSkills(id);
    }
    return field == null
        ? values
        : {'path': parsed.displayPath, 'value': values[field]};
  }

  Map<String, dynamic> _characterProfileValues(CharacterProfile entry) {
    return {
      'id': entry.id,
      'name': entry.name,
      'role': entry.role,
      'gender': entry.gender,
      'aliases': entry.aliases,
      'tags': entry.tags,
      'identity': entry.identity,
      'age': entry.age,
      'motivation': entry.motivation,
      'arc': entry.arc,
      'biography': entry.biography,
      'personality': entry.personality,
      'description': entry.description,
      'appearance': entry.appearance,
      'behavior_tags': entry.behaviorTags.map((tag) => tag.toJson()).toList(),
      'current_state': entry.currentState,
      'first_appear_chapter_id': entry.firstAppearChapterId,
      'avatar_asset_id': entry.avatarAssetId,
      'photos': entry.photos?.map((photo) => photo.toJson()).toList() ?? [],
    };
  }

  Future<Map<String, dynamic>> _readForeshadowing(ParsedPath parsed) async {
    final id = parsed.id;
    final field = parsed.field;
    if (id == null) {
      final entries = await _contentService.getForeshadowings();
      return {
        'type': 'listing',
        'entries': entries.map((e) => {'id': e.id, 'title': e.title}).toList(),
      };
    }

    final entry = await _contentService.getForeshadowingById(id);
    if (entry == null) {
      return AiToolManager._structuredWriteError(
        path: 'foreshadowing/$id',
        errorCode: ToolErrorCode.not_found,
        message: 'Not found: $id',
        operation: 'read',
      );
    }

    final values = _foreshadowingValues(entry);
    return field == null
        ? values
        : {'path': parsed.displayPath, 'value': values[field]};
  }

  Map<String, dynamic> _foreshadowingValues(Foreshadowing entry) {
    return {
      'id': entry.id,
      'title': entry.title,
      'setup': entry.setup,
      'payoff': entry.payoff,
      'status': entry.status,
      'setup_chapter_id': entry.setupChapterId,
      'payoff_chapter_id': entry.payoffChapterId,
      'setup_scene_id': entry.setupSceneId,
      'payoff_scene_id': entry.payoffSceneId,
    };
  }

  Future<Map<String, dynamic>> _readLocation(ParsedPath parsed) async {
    final id = parsed.id;
    final field = parsed.field;
    if (id == null) {
      final entries = await _contentService.locationsService.getLocations();
      return {
        'type': 'listing',
        'entries': entries
            .map(
              (e) => {
                'id': e.id,
                'name': e.name,
                'type': e.type,
                'parent_id': e.parentId,
              },
            )
            .toList(),
      };
    }

    final entry = await _contentService.locationsService.getLocationById(id);
    if (entry == null) {
      return AiToolManager._structuredWriteError(
        path: 'locations/$id',
        errorCode: ToolErrorCode.not_found,
        message: 'Not found: $id',
        operation: 'read',
      );
    }

    final values = <String, dynamic>{
      'id': entry.id,
      'name': entry.name,
      'description': entry.description,
      'type': entry.type,
      'parent_id': entry.parentId,
      'photos': entry.photos?.map((photo) => photo.toJson()).toList() ?? [],
    };
    return field == null
        ? values
        : {'path': parsed.displayPath, 'value': values[field]};
  }

  Future<Map<String, dynamic>> _readRelation(ParsedPath parsed) async {
    if (parsed.resourceSegment == 'change_logs') {
      return _readToolRelationHistory(_contentService, parsed);
    }
    final id = parsed.id;
    final queryParameters = parsed.queryParameters;
    // 如果有查询参数，使用过滤查询
    if (id == null && queryParameters.isNotEmpty) {
      return _queryRelations(queryParameters);
    }

    if (id == null) {
      final allRelations = await _contentService.entityRelationsService
          .getAllRelations();
      return {
        'type': 'listing',
        'entries': allRelations.map(_relationToJson).toList(),
      };
    }

    final relation = await _contentService.entityRelationsService
        .getRelationSummaryById(id);
    if (relation == null) {
      return AiToolManager._structuredWriteError(
        path: 'relations/$id',
        errorCode: ToolErrorCode.not_found,
        message: 'Relation not found: $id',
        operation: 'read',
      );
    }
    final field = parsed.field;
    if (field != null) {
      return {
        'path': parsed.displayPath,
        'value': _relationToJson(relation)[field],
      };
    }
    try {
      final detail = await _contentService.entityRelationsService
          .getRelationById(id);
      if (detail == null) {
        throw const RelationServiceException(
          'not_found',
          'Relation was not found.',
        );
      }
      return {
        ..._relationToJson(_relationSummary(detail)),
        'history_count': detail.changeLogs
            .where((s) => s.kind == RelationSnapshotKind.change)
            .length,
      };
    } catch (error) {
      return _relationFailure(parsed, error, 'read');
    }
  }

  Future<Map<String, dynamic>> _queryRelations(
    Map<String, String> query,
  ) async {
    final service = _contentService.entityRelationsService;
    final results = await service.queryRelationSummaries(
      sourceType: query['source_type'],
      sourceId: query['source_id'],
      targetType: query['target_type'],
      targetId: query['target_id'],
      relationType: query['relation_type'],
      chapterId: query['chapter_id'],
      sceneId: query['scene_id'],
      status: query['status'],
    );

    return {
      'type': 'listing',
      'entries': results.map(_relationToJson).toList(),
      'query': query,
    };
  }

  Future<Map<String, dynamic>> _readItem(ParsedPath parsed) async {
    final collection = parsed.collection;
    final itemType = parsed._resource!.schema.itemType!;
    final id = parsed.id;
    final field = parsed.field;
    if (id == null) {
      final entries = await _contentService.getItemsByType(itemType);
      return {
        'type': 'listing',
        'entries': entries.map((e) => {'id': e.id, 'title': e.title}).toList(),
      };
    }

    final entry = await _contentService.getItemById(id);
    if (entry == null) {
      return AiToolManager._structuredWriteError(
        path: '$collection/$id',
        errorCode: ToolErrorCode.not_found,
        message: 'Not found: $id',
        operation: 'read',
      );
    }
    if (entry.type != itemType) {
      return AiToolManager._structuredWriteError(
        path: '$collection/$id',
        errorCode: ToolErrorCode.unsupported,
        message: 'Entry $id does not belong to $collection',
        operation: 'read',
      );
    }
    final values = <String, dynamic>{
      'id': entry.id,
      'title': entry.title,
      'content': entry.content,
      'category': entry.category,
    };
    return field == null
        ? values
        : {'path': parsed.displayPath, 'value': values[field]};
  }

  Future<Map<String, dynamic>> _readDocument(ParsedPath parsed) async {
    final collection = parsed.collection;
    final documentType = parsed._resource!.schema.documentType!;
    final namePath = parsed.namePath;
    final field = parsed.field;
    if (namePath.isEmpty) {
      final documents = await _contentService.documentsService.getChildren(
        null,
      );
      final filteredDocs = documents.where((d) => d.type == documentType);

      return {
        'type': 'listing',
        'entries': await Future.wait(
          filteredDocs.map(
            (d) async => {
              'id': d.id,
              'title': d.title,
              'is_folder': d.isFolder,
            },
          ),
        ),
      };
    }

    final document = await _contentService.documentsService
        .getDocumentByNamePath(type: documentType, namePath: namePath);
    if (document == null) {
      final pathStr = namePath.join('/');
      return AiToolManager._structuredWriteError(
        path: '$collection/$pathStr',
        errorCode: ToolErrorCode.not_found,
        message: 'Not found: $pathStr',
        operation: 'read',
      );
    }
    if (document.isFolder) {
      if (field != null) {
        return AiToolManager._structuredWriteError(
          path: '$collection/${namePath.join('/')}/$field',
          errorCode: ToolErrorCode.failed_precondition,
          message:
              'Cannot read field "$field" from a folder. Use "$collection/${namePath.join('/')}" to list folder contents.',
          operation: 'read',
        );
      }

      final children = await _contentService.documentsService.getChildren(
        document.id,
      );
      final filteredChildren = children.where((d) => d.type == documentType);

      return {
        'id': document.id,
        'title': document.title,
        'is_folder': true,
        'type': 'folder',
        'entries': await Future.wait(
          filteredChildren.map(
            (d) async => {
              'id': d.id,
              'title': d.title,
              'is_folder': d.isFolder,
            },
          ),
        ),
      };
    }

    final values = <String, dynamic>{
      'id': document.id,
      'title': document.title,
      'content': document.content,
      'category': document.category,
      'is_folder': false,
    };
    return field == null
        ? values
        : {'path': parsed.displayPath, 'value': values[field]};
  }

  Future<Map<String, dynamic>> _readOutline(ParsedPath parsed) async {
    if (!parsed.isOutlineBeat && parsed.isResourceListing) {
      final outlines = await _contentService.outlineService.getAll();
      return {
        'type': 'listing',
        'entries': outlines
            .map(
              (o) => {
                'id': o.documentId,
                'title': o.title,
                'start_chapter_num': o.startChapterNum,
                'is_folder': false,
              },
            )
            .toList(),
      };
    }
    final located = await _locateOutline(parsed);
    if (located.error != null) {
      return located.error!;
    }
    final target = located.target!;
    final outline = target.outline;
    if (parsed.isOutlineBeat) {
      return _readOutlineBeatPath(target);
    }
    final values = <String, dynamic>{
      'id': outline.documentId,
      'title': outline.title,
      'content': outline.content,
      'status': outline.status,
      'start_chapter_num': outline.startChapterNum,
      'is_folder': false,
      'beats': outline.beats.map(_outlineBeatToJson).toList(growable: false),
    };
    return parsed.field == null ? values : {'value': values[parsed.field]};
  }

  Map<String, dynamic> _readOutlineBeatPath(_LocatedOutlineTarget target) {
    final parsed = target.parsed;
    if (parsed.isResourceListing) {
      return {
        'type': 'listing',
        'path': parsed.displayPath,
        'entries': target.outline.beats
            .asMap()
            .entries
            .map(
              (entry) => {
                'index': entry.key,
                ..._outlineBeatToJson(entry.value),
                'path': '${parsed.displayPath}/${entry.value.id}',
              },
            )
            .toList(growable: false),
      };
    }
    final values = _outlineBeatToJson(target.beat!);
    return parsed.field == null
        ? {'path': parsed.displayPath, 'index': target.beatIndex, ...values}
        : {'path': parsed.displayPath, 'value': values[parsed.field]};
  }

  Map<String, dynamic> _outlineBeatToJson(OutlineBeatDraft beat) {
    return {
      'id': beat.id,
      'title': beat.title,
      'content': beat.content,
      'status': beat.status,
      'chapter_count': beat.chapterCount,
    };
  }

  Future<List<Map<String, dynamic>>> _readCharacterSkills(
    String characterId,
  ) async {
    final network = await _contentService.entityRelationsService
        .getCharacterNetwork(characterId);
    final relations = network['skills']?.cast<RelationSummary>() ?? [];
    if (relations.isEmpty) return [];

    final skillIds = relations
        .map((r) => r.sourceType == entityTypeSkill ? r.sourceId : r.targetId)
        .toSet();

    final skills = await _contentService.getItemsByIds(skillIds);
    final skillById = {for (final s in skills) s.id: s};

    final result = <Map<String, dynamic>>[];
    for (final r in relations) {
      final skillId = r.sourceType == entityTypeSkill ? r.sourceId : r.targetId;
      final skill = skillById[skillId];
      if (skill == null || skill.type != 'skill') {
        continue;
      }
      result.add({
        'name': skill.title,
        'path': _resourceReferencePath('skills/${skill.id}'),
        'relation_type': r.relationType,
      });
    }
    return result;
  }
}

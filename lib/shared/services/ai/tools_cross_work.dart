// 职责: 冻结 AI 资源调用的作品作用域与依赖，管理跨作品只读 lease 并序列化结果引用。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_support.dart
//   lib/shared/database/app_database.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/services/novel_content.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/error-handling.md
//   .agents/rules/tools_path.md
part of 'tools.dart';

final Object _resourceCallContextZoneKey = Object();

_ResourceCallContext? get _currentResourceCallContext =>
    Zone.current[_resourceCallContextZoneKey] as _ResourceCallContext?;

enum _ResourceWorkKind {
  novel,
  screenplay,
  canvas;

  static _ResourceWorkKind? parse(String value) => switch (value) {
    contentKindNovel => novel,
    contentKindScreenplay => screenplay,
    contentKindCanvas => canvas,
    _ => null,
  };
}

/// 单次调用的作品身份和类型；绝对地址不等于跨作品权限。
class _ResourceScope {
  const _ResourceScope({
    required this.currentWorkId,
    required this.targetWorkId,
    required this.kind,
    required this.absolutePaths,
  });

  final String? currentWorkId;
  final String? targetWorkId;
  final _ResourceWorkKind kind;
  final bool absolutePaths;

  bool get isOtherWork => targetWorkId != currentWorkId;

  _ResourceReference reference(String path) =>
      _ResourceReference(workId: targetWorkId, localPath: path);
}

/// 保留现有会话执行上下文与 lease 生命周期，只冻结本次调用的资源依赖。
class _ResourceCallContext {
  const _ResourceCallContext({
    required this.scope,
    required this.operation,
    required this.service,
    required this.novelReader,
    required this.executionContext,
  });

  final _ResourceScope scope;
  final String operation;
  final NovelContentService service;
  final AiNovelReader? novelReader;
  final ToolExecutionContext? executionContext;
}

/// 仅资源引用参与路径序列化，业务 payload 不经过路径推断。
class _ResourceReference {
  const _ResourceReference({required this.workId, required this.localPath});

  final String? workId;
  final String localPath;

  String serialize({required bool absolute}) => absolute && workId != null
      ? _prefixWorkPath(localPath, workId!)
      : canonicalResourcePath(localPath);
}

String _resourceReferencePath(String path) {
  final scope = _currentResourceCallContext?.scope;
  return scope == null
      ? canonicalResourcePath(path)
      : scope.reference(path).serialize(absolute: scope.absolutePaths);
}

/// 可被 AI 发现和读取的本地作品描述。
class CrossWorkDescriptor {
  const CrossWorkDescriptor({
    required this.workId,
    required this.title,
    required this.databasePath,
    required this.contentKind,
    required this.novelMetadata,
  });

  final String workId;
  final String title;
  final String databasePath;
  final String contentKind;
  final Map<String, dynamic> novelMetadata;

  AiNovelReader get novelReader =>
      () async => {...novelMetadata, 'content_kind': contentKind};

  Map<String, dynamic> toListingEntry() {
    return {
      ...novelMetadata,
      'content_kind': contentKind,
      'id': workId,
      'path': '/works/$workId',
    };
  }
}

/// 一次跨作品内容库借用；[release] 同步且幂等。
class CrossWorkLease {
  CrossWorkLease({
    required this.work,
    required this.service,
    required this._release,
  });

  final CrossWorkDescriptor work;
  final NovelContentService service;
  final void Function() _release;
  bool _released = false;

  String get workId => work.workId;
  AiNovelReader get novelReader => work.novelReader;

  void release() {
    if (_released) {
      return;
    }
    _released = true;
    _release();
  }
}

/// Tool Manager 所需的跨作品发现与只读内容库获取契约。
abstract interface class CrossWorkAccess {
  Future<List<CrossWorkDescriptor>> listWorks();

  String get currentWorkId;

  Future<CrossWorkLease> acquire(String workId);
}

class CrossWorkAccessException implements Exception {
  const CrossWorkAccessException(this.errorCode, this.message);

  final String errorCode;
  final String message;

  @override
  String toString() => '$errorCode: $message';
}

typedef CrossWorkDatabaseOpener = NovelContentDatabase Function(String path);

/// 从应用主库解析作品，并从内容库缓存工厂借用只读连接。
class CrossWorkResolver implements CrossWorkAccess {
  CrossWorkResolver({
    required this._appDatabase,
    required this._currentDatabasePath,
    required this._currentContentService,
    required String currentWorkId,
    this._databaseOpener = NovelContentDatabase.new,
  }) : _currentWorkId = currentWorkId.trim();

  final AppDatabase _appDatabase;
  final String _currentDatabasePath;
  final NovelContentService _currentContentService;
  final String _currentWorkId;
  final CrossWorkDatabaseOpener _databaseOpener;

  @override
  Future<List<CrossWorkDescriptor>> listWorks() async {
    final novels = await _appDatabase.novelDao.getAll();
    final current = novels
        .where((novel) => novel.id == _currentWorkId)
        .firstOrNull;
    final works = <CrossWorkDescriptor>[];
    for (final novel in novels) {
      final storedPath = novel.contentDatabasePath?.trim();
      if (novel.draft || storedPath == null || storedPath.isEmpty) {
        continue;
      }
      final resolvedPath = RevericPaths.resolveDatabasePath(storedPath);
      if (!File(resolvedPath).existsSync()) {
        continue;
      }
      works.add(
        _descriptorForNovel(
          novel,
          resolvedPath,
          relationship: current?.sourceNovelId == novel.id
              ? current?.type
              : null,
        ),
      );
    }
    return works;
  }

  @override
  String get currentWorkId => _currentWorkId;

  @override
  Future<CrossWorkLease> acquire(String workId) async {
    final normalizedWorkId = workId.trim();
    try {
      return await _acquireWork(normalizedWorkId);
    } on CrossWorkAccessException {
      rethrow;
    } catch (error, stackTrace) {
      _log.error(
        'cross-work content access failed workId=$normalizedWorkId',
        error: error,
        stackTrace: stackTrace,
      );
      throw CrossWorkAccessException(
        'work_unavailable',
        'Work content is unavailable: $normalizedWorkId',
      );
    }
  }

  Future<CrossWorkLease> _acquireWork(String normalizedWorkId) async {
    if (normalizedWorkId.isEmpty) {
      throw const CrossWorkAccessException(
        'work_not_found',
        'Work was not found.',
      );
    }

    final novel = await _appDatabase.novelDao.get(normalizedWorkId);
    final storedPath = novel?.contentDatabasePath?.trim();
    if (novel == null || novel.draft) {
      throw CrossWorkAccessException(
        'work_not_found',
        'Work was not found: $normalizedWorkId',
      );
    }

    if (storedPath == null || storedPath.isEmpty) {
      throw CrossWorkAccessException(
        'work_unavailable',
        'Work content is unavailable: $normalizedWorkId',
      );
    }
    final resolvedPath = RevericPaths.resolveDatabasePath(storedPath);
    final descriptor = _descriptorForNovel(novel, resolvedPath);
    if (_isCurrentNovel(novel.id, storedPath)) {
      return CrossWorkLease(
        work: descriptor,
        service: _currentContentService,
        release: () {},
      );
    }
    if (!File(resolvedPath).existsSync()) {
      throw CrossWorkAccessException(
        'work_unavailable',
        'Work content is unavailable: $normalizedWorkId',
      );
    }

    NovelContentDatabase? database;
    try {
      database = _databaseOpener(resolvedPath);
      await database.customSelect('SELECT 1').getSingle();
      final acquired = database;
      return CrossWorkLease(
        work: descriptor,
        service: NovelContentService(acquired),
        release: () {
          unawaited(
            acquired.close().catchError((Object error, StackTrace stackTrace) {
              _log.error(
                'cross-work database close failed workId=$normalizedWorkId',
                error: error,
                stackTrace: stackTrace,
              );
            }),
          );
        },
      );
    } catch (error, stackTrace) {
      if (database != null) {
        try {
          await database.close();
        } catch (closeError, closeStackTrace) {
          _log.error(
            'cross-work database cleanup failed workId=$normalizedWorkId',
            error: closeError,
            stackTrace: closeStackTrace,
          );
        }
      }
      _log.error(
        'cross-work database unavailable workId=$normalizedWorkId',
        error: error,
        stackTrace: stackTrace,
      );
      if (error is CrossWorkAccessException) {
        rethrow;
      }
      throw CrossWorkAccessException(
        'work_unavailable',
        'Work content is unavailable: $normalizedWorkId',
      );
    }
  }

  bool _isCurrentNovel(String novelId, String storedPath) {
    return novelId == _currentWorkId ||
        _sameDatabasePath(storedPath, _currentDatabasePath);
  }

  bool _sameDatabasePath(String left, String right) {
    final normalizedLeft = p.normalize(
      File(RevericPaths.resolveDatabasePath(left)).absolute.path,
    );
    final normalizedRight = p.normalize(
      File(RevericPaths.resolveDatabasePath(right)).absolute.path,
    );
    if (Platform.isWindows) {
      return normalizedLeft.toLowerCase() == normalizedRight.toLowerCase();
    }
    return normalizedLeft == normalizedRight;
  }

  CrossWorkDescriptor _descriptorForNovel(
    Novel novel,
    String databasePath, {
    String? relationship,
  }) {
    return CrossWorkDescriptor(
      workId: novel.id,
      title: novel.title,
      databasePath: databasePath,
      contentKind: novel.contentKind,
      novelMetadata: {
        'title': novel.title,
        'author_name': novel.authorName,
        'description': novel.description,
        'category': novel.category,
        'status': novel.status,
        'word_count': novel.wordCount,
        'tags': novel.tags,
        if (novel.sourceNovelId != null) 'source_novel_id': novel.sourceNovelId,
        'relationship': ?relationship,
      },
    );
  }
}

class _CrossWorkLeaseEntry {
  _CrossWorkLeaseEntry(this.lease);

  final CrossWorkLease lease;
  int inFlight = 0;
}

class _CrossWorkScope {
  const _CrossWorkScope({this.workId, this.error});

  final String? workId;
  final Map<String, dynamic>? error;
}

class _SinglePathWorkScope {
  const _SinglePathWorkScope.none() : workId = null, ambiguous = false;
  const _SinglePathWorkScope.target(this.workId) : ambiguous = false;
  const _SinglePathWorkScope.ambiguous() : workId = null, ambiguous = true;

  final String? workId;
  final bool ambiguous;
}

mixin _AiToolManagerCrossWorkMixin
    on
        _AiToolManagerBase,
        _AiToolManagerReadMixin,
        _AiToolManagerGlobMixin,
        _AiToolManagerGrepMixin,
        _AiToolManagerGraphMixin {
  final Map<String, Future<_CrossWorkLeaseEntry>> _crossWorkAcquisitions = {};
  bool _crossWorkDisposed = false;

  Future<Map<String, dynamic>> _handleCrossWorkRead(
    Map<String, dynamic> input,
  ) async {
    final rawPath = _parseStringArgument(
      input['path'],
      defaultValue: '/',
      trim: true,
    );
    final options = _splitReadOptionsFromPath(rawPath);
    final parsed = ParsedPath.parse(
      options.path,
      schemaLookup: _getCollectionSchema,
    );

    if (parsed.collection == '_schema') {
      return _readSchemaContract(parseAiToolPath(rawPath));
    }

    // `ParsedPath.isRoot` 对 `/works/{work_id}` 也为 true，因为它表示目标作品内的
    // 空资源路径；只有没有 workId 的 `/` 才是文件系统全局根。
    if (parsed.isRoot && parsed.workId == null) {
      return _applyReadOptions(
        {
          'type': 'directory',
          'path': '/',
          'entries': _buildFilesystemRootDirectoryEntries(),
        },
        offset: _parseIntArgument(input['offset']) ?? options.offset,
        limit: _parseIntArgument(input['limit']) ?? options.limit,
        sort: _parseStringArgument(input['sort'], trim: true).isNotEmpty
            ? _parseStringArgument(input['sort'], trim: true)
            : options.sort,
      );
    }

    if (parsed.isWorksListing) {
      if (parsed.hasQuery) {
        return {
          'ok': false,
          'error': 'Query parameters are not supported for /works.',
          'error_code': ToolErrorCode.unsupported.name,
          'path': '/works',
        };
      }
      return _readWorksListing(input, options);
    }
    final workId = parsed.workId;
    if (workId == null) {
      return _withCurrentResourceContext('Read', () => _handleRead(input));
    }

    final localInput = Map<String, dynamic>.from(input);
    localInput['path'] = _stripWorkPrefix(rawPath, workId);
    return _withCrossWork(
      workId,
      'Read',
      () => _handleRead(localInput),
      resultTarget: parsed,
    );
  }

  Future<Map<String, dynamic>> _readWorksListing(
    Map<String, dynamic> input,
    _ReadPathOptions options,
  ) async {
    final access = crossWorkAccess;
    if (access == null) {
      return _crossWorkUnavailable('/works');
    }
    try {
      final works = await access.listWorks();
      return _applyReadOptions(
        {
          'type': 'listing',
          'path': '/works',
          'entries': works.map((work) => work.toListingEntry()).toList(),
        },
        offset: _parseIntArgument(input['offset']) ?? options.offset,
        limit: _parseIntArgument(input['limit']) ?? options.limit,
        sort: _parseStringArgument(input['sort'], trim: true).isNotEmpty
            ? _parseStringArgument(input['sort'], trim: true)
            : options.sort,
      );
    } catch (error, stackTrace) {
      _log.error(
        'cross-work listing failed',
        error: error,
        stackTrace: stackTrace,
      );
      return {
        'ok': false,
        'error': 'Local works are unavailable.',
        'error_code': ToolErrorCode.unavailable.name,
        'path': '/works',
      };
    }
  }

  Future<Map<String, dynamic>> _handleCrossWorkGlob(
    Map<String, dynamic> input,
  ) async {
    final scope = _resolveCrossWorkScope([
      _parseStringArgument(input['path'], trim: true),
      _parseStringArgument(input['pattern'], trim: true),
    ]);
    if (scope.error != null) {
      return scope.error!;
    }
    final workId = scope.workId;
    if (workId == null) {
      return _withCurrentResourceContext('Glob', () => _handleGlob(input));
    }
    final localInput = Map<String, dynamic>.from(input);
    for (final key in const ['path', 'pattern']) {
      final value = _parseStringArgument(localInput[key], trim: true);
      if (_pathWorkScope(value).workId == workId) {
        localInput[key] = _stripWorkPrefix(value, workId);
      }
    }
    return _withCrossWork(workId, 'Glob', () => _handleGlob(localInput));
  }

  Future<Map<String, dynamic>> _handleCrossWorkGrep(
    Map<String, dynamic> input,
  ) async {
    final scope = _resolveCrossWorkScope([
      _parseStringArgument(input['path'], trim: true),
      _parseStringArgument(input['glob'], trim: true),
    ]);
    if (scope.error != null) {
      return scope.error!;
    }
    final workId = scope.workId;
    if (workId == null) {
      return _withCurrentResourceContext('Grep', () => _handleGrep(input));
    }
    final localInput = Map<String, dynamic>.from(input);
    for (final key in const ['path', 'glob']) {
      final value = _parseStringArgument(localInput[key], trim: true);
      if (_pathWorkScope(value).workId == workId) {
        localInput[key] = _stripWorkPrefix(value, workId);
      }
    }
    return _withCrossWork(workId, 'Grep', () => _handleGrep(localInput));
  }

  Future<Map<String, dynamic>> _handleCrossWorkGraphSearch(
    Map<String, dynamic> input,
  ) async {
    final workId = _parseOptionalStringArgument(input['work_id']);
    if (workId == null) {
      return _withCurrentResourceContext(
        'GraphSearch',
        () => _handleGraphSearch(input),
      );
    }

    final localInput = Map<String, dynamic>.from(input)..remove('work_id');
    return _withCrossWork(
      workId,
      'GraphSearch',
      () => _handleGraphSearch(localInput),
    );
  }

  Future<Map<String, dynamic>> _handleCrossWorkMutation({
    required String toolName,
    required Map<String, dynamic> input,
    required Future<Map<String, dynamic>> Function(
      Map<String, dynamic> localInput,
    )
    run,
  }) async {
    final collection = parseAiToolPath(
      _parseStringArgument(input['path']),
    ).collection;
    if (collection == '_schema') {
      return _schemaError(
        ToolErrorCode.permission_denied,
        'Resource contracts are read-only.',
      );
    }
    final currentWorkId = crossWorkAccess?.currentWorkId ?? workId;
    String? targetWorkId;
    for (final key in const ['path', 'glob']) {
      final value = _parseStringArgument(input[key], trim: true);
      final scope = _pathWorkScope(value);
      if (scope.ambiguous) {
        return _crossWorkMutationDenied(
          toolName,
          value,
          currentWorkId: currentWorkId,
        );
      }
      final workId = scope.workId;
      if (workId == null) {
        continue;
      }
      if (currentWorkId == null || workId != currentWorkId) {
        return _crossWorkMutationDenied(
          toolName,
          value,
          currentWorkId: currentWorkId,
        );
      }
      targetWorkId = workId;
    }

    if (targetWorkId == null) {
      return _withCurrentResourceContext(toolName, () => run(input));
    }

    final localWorkId = currentWorkId!;
    final localInput = Map<String, dynamic>.from(input);
    for (final key in const ['path', 'glob']) {
      final value = _parseStringArgument(localInput[key], trim: true);
      if (_pathWorkScope(value).workId == localWorkId) {
        localInput[key] = _stripWorkPrefix(value, localWorkId);
      }
    }
    return _withCurrentResourceContext(
      toolName,
      () => run(localInput),
      absolutePaths: true,
    );
  }

  Future<Map<String, dynamic>> _withCrossWork(
    String workId,
    String operation,
    Future<Map<String, dynamic>> Function() run, {
    ParsedPath? resultTarget,
  }) async {
    if (_crossWorkDisposed) {
      return _crossWorkDisposedResult(workId);
    }
    if (workId == (crossWorkAccess?.currentWorkId ?? this.workId)) {
      return _withCurrentResourceContext(
        operation,
        run,
        absolutePaths: true,
        resultTarget: resultTarget,
      );
    }
    final access = crossWorkAccess;
    if (access == null) {
      return _crossWorkUnavailable('/works/$workId');
    }

    final acquisition = _crossWorkAcquisitions.putIfAbsent(
      workId,
      () => _acquireCrossWork(access, workId),
    );
    final _CrossWorkLeaseEntry entry;
    try {
      entry = await acquisition;
    } on CrossWorkAccessException catch (error) {
      if (identical(_crossWorkAcquisitions[workId], acquisition)) {
        _crossWorkAcquisitions.remove(workId);
      }
      return _workAccessError(workId, error.errorCode, error.message);
    } catch (error, stackTrace) {
      if (identical(_crossWorkAcquisitions[workId], acquisition)) {
        _crossWorkAcquisitions.remove(workId);
      }
      _log.error(
        'cross-work acquisition failed workId=$workId',
        error: error,
        stackTrace: stackTrace,
      );
      return _workAccessError(
        workId,
        'work_unavailable',
        'Work content is unavailable: $workId',
      );
    }

    if (_crossWorkDisposed) {
      entry.lease.release();
      return _crossWorkDisposedResult(workId);
    }

    entry.inFlight += 1;
    try {
      final context = _ResourceCallContext(
        scope: _ResourceScope(
          currentWorkId: access.currentWorkId,
          targetWorkId: entry.lease.workId,
          kind: _ResourceWorkKind.parse(entry.lease.work.contentKind)!,
          absolutePaths: true,
        ),
        operation: operation,
        service: entry.lease.service,
        novelReader: entry.lease.novelReader,
        executionContext: _currentToolExecutionContext,
      );
      final result = await runZoned(
        run,
        zoneValues: {_resourceCallContextZoneKey: context},
      );
      return _serializeCallResult(result, context, resultTarget: resultTarget);
    } finally {
      entry.inFlight -= 1;
      if (_crossWorkDisposed && entry.inFlight == 0) {
        entry.lease.release();
      }
    }
  }

  Future<Map<String, dynamic>> _withCurrentResourceContext(
    String operation,
    Future<Map<String, dynamic>> Function() run, {
    bool absolutePaths = false,
    ParsedPath? resultTarget,
  }) async {
    final kind = _ResourceWorkKind.parse(contentKind);
    final currentWorkId = crossWorkAccess?.currentWorkId ?? workId;
    if (kind == null) {
      return {
        'ok': false,
        'error_code': ToolErrorCode.unsupported.name,
        'error': 'The current work has an unsupported content kind.',
        if (currentWorkId != null) 'path': '/works/$currentWorkId',
      };
    }
    final context = _ResourceCallContext(
      scope: _ResourceScope(
        currentWorkId: currentWorkId,
        targetWorkId: currentWorkId,
        kind: kind,
        absolutePaths: absolutePaths,
      ),
      operation: operation,
      service: _primaryContentService,
      novelReader: _primaryNovelReader,
      executionContext: _currentToolExecutionContext,
    );
    final result = await runZoned(
      run,
      zoneValues: {_resourceCallContextZoneKey: context},
    );
    return absolutePaths
        ? _serializeCallResult(result, context, resultTarget: resultTarget)
        : result;
  }

  Future<_CrossWorkLeaseEntry> _acquireCrossWork(
    CrossWorkAccess access,
    String workId,
  ) async {
    final lease = await access.acquire(workId);
    if (_crossWorkDisposed) {
      lease.release();
      throw const CrossWorkAccessException(
        'tool_manager_disposed',
        'Tool manager has been disposed.',
      );
    }
    if (lease.workId != workId) {
      lease.release();
      throw const CrossWorkAccessException(
        'work_unavailable',
        'The acquired content does not belong to the requested work.',
      );
    }
    if (_ResourceWorkKind.parse(lease.work.contentKind) == null) {
      lease.release();
      throw const CrossWorkAccessException(
        'unsupported_content_kind',
        'The target work has an unsupported content kind.',
      );
    }
    return _CrossWorkLeaseEntry(lease);
  }

  void _disposeCrossWork() {
    if (_crossWorkDisposed) {
      return;
    }
    _crossWorkDisposed = true;
    final acquisitions = _crossWorkAcquisitions.values.toList();
    _crossWorkAcquisitions.clear();
    for (final acquisition in acquisitions) {
      unawaited(
        acquisition.then((entry) {
          if (entry.inFlight == 0) {
            entry.lease.release();
          }
        }, onError: (Object _, StackTrace _) {}),
      );
    }
  }
}

_CrossWorkScope _resolveCrossWorkScope(List<String> values) {
  String? resolvedWorkId;
  for (final value in values) {
    final scope = _pathWorkScope(value);
    if (scope.ambiguous) {
      return _CrossWorkScope(error: _workIdRequiredResult());
    }
    final workId = scope.workId;
    if (workId == null) {
      continue;
    }
    if (resolvedWorkId != null && resolvedWorkId != workId) {
      return _CrossWorkScope(
        error: {
          'ok': false,
          'error': 'A tool call can target only one work_id.',
          'error_code': ToolErrorCode.invalid_argument.name,
        },
      );
    }
    resolvedWorkId = workId;
  }
  return _CrossWorkScope(workId: resolvedWorkId);
}

_SinglePathWorkScope _pathWorkScope(String rawPath) {
  if (rawPath.trim().isEmpty) {
    return const _SinglePathWorkScope.none();
  }
  // 作品段里的 ? 属于通配语法，不能先作为 query 裁掉再取得另一个 workId。
  final normalized = ParsedPath._normalizePath(rawPath);
  final segments = ParsedPath._splitPath(normalized);
  if (segments.firstOrNull == 'works') {
    if (segments.length < 2 || _containsPathPatternSyntax(segments[1])) {
      return const _SinglePathWorkScope.ambiguous();
    }
    return _SinglePathWorkScope.target(segments[1]);
  }
  return const _SinglePathWorkScope.none();
}

bool _containsPathPatternSyntax(String segment) {
  return segment.contains('*') ||
      segment.contains('?') ||
      segment.contains('[') ||
      segment.contains(']') ||
      segment.contains('{');
}

String _stripWorkPrefix(String rawPath, String workId) {
  final queryStart = rawPath.indexOf('?');
  final pathPart = queryStart < 0 ? rawPath : rawPath.substring(0, queryStart);
  final query = queryStart < 0 ? '' : rawPath.substring(queryStart);
  final normalized = ParsedPath._normalizePath(pathPart);
  final segments = ParsedPath._splitPath(normalized);
  if (segments.length < 2 || segments[0] != 'works' || segments[1] != workId) {
    return rawPath;
  }
  final localPath = segments.length == 2 ? '/' : segments.skip(2).join('/');
  return '$localPath$query';
}

/// 公共结果出口只序列化已声明的响应引用与直接 listing 条目。
/// 搜索在生成处标记引用，正文、任意嵌套业务 JSON 与 prose 保持原样。
Map<String, dynamic> _serializeCallResult(
  Map<String, dynamic> result,
  _ResourceCallContext context, {
  ParsedPath? resultTarget,
}) {
  if (result.length == 1 && result['ok'] == true) {
    return result;
  }
  Map<String, dynamic> referenceRecord(Map<String, dynamic> record) {
    final out = Map<String, dynamic>.from(record);
    for (final key in const [
      'path',
      'episode_path',
      'parent_path',
      'history_path',
    ]) {
      final path = record[key];
      if (path is String) {
        out[key] = context.scope
            .reference(path)
            .serialize(absolute: context.scope.absolutePaths);
      }
    }
    if (record['path'] is String) {
      out['work_id'] = context.scope.targetWorkId;
    }
    return out;
  }

  final out = referenceRecord(result);
  out['work_id'] = context.scope.targetWorkId;
  final entries = result['entries'];
  if (entries is List &&
      (resultTarget?.isRoot == true ||
          resultTarget?.isResourceListing == true ||
          result['type'] == 'listing' ||
          result['is_folder'] == true)) {
    out['entries'] = [
      for (final entry in entries)
        if (entry is Map<String, dynamic>) referenceRecord(entry) else entry,
    ];
  }
  // chapters/{id}/relations 是明确的关系引用数组，不是任意 JSON 字段。
  if (resultTarget?.collection == 'chapters' &&
      resultTarget?.field == 'relations') {
    final relations = result['value'];
    if (relations is List) {
      out['value'] = [
        for (final relation in relations)
          if (relation is Map<String, dynamic>)
            referenceRecord({
              ...relation,
              'path': 'relations/${relation['id']}',
            })
          else
            relation,
      ];
    }
  }
  return out;
}

/// [reason] 是 [CrossWorkAccessException.errorCode]，在工具出口收敛为大类。
Map<String, dynamic> _workAccessError(
  String workId,
  String reason,
  String message,
) => {
  'ok': false,
  'error': message,
  'error_code': switch (reason) {
    'work_not_found' => ToolErrorCode.not_found,
    'unsupported_content_kind' => ToolErrorCode.unsupported,
    _ => ToolErrorCode.unavailable,
  }.name,
  'path': reason == 'works_unavailable' ? '/works' : '/works/$workId',
  if (reason == 'work_not_found')
    'hint': 'Read /works and choose an available work_id.',
  if (reason == 'work_unavailable')
    'hint':
        'The target content is temporarily unavailable. Retry access later.',
};

String _prefixWorkPath(String path, String workId) {
  final canonical = canonicalResourcePath(path);
  if (canonical == '/') {
    return '/works/$workId';
  }
  if (canonical.startsWith('/')) {
    return canonical;
  }
  return '/works/$workId/$canonical';
}

Map<String, dynamic> _workIdRequiredResult() {
  return {
    'ok': false,
    'error': 'Choose one work_id before searching across works.',
    'error_code': ToolErrorCode.invalid_argument.name,
    'hint': 'Read /works, then target /works/{work_id}/… in one work.',
  };
}

Map<String, dynamic> _crossWorkMutationDenied(
  String toolName,
  String path, {
  String? currentWorkId,
}) {
  final currentPath = currentWorkId == null
      ? 'a relative path in the current work'
      : 'a relative path or /works/$currentWorkId/…';
  return {
    'ok': false,
    'error': '$toolName can only modify the current work.',
    'error_code': ToolErrorCode.permission_denied.name,
    'path': path,
    'hint': 'Use $currentPath.',
  };
}

Map<String, dynamic> _crossWorkUnavailable(String path) {
  return {
    'ok': false,
    'error': 'Cross-work access is unavailable in this session.',
    'error_code': ToolErrorCode.unavailable.name,
    'path': path,
  };
}

Map<String, dynamic> _crossWorkDisposedResult(String workId) {
  return {
    'ok': false,
    'error': 'Tool manager has been disposed.',
    'error_code': ToolErrorCode.unavailable.name,
    'path': '/works/$workId',
  };
}

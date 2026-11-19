// 职责: AI 小说工具创建能力，负责统一 Create 入口及可回滚 working change patch 记录。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_read.dart
//   lib/shared/services/working_overlay.dart
// ignore_for_file: use_null_aware_elements
part of 'tools.dart';

const _createDescription = '''创建作品工作区资源。

用户明确要求新建作品时，使用 Create /works，字段见 Read /_schema/works。成功返回新作品的 id 和 path，当前会话仍指向原作品。

批量创建时，每次调用都是独立请求，不继承同批或上次调用的参数。部分成功时，只修正并重试失败项，避免重复创建已成功的资源。

跨字段约束：
- chapters：不传 volume_id 时写入最新正文所在的卷，没有正文时写入最后一个卷。volume_id 从 Read volumes 的 entries[].id 原样复制。

示例：{"path": "chapters", "fields": {"title": "风暴开端", "content": "..."}}''';

/// Create 的 input schema。顶层只有 path / fields 两个键。
///
/// **新增顶层字段前必须获得人工确认。** 资源字段一律走 `fields`，路径专属的参数
/// 也一样——`fields` 是 `additionalProperties: true` 的开放袋子，容得下。加顶层
/// 字段只会：
/// - 让一个只服务少数集合的键常驻在每一次 Create 的 schema 里；
/// - 加重已有的歧义——`_resolveCreateFields` 已经要在顶层与 `fields` 之间做
///   `conflicting_fields` 比对，每多一个顶层键就多一份要对齐的状态。
final _createInputSchema = const {
  'type': 'object',
  'properties': {
    'path': {
      'type': 'string',
      'description':
          '目标资源路径、集合根或子资源 listing。'
          'lore 与 materials 的路径段是父目录、fields.title 是叶子名，'
          '缺失的父目录会一并建出来。',
    },
    'fields': {
      'type': 'object',
      'description':
          '要创建的字段。可用字段、必需项与枚举见路径字段表；带 * 的创建时必需。'
          '字符串去除首尾空白，普通值数组去重，整数字段四舍五入。未知或不可创建字段会跳过，数组、对象内部的同类键一并跳过，'
          '全部在 ignored_fields 中按 `beats[0].foo` 这样的位置列出。',
      'additionalProperties': true,
    },
  },
  'required': ['path', 'fields'],
  'additionalProperties': false,
};

const _worksDefinition = _ResourceDefinition(
  segment: 'works',
  address: _ResourceAddress(_AddressKind.id, itemToken: 'work_id'),
  description: '新建作品直接加入书架。Read /works 列出书架上可读取的作品。',
  fields: {
    'id': _ResourceField(
      value: _ValueSchema(_ValueType.string),
      read: _FieldRead(listing: true, path: true),
    ),
    'title': _ResourceField(
      value: _ValueSchema(_ValueType.string),
      create: _FieldInputUse(
        required: true,
        value: _ValueSchema(_ValueType.string, minLength: 1),
      ),
      read: _FieldRead(listing: true, path: true),
      write: _FieldInputUse(field: true),
      edit: _FieldEdit(),
      search: {_FieldSearch.short_text},
    ),
    'author_name': _ResourceField(
      value: _ValueSchema(_ValueType.string),
      read: _FieldRead(path: true),
      write: _FieldInputUse(field: true),
      edit: _FieldEdit(),
      search: {_FieldSearch.body},
    ),
    'description': _ResourceField(
      value: _ValueSchema(_ValueType.string),
      create: _FieldInputUse(),
      read: _FieldRead(listing: true, path: true),
      write: _FieldInputUse(field: true),
      edit: _FieldEdit(),
      search: {_FieldSearch.body},
    ),
    'category': _ResourceField(
      value: _ValueSchema(_ValueType.string),
      read: _FieldRead(listing: true, path: true),
      write: _FieldInputUse(field: true),
      edit: _FieldEdit(),
      search: {_FieldSearch.body},
    ),
    'status': _ResourceField(
      value: _ValueSchema(
        _ValueType.string,
        enumAliases: _ChineseEnumMappings.novelStatusZh,
        enumValues: _aiNovelStatuses,
      ),
      read: _FieldRead(listing: true, path: true),
      write: _FieldInputUse(field: true),
    ),
    'tags': _ResourceField(
      value: _ValueSchema(_ValueType.string),
      read: _FieldRead(path: true),
      write: _FieldInputUse(field: true),
      edit: _FieldEdit(),
      description: '逗号分隔字符串',
      search: {_FieldSearch.body},
    ),
    'draft': _ResourceField(
      value: _ValueSchema(_ValueType.boolean),
      read: _FieldRead(listing: true, path: true),
      write: _FieldInputUse(field: true),
      description: 'true 为草稿，false 为已加入书架',
    ),
    'content_kind': _ResourceField(
      value: _ValueSchema(_ValueType.string, enumValues: [...contentKinds]),
      create: _FieldInputUse(required: true),
      read: _FieldRead(listing: true, path: true),
    ),
    'type': _ResourceField(
      value: _ValueSchema(
        _ValueType.string,
        enumValues: creatableScreenplayWorkTypes,
      ),
      create: _FieldInputUse(hasDefault: true, defaultValue: novelTypeOriginal),
      description: 'adaptation 仅用于剧本。画布使用 original。',
    ),
    'source_novel_id': _ResourceField(
      value: _ValueSchema(_ValueType.string, nullable: true),
      create: _FieldInputUse(
        value: _ValueSchema(_ValueType.string, minLength: 1),
      ),
      read: _FieldRead(
        listing: true,
        path: true,
        requiredInListing: false,
        requiredInDetail: false,
      ),
      description: '来源小说的 id，从当前作品或 Read /works 的结果获取。',
    ),
  },
  operations: [
    _ResourceOperation(
      _ResourceTool.read,
      _ResourceTargetKind.listing,
      result: _ResourceResult(
        _ResourceResultKind.listing,
        references: ['entries[].path'],
      ),
    ),
    _ResourceOperation(
      _ResourceTool.read,
      _ResourceTargetKind.resource,
      result: _ResourceResult(_ResourceResultKind.entity, references: ['path']),
    ),
    _ResourceOperation(
      _ResourceTool.write,
      _ResourceTargetKind.resource,
      input: _ResourceInput(_ResourceInputKind.resource_fields),
    ),
    _ResourceOperation(
      _ResourceTool.create,
      _ResourceTargetKind.listing,
      input: _ResourceInput(_ResourceInputKind.create_fields),
      constraints: [
        _ResourceConstraint(
          _ConstraintKind.required_when,
          ['source_novel_id'],
          whenField: 'type',
          whenValues: [novelTypeAdaptation],
        ),
      ],
    ),
  ],
);

class _DocumentFolderEnsureResult {
  const _DocumentFolderEnsureResult({
    required this.parentId,
    required this.createdFolders,
  }) : error = null;

  _DocumentFolderEnsureResult.error(this.error)
    : parentId = null,
      createdFolders = const [];

  final String? parentId;
  final List<String> createdFolders;
  final Map<String, dynamic>? error;
}

class _CreateFieldsResult {
  const _CreateFieldsResult(this.fields, this.error);

  final Map<String, dynamic>? fields;
  final Map<String, dynamic>? error;
}

mixin _AiToolManagerCreateMixin
    on
        _AiToolManagerBase,
        _AiToolManagerOutlineMixin,
        _AiToolManagerGraphMixin,
        _AiToolManagerCanvasMixin,
        _AiToolManagerWriteMixin {
  Future<Map<String, dynamic>> _handleCreate(
    Map<String, dynamic> input, {
    ParsedPath? worksPath,
  }) async {
    final path = _parseStringArgument(input['path'], trim: true);
    if (path.isEmpty) {
      return AiToolManager._structuredWriteError(
        path: path,
        errorCode: ToolErrorCode.invalid_argument,
        message: 'Create requires path',
        operation: 'create',
        missingFields: const ['path'],
        requiredFields: const ['path', 'fields'],
        hint:
            'Each call needs its own path; do not inherit it from another call. '
            'Retry only failed calls with complete arguments.',
      );
    }

    final parsed =
        worksPath ?? ParsedPath.parse(path, schemaLookup: _getCollectionSchema);
    if (parsed.isWorksListing && worksPath == null) {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.invalid_argument,
        'Use /works directly to create a work.',
      );
    }
    if (worksPath != null && parsed.hasQuery) {
      return AiToolManager._structuredWriteError(
        path: parsed.displayPath,
        errorCode: ToolErrorCode.invalid_argument,
        message: 'Query parameters are not supported for Create /works.',
        operation: 'create',
      );
    }
    final contentKindError = worksPath == null
        ? _contentKindGate(parsed)
        : null;
    if (contentKindError != null) {
      return contentKindError;
    }
    final operationError = _resourceOperationGate(parsed, _ResourceTool.create);
    if (operationError != null) {
      return operationError;
    }
    if (parsed._resource!.schema.isSingleton) {
      if (parsed._resource.schema == _productionCanvas &&
          (input['fields'] == null ||
              input['fields'] is Map && (input['fields'] as Map).isEmpty)) {
        return _handleWrite({
          ...input,
          'fields': {'positions': <dynamic>[]},
        });
      }
      return _handleWrite(input);
    }
    if (parsed.isRoot || parsed.hasField) {
      return AiToolManager._structuredWriteError(
        path: path,
        errorCode: ToolErrorCode.invalid_argument,
        message:
            'Create requires a collection path or supported subresource path',
        operation: 'create',
      );
    }

    final fieldsResult = _resolveCreateFields(input, parsed);
    if (fieldsResult.error case final error?) {
      return _attachCreateResourcePath(parsed, error);
    }
    final prepared = _prepareResourceInput(
      parsed,
      fieldsResult.fields!,
      create: true,
    );
    return _attachIgnoredFields(switch ((prepared.error, worksPath)) {
      (final error?, _) => _attachCreateResourcePath(parsed, error),
      (null, final works?) => await _executeCreateWork(works, prepared.fields!),
      (null, null) => await _executePreparedCreate(parsed, prepared.fields!),
    }, prepared.ignoredFields);
  }

  Future<Map<String, dynamic>> _executeCreateWork(
    ParsedPath parsed,
    Map<String, dynamic> fields,
  ) async {
    final actions = workCreationService;
    if (actions == null) {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.unavailable,
        'Work creation is unavailable in this session.',
      );
    }
    final kind = fields['content_kind'] as String;
    final type = fields['type'] as String? ?? novelTypeOriginal;
    final validType = kind == contentKindCanvas
        ? type == novelTypeOriginal
        : creatableNovelTypesFor(kind).contains(type);
    if (!validType) {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.invalid_argument,
        'Work type $type is unavailable for $kind.',
        hint: 'Read /_schema/works for supported fields.',
      );
    }
    try {
      final id = await actions.createNovel(
        title: fields['title'] as String,
        description: fields['description'] as String? ?? '',
        contentKind: kind,
        type: type,
        sourceNovelId: fields['source_novel_id'] as String?,
      );
      return {'ok': true, 'created': true, 'id': id, 'path': '/works/$id'};
    } on NovelTitleConflictException catch (error) {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.already_exists,
        'A library work named "${error.title}" already exists.',
      );
    } on ArgumentError catch (error) {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.invalid_argument,
        error.message.toString(),
      );
    }
  }

  Future<Map<String, dynamic>> _executePreparedCreate(
    ParsedPath parsed,
    Map<String, dynamic> fields,
  ) async {
    if (isScreenplayPath(parsed)) {
      return _attachCreateResourcePath(
        parsed,
        await _executeScreenplay(
          parsed,
          parsed._resource!.operation(_ResourceTool.create)!,
          fields: fields,
        ),
      );
    }

    if (isCanvasPath(parsed)) {
      return _attachCreateResourcePath(
        parsed,
        await _executeCanvas(
          parsed,
          parsed._resource!.operation(_ResourceTool.create)!,
          fields: fields,
        ),
      );
    }

    if (_createTitlePathCharsError(parsed, fields) case final error?) {
      return _attachCreateResourcePath(parsed, error);
    }

    if (parsed.isOutlineBeat && parsed.isResourceListing) {
      final located = await _locateOutline(parsed);
      if (located.error != null) {
        return _attachCreateResourcePath(parsed, located.error!);
      }
      final result = await _handleCreateBeat(
        located.target!,
        fields,
        toolName: 'Create',
      );
      return _attachCreateResourcePath(parsed, result);
    }

    if (parsed.collection == 'lore' || parsed.collection == 'materials') {
      final result = await _handleCreateDocumentResource(parsed, fields);
      return _attachCreateResourcePath(parsed, result);
    }

    final result = switch (parsed.collection) {
      'chapters' => await _handleCreateChapter(parsed, fields),
      'relations' => await _handleCreateRelation(parsed, fields),
      'volumes' => await _handleCreateVolume(parsed, fields),
      'characters' => await _handleCreateCharacter(parsed, fields),
      'locations' => await _handleCreateLocation(parsed, fields),
      'foreshadowing' => await _handleCreateForeshadowing(parsed, fields),
      'outlines' => await _handleCreateOutline(fields, toolName: 'Create'),
      'skills' ||
      'items' ||
      'factions' ||
      'creatures' => await _handleCreateItem(parsed, fields),
      _ => AiToolManager._structuredWriteError(
        path: parsed.displayPath,
        errorCode: ToolErrorCode.invalid_argument,
        message: 'Create does not support collection: ${parsed.collection}',
        operation: 'create',
      ),
    };
    return _attachCreateResourcePath(parsed, result);
  }

  /// 这些集合的 service 会拒绝含 `/`、`?` 的标题；在工具层先拦截，给模型可执行的 hint，
  /// 避免 service 的 ArgumentError 落入通用异常兜底。
  static const _titlePathSafeCollections = {
    'outlines',
    'lore',
    'materials',
    'skills',
    'items',
    'factions',
    'creatures',
  };

  Map<String, dynamic>? _createTitlePathCharsError(
    ParsedPath parsed,
    Map<String, dynamic> fields,
  ) {
    if (parsed.isOutlineBeat ||
        !_titlePathSafeCollections.contains(parsed.collection)) {
      return null;
    }
    final title = fields['title'];
    if (title is! String || !nameHasAiPathStructuralChars(title)) {
      return null;
    }
    return AiToolManager._structuredWriteError(
      path: parsed.displayPath,
      errorCode: ToolErrorCode.invalid_argument,
      message:
          'Title must not contain "/" or "?" because it is used as the resource path.',
      operation: 'create',
      hint:
          'Retry with "/" and "?" removed from the title, e.g. replace "/" with "-".',
    );
  }

  _CreateFieldsResult _resolveCreateFields(
    Map<String, dynamic> input,
    ParsedPath parsed,
  ) {
    final parsedFields = AiToolManager._tryCoerceContentMap(
      input['fields'],
      toolName: 'Create',
    );
    if (parsedFields.error != null ||
        (input.containsKey('fields') && parsedFields.value == null)) {
      final error = parsedFields.error ?? 'Create.fields must be an object.';
      return _CreateFieldsResult(
        null,
        _resourceInputEnvelopeError(
          parsed: parsed,
          tool: _ResourceTool.create,
          issues: const [_ResourceInputIssue('invalid_type', field: 'fields')],
          errorCode: ToolErrorCode.invalid_argument,
          message: error,
          operation: 'create',
        ),
      );
    }

    final fields = Map<String, dynamic>.from(parsedFields.value ?? const {});
    for (final entry in input.entries) {
      if (entry.key != 'path' && entry.key != 'fields') {
        _addResourceInputSource(fields, entry.key, entry.value);
      }
    }
    return _CreateFieldsResult(fields, null);
  }

  Future<Map<String, dynamic>> _handleCreateDocumentResource(
    ParsedPath parsed,
    Map<String, dynamic> fields,
  ) async {
    final collection = parsed.collection;
    final documentType = parsed._resource!.schema.documentType!;
    final pathNamePath = parsed.namePath;
    final explicitTitle = fields['title'] as String? ?? '';
    final createFolder = fields['type'] == 'folder';

    final targetPath = explicitTitle.isNotEmpty
        ? [...pathNamePath, explicitTitle]
        : pathNamePath;
    if (targetPath.isEmpty) {
      return AiToolManager._structuredWriteError(
        path: collection,
        errorCode: ToolErrorCode.invalid_argument,
        message:
            'title is required when creating a $collection resource at collection root',
        operation: 'create',
        missingFields: const ['title'],
        requiredFields: const ['title'],
      );
    }

    final targetTitle = targetPath.last;
    final parentPath = targetPath.sublist(0, targetPath.length - 1);
    final parentResult = await _ensureDocumentFolderPath(
      collection: collection,
      documentType: documentType,
      parentPath: parentPath,
    );
    if (parentResult.error != null) {
      return parentResult.error!;
    }

    final targetDisplayPath = _documentCreateDisplayPath(
      collection,
      targetPath,
    );
    final duplicateTitleError = await _validateDocumentTitleAvailable(
      contentService: _contentService,
      collection: collection,
      documentType: documentType,
      title: targetTitle,
      path: targetDisplayPath,
      operation: 'create',
      parentId: parentResult.parentId,
    );
    if (duplicateTitleError != null) {
      return duplicateTitleError;
    }

    if (createFolder) {
      try {
        final newId = await _contentService.documentsService.createFolder(
          type: documentType,
          parentId: parentResult.parentId,
          title: targetTitle,
        );
        return {
          'path': targetDisplayPath,
          'id': newId,
          'created': true,
          'is_folder': true,
          'created_parent_folders': parentResult.createdFolders,
        };
      } catch (error, stackTrace) {
        _log.error(
          'documents INSERT folder failed '
          'type=$documentType title=$targetTitle parent_id=${parentResult.parentId} '
          'error=$error',
          stackTrace: stackTrace,
        );
        return AiToolManager._structuredWriteError(
          path: targetDisplayPath,
          errorCode: ToolErrorCode.internal,
          message: 'Failed to create $collection folder',
          operation: 'create',
        );
      }
    }

    final content = fields['content'] as String? ?? '';
    final category = fields['category'] as String? ?? '';
    try {
      final newId = await _contentService.documentsService.createDocument(
        type: documentType,
        parentId: parentResult.parentId,
        title: targetTitle,
        content: content,
        category: category,
      );

      final previewText = [
        targetTitle,
        if (content.isNotEmpty) content,
        if (parentPath.isNotEmpty) '父文件夹：${parentPath.join('/')}',
      ].join('\n\n');
      await _stageCreateChange(
        resourcePath: '$collection/$newId',
        resourceType: collection,
        resourceId: newId,
        previewText: previewText,
        source: workingChangeSourceAi,
        toolName: 'Create',
        summary: 'AI created $collection document',
      );
      return {
        'path': targetDisplayPath,
        'id': newId,
        'created': true,
        'is_folder': false,
        'created_parent_folders': parentResult.createdFolders,
      };
    } catch (error, stackTrace) {
      _log.error(
        'documents INSERT document failed '
        'type=$documentType title=$targetTitle parent_id=${parentResult.parentId} '
        'error=$error',
        stackTrace: stackTrace,
      );
      return AiToolManager._structuredWriteError(
        path: targetDisplayPath,
        errorCode: ToolErrorCode.internal,
        message: 'Failed to create $collection document',
        operation: 'create',
      );
    }
  }

  Future<_DocumentFolderEnsureResult> _ensureDocumentFolderPath({
    required String collection,
    required String documentType,
    required List<String> parentPath,
  }) async {
    String? parentId;
    final currentPath = <String>[];
    final createdFolders = <String>[];
    for (final segment in parentPath) {
      currentPath.add(segment);
      final existing = await _contentService.documentsService
          .getDocumentByNamePath(type: documentType, namePath: currentPath);
      if (existing != null) {
        if (!existing.isFolder) {
          final pathStr = currentPath.join('/');
          return _DocumentFolderEnsureResult.error(
            AiToolManager._structuredWriteError(
              path: '$collection/$pathStr',
              errorCode: ToolErrorCode.invalid_argument,
              message: 'Parent $pathStr is not a folder',
              operation: 'create',
            ),
          );
        }
        parentId = existing.id;
        continue;
      }

      try {
        parentId = await _contentService.documentsService.createFolder(
          type: documentType,
          parentId: parentId,
          title: segment,
        );
        createdFolders.add('$collection/${currentPath.join('/')}');
      } catch (error, stackTrace) {
        _log.error(
          'documents INSERT folder failed '
          'type=$documentType title=$segment parent_id=$parentId '
          'error=$error',
          stackTrace: stackTrace,
        );
        return _DocumentFolderEnsureResult.error(
          AiToolManager._structuredWriteError(
            path: '$collection/${currentPath.join('/')}',
            errorCode: ToolErrorCode.internal,
            message: 'Failed to create parent folder: ${currentPath.join('/')}',
            operation: 'create',
          ),
        );
      }
    }
    return _DocumentFolderEnsureResult(
      parentId: parentId,
      createdFolders: createdFolders,
    );
  }

  String _documentCreateDisplayPath(String collection, List<String> namePath) {
    if (namePath.isEmpty) {
      return collection;
    }
    return '$collection/${namePath.join('/')}';
  }

  Future<Map<String, dynamic>> _handleCreateChapter(
    ParsedPath parsed,
    Map<String, dynamic> input,
  ) async {
    final title = AiToolManager.stripChapterTitlePrefix(
      input['title'] as String,
    );
    if (title.isEmpty) {
      return AiToolManager._structuredWriteError(
        path: 'chapters',
        errorCode: ToolErrorCode.invalid_argument,
        message:
            'Chapter title contains only a chapter number. '
            'Provide title text after the chapter number.',
        operation: 'create',
        missingFields: const ['title'],
        requiredFields: const ['title'],
        hint:
            'Retry with fields.title containing a descriptive title, '
            'for example "第一章 风暴开端" or "风暴开端". '
            'Chapter numbering is assigned separately.',
      );
    }

    final volumeValue = input['volume_id'] as String?;
    // 空关联与未提供都使用既有默认归卷规则。
    final requestedVolumeId = volumeValue == null || volumeValue.isEmpty
        ? null
        : volumeValue;
    String? parentId;
    int siblingOrder;
    if (requestedVolumeId != null) {
      final volume = await _contentService.getChapterById(requestedVolumeId);
      if (volume == null) {
        return AiToolManager._structuredWriteError(
          path: 'chapters',
          errorCode: ToolErrorCode.invalid_argument,
          message: 'Volume not found: $requestedVolumeId',
          operation: 'create',
        );
      }
      if (!volume.isVolume) {
        return AiToolManager._structuredWriteError(
          path: 'chapters',
          errorCode: ToolErrorCode.unsupported,
          message: 'Resource "$requestedVolumeId" is not a volume.',
          operation: 'create',
        );
      }
      parentId = volume.id;
      siblingOrder = await _contentService.getNextSiblingOrderInVolume(
        volume.id,
      );
    } else {
      final chapters = await _contentService.getChapters();
      final latestChapter = chapters
          .where((chapter) => chapter.isNumberedChapter)
          .fold<Chapter?>(
            null,
            (latest, chapter) =>
                latest == null ||
                    (chapter.chapterNum ?? -1) > (latest.chapterNum ?? -1)
                ? chapter
                : latest,
          );
      if (latestChapter != null) {
        parentId = latestChapter.parentId;
        siblingOrder = parentId == null
            ? await _contentService.getNextSiblingOrderAtRoot()
            : await _contentService.getNextSiblingOrderInVolume(parentId);
      } else {
        final volumes = chapters.where((c) => c.isVolume).toList()
          ..sort((a, b) => a.siblingOrder.compareTo(b.siblingOrder));
        if (volumes.isEmpty) {
          siblingOrder = await _contentService.getNextSiblingOrderAtRoot();
        } else {
          final lastVolume = volumes.last;
          parentId = lastVolume.id;
          siblingOrder = await _contentService.getNextSiblingOrderInVolume(
            lastVolume.id,
          );
        }
      }
    }

    final outline = input['outline'] as String? ?? '';
    final content = input['content'] as String? ?? '';
    final brief = input['brief'] as String? ?? '';

    final newId = await _contentService.createChapter(
      siblingOrder: siblingOrder,
      title: title,
      parentId: parentId,
    );
    await _contentService.updateChapterContent(
      chapterId: newId,
      title: title,
      outline: outline,
      content: content,
      brief: brief,
    );
    for (final fieldName in _chapterAnalysisFields) {
      if (!input.containsKey(fieldName)) {
        continue;
      }
      final analysisResult = await _writeChapterAnalysisField(
        newId,
        fieldName,
        input[fieldName],
      );
      if (analysisResult['ok'] == false || analysisResult['error'] != null) {
        return analysisResult;
      }
    }
    final volumeLabel = parentId != null ? '（卷内）' : '';
    final previewText = [
      '$title$volumeLabel',
      if (outline.isNotEmpty) '大纲：$outline',
      if (content.isNotEmpty) '正文：$content',
    ].join('\n\n');
    await _stageCreateChange(
      resourcePath: 'chapters/$newId',
      resourceType: 'chapters',
      resourceId: newId,
      previewText: previewText,
      source: workingChangeSourceAi,
      toolName: 'Create',
      summary: 'AI created chapter $title',
    );
    return {
      'path': 'chapters/$newId',
      'id': newId,
      'created': true,
      'volume_id': parentId ?? '',
      'content_word_counts': _chapterWordCount(content),
    };
  }

  Future<Map<String, dynamic>> _handleCreateVolume(
    ParsedPath parsed,
    Map<String, dynamic> input,
  ) async {
    final title = input['title'] as String;
    final outline = input['outline'] as String? ?? '';
    final newId = await _contentService.createVolume(
      title: title,
      description: outline.isEmpty ? null : outline,
    );

    final previewText = [title, if (outline.isNotEmpty) outline].join('\n\n');
    await _stageCreateChange(
      resourcePath: 'volumes/$newId',
      resourceType: 'volumes',
      resourceId: newId,
      previewText: previewText,
      source: workingChangeSourceAi,
      toolName: 'Create',
      summary: 'AI created volume $title',
    );
    return {'path': 'volumes/$newId', 'id': newId, 'created': true};
  }

  Future<Map<String, dynamic>> _handleCreateCharacter(
    ParsedPath parsed,
    Map<String, dynamic> input,
  ) async {
    final name = input['name'] as String;
    final finalRole = input['role'] as String? ?? characterRoleSupporting;
    final finalGender = input['gender'] as String? ?? characterGenderUnknown;
    final aliases = (input['aliases'] as List? ?? const []).cast<String>();
    final tags = (input['tags'] as List? ?? const []).cast<String>();
    final behaviorTags = [
      for (final tag
          in (input['behavior_tags'] as List? ?? const [])
              .cast<Map<String, dynamic>>())
        CharacterBehaviorTag(
          tag: tag['tag'] as String,
          context: tag['context'] as String,
        ),
    ];
    final identity = input['identity'] as String? ?? '';
    final age = input['age'] as String? ?? '';
    final motivation = input['motivation'] as String? ?? '';
    final arc = input['arc'] as String? ?? '';
    final biography = input['biography'] as String? ?? '';
    final appearance = input['appearance'] as String? ?? '';
    final personality = input['personality'] as String? ?? '';
    final description = input['description'] as String? ?? '';
    final currentState = input['current_state'] as String? ?? '';
    final firstAppearance = input['first_appear_chapter_id'] as String?;
    final firstAppearChapterId =
        firstAppearance == null || firstAppearance.isEmpty
        ? null
        : firstAppearance;
    final avatarAssetId = input['avatar_asset_id'] as String?;
    final avatarError = await _avatarAssetError(
      'characters/avatar_asset_id',
      avatarAssetId,
    );
    if (avatarError != null) {
      return avatarError;
    }
    late final String newId;
    try {
      newId = await _contentService.createCharacterProfile(
        name: name,
        role: finalRole,
        gender: finalGender,
        aliases: aliases,
        tags: tags,
        identity: identity,
        age: age,
        motivation: motivation,
        arc: arc,
        biography: biography,
        appearance: appearance,
        personality: personality,
        description: description,
        behaviorTags: behaviorTags,
        currentState: currentState,
        firstAppearChapterId: firstAppearChapterId,
      );
    } on ArgumentError catch (error) {
      return AiToolManager._structuredWriteError(
        path: 'characters',
        errorCode: ToolErrorCode.invalid_argument,
        message: error.message?.toString() ?? error.toString(),
        operation: 'create',
      );
    }
    final previewText = [
      name,
      '角色：$finalRole',
      '性别：$finalGender',
      if (aliases.isNotEmpty) '别名：${aliases.join('、')}',
      if (tags.isNotEmpty) '标签：${tags.join('、')}',
      if (identity.isNotEmpty) '身份：$identity',
      if (age.isNotEmpty) '年龄：$age',
      if (motivation.isNotEmpty) '动机：$motivation',
      if (arc.isNotEmpty) '人物弧光：$arc',
      if (biography.isNotEmpty) biography,
      if (appearance.isNotEmpty) '外观：$appearance',
      if (personality.isNotEmpty) '性格：$personality',
      if (description.isNotEmpty) description,
      if (behaviorTags.isNotEmpty)
        '行为标签：${behaviorTags.map((tag) => '${tag.tag}（${tag.context}）').join('、')}',
      if (currentState.isNotEmpty) '当前状态：$currentState',
      if (firstAppearChapterId != null) '首次出场章节：$firstAppearChapterId',
    ].join('\n\n');
    await _stageCreateChange(
      resourcePath: 'characters/$newId',
      resourceType: 'characters',
      resourceId: newId,
      previewText: previewText,
      source: workingChangeSourceAi,
      toolName: 'Create',
      summary: 'AI created character $name',
    );
    if (avatarAssetId != null && avatarAssetId.isNotEmpty) {
      await _contentService.updateCharacterAvatarAndPhotos(
        entryId: newId,
        avatarAssetId: avatarAssetId,
      );
    }
    return {'path': 'characters/$newId', 'id': newId, 'created': true};
  }

  Future<Map<String, dynamic>> _handleCreateForeshadowing(
    ParsedPath parsed,
    Map<String, dynamic> input,
  ) async {
    final title = input['title'] as String;
    final finalStatus =
        input['status'] as String? ?? foreshadowingStatusPlanted;
    final setup = input['setup'] as String? ?? '';
    final payoff = input['payoff'] as String? ?? '';
    String? position(String field) {
      final value = input[field] as String?;
      return value == null || value.isEmpty ? null : value;
    }

    final setupChapterId = position('setup_chapter_id');
    final payoffChapterId = position('payoff_chapter_id');
    final duplicateTitleError = await _validateForeshadowingTitleAvailable(
      contentService: _contentService,
      title: title,
      path: 'foreshadowing',
      operation: 'create',
    );
    if (duplicateTitleError != null) {
      return duplicateTitleError;
    }

    try {
      return await _withWorkingChangeTransaction(() async {
        final newId = await _contentService.createForeshadowing(
          title: title,
          setup: setup,
          payoff: payoff,
          status: finalStatus,
          setupChapterId: setupChapterId,
          payoffChapterId: payoffChapterId,
          setupSceneId: position('setup_scene_id'),
          payoffSceneId: position('payoff_scene_id'),
        );
        final previewText = [
          title,
          if (setup.isNotEmpty) '铺垫：$setup',
          if (payoff.isNotEmpty) '回收：$payoff',
          '状态：$finalStatus',
          if (setupChapterId != null) '铺垫章节：$setupChapterId',
          if (payoffChapterId != null) '兑现章节：$payoffChapterId',
        ].join('\n\n');
        await _stageCreateChange(
          resourcePath: 'foreshadowing/$newId',
          resourceType: 'foreshadowing',
          resourceId: newId,
          previewText: previewText,
          source: workingChangeSourceAi,
          toolName: 'Create',
          summary: 'AI created foreshadowing $title',
        );
        return {'path': 'foreshadowing/$newId', 'id': newId, 'created': true};
      });
    } on FormatException catch (error) {
      return AiToolManager._structuredWriteError(
        path: 'foreshadowing',
        errorCode: ToolErrorCode.invalid_argument,
        message: error.message,
      );
    }
  }

  Future<Map<String, dynamic>> _handleCreateLocation(
    ParsedPath parsed,
    Map<String, dynamic> input,
  ) async {
    if (createLocationCallback == null) {
      return AiToolManager._structuredWriteError(
        path: 'locations',
        errorCode: ToolErrorCode.unavailable,
        message: 'CreateLocation not configured',
        operation: 'create',
      );
    }
    final name = input['name'] as String;
    final rawType = input['type'] as String?;
    final type = rawType == null || rawType.isEmpty
        ? locationTypeGeneric
        : rawType;
    final parentValue = input['parent_id'] as String?;
    final parentId = parentValue == null || parentValue.isEmpty
        ? null
        : parentValue;
    if (type != locationTypeWorld && parentId == null) {
      return AiToolManager._structuredWriteError(
        path: 'locations',
        errorCode: ToolErrorCode.invalid_argument,
        message:
            'CreateLocation requires parent_id for non-world locations. If no world location exists, create a type=world location first.',
        operation: 'create',
        missingFields: const ['parent_id'],
        hint:
            'Create a type=world location first, then use its id as parent_id.',
      );
    }
    try {
      final id = await createLocationCallback!(
        name: name,
        description: input['description'] as String?,
        type: type,
        parentId: parentId,
      );
      return {
        'ok': true,
        'path': 'locations/$id',
        'id': id,
        'name': name,
        'created': true,
      };
    } on DuplicateLocationNameException catch (error) {
      return _duplicateLocationNameError(parsed, error, 'create');
    } catch (e) {
      return AiToolManager._structuredWriteError(
        path: 'locations',
        errorCode: ToolErrorCode.internal,
        message: 'Failed to create location',
        operation: 'create',
      );
    }
  }

  Future<Map<String, dynamic>> _handleCreateItem(
    ParsedPath parsed,
    Map<String, dynamic> fields,
  ) async {
    final collection = parsed.collection;
    final itemType = parsed._resource!.schema.itemType!;
    final title = fields['title'] as String;
    final itemContent = fields['content'] as String? ?? '';
    final category = fields['category'] as String? ?? '';

    final duplicateTitleError = await _validateItemTitleAvailable(
      contentService: _contentService,
      collection: collection,
      itemType: itemType,
      title: title,
      path: collection,
      operation: 'create',
    );
    if (duplicateTitleError != null) {
      return duplicateTitleError;
    }

    final newId = await _contentService.createItem(
      type: itemType,
      title: title,
      content: itemContent,
      category: category,
    );

    final previewText = [
      title,
      if (itemContent.isNotEmpty) itemContent,
    ].join('\n\n');
    await _stageCreateChange(
      resourcePath: '$collection/$newId',
      resourceType: collection,
      resourceId: newId,
      previewText: previewText,
      source: workingChangeSourceAi,
      toolName: 'Create',
      summary: 'AI created $collection entry',
    );
    return {'path': '$collection/$newId', 'id': newId, 'created': true};
  }
}

bool _jsonLikeValuesEqual(Object? left, Object? right) {
  if (identical(left, right)) {
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (!_jsonLikeValuesEqual(left[index], right[index])) {
        return false;
      }
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) {
      return false;
    }
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_jsonLikeValuesEqual(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  return left == right;
}

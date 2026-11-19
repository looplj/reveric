// 职责: AI 小说工具编辑能力，负责 Edit 及可回滚 working change patch 记录。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_read.dart
//   lib/shared/services/ai/tools_outline.dart
//   lib/shared/services/working_overlay.dart
// ignore_for_file: use_null_aware_elements
part of 'tools.dart';

const _editDescription = '''替换资源字段中的精确文本。

行为：
- chapters：修改 `content` 成功时返回 `content_word_counts`，其中 `with_punctuation` 含标点，`without_punctuation` 不含标点。
- 先 Read 确认精确文本。''';

/// Edit 的 input schema。顶层只有 path / old_text / new_text / all 四个键。
///
/// **新增顶层字段前必须获得人工确认。** Edit 是通用的精确文本替换，没有 `fields`
/// 那样的开放袋子，所以任何路径专属参数加进来都会常驻在每一次 Edit 的 schema 里，
/// 却只服务一条路径。
final _editInputSchema = const {
  'type': 'object',
  'properties': {
    'path': {
      'type': 'string',
      'description':
          '必须提供完整字段路径：资源 path + "/" + 字段名，例如 chapters/{chapter_id}/content；不能省略字段名。',
    },
    'old_text': {
      'type': 'string',
      'description':
          '要在字段中查找的精确文本。逐字符匹配，缩进、行首/行尾空格与换行都必须一致 —— '
          '编辑大纲等结构化文本时不要省略行首空格。空字段初始化传空字符串。',
    },
    'new_text': {'type': 'string', 'description': '替换文本。'},
    'all': {'type': 'boolean', 'description': '是否替换所有精确匹配。默认为 false。'},
  },
  'required': ['path', 'old_text', 'new_text'],
  'additionalProperties': false,
};

/// Edit 的当前文本：DB null 与空字符串同义，交给 [_replaceExactText]
/// （空字段初始化 / old_text_not_found）。非字符串才是 not_text_field。
String? _coerceEditSourceText(Object? value) {
  if (value == null) {
    return '';
  }
  if (value is String) {
    return value;
  }
  return null;
}

Map<String, dynamic> _editNotTextFieldError({
  required String path,
  required String field,
}) {
  return AiToolManager._structuredWriteError(
    path: path,
    errorCode: ToolErrorCode.unsupported,
    message: 'Field "$field" is not a text field',
    operation: 'edit',
  );
}

/// 字段错误和纠正建议只读取命中的资源节点，子资源不继承父字段权限。
Map<String, dynamic> _editFieldNotEditableError({
  required String path,
  required _ResourceDefinition node,
  required String field,
  required String noun,
}) {
  final writeScalar = _writeScalarFields(node);
  if (writeScalar.contains(field)) {
    return _resourceError(
      path,
      ToolErrorCode.unsupported,
      'Field "$field" of $noun is written with Write, not Edit. Use Write on $path with a value.',
      hint:
          'Write-only fields: ${writeScalar.join(', ')}. Editable with Edit: ${_editableFieldList(node)}.',
    );
  }
  return _resourceError(
    path,
    node.fields[field]?.canRead == true
        ? ToolErrorCode.permission_denied
        : ToolErrorCode.invalid_argument,
    'Unsupported $noun field: $field. Editable fields: ${_editableFieldList(node)}.',
  );
}

Map<String, dynamic> _editFieldRequiredError(ParsedPath parsed) {
  final paths = [
    for (final field in parsed._resource!.schema.editableFields)
      _joinDisplayPath(parsed.displayPath, field),
  ];
  final hint = paths.isEmpty
      ? 'This resource has no editable text fields.'
      : 'Use one of these field paths: ${paths.join(', ')}.';
  return {
    ...AiToolManager._structuredWriteError(
      path: parsed.displayPath,
      errorCode: ToolErrorCode.invalid_argument,
      message: 'Edit requires an explicit field path. $hint',
      operation: 'edit',
      hint: hint,
    ),
    'editable_paths': paths,
  };
}

/// 容错接受只有正文的故事状态资源路径，显式字段始终原样校验。
ParsedPath _parseEditPath(String path) {
  final parsed = parseAiToolPath(path);
  if (parsed.collection != 'story_state' ||
      parsed.hasField ||
      parsed._resource == null) {
    return parsed;
  }
  return parseAiToolPath(_joinDisplayPath(parsed.displayPath, 'content'));
}

mixin _AiToolManagerEditMixin
    on
        _AiToolManagerBase,
        _AiToolManagerReadMixin,
        _AiToolManagerOutlineMixin,
        _AiToolManagerCanvasMixin {
  /// Edit、Replace 与预览共享目标权限，业务执行仍重新检查目标状态。
  Map<String, dynamic>? _prepareEditTarget(ParsedPath parsed) =>
      _contentKindGate(parsed) ??
      _resourceOperationGate(parsed, _ResourceTool.edit);

  Future<Map<String, dynamic>> _handleEdit(Map<String, dynamic> input) async {
    final path = _parseStringArgument(input['path'], trim: true);
    final parsed = _parseEditPath(path);
    final oldText = _parseTextArgument(input['old_text']);
    final newText = _parseTextArgument(input['new_text']);
    final replaceAll = _parseBoolArgument(input['all']);

    return _attachMutationResourcePath(
      parsed,
      await _applyEditToPath(parsed, oldText, newText, replaceAll),
    );
  }

  /// 复用 Edit 的目标分发和写入守卫，但保留原始结果的顶层 path 供批量调用聚合。
  Future<Map<String, dynamic>> _applyEditToPath(
    ParsedPath parsed,
    String oldText,
    String newText,
    bool replaceAll,
  ) async {
    final targetError = _prepareEditTarget(parsed);
    if (targetError != null) {
      return targetError;
    }

    if (parsed.collection == 'relations') {
      return _editToolRelation(
        _contentService,
        parsed,
        oldText,
        newText,
        replaceAll,
      );
    }
    if (isScreenplayPath(parsed)) {
      return _executeScreenplay(
        parsed,
        parsed._resource!.operation(_ResourceTool.edit)!,
        edit: (oldText: oldText, newText: newText, replaceAll: replaceAll),
      );
    }

    if (isCanvasPath(parsed)) {
      return _executeCanvas(
        parsed,
        parsed._resource!.operation(_ResourceTool.edit)!,
        edit: (oldText: oldText, newText: newText, replaceAll: replaceAll),
      );
    }

    if (parsed.collection == 'outlines') {
      return _handleEditOutline(parsed, oldText, newText, replaceAll);
    }

    if (parsed._isWorkMetadata) {
      return _editWork(parsed, oldText, newText, replaceAll);
    }

    if (parsed.collection == 'story_state') {
      return _editStoryState(parsed, oldText, newText, replaceAll);
    }

    if (parsed._resource!.schema.isItemCollection) {
      return _editItem(parsed, oldText, newText, replaceAll);
    }

    if (parsed.collection == 'locations') {
      return _editLocation(parsed, oldText, newText, replaceAll);
    }

    if (parsed.collection == 'chapters') {
      return _editChapter(parsed, oldText, newText, replaceAll);
    }
    if (parsed.collection == 'volumes') {
      return _editVolume(parsed, oldText, newText, replaceAll);
    }

    if (parsed.collection == 'characters') {
      return _editCharacter(parsed, oldText, newText, replaceAll);
    }

    if (parsed.collection == 'foreshadowing') {
      return _editForeshadowing(parsed, oldText, newText, replaceAll);
    }

    if (parsed.collection == 'lore' || parsed.collection == 'materials') {
      return _editDocument(parsed, oldText, newText, replaceAll);
    }

    return AiToolManager._structuredWriteError(
      path: parsed.displayPath,
      errorCode: ToolErrorCode.invalid_argument,
      message: 'Unknown collection: ${parsed.collection}',
      operation: 'edit',
    );
  }

  /// 编辑当前故事状态；尚无快照时与 Read 一致，按空文本处理。
  Future<Map<String, dynamic>> _editStoryState(
    ParsedPath parsed,
    String oldText,
    String newText,
    bool replaceAll,
  ) async {
    const path = 'story_state';
    final snapshot = await _contentService.getCurrentStateSnapshot();
    final updated = AiToolManager._replaceExactText(
      snapshot?.content ?? '',
      oldText,
      newText,
      path: path,
      replaceAll: replaceAll,
    );
    if (updated.error != null) {
      return AiToolManager._replaceTextErrorResult(updated);
    }

    await _contentService.writeCurrentStateSnapshot(
      content: updated.value ?? '',
      createdBy: novelStateSnapshotCreatedByUser,
    );
    return {
      'path': path,
      'edited': updated.changed,
      'match_count': updated.matchCount,
      'status': novelStateSnapshotStatusActive,
    };
  }

  Future<Map<String, dynamic>> _editChapter(
    ParsedPath parsed,
    String oldText,
    String newText,
    bool replaceAll,
  ) async {
    final id = parsed.id!;
    final field = parsed.field!;
    final chapter = await _contentService.getChapterById(id);
    if (chapter == null) {
      return AiToolManager._structuredWriteError(
        path: 'chapters/$id',
        errorCode: ToolErrorCode.not_found,
        message: 'Chapter not found: $id',
        operation: 'edit',
      );
    }
    if (!chapter.isChapter) {
      return AiToolManager._structuredWriteError(
        path: 'chapters/$id',
        errorCode: ToolErrorCode.unsupported,
        message:
            'Resource "$id" is a volume. Use "volumes/$id/outline" for volume outline.',
        operation: 'edit',
      );
    }
    if (chapter.stat == chapterStatPublished) {
      return AiToolManager._structuredWriteError(
        path: 'chapters/$id',
        errorCode: ToolErrorCode.locked,
        message:
            'Chapter "$id" is published and cannot be modified. Unpublish it in the UI first.',
        operation: 'edit',
      );
    }
    final readResult = await _readChapter(parsed);
    if (readResult.containsKey('error')) {
      return readResult;
    }
    final current = _coerceEditSourceText(readResult['value']);
    if (current == null) {
      return _editNotTextFieldError(path: 'chapters/$id/$field', field: field);
    }
    final updated = AiToolManager._replaceExactText(
      current,
      oldText,
      newText,
      path: 'chapters/$id/$field',
      replaceAll: replaceAll,
    );
    if (updated.error != null) {
      return AiToolManager._replaceTextErrorResult(updated);
    }
    final nextValue = updated.value ?? '';
    await _stageTextChange(
      resourcePath: 'chapters/$id/$field',
      resourceType: 'chapters',
      resourceId: id,
      field: field,
      oldText: current,
      newText: nextValue,
      source: workingChangeSourceAi,
      toolName: 'Edit',
      summary: 'AI edited chapter $field',
    );
    return {
      'path': 'chapters/$id/$field',
      'edited': updated.changed,
      'match_count': updated.matchCount,
      if (field == 'content')
        'content_word_counts': _chapterWordCount(nextValue),
    };
  }

  Future<Map<String, dynamic>> _editWork(
    ParsedPath parsed,
    String oldText,
    String newText,
    bool replaceAll,
  ) async {
    final field = parsed.field!;
    if (novelReader == null || novelWriter == null) {
      return AiToolManager._structuredWriteError(
        path: parsed.displayPath,
        errorCode: ToolErrorCode.unavailable,
        message: 'Work metadata is unavailable in this AI session',
        operation: 'edit',
      );
    }

    final novel = await novelReader!.call();
    if (novel == null) {
      return AiToolManager._structuredWriteError(
        path: parsed.displayPath,
        errorCode: ToolErrorCode.unavailable,
        message: 'Work metadata is unavailable in this AI session',
        operation: 'edit',
      );
    }

    final readResult = await _readWork(parsed);
    if (readResult.containsKey('error')) {
      return readResult;
    }
    final currentValue = _coerceEditSourceText(readResult['value']);
    if (currentValue == null) {
      return _editNotTextFieldError(path: parsed.displayPath, field: field);
    }

    final updated = AiToolManager._replaceExactText(
      currentValue,
      oldText,
      newText,
      path: parsed.displayPath,
      replaceAll: replaceAll,
    );
    if (updated.error != null) {
      return AiToolManager._replaceTextErrorResult(updated);
    }
    // title/author_name/description/category/tags 属作品元数据，直写 DB，不产生可回滚 working change。
    final value = updated.value!;
    final nextValue = field == 'tags'
        ? value
              .split(',')
              .map((tag) => tag.trim())
              .where((tag) => tag.isNotEmpty)
              .toList()
        : value;
    final error = await _persistWorkMetadata(
      novelWriter!,
      {field: nextValue},
      path: parsed.displayPath,
      operation: 'edit',
    );
    if (error != null) {
      return error;
    }
    return {
      'path': parsed.displayPath,
      'edited': updated.changed,
      'match_count': updated.matchCount,
    };
  }

  Future<Map<String, dynamic>> _editItem(
    ParsedPath parsed,
    String oldText,
    String newText,
    bool replaceAll,
  ) async {
    final collection = parsed.collection;
    final id = parsed.id!;
    final field = parsed.field!;
    final entry = await _contentService.getItemById(id);
    if (entry == null || entry.type != parsed._resource!.schema.itemType) {
      return AiToolManager._structuredWriteError(
        path: '$collection/$id',
        errorCode: ToolErrorCode.not_found,
        message: 'Not found: $id',
        operation: 'edit',
      );
    }
    final current = field == 'title' ? entry.title : entry.content;

    final updated = AiToolManager._replaceExactText(
      current,
      oldText,
      newText,
      path: '$collection/$id/$field',
      replaceAll: replaceAll,
    );
    if (updated.error != null) {
      return AiToolManager._replaceTextErrorResult(updated);
    }
    await _stageTextChange(
      resourcePath: '$collection/$id/$field',
      resourceType: collection,
      resourceId: id,
      field: field,
      oldText: current,
      newText: updated.value!,
      source: workingChangeSourceAi,
      toolName: 'Edit',
      summary: 'AI edited $collection $field',
    );
    return {
      'id': id,
      'field': field,
      'edited': updated.changed,
      'match_count': updated.matchCount,
    };
  }

  Future<Map<String, dynamic>> _editVolume(
    ParsedPath parsed,
    String oldText,
    String newText,
    bool replaceAll,
  ) async {
    final id = parsed.id!;
    final field = parsed.field!;
    final volume = await _contentService.getChapterById(id);
    if (volume == null || !volume.isVolume) {
      return AiToolManager._structuredWriteError(
        path: 'volumes/$id',
        errorCode: ToolErrorCode.not_found,
        message: 'Volume not found: $id',
        operation: 'edit',
      );
    }
    final readResult = await _readVolume(parsed);
    if (readResult.containsKey('error')) {
      return readResult;
    }
    final current = _coerceEditSourceText(readResult['value']);
    if (current == null) {
      return _editNotTextFieldError(path: 'volumes/$id/$field', field: field);
    }
    final updated = AiToolManager._replaceExactText(
      current,
      oldText,
      newText,
      path: 'volumes/$id/$field',
      replaceAll: replaceAll,
    );
    if (updated.error != null) {
      return AiToolManager._replaceTextErrorResult(updated);
    }
    await _stageTextChange(
      resourcePath: 'volumes/$id/$field',
      resourceType: 'volumes',
      resourceId: id,
      field: field,
      oldText: current,
      newText: updated.value!,
      source: workingChangeSourceAi,
      toolName: 'Edit',
      summary: 'AI edited volume $field',
    );
    return {
      'path': 'volumes/$id/$field',
      'edited': updated.changed,
      'match_count': updated.matchCount,
    };
  }

  Future<Map<String, dynamic>> _editCharacter(
    ParsedPath parsed,
    String oldText,
    String newText,
    bool replaceAll,
  ) async {
    final id = parsed.id!;
    final field = parsed.field!;
    final readResult = await _readCharacter(parsed);
    if (readResult.containsKey('error')) {
      return readResult;
    }
    final current = _coerceEditSourceText(readResult['value']);
    if (current == null) {
      return _editNotTextFieldError(
        path: 'characters/$id/$field',
        field: field,
      );
    }
    final updated = AiToolManager._replaceExactText(
      current,
      oldText,
      newText,
      path: 'characters/$id/$field',
      replaceAll: replaceAll,
    );
    if (updated.error != null) {
      return AiToolManager._replaceTextErrorResult(updated);
    }
    await _stageTextChange(
      resourcePath: 'characters/$id/$field',
      resourceType: 'characters',
      resourceId: id,
      field: field,
      oldText: current,
      newText: updated.value!,
      source: workingChangeSourceAi,
      toolName: 'Edit',
      summary: 'AI edited character $field',
    );
    return {
      'id': id,
      'field': field,
      'edited': updated.changed,
      'match_count': updated.matchCount,
    };
  }

  Future<Map<String, dynamic>> _editForeshadowing(
    ParsedPath parsed,
    String oldText,
    String newText,
    bool replaceAll,
  ) async {
    final id = parsed.id!;
    final field = parsed.field!;
    final readResult = await _readForeshadowing(parsed);
    if (readResult.containsKey('error')) {
      return readResult;
    }
    final current = _coerceEditSourceText(readResult['value']);
    if (current == null) {
      return _editNotTextFieldError(
        path: 'foreshadowing/$id/$field',
        field: field,
      );
    }
    final updated = AiToolManager._replaceExactText(
      current,
      oldText,
      newText,
      path: 'foreshadowing/$id/$field',
      replaceAll: replaceAll,
    );
    if (updated.error != null) {
      return AiToolManager._replaceTextErrorResult(updated);
    }
    await _stageTextChange(
      resourcePath: 'foreshadowing/$id/$field',
      resourceType: 'foreshadowing',
      resourceId: id,
      field: field,
      oldText: current,
      newText: updated.value!,
      source: workingChangeSourceAi,
      toolName: 'Edit',
      summary: 'AI edited foreshadowing $field',
    );
    return {
      'id': id,
      'field': field,
      'edited': updated.changed,
      'match_count': updated.matchCount,
    };
  }

  Future<Map<String, dynamic>> _editLocation(
    ParsedPath parsed,
    String oldText,
    String newText,
    bool replaceAll,
  ) async {
    final id = parsed.id!;
    final field = parsed.field!;
    final readResult = await _readLocation(parsed);
    if (readResult.containsKey('error')) {
      return readResult;
    }
    final current = _coerceEditSourceText(readResult['value']);
    if (current == null) {
      return _editNotTextFieldError(path: 'locations/$id/$field', field: field);
    }
    final updated = AiToolManager._replaceExactText(
      current,
      oldText,
      newText,
      path: 'locations/$id/$field',
      replaceAll: replaceAll,
    );
    if (updated.error != null) {
      return AiToolManager._replaceTextErrorResult(updated);
    }
    try {
      await _stageTextChange(
        resourcePath: 'locations/$id/$field',
        resourceType: 'locations',
        resourceId: id,
        field: field,
        oldText: current,
        newText: updated.value!,
        source: workingChangeSourceAi,
        toolName: 'Edit',
        summary: 'AI edited location $field',
      );
    } on DuplicateLocationNameException catch (error) {
      return _duplicateLocationNameError(parsed, error, 'edit');
    }
    return {
      'id': id,
      'field': field,
      'edited': updated.changed,
      'match_count': updated.matchCount,
    };
  }

  Future<Map<String, dynamic>> _editDocument(
    ParsedPath parsed,
    String oldText,
    String newText,
    bool replaceAll,
  ) async {
    final collection = parsed.collection;
    final documentType = parsed._resource!.schema.documentType!;
    final namePath = parsed.namePath;
    final field = parsed.field!;
    final document = await _contentService.documentsService
        .getDocumentByNamePath(type: documentType, namePath: namePath);
    if (document == null) {
      final pathStr = namePath.join('/');
      return AiToolManager._structuredWriteError(
        path: '$collection/$pathStr',
        errorCode: ToolErrorCode.not_found,
        message: 'Not found: $pathStr',
        operation: 'edit',
      );
    }
    if (document.isFolder) {
      final pathStr = namePath.join('/');
      return AiToolManager._structuredWriteError(
        path: '$collection/$pathStr',
        errorCode: ToolErrorCode.failed_precondition,
        message: 'Cannot edit a folder. Only documents can be edited.',
        operation: 'edit',
      );
    }

    final pathStr = namePath.join('/');
    final readResult = await _readDocument(parsed);
    if (readResult.containsKey('error')) {
      return readResult;
    }
    final current = _coerceEditSourceText(readResult['value']);
    if (current == null) {
      return _editNotTextFieldError(
        path: '$collection/$pathStr/$field',
        field: field,
      );
    }
    final updated = AiToolManager._replaceExactText(
      current,
      oldText,
      newText,
      path: '$collection/$pathStr/$field',
      replaceAll: replaceAll,
    );
    if (updated.error != null) {
      return AiToolManager._replaceTextErrorResult(updated);
    }
    await _stageTextChange(
      resourcePath: '$collection/${document.id}/$field',
      resourceType: collection,
      resourceId: document.id,
      field: field,
      oldText: current,
      newText: updated.value!,
      source: workingChangeSourceAi,
      toolName: 'Edit',
      summary: 'AI edited $collection $field',
    );
    return {
      'path': '$collection/$pathStr/$field',
      'edited': updated.changed,
      'match_count': updated.matchCount,
    };
  }
}

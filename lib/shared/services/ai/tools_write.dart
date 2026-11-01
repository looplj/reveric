// 职责: AI 小说工具写入能力，负责 Write 及可回滚 working change patch 记录。
// 关联文件:
//   lib/shared/services/ai/tools_read.dart
//   lib/shared/services/working_overlay.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/utils/storage_paths.dart
// 遵循的 Rules:
//   .agents/rules/file-access.md
//   .agents/rules/data-deletion.md
//   .agents/rules/error-handling.md
// ignore_for_file: use_null_aware_elements
part of 'tools.dart';

final _writeDescription =
    '''写入资源字段。整体覆盖用 Write，替换局部文本用 Edit。

- 多字段写入跳过未知或只读字段，数组、对象内部的同类键一并跳过，全部在 ignored_fields 中按 `beats[0].foo` 这样的位置列出；全部被跳过时 updated=false。重复提供同一字段时，规范化后的值必须一致。
- 须用 Create 而非 Write 创建：${_buildCreateOnlyCollectionList()}。
- lore/materials：标题路径，不存在则自动创建文档；不可写入文件夹。
- 数组写入（value 和 fields）提交完整的目标列表，未保留的项从列表中移除，空数组清空列表。实体对象逐项按 id 保留身份，省略 id 的项新建；引用 ID 列表只调整引用，不删除被引用实体。追加或局部修改时，先 Read，再合并后提交。
- 已发布章节不可写 ${_publishedLockedChapterFields.join('、')}；其余可写字段照常。

示例：{"path": "profile/description", "value": "新简介"}
''';

/// Write 的 input schema。顶层只有 path / value / fields 三个键。
///
/// **新增顶层字段前必须获得人工确认。** 路径专属的参数一律放进 `fields`——
/// 它是 `additionalProperties: true` 的开放袋子。加顶层字段不会让任何调用变得可行，只会：
/// - 让一个只服务极少数路径的键常驻在每一次 Write 的 schema 里；
/// - 制造「同一个键有两个合法位置」的歧义——Create 为此专门写了 `conflicting_fields`
///   校验，不要再造一个需要同样兜底的入口。
final _writeInputSchema = const {
  'type': 'object',
  'properties': {
    'path': {'type': 'string', 'description': '要写入的资源或字段路径。'},
    'value': {
      'description':
          '单字段写入值，path 指向字段时使用。'
          '取值形状按路径字段说明；字符串去除首尾空白，整数字段四舍五入。',
    },
    'fields': {
      'type': 'object',
      'description': '多字段写入的字段集合，传 JSON 对象；未提供的字段不修改。字符串去除首尾空白，普通值数组去重。',
      'additionalProperties': true,
    },
  },
  'required': ['path'],
  'additionalProperties': false,
};

/// 已发布章节仍允许写入的字段。
///
/// chronicler 在章节**发布之后**运行，它的写后产物（brief / tension / emotion /
/// events）必须能落库，否则整条链路在发布这一步就断了。正文和标题依然锁死 ——
/// 发布后改正文要走用户的正式流程，不是 AI 顺手改。
const _publishedWritableChapterFields = <String>[
  'outline',
  'brief',
  'tension',
  'emotion',
  'events',
];

/// 已发布章节被锁住的字段 = 可写字段减去 [_publishedWritableChapterFields]。
/// 描述里报的是「不能写哪些」，模型据此决定要不要发这次调用；由此派生而不是
/// 手抄，改白名单时描述自动跟上。
List<String> get _publishedLockedChapterFields => _writableFields('chapters')
    .where((field) => !_publishedWritableChapterFields.contains(field))
    .toList(growable: false);

/// chronicler 的结构化分析字段：直写 DB，不做可回滚文本 diff。
/// 它们不是用户逐字审阅的正文，做成 diff 既无意义也读不懂。
const _chapterAnalysisFields = <String>['tension', 'emotion', 'events'];

/// 在角色事务内部中止写入，完成回滚后再转换为工具错误。
class _CharacterWriteFailure implements Exception {
  const _CharacterWriteFailure(this.result);

  final Map<String, dynamic> result;
}

Map<String, dynamic> _duplicateLocationNameError(
  ParsedPath parsed,
  DuplicateLocationNameException error,
  String operation,
) => AiToolManager._structuredWriteError(
  path: parsed.displayPath,
  errorCode: ToolErrorCode.already_exists,
  message: 'A location named "${error.name}" already exists in this work.',
  operation: operation,
  hint: 'Choose a unique location name.',
);

Map<String, dynamic> _skippedReadOnlyWriteResult({
  required String path,
  required String field,
  required String resourceLabel,
  String? hint,
}) {
  final message =
      hint ??
      '$resourceLabel field "$field" is read-only or not writable and was skipped.';
  return {
    'path': path,
    'updated': false,
    'error': message,
    'error_code': ToolErrorCode.permission_denied.name,
    'fields': const <String>[],
    'ignored_fields': [field],
    'hint': message,
  };
}

Future<Map<String, dynamic>?> _validateForeshadowingTitleAvailable({
  required NovelContentService contentService,
  required String title,
  required String path,
  required String operation,
  String? currentId,
}) async {
  for (final entry in await contentService.getForeshadowings()) {
    if (entry.id == currentId) {
      continue;
    }
    if (entry.title != title) {
      continue;
    }

    return AiToolManager._structuredWriteError(
      path: path,
      errorCode: ToolErrorCode.already_exists,
      message: 'Foreshadowing title already exists: $title',
      operation: operation,
      hint: 'Use a unique foreshadowing title before writing.',
    );
  }
  return null;
}

Future<Map<String, dynamic>?> _validateItemTitleAvailable({
  required NovelContentService contentService,
  required String collection,
  required String itemType,
  required String title,
  required String path,
  required String operation,
  String? currentId,
}) async {
  for (final entry in await contentService.getItemsByType(itemType)) {
    if (entry.id == currentId) {
      continue;
    }
    if (entry.title != title) {
      continue;
    }

    return AiToolManager._structuredWriteError(
      path: path,
      errorCode: ToolErrorCode.already_exists,
      message: '$collection title already exists: $title',
      operation: operation,
      hint: 'Use a unique title before writing.',
    );
  }
  return null;
}

Future<Map<String, dynamic>?> _validateDocumentTitleAvailable({
  required NovelContentService contentService,
  required String collection,
  required String documentType,
  required String title,
  required String path,
  required String operation,
  String? parentId,
  String? currentId,
}) async {
  final available = await contentService.documentsService.isTitleAvailable(
    type: documentType,
    title: title,
    parentId: parentId,
    excludeId: currentId,
  );
  if (available) {
    return null;
  }

  return AiToolManager._structuredWriteError(
    path: path,
    errorCode: ToolErrorCode.already_exists,
    message: '$collection title already exists in this folder: $title',
    operation: operation,
    hint: 'Use a unique title in the target folder before writing.',
  );
}

class _PreparedWrite extends _WritePayloadResult {
  const _PreparedWrite(
    super.fields,
    super.error, {
    this.ignoredFields = const [],
  });

  final List<String> ignoredFields;
}

mixin _AiToolManagerWriteMixin
    on
        _AiToolManagerBase,
        _AiToolManagerReadMixin,
        _AiToolManagerOutlineMixin,
        _AiToolManagerCanvasMixin {
  /// 预览与执行共用路径、参数解析和静态校验；预览不触发画布升级交互。
  Future<_PreparedWrite> _prepareWrite(
    ParsedPath parsed,
    Map<String, dynamic> input, {
    bool forPreview = false,
  }) async {
    if (parsed.isRoot) {
      return _PreparedWrite(
        null,
        AiToolManager._structuredWriteError(
          path: '/',
          errorCode: ToolErrorCode.permission_denied,
          message: 'Cannot write to root path',
        ),
      );
    }
    final targetError =
        _contentKindGate(parsed) ??
        _resourceOperationGate(parsed, _ResourceTool.write);
    if (targetError != null) {
      return _PreparedWrite(null, targetError);
    }
    final payload = AiToolManager._resolveWritePayload(parsed, input);
    if (payload.error != null) {
      return _PreparedWrite(null, payload.error);
    }
    // 字段被跳光时 fields 为空且没有 error，调用方据此绕开执行器，避免创建空
    // 文档或故事状态快照。
    final prepared = _prepareResourceInput(
      parsed,
      payload.fields!,
      create: false,
    );
    return _PreparedWrite(
      prepared.fields,
      prepared.error,
      ignoredFields: prepared.ignoredFields,
    );
  }

  Future<Map<String, dynamic>> _handleWrite(Map<String, dynamic> input) async {
    final parsed = ParsedPath.parse(
      // 路径要拿去解析和查找，带空白会静默 miss；pattern 才保留原样。
      _parseStringArgument(input['path'], trim: true),
      schemaLookup: _getCollectionSchema,
    );
    final prepared = await _prepareWrite(parsed, input);
    return _attachIgnoredFields(
      prepared.error ??
          (prepared.fields!.isEmpty
              ? {
                  'path': parsed.displayPath,
                  'updated': false,
                  'fields': const <String>[],
                }
              : await _executePreparedWrite(parsed, prepared.fields!)),
      prepared.ignoredFields,
    );
  }

  Future<Map<String, dynamic>> _executePreparedWrite(
    ParsedPath parsed,
    Map<String, dynamic> fields,
  ) async {
    if (parsed.collection == 'relations') {
      return _writeToolRelation(_contentService, parsed, fields);
    }
    if (isScreenplayPath(parsed)) {
      return _executeScreenplay(
        parsed,
        parsed._resource!.operation(_ResourceTool.write)!,
        fields: fields,
      );
    }
    if (isCanvasPath(parsed)) {
      return _executeCanvas(
        parsed,
        parsed._resource!.operation(_ResourceTool.write)!,
        fields: fields,
      );
    }
    if (parsed.collection == 'outlines') {
      return _attachMutationResourcePath(
        parsed,
        parsed.isOutlineBeat && parsed.isResourceListing
            ? await _writeOutlineBeats(parsed, fields)
            : await _writeOutlineFields(parsed, fields),
      );
    }
    if (parsed.collection == 'story_state') {
      return _attachMutationResourcePath(
        parsed,
        await _writeStoryState(parsed, fields),
      );
    }
    if (parsed.collection == 'profile') {
      return _attachMutationResourcePath(
        parsed,
        await _writeProfile(parsed, fields),
      );
    }
    if (parsed._resource!.schema.isItemCollection) {
      return _attachMutationResourcePath(
        parsed,
        await _enrichNotFoundError(parsed, await _writeItem(parsed, fields)),
      );
    }
    if (parsed.collection == 'locations') {
      return _attachMutationResourcePath(
        parsed,
        await _enrichNotFoundError(
          parsed,
          await _writeLocation(parsed, fields),
        ),
      );
    }
    if (parsed.collection == 'chapters' || parsed.collection == 'volumes') {
      final result = parsed.collection == 'chapters'
          ? await _writeChapter(parsed, fields)
          : await _writeVolume(parsed, fields);
      return _attachMutationResourcePath(
        parsed,
        await _enrichNotFoundError(parsed, result),
      );
    }
    if (parsed.collection == 'characters') {
      return _attachMutationResourcePath(
        parsed,
        await _enrichNotFoundError(
          parsed,
          await _writeCharacter(parsed, fields),
        ),
      );
    }
    if (parsed.collection == 'foreshadowing') {
      return _attachMutationResourcePath(
        parsed,
        await _enrichNotFoundError(
          parsed,
          await _writeForeshadowing(parsed, fields),
        ),
      );
    }
    if (parsed.collection == 'lore' || parsed.collection == 'materials') {
      return _attachMutationResourcePath(
        parsed,
        await _enrichNotFoundError(
          parsed,
          await _writeDocument(parsed, fields),
        ),
      );
    }
    return AiToolManager._structuredWriteError(
      path: parsed.displayPath,
      errorCode: ToolErrorCode.invalid_argument,
      message: 'Unknown collection: ${parsed.collection}',
    );
  }

  Future<Map<String, dynamic>> _writeProfile(
    ParsedPath parsed,
    Map<String, dynamic> fields,
  ) async {
    if (novelWriter == null) {
      return AiToolManager._structuredWriteError(
        path: 'profile',
        errorCode: ToolErrorCode.unavailable,
        message: 'Work profile is unavailable in this AI session',
      );
    }

    if (fields.isEmpty) {
      return {'path': 'profile', 'updated': false, 'fields': const <String>[]};
    }
    // 作品元数据由宿主一次保存，避免逐字段更新覆盖同批次的其他字段。
    // tags 的逗号分隔文本在持久化边界转换为标签列表。
    final current = await _readProfile(parseAiToolPath('profile'));
    if (current.containsKey('error')) {
      return current;
    }
    final directWrites = <String, dynamic>{};
    final changedFields = <String>[];
    for (final entry in fields.entries) {
      final nextValue = entry.value as String;
      if (entry.key != 'tags' && current[entry.key] == nextValue) {
        continue;
      }
      final normalized = entry.key == 'tags'
          ? nextValue
                .split(',')
                .map((tag) => tag.trim())
                .where((tag) => tag.isNotEmpty)
                .toList()
          : nextValue;
      if (entry.key == 'tags') {
        final oldTags = (current['tags'] as String? ?? '')
            .split(',')
            .map((tag) => tag.trim())
            .where((tag) => tag.isNotEmpty)
            .toList();
        if (const DeepCollectionEquality().equals(oldTags, normalized)) {
          continue;
        }
      }
      directWrites[entry.key] = normalized;
      changedFields.add(entry.key);
    }
    if (directWrites.isNotEmpty) {
      await novelWriter!.call(directWrites);
    }
    return {
      'path': parsed.displayPath,
      'updated': changedFields.isNotEmpty,
      'fields': changedFields,
    };
  }

  /// `Write story_state` —— 覆盖当前故事状态，保留历史版本。
  Future<Map<String, dynamic>> _writeStoryState(
    ParsedPath parsed,
    Map<String, dynamic> fields,
  ) async {
    final snapshotContent = fields['content'] as String? ?? '';
    if (snapshotContent.isEmpty) {
      return AiToolManager._structuredWriteError(
        path: 'story_state',
        errorCode: ToolErrorCode.invalid_argument,
        message: 'Story state snapshot content must be a non-empty string.',
        hint: 'Pass fields: {"content": "<snapshot markdown>"}.',
      );
    }

    final current = await _contentService.getCurrentStateSnapshot();
    if (current?.content == snapshotContent) {
      return {
        'path': 'story_state',
        'updated': false,
        'fields': const <String>[],
      };
    }
    await _contentService.writeCurrentStateSnapshot(content: snapshotContent);
    return {
      'path': 'story_state',
      'updated': true,
      'fields': const ['content'],
      'status': novelStateSnapshotStatusActive,
    };
  }

  Future<Map<String, dynamic>> _writeChapter(
    ParsedPath parsed,
    Map<String, dynamic> fields,
  ) async {
    final id = parsed.id!;
    final field = parsed.field;
    final chapter = await _contentService.getChapterById(id);
    if (chapter == null) {
      return AiToolManager._structuredWriteError(
        path: parsed.displayPath,
        errorCode: ToolErrorCode.not_found,
        message: 'Chapter not found: $id',
      );
    }
    if (!chapter.isChapter) {
      return AiToolManager._structuredWriteError(
        path: parsed.displayPath,
        errorCode: ToolErrorCode.unsupported,
        message:
            'Resource "$id" is a volume. Use "volumes/$id/outline" for volume outline.',
        operation: 'write',
      );
    }
    if (chapter.stat == chapterStatPublished &&
        fields.keys.any(
          (name) => !_publishedWritableChapterFields.contains(name),
        )) {
      return AiToolManager._structuredWriteError(
        path: parsed.displayPath,
        errorCode: ToolErrorCode.locked,
        message:
            'Chapter "$id" is published; only continuity fields (${_publishedWritableChapterFields.join(', ')}) can be updated.',
      );
    }

    final nextVolumeId = fields['volume_id'] as String?;
    var volumeUpdated = false;
    if (fields.containsKey('volume_id')) {
      volumeUpdated = nextVolumeId != chapter.parentId;
      if (volumeUpdated) {
        if (nextVolumeId == null || nextVolumeId.isEmpty) {
          await _contentService.moveOutOfVolume(id);
        } else {
          final volume = await _contentService.getChapterById(nextVolumeId);
          if (volume == null) {
            return AiToolManager._structuredWriteError(
              path: 'chapters/$id/volume_id',
              errorCode: ToolErrorCode.invalid_argument,
              message: 'Volume not found: $nextVolumeId',
            );
          }
          if (!volume.isVolume) {
            return AiToolManager._structuredWriteError(
              path: 'chapters/$id/volume_id',
              errorCode: ToolErrorCode.unsupported,
              message: 'Resource "$nextVolumeId" is not a volume.',
            );
          }
          await _contentService.moveToVolume(id, nextVolumeId);
        }
      }
    }
    if (field == 'volume_id') {
      return {
        'path': parsed.displayPath,
        'updated': volumeUpdated,
        'volume_id': nextVolumeId,
      };
    }
    if (field != null && _chapterAnalysisFields.contains(field)) {
      return _writeChapterAnalysisField(id, field, fields[field]);
    }

    final originalText = <String, String?>{
      'title': chapter.title ?? '',
      'outline': chapter.outline,
      'brief': chapter.brief,
      'content': chapter.content,
    };
    final changedFields = <String>[];
    String? updatedContent;
    for (final name in parsed._resource!.schema.writeFields) {
      if (name == 'volume_id') {
        if (volumeUpdated) {
          changedFields.add(name);
        }
        continue;
      }
      if (!fields.containsKey(name)) {
        continue;
      }
      final value = fields[name];
      if (_chapterAnalysisFields.contains(name)) {
        final result = await _writeChapterAnalysisField(id, name, value);
        if (result['ok'] == false) {
          return result;
        }
        if (result['updated'] != true) {
          continue;
        }
      } else {
        final text = value as String;
        if ((originalText[name] ?? '') == text) {
          continue;
        }
        await _stageTextChange(
          resourcePath: 'chapters/$id/$name',
          resourceType: 'chapters',
          resourceId: id,
          field: name,
          oldText: originalText[name],
          newText: text,
          source: workingChangeSourceAi,
          toolName: 'Write',
          summary: 'AI updated chapter $name',
        );
        if (name == 'content') {
          updatedContent = text;
        }
      }
      changedFields.add(name);
    }
    return {
      'path': parsed.displayPath,
      'updated': changedFields.isNotEmpty,
      if (field == null) 'fields': changedFields,
      if (updatedContent != null)
        'content_word_counts': _chapterWordCount(updatedContent),
    };
  }

  /// 将公共入口已规范化的分析值交给章节业务服务。
  Future<Map<String, dynamic>> _writeChapterAnalysisField(
    String id,
    String field,
    Object? value,
  ) async {
    final path = 'chapters/$id/$field';
    final chapter = await _contentService.getChapterById(id);
    switch (field) {
      case 'tension':
        final tension = value as int?;
        if (chapter?.tension == tension) {
          return {'path': path, 'updated': false, 'value': tension};
        }
        await _contentService.updateChapterAnalysis(
          chapterId: id,
          tension: tension,
          clearTension: tension == null,
        );
        return {'path': path, 'updated': true, 'value': tension};
      case 'emotion':
        final emotion = (value as List).cast<String>();
        if (const DeepCollectionEquality().equals(
          chapter?.emotion ?? const [],
          emotion,
        )) {
          return {'path': path, 'updated': false, 'value': emotion};
        }
        await _contentService.updateChapterAnalysis(
          chapterId: id,
          emotion: emotion,
        );
        return {'path': path, 'updated': true, 'value': emotion};
      case 'events':
        // 持久化章内事件保留 title/summary 两列，空 state_change 不落入快照。
        final events = [
          for (final event in (value as List).cast<Map<String, dynamic>>())
            <String, dynamic>{
              'title': event['title'] as String? ?? '',
              'summary': event['summary'] as String? ?? '',
              if ((event['state_change'] as String?)?.isNotEmpty == true)
                'state_change': event['state_change'],
            },
        ];
        if (const DeepCollectionEquality().equals(
          chapter?.events ?? const [],
          events,
        )) {
          return {'path': path, 'updated': false, 'count': events.length};
        }
        await _contentService.updateChapterAnalysis(
          chapterId: id,
          events: events,
        );
        return {'path': path, 'updated': true, 'count': events.length};
      default:
        throw StateError('Unsupported chapter analysis field: $field');
    }
  }

  Future<Map<String, dynamic>> _writeVolume(
    ParsedPath parsed,
    Map<String, dynamic> fields,
  ) async {
    final id = parsed.id!;
    final volume = await _contentService.getChapterById(id);
    if (volume == null || !volume.isVolume) {
      return AiToolManager._structuredWriteError(
        path: 'volumes/$id',
        errorCode: ToolErrorCode.not_found,
        message: 'Volume not found: $id',
      );
    }
    final originalText = {
      'title': volume.title ?? '',
      'outline': volume.outline,
    };
    final changedFields = <String>[];
    for (final name in parsed._resource!.schema.writeFields) {
      final value = fields[name] as String?;
      if (value == null || (originalText[name] ?? '') == value) {
        continue;
      }
      await _stageTextChange(
        resourcePath: 'volumes/$id/$name',
        resourceType: 'volumes',
        resourceId: id,
        field: name,
        oldText: originalText[name],
        newText: value,
        source: workingChangeSourceAi,
        toolName: 'Write',
        summary: 'AI updated volume $name',
      );
      changedFields.add(name);
    }
    return {
      'path': parsed.displayPath,
      'updated': changedFields.isNotEmpty,
      if (!parsed.hasField) 'fields': changedFields,
    };
  }

  Future<Map<String, dynamic>> _writeCharacter(
    ParsedPath parsed,
    Map<String, dynamic> fields,
  ) async {
    if (fields['photos'] case final List photos) {
      if (await _photoAssetError(parsed.displayPath, photos)
          case final error?) {
        return error;
      }
      fields = {
        ...fields,
        'photos': _normalizeSubjectPhotos(
          photos,
        ).map((photo) => photo.toJson()).toList(),
      };
    }
    final id = parsed.id!;
    final field = parsed.field;
    final existing = await _contentService.getCharacterProfileById(id);
    if (existing == null) {
      return AiToolManager._structuredWriteError(
        path: 'characters/$id',
        errorCode: ToolErrorCode.not_found,
        message: 'Not found: $id',
      );
    }
    Future<void> validateFirstAppearance() async {
      final chapterId = fields['first_appear_chapter_id'] as String?;
      if (chapterId != null && chapterId.isNotEmpty) {
        final target = await _contentService.getChapterById(chapterId);
        if (target == null || !target.isChapter) {
          throw _CharacterWriteFailure(
            AiToolManager._structuredWriteError(
              path: 'characters/$id/first_appear_chapter_id',
              errorCode: ToolErrorCode.invalid_argument,
              message:
                  'First appearance must reference an existing chapter or extra.',
              operation: 'write',
            ),
          );
        }
      }
    }

    final changedFields = <String>[];
    final avatarAssetId = fields['avatar_asset_id'] as String?;
    if (fields.containsKey('avatar_asset_id')) {
      final error = await _avatarAssetError(
        'characters/$id/avatar_asset_id',
        avatarAssetId,
      );
      if (error != null) {
        return error;
      }
    }
    try {
      // 写入前及事务内检查引用，避免使用失效的章节。
      await validateFirstAppearance();
      await _withWorkingChangeTransaction(() async {
        final current = await _contentService.getCharacterProfileById(id);
        if (current == null) {
          throw _CharacterWriteFailure(
            AiToolManager._structuredWriteError(
              path: 'characters/$id',
              errorCode: ToolErrorCode.not_found,
              message: 'Not found: $id',
            ),
          );
        }
        await validateFirstAppearance();
        final values = _characterProfileValues(current);
        changedFields.addAll(
          fields.keys.where(
            (name) => name == 'tags'
                ? !const DeepCollectionEquality().equals(
                    values[name],
                    fields[name],
                  )
                : _encodeCharacterWorkingValue(name, values[name]) !=
                      _encodeCharacterWorkingValue(name, fields[name]),
          ),
        );
        if (changedFields.contains('avatar_asset_id')) {
          await _contentService.updateCharacterAvatarAndPhotos(
            entryId: id,
            avatarAssetId: avatarAssetId ?? '',
          );
        }
        if (changedFields.contains('tags')) {
          await _contentService.updateCharacterTags(
            entryId: id,
            tags: (fields['tags'] as List).cast<String>(),
          );
        }
        await _stageTextChangesAtomically(
          changes: [
            for (final name in parsed._resource!.schema.writeFields)
              if (name != 'avatar_asset_id' &&
                  name != 'tags' &&
                  changedFields.contains(name))
                WorkingTextChangeRequest(
                  resourcePath: 'characters/$id/$name',
                  resourceType: 'characters',
                  resourceId: id,
                  field: name,
                  oldText: _encodeCharacterWorkingValue(name, values[name]),
                  newText: _encodeCharacterWorkingValue(name, fields[name]),
                  summary: 'AI updated character $name',
                ),
          ],
          source: workingChangeSourceAi,
          toolName: 'Write',
        );
      });
    } on _CharacterWriteFailure catch (error) {
      return error.result;
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=character_profiles,working_changes operation=UPDATE id=$id',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
    return {
      'id': id,
      if (field != null) 'path': parsed.displayPath,
      'updated': changedFields.isNotEmpty,
      if (field == null || field == 'avatar_asset_id') 'fields': changedFields,
      if (field == 'avatar_asset_id')
        'avatar_asset_id': avatarAssetId?.isEmpty == true
            ? null
            : avatarAssetId,
    };
  }

  Future<Map<String, dynamic>?> _avatarAssetError(
    String path,
    String? assetId,
  ) async {
    if (assetId == null || assetId.isEmpty) {
      return null;
    }
    if (await _contentService.imagePath(assetId) != null) {
      return null;
    }
    return AiToolManager._structuredWriteError(
      path: path,
      errorCode: ToolErrorCode.invalid_argument,
      message: 'Avatar image asset not found: $assetId',
    );
  }

  Future<Map<String, dynamic>> _writeForeshadowing(
    ParsedPath parsed,
    Map<String, dynamic> fields,
  ) async {
    final id = parsed.id!;
    final field = parsed.field;
    final existing = await _contentService.getForeshadowingById(id);
    if (existing == null) {
      return AiToolManager._structuredWriteError(
        path: 'foreshadowing/$id',
        errorCode: ToolErrorCode.not_found,
        message: 'Not found: $id',
      );
    }

    final nextTitle = fields['title'] as String? ?? existing.title;
    final duplicateTitleError = await _validateForeshadowingTitleAvailable(
      contentService: _contentService,
      title: nextTitle,
      path: field == 'title' ? 'foreshadowing/$id/title' : 'foreshadowing/$id',
      operation: 'write',
      currentId: id,
    );
    if (duplicateTitleError != null) {
      return duplicateTitleError;
    }

    final changedFields = <String>[];
    try {
      await _withWorkingChangeTransaction(() async {
        final changes = <WorkingTextChangeRequest>[];
        final current = _foreshadowingValues(existing);
        for (final entry in fields.entries) {
          if ((current[entry.key] ?? '') == (entry.value ?? '')) {
            continue;
          }
          changedFields.add(entry.key);
          changes.add(
            WorkingTextChangeRequest(
              resourcePath: 'foreshadowing/$id/${entry.key}',
              resourceType: 'foreshadowing',
              resourceId: id,
              field: entry.key,
              // 未设置的位置字段与 overlay 读取口径一致记为空串，null 会让回滚跳过。
              oldText: current[entry.key] as String? ?? '',
              newText: entry.value as String? ?? '',
              summary: 'AI updated foreshadowing ${entry.key}',
            ),
          );
        }
        await _stageTextChangesAtomically(
          changes: changes,
          source: workingChangeSourceAi,
          toolName: 'Write',
        );
      });
    } on FormatException catch (error) {
      return AiToolManager._structuredWriteError(
        path: 'foreshadowing/$id',
        errorCode: ToolErrorCode.invalid_argument,
        message: error.message,
      );
    }
    return {
      'id': id,
      'path': 'foreshadowing/$id${field == null ? "" : "/$field"}',
      'updated': changedFields.isNotEmpty,
      'fields': changedFields,
    };
  }

  /// 照片只引用已登记的图片资产，不接受任意文件路径。
  Future<Map<String, dynamic>?> _photoAssetError(
    String path,
    List photos,
  ) async {
    for (final photo in _normalizeSubjectPhotos(photos)) {
      if (await _contentService.imagePath(photo.assetId) == null) {
        return AiToolManager._structuredWriteError(
          path: path,
          errorCode: ToolErrorCode.invalid_argument,
          message: 'Photo image asset not found: ${photo.assetId}',
          operation: 'write',
        );
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> _writeLocation(
    ParsedPath parsed,
    Map<String, dynamic> fields,
  ) async {
    final id = parsed.id!;
    final field = parsed.field;
    final existing = await _contentService.locationsService.getLocationById(id);
    if (existing == null) {
      return AiToolManager._structuredWriteError(
        path: 'locations/$id',
        errorCode: ToolErrorCode.not_found,
        message: 'Not found: $id',
      );
    }
    if (fields['photos'] case final List photos) {
      if (await _photoAssetError(parsed.displayPath, photos)
          case final error?) {
        return error;
      }
    }

    final fieldsToWrite = <String, String>{
      for (final name in parsed._resource!.schema.writeFields)
        if (fields.containsKey(name))
          name: name == 'photos'
              ? const SubjectPhotoListConverter().toSql(
                  _normalizeSubjectPhotos(fields[name] as List),
                )
              : fields[name] as String? ?? '',
    };
    final finalType = fieldsToWrite['type'] ?? existing.type;
    final parentValue = fieldsToWrite['parent_id'];
    // 空关联值代表解除父级，未提供则保留当前归属。
    final nextParentId = parentValue == null
        ? existing.parentId
        : parentValue.isEmpty
        ? null
        : parentValue;
    final onlyPhotos =
        fieldsToWrite.length == 1 && fieldsToWrite.containsKey('photos');
    if (!onlyPhotos && finalType != locationTypeWorld && nextParentId == null) {
      return AiToolManager._structuredWriteError(
        path: 'locations/$id',
        errorCode: ToolErrorCode.invalid_argument,
        message:
            'Non-world locations require parent_id. Set parent_id to an existing world or parent location before changing type.',
        operation: 'write',
        missingFields: const ['parent_id'],
        requiredFields: const ['parent_id'],
      );
    }

    if (!onlyPhotos && nextParentId != null) {
      final parent = await _contentService.locationsService.getLocationById(
        nextParentId,
      );
      if (parent == null) {
        return AiToolManager._structuredWriteError(
          path: 'locations/$id',
          errorCode: ToolErrorCode.invalid_argument,
          message: 'Parent location not found: $nextParentId',
          operation: 'write',
        );
      }
    }

    final changedFields = <String>[];
    final stageOrder = fieldsToWrite.keys.toList();
    void moveBefore(String fieldName, String beforeField) {
      stageOrder.remove(fieldName);
      stageOrder.insert(stageOrder.indexOf(beforeField), fieldName);
    }

    if (stageOrder.contains('type') && stageOrder.contains('parent_id')) {
      if (finalType == locationTypeWorld && nextParentId == null) {
        moveBefore('type', 'parent_id');
      } else if (finalType != locationTypeWorld && nextParentId != null) {
        moveBefore('parent_id', 'type');
      }
    }

    final changes = <WorkingTextChangeRequest>[];
    for (final fieldName in stageOrder) {
      final current = switch (fieldName) {
        'name' => existing.name,
        'description' => existing.description,
        'type' => existing.type,
        'parent_id' => existing.parentId,
        'photos' => const SubjectPhotoListConverter().toSql(
          existing.photos ?? const [],
        ),
        _ => throw StateError(
          'Unsupported normalized location field: $fieldName',
        ),
      };
      final valueToWrite = switch (fieldName) {
        'type' => finalType,
        _ => fieldsToWrite[fieldName]!,
      };
      if ((current ?? '') == valueToWrite) {
        continue;
      }
      changedFields.add(fieldName);
      changes.add(
        WorkingTextChangeRequest(
          resourcePath: 'locations/$id/$fieldName',
          resourceType: 'locations',
          resourceId: id,
          field: fieldName,
          oldText: current,
          newText: valueToWrite,
          summary: 'AI updated location $fieldName',
        ),
      );
    }
    try {
      await _stageTextChangesAtomically(
        changes: changes,
        source: workingChangeSourceAi,
        toolName: 'Write',
      );
    } on DuplicateLocationNameException catch (error) {
      return _duplicateLocationNameError(parsed, error, 'write');
    }

    return {
      'id': id,
      if (field != null) 'path': 'locations/$id/$field',
      'updated': changedFields.isNotEmpty,
      'fields': changedFields,
    };
  }

  Future<Map<String, dynamic>> _writeItem(
    ParsedPath parsed,
    Map<String, dynamic> fields,
  ) async {
    final collection = parsed.collection;
    final itemType = parsed._resource!.schema.itemType!;
    final id = parsed.id!;
    final field = parsed.field;
    final resolvedExisting = await _contentService.getItemById(id);
    if (resolvedExisting == null) {
      return AiToolManager._structuredWriteError(
        path: '$collection/$id',
        errorCode: ToolErrorCode.not_found,
        message: 'Not found: $id',
      );
    }
    if (resolvedExisting.type != itemType) {
      return AiToolManager._structuredWriteError(
        path: '$collection/$id',
        errorCode: ToolErrorCode.invalid_argument,
        message: 'Entry $id does not belong to $collection',
      );
    }

    final nextTitle = fields['title'] as String? ?? resolvedExisting.title;
    final duplicateTitleError = await _validateItemTitleAvailable(
      contentService: _contentService,
      collection: collection,
      itemType: itemType,
      title: nextTitle,
      path: field == 'title' ? '$collection/$id/title' : '$collection/$id',
      operation: 'write',
      currentId: resolvedExisting.id,
    );
    if (duplicateTitleError != null) {
      return duplicateTitleError;
    }

    final changedFields = <String>[];
    for (final fieldName in parsed._resource.schema.writeFields.where(
      fields.containsKey,
    )) {
      final nextValue = fields[fieldName] as String? ?? '';

      final currentValue = switch (fieldName) {
        'title' => resolvedExisting.title,
        'content' => resolvedExisting.content,
        'category' => resolvedExisting.category,
        _ => throw StateError('Unsupported normalized item field: $fieldName'),
      };
      if (currentValue == nextValue) {
        continue;
      }
      await _stageTextChange(
        resourcePath: '$collection/$id/$fieldName',
        resourceType: collection,
        resourceId: resolvedExisting.id,
        field: fieldName,
        oldText: currentValue,
        newText: nextValue,
        source: workingChangeSourceAi,
        toolName: 'Write',
        summary: 'AI updated $collection $fieldName',
      );
      changedFields.add(fieldName);
    }

    return {
      'id': resolvedExisting.id,
      if (field != null) 'path': '$collection/$id/$field',
      'updated': changedFields.isNotEmpty,
      'fields': changedFields,
    };
  }

  Future<Map<String, dynamic>> _writeDocument(
    ParsedPath parsed,
    Map<String, dynamic> fields,
  ) async {
    final collection = parsed.collection;
    final documentType = parsed._resource!.schema.documentType!;
    final namePath = parsed.namePath;
    final field = parsed.field;
    final existing = await _contentService.documentsService
        .getDocumentByNamePath(type: documentType, namePath: namePath);
    if (existing == null) {
      return _createDocument(parsed, fields);
    }
    final pathStr = namePath.join('/');
    if (existing.isFolder) {
      return AiToolManager._structuredWriteError(
        path: '$collection/$pathStr',
        errorCode: ToolErrorCode.failed_precondition,
        message:
            'Cannot write to a folder. Write to a specific document path inside the folder to create or update it.',
      );
    }
    final nextTitle = fields['title'] as String?;
    if (nextTitle != null && nextTitle != existing.title) {
      final duplicateTitleError = await _validateDocumentTitleAvailable(
        contentService: _contentService,
        collection: collection,
        documentType: documentType,
        title: nextTitle,
        path: parsed.displayPath,
        operation: 'write',
        parentId: existing.parentId,
        currentId: existing.id,
      );
      if (duplicateTitleError != null) {
        return duplicateTitleError;
      }
    }
    // 名称仅用于首次定位；同次写入重命名后仍更新已经定位的文档 ID。
    final current = {
      'title': existing.title,
      'content': existing.content,
      'category': existing.category,
    };
    final changedFields = <String>[];
    for (final name in parsed._resource.schema.writeFields) {
      final value = fields[name] as String?;
      if (value == null || (current[name] ?? '') == value) {
        continue;
      }
      await _stageTextChange(
        resourcePath: '$collection/${existing.id}/$name',
        resourceType: collection,
        resourceId: existing.id,
        field: name,
        oldText: current[name],
        newText: value,
        source: workingChangeSourceAi,
        toolName: 'Write',
        summary: 'AI updated $collection $name',
      );
      changedFields.add(name);
    }
    return {
      'path': parsed.displayPath,
      'updated': changedFields.isNotEmpty,
      if (field == null) 'fields': changedFields,
    };
  }

  Future<Map<String, dynamic>> _createDocument(
    ParsedPath parsed,
    Map<String, dynamic> fields,
  ) async {
    final collection = parsed.collection;
    final documentType = parsed._resource!.schema.documentType!;
    final namePath = parsed.namePath;
    final title = namePath.last;
    String? parentId;

    if (namePath.length > 1) {
      final parentPath = namePath.sublist(0, namePath.length - 1);
      final parent = await _contentService.documentsService
          .getDocumentByNamePath(type: documentType, namePath: parentPath);
      if (parent == null) {
        final pathStr = namePath.join('/');
        return AiToolManager._structuredWriteError(
          path: '$collection/$pathStr',
          errorCode: ToolErrorCode.invalid_argument,
          message: 'Parent folder not found: ${parentPath.join('/')}',
          operation: 'create',
        );
      }
      if (!parent.isFolder) {
        final pathStr = namePath.join('/');
        return AiToolManager._structuredWriteError(
          path: '$collection/$pathStr',
          errorCode: ToolErrorCode.invalid_argument,
          message: 'Parent ${parentPath.join('/')} is not a folder',
          operation: 'create',
        );
      }
      parentId = parent.id;
    }

    final docContent = fields['content'] as String? ?? '';
    final docCategory = fields['category'] as String?;

    if (docContent.isEmpty && docCategory == null) {
      final pathStr = namePath.join('/');
      return AiToolManager._structuredWriteError(
        path: '$collection/$pathStr',
        errorCode: ToolErrorCode.invalid_argument,
        message: 'No writable fields provided for new document',
      );
    }

    final duplicateTitleError = await _validateDocumentTitleAvailable(
      contentService: _contentService,
      collection: collection,
      documentType: documentType,
      title: title,
      path: '$collection/${namePath.join('/')}',
      operation: 'create',
      parentId: parentId,
    );
    if (duplicateTitleError != null) {
      return duplicateTitleError;
    }

    final newId = await _contentService.documentsService.createDocument(
      type: documentType,
      parentId: parentId,
      title: title,
      content: docContent,
      category: docCategory ?? '',
    );

    final pathStr = namePath.join('/');
    final previewText = [
      title,
      if (docContent.isNotEmpty) docContent,
      if (namePath.length > 1)
        '父文件夹：${namePath.sublist(0, namePath.length - 1).join('/')}',
    ].join('\n\n');
    await _stageCreateChange(
      resourcePath: '$collection/$newId',
      resourceType: collection,
      resourceId: newId,
      previewText: previewText,
      source: workingChangeSourceAi,
      toolName: 'Write',
      summary: 'AI created $collection document',
    );
    return {'path': '$collection/$pathStr', 'id': newId, 'created': true};
  }
}

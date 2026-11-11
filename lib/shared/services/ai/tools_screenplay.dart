// 职责: 按公共资源目标与已校验操作执行剧本、季、集、场次和元素读写。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/screenplay_create_orchestrator.dart
//   lib/shared/services/screenplay_service.dart
//   lib/shared/services/working_overlay.dart
//   lib/shared/models/screenplay_element.dart
// 遵循的 Rules:
//   .agents/rules/ai-calling.md
//   .agents/rules/tools_path.md
//   .agents/rules/error-handling.md
part of 'tools.dart';

mixin _AiToolManagerScreenplayMixin on _AiToolManagerBase {
  ScreenplayService get _screenplayService => ScreenplayService(
    _contentService.database,
    novelActionsService: _contentService.novelActionsService,
  );

  @override
  String get _targetContentKind =>
      _currentResourceCallContext?.scope.kind.name ?? contentKind;

  @override
  bool isScreenplayPath(ParsedPath parsed) => const {
    contentKindScreenplay,
    contentKindCanvas,
  }.contains(_resourceDefinitions[parsed.collection]?.group);

  @override
  Map<String, dynamic>? _contentKindGate(ParsedPath parsed) {
    final schema = _resourceDefinitions[parsed.collection];
    if (parsed.collection.isNotEmpty && schema == null) {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.invalid_argument,
        'Unknown collection: ${parsed.collection}.',
        hint:
            'Read /works/${parsed.targetWorkId ?? crossWorkAccess?.currentWorkId ?? workId ?? "{work_id}"} and Read /_schema.',
      );
    }
    if (schema == null) {
      return null;
    }
    if (schema.supports(_targetContentKind)) {
      if (parsed._resource == null) {
        return _resourceError(
          parsed.displayPath,
          ToolErrorCode.invalid_argument,
          'Unsupported resource path. Read /_schema/${schema.name}.',
        );
      }
      if (parsed.isOutlineBeat &&
          !parsed.isResourceListing &&
          !parsed._resource.hasUnknownField &&
          num.tryParse(parsed.outlineBeatId ?? '') != null) {
        return _resourceError(
          parsed.displayPath,
          ToolErrorCode.invalid_argument,
          'Beat paths require a beat ID; numeric index paths are no longer supported.',
          hint:
              'Read ${_resourceReferencePath('outlines/${parsed.locator('title')}/beats')} and copy an ID path.',
        );
      }
      return null;
    }
    return _resourceError(
      parsed.displayPath,
      ToolErrorCode.invalid_argument,
      'The target work is a $_targetContentKind and does not expose ${schema.name}.',
      hint:
          'Read ${"/works/${parsed.targetWorkId ?? crossWorkAccess?.currentWorkId ?? workId ?? "{work_id}"}"} and Read /_schema/groups/$_targetContentKind.',
    );
  }

  @override
  List<Map<String, dynamic>> _workspaceRootEntries() =>
      _buildRootDirectoryEntries(kind: _targetContentKind);

  @override
  Future<Map<String, dynamic>> _executeScreenplay(
    ParsedPath parsed,
    _ResourceOperation operation, {
    Map<String, dynamic> fields = const {},
    bool force = false,
    ({String oldText, String newText, bool replaceAll})? edit,
  }) async {
    if (const {
      _episodeProductionDefinition,
      _productionCanvas,
      _productionNodes,
      _productionEdges,
      _canvasProductionDefinition,
      _canvasProductionCanvas,
      _canvasProductionNodes,
      _canvasProductionEdges,
    }.contains(parsed._resource!.schema)) {
      return _executeProduction(parsed, operation, fields: fields);
    }
    if (parsed.resourceSegment == 'generations') {
      try {
        return await _executeProductionMetadata(parsed);
      } on ToolOperationException catch (error) {
        return {'ok': false, 'error_code': error.code, 'error': error.message};
      }
    }
    if ((parsed.collection == 'screenplay' &&
            operation.tool != _ResourceTool.read) ||
        parsed._resource.schema == _canvasProductionSettings) {
      return _executeScreenplayStyle(parsed, operation, fields, edit);
    }
    if (parsed.resourceSegment == 'clips') {
      return _executeStoryboard(parsed, operation, fields: fields, edit: edit);
    }
    return switch (operation.tool) {
      _ResourceTool.read => _readScreenplay(parsed, operation),
      _ResourceTool.create => _createScreenplay(parsed, fields),
      _ResourceTool.write => _writeScreenplay(parsed, operation, fields),
      _ResourceTool.edit => _editScreenplay(
        parsed,
        operation,
        edit!.oldText,
        edit.newText,
        edit.replaceAll,
      ),
      _ResourceTool.remove => _removeScreenplay(parsed, force: force),
    };
  }

  Future<Map<String, dynamic>> _readScreenplay(
    ParsedPath parsed,
    _ResourceOperation operation,
  ) async {
    try {
      final resource = parsed._resource!;
      final dao = _contentService.database.screenplayDao;
      final root = await dao.getRoot();
      if (root == null) {
        return _resourceError(
          parsed.displayPath,
          ToolErrorCode.not_found,
          'Screenplay root was not found.',
        );
      }
      if (parsed.collection == 'screenplay') {
        final seasons = await dao.getSeasons(root.id);
        var episodeCount = 0;
        for (final season in seasons) {
          episodeCount += (await dao.getEpisodes(season.id)).length;
        }
        final overview = await dao.watchOverview(root.id).first;
        final data = <String, dynamic>{
          'id': root.id,
          'path': 'screenplay',
          'style_id': root.styleId,
          'ratio': root.ratio,
          'resolution': root.resolution,
          'width': root.width,
          'height': root.height,
          'kind': root.kind,
          'format': root.format,
          'season_count': seasons.length,
          'episode_count': episodeCount,
          'scene_count': overview.sceneCount,
          'page_eighths': overview.pageEighths,
          'dialogue_line_count': overview.dialogueLineCount,
          'word_count': overview.wordCount,
        };
        return parsed.hasField ? {'value': data[parsed.field]} : data;
      }
      return await switch (resource.schema.segment) {
        'seasons' => _readSeasons(parsed, root.id),
        'episodes' => _readEpisodes(parsed, root.id),
        'scenes' || 'elements' => _readScenes(parsed, operation, root.id),
        _ => _resourceError(
          parsed.displayPath,
          ToolErrorCode.invalid_argument,
          'Unsupported screenplay path.',
        ),
      };
    } on WorkingOverlayConflictException catch (error) {
      return _workingChangeConflict(error);
    } on ScreenplayServiceException catch (error) {
      return _screenplayException(parsed.displayPath, error);
    } on ScreenplayElementValidationException catch (error) {
      return _resourceError(
        parsed.displayPath,
        _serviceErrorCode(error.errorCode),
        error.message,
      );
    } on FormatException catch (error) {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.invalid_argument,
        error.message,
      );
    }
  }

  Future<Map<String, dynamic>> _readSeasons(
    ParsedPath parsed,
    String screenplayId,
  ) async {
    final dao = _contentService.database.screenplayDao;
    if (parsed._resource!.listing) {
      final rows = await dao.getSeasons(screenplayId);
      return {
        'type': 'listing',
        'entries': [for (final row in rows) _seasonJson(row)],
      };
    }
    final row = await dao.getSeason(parsed.locator('season_id')!);
    if (row == null) {
      return _notFound(parsed, 'season');
    }
    if (parsed.hasField) {
      return {'value': row.title};
    }
    return _seasonJson(row);
  }

  Future<Map<String, dynamic>> _readEpisodes(
    ParsedPath parsed,
    String screenplayId,
  ) async {
    final dao = _contentService.database.screenplayDao;
    if (parsed._resource!.listing) {
      final scope = await _resolveReadSeasons(screenplayId, parsed);
      if (scope.error != null) {
        return scope.error!;
      }
      final entries = <Map<String, dynamic>>[];
      for (final seasonId in scope.ids) {
        final rows = await dao.getEpisodes(seasonId);
        entries.addAll([for (final row in rows) _episodeJson(row)]);
      }
      return {
        'type': 'listing',
        if (scope.scopedId != null) 'season_id': scope.scopedId,
        'entries': entries,
      };
    }
    final row = await dao.getEpisode(parsed.locator('episode_id')!);
    if (row == null) {
      return _notFound(parsed, 'episode');
    }
    if (parsed.hasField) {
      return {'value': _episodeJson(row, includeOutline: true)[parsed.field]};
    }
    return _episodeJson(row, includeOutline: true);
  }

  Future<Map<String, dynamic>> _readScenes(
    ParsedPath parsed,
    _ResourceOperation operation,
    String screenplayId,
  ) async {
    final dao = _contentService.database.screenplayDao;
    if (parsed._resource!.schema.segment == 'scenes' &&
        operation.target == _ResourceTargetKind.listing) {
      final scope = await _resolveReadEpisodes(screenplayId, parsed);
      if (scope.error != null) {
        return scope.error!;
      }
      final stage = parsed.queryParameters['stage'];
      final search = parsed.queryParameters[_listingSearchQueryParam]
          ?.toLowerCase();
      final entries = <Map<String, dynamic>>[];
      for (final episodeId in scope.ids) {
        final rows = await dao.watchScenes(episodeId).first;
        for (final row in rows) {
          if (stage != null && row.stage != stage) {
            continue;
          }
          if (search != null &&
              search.isNotEmpty &&
              !row.title.toLowerCase().contains(search) &&
              !row.synopsis.toLowerCase().contains(search) &&
              !row.timeLabel.toLowerCase().contains(search)) {
            continue;
          }
          entries.add(_sceneSummaryJson(row));
        }
      }
      return {
        'type': 'listing',
        if (scope.scopedId != null) 'episode_id': scope.scopedId,
        'entries': entries,
      };
    }
    final resource = parsed._resource;
    final sceneId = resource.ids['scene_id']!;
    final scene = await dao.getScene(sceneId);
    if (scene == null) {
      return _notFound(parsed, 'scene');
    }
    if (resource.schema.segment == 'scenes') {
      if (operation.target == _ResourceTargetKind.resource) {
        final siblings = await dao.watchScenes(scene.episodeId).first;
        final summary = siblings.firstWhere((item) => item.id == scene.id);
        return {
          ..._sceneSummaryJson(summary),
          'events': scene.events ?? <Map<String, dynamic>>[],
        };
      }
      return switch (operation.field!) {
        'synopsis' => {'value': scene.synopsis},
        'cast' => {'value': await _castEntries(sceneId)},
        final field => {
          'value': {'emotion', 'events'}.contains(field)
              ? _scenePropertyValues(scene)[field] ?? []
              : _scenePropertyValues(scene)[field],
        },
      };
    }
    final elements = await _sceneElements(sceneId);
    if (operation.target == _ResourceTargetKind.listing) {
      return {
        'type': 'listing',
        'entries': [
          for (final entry in await _elementEntries(elements))
            {...entry, 'path': 'scenes/$sceneId/elements/${entry['id']}'},
        ],
      };
    }
    final element = elements
        .where((item) => item.id == resource.ids['element_id'])
        .firstOrNull;
    if (element == null) {
      return _notFound(parsed, 'element');
    }
    if (operation.target == _ResourceTargetKind.field &&
        !resource.schema.fields[operation.field]!.read!.acceptsTarget({
          'type': element.type.name,
        })) {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.invalid_argument,
        'Field is not available for this resource: ${operation.field}.',
      );
    }
    if (operation.target == _ResourceTargetKind.field) {
      final value = switch (operation.field!) {
        'text' => element.text,
        'character_id' => element.characterId,
        _ => throw StateError(
          'Unsupported screenplay element field: ${operation.field}',
        ),
      };
      return {'value': value};
    }
    return await _elementEntry(element);
  }

  Future<Map<String, dynamic>> _createScreenplay(
    ParsedPath parsed,
    Map<String, dynamic> fields,
  ) async {
    final resource = parsed._resource!;
    try {
      final root = await _contentService.database.screenplayDao.getRoot();
      if (root == null) {
        return _resourceError(
          parsed.displayPath,
          ToolErrorCode.not_found,
          'Screenplay root was not found.',
        );
      }
      if (resource.schema.segment == 'elements') {
        // 定位、保存和身份回读必须在同一事务，防止提交后被其他编辑重排。
        return await _withWorkingChangeTransaction(() async {
          final scene = await _contentService.database.screenplayDao.getScene(
            resource.ids['scene_id']!,
          );
          if (scene == null) {
            return _notFound(parsed, 'scene');
          }
          final current = await _sceneElements(resource.ids['scene_id']!);
          final element = _elementFromFields(fields);
          var insertionIndex = current.length;
          final afterId = _screenplayOptionalField(fields, 'after_element_id');
          final target = [...current];
          if (afterId == null) {
            target.add(element);
          } else {
            final index = current.indexWhere((item) => item.id == afterId);
            if (index < 0) {
              return _resourceError(
                parsed.displayPath,
                ToolErrorCode.invalid_argument,
                'after_element_id must reference an existing element in this scene.',
              );
            }
            insertionIndex = index + 1;
            target.insert(insertionIndex, element);
          }
          final result = await _stageElements(
            parsed,
            scene.id,
            current,
            target,
          );
          // 事务内读取本次保存的顺序和身份，取插入位置的真实 ID。
          final created = (result['entries'] as List)[insertionIndex] as Map;
          return {
            ...result,
            'created': true,
            'id': created['id'],
            'path': 'scenes/${scene.id}/elements/${created['id']}',
          };
        });
      }
      switch (resource.schema.segment) {
        case 'seasons':
          final created = await _screenplayService.createSeason(
            screenplayId: root.id,
            title: fields['title'] as String? ?? '',
            plannedEpisodeCount: fields['planned_episode_count'] as int?,
          );
          return {
            'ok': true,
            'created': true,
            'id': created.seasonId,
            'episode_id': created.episodeId,
            'path': 'seasons/${created.seasonId}',
            'episode_path': 'episodes/${created.episodeId}',
          };
        case 'episodes':
          final season = await _resolveSeason(root.id, parsed, fields: fields);
          if (season.error != null) {
            return season.error!;
          }
          final id = await _screenplayService.createEpisode(
            seasonId: season.id!,
            title: fields['title'] as String? ?? '',
          );
          final episode = (await _contentService.database.screenplayDao
              .getEpisode(id))!;
          return {
            'ok': true,
            'created': true,
            'id': id,
            'path': 'episodes/$id',
            'editing_id': episode.editingId,
            'editing_revision': 0,
          };
        case 'scenes':
          return await _createScene(root.id, fields);
      }
      return _invalidScreenplayPath(parsed);
    } on WorkingOverlayConflictException catch (error) {
      return _workingChangeConflict(error);
    } on ScreenplayServiceException catch (error) {
      return _screenplayException(parsed.displayPath, error);
    } on ScreenplayElementValidationException catch (error) {
      return _resourceError(
        parsed.displayPath,
        _serviceErrorCode(error.errorCode),
        error.message,
      );
    } on FormatException catch (error) {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.invalid_argument,
        error.message,
      );
    }
  }

  Future<Map<String, dynamic>> _createScene(
    String screenplayId,
    Map<String, dynamic> fields,
  ) async {
    final before = _screenplayOptionalField(fields, 'before_scene_id');
    final after = _screenplayOptionalField(fields, 'after_scene_id');
    final explicitEpisode = _screenplayOptionalField(fields, 'episode_id');
    String episodeId;
    if (before != null || after != null) {
      final anchorId = before ?? after!;
      final anchor = await _contentService.database.screenplayDao.getScene(
        anchorId,
      );
      if (anchor == null) {
        throw const ScreenplayServiceException(
          'invalid_scene_ref',
          'Scene anchor was not found.',
        );
      }
      episodeId = anchor.episodeId;
    } else {
      // 不回落到当前集：新场次会静默落进用户正在看的那一集，而调用方以为自己
      // 指定过落点。schema 的 at_least_one 已经拦在前面，这里是兜底。
      episodeId = explicitEpisode ?? '';
      if (episodeId.isEmpty) {
        throw const FormatException(
          'episode_id, before_scene_id or after_scene_id is required.',
        );
      }
    }
    final sourceSession = _resolvedScreenplaySessionId();
    final locationId = _screenplayOptionalField(fields, 'location_id');
    final interiorExterior = _screenplayOptionalField(
      fields,
      'interior_exterior',
    );
    final stage =
        _screenplayOptionalField(fields, 'stage') ?? screenplayStageDraft;
    final cast = fields['cast'] == null
        ? null
        : (fields['cast'] as List).cast<String>();
    final decodedElements = fields['elements'] == null
        ? null
        : _decodeElements(fields['elements'] as List);
    WorkingChange? createdChange;
    late final String id;
    try {
      id = await ScreenplayCreateOrchestrator().createScene(
        database: _contentService.database,
        service: _screenplayService,
        screenplayId: screenplayId,
        episodeId: episodeId,
        locationId: locationId,
        interiorExterior: interiorExterior,
        stage: stage,
        timeLabel: fields['time'] as String? ?? '',
        synopsis: fields['synopsis'] as String? ?? '',
        title: fields['title'] as String? ?? '',
        emotion: fields['emotion'] == null
            ? null
            : (fields['emotion'] as List).cast<String>(),
        events: fields['events'] == null
            ? null
            : (fields['events'] as List)
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList(),
        cast: cast,
        elements: decodedElements,
        beforeSceneId: before,
        afterSceneId: after,
        stageCreateChange: (id) async {
          final scene = await _contentService.database.screenplayDao.getScene(
            id,
          );
          final elements = await _sceneElements(id);
          final preview = [
            if (scene != null) _sceneHeading(scene),
            if (scene != null && scene.synopsis.isNotEmpty) scene.synopsis,
            renderScreenplayElements(
              elements,
              characterNames: await _characterNames(),
              includeNotes: true,
            ),
          ].where((value) => value.isNotEmpty).join('\n\n');
          createdChange = await workingOverlayService.stageCreateChange(
            resourcePath: 'scenes/$id',
            resourceType: workingChangeResourceTypeScreenplayScenes,
            resourceId: id,
            previewText: preview,
            source: workingChangeSourceAi,
            sourceSessionId: sourceSession,
            sourceTurnId: _currentToolExecutionContext?.sourceTurnId,
            toolName: _currentStagingToolName ?? 'Create',
            summary: 'Create screenplay scene',
          );
        },
      );
    } finally {
      if (createdChange != null) {
        final committed = await workingOverlayService.getWorkingChangeById(
          createdChange!.id,
        );
        if (committed != null) {
          _reportWorkingChange(committed);
        }
      }
    }
    return {'ok': true, 'created': true, 'id': id, 'path': 'scenes/$id'};
  }

  Future<Map<String, dynamic>> _writeScreenplay(
    ParsedPath parsed,
    _ResourceOperation operation,
    Map<String, dynamic> fields,
  ) async {
    final resource = parsed._resource!;
    try {
      return await _withWorkingChangeTransaction(() async {
        final dao = _contentService.database.screenplayDao;
        Map<String, dynamic>? businessFields(Map<String, dynamic>? row) => row
          ?..remove('createdAt')
          ..remove('updatedAt');
        Future<Object?> readState() async {
          switch (resource.schema.segment) {
            case 'seasons':
              return businessFields(
                (await dao.getSeason(resource.ids['season_id']!))?.toJson(),
              );
            case 'episodes':
              return businessFields(
                (await dao.getEpisode(resource.ids['episode_id']!))?.toJson(),
              );
            case 'elements':
              if (await dao.getScene(resource.ids['scene_id']!) == null) {
                return null;
              }
              return serializeScreenplayElements(
                await _sceneElements(resource.ids['scene_id']!),
              );
            case 'scenes':
              final scene = await dao.getScene(resource.ids['scene_id']!);
              if (scene == null) {
                return null;
              }
              return {
                'scene': businessFields(scene.row.toJson()),
                'heading': businessFields(scene.heading.toJson()),
                if (fields.containsKey('cast'))
                  'cast': [
                    for (final member in await dao.getSceneCharacters(
                      resource.ids['scene_id']!,
                    ))
                      member.characterId,
                  ],
              };
          }
          throw StateError(
            'Unsupported screenplay write target: ${resource.schema.segment}',
          );
        }

        // 只读取目标记录，不加载整集列表；更新时间不代表业务数据变化。
        final before = await readState();
        if (before == null) {
          return _notFound(parsed, 'Write target');
        }
        final result = await _writeScreenplayResource(
          parsed,
          operation,
          fields,
        );
        if (!toolResultIsSuccess(result)) {
          return result;
        }
        return {
          'ok': true,
          'path': result['path'] ?? parsed.displayPath,
          'updated': !const DeepCollectionEquality().equals(
            before,
            await readState(),
          ),
        };
      });
    } on WorkingOverlayConflictException catch (error) {
      return _workingChangeConflict(error);
    } on ScreenplayServiceException catch (error) {
      return _screenplayException(parsed.displayPath, error);
    } on ScreenplayElementValidationException catch (error) {
      return _resourceError(
        parsed.displayPath,
        _serviceErrorCode(error.errorCode),
        error.message,
      );
    } on FormatException catch (error) {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.invalid_argument,
        error.message,
      );
    }
  }

  Future<Map<String, dynamic>> _writeScreenplayResource(
    ParsedPath parsed,
    _ResourceOperation operation,
    Map<String, dynamic> fields,
  ) async {
    final resource = parsed._resource!;
    switch (resource.schema.segment) {
      case 'seasons':
        await _screenplayService.updateSeason(
          seasonId: resource.ids['season_id']!,
          title: fields.containsKey('title')
              ? fields['title'] as String? ?? ''
              : null,
          plannedEpisodeCount: fields.containsKey('planned_episode_count')
              ? Value(fields['planned_episode_count'] as int?)
              : const Value.absent(),
        );
        return {'ok': true, 'path': 'seasons/${resource.ids['season_id']}'};
      case 'episodes':
        return await _writeEpisode(parsed, resource.ids['episode_id']!, fields);
      case 'scenes':
      case 'elements':
        return await _writeScene(parsed, operation, fields);
    }
    return _invalidScreenplayPath(parsed);
  }

  Map<String, dynamic> _workingChangeConflict(
    WorkingOverlayConflictException error,
  ) {
    return _resourceError(
      error.resourcePath,
      ToolErrorCode.conflict,
      'Another AI session has an active screenplay body change for this scene.',
      hint:
          'Accept, revert, or manually take over that change before retrying.',
    );
  }

  Future<Map<String, dynamic>> _writeEpisode(
    ParsedPath parsed,
    String episodeId,
    Map<String, dynamic> fields,
  ) async {
    // 资源路径与单字段路径已由 _prepareWrite 校验，并统一成 fields。
    // 只有大纲时不碰 updateEpisode：那条路径会重排/移动并 bump updatedAt，
    // 而大纲改动本身要走待审阅，不该顺带产生结构写入。
    final hasStructuralFields = fields.keys.any((key) => key != 'outline');
    if (hasStructuralFields) {
      await _screenplayService.updateEpisode(
        episodeId: episodeId,
        title: fields.containsKey('title')
            ? fields['title'] as String? ?? ''
            : null,
        episodeNumber: fields.containsKey('episode_number')
            ? fields['episode_number'] as int
            : null,
        targetSeasonId: _screenplayOptionalField(fields, 'season_id'),
      );
    }
    // 重读：上面可能刚把该集移到别的季。
    final episode = await _contentService.database.screenplayDao.getEpisode(
      episodeId,
    );
    if (fields.containsKey('outline')) {
      if (episode == null) {
        return _notFound(parsed, 'episode');
      }
      return _stageEpisodeOutline(
        parsed,
        episodeId,
        episode.outline,
        fields['outline'] as String? ?? '',
      );
    }
    return {'ok': true, if (episode != null) ..._episodeJson(episode)};
  }

  Future<Map<String, dynamic>> _writeScene(
    ParsedPath parsed,
    _ResourceOperation operation,
    Map<String, dynamic> fields,
  ) => _withWorkingChangeTransaction(
    () => _writeSceneInTransaction(parsed, operation, fields),
  );

  Future<Map<String, dynamic>> _writeSceneInTransaction(
    ParsedPath parsed,
    _ResourceOperation operation,
    Map<String, dynamic> fields,
  ) async {
    final resource = parsed._resource!;
    final sceneId = resource.ids['scene_id']!;
    if (resource.schema.segment == 'elements') {
      final current = await _sceneElements(sceneId);
      var target = current;
      if (operation.target == _ResourceTargetKind.listing) {
        target = _decodeElements(fields['elements'] as List);
      } else {
        final index = current.indexWhere(
          (item) => item.id == resource.ids['element_id'],
        );
        if (index < 0) {
          return _notFound(parsed, 'element');
        }
        final replacement = _elementFromFields(
          fields,
          existing: current[index],
        );
        target = [...current]..[index] = replacement;
      }
      return _stageElements(parsed, sceneId, current, target);
    }
    if (operation.target == _ResourceTargetKind.field &&
        operation.field != 'synopsis' &&
        operation.field != 'cast') {
      return _stageSceneProperty(
        parsed,
        sceneId,
        operation.field!,
        fields[operation.field],
      );
    }
    if (operation.field == 'synopsis') {
      final scene = await _contentService.database.screenplayDao.getScene(
        sceneId,
      );
      if (scene == null) {
        return _notFound(parsed, 'scene');
      }
      return _stageSynopsis(
        parsed,
        sceneId,
        scene.synopsis,
        fields['synopsis'] as String? ?? '',
      );
    }
    if (operation.field == 'cast') {
      await _screenplayService.replaceCast(
        sceneId: sceneId,
        characterIds: (fields['cast'] as List).cast<String>(),
      );
      return {'ok': true, 'path': 'scenes/$sceneId/cast'};
    }
    final before = _screenplayOptionalField(fields, 'before_scene_id');
    final after = _screenplayOptionalField(fields, 'after_scene_id');
    final episodeId = _screenplayOptionalField(fields, 'episode_id');
    await _screenplayService.updateScene(
      sceneId: sceneId,
      locationId: fields.containsKey('location_id')
          ? Value(_screenplayOptionalField(fields, 'location_id'))
          : const Value.absent(),
      timeLabel: fields.containsKey('time')
          ? fields['time'] as String? ?? ''
          : null,
      stage: fields.containsKey('stage')
          ? fields['stage'] as String? ?? ''
          : null,
    );
    if (before != null) {
      await _screenplayService.moveSceneBefore(sceneId, before);
    }
    if (after != null) {
      await _screenplayService.moveSceneAfter(sceneId, after);
    }
    if (episodeId != null) {
      await _screenplayService.moveSceneToEpisodeEnd(sceneId, episodeId);
    }
    if (fields.containsKey('cast')) {
      await _screenplayService.replaceCast(
        sceneId: sceneId,
        characterIds: (fields['cast'] as List).cast<String>(),
      );
    }
    for (final field in ['title', 'emotion', 'events', 'interior_exterior']) {
      if (fields.containsKey(field)) {
        await _stageSceneProperty(parsed, sceneId, field, fields[field]);
      }
    }
    if (fields.containsKey('synopsis')) {
      final scene = await _contentService.database.screenplayDao.getScene(
        sceneId,
      );
      if (scene == null) {
        return _notFound(parsed, 'scene');
      }
      return _stageSynopsis(
        parsed,
        sceneId,
        scene.synopsis,
        fields['synopsis'] as String? ?? '',
      );
    }
    return {'ok': true, 'path': 'scenes/$sceneId'};
  }

  Future<Map<String, dynamic>> _editScreenplay(
    ParsedPath parsed,
    _ResourceOperation operation,
    String oldText,
    String newText,
    bool replaceAll,
  ) async {
    final resource = parsed._resource!;
    var matchCount = 0;
    var changed = false;
    _ReplaceTextResult replace(String source) {
      final result = AiToolManager._replaceExactText(
        source,
        oldText,
        newText,
        path: parsed.displayPath,
        replaceAll: replaceAll,
      );
      matchCount = result.matchCount;
      changed = result.changed;
      return result;
    }

    Future<Map<String, dynamic>> finish(
      Future<Map<String, dynamic>> pending,
    ) async {
      final result = await pending;
      if (!toolResultIsSuccess(result)) {
        return result;
      }
      return {...result, 'edited': changed, 'match_count': matchCount};
    }

    try {
      if (resource.schema.segment == 'scenes' && operation.field == 'title') {
        final scene = await _contentService.database.screenplayDao.getScene(
          resource.ids['scene_id']!,
        );
        if (scene == null) {
          return _notFound(parsed, 'scene');
        }
        // Edit 替换后的完整标题沿用标题业务语义；Write 输入已由 harness trim。
        final replaced = replace(scene.title);
        if (replaced.error != null) {
          return AiToolManager._replaceTextErrorResult(replaced);
        }
        final title = replaced.value!.trim();
        changed = title != scene.title;
        return await finish(
          _stageSceneProperty(parsed, scene.id, 'title', title),
        );
      }
      if (resource.schema.segment == 'scenes' &&
          operation.field == 'synopsis') {
        final scene = await _contentService.database.screenplayDao.getScene(
          resource.ids['scene_id']!,
        );
        if (scene == null) {
          return _notFound(parsed, 'scene');
        }
        final replaced = replace(scene.synopsis);
        if (replaced.error != null) {
          return AiToolManager._replaceTextErrorResult(replaced);
        }
        return await finish(
          _stageSynopsis(
            parsed,
            resource.ids['scene_id']!,
            scene.synopsis,
            replaced.value!,
          ),
        );
      }
      if (resource.schema.segment == 'elements') {
        final elements = await _sceneElements(resource.ids['scene_id']!);
        final index = elements.indexWhere(
          (item) => item.id == resource.ids['element_id'],
        );
        if (index < 0) {
          return _notFound(parsed, 'element');
        }
        final requirementError = _validateTargetRequirements(
          parsed,
          _ResourceTool.edit,
          const {},
          {'type': elements[index].type.name},
        );
        if (requirementError != null) {
          return _resourceError(
            parsed.displayPath,
            ToolErrorCode.permission_denied,
            requirementError['error'] as String,
          );
        }
        final replaced = replace(elements[index].text);
        if (replaced.error != null) {
          return AiToolManager._replaceTextErrorResult(replaced);
        }
        final target = [...elements]
          ..[index] = elements[index].copyWith(text: replaced.value!);
        return await finish(
          _stageElements(parsed, resource.ids['scene_id']!, elements, target),
        );
      }
      if (resource.schema.segment == 'episodes' &&
          operation.field == 'outline') {
        final episode = await _contentService.database.screenplayDao.getEpisode(
          resource.ids['episode_id']!,
        );
        if (episode == null) {
          return _notFound(parsed, 'episode');
        }
        final replaced = replace(episode.outline);
        if (replaced.error != null) {
          return AiToolManager._replaceTextErrorResult(replaced);
        }
        return await finish(
          _stageEpisodeOutline(
            parsed,
            resource.ids['episode_id']!,
            episode.outline,
            replaced.value!,
          ),
        );
      }
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.unsupported,
        'Edit supports only scene synopsis, scene element text, episode '
        'outline paths.',
      );
    } on WorkingOverlayConflictException catch (error) {
      return _workingChangeConflict(error);
    } on ScreenplayServiceException catch (error) {
      return _screenplayException(parsed.displayPath, error);
    } on ScreenplayElementValidationException catch (error) {
      return _resourceError(
        parsed.displayPath,
        _serviceErrorCode(error.errorCode),
        error.message,
      );
    } on FormatException catch (error) {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.invalid_argument,
        error.message,
      );
    }
  }

  Future<Map<String, dynamic>> _removeScreenplay(
    ParsedPath parsed, {
    bool force = false,
  }) async {
    final resource = parsed._resource!;
    try {
      if (resource.schema.segment == 'episodes') {
        await _screenplayService.deleteEpisode(resource.ids['episode_id']!);
      } else if (resource.schema.segment == 'scenes') {
        await _screenplayService.deleteScene(resource.ids['scene_id']!);
      } else if (resource.schema.segment == 'elements') {
        final current = await _sceneElements(resource.ids['scene_id']!);
        final index = current.indexWhere(
          (item) => item.id == resource.ids['element_id'],
        );
        if (index < 0) {
          return force
              ? _screenplayRemoveMissing(parsed)
              : _notFound(parsed, 'element');
        }
        if (current[index].type == ScreenplayElementType.character &&
            index + 1 < current.length &&
            (current[index + 1].type == ScreenplayElementType.parenthetical ||
                current[index + 1].type == ScreenplayElementType.dialogue)) {
          return _resourceError(
            parsed.displayPath,
            ToolErrorCode.failed_precondition,
            'Remove or reassign the dialogue block before deleting its character.',
          );
        }
        final target = [...current]..removeAt(index);
        return {
          ...await _stageElements(
            parsed,
            resource.ids['scene_id']!,
            current,
            target,
          ),
          'removed': true,
        };
      } else {
        return _invalidScreenplayPath(parsed);
      }
      return {'ok': true, 'removed': true, 'path': parsed.displayPath};
    } on WorkingOverlayConflictException catch (error) {
      return _workingChangeConflict(error);
    } on ScreenplayServiceException catch (error) {
      final missingCode = switch (resource.schema.segment) {
        'episodes' => 'invalid_episode_ref',
        'scenes' => 'invalid_scene_ref',
        _ => null,
      };
      // 删除目标本身不存在时，service 的 invalid_*_ref 对应工具层 not_found。
      if (error.errorCode == missingCode) {
        return force
            ? _screenplayRemoveMissing(parsed)
            : _resourceError(
                parsed.displayPath,
                ToolErrorCode.not_found,
                error.message,
              );
      }
      return _screenplayException(parsed.displayPath, error);
    }
  }

  Map<String, dynamic> _screenplayRemoveMissing(ParsedPath parsed) => {
    'ok': true,
    'path': parsed.displayPath,
    'removed': true,
    'missing': true,
  };

  Future<Map<String, dynamic>> _stageElements(
    ParsedPath parsed,
    String sceneId,
    List<ScreenplayElement> current,
    List<ScreenplayElement> target,
  ) async {
    final oldText = serializeScreenplayElements(current);
    final newText = serializeScreenplayElements(target);
    final change = await workingOverlayService.stageTextChange(
      resourcePath: 'scenes/$sceneId/elements',
      resourceType: workingChangeResourceTypeScreenplayScenes,
      resourceId: sceneId,
      field: 'elements',
      oldText: oldText,
      newText: newText,
      source: workingChangeSourceAi,
      sourceSessionId: _resolvedScreenplaySessionId(),
      sourceTurnId: _currentToolExecutionContext?.sourceTurnId,
      toolName: _currentStagingToolName ?? 'Write',
      summary: 'Update screenplay scene elements',
      expectedCurrentText: oldText,
    );
    _reportWorkingChange(change);
    final saved = await _sceneElements(sceneId);
    return {
      'ok': true,
      'path': 'scenes/$sceneId/elements',
      'entries': await _elementEntries(saved),
    };
  }

  Map<String, Object?> _scenePropertyValues(ScreenplaySceneRecord scene) => {
    'title': scene.title,
    'emotion': scene.emotion,
    'events': scene.events,
    'interior_exterior': scene.interiorExterior,
  };

  Future<Map<String, dynamic>> _stageSceneProperty(
    ParsedPath parsed,
    String sceneId,
    String field,
    Object? value,
  ) async {
    final scene = await _contentService.database.screenplayDao.getScene(
      sceneId,
    );
    if (scene == null) {
      return _notFound(parsed, 'scene');
    }
    final current = _scenePropertyValues(scene)[field];
    final target = value;
    final oldText = field == 'title' ? current as String : jsonEncode(current);
    final newText = field == 'title' ? target as String : jsonEncode(target);
    final change = await workingOverlayService.stageTextChange(
      resourcePath: 'scenes/$sceneId/$field',
      resourceType: workingChangeResourceTypeScreenplayScenes,
      resourceId: sceneId,
      field: field,
      oldText: oldText,
      newText: newText,
      source: workingChangeSourceAi,
      sourceSessionId: _resolvedScreenplaySessionId(),
      sourceTurnId: _currentToolExecutionContext?.sourceTurnId,
      toolName: _currentStagingToolName ?? 'Write',
      summary: 'Update screenplay scene $field',
      expectedCurrentText: oldText,
    );
    _reportWorkingChange(change);
    return {'ok': true, 'path': 'scenes/$sceneId/$field', field: target};
  }

  Future<Map<String, dynamic>> _stageSynopsis(
    ParsedPath parsed,
    String sceneId,
    String current,
    String target,
  ) async {
    final change = await workingOverlayService.stageTextChange(
      resourcePath: 'scenes/$sceneId/synopsis',
      resourceType: workingChangeResourceTypeScreenplayScenes,
      resourceId: sceneId,
      field: 'synopsis',
      oldText: current,
      newText: target,
      source: workingChangeSourceAi,
      sourceSessionId: _resolvedScreenplaySessionId(),
      sourceTurnId: _currentToolExecutionContext?.sourceTurnId,
      toolName: _currentStagingToolName ?? 'Write',
      summary: 'Update screenplay scene synopsis',
      expectedCurrentText: current,
    );
    _reportWorkingChange(change);
    return {'ok': true, 'path': 'scenes/$sceneId/synopsis', 'synopsis': target};
  }

  Future<Map<String, dynamic>> _stageEpisodeOutline(
    ParsedPath parsed,
    String episodeId,
    String current,
    String target,
  ) async {
    final change = await workingOverlayService.stageTextChange(
      resourcePath: 'episodes/$episodeId/outline',
      resourceType: workingChangeResourceTypeScreenplayEpisodes,
      resourceId: episodeId,
      field: 'outline',
      oldText: current,
      newText: target,
      source: workingChangeSourceAi,
      sourceSessionId: _resolvedScreenplaySessionId(),
      sourceTurnId: _currentToolExecutionContext?.sourceTurnId,
      toolName: _currentStagingToolName ?? 'Write',
      summary: 'Update screenplay episode outline',
      expectedCurrentText: current,
    );
    _reportWorkingChange(change);
    return {
      'ok': true,
      'path': 'episodes/$episodeId/outline',
      'outline': target,
    };
  }

  String _resolvedScreenplaySessionId() {
    final context = _currentToolExecutionContext;
    final value =
        context?.sourceSessionId ??
        sourceSessionId ??
        context?.sessionId ??
        sessionId;
    if (value == null || value.trim().isEmpty) {
      throw const ScreenplayServiceException(
        'missing_session_context',
        'Screenplay body changes require a session context.',
      );
    }
    return value;
  }

  /// scenes listing 的集作用域：只认显式 `episode_id`，没有就按季号、
  /// 集号枚举整剧。
  ///
  /// 刻意不回落到当前集：那样会把整剧读悄悄缩成一集，而 listing 的 `total`
  /// 也跟着缩水，模型无从察觉结果被过滤过，会把一集的场次数当成全剧的。
  /// 少一次往返换一个静默的错误结论，不划算。
  ///
  /// [scopedId] 仅在显式指定单集时有值，用于 listing 顶层回显；枚举整剧时留空，
  /// 避免把第一集伪装成整个结果的作用域。条目自带 `episode_id`，
  /// 而 `scene_number` 是集内位置，跨集拼接时不重编号。
  Future<({List<String> ids, String? scopedId, Map<String, dynamic>? error})>
  _resolveReadEpisodes(String screenplayId, ParsedPath parsed) async {
    final dao = _contentService.database.screenplayDao;
    final episodeId = parsed.queryParameters['episode_id'];
    if (episodeId != null && episodeId.isNotEmpty) {
      final episode = await dao.getEpisode(episodeId);
      if (episode == null) {
        return (
          ids: const <String>[],
          scopedId: null,
          error: _resourceError(
            parsed.displayPath,
            ToolErrorCode.not_found,
            'The selected episode does not exist.',
            hint:
                'Read ${_resourceReferencePath('episodes')} and copy an episode_id.',
          ),
        );
      }
      return (ids: [episode.id], scopedId: episode.id, error: null);
    }
    final ids = <String>[];
    for (final season in await dao.getSeasons(screenplayId)) {
      for (final episode in await dao.getEpisodes(season.id)) {
        ids.add(episode.id);
      }
    }
    return (ids: ids, scopedId: null, error: null);
  }

  /// episodes listing 的季作用域：只认显式 `season_id`，没有就按季号枚举整剧。
  ///
  /// 与 [_resolveReadEpisodes] 同样刻意不回落到当前季 —— 那样会让多季剧本的
  /// listing 连同 `total` 一起缩成一季，模型会把一季的集数当成全剧的。
  Future<({List<String> ids, String? scopedId, Map<String, dynamic>? error})>
  _resolveReadSeasons(String screenplayId, ParsedPath parsed) async {
    final dao = _contentService.database.screenplayDao;
    final seasonId = parsed.queryParameters['season_id'];
    if (seasonId != null && seasonId.isNotEmpty) {
      final season = await dao.getSeason(seasonId);
      if (season == null || season.screenplayId != screenplayId) {
        return (
          ids: const <String>[],
          scopedId: null,
          error: _resourceError(
            parsed.displayPath,
            ToolErrorCode.not_found,
            'Season was not found.',
            hint:
                'Read ${_resourceReferencePath('seasons')} and copy a season_id.',
          ),
        );
      }
      return (ids: [season.id], scopedId: season.id, error: null);
    }
    return (
      ids: [for (final season in await dao.getSeasons(screenplayId)) season.id],
      scopedId: null,
      error: null,
    );
  }

  /// Create episode 的落点：只认显式 `season_id`，没有就报错，不看当前季。
  Future<({String? id, Map<String, dynamic>? error})> _resolveSeason(
    String screenplayId,
    ParsedPath parsed, {
    Map<String, dynamic>? fields,
  }) async {
    final explicit =
        parsed.queryParameters['season_id'] ??
        _screenplayOptionalField(fields ?? const {}, 'season_id');
    if (explicit != null) {
      final season = await _contentService.database.screenplayDao.getSeason(
        explicit,
      );
      if (season == null || season.screenplayId != screenplayId) {
        return (
          id: null,
          error: _resourceError(
            parsed.displayPath,
            ToolErrorCode.invalid_argument,
            'Season was not found.',
          ),
        );
      }
      return (id: explicit, error: null);
    }
    // 不回落到当前季：新集会静默落进用户正在看的那一季，而调用方以为自己指定过。
    // schema 的 required 已经拦在前面，这里是兜底。
    return (
      id: null,
      error: _resourceError(
        parsed.displayPath,
        ToolErrorCode.invalid_argument,
        'season_id is required.',
        hint: 'Read ${_resourceReferencePath('seasons')} and copy a season_id.',
      ),
    );
  }

  Future<List<ScreenplayElement>> _sceneElements(String sceneId) async {
    final rows = await _contentService.database.screenplayDao.getElementRows(
      sceneId,
    );
    return [
      for (final row in rows)
        ScreenplayElement(
          id: row.id,
          type: screenplayElementTypeFromName(row.type),
          text: row.textContent,
          characterId: row.characterId,
          extension: row.extension,
        ),
    ];
  }

  Future<Map<String, String>> _characterNames() async => {
    for (final character in await _contentService.getCharacterProfiles())
      character.id: character.name,
  };

  Future<List<Map<String, dynamic>>> _castEntries(String sceneId) async {
    final names = await _characterNames();
    final rows = await _contentService.database.screenplayDao
        .getSceneCharacters(sceneId);
    return [
      for (final row in rows)
        {
          'character_id': row.characterId,
          'name': names[row.characterId] ?? '（角色不存在）',
        },
    ];
  }

  Future<List<Map<String, dynamic>>> _elementEntries(
    List<ScreenplayElement> elements,
  ) async => [
    for (final element in elements) await _elementEntry(element, listing: true),
  ];

  Future<Map<String, dynamic>> _elementEntry(
    ScreenplayElement element, {
    bool listing = false,
  }) async {
    final names = await _characterNames();
    return _screenplayElementDefinition.readValues({
      'id': element.id,
      'type': element.type.name,
      'character_id': element.characterId,
      'name': names[element.characterId] ?? '（角色不存在）',
      if (element.extension.isNotEmpty) 'extension': element.extension,
      'text': element.text,
    }, listing: listing);
  }

  List<ScreenplayElement> _decodeElements(List<dynamic> values) => [
    for (final value in values)
      _elementFromFields(value as Map<String, dynamic>),
  ];

  ScreenplayElement _elementFromFields(
    Map<String, dynamic> fields, {
    ScreenplayElement? existing,
  }) {
    final type = screenplayElementTypeFromName(
      fields['type'] as String? ?? existing!.type.name,
    );
    final element = ScreenplayElement(
      id: _screenplayOptionalField(fields, 'id') ?? existing?.id,
      type: type,
      text: fields.containsKey('text')
          ? fields['text'] as String? ?? ''
          : existing?.text ?? '',
      characterId: fields.containsKey('character_id')
          ? _screenplayOptionalField(fields, 'character_id')
          : existing?.characterId,
      extension: fields.containsKey('extension')
          ? fields['extension'] as String? ?? ''
          : existing?.extension ?? '',
    );
    // 局部更新可能继承旧类型或旧关联，需校验合并后的元素字段组合。
    element.validateShape();
    if (type != ScreenplayElementType.character && element.text.isEmpty) {
      throw const FormatException('Non-character elements require text.');
    }
    return element;
  }
}

// 已规范化的可选空字符串沿用业务上的「未选择／清除关联」语义。
String? _screenplayOptionalField(Map<String, dynamic> fields, String name) {
  final value = fields[name] as String?;
  return value == '' ? null : value;
}

Map<String, dynamic> _seasonJson(ScreenplaySeasonRow row) => {
  'id': row.id,
  'season_number': row.seasonNumber,
  'title': row.title,
  'planned_episode_count': row.plannedEpisodeCount,
  'path': 'seasons/${row.id}',
};

Map<String, dynamic> _episodeJson(
  ScreenplayEpisodeRow row, {
  bool includeOutline = false,
}) => {
  'id': row.id,
  'season_id': row.seasonId,
  'editing_id': row.editingId,
  'episode_number': row.episodeNumber,
  'title': row.title,
  if (includeOutline) 'outline': row.outline,
  'path': 'episodes/${row.id}',
};

Map<String, dynamic> _sceneSummaryJson(ScreenplaySceneSummary row) => {
  'id': row.id,
  'episode_id': row.episodeId,
  'scene_number': row.sceneNumber,
  'location_id': row.locationId,
  'interior_exterior': row.interiorExterior,
  'time': row.timeLabel,
  'synopsis': row.synopsis,
  'title': row.title,
  'emotion': row.emotion,
  'stage': row.stage,
  'page_eighths': row.pageEighths,
  'dialogue_line_count': row.dialogueLineCount,
  'word_count': row.wordCount,
  'path': 'scenes/${row.id}',
};

String _sceneHeading(ScreenplaySceneRecord row) => [
  row.interiorExterior?.toUpperCase(),
  row.locationId,
  row.timeLabel,
].whereType<String>().where((value) => value.isNotEmpty).join(' - ');

Map<String, dynamic> _screenplayException(
  String path,
  ScreenplayServiceException error,
) => _resourceError(
  path,
  _serviceErrorCode(error.errorCode),
  error.message,
  details: error.details,
);

Map<String, dynamic> _invalidScreenplayPath(ParsedPath parsed) =>
    _resourceError(
      parsed.displayPath,
      ToolErrorCode.invalid_argument,
      'Unsupported screenplay path.',
    );

Map<String, dynamic> _notFound(ParsedPath parsed, String resource) =>
    _resourceError(
      parsed.displayPath,
      ToolErrorCode.not_found,
      '$resource was not found.',
    );

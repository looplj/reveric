// 职责: 执行制作画布、剧本制作设置与视觉风格和素材查询工具，保留事务与变更历史。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_production_schema.dart
//   lib/shared/services/storyboard/service.dart
//   lib/shared/services/production/canvas_service.dart
part of 'tools.dart';

extension _ProductionStyleAccess on _AiToolManagerBase {
  Future<ProductionCanvasService> _productionStyleService() async {
    final build = productionStyleServiceBuilder;
    if (build == null) {
      throw const ToolOperationException(
        'unavailable',
        'Visual styles require a work session.',
      );
    }
    final service = await build();
    if (!identical(service.db, _contentService.database)) {
      throw const ToolPermissionException(
        'permission_denied',
        'Cross-work style access is unavailable.',
      );
    }
    return service;
  }
}

extension _ProductionTools on _AiToolManagerScreenplayMixin {
  Future<Map<String, dynamic>> _executeScreenplayStyle(
    ParsedPath parsed,
    _ResourceOperation operation,
    Map<String, dynamic> fields,
    ({String oldText, String newText, bool replaceAll})? edit,
  ) async {
    try {
      final service = StoryboardService(
        _contentService.database,
        contentKind: _targetContentKind,
      );
      final settingsPath = _targetContentKind == contentKindCanvas
          ? 'production/settings'
          : 'screenplay';
      return await service.write('UPDATE_SETTINGS', settingsPath, () async {
        final root = await service.getSettings();
        if (root == null) {
          return _notFound(parsed, 'screenplay');
        }
        if (operation.tool == _ResourceTool.read) {
          final data = {
            'id': root.id,
            'path': settingsPath,
            'style_id': root.styleId,
            'ratio': root.ratio,
            'resolution': root.resolution,
          };
          return parsed.hasField ? {'value': data[parsed.field]} : data;
        }
        final settings = <String, dynamic>{
          for (final key in ['ratio', 'resolution'])
            if (fields.containsKey(key)) key: fields[key],
        };
        final editsStyle = edit != null && operation.field == 'style_id';
        var next = fields.containsKey('style_id')
            ? fields['style_id'] as String?
            : root.styleId;
        var matches = 0;
        if (edit != null) {
          final replaced = AiToolManager._replaceExactText(
            switch (operation.field) {
              'ratio' => root.ratio,
              'resolution' => root.resolution,
              _ => root.styleId ?? '',
            },
            edit.oldText,
            edit.newText,
            path: parsed.displayPath,
            replaceAll: edit.replaceAll,
          );
          if (replaced.error != null) {
            return AiToolManager._replaceTextErrorResult(replaced);
          }
          if (editsStyle) {
            next = replaced.value;
          } else {
            settings[operation.field!] = replaced.value;
          }
          matches = replaced.matchCount;
        }
        if (next == 'none') {
          next = null;
        }
        ProductionSettings.validate(
          settings['ratio'] as String? ?? root.ratio,
          settings['resolution'] as String? ?? root.resolution,
        );
        if (next != null && (fields.containsKey('style_id') || editsStyle)) {
          await (await _productionStyleService()).requireStyle(next);
        }
        if (next != root.styleId) {
          final change = await workingOverlayService.stageTextChange(
            resourcePath: '$settingsPath/style_id',
            resourceType: 'screenplays',
            resourceId: root.id,
            field: 'style_id',
            oldText: jsonEncode(root.styleId),
            newText: jsonEncode(next),
            expectedCurrentText: jsonEncode(root.styleId),
            source: workingChangeSourceAi,
            sourceSessionId: _resolvedScreenplaySessionId(),
            sourceTurnId: _currentToolExecutionContext?.sourceTurnId,
            toolName: operation.tool.name,
          );
          _reportWorkingChange(change);
        }
        final saved = settings.isEmpty
            ? root
            : await service.saveSettings(settings);
        final updated =
            next != root.styleId ||
            saved.ratio != root.ratio ||
            saved.resolution != root.resolution;
        return {
          'ok': true,
          'id': root.id,
          'path': settingsPath,
          'style_id': next,
          'ratio': saved.ratio,
          'resolution': saved.resolution,
          'updated': updated,
          if (edit != null) ...{'edited': updated, 'match_count': matches},
        };
      });
    } on FormatException catch (error) {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.invalid_argument,
        error.message,
      );
    } on ToolOperationException catch (error) {
      return {'ok': false, 'error_code': error.code, 'error': error.message};
    } on StoryboardException {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.invalid_argument,
        'Style is unavailable. Query Run styles for available styles.',
      );
    } on WorkingOverlayConflictException catch (error) {
      return _workingChangeConflict(error);
    }
  }

  Future<Map<String, dynamic>> _executeProductionMetadata(
    ParsedPath parsed,
  ) async {
    final build = operationHost?.production;
    if (build == null) {
      throw const ToolOperationException(
        'unavailable',
        'Production services are unavailable.',
      );
    }
    final host = await build();
    if (!identical(host.canvas.db, _contentService.database)) {
      throw const ToolPermissionException(
        'permission_denied',
        'Cross-work media queries are unavailable.',
      );
    }
    final entries = <Map<String, dynamic>>[];
    final clipId = parsed.locator('clip_id')!;
    await host.nodeForClip(clipId);
    final tasks = await host.database.generationTaskDao
        .watchSource(
          novelId: host.canvas.novelId,
          sourceType: 'production_clip',
          sourceId: clipId,
        )
        .first;
    for (final task in tasks) {
      entries.add({
        ...await host.summary(task),
        'path':
            '${_targetContentKind == contentKindCanvas ? 'production/' : ''}clips/$clipId/generations/${task.id}',
        'model_id': task.modelId,
        'run_id': operationHost?.operations.state.runs
            .where((run) => run.taskId == task.id && !run.terminal)
            .firstOrNull
            ?.runId,
        'request': task.requestJson.toJson(),
      });
    }
    if (parsed.isResourceListing) {
      return {'type': 'listing', 'entries': entries};
    }
    final id = parsed.locator('task_id');
    final entry = entries.where((e) => e['id'] == id).firstOrNull;
    if (entry == null) {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.not_found,
        'Media resource not found.',
      );
    }
    return parsed.hasField ? {'value': entry[parsed.field]} : entry;
  }

  Future<Map<String, dynamic>> _executeProduction(
    ParsedPath parsed,
    _ResourceOperation operation, {
    Map<String, dynamic> fields = const {},
  }) async {
    final db = _contentService.database;
    final shots = StoryboardService(db, contentKind: _targetContentKind);
    final canvasWork = _targetContentKind == contentKindCanvas;
    final episodeId = canvasWork ? '' : parsed.locator('episode_id')!;
    final base = canvasWork
        ? 'production/canvas'
        : 'episodes/$episodeId/production/canvas';
    final segment = parsed.resourceSegment;
    final tool = operation.tool;
    Future<Map<String, dynamic>> nodeData(CanvasNode node) async {
      final editing = node.editingId == null
          ? null
          : await db.editingDao.get(node.editingId!);
      return {
        'id': node.id,
        'type': node.type,
        'ref_type': node.refType,
        'ref_id': node.refId,
        'title': editing?.title ?? node.title,
        if (node.type == canvasNodeTypeText) 'content': node.content,
        'x': node.x,
        'y': node.y,
        'width': node.width,
        'height': node.height,
        'parent_id': node.parentId,
        'panorama': PanoramaView.fromStyle(node.style)?.toJson(),
        'image_method': (node.style?['imageGeneration'] as Map?)?['method'],
        if (node.type == canvasNodeTypeGroup)
          'group': ProductionGroupLayout.fromStyle(node.style).toJson(),
        'path': '$base/nodes/${node.id}',
      };
    }

    Map<String, dynamic> edgeData(ProductionConnection edge) => {
      'id': edge.id,
      'source_node_id': edge.sourceNodeId,
      'target_node_id': edge.targetNodeId,
      'type': edge.type,
      'role': edge.role,
      'path': '$base/edges/${edge.id}',
    };
    try {
      await shots.requireEpisode(episodeId);
      if (segment == 'production') {
        final data = <String, dynamic>{
          'id': canvasWork ? (await shots.requireSettings()).id : episodeId,
          'path': canvasWork ? 'production' : 'episodes/$episodeId/production',
          if (canvasWork) 'settings_path': 'production/settings',
          if (canvasWork) 'clips_path': 'production/clips',
          'canvas_path': base,
        };
        return parsed.hasField ? {'value': data[parsed.field]} : data;
      }
      Future<CanvasEntry?> readCanvas() async {
        if (canvasWork) {
          return shots.ensureCanvas('');
        }
        final episode = (await db.screenplayDao.getEpisode(episodeId))!;
        final canvas = episode.canvasId == null
            ? null
            : await db.canvasDao.getCanvasById(episode.canvasId!);
        if (canvas != null && canvas.kind != canvasKindProduction) {
          throw const StoryboardException('invalid_reference');
        }
        return canvas;
      }

      if (tool == _ResourceTool.read) {
        final canvas = await readCanvas();
        if (canvas == null) {
          return _resourceError(
            parsed.displayPath,
            ToolErrorCode.not_found,
            'Production canvas has not been created. Use Create on this canvas path.',
          );
        }
        final nodes = await db.canvasDao.getNodesByCanvas(canvas.id);
        final edges = (await ProductionCanvasService.readContent(
          db,
          canvas.id,
        )).edges;
        if (segment == 'canvas') {
          final data = {
            'id': canvas.id,
            'path': base,
            if (!canvasWork) 'episode_id': episodeId,
            'nodes': await Future.wait(nodes.map(nodeData)),
            'edges': edges.map(edgeData).toList(),
          };
          return parsed.hasField ? {'value': data[parsed.field]} : data;
        }
        final values = segment == 'nodes'
            ? await Future.wait(nodes.map(nodeData))
            : edges.map(edgeData).toList();
        if (parsed.isResourceListing) {
          return {'type': 'listing', 'entries': values};
        }
        final id = parsed.locator(segment == 'nodes' ? 'node_id' : 'edge_id');
        final value = values.where((v) => v['id'] == id).firstOrNull;
        if (value == null) {
          throw const StoryboardException('source_missing');
        }
        return parsed.hasField
            ? {'value': parsed.field == 'data' ? value : value[parsed.field]}
            : value;
      }
      return await shots.write('AI_PRODUCTION', episodeId, () async {
        final canvas = await shots.ensureCanvas(episodeId);
        Future<CanvasNode> requireNode(String id) async {
          final node = await db.canvasDao.getNodeById(id);
          if (node == null || node.canvasId != canvas.id) {
            throw const StoryboardException('source_missing');
          }
          return node;
        }

        final groups = ProductionGroupService(shots);
        // 分组规则统一在 group_service：删除分组连带成员，分组移动带动成员，分镜组成员不能单独移动。
        Future<void> removeNode(CanvasNode node) => groups.remove(node);

        Future<void> position(CanvasNode node, Map values) async {
          final x = values['x'] ?? node.x, y = values['y'] ?? node.y;
          if (x is! num || y is! num || !x.isFinite || !y.isFinite) {
            throw const StoryboardException('invalid_config');
          }
          await groups.move(node, x.toDouble(), y.toDouble());
        }

        if (segment == 'canvas') {
          final positions = fields['positions'] as List? ?? const [];
          final ids = <String>{};
          for (final item in positions) {
            if (item is! Map ||
                item['id'] is! String ||
                !ids.add(item['id'] as String)) {
              throw const StoryboardException('invalid_config');
            }
            await position(await requireNode(item['id'] as String), item);
          }
          final types = (fields['remove_types'] as List? ?? const [])
              .cast<String>()
              .toSet();
          if (types.isNotEmpty) {
            for (final node in await db.canvasDao.getNodesByCanvas(canvas.id)) {
              if (types.contains(node.type)) {
                await removeNode(node);
              }
            }
          }
          return {'ok': true, 'updated': true, 'id': canvas.id, 'path': base};
        }
        if (segment != 'nodes') {
          throw const StoryboardException('invalid_config');
        }
        if (tool == _ResourceTool.create) {
          final type = fields['type'];
          if (fields.containsKey('content') && type != canvasNodeTypeText) {
            throw const StoryboardException('invalid_config');
          }
          String? refId = fields['ref_id'] as String?;
          final expectedRefType = {'video', 'image', 'audio'}.contains(type)
              ? canvasNodeRefTypeProductionClip
              : canvasNodeRefTypeStaging;
          if (fields['ref_type'] != null &&
              fields['ref_type'] != expectedRefType) {
            throw const StoryboardException('invalid_reference');
          }
          CanvasNode node;
          if ({'video', 'image', 'audio'}.contains(type)) {
            if (refId == null) {
              final clip = await StoryboardEditOrchestrator().create(
                service: shots,
                overlay: workingOverlayService,
                episodeId: episodeId,
                values: {
                  'kind': type,
                  'title': fields['title'] ?? '',
                  if (type == 'video') 'duration_ms': 6000,
                },
                origin: ShotEditOrigin.agent(
                  sessionId: _resolvedScreenplaySessionId(),
                  tool: 'Create',
                  turnId: _currentToolExecutionContext?.sourceTurnId,
                ),
              );
              refId = clip.id;
            }
            final clip = await shots.getShot(refId);
            if (clip == null ||
                clip.kind != type ||
                clip.episodeId != episodeId) {
              throw const StoryboardException('invalid_reference');
            }
            node = await shots.ensureClipNode(refId);
          } else if (type == canvasNodeTypeMedia) {
            if ((fields['asset_id'] == null) == (fields['path'] == null) ||
                refId != null ||
                fields['ref_type'] != null) {
              throw const StoryboardException('invalid_reference');
            }
            final build = operationHost?.production;
            if (build == null) {
              throw const ToolOperationException(
                'unavailable',
                'Production services are unavailable.',
              );
            }
            final host = await build();
            if (!identical(host.canvas.db, db)) {
              throw const ToolPermissionException(
                'permission_denied',
                'Cross-work media writes are unavailable.',
              );
            }
            node = fields['asset_id'] != null
                ? await host.canvas.addMedia(
                    canvas.id,
                    fields['asset_id'] as String,
                  )
                : await host.canvas.addMedia(
                    canvas.id,
                    (await host.importPath(
                      fields['path'] as String,
                      _currentToolExecutionContext ??
                          (throw const ToolOperationException(
                            'unavailable',
                            'Media import requires a chat session.',
                          )),
                      operationHost?.operations ??
                          (throw const ToolOperationException(
                            'unavailable',
                            'Media import requires session operations.',
                          )),
                      _activeRunCallId ?? '',
                    )).id,
                  );
          } else if (type == canvasNodeTypeText ||
              type == canvasNodeTypeEditing) {
            if (refId != null || fields['ref_type'] != null) {
              throw const StoryboardException('invalid_reference');
            }
            final service = await _productionStyleService();
            node = type == canvasNodeTypeText
                ? await service.addText(
                    canvas.id,
                    title: fields['title'] as String? ?? '',
                    content: fields['content'] as String? ?? '',
                  )
                : await service.addEditing(
                    canvas.id,
                    title: fields['title'] as String? ?? '',
                  );
          } else if (type == canvasNodeTypeStaging) {
            final stagings = _contentService.stagingEditService;
            final staging = refId == null
                ? await stagings.create(fields['title'] as String? ?? 'Staging')
                : await stagings.require(refId);
            refId = staging.id;
            final existingNodes = await db.canvasDao.getNodesByCanvas(
              canvas.id,
            );
            var x = 0.0;
            for (final existing in existingNodes) {
              final right = existing.x + (existing.width ?? 300) + 120;
              if (right > x) {
                x = right;
              }
            }
            final id = await insertWithShortEntityId(
              type: ShortEntityIdType.canvasNode,
              tableName: 'canvas_nodes',
              idExists: db.canvasDao.nodeIdExists,
              insert: (id) => db
                  .into(db.canvasNodes)
                  .insert(
                    CanvasNodesCompanion.insert(
                      id: id,
                      canvasId: canvas.id,
                      type: const Value(canvasNodeTypeStaging),
                      refType: const Value(canvasNodeRefTypeStaging),
                      refId: Value(refId),
                      title: Value(staging.title),
                      x: Value(x),
                      y: const Value(80),
                      width: const Value(300),
                      height: const Value(220),
                    ),
                  ),
            );
            node = (await db.canvasDao.getNodeById(id))!;
          } else {
            throw const StoryboardException('invalid_config');
          }
          await position(node, fields);
          return {
            'ok': true,
            'created': true,
            ...await nodeData((await db.canvasDao.getNodeById(node.id))!),
          };
        }
        final node = await requireNode(parsed.locator('node_id')!);
        if (tool == _ResourceTool.remove) {
          await removeNode(node);
          return {
            'ok': true,
            'removed': true,
            'path': '$base/nodes/${node.id}',
          };
        }
        if (fields.containsKey('content')) {
          if (node.type != canvasNodeTypeText) {
            throw const StoryboardException('invalid_config');
          }
          await (await _productionStyleService()).updateText(
            node.id,
            content: fields['content'] as String,
            title: fields['title'] as String? ?? node.title,
          );
        }
        if (fields.containsKey('title')) {
          // Video content is owned by /clips; canvas writes only change its layout.
          if (node.clipId != null) {
            throw const StoryboardException('invalid_config');
          }
          if (node.editingId != null) {
            final project = await db.editingDao.get(node.editingId!);
            if (project == null) {
              throw const StoryboardException('source_missing');
            }
            await db.editingDao.save(
              project.id,
              expectedRevision: project.revision,
              document: project.document,
              title: fields['title'] as String,
            );
          }
          await db.canvasDao.updateActiveNodeFields(
            node.id,
            CanvasNodesCompanion(title: Value(fields['title'] as String)),
          );
        }
        await position(node, fields);
        return {
          'ok': true,
          'updated': true,
          ...await nodeData((await db.canvasDao.getNodeById(node.id))!),
        };
      });
    } on ToolOperationException catch (error) {
      return {'ok': false, 'error_code': error.code, 'error': error.message};
    } on StoryboardException catch (error) {
      return _resourceError(
        parsed.displayPath,
        error.code == 'source_missing'
            ? ToolErrorCode.not_found
            : ToolErrorCode.invalid_argument,
        'Invalid production canvas operation: ${error.code}',
      );
    } on DocumentError catch (error) {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.invalid_argument,
        'Invalid staging reference: ${error.reason}',
      );
    }
  }
}

const _assetsHelp =
    'assets list: optional type and search (name substring). '
    'assets read: id required. Returns id, name, type, file_path, specifications and certifications. '
    'assets view-image: id required. Returns the same fields plus viewable image content; '
    'only image assets are accepted. '
    'assets certify: id and provider_id required; image assets only. '
    'Registers the asset into the provider\'s private asset library; '
    'the provider must have asset_certification=true. '
    'Returns status processing; assets read returns certifications '
    '(processing, active, or failed with error_code). '
    'Video generation on that provider then references the certified asset '
    'instead of uploading the file. '
    'Includes this work’s assets and shared assets, whether or not they are in the asset library. '
    'in_library is true only for assets the user added to the asset library; '
    'pickers in the app list only those, while references by asset id work either way.';

extension _AssetCommands on _AiToolManagerBase {
  Future<Map<String, dynamic>> _runAssetsCommand(
    String action,
    Map<String, dynamic> options,
  ) async {
    if (contentKind != contentKindScreenplay &&
        contentKind != contentKindCanvas) {
      throw const ToolOperationException(
        'unavailable',
        'Asset queries require a screenplay or canvas work.',
      );
    }
    if (!{'list', 'read', 'view-image', 'certify'}.contains(action)) {
      throw const FormatException(
        'Unknown assets action. Use Run help assets.',
      );
    }
    _productionCommandKeys(options, switch (action) {
      'list' => {'type', 'search'},
      'certify' => {'id', 'provider_id'},
      _ => {'id'},
    });
    final id = action == 'list' ? null : _productionCommandText(options, 'id');
    for (final key in ['type', 'search']) {
      if (options.containsKey(key) && options[key] is! String) {
        throw FormatException('$key must be a string.');
      }
    }
    final build = operationHost?.production;
    if (build == null) {
      throw const ToolOperationException(
        'unavailable',
        'Asset queries require an active work session.',
      );
    }
    final host = await build();
    if (!identical(host.canvas.db, _contentService.database)) {
      throw const ToolOperationException(
        'permission_denied',
        'Cross-work asset queries are unavailable.',
      );
    }
    final assets = await host.database.assetDao
        .watchAssets(
          novelId: host.canvas.novelId,
          type: options['type'] as String?,
        )
        .first;
    final certifications = <String, List<Map<String, dynamic>>>{};
    for (final row in await host.database.providerAssetDao.watchByAssets([
      for (final asset in assets) asset.id,
    ]).first) {
      (certifications[row.assetId] ??= []).add({
        'provider_id': row.providerId,
        'status': row.status.name,
        if (row.errorCode != null) 'error_code': row.errorCode,
      });
    }
    final search = (options['search'] as String?)?.toLowerCase();
    final files = SessionFiles(
      root: host.canvas.library.root.path,
      novelId: host.canvas.novelId,
    );
    final entries = <Map<String, dynamic>>[
      for (final asset in assets)
        if ((id == null || asset.id == id) &&
            (search == null || asset.name.toLowerCase().contains(search)))
          {
            'id': asset.id,
            'name': asset.name,
            'type': asset.type,
            'in_library': asset.inLibrary,
            'file_path': commandFileResult({
              'file_path': asset.path,
            }, files)['file_path'],
            'specifications': {
              'mime_type': asset.mimeType,
              'width': asset.width,
              'height': asset.height,
              'duration_ms': asset.durationMs,
              'bytes': asset.bytes,
            },
            'certifications': certifications[asset.id] ?? const [],
          },
    ];
    if (action == 'list') {
      return {'ok': true, 'entries': entries};
    }
    if (entries.isEmpty) {
      throw const ToolOperationException(
        'not_found',
        'Asset not found in this work.',
      );
    }
    final entry = entries.single;
    if (action == 'read') {
      return {'ok': true, ...entry};
    }
    if (action == 'certify') {
      return _certifyAsset(
        host,
        assets.singleWhere((asset) => asset.id == id),
        _productionCommandText(options, 'provider_id'),
      );
    }
    if (entry['type'] != 'image') {
      throw const FormatException(
        'assets view-image requires an image asset. Use assets read for metadata.',
      );
    }
    final stored = assets.singleWhere((asset) => asset.id == id).path;
    return {
      ...commandFileResult(await _viewAssetFile(stored), files),
      ...entry,
    };
  }

  Future<Map<String, dynamic>> _certifyAsset(
    ProductionToolHost host,
    AssetRow asset,
    String providerId,
  ) async {
    final service = host.assets;
    if (service == null) {
      throw const ToolOperationException(
        'unavailable',
        'Asset certification is unavailable in this session.',
      );
    }
    if (asset.type != 'image' || asset.path == null) {
      throw const FormatException(
        'assets certify requires an image asset with a file.',
      );
    }
    final media = await host.canvas.requireFile(asset.path!, type: 'image');
    try {
      await service.certify(
        assetId: asset.id,
        providerId: providerId,
        file: File(host.canvas.library.resolvePath(media.path)),
        mimeType: media.mimeType,
        name: asset.name,
      );
    } on ProviderAssetException catch (error) {
      throw ToolOperationException(
        error.code,
        error.message.isEmpty
            ? 'Asset certification failed: ${error.code}.'
            : error.message,
      );
    }
    return {
      'ok': true,
      'id': asset.id,
      'provider_id': providerId,
      'status': ProviderAssetStatus.processing.name,
    };
  }

  /// Asset content is the work's own data: read it directly without the files.read gate.
  Future<Map<String, dynamic>> _viewAssetFile(String? path) async {
    final session = _currentToolExecutionContext?.sessionId ?? sessionId;
    if (session == null) {
      throw const ToolOperationException(
        'unavailable',
        'Viewing assets requires an active chat session.',
      );
    }
    if (path == null || path.isEmpty) {
      throw const ToolOperationException(
        'not_found',
        'This asset has no file.',
      );
    }
    final cancellation = MediaCancellation();
    final unlink = _currentToolExecutionContext?.cancellationToken?.onCancel(
      () => unawaited(cancellation.cancel()),
    );
    try {
      return await FileReader(SessionFiles(novelId: workId), FfmpegRunner())
          .read(session, {'path': path, 'mode': 'image'}, cancellation)
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () async {
              await cancellation.cancel();
              throw const ToolOperationException(
                'timeout',
                'Viewing the asset exceeded 30 seconds.',
              );
            },
          );
    } on UnsupportedError {
      throw const ToolOperationException(
        'unsupported',
        'Media inspection requires Windows or macOS.',
      );
    } on FileSystemException catch (error, stack) {
      _log.error('Asset view failed', error: error, stackTrace: stack);
      throw const ToolOperationException(
        'unavailable',
        'The asset file could not be read.',
      );
    } finally {
      unlink?.call();
    }
  }
}

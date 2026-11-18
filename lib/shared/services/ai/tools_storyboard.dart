// 职责: 执行制片片段根集合的静态资源工具读写。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/storyboard/service.dart
//   lib/shared/services/storyboard/edit_orchestrator.dart
// 遵循的 Rules:
//   .agents/rules/ai-calling.md
//   .agents/rules/tools_path.md
part of 'tools.dart';

extension _StoryboardTools on _AiToolManagerScreenplayMixin {
  Future<Map<String, dynamic>> _executeStoryboard(
    ParsedPath parsed,
    _ResourceOperation operation, {
    Map<String, dynamic> fields = const {},
    ({String oldText, String newText, bool replaceAll})? edit,
  }) async {
    final service = StoryboardService(
      _contentService.database,
      contentKind: _targetContentKind,
    );
    final canvasWork = _targetContentKind == contentKindCanvas;
    try {
      Map<String, dynamic> data(ProductionClipRow row) => {
        'id': row.id,
        'path': '${canvasWork ? 'production/' : ''}clips/${row.id}',
        for (final entry in service.snapshot(row).entries)
          if (!canvasWork ||
              !const {
                'episode_id',
                'scene_id',
                'sort_order',
                'location_id',
                'item_id',
              }.contains(entry.key))
            entry.key: entry.value,
        if (!canvasWork) 'is_storyboard': row.sceneId != null,
        'adopted_asset_id': row.adoptedAssetId,
      };

      // Mutations name what changed instead of echoing the written record;
      // short placement fields always return because the service may derive
      // them, other values return only when stored differently from the request.
      const placement = {
        'kind',
        'episode_id',
        'scene_id',
        'sort_order',
        'is_storyboard',
      };
      Map<String, dynamic> changeSummary(
        ProductionClipRow row,
        String change,
        Map<String, dynamic> requested, {
        int? matchCount,
      }) {
        final stored = data(row);
        final adjusted = {
          for (final entry in requested.entries)
            if (entry.key != 'prompt' &&
                entry.key != 'inputs' &&
                !placement.contains(entry.key) &&
                stored.containsKey(entry.key) &&
                !const DeepCollectionEquality().equals(
                  stored[entry.key],
                  entry.value,
                ))
              entry.key: stored[entry.key],
        };
        return {
          'ok': true,
          change: true,
          'id': row.id,
          'path': stored['path'],
          for (final key in placement)
            if (stored.containsKey(key)) key: stored[key],
          'fields': requested.keys.toList(),
          'match_count': ?matchCount,
          if (adjusted.isNotEmpty) 'adjusted': adjusted,
          if (requested.containsKey('inputs'))
            'input_ids': [for (final input in row.inputs) input.id],
        };
      }

      if (operation.tool == _ResourceTool.read && parsed._resource!.listing) {
        final sceneId = parsed.queryParameters['scene_id'];
        final episodeId = parsed.queryParameters['episode_id'];
        final rows = <ProductionClipRow>[];
        if (canvasWork) {
          rows.addAll(await service.episodeClips(''));
        } else if (sceneId != null) {
          final scene = await service.requireScene(sceneId);
          if (episodeId != null && episodeId != scene.episodeId) {
            throw const StoryboardException('source_missing');
          }
          rows.addAll(await service.sceneShots(sceneId));
        } else if (episodeId != null) {
          await service.requireEpisode(episodeId);
          rows.addAll(await service.episodeClips(episodeId));
        } else {
          final root = await service.database.screenplayDao.getRoot();
          if (root == null) {
            throw const StoryboardException('source_missing');
          }
          for (final season in await service.database.screenplayDao.getSeasons(
            root.id,
          )) {
            for (final episode
                in await service.database.screenplayDao.getEpisodes(
                  season.id,
                )) {
              rows.addAll(await service.episodeClips(episode.id));
            }
          }
        }
        final filtered = _applyListingFilters(
          {
            'type': 'listing',
            'entries': [for (final row in rows) data(row)],
          },
          {
            for (final entry in parsed.queryParameters.entries)
              if (entry.key != 'view') entry.key: entry.value,
          },
        );
        if (parsed.queryParameters['view'] != 'summary') {
          return filtered;
        }
        return {
          ...filtered,
          'entries': [
            for (final entry
                in (filtered['entries'] as List).cast<Map<String, dynamic>>())
              Map<String, dynamic>.from(entry)..remove('prompt'),
          ],
        };
      }
      final origin = operation.tool == _ResourceTool.read
          ? const ShotEditOrigin.manual()
          : ShotEditOrigin.agent(
              sessionId: _resolvedScreenplaySessionId(),
              turnId: _currentToolExecutionContext?.sourceTurnId,
              tool: operation.tool.name,
            );
      Future<void> validateStyle(String kind) async {
        if (!fields.containsKey('style_selection')) {
          return;
        }
        if (kind != 'image' && kind != 'video') {
          throw const FormatException(
            'Visual styles require an image or video clip.',
          );
        }
        final choice = ProductionStyleChoice.fromStored(
          fields['style_selection'] as String?,
        );
        if (choice case PresetProductionStyle() || CustomProductionStyle()) {
          await (await _productionStyleService()).requireStyle(choice.stored!);
        }
      }

      Future<ProductionToolHost> productionHost() async {
        final build = operationHost?.production;
        if (build == null) {
          throw const ToolOperationException(
            'unavailable',
            'Production media services are unavailable.',
          );
        }
        final host = await build();
        if (!identical(host.canvas.db, service.database)) {
          throw const ToolPermissionException(
            'permission_denied',
            'Cross-work production editing is unavailable.',
          );
        }
        return host;
      }

      if (operation.tool == _ResourceTool.create) {
        await validateStyle(fields['kind'] as String? ?? 'video');
        final sceneId = fields['scene_id'] as String?;
        final episodeId = canvasWork ? '' : fields['episode_id'] as String?;
        if (sceneId == null && episodeId == null) {
          throw const StoryboardException('invalid_config');
        }
        final values = Map<String, dynamic>.from(fields)..remove('scene_id');
        final inputs = ((values.remove('inputs') as List?) ?? const [])
            .map(
              (value) => ProductionInput.fromJson(
                Map<String, dynamic>.from(value as Map),
              ),
            )
            .toList();
        if (inputs.isNotEmpty) {
          final host = await productionHost();
          final row = await host.canvas.createClipWithInputs(
            overlay: workingOverlayService,
            sceneId: sceneId,
            episodeId: episodeId,
            values: values,
            inputs: inputs,
            origin: origin,
          );
          return changeSummary(row, 'created', fields);
        }
        final row = await StoryboardEditOrchestrator().create(
          service: service,
          overlay: workingOverlayService,
          sceneId: sceneId,
          episodeId: episodeId,
          values: values,
          origin: origin,
        );
        return changeSummary(row, 'created', fields);
      }
      var row = await service.getShot(parsed.locator('clip_id')!);
      if (row == null) {
        return _resourceError(
          parsed.displayPath,
          ToolErrorCode.not_found,
          'Clip not found.',
        );
      }
      if (operation.tool == _ResourceTool.read) {
        final detail = {
          ...data(row),
          'inputs': await service.inputSnapshot(row.id),
        };
        return parsed.hasField ? {'value': detail[parsed.field]} : detail;
      }
      await validateStyle(row.kind);
      final changed = operation.tool == _ResourceTool.edit
          ? 'edited'
          : 'updated';
      final values = Map<String, dynamic>.from(fields);
      int? matchCount;
      if (edit != null) {
        final current = service.snapshot(row)[parsed.field] as String;
        matchCount = edit.oldText.isEmpty
            ? 0
            : edit.oldText.allMatches(current).length;
        if (edit.oldText.isEmpty || matchCount == 0) {
          return _resourceError(
            parsed.displayPath,
            ToolErrorCode.invalid_argument,
            edit.oldText.isEmpty
                ? 'old_text must not be empty.'
                : 'old_text was not found in ${parsed.field}; read the field again.',
          );
        }
        if (!edit.replaceAll && matchCount != 1) {
          return _resourceError(
            parsed.displayPath,
            ToolErrorCode.invalid_argument,
            'old_text matches $matchCount times in ${parsed.field}; include more surrounding text or set all=true.',
          );
        }
        values[parsed.field!] = edit.replaceAll
            ? current.replaceAll(edit.oldText, edit.newText)
            : current.replaceFirst(edit.oldText, edit.newText);
      }
      if (values.containsKey('prompt') && !values.containsKey('inputs')) {
        final prompt = StoryboardPrompt.parse(values['prompt'] as String);
        prompt.requireValidReferences(row.inputs.map((input) => input.id));
        if (prompt.references.isNotEmpty) {
          final host = await productionHost();
          final referencedIds = prompt.references
              .map((ref) => ref.inputId)
              .toSet();
          await host.canvas.validateInputs(
            node: await host.nodeForClip(row.id),
            values: {...service.snapshot(row), ...values},
            inputs: row.inputs
                .where((input) => referencedIds.contains(input.id))
                .toList(),
            origin: origin,
          );
        }
      }
      if (values.containsKey('inputs') ||
          values.containsKey('adopted_asset_id')) {
        final host = await productionHost();
        final node = await host.nodeForClip(row.id);
        return await service.write('AI_INPUTS', row.id, () async {
          if (values.containsKey('inputs')) {
            final inputs = <ProductionInput>[];
            for (final value in values.remove('inputs') as List) {
              inputs.add(
                ProductionInput.fromJson(
                  Map<String, dynamic>.from(value as Map),
                ),
              );
            }
            final selected = values.remove('adopted_asset_id');
            final hasSelected = fields.containsKey('adopted_asset_id');
            await host.canvas.saveDraft(
              nodeId: node.id,
              values: {...service.snapshot(row!), ...values},
              inputs: inputs,
              overlay: workingOverlayService,
              origin: origin,
            );
            if (hasSelected) {
              await host.adopt(row!.id, selected as String?);
            }
          } else {
            final selected = values.remove('adopted_asset_id') as String?;
            if (values.isNotEmpty) {
              row = await StoryboardEditOrchestrator().moveOrSave(
                service: service,
                overlay: workingOverlayService,
                shotId: row!.id,
                values: values,
                origin: origin,
              );
            }
            await host.adopt(row!.id, selected);
          }
          final current = (await service.getShot(node.clipId!))!;
          return changeSummary(
            current,
            changed,
            edit == null ? fields : {parsed.field!: values[parsed.field]},
            matchCount: matchCount,
          );
        });
      }
      row = await StoryboardEditOrchestrator().moveOrSave(
        service: service,
        overlay: workingOverlayService,
        shotId: row.id,
        values: values,
        origin: origin,
      );
      return changeSummary(
        row,
        changed,
        edit == null ? fields : {parsed.field!: values[parsed.field]},
        matchCount: matchCount,
      );
    } on ToolOperationException catch (error) {
      return {'ok': false, 'error_code': error.code, 'error': error.message};
    } on StoryboardException catch (e) {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.invalid_argument,
        [
          switch (e.code) {
            'source_missing' => 'The source scene or episode is unavailable.',
            'invalid_asset' =>
              'The referenced asset is missing or unavailable.',
            'invalid_reference' =>
              'The referenced input source is missing or invalid.',
            'cross_episode_move' =>
              'Moving a clip across episodes is not supported. Create a copy in the destination scene.',
            _ => 'Invalid production settings.',
          },
          ?e.detail,
        ].join(' '),
      );
    } on FormatException catch (e) {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.invalid_argument,
        e.message,
      );
    } on ScreenplayServiceException catch (e) {
      return _screenplayException(parsed.displayPath, e);
    } on WorkingOverlayConflictException catch (e) {
      return _workingChangeConflict(e);
    }
  }
}

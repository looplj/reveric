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
                'character_id',
                'location_id',
                'item_id',
              }.contains(entry.key))
            entry.key: entry.value,
        if (!canvasWork) 'is_storyboard': row.sceneId != null,
        'adopted_asset_id': row.adoptedAssetId,
      };

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
        return _applyListingFilters({
          'type': 'listing',
          'entries': [for (final row in rows) data(row)],
        }, parsed.queryParameters);
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
          return {
            'ok': true,
            'created': true,
            ...data(row),
            'inputs': await service.inputSnapshot(row.id),
          };
        }
        final row = await StoryboardEditOrchestrator().create(
          service: service,
          overlay: workingOverlayService,
          sceneId: sceneId,
          episodeId: episodeId,
          values: values,
          origin: origin,
        );
        return {'ok': true, 'created': true, ...data(row)};
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
      if (edit != null) {
        final current = service.snapshot(row)[parsed.field] as String;
        if (edit.oldText.isEmpty ||
            !current.contains(edit.oldText) ||
            (!edit.replaceAll &&
                edit.oldText.allMatches(current).length != 1)) {
          return _resourceError(
            parsed.displayPath,
            ToolErrorCode.invalid_argument,
            'The requested text must match exactly; read the field again.',
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
          return {
            'ok': true,
            changed: true,
            ...data(current),
            'inputs': await service.inputSnapshot(current.id),
          };
        });
      }
      row = await StoryboardEditOrchestrator().moveOrSave(
        service: service,
        overlay: workingOverlayService,
        shotId: row.id,
        values: values,
        origin: origin,
      );
      return {'ok': true, changed: true, ...data(row)};
    } on ToolOperationException catch (error) {
      return {'ok': false, 'error_code': error.code, 'error': error.message};
    } on StoryboardException catch (e) {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.invalid_argument,
        switch (e.code) {
          'source_missing' => 'The source scene or episode is unavailable.',
          'invalid_asset' => 'The referenced asset is missing or unavailable.',
          'invalid_reference' =>
            'The referenced input source is missing or invalid.',
          'cross_episode_move' =>
            'Moving a clip across episodes is not supported. Create a copy in the destination scene.',
          _ => 'Invalid production settings.',
        },
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

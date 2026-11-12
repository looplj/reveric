// 职责: 查询片段与剧本制作设置并执行归属和提示词校验后的事务保存。
// 关联文件:
//   lib/shared/database/novel_content_database.dart
//   lib/shared/models/storyboard/prompt.dart
//   lib/shared/services/storyboard/edit_orchestrator.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md
//   .agents/rules/service-naming.md
import 'dart:math' as math;

import 'package:drift/drift.dart';
import '../../database/novel_content_database.dart';
import '../../logger/app_logger.dart';
import '../../models/screenplay.dart';
import '../../models/content_kind.dart';
import '../../models/production/settings.dart';
import '../../models/storyboard/prompt.dart';
import '../../models/video/request.dart';
import '../../models/production/input.dart';
import '../../models/subject.dart';
import '../../utils/short_entity_id.dart';
import '../../utils/short_entity_id_allocator.dart';

class StoryboardException implements Exception {
  const StoryboardException(this.code, [this.detail]);
  final String code;

  /// 给 Agent 的具体原因；界面按 [code] 映射文案，不展示它。
  final String? detail;

  @override
  String toString() => detail == null
      ? 'StoryboardException($code)'
      : 'StoryboardException($code): $detail';
}

class StoryboardService {
  StoryboardService(
    this.database, {
    this.contentKind = contentKindScreenplay,
    this.resolveContentKind,
  });
  final String contentKind;
  final Future<String> Function()? resolveContentKind;

  /// 空集归属只允许来自作品登记或创建上下文的画布类型；不能从数据形状推断。
  Future<bool> get isCanvasWork async =>
      (await resolveContentKind?.call() ?? contentKind) == contentKindCanvas;
  final NovelContentDatabase database;
  static final _log = AppLogger.forModule('Storyboard');
  static const _settingsPromptStateKey = 'production_settings';

  Future<T> write<T>(
    String operation,
    String id,
    Future<T> Function() action,
  ) async {
    try {
      return await database.transaction(action);
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=production_clips,screenplays operation=$operation id=$id',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// 新片段用短 ID 严格插入；与历史行（含软删除）碰撞时换号重试。
  Future<String> _createClip(Map<String, dynamic> values) =>
      insertWithShortEntityId(
        type: ShortEntityIdType.productionClip,
        tableName: 'production_clips',
        idExists: (id) async =>
            await (database.selectOnly(database.productionClips)
                  ..addColumns([database.productionClips.id])
                  ..where(database.productionClips.id.equals(id))
                  ..limit(1))
                .getSingleOrNull() !=
            null,
        insert: (id) => apply(id, values, creating: true),
      );

  SimpleSelectStatement<ProductionClips, ProductionClipRow> _shots() =>
      database.select(database.productionClips)
        ..where((t) => t.deletedAt.equals(notDeletedSentinel));

  Future<ProductionClipRow?> getShot(String id) =>
      (_shots()..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<List<ProductionClipRow>> sceneShots(String sceneId) =>
      (_shots()
            ..where((t) => t.sceneId.equals(sceneId))
            ..orderBy([
              (t) => OrderingTerm.asc(t.sortOrder),
              (t) => OrderingTerm.asc(t.id),
            ]))
          .get();

  JoinedSelectStatement<HasResultSet, dynamic> _episodeQuery(String episodeId) {
    final shots = database.productionClips;
    final scenes = database.screenplayScenes;
    final headings = database.screenplaySceneElements;
    return database.select(shots).join([
        leftOuterJoin(scenes, scenes.id.equalsExp(shots.sceneId)),
        leftOuterJoin(
          headings,
          headings.sceneId.equalsExp(scenes.id) &
              headings.type.equals('scene_heading') &
              headings.deletedAt.equals(notDeletedSentinel),
        ),
      ])
      ..where(
        shots.deletedAt.equals(notDeletedSentinel) &
            shots.episodeId.equals(episodeId) &
            shots.sceneId.isNotNull(),
      )
      ..orderBy([
        OrderingTerm.asc(headings.sortOrder),
        OrderingTerm.asc(shots.sortOrder),
        OrderingTerm.asc(shots.id),
      ]);
  }

  Stream<List<ProductionClipRow>> watchShots(String episodeId) =>
      _episodeQuery(episodeId).watch().map(
        (rows) =>
            rows.map((row) => row.readTable(database.productionClips)).toList(),
      );
  Future<List<ProductionClipRow>> episodeShots(String episodeId) async =>
      (await _episodeQuery(
        episodeId,
      ).get()).map((row) => row.readTable(database.productionClips)).toList();

  Future<List<ProductionClipRow>> episodeClips(String episodeId) async => [
    ...await episodeShots(episodeId),
    ...await (_shots()
          ..where((t) => t.episodeId.equals(episodeId) & t.sceneId.isNull())
          ..orderBy([
            (t) => OrderingTerm.asc(t.createdAt),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .get(),
  ];

  Future<ScreenplayRow?> getSettings() => database.screenplayDao.getRoot();
  Future<ScreenplayRow> requireSettings() async {
    final row = await getSettings();
    if (row == null) {
      throw const StoryboardException('source_missing');
    }
    return row;
  }

  Stream<ScreenplayRow?> watchSettings() => database.screenplayDao.watchRoot();

  Future<bool> hasSettingsPrompted() async {
    final state = await database.novelStateDao.get(_settingsPromptStateKey);
    return state?.status == 'prompted';
  }

  Future<void> markSettingsPrompted() async {
    try {
      await database.novelStateDao.upsert(
        key: _settingsPromptStateKey,
        status: 'prompted',
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=novel_states operation=UPSERT id=$_settingsPromptStateKey',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> requireEpisode(String id) async {
    if (id.isEmpty) {
      if (await isCanvasWork &&
          await database.screenplayDao.getRoot() != null) {
        return;
      }
      throw const StoryboardException('source_missing');
    }
    final episode = await database.screenplayDao.getEpisode(id);
    final root = await database.screenplayDao.getRoot();
    final season = episode == null
        ? null
        : await database.screenplayDao.getSeason(episode.seasonId);
    if (episode == null ||
        season == null ||
        root == null ||
        episode.screenplayId != root.id ||
        season.screenplayId != root.id) {
      throw const StoryboardException('source_missing');
    }
  }

  Future<ScreenplaySceneRecord> requireScene(String id) async {
    final scene = await database.screenplayDao.getScene(id);
    if (scene == null) {
      throw const StoryboardException('source_missing');
    }
    await requireEpisode(scene.episodeId);
    if (scene.screenplayId != (await database.screenplayDao.getRoot())!.id) {
      throw const StoryboardException('source_missing');
    }
    return scene;
  }

  Future<ScreenplayRow> saveSettings(Map<String, dynamic> values) =>
      write('UPDATE_SETTINGS', 'screenplay', () async {
        final row = await requireSettings();
        if (values.keys.any((key) => !{'ratio', 'resolution'}.contains(key))) {
          throw const FormatException(
            'Only ratio and resolution can be changed.',
          );
        }
        final ratio = values['ratio'] as String? ?? row.ratio;
        final resolution = values['resolution'] as String? ?? row.resolution;
        ProductionSettings.validate(ratio, resolution);
        await (database.update(
          database.screenplays,
        )..where((t) => t.id.equals(row.id))).write(
          ScreenplaysCompanion(
            ratio: Value(ratio),
            resolution: Value(resolution),
            updatedAt: Value(DateTime.now()),
          ),
        );
        return (await getSettings())!;
      });

  Map<String, dynamic> snapshot(ProductionClipRow row) => {
    'episode_id': row.episodeId,
    'kind': row.kind,
    'character_id': row.characterId,
    'location_id': row.locationId,
    'item_id': row.itemId,
    'scene_id': row.sceneId,
    'sort_order': row.sortOrder,
    'title': row.title,
    'prompt': row.prompt,
    'style_selection': row.styleSelection,
    'provider_id': row.providerId,
    'model_id': row.modelId,
    'reference_mode': row.referenceMode,
    'duration_ms': row.durationMs,
    'generate_audio': row.generateAudio,
    'ratio': row.ratio,
    'resolution': row.resolution,
  };

  Future<ProductionClipRow> create(
    String sceneId, {
    Map<String, dynamic> values = const {},
  }) => write('INSERT', sceneId, () async {
    final scene = await requireScene(sceneId);
    final defaults = await requireSettings();
    final siblings = await sceneShots(sceneId);
    final data = <String, dynamic>{
      'episode_id': scene.episodeId,
      'kind': 'video',
      'scene_id': sceneId,
      'sort_order': siblings.isEmpty ? 0 : siblings.last.sortOrder! + 1,
      'title': '',
      'prompt': '',
      'reference_mode': 'reference',
      'ratio': values['kind'] == 'image' ? '1:1' : defaults.ratio,
      'resolution': values['kind'] == 'image' ? '1K' : defaults.resolution,
      ...values,
    };
    final id = await _createClip(data);
    return (await getShot(id))!;
  });

  Future<ProductionClipRow> createVideo(
    String episodeId, {
    Map<String, dynamic> values = const {},
  }) => write('INSERT', episodeId, () async {
    await requireEpisode(episodeId);
    final defaults = await requireSettings();
    final id = await _createClip({
      'episode_id': episodeId,
      'kind': 'video',
      'scene_id': null,
      'sort_order': null,
      'title': '',
      'prompt': '',
      'reference_mode': 'reference',
      'ratio': defaults.ratio,
      'resolution': defaults.resolution,
      ...values,
    });
    return (await getShot(id))!;
  });

  Future<ProductionClipRow> createImage(
    String episodeId, {
    Map<String, dynamic> values = const {},
  }) => write('INSERT', episodeId, () async {
    await requireEpisode(episodeId);
    final id = await _createClip({
      'episode_id': episodeId,
      'kind': 'image',
      'scene_id': null,
      'sort_order': null,
      'title': '',
      'prompt': '',
      'reference_mode': 'reference',
      'duration_ms': null,
      'ratio': '1:1',
      'resolution': '1K',
      ...values,
    });
    return (await getShot(id))!;
  });

  Future<ProductionClipRow> createAudio(
    String episodeId, {
    Map<String, dynamic> values = const {},
  }) => write('INSERT', episodeId, () async {
    await requireEpisode(episodeId);
    final id = await _createClip({
      'episode_id': episodeId,
      'kind': 'audio',
      'scene_id': null,
      'sort_order': null,
      'title': '',
      'prompt': '',
      'reference_mode': 'reference',
      'duration_ms': null,
      'ratio': '1:1',
      'resolution': '24k',
      ...values,
    });
    return (await getShot(id))!;
  });

  Future<CanvasEntry> ensureCanvas(String episodeId) => write(
    'ENSURE_CANVAS',
    episodeId,
    () async {
      await requireEpisode(episodeId);
      if (episodeId.isEmpty) {
        return _ensureWorkCanvas();
      }
      final production = (await database.screenplayDao.getEpisode(episodeId))!;
      if (production.canvasId != null) {
        final canvas = await database.canvasDao.getCanvasById(
          production.canvasId!,
        );
        if (canvas == null || canvas.kind != canvasKindProduction) {
          throw const StoryboardException('source_missing');
        }
        await _ensureSceneNodes(canvas.id, episodeId);
        return canvas;
      }
      final id = await insertWithShortEntityId(
        type: ShortEntityIdType.canvas,
        tableName: 'canvases',
        idExists: database.canvasDao.canvasIdExists,
        insert: (id) => database
            .into(database.canvases)
            .insert(
              CanvasesCompanion.insert(
                id: id,
                name: 'production-$episodeId',
                kind: const Value(canvasKindProduction),
              ),
            ),
      );
      await (database.update(
        database.screenplayEpisodes,
      )..where((t) => t.id.equals(production.id))).write(
        ScreenplayEpisodesCompanion(
          canvasId: Value(id),
          updatedAt: Value(DateTime.now()),
        ),
      );
      final clips =
          await (database.select(database.productionClips)..where(
                (t) =>
                    t.episodeId.equals(episodeId) &
                    t.deletedAt.equals(notDeletedSentinel),
              ))
              .get();
      for (final clip in clips) {
        await ensureClipNode(clip.id);
      }
      await _ensureSceneNodes(id, episodeId);
      return (await database.canvasDao.getCanvasById(id))!;
    },
  );

  Future<CanvasEntry> _ensureWorkCanvas() async {
    final existing =
        await (database.select(database.canvases)
              ..where(
                (t) =>
                    t.kind.equals(canvasKindProduction) &
                    t.deletedAt.equals(notDeletedSentinel),
              )
              ..orderBy([
                (t) => OrderingTerm.asc(t.createdAt),
                (t) => OrderingTerm.asc(t.id),
              ])
              ..limit(2))
            .get();
    if (existing.isNotEmpty) {
      if (existing.length > 1) {
        _log.error(
          '[DB] table=canvases operation=SELECT duplicate production canvases; using ${existing.first.id}',
        );
      }
      return existing.first;
    }
    final id = await insertWithShortEntityId(
      type: ShortEntityIdType.canvas,
      tableName: 'canvases',
      idExists: database.canvasDao.canvasIdExists,
      insert: (id) => database
          .into(database.canvases)
          .insert(
            CanvasesCompanion.insert(
              id: id,
              name: 'production',
              kind: const Value(canvasKindProduction),
            ),
          ),
    );
    return (await database.canvasDao.getCanvasById(id))!;
  }

  Future<CanvasNode> ensureClipNode(String clipId) =>
      write('ENSURE_NODE', clipId, () async {
        final clip = await getShot(clipId);
        if (clip == null) {
          throw const StoryboardException('source_missing');
        }
        final canvas = await ensureCanvas(clip.episodeId);
        final existing =
            await (database.select(database.canvasNodes)..where(
                  (t) =>
                      t.refType.equals(canvasNodeRefTypeProductionClip) &
                      t.refId.equals(clipId) &
                      t.deletedAt.equals(notDeletedSentinel),
                ))
                .getSingleOrNull();
        if (existing != null) {
          if (existing.canvasId != canvas.id) {
            throw const StoryboardException('source_missing');
          }
          return existing;
        }
        final scenes = clip.episodeId.isEmpty
            ? <ScreenplaySceneRecord>[]
            : await database.screenplayDao.getSceneRows(clip.episodeId);
        final sceneIndex = scenes.indexWhere((s) => s.id == clip.sceneId);
        var x = 360.0 + (clip.sortOrder ?? 0) * 360;
        var y = 80.0 + (sceneIndex < 0 ? scenes.length : sceneIndex) * 280;
        final nodes = await database.canvasDao.getNodesByCanvas(canvas.id);
        final anchor = nodes
            .where((n) => n.sceneId != null && n.sceneId == clip.sceneId)
            .firstOrNull;
        if (clip.sceneId != null) {
          // 每场占一列，场内片段向下排列。
          x = 360.0 + (sceneIndex < 0 ? scenes.length : sceneIndex) * 360;
          y = 80.0 + (clip.sortOrder ?? 0) * 280;
          final siblingIds = (await sceneShots(
            clip.sceneId!,
          )).map((sibling) => sibling.id).toSet();
          final siblings = nodes.where(
            (node) => siblingIds.contains(node.clipId),
          );
          if (siblings.isNotEmpty) {
            // 新段跟随已移动的场次，避免旧的默认坐标改变整场的布局原点。
            x = siblings.map((node) => node.x).reduce((a, b) => a < b ? a : b);
            y =
                siblings.map((node) => node.y).reduce((a, b) => a > b ? a : b) +
                280;
          } else if (anchor != null) {
            // 空场次的第一段落在场次框原位。
            x = anchor.x;
            y = anchor.y;
          }
        }
        // 画布卡片按画面比例渲染，长边最大 260，上方还有一行标题；占位按最大卡片加间距算。
        // 场内片段由场次节点排位，不另找空位。
        const slot = 300.0;
        while (anchor == null &&
            nodes.any(
              (n) =>
                  x < n.x + slot &&
                  x + slot > n.x &&
                  y < n.y + slot &&
                  y + slot > n.y,
            )) {
          y += slot;
        }
        final id = await insertWithShortEntityId(
          type: ShortEntityIdType.canvasNode,
          tableName: 'canvas_nodes',
          idExists: database.canvasDao.nodeIdExists,
          insert: (id) => database
              .into(database.canvasNodes)
              .insert(
                CanvasNodesCompanion.insert(
                  id: id,
                  canvasId: canvas.id,
                  type: Value(clip.kind),
                  refType: const Value(canvasNodeRefTypeProductionClip),
                  refId: Value(clipId),
                  title: Value(clip.title),
                  x: Value(x),
                  y: Value(y),
                  width: const Value(300),
                  height: const Value(220),
                ),
              ),
        );
        return (await database.canvasDao.getNodeById(id))!;
      });

  /// 给本集每个还没有场次节点的场次补一个。已有片段节点的场次取这些节点最左、最上的坐标，
  /// 与原先由片段推出的场次位置一致；空场次排在已有场次右侧，与它们顶边对齐，被占用时往下让。
  Future<void> _ensureSceneNodes(String canvasId, String episodeId) async {
    if (episodeId.isEmpty) {
      return;
    }
    final scenes = await database.screenplayDao.getSceneRows(episodeId);
    final nodes = await database.canvasDao.getNodesByCanvas(canvasId);
    final anchored = {for (final n in nodes) ?n.sceneId};
    final missing = scenes.where((s) => !anchored.contains(s.id)).toList();
    if (missing.isEmpty) {
      return;
    }
    final clips = await (_shots()..where((t) => t.episodeId.equals(episodeId)))
        .get();
    final sceneOfClip = {for (final c in clips) c.id: c.sceneId};
    for (final scene in missing) {
      final members = nodes.where((n) => sceneOfClip[n.clipId] == scene.id);
      double x;
      double y;
      if (members.isNotEmpty) {
        x = members.map((n) => n.x).reduce(math.min);
        y = members.map((n) => n.y).reduce(math.min);
      } else {
        final others = nodes.where((n) => n.sceneId != null);
        x = others.isEmpty
            ? 360.0 + scenes.indexOf(scene) * 360
            : others.map((n) => n.x).reduce(math.max) + 360;
        y = others.isEmpty ? 80.0 : others.map((n) => n.y).reduce(math.min);
        // 空场次只有标题和添加入口，按一张卡片的占位找空位。
        const slot = 300.0;
        while (nodes.any(
          (n) =>
              x < n.x + slot &&
              x + slot > n.x &&
              y < n.y + slot &&
              y + slot > n.y,
        )) {
          y += slot;
        }
      }
      final id = await insertWithShortEntityId(
        type: ShortEntityIdType.canvasNode,
        tableName: 'canvas_nodes',
        idExists: database.canvasDao.nodeIdExists,
        insert: (id) => database
            .into(database.canvasNodes)
            .insert(
              CanvasNodesCompanion.insert(
                id: id,
                canvasId: canvasId,
                type: const Value(canvasNodeTypeScene),
                refType: const Value(canvasNodeRefTypeScreenplayScene),
                refId: Value(scene.id),
                x: Value(x),
                y: Value(y),
              ),
            ),
      );
      nodes.add((await database.canvasDao.getNodeById(id))!);
    }
  }

  Future<void> apply(
    String id,
    Map<String, dynamic> values, {
    bool creating = false,
    bool restoring = false,
  }) => write(creating ? 'INSERT' : 'UPDATE', id, () async {
    final previous = await getShot(id);
    if (!creating && previous == null) {
      throw const StoryboardException('source_missing');
    }
    final sceneId = values['scene_id'] as String?;
    final kind = values['kind'] as String;
    final episodeId = values['episode_id'] as String;
    final order = values['sort_order'] as int?;
    if (!{'video', 'image', 'audio'}.contains(kind) ||
        (kind == 'audio' && sceneId != null) ||
        (previous != null && previous.kind != kind) ||
        (sceneId != null && order == null) ||
        (sceneId == null && order != null)) {
      throw const StoryboardException('invalid_config');
    }
    if (!restoring) {
      await requireEpisode(episodeId);
      if (previous != null && previous.episodeId != episodeId) {
        throw const StoryboardException('cross_episode_move');
      }
      if (sceneId != null && (creating || previous?.sceneId != sceneId)) {
        final scene = await requireScene(sceneId);
        if (scene.episodeId != episodeId) {
          throw const StoryboardException('cross_episode_move');
        }
      }
    }
    final characterId = values['character_id'] as String?;
    final locationId = values['location_id'] as String?;
    final itemId = values['item_id'] as String?;
    final subjectCount = [characterId, locationId, itemId].nonNulls.length;
    if (episodeId.isEmpty &&
        (sceneId != null || order != null || subjectCount != 0)) {
      throw const StoryboardException('invalid_config');
    }
    if (episodeId.isEmpty && restoring) {
      await requireEpisode(episodeId);
    }
    if ((previous != null &&
            (previous.characterId != characterId ||
                previous.locationId != locationId ||
                previous.itemId != itemId)) ||
        subjectCount > 1 ||
        (kind != 'image' && subjectCount != 0)) {
      throw const StoryboardException('invalid_config');
    }
    if (characterId != null &&
            await database.characterProfileDao.getById(characterId) == null ||
        locationId != null &&
            await database.locationDao.getById(locationId) == null) {
      throw const StoryboardException('source_missing');
    }
    if (itemId != null) {
      final item = await database.itemDao.getById(itemId);
      if (item == null) {
        throw const StoryboardException('source_missing');
      }
      if (!compendiumEntityTypes.contains(item.type)) {
        throw const StoryboardException('invalid_config');
      }
    }
    final prompt = values['prompt'] as String;
    StoryboardPrompt.parse(prompt);
    final mode = values['reference_mode'] as String;
    final duration = values['duration_ms'] as int?;
    final provider = values['provider_id'] as String?;
    final model = values['model_id'] as String?;
    // 用户只选全参考 / 首尾帧；文生视频、首帧由提交时按输入换算。
    if (!{
          VideoMode.reference.name,
          VideoMode.first_last_frame.name,
        }.contains(mode) ||
        (duration != null && duration <= 0) ||
        (provider == null) != (model == null) ||
        (provider != null &&
            (provider.trim().isEmpty || model!.trim().isEmpty)) ||
        (order != null && order < 0) ||
        (values['resolution'] as String).trim().isEmpty) {
      throw const StoryboardException('invalid_config');
    }
    final ratio = values['ratio'] as String;
    if (!RegExp(r'^\d+:\d+$').hasMatch(ratio) &&
        ratio != 'adaptive' &&
        !(kind == 'image' && ratio == 'auto')) {
      throw const StoryboardException('invalid_config');
    }
    final companion = ProductionClipsCompanion.insert(
      id: id,
      episodeId: episodeId,
      kind: kind,
      sceneId: Value(sceneId),
      characterId: Value(characterId),
      locationId: Value(locationId),
      itemId: Value(itemId),
      sortOrder: Value(order),
      title: Value(values['title'] as String),
      prompt: Value(prompt),
      styleSelection: Value(
        values.containsKey('style_selection')
            ? values['style_selection'] as String?
            : previous?.styleSelection,
      ),
      providerId: Value(provider),
      modelId: Value(model),
      referenceMode: Value(mode),
      durationMs: Value(duration),
      generateAudio: Value(
        values.containsKey('generate_audio')
            ? values['generate_audio'] as bool?
            : previous?.generateAudio,
      ),
      ratio: Value(values['ratio'] as String),
      resolution: Value(values['resolution'] as String),
      updatedAt: Value(DateTime.now()),
    );
    if (creating) {
      await database.into(database.productionClips).insert(companion);
      await ensureClipNode(id);
    } else {
      await (database.update(
        database.productionClips,
      )..where((t) => t.id.equals(id))).write(companion);
    }
  });

  Future<List<Map<String, dynamic>>> inputSnapshot(String clipId) async {
    final clip = await getShot(clipId);
    if (clip == null) {
      throw const StoryboardException('source_missing');
    }
    return clip.inputs.map((input) => input.toJson()).toList();
  }

  Future<void> restoreInputs(
    String clipId,
    List<Map<String, dynamic>> inputs,
  ) => write('RESTORE_INPUTS', clipId, () async {
    final values = inputs.map(ProductionInput.fromJson).toList();
    ProductionInput.validateList(values);
    if (await getShot(clipId) == null) {
      throw const StoryboardException('source_missing');
    }
    final references = values
        .where((input) => input.sourceNodeId != null)
        .toList();
    if (references.isNotEmpty) {
      final target = await ensureClipNode(clipId);
      final nodes = await database.canvasDao.getNodesByCanvas(target.canvasId);
      final clips = await (database.select(
        database.productionClips,
      )..where((t) => t.id.isIn(nodes.map((n) => n.clipId).nonNulls))).get();
      final byId = {for (final clip in clips) clip.id: clip};
      final graph = <String, List<String>>{};
      for (final node in nodes) {
        if (node.id == target.id) {
          continue;
        }
        for (final input in byId[node.clipId]?.inputs ?? <ProductionInput>[]) {
          if (input.sourceNodeId != null) {
            graph.putIfAbsent(input.sourceNodeId!, () => []).add(node.id);
          }
        }
      }
      bool reaches(String at, String destination, Set<String> seen) =>
          at == destination ||
          (seen.add(at) &&
              (graph[at] ?? []).any(
                (next) => reaches(next, destination, seen),
              ));
      for (final input in references) {
        final source = await database.canvasDao.getNodeById(input.refId);
        if (input.isPrompt && source?.type != canvasNodeTypeText ||
            !input.isPrompt && source?.type == canvasNodeTypeText) {
          throw const StoryboardException('invalid_reference');
        }
        // 删除的媒体来源保持为失效参考，让用户在卡片中修复。
        if (source != null && source.canvasId != target.canvasId ||
            reaches(target.id, input.refId, {})) {
          throw const StoryboardException('invalid_reference');
        }
      }
    }
    await (database.update(
      database.productionClips,
    )..where((t) => t.id.equals(clipId))).write(
      ProductionClipsCompanion(
        inputs: Value(values),
        updatedAt: Value(DateTime.now()),
      ),
    );
  });

  Future<void> setErrorDismissed(String clipId, bool dismissed) =>
      write('SET_ERROR_DISMISSED', clipId, () async {
        if (await getShot(clipId) == null) {
          throw const StoryboardException('source_missing');
        }
        await (database.update(database.productionClips)
              ..where((t) => t.id.equals(clipId)))
            .write(ProductionClipsCompanion(errorDismissed: Value(dismissed)));
      });

  Future<void> softDelete(String id) => write('SOFT_DELETE', id, () async {
    final row = await getShot(id);
    if (row == null) {
      throw const StoryboardException('source_missing');
    }
    final nodes =
        await (database.select(database.canvasNodes)..where(
              (t) =>
                  t.refType.equals(canvasNodeRefTypeProductionClip) &
                  t.refId.equals(id) &
                  t.deletedAt.equals(notDeletedSentinel),
            ))
            .get();
    for (final node in nodes) {
      await database.canvasDao.softDeleteNode(node.id);
    }
    await (database.update(
      database.productionClips,
    )..where((t) => t.id.equals(id))).write(
      ProductionClipsCompanion(
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
  });
}

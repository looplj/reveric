// 职责: 维护每集唯一制作画布、片段/素材/导演台节点、导演台导出结果、视频处理产物和有序生成输入。
// 关联文件:
//   lib/shared/database/novel_content_database.dart
//   lib/shared/services/storyboard/edit_orchestrator.dart
//   lib/shared/services/production/library_service.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/error-handling.md
import 'dart:io';
import 'package:uuid/uuid.dart';
import '../../models/editing/document.dart';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:ui' show Offset;
import 'package:drift/drift.dart';
import '../../database/app_database.dart'
    show AssetRow, GenerationTask, GenerationTaskRequest;
import '../../models/generation/task.dart';
import '../../database/novel_content_database.dart';
import '../../models/video/request.dart';
import '../../models/director/document.dart';
import '../../models/production/settings.dart';
import '../../models/production/panorama.dart';
import '../../models/production/group_layout.dart';
export '../../models/production/group_layout.dart';
import '../../models/production/view_presets.dart';
import '../../models/production/input.dart';
export '../../models/production/input.dart';
import '../../models/production/subject.dart';
export '../../models/production/subject.dart';
export '../../models/subject.dart';
import '../../models/production/style.dart';
import '../../models/production/image_request.dart';
import '../../models/audio/request.dart';
import '../../models/storyboard/prompt.dart';
import '../../utils/random_id.dart';
import '../../utils/short_entity_id.dart';
import '../../utils/short_entity_id_allocator.dart';
import '../storyboard/service.dart';
import 'canvas_history.dart';
import '../storyboard/edit_orchestrator.dart';
import '../working_overlay.dart';
import '../novel_content.dart';
import '../maps_service.dart';
import 'library_service.dart';
import 'group_service.dart';
export 'group_service.dart';
import 'ffmpeg_runner.dart';
import 'media_file.dart';
import 'voices.dart';
export 'media_file.dart';

bool canAdoptProductionTask(GenerationTask task) =>
    task.status == GenerationTaskStatus.completed && task.resultAssetId != null;

/// 新节点的确切落点，以及为它让位而移动的其他节点（画布坐标）。
typedef ProductionNodePlacement = ({
  ({double x, double y}) at,
  Map<String, ({double x, double y})> moves,
});

/// 制作输入边是 inputs 的投影；导演台输出边仍来自 canvas_edges。
class ProductionConnection {
  const ProductionConnection({
    required this.id,
    required this.sourceNodeId,
    required this.targetNodeId,
    required this.type,
    this.role,
    this.inputId,
    this.middleFrameIndex,
  });
  final String id, sourceNodeId, targetNodeId, type;
  final String? role;

  /// 由片段输入派生的连线才有；输入 id 只在所属片段内唯一。
  final String? inputId;
  final int? middleFrameIndex;
  factory ProductionConnection.stored(CanvasEdge edge) => ProductionConnection(
    id: edge.id,
    sourceNodeId: edge.sourceNodeId,
    targetNodeId: edge.targetNodeId,
    type: edge.type,
  );
}

class ProductionCanvasService {
  ProductionCanvasService(this.shots, this.library, this.novelId);
  final StoryboardService shots;
  final MediaLibraryService library;
  final String novelId;
  NovelContentDatabase get db => shots.database;
  late final groups = ProductionGroupService(shots);

  /// [id] 是风格引用：`preset:<slug>` 解析内置预设，其他值按自定义风格 ID 查询。
  Future<ProductionStylePrompt> requireStyle(String id) async {
    if (isProductionStylePresetRef(id)) {
      final preset = productionStylePreset(
        id.substring(productionStylePresetPrefix.length),
      );
      if (preset == null) {
        throw const StoryboardException('style_missing');
      }
      return preset.prompt;
    }
    final style = await library.database.productionStyleDao.getStyle(id);
    if (style == null) {
      throw const StoryboardException('style_missing');
    }
    return ProductionStylePrompt(before: style.before, after: style.after);
  }

  Future<ProductionStylePrompt?> effectiveStyle(ProductionClipRow clip) async {
    final selection = ProductionStyleChoice.fromStored(clip.styleSelection);
    final String? id;
    switch (selection) {
      case InheritedProductionStyle():
        await shots.requireEpisode(clip.episodeId);
        id = (await db.screenplayDao.getRoot())!.styleId;
      case NoProductionStyle():
        id = null;
      case PresetProductionStyle() || CustomProductionStyle():
        id = selection.stored;
    }
    return id == null ? null : requireStyle(id);
  }

  /// [styleId] 为 null 表示无风格，否则是 [requireStyle] 能解析的风格引用。
  Future<void> setScreenplayStyle(String? styleId) =>
      shots.write('UPDATE screenplays', novelId, () async {
        final screenplay = await db.screenplayDao.getRoot();
        if (screenplay == null) {
          throw const StoryboardException('source_missing');
        }
        if (styleId != null) {
          await requireStyle(styleId);
        }
        await (db.update(
          db.screenplays,
        )..where((t) => t.id.equals(screenplay.id))).write(
          ScreenplaysCompanion(
            styleId: Value(styleId),
            updatedAt: Value(DateTime.now()),
          ),
        );
      });

  Future<void> setClipStyle(String clipId, ProductionStyleChoice choice) =>
      shots.write('UPDATE production_clips', clipId, () async {
        final clip = await shots.getShot(clipId);
        if (clip == null) {
          throw const StoryboardException('source_missing');
        }
        await shots.requireEpisode(clip.episodeId);
        if (choice case PresetProductionStyle() || CustomProductionStyle()) {
          await requireStyle(choice.stored!);
        }
        await (db.update(
          db.productionClips,
        )..where((t) => t.id.equals(clipId))).write(
          ProductionClipsCompanion(
            styleSelection: Value(choice.stored),
            updatedAt: Value(DateTime.now()),
          ),
        );
      });

  Future<T> write<T>(String id, Future<T> Function() action) => shots.write(
    'UPDATE canvas_nodes,canvas_edges,canvases,production_clips,character_profiles,locations,items',
    id,
    action,
  );

  /// 打开制作画布时补齐本集场景的主体与空节点的首图；保留已有选图和手动删除。
  Future<CanvasEntry> ensureCanvas(String episodeId) => shots.write(
    'ENSURE canvases,canvas_nodes,production_clips',
    episodeId,
    () async {
      final canvas = await shots.ensureCanvas(episodeId);
      if (episodeId.isEmpty) {
        return canvas;
      }
      final scenes = await db.screenplayDao.getSceneRows(episodeId);
      if (scenes.isEmpty) {
        return canvas;
      }
      final clips = db.productionClips;
      final existing =
          await (db.selectOnly(clips)
                ..addColumns([clips.characterId, clips.locationId])
                ..where(
                  clips.episodeId.equals(episodeId) &
                      clips.kind.equals('image'),
                ))
              .get();
      final characters = existing
          .map((row) => row.read(clips.characterId))
          .whereType<String>()
          .toSet();
      final locations = existing
          .map((row) => row.read(clips.locationId))
          .whereType<String>()
          .toSet();
      final cast = db.screenplaySceneCharacters;
      final castRows =
          await (db.selectOnly(cast)
                ..addColumns([cast.characterId])
                ..where(
                  cast.sceneId.isIn(scenes.map((scene) => scene.id)) &
                      cast.deletedAt.equals(notDeletedSentinel),
                )
                ..orderBy([
                  OrderingTerm.asc(cast.sortOrder),
                  OrderingTerm.asc(cast.id),
                ]))
              .get();
      for (final row in castRows) {
        final id = row.read(cast.characterId)!;
        if (characters.add(id)) {
          await addSubject(canvas.id, characterId: id);
        }
      }
      for (final scene in scenes) {
        final id = scene.locationId;
        if (id != null && locations.add(id)) {
          await addSubject(canvas.id, locationId: id);
        }
      }
      // 主体可能在节点创建后才添加图片；只为本集场景中仍未选图的节点补选。
      final emptySubjects =
          await (db.select(clips)..where(
                (t) =>
                    t.episodeId.equals(episodeId) &
                    t.kind.equals('image') &
                    t.deletedAt.equals(notDeletedSentinel) &
                    t.adoptedAssetId.isNull() &
                    (t.characterId.isIn(
                          castRows.map((row) => row.read(cast.characterId)!),
                        ) |
                        t.locationId.isIn(
                          scenes.map((scene) => scene.locationId).nonNulls,
                        )),
              ))
              .get();
      for (final clip in emptySubjects) {
        final first = (await subjectPhotos(clip)).firstOrNull;
        if (first != null) {
          await (db.update(clips)..where((t) => t.id.equals(clip.id))).write(
            ProductionClipsCompanion(adoptedAssetId: Value(first.assetId)),
          );
        }
      }
      return canvas;
    },
  );

  Future<void> removeCanvas(String canvasId) => write(canvasId, () async {
    await requireCanvas(canvasId);
    await (db.update(db.screenplayEpisodes)..where(
          (t) =>
              t.canvasId.equals(canvasId) &
              t.deletedAt.equals(notDeletedSentinel),
        ))
        .write(
          ScreenplayEpisodesCompanion(
            canvasId: const Value(null),
            updatedAt: Value(DateTime.now()),
          ),
        );
    for (final node in await db.canvasDao.getNodesByCanvas(canvasId)) {
      if (node.type == canvasNodeTypeText) {
        await groups.remove(node);
      }
      if (node.type == canvasNodeTypeEditing && node.editingId != null) {
        await db.editingDao.softDelete(node.editingId!);
      }
    }
    await db.canvasDao.softDeleteCanvas(canvasId);
  });

  Future<CanvasEntry> requireCanvas(String id) async {
    final canvas = await db.canvasDao.getCanvasById(id);
    final settings =
        await (db.select(db.screenplayEpisodes)..where(
              (t) =>
                  t.canvasId.equals(id) &
                  t.deletedAt.equals(notDeletedSentinel),
            ))
            .getSingleOrNull();
    if (canvas == null || canvas.kind != canvasKindProduction) {
      throw const StoryboardException('source_missing');
    }
    await shots.requireEpisode(settings?.id ?? '');
    return canvas;
  }

  /// 已校验画布的制作归属；独立画布返回空集，剧本仍返回真实集 ID。
  Future<String> episodeForCanvas(String canvasId) async {
    await requireCanvas(canvasId);
    final episode =
        await (db.select(db.screenplayEpisodes)..where(
              (t) =>
                  t.canvasId.equals(canvasId) &
                  t.deletedAt.equals(notDeletedSentinel),
            ))
            .getSingleOrNull();
    return episode?.id ?? '';
  }

  Future<CanvasNode> requireNode(String id) async {
    final node = await db.canvasDao.getNodeById(id);
    if (node == null) {
      throw const StoryboardException('source_missing');
    }
    await requireCanvas(node.canvasId);
    if ((node.isGenerationNode && node.clipId == null) ||
        (node.type == canvasNodeTypeMedia && (node.mediaAssetId == null)) ||
        (node.type == canvasNodeTypeStaging &&
            (node.stagingId == null ||
                await db.screenplayDao.getStaging(node.stagingId!) == null))) {
      throw const StoryboardException('source_missing');
    }
    if (node.clipId != null) {
      final shot = await shots.getShot(node.clipId!);
      if (shot == null) {
        throw const StoryboardException('source_missing');
      }
      await shots.requireEpisode(shot.episodeId);
      if (shot.episodeId.isNotEmpty &&
          (await db.screenplayDao.getEpisode(shot.episodeId))?.canvasId !=
              node.canvasId) {
        throw const StoryboardException('source_missing');
      }
    }
    return node;
  }

  Future<CanvasNode> ensureShotNode(String shotId) =>
      shots.ensureClipNode(shotId);

  /// 画布打开期间新加的场次补上场次节点；打开画布时 [ensureCanvas] 已补过一次。
  Future<void> ensureSceneNodes(String canvasId) => write(canvasId, () async {
    final episodeId = await episodeForCanvas(canvasId);
    if (episodeId.isNotEmpty) {
      await shots.ensureCanvas(episodeId);
    }
  });

  /// 画布上「＋」新建的片段 / 视频节点默认时长。
  static const defaultDurationMs = 6000;

  Future<CanvasNode> addFree(
    String canvasId, {
    required WorkingOverlayService overlay,
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'addFree',
    const [],
    () => write(canvasId, () async {
      await requireCanvas(canvasId);
      final episodeId = await episodeForCanvas(canvasId);
      final clip = await StoryboardEditOrchestrator().create(
        service: shots,
        overlay: overlay,
        episodeId: episodeId,
        values: const {'duration_ms': defaultDurationMs},
      );
      return shots.ensureClipNode(clip.id);
    }),
  );

  Future<CanvasNode> addEditing(
    String canvasId, {
    required String title,
    String? ratio,
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'addEditing',
    const [],
    () => write(canvasId, () async {
      await requireCanvas(canvasId);
      if (!await shots.isCanvasWork) {
        throw const StoryboardException('invalid_config');
      }
      final editingId = const Uuid().v4();
      final settings = await shots.requireSettings();
      await db.editingDao.create(
        editingId,
        title,
        EditingDocument.empty(ratio ?? settings.ratio),
      );
      return _insertNode(
        canvasId,
        canvasNodeTypeEditing,
        title: title,
        refType: canvasNodeRefTypeEditing,
        refId: editingId,
      );
    }),
  );

  /// 打开剪辑必须从当前作品的有效节点进入；失效记录仍可通过普通 removeNode 删除。
  Future<VideoEditingRow> requireEditingNode(String nodeId) async {
    final node = await requireNode(nodeId);
    if (!await shots.isCanvasWork ||
        node.type != canvasNodeTypeEditing ||
        node.editingId == null) {
      throw const StoryboardException('invalid_reference');
    }
    return await db.editingDao.get(node.editingId!) ??
        (throw const StoryboardException('source_missing'));
  }

  Future<CanvasNode> addText(
    String canvasId, {
    String title = '',
    String content = '',
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'addText',
    const [],
    () => write(canvasId, () async {
      await requireCanvas(canvasId);
      return _insertNode(
        canvasId,
        canvasNodeTypeText,
        title: title,
        content: content,
        refType: null,
        refId: null,
      );
    }),
  );

  Future<void> updateText(
    String nodeId, {
    required String title,
    required String content,
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'updateText',
    [nodeId],
    () => write(nodeId, () async {
      final node = await requireNode(nodeId);
      if (node.type != canvasNodeTypeText) {
        throw const StoryboardException('invalid_config');
      }
      await db.canvasDao.updateActiveNodeFields(
        nodeId,
        CanvasNodesCompanion(title: Value(title), content: Value(content)),
      );
    }),
  );

  /// 卡片外显示的标题；主体图片节点显示的是角色、场景或道具的名称，不可在画布上改，返回 null。
  Future<String?> nodeTitle(String nodeId) async {
    final node = await requireNode(nodeId);
    if (node.clipId case final clipId?) {
      final clip = await shots.getShot(clipId);
      return clip == null || clip.hasSubject ? null : clip.title;
    }
    if (node.stagingId case final id?) {
      return (await db.screenplayDao.getStaging(id))?.title ?? node.title;
    }
    if (node.editingId case final id?) {
      return (await db.editingDao.get(id))?.title ?? node.title;
    }
    return node.title;
  }

  /// 改卡片外显示的标题，写到它的来源：片段、导演文档、剪辑工程或节点自身。
  /// 画布撤销只还原节点自身的标题；片段、导演文档和剪辑工程的标题不在撤销快照内，
  /// 这几类改名不记撤销步，免得撤销后节点与来源各显示一个名字。
  Future<void> renameNode(
    String nodeId,
    String title, {
    CanvasHistory? history,
  }) async {
    final target = await requireNode(nodeId);
    final own =
        target.clipId == null &&
        target.stagingId == null &&
        target.editingId == null;
    return withCanvasHistory(own ? history : null, shots, 'renameNode', [
      nodeId,
    ], () => _renameNode(nodeId, title));
  }

  Future<void> _renameNode(
    String nodeId,
    String title,
  ) => write(nodeId, () async {
    final node = await requireNode(nodeId);
    final now = DateTime.now();
    if (node.clipId case final clipId?) {
      final clip = await shots.getShot(clipId);
      if (clip == null) {
        throw const StoryboardException('source_missing');
      }
      if (clip.hasSubject) {
        throw const StoryboardException('invalid_config');
      }
      await (db.update(
        db.productionClips,
      )..where((t) => t.id.equals(clipId))).write(
        ProductionClipsCompanion(title: Value(title), updatedAt: Value(now)),
      );
      return;
    }
    if (node.stagingId case final id?) {
      await db.screenplayDao.serializeStaging(id, () async {
        final row = await db.screenplayDao.getStaging(id);
        if (row == null) {
          throw const StoryboardException('source_missing');
        }
        if (row.document == null) {
          await (db.update(
            db.videoStagings,
          )..where((t) => t.id.equals(id))).write(
            VideoStagingsCompanion(title: Value(title), updatedAt: Value(now)),
          );
          return;
        }
        final current = DirectorDocument.fromJson(row.document!);
        final next = DirectorDocument.fromJson(
          current.toJson()
            ..['title'] = title
            ..['revision'] = current.revision + 1,
        );
        await db.screenplayDao.saveStaging(
          id,
          next.toJson(),
          title: title,
          savedAt: now,
        );
      });
    }
    if (node.editingId case final id?) {
      final project = await db.editingDao.get(id);
      if (project == null) {
        throw const StoryboardException('source_missing');
      }
      await db.editingDao.save(
        id,
        expectedRevision: project.revision,
        title: title,
      );
    }
    await db.canvasDao.updateActiveNodeFields(
      nodeId,
      CanvasNodesCompanion(title: Value(title)),
    );
  });

  Future<Map<String, String>> promptTexts(List<ProductionInput> inputs) async {
    final text = <String, String>{};
    for (final input in inputs.where((input) => input.isPrompt)) {
      final node = await requireNode(input.refId);
      if (node.type != canvasNodeTypeText) {
        throw const StoryboardException('invalid_reference');
      }
      text[input.id] = node.content;
    }
    return text;
  }

  Future<CanvasNode> addImage(String canvasId, {CanvasHistory? history}) =>
      withCanvasHistory(
        history,
        shots,
        'addImage',
        const [],
        () => write(canvasId, () async {
          await requireCanvas(canvasId);
          final episodeId = await episodeForCanvas(canvasId);
          final clip = await shots.createImage(episodeId);
          return shots.ensureClipNode(clip.id);
        }),
      );

  /// 组级引用按当前格位展开为成员引用；保留已有引用 ID，让提示词引用仍然有效。
  Future<void> attachStoryboardGroup(
    String groupId,
    String targetId, {
    required WorkingOverlayService overlay,
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'attachStoryboardGroup',
    [targetId],
    () => write(groupId, () async {
      final group = await groups.requireGroup(groupId);
      final target = await requireNode(targetId);
      final members = await groups.members(groupId);
      if (ProductionGroupLayout.fromStyle(group.style)
              is! StoryboardGroupLayout ||
          members.isEmpty ||
          target.canvasId != group.canvasId ||
          (target.type != canvasNodeTypeImage &&
              target.type != canvasNodeTypeVideo)) {
        throw const StoryboardException('invalid_reference');
      }
      final clip = (await shots.getShot(target.clipId!))!;
      if (target.type == canvasNodeTypeVideo &&
          clip.referenceMode != 'reference') {
        throw const StoryboardException('invalid_reference');
      }
      final ids = members.map((n) => n.id).toSet();
      final existing = clip.inputs;
      await saveDraft(
        nodeId: targetId,
        values: {'prompt': clip.prompt},
        inputs: [
          ...existing.where(
            (i) =>
                i.refType != ProductionInputType.node || !ids.contains(i.refId),
          ),
          for (final member in members)
            existing
                    .where(
                      (i) =>
                          i.refType == ProductionInputType.node &&
                          i.refId == member.id &&
                          !i.isPrompt &&
                          i.role == VideoInputRole.reference_image,
                    )
                    .firstOrNull ??
                ProductionInput.node(member.id, VideoInputRole.reference_image),
        ],
        overlay: overlay,
      );
    }),
  );

  /// 从组的共同出口新建一个多图参考草稿，不自动提交生成任务。
  Future<CanvasNode> addStoryboardReference(
    String groupId, {
    required bool video,
    required WorkingOverlayService overlay,
    required ProductionNodePlacement placement,
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'addStoryboardReference',
    placement.moves.keys,
    () => write(groupId, () async {
      final group = await groups.requireGroup(groupId);
      final target = video
          ? await addFree(group.canvasId, overlay: overlay)
          : await addImage(group.canvasId);
      if (video) {
        await saveDraft(
          nodeId: target.id,
          values: const {'prompt': '', 'reference_mode': 'reference'},
          inputs: const [],
          overlay: overlay,
        );
      }
      await attachStoryboardGroup(groupId, target.id, overlay: overlay);
      await moveNodes(group.canvasId, {
        ...placement.moves,
        target.id: placement.at,
      });
      return requireNode(target.id);
    }),
  );

  /// 视角不进入撤销历史，只合并节点自身的预览键。
  Future<void> setPanoramaView(
    String nodeId,
    PanoramaView? view, {
    bool onlyIfActive = false,
  }) => write(nodeId, () async {
    final node = await requireNode(nodeId);
    if (node.type == canvasNodeTypeMedia) {
      await requireAsset(node.mediaAssetId!, type: 'image');
    } else if (node.type != canvasNodeTypeImage) {
      throw const StoryboardException('invalid_config');
    }
    final style = <String, dynamic>{...?node.style};
    // 卸载前排队的视角保存不能重新开启已退出的预览。
    if (onlyIfActive && !style.containsKey('panorama')) {
      return;
    }
    if (view == null) {
      style.remove('panorama');
    } else {
      style['panorama'] = view.toJson();
    }
    await db.canvasDao.updateActiveNodeFields(
      nodeId,
      CanvasNodesCompanion(style: Value(style)),
    );
  });

  Future<CanvasNode> addAudio(String canvasId, {CanvasHistory? history}) =>
      withCanvasHistory(
        history,
        shots,
        'addAudio',
        const [],
        () => write(canvasId, () async {
          await requireCanvas(canvasId);
          final episodeId = await episodeForCanvas(canvasId);
          final clip = await shots.createAudio(episodeId);
          return shots.ensureClipNode(clip.id);
        }),
      );

  /// 派生草稿、输入与节点一次写入；后续任务提交失败仍保留可编辑草稿。
  Future<CanvasNode> addDerivedImage({
    required String sourceNodeId,
    required ProductionImageDraft draft,
    required ProductionInput input,
    bool panorama = false,
  }) => write(sourceNodeId, () async {
    final source = await requireNode(sourceNodeId);
    if (input.sourceNodeId != source.id ||
        input.isPrompt ||
        input.role != VideoInputRole.reference_image ||
        !{canvasNodeTypeImage, canvasNodeTypeMedia}.contains(source.type)) {
      throw const StoryboardException('invalid_reference');
    }
    await inputAsset(input);
    final episodeId = await episodeForCanvas(source.canvasId);
    final clip = await shots.createImage(
      episodeId,
      values: {
        'title': draft.title ?? '',
        'prompt': draft.prompt,
        'provider_id': draft.providerId,
        'model_id': draft.providerId == null ? null : draft.modelId,
        'ratio': draft.ratio,
        'resolution': draft.resolution,
      },
    );
    final node = await shots.ensureClipNode(clip.id);
    final nodes = await db.canvasDao.getNodesByCanvas(source.canvasId);
    final x = source.x + (source.width ?? 300) + 120;
    var y = source.y;
    while (nodes.any(
      (n) =>
          n.id != node.id &&
          x < n.x + (n.width ?? 300) + 24 &&
          x + 324 > n.x &&
          y < n.y + (n.height ?? 220) + 24 &&
          y + 244 > n.y,
    )) {
      y += 260;
    }
    await db.canvasDao.updateActiveNodeFields(
      node.id,
      CanvasNodesCompanion(
        x: Value(x),
        y: Value(y),
        style: panorama || draft.preset != null
            ? Value({
                if (draft.preset != null)
                  'imageGeneration': draft.preset!.toJson(),
                if (panorama ||
                    draft.preset?.method == ImageGenerationMethod.panorama)
                  'panorama': const PanoramaView().toJson(),
              })
            : const Value.absent(),
      ),
    );
    await shots.restoreInputs(clip.id, [input.toJson()]);
    return (await db.canvasDao.getNodeById(node.id))!;
  });

  Future<CanvasNode> addSubject(
    String canvasId, {
    String? characterId,
    String? locationId,
    String? itemId,
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'addSubject',
    const <String>[],
    () => write(canvasId, () async {
      if ([characterId, locationId, itemId].nonNulls.length != 1) {
        throw const StoryboardException('invalid_config');
      }
      await requireCanvas(canvasId);
      final character = characterId == null
          ? null
          : await db.characterProfileDao.getById(characterId);
      final location = locationId == null
          ? null
          : await db.locationDao.getById(locationId);
      final item = itemId == null ? null : await db.itemDao.getById(itemId);
      if (character == null && location == null && item == null) {
        throw const StoryboardException('source_missing');
      }
      final episodeId = await episodeForCanvas(canvasId);
      final clip = await shots.createImage(
        episodeId,
        values: {
          'title': character?.name ?? location?.name ?? item!.title,
          'character_id': characterId,
          'location_id': locationId,
          'item_id': itemId,
        },
      );
      final first =
          (character?.photos ?? location?.photos ?? item?.photos)?.firstOrNull;
      if (first != null) {
        await (db.update(
          db.productionClips,
        )..where((t) => t.id.equals(clip.id))).write(
          ProductionClipsCompanion(adoptedAssetId: Value(first.assetId)),
        );
      }
      return shots.ensureClipNode(clip.id);
    }),
  );

  Future<List<SubjectPhoto>> subjectPhotos(ProductionClipRow clip) async {
    if (clip.characterId != null) {
      final character = await db.characterProfileDao.getById(clip.characterId!);
      if (character == null) {
        throw const StoryboardException('source_missing');
      }
      return character.photos ?? const [];
    }
    if (clip.locationId != null) {
      final location = await db.locationDao.getById(clip.locationId!);
      if (location == null) {
        throw const StoryboardException('source_missing');
      }
      return location.photos ?? const [];
    }
    if (clip.itemId case final id?) {
      final item = await db.itemDao.getById(id);
      if (item == null) {
        throw const StoryboardException('source_missing');
      }
      return item.photos ?? const [];
    }
    return const [];
  }

  Future<void> renameSubjectPhoto(
    ProductionClipRow clip,
    String assetId,
    String name,
  ) async {
    if (clip.characterId case final id?) {
      await NovelContentService(
        db,
      ).renameCharacterPhoto(id: id, assetId: assetId, name: name);
    } else if (clip.locationId case final id?) {
      await LocationsService(
        db,
      ).renamePhoto(id: id, assetId: assetId, name: name);
    } else if (clip.itemId case final id?) {
      await NovelContentService(db).renameItemPhoto(id, assetId, name);
    } else {
      throw const StoryboardException('source_missing');
    }
  }

  /// 从主体照片集移除关联，保留资产、头像和片段已采用的图片。
  Future<void> removeSubjectPhoto(ProductionClipRow clip, String assetId) =>
      write(clip.subjectId ?? clip.id, () async {
        final photos = await subjectPhotos(clip);
        if (clip.characterId case final id?) {
          await NovelContentService(db).updateCharacterAvatarAndPhotos(
            entryId: id,
            photos: photos.where((photo) => photo.assetId != assetId).toList(),
          );
        } else if (clip.locationId case final id?) {
          await LocationsService(db).removePhoto(id: id, assetId: assetId);
        } else if (clip.itemId case final id?) {
          await NovelContentService(db).removeItemPhoto(id, assetId);
        } else {
          throw const StoryboardException('source_missing');
        }
      });

  /// Called inside the same content transaction as adoption and its task marker.
  Future<void> appendSubjectPhoto(
    ProductionClipRow clip,
    String assetId,
  ) async {
    if (!clip.hasSubject) {
      return;
    }
    final photos = [...await subjectPhotos(clip)];
    if (photos.any((photo) => photo.assetId == assetId)) {
      return;
    }
    photos.add(SubjectPhoto(assetId: assetId, name: clip.title.trim()));
    if (clip.characterId != null) {
      await (db.update(
        db.characterProfiles,
      )..where((t) => t.id.equals(clip.characterId!))).write(
        CharacterProfilesCompanion(
          photos: Value(photos),
          updatedAt: Value(DateTime.now()),
        ),
      );
    } else if (clip.locationId != null) {
      await (db.update(
        db.locations,
      )..where((t) => t.id.equals(clip.locationId!))).write(
        LocationsCompanion(
          photos: Value(photos),
          updatedAt: Value(DateTime.now()),
        ),
      );
    } else {
      await db.itemDao.updatePhotos(clip.itemId!, photos);
    }
  }

  Future<CanvasNode> copyVideo(
    String nodeId, {
    required WorkingOverlayService overlay,
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'copyVideo',
    const [],
    () => write(nodeId, () async {
      final node = await requireNode(nodeId);
      final clip = node.clipId == null
          ? null
          : await shots.getShot(node.clipId!);
      if (clip == null || !{'video', 'image', 'audio'}.contains(clip.kind)) {
        throw const StoryboardException('invalid_config');
      }
      final copy = clip.kind == 'audio'
          ? await shots.createAudio(
              clip.episodeId,
              values: shots.snapshot(clip),
            )
          : clip.kind == 'image'
          ? await shots.createImage(
              clip.episodeId,
              values: shots.snapshot(clip),
            )
          : await StoryboardEditOrchestrator().create(
              service: shots,
              overlay: overlay,
              episodeId: clip.episodeId,
              values: shots.snapshot(clip),
            );
      if (clip.hasSubject) {
        await (db.update(
          db.productionClips,
        )..where((t) => t.id.equals(copy.id))).write(
          ProductionClipsCompanion(adoptedAssetId: Value(clip.adoptedAssetId)),
        );
      }
      final target = await shots.ensureClipNode(copy.id);
      final inputs = await draftInputs(nodeId);
      final copiedInputs = inputs
          .map(
            (input) => input.withId(
              buildShortEntityId(ShortEntityIdType.productionInput),
            ),
          )
          .toList();
      final copiedIds = {
        for (var i = 0; i < inputs.length; i++)
          inputs[i].id: copiedInputs[i].id,
      };
      final copiedPrompt = StoryboardPrompt.parse(clip.prompt).parts
          .map(
            (part) => part.isReference && copiedIds.containsKey(part.inputId)
                ? StoryboardPrompt.reference(
                    copiedIds[part.inputId]!,
                    part.label!,
                  )
                : part.text,
          )
          .join();
      await shots.restoreInputs(
        copy.id,
        copiedInputs.map((input) => input.toJson()).toList(),
      );
      await shots.apply(copy.id, {
        ...shots.snapshot(copy),
        'prompt': copiedPrompt,
      });
      final settingsKey = clip.kind == 'audio'
          ? 'audioGeneration'
          : 'imageGeneration';
      if ({'image', 'audio'}.contains(clip.kind) &&
          node.style?[settingsKey] != null) {
        await db.canvasDao.updateActiveNodeFields(
          target.id,
          CanvasNodesCompanion(
            style: Value({settingsKey: node.style![settingsKey]}),
          ),
        );
      }
      return (await db.canvasDao.getNodeById(target.id))!;
    }),
  );

  Future<AssetRow> requireAsset(String id, {String? type}) async {
    final asset = await library.database.assetDao.getAsset(id);
    if (asset == null ||
        (asset.novelId != null && asset.novelId != novelId) ||
        (type != null && asset.type != type) ||
        !{'image', 'video', 'audio'}.contains(asset.type)) {
      throw const StoryboardException('invalid_asset');
    }
    final file = File(library.resolve(asset));
    final handle = await file.open();
    try {
      if (await handle.length() == 0) {
        throw const StoryboardException('invalid_asset');
      }
    } finally {
      await handle.close();
    }
    return asset;
  }

  Future<CanvasNode> addMedia(
    String canvasId,
    String assetId, {
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'addMedia',
    const [],
    () => write(canvasId, () async {
      await requireCanvas(canvasId);
      final asset = await requireAsset(assetId);
      return _insertNode(
        canvasId,
        canvasNodeTypeMedia,
        title: asset.name,
        refType: canvasNodeRefTypeAsset,
        refId: asset.id,
      );
    }),
  );

  /// 新建一份空调度和指向它的导演台节点。
  Future<CanvasNode> addDirector(
    String canvasId,
    String title, {
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'addDirector',
    const [],
    () => write(canvasId, () async {
      await requireCanvas(canvasId);
      final stagingId = buildRandomId('staging');
      final settings = await shots.requireSettings();
      final document = DirectorDocument.blank(title).toJson();
      (document['output'] as Map).remove('aspect_mode');
      document['output']['width'] = settings.width;
      document['output']['height'] = settings.height;
      final validated = DirectorDocument.fromJson(document);
      await db.screenplayDao.createStaging(stagingId, title);
      await db.screenplayDao.saveStaging(
        stagingId,
        validated.toJson(),
        title: title,
        savedAt: DateTime.now(),
      );
      return _insertNode(
        canvasId,
        canvasNodeTypeStaging,
        title: title,
        refType: canvasNodeRefTypeStaging,
        refId: stagingId,
      );
    }),
  );

  /// 导演台导出的资产放在导演台节点右侧，并用 staging_output 连线标明来源。
  /// 同一资产已经挂在这个导演台下面时直接返回原节点。
  Future<CanvasNode> addStagingOutput(String directorNodeId, String assetId) =>
      write(directorNodeId, () async {
        final director = await requireNode(directorNodeId);
        if (director.type != canvasNodeTypeStaging) {
          throw const StoryboardException('invalid_config');
        }
        final asset = await requireAsset(assetId);
        for (final output in await stagingOutputs(directorNodeId)) {
          if (output.mediaAssetId == asset.id) {
            return output;
          }
        }
        final node = await _insertNode(
          director.canvasId,
          canvasNodeTypeMedia,
          title: asset.name,
          refType: canvasNodeRefTypeAsset,
          refId: asset.id,
          x: director.x + (director.width ?? 300) + 120,
          y: director.y,
        );
        await _insertEdge(
          (id) => CanvasEdgesCompanion.insert(
            id: id,
            canvasId: director.canvasId,
            sourceNodeId: director.id,
            targetNodeId: node.id,
            type: const Value(canvasEdgeTypeStagingOutput),
          ),
        );
        return node;
      });

  /// 视频节点当前的视频：素材节点取素材，视频节点取采用结果。
  Future<AssetRow> videoSource(String nodeId) async {
    final node = await requireNode(nodeId);
    final assetId =
        node.mediaAssetId ??
        (node.clipId == null
            ? null
            : (await shots.getShot(node.clipId!))?.adoptedAssetId);
    if (assetId == null) {
      throw const StoryboardException('invalid_reference');
    }
    return requireAsset(assetId, type: 'video');
  }

  /// 视频处理的产物用 derived_output 连线标明来源。给了 [placement] 时落在指定位置并同时移动让位的节点；
  /// 否则放在源节点右侧找空位。
  Future<CanvasNode> addDerivedOutput(
    String sourceNodeId,
    String assetId, {
    ProductionNodePlacement? placement,
    String? title,
  }) => write(sourceNodeId, () async {
    final source = await requireNode(sourceNodeId);
    final asset = await requireAsset(assetId);
    if (placement != null) {
      await _moveAll(source.canvasId, placement.moves);
    }
    final node = await _insertNode(
      source.canvasId,
      canvasNodeTypeMedia,
      title: title ?? asset.name,
      refType: canvasNodeRefTypeAsset,
      refId: asset.id,
      x: placement?.at.x ?? source.x + (source.width ?? 300) + 120,
      y: placement?.at.y ?? source.y,
      findFree: placement == null,
    );
    await _insertEdge(
      (id) => CanvasEdgesCompanion.insert(
        id: id,
        canvasId: source.canvasId,
        sourceNodeId: source.id,
        targetNodeId: node.id,
        type: const Value(canvasEdgeTypeDerivedOutput),
      ),
    );
    return node;
  });

  /// 导演台节点名下仍在画布上的导出结果节点，按创建先后排列。
  Future<List<CanvasNode>> stagingOutputs(String directorNodeId) async {
    final director = await requireNode(directorNodeId);
    final targets = {
      for (final edge in await db.canvasDao.getEdgesByCanvas(director.canvasId))
        if (edge.type == canvasEdgeTypeStagingOutput &&
            edge.sourceNodeId == director.id)
          edge.targetNodeId,
    };
    return (await db.canvasDao.getNodesByCanvas(
        director.canvasId,
      )).where((n) => targets.contains(n.id)).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  /// 画布上可见的图片：图片素材节点与已采用结果的图片生成节点，按节点创建先后去重。
  Future<List<AssetRow>> canvasImages(String canvasId) async {
    final nodes = await db.canvasDao.getNodesByCanvas(canvasId)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final clipIds = [
      for (final node in nodes)
        if (node.type == canvasNodeTypeImage) ?node.clipId,
    ];
    final adopted = {
      for (final clip in await (db.select(
        db.productionClips,
      )..where((t) => t.id.isIn(clipIds))).get())
        clip.id: clip.adoptedAssetId,
    };
    final images = <AssetRow>[];
    final seen = <String>{};
    for (final node in nodes) {
      final id = node.mediaAssetId ?? adopted[node.clipId];
      if (id == null || !seen.add(id)) {
        continue;
      }
      final asset = await library.database.assetDao.getAsset(id);
      if (asset != null && asset.type == 'image') {
        images.add(asset);
      }
    }
    return images;
  }

  Future<CanvasNode> _insertNode(
    String canvasId,
    String type, {
    String title = '',
    required String? refType,
    required String? refId,
    String content = '',
    double x = 360,
    double y = 80,
    bool findFree = true,
  }) async {
    if (!x.isFinite || !y.isFinite) {
      throw const StoryboardException('invalid_config');
    }
    final nodes = findFree
        ? await db.canvasDao.getNodesByCanvas(canvasId)
        : const <CanvasNode>[];
    // Find a free rectangle without moving existing nodes.
    while (nodes.any(
      (n) =>
          x < n.x + (n.width ?? 300) + 24 &&
          x + 300 + 24 > n.x &&
          y < n.y + (n.height ?? 220) + 24 &&
          y + 220 + 24 > n.y,
    )) {
      y += 260;
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
              canvasId: canvasId,
              type: Value(type),
              title: Value(title),
              content: Value(content),
              refType: Value(refType),
              refId: Value(refId),
              x: Value(x),
              y: Value(y),
              width: const Value(300),
              height: const Value(220),
            ),
          ),
    );
    return (await db.canvasDao.getNodeById(id))!;
  }

  Future<void> _insertEdge(CanvasEdgesCompanion Function(String id) edge) =>
      insertWithShortEntityId(
        type: ShortEntityIdType.canvasEdge,
        tableName: 'canvas_edges',
        idExists: db.canvasDao.edgeIdExists,
        insert: (id) => db.into(db.canvasEdges).insert(edge(id)),
      );

  Future<void> move(
    String nodeId,
    double x,
    double y, {
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'move',
    [nodeId],
    () => write(nodeId, () async {
      await groups.move(await requireNode(nodeId), x, y);
    }),
  );

  /// 整组位置在一个事务内保存，避免场次只移动了一部分。
  Future<void> moveNodes(
    String canvasId,
    Map<String, ({double x, double y})> positions, {
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'moveNodes',
    positions.keys,
    () => write(canvasId, () async {
      await requireCanvas(canvasId);
      await _moveAll(canvasId, positions);
    }),
  );

  Future<void> _moveAll(
    String canvasId,
    Map<String, ({double x, double y})> positions,
  ) async {
    for (final id in positions.keys) {
      await requireNode(id);
    }
    await groups.moveAll(canvasId, positions);
  }

  /// 删除分组时连同成员一起软删除。
  Future<void> removeNode(String nodeId, {CanvasHistory? history}) =>
      withCanvasHistory(
        history,
        shots,
        'removeNode',
        [nodeId],
        () => write(nodeId, () async {
          await groups.remove(await requireNode(nodeId));
        }),
      );

  /// 选区删除一次事务完成；已选分组的成员由分组级联处理，不重复删除。
  Future<void> removeNodes(
    String canvasId,
    Set<String> nodeIds, {
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'removeNodes',
    nodeIds,
    () => write(canvasId, () async {
      await requireCanvas(canvasId);
      final nodes = [for (final id in nodeIds) await requireNode(id)];
      if (nodes.any((node) => node.canvasId != canvasId)) {
        throw const StoryboardException('invalid_reference');
      }
      final groups = nodes
          .where((node) => node.type == canvasNodeTypeGroup)
          .map((node) => node.id)
          .toSet();
      for (final node in nodes) {
        if (!groups.contains(node.parentId)) {
          await removeNode(node.id);
        }
      }
    }),
  );

  /// 宫格切分与高清生成的成员一次挂进新分镜组；素材成员必须是图片资产。
  Future<CanvasNode> createStoryboardGroup(
    String canvasId, {
    required StoryboardGroupLayout layout,
    required Offset origin,
    required List<String> memberIds,
    String title = '',
    String? sourceNodeId,
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'createStoryboardGroup',
    memberIds,
    () => write(canvasId, () async {
      await requireCanvas(canvasId);
      for (final id in memberIds) {
        final node = await requireNode(id);
        if (node.mediaAssetId case final assetId?) {
          await requireAsset(assetId, type: 'image');
        }
      }
      final group = await groups.createStoryboard(
        canvasId,
        layout: layout,
        origin: origin,
        memberIds: memberIds,
        title: title,
      );
      if (sourceNodeId != null) {
        final source = await requireNode(sourceNodeId);
        if (source.canvasId != canvasId) {
          throw const StoryboardException('invalid_reference');
        }
        await _insertEdge(
          (id) => CanvasEdgesCompanion.insert(
            id: id,
            canvasId: canvasId,
            sourceNodeId: sourceNodeId,
            targetNodeId: group.id,
            type: const Value(canvasEdgeTypeDerivedOutput),
          ),
        );
      }
      return group;
    }),
  );

  /// 图片选择器在一个事务内创建并挂入空格位；格位已被占用时整笔回滚。
  Future<CanvasNode> fillStoryboardSlot(
    String groupId,
    int slot,
    String assetId, {
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'fillStoryboardSlot',
    [groupId],
    () => write(groupId, () async {
      final group = await groups.requireGroup(groupId);
      await requireAsset(assetId, type: 'image');
      final member = await addMedia(group.canvasId, assetId);
      await groups.attachToSlot(groupId, member.id, slot);
      return requireNode(member.id);
    }),
  );

  Future<List<ProductionInput>> inputs(String nodeId) async {
    final node = await requireNode(nodeId);
    if (node.clipId == null) {
      throw const StoryboardException('invalid_reference');
    }
    return (await shots.getShot(node.clipId!))!.inputs;
  }

  Future<List<ProductionInput>> draftInputs(String nodeId) => inputs(nodeId);

  Future<({List<CanvasNode> nodes, List<ProductionConnection> edges})> content(
    String canvasId,
  ) => readContent(db, canvasId);

  static Future<({List<CanvasNode> nodes, List<ProductionConnection> edges})>
  readContent(NovelContentDatabase db, String canvasId) =>
      db.transaction(() async {
        final nodes = await db.canvasDao.getNodesByCanvas(canvasId);
        final clips = await (db.select(
          db.productionClips,
        )..where((t) => t.id.isIn(nodes.map((n) => n.clipId).nonNulls))).get();
        final byId = {for (final clip in clips) clip.id: clip};
        final stored = await db.canvasDao.getEdgesByCanvas(canvasId);
        return (
          nodes: nodes,
          edges: [
            for (final edge in stored) ProductionConnection.stored(edge),
            for (final node in nodes)
              for (final input
                  in byId[node.clipId]?.inputs ?? <ProductionInput>[])
                if (input.sourceNodeId != null)
                  ProductionConnection(
                    // 不同片段可以有同名输入，连线身份要带上目标节点。
                    id: '${node.id}:${input.id}',
                    sourceNodeId: input.sourceNodeId!,
                    targetNodeId: node.id,
                    type: canvasEdgeTypeInput,
                    role: input.roleName,
                    inputId: input.id,
                    middleFrameIndex: input.middleFrameIndex(
                      byId[node.clipId]!.inputs,
                    ),
                  ),
          ],
        );
      });

  Stream<({List<CanvasNode> nodes, List<ProductionConnection> edges})>
  watchContent(String canvasId) => db
      .customSelect(
        'SELECT 1',
        readsFrom: {db.canvasNodes, db.canvasEdges, db.productionClips},
      )
      .watch()
      .asyncMap((_) => content(canvasId));

  Future<ProductionMediaFile> requireFile(String path, {String? type}) =>
      ProductionMediaFile.read(library, path, type: type);

  /// 文件入口统一登记资产；已软删除的记录不能作为读取回退。
  Future<AssetRow> assetForPath(String path, {String? type}) async {
    final relative = library.relativePath(path);
    final existing = await library.database.assetDao.findByPath(relative);
    if (existing != null) {
      return requireAsset(existing.id, type: type);
    }
    final file = await requireFile(relative, type: type);
    return library.importFile(
      File(library.resolvePath(file.path)),
      name: file.name,
      novelId: novelId,
      purpose: AssetPurpose.production_output,
      cancellation: MediaCancellation(),
    );
  }

  Future<AssetRow> inputAsset(ProductionInput input) async {
    if (input.isPrompt) {
      throw const StoryboardException('invalid_reference');
    }
    if (input.refType == ProductionInputType.asset) {
      return requireAsset(input.refId, type: input.role.kind.name);
    }
    final source = await requireNode(input.refId);
    final assetId =
        source.mediaAssetId ??
        (source.clipId == null
            ? null
            : (await shots.getShot(source.clipId!))?.adoptedAssetId);
    if (assetId == null) {
      throw const StoryboardException('invalid_reference');
    }
    return requireAsset(assetId, type: input.role.kind.name);
  }

  Future<ProductionMediaFile> resolveInput(ProductionInput input) async {
    final asset = await inputAsset(input);
    return requireFile(asset.path!, type: input.role.kind.name);
  }

  /// 同时响应资产软删除、来源节点删除和生成片段采用结果的变化。
  Stream<AssetRow> watchInputAsset(ProductionInput input) =>
      Stream.multi((events) {
        var revision = 0;
        var cancelled = false;
        Future<void> refresh() async {
          final current = ++revision;
          try {
            final asset = await inputAsset(input);
            if (!cancelled && current == revision) {
              events.add(asset);
            }
          } catch (error, stack) {
            if (!cancelled && current == revision) {
              events.addError(error, stack);
            }
          }
        }

        final sources = db
            .customSelect(
              'SELECT 1',
              readsFrom: {db.canvasNodes, db.productionClips},
            )
            .watch()
            .listen((_) => refresh(), onError: events.addError);
        final assets = library.database.assetDao
            .watchAssets(novelId: novelId)
            .listen((_) => refresh(), onError: events.addError);
        events.onCancel = () {
          cancelled = true;
          unawaited(sources.cancel());
          unawaited(assets.cancel());
        };
      });

  Future<String> inputName(ProductionInput input) async {
    if (input.refType == ProductionInputType.node) {
      final title = (await db.canvasDao.getNodeById(input.refId))?.title;
      return title == null || title.trim().isEmpty ? input.refId : title;
    }
    return (await library.database.assetDao.getAsset(input.refId))?.name ??
        input.refId;
  }

  Future<void> requireAcyclic(
    String sourceId,
    String targetId,
    String canvasId,
  ) async {
    final edges = (await content(
      canvasId,
    )).edges.where((e) => e.type == canvasEdgeTypeInput);
    final pending = [targetId];
    final visited = <String>{};
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (current == sourceId) {
        throw const StoryboardException('invalid_reference');
      }
      if (!visited.add(current)) {
        continue;
      }
      pending.addAll(
        edges
            .where((e) => e.sourceNodeId == current)
            .map((e) => e.targetNodeId),
      );
    }
  }

  Future<void> save({
    required String nodeId,
    required VideoRequest request,
    String? title,
    required String? providerId,
    required List<ProductionInput> inputs,
    required WorkingOverlayService overlay,
  }) => saveDraft(
    nodeId: nodeId,
    inputs: inputs,
    overlay: overlay,
    values: {
      'title': ?title,
      'prompt': request.prompt,
      'provider_id': providerId,
      'model_id': providerId == null ? null : request.modelId,
      'reference_mode': request.mode.name,
      'generate_audio': request.audio,
      'duration_ms': request.durationSeconds == 0
          ? null
          : request.durationSeconds * 1000,
      'ratio': request.ratio,
      'resolution': request.resolution,
    },
  );

  Future<void> saveImage({
    required String nodeId,
    required ProductionImageDraft draft,
    required List<ProductionInput> inputs,
    required WorkingOverlayService overlay,
  }) => write(nodeId, () async {
    await saveDraft(
      nodeId: nodeId,
      inputs: inputs,
      overlay: overlay,
      values: {
        'title': ?draft.title,
        'prompt': draft.prompt,
        'provider_id': draft.providerId,
        'model_id': draft.providerId == null ? null : draft.modelId,
        'reference_mode': 'reference',
        'duration_ms': null,
        'ratio': draft.ratio,
        'resolution': draft.resolution,
      },
    );
    final preset = draft.preset;
    if (preset != null) {
      final node = await requireNode(nodeId);
      final previous = ImageGenerationPreset.fromStyle(node.style);
      final style = {...?node.style, 'imageGeneration': preset.toJson()};
      if (previous.method != preset.method) {
        if (preset.method == ImageGenerationMethod.panorama) {
          style['panorama'] = const PanoramaView().toJson();
        } else {
          style.remove('panorama');
        }
      }
      await db.canvasDao.updateActiveNodeFields(
        node.id,
        CanvasNodesCompanion(style: Value(style)),
      );
    }
  });

  Future<void> saveAudio({
    required String nodeId,
    required String prompt,
    required String? providerId,
    required String? modelId,
    required List<ProductionInput> inputs,
    required WorkingOverlayService overlay,
    AudioRequestDefaults? parameters,
  }) => write(nodeId, () async {
    await saveDraft(
      nodeId: nodeId,
      inputs: inputs,
      overlay: overlay,
      values: {
        'prompt': prompt,
        'provider_id': providerId,
        'model_id': modelId,
        'reference_mode': 'reference',
        'duration_ms': null,
        'ratio': '1:1',
        'resolution': '24k',
      },
    );
    if (parameters != null) {
      final node = await requireNode(nodeId);
      await db.canvasDao.updateActiveNodeFields(
        nodeId,
        CanvasNodesCompanion(
          style: Value({
            ...?node.style,
            'audioGeneration': {
              'provider_id': providerId,
              'model_id': modelId,
              'parameters': parameters.toJson(),
            },
          }),
        ),
      );
    }
  });

  Future<void> saveDraft({
    required String nodeId,
    required Map<String, dynamic> values,
    required List<ProductionInput> inputs,
    required WorkingOverlayService overlay,
    ShotEditOrigin origin = const ShotEditOrigin.manual(),
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'saveDraft',
    [nodeId],
    () => write(nodeId, () async {
      final node = await requireNode(nodeId);
      final beforeInputs = node.clipId != null
          ? await shots.inputSnapshot(node.clipId!)
          : null;
      if (!origin.isAgent && node.clipId != null) {
        await StoryboardEditOrchestrator().takeOver(overlay, node.clipId!);
      }
      await validateInputs(
        node: node,
        values: values,
        inputs: inputs,
        origin: origin,
      );
      await shots.restoreInputs(
        node.clipId!,
        inputs.map((input) => input.toJson()).toList(),
      );
      if (node.clipId != null) {
        String? inputChangeId;
        if (beforeInputs != null) {
          final afterInputs = await shots.inputSnapshot(node.clipId!);
          if (jsonEncode(beforeInputs) != jsonEncode(afterInputs)) {
            final inputChange = await overlay.stageTextChange(
              resourcePath: 'clips/${node.clipId}/inputs',
              resourceType: 'production_clips',
              resourceId: node.clipId!,
              field: 'inputs',
              oldText: jsonEncode(beforeInputs),
              newText: jsonEncode(afterInputs),
              source: origin.source,
              sourceSessionId: origin.sessionId,
              sourceTurnId: origin.turnId,
              toolName: origin.tool,
              summary: 'Production inputs',
            );
            inputChangeId = inputChange.id;
          }
        }
        await StoryboardEditOrchestrator().save(
          service: shots,
          overlay: overlay,
          shotId: node.clipId!,
          origin: origin,
          values: {
            ...values,
            if (node.type != canvasNodeTypeVideo) 'duration_ms': null,
          },
        );
        if (!origin.isAgent && inputChangeId != null) {
          await overlay.commitManualSave(
            manualChangeIds: [inputChangeId],
            resourceScopes: ['clips/${node.clipId}'],
            manualMessage: 'history.commit_message.manual_storyboard_save',
          );
        }
      }
    }),
  );

  Future<void> validateInputs({
    required CanvasNode node,
    required Map<String, dynamic> values,
    required List<ProductionInput> inputs,
    required ShotEditOrigin origin,
  }) async {
    if (!node.isGenerationNode ||
        inputs.map((e) => e.id).toSet().length != inputs.length) {
      throw const StoryboardException('invalid_config');
    }
    if (node.type == canvasNodeTypeImage &&
        inputs.any(
          (i) => !i.isPrompt && i.role != VideoInputRole.reference_image,
        )) {
      throw const StoryboardException('invalid_reference');
    }
    if (node.type == canvasNodeTypeAudio) {
      if (inputs.any(
        (i) =>
            !i.isPrompt &&
            !{
              VideoInputRole.reference_audio,
              VideoInputRole.reference_image,
            }.contains(i.role),
      )) {
        throw const StoryboardException('audio_reference_format');
      }
      final model = values['model_id'] as String?;
      if (model != null) {
        final providerId = values['provider_id'] as String?;
        final provider = providerId == null
            ? null
            : await library.database.aiProviderDao.getById(providerId);
        if (provider == null) {
          throw const StoryboardException('invalid_config');
        }
        AudioCapabilities.forProvider(model, provider).validateSelection(
          inputs.where((i) => !i.isPrompt).map((i) => i.role.kind.name),
        );
      }
    }
    final prompt = StoryboardPrompt.parse(values['prompt'] as String);
    if (origin.isAgent) {
      prompt.requireValidReferences(inputs.map((input) => input.id));
    }
    ProductionInput.validateList(inputs);
    final existing = await this.inputs(node.id);
    for (final input in inputs) {
      if (input.isPrompt) {
        final source = await requireNode(input.refId);
        if (source.type != canvasNodeTypeText ||
            source.canvasId != node.canvasId) {
          throw const StoryboardException('invalid_reference');
        }
        continue;
      }
      // 已失效的已存参考保留，允许用户继续编辑并在卡片修复；提交会重新校验。
      final unchanged =
          !origin.isAgent &&
          existing.any(
            (old) =>
                old.id == input.id &&
                old.sourceIdentity == input.sourceIdentity,
          );
      if (input.voiceAssetId != null) {
        if (node.type != canvasNodeTypeVideo) {
          throw const StoryboardException('invalid_reference');
        }
        final sameVoice =
            unchanged &&
            existing.any(
              (old) =>
                  old.id == input.id && old.voiceAssetId == input.voiceAssetId,
            );
        if (!sameVoice) {
          await requireInputVoice(input, requireBinding: true);
        }
      }
      if (input.refType == ProductionInputType.node) {
        final source = await db.canvasDao.getNodeById(input.refId);
        if (source == null && unchanged) {
          continue;
        }
        if (source == null ||
            source.canvasId != node.canvasId ||
            (!source.isGenerationNode && source.mediaAssetId == null)) {
          throw const StoryboardException('invalid_reference');
        }
        if (source.isGenerationNode && source.type != input.role.kind.name) {
          throw const StoryboardException('invalid_reference');
        }
        if (!unchanged && source.mediaAssetId != null) {
          await requireAsset(source.mediaAssetId!, type: input.role.kind.name);
        }
        await requireAcyclic(source.id, node.id, node.canvasId);
      }
      if (!unchanged && input.refType == ProductionInputType.asset) {
        await requireAsset(input.refId, type: input.role.kind.name);
      }
    }
  }

  /// Agent 带输入创建片段：建行、建节点、校验输入在同一事务内，只留一条创建记录。
  Future<ProductionClipRow> createClipWithInputs({
    required WorkingOverlayService overlay,
    required List<ProductionInput> inputs,
    required ShotEditOrigin origin,
    String? sceneId,
    String? episodeId,
    Map<String, dynamic> values = const {},
  }) => write(sceneId ?? episodeId ?? '', () async {
    final row = await StoryboardEditOrchestrator().create(
      service: shots,
      overlay: overlay,
      sceneId: sceneId,
      episodeId: episodeId,
      values: values,
      origin: origin,
      inputs: inputs,
    );
    final node = await shots.ensureClipNode(row.id);
    await validateInputs(
      node: node,
      values: shots.snapshot(row),
      inputs: inputs,
      origin: origin,
    );
    await shots.restoreInputs(
      row.id,
      inputs.map((input) => input.toJson()).toList(),
    );
    return (await shots.getShot(row.id))!;
  });

  Future<void> adoptGenerated(
    String nodeId,
    String taskId, {
    String? assetId,
  }) => write(nodeId, () async {
    final node = await requireNode(nodeId);
    final task = await library.database.generationTaskDao.getById(taskId);
    if (task == null ||
        !canAdoptProductionTask(task) ||
        task.novelId != novelId ||
        task.sourceType != 'production_clip' ||
        task.sourceId != node.clipId ||
        task.kind.name != node.type) {
      throw const StoryboardException('invalid_result');
    }
    final selected = assetId ?? task.resultAssetId!;
    if (!task.resultAssetIds.contains(selected)) {
      throw const StoryboardException('invalid_result');
    }
    await adopt(nodeId, selected);
  });

  /// 外部文件先在导入入口登记成资产，这里只接收资产 id。
  Future<void> adopt(String nodeId, String assetId) => write(nodeId, () async {
    final node = await requireNode(nodeId);
    if (node.clipId == null) {
      throw const StoryboardException('invalid_config');
    }
    final asset = await requireAsset(assetId, type: node.type);
    await appendSubjectPhoto((await shots.getShot(node.clipId!))!, asset.id);
    await (db.update(
      db.productionClips,
    )..where((t) => t.id.equals(node.clipId!))).write(
      ProductionClipsCompanion(
        adoptedAssetId: Value(asset.id),
        updatedAt: Value(DateTime.now()),
      ),
    );
  });

  /// 取消采用；下游输入按节点解析，不再读到旧结果。
  Future<void> unadopt(String nodeId) => write(nodeId, () async {
    final node = await requireNode(nodeId);
    if (node.clipId == null) {
      throw const StoryboardException('invalid_config');
    }
    await (db.update(
      db.productionClips,
    )..where((t) => t.id.equals(node.clipId!))).write(
      ProductionClipsCompanion(
        adoptedAssetId: const Value(null),
        updatedAt: Value(DateTime.now()),
      ),
    );
  });
}

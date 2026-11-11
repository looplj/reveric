// 职责: 原子编排人工和 Agent 片段保存、复制、排序及变更历史。
// 关联文件:
//   lib/shared/services/storyboard/service.dart
//   lib/shared/services/working_overlay.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
import 'dart:convert';
import '../../database/novel_content_database.dart';
import '../../models/storyboard/prompt.dart';
import '../../models/production/input.dart';
import '../../utils/short_entity_id.dart';
import '../../utils/resource_path.dart';
import '../working_overlay.dart';
import 'service.dart';

class ShotEditOrigin {
  const ShotEditOrigin.manual() : sessionId = null, turnId = null, tool = null;
  const ShotEditOrigin.agent({
    required this.sessionId,
    this.turnId,
    required this.tool,
  });
  final String? sessionId;
  final String? turnId;
  final String? tool;
  bool get isAgent => tool != null;
  String get source =>
      isAgent ? workingChangeSourceAi : workingChangeSourceManual;
}

class StoryboardEditOrchestrator {
  Future<void> takeOver(WorkingOverlayService overlay, String id) async {
    final changes = (await overlay.getWorkingChanges()).where(
      (c) =>
          c.status == workingChangeStatusActive &&
          c.source == workingChangeSourceAi &&
          resourcePathIsWithin(c.resourcePath, 'clips/$id'),
    );
    await overlay.commitWorkingChanges(
      changes.map((c) => c.id).toList(),
      source: workingChangeSourceAi,
      message: 'history.commit_message.auto_commit_ai_changes',
    );
  }

  Future<ProductionClipRow> save({
    required StoryboardService service,
    required WorkingOverlayService overlay,
    required String shotId,
    required Map<String, dynamic> values,
    ShotEditOrigin origin = const ShotEditOrigin.manual(),
  }) => service.write('SAVE', shotId, () async {
    final current = await service.getShot(shotId);
    if (current == null) {
      throw const StoryboardException('source_missing');
    }
    final target = {...service.snapshot(current), ...values};
    final prompt = StoryboardPrompt.parse(target['prompt'] as String);
    if (origin.isAgent) {
      prompt.requireValidReferences(current.inputs.map((input) => input.id));
    } else {
      await takeOver(overlay, current.id);
    }
    final before = jsonEncode(service.snapshot(current));
    final after = jsonEncode(target);
    if (before == after) {
      return current;
    }
    final change = await overlay.stageTextChange(
      resourcePath: 'clips/${current.id}/document',
      resourceType: 'production_clips',
      resourceId: current.id,
      field: 'document',
      oldText: before,
      newText: after,
      source: origin.source,
      sourceSessionId: origin.sessionId,
      sourceTurnId: origin.turnId,
      toolName: origin.tool,
      summary: current.title,
    );
    if (!origin.isAgent) {
      await overlay.commitManualSave(
        manualChangeIds: [change.id],
        resourceScopes: ['clips/${current.id}'],
        manualMessage: 'history.commit_message.manual_storyboard_save',
      );
    }
    return (await service.getShot(current.id))!;
  });

  Future<ProductionClipRow> create({
    required StoryboardService service,
    required WorkingOverlayService overlay,
    String? sceneId,
    String? episodeId,
    Map<String, dynamic> values = const {},
    ShotEditOrigin origin = const ShotEditOrigin.manual(),
    List<ProductionInput> inputs = const [],
  }) => service.write('CREATE', sceneId ?? episodeId ?? '', () async {
    if (origin.isAgent) {
      StoryboardPrompt.parse(
        values['prompt'] as String? ?? '',
      ).requireValidReferences(inputs.map((input) => input.id));
    }
    if (sceneId == null && episodeId == null) {
      throw const StoryboardException('source_missing');
    }
    final row = sceneId != null
        ? await service.create(sceneId, values: values)
        : values['kind'] == 'audio'
        ? await service.createAudio(episodeId!, values: values)
        : values['kind'] == 'image'
        ? await service.createImage(episodeId!, values: values)
        : await service.createVideo(episodeId!, values: values);
    final change = await overlay.stageCreateChange(
      resourcePath: 'clips/${row.id}',
      resourceType: 'production_clips',
      resourceId: row.id,
      previewText: jsonEncode(service.snapshot(row)),
      source: origin.source,
      sourceSessionId: origin.sessionId,
      sourceTurnId: origin.turnId,
      toolName: origin.tool,
      summary: row.title,
    );
    if (!origin.isAgent) {
      await overlay.commitManualSave(
        manualChangeIds: [change.id],
        resourceScopes: ['clips/${row.id}'],
        manualMessage: 'history.commit_message.manual_storyboard_save',
      );
    }
    return row;
  });

  Future<ProductionClipRow> copy({
    required StoryboardService service,
    required WorkingOverlayService overlay,
    required ProductionClipRow shot,
    required String sceneId,
  }) => service.write('COPY', shot.id, () async {
    final values = service.snapshot(shot)
      ..remove('episode_id')
      ..remove('scene_id')
      ..remove('sort_order');
    final destination = await service.requireScene(sceneId);
    if (destination.episodeId != shot.episodeId &&
        shot.inputs.any((i) => i.sourceNodeId != null)) {
      throw const StoryboardException('cross_episode_move');
    }
    final copiedInputs = shot.inputs
        .map(
          (input) => input.withId(
            buildShortEntityId(ShortEntityIdType.productionInput),
          ),
        )
        .toList();
    final copiedIds = {
      for (var i = 0; i < shot.inputs.length; i++)
        shot.inputs[i].id: copiedInputs[i].id,
    };
    values['prompt'] = StoryboardPrompt.parse(shot.prompt).parts
        .map(
          (part) => part.isReference && copiedIds.containsKey(part.inputId)
              ? StoryboardPrompt.reference(
                  copiedIds[part.inputId]!,
                  part.label!,
                )
              : part.text,
        )
        .join();
    final copied = await create(
      service: service,
      overlay: overlay,
      sceneId: sceneId,
      values: values,
    );
    await service.restoreInputs(
      copied.id,
      copiedInputs.map((i) => i.toJson()).toList(),
    );
    return (await service.getShot(copied.id))!;
  });

  Future<ProductionClipRow> moveOrSave({
    required StoryboardService service,
    required WorkingOverlayService overlay,
    required String shotId,
    required Map<String, dynamic> values,
    ShotEditOrigin origin = const ShotEditOrigin.manual(),
  }) => service.write('MOVE_OR_SAVE', shotId, () async {
    final current = await service.getShot(shotId);
    if (current == null) {
      throw const StoryboardException('source_missing');
    }
    if (!values.containsKey('sort_order') && !values.containsKey('scene_id')) {
      return save(
        service: service,
        overlay: overlay,
        shotId: shotId,
        values: values,
        origin: origin,
      );
    }
    final destination = values.containsKey('scene_id')
        ? values['scene_id'] as String?
        : current.sceneId;
    if (destination == null) {
      if (values['sort_order'] != null) {
        throw const StoryboardException('invalid_config');
      }
      return save(
        service: service,
        overlay: overlay,
        shotId: shotId,
        values: {...values, 'scene_id': null, 'sort_order': null},
        origin: origin,
      );
    }
    if (values.containsKey('sort_order') && values['sort_order'] == null) {
      throw const StoryboardException('invalid_config');
    }
    final siblings = (await service.sceneShots(
      destination,
    )).where((shot) => shot.id != shotId).toList();
    final index = values['sort_order'] as int? ?? siblings.length;
    if (index < 0 || index > siblings.length) {
      throw const StoryboardException('invalid_config');
    }
    final saved = await save(
      service: service,
      overlay: overlay,
      shotId: shotId,
      values: {...values, 'sort_order': index},
      origin: origin,
    );
    siblings.insert(index, saved);
    for (var i = 0; i < siblings.length; i++) {
      final sibling = siblings[i];
      if (sibling.id != saved.id && sibling.sortOrder != i) {
        await save(
          service: service,
          overlay: overlay,
          shotId: sibling.id,
          values: {'sort_order': i},
          origin: origin,
        );
      }
    }
    return saved;
  });

  Future<void> reorder({
    required StoryboardService service,
    required WorkingOverlayService overlay,
    required List<ProductionClipRow> ordered,
  }) => service.write('REORDER', ordered.firstOrNull?.sceneId ?? '', () async {
    if (ordered.isEmpty) {
      return;
    }
    final current = await service.sceneShots(ordered.first.sceneId!);
    if (current.length != ordered.length ||
        ordered.map((s) => s.id).toSet().length != current.length ||
        !current.every((s) => ordered.any((o) => o.id == s.id))) {
      throw const StoryboardException('invalid_config');
    }
    for (var i = 0; i < ordered.length; i++) {
      await save(
        service: service,
        overlay: overlay,
        shotId: ordered[i].id,
        values: {'sort_order': i},
      );
    }
  });
}

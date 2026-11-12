// 职责: 维护制作画布分组：成员挂接与校验、布局变更、分镜组与普通组互转、整组与场次移动、解组、清空与删除。
// 关联文件:
//   lib/shared/models/production/group_layout.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/storyboard/service.dart
//   lib/shared/services/ai/tools_production.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/data-deletion.md
import 'dart:math' as math;
import 'dart:ui';

import 'package:drift/drift.dart';

import '../../database/novel_content_database.dart';
import '../../models/production/group_layout.dart';
import '../../models/storyboard/prompt.dart';
import '../../utils/short_entity_id.dart';
import '../../utils/short_entity_id_allocator.dart';
import '../storyboard/service.dart';
import 'canvas_history.dart';

/// 分组成员只能是图片节点：图片生成节点或图片素材节点；素材是否为图片由调用方按资产校验。
bool isProductionGroupMemberType(CanvasNode node) =>
    node.type == canvasNodeTypeImage ||
    (node.type == canvasNodeTypeMedia && node.mediaAssetId != null);

/// 只依赖内容库，Agent 画布工具与制作画布服务共用同一套分组规则。
class ProductionGroupService {
  ProductionGroupService(this.shots);
  final StoryboardService shots;
  NovelContentDatabase get db => shots.database;

  Future<T> write<T>(String id, Future<T> Function() action) => shots.write(
    'UPDATE canvas_nodes,canvas_edges,production_clips',
    id,
    action,
  );

  /// 未删除的分组节点；不存在、已删除或不是分组时为 null。
  Future<CanvasNode?> group(String? id) async {
    if (id == null) {
      return null;
    }
    final node = await db.canvasDao.getNodeById(id);
    return node?.type == canvasNodeTypeGroup ? node : null;
  }

  Future<CanvasNode> requireGroup(String id) async =>
      await group(id) ?? (throw const StoryboardException('source_missing'));

  /// [node] 所属分组；parent_id 指向不存在、已删除或别的画布的分组时视为不在分组中。
  Future<CanvasNode?> groupOf(CanvasNode node) async {
    final parent = await group(node.parentId);
    return parent?.canvasId == node.canvasId ? parent : null;
  }

  /// 分组的未删除成员，按 sort_order（分镜组即格位）排列。
  Future<List<CanvasNode>> members(String groupId) =>
      (db.select(db.canvasNodes)
            ..where(
              (t) =>
                  t.parentId.equals(groupId) &
                  t.deletedAt.equals(notDeletedSentinel),
            )
            ..orderBy([
              (t) => OrderingTerm(expression: t.sortOrder),
              (t) => OrderingTerm(expression: t.id),
            ]))
          .get();

  /// [node] 是否属于分镜组；分镜组成员坐标由布局决定，不能单独修改。
  Future<bool> inStoryboard(CanvasNode node) async {
    final parent = await groupOf(node);
    return parent != null &&
        ProductionGroupLayout.fromStyle(parent.style) is StoryboardGroupLayout;
  }

  /// 将成员放入目标格位；有成员时交换，空格位时移动，成员身份和连线保持不变。
  Future<void> swapSlot(
    String groupId,
    String memberId,
    int slot, {
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'swapSlot',
    [groupId],
    () => write(groupId, () async {
      final group = await requireGroup(groupId);
      final layout = _storyboard(group);
      final list = await members(groupId);
      final member = list.where((n) => n.id == memberId).firstOrNull;
      if (member == null || slot < 0 || slot >= layout.capacity) {
        throw const StoryboardException('invalid_config');
      }
      if (member.sortOrder == slot) {
        return;
      }
      final origin = Offset(group.x, group.y);
      // 只有换位的两行变化，其余成员不重写。
      for (final row in list) {
        final at = row.id == memberId
            ? slot
            : row.sortOrder == slot
            ? member.sortOrder
            : null;
        if (at == null) {
          continue;
        }
        final position = origin + layout.cellOffset(at);
        await db.canvasDao.updateActiveNodeFields(
          row.id,
          CanvasNodesCompanion(
            sortOrder: Value(at),
            x: Value(position.dx),
            y: Value(position.dy),
          ),
        );
      }
    }),
  );

  /// 建分镜组并按 [memberIds] 顺序占用格位 0…N-1，成员坐标按布局重写。
  Future<CanvasNode> createStoryboard(
    String canvasId, {
    required StoryboardGroupLayout layout,
    required Offset origin,
    required List<String> memberIds,
    String title = '',
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'createStoryboard',
    memberIds,
    () => write(canvasId, () async {
      layout.validate();
      if (!origin.dx.isFinite ||
          !origin.dy.isFinite ||
          memberIds.length > layout.capacity ||
          memberIds.toSet().length != memberIds.length) {
        throw const StoryboardException('invalid_config');
      }
      for (final id in memberIds) {
        await _requireAttachable(id, canvasId);
      }
      final size = layout.frameSize;
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
                type: const Value(canvasNodeTypeGroup),
                title: Value(title),
                x: Value(origin.dx),
                y: Value(origin.dy),
                width: Value(size.width),
                height: Value(size.height),
                style: Value(layout.writeTo(null)),
              ),
            ),
      );
      for (var i = 0; i < memberIds.length; i++) {
        final at = origin + layout.cellOffset(i);
        await db.canvasDao.updateActiveNodeFields(
          memberIds[i],
          CanvasNodesCompanion(
            parentId: Value(id),
            sortOrder: Value(i),
            x: Value(at.dx),
            y: Value(at.dy),
          ),
        );
      }
      return (await db.canvasDao.getNodeById(id))!;
    }),
  );

  /// 在分镜组的空格位 [slot] 挂上 [memberId]。
  Future<void> attachToSlot(
    String groupId,
    String memberId,
    int slot, {
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'attachToSlot',
    [groupId, memberId],
    () => write(groupId, () async {
      final group = await requireGroup(groupId);
      final layout = _storyboard(group);
      await _requireAttachable(memberId, group.canvasId);
      final taken = (await members(groupId)).map((m) => m.sortOrder);
      if (slot < 0 || slot >= layout.capacity || taken.contains(slot)) {
        throw const StoryboardException('invalid_config');
      }
      final at = Offset(group.x, group.y) + layout.cellOffset(slot);
      await db.canvasDao.updateActiveNodeFields(
        memberId,
        CanvasNodesCompanion(
          parentId: Value(groupId),
          sortOrder: Value(slot),
          x: Value(at.dx),
          y: Value(at.dy),
        ),
      );
    }),
  );

  /// 改比例、宫格或序号。宫格变化时成员按当前顺序重新紧凑排列，空格位移到末尾。
  Future<void> setStoryboardLayout(
    String groupId,
    StoryboardGroupLayout next, {
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'setStoryboardLayout',
    [groupId],
    () => write(groupId, () async {
      next.validate();
      final group = await requireGroup(groupId);
      final current = _storyboard(group);
      final list = await members(groupId);
      if (next.capacity < list.length) {
        throw const StoryboardException('invalid_config');
      }
      final regrid = current.cols != next.cols || current.rows != next.rows;
      await _writeStoryboard(group, next, {
        for (var i = 0; i < list.length; i++)
          list[i].id: regrid ? i : list[i].sortOrder,
      });
    }),
  );

  /// 分镜组转普通组：成员恢复 [sizes] 给出的实际显示尺寸，按宫格顺序以卡片间距重排。
  Future<void> toFree(
    String groupId,
    Map<String, Size> sizes, {
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'toFree',
    [groupId],
    () => write(groupId, () async {
      final group = await requireGroup(groupId);
      final layout = _storyboard(group);
      final list = await members(groupId);
      if (list.any((m) => sizes[m.id] == null)) {
        throw const StoryboardException('invalid_config');
      }
      final arranged = arrangeFreeGroup(Offset(group.x, group.y), [
        for (final m in list) sizes[m.id]!,
      ], layout.cols);
      for (var i = 0; i < list.length; i++) {
        await db.canvasDao.updateActiveNodeFields(
          list[i].id,
          CanvasNodesCompanion(
            sortOrder: Value(i),
            x: Value(arranged.positions[i].dx),
            y: Value(arranged.positions[i].dy),
          ),
        );
      }
      final frame = list.isEmpty
          ? Offset(group.x, group.y) & Size(group.width!, group.height!)
          : arranged.frame;
      await db.canvasDao.updateActiveNodeFields(
        groupId,
        CanvasNodesCompanion(
          style: Value(const FreeGroupLayout().writeTo(group.style)),
          x: Value(frame.left),
          y: Value(frame.top),
          width: Value(frame.width),
          height: Value(frame.height),
        ),
      );
    }),
  );

  /// 普通组转分镜组：成员按 [rects]（当前显示位置与尺寸）先行后列排序，
  /// 取能放下成员数的最小方阵，比例取第一个成员的最近比例。
  Future<void> toStoryboard(
    String groupId,
    Map<String, Rect> rects, {
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'toStoryboard',
    [groupId],
    () => write(groupId, () async {
      final group = await requireGroup(groupId);
      if (ProductionGroupLayout.fromStyle(group.style) is! FreeGroupLayout) {
        throw const StoryboardException('invalid_config');
      }
      final list = await members(groupId);
      if (list.any(
        (m) => !isProductionGroupMemberType(m) || rects[m.id] == null,
      )) {
        throw const StoryboardException('invalid_config');
      }
      final order = readingOrder({for (final m in list) m.id: rects[m.id]!});
      final first = order.isEmpty ? null : rects[order.first]!;
      final layout = StoryboardGroupLayout.fitting(
        list.length,
        ratio: first == null || first.isEmpty
            ? '16:9'
            : productionNearestRatio(first.width / first.height),
      );
      await _writeStoryboard(group, layout, {
        for (var i = 0; i < order.length; i++) order[i]: i,
      });
    }),
  );

  /// 普通组外框手动调整；不小于成员范围由界面按显示尺寸夹住。
  Future<void> resizeFree(
    String groupId,
    Rect frame, {
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'resizeFree',
    [groupId],
    () => write(groupId, () async {
      final group = await requireGroup(groupId);
      if (ProductionGroupLayout.fromStyle(group.style) is! FreeGroupLayout ||
          ![
            frame.left,
            frame.top,
            frame.width,
            frame.height,
          ].every((v) => v.isFinite) ||
          frame.width <= 0 ||
          frame.height <= 0) {
        throw const StoryboardException('invalid_config');
      }
      await db.canvasDao.updateActiveNodeFields(
        groupId,
        CanvasNodesCompanion(
          x: Value(frame.left),
          y: Value(frame.top),
          width: Value(frame.width),
          height: Value(frame.height),
        ),
      );
    }),
  );

  Future<void> rename(String groupId, String title, {CanvasHistory? history}) =>
      withCanvasHistory(
        history,
        shots,
        'rename',
        [groupId],
        () => write(groupId, () async {
          await requireGroup(groupId);
          await db.canvasDao.updateActiveNodeFields(
            groupId,
            CanvasNodesCompanion(title: Value(title.trim())),
          );
        }),
      );

  /// 删除分组节点（连同其连线）并清空成员 parent_id。分镜组先按 [toFree] 恢复尺寸重排，
  /// 避免紧凑格子恢复原尺寸后互相重叠。
  Future<void> ungroup(
    String groupId, {
    Map<String, Size> sizes = const {},
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'ungroup',
    [groupId],
    () => write(groupId, () async {
      final group = await requireGroup(groupId);
      if (ProductionGroupLayout.fromStyle(group.style)
          is StoryboardGroupLayout) {
        await toFree(groupId, sizes);
      }
      for (final member in await members(groupId)) {
        await db.canvasDao.updateActiveNodeFields(
          member.id,
          const CanvasNodesCompanion(parentId: Value(null)),
        );
      }
      await db.canvasDao.softDeleteNode(groupId);
    }),
  );

  /// 软删除全部成员，保留分组与布局。
  Future<void> clear(String groupId, {CanvasHistory? history}) =>
      withCanvasHistory(
        history,
        shots,
        'clear',
        [groupId],
        () => write(groupId, () async {
          await requireGroup(groupId);
          for (final member in await members(groupId)) {
            await _removeOne(member);
          }
        }),
      );

  /// 删除节点；删除分组时连同成员，删除成员只留下空格位。
  Future<void> remove(CanvasNode node, {CanvasHistory? history}) =>
      withCanvasHistory(
        history,
        shots,
        'remove',
        [node.id],
        () => write(node.id, () async {
          // 场次节点随剧本场次存在，不能从画布删除。
          if (node.type == canvasNodeTypeScene) {
            throw const StoryboardException('invalid_config');
          }
          if (node.type == canvasNodeTypeGroup) {
            for (final member in await members(node.id)) {
              await _removeOne(member);
            }
            await db.canvasDao.softDeleteNode(node.id);
            return;
          }
          await _removeOne(node);
        }),
      );

  /// 单个节点移到 (x, y)：分组带动成员，分镜组成员不能单独移动。
  Future<void> move(
    CanvasNode node,
    double x,
    double y, {
    CanvasHistory? history,
  }) => moveAll(node.canvasId, {node.id: (x: x, y: y)}, history: history);

  /// 一次事务内保存一组位置。分组移动时成员随之平移（分镜组按布局重算），
  /// 位置表里的这些成员以分组为准；单独改分镜组成员坐标被拒绝。
  Future<void> moveAll(
    String canvasId,
    Map<String, ({double x, double y})> positions, {
    CanvasHistory? history,
  }) => withCanvasHistory(
    history,
    shots,
    'moveAll',
    positions.keys,
    () => write(canvasId, () async {
      final nodes = <String, CanvasNode>{};
      for (final entry in positions.entries) {
        final node = await db.canvasDao.getNodeById(entry.key);
        final at = entry.value;
        if (node == null) {
          throw const StoryboardException('source_missing');
        }
        if (node.canvasId != canvasId || !at.x.isFinite || !at.y.isFinite) {
          throw const StoryboardException('invalid_config');
        }
        nodes[node.id] = node;
      }
      final handled = <String>{};
      for (final group in nodes.values.where(
        (n) => n.type == canvasNodeTypeGroup,
      )) {
        final at = positions[group.id]!;
        final delta = Offset(at.x - group.x, at.y - group.y);
        final layout = ProductionGroupLayout.fromStyle(group.style);
        for (final member in await members(group.id)) {
          handled.add(member.id);
          final to = switch (layout) {
            StoryboardGroupLayout() =>
              Offset(at.x, at.y) + layout.cellOffset(member.sortOrder),
            FreeGroupLayout() => Offset(member.x, member.y) + delta,
          };
          await _setPosition(member.id, to.dx, to.dy);
        }
        await _setPosition(group.id, at.x, at.y);
      }
      for (final node in nodes.values) {
        if (node.type == canvasNodeTypeGroup || handled.contains(node.id)) {
          continue;
        }
        final at = positions[node.id]!;
        if (await inStoryboard(node)) {
          if (at.x != node.x || at.y != node.y) {
            throw const StoryboardException('invalid_config');
          }
          continue;
        }
        await _setPosition(node.id, at.x, at.y);
      }
      await _syncScenes(canvasId, nodes, positions);
    }),
  );

  /// 场次节点与场内片段节点保持一致：只移动场次节点时，没一起提交的片段跟着平移；
  /// 只移动片段时，场次节点取场内片段节点最左、最上的坐标。[before] 是移动前的节点。
  Future<void> _syncScenes(
    String canvasId,
    Map<String, CanvasNode> before,
    Map<String, ({double x, double y})> positions,
  ) async {
    final current = await db.canvasDao.getNodesByCanvas(canvasId);
    final anchors = {for (final n in current) ?n.sceneId: n};
    if (anchors.isEmpty) {
      return;
    }
    final clips =
        await (db.select(db.productionClips)..where(
              (t) =>
                  t.id.isIn(current.map((n) => n.clipId).nonNulls) &
                  t.deletedAt.equals(notDeletedSentinel),
            ))
            .get();
    final sceneOfClip = {for (final c in clips) c.id: c.sceneId};
    Iterable<CanvasNode> members(String sceneId) =>
        current.where((n) => sceneOfClip[n.clipId] == sceneId);
    final movedScenes = <String>{};
    for (final anchor in before.values) {
      final sceneId = anchor.sceneId;
      if (sceneId == null) {
        continue;
      }
      movedScenes.add(sceneId);
      final at = positions[anchor.id]!;
      final dx = at.x - anchor.x, dy = at.y - anchor.y;
      for (final member in members(sceneId)) {
        if (!positions.containsKey(member.id)) {
          await _setPosition(member.id, member.x + dx, member.y + dy);
        }
      }
    }
    final touched = {
      for (final id in positions.keys)
        if (before[id]?.clipId case final clipId?) ?sceneOfClip[clipId],
    }.difference(movedScenes);
    for (final sceneId in touched) {
      final anchor = anchors[sceneId];
      final group = members(sceneId);
      if (anchor == null || group.isEmpty) {
        continue;
      }
      await _setPosition(
        anchor.id,
        group.map((n) => n.x).reduce(math.min),
        group.map((n) => n.y).reduce(math.min),
      );
    }
  }

  StoryboardGroupLayout _storyboard(CanvasNode group) {
    final layout = ProductionGroupLayout.fromStyle(group.style);
    if (layout is! StoryboardGroupLayout) {
      throw const StoryboardException('invalid_config');
    }
    return layout;
  }

  /// 写布局、成员格位与坐标、外框尺寸；格位必须在容量内且不重复。
  Future<void> _writeStoryboard(
    CanvasNode group,
    StoryboardGroupLayout layout,
    Map<String, int> slots,
  ) async {
    if (slots.values.toSet().length != slots.length ||
        slots.values.any((s) => s < 0 || s >= layout.capacity)) {
      throw const StoryboardException('invalid_config');
    }
    final origin = Offset(group.x, group.y);
    for (final entry in slots.entries) {
      final at = origin + layout.cellOffset(entry.value);
      await db.canvasDao.updateActiveNodeFields(
        entry.key,
        CanvasNodesCompanion(
          sortOrder: Value(entry.value),
          x: Value(at.dx),
          y: Value(at.dy),
        ),
      );
    }
    final size = layout.frameSize;
    await db.canvasDao.updateActiveNodeFields(
      group.id,
      CanvasNodesCompanion(
        style: Value(layout.writeTo(group.style)),
        width: Value(size.width),
        height: Value(size.height),
      ),
    );
  }

  Future<void> _requireAttachable(String id, String canvasId) async {
    final node = await db.canvasDao.getNodeById(id);
    if (node == null) {
      throw const StoryboardException('source_missing');
    }
    if (node.canvasId != canvasId ||
        !isProductionGroupMemberType(node) ||
        await groupOf(node) != null) {
      throw const StoryboardException('invalid_config');
    }
  }

  Future<void> _setPosition(String id, double x, double y) =>
      db.canvasDao.updateActiveNodeFields(
        id,
        CanvasNodesCompanion(x: Value(x), y: Value(y)),
      );

  Future<void> _removeTextInputs(String nodeId) async {
    final clips = await (db.select(
      db.productionClips,
    )..where((t) => t.deletedAt.equals(notDeletedSentinel))).get();
    for (final clip in clips) {
      final removed = clip.inputs
          .where((input) => input.isPrompt && input.sourceNodeId == nodeId)
          .map((input) => input.id)
          .toSet();
      if (removed.isEmpty) {
        continue;
      }
      final prompt = StoryboardPrompt.parse(clip.prompt).parts
          .where((part) => !part.isReference || !removed.contains(part.inputId))
          .map((part) => part.text)
          .join();
      await (db.update(
        db.productionClips,
      )..where((t) => t.id.equals(clip.id))).write(
        ProductionClipsCompanion(
          inputs: Value(
            clip.inputs.where((input) => !removed.contains(input.id)).toList(),
          ),
          prompt: Value(prompt),
          updatedAt: Value(DateTime.now()),
        ),
      );
      recordCanvasPromptCleanup(
        shots,
        clip.id,
        before: clip.prompt,
        after: prompt,
      );
    }
  }

  Future<void> _removeOne(CanvasNode node) async {
    if (node.clipId != null) {
      await shots.softDelete(node.clipId!);
    } else {
      if (node.type == canvasNodeTypeText) {
        await _removeTextInputs(node.id);
      }
      if (node.type == canvasNodeTypeEditing && node.editingId != null) {
        await db.editingDao.softDelete(node.editingId!);
      }
      await db.canvasDao.softDeleteNode(node.id);
    }
  }
}

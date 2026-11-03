// 职责: 小说工作区持久化状态 — 定义版本化选择与树节点展开快照及资源失效修复。
// 关联文件:
//   lib/shared/models/novel_workspace.dart
//   lib/shared/models/screenplay_workspace_state.dart
//   lib/shared/providers/novel_workspace_state_provider.dart

import '../app_config.dart';

import 'novel_workspace.dart';

class NovelWorkspaceStateData {
  NovelWorkspaceStateData({
    required this.selection,
    required this.isHydrated,
    Map<NovelWorkspaceSection, Set<String>> expandedNodeIdsBySection =
        const <NovelWorkspaceSection, Set<String>>{},
  }) : _expandedNodeIdsBySection = Map.unmodifiable({
         for (final entry in expandedNodeIdsBySection.entries)
           if (entry.value.isNotEmpty)
             entry.key: Set<String>.unmodifiable(entry.value),
       });

  factory NovelWorkspaceStateData.initial() {
    return NovelWorkspaceStateData(
      selection: const WorkspaceSelection.overview(),
      isHydrated: false,
    );
  }

  factory NovelWorkspaceStateData.fromJson(Map<String, dynamic> json) {
    final selectionJson = json['selection'];
    final decodedSelection = selectionJson is Map
        ? _selectionFromJson(Map<String, dynamic>.from(selectionJson))
        : const WorkspaceSelection.overview();
    final expandedNodesJson = json['expandedNodes'];
    final expandedNodes = <NovelWorkspaceSection, Set<String>>{};
    if (expandedNodesJson is Map) {
      for (final entry in expandedNodesJson.entries) {
        final section = _sectionFromName(entry.key);
        final value = entry.value;
        if (section == null || value is! List) {
          continue;
        }
        final ids = value
            .whereType<String>()
            .map((id) => id.trim())
            .where((id) => id.isNotEmpty)
            .toSet();
        if (ids.isNotEmpty) {
          expandedNodes[section] = ids;
        }
      }
    }
    return NovelWorkspaceStateData(
      selection: decodedSelection,
      isHydrated: true,
      expandedNodeIdsBySection: expandedNodes,
    );
  }

  static const int currentVersion = 1;

  final WorkspaceSelection selection;
  final bool isHydrated;
  final Map<NovelWorkspaceSection, Set<String>> _expandedNodeIdsBySection;

  Set<String> expandedNodeIdsFor(NovelWorkspaceSection section) {
    return _expandedNodeIdsBySection[section] ?? const <String>{};
  }

  NovelWorkspaceStateData copyWith({
    WorkspaceSelection? selection,
    bool? isHydrated,
    Map<NovelWorkspaceSection, Set<String>>? expandedNodeIdsBySection,
  }) {
    return NovelWorkspaceStateData(
      selection: selection ?? this.selection,
      isHydrated: isHydrated ?? this.isHydrated,
      expandedNodeIdsBySection:
          expandedNodeIdsBySection ?? _expandedNodeIdsBySection,
    );
  }

  NovelWorkspaceStateData copyWithExpandedNodeIds(
    NovelWorkspaceSection section,
    Set<String> nodeIds,
  ) {
    final next = <NovelWorkspaceSection, Set<String>>{
      ..._expandedNodeIdsBySection,
    };
    if (nodeIds.isEmpty) {
      next.remove(section);
    } else {
      next[section] = nodeIds;
    }
    return copyWith(expandedNodeIdsBySection: next);
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'version': currentVersion,
      'selection': <String, dynamic>{
        'section': selection.section.name,
        if (selection.itemId != null) 'itemId': selection.itemId,
        if (selection.isViewingAllOutlines)
          'isViewingAllOutlines': selection.isViewingAllOutlines,
      },
      'expandedNodes': <String, dynamic>{
        for (final entry in _expandedNodeIdsBySection.entries)
          entry.key.name: entry.value.toList()..sort(),
      },
    };
  }
}

WorkspaceSelection reconcileWorkspaceSelection({
  required WorkspaceSelection selection,
  required Iterable<String> availableItemIds,
  bool selectFirstWhenMissing = false,
}) {
  if (selection.isCreating) {
    return selection;
  }
  final ids = availableItemIds.toList(growable: false);
  final selectedItemId = selection.itemId;
  if (selectedItemId != null && ids.contains(selectedItemId)) {
    return selection;
  }
  if (selectedItemId == null && !selectFirstWhenMissing) {
    return selection;
  }
  final fallbackItemId = selectFirstWhenMissing && ids.isNotEmpty
      ? ids.first
      : null;
  return WorkspaceSelection(
    section: selection.section,
    itemId: fallbackItemId,
    isViewingAllOutlines: selection.isViewingAllOutlines,
  );
}

/// 把通用工作区选择中的剧本资源 ID 对齐到剧本工作区的当前季集状态。
///
/// 大纲以集 ID 寻址；剧本正文和场次以当前场次 ID 寻址；分镜选择在切集时清除。
WorkspaceSelection reconcileScreenplayWorkspaceSelection({
  required WorkspaceSelection selection,
  required String? previousEpisodeId,
  required String? episodeId,
  required String? sceneId,
}) {
  final String? itemId;
  switch (selection.section) {
    case NovelWorkspaceSection.screenplay_outline:
      itemId = episodeId;
    case NovelWorkspaceSection.screenplay_script:
    case NovelWorkspaceSection.screenplay_scenes:
      itemId = sceneId;
    case NovelWorkspaceSection.storyboard:
      itemId = previousEpisodeId == episodeId ? selection.itemId : null;
    default:
      return selection;
  }
  if (selection.itemId == itemId) {
    return selection;
  }
  return WorkspaceSelection(
    section: selection.section,
    itemId: itemId,
    isViewingAllOutlines: selection.isViewingAllOutlines,
  );
}

WorkspaceSelection _selectionFromJson(Map<String, dynamic> json) {
  final section = _sectionFromName(json['section']);
  if (section == null ||
      (!ideationCanvasEnabled && section == NovelWorkspaceSection.canvas)) {
    return const WorkspaceSelection.overview();
  }
  final rawItemId = json['itemId'];
  final itemId = rawItemId is String && rawItemId.trim().isNotEmpty
      ? rawItemId.trim()
      : null;
  return WorkspaceSelection(
    section: section,
    itemId: itemId,
    isViewingAllOutlines: json['isViewingAllOutlines'] == true,
  );
}

NovelWorkspaceSection? _sectionFromName(Object? value) {
  if (value is! String) {
    return null;
  }
  for (final section in NovelWorkspaceSection.values) {
    if (section.name == value) {
      return section;
    }
  }
  return null;
}

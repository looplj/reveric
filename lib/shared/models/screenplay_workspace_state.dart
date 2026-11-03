// 职责: 定义剧本工作区的版本化本机选择快照与父子层级失效修复。
// 关联文件:
//   lib/shared/providers/screenplay_workspace_state_provider.dart
//   lib/shared/models/screenplay.dart

enum ScreenplayWorkspaceSection {
  overview,
  script,
  outline,
  scenes,
  characters,
  foreshadowings,
  lore,
  items,
  factions,
  creatures,
  skills,
  maps,
  materials,
  entity_graph,
  story_progress,
}

class ScreenplayWorkspaceState {
  const ScreenplayWorkspaceState({
    required this.section,
    required this.isHydrated,
    this.seasonId,
    this.episodeId,
    this.sceneId,
  });

  factory ScreenplayWorkspaceState.initial() {
    return const ScreenplayWorkspaceState(
      section: ScreenplayWorkspaceSection.overview,
      isHydrated: false,
    );
  }

  factory ScreenplayWorkspaceState.fromJson(Map<String, dynamic> json) {
    return ScreenplayWorkspaceState(
      section: _sectionFromName(json['section']),
      seasonId: _nonEmptyString(json['seasonId']),
      episodeId: _nonEmptyString(json['episodeId']),
      sceneId: _nonEmptyString(json['sceneId']),
      isHydrated: true,
    );
  }

  static const int currentVersion = 1;

  final ScreenplayWorkspaceSection section;
  final String? seasonId;
  final String? episodeId;
  final String? sceneId;
  final bool isHydrated;

  ScreenplayWorkspaceState copyWith({
    ScreenplayWorkspaceSection? section,
    String? seasonId,
    bool clearSeasonId = false,
    String? episodeId,
    bool clearEpisodeId = false,
    String? sceneId,
    bool clearSceneId = false,
    bool? isHydrated,
  }) {
    return ScreenplayWorkspaceState(
      section: section ?? this.section,
      seasonId: clearSeasonId ? null : seasonId ?? this.seasonId,
      episodeId: clearEpisodeId ? null : episodeId ?? this.episodeId,
      sceneId: clearSceneId ? null : sceneId ?? this.sceneId,
      isHydrated: isHydrated ?? this.isHydrated,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'version': currentVersion,
      'section': section.name,
      if (seasonId != null) 'seasonId': seasonId,
      if (episodeId != null) 'episodeId': episodeId,
      if (sceneId != null) 'sceneId': sceneId,
    };
  }
}

ScreenplayWorkspaceState reconcileScreenplayWorkspaceState({
  required ScreenplayWorkspaceState state,
  required List<String> seasonIds,
  required Map<String, List<String>> episodeIdsBySeason,
  required Map<String, List<String>> sceneIdsByEpisode,
  int? preferredSeasonIndex,
}) {
  if (seasonIds.isEmpty) {
    return state.copyWith(
      clearSeasonId: true,
      clearEpisodeId: true,
      clearSceneId: true,
      isHydrated: true,
    );
  }
  final seasonId = seasonIds.contains(state.seasonId)
      ? state.seasonId!
      : seasonIds[(preferredSeasonIndex ?? 0).clamp(0, seasonIds.length - 1)];
  final episodeIds = episodeIdsBySeason[seasonId] ?? const <String>[];
  final episodeId = episodeIds.contains(state.episodeId)
      ? state.episodeId
      : episodeIds.firstOrNull;
  final sceneIds = episodeId == null
      ? const <String>[]
      : sceneIdsByEpisode[episodeId] ?? const <String>[];
  final sceneId = sceneIds.contains(state.sceneId)
      ? state.sceneId
      : sceneIds.firstOrNull;
  return ScreenplayWorkspaceState(
    section: state.section,
    seasonId: seasonId,
    episodeId: episodeId,
    sceneId: sceneId,
    isHydrated: true,
  );
}

ScreenplayWorkspaceSection _sectionFromName(Object? value) {
  if (value is String) {
    for (final section in ScreenplayWorkspaceSection.values) {
      if (section.name == value) {
        return section;
      }
    }
  }
  return ScreenplayWorkspaceSection.overview;
}

String? _nonEmptyString(Object? value) {
  return value is String && value.trim().isNotEmpty ? value.trim() : null;
}

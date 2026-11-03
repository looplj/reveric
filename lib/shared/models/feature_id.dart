// 职责: 稳定功能标识符枚举 — 用于 feature 元数据映射与发现横幅
// 关联文件:
//   lib/shared/heuristic/feature_metadata.dart
//   lib/shared/models/novel_workspace.dart
//   lib/shared/models/ai_session_mode.dart
// 遵循的 Rules:
//   .agents/rules/form.md

import 'ai_session_mode.dart';
import 'novel_workspace.dart';

/// 功能标识符 — 用于 feature usage 追踪、场景启发式判断、发现推荐。
///
/// 枚举值使用 snake_case，因为代表功能分类（非表单字段）。
enum FeatureId {
  overview,
  chapters,
  novel_description,
  outlines,
  characters,
  worldbuilding,
  maps,
  materials,
  foreshadowings,
  factions,
  creatures,
  items,
  skills,
  entity_graph,
  ai_chat,
  ai_council,
  ai_monologue,
  ai_theater,
  ai_roleplay,
  ai_cover_studio,
  ai_style_polish,
  ai_review,
  agent_profile,
  sub_agent,
}

extension FeatureIdX on FeatureId {
  String get storageKey => name;

  static FeatureId? fromStorageKey(String key) {
    for (final f in FeatureId.values) {
      if (f.name == key) return f;
    }
    return null;
  }
}

extension NovelWorkspaceSectionFeatureIdX on NovelWorkspaceSection {
  /// 映射到对应的 [FeatureId]。若没有对应项则返回 null。
  FeatureId? get featureId => switch (this) {
    NovelWorkspaceSection.overview => FeatureId.overview,
    NovelWorkspaceSection.chapters => FeatureId.chapters,
    NovelWorkspaceSection.novel_description => FeatureId.novel_description,
    NovelWorkspaceSection.outlines => FeatureId.outlines,
    NovelWorkspaceSection.characters => FeatureId.characters,
    NovelWorkspaceSection.lore => FeatureId.worldbuilding,
    NovelWorkspaceSection.maps => FeatureId.maps,
    NovelWorkspaceSection.materials => FeatureId.materials,
    NovelWorkspaceSection.foreshadowings => FeatureId.foreshadowings,
    NovelWorkspaceSection.factions => FeatureId.factions,
    NovelWorkspaceSection.creatures => FeatureId.creatures,
    NovelWorkspaceSection.items => FeatureId.items,
    NovelWorkspaceSection.skills => FeatureId.skills,
    NovelWorkspaceSection.entity_graph => FeatureId.entity_graph,
    // 当前进展是快照的只读视图，不单独做 feature 追踪与发现推荐。
    NovelWorkspaceSection.story_progress => null,
    NovelWorkspaceSection.canvas => null,
    NovelWorkspaceSection.screenplay_script ||
    NovelWorkspaceSection.screenplay_outline ||
    NovelWorkspaceSection.storyboard ||
    NovelWorkspaceSection.screenplay_scenes => null,
  };
}

extension AiSessionModeFeatureIdX on AiSessionMode {
  /// 映射到对应的 [FeatureId]。
  FeatureId get featureId => switch (this) {
    AiSessionMode.chat => FeatureId.ai_chat,
    AiSessionMode.council => FeatureId.ai_council,
    AiSessionMode.monologue => FeatureId.ai_monologue,
    AiSessionMode.theater => FeatureId.ai_theater,
    AiSessionMode.roleplay => FeatureId.ai_roleplay,
  };
}

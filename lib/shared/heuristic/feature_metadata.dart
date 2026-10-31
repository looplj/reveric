// 职责: FeatureId → (名称 locale key, 描述 locale key) 映射 — 供发现横幅渲染使用
// 关联文件:
//   lib/shared/models/feature_id.dart
//   lib/shared/localization/locale_keys.dart
//   lib/desktop/widgets/heuristic/discovery_banner.dart
import '../localization/locale_keys.dart';
import '../models/feature_id.dart';

final class FeatureMetadata {
  const FeatureMetadata({required this.nameKey, required this.descriptionKey});

  final String nameKey;
  final String descriptionKey;
}

final Map<FeatureId, FeatureMetadata> featureMetadata = {
  FeatureId.overview: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureOverview,
    descriptionKey: LocaleKeys.heuristicFeatureOverviewDesc,
  ),
  FeatureId.chapters: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureChapters,
    descriptionKey: LocaleKeys.heuristicFeatureChaptersDesc,
  ),
  FeatureId.novel_description: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureNovelDescription,
    descriptionKey: LocaleKeys.heuristicFeatureNovelDescriptionDesc,
  ),
  FeatureId.outlines: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureOutlines,
    descriptionKey: LocaleKeys.heuristicFeatureOutlinesDesc,
  ),
  FeatureId.characters: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureCharacters,
    descriptionKey: LocaleKeys.heuristicFeatureCharactersDesc,
  ),
  FeatureId.worldbuilding: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureWorldbuilding,
    descriptionKey: LocaleKeys.heuristicFeatureWorldbuildingDesc,
  ),
  FeatureId.maps: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureMaps,
    descriptionKey: LocaleKeys.heuristicFeatureMapsDesc,
  ),
  FeatureId.materials: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureMaterials,
    descriptionKey: LocaleKeys.heuristicFeatureMaterialsDesc,
  ),
  FeatureId.foreshadowings: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureForeshadowings,
    descriptionKey: LocaleKeys.heuristicFeatureForeshadowingsDesc,
  ),
  FeatureId.factions: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureFactions,
    descriptionKey: LocaleKeys.heuristicFeatureFactionsDesc,
  ),
  FeatureId.creatures: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureCreatures,
    descriptionKey: LocaleKeys.heuristicFeatureCreaturesDesc,
  ),
  FeatureId.items: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureItems,
    descriptionKey: LocaleKeys.heuristicFeatureItemsDesc,
  ),
  FeatureId.skills: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureSkills,
    descriptionKey: LocaleKeys.heuristicFeatureSkillsDesc,
  ),
  FeatureId.entity_graph: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureEntityGraph,
    descriptionKey: LocaleKeys.heuristicFeatureEntityGraphDesc,
  ),
  FeatureId.ai_chat: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureAiChat,
    descriptionKey: LocaleKeys.heuristicFeatureAiChatDesc,
  ),
  FeatureId.ai_council: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureAiCouncil,
    descriptionKey: LocaleKeys.heuristicFeatureAiCouncilDesc,
  ),
  FeatureId.ai_monologue: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureAiMonologue,
    descriptionKey: LocaleKeys.heuristicFeatureAiMonologueDesc,
  ),
  FeatureId.ai_theater: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureAiTheater,
    descriptionKey: LocaleKeys.heuristicFeatureAiTheaterDesc,
  ),
  FeatureId.ai_roleplay: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureAiRoleplay,
    descriptionKey: LocaleKeys.heuristicFeatureAiRoleplayDesc,
  ),
  FeatureId.ai_cover_studio: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureAiCoverStudio,
    descriptionKey: LocaleKeys.heuristicFeatureAiCoverStudioDesc,
  ),
  FeatureId.ai_style_polish: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureAiStylePolish,
    descriptionKey: LocaleKeys.heuristicFeatureAiStylePolishDesc,
  ),
  FeatureId.ai_review: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureAiReview,
    descriptionKey: LocaleKeys.heuristicFeatureAiReviewDesc,
  ),
  FeatureId.agent_profile: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureAgentProfile,
    descriptionKey: LocaleKeys.heuristicFeatureAgentProfileDesc,
  ),
  FeatureId.sub_agent: const FeatureMetadata(
    nameKey: LocaleKeys.heuristicFeatureSubAgent,
    descriptionKey: LocaleKeys.heuristicFeatureSubAgentDesc,
  ),
};

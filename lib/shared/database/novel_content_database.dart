// 职责: 定义作品内容数据库并创建当前表结构、索引与章节视图。
// 关联文件:
//   lib/shared/database/novel_content_database_indexes.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/services/documents_service.dart
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_read.dart
//   lib/shared/services/ai/tools_write.dart
//   lib/shared/services/ai/tools_create.dart
//   lib/shared/services/ai/tools_edit.dart
//   lib/shared/widgets/ai/tools/tool_card_descriptor.dart
//   lib/desktop/widgets/ai/diff/pending_changes_detail_dialog.dart
//   lib/shared/widgets/ai/diff/recent_changes_log.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/history.json
//   assets/translations/zh-CN/history.json
//   lib/shared/providers/novel_providers.dart
//   lib/shared/logger/startup_failure_reporter.dart
// 遵循的 Rules:
//   .agents/rules/json.md
//   .agents/rules/db-migration.md
// ⚠️ 修改此文件后必须运行 `make codegen`，否则 .drift.dart / .g.dart 不会更新
// ⚠️ 新增字段时需要同步更新：DB → service → AI tools（schema/read/write/create/edit） → tool card i18n（fieldLabel/translation）
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:meta/meta.dart';

import 'type_converters.dart';
import '../models/character_voice.dart';
export '../models/character_voice.dart';
export 'app_database.dart' show notDeletedSentinel;
export '../models/chapter.dart' show Chapter;
export '../models/entity_relation_history.dart' show RelationSummary;
export '../models/character_behavior_tag.dart' show CharacterBehaviorTag;
export '../models/subject_photo.dart' show SubjectPhoto;
import '../models/subject_photo.dart';
import '../models/ai_message_block.dart';
import '../models/chapter_comment.dart';
import '../models/character_behavior_tag.dart';
import '../models/content_status.dart';
import '../models/outline_draft.dart';
import '../models/entity_relation_history.dart';
import '../models/screenplay.dart';
import '../models/editing/document.dart';
import '../models/production/input.dart';
import '../logger/app_logger.dart';
import '../logger/startup_failure_reporter.dart';
import '../utils/short_entity_id.dart';
import '../utils/short_entity_id_allocator.dart';
import '../utils/storage_paths.dart';
import '../utils/windows_safe_path.dart';
import 'novel_content_daos/agent_rule_dao.dart';
import 'novel_content_daos/ai_chat_message_dao.dart';
import 'novel_content_daos/canvas_dao.dart';
import 'novel_content_daos/change_commit_dao.dart';
import 'novel_content_daos/chapter_dao.dart';
import 'novel_content_daos/character_profile_dao.dart';
import 'novel_content_daos/document_dao.dart';
import 'novel_content_daos/foreshadowing_dao.dart';
import 'novel_content_daos/item_dao.dart';
import 'novel_content_daos/location_dao.dart';
import 'novel_content_daos/novel_state_dao.dart';
import 'novel_content_daos/novel_state_snapshot_dao.dart';
import 'novel_content_daos/outline_dao.dart';
import 'novel_content_daos/screenplay_dao.dart';
import 'novel_content_daos/editing_dao.dart';
import 'novel_content_daos/working_change_dao.dart';
import 'novel_content_database_indexes.dart';

part 'novel_content_database.drift.dart';

const String characterRoleProtagonist = 'protagonist';
const String characterRoleAntagonist = 'antagonist';
const String characterRoleSupporting = 'supporting';
const String characterRoleMinor = 'minor';
const String characterGenderMale = 'male';
const String characterGenderFemale = 'female';
const String characterGenderNonBinary = 'non_binary';
const String characterGenderOther = 'other';
const String characterGenderUnknown = 'unknown';

const String chapterEmbeddingSyncStatusPending = 'pending';
const String novelStateStatusIdle = 'idle';
const String novelStateStatusRunning = 'running';
const String novelStateStatusPaused = 'paused';
const String novelStateStatusError = 'error';
const String nodeTypeVolume = 'volume';
const String nodeTypeChapter = 'chapter';
const String nodeTypeExtra = 'extra';
const List<String> nodeTypes = <String>[
  nodeTypeVolume,
  nodeTypeChapter,
  nodeTypeExtra,
];

const String chapterStatDraft = 'draft';
const String chapterStatPublished = 'published';
const String novelStateSnapshotStatusActive = 'active';
const String novelStateSnapshotStatusSuperseded = 'superseded';
const String novelStateSnapshotCreatedByChronicler = 'chronicler';
const String novelStateSnapshotCreatedByUser = 'user';

const String foreshadowingStatusPending = 'pending';
const String foreshadowingStatusPlanted = 'planted';
const String foreshadowingStatusPayoff = 'payoff';
const String foreshadowingStatusAbandoned = 'abandoned';

const List<String> foreshadowingStatuses = <String>[
  foreshadowingStatusPending,
  foreshadowingStatusPlanted,
  foreshadowingStatusPayoff,
  foreshadowingStatusAbandoned,
];

const String documentTypeLore = 'lore';
const String documentTypeMaterial = 'material';

const List<String> documentTypes = <String>[
  documentTypeLore,
  documentTypeMaterial,
];

const String documentStatusActive = 'active';
const String documentStatusArchived = 'archived';

const List<String> documentStatuses = <String>[
  documentStatusActive,
  documentStatusArchived,
];

const String entityTypeCharacter = 'character';
const String entityTypeFaction = 'faction';
const String entityTypeSkill = 'skill';
const String entityTypeItem = 'item';
const String entityTypeLocation = 'location';
const String entityTypeChapter = 'chapter';
const String entityTypeForeshadowing = 'foreshadowing';
const String entityTypeCreature = 'creature';

const List<String> entityTypes = <String>[
  entityTypeCharacter,
  entityTypeFaction,
  entityTypeSkill,
  entityTypeItem,
  entityTypeLocation,
  entityTypeChapter,
  entityTypeForeshadowing,
  entityTypeCreature,
];

// Canvas 节点引用型资源类型 — 复用 [entityTypes] 单数形式 + outline/document。
const String canvasNodeRefTypeOutline = 'outline';
const String canvasNodeRefTypeDocument = 'document';
const String canvasNodeRefTypeScreenplayScene = 'screenplay_scene';

/// 画布引用型节点可指向的资源类型集合；场次不参与通用实体关系图。
const List<String> canvasNodeRefTypes = <String>[
  ...entityTypes,
  canvasNodeRefTypeOutline,
  canvasNodeRefTypeDocument,
  canvasNodeRefTypeScreenplayScene,
];

// Canvas 节点类型
const String canvasNodeTypeReference = 'reference';
const String canvasNodeTypeSticky = 'sticky';

const List<String> canvasNodeTypes = <String>[
  canvasNodeTypeReference,
  canvasNodeTypeSticky,
];

// Canvas 边类型 — 视觉组织,不进入 entity_graph 业务关系。
const String canvasEdgeTypeRelationship = 'relationship'; // 人物关系
const String canvasEdgeTypeCausal = 'causal'; // 因果
const String canvasEdgeTypeTimeline = 'timeline'; // 时间线
const String canvasEdgeTypeForeshadowPayoff = 'foreshadow_payoff'; // 伏笔兑现
const String canvasEdgeTypeAssociation = 'association'; // 通用关联

const List<String> canvasEdgeTypes = <String>[
  canvasEdgeTypeRelationship,
  canvasEdgeTypeCausal,
  canvasEdgeTypeTimeline,
  canvasEdgeTypeForeshadowPayoff,
  canvasEdgeTypeAssociation,
];

// Canvas 用途：用户构思画布与剧集制作画布。
const String canvasKindUser = 'user';
const String canvasKindProduction = 'production';
const String canvasNodeTypeVideo = 'video';
const String canvasNodeTypeImage = 'image';
const String canvasNodeTypeAudio = 'audio';
const String canvasNodeTypeMedia = 'media';
const String canvasNodeTypeStaging = 'staging';
// 制作画布分组；成员用 parent_id 指向它，布局参数在 style.group。
const String canvasNodeTypeGroup = 'group';
const String canvasNodeTypeText = 'text';
const String canvasNodeTypeEditing = 'editing';
// 制作画布场次：每场一个，refType 为 screenplay_scene，x / y 是场次框内第一张卡片的左上角。
// 场内片段由 production_clips.scene_id 决定并按成片顺序排在它下方，不用 parent_id 挂靠。
const String canvasNodeTypeScene = 'scene';
// 制作画布节点用 refType/refId 指向内容；不进构思画布的 [canvasNodeRefTypes]。
const String canvasNodeRefTypeProductionClip = 'production_clip';
const String canvasNodeRefTypeAsset = 'asset';
const String canvasNodeRefTypeStaging = 'staging';
const String canvasNodeRefTypeEditing = 'editing';
const String canvasEdgeTypeInput = 'generation_input';
// 导演台节点到它导出结果节点的连线，只由导出生成。
const String canvasEdgeTypeStagingOutput = 'staging_output';
// 来源节点到它本地派生产物的连线：视频处理的帧、音轨、处理后视频，宫格切分的分组，分组拼接图。
const String canvasEdgeTypeDerivedOutput = 'derived_output';

/// 制作画布节点按 refType 解出所指内容的 id。
extension ProductionCanvasNodeRef on CanvasNode {
  bool get isGenerationNode =>
      type == canvasNodeTypeVideo ||
      type == canvasNodeTypeImage ||
      type == canvasNodeTypeAudio;
  String? get clipId =>
      refType == canvasNodeRefTypeProductionClip ? refId : null;
  String? get mediaAssetId => refType == canvasNodeRefTypeAsset ? refId : null;
  String? get stagingId => refType == canvasNodeRefTypeStaging ? refId : null;
  String? get editingId => refType == canvasNodeRefTypeEditing ? refId : null;
  String? get sceneId => type == canvasNodeTypeScene ? refId : null;
}

const List<String> canvasKinds = <String>[canvasKindUser];

// 关联文件: lib/shared/services/ai/tools_graph.dart
//   assets/bundled_skills/story-continuity/references/relations.md
// 修改关系类型或支持的实体对时，需要同步更新 _validRelationTypesFor，以及关系图谱
// 指南 skill 的合法类型全表与方向表（bundled_control_skills_test.dart 的 drift 用例
// 会把漏改变成测试失败）。
//
// 方向约定：`A --type--> B` 读作「A 是 B 的 <type>」，即类型名描述 **source** 的身份。
// 三类偏离单独标注在行尾：
//   1. 历史例外 —— subordinate / alter_ego 反过来描述 target（改动会重解释存量数据）。
//   2. 动词短语 —— evolves_to / learned / mastering / mastered 按字面读，source 是主语。
//   3. 对称 —— 两端可互换，建一条即可，标 [对称]。
// character → character
const String characterRelationFamily = 'family'; // 泛亲属/血缘 [对称]
const String characterRelationParent = 'parent'; // 父母（A 是 B 的父母）
const String characterRelationSibling = 'sibling'; // 兄弟姐妹 [对称]
const String characterRelationGrandparent = 'grandparent'; // 祖辈（A 是 B 的祖辈）
const String characterRelationFriend = 'friend'; // 朋友 [对称]
const String characterRelationEnemy = 'enemy'; // 敌人 [对称]
const String characterRelationLover = 'lover'; // 恋人 [对称]
const String characterRelationMasterDisciple =
    'master_disciple'; // 师徒（A 是 B 的师父）
const String characterRelationColleague = 'colleague'; // 同事 [对称]
// 例外 1：类型名描述 target。读作「B 是 A 的下属」。
const String characterRelationSubordinate = 'subordinate'; // 下属（A 是上级）
// 例外 1：类型名描述 target。读作「B 是 A 的化身」。
const String characterRelationAlterEgo =
    'alter_ego'; // 另一身份/马甲/化身（A 是本体或主要叙事身份）

// character → faction（角色恒为 source，方向由实体类型确定）
const String characterFactionMember = 'member'; // 成员（A 是 B 的成员）
const String characterFactionLeader = 'leader'; // 首领（A 是 B 的首领）
const String characterFactionFounder = 'founder'; // 创始人（A 是 B 的创始人）
const String characterFactionAlly = 'ally'; // 盟友（A 是 B 的盟友）
const String characterFactionEnemy = 'enemy'; // 敌人（A 是 B 的敌人）

// character → skill（角色恒为 source）
const String characterSkillLearned = 'learned'; // 已学会（A 已学会 B）
const String characterSkillMastering = 'mastering'; // 学习中（A 正在学 B）
const String characterSkillMastered = 'mastered'; // 已精通（A 已精通 B）
const String characterSkillCreator = 'creator'; // 创造者（A 是 B 的创造者）

// character → item（角色恒为 source）
const String characterItemOwner = 'owner'; // 持有者（A 是 B 的持有者）
const String characterItemUser = 'user'; // 使用者（A 是 B 的使用者）
const String characterItemCreator = 'creator'; // 创造者（A 是 B 的制造者）
const String characterItemFormerOwner = 'former_owner'; // 前持有者（A 是 B 的前持有者）

// faction → faction
const String factionFactionAlly = 'ally'; // 盟友 [对称]
const String factionFactionEnemy = 'enemy'; // 敌人 [对称]
// 例外 1：与 characterRelationSubordinate 同义，类型名描述 target。
const String factionFactionSubordinate = 'subordinate'; // 下属组织（A 是上级组织）

// skill → skill
const String skillSkillPrerequisite = 'prerequisite'; // 前置技能（A 是 B 的前置技能）
const String skillSkillEvolvesTo = 'evolves_to'; // 进化为（A 进化为 B）
const String skillSkillBranch = 'branch'; // 分支（A 是 B 的分支流派）

// item → item
const String itemItemPartOf = 'part_of'; // 组成部分（A 是 B 的组成部分）
const String itemItemEvolvesTo = 'evolves_to'; // 进化为（A 进化为 B）

// creature → creature
const String creatureCreatureEvolvesTo = 'evolves_to'; // 进化为（A 进化为 B）
const String creatureCreaturePrey = 'prey'; // 猎物（A 是 B 的猎物，B 捕食 A）
const String creatureCreaturePredator = 'predator'; // 天敌（A 是 B 的天敌，A 捕食 B）

const List<String> creatureRelationTypes = <String>[
  creatureCreatureEvolvesTo,
  creatureCreaturePrey,
  creatureCreaturePredator,
];

const String locationTypeGeneric = 'generic';
const String locationTypeWorld = 'world';
const String locationTypeContinent = 'continent';
const String locationTypeCountry = 'country';
const String locationTypeRegion = 'region';
const String locationTypeMountain = 'mountain';
const String locationTypePlain = 'plain';
const String locationTypeForest = 'forest';
const String locationTypeRiver = 'river';
const String locationTypeLake = 'lake';
const String locationTypeSea = 'sea';
const String locationTypeIsland = 'island';
const String locationTypeCity = 'city';
const String locationTypeDistrict = 'district';
const String locationTypeVillage = 'village';
const String locationTypeBuilding = 'building';
const String locationTypeRoom = 'room';
const String locationTypeLandmark = 'landmark';
const String locationTypeCustom = 'custom';
const String locationTypeNatural = 'natural';

const List<String> locationTypes = <String>[
  locationTypeGeneric,
  locationTypeWorld,
  locationTypeContinent,
  locationTypeCountry,
  locationTypeRegion,
  locationTypeMountain,
  locationTypePlain,
  locationTypeForest,
  locationTypeRiver,
  locationTypeLake,
  locationTypeSea,
  locationTypeIsland,
  locationTypeCity,
  locationTypeDistrict,
  locationTypeVillage,
  locationTypeBuilding,
  locationTypeRoom,
  locationTypeLandmark,
  locationTypeCustom,
  locationTypeNatural,
];

const String locationStatusActive = 'active';
const String locationStatusArchived = 'archived';

const List<String> locationStatuses = <String>[
  locationStatusActive,
  locationStatusArchived,
];

const String mapTypeWorld = 'world';
const String mapTypeRegion = 'region';
const String mapTypeCity = 'city';
const String mapTypeBuilding = 'building';
const String mapTypeDungeon = 'dungeon';

const List<String> mapTypes = <String>[
  mapTypeWorld,
  mapTypeRegion,
  mapTypeCity,
  mapTypeBuilding,
  mapTypeDungeon,
];

const List<String> characterRelationTypes = <String>[
  characterRelationFamily,
  characterRelationParent,
  characterRelationSibling,
  characterRelationGrandparent,
  characterRelationFriend,
  characterRelationEnemy,
  characterRelationLover,
  characterRelationMasterDisciple,
  characterRelationColleague,
  characterRelationSubordinate,
  characterRelationAlterEgo,
];

const List<String> characterFactionRelationTypes = <String>[
  characterFactionMember,
  characterFactionLeader,
  characterFactionFounder,
  characterFactionAlly,
  characterFactionEnemy,
];

const List<String> characterSkillRelationTypes = <String>[
  characterSkillLearned,
  characterSkillMastering,
  characterSkillMastered,
  characterSkillCreator,
];

const List<String> characterItemRelationTypes = <String>[
  characterItemOwner,
  characterItemUser,
  characterItemCreator,
  characterItemFormerOwner,
];

const List<String> factionRelationTypes = <String>[
  factionFactionAlly,
  factionFactionEnemy,
  factionFactionSubordinate,
];

const List<String> skillRelationTypes = <String>[
  skillSkillPrerequisite,
  skillSkillEvolvesTo,
  skillSkillBranch,
];

const List<String> itemRelationTypes = <String>[
  itemItemPartOf,
  itemItemEvolvesTo,
];

const List<String> characterRoles = <String>[
  characterRoleProtagonist,
  characterRoleAntagonist,
  characterRoleSupporting,
  characterRoleMinor,
];

const List<String> characterGenders = <String>[
  characterGenderMale,
  characterGenderFemale,
  characterGenderNonBinary,
  characterGenderOther,
  characterGenderUnknown,
];

class CharacterProfiles extends Table {
  TextColumn get id => text()();

  TextColumn get name => text()();

  TextColumn get role =>
      text().withDefault(const Constant(characterRoleSupporting))();

  TextColumn get gender =>
      text().withDefault(const Constant(characterGenderUnknown))();

  /// 可用于显示、检索和同一人物识别的曾用名、称号与昵称。
  TextColumn get aliases => text()
      .map(const StringListConverter())
      .withDefault(const Constant('[]'))();

  /// 供角色列表筛选与分组使用的自由标签，不承担剧情关系语义。
  TextColumn get tags => text()
      .map(const StringListConverter())
      .withDefault(const Constant('[]'))();

  /// 人物小传：记录人物设定、动机、关系和弧光等完整信息。
  /// 这是人物的「档案」，通常在创作初期设定，后续较少改动。
  TextColumn get biography => text().withDefault(const Constant(''))();

  /// 人物外观：体貌、发型发色、眼睛、服饰等稳定视觉特征。
  TextColumn get appearance => text().withDefault(const Constant(''))();

  /// 人物描述：声线、动作习惯、可观察气质和公众印象。
  /// 这是相对稳定的人物档案，不记录临时位置、伤势和知识状态。
  TextColumn get description => text().withDefault(const Constant(''))();

  /// 人物在最新剧情节点的位置、伤势、物品、能力、情绪、目标与知识边界。
  TextColumn get currentState => text().withDefault(const Constant(''))();

  /// 角色头像图片资产
  TextColumn get avatarAssetId => text().nullable()();

  /// 角色照片集，保存图片资产和名称。
  TextColumn get photos =>
      text().map(const SubjectPhotoListConverter()).nullable()();

  /// 角色跨集共用的参考音频及名称。
  TextColumn get voices =>
      text().map(const CharacterVoiceListConverter()).nullable()();

  /// 角色身份/称号
  TextColumn get identity => text().withDefault(const Constant(''))();

  /// 角色年龄
  TextColumn get age => text().withDefault(const Constant('未知'))();

  /// 角色动机
  TextColumn get motivation => text().withDefault(const Constant(''))();

  /// 人物弧光
  TextColumn get arc => text().withDefault(const Constant(''))();

  /// 角色性格描述：性格特质、行为模式等
  TextColumn get personality => text().withDefault(const Constant(''))();

  /// 带情境的人物行为倾向，每项为 tag + context。
  TextColumn get behaviorTags => text()
      .map(const CharacterBehaviorTagListConverter())
      .withDefault(const Constant('[]'))();

  /// 角色首次出场章节 ID
  TextColumn get firstAppearChapterId => text().nullable()();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Items extends Table {
  TextColumn get id => text()();

  TextColumn get type => text()();

  TextColumn get title => text()();

  TextColumn get content => text().withDefault(const Constant(''))();

  TextColumn get status =>
      text().withDefault(const Constant(itemEntryStatusActive))();

  TextColumn get category => text().withDefault(const Constant(''))();

  /// 物品照片集，保存图片资产和名称。
  TextColumn get photos =>
      text().map(const SubjectPhotoListConverter()).nullable()();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {type, title, deletedAt},
  ];
}

@DataClassName('ChapterData')
class Chapters extends Table {
  @override
  String get tableName => 'chapter_nodes';

  TextColumn get id => text()();

  TextColumn get type => text()();
  TextColumn get parentId => text().nullable()();
  IntColumn get siblingOrder => integer()();

  TextColumn get title => text().nullable()();

  TextColumn get outline => text().withDefault(const Constant(''))();

  /// 写后总结，chronicler 发布后写入。outline 保持写前规划，不被覆盖。
  TextColumn get brief => text().withDefault(const Constant(''))();

  TextColumn get content => text().withDefault(const Constant(''))();

  IntColumn get wordCount => integer().withDefault(const Constant(0))();

  TextColumn get stat => text().withDefault(const Constant(chapterStatDraft))();

  /// 紧张度 1-10，chronicler 处理后估算。
  IntColumn get tension => integer().nullable()();

  /// 情绪标签列表（2-4 字），chronicler 处理后提取。
  TextColumn get emotion =>
      text().map(const StringListConverter()).nullable()();

  /// 章内事件序列 `[{title, summary, state_change}]`，chronicler 处理后提取。
  /// 与 brief 分工：brief 是整章散文总结，events 是可跨章聚合的结构化事件。
  TextColumn get events =>
      text().map(const JsonMapListConverter()).nullable()();

  /// 作者对正文选区写下的批注 `[{id, start, end, quote, content, status, ...}]`。
  /// 与 events 分工：events 是 AI 提取的结构化事件，comments 是作者手写的笔记。
  TextColumn get comments =>
      text().map(const ChapterCommentListConverter()).nullable()();

  TextColumn get embeddingSyncStatus =>
      text().withDefault(const Constant(chapterEmbeddingSyncStatusPending))();

  DateTimeColumn get embeddingSyncedAt => dateTime().nullable()();

  TextColumn get embeddingSyncModelId => text().nullable()();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Foreshadowings extends Table {
  TextColumn get id => text()();

  TextColumn get title => text()();

  TextColumn get setup => text().withDefault(const Constant(''))();

  TextColumn get payoff => text().withDefault(const Constant(''))();

  /// 铺垫章节 ID
  TextColumn get setupChapterId => text().nullable()();

  /// 兑现章节 ID
  TextColumn get payoffChapterId => text().nullable()();

  TextColumn get setupSceneId => text().nullable()();

  TextColumn get payoffSceneId => text().nullable()();

  TextColumn get status =>
      text().withDefault(const Constant(foreshadowingStatusPending))();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {title, deletedAt},
  ];
}

class AiChatMessages extends Table {
  TextColumn get id => text()();

  TextColumn get sessionId => text()();

  TextColumn get role => text()();

  TextColumn get type => text().withDefault(const Constant('text'))();

  TextColumn get content => text().withDefault(const Constant(''))();

  TextColumn get blocks =>
      text().map(const AiMessageBlockListConverter()).nullable()();

  TextColumn get metadata => text().map(const JsonMapConverter()).nullable()();

  /// 输入（prompt）token 数，含 cached tokens
  IntColumn get inputTokens => integer().withDefault(const Constant(0))();

  /// 输出（completion）token 数，含 reasoning tokens
  IntColumn get outputTokens => integer().withDefault(const Constant(0))();

  /// Prompt cache 命中（读取）token 数
  IntColumn get cacheReadTokens => integer().withDefault(const Constant(0))();

  /// Prompt cache 写入 token 数
  IntColumn get cacheWriteTokens => integer().withDefault(const Constant(0))();

  /// 推理/思考 token 数
  IntColumn get reasoningTokens => integer().withDefault(const Constant(0))();

  IntColumn get sequence => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class AiEmbeddingDocuments extends Table {
  TextColumn get id => text()();

  TextColumn get sourceId => text()();

  TextColumn get sourceType => text()();

  TextColumn get path => text()();

  TextColumn get title => text().withDefault(const Constant(''))();

  IntColumn get chunkIndex => integer()();

  TextColumn get content => text()();

  TextColumn get embeddingModel => text()();

  TextColumn get providerId => text().nullable()();

  TextColumn get vector => text().map(const DoubleListConverter())();

  TextColumn get metadata => text().map(const JsonMapConverter()).nullable()();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class WorkingChanges extends Table {
  TextColumn get id => text()();

  TextColumn get resourcePath => text()();

  TextColumn get resourceType => text()();

  TextColumn get resourceId => text().nullable()();

  TextColumn get field => text().nullable()();

  TextColumn get changeType => text()();

  TextColumn get source => text()();

  TextColumn get sourceSessionId => text().nullable()();

  /// 触发该改动的 user 消息 id（= 轮次 id）；旧数据为 null（轮次回退不可用）。
  /// 详见 docs/solutions/chat-changes-rework.md。
  TextColumn get sourceTurnId => text().nullable()();

  TextColumn get toolName => text().nullable()();

  TextColumn get summary => text().withDefault(const Constant(''))();

  TextColumn get oldText => text().nullable()();

  TextColumn get newText => text().nullable()();

  IntColumn get baseVersion => integer().withDefault(const Constant(0))();

  TextColumn get status => text().withDefault(const Constant('active'))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class ChangeCommits extends Table {
  TextColumn get id => text()();

  TextColumn get message => text().withDefault(const Constant(''))();

  TextColumn get source => text().withDefault(const Constant('manual_edit'))();

  IntColumn get changeCount => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class ChangeCommitItems extends Table {
  TextColumn get id => text()();

  TextColumn get commitId => text()();

  TextColumn get workingChangeId => text()();

  TextColumn get resourcePath => text()();

  TextColumn get resourceType => text()();

  TextColumn get resourceId => text().nullable()();

  TextColumn get field => text().nullable()();

  TextColumn get oldText => text().nullable()();

  TextColumn get newText => text().nullable()();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class NovelStates extends Table {
  TextColumn get key => text()();

  TextColumn get status =>
      text().withDefault(const Constant(novelStateStatusIdle))();

  TextColumn get data => text().nullable()();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// 故事状态快照 — 每次写入生成一条，覆盖范围记录在正文，保留历史用于回溯。
class NovelStateSnapshots extends Table {
  TextColumn get id => text()();

  /// 完整快照 Markdown 正文。
  TextColumn get content => text().withDefault(const Constant(''))();

  /// active / superseded
  TextColumn get status =>
      text().withDefault(const Constant(novelStateSnapshotStatusActive))();

  /// chronicler / user
  TextColumn get createdBy => text().withDefault(
    const Constant(novelStateSnapshotCreatedByChronicler),
  )();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class AgentRules extends Table {
  TextColumn get id => text()();

  TextColumn get name => text()();

  TextColumn get content => text()();

  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Documents extends Table {
  TextColumn get id => text()();

  TextColumn get type => text()();

  TextColumn get title => text()();

  TextColumn get content => text().withDefault(const Constant(''))();

  TextColumn get status =>
      text().withDefault(const Constant(documentStatusActive))();

  TextColumn get category => text().withDefault(const Constant(''))();

  TextColumn get tags => text().withDefault(const Constant(''))();

  TextColumn get parentId => text().nullable()();

  BoolColumn get isFolder => boolean().withDefault(const Constant(false))();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {type, parentId, title, deletedAt},
  ];
}

class Outlines extends Table {
  @override
  String get tableName => 'outlines';

  TextColumn get documentId => text()();

  TextColumn get title => text().withDefault(const Constant(''))();

  TextColumn get content => text().withDefault(const Constant(''))();

  TextColumn get status =>
      text().withDefault(const Constant(outlineStatusPending))();

  IntColumn get startChapterNum => integer().withDefault(const Constant(1))();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {documentId};
}

class OutlineBeats extends Table {
  @override
  String get tableName => 'outline_beats';

  TextColumn get id => text()();

  TextColumn get outlineDocumentId => text()();

  TextColumn get title => text().withDefault(const Constant(''))();

  TextColumn get content => text().withDefault(const Constant(''))();

  TextColumn get status =>
      text().withDefault(const Constant(outlineStatusPending))();

  IntColumn get chapterCount => integer().withDefault(const Constant(1))();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 无限画布 — 一张画布(构思层,非正典业务关系)。
/// data class 命名为 CanvasEntry(避免与 dart:ui.Canvas 冲突)。
@DataClassName('CanvasEntry')
class Canvases extends Table {
  /// 上次成功执行的布局；之后手动移动不清除此值。
  TextColumn get layout => text().nullable()();

  TextColumn get id => text()();

  TextColumn get name => text()();

  TextColumn get description => text().withDefault(const Constant(''))();

  /// 画布用途：'user'（构思）/ 'production'（当前集制作）。
  TextColumn get kind => text().withDefault(const Constant(canvasKindUser))();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 画布节点：构思引用/便签，以及制作视频/素材/导演台节点。
/// 位置/大小是列,不入 metadata(守 AGENTS.md metadata 禁令)。
class CanvasNodes extends Table {
  TextColumn get id => text()();

  TextColumn get canvasId => text()();

  TextColumn get type =>
      text().withDefault(const Constant(canvasNodeTypeReference))();

  /// 引用型必填:'character'/'chapter'/'foreshadowing'/'outline'/'location'/
  /// 'item'/'faction'/'skill'/'creature'/'document';便签型为 NULL。
  /// 制作画布:video/image → production_clip,staging → staging。
  /// media 通过 refType=asset/refId 读取资产；资产删除或文件缺失时展示错误，
  /// 不在节点保存文件路径或类型，也不回退到已删除资产的文件。
  TextColumn get refType => text().nullable()();

  /// 引用型必填:指向资源 id;便签型为 NULL。
  TextColumn get refId => text().nullable()();

  /// 引用型缓存资源标题(避免渲染时 join 资源表);便签型为便签标题。
  TextColumn get title => text().withDefault(const Constant(''))();

  /// 便签正文；转为引用后保留但不展示，转回便签时复用。
  TextColumn get content => text().withDefault(const Constant(''))();

  RealColumn get x => real().withDefault(const Constant(0.0))();

  RealColumn get y => real().withDefault(const Constant(0.0))();

  RealColumn get width => real().nullable()();

  RealColumn get height => real().nullable()();

  /// 纯视觉(颜色/形状/图标),非业务数据。
  TextColumn get style => text().map(const JsonMapConverter()).nullable()();

  IntColumn get zIndex => integer().withDefault(const Constant(0))();

  /// 分组内顺序；分镜组中即格位下标（行 × 列数 + 列）。
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// 制作画布分组成员指向同画布的 [canvasNodeTypeGroup] 节点；NULL 表示不在分组中。
  TextColumn get parentId => text().nullable()();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 画布边 — 类型化视觉组织边(不进入 EntityRelations)。
/// 硬删(与 EntityRelations 一致,边轻量易重建)。
class CanvasEdges extends Table {
  TextColumn get id => text()();

  TextColumn get canvasId => text()();

  TextColumn get sourceNodeId => text()();

  TextColumn get targetNodeId => text()();

  TextColumn get type =>
      text().withDefault(const Constant(canvasEdgeTypeAssociation))();

  TextColumn get label => text().nullable()();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {canvasId, sourceNodeId, targetNodeId, type},
  ];
}

class EntityRelations extends Table {
  TextColumn get id => text()();

  TextColumn get sourceType => text()();

  TextColumn get sourceId => text()();

  TextColumn get targetType => text()();

  TextColumn get targetId => text()();

  TextColumn get relationType => text()();

  TextColumn get status => text().withDefault(const Constant('active'))();

  TextColumn get changeLogs => text()
      .map(const RelationStateSnapshotListConverter())
      .withDefault(const Constant('[]'))();

  TextColumn get chapterId => text().nullable()();

  TextColumn get sceneId => text().nullable()();

  TextColumn get proof => text().withDefault(const Constant(''))();

  TextColumn get properties =>
      text().map(const JsonMapConverter()).nullable()();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('ScreenplayRow')
class Screenplays extends Table {
  // 剧本风格引用：null 无风格；'preset:<slug>' 为内置预设；其他值为自定义风格（production_styles）ID。
  TextColumn get styleId => text().nullable()();
  TextColumn get id => text()();
  TextColumn get kind =>
      text().withDefault(const Constant(screenplayKindSeries))();
  TextColumn get format =>
      text().withDefault(const Constant(screenplayFormatAsian))();
  TextColumn get ratio => text().withDefault(const Constant('16:9'))();
  TextColumn get resolution => text().withDefault(const Constant('720p'))();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('ScreenplaySeasonRow')
class ScreenplaySeasons extends Table {
  TextColumn get id => text()();
  TextColumn get screenplayId => text()();
  IntColumn get seasonNumber => integer()();
  TextColumn get title => text().withDefault(const Constant(''))();
  IntColumn get plannedEpisodeCount => integer().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('ScreenplayEpisodeRow')
class ScreenplayEpisodes extends Table {
  TextColumn get id => text()();
  TextColumn get screenplayId => text()();
  TextColumn get seasonId => text()();
  TextColumn get canvasId => text().nullable()();
  TextColumn get editingId => text().nullable()();
  IntColumn get episodeNumber => integer()();
  TextColumn get title => text().withDefault(const Constant(''))();

  /// 每集的大纲正文（markdown）：Logline / Synopsis / Theme / Character Arcs
  /// 写在同一段内容里，与小说端 outlines.content 同一种 blob 模式。
  TextColumn get outline => text().withDefault(const Constant(''))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('VideoEditingRow')
class VideoEditings extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get document => text().map(const EditingDocumentConverter())();
  IntColumn get revision => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('ScreenplaySceneRow')
class ScreenplayScenes extends Table {
  TextColumn get id => text()();
  TextColumn get screenplayId => text()();
  TextColumn get episodeId => text()();
  TextColumn get beatId => text().nullable()();
  TextColumn get title => text().withDefault(const Constant(''))();

  TextColumn get emotion =>
      text().map(const StringListConverter()).nullable()();
  TextColumn get events =>
      text().map(const JsonMapListConverter()).nullable()();
  TextColumn get synopsis => text().withDefault(const Constant(''))();
  TextColumn get stage =>
      text().withDefault(const Constant(screenplayStageDraft))();
  IntColumn get pageEighths => integer().withDefault(const Constant(0))();

  IntColumn get dialogueLineCount => integer().withDefault(const Constant(0))();
  IntColumn get wordCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 每个实体的版本独立成行，关系和版本号显式存储，值由所属领域解析。
@DataClassName('RevisionRow')
class Revisions extends Table {
  TextColumn get id => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  IntColumn get version => integer()();
  TextColumn get value => text().map(const JsonMapConverter())();
  DateTimeColumn get restoredFrom => dateTime().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 导演台调度：当前文档存本表，每次编辑会话或 AI 回合首次修改前留一份 revisions 快照。
@DataClassName('VideoStagingRow')
class VideoStagings extends Table {
  TextColumn get id => text()();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get document => text().map(const JsonMapConverter()).nullable()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('ScreenplayBeatRow')
class ScreenplayBeats extends Table {
  TextColumn get id => text()();
  TextColumn get screenplayId => text()();
  TextColumn get episodeId => text()();
  IntColumn get actNumber => integer()();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get description => text().withDefault(const Constant(''))();
  IntColumn get sortOrder => integer()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('ScreenplaySceneCharacterRow')
class ScreenplaySceneCharacters extends Table {
  TextColumn get id => text()();
  TextColumn get sceneId => text()();
  TextColumn get characterId => text()();
  IntColumn get sortOrder => integer()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('ScreenplaySceneElementRow')
class ScreenplaySceneElements extends Table {
  TextColumn get id => text()();
  TextColumn get sceneId => text()();
  TextColumn get episodeId => text()();
  TextColumn get interiorExterior => text().nullable()();
  TextColumn get locationId => text().nullable()();
  TextColumn get timeLabel => text().nullable()();
  IntColumn get sortOrder => integer()();
  TextColumn get type => text()();
  TextColumn get textContent =>
      text().named('text').withDefault(const Constant(''))();
  TextColumn get characterId => text().nullable()();
  TextColumn get extension => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  List<String> get customConstraints => [
    "CHECK ((type = 'scene_heading' AND text = '' AND character_id IS NULL AND extension = '' AND time_label IS NOT NULL AND (interior_exterior IS NULL OR interior_exterior IN ('interior','exterior','interior_exterior'))) OR (type IN ('action','character','parenthetical','dialogue','transition','subtitle','note') AND interior_exterior IS NULL AND location_id IS NULL AND time_label IS NULL AND ((type = 'character' AND text = '' AND character_id IS NOT NULL AND length(trim(character_id)) > 0) OR (type != 'character' AND character_id IS NULL AND extension = ''))))",
  ];

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Locations extends Table {
  TextColumn get photos =>
      text().map(const SubjectPhotoListConverter()).nullable()();
  TextColumn get id => text()();

  TextColumn get name => text()();

  TextColumn get description => text().withDefault(const Constant(''))();

  TextColumn get type =>
      text().withDefault(const Constant(locationTypeGeneric))();

  TextColumn get parentId => text().nullable()();

  TextColumn get tags => text().withDefault(const Constant(''))();

  TextColumn get meta => text().map(const JsonMapConverter()).nullable()();

  TextColumn get status =>
      text().withDefault(const Constant(locationStatusActive))();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class NovelMaps extends Table {
  TextColumn get id => text()();

  TextColumn get name => text()();

  TextColumn get description => text().withDefault(const Constant(''))();

  TextColumn get type => text().withDefault(const Constant(mapTypeWorld))();

  /// 这张地图归属的地点（世界图 ↔ 世界地点、区域图 ↔ 区域地点）。
  TextColumn get locationId => text().nullable()();

  RealColumn get width => real().withDefault(const Constant(1000.0))();

  RealColumn get height => real().withDefault(const Constant(800.0))();

  TextColumn get settings => text().map(const JsonMapConverter()).nullable()();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class MapLocations extends Table {
  TextColumn get id => text()();

  TextColumn get mapId => text()();

  TextColumn get locationId => text()();

  RealColumn get x => real().withDefault(const Constant(0.0))();

  RealColumn get y => real().withDefault(const Constant(0.0))();

  RealColumn get width => real().nullable()();

  RealColumn get height => real().nullable()();

  TextColumn get style => text().map(const JsonMapConverter()).nullable()();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {mapId, locationId, deletedAt},
  ];
}

@DataClassName('ProductionClipRow')
class ProductionClips extends Table {
  /// 数组顺序即参考顺序；node 输入派生连线，asset 输入不创建画布节点。
  TextColumn get inputs => text()
      .map(const ProductionInputsConverter())
      .withDefault(const Constant('[]'))();
  TextColumn get characterId => text().nullable()();
  TextColumn get locationId => text().nullable()();
  TextColumn get itemId => text().nullable()();
  // 风格选择：null 继承所属剧本的 styleId；'none' 明确禁用风格；
  // 'preset:<slug>' 为内置预设；其他值为指定的自定义风格（production_styles）ID。
  // 此列同时表达继承策略和风格引用，不能只按 ID 解释。
  TextColumn get styleSelection => text().nullable()();

  /// null 继承模型默认值；false 明确关闭生成音频。
  BoolColumn get generateAudio => boolean().nullable()();
  TextColumn get lastAppliedGenerationTaskId => text().nullable()();
  TextColumn get id => text()();
  TextColumn get episodeId => text()();
  TextColumn get kind => text()();
  TextColumn get sceneId => text().nullable()();
  IntColumn get sortOrder => integer().nullable()();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get prompt => text().withDefault(const Constant(''))();
  BoolColumn get errorDismissed =>
      boolean().withDefault(const Constant(false))();
  TextColumn get providerId => text().nullable()();
  TextColumn get modelId => text().nullable()();
  TextColumn get referenceMode =>
      text().withDefault(const Constant('reference'))();
  IntColumn get durationMs => integer().nullable()();
  TextColumn get ratio => text().withDefault(const Constant('9:16'))();
  TextColumn get resolution => text().withDefault(const Constant('720p'))();

  /// 采用的生成结果或上传素材；文件路径从资产读取。
  TextColumn get adoptedAssetId => text().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DriftDatabase(
  tables: [
    CharacterProfiles,
    Items,
    Chapters,
    Foreshadowings,
    AiChatMessages,
    AiEmbeddingDocuments,
    WorkingChanges,
    ChangeCommits,
    ChangeCommitItems,
    NovelStates,
    AgentRules,
    Documents,
    EntityRelations,
    Locations,
    NovelMaps,
    MapLocations,
    Outlines,
    OutlineBeats,
    NovelStateSnapshots,
    Canvases,
    CanvasNodes,
    CanvasEdges,
    Screenplays,
    ScreenplaySeasons,
    ScreenplayEpisodes,
    ScreenplayScenes,
    VideoStagings,
    VideoEditings,
    Revisions,
    ScreenplayBeats,
    ScreenplaySceneCharacters,
    ScreenplaySceneElements,
    ProductionClips,
  ],
  daos: [
    CharacterProfileDao,
    ItemDao,
    ChapterDao,
    ForeshadowingDao,
    AiChatMessageDao,
    WorkingChangeDao,
    ChangeCommitDao,
    NovelStateDao,
    NovelStateSnapshotDao,
    AgentRuleDao,
    DocumentDao,
    LocationDao,
    OutlineDao,
    CanvasDao,
    ScreenplayDao,
    EditingDao,
  ],
)
class NovelContentDatabase extends _$NovelContentDatabase {
  static final _log = AppLogger.forModule('NovelContentDB');

  factory NovelContentDatabase(String filePath) {
    final normalizedPath = _normalizedDatabasePath(filePath);
    final cachedDatabase = _databaseCache[normalizedPath];
    if (cachedDatabase != null) {
      cachedDatabase.referenceCount += 1;
      return cachedDatabase.database;
    }

    final database = NovelContentDatabase._internal(normalizedPath);
    _databaseCache[normalizedPath] = _CachedNovelContentDatabase(
      database: database,
    );
    return database;
  }

  NovelContentDatabase._internal(this.filePath)
    : super(_openConnection(filePath));

  @visibleForTesting
  NovelContentDatabase.forTest(super.executor) : filePath = ':memory:';

  /// 供受控维护操作在内存库中生成当前 schema 参考。
  NovelContentDatabase.forSchemaRepair(super.executor) : filePath = ':memory:';

  static final Map<String, _CachedNovelContentDatabase> _databaseCache = {};

  final String filePath;

  final Object _transactionContext = Object();

  /// 需要在提交后更新内存状态的操作据此确保自己拥有最外层事务。
  bool get isInTransaction => Zone.current[_transactionContext] == true;

  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) => super.transaction(
    () => runZoned(action, zoneValues: {_transactionContext: true}),
    requireNew: requireNew,
  );

  late final chapterDao = ChapterDao(this);

  static const currentSchemaVersion = 2;

  @override
  int get schemaVersion => currentSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (migrator, from, to) async {
      if (from < 2) {
        await migrator.addColumn(
          productionClips,
          productionClips.generateAudio,
        );
      }
    },
    onCreate: (migrator) async {
      // checkpoint 立即落盘：原生崩溃（sqlite3.dll）会绕过 catch，
      // 这条日志用于区分"死在建库"与其它启动路径。
      _log.checkpoint('onCreate schema v$schemaVersion (native sqlite)');
      try {
        await migrator.createAll();
        await createNovelContentDatabaseIndexes(migrator.database);
        await _createTreeView();
      } catch (error, stackTrace) {
        await StartupFailureReporter().report(
          phase: 'novel_content_database_create',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
    },
  );

  /// 首次建库时创建章节查询视图。
  Future<void> _createTreeView() async {
    await customStatement('''
      CREATE VIEW chapters AS
      WITH volume_rank AS (
        SELECT id,
          ROW_NUMBER() OVER (ORDER BY sibling_order) AS volume_num
        FROM chapter_nodes
        WHERE type = 'volume' AND deleted_at = 0 AND parent_id IS NULL
      ),
      chapter_global_rank AS (
        SELECT c.id,
          ROW_NUMBER() OVER (
            ORDER BY
              COALESCE(p.sibling_order, c.sibling_order),
              CASE WHEN c.parent_id IS NULL THEN 0 ELSE c.sibling_order END
          ) AS chapter_num
        FROM chapter_nodes c
        LEFT JOIN chapter_nodes p ON c.parent_id = p.id
        WHERE c.type = 'chapter' AND c.deleted_at = 0
      ),
      chapter_volume_rank AS (
        SELECT id,
          ROW_NUMBER() OVER (PARTITION BY parent_id ORDER BY sibling_order) AS volume_chapter_num
        FROM chapter_nodes
        WHERE type = 'chapter' AND parent_id IS NOT NULL AND deleted_at = 0
      )
      SELECT
        cn.id, cn.type, cn.parent_id, cn.sibling_order,
        cn.title, cn.outline, cn.brief, cn.content, cn.word_count, cn.stat,
        cn.tension, cn.emotion, cn.events, cn.comments,
        cn.embedding_sync_status, cn.embedding_synced_at,
        cn.embedding_sync_model_id, cn.created_at, cn.updated_at, cn.deleted_at,
        parent.sibling_order AS parent_sibling_order,
        vr.volume_num, cgr.chapter_num, cvr.volume_chapter_num
      FROM chapter_nodes cn
      LEFT JOIN chapter_nodes parent ON cn.parent_id = parent.id
      LEFT JOIN volume_rank vr ON vr.id = cn.id
      LEFT JOIN chapter_global_rank cgr ON cgr.id = cn.id
      LEFT JOIN chapter_volume_rank cvr ON cvr.id = cn.id
      WHERE cn.deleted_at = 0
      ORDER BY
        COALESCE(parent.sibling_order, cn.sibling_order),
        CASE WHEN cn.parent_id IS NULL THEN 0 ELSE cn.sibling_order END
    ''');
  }

  Future<void> seedDefaultWorkspace({
    bool includeInitialChapter = false,
    ShortEntityIdBuilder idBuilder = buildShortEntityId,
  }) async {
    final hasChapter = await (select(chapters)..limit(1)).getSingleOrNull();
    final now = DateTime.now();
    if (includeInitialChapter && hasChapter == null) {
      String? attemptedId;
      try {
        await insertWithShortEntityId(
          type: ShortEntityIdType.chapter,
          tableName: 'chapter_nodes',
          buildId: idBuilder,
          idExists: (id) async =>
              await customSelect(
                'SELECT 1 FROM chapter_nodes WHERE id = ? LIMIT 1',
                variables: [Variable.withString(id)],
              ).getSingleOrNull() !=
              null,
          insert: (id) async {
            attemptedId = id;
            await into(chapters).insert(
              ChaptersCompanion.insert(
                id: id,
                type: nodeTypeChapter,
                parentId: const Value(null),
                siblingOrder: 1,
                title: const Value('新的开始'),
                outline: const Value(''),
                content: const Value(''),
                wordCount: const Value(0),
                createdAt: Value(now),
                updatedAt: Value(now),
              ),
            );
          },
        );
      } catch (error, stackTrace) {
        _log.error(
          '[DB] chapter_nodes INSERT failed, id=$attemptedId',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
    }
  }

  @override
  Future<void> close() async {
    final cachedDatabase = _databaseCache[filePath];
    if (cachedDatabase == null) {
      return super.close();
    }

    cachedDatabase.referenceCount -= 1;
    if (cachedDatabase.referenceCount > 0) {
      return;
    }

    _databaseCache.remove(filePath);
    await super.close();
  }

  /// Fully closes all cached content databases, bypassing reference counts.
  static Future<void> closeAllCached() async {
    await _closeAllCached((database) => database.close());
  }

  /// Force-closes all cached content databases immediately before process exit.
  ///
  /// This deliberately closes the SQLite executor without waiting for Drift
  /// query streams to shut down; paused listeners can otherwise keep the
  /// normal [close] path pending and prevent the process from reaching [exit].
  static Future<void> closeAllCachedForProcessExit() async {
    await _closeAllCached(
      (database) => database._closeExecutorForProcessExit(),
    );
  }

  static Future<void> _closeAllCached(
    Future<void> Function(NovelContentDatabase database) closeDatabase,
  ) async {
    // Iterate a snapshot of the entries map
    final entries = _databaseCache.entries.toList();
    for (final entry in entries) {
      _databaseCache.remove(entry.key);
      await closeDatabase(entry.value.database);
    }
  }

  Future<void> _closeExecutorForProcessExit() => executor.close();

  /// Closes all cached SQLite executors before replacing content database
  /// files, without waiting for paused Drift query streams to shut down.
  ///
  /// The caller must restart the app before using database-backed features.
  static Future<void> closeAllCachedForFileReplacement() async {
    final entries = _databaseCache.entries.toList();
    for (final entry in entries) {
      _databaseCache.remove(entry.key);
      await entry.value.database._closeExecutorImmediately();
    }
  }

  /// Force-close a cached content database for [filePath], bypassing reference
  /// counts so the underlying SQLite file can be deleted or replaced.
  static Future<void> closeCached(String filePath) async {
    final normalizedPath = _normalizedDatabasePath(filePath);
    final cached = _databaseCache.remove(normalizedPath);
    if (cached != null) {
      await cached.database.close();
    }
  }

  Future<void> _closeExecutorImmediately() => executor.close();

  /// 删除 [filePath] 对应的内容库文件及 `-wal` / `-shm` / `-journal` 伴随文件。
  /// 调用方须先关闭该库的连接（见 [closeCached]）。
  static Future<void> deleteFiles(String filePath) async {
    final resolved = RevericPaths.resolveDatabasePath(filePath);
    for (final suffix in const ['', '-wal', '-shm', '-journal']) {
      final file = File('$resolved$suffix');
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  @visibleForTesting
  static bool isCachedForTesting(String filePath) {
    final normalizedPath = _normalizedDatabasePath(filePath);
    return _databaseCache.containsKey(normalizedPath);
  }

  /// 内容库路径归一化（缓存键 / 打开 sqlite 用）：
  /// 先把存储值（相对 / 当前根绝对 / 旧根失效绝对）resolve 为绝对路径，
  /// 再做 Windows 8.3 短路径转换（中文用户名下 sqlite3 才能打开）。
  static String _normalizedDatabasePath(String filePath) {
    final resolved = RevericPaths.resolveDatabasePath(filePath);
    return toWindowsSafePath(File(resolved).absolute.path);
  }
}

QueryExecutor _openConnection(String filePath) {
  return NativeDatabase.createInBackground(File(filePath));
}

class _CachedNovelContentDatabase {
  _CachedNovelContentDatabase({required this.database});

  final NovelContentDatabase database;
  int referenceCount = 1;
}

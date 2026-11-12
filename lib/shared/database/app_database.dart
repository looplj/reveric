// 职责: 应用级数据库定义与小说、设置、AI Provider、AI 聊天 的持久化读写。
// 关联文件:
//   lib/shared/providers/novel_providers.dart
//   lib/shared/services/novel_actions.dart
//   lib/shared/models/novel_type.dart
//   lib/shared/services/ai/session_persistence.dart
//   lib/shared/logger/startup_failure_reporter.dart
// ⚠️ 修改此文件后必须运行 `flutter pub run build_runner build --delete-conflicting-outputs`，否则 .drift.dart / .g.dart 不会更新
// 遵循的 Rules:
//   .agents/rules/db-migration.md
import 'package:reveric/shared/models/generation/task.dart';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/ai_message_block.dart';
import '../models/tool_permission.dart';
import '../models/provider_asset.dart';
import '../models/collections/filter.dart';
import '../models/content_status.dart';
import '../models/content_kind.dart';
import '../models/novel_type.dart';
import '../models/video/request.dart';
import '../logger/app_logger.dart';
import '../logger/startup_failure_reporter.dart';
import '../utils/windows_safe_path.dart';
import 'daos/global_agent_dao.dart';
import 'daos/novel_agent_skill_dao.dart';
import 'daos/novel_agent_skill_revision_dao.dart';
import 'daos/ai_chat_session_dao.dart';
import 'daos/session_subscriptions_dao.dart';
import 'daos/assistant_session_dao.dart';
import 'daos/assistant_inbox_dao.dart';
import 'daos/ai_shortcut_action_dao.dart';
import 'daos/ai_provider_dao.dart';
import 'daos/generation_task_dao.dart';
import 'daos/provider_asset_dao.dart';
import 'daos/tool_permission_dao.dart';
import 'daos/anonymous_outbox_dao.dart';
import 'daos/image_asset_dao.dart';
import 'daos/asset_dao.dart';
import 'daos/production_style_dao.dart';
import 'daos/app_settings_dao.dart';
import 'daos/plugin_dao.dart';
import 'daos/plugin_task_dao.dart';
import 'daos/app_state_dao.dart';
import 'daos/novel_dao.dart';
import 'daos/novel_collection_dao.dart';
import 'daos/reading_progress_dao.dart';
import 'daos/todo_dao.dart';
import 'type_converters.dart';
import '../models/production/image_request.dart';
import '../models/audio/request.dart';
export '../models/generation/task.dart';
import '../models/production/asset_content.dart';
import 'app_database_indexes.dart';
import 'app_database_migrations.dart';

part 'app_database.drift.dart';

final DateTime notDeletedSentinel = DateTime.fromMillisecondsSinceEpoch(0);

/// [ImageBatchSlots.status] 的取值。
const String imageBatchSlotStatusPending = 'pending';
const String imageBatchSlotStatusSucceeded = 'succeeded';
const String imageBatchSlotStatusFailed = 'failed';

/// [ImageBatches.status] 的取值。生成中为 running；作者点停止后进入 stopping，
/// 在途那一张画完才收敛。收敛结果四选一：全成功 completed、有成功也有失败或
/// 中途停止 partial、停止且零产物 canceled、全失败 failed。
const String imageBatchStatusRunning = 'running';
const String imageBatchStatusStopping = 'stopping';
const String imageBatchStatusCompleted = 'completed';
const String imageBatchStatusPartial = 'partial';
const String imageBatchStatusCanceled = 'canceled';
const String imageBatchStatusFailed = 'failed';

class Novels extends Table {
  TextColumn get id => text()();

  TextColumn get title => text()();

  TextColumn get authorName => text().withDefault(const Constant(''))();

  TextColumn get description => text()();

  /// 封面图片资产
  TextColumn get coverAssetId => text().nullable()();

  TextColumn get status =>
      text().withDefault(const Constant(contentStatusInProgress))();

  TextColumn get type =>
      text().withDefault(const Constant(novelTypeOriginal))();

  TextColumn get contentKind =>
      text().withDefault(const Constant(contentKindNovel))();

  TextColumn get sourceNovelId => text().nullable()();

  TextColumn get contentDatabasePath => text().nullable()();

  IntColumn get wordCount => integer().withDefault(const Constant(0))();

  /// 快速开书草稿标记：true = 尚未「加入书架」，书库不显示。
  /// 仅由显式动作清除（编辑器「加入书架」按钮 / Run novel add-to-library），不自动清。
  BoolColumn get draft => boolean().withDefault(const Constant(false))();

  TextColumn get category => text().withDefault(const Constant(''))();

  TextColumn get tags => text()
      .map(const StringListConverter())
      .withDefault(const Constant('[]'))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 集合按作品类型分开：小说库和剧本库各有自己的集合；成员关系保存在 NovelCollectionMembers。
class NovelCollections extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  BoolColumn get builtin => boolean()
      .withDefault(const Constant(false))
      .customConstraint('NOT NULL DEFAULT 0')();
  TextColumn get filterMode => text().withDefault(const Constant('manual'))();
  TextColumn get filter =>
      text().nullable().map(const CollectionFilterConverter())();

  /// 集合所属的作品类型。null 只留给各库共用的内置「全部」。
  /// 取值由 Dart 侧 [validateContentKind] 校验。
  TextColumn get contentKind => text().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 移出后保留关系记录，再次加入时恢复同一条关系。
class NovelCollectionMembers extends Table {
  TextColumn get collectionId => text()();
  TextColumn get novelId => text()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();
  @override
  Set<Column<Object>> get primaryKey => {collectionId, novelId};
}

/// 用户保存的应用配色；baseTheme 只允许内置主题，由 Dart 校验。
class CustomThemes extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get baseTheme => text()();
  TextColumn get lightOverrides => text().map(const StringMapConverter())();
  TextColumn get darkOverrides => text().map(const StringMapConverter())();
  IntColumn get revision => integer().withDefault(const Constant(1))();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class AppSettings extends Table {
  TextColumn get key => text()();

  TextColumn get value => text().withDefault(const Constant(''))();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// 匿名诊断和用量事件共用的本地可靠投递队列。
class AnonymousOutboxEvents extends Table {
  @override
  String get tableName => 'anonymous_outbox_events';

  IntColumn get id => integer().autoIncrement()();

  /// 可选的事件幂等键；未提供时不按事件 ID 去重。
  TextColumn get eventId => text().nullable()();

  TextColumn get channel => text()();

  IntColumn get priority => integer()();

  TextColumn get endpoint => text()();

  TextColumn get productCode => text()();

  TextColumn get deviceId => text()();

  /// 单条、endpoint 专属 payload，不持久化批请求体或签名。
  TextColumn get payloadJson => text()();

  DateTimeColumn get occurredAt => dateTime()();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();

  DateTimeColumn get nextRetryAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();

  IntColumn get attemptCount => integer().withDefault(const Constant(0))();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {eventId},
  ];
}

/// 统一媒体资产；文件路径相对 Application Support 根保存。
@DataClassName('AssetRow')
class Assets extends Table {
  TextColumn get id => text()();
  TextColumn get type => text()();
  TextColumn get content =>
      text().map(const AssetContentConverter()).nullable()();
  TextColumn get name => text().withDefault(const Constant(''))();
  TextColumn get novelId => text().nullable()();
  TextColumn get batchId => text().nullable()();
  TextColumn get purpose => text()();
  TextColumn get source => text().withDefault(const Constant('uploaded'))();
  TextColumn get path => text().nullable()();
  TextColumn get sha256 => text().nullable()();
  TextColumn get metadataJson =>
      text().map(const JsonMapConverter()).nullable()();
  BoolColumn get favorite => boolean().withDefault(const Constant(false))();

  /// 用户手动收进素材库的资产；挑选素材的界面只列这些，按 id 引用不受影响。
  BoolColumn get inLibrary => boolean().withDefault(const Constant(false))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 用户自定义的生成风格：套在生成提示词前后的文本，跨作品共用；内置预设不入库。
@DataClassName('ProductionStyleRow')
class ProductionStyles extends Table {
  TextColumn get id => text()();
  TextColumn get name => text().withDefault(const Constant(''))();
  TextColumn get before => text().withDefault(const Constant(''))();
  TextColumn get after => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('ImageBatchRow')
class ImageBatches extends Table {
  TextColumn get id => text()();
  TextColumn get novelId => text().nullable()();
  TextColumn get purpose => text().withDefault(const Constant('cover'))();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get prompt => text()();
  TextColumn get paramsJson => text().nullable()();
  TextColumn get providerId => text().nullable()();
  TextColumn get model => text().nullable()();
  IntColumn get requestedCount => integer().withDefault(const Constant(1))();
  IntColumn get completedCount => integer().withDefault(const Constant(0))();
  TextColumn get errorMessage => text().nullable()();
  TextColumn get errorCode => text().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 批次里的一个格子。成功的格子指向 [Assets]，失败的格子没有图片可挂，
/// 只留错误分类，胶片条据此把那一格画成可点进去看原因的失败位。
@DataClassName('ImageBatchSlotRow')
class ImageBatchSlots extends Table {
  TextColumn get id => text()();
  TextColumn get batchId => text()();

  /// 格子在批次内的序号，从 0 起。
  IntColumn get ordinal => integer()();

  /// pending / succeeded / failed
  TextColumn get status =>
      text().withDefault(const Constant(imageBatchSlotStatusPending))();
  TextColumn get assetId => text().nullable()();

  /// 重出时被替换掉的那张，用于溯源的「重出自」。
  TextColumn get previousAssetId => text().nullable()();
  TextColumn get errorCode => text().nullable()();
  TextColumn get errorMessage => text().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('ImageAssetReferenceRow')
class ImageAssetReferences extends Table {
  TextColumn get id => text()();
  TextColumn get assetId => text()();
  TextColumn get batchId => text()();
  TextColumn get referenceAssetId => text().nullable()();
  TextColumn get role => text().withDefault(const Constant('reference'))();
  IntColumn get ordinal => integer()();
  TextColumn get purpose => text()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class AiProviders extends Table {
  @override
  String get tableName => 'ai_providers';

  TextColumn get id => text()();

  TextColumn get name => text()();

  BoolColumn get builtin => boolean().withDefault(const Constant(false))();

  TextColumn get type => text()();

  BoolColumn get enabled => boolean().withDefault(const Constant(false))();

  TextColumn get apiKey => text().withDefault(const Constant(''))();

  TextColumn get baseUrl => text().withDefault(const Constant(''))();

  TextColumn get models => text()
      .map(const StringListConverter())
      .withDefault(const Constant('[]'))();

  TextColumn get imageModels => text()
      .map(const StringListConverter())
      .withDefault(const Constant('[]'))();

  TextColumn get audioModels => text()
      .map(const StringListConverter())
      .withDefault(const Constant('[]'))();

  TextColumn get videoModels => text()
      .map(const StringListConverter())
      .withDefault(const Constant('[]'))();

  TextColumn get embeddingModels => text()
      .map(const StringListConverter())
      .withDefault(const Constant('[]'))();

  RealColumn get temperature => real().withDefault(const Constant(0.7))();

  IntColumn get maxTurns => integer().withDefault(const Constant(512))();

  TextColumn get reasoningEffort => text().nullable()();

  TextColumn get proxyUrl => text().withDefault(const Constant(''))();

  TextColumn get proxyUsername => text().withDefault(const Constant(''))();

  TextColumn get proxyPassword => text().withDefault(const Constant(''))();

  /// 渠道 OpenAPI 的 AK/SK 与项目，用于私域素材库；只有支持素材认证的渠道填写。
  TextColumn get accessKeyId => text().nullable()();

  TextColumn get secretAccessKey => text().nullable()();

  TextColumn get assetProjectName => text().nullable()();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class ToolPermissionRules extends Table {
  TextColumn get id => text()();
  TextColumn get action => text()();
  TextColumn get scopeType => textEnum<ToolPermissionScopeType>()();
  TextColumn get workId => text()();
  TextColumn get scopeId => text()();
  TextColumn get decision => textEnum<ToolPermissionDecision>()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 本地素材在渠道中的上传或认证记录；同一素材按渠道和用途分别保存。
class ProviderAssets extends Table {
  TextColumn get kind => textEnum<ProviderAssetKind>().withDefault(
    const Constant('certification'),
  )();
  TextColumn get contextHash => text().nullable()();
  TextColumn get remoteUrl => text().nullable()();
  DateTimeColumn get expiresAt => dateTime().nullable()();
  TextColumn get id => text()();
  TextColumn get assetId => text()();
  TextColumn get providerId => text()();

  /// 渠道返回的素材 id，生成请求里以 `asset://` 引用；还没提交到渠道时为空。
  TextColumn get remoteId => text().nullable()();

  /// 渠道查询认证进度用的 id；为空时直接用 [remoteId] 查。
  TextColumn get remoteTaskId => text().nullable()();
  TextColumn get remoteGroupId => text().nullable()();
  TextColumn get status => textEnum<ProviderAssetStatus>()();
  TextColumn get errorCode => text().nullable()();
  TextColumn get errorMessage => text().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

class GenerationTasks extends Table {
  TextColumn get imageOutputs =>
      text().map(const ImageTaskOutputsConverter()).nullable()();
  TextColumn get kind => textEnum<GenerationKind>()();
  TextColumn get id => text()();

  /// 草稿生成属于任务流程；普通任务和草稿完成任务均为 false。
  BoolColumn get draft => boolean()
      .withDefault(const Constant(false))
      .customConstraint('NOT NULL DEFAULT 0')();

  /// 草稿完成任务关联的本地任务 ID，上游 ID 从原任务的 providerTaskId 读取。
  TextColumn get draftTaskId => text().nullable()();
  TextColumn get novelId => text()();
  TextColumn get sourceType => text()();
  TextColumn get sourceId => text()();
  TextColumn get resultAssetId => text().nullable()();
  TextColumn get providerId => text()();
  TextColumn get providerType => text()();
  TextColumn get modelId => text()();
  TextColumn get providerTaskId => text().nullable()();
  TextColumn get pollingUrl => text().nullable()();
  TextColumn get outputUrl => text().nullable()();
  TextColumn get status => textEnum<GenerationTaskStatus>()();
  TextColumn get requestJson =>
      text().map(const GenerationRequestConverter())();
  DateTimeColumn get nextPollAt => dateTime().nullable()();
  TextColumn get errorCode => text().nullable()();
  TextColumn get errorMessage => text().nullable()();

  /// 脱敏后的供应商错误码和原文，只返回给 Agent；界面只展示 [errorMessage]。
  TextColumn get errorDetail => text().nullable()();
  TextColumn get path => text().nullable()();
  TextColumn get outputHash => text().nullable()();
  DateTimeColumn get cancelRequestedAt => dateTime().nullable()();
  DateTimeColumn get submittedAt => dateTime().nullable()();
  DateTimeColumn get completedAt => dateTime().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('AiUsageRecord')
class AiUsages extends Table {
  @override
  String get tableName => 'ai_usages';

  TextColumn get id => text()();

  TextColumn get providerId => text()();

  TextColumn get model => text()();

  TextColumn get sessionId => text().nullable()();

  TextColumn get novelId => text().nullable()();

  /// 统计来源，取值见 `UsageSources`；写入值必须与枚举一致，新增枚举值需先与用户确认。
  TextColumn get source => text().withDefault(const Constant('chat'))();

  /// 单次用户发起运行的标识。用于把同一子会话中的多次 SpawnAgent 调用拆开。
  TextColumn get runId => text().nullable()();

  /// 运行的用户可读摘要。当前由 SpawnAgent task 提供。
  TextColumn get runLabel => text().nullable()();

  IntColumn get inputTokens => integer().withDefault(const Constant(0))();

  IntColumn get outputTokens => integer().withDefault(const Constant(0))();

  IntColumn get cacheReadTokens => integer().withDefault(const Constant(0))();

  IntColumn get cacheWriteTokens => integer().withDefault(const Constant(0))();

  IntColumn get reasoningTokens => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

const String agentScopeGlobal = 'global';
const String agentScopeNovel = 'novel';

@DataClassName('GlobalAgent')
class Agents extends Table {
  @override
  String get tableName => 'agents';

  TextColumn get id => text()();

  TextColumn get scope => text()();

  TextColumn get novelId => text().withDefault(const Constant(''))();

  TextColumn get slug => text()();

  TextColumn get name => text()();

  TextColumn get description => text().withDefault(const Constant(''))();

  TextColumn get prompt => text()();

  TextColumn get category => text()();

  TextColumn get mode => text().withDefault(const Constant('chat'))();

  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  BoolColumn get useCustomPrompt =>
      boolean().withDefault(const Constant(false))();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  TextColumn get allowedToolNames => text()
      .map(const StringListConverter())
      .withDefault(const Constant('[]'))();

  TextColumn get ignoredSkillNames => text()
      .map(const StringListConverter())
      .withDefault(const Constant('[]'))();

  TextColumn get providerId => text().nullable()();

  TextColumn get model => text().nullable()();

  TextColumn get reasoningEffort => text().nullable()();

  TextColumn get avatarPath => text().nullable()();

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
    {scope, novelId, slug, deletedAt},
  ];
}

class AiChatSessions extends Table {
  TextColumn get id => text()();

  TextColumn get novelId => text()();

  TextColumn get parentId => text().nullable()();

  TextColumn get title => text().withDefault(const Constant(''))();

  TextColumn get provider => text().nullable()();

  TextColumn get model => text().nullable()();

  TextColumn get mode => text().withDefault(const Constant('chat'))();

  TextColumn get agentSlug => text().nullable()();

  TextColumn get reasoningEffort => text().nullable()();

  TextColumn get metadata => text().map(const JsonMapConverter()).nullable()();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

const String sessionSubscriberRemoteChat = 'remote_chat';
const String sessionSubscriberTaskComments = 'task_comments';
const String sessionChannelWechat = 'wechat';

/// Session 订阅关系表（app DB，cross-novel）— 记录某 session 的下行输出订阅者。
/// session 行在本库 ai_chat_sessions（软删除语义），消息在各 novel content DB；
/// 仅字符串引用 session_id，不设外键。
/// 已知两类订阅者：remote_chat（转发到 IM chat）、task_comments（落 task comment，
/// 接线另立方案）。表一次建好两类 subscriber_type（§5.2）。
class SessionSubscriptions extends Table {
  @override
  String get tableName => 'session_subscriptions';

  TextColumn get id => text()();

  TextColumn get sessionId => text()();

  TextColumn get subscriberType => text()();

  /// remote_chat → chatId（如 wxid）；task_comments → taskId。
  TextColumn get targetId => text()();

  /// 仅 remote_chat 用：IM channel 类型（如 'wechat'）；task_comments 为 null。
  TextColumn get channelType => text().nullable()();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {sessionId, subscriberType, targetId},
  ];
}

/// Remote / home page Assistant 会话表（app DB，cross-novel）。
/// V1 仅 channel_type='wechat'；未来可扩展本地 Assistant 入口。
class AssistantSessions extends Table {
  @override
  String get tableName => 'assistant_sessions';

  TextColumn get id => text()();

  /// IM / 本地入口标识：如 wxid。
  TextColumn get chatId => text()();

  /// 入口类型：'wechat' / 未来 'local'。
  TextColumn get channelType => text()();

  TextColumn get provider => text().nullable()();

  TextColumn get model => text().nullable()();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {channelType, chatId},
  ];
}

/// Remote / home page Assistant 消息表（app DB）。
/// 字段语义与 novel content DB 的 ai_chat_messages 对齐，复用同一序列化/反序列化路径。
class AssistantMessages extends Table {
  @override
  String get tableName => 'assistant_messages';

  TextColumn get id => text()();

  TextColumn get sessionId => text()();

  TextColumn get role => text()();

  TextColumn get type => text().withDefault(const Constant('text'))();

  TextColumn get content => text().withDefault(const Constant(''))();

  TextColumn get blocks =>
      text().map(const AiMessageBlockListConverter()).nullable()();

  TextColumn get metadata => text().map(const JsonMapConverter()).nullable()();

  IntColumn get inputTokens => integer().withDefault(const Constant(0))();

  IntColumn get outputTokens => integer().withDefault(const Constant(0))();

  IntColumn get cacheReadTokens => integer().withDefault(const Constant(0))();

  IntColumn get cacheWriteTokens => integer().withDefault(const Constant(0))();

  IntColumn get reasoningTokens => integer().withDefault(const Constant(0))();

  IntColumn get sequence => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Assistant 通用收件箱表（app DB）。
/// 接受各种来源的消息（run_agent 主动 notify / run_observer 崩溃兜底 / 未来扩展），
/// 给 Assistant 下一轮 turn 组装 context 时注入。不混入 assistant_messages。
class AssistantInbox extends Table {
  @override
  String get tableName => 'assistant_inbox';

  TextColumn get id => text()();

  /// 所属 Assistant 会话（AssistantSessions.id；字符串引用，不设外键）。
  TextColumn get assistantSessionId => text()();

  /// 消息来源：'run_agent' / 'run_observer' / 未来扩展。
  TextColumn get source => text()();

  /// 来源引用（nullable）：run_agent/run_observer → run_session_id。
  TextColumn get sourceRef => text().nullable()();

  /// 消息类型：'progress' / 'question' / 'complete' / 'error' / ...
  TextColumn get messageType => text()();

  /// 消息内容（agent notify 时是 agent 写的摘要，observer 崩溃时是错误摘要）。
  TextColumn get content => text()();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class AppStates extends Table {
  @override
  String get tableName => 'app_states';

  TextColumn get key => text()();

  TextColumn get value => text().withDefault(const Constant(''))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

// 应用级全局可执行 AgentSkill。Setup 引导状态复用 NovelContentDatabase 的
// NovelStates（key='agent_skill_setup'），不再独立建表。

const String agentSkillSourceKindNovelLocal = 'novel_local';
const String agentSkillSourceKindOfficial = 'official';
const String agentSkillSourceKindMarketplace = 'marketplace';

/// 应用级全局可执行 AgentSkill —— name 全局唯一，即工具名。
@DataClassName('NovelAgentSkill')
class NovelAgentSkills extends Table {
  @override
  String get tableName => 'novel_agent_skills';

  TextColumn get id => text()();

  TextColumn get sourceKind => text()();

  TextColumn get sourceListingPublicId => text().nullable()();

  TextColumn get sourceVersion => text().nullable()();

  TextColumn get sourceDisplayName => text().nullable()();

  /// 全局唯一工具名。
  TextColumn get name => text()();

  TextColumn get whenToUse => text().withDefault(const Constant(''))();

  TextColumn get description => text()();

  TextColumn get prompt => text()();

  TextColumn get agentScopes => text()
      .map(const StringListConverter())
      .withDefault(const Constant('[]'))();

  TextColumn get category => text().withDefault(const Constant(''))();

  TextColumn get tags => text()
      .map(const StringListConverter())
      .withDefault(const Constant('[]'))();

  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// 非 null 时运行时跳过执行,即使 enabled=true(用于紧急撤销)。
  TextColumn get executionBlockedReason => text().nullable()();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {name},
  ];
}

/// AgentSkill 的 references 正文独立存储，避免主技能查询携带大附件。
@DataClassName('NovelAgentSkillReference')
class NovelAgentSkillReferences extends Table {
  @override
  String get tableName => 'novel_agent_skill_references';

  TextColumn get skillId =>
      text().references(NovelAgentSkills, #id, onDelete: KeyAction.cascade)();

  TextColumn get path => text()();

  TextColumn get content => text()();

  IntColumn get byteSize => integer()();

  TextColumn get sha256 => text().withDefault(const Constant(''))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {skillId, path};
}

/// AgentSkill 内容变更留档。纯 append-only，永不反向写回 [NovelAgentSkills]。
///
/// `content_hash` 覆盖内容字段与附件清单，是「内容有没有变」的唯一判据；
/// `enabled` / `sort_order` / `execution_blocked_reason` 不在其中，
/// 因此启停与排序不产生版本。
@DataClassName('NovelAgentSkillRevision')
class NovelAgentSkillRevisions extends Table {
  @override
  String get tableName => 'novel_agent_skill_revisions';

  TextColumn get id => text()();

  TextColumn get skillId =>
      text().references(NovelAgentSkills, #id, onDelete: KeyAction.cascade)();

  /// 技能内自增，从 1 开始。
  IntColumn get revision => integer()();

  /// AI 聚合键（来自 `ToolExecutionContext.sourceTurnId`）。
  /// 用户手动编辑为 null，同一 turn 内的多次 AI 改动覆盖同一行。
  TextColumn get turnId => text().nullable()();

  TextColumn get name => text()();

  TextColumn get whenToUse => text().withDefault(const Constant(''))();

  TextColumn get description => text().withDefault(const Constant(''))();

  TextColumn get prompt => text().withDefault(const Constant(''))();

  TextColumn get category => text().withDefault(const Constant(''))();

  TextColumn get tags => text()
      .map(const StringListConverter())
      .withDefault(const Constant('[]'))();

  TextColumn get agentScopes => text()
      .map(const StringListConverter())
      .withDefault(const Constant('[]'))();

  TextColumn get contentHash => text()();

  TextColumn get changeSource => text()();

  TextColumn get changeNote => text().nullable()();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {skillId, revision},
  ];
}

/// 某个历史版本的附件清单：只记 path → 内容 hash，正文在
/// [NovelAgentSkillBlobs] 里按 hash 全局存一份。
@DataClassName('NovelAgentSkillRevisionFile')
class NovelAgentSkillRevisionFiles extends Table {
  @override
  String get tableName => 'novel_agent_skill_revision_files';

  TextColumn get revisionId => text().references(
    NovelAgentSkillRevisions,
    #id,
    onDelete: KeyAction.cascade,
  )();

  TextColumn get path => text()();

  /// 逻辑引用 [NovelAgentSkillBlobs]，不加外键约束，孤儿由 GC 扫描回收。
  TextColumn get sha256 => text()();

  @override
  Set<Column<Object>> get primaryKey => {revisionId, path};
}

/// 内容寻址的附件正文。同一份内容无论被多少版本引用都只存一行。
@DataClassName('NovelAgentSkillBlob')
class NovelAgentSkillBlobs extends Table {
  @override
  String get tableName => 'novel_agent_skill_blobs';

  TextColumn get sha256 => text()();

  TextColumn get content => text()();

  IntColumn get byteSize => integer()();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {sha256};
}

class AiShortcutActions extends Table {
  @override
  String get tableName => 'ai_shortcut_actions';

  TextColumn get id => text()();

  TextColumn get builtinId => text().nullable()();

  TextColumn get name => text()();

  TextColumn get prompt => text()();

  TextColumn get locations => text()
      .map(const StringListConverter())
      .withDefault(const Constant('[]'))();

  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  BoolColumn get autoSend => boolean().withDefault(const Constant(false))();

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
    {builtinId, deletedAt},
  ];
}

/// Todo 任务表 — 用于 AI 会话中的任务管理
class Todos extends Table {
  TextColumn get id => text()();

  TextColumn get content => text()();

  TextColumn get status => text().withDefault(const Constant('pending'))();

  TextColumn get priority => text().withDefault(const Constant('medium'))();

  TextColumn get sessionId => text()();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {sessionId, id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [];
}

class FeatureUsages extends Table {
  TextColumn get featureId => text()();

  DateTimeColumn get firstUsedAt => dateTime()();
  DateTimeColumn get lastUsedAt => dateTime()();
  IntColumn get usedCount => integer().withDefault(const Constant(1))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {featureId};
}

class ReadingProgress extends Table {
  TextColumn get novelId => text()();

  TextColumn get chapterId => text().nullable()();

  RealColumn get scrollOffset => real().withDefault(const Constant(0))();

  DateTimeColumn get lastReadAt => dateTime().nullable()();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {novelId};
}

class PluginTasks extends Table {
  TextColumn get pluginId => text()();
  TextColumn get taskId => text()();
  BoolColumn get enabled => boolean().customConstraint('NOT NULL DEFAULT 1')();
  DateTimeColumn get nextDueAt => dateTime()();
  TextColumn get runId => text().nullable()();
  DateTimeColumn get leaseExpiresAt => dateTime().nullable()();
  IntColumn get attempt => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastStartedAt => dateTime().nullable()();
  DateTimeColumn get lastFinishedAt => dateTime().nullable()();
  TextColumn get lastStatus => text().withDefault(const Constant('never'))();
  TextColumn get lastSummary => text().nullable()();
  TextColumn get lastErrorCode => text().nullable()();
  TextColumn get lastUsage => text().map(const JsonMapConverter()).nullable()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();
  @override
  Set<Column<Object>> get primaryKey => {pluginId, taskId};
}

class PluginRegistry extends Table {
  TextColumn get pluginId => text()();
  TextColumn get version => text()();
  TextColumn get source => text()();
  TextColumn get packagePath => text()();
  BoolColumn get enabled => boolean().customConstraint('NOT NULL')();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();
  @override
  Set<Column<Object>> get primaryKey => {pluginId};
}

class PluginPermissions extends Table {
  TextColumn get pluginId => text()();
  TextColumn get permission => text()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();
  @override
  Set<Column<Object>> get primaryKey => {pluginId, permission};
}

class PluginStorage extends Table {
  TextColumn get pluginId => text()();
  TextColumn get key => text()();
  TextColumn get value => text()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get deletedAt =>
      dateTime().customConstraint('NOT NULL DEFAULT 0')();
  @override
  Set<Column<Object>> get primaryKey => {pluginId, key};
}

class PluginSecrets extends Table {
  TextColumn get pluginId => text()();
  TextColumn get key => text()();
  TextColumn get value => text()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column<Object>> get primaryKey => {pluginId, key};
}

final _log = AppLogger.forModule('Database');

@DriftDatabase(
  tables: [
    AppSettings,
    CustomThemes,
    AppStates,
    Novels,
    NovelCollections,
    NovelCollectionMembers,
    Agents,
    NovelAgentSkills,
    NovelAgentSkillReferences,
    NovelAgentSkillRevisions,
    NovelAgentSkillRevisionFiles,
    NovelAgentSkillBlobs,
    AiShortcutActions,
    AiProviders,
    GenerationTasks,
    ProviderAssets,
    ToolPermissionRules,
    AiUsages,
    AiChatSessions,
    SessionSubscriptions,
    AssistantSessions,
    AssistantMessages,
    AssistantInbox,
    Todos,
    FeatureUsages,
    ReadingProgress,
    AnonymousOutboxEvents,
    Assets,
    ProductionStyles,
    ImageBatches,
    ImageBatchSlots,
    ImageAssetReferences,
    PluginRegistry,
    PluginTasks,
    PluginStorage,
    PluginPermissions,
    PluginSecrets,
  ],
  daos: [
    PluginDao,
    PluginTaskDao,
    AiProviderDao,
    GenerationTaskDao,
    ProviderAssetDao,
    ToolPermissionDao,
    AppSettingsDao,
    NovelDao,
    NovelCollectionDao,
    GlobalAgentDao,
    NovelAgentSkillDao,
    NovelAgentSkillRevisionDao,
    AiShortcutActionDao,
    AiChatSessionDao,
    SessionSubscriptionsDao,
    AssistantSessionDao,
    AssistantInboxDao,
    AppStateDao,
    TodoDao,
    ReadingProgressDao,
    AnonymousOutboxDao,
    ImageAssetDao,
    AssetDao,
    ProductionStyleDao,
  ],
)
class AppDatabase extends _$AppDatabase {
  factory AppDatabase() {
    final cachedDatabase = _cachedDatabase;
    if (cachedDatabase != null) {
      cachedDatabase.referenceCount += 1;
      return cachedDatabase.database;
    }

    final database = AppDatabase._internal();
    _cachedDatabase = _CachedAppDatabase(database: database);
    return database;
  }

  AppDatabase._internal() : super(_openConnection());

  @visibleForTesting
  AppDatabase.forTest(super.executor);

  /// 供受控维护操作在内存库中生成当前 schema 参考。
  AppDatabase.forSchemaRepair(super.executor);

  static _CachedAppDatabase? _cachedDatabase;

  static const currentSchemaVersion = 6;

  @override
  int get schemaVersion => currentSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (migrator, from, to) async {
      final migrations = AppDatabaseMigrations(this);
      if (from < 2) {
        try {
          await migrations.migrateToV2(migrator);
        } catch (error, stackTrace) {
          _log.error(
            '[DB] CREATE plugin_registry/plugin_storage/plugin_secrets schema=2',
            error: error,
            stackTrace: stackTrace,
          );
          rethrow;
        }
      }
      if (from < 3) {
        try {
          await migrations.migrateToV3(migrator, from: from);
        } catch (error, stackTrace) {
          _log.error(
            '[DB] CREATE plugin_permissions/plugin_tasks / ALTER plugin_storage / DROP memories schema=3',
            error: error,
            stackTrace: stackTrace,
          );
          rethrow;
        }
      }
      if (from < 4) {
        try {
          await migrations.migrateToV4(migrator);
        } catch (error, stackTrace) {
          _log.error(
            '[DB] ALTER novel_collections ADD content_kind / split mixed collections schema=4',
            error: error,
            stackTrace: stackTrace,
          );
          rethrow;
        }
      }
      if (from < 5) {
        try {
          await migrations.migrateToV5(migrator);
        } catch (error, stackTrace) {
          _log.error(
            '[DB] ALTER provider_assets schema=5',
            error: error,
            stackTrace: stackTrace,
          );
          rethrow;
        }
      }
      if (from < 6) {
        try {
          await migrations.migrateToV6(migrator);
        } catch (error, stackTrace) {
          _log.error(
            '[DB] ALTER generation_tasks ADD image_outputs schema=6',
            error: error,
            stackTrace: stackTrace,
          );
          rethrow;
        }
      }
    },
    onCreate: (migrator) async {
      // checkpoint 立即落盘：原生崩溃（sqlite3.dll）会绕过 catch，
      // 这条日志用于区分"死在建库"与其它启动路径。
      _log.checkpoint('onCreate schema v$schemaVersion (native sqlite)');
      try {
        await migrator.createAll();
        await createAppDatabaseIndexes(migrator.database);
      } catch (error, stackTrace) {
        await StartupFailureReporter().report(
          phase: 'app_database_create',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
    },
  );

  @override
  Future<void> close() async {
    final cachedDatabase = _cachedDatabase;
    if (cachedDatabase == null) {
      return super.close();
    }

    cachedDatabase.referenceCount -= 1;
    if (cachedDatabase.referenceCount > 0) {
      return;
    }

    _cachedDatabase = null;
    await super.close();
  }

  /// Force-close the cached singleton, bypassing the reference count.
  ///
  /// This is used during app shutdown ([exit]) where [ProviderContainer.dispose]
  /// may not run, meaning the `ref.onDispose` callbacks in providers never fire.
  /// If the database is not explicitly closed before [exit], Dart's
  /// [NativeFinalizer]s (from `package:sqlite3`) fire during isolate shutdown in
  /// an unpredictable order — the database finalizer can close the SQLite handle
  /// before statement finalizers finish, causing a SIGSEGV in
  /// `sqlite3_finalize`.
  ///
  /// Call this from the system tray quit handler (and any other shutdown path)
  /// before calling `exit(0)`.
  static Future<void> closeCached() async {
    final cached = _cachedDatabase;
    if (cached != null) {
      _cachedDatabase = null;
      // After clearing the cache, the instance's close() takes the
      // `super.close()` path, bypassing ref-count checks.
      await cached.database.close();
    }
  }

  /// Closes the cached SQLite executor before replacing the database file.
  ///
  /// File replacement cannot wait for Drift's query streams to shut down: a
  /// paused listener may keep [GeneratedDatabase.close] pending indefinitely.
  /// The caller must restart the app before using database-backed features.
  static Future<void> closeCachedForFileReplacement() async {
    await _closeCachedExecutorImmediately();
  }

  /// Closes the cached SQLite executor immediately before process exit.
  ///
  /// Unlike [closeCached], this deliberately skips Drift's query-stream
  /// shutdown. A paused stream listener can prevent `GeneratedDatabase.close`
  /// from completing indefinitely, while the executor still needs to close so
  /// SQLite native resources are released in a deterministic order.
  static Future<void> closeCachedForProcessExit() async {
    await _closeCachedExecutorImmediately();
  }

  static Future<void> _closeCachedExecutorImmediately() async {
    final cached = _cachedDatabase;
    if (cached != null) {
      _cachedDatabase = null;
      await cached.database._closeExecutorImmediately();
    }
  }

  Future<void> _closeExecutorImmediately() => executor.close();

  @visibleForTesting
  Future<void> closeExecutorForProcessExitForTesting() {
    return _closeExecutorImmediately();
  }
}

QueryExecutor _openConnection() {
  return driftDatabase(
    name: 'reveric',
    native: DriftNativeOptions(
      databasePath: () async {
        final dir = await getApplicationSupportDirectory();
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        final safeDir = toWindowsSafePath(dir.path);
        final dbPath = p.join(safeDir, 'reveric.sqlite');
        if (_log.isDebugEnabled) {
          _log.debug('resolved path: $dbPath');
        }
        return dbPath;
      },
      tempDirectoryPath: () async {
        final dir = await getTemporaryDirectory();
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        return toWindowsSafePath(dir.path);
      },
    ),
  );
}

class _CachedAppDatabase {
  _CachedAppDatabase({required this.database});

  final AppDatabase database;
  int referenceCount = 1;
}

/// Read-only media summaries for asset library and reference displays.
/// Type-specific editing uses the concrete content type.
extension AssetMediaSummary on AssetRow {
  int? get width => switch (content) {
    ImageAssetContent(:final width) || VideoAssetContent(:final width) => width,
    _ => null,
  };
  int? get height => switch (content) {
    ImageAssetContent(:final height) ||
    VideoAssetContent(:final height) => height,
    _ => null,
  };
  int? get durationMs => switch (content) {
    VideoAssetContent(:final durationMs) ||
    AudioAssetContent(:final durationMs) => durationMs,
    _ => null,
  };
  String? get mimeType => switch (content) {
    MediaAssetContent(:final mimeType) => mimeType,
    _ => null,
  };
  int? get bytes => switch (content) {
    MediaAssetContent(:final bytes) => bytes,
    _ => null,
  };
  String? get prompt => switch (content) {
    MediaAssetContent(:final generation) => generation?.prompt,
    _ => null,
  };
  String? get model => switch (content) {
    MediaAssetContent(:final generation) => generation?.model,
    _ => null,
  };
}

extension GenerationTaskRequest on GenerationTask {
  List<String> get resultAssetIds => imageOutputs == null
      ? [?resultAssetId]
      : [for (final item in imageOutputs!.items) ?item.assetId];

  AudioRequest get audioRequest =>
      (requestJson as AudioGenerationRequest).request;
  VideoRequest get videoRequest =>
      (requestJson as VideoGenerationRequest).request;
  List<VideoInput> get videoInputs =>
      (requestJson as VideoGenerationRequest).inputs;
  ProductionImageRequest get imageRequest =>
      (requestJson as ImageGenerationRequest).request;
}

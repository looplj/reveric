// 职责: 统一导出 Drift 生成的 DataClass，业务层统一从此导入
// 关联文件:
//   lib/shared/database/novel_content_database.dart
//   lib/shared/database/app_database.dart

export 'agent_rule.dart';
export 'ai_chat_session.dart';
export 'chapter.dart';
export 'character_profile.dart';
export 'document.dart';
export 'foreshadowing.dart';
export 'item.dart';
export 'location.dart';
export 'novel.dart';
export 'novel_state.dart';
export 'outline.dart';
export 'todo.dart';
export 'working_change.dart';

export '../database/novel_content_database.dart'
    show
        AiChatMessage,
        AiChatMessages,
        AiChatMessagesCompanion,
        AiEmbeddingDocument,
        AiEmbeddingDocuments,
        AiEmbeddingDocumentsCompanion,
        ChangeCommit,
        ChangeCommits,
        ChangeCommitsCompanion,
        ChangeCommitItem,
        ChangeCommitItems,
        ChangeCommitItemsCompanion,
        EntityRelation,
        EntityRelations,
        EntityRelationsCompanion,
        MapLocation,
        MapLocations,
        MapLocationsCompanion,
        NovelMap,
        NovelMaps,
        NovelMapsCompanion;

export '../database/app_database.dart'
    show
        AiProvider,
        AiProviders,
        AiProvidersCompanion,
        AppSetting,
        AppSettings,
        AppSettingsCompanion,
        AppState,
        AppStates,
        AppStatesCompanion,
        GlobalAgent,
        Agents,
        AgentsCompanion;

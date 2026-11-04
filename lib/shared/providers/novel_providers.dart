// 职责: 装配作品内容库与工作区服务，并在删除内容库前等待所属聊天运行态收尾。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/services/novel_actions.dart
//   lib/shared/services/working_overlay.dart
//   lib/shared/providers/ai_providers.dart
import 'dart:async';
import 'tool_operations.dart';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:drift/drift.dart' show TableInfo;
import 'package:flutter/foundation.dart' show listEquals;

import '../database/app_database.dart';
import '../database/novel_content_database.dart';
import '../models/ai_session_mode.dart';
import '../models/outline.dart';
import '../services/ai/session_persistence.dart';
import '../services/novel_content.dart';
import '../services/novel_actions.dart';
import '../services/novel_export.dart';
import '../services/image_library_service.dart';
import '../services/working_overlay.dart';
import '../services/working_change_summary.dart';
import 'production_media.dart' show mediaLibraryServiceProvider;
import 'ai_providers.dart' show AiChatCancelSource, aiChatRuntimeProvider;

part 'novel_providers.g.dart';

@Riverpod(keepAlive: true)
AppDatabase appDatabase(Ref ref) {
  final database = AppDatabase();
  ref.onDispose(database.close);
  return database;
}

@Riverpod(keepAlive: true)
ImageLibraryService imageLibraryService(Ref ref) {
  return ImageLibraryService(
    ref.watch(appDatabaseProvider),
    () => ref.read(mediaLibraryServiceProvider),
  );
}

@riverpod
Stream<List<AssetRow>> imageAssets(
  Ref ref,
  String? novelId, {
  String? purpose,
}) {
  return ref
      .watch(appDatabaseProvider)
      .imageAssetDao
      .watchAssets(novelId: novelId, purpose: purpose);
}

@riverpod
Stream<List<ImageBatchRow>> imageBatches(
  Ref ref,
  String? novelId, {
  String? purpose,
}) {
  return ref
      .watch(appDatabaseProvider)
      .imageAssetDao
      .watchBatches(novelId: novelId, purpose: purpose);
}

@riverpod
Stream<List<ImageBatchSlotRow>> imageBatchSlots(Ref ref, String batchId) {
  return ref.watch(appDatabaseProvider).imageAssetDao.watchSlots(batchId);
}

@riverpod
Stream<List<Novel>> novels(Ref ref) {
  final database = ref.watch(appDatabaseProvider);
  return database.novelDao.watchAll();
}

/// 回收站中的作品。
@riverpod
Stream<List<Novel>> deletedNovels(Ref ref) {
  final database = ref.watch(appDatabaseProvider);
  return database.novelDao.watchDeleted();
}

@riverpod
Stream<Novel?> novel(Ref ref, String novelId) {
  final database = ref.watch(appDatabaseProvider);
  return database.novelDao.watch(novelId);
}

@riverpod
Stream<Novel?> novelByContentDatabasePath(Ref ref, String databasePath) {
  final database = ref.watch(appDatabaseProvider);
  return database.novelDao.watchByContentDatabasePath(databasePath);
}

@riverpod
NovelActionsService novelActions(Ref ref) {
  final database = ref.watch(appDatabaseProvider);
  final container = ref.container;
  return NovelActionsService(
    database,
    imageLibraryService: ref.watch(imageLibraryServiceProvider),

    onBeforeDeleteContentDatabase: (novelId, databasePath) async {
      // 包含已隐藏和子会话：仍在收尾的执行体也不能访问即将关闭的内容库。
      final sessions = await (database.select(
        database.aiChatSessions,
      )..where((row) => row.novelId.equals(novelId))).get();
      final runtimes = [
        for (final session in sessions)
          if (container.exists(aiChatRuntimeProvider(session.id)))
            (
              session.id,
              container.read(aiChatRuntimeProvider(session.id).notifier),
            ),
      ];
      await Future.wait([
        for (final (_, runtime) in runtimes)
          runtime.stopAll(source: AiChatCancelSource.workDeleted),
      ]);
      for (final (sessionId, _) in runtimes) {
        container.invalidate(aiChatRuntimeProvider(sessionId));
      }
      // 内容服务依赖 novelActions，删除时由容器统一清理，避免 Ref 反向访问依赖者。
      container.invalidate(workingOverlayServiceProvider(databasePath));
      container.invalidate(novelContentServiceProvider(databasePath));
      container.invalidate(novelContentDatabaseProvider(databasePath));
      await Future<void>.delayed(Duration.zero);
    },
  );
}

@Riverpod(keepAlive: true)
NovelContentDatabase novelContentDatabase(Ref ref, String databasePath) {
  final database = NovelContentDatabase(databasePath);
  ref.onDispose(database.close);
  return database;
}

@riverpod
NovelContentService novelContentService(Ref ref, String databasePath) {
  final database = ref.watch(novelContentDatabaseProvider(databasePath));
  final novelActions = ref.watch(novelActionsProvider);
  return NovelContentService(
    database,
    novelActionsService: novelActions,
    imageLibraryService: ref.watch(imageLibraryServiceProvider),
  );
}

@riverpod
NovelExportService novelExport(Ref ref, String databasePath) {
  final contentService = ref.watch(novelContentServiceProvider(databasePath));
  return NovelExportService(contentService);
}

@riverpod
WorkingOverlayService workingOverlayService(Ref ref, String databasePath) {
  final contentDatabase = ref.watch(novelContentDatabaseProvider(databasePath));
  final contentService = ref.watch(novelContentServiceProvider(databasePath));
  final novelActions = ref.watch(novelActionsProvider);
  return WorkingOverlayService(
    contentDatabase,
    contentService,
    novelActionsService: novelActions,
  );
}

@riverpod
Stream<List<Chapter>> chapters(Ref ref, String databasePath) {
  final service = ref.watch(novelContentServiceProvider(databasePath));
  return service.watchChapters();
}

@riverpod
Stream<List<Chapter>> chapterTree(Ref ref, String databasePath) {
  final service = ref.watch(novelContentServiceProvider(databasePath));
  return service.watchChapterTree();
}

/// 当前故事状态快照（最新 active）。没有快照时发出 null。
@riverpod
Stream<NovelStateSnapshot?> currentStateSnapshot(Ref ref, String databasePath) {
  final service = ref.watch(novelContentServiceProvider(databasePath));
  return service.watchCurrentStateSnapshot();
}

@riverpod
Stream<Chapter?> chapterById(
  Ref ref, {
  required String path,
  required String chapterId,
}) {
  final service = ref.watch(novelContentServiceProvider(path));
  return service.watchChapterById(chapterId);
}

/// 编辑器正文加载专用：只含原表正文列，不含 VIEW 计算章号（章号走章节树）。
/// 避开 `chapters` VIEW 的窗口函数开销，详见 [ChapterDao.watchContentById]。
@riverpod
Stream<Chapter?> chapterContentById(
  Ref ref, {
  required String path,
  required String chapterId,
}) {
  final service = ref.watch(novelContentServiceProvider(path));
  return service.watchChapterContentById(chapterId);
}

@riverpod
Stream<Chapter?> lastWrittenChapter(Ref ref, String databasePath) {
  final service = ref.watch(novelContentServiceProvider(databasePath));
  return service.watchLastWrittenChapter();
}

@riverpod
Stream<Chapter?> lastEditedChapter(Ref ref, String databasePath) {
  final service = ref.watch(novelContentServiceProvider(databasePath));
  return service.watchLastEditedChapter();
}

@riverpod
Stream<List<CharacterProfile>> characterProfiles(Ref ref, String databasePath) {
  final service = ref.watch(novelContentServiceProvider(databasePath));
  return service.watchCharacterProfiles();
}

@riverpod
Stream<List<Item>> items(
  Ref ref, {
  required String path,
  required String type,
}) {
  final service = ref.watch(novelContentServiceProvider(path));
  return service.watchItemsByType(type);
}

@riverpod
Stream<List<Foreshadowing>> foreshadowings(Ref ref, String databasePath) {
  final service = ref.watch(novelContentServiceProvider(databasePath));
  return service.watchForeshadowings();
}

@riverpod
Stream<List<WorkingChange>> workingChanges(Ref ref, String databasePath) {
  final service = ref.watch(workingOverlayServiceProvider(databasePath));
  return service.watchWorkingChanges();
}

@riverpod
Stream<List<WorkingChange>> sessionChanges(
  Ref ref,
  String databasePath,
  String? sessionId,
) {
  final service = ref.watch(workingOverlayServiceProvider(databasePath));
  return service.watchSessionChanges(sessionId);
}

/// 只订阅审阅涉及的资源表；直接手动编辑也会使右侧快照刷新。
@riverpod
Stream<List<WorkingFieldReview>> workingFieldReviews(
  Ref ref,
  String databasePath,
  List<WorkingChange> changes,
) {
  final service = ref.watch(workingOverlayServiceProvider(databasePath));
  final db = ref.watch(novelContentServiceProvider(databasePath)).database;
  final tables = <TableInfo>{db.workingChanges};
  for (final type in changes.map((row) => row.resourceType).toSet()) {
    tables.addAll(switch (type) {
      'novel' => <TableInfo>[],
      'chapters' || 'volumes' => [db.chapters],
      'characters' => [db.characterProfiles],
      'foreshadowing' => [db.foreshadowings],
      'locations' => [db.locations],
      'outlines' => [db.outlines, db.outlineBeats, db.documents],
      'screenplay_scenes' => [db.screenplayScenes, db.screenplaySceneElements],
      'screenplay_episodes' => [db.screenplayEpisodes],
      'production_clips' => [db.productionClips],
      'lore' || 'worldbuilding' || 'materials' => [db.documents],
      _ => [db.items],
    });
  }
  if (changes.any((row) => row.resourceType == 'novel')) {
    ref.watch(novelByContentDatabasePathProvider(databasePath));
  }
  return db
      .customSelect('SELECT 1', readsFrom: tables)
      .watch()
      .asyncMap((_) async {
        final current = <WorkingChange>[];
        for (final row in changes) {
          final saved = await db.workingChangeDao.getById(row.id);
          if (saved != null &&
              (saved.status == workingChangeStatusActive ||
                  saved.status == workingChangeStatusCommitted)) {
            current.add(saved);
          }
        }
        return service.resolveFieldReviews(current);
      })
      .distinct(listEquals);
}

@riverpod
Stream<List<ChangeCommit>> changeCommits(
  Ref ref, {
  required String path,
  int? limit,
}) {
  final service = ref.watch(workingOverlayServiceProvider(path));
  return service.watchChangeCommits(limit: limit);
}

@riverpod
Future<List<ChangeCommitItem>> changeCommitItems(
  Ref ref, {
  required String path,
  required String commitId,
}) {
  final service = ref.watch(workingOverlayServiceProvider(path));
  return service.getChangeCommitItemsForCommit(commitId);
}

@riverpod
Future<List<ChangeCommitItem>> changeCommitResourceItems(
  Ref ref, {
  required String path,
  required String commitId,
  required String resourceId,
}) {
  ref.watch(changeCommitsProvider(path: path, limit: null));
  final service = ref.watch(workingOverlayServiceProvider(path));
  return service.getChangeCommitItemsForCommitAndResourceId(
    commitId,
    resourceId,
  );
}

@riverpod
Future<List<ChangeCommitItem>> resourceChangeHistory(
  Ref ref, {
  required String path,
  required String resourcePath,
  int? limit,
}) {
  ref.watch(changeCommitsProvider(path: path, limit: null));
  final service = ref.watch(workingOverlayServiceProvider(path));
  return service.getChangeCommitItemsForResource(resourcePath, limit: limit);
}

@riverpod
Future<List<ChangeCommitItem>> resourceIdChangeHistory(
  Ref ref, {
  required String path,
  required String resourceId,
  int? limit,
}) {
  ref.watch(changeCommitsProvider(path: path, limit: null));
  final service = ref.watch(workingOverlayServiceProvider(path));
  return service.getChangeCommitItemsForResourceId(resourceId, limit: limit);
}

@Riverpod(keepAlive: true)
AiSessionPersistenceService aiSessionPersistenceService(
  Ref ref, {
  required String novelId,
  String? databasePath,
}) {
  final database = ref.watch(appDatabaseProvider);
  final novelContentDatabase = databasePath != null
      ? ref.watch(novelContentDatabaseProvider(databasePath))
      : null;
  return AiSessionPersistenceService(
    database,
    novelId,
    novelContentDatabase: novelContentDatabase,
    operationRecords: ref.watch(toolOperationRegistryProvider).forSession,
  );
}

final _excludedSpecialModes = [
  AiSessionMode.council.value,
  AiSessionMode.monologue.value,
  AiSessionMode.theater.value,
  AiSessionMode.roleplay.value,
];

@riverpod
Stream<List<AiChatSession>> aiChatSessions(
  Ref ref, {
  required String novelId,
  String? databasePath,
}) {
  final service = ref.watch(
    aiSessionPersistenceServiceProvider(
      novelId: novelId,
      databasePath: databasePath,
    ),
  );
  return service.watchSessionsExcludingModes(_excludedSpecialModes);
}

/// 当前小说的 chat 会话总数（不含 council / monologue / theater / roleplay）。
///
/// 用于 setup_phase 门控等只需数量的场景；用 SQL COUNT，不加载会话列表。
@riverpod
Stream<int> novelChatSessionCount(
  Ref ref, {
  required String novelId,
  String? databasePath,
}) {
  final service = ref.watch(
    aiSessionPersistenceServiceProvider(
      novelId: novelId,
      databasePath: databasePath,
    ),
  );
  return service.watchChatSessionCountExcludingModes(_excludedSpecialModes);
}

@riverpod
Stream<({List<AiChatSession> sessions, bool hasMore})> aiChatSessionsPage(
  Ref ref, {
  required String novelId,
  String? databasePath,
  required int limit,
}) {
  final service = ref.watch(
    aiSessionPersistenceServiceProvider(
      novelId: novelId,
      databasePath: databasePath,
    ),
  );
  return service
      .watchSessionsExcludingModes(_excludedSpecialModes, limit: limit + 1)
      .map((sessions) {
        final hasMore = sessions.length > limit;
        return (
          sessions: hasMore ? sessions.take(limit).toList() : sessions,
          hasMore: hasMore,
        );
      });
}

/// 监听当前 novel 在 `novel_states` 表中持久化的 active chat session id。
///
/// 进入 NovelEditor 时若 `initialSessionId` 为空，应优先使用该 id 还原上次
/// active 的 chat 会话，而不是 fallback 到「最近更新」的会话。
@riverpod
Stream<String?> activeChatSessionId(
  Ref ref, {
  required String novelId,
  String? databasePath,
}) {
  final service = ref.watch(
    aiSessionPersistenceServiceProvider(
      novelId: novelId,
      databasePath: databasePath,
    ),
  );
  return service.watchActiveSessionId();
}

@riverpod
Stream<List<AiChatSession>> aiChatSessionsByMode(
  Ref ref, {
  required String novelId,
  String? databasePath,
  required String mode,
}) {
  final service = ref.watch(
    aiSessionPersistenceServiceProvider(
      novelId: novelId,
      databasePath: databasePath,
    ),
  );
  return service.watchSessionsByMode(mode);
}

@riverpod
Stream<List<Document>> documents(
  Ref ref, {
  required String path,
  required String type,
}) {
  final service = ref.watch(novelContentServiceProvider(path));
  return service.documentsService.watchDocumentsByType(type);
}

@riverpod
Stream<List<OutlineDraft>> outlines(Ref ref, String databasePath) {
  final service = ref.watch(novelContentServiceProvider(databasePath));
  return service.outlineService.watchAll();
}

@riverpod
Stream<OutlineDraft?> outline(
  Ref ref, {
  required String path,
  required String documentId,
}) {
  final service = ref.watch(novelContentServiceProvider(path));
  return service.outlineService.watchByDocumentId(documentId);
}

@riverpod
Stream<List<RelationSummary>> entityRelations(
  Ref ref, {
  required String path,
  required String entityType,
  required String entityId,
  String? relationType,
}) {
  final service = ref.watch(novelContentServiceProvider(path));
  return service.entityRelationsService.watchRelationsForEntity(
    entityType: entityType,
    entityId: entityId,
    relationType: relationType,
  );
}

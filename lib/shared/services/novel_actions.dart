// 职责: 小说元数据操作 — 创建、更新、删除作品并管理封面文件和内容库连接。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/database/novel_content_daos/novel_state_dao.dart
//   lib/shared/models/content_kind.dart
//   lib/shared/models/novel_type.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/logger/app_logger.dart
import 'dart:io';
import 'package:reveric/shared/models/asset_purpose.dart';

import 'package:flutter/foundation.dart';

import '../database/app_database.dart';
import '../database/novel_content_database.dart';
import '../models/content_kind.dart';
import '../models/novel_type.dart';
import '../models/production/default_style.dart';
import '../logger/app_logger.dart';
import '../utils/short_entity_id.dart';
import '../utils/storage_paths.dart';
import 'image_library_service.dart';
import 'novel_content.dart';
import 'screenplay_service.dart';

final _log = AppLogger.forModule('NovelActions');

class NovelTitleConflictException implements Exception {
  const NovelTitleConflictException(this.title);

  final String title;

  @override
  String toString() => 'Novel title conflict: "$title"';
}

class NovelActionsService {
  NovelActionsService(
    this._database, {
    this._onBeforeDeleteContentDatabase,
    this._imageLibraryService,
    @visibleForTesting
    NovelContentDatabase Function(String path)? contentDatabaseFactory,
    @visibleForTesting this._seedNovelWorkspace,
    @visibleForTesting this._seedScreenplayWorkspace,
    @visibleForTesting
    Future<void> Function(NovelContentDatabase database)? closeContentDatabase,
    @visibleForTesting this._finalizeScreenplayCreation,
  }) : _contentDatabaseFactory =
           contentDatabaseFactory ?? NovelContentDatabase.new,
       _closeContentDatabaseForCreation = closeContentDatabase;

  final AppDatabase _database;
  final Future<void> Function(String novelId, String databasePath)?
  _onBeforeDeleteContentDatabase;
  final ImageLibraryService? _imageLibraryService;
  final NovelContentDatabase Function(String path) _contentDatabaseFactory;
  final Future<void> Function(NovelContentDatabase database)?
  _seedNovelWorkspace;
  final Future<void> Function(
    NovelContentDatabase database,
    int? plannedEpisodeCount,
  )?
  _seedScreenplayWorkspace;
  final Future<void> Function(NovelContentDatabase database)?
  _closeContentDatabaseForCreation;
  final Future<void> Function({
    required String id,
    required String contentDatabasePath,
    required bool requestedDraft,
  })?
  _finalizeScreenplayCreation;

  Future<String> createNovel({
    required String title,
    required String description,
    String? authorName,
    String? coverSourcePath,
    List<String>? tags,
    String? category,
    String? type,
    String contentKind = contentKindNovel,
    String? sourceNovelId,
    int? plannedEpisodeCount,
    bool setNovelOnboardingEligible = true,
    bool draft = false,
  }) async {
    if (!draft) {
      await _ensureShelfTitleAvailable(title);
    }
    final novelId = buildShortEntityId(
      contentKind == contentKindScreenplay
          ? ShortEntityIdType.screenplay
          : ShortEntityIdType.novel,
    );
    final coverAssetId = await _storeCoverFile(
      novelId: novelId,
      coverSourcePath: coverSourcePath,
    );
    await _database.novelDao.create(
      id: novelId,
      title: title,
      authorName: authorName,
      description: description,
      coverAssetId: coverAssetId,
      tags: tags,
      category: category,
      type: type ?? novelTypeOriginal,
      contentKind: contentKind,
      sourceNovelId: sourceNovelId,
      draft: contentKind == contentKindScreenplay ? true : draft,
    );
    try {
      final contentDatabasePath = await buildNovelContentDatabasePath(novelId);
      await _initializeContentDatabase(
        contentDatabasePath: contentDatabasePath,
        contentKind: contentKind,
        category: category,
        tags: tags,
        plannedEpisodeCount: plannedEpisodeCount,
        setNovelOnboardingEligible: setNovelOnboardingEligible,
      );
      if (contentKind == contentKindScreenplay) {
        final finalize = _finalizeScreenplayCreation;
        if (finalize == null) {
          await _database.novelDao.finalizeCreation(
            id: novelId,
            contentDatabasePath: contentDatabasePath,
            requestedDraft: draft,
          );
        } else {
          await finalize(
            id: novelId,
            contentDatabasePath: contentDatabasePath,
            requestedDraft: draft,
          );
        }
      } else {
        await _database.novelDao.updateContentDatabasePath(
          id: novelId,
          contentDatabasePath: contentDatabasePath,
        );
      }
    } catch (error, stackTrace) {
      await _compensateFailedCreation(novelId, error, stackTrace);
      Error.throwWithStackTrace(error, stackTrace);
    }
    return novelId;
  }

  Future<void> _initializeContentDatabase({
    required String contentDatabasePath,
    required String contentKind,
    required String? category,
    required List<String>? tags,
    required int? plannedEpisodeCount,
    required bool setNovelOnboardingEligible,
  }) async {
    final contentDatabase = _contentDatabaseFactory(contentDatabasePath);
    Object? operationError;
    try {
      if (contentKind == contentKindScreenplay) {
        final seedScreenplay = _seedScreenplayWorkspace;
        if (seedScreenplay == null) {
          await ScreenplayService(contentDatabase).createInitialStructure(
            plannedEpisodeCount: plannedEpisodeCount,
            style: initialProductionStyle(
              category: category,
              tags: tags ?? const [],
            ),
          );
        } else {
          await seedScreenplay(contentDatabase, plannedEpisodeCount);
        }
        return;
      }
      final seedNovel = _seedNovelWorkspace;
      if (seedNovel == null) {
        await contentDatabase.seedDefaultWorkspace();
      } else {
        await seedNovel(contentDatabase);
      }
      if (!setNovelOnboardingEligible) {
        return;
      }
      try {
        await contentDatabase.novelStateDao.upsert(
          key: 'novel_onboarding',
          status: 'eligible',
        );
      } catch (error, stackTrace) {
        _log.error(
          '[DB][novel_states][UPSERT] key=novel_onboarding status=eligible failed path=$contentDatabasePath',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
    } catch (error, stackTrace) {
      operationError = error;
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      try {
        final closeContentDatabase = _closeContentDatabaseForCreation;
        if (closeContentDatabase == null) {
          await contentDatabase.close();
        } else {
          await closeContentDatabase(contentDatabase);
        }
      } catch (error, stackTrace) {
        if (operationError == null) {
          rethrow;
        }
        _log.error(
          '[DB][content][CLOSE] failed after create failure path=$contentDatabasePath',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  Future<void> _compensateFailedCreation(
    String novelId,
    Object creationError,
    StackTrace creationStackTrace,
  ) async {
    try {
      await _database.novelDao.softDelete(novelId);
    } catch (error, stackTrace) {
      _log.error(
        '[DB][novels][COMPENSATE_CREATE] failed id=$novelId; original=$creationError',
        error: error,
        stackTrace: stackTrace,
      );
      _log.error(
        '[DB][novels][CREATE] original failure id=$novelId',
        error: creationError,
        stackTrace: creationStackTrace,
      );
    }
  }

  /// 快速开书：用占位标题建一部最小作品（原创、无简介/分类/标签/封面），
  /// 返回新作品 id。其余设定留给编辑器内的创作向导 onboarding 引导补全。
  /// [untitledTitle] 由调用方按当前 locale 传入（如「未命名作品」）。
  Future<String> createQuickStartNovel({required String untitledTitle}) async {
    return createNovel(
      title: untitledTitle,
      description: '',
      category: '',
      type: novelTypeOriginal,
      tags: const [],
      draft: true,
    );
  }

  /// 「加入书架」：清除快速开书占位标记，让作品正式进入书库。
  /// 由编辑器「加入书架」按钮或 Run 的 add-to-library 命令显式触发，不耦合写入动作。
  Future<void> clearNovelDraft(String novelId) async {
    try {
      await _database.transaction(() async {
        final novel = await _database.novelDao.get(novelId);
        if (novel == null || !novel.draft) {
          return;
        }
        await _ensureShelfTitleAvailable(novel.title, excludingId: novel.id);
        await _database.novelDao.updateDraft(id: novelId, draft: false);
      });
    } catch (error, stackTrace) {
      _log.error(
        '[DB][novels][PUBLISH] failed id=$novelId',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> deleteNovel(Novel novel) async {
    await _closeContentDatabase(novel.id, novel.contentDatabasePath);
    try {
      await _database.transaction(() async {
        await _deleteMainDatabaseNovelResources(novel.id);
        await _database.novelDao.hardDelete(novel.id);
      });
    } catch (error, stackTrace) {
      _log.error(
        '[DB][novels][DELETE] failed id=${novel.id}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> _deleteMainDatabaseNovelResources(String novelId) async {
    await _database.customStatement(
      '''
DELETE FROM todos
WHERE session_id IN (
  SELECT id FROM ai_chat_sessions WHERE novel_id = ?
)
''',
      [novelId],
    );
    // NovelAgentSkill 现为应用级全局技能，不再随小说删除而清理。
    await (_database.delete(
      _database.aiChatSessions,
    )..where((table) => table.novelId.equals(novelId))).go();
    await (_database.delete(
      _database.agents,
    )..where((table) => table.novelId.equals(novelId))).go();
  }

  Future<void> updateNovel({
    required Novel novel,
    required String title,
    required String description,
    String? authorName,
    String? coverSourcePath,

    /// 直接换成已登记的图片资产（封面工作室采用生成结果）；优先于 [coverSourcePath]。
    String? coverAssetId,
    required bool removeCover,
    List<String>? tags,
    String? category,
    String? type,
    bool updateSourceNovel = false,
    String? sourceNovelId,
  }) async {
    if (!novel.draft) {
      await _ensureShelfTitleAvailable(title, excludingId: novel.id);
    }
    final nextCoverAssetId = await _resolveUpdatedCover(
      novel: novel,
      coverSourcePath: coverSourcePath,
      coverAssetId: coverAssetId,
      removeCover: removeCover,
    );
    await _database.transaction(() async {
      final nextSourceNovelId = updateSourceNovel
          ? sourceNovelId
          : novel.sourceNovelId;
      await _database.novelDao.updateDetails(
        id: novel.id,
        title: title,
        authorName: authorName,
        description: description,
        coverAssetId: nextCoverAssetId,
        tags: tags,
        category: category,
        type: type,
      );
      if (updateSourceNovel || (type != null && type != novel.type)) {
        await _database.novelDao.updateSourceNovel(
          id: novel.id,
          sourceNovelId: nextSourceNovelId,
        );
      }
    });
  }

  /// 更新 AI 工具传入的作品元数据字段，不读取/回写未变更字段。
  Future<void> updateNovelMetadata({
    required String novelId,
    String? title,
    String? authorName,
    String? description,
    List<String>? tags,
    String? category,
  }) async {
    if (title == null &&
        authorName == null &&
        description == null &&
        tags == null &&
        category == null) {
      return;
    }
    await _database.transaction(() async {
      if (title != null) {
        final novel = await _database.novelDao.get(novelId);
        if (novel == null) {
          throw StateError('Novel not found: $novelId');
        }
        if (!novel.draft) {
          await _ensureShelfTitleAvailable(title, excludingId: novelId);
        }
      }
      final updated = await _database.novelDao.updateMetadata(
        id: novelId,
        title: title,
        authorName: authorName,
        description: description,
        tags: tags,
        category: category,
      );
      if (updated == 0) {
        throw StateError('Novel not found: $novelId');
      }
    });
  }

  /// 内容编辑只更新所属作品的时间，保留主记录的元数据与字数。
  /// 尚未绑定到作品的内容库（初始化、导入）不参与书库排序。
  Future<void> markContentEdited(String contentDatabasePath) async {
    final novel = await getNovelByContentDatabasePath(contentDatabasePath);
    if (novel == null) {
      return;
    }
    await _database.novelDao.updateMetadata(id: novel.id);
  }

  Future<void> updateNovelWordCount({
    required String novelId,
    required int wordCount,
  }) async {
    await _database.novelDao.updateWordCount(id: novelId, wordCount: wordCount);
  }

  Future<void> updateNovelStatus({
    required String novelId,
    required String status,
  }) async {
    await _database.novelDao.updateStatus(id: novelId, status: status);
  }

  Future<Novel?> getNovel(String novelId) {
    return _database.novelDao.get(novelId);
  }

  Future<List<Novel>> getNovels() {
    return _database.novelDao.getAll();
  }

  Future<Novel?> findNovelByTitle(String title) {
    return _database.novelDao.getShelfByTitle(title);
  }

  Future<void> _ensureShelfTitleAvailable(
    String title, {
    String? excludingId,
  }) async {
    final existing = await _database.novelDao.getShelfByTitle(title);
    if (existing != null && existing.id != excludingId) {
      throw NovelTitleConflictException(title);
    }
  }

  Future<Novel?> getNovelByContentDatabasePath(
    String contentDatabasePath,
  ) async {
    final relativePath = RevericPaths.toRelative(contentDatabasePath);
    final directPaths = <String>{contentDatabasePath};
    if (relativePath != null) {
      directPaths.add(relativePath);
    }
    for (final path in directPaths) {
      final novel = await _database.novelDao.getByContentDatabasePath(path);
      if (novel != null) {
        return novel;
      }
    }

    return null;
  }

  Future<String> ensureNovelContentDatabasePath(Novel novel) async {
    final existingPath = novel.contentDatabasePath;
    if (existingPath != null && existingPath.isNotEmpty) {
      // 解析存储路径后检查内容库是否存在。
      final resolvedPath = RevericPaths.resolveDatabasePath(existingPath);
      final exists = await File(resolvedPath).exists();
      if (exists) {
        final contentDatabase = NovelContentDatabase(existingPath);
        await contentDatabase.seedDefaultWorkspace();
        await contentDatabase.close();
        // 返回存储原值（相对路径），保持其作为 Riverpod family key 的一致性。
        return existingPath;
      }
    }

    final databasePath = await buildNovelContentDatabasePath(novel.id);
    final contentDatabase = NovelContentDatabase(databasePath);
    await contentDatabase.seedDefaultWorkspace();
    await contentDatabase.close();
    await _database.novelDao.updateContentDatabasePath(
      id: novel.id,
      contentDatabasePath: databasePath,
    );
    return databasePath;
  }

  Future<String?> _storeCoverFile({
    required String novelId,
    required String? coverSourcePath,
  }) async {
    if (coverSourcePath == null || coverSourcePath.isEmpty) {
      return null;
    }

    final library = _imageLibraryService;
    if (library == null) {
      throw StateError('Novel covers require the image library.');
    }
    final asset = await library.importFile(
      coverSourcePath,
      novelId: novelId,
      purpose: AssetPurpose.cover,
    );
    return asset.id;
  }

  Future<void> _closeContentDatabase(
    String novelId,
    String? databasePath,
  ) async {
    if (databasePath == null || databasePath.isEmpty) {
      return;
    }
    try {
      // 回调用存储原值（相对路径）作 key 失效相关 provider；closeCached 内部会
      // resolve 到当前根以关闭缓存连接。
      await _onBeforeDeleteContentDatabase?.call(novelId, databasePath);
      await NovelContentDatabase.closeCached(databasePath);
    } catch (error, stackTrace) {
      _log.error(
        '[DB][novel_content_database][CLOSE] failed path=$databasePath',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<String?> _resolveUpdatedCover({
    required Novel novel,
    required String? coverSourcePath,
    required String? coverAssetId,
    required bool removeCover,
  }) async {
    if (removeCover) {
      return null;
    }
    if (coverAssetId != null) {
      return coverAssetId;
    }
    if (coverSourcePath == null || coverSourcePath.isEmpty) {
      return novel.coverAssetId;
    }
    return await _storeCoverFile(
          novelId: novel.id,
          coverSourcePath: coverSourcePath,
        ) ??
        novel.coverAssetId;
  }
}

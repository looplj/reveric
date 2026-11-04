// 职责: 彻底删除在回收站停留超过保留期的作品，连同其会话、内容库与作品文件。
// 关联文件:
//   lib/shared/services/storage_cleanup_service.dart
//   lib/shared/services/novel_actions.dart
//   lib/shared/database/daos/novel_dao.dart
//   lib/shared/utils/storage_paths.dart
// 遵循的 Rules:
//   .agents/rules/data-deletion.md
//   .agents/rules/error-handling.md

part of '../storage_cleanup_service.dart';

class _DeletedWorksResult {
  /// 主库记录已删除的作品数；文件阶段失败的作品也计入，残留文件只记日志。
  var purged = 0;

  /// 记录删除前失败、下轮重试的作品数。
  var failed = 0;
}

extension on StorageCleanupService {
  /// 彻底删除 `deleted_at` 早于 [cutoff] 的回收站作品；[cutoff] 与其他清理
  /// 共用同一个保留期设置。
  Future<_DeletedWorksResult> _purgeDeletedWorks(
    Map<String, CleanupSession> sessions,
    Map<String, NovelContentDatabase> contents,
    DateTime cutoff,
  ) async {
    final result = _DeletedWorksResult();
    final rows = await _appDatabase
        .customSelect(
          'SELECT id, content_database_path FROM novels '
          'WHERE deleted_at > 0 AND deleted_at < ? ORDER BY id',
          variables: [Variable<DateTime>(cutoff)],
        )
        .get();
    for (final row in rows) {
      final novelId = row.read<String>('id');
      final permit = _coordinator.tryAcquireCleanup(novelId);
      if (permit == null) {
        continue;
      }
      var stage = 'recheck';
      // 主库记录先删、文件后删：记录删除带 deleted_at 条件，期间被恢复的作品
      // 不会被动过；文件阶段失败只留下孤儿文件，不会留下没有内容库的作品。
      var rowsDeleted = false;
      try {
        if (await _softDeleteProtected(novelId, sessions)) {
          continue;
        }
        final current = await _appDatabase
            .customSelect(
              'SELECT content_database_path FROM novels '
              'WHERE id = ? AND deleted_at > 0 AND deleted_at < ?',
              variables: [
                Variable<String>(novelId),
                Variable<DateTime>(cutoff),
              ],
            )
            .getSingleOrNull();
        if (current == null) {
          continue;
        }
        final storedPath = current.readNullable<String>(
          'content_database_path',
        );
        stage = 'content:close';
        await contents.remove(novelId)?.close();
        if (storedPath != null && storedPath.isNotEmpty) {
          await NovelContentDatabase.closeCached(storedPath);
        }
        stage = 'main:assets';
        // 先解析全部路径，配置或路径错误时在改动任何数据之前失败。
        final assets = await _ownedAssets(novelId);
        final workspace = Directory(
          p.join(
            RevericPaths.fileWorkspaceParent,
            RevericPaths.fileWorkspaceDirectory(novelId),
          ),
        );
        final contentPath = storedPath == null || storedPath.isEmpty
            ? null
            : RevericPaths.resolveDatabasePath(storedPath);
        stage = 'main:rows';
        if (!await _deleteWorkRows(novelId, assets, cutoff)) {
          continue;
        }
        rowsDeleted = true;
        stage = 'files:assets';
        for (final file in assets.removedFiles) {
          if (await file.exists()) {
            await file.delete();
          }
        }
        stage = 'files:content_database';
        if (contentPath != null) {
          await NovelContentDatabase.deleteFiles(contentPath);
        }
        stage = 'files:workspace';
        await _removeWorkspace(workspace, assets.keptFiles);
        _log.info(
          '[DB] cleanup op=DELETE stage=deleted_work novel=$novelId '
          'removedAssets=${assets.removedIds.length} '
          'keptAssets=${assets.keptIds.length}',
        );
      } catch (error, stackTrace) {
        if (!rowsDeleted) {
          result.failed++;
        }
        _log.error(
          '[DB] cleanup op=DELETE stage=deleted_work novel=$novelId '
          'step=$stage rowsDeleted=$rowsDeleted',
          error: error,
          stackTrace: stackTrace,
        );
      } finally {
        if (rowsDeleted) {
          result.purged++;
        }
        permit.release();
      }
    }
    return result;
  }

  /// 素材库中的图片和被其他作品用作封面的图片保留下来，转为不归属任何作品；
  /// 其余图片（含已软删除的）随作品删除。只删应用目录内的相对路径文件，
  /// 且不删仍被保留记录共用的文件。
  Future<_OwnedAssets> _ownedAssets(String novelId) async {
    final rows = await _appDatabase
        .customSelect(
          'SELECT id, path, '
          '(a.deleted_at = 0 AND (a.in_library OR EXISTS ('
          'SELECT 1 FROM novels n WHERE n.id != ? AND n.cover_asset_id = a.id'
          '))) AS keep '
          'FROM assets a WHERE a.novel_id = ?',
          variables: [Variable<String>(novelId), Variable<String>(novelId)],
        )
        .get();
    final removedIds = <String>[];
    final keptIds = <String>[];
    final removedPaths = <String>{};
    final keptPaths = <String>{};
    for (final row in rows) {
      final id = row.read<String>('id');
      final path = row.readNullable<String>('path');
      final keep = row.read<bool>('keep');
      (keep ? keptIds : removedIds).add(id);
      if (path != null && path.isNotEmpty) {
        (keep ? keptPaths : removedPaths).add(path);
      }
    }
    if (removedPaths.isNotEmpty) {
      final shared = await _appDatabase
          .customSelect(
            'SELECT DISTINCT path FROM assets WHERE path IN '
            '(${List.filled(removedPaths.length, '?').join(',')}) '
            "AND (novel_id IS NULL OR novel_id != ?)",
            variables: [
              ...removedPaths.map(Variable<String>.new),
              Variable<String>(novelId),
            ],
          )
          .get();
      keptPaths.addAll(shared.map((r) => r.read<String>('path')));
      removedPaths.removeAll(keptPaths);
    }
    File? appFile(String stored) {
      if (RevericPaths.contextForStoredPath(stored).isAbsolute(stored)) {
        return null;
      }
      return File(
        p.normalize(
          RevericPaths.resolveRelative(
            stored,
            support: RevericPaths.supportRoot,
          ),
        ),
      );
    }

    return _OwnedAssets(
      removedIds: removedIds,
      keptIds: keptIds,
      removedFiles: [...removedPaths.map(appFile).whereType<File>()],
      keptFiles: {
        ...keptPaths.map(appFile).whereType<File>().map((f) => f.path),
      },
    );
  }

  /// 删除作品文件工作区（会话附件、媒体等），保留仍有记录引用的图片文件。
  Future<void> _removeWorkspace(
    Directory directory,
    Set<String> keptFiles,
  ) async {
    if (!await directory.exists()) {
      return;
    }
    final kept = {
      ...keptFiles.where((path) => p.isWithin(directory.path, path)),
    };
    if (kept.isEmpty) {
      await directory.delete(recursive: true);
      return;
    }
    final directories = <Directory>[];
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Directory) {
        directories.add(entity);
      } else if (!kept.contains(p.normalize(entity.path))) {
        await entity.delete();
      }
    }
    directories.sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final child in directories) {
      if (await child.list().isEmpty) {
        await child.delete();
      }
    }
  }

  /// 删除作品在主库的全部记录。作品行只在仍是过期回收站状态时删除；
  /// 期间已被恢复则不改动任何记录并返回 false。
  Future<bool> _deleteWorkRows(
    String novelId,
    _OwnedAssets assets,
    DateTime cutoff,
  ) async {
    final db = _appDatabase;
    final id = Variable<String>(novelId);
    const sessionIds = 'SELECT id FROM ai_chat_sessions WHERE novel_id = ?';
    const batchIds = 'SELECT id FROM image_batches WHERE novel_id = ?';
    Future<int> run(String sql, TableInfo table, [List<Variable>? vars]) {
      return db.customUpdate(
        sql,
        variables: vars ?? [id],
        updates: {table},
        updateKind: UpdateKind.delete,
      );
    }

    String placeholders(List<String> ids) =>
        List.filled(ids.length, '?').join(',');
    return db.transaction(() async {
      final claimed = await run(
        'DELETE FROM novels WHERE id = ? AND deleted_at > 0 AND deleted_at < ?',
        db.novels,
        [id, Variable<DateTime>(cutoff)],
      );
      if (claimed == 0) {
        return false;
      }
      await run(
        'DELETE FROM todos WHERE session_id IN ($sessionIds)',
        db.todos,
      );
      await run(
        'DELETE FROM session_subscriptions WHERE session_id IN ($sessionIds)',
        db.sessionSubscriptions,
      );
      await run(
        'DELETE FROM ai_chat_sessions WHERE novel_id = ?',
        db.aiChatSessions,
      );
      await run('DELETE FROM agents WHERE novel_id = ?', db.agents);
      await run(
        'DELETE FROM tool_permission_rules WHERE work_id = ?',
        db.toolPermissionRules,
      );
      await run(
        'DELETE FROM reading_progress WHERE novel_id = ?',
        db.readingProgress,
      );
      await run(
        'DELETE FROM generation_tasks WHERE novel_id = ?',
        db.generationTasks,
      );
      await run(
        'DELETE FROM image_batch_slots WHERE batch_id IN ($batchIds)',
        db.imageBatchSlots,
      );
      await run(
        'DELETE FROM image_asset_references WHERE batch_id IN ($batchIds)',
        db.imageAssetReferences,
      );
      await run(
        'DELETE FROM image_batches WHERE novel_id = ?',
        db.imageBatches,
      );
      for (final batch in _batches(assets.removedIds)) {
        final vars = batch.map(Variable<String>.new).toList();
        await run(
          'DELETE FROM image_asset_references '
          'WHERE asset_id IN (${placeholders(batch)})',
          db.imageAssetReferences,
          vars,
        );
        await run(
          'DELETE FROM provider_assets '
          'WHERE asset_id IN (${placeholders(batch)})',
          db.providerAssets,
          vars,
        );
        await run(
          'DELETE FROM assets WHERE id IN (${placeholders(batch)})',
          db.assets,
          vars,
        );
      }
      for (final batch in _batches(assets.keptIds)) {
        await db.customUpdate(
          'UPDATE assets SET novel_id = NULL, batch_id = NULL '
          'WHERE id IN (${placeholders(batch)})',
          variables: batch.map(Variable<String>.new).toList(),
          updates: {db.assets},
          updateKind: UpdateKind.update,
        );
      }
      await run(
        'DELETE FROM novel_collection_members WHERE novel_id = ?',
        db.novelCollectionMembers,
      );
      return true;
    });
  }
}

class _OwnedAssets {
  const _OwnedAssets({
    required this.removedIds,
    required this.keptIds,
    required this.removedFiles,
    required this.keptFiles,
  });

  final List<String> removedIds;
  final List<String> keptIds;
  final List<File> removedFiles;

  /// 归一化后的绝对路径，供工作区清理跳过。
  final Set<String> keptFiles;
}

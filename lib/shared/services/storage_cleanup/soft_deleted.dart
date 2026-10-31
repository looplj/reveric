// 职责: 按固定表名单和删除时间回收软删除记录，并复用作品维护许可保护在用数据。
// 关联文件:
//   lib/shared/services/storage_cleanup_service.dart
//   lib/shared/services/novel_maintenance_coordinator.dart
// 遵循的 Rules:
//   .agents/rules/data-deletion.md
//   .agents/rules/error-handling.md

part of '../storage_cleanup_service.dart';

// 不自动枚举所有含 deleted_at 的表：新增表不等于获得硬删除授权。
// 作品登记、图片资产/批次不在名单中；会话及历史沿用原有专用清理策略。
const _softDeletedMainTables = <String, String?>{
  'agents': 'novel_id',
  'ai_shortcut_actions': null,
  'ai_providers': null,
};

const _softDeletedContentTables = [
  'canvas_nodes',
  'canvases',
  'screenplay_scene_characters',
  'screenplay_scene_elements',
  'screenplay_scenes',
  'screenplay_beats',
  'screenplay_episodes',
  'screenplay_seasons',
  'screenplays',
  'map_locations',
  'novel_maps',
  'outline_beats',
  'outlines',
  'foreshadowings',
  'character_profiles',
  'items',
  'chapter_nodes',
  'agent_rules',
  'documents',
  'locations',
];

class _SoftDeletedResult {
  final deleted = <String, int>{};
  var failedBatches = 0;
}

extension on StorageCleanupService {
  Future<_SoftDeletedResult> _cleanupSoftDeleted(
    DateTime cutoff,
    Map<String, CleanupSession> sessions,
    Map<String, String?> registry,
    Map<String, NovelContentDatabase> contents,
  ) async {
    final result = _SoftDeletedResult();
    for (final novelId in registry.keys) {
      if (await _softDeleteProtected(novelId, sessions)) {
        continue;
      }
      // 孤儿扫描已为登记作品开好连接且尚未关闭，复用它；只有扫描跳过的作品
      // 才自己开一个，并且只关自己开的那个。
      final shared = contents[novelId];
      final path = registry[novelId];
      final content =
          shared ??
          (path != null && path.isNotEmpty && await File(path).exists()
              ? NovelContentDatabase(path)
              : null);
      if (content != null) {
        try {
          for (final name in _softDeletedContentTables) {
            await _purgeSoftDeletedTable(
              content,
              name,
              cutoff,
              result,
              novelId: novelId,
              sessions: sessions,
              registry: registry,
            );
          }
        } finally {
          if (shared == null) {
            await content.close();
          }
        }
      }
      for (final entry in _softDeletedMainTables.entries) {
        if (entry.value == null) {
          continue;
        }
        await _purgeSoftDeletedTable(
          _appDatabase,
          entry.key,
          cutoff,
          result,
          scope: '${entry.value} = ?',
          scopeVariables: [Variable<String>(novelId)],
          novelId: novelId,
          sessions: sessions,
          registry: registry,
        );
      }
    }
    for (final entry in _softDeletedMainTables.entries) {
      final column = entry.value;
      await _purgeSoftDeletedTable(
        _appDatabase,
        entry.key,
        cutoff,
        result,
        scope: column == null
            ? '1'
            : "($column IS NULL OR $column = '' OR $column NOT IN (SELECT id FROM novels))",
        sessions: sessions,
        registry: registry,
      );
    }
    return result;
  }

  Future<bool> _softDeleteProtected(
    String novelId,
    Map<String, CleanupSession> sessions,
  ) async {
    if (await _protected(novelId, sessions)) {
      return true;
    }
    return _coordinator.isOpen(novelId);
  }

  Future<void> _purgeSoftDeletedTable(
    GeneratedDatabase database,
    String name,
    DateTime cutoff,
    _SoftDeletedResult result, {
    String scope = '1',
    List<Variable> scopeVariables = const [],
    String? novelId,
    required Map<String, CleanupSession> sessions,
    required Map<String, String?> registry,
  }) async {
    final table = database.allTables.singleWhere(
      (t) => t.actualTableName == name,
    );
    final key = name == 'outlines' ? 'document_id' : 'id';
    final predicate = 'deleted_at > 0 AND deleted_at < ? AND ($scope)';
    final variables = [Variable<DateTime>(cutoff), ...scopeVariables];
    while (true) {
      final permits = <NovelCleanupPermit>[];
      var ids = <String>[];
      try {
        // 全局配置可能供任意作品使用；全局清理时同时保护所有登记作品。
        final owners = novelId == null ? registry.keys : [novelId];
        for (final owner in owners) {
          final permit = _coordinator.tryAcquireCleanup(owner);
          if (permit == null) {
            return;
          }
          permits.add(permit);
          if (await _softDeleteProtected(owner, sessions)) {
            return;
          }
        }
        if (novelId == null) {
          // 包括未登记作品的后台任务；未知归属时不回收全局配置。
          if (_runningSessionIds().isNotEmpty) {
            return;
          }
        }
        final rows = await database
            .customSelect(
              'SELECT $key AS id FROM $name WHERE $predicate ORDER BY $key LIMIT 400',
              variables: variables,
            )
            .get();
        ids = rows.map((r) => r.read<String>('id')).toList();
        if (ids.isEmpty) {
          return;
        }
        // 打开意图可在查询候选期间到达；提交前再检查一次。
        for (final owner in owners) {
          if (await _softDeleteProtected(owner, sessions)) {
            return;
          }
        }
        final counts = await database.transaction(() async {
          final deleted = await database.customUpdate(
            'DELETE FROM $name WHERE $predicate AND $key IN (${List.filled(ids.length, '?').join(',')})',
            variables: [...variables, ...ids.map(Variable<String>.new)],
            updates: {table},
            updateKind: UpdateKind.delete,
          );
          return deleted;
        });
        if (counts == 0) {
          return;
        }
        result.deleted.update(name, (n) => n + counts, ifAbsent: () => counts);
      } catch (error, stackTrace) {
        result.failedBatches++;
        // 回收的是已过期的软删除行，单个 id 没有排查价值，只会每小时往
        // latest.log 里灌一批 uuid；表名、归属和批量足够定位。
        _log.error(
          '[DB] cleanup op=DELETE table=$name novel=$novelId '
          'count=${ids.length} cutoff=$cutoff',
          error: error,
          stackTrace: stackTrace,
        );
        return;
      } finally {
        for (final permit in permits.reversed) {
          permit.release();
        }
      }
    }
  }
}

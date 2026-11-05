// 职责: 保护在用作品，按保留期协调会话、历史、软删除记录、回收站作品与图片缓存的清理。
// 关联文件:
//   lib/shared/services/novel_maintenance_coordinator.dart
//   lib/shared/services/network_image/disk_cache.dart
//   lib/shared/database/app_database.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/services/storage_cleanup/soft_deleted.dart
//   lib/shared/services/storage_cleanup/deleted_works.dart

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../database/daos/ai_chat_session_dao.dart';
import 'network_image/disk_cache.dart';
import 'ai/files/session_files.dart';
import 'novel_maintenance_coordinator.dart';

import '../database/app_database.dart';
import '../logger/app_logger.dart';
import '../database/novel_content_database.dart';
import '../utils/storage_paths.dart';

part 'storage_cleanup/soft_deleted.dart';
part 'storage_cleanup/deleted_works.dart';

/// 清理结果
class CleanupResult {
  final Map<String, ({int candidate, int skipped, int completed, int failed})>
  groups;
  final int unattributed;
  final int conflicts;
  final int invalidSessions;
  final int scanFailures;
  final int candidateTrees;
  final int skippedTrees;
  final int completedTrees;
  final int failedTrees;
  final int deletedTodos;
  final int deletedSessions;
  final int deletedMessages;
  final int deletedChanges;
  final int deletedCommits;
  final int deletedSnapshots;
  final Map<String, int> deletedSoftRows;
  final int failedSoftDeleteBatches;

  /// 回收站到期后彻底删除的作品数，以及删除失败、留待下轮重试的作品数。
  final int purgedWorks;
  final int failedWorkPurges;

  /// 被回收的远端图片缓存文件数与字节数。它们是可按原 URL 重新下载的派生文件，
  /// 不是用户业务数据，因此不计入 [totalDeleted]（那是数据库记录数）。
  final int deletedImageFiles;
  final int freedImageBytes;

  const CleanupResult({
    this.groups = const {},
    this.unattributed = 0,
    this.conflicts = 0,
    this.invalidSessions = 0,
    this.scanFailures = 0,
    this.candidateTrees = 0,
    this.skippedTrees = 0,
    this.completedTrees = 0,
    this.failedTrees = 0,
    this.deletedTodos = 0,
    this.deletedSessions = 0,
    this.deletedMessages = 0,
    this.deletedChanges = 0,
    this.deletedCommits = 0,
    this.deletedSnapshots = 0,
    this.deletedSoftRows = const {},
    this.failedSoftDeleteBatches = 0,
    this.purgedWorks = 0,
    this.failedWorkPurges = 0,
    this.deletedImageFiles = 0,
    this.freedImageBytes = 0,
  });

  int get totalDeleted =>
      deletedTodos +
      deletedSessions +
      deletedMessages +
      deletedChanges +
      deletedCommits +
      deletedSnapshots +
      deletedSoftRows.values.fold(0, (sum, count) => sum + count);

  @override
  String toString() =>
      'trees(candidate=$candidateTrees skipped=$skippedTrees '
      'completed=$completedTrees failed=$failedTrees) sessions=$deletedSessions '
      'messages=$deletedMessages todos=$deletedTodos changes=$deletedChanges '
      'commits=$deletedCommits snapshots=$deletedSnapshots imageFiles=$deletedImageFiles '
      'imageBytes=$freedImageBytes groups=$groups unattributed=$unattributed '
      'conflicts=$conflicts invalidSessions=$invalidSessions scanFailures=$scanFailures '
      'softDeleted=$deletedSoftRows failedSoftDeleteBatches=$failedSoftDeleteBatches '
      'purgedWorks=$purgedWorks failedWorkPurges=$failedWorkPurges';
}

/// 存储清理调度器 — 按配置的间隔周期性清理过期数据。
///
/// 清理范围：
/// - working_changes（每个小说的内容库）
/// - change_commits + change_commit_items（每个小说的内容库）
/// - ai_chat_messages（每个小说的内容库）
/// - novel_state_snapshots（仅 superseded；每个小说的内容库）
/// - ai_chat_sessions（主数据库）
/// - soft_deleted.dart 固定名单中的软删除记录（从 deleted_at 起算）
/// - 回收站中超过保留期的作品及其全部数据（deleted_works.dart）
/// - network_image_cache/（App 私有目录下的远端图片缓存文件，可按原 URL 重下）
final _log = AppLogger.forModule('StorageCleanup');

class StorageCleanupService {
  StorageCleanupService({
    required this._appDatabase,
    required this._coordinator,
    required this._runningSessionIds,
    Future<void> Function(String, Iterable<String>)? deleteSessionFiles,
    int retentionDays = 30,
    int checkIntervalMinutes = 60,
  }) : _deleteSessionFiles =
           deleteSessionFiles ??
           ((novelId, ids) =>
               SessionFiles(novelId: novelId).deleteSessions(ids)),
       _retentionDays = retentionDays.clamp(7, 365),
       _checkInterval = Duration(minutes: checkIntervalMinutes);

  final Future<void> Function(String, Iterable<String>) _deleteSessionFiles;
  final AppDatabase _appDatabase;
  final NovelMaintenanceCoordinator _coordinator;
  final Set<String> Function() _runningSessionIds;
  final Duration _checkInterval;

  int _retentionDays;
  bool _enabled = true;
  Timer? _timer;
  bool _disposed = false;
  bool _running = false;

  /// 上一轮图片缓存裁剪的失败签名，以及此后被折叠掉的重复次数。
  ///
  /// 裁剪每小时跑一次，故障（目录不可写、依赖未初始化等）通常是持续性的：
  /// 完整堆栈只有第一次有信息量，之后每小时再打一份只会把 latest.log 冲满，
  /// 顺带训练人忽略 `[ERROR]`。
  String? _imagePruneFailure;
  int _imagePruneFailureRepeats = 0;

  /// 当前 retention 天数
  int get retentionDays => _retentionDays;

  /// 动态更新 retention 天数（不重启 timer）
  void updateConfig({int? retentionDays, bool? enabled}) {
    if (retentionDays != null) {
      _retentionDays = retentionDays.clamp(7, 365);
    }
    if (enabled != null) {
      _enabled = enabled;
    }
  }

  /// 启动定时清理
  void start() {
    if (_disposed) {
      return;
    }
    _timer?.cancel();
    _timer = Timer.periodic(_checkInterval, (_) => _tick());
  }

  /// 停止定时清理
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 释放资源
  void dispose() {
    _disposed = true;
    stop();
  }

  /// 立即执行一次完整清理
  Future<CleanupResult> runNow() async {
    if (_running) {
      _log.info('already running, skipping');
      return const CleanupResult();
    }
    _running = true;
    try {
      return await _runCleanup();
    } finally {
      _running = false;
    }
  }

  void _tick() {
    if (!_enabled || _disposed) {
      return;
    }
    unawaited(
      runNow().catchError((Object error, StackTrace stackTrace) {
        _log.error(
          'scheduled cleanup failed',
          error: error,
          stackTrace: stackTrace,
        );
        return const CleanupResult();
      }),
    );
  }

  Future<bool> _protected(
    String novelId,
    Map<String, CleanupSession> sessions,
  ) async {
    if (_coordinator.isOpen(novelId)) {
      return true;
    }
    // 新运行尚未出现在本轮关系快照中时保守跳过，不能推断它不属于该作品。
    for (final id in _runningSessionIds()) {
      if (sessions[id] == null || sessions[id]!.novelId == novelId) {
        return true;
      }
    }
    return false;
  }

  Iterable<List<String>> _batches(List<String> ids) sync* {
    for (var offset = 0; offset < ids.length; offset += 400) {
      yield ids.sublist(offset, (offset + 400).clamp(0, ids.length));
    }
  }

  Future<bool> _eligible(
    List<CleanupSession> tree,
    String rootId,
    String novelId,
    DateTime cutoff,
    NovelContentDatabase content, {
    bool orphan = false,
  }) async {
    if (tree.any((s) => s.novelId != novelId)) {
      return false;
    }
    if ((!orphan && !tree.any((s) => s.id == rootId && s.parentId == null)) ||
        tree.any((s) => !s.updatedAt.isBefore(cutoff))) {
      return false;
    }
    final groupIds = {rootId, ...tree.map((s) => s.id)}.toList();
    if (orphan && tree.isEmpty) {
      final messageTime = await content.aiChatMessageDao
          .lastActivityForSessions(groupIds);
      final todoTime = await _appDatabase.todoDao.lastActivityForSessions(
        groupIds,
      );
      if (messageTime == null && todoTime == null) {
        final pointer = await content.novelStateDao.get('active_chat_session');
        if (pointer?.data != rootId || !pointer!.updatedAt.isBefore(cutoff)) {
          return false;
        }
      }
    }
    for (final ids in _batches(groupIds)) {
      final placeholders = List.filled(ids.length, '?').join(',');
      final references = await _appDatabase
          .customSelect(
            'SELECT 1 FROM session_subscriptions WHERE session_id IN ($placeholders) LIMIT 1',
            variables: ids.map(Variable<String>.new).toList(),
          )
          .get();
      if (references.isNotEmpty) {
        return false;
      }
      final todoTime = await _appDatabase.todoDao.lastActivityForSessions(ids);
      final messageTime = await content.aiChatMessageDao
          .lastActivityForSessions(ids);
      if ((todoTime != null && !todoTime.isBefore(cutoff)) ||
          (messageTime != null && !messageTime.isBefore(cutoff))) {
        return false;
      }
      final changes = content.workingChanges;
      final active =
          await (content.selectOnly(changes)
                ..addColumns([changes.id])
                ..where(
                  changes.sourceSessionId.isIn(ids) &
                      changes.status.equals('active'),
                )
                ..limit(1))
              .get();
      if (active.isNotEmpty) {
        return false;
      }
    }
    return true;
  }

  Future<CleanupResult> _runCleanup() async {
    final cutoff = DateTime.now().subtract(Duration(days: _retentionDays));
    _log.info('running cleanup, retentionDays=$_retentionDays, cutoff=$cutoff');
    final all = await _appDatabase.aiChatSessionDao.getCleanupSessions();
    final sessions = {for (final session in all) session.id: session};
    final children = <String, List<CleanupSession>>{};
    for (final session in all) {
      final parent = session.parentId;
      if (parent != null) {
        children.putIfAbsent(parent, () => []).add(session);
      }
    }
    final trees = <String, List<_CleanupGroup>>{};
    final visited = <String>{};
    List<CleanupSession> descendants(List<CleanupSession> roots) {
      final tree = <CleanupSession>[];
      final pending = [...roots];
      while (pending.isNotEmpty) {
        final current = pending.removeLast();
        if (!visited.add(current.id)) {
          continue;
        }
        tree.add(current);
        pending.addAll(children[current.id] ?? const []);
      }
      return tree;
    }

    var conflicts = 0;
    void addGroup(
      String root,
      List<CleanupSession> tree,
      Set<String> owners,
      bool orphan,
    ) {
      if (owners.length != 1) {
        conflicts++;
        return;
      }
      trees
          .putIfAbsent(owners.single, () => [])
          .add(_CleanupGroup(root, tree, orphan));
    }

    for (final root in all.where((s) => s.parentId == null)) {
      final tree = descendants([root]);
      addGroup(root.id, tree, tree.map((s) => s.novelId).toSet(), false);
    }
    // 包含软删除作品；未能扫描的登记库不能视为空库。
    final registry = await _registry();
    final contents = <String, NovelContentDatabase>{};
    final versions = <String, (int, int)>{};
    final owners = <String, Set<String>>{};
    var scanFailures = 0;
    try {
      for (final entry in registry.entries) {
        final path = entry.value;
        if (path == null || path.isEmpty) {
          continue;
        }
        try {
          if (!await File(path).exists()) {
            scanFailures++;
            continue;
          }
          final content = NovelContentDatabase(path);
          contents[entry.key] = content;
          final before = await _contentVersion(content);
          final rows = await content
              .customSelect(
                "SELECT session_id FROM ai_chat_messages GROUP BY session_id "
                "UNION SELECT data AS session_id FROM novel_states "
                "WHERE key = 'active_chat_session' AND data IS NOT NULL AND data != ''",
              )
              .get();
          for (final row in rows) {
            owners
                .putIfAbsent(row.read<String>('session_id'), () => {})
                .add(entry.key);
          }
          versions[entry.key] = before;
          if (before != await _contentVersion(content)) {
            scanFailures++;
          }
        } catch (error, stackTrace) {
          scanFailures++;
          _log.error(
            'orphan scan failed novel=${entry.key}',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      final missingRoots = children.keys
          .where((id) => !sessions.containsKey(id))
          .toSet();
      for (final root in missingRoots) {
        final tree = descendants(children[root]!);
        final evidence = <String>{...tree.map((s) => s.novelId)};
        for (final id in [root, ...tree.map((s) => s.id)]) {
          evidence.addAll(owners[id] ?? const {});
        }
        addGroup(root, tree, evidence, true);
      }
      final todoIds = await _appDatabase
          .customSelect('SELECT DISTINCT session_id FROM todos')
          .get();
      final residue =
          {...owners.keys, ...todoIds.map((r) => r.read<String>('session_id'))}
            ..removeAll(sessions.keys)
            ..removeAll(missingRoots);
      var unattributed = 0;
      for (final id in residue) {
        final evidence = owners[id] ?? const <String>{};
        if (evidence.isEmpty) {
          unattributed++;
        } else {
          addGroup(id, [], evidence, true);
        }
      }
      final invalidSessions = all.length - visited.length;
      final groupCounts =
          <String, ({int candidate, int skipped, int completed, int failed})>{};
      void record(_CleanupGroup group, String outcome) {
        final old =
            groupCounts[group.kind] ??
            (candidate: 0, skipped: 0, completed: 0, failed: 0);
        groupCounts[group.kind] = (
          candidate: old.candidate + (outcome == 'candidate' ? 1 : 0),
          skipped: old.skipped + (outcome == 'skipped' ? 1 : 0),
          completed: old.completed + (outcome == 'completed' ? 1 : 0),
          failed: old.failed + (outcome == 'failed' ? 1 : 0),
        );
      }

      var candidates = 0;
      var skipped = 0;
      var completed = 0;
      var failed = 0;
      var deletedSessions = 0;
      var deletedMessages = 0;
      var deletedTodos = 0;
      var deletedChanges = 0;
      var deletedCommits = 0;
      var deletedSnapshots = 0;
      Future<T> contentCommit<T>(
        String novelId,
        NovelContentDatabase content,
        Future<T> Function() action,
      ) async {
        (int, int)? next;
        final result = await content.transaction(() async {
          final before = await _contentVersion(content);
          final value = await action();
          final after = await _contentVersion(content);
          if (versions[novelId] == before && before.$2 == after.$2) {
            next = after;
          }
          return value;
        });
        if (next != null) {
          versions[novelId] = next!;
        }
        return result;
      }

      for (final novelId in registry.keys) {
        final novelTrees = trees[novelId] ?? const <_CleanupGroup>[];
        for (final group in novelTrees) {
          record(group, 'candidate');
        }
        candidates += novelTrees.length;
        final path = registry[novelId];
        if (await _protected(novelId, sessions)) {
          skipped += novelTrees.length;
          for (final group in novelTrees) {
            record(group, 'skipped');
          }
          continue;
        }
        if (path == null || path.isEmpty || !await File(path).exists()) {
          skipped += novelTrees.length;
          for (final group in novelTrees) {
            record(group, 'skipped');
          }
          continue;
        }
        final content = NovelContentDatabase(path);
        try {
          for (final scannedTree in novelTrees) {
            final rootId = scannedTree.root;
            final orphan = scannedTree.orphan;
            var stage = 'candidate';
            NovelCleanupPermit? permit;
            try {
              if (orphan && scanFailures != 0) {
                skipped++;
                record(scannedTree, 'skipped');
                continue;
              }
              if (!await _eligible(
                scannedTree.tree,
                rootId,
                novelId,
                cutoff,
                content,
                orphan: orphan,
              )) {
                skipped++;
                record(scannedTree, 'skipped');
                continue;
              }
              permit = _coordinator.tryAcquireCleanup(novelId);
              if (permit == null) {
                skipped++;
                record(scannedTree, 'skipped');
                continue;
              }
              stage = 'recheck';
              final tree = await _groupSessions(rootId);
              if (!_sameTree(scannedTree.tree, tree) ||
                  (orphan &&
                      (tree.any((s) => s.id == rootId) ||
                          !await _ownershipUnchanged(
                            registry,
                            contents,
                            versions,
                          ))) ||
                  !await _eligible(
                    tree,
                    rootId,
                    novelId,
                    cutoff,
                    content,
                    orphan: orphan,
                  ) ||
                  await _protected(novelId, sessions)) {
                skipped++;
                record(scannedTree, 'skipped');
                continue;
              }
              final ids = {rootId, ...tree.map((s) => s.id)}.toList();
              stage = 'files:sessions';
              await _deleteSessionFiles(novelId, ids);
              final recordsOnly = orphan && tree.isEmpty;
              if (recordsOnly) {
                stage = 'main:todos';
                deletedTodos += await _appDatabase.transaction(() async {
                  return _appDatabase.todoDao.deleteCleanupSessions(ids);
                });
              }
              stage = 'content:ai_chat_messages,novel_states';
              deletedMessages += await contentCommit(
                novelId,
                content,
                () async {
                  var count = 0;
                  for (final batch in _batches(ids)) {
                    count += await content.aiChatMessageDao
                        .deleteCleanupSessions(batch);
                    await content.novelStateDao.clearActiveChatSessionIn(batch);
                  }
                  return count;
                },
              );
              if (!recordsOnly) {
                stage = 'main:todos,ai_chat_sessions';
                final counts = await _appDatabase.transaction(() async {
                  var todos = 0;
                  var sessions = 0;
                  for (final batch in _batches(ids)) {
                    todos += await _appDatabase.todoDao.deleteCleanupSessions(
                      batch,
                    );
                  }
                  for (final batch in _batches(
                    ids.where((id) => id != rootId).toList(),
                  )) {
                    sessions += await _appDatabase.aiChatSessionDao
                        .deleteCleanupSessions(batch);
                  }
                  sessions += await _appDatabase.aiChatSessionDao
                      .deleteCleanupSessions([rootId]);
                  return (todos, sessions);
                });
                deletedTodos += counts.$1;
                deletedSessions += counts.$2;
              }
              completed++;
              record(scannedTree, 'completed');
            } catch (error, stackTrace) {
              failed++;
              record(scannedTree, 'failed');
              _log.error(
                '[DB] cleanup op=DELETE novel=$novelId root=$rootId stage=$stage',
                error: error,
                stackTrace: stackTrace,
              );
            } finally {
              permit?.release();
            }
          }
          // 内容历史同样服从作品保护；每一类事务之间让出打开机会。
          for (final kind in [
            'working_changes',
            'change_commits',
            'novel_state_snapshots',
          ]) {
            final permit = _coordinator.tryAcquireCleanup(novelId);
            if (permit == null) {
              break;
            }
            try {
              if (await _protected(novelId, sessions)) {
                break;
              }
              await contentCommit(novelId, content, () async {
                switch (kind) {
                  case 'working_changes':
                    deletedChanges += await content.workingChangeDao
                        .deleteOlderThan(cutoff);
                  case 'change_commits':
                    deletedCommits += await content.changeCommitDao
                        .deleteOlderThan(cutoff);
                  case 'novel_state_snapshots':
                    deletedSnapshots += await content.novelStateSnapshotDao
                        .deleteSupersededOlderThan(cutoff);
                }
              });
            } catch (error, stackTrace) {
              _log.error(
                '[DB] cleanup op=DELETE novel=$novelId stage=content_history table=$kind',
                error: error,
                stackTrace: stackTrace,
              );
            } finally {
              permit.release();
            }
          }
        } finally {
          await content.close();
        }
      }
      final softDeleted = await _cleanupSoftDeleted(
        cutoff,
        sessions,
        registry,
        contents,
      );
      final deletedWorks = await _purgeDeletedWorks(sessions, contents, cutoff);
      final images = await _pruneNetworkImageCache(cutoff);
      final result = CleanupResult(
        groups: groupCounts,
        unattributed: unattributed,
        conflicts: conflicts,
        invalidSessions: invalidSessions,
        scanFailures: scanFailures,
        candidateTrees: candidates,
        skippedTrees: skipped,
        completedTrees: completed,
        failedTrees: failed,
        deletedSessions: deletedSessions,
        deletedMessages: deletedMessages,
        deletedTodos: deletedTodos,
        deletedChanges: deletedChanges,
        deletedCommits: deletedCommits,
        deletedSnapshots: deletedSnapshots,
        deletedSoftRows: Map.unmodifiable(softDeleted.deleted),
        failedSoftDeleteBatches: softDeleted.failedBatches,
        purgedWorks: deletedWorks.purged,
        failedWorkPurges: deletedWorks.failed,
        deletedImageFiles: images.deletedFiles,
        freedImageBytes: images.freedBytes,
      );
      _log.info('cleanup done: $result');
      return result;
    } finally {
      for (final content in contents.values) {
        await content.close();
      }
    }
  }

  /// 裁剪远端图片磁盘缓存，与数据库保留期共用同一个 [cutoff]。
  ///
  /// 删除范围严格限定在 `<ApplicationSupport>/network_image_cache/` 下由缓存自己
  /// 写入的文件。它们可以按原 URL 重新下载，删掉只让下次显示多一次网络请求，
  /// 不涉及任何用户业务数据，因此不适用软删除。
  ///
  /// 失败不上抛：图片缓存裁剪不该让整轮数据库清理白跑。
  ///
  /// 同一个故障连续出现时只完整记录第一次，后续折叠；恢复时再补一条 info 说明
  /// 期间折叠了多少轮，避免「第一天一条 error、之后没动静」被读成已经恢复。
  Future<NetworkImageCachePruneResult> _pruneNetworkImageCache(
    DateTime cutoff,
  ) async {
    try {
      final result = await NetworkImageDiskCache.prune(cutoff: cutoff);
      if (_imagePruneFailure != null) {
        _log.info(
          'cleanup stage=network_image_cache recovered '
          'suppressedRounds=$_imagePruneFailureRepeats',
        );
        _imagePruneFailure = null;
        _imagePruneFailureRepeats = 0;
      }
      return result;
    } catch (error, stackTrace) {
      final signature = '${error.runtimeType}: $error';
      if (signature == _imagePruneFailure) {
        _imagePruneFailureRepeats++;
        return const NetworkImageCachePruneResult();
      }
      _imagePruneFailure = signature;
      _imagePruneFailureRepeats = 0;
      _log.error(
        'cleanup op=DELETE stage=network_image_cache',
        error: error,
        stackTrace: stackTrace,
      );
      return const NetworkImageCachePruneResult();
    }
  }

  Future<Map<String, String?>> _registry() async {
    final rows = await _appDatabase
        .customSelect('SELECT id, content_database_path FROM novels')
        .get();
    return {
      for (final row in rows)
        row.read<String>('id'): row.readNullable<String>(
          'content_database_path',
        ),
    };
  }

  // total_changes 捕获共享连接写入，data_version 捕获其他连接提交。
  Future<(int, int)> _contentVersion(NovelContentDatabase content) async {
    final changes = await content
        .customSelect('SELECT total_changes() AS value')
        .getSingle();
    final version = await content
        .customSelect('PRAGMA data_version')
        .getSingle();
    return (changes.read<int>('value'), version.read<int>('data_version'));
  }

  Future<bool> _ownershipUnchanged(
    Map<String, String?> registry,
    Map<String, NovelContentDatabase> contents,
    Map<String, (int, int)> versions,
  ) async {
    final current = await _registry();
    if (current.length != registry.length ||
        registry.entries.any(
          (e) => current[e.key] != e.value || !current.containsKey(e.key),
        )) {
      return false;
    }
    // 许可内只核对版本，不重新扫描跨库消息或归属。
    for (final entry in contents.entries) {
      if (!await File(entry.value.filePath).exists() ||
          versions[entry.key] != await _contentVersion(entry.value)) {
        return false;
      }
    }
    return true;
  }

  Future<List<CleanupSession>> _groupSessions(String root) async {
    final rows = await _appDatabase
        .customSelect(
          'WITH RECURSIVE tree(id) AS (SELECT ? UNION '
          'SELECT s.id FROM ai_chat_sessions s JOIN tree t ON s.parent_id = t.id) '
          'SELECT id, novel_id, parent_id, updated_at FROM ai_chat_sessions '
          'WHERE id IN (SELECT id FROM tree)',
          variables: [Variable<String>(root)],
        )
        .get();
    return rows
        .map(
          (row) => (
            id: row.read<String>('id'),
            novelId: row.read<String>('novel_id'),
            parentId: row.readNullable<String>('parent_id'),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(
              row.read<int>('updated_at') * 1000,
            ),
          ),
        )
        .toList();
  }

  bool _sameTree(List<CleanupSession> before, List<CleanupSession> after) {
    final relationships = {
      for (final s in before) (s.id, s.parentId, s.novelId),
    };
    return relationships.length == after.length &&
        after.every(
          (s) => relationships.contains((s.id, s.parentId, s.novelId)),
        );
  }
}

class _CleanupGroup {
  const _CleanupGroup(this.root, this.tree, this.orphan);
  final String root;
  final List<CleanupSession> tree;
  final bool orphan;
  String get kind => !orphan
      ? 'normal_tree'
      : tree.isEmpty
      ? 'orphan_records'
      : 'orphan_tree';
}

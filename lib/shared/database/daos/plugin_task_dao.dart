// 职责: 持久化插件任务定义、用户启停选择与带运行身份的租约和结果。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/models/plugin/task.dart
//   lib/shared/services/plugins/tasks.dart
import 'package:drift/drift.dart';
import '../app_database.dart';
import '../../logger/app_logger.dart';
import '../../models/plugin/task.dart';
part 'plugin_task_dao.drift.dart';

final _log = AppLogger.forModule('PluginTaskDao');

@DriftAccessor(tables: [PluginTasks])
class PluginTaskDao extends DatabaseAccessor<AppDatabase>
    with _$PluginTaskDaoMixin {
  PluginTaskDao(super.db);
  Future<T> _write<T>(
    String id,
    String operation,
    Future<T> Function() action,
  ) async {
    try {
      return await action();
    } catch (error, stack) {
      _log.error(
        '[DB] plugin_tasks $operation id=$id',
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  Future<List<PluginTask>> forPlugin(
    String id, {
    bool includeRemoved = false,
  }) =>
      (select(pluginTasks)
            ..where(
              (t) =>
                  t.pluginId.equals(id) &
                  (includeRemoved
                      ? const Constant(true)
                      : t.deletedAt.equals(notDeletedSentinel)),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.taskId)]))
          .get();
  Stream<List<PluginTask>> watchPlugin(String id) =>
      (select(pluginTasks)
            ..where((t) => t.pluginId.equals(id))
            ..orderBy([(t) => OrderingTerm.asc(t.taskId)]))
          .watch();
  Future<PluginTask?> get(String pluginId, String taskId) =>
      (select(pluginTasks)..where(
            (t) => t.pluginId.equals(pluginId) & t.taskId.equals(taskId),
          ))
          .getSingleOrNull();
  Future<void> synchronize(
    String id,
    List<PluginTaskDefinition> definitions,
    DateTime now,
  ) => _write(
    id,
    'UPSERT',
    () => transaction(() async {
      final old = {
        for (final row in await forPlugin(id, includeRemoved: true))
          row.taskId: row,
      };
      final present = definitions.map((d) => d.id).toSet();
      for (final definition in definitions) {
        final prior = old[definition.id];
        // 定义内容的兼容由插件负责；只有新出现或恢复的任务重新排期。
        final changed = prior == null || prior.deletedAt != notDeletedSentinel;
        await into(pluginTasks).insertOnConflictUpdate(
          PluginTasksCompanion.insert(
            pluginId: id,
            taskId: definition.id,
            enabled: Value(prior?.enabled ?? true),
            nextDueAt: changed
                ? now.add(Duration(minutes: definition.intervalMinutes))
                : prior.nextDueAt,
            createdAt: prior == null ? Value(now) : Value(prior.createdAt),
            updatedAt: Value(now),
            deletedAt: Value(notDeletedSentinel),
            leaseExpiresAt: changed ? const Value(null) : const Value.absent(),
          ),
        );
      }
      for (final row in old.values.where(
        (row) =>
            !present.contains(row.taskId) &&
            row.deletedAt == notDeletedSentinel,
      )) {
        await (update(pluginTasks)..where(
              (t) => t.pluginId.equals(id) & t.taskId.equals(row.taskId),
            ))
            .write(
              PluginTasksCompanion(
                deletedAt: Value(now),
                updatedAt: Value(now),
                leaseExpiresAt: const Value(null),
              ),
            );
      }
    }),
  );
  Future<void> setEnabled(
    String id,
    String taskId,
    bool enabled,
    DateTime now,
  ) => _write('$id/$taskId', 'UPDATE', () async {
    await (update(pluginTasks)..where(
          (t) =>
              t.pluginId.equals(id) &
              t.taskId.equals(taskId) &
              t.deletedAt.equals(notDeletedSentinel),
        ))
        .write(
          PluginTasksCompanion(enabled: Value(enabled), updatedAt: Value(now)),
        );
  });
  Future<List<PluginTask>> due(DateTime now) =>
      (select(pluginTasks)
            ..where(
              (t) =>
                  t.enabled.equals(true) &
                  t.deletedAt.equals(notDeletedSentinel) &
                  t.leaseExpiresAt.isNull() &
                  t.nextDueAt.isSmallerOrEqualValue(now),
            )
            ..orderBy([
              (t) => OrderingTerm.asc(t.nextDueAt),
              (t) => OrderingTerm.asc(t.pluginId),
              (t) => OrderingTerm.asc(t.taskId),
            ]))
          .get();
  Future<bool> claim(
    PluginTask row, {
    required String runId,
    required int attempt,
    required DateTime now,
    bool manual = false,
  }) => _write('${row.pluginId}/${row.taskId}', 'UPDATE claim', () async {
    final changed =
        await (update(pluginTasks)..where(
              (t) =>
                  t.pluginId.equals(row.pluginId) &
                  t.taskId.equals(row.taskId) &
                  t.deletedAt.equals(notDeletedSentinel) &
                  (manual ? const Constant(true) : t.enabled.equals(true)) &
                  t.leaseExpiresAt.isNull(),
            ))
            .write(
              PluginTasksCompanion(
                runId: Value(runId),
                attempt: Value(attempt),
                leaseExpiresAt: Value(now.add(const Duration(minutes: 5))),
                lastStartedAt: Value(now),
                lastStatus: const Value('running'),
                lastErrorCode: const Value(null),
                updatedAt: Value(now),
              ),
            );
    return changed == 1;
  });
  Future<bool> finish(
    PluginTask row, {
    required String runId,
    required DateTime now,
    required DateTime nextDueAt,
    required String status,
    String? summary,
    String? errorCode,
    Map<String, dynamic>? usage,
  }) => _write('${row.pluginId}/${row.taskId}', 'UPDATE finish', () async {
    final changed =
        await (update(pluginTasks)..where(
              (t) =>
                  t.pluginId.equals(row.pluginId) &
                  t.taskId.equals(row.taskId) &
                  t.runId.equals(runId) &
                  t.leaseExpiresAt.isNotNull() &
                  t.deletedAt.equals(notDeletedSentinel),
            ))
            .write(
              PluginTasksCompanion(
                leaseExpiresAt: const Value(null),
                lastFinishedAt: Value(now),
                nextDueAt: Value(nextDueAt),
                lastStatus: Value(status),
                lastSummary: Value(summary),
                lastErrorCode: Value(errorCode),
                lastUsage: Value(usage),
                updatedAt: Value(now),
              ),
            );
    return changed == 1;
  });
  Future<bool> recordUsage(
    PluginTask row,
    Map<String, dynamic> usage,
    DateTime now,
  ) => _write('${row.pluginId}/${row.taskId}', 'UPDATE usage', () async {
    final changed =
        await (update(pluginTasks)..where(
              (t) =>
                  t.pluginId.equals(row.pluginId) &
                  t.taskId.equals(row.taskId) &
                  t.runId.equals(row.runId!) &
                  t.attempt.equals(row.attempt) &
                  t.leaseExpiresAt.isNotNull() &
                  t.deletedAt.equals(notDeletedSentinel),
            ))
            .write(
              PluginTasksCompanion(
                lastUsage: Value(usage),
                updatedAt: Value(now),
              ),
            );
    return changed == 1;
  });

  Future<void> recoverLeases(DateTime now) =>
      _write('*', 'UPDATE recover', () async {
        await (update(
          pluginTasks,
        )..where((t) => t.leaseExpiresAt.isNotNull())).write(
          PluginTasksCompanion(
            leaseExpiresAt: const Value(null),
            lastStatus: const Value('interrupted'),
            lastErrorCode: const Value('interrupted'),
            lastFinishedAt: Value(now),
            nextDueAt: Value(now),
            updatedAt: Value(now),
          ),
        );
      });
  Future<void> defer(PluginTask row, DateTime due, DateTime now) => _write(
    '${row.pluginId}/${row.taskId}',
    'UPDATE defer',
    () async {
      await (update(pluginTasks)..where(
            (t) =>
                t.pluginId.equals(row.pluginId) &
                t.taskId.equals(row.taskId) &
                t.leaseExpiresAt.isNull(),
          ))
          .write(
            PluginTasksCompanion(nextDueAt: Value(due), updatedAt: Value(now)),
          );
    },
  );
}

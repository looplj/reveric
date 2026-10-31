// 职责: 验证插件任务的暂停保留、租约互斥、运行身份保护与中断恢复。
// 关联文件:
//   lib/shared/database/daos/plugin_task_dao.dart
//   lib/shared/database/app_database.dart
//   lib/shared/models/plugin/task.dart
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/plugin/task.dart';

PluginTaskDefinition task(
  String plugin, {
  String id = 'organize',
  String version = '1.0.0',
  int minutes = 60,
}) => PluginTaskDefinition(
  pluginId: plugin,
  version: version,
  definition: {'id': id, 'title': 'Organize', 'intervalMinutes': minutes},
);
void main() {
  final now = DateTime.utc(2026, 10, 31, 8);
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTest(NativeDatabase.memory()));
  tearDown(() => db.close());
  test(
    'synchronize preserves user pause and schedules only new or restored tasks',
    () async {
      final dao = db.pluginTaskDao;
      await dao.synchronize('test.one', [task('test.one')], now);
      await dao.setEnabled('test.one', 'organize', false, now);
      await dao.synchronize('test.one', [
        task('test.one'),
      ], now.add(const Duration(minutes: 5)));
      var row = (await dao.get('test.one', 'organize'))!;
      expect(row.enabled, false);
      expect(row.nextDueAt.toUtc(), now.add(const Duration(minutes: 60)));
      await dao.synchronize('test.one', [
        task('test.one', version: '2.0.0', minutes: 30),
      ], now.add(const Duration(minutes: 10)));
      row = (await dao.get('test.one', 'organize'))!;
      expect(row.enabled, false);
      expect(row.nextDueAt.toUtc(), now.add(const Duration(minutes: 60)));
      expect(row.createdAt.toUtc(), now);
      await dao.synchronize(
        'test.one',
        [],
        now.add(const Duration(minutes: 11)),
      );
      expect(await dao.forPlugin('test.one'), isEmpty);
      expect(
        await dao.forPlugin('test.one', includeRemoved: true),
        hasLength(1),
      );
      await dao.synchronize('test.one', [
        task('test.one', version: '3.0.0'),
      ], now);
      row = (await dao.get('test.one', 'organize'))!;
      expect(row.enabled, false);
      expect(row.nextDueAt.toUtc(), now.add(const Duration(minutes: 60)));
    },
  );
  test('leases cannot overlap and an old run cannot overwrite state', () async {
    final dao = db.pluginTaskDao;
    await dao.synchronize('test.one', [task('test.one')], now);
    final row = (await dao.get('test.one', 'organize'))!;
    expect(await dao.claim(row, runId: 'run1', attempt: 1, now: now), true);
    expect(await dao.claim(row, runId: 'run2', attempt: 1, now: now), false);
    expect(
      await dao.finish(
        row,
        runId: 'wrong',
        now: now,
        nextDueAt: now,
        status: 'success',
      ),
      false,
    );
    expect(
      await dao.finish(
        row,
        runId: 'run1',
        now: now,
        nextDueAt: now.add(const Duration(hours: 1)),
        status: 'success',
        summary: 'Done',
        usage: {'outputTokens': 5},
      ),
      true,
    );
    expect(
      await dao.finish(
        row,
        runId: 'run1',
        now: now,
        nextDueAt: now,
        status: 'failed',
      ),
      false,
    );
    final saved = (await dao.get('test.one', 'organize'))!;
    expect(saved.lastSummary, 'Done');
    expect(saved.lastUsage, {'outputTokens': 5});
  });
  test(
    'startup interruption keeps logical run id and due ordering is stable',
    () async {
      final dao = db.pluginTaskDao;
      await dao.synchronize('test.b', [task('test.b')], now);
      await dao.synchronize('test.a', [task('test.a')], now);
      for (final id in ['test.a', 'test.b']) {
        final row = (await dao.get(id, 'organize'))!;
        await dao.claim(row, runId: '$id-run', attempt: 2, now: now);
      }
      await dao.recoverLeases(now.add(const Duration(minutes: 1)));
      final due = await dao.due(now.add(const Duration(minutes: 1)));
      expect(due.map((r) => r.pluginId), ['test.a', 'test.b']);
      expect(due.map((r) => r.lastStatus), everyElement('interrupted'));
      expect(due.first.runId, 'test.a-run');
      expect(due.first.attempt, 2);
      expect(due.first.leaseExpiresAt, null);
    },
  );
  test(
    'published schema upgrades to typed tasks with integer timestamps and index',
    () async {
      final migrated = AppDatabase.forTest(
        NativeDatabase.memory(
          setup: (sqlite) {
            sqlite.execute(
              File(
                'test/shared/database/fixtures/app_v0_4_0.sql',
              ).readAsStringSync(),
            );
          },
        ),
      );
      try {
        await migrated.pluginTaskDao.synchronize('test.one', [
          task('test.one'),
        ], now);
        expect(
          (await migrated.pluginTaskDao.get(
            'test.one',
            'organize',
          ))!.nextDueAt.toUtc(),
          now.add(const Duration(hours: 1)),
        );
        final schema =
            (await migrated
                    .customSelect(
                      "SELECT sql FROM sqlite_master WHERE name='plugin_tasks'",
                    )
                    .getSingle())
                .read<String>('sql');
        expect(schema.toUpperCase(), isNot(contains('CHECK')));
        expect(schema, contains('PRIMARY KEY'));
        expect(
          await migrated
              .customSelect(
                "SELECT name FROM sqlite_master WHERE name='plugin_tasks_by_enabled_next_due_at'",
              )
              .get(),
          hasLength(1),
        );
        final types = await migrated
            .customSelect(
              'SELECT typeof(next_due_at) AS due, typeof(created_at) AS created FROM plugin_tasks',
            )
            .getSingle();
        expect(types.read<String>('due'), 'integer');
        expect(types.read<String>('created'), 'integer');
        expect(await migrated.appSettingsDao.get('fixture'), 'retained');
      } finally {
        await migrated.close();
      }
    },
  );
}

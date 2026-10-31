// 职责: 验证任务调度的并发、公平排队、重试身份、手动合并与前后台取消。
// 关联文件:
//   lib/shared/services/plugins/tasks.dart
//   lib/shared/database/daos/plugin_task_dao.dart
import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/plugin/task.dart';
import 'package:reveric/shared/services/plugins/tasks.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';

PluginTaskDefinition task(String plugin, String id) => PluginTaskDefinition(
  pluginId: plugin,
  version: '1.0.0',
  definition: {'id': id, 'title': id, 'intervalMinutes': 60},
);
Future<void> until(FutureOr<bool> Function() check) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!await check()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('Task condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  late AppDatabase db;
  late DateTime now;
  setUp(() {
    db = AppDatabase.forTest(NativeDatabase.memory());
    now = DateTime.utc(2026, 10, 31, 9);
  });
  tearDown(() => db.close());
  test(
    'global two/plugin one and duplicate manual triggers coalesce',
    () async {
      final gates = <String, Completer<PluginTaskResult>>{};
      final calls = <String>[];
      final active = <String>{};
      var peak = 0;
      final scheduler = PluginTaskScheduler(
        dao: db.pluginTaskDao,
        canRun: (_) => true,
        autoTick: false,
        clock: () => now,
        jitter: () => Duration.zero,
        run: (def, run, cancellation) async {
          expect(active.add(def.pluginId), true);
          if (active.length > peak) {
            peak = active.length;
          }
          expect(active.length, lessThanOrEqualTo(2));
          final key = '${def.pluginId}/${def.id}';
          calls.add(key);
          final gate = gates[key] = Completer<PluginTaskResult>();
          try {
            return await gate.future;
          } finally {
            active.remove(def.pluginId);
          }
        },
      );
      try {
        await scheduler.initialize();
        await scheduler.register('a', [task('a', 'one'), task('a', 'two')]);
        await scheduler.register('b', [task('b', 'one')]);
        await scheduler.start();
        await Future.wait([
          scheduler.runNow('a', 'one'),
          scheduler.runNow('a', 'two'),
          scheduler.runNow('b', 'one'),
          scheduler.runNow('a', 'one'),
        ]);
        await until(() => calls.length == 2);
        expect(calls.toSet(), {'a/one', 'b/one'});
        gates['a/one']!.complete((summary: 'done', usage: null));
        await until(() => calls.length == 3);
        gates['a/two']!.complete((summary: 'done', usage: null));
        gates['b/one']!.complete((summary: 'done', usage: null));
        await until(
          () =>
              !scheduler.pending('a', 'two') && !scheduler.pending('b', 'one'),
        );
        expect(calls, hasLength(3));
        expect(peak, 2);
      } finally {
        await scheduler.dispose();
      }
    },
  );
  test(
    'failure backoff reuses run id three times then returns to normal period',
    () async {
      final runs = <PluginTaskRun>[];
      final scheduler = PluginTaskScheduler(
        dao: db.pluginTaskDao,
        canRun: (_) => true,
        autoTick: false,
        clock: () => now,
        jitter: () => Duration.zero,
        run: (def, run, cancellation) async {
          runs.add(run);
          throw PluginHostError('network', 'offline');
        },
      );
      try {
        await scheduler.initialize();
        await scheduler.register('a', [task('a', 'one')]);
        await scheduler.start();
        await scheduler.runNow('a', 'one');
        for (var attempt = 1; attempt <= 4; attempt++) {
          await until(
            () async =>
                !scheduler.pending('a', 'one') &&
                (await db.pluginTaskDao.get('a', 'one'))!.attempt == attempt,
          );
          final row = (await db.pluginTaskDao.get('a', 'one'))!;
          expect(row.lastStatus, attempt <= 3 ? 'retrying' : 'failed');
          expect(
            row.nextDueAt.toUtc(),
            now.toUtc().add(
              Duration(minutes: const [1, 5, 15, 60][attempt - 1]),
            ),
          );
          if (attempt < 4) {
            now = row.nextDueAt;
            await scheduler.tick();
          }
        }
        expect(runs.map((r) => r.runId).toSet(), hasLength(1));
        now = (await db.pluginTaskDao.get('a', 'one'))!.nextDueAt;
        await scheduler.tick();
        await until(() => runs.length == 5);
        expect(runs.last.runId, isNot(runs.first.runId));
        await until(() => !scheduler.pending('a', 'one'));
      } finally {
        await scheduler.dispose();
      }
    },
  );
  test(
    'manual run preserves pause and cancellation/background do not schedule failure retries',
    () async {
      var calls = 0;
      final scheduler = PluginTaskScheduler(
        dao: db.pluginTaskDao,
        canRun: (_) => true,
        autoTick: false,
        clock: () => now,
        jitter: () => Duration.zero,
        run: (def, run, cancellation) async {
          calls++;
          final gate = Completer<PluginTaskResult>();
          cancellation.onCancel(
            () => gate.completeError(PluginHostError('cancelled', 'stop')),
          );
          return gate.future;
        },
      );
      try {
        await scheduler.initialize();
        await scheduler.register('a', [task('a', 'one')]);
        await scheduler.start();
        await scheduler.setEnabled('a', 'one', false);
        await scheduler.runNow('a', 'one');
        await until(() => calls == 1);
        await scheduler.cancel('a', 'one');
        var row = (await db.pluginTaskDao.get('a', 'one'))!;
        expect(row.enabled, false);
        expect(row.lastStatus, 'cancelled');
        expect(row.nextDueAt.toUtc(), now.add(const Duration(hours: 1)));
        await scheduler.runNow('a', 'one');
        await until(() => calls == 2);
        await scheduler.setForeground(false);
        row = (await db.pluginTaskDao.get('a', 'one'))!;
        expect(row.lastStatus, 'cancelled');
        expect(row.lastErrorCode, 'background');
        await expectLater(
          scheduler.runNow('a', 'one'),
          throwsA(isA<PluginHostError>()),
        );
        await scheduler.setForeground(true);
        expect(calls, 2);
      } finally {
        await scheduler.dispose();
      }
    },
  );
  test(
    'overdue work receives jitter and catches up once instead of replaying ticks',
    () async {
      var calls = 0;
      await db.pluginTaskDao.synchronize('a', [
        task('a', 'one'),
      ], now.subtract(const Duration(hours: 3)));
      final scheduler = PluginTaskScheduler(
        dao: db.pluginTaskDao,
        canRun: (_) => true,
        autoTick: false,
        clock: () => now,
        jitter: () => const Duration(seconds: 20),
        run: (def, run, cancellation) async {
          calls++;
          return (summary: 'done', usage: null);
        },
      );
      try {
        await scheduler.initialize();
        await scheduler.register('a', [task('a', 'one')]);
        await scheduler.start();
        await scheduler.tick();
        expect(calls, 0);
        expect(
          (await db.pluginTaskDao.get('a', 'one'))!.nextDueAt.toUtc(),
          now.add(const Duration(seconds: 20)),
        );
        now = now.add(const Duration(seconds: 20));
        await scheduler.tick();
        await until(() => calls == 1 && !scheduler.pending('a', 'one'));
        now = now.add(const Duration(hours: 5));
        await scheduler.setForeground(false);
        await scheduler.setForeground(true);
        expect(calls, 1);
        now = now.add(const Duration(seconds: 20));
        await scheduler.tick();
        await until(() => calls == 2 && !scheduler.pending('a', 'one'));
        expect(calls, 2);
      } finally {
        await scheduler.dispose();
      }
    },
  );
}

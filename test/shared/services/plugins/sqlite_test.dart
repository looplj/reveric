// 职责: 用真实后台 isolate 验证插件私有库隔离、队列取消和未知提交后的持久结果。
// 关联文件:
//   lib/shared/services/plugins/sqlite.dart
//   lib/shared/services/plugins/sqlite_worker.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';
import 'package:reveric/shared/services/plugins/sqlite.dart';

const migration = {
  'version': 1,
  'sql':
      'CREATE TABLE notes(id INTEGER PRIMARY KEY, text TEXT NOT NULL, deleted_at INTEGER);',
};
Map<String, dynamic> statement(String sql, [List<Object?> params = const []]) =>
    {
      'statement': {'sql': sql, 'params': params},
    };
Matcher failure(String code) =>
    throwsA(isA<PluginHostError>().having((e) => e.code, 'code', code));
void main() {
  late Directory root;
  late PluginSqliteService service;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('plugin-sql-queue-');
    service = PluginSqliteService(
      root: root,
      idleTimeout: const Duration(milliseconds: 50),
    );
    await service.migrate('test.one', [migration]);
  });
  tearDown(() async {
    await service.dispose();
    await root.delete(recursive: true);
  });
  test(
    'independent identities preserve files after idle close and reopen',
    () async {
      await service.migrate('test.two', [migration]);
      await service.call(
        'test.one',
        'execute',
        statement("INSERT INTO notes(text) VALUES ('one')"),
      );
      expect(
        await service.call(
          'test.two',
          'query',
          statement('SELECT * FROM notes'),
        ),
        [],
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        await service.call(
          'test.one',
          'query',
          statement('SELECT text FROM notes'),
        ),
        [
          {'text': 'one'},
        ],
      );
      service.pause('test.one');
      await expectLater(
        service.call('test.one', 'query', statement('SELECT 1')),
        failure('database_paused'),
      );
      await service.close('test.one');
      service.resume('test.one');
      expect(
        await service.call(
          'test.one',
          'query',
          statement('SELECT COUNT(*) AS count FROM notes'),
        ),
        [
          {'count': 1},
        ],
      );
    },
  );
  test(
    'started writes time out as commit_unknown and finish once without retry',
    () async {
      await expectLater(
        service.call(
          'test.one',
          'execute',
          statement(
            "INSERT INTO notes(text) WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<100000) SELECT CAST(x AS TEXT) FROM n",
          ),
          waitBudget: const Duration(milliseconds: 1),
        ),
        failure('commit_unknown'),
      );
      await service.drain('test.one', timeout: const Duration(seconds: 20));
      expect(
        await service.call(
          'test.one',
          'query',
          statement('SELECT COUNT(*) AS count FROM notes'),
        ),
        [
          {'count': 100000},
        ],
      );
    },
  );
  test(
    'pending queue rejects the 33rd call without creating another connection',
    () async {
      final active = service.call(
        'test.one',
        'query',
        statement(
          'WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<1000000) SELECT SUM(x) AS total FROM n',
        ),
      );
      final queued = [
        for (var i = 0; i < 31; i++)
          service.call('test.one', 'query', statement('SELECT 1 AS value')),
      ];
      await expectLater(
        service.call('test.one', 'query', statement('SELECT 2')),
        failure('database_busy'),
      );
      await active;
      for (final result in await Future.wait(queued)) {
        expect(result, [
          {'value': 1},
        ]);
      }
    },
  );
  test(
    'queued calls cancel before SQL and running query only ends caller wait',
    () async {
      final long = service.call(
        'test.one',
        'query',
        statement(
          'WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<2000000) SELECT SUM(x) AS total FROM n',
        ),
        waitBudget: const Duration(milliseconds: 1),
      );
      final cancellation = AgentCancellationController();
      final queued = service.call(
        'test.one',
        'execute',
        statement("INSERT INTO notes(text) VALUES ('cancelled')"),
        cancellation: cancellation.token,
      );
      final queuedCheck = expectLater(queued, failure('cancelled'));
      cancellation.cancel();
      await queuedCheck;
      await expectLater(long, failure('wait_timeout'));
      await expectLater(
        service.close('test.one', timeout: const Duration(milliseconds: 1)),
        failure('database_busy'),
      );
      await service.drain('test.one', timeout: const Duration(seconds: 20));
      expect(
        await service.call(
          'test.one',
          'query',
          statement('SELECT COUNT(*) AS count FROM notes'),
        ),
        [
          {'count': 0},
        ],
      );
    },
  );
}

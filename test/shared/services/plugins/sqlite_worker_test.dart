// 职责: 验证插件私有 SQL 的类型、软删除限制、事务回滚、迁移指纹与一致性备份。
// 关联文件:
//   lib/shared/services/plugins/sqlite_worker.dart
//   lib/shared/services/plugins/sql_contract.dart
//   lib/shared/models/plugin/manifest.dart
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/plugins/sqlite_worker.dart';
import 'package:reveric/shared/services/plugins/sql_contract.dart';
import 'package:reveric/shared/models/plugin/manifest.dart';

const schema =
    'CREATE TABLE notes(id INTEGER PRIMARY KEY, text TEXT NOT NULL, big INTEGER, data BLOB, deleted_at INTEGER); CREATE INDEX notes_by_deleted_at ON notes(deleted_at);';
Map<String, Object?> statement(String sql, [List<Object?> params = const []]) =>
    {'sql': sql, 'params': params};
Map<String, Object?> migration(int version, String sql) => {
  'version': version,
  'sql': sql,
};
void main() {
  late Directory directory;
  late PluginSqlConnection db;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('plugin-sql-test-');
    db = PluginSqlConnection('${directory.path}/data.sqlite');
    await db.run('migrate', {
      'migrations': [migration(1, schema)],
    });
  });
  tearDown(() async {
    db.close();
    await directory.delete(recursive: true);
  });
  Future<Object?> query(String sql, [List<Object?> params = const []]) =>
      db.run('query', {'statement': statement(sql, params)});
  Future<Object?> execute(String sql, [List<Object?> params = const []]) =>
      db.run('execute', {'statement': statement(sql, params)});
  Matcher failure(String code) =>
      throwsA(isA<PluginSqlError>().having((e) => e.code, 'code', code));

  test(
    'int64/blob round trip and insert rowid never leaks into later writes',
    () async {
      final big = {'__revericSql': 'int64', 'value': '9223372036854775807'};
      final blob = {
        '__revericSql': 'blob',
        'value': base64Encode([0, 255, 1]),
      };
      expect(
        await execute('INSERT INTO notes(text,big,data) VALUES (?,?,?)', [
          'A',
          big,
          blob,
        ]),
        {
          'changes': 1,
          'lastInsertRowId': {'__revericSql': 'int64', 'value': '1'},
        },
      );
      expect(await query('SELECT big,data FROM notes'), [
        {'big': big, 'data': blob},
      ]);
      expect(await execute('UPDATE notes SET text=? WHERE id=?', ['B', 1]), {
        'changes': 1,
        'lastInsertRowId': null,
      });
      expect(
        await execute(
          'INSERT INTO notes(text) SELECT text FROM notes WHERE id=999',
        ),
        {'changes': 0, 'lastInsertRowId': null},
      );
      await expectLater(
        execute('INSERT INTO notes(text,big) VALUES (?,?)', [
          'C',
          9223372036854775807,
        ]),
        failure('invalid_argument'),
      );
    },
  );
  test(
    'transactions rollback actual SQL failure with diagnostic index',
    () async {
      await expectLater(
        db.run('transaction', {
          'statements': [
            statement("INSERT INTO notes(text) VALUES ('first')"),
            statement('INSERT INTO notes(text) VALUES (NULL)'),
          ],
        }),
        throwsA(
          isA<PluginSqlError>()
              .having((e) => e.details['statementIndex'], 'index', 1)
              .having((e) => e.details['sqliteCode'], 'code', 19),
        ),
      );
      expect(await query('SELECT COUNT(*) AS count FROM notes'), [
        {'count': 0},
      ]);
      await expectLater(
        db.run('transaction', {
          'statements': [
            statement("INSERT INTO notes(id,text) VALUES (1,'first')"),
            statement(
              "INSERT OR ROLLBACK INTO notes(id,text) VALUES (1,'duplicate')",
            ),
          ],
        }),
        failure('sqlite_error'),
      );
      expect(await query('SELECT COUNT(*) AS count FROM notes'), [
        {'count': 0},
      ]);
    },
  );
  test(
    'soft-delete contract rejects DDL, control, hidden ledger and implicit deletes',
    () async {
      for (final sql in [
        'DELETE FROM notes',
        'DROP TABLE notes',
        "REPLACE INTO notes(text) VALUES ('X')",
        "INSERT OR REPLACE INTO notes(text) VALUES ('X')",
        'PRAGMA user_version',
        'BEGIN',
        'ATTACH DATABASE \'other\' AS other',
        'CREATE TABLE other(x)',
        'UPDATE notes SET text=\'x\' RETURNING id',
      ]) {
        await expectLater(execute(sql), failure('invalid_sql'), reason: sql);
      }
      for (final sql in [
        'SELECT * FROM _reveric_migrations',
        "SELECT readfile('x')",
        'SELECT * FROM pragma_table_info(\'notes\')',
        'SELECT :named',
      ]) {
        await expectLater(query(sql), failure('invalid_sql'), reason: sql);
      }
      await expectLater(
        query('SELECT 1; SELECT 2'),
        throwsA(isA<PluginSqlError>()),
      );
      await expectLater(
        query('SELECT 1 AS x, 2 AS x'),
        failure('duplicate_columns'),
      );
      await execute("INSERT INTO notes(text) VALUES ('keep')");
      await execute('UPDATE notes SET deleted_at=unixepoch()');
      expect((await query('SELECT text FROM notes')), [
        {'text': 'keep'},
      ]);
    },
  );
  test('query budgets reject rather than truncate', () async {
    await expectLater(
      query(
        'WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<1001) SELECT x FROM n',
      ),
      failure('result_too_large'),
    );
    await expectLater(
      query('SELECT zeroblob(900000) AS huge'),
      failure('result_too_large'),
    );
    await expectLater(
      db.run('transaction', {
        'statements': List.generate(
          101,
          (_) => statement('UPDATE notes SET text=text'),
        ),
      }),
      failure('invalid_argument'),
    );
  });
  test(
    'migration hashes and failed upgrades preserve old records and schema',
    () async {
      await execute("INSERT INTO notes(text) VALUES ('original')");
      await expectLater(
        db.run('migrate', {
          'migrations': [migration(1, '$schema -- modified')],
        }),
        failure('migration_changed'),
      );
      await expectLater(
        db.run('migrate', {
          'migrations': [
            migration(1, schema),
            migration(
              2,
              'ALTER TABLE notes ADD COLUMN extra TEXT; UPDATE missing SET x=1;',
            ),
          ],
        }),
        failure('migration_failed'),
      );
      expect(await query('SELECT text FROM notes'), [
        {'text': 'original'},
      ]);
      await db.run('migrate', {
        'migrations': [
          migration(1, schema),
          migration(
            2,
            "ALTER TABLE notes ADD COLUMN extra TEXT DEFAULT 'ready';",
          ),
        ],
      });
      expect(await query('SELECT extra FROM notes'), [
        {'extra': 'ready'},
      ]);
      await expectLater(
        db.run('migrate', {
          'migrations': [migration(1, schema)],
        }),
        failure('migration_downgrade'),
      );
      final copy = '${directory.path}/backup.sqlite';
      await db.run('backup', {'path': copy});
      final backup = PluginSqlConnection(copy);
      try {
        expect(
          await backup.run('query', {
            'statement': statement('SELECT text,extra FROM notes'),
          }),
          [
            {'text': 'original', 'extra': 'ready'},
          ],
        );
      } finally {
        backup.close();
      }
    },
  );
  test('schema constraints and malformed declarations fail before use', () {
    for (final sql in [
      'CREATE TABLE x(v TEXT CHECK(length(v)>0))',
      'CREATE TABLE x(v TEXT UNIQUE)',
      'CREATE TABLE x(id INTEGER PRIMARY KEY AUTOINCREMENT)',
      'CREATE VIEW x AS SELECT 1',
      'CREATE TABLE x(v INTEGER REFERENCES notes(id))',
    ]) {
      expect(
        () => validatePluginSql(sql, query: false, migration: true),
        failure('invalid_sql'),
      );
    }
    final valid = {
      'version': 1,
      'migrations': [
        {'version': 1, 'source': 'migrations/001.sql'},
      ],
    };
    expect(PluginDatabaseManifest.parse(valid).version, 1);
    for (final invalid in [
      {'version': 2, 'migrations': valid['migrations']},
      {
        'version': 1,
        'migrations': [
          {'version': 1, 'source': '../x.sql'},
        ],
      },
    ]) {
      expect(
        () => PluginDatabaseManifest.parse(invalid),
        throwsFormatException,
      );
    }
  });
}

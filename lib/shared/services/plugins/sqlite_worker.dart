// 职责: 在插件专属后台 isolate 执行 SQL、迁移和一致性备份，保持单连接和事务完整性。
// 关联文件:
//   lib/shared/services/plugins/sqlite.dart
//   lib/shared/services/plugins/sql_contract.dart
//   lib/shared/services/plugins/database_install.dart
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlparser/sqlparser.dart' show InsertStatement;
import 'sql_contract.dart';
import '../../logger/app_logger.dart';

final _log = AppLogger.forModule('PluginSql');

void pluginSqlWorker(Map<String, Object?> input) async {
  final output = input['output'] as SendPort;
  final receive = ReceivePort();
  PluginSqlConnection? connection;
  try {
    connection = PluginSqlConnection(input['path'] as String);
    output.send({'ready': receive.sendPort});
    await for (final raw in receive) {
      final request = raw as Map;
      try {
        final result = await connection.run(
          request['operation'] as String,
          request['args'] as Map,
        );
        output.send({'id': request['id'], 'result': result});
        if (request['operation'] == 'close') {
          break;
        }
      } catch (error) {
        final failure = error is PluginSqlError
            ? error
            : PluginSqlError('database_error', error.toString());
        output.send({'id': request['id'], 'error': failure.toJson()});
      }
    }
  } catch (error) {
    output.send({
      'error': error is PluginSqlError
          ? error.toJson()
          : {'code': 'database_open_failed', 'message': error.toString()},
    });
  } finally {
    connection?.close();
    receive.close();
  }
}

class PluginSqlConnection {
  PluginSqlConnection(this.path) {
    Directory(File(path).parent.path).createSync(recursive: true);
    database = sqlite3.open(path);
    try {
      database.execute('PRAGMA journal_mode=DELETE');
      database.execute('PRAGMA busy_timeout=1000');
      final pageSize =
          database.select('PRAGMA page_size').single.values.first as int;
      final limit = 64 * 1024 * 1024 ~/ pageSize;
      final applied =
          database.select('PRAGMA max_page_count=$limit').single.values.first
              as int;
      if (applied > limit) {
        throw PluginSqlError(
          'database_quota',
          'Existing database exceeds 64 MB',
        );
      }
    } catch (_) {
      database.close();
      rethrow;
    }
  }
  final String path;
  late final Database database;
  bool _closed = false;
  void close() {
    if (!_closed) {
      _closed = true;
      database.close();
    }
  }

  Future<Object?> run(String operation, Map args) async {
    try {
      return await _run(operation, args);
    } catch (error, stack) {
      if (operation != 'query') {
        _log.error(
          '[DB] plugin private database operation=$operation',
          error: error,
          stackTrace: stack,
        );
      }
      rethrow;
    }
  }

  Future<Object?> _run(String operation, Map args) async {
    if (_closed) {
      throw PluginSqlError('database_closed', 'Database connection is closed');
    }
    if (operation == 'close') {
      close();
      return null;
    }
    var ownedBytes = 0;
    for (final entry in File(path).parent.listSync(followLinks: false)) {
      if (entry is File) {
        ownedBytes += entry.lengthSync();
      }
    }
    if (ownedBytes > 128 * 1024 * 1024) {
      throw PluginSqlError(
        'database_quota',
        'Plugin database/journal directory exceeds 128 MB',
      );
    }
    if (operation == 'backup') {
      final target = sqlite3.open(args['path'] as String);
      try {
        await database.backup(target).drain<void>();
      } finally {
        target.close();
      }
      return null;
    }
    if (operation == 'migrate') {
      return _migrate((args['migrations'] as List).cast<Map>());
    }
    if (utf8.encode(jsonEncode(args)).length > pluginSqlPayloadLimit) {
      throw PluginSqlError('request_too_large', 'SQL request exceeds 1 MB');
    }
    if (operation == 'transaction') {
      final statements = args['statements'];
      if (statements is! List || statements.length > 100) {
        throw PluginSqlError(
          'invalid_argument',
          'transaction accepts up to 100 statements',
        );
      }
      if (statements.isEmpty) {
        return <Object?>[];
      }
      database.execute('BEGIN IMMEDIATE');
      var index = 0;
      try {
        final results = <Object?>[];
        for (final statement in statements) {
          results.add(_statement(statement, query: false, index: index));
          index++;
        }
        database.execute('COMMIT');
        return results;
      } catch (error) {
        if (!database.autocommit) {
          database.execute('ROLLBACK');
        }
        if (error is PluginSqlError) {
          throw PluginSqlError(
            error.code,
            error.message,
            details: {...error.details, 'statementIndex': index},
          );
        }
        rethrow;
      }
    }
    if (!const {'query', 'execute'}.contains(operation)) {
      throw PluginSqlError(
        'invalid_argument',
        'Unknown SQLite operation $operation',
      );
    }
    return _statement(args['statement'], query: operation == 'query');
  }

  Object _statement(Object? value, {required bool query, int? index}) {
    if (value is! Map ||
        value['sql'] is! String ||
        (value['params'] != null && value['params'] is! List)) {
      throw PluginSqlError(
        'invalid_argument',
        'Expected sql and positional params',
      );
    }
    final sql = value['sql'] as String;
    final root = validatePluginSql(sql, query: query);
    final params = (value['params'] as List? ?? const [])
        .map(decodeSqlValue)
        .toList();
    try {
      final statement = database.prepare(sql, checkNoTail: true);
      try {
        if (query) {
          if (!statement.isReadOnly) {
            throw PluginSqlError('invalid_sql', 'query cannot write');
          }
          final cursor = statement.iterateWith(StatementParameters(params));
          final rows = <Map<String, Object?>>[];
          var bytes = 2;
          var hasNext = cursor.moveNext();
          final columns = cursor.columnNames;
          if (columns.toSet().length != columns.length) {
            throw PluginSqlError(
              'duplicate_columns',
              'Query columns must have unique names; use aliases',
            );
          }
          while (hasNext) {
            if (rows.length >= 1000) {
              throw PluginSqlError(
                'result_too_large',
                'Query exceeds 1000 rows',
              );
            }
            final row = <String, Object?>{
              for (final name in columns)
                name: encodeSqlValue(cursor.current[name]),
            };
            bytes += utf8.encode(jsonEncode(row)).length + 1;
            if (bytes > pluginSqlPayloadLimit) {
              throw PluginSqlError(
                'result_too_large',
                'Query result exceeds 1 MB',
              );
            }
            rows.add(row);
            hasNext = cursor.moveNext();
          }
          return rows;
        }
        statement.execute(params);
        final changes = database.updatedRows;
        return {
          'changes': changes,
          'lastInsertRowId': root is InsertStatement && changes > 0
              ? {
                  '__revericSql': 'int64',
                  'value': database.lastInsertRowId.toString(),
                }
              : null,
        };
      } finally {
        statement.close();
      }
    } on SqliteException catch (error) {
      throw PluginSqlError(
        error.resultCode == 13 ? 'database_quota' : 'sqlite_error',
        error.message,
        details: {
          'sqliteCode': error.resultCode,
          'sqliteExtendedCode': error.extendedResultCode,
          'statementIndex': ?index,
        },
      );
    }
  }

  Object? _migrate(List<Map> migrations) {
    database.execute(
      'CREATE TABLE IF NOT EXISTS _reveric_migrations (version INTEGER PRIMARY KEY, hash TEXT NOT NULL, applied_at INTEGER NOT NULL)',
    );
    final existing = database.select(
      'SELECT version, hash FROM _reveric_migrations ORDER BY version',
    );
    if (existing.length > migrations.length) {
      throw PluginSqlError(
        'migration_downgrade',
        'Cannot downgrade plugin database',
      );
    }
    final hashes = <String>[];
    for (var i = 0; i < migrations.length; i++) {
      final migration = migrations[i];
      if (migration['version'] != i + 1 || migration['sql'] is! String) {
        throw PluginSqlError(
          'invalid_migration',
          'Migration versions must be consecutive',
        );
      }
      hashes.add(
        sha256.convert(utf8.encode(migration['sql'] as String)).toString(),
      );
      if (i < existing.length &&
          (existing[i]['version'] != i + 1 ||
              existing[i]['hash'] != hashes[i])) {
        throw PluginSqlError(
          'migration_changed',
          'Applied migration ${i + 1} differs from package',
        );
      }
    }
    database.execute('BEGIN IMMEDIATE');
    try {
      for (var i = existing.length; i < migrations.length; i++) {
        final statements = pluginMigrationStatements(
          migrations[i]['sql'] as String,
        );
        for (var j = 0; j < statements.length; j++) {
          final sql = statements[j];
          validatePluginSql(sql, query: false, migration: true);
          try {
            final prepared = database.prepare(sql, checkNoTail: true);
            try {
              prepared.execute();
            } finally {
              prepared.close();
            }
          } on SqliteException catch (error) {
            throw PluginSqlError(
              'migration_failed',
              error.message,
              details: {
                'sqliteCode': error.resultCode,
                'sqliteExtendedCode': error.extendedResultCode,
                'migrationVersion': i + 1,
                'statementIndex': j,
              },
            );
          }
        }
        database.execute(
          'INSERT INTO _reveric_migrations(version, hash, applied_at) VALUES (?, ?, unixepoch())',
          [i + 1, hashes[i]],
        );
      }
      database.execute('COMMIT');
    } catch (error) {
      if (!database.autocommit) {
        database.execute('ROLLBACK');
      }
      rethrow;
    }
    return migrations.length;
  }
}

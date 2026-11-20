// 职责: SQLite schema 修复 — 按当前 Drift 定义补齐主库和小说内容库缺失结构。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/widgets/settings/debug_settings_section.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md
//   .agents/rules/db-migration.md
import 'dart:io';

import 'package:drift/drift.dart' show GeneratedDatabase;
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../database/app_database.dart';
import '../../database/novel_content_database.dart';
import '../../logger/app_logger.dart';
import '../../utils/storage_paths.dart';
import '../../utils/windows_safe_path.dart';

final _log = AppLogger.forModule('SqliteSchemaRepair');

class SqliteSchemaRepairResult {
  const SqliteSchemaRepairResult({required this.success});

  final bool success;
}

/// 修复历史分支复用 schema version 后可能遗漏的表、索引和可安全追加的列。
class SqliteSchemaRepairOrchestrator {
  Future<SqliteSchemaRepairResult> repair() async {
    try {
      await AppDatabase.closeCached();
      await NovelContentDatabase.closeAllCached();

      final appSupportDir = await getApplicationSupportDirectory();
      final appDatabasePath = p.join(appSupportDir.path, 'reveric.sqlite');
      if (!await File(appDatabasePath).exists()) {
        throw StateError('Main database file not found: $appDatabasePath');
      }

      final appSchema = await _captureAppDatabaseSchema();
      final contentSchema = await _captureNovelContentDatabaseSchema();
      final appStats = _repairDatabase(appDatabasePath, appSchema);
      final contentPaths = await _collectNovelContentDatabasePaths(
        appSupportDir,
        appDatabasePath,
      );
      var contentStats = const _SchemaRepairStats();
      for (final path in contentPaths) {
        final stats = _repairDatabase(path, contentSchema);
        contentStats += stats;
      }

      _log.info(
        '[DB] operation=REPAIR_SCHEMA result=success '
        'databases=${1 + contentPaths.length} '
        'tables=${appStats.tablesCreated + contentStats.tablesCreated} '
        'columns=${appStats.columnsAdded + contentStats.columnsAdded} '
        'indexes=${appStats.indexesCreated + contentStats.indexesCreated} '
        'views=${appStats.viewsCreated + contentStats.viewsCreated}',
      );
      return const SqliteSchemaRepairResult(success: true);
    } catch (error, stackTrace) {
      _log.error(
        '[DB] operation=REPAIR_SCHEMA error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      return const SqliteSchemaRepairResult(success: false);
    }
  }
}

Future<_SchemaSnapshot> _captureAppDatabaseSchema() async {
  final database = AppDatabase.forSchemaRepair(NativeDatabase.memory());
  try {
    return await _captureSchema(database);
  } finally {
    await database.close();
  }
}

Future<_SchemaSnapshot> _captureNovelContentDatabaseSchema() async {
  final database = NovelContentDatabase.forSchemaRepair(
    NativeDatabase.memory(),
  );
  try {
    return await _captureSchema(database);
  } finally {
    await database.close();
  }
}

Future<_SchemaSnapshot> _captureSchema(GeneratedDatabase database) async {
  final rows = await database
      .customSelect(
        "SELECT type, name, sql FROM sqlite_master "
        "WHERE type IN ('table', 'index', 'view') "
        "AND name NOT LIKE 'sqlite_%' AND sql IS NOT NULL",
      )
      .get();

  final tables = <String, String>{};
  final indexes = <String, String>{};
  final views = <String, String>{};
  for (final row in rows) {
    final type = row.read<String>('type');
    final name = row.read<String>('name');
    final sql = row.read<String>('sql');
    switch (type) {
      case 'table':
        tables[name] = sql;
      case 'index':
        indexes[name] = sql;
      case 'view':
        views[name] = sql;
    }
  }

  return _SchemaSnapshot(
    tables: tables,
    indexes: indexes,
    views: views,
    columnDefinitions: {
      for (final entry in tables.entries)
        entry.key: _columnDefinitions(entry.value),
    },
  );
}

Future<Set<String>> _collectNovelContentDatabasePaths(
  Directory appSupportDir,
  String appDatabasePath,
) async {
  final paths = <String>{};
  final workspaceDirectory = Directory(
    p.join(appSupportDir.path, 'novel_workspaces'),
  );
  if (await workspaceDirectory.exists()) {
    await for (final entity in workspaceDirectory.list(recursive: true)) {
      if (entity is File && p.extension(entity.path) == '.sqlite') {
        paths.add(p.normalize(entity.path));
      }
    }
  }

  final appDatabase = sqlite3.open(
    toWindowsSafePath(appDatabasePath),
    mode: OpenMode.readOnly,
  );
  try {
    final rows = appDatabase.select(
      'SELECT id, content_database_path FROM novels '
      'WHERE content_database_path IS NOT NULL '
      "AND content_database_path != ''",
    );
    for (final row in rows) {
      final registeredPath = row['content_database_path'];
      if (registeredPath is! String) {
        continue;
      }
      try {
        final path = RevericPaths.resolveDatabasePath(
          registeredPath,
          support: appSupportDir.path,
        );
        if (await File(path).exists()) {
          paths.add(p.normalize(path));
        }
      } on FormatException catch (error, stackTrace) {
        _log.error(
          'invalid registered content path novel=${row['id']}',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  } finally {
    appDatabase.close();
  }

  return paths;
}

_SchemaRepairStats _repairDatabase(String path, _SchemaSnapshot schema) {
  Database? database;
  var transactionOpen = false;

  try {
    database = sqlite3.open(toWindowsSafePath(path));
    database.execute('BEGIN IMMEDIATE');
    transactionOpen = true;

    final existingObjects = _existingObjects(database);
    var stats = const _SchemaRepairStats();
    for (final entry in schema.tables.entries) {
      if (existingObjects.tables.contains(entry.key)) {
        continue;
      }
      database.execute(entry.value);
      stats += const _SchemaRepairStats(tablesCreated: 1);
    }

    for (final entry in schema.columnDefinitions.entries) {
      stats += _repairMissingColumns(
        database: database,
        tableName: entry.key,
        expectedDefinitions: entry.value,
      );
    }

    final objectsAfterTables = _existingObjects(database);
    for (final entry in schema.indexes.entries) {
      final existingSql = objectsAfterTables.indexes[entry.key];
      if (existingSql == null) {
        database.execute(entry.value);
        stats += const _SchemaRepairStats(indexesCreated: 1);
      } else if (_normalizeSql(existingSql) != _normalizeSql(entry.value)) {
        database.execute('DROP INDEX ${_quoteIdentifier(entry.key)}');
        database.execute(entry.value);
        stats += const _SchemaRepairStats(indexesCreated: 1);
      }
    }

    final objectsAfterIndexes = _existingObjects(database);
    for (final entry in schema.views.entries) {
      final existingSql = objectsAfterIndexes.views[entry.key];
      if (existingSql == null) {
        database.execute(entry.value);
        stats += const _SchemaRepairStats(viewsCreated: 1);
      } else if (_normalizeSql(existingSql) != _normalizeSql(entry.value)) {
        database.execute('DROP VIEW ${_quoteIdentifier(entry.key)}');
        database.execute(entry.value);
        stats += const _SchemaRepairStats(viewsCreated: 1);
      }
    }

    database.execute('COMMIT');
    transactionOpen = false;
    return stats;
  } catch (_) {
    if (transactionOpen) {
      try {
        database?.execute('ROLLBACK');
      } catch (_) {
        // 保留原始异常，让上层记录完整错误信息。
      }
    }
    rethrow;
  } finally {
    database?.close();
  }
}

_SchemaRepairStats _repairMissingColumns({
  required Database database,
  required String tableName,
  required Map<String, String> expectedDefinitions,
}) {
  final existingColumns = _tableColumns(database, tableName);
  final hasRows = _tableHasRows(database, tableName);
  var stats = const _SchemaRepairStats();

  for (final entry in expectedDefinitions.entries) {
    if (existingColumns.contains(entry.key)) {
      continue;
    }
    if (hasRows && !_canAddColumnToPopulatedTable(entry.value)) {
      throw StateError(
        'Cannot safely add ${entry.key} to populated table $tableName',
      );
    }
    database.execute(
      'ALTER TABLE ${_quoteIdentifier(tableName)} '
      'ADD COLUMN ${entry.value}',
    );
    stats += const _SchemaRepairStats(columnsAdded: 1);
  }
  return stats;
}

_SchemaObjects _existingObjects(Database database) {
  final tables = <String>{};
  final indexes = <String, String>{};
  final views = <String, String>{};
  final rows = database.select(
    "SELECT type, name, sql FROM sqlite_master "
    "WHERE type IN ('table', 'index', 'view') AND name NOT LIKE 'sqlite_%'",
  );
  for (final row in rows) {
    final type = row['type'] as String;
    final name = row['name'] as String;
    final sql = row['sql'] as String?;
    switch (type) {
      case 'table':
        tables.add(name);
      case 'index':
        if (sql != null) {
          indexes[name] = sql;
        }
      case 'view':
        if (sql != null) {
          views[name] = sql;
        }
    }
  }
  return _SchemaObjects(tables: tables, indexes: indexes, views: views);
}

Set<String> _tableColumns(Database database, String tableName) {
  return database
      .select('PRAGMA table_info(${_quoteIdentifier(tableName)})')
      .map((row) => row['name'] as String)
      .toSet();
}

bool _tableHasRows(Database database, String tableName) {
  final row = database
      .select(
        'SELECT EXISTS(SELECT 1 FROM ${_quoteIdentifier(tableName)} LIMIT 1) '
        'AS has_rows',
      )
      .single;
  return row['has_rows'] == 1;
}

bool _canAddColumnToPopulatedTable(String definition) {
  final upper = definition.toUpperCase();
  return !upper.contains('NOT NULL') || upper.contains('DEFAULT');
}

Map<String, String> _columnDefinitions(String createTableSql) {
  final definitions = _splitTopLevelDefinitions(createTableSql);
  final columns = <String, String>{};
  for (final definition in definitions) {
    final name = _columnName(definition);
    if (name == null) {
      continue;
    }
    columns[name] = definition;
  }
  return columns;
}

List<String> _splitTopLevelDefinitions(String createTableSql) {
  final start = createTableSql.indexOf('(');
  final end = createTableSql.lastIndexOf(')');
  if (start < 0 || end <= start) {
    throw StateError('Unable to parse table schema: $createTableSql');
  }

  final definitions = <String>[];
  final buffer = StringBuffer();
  var depth = 0;
  String? quote;
  for (var index = start + 1; index < end; index += 1) {
    final character = createTableSql[index];
    if (quote != null) {
      buffer.write(character);
      if (character == quote) {
        final nextIndex = index + 1;
        if (nextIndex < end && createTableSql[nextIndex] == quote) {
          buffer.write(createTableSql[nextIndex]);
          index += 1;
        } else {
          quote = null;
        }
      }
      continue;
    }

    if (character == "'" || character == '"' || character == '`') {
      quote = character;
      buffer.write(character);
    } else if (character == '(') {
      depth += 1;
      buffer.write(character);
    } else if (character == ')') {
      depth -= 1;
      buffer.write(character);
    } else if (character == ',' && depth == 0) {
      definitions.add(buffer.toString().trim());
      buffer.clear();
    } else {
      buffer.write(character);
    }
  }
  final finalDefinition = buffer.toString().trim();
  if (finalDefinition.isNotEmpty) {
    definitions.add(finalDefinition);
  }
  return definitions;
}

String? _columnName(String definition) {
  final trimmed = definition.trim();
  final upper = trimmed.toUpperCase();
  if (upper.startsWith('PRIMARY KEY') ||
      upper.startsWith('UNIQUE') ||
      upper.startsWith('FOREIGN KEY') ||
      upper.startsWith('CHECK') ||
      upper.startsWith('CONSTRAINT')) {
    return null;
  }

  if (trimmed.startsWith('"') ||
      trimmed.startsWith("'") ||
      trimmed.startsWith('`')) {
    final quote = trimmed[0];
    final end = trimmed.indexOf(quote, 1);
    if (end <= 1) {
      throw StateError('Unable to parse column definition: $definition');
    }
    return trimmed.substring(1, end);
  }
  return trimmed.split(RegExp(r'\s+')).first;
}

String _normalizeSql(String sql) => sql.replaceAll(RegExp(r'\s+'), ' ').trim();

String _quoteIdentifier(String identifier) =>
    '"${identifier.replaceAll('"', '""')}"';

class _SchemaSnapshot {
  const _SchemaSnapshot({
    required this.tables,
    required this.indexes,
    required this.views,
    required this.columnDefinitions,
  });

  final Map<String, String> tables;
  final Map<String, String> indexes;
  final Map<String, String> views;
  final Map<String, Map<String, String>> columnDefinitions;
}

class _SchemaObjects {
  const _SchemaObjects({
    required this.tables,
    required this.indexes,
    required this.views,
  });

  final Set<String> tables;
  final Map<String, String> indexes;
  final Map<String, String> views;
}

class _SchemaRepairStats {
  const _SchemaRepairStats({
    this.tablesCreated = 0,
    this.columnsAdded = 0,
    this.indexesCreated = 0,
    this.viewsCreated = 0,
  });

  final int tablesCreated;
  final int columnsAdded;
  final int indexesCreated;
  final int viewsCreated;

  _SchemaRepairStats operator +(_SchemaRepairStats other) {
    return _SchemaRepairStats(
      tablesCreated: tablesCreated + other.tablesCreated,
      columnsAdded: columnsAdded + other.columnsAdded,
      indexesCreated: indexesCreated + other.indexesCreated,
      viewsCreated: viewsCreated + other.viewsCreated,
    );
  }
}

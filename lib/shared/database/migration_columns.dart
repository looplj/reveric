// 职责: 根据 SQLite 的实际表结构判断迁移是否需要加列。
// 关联文件:
//   lib/shared/database/app_database_migrations.dart
//   lib/shared/database/novel_content_database.dart
// 遵循的 Rules:
//   .agents/rules/db-migration.md
import 'package:drift/drift.dart';

extension MigrationColumns on Migrator {
  Future<void> addColumnIfMissing(
    TableInfo table,
    GeneratedColumn column,
  ) async {
    if (!await tableHasColumn(database, table.actualTableName, column.$name)) {
      await addColumn(table, column);
    }
  }
}

Future<bool> tableHasColumn(
  DatabaseConnectionUser database,
  String table,
  String column,
) async {
  final match = await database
      .customSelect(
        'SELECT 1 FROM pragma_table_xinfo(?) WHERE name = ? COLLATE NOCASE',
        variables: [Variable(table), Variable(column)],
      )
      .getSingleOrNull();
  return match != null;
}

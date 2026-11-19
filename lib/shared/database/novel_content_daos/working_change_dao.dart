// 职责: 工作变更数据访问对象 — 封装所有工作变更相关的数据库操作
// 关联文件:
//   lib/shared/database/novel_content_database.dart
//   lib/shared/services/working_overlay.dart

import 'package:drift/drift.dart' hide Column;

import '../novel_content_database.dart';
import '../../utils/resource_path.dart';

part 'working_change_dao.drift.dart';

final _workDescriptionPathPattern = RegExp(r'^/works/([^/?]+)/description$');

/// 查询现行简介地址时，同时命中同一作品的旧存储键。
Expression<bool> matchesWorkingChangePath(
  String path, {
  required GeneratedColumn<String> resourcePath,
  required GeneratedColumn<String> resourceType,
  required GeneratedColumn<String> resourceId,
}) {
  final canonical = canonicalResourcePath(path);
  final exact = resourcePath.equals(canonical);
  final workId = _workDescriptionPathPattern.firstMatch(canonical)?.group(1);
  if (workId == null) {
    return exact;
  }
  return exact |
      (resourcePath.equals(legacyWorkDescriptionPath) &
          resourceType.equals('novel') &
          resourceId.equals(workId));
}

@DriftAccessor(tables: [WorkingChanges])
class WorkingChangeDao extends DatabaseAccessor<NovelContentDatabase>
    with _$WorkingChangeDaoMixin {
  WorkingChangeDao(super.db);

  Stream<List<WorkingChange>> watchAll() {
    return (select(workingChanges)..orderBy([
          (table) => OrderingTerm(
            expression: table.updatedAt,
            mode: OrderingMode.desc,
          ),
        ]))
        .watch();
  }

  Future<List<WorkingChange>> getAll() {
    return (select(workingChanges)..orderBy([
          (table) => OrderingTerm(
            expression: table.updatedAt,
            mode: OrderingMode.desc,
          ),
        ]))
        .get();
  }

  Future<List<WorkingChange>> getByResource(String resourcePath) {
    return (select(workingChanges)
          ..where(
            (table) => matchesWorkingChangePath(
              resourcePath,
              resourcePath: table.resourcePath,
              resourceType: table.resourceType,
              resourceId: table.resourceId,
            ),
          )
          ..orderBy([
            (table) => OrderingTerm(
              expression: table.updatedAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .get();
  }

  Future<WorkingChange?> getById(String id) {
    return (select(
      workingChanges,
    )..where((table) => table.id.equals(id))).getSingleOrNull();
  }

  /// oldText 在首次 INSERT 时冻结，后续 coalesce／接受只 UPDATE 原行。
  /// 当前历史表的 rowid 表示这些基线的插入顺序；不以秒级时间或随机 ID 排序。
  /// 此表未来若重建或导入，须保留基线顺序；rowid 不作为跨库身份。
  Future<List<WorkingChange>> getBySourceTurnId(String turnId) {
    return (select(workingChanges)
          ..where((table) => table.sourceTurnId.equals(turnId))
          ..orderBy([(table) => OrderingTerm.desc(table.rowId)]))
        .get();
  }

  Future<List<WorkingChange>> getBySourceTurnIds(Iterable<String> turnIds) {
    return (select(workingChanges)
          ..where((table) => table.sourceTurnId.isIn(turnIds))
          ..orderBy([(table) => OrderingTerm.asc(table.rowId)]))
        .get();
  }

  /// 只读取选中历史的插入顺序，不加载正文，也不把 rowid 作为资源身份。
  Future<Map<String, int>> getInsertionOrder(Iterable<String> changeIds) async {
    final rowId = workingChanges.rowId;
    final query = selectOnly(workingChanges)
      ..addColumns([workingChanges.id, rowId])
      ..where(workingChanges.id.isIn(changeIds));
    final rows = await query.get();
    return {
      for (final row in rows) row.read(workingChanges.id)!: row.read(rowId)!,
    };
  }

  Stream<List<WorkingChange>> watchSessionChanges(String? sessionId) {
    if (sessionId == null || sessionId.isEmpty) {
      return const Stream<List<WorkingChange>>.empty();
    }
    return (select(workingChanges)
          ..where(
            (table) =>
                table.source.equals('ai') &
                (table.status.equals('active') |
                    table.status.equals('committed')) &
                table.sourceSessionId.equals(sessionId),
          )
          ..orderBy([(table) => OrderingTerm.asc(table.rowId)]))
        .watch();
  }

  /// 清理过期历史，保留仍可提交或回退的 active 改动。
  Future<int> deleteOlderThan(DateTime cutoff) {
    return (delete(workingChanges)..where(
          (t) =>
              ColumnFilters<DateTime>(t.createdAt).isBefore(cutoff) &
              t.status.isNotValue('active'),
        ))
        .go();
  }
}

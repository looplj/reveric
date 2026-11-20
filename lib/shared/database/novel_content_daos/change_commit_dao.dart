// 职责: 变更提交数据访问对象 — 封装所有变更提交相关的数据库操作
// 关联文件:
//   lib/shared/database/novel_content_database.dart

import 'package:drift/drift.dart';

import '../novel_content_database.dart';
import '../../logger/app_logger.dart';
import 'working_change_dao.dart';

part 'change_commit_dao.drift.dart';

@DriftAccessor(tables: [ChangeCommits, ChangeCommitItems])
class ChangeCommitDao extends DatabaseAccessor<NovelContentDatabase>
    with _$ChangeCommitDaoMixin {
  ChangeCommitDao(super.db);

  Future<ChangeCommit?> getLatestCommit() {
    return (select(changeCommits)
          ..orderBy([
            (table) => OrderingTerm(
              expression: table.createdAt,
              mode: OrderingMode.desc,
            ),
          ])
          ..limit(1))
        .getSingleOrNull();
  }

  Future<ChangeCommit?> getById(String id) {
    return (select(
      changeCommits,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<List<ChangeCommit>> getAll({int? limit}) {
    final query = select(changeCommits)
      ..orderBy([
        (table) =>
            OrderingTerm(expression: table.createdAt, mode: OrderingMode.desc),
      ]);
    if (limit != null) {
      query.limit(limit);
    }
    return query.get();
  }

  Stream<List<ChangeCommit>> watchAll({int? limit}) {
    final query = select(changeCommits)
      ..orderBy([
        (table) =>
            OrderingTerm(expression: table.createdAt, mode: OrderingMode.desc),
      ]);
    if (limit != null) {
      query.limit(limit);
    }
    return query.watch();
  }

  Future<List<ChangeCommitItem>> getItemsByResource(
    String resourcePath, {
    int? limit,
  }) {
    final query = select(changeCommitItems)
      ..where(
        (table) => matchesWorkingChangePath(
          resourcePath,
          resourcePath: table.resourcePath,
          resourceType: table.resourceType,
          resourceId: table.resourceId,
        ),
      )
      ..orderBy([
        (table) =>
            OrderingTerm(expression: table.createdAt, mode: OrderingMode.desc),
      ]);
    if (limit != null) {
      query.limit(limit);
    }
    return query.get();
  }

  Future<List<ChangeCommitItem>> getItemsByResourceId(
    String resourceId, {
    int? limit,
  }) {
    final query = select(changeCommitItems)
      ..where((table) => table.resourceId.equals(resourceId))
      ..orderBy([
        (table) =>
            OrderingTerm(expression: table.createdAt, mode: OrderingMode.desc),
      ]);
    if (limit != null) {
      query.limit(limit);
    }
    return query.get();
  }

  Future<List<ChangeCommitItem>> getItemsByCommit(String commitId) {
    return (select(changeCommitItems)
          ..where((table) => table.commitId.equals(commitId))
          ..orderBy([(table) => OrderingTerm(expression: table.createdAt)]))
        .get();
  }

  Future<List<ChangeCommitItem>> getItemsByCommitAndResourceId(
    String commitId,
    String resourceId,
  ) {
    return (select(changeCommitItems)
          ..where(
            (table) =>
                table.commitId.equals(commitId) &
                table.resourceId.equals(resourceId),
          )
          ..orderBy([(table) => OrderingTerm(expression: table.createdAt)]))
        .get();
  }

  Future<ChangeCommitItem?> getItemByWorkingChangeId(String workingChangeId) {
    return (select(changeCommitItems)
          ..where((table) => table.workingChangeId.equals(workingChangeId))
          ..limit(1))
        .getSingleOrNull();
  }

  /// 返回自 [since] 起所有 `chapters.content` 字段提交的字数净变化（newText.length - oldText.length 之和）。
  ///
  /// 仅统计字符长度差，不区分增/删。返回值可能为负（如果今日整体删字多于加字）。
  Future<int> sumChapterContentDeltaSince(DateTime since) async {
    final lenNew = changeCommitItems.newText.length;
    final lenOld = changeCommitItems.oldText.length;
    final delta = (lenNew - lenOld).cast<int>();
    final sum = delta.sum();
    final query = selectOnly(changeCommitItems)
      ..addColumns([sum])
      ..where(
        changeCommitItems.resourceType.equals('chapters') &
            changeCommitItems.field.equals('content') &
            changeCommitItems.createdAt.isBiggerOrEqualValue(since),
      );
    final row = await query.getSingleOrNull();
    return row?.read<int>(sum) ?? 0;
  }

  /// 删除所有 createdAt 早于 [cutoff] 的 commit 及其关联的 commit items。
  Future<int> deleteOlderThan(DateTime cutoff) async {
    try {
      return await transaction(() async {
        final expiredIds = selectOnly(changeCommits)
          ..addColumns([changeCommits.id])
          ..where(changeCommits.createdAt.isSmallerThanValue(cutoff));
        await (delete(
          changeCommitItems,
        )..where((table) => table.commitId.isInQuery(expiredIds))).go();
        return (delete(
          changeCommits,
        )..where((table) => table.createdAt.isSmallerThanValue(cutoff))).go();
      });
    } catch (error, stackTrace) {
      AppLogger.forModule('DB').error(
        '[DB] table=change_commits,change_commit_items op=DELETE '
        'ids=created_at_before_cutoff cutoff=$cutoff',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }
}

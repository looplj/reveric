// 职责: AI 聊天会话数据访问对象 — 封装所有 AI 聊天会话相关的数据库操作
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/providers/ai_chat_providers.dart
//   lib/shared/services/ai/session_persistence.dart

import 'package:drift/drift.dart';

import '../../logger/app_logger.dart';
import '../app_database.dart';

part 'ai_chat_session_dao.drift.dart';

final _log = AppLogger.forModule('DB');

typedef CleanupSession = ({
  String id,
  String novelId,
  String? parentId,
  DateTime updatedAt,
});

@DriftAccessor(tables: [AiChatSessions])
class AiChatSessionDao extends DatabaseAccessor<AppDatabase>
    with _$AiChatSessionDaoMixin {
  AiChatSessionDao(super.db);

  /// 维护扫描只取关系和时间，不读取消息、metadata 或 UI 分页。
  Future<List<CleanupSession>> getCleanupSessions({String? rootId}) async {
    final rows = await customSelect(
      rootId == null
          ? 'SELECT id, novel_id, parent_id, updated_at FROM ai_chat_sessions'
          : '''WITH RECURSIVE tree(id) AS (
              SELECT id FROM ai_chat_sessions WHERE id = ?
              UNION
              SELECT s.id FROM ai_chat_sessions s JOIN tree t ON s.parent_id = t.id
            ) SELECT id, novel_id, parent_id, updated_at FROM ai_chat_sessions
              WHERE id IN (SELECT id FROM tree)''',
      variables: [if (rootId != null) Variable<String>(rootId)],
      readsFrom: {aiChatSessions},
    ).get();
    return rows
        .map(
          (row) => (
            id: row.read<String>('id'),
            novelId: row.read<String>('novel_id'),
            parentId: row.readNullable<String>('parent_id'),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(
              row.read<int>('updated_at') * 1000,
            ),
          ),
        )
        .toList();
  }

  Future<int> deleteCleanupSessions(List<String> ids) async {
    try {
      return await (delete(aiChatSessions)..where((t) => t.id.isIn(ids))).go();
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=ai_chat_sessions op=DELETE ids=$ids',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Stream<List<AiChatSession>> watchByNovel(String novelId, {int? limit}) {
    final query = select(aiChatSessions)
      ..where(
        (table) =>
            table.novelId.equals(novelId) &
            table.parentId.isNull() &
            table.deletedAt.equals(notDeletedSentinel),
      )
      ..orderBy([
        (table) =>
            OrderingTerm(expression: table.createdAt, mode: OrderingMode.desc),
      ]);
    if (limit != null) {
      query.limit(limit);
    }
    return query.watch();
  }

  Stream<List<AiChatSession>> watchByNovelExcludingModes(
    String novelId,
    List<String> excludedModes, {
    int? limit,
  }) {
    final query = select(aiChatSessions)
      ..where((table) {
        var condition =
            table.novelId.equals(novelId) &
            table.parentId.isNull() &
            table.deletedAt.equals(notDeletedSentinel);
        for (final mode in excludedModes) {
          condition = condition & table.mode.isNotValue(mode);
        }
        return condition;
      })
      ..orderBy([
        (table) =>
            OrderingTerm(expression: table.createdAt, mode: OrderingMode.desc),
      ]);
    if (limit != null) {
      query.limit(limit);
    }
    return query.watch();
  }

  Stream<List<AiChatSession>> watchByMode(
    String novelId,
    String mode, {
    int? limit,
  }) {
    final query = select(aiChatSessions)
      ..where(
        (table) =>
            table.novelId.equals(novelId) &
            table.parentId.isNull() &
            table.mode.equals(mode) &
            table.deletedAt.equals(notDeletedSentinel),
      )
      ..orderBy([
        (table) =>
            OrderingTerm(expression: table.createdAt, mode: OrderingMode.desc),
      ]);
    if (limit != null) {
      query.limit(limit);
    }
    return query.watch();
  }

  /// 某作品某模式的全部历史会话，按 [updatedAt] 降序。供移动端 history sheet 使用。
  Stream<List<AiChatSession>> watchHistoryByNovelAndMode(
    String novelId,
    String mode,
  ) {
    return (select(aiChatSessions)
          ..where(
            (table) =>
                table.novelId.equals(novelId) &
                table.parentId.isNull() &
                table.mode.equals(mode) &
                table.deletedAt.equals(notDeletedSentinel),
          )
          ..orderBy([
            (table) => OrderingTerm(
              expression: table.updatedAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .watch();
  }

  Expression<bool> _novelChatSessionCountCondition(
    String novelId,
    List<String> excludedModes,
  ) {
    var condition =
        aiChatSessions.novelId.equals(novelId) &
        aiChatSessions.parentId.isNull() &
        aiChatSessions.deletedAt.equals(notDeletedSentinel);
    for (final mode in excludedModes) {
      condition = condition & aiChatSessions.mode.isNotValue(mode);
    }
    return condition;
  }

  Future<int> countByNovelExcludingModes(
    String novelId,
    List<String> excludedModes,
  ) async {
    final countExp = aiChatSessions.id.count();
    final query = selectOnly(aiChatSessions)..addColumns([countExp]);
    query.where(_novelChatSessionCountCondition(novelId, excludedModes));
    final row = await query.getSingle();
    return row.read(countExp) ?? 0;
  }

  Stream<int> watchCountByNovelExcludingModes(
    String novelId,
    List<String> excludedModes,
  ) {
    final countExp = aiChatSessions.id.count();
    final query = selectOnly(aiChatSessions)..addColumns([countExp]);
    query.where(_novelChatSessionCountCondition(novelId, excludedModes));
    return query.watchSingle().map((row) => row.read(countExp) ?? 0);
  }

  Future<List<AiChatSession>> getByNovel(String novelId, {int? limit}) {
    final query = select(aiChatSessions)
      ..where(
        (table) =>
            table.novelId.equals(novelId) &
            table.parentId.isNull() &
            table.deletedAt.equals(notDeletedSentinel),
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

  Future<AiChatSession?> getById(String id, {String? novelId}) {
    final query = select(aiChatSessions)
      ..where((table) {
        var condition =
            table.id.equals(id) & table.deletedAt.equals(notDeletedSentinel);
        if (novelId != null) {
          condition = condition & table.novelId.equals(novelId);
        }
        return condition;
      });
    return query.getSingleOrNull();
  }

  /// Tool listing includes child sessions and every saved mode.
  Future<List<AiChatSession>> listForTools({
    required String workId,
    String? titleQuery,
    String? mode,
    String? parentId,
    AiChatSession? after,
    int limit = 20,
  }) {
    final query = select(aiChatSessions)
      ..where((t) {
        var condition =
            t.novelId.equals(workId) & t.deletedAt.equals(notDeletedSentinel);
        if (titleQuery != null) {
          condition &= FunctionCallExpression<int>('instr', [
            t.title,
            Variable(titleQuery),
          ]).isBiggerThanValue(0);
        }
        if (mode != null) {
          condition &= t.mode.equals(mode);
        }
        if (parentId != null) {
          condition &= t.parentId.equals(parentId);
        }
        if (after != null) {
          condition &=
              t.updatedAt.isSmallerThanValue(after.updatedAt) |
              (t.updatedAt.equals(after.updatedAt) &
                  t.id.isSmallerThanValue(after.id));
        }
        return condition;
      })
      ..orderBy([
        (t) => OrderingTerm.desc(t.updatedAt),
        (t) => OrderingTerm.desc(t.id),
      ])
      ..limit(limit);
    return query.get();
  }

  Future<List<AiChatSession>> getValidForTools(
    String workId,
    Iterable<String> ids,
  ) {
    return (select(aiChatSessions)..where(
          (t) =>
              t.novelId.equals(workId) &
              t.id.isIn(ids) &
              t.deletedAt.equals(notDeletedSentinel),
        ))
        .get();
  }

  Future<void> upsert({
    required String id,
    required String novelId,
    required String title,
    String? provider,
    String? model,
    String? mode,
    String? agentSlug,
    String? parentId,
    String? reasoningEffort,
    Map<String, dynamic>? metadata,
    DateTime? createdAt,
  }) async {
    final now = DateTime.now();
    await into(aiChatSessions).insertOnConflictUpdate(
      AiChatSessionsCompanion.insert(
        id: id,
        novelId: novelId,
        parentId: Value(parentId),
        title: Value(title),
        provider: Value(provider),
        model: Value(model),
        mode: mode == null ? const Value.absent() : Value(mode),
        agentSlug: agentSlug == null ? const Value.absent() : Value(agentSlug),
        reasoningEffort: Value(reasoningEffort),
        metadata: metadata == null ? const Value.absent() : Value(metadata),
        createdAt: createdAt == null ? const Value.absent() : Value(createdAt),
        updatedAt: Value(now),
      ),
    );
  }

  Future<void> updateTitle({
    required String id,
    required String title,
    String? novelId,
  }) {
    return (update(aiChatSessions)..where((table) {
          final matchesId = table.id.equals(id);
          if (novelId == null) {
            return matchesId;
          }
          return matchesId & table.novelId.equals(novelId);
        }))
        .write(
          AiChatSessionsCompanion(
            title: Value(title),
            updatedAt: Value(DateTime.now()),
          ),
        );
  }

  Future<void> updateModelSelection({
    required String id,
    required String? provider,
    required String? model,
    String? reasoningEffort,
    String? novelId,
  }) {
    return (update(aiChatSessions)..where((table) {
          final matchesId = table.id.equals(id);
          if (novelId == null) {
            return matchesId;
          }
          return matchesId & table.novelId.equals(novelId);
        }))
        .write(
          AiChatSessionsCompanion(
            provider: Value(provider),
            model: Value(model),
            reasoningEffort: Value(reasoningEffort),
            updatedAt: Value(DateTime.now()),
          ),
        );
  }

  Future<void> updateMode({
    required String id,
    required String mode,
    String? novelId,
  }) {
    return (update(aiChatSessions)..where((table) {
          final matchesId = table.id.equals(id);
          if (novelId == null) {
            return matchesId;
          }
          return matchesId & table.novelId.equals(novelId);
        }))
        .write(
          AiChatSessionsCompanion(
            mode: Value(mode),
            updatedAt: Value(DateTime.now()),
          ),
        );
  }

  Future<void> updateAgentSlug({
    required String id,
    required String? agentSlug,
    String? novelId,
  }) {
    return (update(aiChatSessions)..where((table) {
          final matchesId = table.id.equals(id);
          if (novelId == null) {
            return matchesId;
          }
          return matchesId & table.novelId.equals(novelId);
        }))
        .write(
          AiChatSessionsCompanion(
            agentSlug: Value(agentSlug),
            updatedAt: Value(DateTime.now()),
          ),
        );
  }

  Future<int> updateTopLevelChatAgentSlug(String agentSlug) async {
    try {
      return await (update(aiChatSessions)..where(
            (table) =>
                table.mode.equals('chat') &
                table.parentId.isNull() &
                table.deletedAt.equals(notDeletedSentinel),
          ))
          .write(
            AiChatSessionsCompanion(
              agentSlug: Value(agentSlug),
              updatedAt: Value(DateTime.now()),
            ),
          );
    } catch (error, stackTrace) {
      _log.error(
        '[ai_chat_sessions][UPDATE] failed '
        'updateTopLevelChatAgentSlug agentSlug=$agentSlug error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> touch(String id, {String? novelId}) {
    return (update(aiChatSessions)..where((table) {
          final matchesId = table.id.equals(id);
          if (novelId == null) {
            return matchesId;
          }
          return matchesId & table.novelId.equals(novelId);
        }))
        .write(AiChatSessionsCompanion(updatedAt: Value(DateTime.now())));
  }

  /// 跨作品的最近会话只列书架上仍存在的作品，回收站作品的会话不显示。
  Expression<bool> _recentCondition($AiChatSessionsTable table, String? mode) {
    final novels = attachedDatabase.novels;
    final liveNovels = selectOnly(novels)
      ..addColumns([novels.id])
      ..where(novels.deletedAt.equals(notDeletedSentinel));
    var condition =
        table.parentId.isNull() &
        table.deletedAt.equals(notDeletedSentinel) &
        table.novelId.isInQuery(liveNovels);
    if (mode != null) {
      condition = condition & table.mode.equals(mode);
    }
    return condition;
  }

  Stream<List<AiChatSession>> watchRecent({int limit = 3, String? mode}) {
    return (select(aiChatSessions)
          ..where((table) => _recentCondition(table, mode))
          ..orderBy([
            (table) => OrderingTerm(
              expression: table.updatedAt,
              mode: OrderingMode.desc,
            ),
          ])
          ..limit(limit))
        .watch();
  }

  Future<List<AiChatSession>> getRecent({int limit = 3, String? mode}) {
    return (select(aiChatSessions)
          ..where((table) => _recentCondition(table, mode))
          ..orderBy([
            (table) => OrderingTerm(
              expression: table.updatedAt,
              mode: OrderingMode.desc,
            ),
          ])
          ..limit(limit))
        .get();
  }

  Future<int> softDelete(String id, {String? novelId}) async {
    return (update(aiChatSessions)..where((table) {
          var condition = table.id.equals(id);
          if (novelId != null) {
            condition = condition & table.novelId.equals(novelId);
          }
          return condition;
        }))
        .write(
          AiChatSessionsCompanion(
            deletedAt: Value(DateTime.now()),
            updatedAt: Value(DateTime.now()),
          ),
        );
  }

  Future<int> restore(String id, {String? novelId}) async {
    return (update(aiChatSessions)..where((table) {
          var condition = table.id.equals(id);
          if (novelId != null) {
            condition = condition & table.novelId.equals(novelId);
          }
          return condition;
        }))
        .write(AiChatSessionsCompanion(deletedAt: Value(notDeletedSentinel)));
  }

  Future<int> hardDelete(String id, {String? novelId}) async {
    return (delete(aiChatSessions)..where((table) {
          var condition = table.id.equals(id);
          if (novelId != null) {
            condition = condition & table.novelId.equals(novelId);
          }
          return condition;
        }))
        .go();
  }
}

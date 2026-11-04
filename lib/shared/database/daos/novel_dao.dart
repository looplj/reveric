// 职责: 小说数据访问对象 — 封装所有小说相关的数据库操作
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/services/novel_actions.dart
//   lib/shared/models/novel_type.dart
//   lib/shared/utils/storage_paths.dart

import 'package:drift/drift.dart';

import '../../models/novel_type.dart';
import '../../models/content_kind.dart';
import '../../logger/app_logger.dart';
import '../../utils/storage_paths.dart';
import '../app_database.dart';

part 'novel_dao.drift.dart';

final _log = AppLogger.forModule('NovelDao');

@DriftAccessor(tables: [Novels])
class NovelDao extends DatabaseAccessor<AppDatabase> with _$NovelDaoMixin {
  NovelDao(super.db);

  Stream<List<Novel>> watchAll() {
    return (select(novels)
          ..where((table) => table.deletedAt.equals(notDeletedSentinel))
          ..orderBy([
            (table) => OrderingTerm(
              expression: table.updatedAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .watch();
  }

  Future<List<Novel>> getAll() {
    return (select(novels)
          ..where((table) => table.deletedAt.equals(notDeletedSentinel))
          ..orderBy([
            (table) => OrderingTerm(
              expression: table.updatedAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .get();
  }

  Stream<Novel?> watch(String id) {
    return (select(novels)..where(
          (table) =>
              table.id.equals(id) & table.deletedAt.equals(notDeletedSentinel),
        ))
        .watchSingleOrNull();
  }

  Stream<Novel?> watchByContentDatabasePath(String contentDatabasePath) {
    return (select(novels)..where(
          (table) =>
              table.contentDatabasePath.equals(contentDatabasePath) &
              table.deletedAt.equals(notDeletedSentinel),
        ))
        .watchSingleOrNull();
  }

  Future<Novel?> get(String id) {
    return (select(novels)..where(
          (table) =>
              table.id.equals(id) & table.deletedAt.equals(notDeletedSentinel),
        ))
        .getSingleOrNull();
  }

  /// 仅查询书架中可见的作品；草稿可重名，不可使用 getSingleOrNull 查询。
  Future<Novel?> getShelfByTitle(String title) {
    return (select(novels)..where(
          (table) =>
              table.title.equals(title) &
              table.deletedAt.equals(notDeletedSentinel) &
              table.draft.equals(false),
        ))
        .getSingleOrNull();
  }

  Future<Novel?> getByContentDatabasePath(String contentDatabasePath) {
    return (select(novels)..where(
          (table) =>
              table.contentDatabasePath.equals(contentDatabasePath) &
              table.deletedAt.equals(notDeletedSentinel),
        ))
        .getSingleOrNull();
  }

  Future<String> create({
    required String id,
    required String title,
    required String description,
    String? authorName,
    String? coverAssetId,
    String? contentDatabasePath,
    List<String>? tags,
    String? category,
    String? type,
    String contentKind = contentKindNovel,
    String? sourceNovelId,
    bool draft = false,
  }) async {
    validateContentKind(contentKind);
    final resolvedType = type ?? novelTypeOriginal;
    await _validateSourceNovel(
      targetNovelId: id,
      type: resolvedType,
      sourceNovelId: sourceNovelId,
    );
    final now = DateTime.now();
    try {
      await into(novels).insert(
        NovelsCompanion.insert(
          id: id,
          title: title,
          authorName: Value(authorName ?? ''),
          description: description,
          coverAssetId: Value(coverAssetId),
          type: Value(resolvedType),
          contentKind: Value(contentKind),
          sourceNovelId: Value(sourceNovelId),
          contentDatabasePath: Value(contentDatabasePath),
          tags: Value(tags ?? const []),
          category: Value(category ?? ''),
          draft: Value(draft),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB][novels][INSERT] failed id=$id title=$title draft=$draft',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
    return id;
  }

  Future<List<Novel>> getAvailableSourceNovels() {
    return (select(novels)
          ..where(
            (table) =>
                table.contentKind.equals(contentKindNovel) &
                table.deletedAt.equals(notDeletedSentinel) &
                table.draft.equals(false),
          )
          ..orderBy([(table) => OrderingTerm(expression: table.title)]))
        .get();
  }

  Future<void> updateSourceNovel({
    required String id,
    required String? sourceNovelId,
  }) async {
    try {
      await transaction(() async {
        final novel = await get(id);
        if (novel == null) {
          throw ArgumentError.value(id, 'id', 'Work was not found.');
        }
        await _validateSourceNovel(
          targetNovelId: id,
          type: novel.type,
          sourceNovelId: sourceNovelId,
        );
        await (update(novels)..where((table) => table.id.equals(id))).write(
          NovelsCompanion(
            sourceNovelId: Value(sourceNovelId),
            updatedAt: Value(DateTime.now()),
          ),
        );
      });
    } catch (error, stackTrace) {
      _log.error(
        '[DB][novels][UPDATE_SOURCE] failed id=$id sourceNovelId=$sourceNovelId',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> _validateSourceNovel({
    required String targetNovelId,
    required String type,
    required String? sourceNovelId,
  }) async {
    if (sourceNovelId == null) {
      return;
    }
    if (!novelTypeSupportsSourceNovel(type)) {
      throw ArgumentError.value(
        sourceNovelId,
        'sourceNovelId',
        'Work type $type cannot reference a source novel.',
      );
    }
    if (sourceNovelId == targetNovelId) {
      throw ArgumentError.value(
        sourceNovelId,
        'sourceNovelId',
        'A work cannot reference itself as its source novel.',
      );
    }
    final source = await get(sourceNovelId);
    if (source == null ||
        source.contentKind != contentKindNovel ||
        source.draft) {
      throw ArgumentError.value(
        sourceNovelId,
        'sourceNovelId',
        'Source must reference an available novel.',
      );
    }

    final visited = <String>{sourceNovelId};
    var ancestorId = source.sourceNovelId;
    while (ancestorId != null) {
      if (ancestorId == targetNovelId) {
        throw ArgumentError.value(
          sourceNovelId,
          'sourceNovelId',
          'Source novel relationships cannot form a cycle.',
        );
      }
      if (!visited.add(ancestorId)) {
        throw ArgumentError.value(
          sourceNovelId,
          'sourceNovelId',
          'The selected source novel already belongs to a cyclic source chain.',
        );
      }
      ancestorId = (await get(ancestorId))?.sourceNovelId;
    }
  }

  Future<int> softDelete(String id) {
    return (update(novels)..where((table) => table.id.equals(id))).write(
      NovelsCompanion(
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// 回收站列表：已软删除的作品，最近删除的在前。
  Stream<List<Novel>> watchDeleted() {
    return (select(novels)
          ..where(
            (table) => table.deletedAt.isBiggerThanValue(notDeletedSentinel),
          )
          ..orderBy([
            (table) => OrderingTerm(
              expression: table.deletedAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .watch();
  }

  Future<Novel?> getDeleted(String id) {
    return (select(novels)..where(
          (table) =>
              table.id.equals(id) &
              table.deletedAt.isBiggerThanValue(notDeletedSentinel),
        ))
        .getSingleOrNull();
  }

  Future<int> restore(String id) {
    return (update(novels)..where((table) => table.id.equals(id))).write(
      NovelsCompanion(deletedAt: Value(notDeletedSentinel)),
    );
  }

  Future<int> updateDetails({
    required String id,
    required String title,
    required String description,
    String? authorName,
    required String? coverAssetId,
    List<String>? tags,
    String? category,
    String? type,
  }) async {
    try {
      return await (update(
        novels,
      )..where((table) => table.id.equals(id))).write(
        NovelsCompanion(
          title: Value(title),
          authorName: authorName == null
              ? const Value.absent()
              : Value(authorName),
          description: Value(description),
          coverAssetId: Value(coverAssetId),
          tags: tags == null ? const Value.absent() : Value(tags),
          category: category == null ? const Value.absent() : Value(category),
          type: type == null ? const Value.absent() : Value(type),
          updatedAt: Value(DateTime.now()),
        ),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB][novels][UPDATE] failed id=$id title=$title',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<int> updateMetadata({
    required String id,
    String? title,
    String? authorName,
    String? description,
    List<String>? tags,
    String? category,
  }) async {
    try {
      return await (update(
        novels,
      )..where((table) => table.id.equals(id))).write(
        NovelsCompanion(
          title: title == null ? const Value.absent() : Value(title),
          authorName: authorName == null
              ? const Value.absent()
              : Value(authorName),
          description: description == null
              ? const Value.absent()
              : Value(description),
          tags: tags == null ? const Value.absent() : Value(tags),
          category: category == null ? const Value.absent() : Value(category),
          updatedAt: Value(DateTime.now()),
        ),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB][novels][UPDATE_METADATA] failed id=$id',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<int> updateContentDatabasePath({
    required String id,
    required String contentDatabasePath,
  }) {
    // 内容库路径列的唯一写入口：落库前归一化为相对当前根的路径，避免沙盒容器
    // 变化后绝对路径失效。根外路径（toRelative 返回 null）保留原值，不写空。
    final stored =
        RevericPaths.toRelative(contentDatabasePath) ?? contentDatabasePath;
    return (update(novels)..where((table) => table.id.equals(id))).write(
      NovelsCompanion(
        contentDatabasePath: Value(stored),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<int> updateWordCount({required String id, required int wordCount}) {
    return (update(novels)..where((table) => table.id.equals(id))).write(
      NovelsCompanion(
        wordCount: Value(wordCount),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<int> updateStatus({required String id, required String status}) {
    return (update(novels)..where((table) => table.id.equals(id))).write(
      NovelsCompanion(status: Value(status), updatedAt: Value(DateTime.now())),
    );
  }

  /// 清除快速开书占位标记。不更新 updatedAt，避免仅清标记就把空占位顶到「最近编辑」。
  Future<int> updateDraft({required String id, required bool draft}) async {
    try {
      return await (update(novels)..where((table) => table.id.equals(id)))
          .write(NovelsCompanion(draft: Value(draft)));
    } catch (error, stackTrace) {
      _log.error(
        '[DB][novels][UPDATE] failed id=$id draft=$draft',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }
}

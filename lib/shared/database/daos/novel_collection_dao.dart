// 职责: 持久化按作品类型划分的集合及多对多归属，按类型筛选查询并事务化批量加入与软删除。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/providers/novel_collection_providers.dart
//   lib/shared/models/novel_collection.dart
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../logger/app_logger.dart';
import '../../models/collections/filter.dart';
import '../../models/content_kind.dart';
import '../queries/collection_filter.dart';
import '../app_database.dart';

part 'novel_collection_dao.drift.dart';

final _log = AppLogger.forModule('NovelCollectionDao');

@DriftAccessor(tables: [NovelCollections, NovelCollectionMembers, Novels])
class NovelCollectionDao extends DatabaseAccessor<AppDatabase>
    with _$NovelCollectionDaoMixin {
  NovelCollectionDao(super.db);

  Stream<List<NovelCollection>> watchDefinitions() =>
      (select(novelCollections)
            ..where((t) => t.deletedAt.equals(notDeletedSentinel))
            ..orderBy([
              (t) => OrderingTerm.asc(t.createdAt),
              (t) => OrderingTerm.asc(t.id),
            ]))
          .watch();

  Future<List<NovelCollection>> getDefinitions() => (select(
    novelCollections,
  )..where((t) => t.deletedAt.equals(notDeletedSentinel))).get();

  // Lightweight invalidation query: never joins or projects full works.
  Stream<List<NovelCollection>> _watchDependencies() => customSelect(
    'SELECT * FROM novel_collections WHERE deleted_at = 0 ORDER BY created_at, id',
    readsFrom: {novels, novelCollections, novelCollectionMembers},
  ).watch().map((rows) => rows.map((r) => novelCollections.map(r.data)).toList());

  /// [contentKind] 为 null 时同时返回小说与剧本。
  Future<List<Novel>> getWorks(String id, {String? contentKind}) async {
    final collection = await _get(id);
    final predicate = const CollectionFilterCompiler().forCollection(
      collection,
      contentKind: contentKind,
    );
    final rows = await customSelect(
      'SELECT n.* FROM novels AS n WHERE ${predicate.sql} ORDER BY n.updated_at DESC, n.id',
      variables: predicate.variables,
      readsFrom: {novels, novelCollectionMembers},
    ).get();
    return rows.map((r) => novels.map(r.data)).toList();
  }

  Stream<List<Novel>> watchWorks(String id, {String? contentKind}) =>
      _watchDependencies().asyncMap((definitions) async {
        if (!definitions.any((c) => c.id == id)) {
          throw StateError('Collection does not exist: $id');
        }
        return getWorks(id, contentKind: contentKind);
      });

  Future<List<Novel>> preview(
    CollectionFilter filter, {
    String? contentKind,
  }) async {
    final predicate = const CollectionFilterCompiler().compile(
      contentKind: contentKind,
      filter: filter,
    );
    final rows = await customSelect(
      'SELECT n.* FROM novels AS n WHERE ${predicate.sql} ORDER BY n.updated_at DESC, n.id',
      variables: predicate.variables,
      readsFrom: {novels},
    ).get();
    return rows.map((r) => novels.map(r.data)).toList();
  }

  Future<Map<String, int?>> counts(
    List<NovelCollection> definitions, {
    String? contentKind,
  }) async {
    final result = <String, int?>{};
    final queries = <String>[];
    final variables = <Variable>[];
    Future<void> flush() async {
      if (queries.isEmpty) {
        return;
      }
      final rows = await customSelect(
        queries.join(' UNION ALL '),
        variables: List.of(variables),
        readsFrom: {novels, novelCollectionMembers, novelCollections},
      ).get();
      for (final row in rows) {
        result[row.read<String>('id')] = row.read<int>('total');
      }
      queries.clear();
      variables.clear();
    }

    for (final collection in definitions) {
      try {
        final predicate = const CollectionFilterCompiler().forCollection(
          collection,
          contentKind: contentKind,
        );
        queries.add(
          'SELECT ? AS id, COUNT(*) AS total FROM novels AS n WHERE ${predicate.sql}',
        );
        variables.add(Variable(collection.id));
        variables.addAll(predicate.variables);
      } on FormatException {
        result[collection.id] = null;
      }
      // Bound compound SELECT/parameter counts even for large libraries.
      if (queries.length == 100) {
        await flush();
      }
    }
    await flush();
    return result;
  }

  Stream<Map<String, int?>> watchCounts({String? contentKind}) =>
      _watchDependencies().asyncMap(
        (definitions) => counts(definitions, contentKind: contentKind),
      );

  Stream<Map<String, Set<String>>> watchMembership(Set<String> ids) {
    return customSelect(
      'SELECT m.collection_id, m.novel_id FROM novel_collection_members m JOIN novel_collections c ON c.id = m.collection_id JOIN novels n ON n.id = m.novel_id WHERE c.filter_mode = ? AND c.deleted_at = 0 AND m.deleted_at = 0 AND n.deleted_at = 0 AND n.draft = 0 AND m.novel_id IN (${List.filled(ids.length, '?').join(',')})',
      variables: [const Variable('manual'), for (final id in ids) Variable(id)],
      readsFrom: {novels, novelCollections, novelCollectionMembers},
    ).watch().map((rows) {
      final result = <String, Set<String>>{};
      for (final row in rows) {
        result
            .putIfAbsent(row.read<String>('collection_id'), () => {})
            .add(row.read<String>('novel_id'));
      }
      return result;
    });
  }

  Future<T> _write<T>(
    String operation,
    String id,
    Future<T> Function() action,
  ) async {
    try {
      return await transaction(action);
    } catch (error, stackTrace) {
      _log.error(
        '[DB][novel_collections,novel_collection_members][$operation] id=$id',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  String _name(String name) {
    final value = name.trim();
    if (value.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Collection name is required');
    }
    return value;
  }

  Future<NovelCollection> _get(String id) async {
    final row =
        await (select(novelCollections)..where(
              (t) => t.id.equals(id) & t.deletedAt.equals(notDeletedSentinel),
            ))
            .getSingleOrNull();
    if (row == null) {
      throw StateError('Collection does not exist: $id');
    }
    return row;
  }

  /// [contentKind] 是集合所属的库；成员只能是同类型作品。
  Future<String> create({
    required String name,
    required String contentKind,
    Iterable<String> workIds = const [],
    String filterMode = 'manual',
    CollectionFilter? filter,
  }) {
    final id = const Uuid().v4();
    return _write('INSERT', id, () async {
      if (filterMode == 'manual'
          ? filter != null
          : filterMode != 'rule' ||
                filter == null ||
                !filter.isValid ||
                workIds.isNotEmpty) {
        throw ArgumentError('Invalid collection mode, filter or members');
      }
      if (filter != null) {
        CollectionFilter.parse(filter.raw).requireValid();
      }
      validateContentKind(contentKind);
      await into(novelCollections).insert(
        NovelCollectionsCompanion.insert(
          id: id,
          name: _name(name),
          filterMode: Value(filterMode),
          filter: Value(filter),
          contentKind: Value(contentKind),
        ),
      );
      if (filterMode == 'manual') {
        await _setMembership(id, workIds.toSet(), true);
      }
      return id;
    });
  }

  Future<void> rename(String id, String name) => _write('UPDATE', id, () async {
    _requireEditable(await _get(id));
    await (update(novelCollections)..where((t) => t.id.equals(id))).write(
      NovelCollectionsCompanion(
        name: Value(_name(name)),
        updatedAt: Value(DateTime.now()),
      ),
    );
  });

  void _requireEditable(NovelCollection collection) {
    if (collection.builtin) {
      throw StateError('Builtin collection cannot be modified');
    }
  }

  Future<void> updateRule(
    String id, {
    required String name,
    required CollectionFilter filter,
  }) => _write('UPDATE', id, () async {
    final collection = await _get(id);
    _requireEditable(collection);
    if (collection.filterMode != 'rule') {
      throw StateError('Collection mode cannot be changed');
    }
    CollectionFilter.parse(filter.raw).requireValid();
    await (update(novelCollections)..where((t) => t.id.equals(id))).write(
      NovelCollectionsCompanion(
        name: Value(_name(name)),
        filter: Value(filter),
        updatedAt: Value(DateTime.now()),
      ),
    );
  });

  Future<void> softDelete(String id) => _write(
    'UPDATE_SOFT_DELETE',
    id,
    () async {
      _requireEditable(await _get(id));
      final now = DateTime.now();
      await (update(novelCollectionMembers)..where(
            (t) =>
                t.collectionId.equals(id) &
                t.deletedAt.equals(notDeletedSentinel),
          ))
          .write(
            NovelCollectionMembersCompanion(
              deletedAt: Value(now),
              updatedAt: Value(now),
            ),
          );
      await (update(novelCollections)..where((t) => t.id.equals(id))).write(
        NovelCollectionsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
      );
    },
  );

  Future<void> setMembership(
    String id,
    Iterable<String> workIds, {
    required bool included,
  }) => _write(
    included ? 'INSERT_OR_RESTORE' : 'UPDATE_REMOVE',
    id,
    () => _setMembership(id, workIds.toSet(), included),
  );

  Future<void> _setMembership(String id, Set<String> ids, bool included) async {
    final collection = await _get(id);
    if (collection.builtin ||
        collection.filterMode != 'manual' ||
        collection.filter != null) {
      throw StateError('Only manual collections accept members');
    }
    if (ids.isEmpty) {
      return;
    }
    if (included) {
      final works =
          await (select(novels)..where(
                (t) =>
                    t.id.isIn(ids) &
                    t.deletedAt.equals(notDeletedSentinel) &
                    t.draft.equals(false),
              ))
              .get();
      if (works.length != ids.length) {
        throw ArgumentError('All members must be visible works');
      }
      final kind = collection.contentKind;
      if (kind != null && works.any((w) => w.contentKind != kind)) {
        throw ArgumentError('Members must match the collection content kind');
      }
    }
    final now = DateTime.now();
    if (included) {
      for (final novelId in ids) {
        await into(novelCollectionMembers).insert(
          NovelCollectionMembersCompanion.insert(
            collectionId: id,
            novelId: novelId,
          ),
          onConflict: DoUpdate(
            (_) => NovelCollectionMembersCompanion(
              deletedAt: Value(notDeletedSentinel),
              updatedAt: Value(now),
            ),
          ),
        );
      }
    } else {
      await (update(novelCollectionMembers)..where(
            (t) =>
                t.collectionId.equals(id) &
                t.novelId.isIn(ids) &
                t.deletedAt.equals(notDeletedSentinel),
          ))
          .write(
            NovelCollectionMembersCompanion(
              deletedAt: Value(now),
              updatedAt: Value(now),
            ),
          );
    }
    await (update(novelCollections)..where((t) => t.id.equals(id))).write(
      NovelCollectionsCompanion(updatedAt: Value(now)),
    );
  }
}

// 职责: 验证集合 SQL 的字面匹配、基础范围、聚合一致性和数据变更。
// 关联文件:
//   lib/shared/database/queries/collection_filter.dart
//   lib/shared/database/daos/novel_collection_dao.dart
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/queries/collection_filter.dart';
import 'package:reveric/shared/models/collections/filter.dart';
import 'package:reveric/shared/models/collections/fields.dart';

void main() {
  late AppDatabase db;
  setUp(() async {
    db = AppDatabase.forTest(NativeDatabase.memory());
    await db
        .into(db.novels)
        .insert(
          NovelsCompanion.insert(
            id: 'a',
            title: '科幻%_"\\Abc',
            description: '',
            tags: const Value(['穿越', '引号"\\']),
            category: const Value('科幻'),
            wordCount: const Value(100),
          ),
        );
    await db
        .into(db.novels)
        .insert(
          NovelsCompanion.insert(
            id: 'b',
            title: '科幻abc',
            description: '',
            tags: const Value(['硬科幻']),
            status: const Value('finished'),
            wordCount: const Value(200),
          ),
        );
    for (final id in ['draft', 'deleted', 'script']) {
      await db
          .into(db.novels)
          .insert(
            NovelsCompanion.insert(
              id: id,
              title: 'out',
              description: '',
              draft: Value(id == 'draft'),
              deletedAt: Value(
                id == 'deleted' ? DateTime.now() : notDeletedSentinel,
              ),
              contentKind: Value(id == 'script' ? 'screenplay' : 'novel'),
            ),
          );
    }
  });
  tearDown(() => db.close());
  Future<Set<String>> matches(CollectionCondition condition) async =>
      (await db.novelCollectionDao.preview(
        CollectionFilter.fromRoot(condition),
        contentKind: 'novel',
      )).map((n) => n.id).toSet();
  test(
    'Android excludes canvas from collection queries and desktop includes it',
    () async {
      await db.novelDao.create(
        id: 'canvas',
        title: 'Canvas',
        description: '',
        contentKind: 'canvas',
      );
      final filter = CollectionFilter.fromRoot(
        const CollectionCompare('novel.word_count', 'gte', 0),
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(
        (await db.novelCollectionDao.preview(filter)).map((row) => row.id),
        isNot(contains('canvas')),
      );
      expect(
        await db.novelCollectionDao.preview(filter, contentKind: 'canvas'),
        isEmpty,
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(
        (await db.novelCollectionDao.preview(
          filter,
          contentKind: 'canvas',
        )).single.id,
        'canvas',
      );
    },
  );

  test('case-sensitive literal text and exact JSON array elements', () async {
    expect(
      await matches(
        const CollectionCompare('novel.title', 'contains', '%_"\\'),
      ),
      {'a'},
    );
    expect(
      await matches(
        const CollectionCompare('novel.title', 'starts_with', '科幻'),
      ),
      {'a', 'b'},
    );
    expect(
      await matches(const CollectionCompare('novel.title', 'ends_with', 'Abc')),
      {'a'},
    );
    expect(
      await matches(const CollectionCompare('novel.tags', 'contains', '科幻')),
      isEmpty,
    );
    expect(
      await matches(const CollectionCompare('novel.tags', 'contains', '引号"\\')),
      {'a'},
    );
    expect(
      await matches(const CollectionCompare('novel.category', 'is_empty')),
      {'b'},
    );
    expect(
      await matches(const CollectionCompare('novel.tags', 'is_empty')),
      isEmpty,
    );
    await (db.update(db.novels)..where((t) => t.id.equals('b'))).write(
      const NovelsCompanion(tags: Value([])),
    );
    expect(await matches(const CollectionCompare('novel.tags', 'is_empty')), {
      'b',
    });
  });
  test(
    'negation cannot bypass base scope; contradictory numeric bounds are empty',
    () async {
      expect(
        await matches(
          const CollectionNot(CollectionCompare('novel.title', 'eq', 'absent')),
        ),
        {'a', 'b'},
      );
      expect(
        await matches(
          CollectionGroup(false, [
            const CollectionCompare('novel.word_count', 'gte', 200),
            const CollectionCompare('novel.word_count', 'lte', 100),
          ]),
        ),
        isEmpty,
      );
    },
  );
  test(
    'counts, list and preview share semantics; invalid rules are isolated',
    () async {
      final filter = CollectionFilter.fromRoot(
        const CollectionCompare('novel.status', 'eq', 'in_progress'),
      );
      final id = await db.novelCollectionDao.create(
        name: 'Rule',
        contentKind: 'novel',
        filterMode: 'rule',
        filter: filter,
      );
      await db
          .into(db.novelCollections)
          .insert(
            NovelCollectionsCompanion.insert(
              id: 'bad',
              name: 'Bad',
              filterMode: const Value('rule'),
              filter: Value(CollectionFilter.parse('{"version":2,"root":{}}')),
            ),
          );
      final counts = await db.novelCollectionDao
          .watchCounts(contentKind: 'novel')
          .first;
      expect(counts, {id: 1, 'bad': null});
      expect(
        (await db.novelCollectionDao.getWorks(
          id,
          contentKind: 'novel',
        )).map((n) => n.id),
        ['a'],
      );
      await expectLater(
        db.novelCollectionDao.setMembership(id, ['b'], included: true),
        throwsStateError,
      );
      await db.novelCollectionDao.rename('bad', 'Renamed');
      expect(
        (await db.novelCollectionDao.watchDefinitions().first)
            .singleWhere((c) => c.id == 'bad')
            .filter!
            .raw,
        '{"version":2,"root":{}}',
      );
      await (db.update(db.novels)..where((t) => t.id.equals('b'))).write(
        const NovelsCompanion(status: Value('in_progress')),
      );
      expect(
        (await db.novelCollectionDao
            .watchCounts(contentKind: 'novel')
            .first)[id],
        2,
      );
    },
  );
  test(
    'review: rule save revalidates the current registry and keeps name atomic',
    () async {
      final original = CollectionFilter.fromRoot(
        const CollectionCompare('novel.status', 'eq', 'in_progress'),
      );
      final id = await db.novelCollectionDao.create(
        name: 'Original',
        contentKind: 'novel',
        filterMode: 'rule',
        filter: original,
      );
      final custom = CollectionFilter.fromRoot(
        const CollectionCompare('test.custom', 'eq', 'x'),
        fields: {
          ...collectionFields,
          'test.custom': const CollectionField(
            'test.custom',
            CollectionValueType.text,
            {'eq'},
          ),
        },
      );
      expect(custom.isValid, isTrue);
      await expectLater(
        db.novelCollectionDao.updateRule(id, name: 'Changed', filter: custom),
        throwsFormatException,
      );
      final saved = (await db.novelCollectionDao.getDefinitions()).single;
      expect(saved.name, 'Original');
      expect(saved.filter!.raw, original.raw);
    },
  );

  test(
    'review: collection builtin DDL has only nullability and default',
    () async {
      final ddl =
          (await db
                  .customSelect(
                    "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'novel_collections'",
                  )
                  .getSingle())
              .read<String>('sql');
      expect(ddl.toUpperCase(), isNot(contains('CHECK')));
      expect(ddl, contains('"builtin" INTEGER NOT NULL DEFAULT 0'));
    },
  );

  test(
    'field extension registers validation and SQL without changing envelope',
    () async {
      final fields = {
        ...collectionFields,
        'test.author': const CollectionField(
          'test.author',
          CollectionValueType.text,
          {'eq'},
        ),
      };
      final filter = CollectionFilter.fromRoot(
        const CollectionCompare('test.author', 'eq', 'Writer'),
        fields: fields,
      );
      final predicate = CollectionFilterCompiler(
        fields: fields,
        columns: const {'test.author': 'author_name'},
      ).compile(contentKind: 'novel', filter: filter);
      expect(predicate.sql, contains('n."author_name" = ?'));
      expect(
        await db
            .customSelect(
              'SELECT n.id FROM novels n WHERE ${predicate.sql}',
              variables: predicate.variables,
            )
            .get(),
        isEmpty,
      );
    },
  );
}

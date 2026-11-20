// 职责: 验证默认集合的事务初始化、保护边界和失败重试。
// 关联文件:
//   lib/shared/services/initialization/collection_seeds.dart
//   lib/shared/services/app_initialization.dart
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/content_status.dart';
import 'package:reveric/shared/services/initialization/collection_seeds.dart';

void main() {
  late AppDatabase db;
  const names = {
    'all': 'All',
    'in_progress': 'In progress',
    'finished': 'Finished',
  };
  setUp(() => db = AppDatabase.forTest(NativeDatabase.memory()));
  tearDown(() => db.close());
  test(
    'three seeds, one protected record; retries preserve renamed and deleted defaults',
    () async {
      await seedCollections(db, names: names);
      final rows = await db.select(db.novelCollections).get();
      expect(rows.length, 3);
      expect(rows.where((c) => c.builtin).single.id, 'collection:all');
      await db.novelCollectionDao.rename('collection:in_progress', 'Custom');
      await db.novelCollectionDao.softDelete('collection:finished');
      await seedCollections(db, names: names);
      expect((await db.select(db.novelCollections).get()).length, 3);
      final active = await db.novelCollectionDao.watchDefinitions().first;
      expect(active.length, 2);
      expect(active.singleWhere((c) => !c.builtin).name, 'Custom');
      await expectLater(
        db.novelCollectionDao.rename('collection:all', 'New'),
        throwsStateError,
      );
      await expectLater(
        db.novelCollectionDao.softDelete('collection:all'),
        throwsStateError,
      );
      await expectLater(
        db.novelCollectionDao.setMembership(
          'collection:all',
          [],
          included: false,
        ),
        throwsStateError,
      );
    },
  );
  test('failure rolls back all seeds and can retry', () async {
    await expectLater(
      seedCollections(db, names: {'all': 'All'}),
      throwsStateError,
    );
    expect(await db.select(db.novelCollections).get(), isEmpty);
    await seedCollections(db, names: names);
    expect((await db.select(db.novelCollections).get()).length, 3);
  });
  test('corrupt builtin is reported and never rewritten', () async {
    await db
        .into(db.novelCollections)
        .insert(
          NovelCollectionsCompanion.insert(
            id: 'collection:all',
            name: 'Bad',
            builtin: const Value(true),
          ),
        );
    await expectLater(seedCollections(db, names: names), throwsFormatException);
    expect((await db.select(db.novelCollections).get()).single.name, 'Bad');
  });

  test(
    'soft-deletes unscoped collections and keeps builtin and scoped ones',
    () async {
      await seedCollections(db, names: names);
      await db.novelCollectionDao.create(
        name: 'Mine',
        contentKind: contentKindNovel,
      );
      await db.novelCollectionDao.rename('collection:in_progress', 'Custom');
      await removeUnscopedCollections(db);
      final active = await db.novelCollectionDao.getDefinitions();
      expect(active.map((c) => c.id), contains('collection:all'));
      expect(active.map((c) => c.name), contains('Mine'));
      expect(
        active.map((c) => c.id),
        isNot(contains('collection:in_progress')),
      );
      expect(active.map((c) => c.id), isNot(contains('collection:finished')));
      final stored = await db.select(db.novelCollections).get();
      expect(
        stored.singleWhere((c) => c.id == 'collection:in_progress').deletedAt,
        isNot(notDeletedSentinel),
      );
      await removeUnscopedCollections(db);
      expect(
        (await db.novelCollectionDao.getDefinitions()).map((c) => c.id),
        active.map((c) => c.id),
      );
    },
  );

  test('kind status collections stay scoped and do not revive edits', () async {
    const kindNames = {
      'collection:novel:in_progress': 'In progress',
      'collection:novel:finished': 'Finished',
      'collection:screenplay:in_progress': 'In progress',
      'collection:screenplay:finished': 'Finished',
      'collection:canvas:in_progress': 'Active',
      'collection:canvas:archived': 'Archived',
    };
    await insertKindStatusCollections(db, names: kindNames);
    final rows = await db.select(db.novelCollections).get();
    expect(rows, hasLength(6));
    final canvasActive = rows.singleWhere(
      (c) => c.id == 'collection:canvas:in_progress',
    );
    expect(canvasActive.contentKind, contentKindCanvas);
    expect(canvasActive.name, 'Active');
    expect(canvasActive.builtin, isFalse);
    expect(canvasActive.filter!.raw, contains(contentStatusInProgress));
    expect(
      rows.singleWhere((c) => c.id == 'collection:canvas:archived').filter!.raw,
      contains(contentStatusArchived),
    );
    expect(
      rows.where((c) => c.contentKind == contentKindNovel).map((c) => c.id),
      containsAll([
        'collection:novel:in_progress',
        'collection:novel:finished',
      ]),
    );
    expect(
      rows.singleWhere((c) => c.id == 'collection:novel:finished').filter!.raw,
      contains(contentStatusFinished),
    );
    await db.novelCollectionDao.rename(
      'collection:novel:in_progress',
      'Custom',
    );
    await db.novelCollectionDao.softDelete('collection:canvas:archived');
    await insertKindStatusCollections(
      db,
      names: {for (final id in kindNames.keys) id: 'Replaced'},
    );
    final again = await db.select(db.novelCollections).get();
    expect(again, hasLength(6));
    expect(
      again.singleWhere((c) => c.id == 'collection:novel:in_progress').name,
      'Custom',
    );
    expect(
      again.singleWhere((c) => c.id == 'collection:canvas:archived').deletedAt,
      isNot(notDeletedSentinel),
    );
  });

  test('missing kind collection name rolls the insert back', () async {
    await expectLater(
      insertKindStatusCollections(
        db,
        names: {'collection:novel:in_progress': 'Only'},
      ),
      throwsStateError,
    );
    expect(await db.select(db.novelCollections).get(), isEmpty);
  });
}

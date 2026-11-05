// 职责: 验证集合多对多归属、原子校验、软删除和跨连接持久化。
// 关联文件:
//   lib/shared/database/daos/novel_collection_dao.dart
//   lib/shared/models/novel_collection.dart
//   lib/shared/database/app_database.dart
import 'dart:io';
import 'collection_test_helpers.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/content_kind.dart';

void main() {
  late AppDatabase db;
  setUp(() async {
    db = AppDatabase.forTest(NativeDatabase.memory());
    for (final id in ['a', 'b']) {
      await db.novelDao.create(id: id, title: id, description: '');
    }
    await db.novelDao.create(
      id: 'script',
      title: 'script',
      description: '',
      contentKind: contentKindScreenplay,
    );
    await db.novelDao.create(
      id: 'draft',
      title: 'draft',
      description: '',
      draft: true,
    );
  });
  tearDown(() => db.close());

  test(
    'many-to-many membership is idempotent and does not edit works',
    () async {
      final before = await db.novelDao.get('a');
      final first = await db.novelCollectionDao.create(
        name: '  Series  ',
        contentKind: contentKindNovel,
        workIds: ['a'],
      );
      final second = await db.novelCollectionDao.create(
        name: 'Series',
        contentKind: contentKindNovel,
        workIds: ['a', 'b'],
      );
      await db.novelCollectionDao.setMembership(first, [
        'a',
        'a',
      ], included: true);
      var snapshot = await manualSnapshots(db);
      expect(snapshot.singleWhere((c) => c.id == first).name, 'Series');
      expect(
        snapshot.singleWhere((c) => c.id == first).membership(['a', 'b']),
        isNull,
      );
      expect(
        snapshot.singleWhere((c) => c.id == second).membership(['a', 'b']),
        isTrue,
      );
      await db.novelCollectionDao.setMembership(first, [
        'a',
        'b',
      ], included: true);
      snapshot = await manualSnapshots(db);
      expect(snapshot.singleWhere((c) => c.id == first).workIds, {'a', 'b'});
      expect((await db.select(db.novelCollectionMembers).get()).length, 4);
      expect((await db.novelDao.get('a'))!.updatedAt, before!.updatedAt);
    },
  );

  test(
    'invalid batches and create-with-members roll back completely',
    () async {
      final id = await db.novelCollectionDao.create(
        name: 'Empty',
        contentKind: contentKindNovel,
      );
      await db.novelDao.softDelete('b');
      for (final invalid in ['draft', 'b', 'missing']) {
        await expectLater(
          db.novelCollectionDao.setMembership(id, [
            'a',
            invalid,
          ], included: true),
          throwsArgumentError,
        );
        expect((await db.select(db.novelCollectionMembers).get()), isEmpty);
        await expectLater(
          db.novelCollectionDao.create(
            name: invalid,
            contentKind: contentKindNovel,
            workIds: ['a', invalid],
          ),
          throwsArgumentError,
        );
      }
      await expectLater(
        db.novelCollectionDao.create(
          name: '   ',
          contentKind: contentKindNovel,
        ),
        throwsArgumentError,
      );
      expect((await db.select(db.novelCollections).get()).length, 1);
      await expectLater(
        db.novelCollectionDao.rename(id, '  '),
        throwsArgumentError,
      );
      expect((await manualSnapshots(db)).single.name, 'Empty');
    },
  );

  test(
    'manual collections belong to one content kind and reject other members',
    () async {
      final dao = db.novelCollectionDao;
      await expectLater(
        dao.create(
          name: 'Series',
          contentKind: contentKindNovel,
          workIds: ['a', 'script'],
        ),
        throwsArgumentError,
      );
      await expectLater(
        dao.create(name: 'Series', contentKind: 'comic'),
        throwsArgumentError,
      );
      final id = await dao.create(
        name: 'Scripts',
        contentKind: contentKindScreenplay,
        workIds: ['script'],
      );
      await expectLater(
        dao.setMembership(id, ['a'], included: true),
        throwsArgumentError,
      );
      final collection = (await dao.getDefinitions()).single;
      expect(collection.contentKind, contentKindScreenplay);
      expect(
        (await dao.getWorks(
          id,
          contentKind: contentKindScreenplay,
        )).map((n) => n.id),
        ['script'],
      );
      expect(
        (await dao.counts([
          collection,
        ], contentKind: contentKindScreenplay))[id],
        1,
      );
    },
  );

  test(
    'remove and rejoin restores the relationship; delete keeps works',
    () async {
      final id = await db.novelCollectionDao.create(
        name: 'Series',
        contentKind: contentKindNovel,
        workIds: ['a', 'b'],
      );
      final other = await db.novelCollectionDao.create(
        name: 'Other',
        contentKind: contentKindNovel,
        workIds: ['a'],
      );
      final original = (await db.select(db.novelCollectionMembers).get()).first;
      await db.novelCollectionDao.setMembership(id, ['a'], included: false);
      expect(
        (await manualSnapshots(db)).singleWhere((c) => c.id == id).workIds,
        {'b'},
      );
      expect((await db.select(db.novelCollectionMembers).get()).length, 3);
      await db.novelCollectionDao.setMembership(id, ['a'], included: true);
      expect(
        (await db.select(db.novelCollectionMembers).get()).first.createdAt,
        original.createdAt,
      );
      await db.novelCollectionDao.rename(id, 'Renamed');
      expect(
        (await manualSnapshots(db)).singleWhere((c) => c.id == id).name,
        'Renamed',
      );
      await db.novelCollectionDao.softDelete(id);
      final snapshot = await manualSnapshots(db);
      expect(snapshot.single.id, other);
      expect(snapshot.single.workIds, {'a'});
      expect((await db.novelDao.get('a'))!.deletedAt, notDeletedSentinel);
      expect((await db.novelDao.get('b'))!.deletedAt, notDeletedSentinel);
      expect(
        (await db.select(db.novelCollectionMembers).get())
            .where((m) => m.collectionId == id)
            .every((m) => m.deletedAt != notDeletedSentinel),
        isTrue,
      );
      await expectLater(
        db.novelCollectionDao.setMembership(id, ['a'], included: true),
        throwsStateError,
      );
    },
  );

  test(
    'deleted works disappear from counts and covers and return on restore',
    () async {
      await db.novelCollectionDao.create(
        name: 'Series',
        contentKind: contentKindNovel,
        workIds: ['a'],
      );
      await db.novelDao.softDelete('a');
      expect((await manualSnapshots(db)).single.works, isEmpty);
      await db.novelDao.restore('a');
      expect((await manualSnapshots(db)).single.workIds, {'a'});
    },
  );

  test('collections persist after reopening the main database', () async {
    final directory = await Directory.systemTemp.createTemp(
      'reveric_collections_',
    );
    final file = File('${directory.path}/app.sqlite');
    var persistent = AppDatabase.forTest(NativeDatabase(file));
    try {
      await persistent.novelDao.create(
        id: 'kept',
        title: 'Kept',
        description: '',
      );
      await persistent.novelCollectionDao.create(
        name: 'Saved',
        contentKind: contentKindNovel,
        workIds: ['kept'],
      );
      await persistent.close();
      persistent = AppDatabase.forTest(NativeDatabase(file));
      final collection = (await manualSnapshots(persistent)).single;
      expect(collection.name, 'Saved');
      expect(collection.workIds, {'kept'});
    } finally {
      await persistent.close();
      await directory.delete(recursive: true);
    }
  });
}

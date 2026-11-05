// 职责: 验证集合导航顺序持久化及定义与作品独立更新。
// 关联文件:
//   lib/shared/providers/novel_collection_providers.dart
//   lib/shared/models/novel_collection.dart
import 'dart:async';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/novel_collection.dart';
import 'package:reveric/shared/providers/novel_collection_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/initialization/collection_seeds.dart';

void main() {
  late AppDatabase db;
  setUp(() async {
    db = AppDatabase.forTest(NativeDatabase.memory());
    await seedCollections(
      db,
      names: {
        'all': 'All',
        'in_progress': 'In progress',
        'finished': 'Finished',
      },
    );
  });
  tearDown(() => db.close());
  test(
    'normalizes order and preserves new/deleted IDs across containers',
    () async {
      final manual = await db.novelCollectionDao.create(
        name: 'Manual',
        contentKind: contentKindNovel,
      );
      var container = ProviderContainer.test(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      var sub = container.listen(orderedCollectionsProvider, (_, _) {});
      final defaults = await container.read(orderedCollectionsProvider.future);
      expect(defaults.map((c) => c.id), [
        'collection:all',
        'collection:in_progress',
        'collection:finished',
        manual,
      ]);
      await saveCollectionOrder(db, [
        manual,
        manual,
        'missing',
        'collection:all',
        'collection:finished',
      ]);
      sub.close();
      container.dispose();
      container = ProviderContainer.test(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      sub = container.listen(orderedCollectionsProvider, (_, _) {});
      final saved = await container.read(orderedCollectionsProvider.future);
      expect(saved.map((c) => c.id), [
        'collection:all',
        manual,
        'collection:finished',
        'collection:in_progress',
      ]);
      await db.novelCollectionDao.softDelete('collection:finished');
      final definitions = (await db.novelCollectionDao.watchDefinitions().first)
          .map(LibraryCollection.new)
          .toList();
      expect(
        orderCollections(
          definitions,
          saved.map((c) => c.id).toList(),
        ).map((c) => c.id),
        ['collection:all', manual, 'collection:in_progress'],
      );
      sub.close();
      container.dispose();
    },
  );
  test(
    'status, metadata fields, membership, soft deletion and drafts update streams',
    () async {
      await db.novelDao.create(
        id: 'work',
        title: 'Work',
        description: '',
        draft: true,
      );
      final works = StreamIterator(
        db.novelCollectionDao.watchWorks('collection:in_progress'),
      );
      final counts = StreamIterator(db.novelCollectionDao.watchCounts());
      expect(await next(works), isEmpty);
      expect((await next(counts))['collection:all'], 0);
      await (db.update(db.novels)..where((t) => t.id.equals('work'))).write(
        const NovelsCompanion(draft: Value(false)),
      );
      expect((await next(works)).single.id, 'work');
      expect((await next(counts))['collection:all'], 1);
      await (db.update(db.novels)..where((t) => t.id.equals('work'))).write(
        const NovelsCompanion(
          status: Value('finished'),
          tags: Value(['科幻']),
          category: Value('小说'),
          wordCount: Value(123),
        ),
      );
      expect(await next(works), isEmpty);
      expect((await next(counts))['collection:finished'], 1);
      await db.novelDao.softDelete('work');
      expect((await next(counts))['collection:all'], 0);
      await works.cancel();
      await counts.cancel();
      final id = await db.novelCollectionDao.create(
        name: 'Manual',
        contentKind: contentKindNovel,
      );
      await db.novelDao.restore('work');
      final members = StreamIterator(db.novelCollectionDao.watchWorks(id));
      expect(await next(members), isEmpty);
      await db.novelCollectionDao.setMembership(id, ['work'], included: true);
      expect((await next(members)).single.id, 'work');
      await db.novelCollectionDao.setMembership(id, ['work'], included: false);
      expect(await next(members), isEmpty);
      await members.cancel();
    },
  );
}

Future<T> next<T>(StreamIterator<T> iterator) async {
  expect(await iterator.moveNext(), isTrue);
  return iterator.current;
}

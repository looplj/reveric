// 职责: 验证正式发布 schema 直接升级到 v4 时集合按作品类型定型、混合集合拆分且旧数据保留。
// 关联文件:
//   lib/shared/database/app_database_migrations.dart
//   lib/shared/database/app_database.dart
//   lib/shared/database/daos/novel_collection_dao.dart
// 遵循的 Rules:
//   .agents/rules/db-migration.md
//   .agents/rules/testing.md

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/collections/filter.dart';
import 'package:reveric/shared/models/content_kind.dart';

void main() {
  final statusFilter = CollectionFilter.fromRoot(
    CollectionCompare('novel.status', 'eq', 'in_progress'),
  ).raw;
  // 每种需要定型的情况各一个集合；mixed 另有一条已移出的小说成员。
  final seed =
      '''
INSERT INTO novels (id, title, description, content_kind, created_at, updated_at) VALUES
  ('n1', 'Novel 1', '', 'novel', 100, 100),
  ('n2', 'Novel 2', '', 'novel', 100, 100),
  ('s1', 'Script 1', '', 'screenplay', 100, 100),
  ('s2', 'Script 2', '', 'screenplay', 100, 100);
INSERT INTO novel_collections (id, name, builtin, filter_mode, filter, created_at, updated_at, deleted_at) VALUES
  ('collection:all', 'All', 1, 'rule', NULL, 10, 10, 0),
  ('collection:in_progress', 'In progress', 0, 'rule', '${statusFilter.replaceAll("'", "''")}', 11, 11, 0),
  ('collection:finished', 'Finished', 0, 'rule', '${statusFilter.replaceAll("'", "''").replaceAll('in_progress', 'finished')}', 12, 12, 0),
  ('novels-only', 'Novels', 0, 'manual', NULL, 20, 20, 0),
  ('scripts-only', 'Scripts', 0, 'manual', NULL, 21, 21, 0),
  ('empty', 'Empty', 0, 'manual', NULL, 22, 22, 0),
  ('mixed', 'Mixed', 0, 'manual', NULL, 23, 23, 0),
  ('deleted-mixed', 'Old', 0, 'manual', NULL, 24, 24, 30);
INSERT INTO novel_collection_members (collection_id, novel_id, created_at, updated_at, deleted_at) VALUES
  ('novels-only', 'n1', 40, 40, 0),
  ('scripts-only', 's1', 41, 41, 0),
  ('mixed', 'n1', 42, 42, 0),
  ('mixed', 'n2', 43, 43, 50),
  ('mixed', 's1', 44, 44, 0),
  ('mixed', 's2', 45, 45, 0),
  ('deleted-mixed', 'n1', 46, 46, 0),
  ('deleted-mixed', 's1', 47, 47, 0);
INSERT INTO app_settings (key, value, updated_at) VALUES
  ('library.collection_order', '["collection:all","mixed","novels-only"]', 60);
''';

  for (final (release, fixture, version) in [
    ('v0.4.0', 'app_v0_4_0.sql', 1),
    ('v0.7.1', 'app_v0_7_1.sql', 3),
  ]) {
    test('$release (schema v$version) upgrades collections by content kind', () async {
      final db = AppDatabase.forTest(
        NativeDatabase.memory(
          setup: (sqlite) {
            sqlite.execute(
              File('test/shared/database/fixtures/$fixture').readAsStringSync(),
            );
            expect(
              sqlite.select('PRAGMA user_version').single['user_version'],
              version,
            );
            sqlite.execute(seed);
          },
        ),
      );
      addTearDown(db.close);

      Future<int> scalar(String sql) async =>
          (await db.customSelect(sql).getSingle()).data.values.single as int;

      expect(
        await scalar('PRAGMA user_version'),
        AppDatabase.currentSchemaVersion,
      );
      final column =
          (await db.customSelect('PRAGMA table_info(novel_collections)').get())
              .singleWhere((row) => row.read<String>('name') == 'content_kind');
      expect(column.read<String>('type'), 'TEXT');
      expect(column.read<int>('notnull'), 0);
      final pk =
          (await db.customSelect('PRAGMA table_info(novel_collections)').get())
              .where((row) => row.read<int>('pk') > 0)
              .map((row) => row.read<String>('name'));
      expect(pk, ['id']);
      expect(
        (await db
                .customSelect('PRAGMA index_list(novel_collection_members)')
                .get())
            .map((row) => row.read<String>('name')),
        contains('novel_collection_members_by_novel_id'),
      );
      expect(await scalar('SELECT COUNT(*) FROM novels'), 4);

      final rows = await db
          .customSelect(
            'SELECT id, name, filter_mode, content_kind, typeof(content_kind) AS type, '
            'created_at, deleted_at FROM novel_collections',
          )
          .get();
      expect(rows, hasLength(9));
      String? kind(String id) => rows
          .singleWhere((row) => row.read<String>('id') == id)
          .readNullable<String>('content_kind');
      for (final shared in [
        'collection:all',
        'collection:in_progress',
        'collection:finished',
      ]) {
        expect(kind(shared), isNull, reason: shared);
      }
      expect(kind('novels-only'), contentKindNovel);
      expect(kind('scripts-only'), contentKindScreenplay);
      expect(kind('empty'), contentKindNovel);
      expect(kind('mixed'), contentKindNovel);
      // 已删除的集合只定型不拆。
      expect(kind('deleted-mixed'), contentKindNovel);

      final copy = rows.singleWhere(
        (row) =>
            row.read<String>('name') == 'Mixed' &&
            row.read<String>('id') != 'mixed',
      );
      final copyId = copy.read<String>('id');
      expect(copy.read<String>('content_kind'), contentKindScreenplay);
      expect(copy.read<String>('type'), 'text');
      expect(copy.read<String>('filter_mode'), 'manual');
      expect(copy.read<int>('created_at'), 23);
      expect(copy.read<int>('deleted_at'), 0);

      Future<Set<String>> active(String id) async => {
        for (final row
            in await db
                .customSelect(
                  "SELECT novel_id FROM novel_collection_members WHERE collection_id = '$id' AND deleted_at = 0",
                )
                .get())
          row.read<String>('novel_id'),
      };
      expect(await active('mixed'), {'n1'});
      expect(await active(copyId), {'s1', 's2'});
      expect(await active('novels-only'), {'n1'});
      expect(await active('scripts-only'), {'s1'});
      expect(await active('deleted-mixed'), {'n1', 's1'});
      // 原集合里的剧本成员是软删除，记录仍在；早先移出的小说成员保持原样。
      expect(
        await scalar(
          "SELECT COUNT(*) FROM novel_collection_members WHERE collection_id = 'mixed'",
        ),
        4,
      );
      expect(
        await scalar(
          "SELECT deleted_at FROM novel_collection_members WHERE collection_id = 'mixed' AND novel_id = 'n2'",
        ),
        50,
      );

      // 拆出的集合在导航顺序里紧跟原集合。
      expect(
        jsonDecode((await db.appSettingsDao.get('library.collection_order'))!),
        ['collection:all', 'mixed', copyId, 'novels-only'],
      );

      // 通过 typed DAO 读取迁移后的记录。
      final definitions = await db.novelCollectionDao.getDefinitions();
      expect(
        definitions.singleWhere((c) => c.id == copyId).contentKind,
        contentKindScreenplay,
      );
      expect(
        definitions.singleWhere((c) => c.id == 'collection:all').contentKind,
        isNull,
      );
      expect(
        (await db.novelCollectionDao.getWorks(
          copyId,
          contentKind: contentKindScreenplay,
        )).map((n) => n.id).toSet(),
        {'s1', 's2'},
      );
    });
  }
}

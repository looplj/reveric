// 职责: 验证正式 schema 升级及插件数据、启用选择的隔离与保留。
// 关联文件:
//   lib/shared/database/daos/plugin_dao.dart
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';

void main() {
  test(
    'published fixture upgrades while preserving retained tables and removing legacy memory',
    () async {
      final original = <String, String>{};
      final counts = <String, int>{};
      final db = AppDatabase.forTest(
        NativeDatabase.memory(
          setup: (sqlite) {
            sqlite.execute(
              File(
                'test/shared/database/fixtures/app_v0_4_0.sql',
              ).readAsStringSync(),
            );
            for (final row in sqlite.select(
              "SELECT name,sql FROM sqlite_master WHERE type='table'",
            )) {
              final name = row['name'] as String;
              original[name] = row['sql'] as String;
              counts[name] =
                  sqlite.select('SELECT count(*) AS n FROM "$name"').single['n']
                      as int;
            }
          },
        ),
      );
      addTearDown(db.close);
      expect(await db.appSettingsDao.get('fixture'), 'retained');
      expect(
        (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
          'user_version',
        ),
        AppDatabase.currentSchemaVersion,
      );
      expect(
        (await db
                .customSelect(
                  "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'plugin_%' ORDER BY name",
                )
                .get())
            .map((row) => row.read<String>('name')),
        [
          'plugin_permissions',
          'plugin_registry',
          'plugin_secrets',
          'plugin_storage',
          'plugin_tasks',
        ],
      );
      expect(
        await db
            .customSelect(
              "SELECT name FROM sqlite_master WHERE name = 'memories'",
            )
            .get(),
        isEmpty,
      );
      for (final entry in original.entries.where(
        (entry) => entry.key != 'memories',
      )) {
        expect(
          (await db
                  .customSelect(
                    "SELECT sql FROM sqlite_master WHERE name='${entry.key}'",
                  )
                  .getSingle())
              .read<String>('sql'),
          // v4 给集合表追加类型列，v5 给渠道素材表追加上传列，其余表结构原样保留。
          switch (entry.key) {
            'novel_collections' => entry.value.replaceFirst(
              ', PRIMARY KEY ("id"))',
              ', "content_kind" TEXT NULL, PRIMARY KEY ("id"))',
            ),
            'provider_assets' => entry.value.replaceFirst(
              ', PRIMARY KEY ("id"))',
              ', "kind" TEXT NOT NULL DEFAULT \'certification\', '
                  '"context_hash" TEXT NULL, "remote_url" TEXT NULL, '
                  '"expires_at" INTEGER NULL, PRIMARY KEY ("id"))',
            ),
            _ => entry.value,
          },
        );
        expect(
          (await db
                  .customSelect('SELECT count(*) AS n FROM "${entry.key}"')
                  .getSingle())
              .read<int>('n'),
          counts[entry.key],
        );
      }
      for (final table in [
        'plugin_permissions',
        'plugin_registry',
        'plugin_storage',
        'plugin_secrets',
      ]) {
        final columns = await db
            .customSelect('PRAGMA table_info($table)')
            .get();
        expect(
          columns
              .firstWhere((c) => c.read<String>('name') == 'plugin_id')
              .read<int>('pk'),
          1,
        );
        expect(
          columns
              .firstWhere((c) => c.read<String>('name') == 'created_at')
              .read<String>('type'),
          'INTEGER',
        );
        expect(
          columns
              .firstWhere((c) => c.read<String>('name') == 'updated_at')
              .read<String>('type'),
          'INTEGER',
        );
        if (table != 'plugin_registry') {
          expect(columns.where((c) => c.read<int>('pk') == 2), hasLength(1));
        }
        expect(
          (await db
                  .customSelect('SELECT count(*) AS n FROM $table')
                  .getSingle())
              .read<int>('n'),
          0,
        );
      }
    },
  );
  test(
    'registration preserves disable preference and data stay scoped by plugin',
    () async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      expect(
        (await db
                .customSelect(
                  "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'plugin_%' ORDER BY name",
                )
                .get())
            .map((row) => row.read<String>('name')),
        [
          'plugin_permissions',
          'plugin_registry',
          'plugin_secrets',
          'plugin_storage',
          'plugin_tasks',
        ],
      );
      final dao = db.pluginDao;
      for (final id in ['a.test', 'b.test']) {
        await dao.register(
          pluginId: id,
          version: '1.0.0',
          source: 'bundled',
          packagePath: 'assets/$id',
          initiallyEnabled: true,
        );
      }
      await dao.setEnabled('a.test', false);
      await dao.register(
        pluginId: 'a.test',
        version: '2.0.0',
        source: 'bundled',
        packagePath: 'assets/new',
        initiallyEnabled: true,
      );
      expect((await dao.getPlugin('a.test'))!.enabled, false);
      expect((await dao.getPlugin('b.test'))!.enabled, true);
      await dao.setStorage('a.test', 'data.x', '{"n":1}');
      await dao.setSecret('a.test', 'key', 'secret');
      expect(await dao.getStorage('b.test', 'data.x'), null);
      expect(await dao.getSecret('b.test', 'key'), null);
    },
  );
}

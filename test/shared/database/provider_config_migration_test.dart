// 职责: 验证已发布的供应商表升级后保留温度，并以空 config 表示默认不发送温度。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/database/app_database_migrations.dart
//   lib/shared/models/ai_provider_config.dart

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/ai_provider_config.dart';

void main() {
  for (final version in [1, 2, 3, 4, 5, 6, 7]) {
    test(
      'schema $version providers gain config and keep temperature unsent',
      () async {
        final database = AppDatabase.forTest(
          NativeDatabase.memory(
            setup: (sqlite) {
              final fixture = File(
                'test/shared/database/fixtures/app_v0_${version <= 2 ? '4_0' : '7_1'}.sql',
              ).readAsStringSync();
              sqlite.execute(fixture);
              if (version == 2) {
                final v3 = File(
                  'test/shared/database/fixtures/app_v0_7_1.sql',
                ).readAsLinesSync();
                for (final table in [
                  'plugin_registry',
                  'plugin_storage',
                  'plugin_secrets',
                ]) {
                  var sql = v3.singleWhere(
                    (line) => line.startsWith('CREATE TABLE "$table"'),
                  );
                  if (table == 'plugin_storage') {
                    sql = sql.replaceFirst(
                      ', "deleted_at" INTEGER NOT NULL DEFAULT 0',
                      '',
                    );
                  }
                  sqlite.execute(sql);
                }
              }
              if (version >= 4) {
                sqlite.execute(
                  'ALTER TABLE novel_collections ADD COLUMN content_kind TEXT',
                );
              }
              if (version >= 5) {
                sqlite.execute(
                  "ALTER TABLE provider_assets ADD COLUMN kind TEXT NOT NULL DEFAULT 'certification'",
                );
                sqlite.execute(
                  'ALTER TABLE provider_assets ADD COLUMN context_hash TEXT',
                );
                sqlite.execute(
                  'ALTER TABLE provider_assets ADD COLUMN remote_url TEXT',
                );
                sqlite.execute(
                  'ALTER TABLE provider_assets ADD COLUMN expires_at INTEGER',
                );
              }
              if (version >= 6) {
                sqlite.execute(
                  'ALTER TABLE generation_tasks ADD COLUMN image_outputs TEXT',
                );
              }
              if (version >= 7) {
                sqlite.execute(
                  'ALTER TABLE generation_tasks ADD COLUMN provider_state TEXT',
                );
              }
              sqlite.execute('PRAGMA user_version=$version');
              sqlite.execute(
                "INSERT INTO ai_providers (id, name, type, temperature, updated_at, deleted_at) "
                "VALUES ('openai', 'OpenAI', 'openai', 0.4, 10, 0), "
                "('deleted', 'Deleted', 'openai', 0.9, 15, 20)",
              );
            },
          ),
        );
        addTearDown(database.close);

        expect(
          (await database.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          AppDatabase.currentSchemaVersion,
        );
        final columns = await database
            .customSelect('PRAGMA table_info(ai_providers)')
            .get();
        expect(
          columns
              .singleWhere((row) => row.read<String>('name') == 'id')
              .read<int>('pk'),
          1,
        );
        final column = columns.singleWhere(
          (row) => row.read<String>('name') == 'config',
        );
        expect(column.read<String>('type'), 'TEXT');
        expect(column.read<int>('notnull'), 0);
        expect(
          (await database.customSelect('PRAGMA index_list(ai_providers)').get())
              .map((row) => row.read<String>('name')),
          contains('sqlite_autoindex_ai_providers_1'),
        );
        expect(
          (await database
                  .customSelect('SELECT count(*) AS n FROM ai_providers')
                  .getSingle())
              .read<int>('n'),
          2,
        );
        expect(await database.aiProviderDao.getById('deleted'), isNull);

        final stored = (await database.aiProviderDao.getById('openai'))!;
        expect(stored.name, 'OpenAI');
        expect(stored.temperature, 0.4);
        expect(stored.config, isNull);
        expect(stored.providerConfig.enableTemperature, isFalse);
        expect(stored.updatedAt.millisecondsSinceEpoch, 10000);

        await database.aiProviderDao.upsert(
          stored.copyWith(
            config: const Value(AiProviderConfig(enableTemperature: true)),
          ),
        );
        final enabled = (await database.aiProviderDao.getById('openai'))!;
        expect(enabled.providerConfig.enableTemperature, isTrue);
        expect(enabled.temperature, 0.4);
      },
    );
  }

  test(
    'missing and unknown config values default to not sending temperature',
    () {
      expect(const AiProviderConfig().enableTemperature, isFalse);
      expect(AiProviderConfig.fromJson(null).enableTemperature, isFalse);
      final config = AiProviderConfig.fromJson({
        'futureOption': 'kept',
        'enableTemperature': 'yes',
      });
      expect(config.enableTemperature, isFalse);
      expect(config.toJson(), {'enableTemperature': false});
    },
  );
}

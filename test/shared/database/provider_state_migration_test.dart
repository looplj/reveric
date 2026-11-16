// 职责: 验证历史任务直接升级后保留身份、旧查询地址和结果，并可持久化供应商状态及下载头。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/database/app_database_migrations.dart
//   lib/shared/database/type_converters.dart
import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/type_converters.dart';

void main() {
  for (final version in [1, 2, 3, 4, 5, 6]) {
    test(
      'schema $version upgrades with nullable task state and no download headers',
      () async {
        final database = AppDatabase.forTest(
          NativeDatabase.memory(
            setup: (sqlite) {
              final fixture = File(
                'test/shared/database/fixtures/app_v0_${version <= 2 ? '4_0' : '7_1'}.sql',
              ).readAsStringSync();
              sqlite.execute(fixture);
              if (version == 2) {
                // v2 introduced these three tables; plugin_storage.deleted_at arrived in v3.
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
              sqlite.execute('PRAGMA user_version=$version');
              for (final id in ['legacy', 'deleted']) {
                sqlite.execute(
                  '''INSERT INTO generation_tasks
            (id,kind,novel_id,source_type,source_id,provider_id,provider_type,model_id,provider_task_id,polling_url,output_url,status,request_json,result_asset_id,path,output_hash,created_at,updated_at,deleted_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
                  [
                    id,
                    'video',
                    'novel',
                    'production_clip',
                    id,
                    'provider',
                    'atlascloud',
                    'model',
                    'remote-id',
                    'https://legacy.example/query',
                    'https://legacy.example/result',
                    'saving',
                    jsonEncode({
                      'version': 1,
                      'kind': 'video',
                      'request': {
                        'version': 1,
                        'model_id': 'model',
                        'prompt': 'unchanged',
                        'mode': 'text',
                        'resolution': '720p',
                        'ratio': '16:9',
                        'duration_seconds': 5,
                      },
                      'inputs': [],
                    }),
                    'asset',
                    'media/result.mp4',
                    'hash',
                    10,
                    20,
                    id == 'deleted' ? 30 : 0,
                  ],
                );
              }
            },
          ),
        );
        addTearDown(database.close);
        final task = (await database.generationTaskDao.getById('legacy'))!;
        expect(task.providerTaskId, 'remote-id');
        expect(task.pollingUrl, 'https://legacy.example/query');
        expect(task.outputUrl, 'https://legacy.example/result');
        expect(task.resultAssetId, 'asset');
        expect(task.path, 'media/result.mp4');
        expect(task.outputHash, 'hash');
        expect(task.videoRequest.prompt, 'unchanged');
        expect(task.createdAt.millisecondsSinceEpoch, 10000);
        expect(task.updatedAt.millisecondsSinceEpoch, 20000);
        expect(task.providerState, isNull);
        expect(await database.generationTaskDao.getById('deleted'), isNull);
        expect(
          (await database
                  .customSelect('SELECT count(*) AS n FROM generation_tasks')
                  .getSingle())
              .read<int>('n'),
          2,
        );
        expect(
          (await database.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          AppDatabase.currentSchemaVersion,
        );
        final columns = await database
            .customSelect('PRAGMA table_info(generation_tasks)')
            .get();
        expect(
          columns
              .singleWhere((row) => row.read<String>('name') == 'id')
              .read<int>('pk'),
          1,
        );
        final state = columns.singleWhere(
          (row) => row.read<String>('name') == 'provider_state',
        );
        expect(state.read<String>('type'), 'TEXT');
        expect(state.read<int>('notnull'), 0);
        // Authenticated download headers are memory-only and never persisted.
        expect(
          columns.map((row) => row.read<String>('name')),
          isNot(contains('output_headers')),
        );
        expect(
          (await database
                  .customSelect('PRAGMA index_list(generation_tasks)')
                  .get())
              .map((row) => row.read<String>('name')),
          containsAll([
            'generation_tasks_by_draft_task_id_deleted_at',
            'generation_tasks_by_kind_status_next_poll_at',
            'generation_tasks_by_novel_id_source_type_source_id_deleted_at',
          ]),
        );
        await (database.update(
          database.generationTasks,
        )..where((row) => row.id.equals('legacy'))).write(
          const GenerationTasksCompanion(
            providerState: Value({
              'queryUrl': 'https://legacy.example/query',
              'outputNode': 42,
            }),
          ),
        );
        final restored = (await database.generationTaskDao.getById('legacy'))!;
        expect(restored.providerState, {
          'queryUrl': 'https://legacy.example/query',
          'outputNode': 42,
        });
        expect(restored.providerTaskId, 'remote-id');
      },
    );
  }
  test(
    'provider state rejects corruption, non-JSON objects and oversize values',
    () {
      const converter = ProviderStateConverter();
      final cycle = <String, dynamic>{};
      cycle['self'] = cycle;
      expect(() => converter.toSql(cycle), throwsFormatException);
      expect(() => converter.fromSql('[]'), throwsFormatException);
      expect(() => converter.fromSql('broken'), throwsFormatException);
      expect(
        () => converter.toSql({'value': double.nan}),
        throwsFormatException,
      );
      expect(
        () => converter.toSql({'value': DateTime(2026)}),
        throwsFormatException,
      );
      expect(
        () => converter.toSql({'value': 'x' * (64 * 1024)}),
        throwsFormatException,
      );
      expect(
        converter.fromSql(
          converter.toSql({
            'list': [true, null, 1, 'value'],
          }),
        ),
        {
          'list': [true, null, 1, 'value'],
        },
      );
    },
  );
  test('image download headers are never persisted with candidates', () {
    final restored = ImageTaskOutputs.fromJson({
      'version': 1,
      'items': [
        {
          'url': 'https://image.example/one',
          'headers': {'Authorization': 'Bearer one'},
        },
      ],
    });
    expect(restored.items.single.url, 'https://image.example/one');
    expect(restored.toJson().toString(), isNot(contains('Bearer')));
  });
}

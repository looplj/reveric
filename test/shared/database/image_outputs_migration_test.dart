// 职责: 验证已发布任务升级后保留单图结果，并通过类型化 DAO 读写多图候选。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/database/app_database_migrations.dart
import 'dart:io';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';

void main() {
  for (final version in [1, 3, 4, 5]) {
    test(
      'schema $version preserves single-image task and adds nullable outputs',
      () async {
        final db = AppDatabase.forTest(
          NativeDatabase.memory(
            setup: (sqlite) {
              sqlite.execute(
                File(
                  'test/shared/database/fixtures/app_v0_${version == 1 ? '4_0' : '7_1'}.sql',
                ).readAsStringSync(),
              );
              if (version >= 4) {
                sqlite.execute(
                  'ALTER TABLE novel_collections ADD COLUMN content_kind TEXT;',
                );
              }
              if (version >= 5) {
                // Columns introduced by the v0.8.3 schema, all other tables match the v3 fixture.
                sqlite.execute(
                  "ALTER TABLE provider_assets ADD COLUMN kind TEXT NOT NULL DEFAULT 'certification';",
                );
                sqlite.execute(
                  'ALTER TABLE provider_assets ADD COLUMN context_hash TEXT;',
                );
                sqlite.execute(
                  'ALTER TABLE provider_assets ADD COLUMN remote_url TEXT;',
                );
                sqlite.execute(
                  'ALTER TABLE provider_assets ADD COLUMN expires_at INTEGER;',
                );
              }
              sqlite.execute('PRAGMA user_version=$version;');
              sqlite.execute('''INSERT INTO generation_tasks
          (id,kind,novel_id,source_type,source_id,provider_id,provider_type,model_id,status,request_json,result_asset_id,path,output_hash,created_at,updated_at,deleted_at)
          VALUES ('old','image','novel','production_clip','clip','provider','openai','gpt-image-2','completed',
          '{"version":1,"kind":"image","request":{"version":1,"provider_id":"provider","model_id":"gpt-image-2","original_prompt":"city","prompt":"city","ratio":"1:1","resolution":"1K","size":"1024x1024","references":[]}}',
          'asset','media/old.png','hash',10,20,0)''');
            },
          ),
        );
        addTearDown(db.close);
        final row = (await db.generationTaskDao.getById('old'))!;
        expect(row.resultAssetId, 'asset');
        expect(row.path, 'media/old.png');
        expect(row.outputHash, 'hash');
        expect(row.imageOutputs, isNull);
        expect(row.resultAssetIds, ['asset']);
        expect(
          (await db.customSelect('PRAGMA user_version').getSingle())
              .data
              .values
              .single,
          6,
        );
        final column =
            (await db.customSelect('PRAGMA table_info(generation_tasks)').get())
                .singleWhere((r) => r.data['name'] == 'image_outputs');
        expect(column.data['type'], 'TEXT');
        expect(column.data['notnull'], 0);
        await (db.update(
          db.generationTasks,
        )..where((t) => t.id.equals('old'))).write(
          GenerationTasksCompanion(
            imageOutputs: Value(
              ImageTaskOutputs([
                const ImageTaskOutput(assetId: 'a'),
                const ImageTaskOutput(assetId: 'b'),
              ]),
            ),
          ),
        );
        expect((await db.generationTaskDao.getById('old'))!.resultAssetIds, [
          'a',
          'b',
        ]);
        expect((await db.select(db.generationTasks).get()), hasLength(1));
      },
    );
  }
}

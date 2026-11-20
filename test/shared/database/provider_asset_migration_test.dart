// 职责: 验证旧素材认证记录升级后保留，上传用途和认证查询互不覆盖。
// 关联文件:
//   lib/shared/database/app_database_migrations.dart
//   lib/shared/database/daos/provider_asset_dao.dart
import 'dart:io';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/provider_asset.dart';

void main() {
  for (final version in [1, 3, 4]) {
    test('schema $version preserves certifications and separates uploads', () async {
      final db = AppDatabase.forTest(
        NativeDatabase.memory(
          setup: (sqlite) {
            sqlite.execute(
              File(
                'test/shared/database/fixtures/app_v0_${version == 1 ? '4_0' : '7_1'}.sql',
              ).readAsStringSync(),
            );
            if (version == 4) {
              // v0.8.2 differs from the v3 fixture by this nullable collection column.
              sqlite.execute(
                'ALTER TABLE novel_collections ADD COLUMN content_kind TEXT; PRAGMA user_version=4;',
              );
            }
            sqlite.execute(
              "INSERT INTO provider_assets (id,asset_id,provider_id,remote_id,status,created_at,updated_at,deleted_at) VALUES ('old','a','p','remote','active',10,20,0),('deleted','a','p','deleted-remote','failed',11,21,30)",
            );
          },
        ),
      );
      addTearDown(db.close);
      final row = (await db.providerAssetDao.find('a', 'p'))!;
      expect(row.id, 'old');
      expect(row.remoteId, 'remote');
      expect(row.kind, ProviderAssetKind.certification);
      expect(row.createdAt.millisecondsSinceEpoch, 10000);
      expect(row.contextHash, isNull);
      expect(
        (await db.customSelect('PRAGMA user_version').getSingle())
            .data
            .values
            .single,
        AppDatabase.currentSchemaVersion,
      );
      final cols = await db
          .customSelect('PRAGMA table_info(provider_assets)')
          .get();
      expect(
        cols.singleWhere((c) => c.data['name'] == 'expires_at').data['type'],
        'INTEGER',
      );
      expect(
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM provider_assets')
                .getSingle())
            .data['n'],
        2,
      );
      final indexes = await db
          .customSelect('PRAGMA index_list(provider_assets)')
          .get();
      expect(
        indexes.map((i) => i.data['name']),
        containsAll([
          'provider_assets_by_asset_id_provider_id',
          'provider_assets_by_status',
        ]),
      );
      final upload = await db.providerAssetDao.start(
        'a',
        'p',
        kind: ProviderAssetKind.upload,
        contextHash: 'hash',
      );
      await db.providerAssetDao.write(
        upload.id,
        const ProviderAssetsCompanion(
          status: Value(ProviderAssetStatus.active),
          remoteUrl: Value('https://example.com/image'),
        ),
      );
      expect((await db.providerAssetDao.find('a', 'p'))!.remoteId, 'remote');
      expect(
        await db.providerAssetDao.watchByAssets(['a']).first,
        hasLength(1),
      );
      final retry = await db.providerAssetDao.start(
        'a',
        'p',
        kind: ProviderAssetKind.upload,
        contextHash: 'new',
      );
      expect(retry.id, upload.id);
      expect(retry.remoteUrl, isNull);
      expect(retry.contextHash, 'new');
    });
  }
}

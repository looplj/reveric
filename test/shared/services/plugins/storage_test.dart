// 职责: 验证插件 KV 的身份隔离、软删除、恢复和原子配额限制。
// 关联文件:
//   lib/shared/services/plugins/host.dart
//   lib/shared/database/daos/plugin_dao.dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/daos/plugin_dao.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTest(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('data is isolated and removal retains the original row', () async {
    final dao = db.pluginDao;
    await dao.setPluginData('test.one', 'value', '{"value":"one"}');
    await dao.setPluginData('test.two', 'value', '{"value":"two"}');
    await dao.removePluginData('test.one', 'value');
    expect(await dao.getStorage('test.one', 'data.value'), null);
    expect(await dao.getStorage('test.two', 'data.value'), '{"value":"two"}');
    final row = await db
        .customSelect(
          "SELECT value, deleted_at FROM plugin_storage WHERE plugin_id = 'test.one'",
        )
        .getSingle();
    expect(row.read<String>('value'), '{"value":"one"}');
    expect(row.read<int>('deleted_at'), greaterThan(0));
    await dao.setPluginData('test.one', 'value', '7');
    expect(await dao.getStorage('test.one', 'data.value'), '7');
  });

  test('oversized values cannot replace stored data', () async {
    await db.pluginDao.setPluginData('test.one', 'value', '1');
    await expectLater(
      db.pluginDao.setPluginData(
        'test.one',
        'value',
        '中' * (256 * 1024 ~/ 3 + 1),
      ),
      throwsA(isA<PluginStorageQuotaException>()),
    );
    expect(await db.pluginDao.getStorage('test.one', 'data.value'), '1');
  });

  test('aggregate quota excludes settings and removed values', () async {
    final value = 'x' * (256 * 1024);
    for (var i = 0; i < 64; i++) {
      await db.pluginDao.setPluginData('test.one', 'k$i', value);
    }
    await db.pluginDao.setStorage('test.one', 'settings.key', 'setting');
    await expectLater(
      db.pluginDao.setPluginData('test.one', 'extra', '1'),
      throwsA(isA<PluginStorageQuotaException>()),
    );
    await db.pluginDao.removePluginData('test.one', 'k0');
    await db.pluginDao.setPluginData('test.one', 'extra', value);
    expect(await db.pluginDao.getStorage('test.one', 'data.extra'), value);
    expect(
      await db.pluginDao.getStorage('test.one', 'settings.key'),
      'setting',
    );
  });

  test(
    'permission grants and revocations remain scoped and reversible',
    () async {
      await db.pluginDao.grantPermissions('test.one', [
        'chapters.read',
        'chapters.write',
      ]);
      expect(await db.pluginDao.grantedPermissions('test.two'), isEmpty);
      await db.pluginDao.revokePermission('test.one', 'chapters.write');
      expect(await db.pluginDao.grantedPermissions('test.one'), {
        'chapters.read',
      });
      await db.pluginDao.grantPermissions('test.one', ['chapters.write']);
      expect(await db.pluginDao.grantedPermissions('test.one'), {
        'chapters.read',
        'chapters.write',
      });
    },
  );
}

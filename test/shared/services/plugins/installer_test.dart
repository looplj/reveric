// 职责: 验证本地插件安装、更新、授权确认与软卸载后重装的数据保留。
// 关联文件:
//   lib/shared/services/plugins/installer.dart
//   lib/shared/services/plugins/host.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/installer.dart';
import 'package:reveric/shared/services/plugins/package_archive.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'host_test.dart' show FakeExecutor;

PluginPackageArchive archive(
  String version, {
  List<String> permissions = const [],
}) => PluginPackageArchive.decode(
  Uint8List.fromList(
    ZipEncoder().encode(
      Archive()
        ..addFile(
          ArchiveFile.string(
            'plugin.json',
            jsonEncode({
              'id': 'example.local',
              'name': 'Local',
              'version': version,
              'pluginApiVersion': '^1',
              'main': 'dist/index.js',
              'permissions': permissions,
            }),
          ),
        )
        ..addFile(ArchiveFile.string('dist/index.js', 'code-$version')),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  late Directory temporary;
  late AppDatabase db;
  late PluginHostService host;
  setUp(() async {
    support = await Directory.systemTemp.createTemp('plugin-install-test-');
    temporary = await Directory('${support.path}/tmp').create();
    db = AppDatabase.forTest(NativeDatabase.memory());
    host = PluginHostService(
      dao: db.pluginDao,
      registry: PluginRegistry(hostToolNames: {}),
      applicationSupport: () async => support,
      packages: () async => [],
      executorFactory: (_, _) => FakeExecutor(),
      platform: 'macos',
    );
  });
  tearDown(() async {
    await host.dispose();
    await db.close();
    await support.delete(recursive: true);
  });
  Future<void> install(
    String version, {
    List<String> permissions = const [],
    Set<String> granted = const {},
  }) => PluginInstallOrchestrator().install(
    host: host,
    archive: archive(version, permissions: permissions),
    grantedPermissions: granted,
    temporaryRoot: temporary,
  );

  test(
    'new install remains disabled, update retains config and enabled choice',
    () async {
      await install('1.0.0');
      expect(host.statuses.single.enabled, false);
      await host.setEnabled('example.local', true);
      await db.pluginDao.setPluginData('example.local', 'value', '1');
      await install('2.0.0');
      expect(host.statuses.single.manifest!.version, '2.0.0');
      expect(host.statuses.single.enabled, true);
      expect(await db.pluginDao.getStorage('example.local', 'data.value'), '1');
      expect(
        await Directory('${support.path}/plugins/example.local/1.0.0').exists(),
        false,
      );
      expect(await temporary.list().toList(), isEmpty);
    },
  );

  test(
    'missing consent and downgrade leave registration and files untouched',
    () async {
      await expectLater(
        install('1.0.0', permissions: ['chapters.read']),
        throwsStateError,
      );
      expect(await db.pluginDao.getPlugin('example.local'), null);
      await install(
        '2.0.0',
        permissions: ['chapters.read'],
        granted: {'chapters.read'},
      );
      await expectLater(install('1.0.0'), throwsStateError);
      expect((await db.pluginDao.getPlugin('example.local'))!.version, '2.0.0');
      expect(await db.pluginDao.grantedPermissions('example.local'), {
        'chapters.read',
      });
    },
  );

  test(
    'soft uninstall and exact reinstall retain package and plugin data',
    () async {
      await install('1.0.0');
      await db.pluginDao.setPluginData('example.local', 'value', '7');
      await host.uninstall('example.local');
      expect(host.statuses, isEmpty);
      expect(await db.pluginDao.getPlugin('example.local'), null);
      expect(
        await Directory('${support.path}/plugins/example.local/1.0.0').exists(),
        true,
      );
      await install('1.0.0');
      expect(host.statuses.single.manifest!.version, '1.0.0');
      expect(await db.pluginDao.getStorage('example.local', 'data.value'), '7');
    },
  );

  test(
    'restart discovers installed package from relative registry path',
    () async {
      await install('1.0.0');
      await host.setEnabled('example.local', true);
      final restarted = PluginHostService(
        dao: db.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        applicationSupport: () async => support,
        executorFactory: (_, _) => FakeExecutor(),
        platform: 'macos',
      );
      try {
        await restarted.start();
        final local = restarted.statuses.singleWhere(
          (status) => status.id == 'example.local',
        );
        expect(local.enabled, true);
        expect(local.state, 'available');
        expect(local.path, 'plugins/example.local/1.0.0');
      } finally {
        await restarted.dispose();
      }
    },
  );

  test(
    'revocation removes active tools without overwriting enable preference',
    () async {
      await install(
        '1.0.0',
        permissions: ['chapters.read'],
        granted: {'chapters.read'},
      );
      await host.setEnabled('example.local', true);
      expect(host.statuses.single.state, 'available');
      await host.revokePermissions('example.local');
      expect(host.statuses.single.state, 'needs_permission');
      expect(host.statuses.single.enabled, true);
      expect(host.registry.toolsFor('example.local'), isEmpty);
      await host.confirmPermissions('example.local');
      expect(host.statuses.single.state, 'available');
    },
  );

  test(
    'concurrent duplicate installs serialize and only one commits',
    () async {
      final results = await Future.wait([
        for (var i = 0; i < 2; i++)
          install('1.0.0').then((_) => true, onError: (Object _) => false),
      ]);
      expect(results.where((result) => result), hasLength(1));
      expect((await db.pluginDao.localPlugins()), hasLength(1));
      expect(await temporary.list().toList(), isEmpty);
    },
  );
}

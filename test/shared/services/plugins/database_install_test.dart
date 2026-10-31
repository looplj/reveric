// 职责: 验证插件库更新先迁移副本并校验代码，主库失败和崩溃窗口恢复原版本。
// 关联文件:
//   lib/shared/services/plugins/database_install.dart
//   lib/shared/services/plugins/installer.dart
//   lib/shared/services/plugins/host.dart
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/services/plugins/database_install.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/installer.dart';
import 'package:reveric/shared/services/plugins/package_archive.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/services/plugins/sqlite.dart';

const schema =
    'CREATE TABLE notes(id INTEGER PRIMARY KEY, text TEXT NOT NULL);';
const upgrade = "ALTER TABLE notes ADD COLUMN extra TEXT DEFAULT 'ready';";
PluginPackageArchive package(
  int version, {
  String migration = upgrade,
  bool brokenApply = false,
}) {
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        'plugin.json',
        jsonEncode({
          'id': 'test.install',
          'name': 'Install',
          'version': '$version.0.0',
          'pluginApiVersion': '^1',
          'tasks': {
            'organize': {'title': 'Organize', 'intervalMinutes': 60},
            'paused': {'title': 'Paused', 'intervalMinutes': 60},
          },
          'main': 'dist/index.js',
          'database': {
            'version': version,
            'migrations': [
              {'version': 1, 'source': '001.sql'},
              if (version == 2) {'version': 2, 'source': '002.sql'},
            ],
          },
        }),
      ),
    )
    ..addFile(ArchiveFile.string('001.sql', schema))
    ..addFile(
      ArchiveFile.string(
        'dist/index.js',
        brokenApply
            ? "var __revericPlugin={apply(){throw new Error('broken apply')}};"
            : """
var __revericPlugin={apply(setup){setup.tasks.register('organize',async context=>{await context.storage.set('runs',((await context.storage.get('runs'))||0)+1);return {summary:'done'};});setup.tasks.register('paused',async()=>({summary:'paused task'}));setup.tools.register({name:'Hold',description:'Wait',inputSchema:{type:'object'},handler:async(input,context)=>{await context.http.fetch(input.url);return {ok:true};}});setup.tools.register({name:'ReadNotes',description:'Read notes',inputSchema:{type:'object'},handler:async(input,context)=>({rows:await context.sqlite.query({sql:'SELECT * FROM notes'})})});}};
""",
      ),
    );
  if (version == 2) {
    archive.addFile(ArchiveFile.string('002.sql', migration));
  }
  return PluginPackageArchive.decode(
    Uint8List.fromList(ZipEncoder().encode(archive)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final path = Platform.environment['FJS_PROBE_LIBRARY'];
    if (path == null) {
      throw StateError('Set FJS_PROBE_LIBRARY');
    }
    await LibFjs.init(externalLibrary: ExternalLibrary.open(path));
  });
  late Directory root, temp;
  late AppDatabase database;
  late PluginHostService host;
  late PluginSqliteService databases;
  Future<void> install(PluginPackageArchive archive) =>
      PluginInstallOrchestrator().install(
        host: host,
        archive: archive,
        grantedPermissions: {},
        temporaryRoot: temp,
      );
  Future<Object?> rows() => databases.call('test.install', 'query', {
    'statement': {'sql': 'SELECT text FROM notes'},
  });
  setUp(() async {
    root = await Directory.systemTemp.createTemp('plugin-db-install-');
    temp = await Directory('${root.path}/temp').create();
    database = AppDatabase.forTest(NativeDatabase.memory());
    host = PluginHostService(
      dao: database.pluginDao,
      registry: PluginRegistry(hostToolNames: {}),
      applicationSupport: () async => root,
      packages: () async => [],
    );
    await install(package(1));
    await host.setEnabled('test.install', true);
    databases = await host.privateDatabases();
    await databases.call('test.install', 'execute', {
      'statement': {'sql': "INSERT INTO notes(text) VALUES ('original')"},
    });
  });
  tearDown(() async {
    await host.dispose();
    await database.close();
    await root.delete(recursive: true);
  });
  test(
    'failed updates restore old tasks without changing paused schedules',
    () async {
      Future<void> settled() async {
        final end = DateTime.now().add(const Duration(seconds: 5));
        while (host.tasks.pending('test.install', 'organize')) {
          if (DateTime.now().isAfter(end)) {
            throw TimeoutException('Task did not finish');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      Future<void> usable() async {
        expect(host.tasks.definition('test.install', 'organize'), isNotNull);
        final row = (await database.pluginTaskDao.get(
          'test.install',
          'organize',
        ))!;
        await database.pluginTaskDao.defer(
          row,
          DateTime.now().subtract(const Duration(seconds: 1)),
          DateTime.now(),
        );
        await host.tasks.tick();
        await settled();
        expect(
          (await database.pluginTaskDao.get(
            'test.install',
            'organize',
          ))!.lastStatus,
          'success',
        );
        await host.tasks.runNow('test.install', 'organize');
        await settled();
      }

      await host.tasks.setEnabled('test.install', 'paused', false);
      final paused = (await database.pluginTaskDao.get(
        'test.install',
        'paused',
      ))!;
      for (final candidate in [
        package(2, migration: '$upgrade UPDATE missing SET x=1;'),
        package(2, brokenApply: true),
      ]) {
        await expectLater(install(candidate), throwsA(anything));
        final after = (await database.pluginTaskDao.get(
          'test.install',
          'paused',
        ))!;
        expect(after.enabled, false);
        expect(after.nextDueAt, paused.nextDueAt);
        expect(after.runId, paused.runId);
        expect(after.attempt, paused.attempt);
        await usable();
      }
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousHttp);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final arrived = Completer<HttpRequest>();
      server.listen(arrived.complete);
      final holding = host.execute('Hold', {
        'url': 'http://127.0.0.1:${server.port}/hold',
      });
      final request = await arrived.future.timeout(const Duration(seconds: 3));
      try {
        await expectLater(install(package(2)), throwsA(anything));
        expect(host.statuses.single.manifest!.version, '1.0.0');
        await usable();
        request.response.write('done');
        await request.response.close();
        await holding;
      } finally {
        await server.close(force: true);
      }
      expect(
        jsonDecode(
          (await database.pluginDao.getStorage('test.install', 'data.runs'))!,
        ),
        6,
      );
      final after = (await database.pluginTaskDao.get(
        'test.install',
        'paused',
      ))!;
      expect(after.enabled, false);
      expect(after.nextDueAt, paused.nextDueAt);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
  test(
    'migration and apply failures preserve DB/registration/package then success switches all',
    () async {
      await expectLater(
        install(package(2, migration: '$upgrade UPDATE missing SET x=1;')),
        throwsA(anything),
      );
      expect(await rows(), [
        {'text': 'original'},
      ]);
      expect(
        (await database.pluginDao.getPlugin('test.install'))!.version,
        '1.0.0',
      );
      expect(
        Directory('${root.path}/plugins/test.install/1.0.0').existsSync(),
        true,
      );
      expect(
        Directory('${root.path}/plugins/test.install/2.0.0').existsSync(),
        false,
      );
      await expectLater(
        install(package(2, brokenApply: true)),
        throwsA(anything),
      );
      expect(await rows(), [
        {'text': 'original'},
      ]);
      await install(package(2));
      expect(
        (await database.pluginDao.getPlugin('test.install'))!.version,
        '2.0.0',
      );
      expect(host.statuses.single.state, 'available');
      expect((await host.execute('ReadNotes', {}))['rows'], [
        {'id': 1, 'text': 'original', 'extra': 'ready'},
      ]);
      expect(
        Directory('${root.path}/plugins/test.install/1.0.0').existsSync(),
        false,
      );
      expect(
        jsonDecode(
          (await database.appStateDao.get('plugin_install.test.install'))!,
        )['phase'],
        'done',
      );
    },
  );
  test(
    'main registry transaction failure restores original after database file switch',
    () async {
      final end = await host.beginMaintenance('test.install');
      try {
        await expectLater(
          PluginDatabaseInstallOrchestrator().install(
            database: database,
            databases: databases,
            pluginId: 'test.install',
            version: '2.0.0',
            oldVersion: '1.0.0',
            migrations: [
              {'version': 1, 'sql': schema},
              {'version': 2, 'sql': upgrade},
            ],
            validate: () async {},
            commit: () async {
              await database.pluginDao.install(
                pluginId: 'test.install',
                version: '2.0.0',
                packagePath: 'plugins/test.install/2.0.0',
                permissions: [],
              );
              throw StateError('Injected main registry failure');
            },
          ),
          throwsStateError,
        );
      } finally {
        end();
      }
      expect(
        (await database.pluginDao.getPlugin('test.install'))!.version,
        '1.0.0',
      );
      expect(await rows(), [
        {'text': 'original'},
      ]);
      expect(
        jsonDecode(
          (await database.appStateDao.get('plugin_install.test.install'))!,
        )['phase'],
        'done',
      );
    },
  );
  test(
    'prepared crash after either rename restores old database and committed cleanup keeps new',
    () async {
      for (final window in [(false, false), (false, true), (true, true)]) {
        final committed = window.$1;
        final end = await host.beginMaintenance('test.install');
        try {
          final current = File(databases.pathFor('test.install'));
          final token = 'install-${const Uuid().v4()}';
          final folder = await Directory(
            '${current.parent.path}/$token',
          ).create();
          final staged = '${folder.path}/staged.sqlite';
          await databases.backup('test.install', staged);
          await PluginSqliteService.migrateStaged(staged, [
            {'version': 1, 'sql': schema},
            {'version': 2, 'sql': "UPDATE notes SET text='new';"},
          ]);
          await databases.close('test.install');
          await current.rename('${folder.path}/previous.sqlite');
          if (window.$2) {
            await File(staged).rename(current.path);
          }
          final record = {
            'phase': committed ? 'committed' : 'prepared',
            'pluginId': 'test.install',
            'oldVersion': '1.0.0',
            'newVersion': '2.0.0',
            'directory': token,
            'hadOriginal': true,
          };
          if (committed) {
            await database.pluginDao.install(
              pluginId: 'test.install',
              version: '2.0.0',
              packagePath: 'plugins/test.install/2.0.0',
              permissions: [],
            );
          }
          await database.appStateDao.set(
            key: 'plugin_install.test.install',
            value: jsonEncode(record),
          );
          expect(
            await PluginDatabaseInstallOrchestrator().recover(
              database: database,
              root: root,
            ),
            isEmpty,
          );
          expect(folder.existsSync(), false);
        } finally {
          end();
        }
        expect(await rows(), [
          {'text': committed ? 'new' : 'original'},
        ]);
      }
    },
  );
  test(
    'startup refuses a committed record with a missing DB instead of recreating it',
    () async {
      await install(package(2));
      await host.dispose();
      final path = databases.pathFor('test.install');
      await File(path).delete();
      final token = 'install-${const Uuid().v4()}';
      await Directory('${File(path).parent.path}/$token').create();
      await database.appStateDao.set(
        key: 'plugin_install.test.install',
        value: jsonEncode({
          'phase': 'committed',
          'pluginId': 'test.install',
          'oldVersion': '1.0.0',
          'newVersion': '2.0.0',
          'directory': token,
          'hadOriginal': true,
        }),
      );
      final archive = package(2);
      host = PluginHostService(
        dao: database.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        applicationSupport: () async => root,
        packages: () async => [
          PluginPackage(
            'plugins/test.install/2.0.0',
            archive.manifest,
            utf8.decode(archive.files[archive.manifest.main]!),
            source: 'local',
          ),
        ],
      );
      await host.start();
      expect(host.statuses.single.state, 'failed');
      expect(host.registry.resolve('ReadNotes'), null);
      expect(File(path).existsSync(), false);
    },
  );
}

// 职责: 测试备份服务 — 验证备份打包、恢复预检及完整/小说级覆盖行为。
// 关联文件:
//   lib/shared/services/backup_service.dart
//   lib/shared/utils/windows_safe_path.dart
//   lib/shared/services/director/storage.dart
//   test/helpers/backup_fixture.dart

import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/models/generation/task.dart';
import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart' show NativeDatabase;
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';
import '../../fixtures/director/animated.dart';
import '../../helpers/backup_fixture.dart';
import 'package:reveric/shared/models/director/document.dart';
import 'package:reveric/shared/models/director/sampling.dart';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/backup_service.dart';
import 'package:reveric/shared/models/mcp/config.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:reveric/shared/services/director/storage.dart';
import 'package:reveric/shared/database/type_converters.dart';
import 'package:reveric/shared/models/map_studio_models.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/database/app_database.dart' show AppDatabase;
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/utils/short_entity_id.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

late BackupDatabases _databases;

class _CancellingPluginHost extends PluginHostService {
  _CancellingPluginHost(AppDatabase database, Directory root)
    : super(
        dao: database.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        packages: () async => [],
        applicationSupport: () async => root,
      );
  @override
  Future<void> shutdownForRestore() async {
    throw PluginHostError('cancelled', 'Keep plugin draft');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _databases = await BackupDatabases.create();
  });

  late Directory tempRoot;
  late Directory appSupportDir;
  late Directory tempDir;
  late Directory outputDir;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('backup_service_test_');
    appSupportDir = Directory(p.join(tempRoot.path, 'support'));
    tempDir = Directory(p.join(tempRoot.path, 'tmp'));
    outputDir = Directory(p.join(tempRoot.path, 'output'));
    await appSupportDir.create(recursive: true);
    await tempDir.create(recursive: true);
    await outputDir.create(recursive: true);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            if (call.method == 'getApplicationSupportDirectory') {
              return appSupportDir.path;
            }
            if (call.method == 'getTemporaryDirectory') {
              return tempDir.path;
            }
            return null;
          },
        );
    await RevericPaths.initialize();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  File packSource(Directory source, {int version = 1}) {
    final archive = Archive()
      ..addFile(
        ArchiveFile.string(
          'manifest.json',
          jsonEncode({'version': version, 'createdAt': '2026-10-13T00:00:00Z'}),
        ),
      );
    for (final file in source.listSync(recursive: true).whereType<File>()) {
      archive.addFile(
        ArchiveFile.bytes(
          p.relative(file.path, from: source.path).replaceAll('\\', '/'),
          file.readAsBytesSync(),
        ),
      );
    }
    return File(p.join(outputDir.path, 'source.zip'))
      ..writeAsBytesSync(ZipEncoder().encode(archive));
  }

  test('full restore disables MCP without rewriting credentials', () async {
    final source = await Directory(p.join(tempRoot.path, 'source')).create();
    final original = McpSettings([
      McpServerConfig(
        name: 'notes',
        enabled: true,
        connection: McpHttpConfig(
          url: 'https://example.test/mcp',
          bearerToken: '${source.path}/opaque-token',
          headers: {'X-Key': '${source.path}/opaque-header'},
        ),
      ),
    ]);
    final sourceDb = _databases.writeMain(
      p.join(source.path, 'reveric.sqlite'),
    );
    insertBackupRow(sourceDb, 'app_settings', {
      'key': McpSettings.key,
      'value': original.encode(),
    });
    sourceDb.close();
    final current = _databases.writeMain(
      p.join(appSupportDir.path, 'reveric.sqlite'),
    );
    current.close();
    final result = await BackupService().restoreFromZip(
      packSource(source).path,
      mode: RestoreMode.fullReplacement,
    );
    expect(result.success, true, reason: '${result.failureReason}');
    final restoredDb = sqlite3.open(
      p.join(appSupportDir.path, 'reveric.sqlite'),
    );
    try {
      final value =
          restoredDb.select('SELECT value FROM app_settings WHERE key = ?', [
                McpSettings.key,
              ]).single['value']
              as String;
      final restored = McpSettings.decode(value).servers.single;
      expect(restored.enabled, false);
      expect(
        restored.connection.toJson(),
        original.servers.single.connection.toJson(),
      );
    } finally {
      restoredDb.close();
    }
  });

  test(
    'plugin database snapshot waits for package mutations and full restore retains exact data',
    () async {
      _writeLibrary(appSupportDir, {
        'work': (title: 'Work', marker: 'plugin snapshot'),
      });
      final appDatabase = AppDatabase.forTest(
        NativeDatabase(File(p.join(appSupportDir.path, 'reveric.sqlite'))),
      );
      final host = PluginHostService(
        dao: appDatabase.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        packages: () async => [],
        applicationSupport: () async => appSupportDir,
      );
      var databaseClosed = false;
      try {
        await host.start();
        final databases = await host.privateDatabases();
        await databases.migrate('example.search', [
          {
            'version': 1,
            'sql':
                'CREATE TABLE notes(id INTEGER PRIMARY KEY, text TEXT NOT NULL);',
          },
        ]);
        await databases.call('example.search', 'execute', {
          'statement': {'sql': "INSERT INTO notes(text) VALUES ('original')"},
        });
        final pluginFile = File(
          p.join(
            appSupportDir.path,
            'plugins/example.search/1.0.0/dist/index.js',
          ),
        );
        await pluginFile.parent.create(recursive: true);
        await pluginFile.writeAsString('original package');
        await appDatabase.pluginDao.install(
          pluginId: 'example.search',
          version: '1.0.0',
          packagePath: 'plugins/example.search/1.0.0',
          permissions: [],
        );
        final ignored = File(
          p.join(
            appSupportDir.path,
            'plugin_data/example.search/install-orphan/previous.sqlite',
          ),
        );
        await ignored.parent.create(recursive: true);
        await ignored.writeAsString('temporary copy');
        final entered = Completer<void>(), release = Completer<void>();
        final mutation = host.mutate('example.search', () async {
          entered.complete();
          await release.future;
          await databases.call('example.search', 'execute', {
            'statement': {
              'sql': "INSERT INTO notes(text) VALUES ('before snapshot')",
            },
          });
        });
        await entered.future;
        var finished = false;
        final service = BackupService(pluginHost: host);
        final backupFuture = service
            .backupToZip(outputDirectory: outputDir.path)
            .then((value) {
              finished = true;
              return value;
            });
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(finished, false);
        release.complete();
        await mutation;
        final backup = await backupFuture;
        expect(backup.success, true, reason: '${backup.failureReason}');
        final archive = ZipDecoder().decodeBytes(
          await File(backup.backupPath!).readAsBytes(),
        );
        final names = archive.files.map((f) => f.name).toList();
        expect(names, contains('plugin_data/example.search/data.sqlite'));
        expect(
          names.any(
            (name) =>
                name.contains('install-orphan') ||
                name.endsWith('-journal') ||
                name.endsWith('-wal'),
          ),
          false,
        );
        await databases.call('example.search', 'execute', {
          'statement': {
            'sql': "INSERT INTO notes(text) VALUES ('after snapshot')",
          },
        });
        await pluginFile.writeAsString('changed package');
        final restored = await service.restoreFromZip(
          backup.backupPath!,
          mode: RestoreMode.fullReplacement,
          onBeforeFileRestore: () async {
            await appDatabase.close();
            databaseClosed = true;
          },
        );
        expect(restored.success, true, reason: '${restored.failureReason}');
        final restoredDb = sqlite3.open(
          p.join(appSupportDir.path, 'plugin_data/example.search/data.sqlite'),
          mode: OpenMode.readOnly,
        );
        try {
          expect(
            restoredDb
                .select('SELECT text FROM notes ORDER BY id')
                .map((r) => r['text']),
            ['original', 'before snapshot'],
          );
        } finally {
          restoredDb.close();
        }
        expect(await pluginFile.readAsString(), 'original package');
        expect(ignored.existsSync(), false);
      } finally {
        await host.dispose();
        if (!databaseClosed) {
          await appDatabase.close();
        }
      }
    },
  );

  test(
    'plugin restore cancellation preserves files and avoids restart requirement',
    () async {
      final source = await Directory(
        p.join(tempRoot.path, 'source-plugin-cancel'),
      ).create();
      _writeLibrary(source, {'work': (title: 'Work', marker: 'backup')});
      final archive = packSource(source);
      _writeLibrary(appSupportDir, {
        'work': (title: 'Work', marker: 'current'),
      });
      final database = AppDatabase.forTest(
        NativeDatabase(File(p.join(appSupportDir.path, 'reveric.sqlite'))),
      );
      final host = _CancellingPluginHost(database, appSupportDir);
      var beforeFiles = false;
      try {
        final result = await BackupService(pluginHost: host).restoreFromZip(
          archive.path,
          mode: RestoreMode.fullReplacement,
          onBeforeFileRestore: () async {
            beforeFiles = true;
          },
        );
        expect(result.cancelled, true);
        expect(result.needsRestart, false);
        expect(beforeFiles, false);
        expect(_readContentMarker(appSupportDir, 'work'), 'current');
      } finally {
        await host.dispose();
        await database.close();
      }
    },
  );

  for (final parentName in [
    'Media.staging',
    'work.part',
    'archive.pending',
    '.reveric_copy_user',
    '.reveric_restore_rollback_user',
  ]) {
    test('backup filtering ignores parent directory $parentName', () async {
      final parent = await Directory(
        p.join(tempRoot.path, parentName),
      ).create();
      appSupportDir = await Directory(p.join(parent.path, 'support')).create();
      tempDir = await Directory(p.join(parent.path, 'tmp')).create();
      final external = await Directory(p.join(parent.path, 'media')).create();
      await RevericPaths.initialize(fileWorkspaceParent: external.path);
      _writeLibrary(appSupportDir, {'work': (title: 'Work', marker: 'backup')});
      const retained = [
        'file_workspaces/work/files/nested/中文.txt',
        'file_workspaces/shared/files/nested/shared.txt',
      ];
      const excluded = [
        'file_workspaces/work/files/incomplete.part',
        'file_workspaces/work/files/render.staging/frame.png',
        'file_workspaces/work/files/.reveric_copy_partial/content',
        'file_workspaces/shared/files/cache.pending/result.txt',
        'file_workspaces/shared/files/.reveric_restore_rollback_partial/original',
      ];
      for (final relative in [...retained, ...excluded]) {
        final file = File(p.join(external.path, relative));
        await file.parent.create(recursive: true);
        await file.writeAsString('backup:$relative');
      }
      final backup = await BackupService().backupToZip(
        outputDirectory: outputDir.path,
      );
      expect(backup.success, true);
      final archive = ZipDecoder().decodeBytes(
        await File(backup.backupPath!).readAsBytes(),
      );
      final names = archive.files.map((entry) => entry.name).toSet();
      expect(names, containsAll(['novel_workspaces/work.sqlite', ...retained]));
      for (final relative in retained) {
        expect(
          utf8.decode(archive.findFile(relative)!.content as List<int>),
          'backup:$relative',
        );
      }
      for (final relative in excluded) {
        expect(names, isNot(contains(relative)));
      }
      // Restore staging also lives below a user-named parent. Both restore
      // modes must read its files, including the recursive shared directory.
      for (final mode in RestoreMode.values) {
        for (final relative in retained) {
          await File(p.join(external.path, relative)).writeAsString('changed');
        }
        final restore = await BackupService().restoreFromZip(
          backup.backupPath!,
          mode: mode,
          novelIds: {'work'},
        );
        expect(restore.success, true, reason: '${restore.failureReason}');
        for (final relative in retained) {
          expect(
            await File(p.join(external.path, relative)).readAsString(),
            'backup:$relative',
          );
        }
      }
    });
  }

  for (final mode in RestoreMode.values) {
    test(
      'external workspace backup and $mode restore keep the directory together',
      () async {
        _writeLibrary(appSupportDir, {
          'work': (title: 'Work', marker: 'backup'),
        });
        final external = await Directory(
          p.join(tempRoot.path, 'external'),
        ).create();
        await RevericPaths.initialize(fileWorkspaceParent: external.path);
        const relative = 'file_workspaces/work/files/中文/readme.txt';
        final current = File(p.join(external.path, relative));
        await current.parent.create(recursive: true);
        await current.writeAsString('external backup');
        final original = File(p.join(appSupportDir.path, relative));
        await original.parent.create(recursive: true);
        await original.writeAsString('original retained');
        final config = File(p.join(appSupportDir.path, 'settings.local.json'));
        await config.writeAsString('machine-specific config');
        final backup = await BackupService().backupToZip(
          outputDirectory: outputDir.path,
        );
        expect(backup.success, true);
        final archive = ZipDecoder().decodeBytes(
          await File(backup.backupPath!).readAsBytes(),
        );
        expect(
          utf8.decode(archive.findFile(relative)!.content as List<int>),
          'external backup',
        );
        expect(archive.findFile('settings.local.json'), isNull);
        await current.writeAsString('changed');
        final restored = await BackupService().restoreFromZip(
          backup.backupPath!,
          mode: mode,
          novelIds: {'work'},
        );
        expect(restored.success, true, reason: '${restored.failureReason}');
        expect(await current.readAsString(), 'external backup');
        expect(await original.readAsString(), 'original retained');
        expect(await config.readAsString(), 'machine-specific config');
      },
    );
  }

  test(
    'external workspace restore failure rolls back files on the external disk',
    () async {
      _writeLibrary(appSupportDir, {'work': (title: 'Work', marker: 'backup')});
      final external = await Directory(
        p.join(tempRoot.path, 'external'),
      ).create();
      await RevericPaths.initialize(fileWorkspaceParent: external.path);
      final own = File(
        p.join(external.path, 'file_workspaces/work/files/own.txt'),
      );
      final blocked = Directory(
        p.join(external.path, 'file_workspaces/shared/files/blocked'),
      );
      await own.parent.create(recursive: true);
      await own.writeAsString('backup own');
      await blocked.create(recursive: true);
      await File(
        p.join(blocked.path, 'child.txt'),
      ).writeAsString('backup child');
      final backup = await BackupService().backupToZip(
        outputDirectory: outputDir.path,
      );
      expect(backup.success, true);
      await own.writeAsString('current own');
      final restored = await BackupService().restoreFromZip(
        backup.backupPath!,
        mode: RestoreMode.selectedNovels,
        novelIds: {'work'},
        onBeforeFileRestore: () async {
          await blocked.delete(recursive: true);
          await File(blocked.path).writeAsString('blocked');
        },
      );
      expect(restored.success, false);
      expect(await own.readAsString(), 'current own');
      expect(await File(blocked.path).readAsString(), 'blocked');
    },
  );

  test(
    'directory backup includes current media and excludes obsolete roots',
    () async {
      _writeLibrary(appSupportDir, {'work': (title: 'Work', marker: 'backup')});
      for (final path in [
        'file_workspaces/work/videos/unregistered.mp4',
        'file_workspaces/work/files/附件/subtitles.srt',
        'file_workspaces/shared/files/unused.txt',
        'file_workspaces/shared/images/retained.png',
        'file_workspaces/other/audio/other.wav',
        'file_workspaces/work/videos/incomplete.part',
        'file_workspaces/work/files/incomplete.pending',
        'file_workspaces/uncommitted.part',
        'file_workspaces/work/.reveric_copy_interrupted/content',
        'file_workspaces/work/.reveric_restore_rollback_interrupted/original',
        'file_workspaces/work/sessions/session/unregistered.mp4',
        'media/work/videos/unpublished.mp4',
        'videos/unpublished.mp4',
        'audio/unpublished.wav',
        'sessions/obsolete/unpublished.txt',
        'novel_covers/obsolete.png',
        'ai_generated_images/obsolete.png',
        'images/obsolete.png',
        'novel_workspaces/images/obsolete.png',
        'novel_workspaces/work/nested/obsolete.png',
        'avatars/avatar.png',
        'agent_avatars/agent.png',
        'ai_images/not-a-released-work-directory.png',
        'character_avatars/not-a-released-work-directory.png',
      ]) {
        final file = File(p.join(appSupportDir.path, path));
        await file.parent.create(recursive: true);
        await file.writeAsString('bytes:$path');
      }
      final backup = await BackupService().backupToZip(
        outputDirectory: outputDir.path,
      );
      expect(backup.success, true);
      final archive = ZipDecoder().decodeBytes(
        await File(backup.backupPath!).readAsBytes(),
      );
      final names = archive.files.map((e) => e.name).toSet();
      expect(
        names,
        containsAll([
          'file_workspaces/work/videos/unregistered.mp4',
          'file_workspaces/work/files/附件/subtitles.srt',
          'file_workspaces/shared/files/unused.txt',
          'file_workspaces/shared/images/retained.png',
          'file_workspaces/work/sessions/session/unregistered.mp4',
          'avatars/avatar.png',
          'agent_avatars/agent.png',
          'novel_workspaces/work.sqlite',
        ]),
      );
      for (final excluded in [
        'file_workspaces/work/videos/incomplete.part',
        'file_workspaces/work/files/incomplete.pending',
        'file_workspaces/uncommitted.part',
        'file_workspaces/work/.reveric_copy_interrupted/content',
        'file_workspaces/work/.reveric_restore_rollback_interrupted/original',
        'media/work/videos/unpublished.mp4',
        'videos/unpublished.mp4',
        'audio/unpublished.wav',
        'sessions/obsolete/unpublished.txt',
        'novel_covers/obsolete.png',
        'ai_generated_images/obsolete.png',
        'images/obsolete.png',
        'novel_workspaces/images/obsolete.png',
        'novel_workspaces/work/nested/obsolete.png',
        'ai_images/not-a-released-work-directory.png',
        'character_avatars/not-a-released-work-directory.png',
      ]) {
        expect(names, isNot(contains(excluded)));
      }
      final manifest =
          jsonDecode(
                utf8.decode(
                  archive.findFile('manifest.json')!.content as List<int>,
                ),
              )
              as Map;
      expect(manifest.containsKey('mediaLayout'), false);
      expect(manifest.containsKey('files'), false);
      appSupportDir = await Directory(
        p.join(tempRoot.path, 'directory-target'),
      ).create();
      _writeLibrary(appSupportDir, {
        'work': (title: 'Work', marker: 'current'),
      });
      for (final relative in [
        'avatars/avatar.png',
        'agent_avatars/agent.png',
      ]) {
        final file = File(p.join(appSupportDir.path, relative));
        await file.parent.create(recursive: true);
        await file.writeAsString('current personal avatar');
      }
      final extra = File(
        p.join(appSupportDir.path, 'file_workspaces/work/files/local-only.txt'),
      );
      await extra.parent.create(recursive: true);
      await extra.writeAsString('removed by directory replacement');
      final other = File(
        p.join(appSupportDir.path, 'file_workspaces/other/audio/other.wav'),
      );
      await other.parent.create(recursive: true);
      await other.writeAsString('existing other work');
      final restore = await BackupService().restoreFromZip(
        backup.backupPath!,
        mode: RestoreMode.selectedNovels,
        novelIds: {'work'},
      );
      expect(restore.success, true, reason: '${restore.failureReason}');
      expect(
        await File(
          p.join(
            appSupportDir.path,
            'file_workspaces/work/videos/unregistered.mp4',
          ),
        ).readAsString(),
        'bytes:file_workspaces/work/videos/unregistered.mp4',
      );
      expect(
        await File(
          p.join(
            appSupportDir.path,
            'file_workspaces/work/files/附件/subtitles.srt',
          ),
        ).exists(),
        true,
      );
      expect(
        await File(
          p.join(appSupportDir.path, 'file_workspaces/shared/files/unused.txt'),
        ).exists(),
        true,
      );
      expect(await other.readAsString(), 'existing other work');
      expect(await extra.exists(), false);
      expect(
        await File(
          p.join(
            appSupportDir.path,
            'file_workspaces/work/sessions/session/unregistered.mp4',
          ),
        ).exists(),
        true,
      );
      for (final relative in [
        'avatars/avatar.png',
        'agent_avatars/agent.png',
      ]) {
        expect(
          await File(p.join(appSupportDir.path, relative)).readAsString(),
          'current personal avatar',
        );
      }
      for (final relative in [
        'ai_images/not-a-released-work-directory.png',
        'character_avatars/not-a-released-work-directory.png',
      ]) {
        expect(
          await File(p.join(appSupportDir.path, relative)).exists(),
          false,
        );
      }
      expect(
        await File(
          p.join(
            appSupportDir.path,
            'file_workspaces/shared/images/retained.png',
          ),
        ).exists(),
        true,
      );
      final full = await BackupService().restoreFromZip(
        backup.backupPath!,
        mode: RestoreMode.fullReplacement,
      );
      expect(full.success, true);
      for (final relative in [
        'avatars/avatar.png',
        'agent_avatars/agent.png',
      ]) {
        expect(
          await File(p.join(appSupportDir.path, relative)).readAsString(),
          'bytes:$relative',
        );
      }
    },
  );

  for (final conflict in [false, true]) {
    test(
      'shared directory merge ${conflict ? 'overwrites different files' : 'restores identical files'}',
      () async {
        _writeLibrary(appSupportDir, {
          'work': (title: 'Work', marker: 'backup'),
        });
        for (final relative in [
          'file_workspaces/work/images/own.png',
          'file_workspaces/shared/images/shared.png',
        ]) {
          final file = File(p.join(appSupportDir.path, relative));
          await file.parent.create(recursive: true);
          await file.writeAsString('backup');
        }
        final backup = await BackupService().backupToZip(
          outputDirectory: outputDir.path,
        );
        expect(backup.success, true);
        final own = File(
          p.join(appSupportDir.path, 'file_workspaces/work/images/own.png'),
        );
        final shared = File(
          p.join(
            appSupportDir.path,
            'file_workspaces/shared/images/shared.png',
          ),
        );
        await own.writeAsString('current');
        await shared.writeAsString(conflict ? 'other work content' : 'backup');
        final localShared = File(
          p.join(appSupportDir.path, 'file_workspaces/shared/files/local.txt'),
        );
        await localShared.parent.create(recursive: true);
        await localShared.writeAsString('local shared file');
        final restore = await BackupService().restoreFromZip(
          backup.backupPath!,
          mode: RestoreMode.selectedNovels,
          novelIds: {'work'},
        );
        expect(restore.success, true);
        expect(await own.readAsString(), 'backup');
        expect(await shared.readAsString(), 'backup');
        expect(await localShared.readAsString(), 'local shared file');
      },
    );
  }

  test(
    'file write failure rolls back replaced directories and overwritten shared files',
    () async {
      _writeLibrary(appSupportDir, {'work': (title: 'Work', marker: 'backup')});
      for (final relative in [
        'file_workspaces/work/images/own.png',
        'file_workspaces/shared/images/shared.png',
        'file_workspaces/shared/images/blocked/child.png',
      ]) {
        final file = File(p.join(appSupportDir.path, relative));
        await file.parent.create(recursive: true);
        await file.writeAsString('backup');
      }
      final backup = await BackupService().backupToZip(
        outputDirectory: outputDir.path,
      );
      expect(backup.success, true);
      final own = File(
        p.join(appSupportDir.path, 'file_workspaces/work/images/own.png'),
      );
      final shared = File(
        p.join(appSupportDir.path, 'file_workspaces/shared/images/shared.png'),
      );
      await own.writeAsString('current own');
      await shared.writeAsString('current shared');
      final local = File(
        p.join(appSupportDir.path, 'file_workspaces/work/images/local.png'),
      );
      await local.writeAsString('local only');
      final restored = await BackupService().restoreFromZip(
        backup.backupPath!,
        mode: RestoreMode.selectedNovels,
        novelIds: {'work'},
        onBeforeFileRestore: () async {
          final blocked = Directory(
            p.join(appSupportDir.path, 'file_workspaces/shared/images/blocked'),
          );
          await blocked.delete(recursive: true);
          await File(
            blocked.path,
          ).writeAsString('file blocks destination directory');
        },
      );
      expect(restored.success, false);
      expect(await own.readAsString(), 'current own');
      expect(await shared.readAsString(), 'current shared');
      expect(await local.readAsString(), 'local only');
    },
  );

  test('failed database restore rolls back copied media', () async {
    final source = Directory(p.join(tempRoot.path, 'progress-source'))
      ..createSync();
    _writeLibrary(source, {'work': (title: 'Work', marker: 'backup')});
    _writeLibrary(appSupportDir, {'work': (title: 'Work', marker: 'current')});
    final sourceDb = sqlite3.open(p.join(source.path, 'reveric.sqlite'));
    insertBackupRow(sourceDb, 'assets', {
      'id': 'image',
      'type': 'image',
      'purpose': 'reference',
      'novel_id': 'work',
      'path': 'file_workspaces/work/images/photo.png',
    });
    sourceDb.close();
    final photo = File(
      p.join(source.path, 'file_workspaces/work/images/photo.png'),
    );
    await photo.parent.create(recursive: true);
    await photo.writeAsString('backup');
    final restored = await BackupService().restoreFromZip(
      packSource(source).path,
      mode: RestoreMode.selectedNovels,
      novelIds: {'work'},
      onBeforeFileRestore: () async {
        final target = sqlite3.open(
          p.join(appSupportDir.path, 'reveric.sqlite'),
        );
        target.execute(
          "CREATE TRIGGER fail_restore BEFORE INSERT ON assets BEGIN SELECT RAISE(FAIL, 'test restore failure'); END",
        );
        target.close();
      },
    );
    // Fail the row transaction after files have been replaced.

    expect(restored.success, false);
    expect(
      await File(
        p.join(appSupportDir.path, 'file_workspaces/work/images/photo.png'),
      ).exists(),
      false,
    );
    final content = sqlite3.open(
      p.join(appSupportDir.path, 'novel_workspaces/work.sqlite'),
    );
    expect(
      content.select('SELECT value FROM content_marker').single['value'],
      'current',
    );
    content.close();
  });

  test('backup refuses a symbolic link inside media', () async {
    _writeLibrary(appSupportDir, {'work': (title: 'Work', marker: 'backup')});
    final media = await Directory(
      p.join(appSupportDir.path, 'file_workspaces/work/files'),
    ).create(recursive: true);
    final outside = await File(
      p.join(tempRoot.path, 'outside.txt'),
    ).writeAsString('private');
    await Link(p.join(media.path, 'link')).create(outside.path);
    final backup = await BackupService().backupToZip(
      outputDirectory: outputDir.path,
    );
    expect(backup.success, false);
    expect(await outside.readAsString(), 'private');
  });

  for (final mode in RestoreMode.values) {
    for (final main in [true, false]) {
      for (final delta in [-1, 0, 1]) {
        test(
          '$mode checks ${main ? 'main' : 'content'} schema delta $delta before business data',
          () async {
            final source = Directory(p.join(tempRoot.path, 'source'))
              ..createSync();
            _writeLibrary(source, {'work': (title: 'Work', marker: 'backup')});
            final relative = main
                ? 'reveric.sqlite'
                : 'novel_workspaces/work.sqlite';
            final db = sqlite3.open(p.join(source.path, relative));
            final supported = main
                ? AppDatabase.currentSchemaVersion
                : NovelContentDatabase.currentSchemaVersion;
            db.execute('PRAGMA user_version = ${supported + delta}');
            db.close();
            if (delta != 0) {
              // A different schema must never reach current JSON/table readers.
              final futureDb = sqlite3.open(
                p.join(source.path, 'reveric.sqlite'),
              );
              futureDb.execute('DROP TABLE generation_tasks');
              futureDb.execute(
                'CREATE TABLE generation_tasks (future_field TEXT)',
              );
              futureDb.close();
            }
            final zip = packSource(source);
            _writeLibrary(appSupportDir, {
              'work': (title: 'Work', marker: 'current'),
            });
            final current = File(p.join(appSupportDir.path, 'reveric.sqlite'));
            final before = current.readAsBytesSync();
            var hookCalled = false;
            final service = BackupService();
            final inspection = await service.inspectBackup(zip.path);
            final restored = await service.restoreFromZip(
              zip.path,
              mode: mode,
              novelIds: {'work'},
              onBeforeFileRestore: () async {
                hookCalled = true;
              },
            );
            if (delta != 0) {
              expect(
                inspection.failureReason,
                RestoreFailureReason.unsupportedBackup,
              );
              expect(
                restored.failureReason,
                RestoreFailureReason.unsupportedBackup,
              );
              expect(current.readAsBytesSync(), before);
              expect(hookCalled, isFalse);
              expect(
                Directory(
                  p.join(appSupportDir.path, 'restore_backups'),
                ).existsSync(),
                isFalse,
              );
            } else {
              expect(inspection.success, isTrue);
              expect(restored.success, isTrue);
              expect(hookCalled, isTrue);
            }
          },
        );
      }
    }
  }

  test(
    'backup emits format 1 and unsupported formats are rejected before payload parsing',
    () async {
      _writeLibrary(appSupportDir, {
        'work': (title: 'Work', marker: 'current'),
      });
      final backup = await BackupService().backupToZip(
        outputDirectory: outputDir.path,
      );
      expect(backup.success, isTrue);
      final archive = ZipDecoder().decodeBytes(
        File(backup.backupPath!).readAsBytesSync(),
      );
      expect(
        jsonDecode(
          utf8.decode(archive.findFile('manifest.json')!.content as List<int>),
        )['version'],
        1,
      );
      final source = Directory(p.join(tempRoot.path, 'source'))..createSync();
      _writeLibrary(source, {'work': (title: 'Work', marker: 'backup')});
      for (final version in [0, 2, 3]) {
        final zip = packSource(source, version: version);
        final inspection = await BackupService().inspectBackup(zip.path);
        expect(
          inspection.failureReason,
          RestoreFailureReason.unsupportedBackup,
        );
        final restored = await BackupService().restoreFromZip(
          zip.path,
          mode: RestoreMode.fullReplacement,
        );
        expect(restored.failureReason, RestoreFailureReason.unsupportedBackup);
      }
    },
  );

  for (final mode in RestoreMode.values) {
    test('$mode cross-root restore preserves raw chat messages', () async {
      final source = await Directory(
        p.join(tempRoot.path, 'chat-source'),
      ).create();
      _writeLibrary(source, {
        'selected': (title: 'Selected', marker: 'backup'),
      });
      _writeLibrary(appSupportDir, {
        'selected': (title: 'Selected', marker: 'current'),
      });
      final db = sqlite3.open(
        p.join(source.path, 'novel_workspaces/selected.sqlite'),
      );
      final oldPath = p.join(
        source.path,
        'file_workspaces/selected/sessions/chat/image.png',
      );
      final valid =
          '[\n  ${jsonEncode({'kind': 'image', 'local_file_path': oldPath})},\n  ${jsonEncode({
            'kind': 'tool_call',
            'result': {'ok': true, 'local_path': oldPath},
          })}\n]';
      for (final entry in <String, String?>{
        'valid': valid,
        'invalid-json': '{broken',
        'object': '{}',
        'json-null': 'null',
        'empty': '',
        'sql-null': null,
      }.entries) {
        insertBackupRow(db, 'ai_chat_messages', {
          'id': entry.key,
          'session_id': 'chat',
          'role': 'assistant',
          'content': 'Keep $oldPath',
          'blocks': entry.value,
          'metadata': '{invalid metadata: $oldPath',
        });
      }
      final expected = db
          .select('SELECT * FROM ai_chat_messages ORDER BY id')
          .map((r) => Map<String, Object?>.from(r))
          .toList();
      db.close();
      final sessionFile = File(oldPath);
      await sessionFile.parent.create(recursive: true);
      await sessionFile.writeAsBytes([1, 2, 3]);
      final archive = packSource(source);

      final restored = await BackupService().restoreFromZip(
        archive.path,
        mode: mode,
        novelIds: {'selected'},
      );

      expect(restored.success, isTrue);
      final reopened = sqlite3.open(
        p.join(appSupportDir.path, 'novel_workspaces/selected.sqlite'),
      );
      try {
        expect(
          reopened
              .select('SELECT * FROM ai_chat_messages ORDER BY id')
              .map((r) => Map<String, Object?>.from(r))
              .toList(),
          expected,
        );
      } finally {
        reopened.close();
      }
      expect(
        await File(
          p.join(
            appSupportDir.path,
            'file_workspaces/selected/sessions/chat/image.png',
          ),
        ).readAsBytes(),
        [1, 2, 3],
      );
    });
  }

  test(
    'director animation and history survive actual backup and restore',
    () async {
      _writeLibrary(appSupportDir, {
        'work': (title: 'Work', marker: 'original'),
      });
      final document = animatedDirectorDocument();
      final contentPath = p.join(
        appSupportDir.path,
        'novel_workspaces',
        'work.sqlite',
      );
      final content = sqlite3.open(contentPath);
      insertBackupRow(content, 'video_stagings', {
        'id': 'staging',
        'document': document.encode(),
      });
      insertBackupRow(content, 'revisions', {
        'id': 'revision',
        'entity_type': 'video_staging',
        'entity_id': 'staging',
        'version': 1,
        'value': document.encode(),
      });
      content.close();
      final result = await BackupService().backupToZip(
        outputDirectory: outputDir.path,
      );
      expect(result.success, isTrue);
      appSupportDir = await Directory(
        p.join(tempRoot.path, 'restored-director'),
      ).create();
      _writeLibrary(appSupportDir, {
        'work': (title: 'Work', marker: 'replacement'),
      });
      final restored = await BackupService().restoreFromZip(
        result.backupPath!,
        mode: RestoreMode.fullReplacement,
      );
      expect(restored.success, isTrue);
      final restoredContent = sqlite3.open(
        p.join(appSupportDir.path, 'novel_workspaces', 'work.sqlite'),
      );
      try {
        for (final json in [
          restoredContent
              .select('SELECT document FROM video_stagings')
              .single['document'],
          restoredContent.select('SELECT value FROM revisions').single['value'],
        ]) {
          final reopened = DirectorDocument.parse(json as String);
          expect(reopened.businessContent, document.businessContent);
          for (final frame in [0, 24, 47, 48, 72, 96, 120]) {
            final actual = sampleDocument(reopened, frame),
                expected = sampleDocument(document, frame);
            expect(actual.objects, expected.objects);
            expect(actual.cameras, expected.cameras);
            expect(actual.cameraId, expected.cameraId);
            expect(actual.lighting, expected.lighting);
          }
        }
      } finally {
        restoredContent.close();
      }
    },
  );

  test('backs up workspace images, director outputs and user avatars', () async {
    _createSqlite(p.join(appSupportDir.path, 'reveric.sqlite'));

    final workspacesDir = Directory(
      p.join(appSupportDir.path, 'novel_workspaces'),
    );
    await workspacesDir.create(recursive: true);
    _createSqlite(p.join(workspacesDir.path, 'novel_1.sqlite'));
    final imagesDir = Directory(
      p.join(appSupportDir.path, 'file_workspaces/novel_1/images'),
    );
    await imagesDir.create(recursive: true);
    await File(p.join(imagesDir.path, 'avatar.png')).writeAsBytes([1, 2, 3]);

    final avatarsDir = Directory(p.join(appSupportDir.path, 'avatars'));
    await avatarsDir.create(recursive: true);
    await File(p.join(avatarsDir.path, 'me.png')).writeAsBytes([4, 5, 6]);

    final director = await DirectorStorage.open('novel-director');
    expect(
      director.root.path,
      p.join(
        appSupportDir.path,
        'file_workspaces',
        'novel-director',
        'files',
        'director',
      ),
    );
    for (final relative in [
      'workspaces/staging/preview.png',
      'workspaces/staging/completed/render/frame_000000.png',
      'exports/output/still.png',
    ]) {
      final file = File(p.join(director.root.path, relative));
      await file.parent.create(recursive: true);
      await file.writeAsBytes([7, 8, 9]);
    }

    final pluginFile = File(
      p.join(appSupportDir.path, 'plugins/example.search/1.0.0/dist/index.js'),
    );
    await pluginFile.parent.create(recursive: true);
    await pluginFile.writeAsString('plugin payload');

    final result = await BackupService().backupToZip(
      outputDirectory: outputDir.path,
    );

    expect(result.success, isTrue);
    expect(result.warnings, isEmpty);
    final archive = ZipDecoder().decodeBytes(
      await File(result.backupPath!).readAsBytes(),
    );
    final names = archive.files.map((file) => file.name).toSet();
    expect(names, contains('file_workspaces/novel_1/images/avatar.png'));
    expect(names, contains('avatars/me.png'));
    expect(names, contains('plugins/example.search/1.0.0/dist/index.js'));
    expect(
      names,
      contains(
        'file_workspaces/novel-director/files/director/workspaces/staging/preview.png',
      ),
    );
    expect(
      names,
      contains(
        'file_workspaces/novel-director/files/director/workspaces/staging/completed/render/frame_000000.png',
      ),
    );
    expect(
      names,
      contains(
        'file_workspaces/novel-director/files/director/exports/output/still.png',
      ),
    );

    // SQLite snapshot files should also be in the archive
    expect(names, contains(p.join('novel_workspaces', 'novel_1.sqlite')));
  });

  test(
    'selected restore retains mixed IDs and their exact relationship',
    () async {
      _writeLibrary(appSupportDir, {
        'novel-a': (title: 'Novel A', marker: 'backup'),
      });
      final databasePath = p.join(
        appSupportDir.path,
        'novel_workspaces',
        'novel-a.sqlite',
      );
      final db = NovelContentDatabase(databasePath);
      const oldId = 'character_aBcD0123456789XY';
      await db
          .into(db.characterProfiles)
          .insert(CharacterProfilesCompanion.insert(id: oldId, name: '旧角色'));
      final content = NovelContentService(
        db,
        idBuilder: (type) => '${shortEntityIdPrefixes[type]}_000001',
      );
      final shortId = await content.createCharacterProfile(name: '新角色');
      final relationId = await content.entityRelationsService.createRelation(
        sourceType: entityTypeCharacter,
        sourceId: oldId,
        targetType: entityTypeCharacter,
        targetId: shortId,
        relationType: characterRelationFriend,
      );
      await db.close();
      final service = BackupService();
      final backup = await service.backupToZip(outputDirectory: outputDir.path);
      expect(backup.success, isTrue);
      _writeLibrary(appSupportDir, {
        'novel-a': (title: 'Novel A', marker: 'current'),
      });
      final restored = await service.restoreFromZip(
        backup.backupPath!,
        mode: RestoreMode.selectedNovels,
        novelIds: const {'novel-a'},
      );
      expect(restored.success, isTrue);
      final restoredDb = NovelContentDatabase(databasePath);
      try {
        final characters = await restoredDb
            .select(restoredDb.characterProfiles)
            .get();
        expect(
          characters.map((row) => row.id),
          unorderedEquals([oldId, shortId]),
        );
        final relation =
            (await restoredDb.select(restoredDb.entityRelations).get()).single;
        expect(relation.id, relationId);
        expect(relation.sourceId, oldId);
        expect(relation.targetId, shortId);
      } finally {
        await restoredDb.close();
      }
    },
  );

  test('fails before backup when output directory is unavailable', () async {
    _createSqlite(p.join(appSupportDir.path, 'reveric.sqlite'));

    final result = await BackupService().backupToZip(
      outputDirectory: p.join(tempRoot.path, 'missing'),
    );

    expect(result.success, isFalse);
    expect(
      result.failureReason,
      BackupFailureReason.outputDirectoryUnavailable,
    );
  });

  test('fails when main database is not readable', () async {
    final sqlitePath = p.join(appSupportDir.path, 'reveric.sqlite');
    _createSqlite(sqlitePath);
    // Remove read permission — sqlite3.open in read-only mode will reject it
    await Process.run('chmod', ['000', sqlitePath]);

    final result = await BackupService().backupToZip(
      outputDirectory: outputDir.path,
    );

    expect(result.success, isFalse);
    expect(result.failureReason, BackupFailureReason.sqliteUnreadable);
  });

  test(
    'full replacement removes current-only novels and restores backup',
    () async {
      _writeLibrary(appSupportDir, {
        'backup-a': (title: 'Backup A', marker: 'backup-a'),
      });
      final service = BackupService();
      final backup = await service.backupToZip(outputDirectory: outputDir.path);
      expect(backup.success, isTrue);

      _writeLibrary(appSupportDir, {
        'current-b': (title: 'Current B', marker: 'current-b'),
      });
      final inspection = await service.inspectBackup(backup.backupPath!);
      expect(inspection.success, isTrue);
      expect(inspection.preview!.novels.map((novel) => novel.id), ['backup-a']);

      var closeCallbackCount = 0;
      final result = await service.restoreFromZip(
        backup.backupPath!,
        mode: RestoreMode.fullReplacement,
        onBeforeFileRestore: () async {
          closeCallbackCount += 1;
        },
      );

      expect(result.success, isTrue);
      expect(result.needsRestart, isTrue);
      expect(result.restoredNovelCount, 1);
      expect(closeCallbackCount, 1);
      expect(File(result.safetyBackupPath!).existsSync(), isTrue);
      expect(_readLibraryTitles(appSupportDir), {'backup-a': 'Backup A'});
      expect(_readContentMarker(appSupportDir, 'backup-a'), 'backup-a');
      expect(
        File(
          p.join(appSupportDir.path, 'novel_workspaces', 'current-b.sqlite'),
        ).existsSync(),
        isFalse,
      );
    },
  );

  test('selected restore changes only chosen novels', () async {
    _writeLibrary(appSupportDir, {
      'novel-a': (title: 'Novel A', marker: 'backup-a'),
      'novel-b': (title: 'Novel B', marker: 'backup-b'),
    });
    final service = BackupService();
    final backup = await service.backupToZip(outputDirectory: outputDir.path);
    expect(backup.success, isTrue);

    _writeLibrary(appSupportDir, {
      'novel-a': (title: 'Novel A', marker: 'current-a'),
      'novel-b': (title: 'Novel B', marker: 'current-b'),
      'novel-c': (title: 'Novel C', marker: 'current-c'),
    });

    final result = await service.restoreFromZip(
      backup.backupPath!,
      mode: RestoreMode.selectedNovels,
      novelIds: const {'novel-a'},
    );

    expect(result.success, isTrue);
    expect(result.restoredNovelCount, 1);
    expect(File(result.safetyBackupPath!).existsSync(), isTrue);
    expect(_readLibraryTitles(appSupportDir), {
      'novel-a': 'Novel A',
      'novel-b': 'Novel B',
      'novel-c': 'Novel C',
    });
    expect(_readContentMarker(appSupportDir, 'novel-a'), 'backup-a');
    expect(_readContentMarker(appSupportDir, 'novel-b'), 'current-b');
    expect(_readContentMarker(appSupportDir, 'novel-c'), 'current-c');
  });

  for (final storedPath in [
    null,
    '',
    'novel-a.sqlite',
    '/old/device/novel_workspaces/novel-a.sqlite',
    r'C:\old\novel_workspaces\novel-a.sqlite',
    'other/novel_workspaces/novel-a.sqlite',
    r'novel_workspaces\missing.sqlite',
    r'novel_workspaces\..\novel_workspaces\novel-a.sqlite',
  ]) {
    test(
      'inspection rejects missing or unsafe content path $storedPath',
      () async {
        _writeLibrary(appSupportDir, {
          'novel-a': (title: 'Novel A', marker: 'unchanged'),
        });
        final db = sqlite3.open(p.join(appSupportDir.path, 'reveric.sqlite'));
        try {
          db.execute('UPDATE novels SET content_database_path = ?', [
            storedPath,
          ]);
        } finally {
          db.close();
        }
        final service = BackupService();
        final backup = await service.backupToZip(
          outputDirectory: outputDir.path,
        );
        expect(backup.success, isTrue);
        final inspection = await service.inspectBackup(backup.backupPath!);
        expect(inspection.success, isTrue);
        expect(inspection.preview!.novels.single.hasContentDatabase, isFalse);
        final restored = await service.restoreFromZip(
          backup.backupPath!,
          mode: RestoreMode.selectedNovels,
          novelIds: const {'novel-a'},
        );
        expect(restored.success, isFalse);
        expect(restored.needsRestart, isFalse);
        expect(restored.safetyBackupPath, isNull);
        expect(_readContentMarker(appSupportDir, 'novel-a'), 'unchanged');
      },
    );
  }

  test('drafts are excluded from restore choices and novel count', () async {
    _writeLibrary(
      appSupportDir,
      {
        'novel-a': (title: 'Novel A', marker: 'backup'),
        'draft-a': (title: 'Untitled', marker: 'draft'),
      },
      draftNovelIds: {'draft-a'},
    );
    final service = BackupService();
    final backup = await service.backupToZip(outputDirectory: outputDir.path);
    expect(backup.success, isTrue);

    final inspection = await service.inspectBackup(backup.backupPath!);
    expect(inspection.success, isTrue);
    expect(inspection.preview!.novels.map((novel) => novel.id), ['novel-a']);
    expect(inspection.preview!.novels.single.canRestore, isTrue);

    final selected = await service.restoreFromZip(
      backup.backupPath!,
      mode: RestoreMode.selectedNovels,
      novelIds: const {'draft-a'},
    );
    expect(selected.success, isFalse);
    expect(selected.failureReason, RestoreFailureReason.invalidBackup);
    expect(selected.needsRestart, isFalse);
    expect(selected.safetyBackupPath, isNull);

    _writeLibrary(appSupportDir, {
      'current': (title: 'Current', marker: 'current'),
    });
    final full = await service.restoreFromZip(
      backup.backupPath!,
      mode: RestoreMode.fullReplacement,
    );
    expect(full.success, isTrue);
    expect(full.restoredNovelCount, 1);
    expect(_readLibraryTitles(appSupportDir), {
      'novel-a': 'Novel A',
      'draft-a': 'Untitled',
    });
    expect(_readContentMarker(appSupportDir, 'draft-a'), 'draft');
  });

  test('current drafts do not block restoring a same-title novel', () async {
    _writeLibrary(appSupportDir, {
      'backup-id': (title: 'Same title', marker: 'backup'),
    });
    final service = BackupService();
    final backup = await service.backupToZip(outputDirectory: outputDir.path);
    expect(backup.success, isTrue);

    _writeLibrary(
      appSupportDir,
      {'draft-id': (title: 'Same title', marker: 'draft')},
      draftNovelIds: {'draft-id'},
    );
    final inspection = await service.inspectBackup(backup.backupPath!);
    expect(inspection.success, isTrue);
    expect(inspection.preview!.novels.single.hasTitleConflict, isFalse);
    expect(inspection.preview!.novels.single.canRestore, isTrue);

    final restored = await service.restoreFromZip(
      backup.backupPath!,
      mode: RestoreMode.selectedNovels,
      novelIds: const {'backup-id'},
    );
    expect(restored.success, isTrue);
    expect(_readLibraryTitles(appSupportDir), {
      'backup-id': 'Same title',
      'draft-id': 'Same title',
    });
    expect(_readContentMarker(appSupportDir, 'backup-id'), 'backup');
    expect(_readContentMarker(appSupportDir, 'draft-id'), 'draft');
  });

  test(
    'selected restore rejects same-title novel with a different id',
    () async {
      _writeLibrary(appSupportDir, {
        'backup-id': (title: 'Same title', marker: 'backup'),
      });
      final service = BackupService();
      final backup = await service.backupToZip(outputDirectory: outputDir.path);
      expect(backup.success, isTrue);

      _writeLibrary(appSupportDir, {
        'current-id': (title: 'Same title', marker: 'current'),
      });
      final inspection = await service.inspectBackup(backup.backupPath!);

      expect(inspection.success, isTrue);
      expect(inspection.preview!.novels.single.hasTitleConflict, isTrue);
      final result = await service.restoreFromZip(
        backup.backupPath!,
        mode: RestoreMode.selectedNovels,
        novelIds: const {'backup-id'},
      );
      expect(result.success, isFalse);
      expect(result.failureReason, RestoreFailureReason.novelTitleConflict);
      expect(_readLibraryTitles(appSupportDir), {'current-id': 'Same title'});
      expect(_readContentMarker(appSupportDir, 'current-id'), 'current');
    },
  );
  for (final mode in RestoreMode.values) {
    for (final separator in ['/', r'\']) {
      test(
        '$mode restores current relative paths with $separator separators',
        () async {
          _writeLibrary(appSupportDir, {
            'work': (title: 'Work', marker: 'backup'),
          });
          final db = sqlite3.open(p.join(appSupportDir.path, 'reveric.sqlite'));
          db.execute(
            'UPDATE novels SET content_database_path = ?, cover_asset_id = ?',
            ['novel_workspaces${separator}work.sqlite', 'cover'],
          );
          insertBackupRow(db, 'assets', {
            'id': 'cover',
            'type': 'image',
            'purpose': 'cover',
            'path':
                'file_workspaces${separator}shared${separator}images${separator}cover.png',
          });
          db.close();
          final cover = File(
            p.join(
              appSupportDir.path,
              'file_workspaces/shared/images/cover.png',
            ),
          );
          await cover.parent.create(recursive: true);
          await cover.writeAsBytes([1, 2, 3]);
          final service = BackupService();
          final backup = await service.backupToZip(
            outputDirectory: outputDir.path,
          );
          expect(backup.success, isTrue);
          appSupportDir = await Directory(
            p.join(tempRoot.path, 'other-root'),
          ).create();
          _writeLibrary(appSupportDir, {
            'other': (title: 'Other', marker: 'current'),
          });
          final result = await service.restoreFromZip(
            backup.backupPath!,
            mode: mode,
            novelIds: {'work'},
          );
          expect(result.success, isTrue, reason: '${result.failureReason}');
          expect(_readContentMarker(appSupportDir, 'work'), 'backup');
          expect(
            await File(
              p.join(
                appSupportDir.path,
                'file_workspaces/shared/images/cover.png',
              ),
            ).readAsBytes(),
            [1, 2, 3],
          );
          final main = sqlite3.open(
            p.join(appSupportDir.path, 'reveric.sqlite'),
          );
          expect(
            main
                .select("SELECT cover_asset_id FROM novels WHERE id = 'work'")
                .single['cover_asset_id'],
            'cover',
          );
          expect(
            main.select("SELECT id FROM assets WHERE id = 'cover'"),
            hasLength(1),
          );
          main.close();
          if (mode == RestoreMode.selectedNovels) {
            expect(_readContentMarker(appSupportDir, 'other'), 'current');
          }
        },
      );
    }

    test(
      '$mode restores current asset references, task records and media',
      () async {
        _writeLibrary(appSupportDir, {
          'work': (title: 'Work', marker: 'backup'),
          'other': (title: 'Other', marker: 'other backup'),
        });
        final main = sqlite3.open(p.join(appSupportDir.path, 'reveric.sqlite'));
        final expectedIds = {
          'avatar',
          'character-photo',
          'location-photo',
          'item-photo',
          'clip',
          'node',
          'batch',
          'previous',
          'reference',
          'task-result',
          'task-input',
          'map',
        };
        for (final id in [...expectedIds, 'unrelated']) {
          final path = 'file_workspaces/shared/images/$id.png';
          insertBackupRow(main, 'assets', {
            'id': id,
            'type': 'image',
            'purpose': 'reference',
            'path': path,
          });
          final file = File(p.join(appSupportDir.path, path));
          await file.parent.create(recursive: true);
          await file.writeAsString('backup-$id');
        }
        insertBackupRow(main, 'image_batches', {
          'id': 'batch',
          'novel_id': 'work',
          'prompt': 'test',
        });
        insertBackupRow(main, 'image_batch_slots', {
          'id': 'slot',
          'batch_id': 'batch',
          'ordinal': 0,
          'asset_id': 'batch',
          'previous_asset_id': 'previous',
        });
        insertBackupRow(main, 'image_asset_references', {
          'id': 'reference',
          'asset_id': 'batch',
          'batch_id': 'batch',
          'reference_asset_id': 'reference',
          'ordinal': 0,
          'purpose': 'reference',
        });
        insertBackupRow(main, 'generation_tasks', {
          'id': 'task',
          'kind': 'image',
          'novel_id': 'work',
          'source_type': 'production_clip',
          'source_id': 'clip',
          'provider_id': 'provider',
          'provider_type': 'openai',
          'model_id': 'model',
          'status': 'completed',
          'result_asset_id': 'task-result',
          'path': 'file_workspaces/shared/images/task-result.png',
          'request_json': const GenerationRequestConverter().toSql(
            ImageGenerationRequest(
              ProductionImageRequest(
                providerId: 'provider',
                modelId: 'model',
                originalPrompt: 'test',
                prompt: 'test',
                ratio: '1:1',
                resolution: '1K',
                size: null,
                references: const [
                  ProductionImageReference(assetId: 'task-input'),
                ],
              ),
            ),
          ),
        });
        main.close();
        final content = sqlite3.open(
          p.join(appSupportDir.path, 'novel_workspaces/work.sqlite'),
        );
        for (final (table, id) in [
          ('character_profiles', 'character-photo'),
          ('locations', 'location-photo'),
          ('items', 'item-photo'),
        ]) {
          insertBackupRow(content, table, {
            'id': id,
            if (table == 'items') ...{
              'title': 'Reference',
              'type': 'item',
            } else
              'name': 'Reference',
            if (table == 'character_profiles') 'avatar_asset_id': 'avatar',
            'photos': jsonEncode([
              {'asset_id': id, 'name': 'Reference'},
            ]),
          });
        }
        insertBackupRow(content, 'production_clips', {
          'id': 'clip',
          'episode_id': 'episode',
          'kind': 'image',
          'adopted_asset_id': 'clip',
        });
        insertBackupRow(content, 'canvas_nodes', {
          'id': 'node',
          'canvas_id': 'canvas',
          'ref_type': 'asset',
          'ref_id': 'node',
          'x': 0,
          'y': 0,
        });
        insertBackupRow(content, 'novel_maps', {
          'id': 'map',
          'name': 'Map',
          'settings': jsonEncode(
            const MapStudioSettings(
              image: 'file_workspaces/shared/images/map.png',
            ).toJson(),
          ),
        });
        content.close();
        final service = BackupService();
        final backup = await service.backupToZip(
          outputDirectory: outputDir.path,
        );
        expect(backup.success, isTrue);
        appSupportDir = await Directory(
          p.join(tempRoot.path, 'reference-target'),
        ).create();
        _writeLibrary(appSupportDir, {
          'other': (title: 'Other', marker: 'current other'),
        });
        final restored = await service.restoreFromZip(
          backup.backupPath!,
          mode: mode,
          novelIds: {'work'},
        );
        expect(restored.success, isTrue, reason: '${restored.failureReason}');
        final restoredMain = sqlite3.open(
          p.join(appSupportDir.path, 'reveric.sqlite'),
        );
        expect(
          restoredMain
              .select('SELECT id FROM assets')
              .map((row) => row['id'])
              .toSet(),
          mode == RestoreMode.fullReplacement
              ? {...expectedIds, 'unrelated'}
              : expectedIds,
        );
        expect(
          restoredMain
              .select('SELECT result_asset_id FROM generation_tasks')
              .single['result_asset_id'],
          'task-result',
        );
        expect(
          restoredMain
              .select('SELECT previous_asset_id FROM image_batch_slots')
              .single['previous_asset_id'],
          'previous',
        );
        restoredMain.close();
        for (final id in expectedIds) {
          expect(
            await File(
              p.join(
                appSupportDir.path,
                'file_workspaces/shared/images/$id.png',
              ),
            ).readAsString(),
            'backup-$id',
          );
        }
        final restoredContent = sqlite3.open(
          p.join(appSupportDir.path, 'novel_workspaces/work.sqlite'),
        );
        expect(
          restoredContent
              .select('SELECT avatar_asset_id FROM character_profiles')
              .single['avatar_asset_id'],
          'avatar',
        );
        expect(
          restoredContent
              .select('SELECT photos FROM locations')
              .single['photos'],
          jsonEncode([
            {'asset_id': 'location-photo', 'name': 'Reference'},
          ]),
        );
        restoredContent.close();
      },
    );
  }

  for (final photo in [
    'file_workspaces/work/images/photo.png',
    {'path': 'file_workspaces/work/images/photo.png', 'name': 'Old'},
  ]) {
    test(
      'selected restore rejects obsolete photo structure $photo and rolls back',
      () async {
        _writeLibrary(appSupportDir, {
          'work': (title: 'Work', marker: 'backup'),
        });
        final db = sqlite3.open(
          p.join(appSupportDir.path, 'novel_workspaces/work.sqlite'),
        );
        insertBackupRow(db, 'locations', {
          'id': 'location',
          'name': 'Place',
          'photos': jsonEncode([photo]),
        });
        db.close();
        final service = BackupService();
        final backup = await service.backupToZip(
          outputDirectory: outputDir.path,
        );
        expect(backup.success, isTrue);
        _writeLibrary(appSupportDir, {
          'work': (title: 'Work', marker: 'current'),
        });
        final result = await service.restoreFromZip(
          backup.backupPath!,
          mode: RestoreMode.selectedNovels,
          novelIds: {'work'},
        );
        expect(result.success, isFalse);
        expect(_readContentMarker(appSupportDir, 'work'), 'current');
      },
    );
  }

  for (final missing in ['assets', 'draft']) {
    test('restore does not tolerate missing current $missing schema', () async {
      _writeLibrary(appSupportDir, {'work': (title: 'Work', marker: 'backup')});
      final db = sqlite3.open(p.join(appSupportDir.path, 'reveric.sqlite'));
      if (missing == 'assets') {
        db.execute('ALTER TABLE assets RENAME TO image_assets');
      } else {
        db.execute('ALTER TABLE novels RENAME COLUMN draft TO obsolete_draft');
      }
      db.close();
      final service = BackupService();
      final backup = await service.backupToZip(outputDirectory: outputDir.path);
      expect(backup.success, isTrue);
      _writeLibrary(appSupportDir, {
        'work': (title: 'Work', marker: 'current'),
      });
      final result = await service.restoreFromZip(
        backup.backupPath!,
        mode: RestoreMode.selectedNovels,
        novelIds: {'work'},
      );
      expect(result.success, isFalse);
      expect(_readContentMarker(appSupportDir, 'work'), 'current');
    });
  }
}

void _createSqlite(String path) {
  final db = sqlite3.open(path);
  try {
    db.execute('CREATE TABLE test_data (id INTEGER PRIMARY KEY, value TEXT)');
    db.execute("INSERT INTO test_data (value) VALUES ('ok')");
  } finally {
    db.close();
  }
}

void _writeLibrary(
  Directory appSupportDir,
  Map<String, ({String title, String marker})> novels, {
  Set<String>? draftNovelIds,
}) {
  final mainDatabase = File(p.join(appSupportDir.path, 'reveric.sqlite'));
  if (mainDatabase.existsSync()) {
    mainDatabase.deleteSync();
  }
  final workspaces = Directory(p.join(appSupportDir.path, 'novel_workspaces'));
  if (workspaces.existsSync()) {
    workspaces.deleteSync(recursive: true);
  }
  workspaces.createSync(recursive: true);

  final db = _databases.writeMain(mainDatabase.path);
  try {
    for (final entry in novels.entries) {
      final relativePath = p.join('novel_workspaces', '${entry.key}.sqlite');
      insertBackupRow(db, 'novels', {
        'id': entry.key,
        'title': entry.value.title,
        'description': entry.value.marker,
        'content_database_path': relativePath,
      });
      if (draftNovelIds?.contains(entry.key) ?? false) {
        db.execute('UPDATE novels SET draft = 1 WHERE id = ?', [entry.key]);
      }
      _writeContentDatabase(
        p.join(appSupportDir.path, relativePath),
        entry.value.marker,
      );
    }
  } finally {
    db.close();
  }
}

void _writeContentDatabase(String path, String marker) {
  final db = _databases.writeContent(path);
  try {
    db.execute('CREATE TABLE content_marker (value TEXT NOT NULL)');
    db.execute('INSERT INTO content_marker (value) VALUES (?)', [marker]);
  } finally {
    db.close();
  }
}

Map<String, String> _readLibraryTitles(Directory appSupportDir) {
  final db = sqlite3.open(p.join(appSupportDir.path, 'reveric.sqlite'));
  try {
    return {
      for (final row in db.select('SELECT id, title FROM novels'))
        row['id'] as String: row['title'] as String,
    };
  } finally {
    db.close();
  }
}

String _readContentMarker(Directory appSupportDir, String novelId) {
  final db = sqlite3.open(
    p.join(appSupportDir.path, 'novel_workspaces', '$novelId.sqlite'),
    mode: OpenMode.readOnly,
  );
  try {
    return db.select('SELECT value FROM content_marker').single['value']
        as String;
  } finally {
    db.close();
  }
}

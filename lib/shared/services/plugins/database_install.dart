// 职责: 用一致性副本迁移插件私有库，并通过持久安装记录恢复文件切换与主库登记。
// 关联文件:
//   lib/shared/services/plugins/sqlite.dart
//   lib/shared/services/plugins/installer.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/database/daos/app_state_dao.dart
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../../database/app_database.dart';
import '../../logger/app_logger.dart';
import 'runtime.dart';
import 'sqlite.dart';

final _log = AppLogger.forModule('PluginDatabaseInstall');

class PluginDatabaseInstallOrchestrator {
  Future<void> install({
    required AppDatabase database,
    required PluginSqliteService databases,
    required String pluginId,
    required String version,
    required String? oldVersion,
    required List<Map<String, Object?>> migrations,
    required Future<void> Function() validate,
    required Future<void> Function() commit,
  }) async {
    final current = File(databases.pathFor(pluginId));
    await current.parent.create(recursive: true);
    final token = 'install-${const Uuid().v4()}';
    final directory = await Directory(
      p.join(current.parent.path, token),
    ).create();
    final staged = File(p.join(directory.path, 'staged.sqlite'));
    final backup = File(p.join(directory.path, 'previous.sqlite'));
    final hadOriginal = await current.exists();
    final record = <String, Object?>{
      'phase': 'prepared',
      'pluginId': pluginId,
      'oldVersion': oldVersion,
      'newVersion': version,
      'directory': token,
      'hadOriginal': hadOriginal,
    };
    var prepared = false, committed = false;
    try {
      await databases.drain(pluginId);
      if (hadOriginal) {
        await databases.backup(pluginId, staged.path);
      }
      await PluginSqliteService.migrateStaged(staged.path, migrations);
      await validate();
      await databases.close(pluginId);
      await _record(database, pluginId, record);
      prepared = true;
      if (hadOriginal) {
        await current.rename(backup.path);
      }
      await staged.rename(current.path);
      await database.transaction(() async {
        await commit();
        await _record(database, pluginId, {...record, 'phase': 'committed'});
      });
      committed = true;
    } catch (error, stack) {
      _log.error(
        'Private database install failed plugin=$pluginId',
        error: error,
        stackTrace: stack,
      );
      if (prepared) {
        try {
          await _recoverOne(database, databases.root, pluginId, record);
        } catch (recovery, trace) {
          _log.error(
            'Database rollback failed plugin=$pluginId',
            error: recovery,
            stackTrace: trace,
          );
          throw PluginHostError(
            'database_recovery_required',
            'Plugin $pluginId requires installation recovery: $recovery',
          );
        }
      } else {
        await _cleanup(directory);
      }
      rethrow;
    }
    if (committed) {
      try {
        await _recoverOne(database, databases.root, pluginId, {
          ...record,
          'phase': 'committed',
        });
      } catch (error, stack) {
        // Registration and canonical file already committed together. Startup
        // completes cleanup from the persisted committed record.
        _log.error(
          'Committed install cleanup deferred plugin=$pluginId',
          error: error,
          stackTrace: stack,
        );
      }
    }
  }

  Future<Map<String, Object>> recover({
    required AppDatabase database,
    required Directory root,
  }) async {
    final failures = <String, Object>{};
    for (final entry in (await database.appStateDao.getAllByPrefix(
      'plugin_install.',
    )).entries) {
      if (!entry.key.startsWith('plugin_install.')) {
        continue;
      }
      final id = entry.key.substring('plugin_install.'.length);
      try {
        final value = jsonDecode(entry.value);
        if (value is! Map<String, dynamic>) {
          throw const FormatException('Invalid installation record');
        }
        if (value['phase'] == 'done') {
          continue;
        }
        await _recoverOne(database, root, id, value);
      } catch (error, stack) {
        failures[id] = error;
        _log.error(
          'Plugin installation recovery failed plugin=$id',
          error: error,
          stackTrace: stack,
        );
      }
    }
    return failures;
  }

  Future<void> _recoverOne(
    AppDatabase database,
    Directory root,
    String id,
    Map record,
  ) async {
    if (!RegExp(r'^[a-z0-9]+(\.[a-z0-9-]+)+$').hasMatch(id) ||
        record['pluginId'] != id ||
        record['directory'] is! String ||
        !RegExp(
          r'^install-[a-f0-9-]{36}$',
        ).hasMatch(record['directory'] as String) ||
        record['hadOriginal'] is! bool ||
        !const {'prepared', 'committed'}.contains(record['phase'])) {
      throw const FormatException(
        'Invalid installation recovery identity or paths',
      );
    }
    final home = Directory(p.join(root.path, 'plugin_data', id));
    final directory = Directory(
      p.join(home.path, record['directory'] as String),
    );
    final current = File(p.join(home.path, 'data.sqlite'));
    final backup = File(p.join(directory.path, 'previous.sqlite'));
    if (record['phase'] == 'prepared') {
      if (record['hadOriginal'] == true) {
        if (await backup.exists()) {
          if (await current.exists()) {
            await current.delete();
          }
          await backup.rename(current.path);
        } else if (!await current.exists()) {
          throw const FileSystemException(
            'Original database and recovery copy are missing',
          );
        }
      } else if (await current.exists()) {
        await current.delete();
      }
    } else {
      if (!await current.exists()) {
        throw const FileSystemException('Committed database is missing');
      }
      final registered = await database.pluginDao.getPlugin(id);
      if (registered == null || registered.version != record['newVersion']) {
        throw const FormatException(
          'Committed package registration differs from database install',
        );
      }
    }
    await _cleanup(directory);
    await _record(database, id, {'phase': 'done', 'pluginId': id});
  }

  Future<void> _record(
    AppDatabase database,
    String id,
    Map<String, Object?> record,
  ) async {
    try {
      await database.appStateDao.set(
        key: 'plugin_install.$id',
        value: jsonEncode(record),
      );
    } catch (error, stack) {
      _log.error(
        '[DB] app_states UPSERT plugin_install.$id',
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  Future<void> _cleanup(Directory directory) async {
    if (!await directory.exists()) {
      return;
    }
    final entries = await directory.list(followLinks: false).toList();
    for (final entry in entries) {
      if (entry is! File ||
          !const {
            'staged.sqlite',
            'previous.sqlite',
            'staged.sqlite-journal',
            'previous.sqlite-journal',
          }.contains(p.basename(entry.path))) {
        throw const FileSystemException(
          'Unexpected file in installation recovery directory',
        );
      }
    }
    for (final entry in entries) {
      await entry.delete();
    }
    await directory.delete();
  }
}

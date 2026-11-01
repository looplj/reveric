// 职责: 按插件身份持久化登记、启停与隔离的键值数据。
// 关联文件:
//   lib/shared/database/app_database.dart
import 'dart:convert';
import 'package:drift/drift.dart';
import '../app_database.dart';
import '../../logger/app_logger.dart';
part 'plugin_dao.drift.dart';

final _log = AppLogger.forModule('PluginDao');

@DriftAccessor(
  tables: [PluginRegistry, PluginStorage, PluginSecrets, PluginPermissions],
)
class PluginDao extends DatabaseAccessor<AppDatabase> with _$PluginDaoMixin {
  PluginDao(super.db);
  Future<PluginRegistryData?> getPlugin(String pluginId) =>
      (select(pluginRegistry)..where(
            (t) =>
                t.pluginId.equals(pluginId) &
                t.deletedAt.equals(notDeletedSentinel),
          ))
          .getSingleOrNull();
  Future<List<PluginRegistryData>> localPlugins() =>
      (select(pluginRegistry)..where(
            (t) =>
                t.source.equals('local') &
                t.deletedAt.equals(notDeletedSentinel),
          ))
          .get();

  Future<void> install({
    required String pluginId,
    required String version,
    required String packagePath,
    required Iterable<String> permissions,
  }) => _write(
    pluginId,
    'plugin_registry/plugin_permissions',
    'UPSERT',
    () => transaction(() async {
      final existing = await (select(
        pluginRegistry,
      )..where((t) => t.pluginId.equals(pluginId))).getSingleOrNull();
      if (existing != null && existing.source != 'local') {
        throw StateError('Cannot replace a bundled plugin');
      }
      await into(pluginRegistry).insertOnConflictUpdate(
        PluginRegistryCompanion.insert(
          pluginId: pluginId,
          version: version,
          source: 'local',
          packagePath: packagePath,
          enabled: existing?.enabled ?? false,
          createdAt: existing == null
              ? const Value.absent()
              : Value(existing.createdAt),
          updatedAt: Value(DateTime.now()),
          deletedAt: Value(notDeletedSentinel),
        ),
      );
      await grantPermissions(pluginId, permissions);
    }),
  );

  Future<void> uninstall(String pluginId) =>
      _write(pluginId, 'plugin_registry', 'UPDATE', () async {
        final row = await getPlugin(pluginId);
        if (row == null || row.source != 'local') {
          throw StateError('Only installed local plugins can be uninstalled');
        }
        await (update(
          pluginRegistry,
        )..where((t) => t.pluginId.equals(pluginId))).write(
          PluginRegistryCompanion(
            deletedAt: Value(DateTime.now()),
            updatedAt: Value(DateTime.now()),
          ),
        );
      });

  Future<T> _write<T>(
    String pluginId,
    String table,
    String operation,
    Future<T> Function() action,
  ) async {
    try {
      return await action();
    } catch (error, stack) {
      _log.error(
        '[DB] $table $operation plugin=$pluginId',
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  Future<void> register({
    required String pluginId,
    required String version,
    required String source,
    required String packagePath,
    required bool initiallyEnabled,
  }) => _write(pluginId, 'plugin_registry', 'UPSERT', () async {
    if (!['bundled', 'local'].contains(source)) {
      throw ArgumentError.value(source, 'source');
    }
    await transaction(() async {
      final existing = await getPlugin(pluginId);
      await into(pluginRegistry).insertOnConflictUpdate(
        PluginRegistryCompanion.insert(
          pluginId: pluginId,
          version: version,
          source: source,
          packagePath: packagePath,
          enabled: existing?.enabled ?? initiallyEnabled,
          createdAt: existing == null
              ? const Value.absent()
              : Value(existing.createdAt),
          updatedAt: Value(DateTime.now()),
        ),
      );
    });
  });
  Future<void> setEnabled(String pluginId, bool enabled) =>
      _write(pluginId, 'plugin_registry', 'UPDATE', () async {
        final count =
            await (update(pluginRegistry)..where(
                  (t) =>
                      t.pluginId.equals(pluginId) &
                      t.deletedAt.equals(notDeletedSentinel),
                ))
                .write(
                  PluginRegistryCompanion(
                    enabled: Value(enabled),
                    updatedAt: Value(DateTime.now()),
                  ),
                );
        if (count != 1) {
          throw StateError('Unknown plugin: $pluginId');
        }
      });
  Future<String?> getStorage(String pluginId, String key) async =>
      (await (select(pluginStorage)..where(
                (t) =>
                    t.pluginId.equals(pluginId) &
                    t.key.equals(key) &
                    t.deletedAt.equals(notDeletedSentinel),
              ))
              .getSingleOrNull())
          ?.value;
  Future<void> setStorage(String pluginId, String key, String value) =>
      _write(pluginId, 'plugin_storage', 'UPSERT', () async {
        await into(pluginStorage).insertOnConflictUpdate(
          PluginStorageCompanion.insert(
            pluginId: pluginId,
            key: key,
            value: value,
            deletedAt: Value(notDeletedSentinel),
            updatedAt: Value(DateTime.now()),
          ),
        );
      });
  Future<String?> getSecret(String pluginId, String key) async =>
      (await (select(pluginSecrets)
                ..where((t) => t.pluginId.equals(pluginId) & t.key.equals(key)))
              .getSingleOrNull())
          ?.value;
  Future<List<String>> secretValues(String pluginId) async =>
      (await (select(
            pluginSecrets,
          )..where((t) => t.pluginId.equals(pluginId))).get())
          .map((r) => r.value)
          .toList();
  Future<void> setSecret(String pluginId, String key, String value) =>
      _write(pluginId, 'plugin_secrets', 'UPSERT', () async {
        await into(pluginSecrets).insertOnConflictUpdate(
          PluginSecretsCompanion.insert(
            pluginId: pluginId,
            key: key,
            value: value,
            updatedAt: Value(DateTime.now()),
          ),
        );
      });
  Future<void> setPluginData(
    String pluginId,
    String key,
    String value,
  ) => _write(
    pluginId,
    'plugin_storage',
    'UPSERT',
    () => transaction(() async {
      final size = utf8.encode(value).length;
      if (size > 256 * 1024) {
        throw const PluginStorageQuotaException();
      }
      final usage = await customSelect(
        "SELECT COALESCE(SUM(length(CAST(value AS BLOB))), 0) AS bytes FROM plugin_storage WHERE plugin_id = ? AND key LIKE 'data.%' AND key <> ? AND deleted_at = 0",
        variables: [Variable(pluginId), Variable('data.$key')],
        readsFrom: {pluginStorage},
      ).getSingle();
      if (usage.read<int>('bytes') + size > 16 * 1024 * 1024) {
        throw const PluginStorageQuotaException();
      }
      await setStorage(pluginId, 'data.$key', value);
    }),
  );

  Future<void> removePluginData(String pluginId, String key) =>
      _write(pluginId, 'plugin_storage', 'UPDATE', () async {
        await (update(pluginStorage)..where(
              (t) =>
                  t.pluginId.equals(pluginId) &
                  t.key.equals('data.$key') &
                  t.deletedAt.equals(notDeletedSentinel),
            ))
            .write(
              PluginStorageCompanion(
                deletedAt: Value(DateTime.now()),
                updatedAt: Value(DateTime.now()),
              ),
            );
      });

  Future<Set<String>> grantedPermissions(String pluginId) async =>
      (await (select(pluginPermissions)..where(
                (t) =>
                    t.pluginId.equals(pluginId) &
                    t.deletedAt.equals(notDeletedSentinel),
              ))
              .get())
          .map((row) => row.permission)
          .toSet();

  Future<void> grantPermissions(
    String pluginId,
    Iterable<String> permissions,
  ) => _write(
    pluginId,
    'plugin_permissions',
    'UPSERT',
    () => transaction(() async {
      for (final permission in permissions) {
        await into(pluginPermissions).insertOnConflictUpdate(
          PluginPermissionsCompanion.insert(
            pluginId: pluginId,
            permission: permission,
            updatedAt: Value(DateTime.now()),
            deletedAt: Value(notDeletedSentinel),
          ),
        );
      }
    }),
  );

  Future<void> revokePermission(String pluginId, String permission) =>
      _write(pluginId, 'plugin_permissions', 'UPDATE', () async {
        await (update(pluginPermissions)..where(
              (t) =>
                  t.pluginId.equals(pluginId) & t.permission.equals(permission),
            ))
            .write(
              PluginPermissionsCompanion(
                updatedAt: Value(DateTime.now()),
                deletedAt: Value(DateTime.now()),
              ),
            );
      });
}

class PluginStorageQuotaException implements Exception {
  const PluginStorageQuotaException();
}

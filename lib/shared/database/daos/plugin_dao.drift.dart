// dart format width=80
// ignore_for_file: type=lint
part of 'plugin_dao.dart';

mixin _$PluginDaoMixin on DatabaseAccessor<AppDatabase> {
  $PluginRegistryTable get pluginRegistry => attachedDatabase.pluginRegistry;
  $PluginStorageTable get pluginStorage => attachedDatabase.pluginStorage;
  $PluginSecretsTable get pluginSecrets => attachedDatabase.pluginSecrets;
  $PluginPermissionsTable get pluginPermissions =>
      attachedDatabase.pluginPermissions;
  PluginDaoManager get managers => PluginDaoManager(this);
}

class PluginDaoManager {
  final _$PluginDaoMixin _db;
  PluginDaoManager(this._db);
  $$PluginRegistryTableTableManager get pluginRegistry =>
      $$PluginRegistryTableTableManager(
        _db.attachedDatabase,
        _db.pluginRegistry,
      );
  $$PluginStorageTableTableManager get pluginStorage =>
      $$PluginStorageTableTableManager(_db.attachedDatabase, _db.pluginStorage);
  $$PluginSecretsTableTableManager get pluginSecrets =>
      $$PluginSecretsTableTableManager(_db.attachedDatabase, _db.pluginSecrets);
  $$PluginPermissionsTableTableManager get pluginPermissions =>
      $$PluginPermissionsTableTableManager(
        _db.attachedDatabase,
        _db.pluginPermissions,
      );
}

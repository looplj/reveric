// dart format width=80
// ignore_for_file: type=lint
part of 'plugin_task_dao.dart';

mixin _$PluginTaskDaoMixin on DatabaseAccessor<AppDatabase> {
  $PluginTasksTable get pluginTasks => attachedDatabase.pluginTasks;
  PluginTaskDaoManager get managers => PluginTaskDaoManager(this);
}

class PluginTaskDaoManager {
  final _$PluginTaskDaoMixin _db;
  PluginTaskDaoManager(this._db);
  $$PluginTasksTableTableManager get pluginTasks =>
      $$PluginTasksTableTableManager(_db.attachedDatabase, _db.pluginTasks);
}

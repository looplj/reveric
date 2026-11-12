// 职责: 应用初始化任务执行器 — Orchestrator + Onboarding helpers
// 关联文件:
//   lib/shared/services/initialization/task.dart
//   lib/shared/services/initialization/agent_seeds.dart
//   lib/shared/services/initialization/demo_screenplay.dart
//   lib/shared/services/demo_novel.dart
//   lib/shared/database/app_database.dart
//   lib/shared/logger/app_logger.dart
//   lib/shared/logger/startup_failure_reporter.dart
import 'dart:async';

import '../logger/app_logger.dart';
import '../logger/startup_failure_reporter.dart';
import '../database/app_database.dart';
import 'demo_novel.dart';
import 'initialization/agent_seeds.dart';
import 'initialization/collection_seeds.dart';
import 'initialization/demo_screenplay.dart';
import 'initialization/shortcut_action_seeds.dart';
import 'initialization/task.dart';
import 'initialization/provider_seeds.dart';

final _log = AppLogger.forModule('AppInit');

const _appInitializationKeyPrefix = 'app_initialization.';

const appStateKeyOnboardingCompleted = 'onboarding_completed';
const appStateKeyChatOnboardingShown = 'chat_onboarding_shown';

Future<void>? _initLock;

List<AppInitializationTask> defaultAppInitializationTasks() {
  return const [
    AppInitializationTask(
      id: 'default_collections_v1',
      run: seedDefaultCollections,
    ),
    AppInitializationTask(
      id: 'remove_unscoped_collections_v1',
      run: removeUnscopedCollections,
    ),
    AppInitializationTask(
      id: 'kind_status_collections_v1',
      run: seedKindStatusCollections,
    ),
    AppInitializationTask(
      id: 'default_third_party_providers_v1',
      run: seedDefaultThirdPartyProviders,
    ),
    AppInitializationTask(
      id: 'default_metaso_provider_v1',
      run: seedDefaultMetasoProvider,
    ),
    AppInitializationTask(
      id: 'default_api88_provider_v1',
      run: seedDefaultApi88Provider,
    ),
    AppInitializationTask(
      id: 'default_apikey_provider_v1',
      run: seedDefaultApikeyProvider,
    ),
    AppInitializationTask(
      id: 'default_global_agents_v1',
      run: seedDefaultGlobalAgents,
    ),
    AppInitializationTask(
      id: 'default_ai_shortcut_actions_v1',
      run: seedDefaultAiShortcutActions,
    ),
    AppInitializationTask(id: 'demo_works_v1', run: _seedDemoWorks),
  ];
}

/// 示例小说与示例剧本作为一项初始化任务写入；两者各自按标题去重。
Future<void> _seedDemoWorks(AppDatabase database) async {
  await createDemoNovel(database);
  await seedDemoScreenplay(database);
}

Future<void> ensureAppInitializationTasks({
  required AppDatabase database,
  required List<AppInitializationTask> tasks,
}) async {
  while (_initLock != null) {
    await _initLock;
  }
  final completer = Completer<void>();
  _initLock = completer.future;
  try {
    // 单次批量查询所有初始化完成记录
    final completedKeys = await database.appStateDao.getAllByPrefix(
      _appInitializationKeyPrefix,
    );
    for (final task in tasks) {
      final settingKey = '$_appInitializationKeyPrefix${task.id}';
      final completedAt = completedKeys[settingKey];
      if (completedAt != null && completedAt.isNotEmpty) {
        if (_log.isDebugEnabled) {
          _log.debug('skip task=${task.id} completedAt=$completedAt');
        }
        continue;
      }
      _log.info('run task=${task.id}');
      try {
        await task.run(database);
        await database.appStateDao.set(
          key: settingKey,
          value: DateTime.now().toIso8601String(),
        );
      } catch (error, stackTrace) {
        _log.error(
          'failed task=${task.id} error=$error',
          error: error,
          stackTrace: stackTrace,
        );
        await StartupFailureReporter().report(
          phase: 'app_initialization_${task.id}',
          error: error,
          stackTrace: stackTrace,
        );
        continue;
      }
      _log.info('complete task=${task.id}');
    }
  } finally {
    completer.complete();
    _initLock = null;
  }
}

Future<bool> hasCompletedOnboarding(AppDatabase database) async {
  _log.info('hasCompletedOnboarding START');
  final result = await database.appStateDao.has(appStateKeyOnboardingCompleted);
  _log.info('hasCompletedOnboarding result=$result');
  return result;
}

Future<void> markOnboardingCompleted(AppDatabase database) async {
  await database.appStateDao.set(
    key: appStateKeyOnboardingCompleted,
    value: DateTime.now().toIso8601String(),
  );
}

Future<void> clearOnboardingAndFeatureUsageRecords(AppDatabase database) async {
  try {
    await database.transaction(() async {
      await database.appStateDao.remove(appStateKeyOnboardingCompleted);
      await database.appStateDao.remove(appStateKeyChatOnboardingShown);
      await database.delete(database.featureUsages).go();
    });
  } catch (error, stackTrace) {
    _log.error(
      '[DB] table=app_states,feature_usages operation=DELETE '
      'id=$appStateKeyOnboardingCompleted,'
      '$appStateKeyChatOnboardingShown,all_feature_usages error=$error',
      error: error,
      stackTrace: stackTrace,
    );
    rethrow;
  }
}

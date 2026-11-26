// 职责: 在应用启动时连接官方技能安装、升级与退役卸载，并持久记录已处理身份。
// 关联文件:
//   lib/shared/services/official_skill_sync.dart
//   lib/shared/providers/agent_skill_catalog_providers.dart
//   lib/shared/providers/novel_agent_skill_providers.dart
//   lib/shared/database/daos/app_state_dao.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/error-handling.md

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logger/app_logger.dart';
import '../services/official_skill_sync.dart';
import 'agent_skill_catalog_providers.dart';
import 'async_read.dart';
import 'novel_agent_skill_providers.dart';

final _log = AppLogger.forModule('OfficialSkillSync');
const _handledKeyPrefix = 'official_skill_sync.handled.';

/// 应用级单实例；启动和引导页共用一次执行，页面离开后仍继续同步。
/// 只有轻量结果常驻。失败由结果或 AsyncError 暴露，下次启动重试。
final officialSkillSyncProvider = FutureProvider<OfficialSkillSyncResult>((
  ref,
) async {
  final database = ref.read(agentSkillAppDatabaseProvider);
  return OfficialSkillSyncOrchestrator().run(
    loadInstalledSkills: () => ref.read(installedAgentSkillsProvider.future),
    loadOfficialCatalog: () async =>
        (await ref.read(officialAgentSkillCatalogProvider.future)).agentSkills,
    loadHandledNames: () async {
      final records = await database.appStateDao.getAllByPrefix(
        _handledKeyPrefix,
      );
      return {
        for (final key in records.keys)
          if (key.startsWith(_handledKeyPrefix))
            key.substring(_handledKeyPrefix.length),
      };
    },
    markHandled: (name) async {
      final key = '$_handledKeyPrefix$name';
      try {
        await database.appStateDao.set(
          key: key,
          value: DateTime.now().toUtc().toIso8601String(),
        );
      } catch (error, stackTrace) {
        _log.error(
          '[DB] UPSERT app_states failed key=$key',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
    },
    loadOfficialSkill: (listingId) =>
        ref.readFuture(officialAgentSkillDetailProvider(listingId).future),
    installOfficialSkill: (source) async {
      final result = await ref
          .read(installedAgentSkillsProvider.notifier)
          .installFromOfficial(source: source);
      return switch (result) {
        InstallFromCatalogSuccess() => true,
        InstallFromCatalogConflict() => false,
      };
    },
    uninstallOfficialSkill: (id) async {
      try {
        await ref.read(installedAgentSkillsProvider.notifier).remove(id);
      } catch (error, stackTrace) {
        _log.error(
          'Failed to uninstall retired skill id=$id',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
    },
    upgradeOfficialSkill: (id) async {
      final result = await ref
          .read(installedAgentSkillsProvider.notifier)
          .upgradeNovelAgentSkill(novelAgentSkillId: id);
      if (result is! UpgradeSuccess && result is! AlreadyLatestVersion) {
        throw StateError(
          'Official skill upgrade did not complete: $id ($result)',
        );
      }
    },
  );
}, retry: (retryCount, error) => null);

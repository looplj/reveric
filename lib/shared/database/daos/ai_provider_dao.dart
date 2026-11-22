// 职责: AI Provider 数据访问对象 — 封装所有 AI Provider 相关的数据库操作
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/models/ai_provider.dart

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../../logger/app_logger.dart';
import '../../models/ai_provider.dart';

part 'ai_provider_dao.drift.dart';

final _log = AppLogger.forModule('AiProviderDao');

@DriftAccessor(tables: [AiProviders])
class AiProviderDao extends DatabaseAccessor<AppDatabase>
    with _$AiProviderDaoMixin {
  AiProviderDao(super.db);

  Future<List<AiProvider>> getAll() async {
    return await (select(aiProviders)
          ..where((table) => table.deletedAt.equals(notDeletedSentinel))
          ..orderBy([
            (table) => OrderingTerm(
              expression: table.updatedAt,
              mode: OrderingMode.asc,
            ),
          ]))
        .get();
  }

  Stream<List<AiProvider>> watchAll() =>
      (select(aiProviders)
            ..where((table) => table.deletedAt.equals(notDeletedSentinel))
            ..orderBy([(table) => OrderingTerm.asc(table.updatedAt)]))
          .watch();

  Future<AiProvider?> getById(String id) async {
    return await (select(aiProviders)..where(
          (table) =>
              table.id.equals(id) & table.deletedAt.equals(notDeletedSentinel),
        ))
        .getSingleOrNull();
  }

  Future<void> upsert(AiProvider provider) async {
    try {
      await transaction(() async {
        final previous = await getById(provider.id);
        if (previous != null &&
            (previous.apiKey != provider.apiKey ||
                previous.effectiveBaseUrl.trim().replaceFirst(
                      RegExp(r'/+$'),
                      '',
                    ) !=
                    provider.effectiveBaseUrl.trim().replaceFirst(
                      RegExp(r'/+$'),
                      '',
                    ) ||
                previous.type != provider.type)) {
          await attachedDatabase.generationTaskDao.pauseForProvider(
            provider.id,
          );
        }
        await into(aiProviders).insertOnConflictUpdate(
          AiProvidersCompanion(
            id: Value(provider.id),
            name: Value(provider.name),
            builtin: Value(provider.builtin),
            type: Value(provider.type),
            enabled: Value(provider.enabled),
            apiKey: Value(provider.apiKey),
            baseUrl: Value(provider.baseUrl),
            models: Value(provider.models),
            imageModels: Value(provider.imageModels),
            videoModels: Value(provider.videoModels),
            audioModels: Value(provider.audioModels),
            asrModels: Value(provider.asrModels),
            embeddingModels: Value(provider.embeddingModels),
            temperature: Value(provider.temperature),
            config: Value(provider.config),
            maxTurns: Value(provider.maxTurns),
            reasoningEffort: Value(provider.reasoningEffort),
            proxyUrl: Value(provider.proxyUrl),
            proxyUsername: Value(provider.proxyUsername),
            proxyPassword: Value(provider.proxyPassword),
            accessKeyId: Value(provider.accessKeyId),
            secretAccessKey: Value(provider.secretAccessKey),
            assetProjectName: Value(provider.assetProjectName),
            updatedAt: Value(DateTime.now()),
          ),
        );
      });
    } catch (error, stackTrace) {
      _log.error(
        '[DB] ai_providers INSERT/UPDATE id=${provider.id}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<List<AiProvider>> getAllIncludingDeleted() =>
      select(aiProviders).get();

  /// 更新现有配置，保留不在列表中的记录及其软删除状态。
  Future<void> saveAll(List<AiProvider> providers) async {
    await transaction(() async {
      for (final provider in providers) {
        await upsert(provider);
      }
    });
  }

  Future<int> softDelete(String id) async {
    try {
      return await (update(
        aiProviders,
      )..where((table) => table.id.equals(id))).write(
        AiProvidersCompanion(
          deletedAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] ai_providers UPDATE softDelete id=$id',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<int> restore(String id) async {
    try {
      return await (update(
        aiProviders,
      )..where((table) => table.id.equals(id))).write(
        AiProvidersCompanion(
          deletedAt: Value(notDeletedSentinel),
          updatedAt: Value(DateTime.now()),
        ),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] ai_providers UPDATE restore id=$id',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<int> hardDelete(String id) async {
    return (delete(aiProviders)..where((table) => table.id.equals(id))).go();
  }
}

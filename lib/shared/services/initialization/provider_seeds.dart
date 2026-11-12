// 职责: 一次性预置第三方供应商，保留已有配置与软删除记录。
// 关联文件:
//   lib/shared/services/app_initialization.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/database/daos/ai_provider_dao.dart
import '../../database/app_database.dart';
import '../../models/ai_provider.dart';

Future<void> seedDefaultThirdPartyProviders(AppDatabase database) async {
  const ids = ['deepseek'];
  await database.transaction(() async {
    final existingIds = (await database.aiProviderDao.getAllIncludingDeleted())
        .map((provider) => provider.id)
        .toSet();
    for (final id in ids) {
      if (!existingIds.contains(id)) {
        await database.aiProviderDao.upsert(aiProviderBuiltinById(id)!);
      }
    }
  });
}

Future<void> seedDefaultApi88Provider(AppDatabase database) async {
  await database.transaction(() async {
    final existing = await database.aiProviderDao.getAllIncludingDeleted();
    if (existing.any((provider) => provider.id == 'api88')) {
      return;
    }
    await database.aiProviderDao.upsert(aiProviderBuiltinById('api88')!);
  });
}

Future<void> seedDefaultMetasoProvider(AppDatabase database) async {
  await database.transaction(() async {
    final existing = await database.aiProviderDao.getAllIncludingDeleted();
    if (existing.any((provider) => provider.id == 'metaso')) {
      return;
    }
    await database.aiProviderDao.upsert(aiProviderBuiltinById('metaso')!);
  });
}

Future<void> seedDefaultApikeyProvider(AppDatabase database) async {
  await database.transaction(() async {
    final existing = await database.aiProviderDao.getAllIncludingDeleted();
    if (existing.any((provider) => provider.id == 'apikey')) {
      return;
    }
    await database.aiProviderDao.upsert(aiProviderBuiltinById('apikey')!);
  });
}

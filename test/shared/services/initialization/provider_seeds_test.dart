// 职责: 验证第三方供应商种子只执行一次，并保留已有配置与删除记录。
// 关联文件:
//   lib/shared/services/initialization/provider_seeds.dart
//   lib/shared/services/app_initialization.dart
//   lib/shared/database/daos/ai_provider_dao.dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/services/app_initialization.dart';
import 'package:reveric/shared/services/initialization/provider_seeds.dart';

void main() {
  late AppDatabase database;
  setUp(() => database = AppDatabase.forTest(NativeDatabase.memory()));
  tearDown(() => database.close());

  test('Infistar has no automatic initialization task', () {
    expect(
      defaultAppInitializationTasks().map((task) => task.id),
      isNot(contains('default_infistar_provider_v1')),
    );
    expect(aiProviderBuiltinById('infistar'), isNull);
  });

  test(
    'seeds only DeepSeek once and never recreates deleted providers',
    () async {
      final tasks = defaultAppInitializationTasks()
          .where((task) => task.id == 'default_third_party_providers_v1')
          .toList();
      expect(tasks, hasLength(1));
      await ensureAppInitializationTasks(database: database, tasks: tasks);
      expect(
        (await database.aiProviderDao.getAll()).map((p) => p.id),
        unorderedEquals(['deepseek']),
      );
      const key = 'app_initialization.default_third_party_providers_v1';
      final completedAt = await database.appStateDao.get(key);
      expect(completedAt, isNotNull);
      await database.aiProviderDao.softDelete('deepseek');
      await ensureAppInitializationTasks(database: database, tasks: tasks);
      expect(await database.appStateDao.get(key), completedAt);
      expect(await database.aiProviderDao.getById('deepseek'), isNull);
      expect(
        await database.aiProviderDao.getAllIncludingDeleted(),
        hasLength(1),
      );
    },
  );

  test(
    '88API is seeded after DeepSeek initialization and stays deleted',
    () async {
      await database.appStateDao.set(
        key: 'app_initialization.default_third_party_providers_v1',
        value: 'done',
      );
      final tasks = defaultAppInitializationTasks()
          .where((task) => task.id == 'default_api88_provider_v1')
          .toList();
      expect(tasks, hasLength(1));
      await ensureAppInitializationTasks(database: database, tasks: tasks);
      final provider = (await database.aiProviderDao.getById('api88'))!;
      expect(provider.type, 'api88');
      expect(provider.name, '88API');
      expect(provider.effectiveBaseUrl, 'https://api.88api.ai/v1');
      expect(provider.enabled, false);
      expect(provider.apiKey, isEmpty);
      expect(provider.models, isEmpty);
      expect(provider.canDelete, true);
      await database.aiProviderDao.softDelete(provider.id);
      await ensureAppInitializationTasks(database: database, tasks: tasks);
      await seedDefaultApi88Provider(database);
      expect(await database.aiProviderDao.getById(provider.id), isNull);
      expect(
        await database.aiProviderDao.getAllIncludingDeleted(),
        hasLength(1),
      );
    },
  );

  test('APIKEY seed preserves edits and deletion and follows 88API', () async {
    final tasks = defaultAppInitializationTasks()
        .where((task) => task.id == 'default_apikey_provider_v1')
        .toList();
    expect(tasks, hasLength(1));
    await ensureAppInitializationTasks(database: database, tasks: tasks);
    final provider = (await database.aiProviderDao.getById('apikey'))!;
    expect(provider.enabled, false);
    expect(provider.apiKey, isEmpty);
    expect(provider.models, isEmpty);
    expect(provider.canDelete, true);
    expect(provider.supportedModelKinds, {AiModelKind.chat});
    expect(provider.effectiveBaseUrl, 'https://api.apikey.fan/v1');
    final ordered = AiSettings.mergeWithRequiredProviders([
      provider,
      aiProviderBuiltinById('deepseek')!,
      aiProviderBuiltinById('metaso')!,
      aiProviderBuiltinById('api88')!,
    ]);
    expect(ordered.map((p) => p.id), ['metaso', 'api88', 'apikey', 'deepseek']);
    await database.aiProviderDao.upsert(
      provider.copyWith(
        apiKey: 'user-key',
        models: ['gpt-6.1-sol'],
        enabled: true,
      ),
    );
    await seedDefaultApikeyProvider(database);
    final edited = (await database.aiProviderDao.getById('apikey'))!;
    expect(edited.apiKey, 'user-key');
    expect(edited.models, ['gpt-6.1-sol']);
    expect(edited.enabled, true);
    await database.aiProviderDao.softDelete('apikey');
    await seedDefaultApikeyProvider(database);
    await ensureAppInitializationTasks(database: database, tasks: tasks);
    expect(await database.aiProviderDao.getById('apikey'), isNull);
    expect(await database.aiProviderDao.getAllIncludingDeleted(), hasLength(1));
  });

  test(
    'METASO seed supplies video models once and preserves user configuration',
    () async {
      final tasks = defaultAppInitializationTasks()
          .where((task) => task.id == 'default_metaso_provider_v1')
          .toList();
      expect(tasks, hasLength(1));
      await ensureAppInitializationTasks(database: database, tasks: tasks);
      final provider = (await database.aiProviderDao.getById('metaso'))!;
      expect(provider.enabled, false);
      expect(provider.apiKey, isEmpty);
      expect(provider.videoModels, [
        'MiniMax-H3',
        'MiniMax-H3-priority',
        'seedance-2.0',
        'seedance-2.0-mini',
      ]);
      await database.aiProviderDao.upsert(
        provider.copyWith(
          apiKey: 'user-key',
          enabled: true,
          videoModels: ['MiniMax-H3'],
        ),
      );
      await seedDefaultMetasoProvider(database);
      expect(
        (await database.aiProviderDao.getById('metaso'))!.apiKey,
        'user-key',
      );
      expect((await database.aiProviderDao.getById('metaso'))!.videoModels, [
        'MiniMax-H3',
      ]);
      await database.aiProviderDao.softDelete('metaso');
      await seedDefaultMetasoProvider(database);
      expect(await database.aiProviderDao.getById('metaso'), isNull);
    },
  );

  for (final deleted in [false, true]) {
    test(
      '88API seed uses its fixed ID independently of custom providers, deleted=$deleted',
      () async {
        final existing = aiProviderBuiltinById('api88')!.copyWith(
          id: 'custom-api88',
          builtin: false,
          apiKey: 'existing-key',
          models: ['selected-model'],
          enabled: true,
        );
        await database.aiProviderDao.upsert(existing);
        if (deleted) {
          await database.aiProviderDao.softDelete(existing.id);
        }
        await seedDefaultApi88Provider(database);
        await seedDefaultApi88Provider(database);
        final providers = await database.aiProviderDao.getAllIncludingDeleted();
        expect(providers, hasLength(2));
        expect(await database.aiProviderDao.getById('api88'), isNotNull);
        final custom = providers.singleWhere(
          (provider) => provider.id == existing.id,
        );
        expect(custom.apiKey, existing.apiKey);
        expect(custom.models, existing.models);
        expect(custom.enabled, true);
        expect(
          await database.aiProviderDao.getById(existing.id),
          deleted ? isNull : isNotNull,
        );
      },
    );
  }

  test(
    'upgrade and retry preserve edits, custom providers and tombstones',
    () async {
      final configured = aiProviderBuiltinById(
        'deepseek',
      )!.copyWith(apiKey: 'test-key', models: ['my-model']);
      final custom = configured.copyWith(id: 'custom', builtin: false);
      await database.aiProviderDao.upsert(configured);
      await database.aiProviderDao.upsert(custom);
      await database.aiProviderDao.upsert(aiProviderBuiltinById('openai')!);
      await database.aiProviderDao.softDelete('openai');
      await seedDefaultThirdPartyProviders(database);
      await seedDefaultThirdPartyProviders(database);
      expect(
        (await database.aiProviderDao.getById('deepseek'))!.apiKey,
        'test-key',
      );
      expect((await database.aiProviderDao.getById('deepseek'))!.models, [
        'my-model',
      ]);
      expect(await database.aiProviderDao.getById('custom'), isNotNull);
      expect(await database.aiProviderDao.getById('openai'), isNull);
      await database.aiProviderDao.saveAll(
        await database.aiProviderDao.getAll(),
      );
      expect(
        await database.aiProviderDao.getAllIncludingDeleted(),
        hasLength(3),
      );
      expect(await database.aiProviderDao.getById('openai'), isNull);
    },
  );
}

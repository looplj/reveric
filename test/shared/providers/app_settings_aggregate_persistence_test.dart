// 职责: 验证 AppSettingsNotifier 按领域 JSON 读写非编辑器设置，并保持运行状态独立。
// 关联文件:
//   lib/shared/providers/settings_providers.dart
//   lib/shared/models/app_settings_aggregate_data.dart
//   lib/shared/database/app_database.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/testing.md

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart' show Brightness;
import 'package:reveric/desktop/widgets/workspace/chapter_outline_window.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/network_proxy.dart';
import 'package:reveric/shared/models/app_settings_aggregate_data.dart';
import 'package:reveric/shared/models/webdav_backup_config.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/initialization/provider_seeds.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'proxy defaults to environment and persists custom settings across reloads',
    () async {
      final database = AppDatabase.forTest(NativeDatabase.memory());
      final container = _createContainer(database);
      addTearDown(() async {
        container.dispose();
        await database.close();
      });
      expect(
        (await container.read(appSettingsProvider.future)).networkProxy.mode,
        NetworkProxyMode.environment,
      );
      const custom = NetworkProxy(
        mode: NetworkProxyMode.custom,
        url: 'socks5://127.0.0.1:1080',
        username: 'user',
        password: 'secret',
      );
      await container
          .read(appSettingsProvider.notifier)
          .setNetworkProxy(custom);
      container.invalidate(appSettingsProvider);
      expect(
        (await container.read(
          appSettingsProvider.future,
        )).networkProxy.encode(),
        custom.encode(),
      );
      await expectLater(
        container
            .read(appSettingsProvider.notifier)
            .setNetworkProxy(
              const NetworkProxy(mode: NetworkProxyMode.custom, url: 'invalid'),
            ),
        throwsFormatException,
      );
      await expectLater(
        container
            .read(appSettingsProvider.notifier)
            .setNetworkProxy(
              NetworkProxy(
                mode: NetworkProxyMode.custom,
                url: custom.url,
                username: 'user',
              ),
            ),
        throwsFormatException,
      );
      expect(
        await database.appSettingsDao.get(NetworkProxy.settingsKey),
        custom.encode(),
      );
      await container
          .read(appSettingsProvider.notifier)
          .setNetworkProxy(
            NetworkProxy(mode: NetworkProxyMode.direct, url: custom.url),
          );
      container.invalidate(appSettingsProvider);
      final direct = (await container.read(
        appSettingsProvider.future,
      )).networkProxy;
      expect(direct.mode, NetworkProxyMode.direct);
      expect(direct.url, custom.url);
    },
  );

  test(
    'startup preserves unsupported AI provider data and selections',
    () async {
      final database = AppDatabase.forTest(NativeDatabase.memory());
      final container = _createContainer(database);
      addTearDown(() async {
        container.dispose();
        await database.close();
      });
      final unknown = aiProviderBuiltinById('openai')!.copyWith(
        id: 'saved-openrouter',
        name: 'OpenRouter',
        type: 'test_xxx',
        builtin: false,
        enabled: true,
        apiKey: 'test-key',
        models: ['saved-model'],
      );
      await database.aiProviderDao.upsert(unknown);
      final stored = await database.aiProviderDao.getById(unknown.id);
      final saved = AiSettings(
        defaultChatModelId: '${unknown.id}::saved-model',
        defaultChatReasoningEffort: 'high',
        defaultWriterModelId: '${unknown.id}::saved-model',
      );
      await database.appSettingsDao.set(
        key: 'ai_settings',
        value: jsonEncode(saved.toJson()),
      );
      final loaded = await container.read(appSettingsProvider.future);
      expect(loaded.aiSettings.toJson(), saved.toJson());
      expect(
        loaded.aiSettings.findConfigById(unknown.id)!.toJson(),
        stored!.toJson(),
      );
      expect(
        loaded.aiSettings.availableModelOptions.any(
          (option) => option.providerId == unknown.id,
        ),
        isFalse,
      );
      await container
          .read(appSettingsProvider.notifier)
          .setThemeMode(AppThemeMode.dark);
      container.invalidate(appSettingsProvider);
      final reloaded = await container.read(appSettingsProvider.future);
      expect(reloaded.aiSettings.toJson(), saved.toJson());
      expect(
        (await database.aiProviderDao.getById(unknown.id))!.toJson(),
        stored.toJson(),
      );
      expect(
        jsonDecode((await database.appSettingsDao.get('ai_settings'))!),
        saved.toJson(),
      );
    },
  );

  test(
    'concurrent AI apply, mode and background changes preserve theme selection',
    () async {
      final database = AppDatabase.forTest(NativeDatabase.memory());
      final container = _createContainer(database);
      addTearDown(() async {
        container.dispose();
        await database.close();
      });
      await container.read(appSettingsProvider.future);
      final notifier = container.read(appSettingsProvider.notifier);
      final theme = await notifier.runThemeCommand({
        'action': 'create',
        'name': 'Forest',
        'baseTheme': 'reveric',
      });
      final id = theme['id'];
      await Future.wait([
        notifier.runThemeCommand({'action': 'apply', 'id': id}),
        notifier.setThemeMode(AppThemeMode.dark),
        notifier.setAppBackgroundImagePath('paper.png'),
      ]);
      final updates = await Future.wait([
        notifier.runThemeCommand({
          'action': 'update',
          'id': id,
          'revision': 1,
          'name': 'First',
        }),
        notifier.runThemeCommand({
          'action': 'update',
          'id': id,
          'revision': 1,
          'name': 'Second',
        }),
      ]);
      expect(updates.map((r) => r['ok']), [true, false]);
      container.invalidate(appSettingsProvider);
      final saved = await container.read(appSettingsProvider.future);
      expect(saved.customTheme?.id, id);
      expect(saved.customTheme?.name, 'First');
      expect(saved.themeMode, AppThemeMode.dark);
      expect(saved.appBackgroundImagePath, 'paper.png');
    },
  );

  test(
    'AI theme changes render immediately, survive restart and exit to the same built-in',
    () async {
      final database = AppDatabase.forTest(NativeDatabase.memory());
      final container = _createContainer(database);
      addTearDown(() async {
        container.dispose();
        await database.close();
      });
      await container.read(appSettingsProvider.future);
      final notifier = container.read(appSettingsProvider.notifier);
      final created = await notifier.runThemeCommand({
        'action': 'create',
        'name': 'Forest',
        'baseTheme': 'reveric',
        'lightOverrides': {'accent': '#245C42', 'onAccent': '#FFFFFF'},
        'darkOverrides': {'accent': '#A4CBA6', 'onAccent': '#172118'},
      });
      expect(created['ok'], isTrue, reason: '$created');
      final id = created['id'];
      await notifier.runThemeCommand({
        'action': 'apply',
        'id': id,
        'themeMode': 'system',
      });
      final settings = container.read(appSettingsProvider).requireValue;
      expect(settings.customTheme?.id, id);
      expect(
        settings
            .themeDataForBrightness(Brightness.light)
            .colors
            .accent
            .toARGB32(),
        0xFF245C42,
      );
      expect(
        settings
            .themeDataForBrightness(Brightness.dark)
            .colors
            .accent
            .toARGB32(),
        0xFFA4CBA6,
      );
      final detached = ChapterOutlineWindowAppearance(
        theme: settings.theme,
        themeMode: settings.themeMode,
        customBaseTheme: settings.customTheme!.baseTheme,
        lightOverrides: settings.customTheme!.lightOverrides,
        darkOverrides: settings.customTheme!.darkOverrides,
        fontFamily: 'Georgia',
        fontSize: 16,
        letterSpacing: 0,
        lineHeight: 1.8,
      );
      expect(
        detached.themeDataForBrightness(Brightness.dark).colors.accent,
        settings.themeDataForBrightness(Brightness.dark).colors.accent,
      );
      await notifier.runThemeCommand({
        'action': 'update',
        'id': id,
        'revision': 1,
        'lightOverrides': {'accent': '#28543D'},
      });
      expect(
        container
            .read(appSettingsProvider)
            .requireValue
            .themeData
            .colors
            .accent
            .toARGB32(),
        0xFF28543D,
      );
      await notifier.setThemeMode(AppThemeMode.dark);
      container.invalidate(appSettingsProvider);
      final reloaded = await container.read(appSettingsProvider.future);
      expect(reloaded.customTheme?.id, id);
      expect(reloaded.customTheme?.revision, 2);
      expect(reloaded.themeMode, AppThemeMode.dark);
      await container
          .read(appSettingsProvider.notifier)
          .setTheme(AppTheme.reveric);
      expect(
        container.read(appSettingsProvider).requireValue.customTheme,
        isNull,
      );
      container.invalidate(appSettingsProvider);
      expect(
        (await container.read(appSettingsProvider.future)).customTheme,
        isNull,
      );
    },
  );

  test('fresh settings default to classic and keep a saved reveric', () async {
    final database = AppDatabase.forTest(NativeDatabase.memory());
    final container = _createContainer(database);
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    expect(
      (await container.read(appSettingsProvider.future)).theme,
      AppTheme.classic,
    );
    await container
        .read(appSettingsProvider.notifier)
        .setTheme(AppTheme.reveric);
    container.invalidate(appSettingsProvider);
    expect(
      (await container.read(appSettingsProvider.future)).theme,
      AppTheme.reveric,
    );
  });

  test('failed deletion keeps the provider in settings state', () async {
    final database = AppDatabase.forTest(NativeDatabase.memory());
    final container = _createContainer(database);
    addTearDown(container.dispose);
    await seedDefaultThirdPartyProviders(database);
    await container.read(appSettingsProvider.future);
    await database.close();
    await expectLater(
      container.read(appSettingsProvider.notifier).removeProvider('deepseek'),
      throwsA(isA<StateError>()),
    );
    expect(
      container
          .read(appSettingsProvider)
          .requireValue
          .aiSettings
          .findConfigById('deepseek'),
      isNotNull,
    );
  });

  test('deletion survives config changes and settings reload', () async {
    final database = AppDatabase.forTest(NativeDatabase.memory());
    final container = _createContainer(database);
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    await seedDefaultThirdPartyProviders(database);
    await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);
    final deepseek = aiProviderBuiltinById(
      'deepseek',
    )!.copyWith(enabled: true, apiKey: 'test-key', models: ['test-model']);
    await notifier.setAiProviderConfig(deepseek);
    await notifier.setDefaultAiModelForKind(
      AiModelKind.chat,
      'deepseek::test-model',
    );
    await notifier.removeProvider('deepseek');
    expect(
      container
          .read(appSettingsProvider)
          .requireValue
          .aiSettings
          .defaultChatModelId,
      isNull,
    );
    await notifier.setAiProviderConfig(
      aiProviderBuiltinById('openai')!.copyWith(temperature: 0.4),
    );
    await notifier.addCustomProvider(
      deepseek.copyWith(id: 'custom', builtin: false),
    );
    await notifier.removeProvider('custom');
    await notifier.removeProvider('reveric');
    container.invalidate(appSettingsProvider);
    final reloaded = await container.read(appSettingsProvider.future);
    expect(reloaded.aiSettings.findConfigById('deepseek'), isNull);
    expect(reloaded.aiSettings.findConfigById('custom'), isNull);
    expect(reloaded.aiSettings.findConfigById('reveric'), isNull);
    expect(reloaded.aiSettings.findConfigById('public_welfare'), isNull);
    expect(reloaded.aiSettings.findConfigById('openai')!.temperature, 0.4);
    final deleted = (await database.aiProviderDao.getAllIncludingDeleted())
        .where((p) => p.id == 'deepseek' || p.id == 'custom');
    expect(deleted, hasLength(2));
    expect(deleted.every((p) => p.deletedAt != notDeletedSentinel), isTrue);
  });

  test('settings loading does not recreate removed hosted providers', () async {
    final database = AppDatabase.forTest(NativeDatabase.memory());
    final container = _createContainer(database);
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    final loaded = await container.read(appSettingsProvider.future);
    expect(loaded.aiSettings.providers.map((p) => p.id), isEmpty);
    container.invalidate(appSettingsProvider);
    final reloaded = await container.read(appSettingsProvider.future);
    expect(reloaded.aiSettings.providers.map((p) => p.id), isEmpty);
    expect((await database.aiProviderDao.getAll()).map((p) => p.id), isEmpty);
  });

  test('normalizes persisted setting submissions', () async {
    expect(
      StorageSettingsData.fromJson({
        'changeRecordRetentionDays': 400,
      }).changeRecordRetentionDays,
      365,
    );
    final database = AppDatabase.forTest(NativeDatabase.memory());
    final container = _createContainer(database);
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    await container.read(appSettingsProvider.future);
    await container
        .read(appSettingsProvider.notifier)
        .setChangeRecordRetentionDays(6);
    expect(
      container
          .read(appSettingsProvider)
          .requireValue
          .changeRecordRetentionDays,
      7,
    );
    final saved = await database.appSettingsDao.get(
      StorageSettingsData.appSettingsKey,
    );
    expect(StorageSettingsData.decode(saved!).changeRecordRetentionDays, 7);
  });

  test('writes recommended settings only to their aggregate keys', () async {
    final database = AppDatabase.forTest(NativeDatabase.memory());
    final container = _createContainer(database);
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);
    await notifier.setReadingFontSize(24);
    await notifier.setTheme(AppTheme.classic);
    await notifier.setAppBackgroundFit(AppBackgroundFit.contain);
    await notifier.setMemoryAutoExtract(false);
    await notifier.setAiAgentIdentity('Custom identity');
    await notifier.setBackupDirectory('/tmp/backups');
    await notifier.setBackupFrequency(BackupFrequency.weekly);
    await notifier.setBackupWeekdays(const <int>[
      DateTime.friday,
      DateTime.sunday,
    ]);
    await notifier.setBackupDayOfMonth(28);
    await notifier.setBackupTime(hour: 23, minute: 45);
    await notifier.setWebDavBackupConfig(
      const WebDavBackupConfig(
        enabled: true,
        serverUrl: 'https://dav.example.com/root',
        username: 'author',
        password: 'secret',
        remoteDirectory: '/Reveric/Test',
      ),
    );
    await notifier.setUsername('Author');
    await notifier.setDebugMode(true);

    final reading = ReadingSettingsData.decode(
      (await database.appSettingsDao.get(ReadingSettingsData.appSettingsKey))!,
      fallback: ReadingSettingsData.defaultsForLanguage('zh_CN'),
    );
    expect(reading.fontSize, 24);

    final appearance = AppearanceSettingsData.decode(
      (await database.appSettingsDao.get(
        AppearanceSettingsData.appSettingsKey,
      ))!,
    );
    expect(appearance.theme, 'classic');
    expect(appearance.backgroundFit, 'contain');

    final memory = MemorySettingsData.decode(
      (await database.appSettingsDao.get(MemorySettingsData.appSettingsKey))!,
    );
    expect(memory.autoExtract, isFalse);

    final aiAgent = AiAgentSettingsData.decode(
      (await database.appSettingsDao.get(AiAgentSettingsData.appSettingsKey))!,
    );
    expect(aiAgent.identity, 'Custom identity');

    final storageRaw = (await database.appSettingsDao.get(
      StorageSettingsData.appSettingsKey,
    ))!;
    final storage = StorageSettingsData.decode(storageRaw);
    expect(storage.backupDirectory, '/tmp/backups');
    expect(storage.backupFrequency, 'weekly');
    expect(storage.backupWeekdays, const <int>[
      DateTime.friday,
      DateTime.sunday,
    ]);
    expect(storage.backupDayOfMonth, 28);
    expect(storage.backupHour, 23);
    expect(storage.backupMinute, 45);
    expect(storage.webDavEnabled, isTrue);
    expect(storage.webDavServerUrl, 'https://dav.example.com/root/');
    expect(storage.webDavUsername, 'author');
    expect(storage.webDavRemoteDirectory, '/Reveric/Test');
    expect(storage.webDavPassword, 'secret');

    final profile = LocalProfileSettingsData.decode(
      (await database.appSettingsDao.get(
        LocalProfileSettingsData.appSettingsKey,
      ))!,
    );
    expect(profile.username, 'Author');

    final debugRaw = (await database.appSettingsDao.get(
      DebugSettingsData.appSettingsKey,
    ))!;
    final debug = DebugSettingsData.decode(debugRaw);
    expect(debug.debugMode, isTrue);

    const legacyKeys = [
      'reading_font_size',
      'app_theme',
      'memory_auto_extract',
      'ai_agent_identity',
      'backup_directory',
      'username',
      'debug_mode',
    ];
    for (final key in legacyKeys) {
      expect(await database.appSettingsDao.has(key), isFalse, reason: key);
    }

    final backupTime = DateTime(2026, 8, 4, 8);
    await notifier.setLastBackupTime(backupTime);
    expect(
      await database.appSettingsDao.get(StorageSettingsData.appSettingsKey),
      storageRaw,
    );
    expect(
      await database.appSettingsDao.get(DebugSettingsData.appSettingsKey),
      debugRaw,
    );
    expect(
      await database.appSettingsDao.get('last_backup_time'),
      backupTime.toIso8601String(),
    );
  });

  test('ignores obsolete domain keys when aggregates are absent', () async {
    final database = AppDatabase.forTest(NativeDatabase.memory());
    await database.appSettingsDao.set(key: 'reading_font_size', value: '23');
    await database.appSettingsDao.set(key: 'username', value: 'Legacy author');
    await database.appSettingsDao.set(key: 'app_theme_mode', value: 'dark');
    final container = _createContainer(database);
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    final settings = await container.read(appSettingsProvider.future);
    expect(
      settings.readingFontSize,
      ReadingSettingsData.defaultsForLanguage('zh_CN').fontSize,
    );
    expect(settings.username, LocalProfileSettingsData.defaults.username);
    expect(settings.themeMode.name, AppearanceSettingsData.defaults.themeMode);
  });

  test(
    'normalizes current backup days and ignores the obsolete singular field',
    () {
      final previous = StorageSettingsData.fromJson(const <String, dynamic>{
        'backupWeekday': DateTime.sunday,
      });
      final multiple = StorageSettingsData.fromJson(const <String, dynamic>{
        'backupWeekdays': <Object>[
          DateTime.friday,
          '${DateTime.tuesday}',
          DateTime.friday,
          99,
        ],
        'backupDayOfMonth': 28,
      });
      final invalidDay = StorageSettingsData.fromJson(const <String, dynamic>{
        'backupDayOfMonth': 29,
      });

      expect(
        previous.backupWeekdays,
        StorageSettingsData.defaults.backupWeekdays,
      );
      expect(previous.backupDayOfMonth, 1);
      expect(multiple.backupWeekdays, const <int>[
        DateTime.tuesday,
        DateTime.friday,
      ]);
      expect(multiple.backupDayOfMonth, 28);
      expect(invalidDay.backupDayOfMonth, 1);
    },
  );

  test(
    'ui text scale persists to the appearance aggregate and reloads',
    () async {
      final database = AppDatabase.forTest(NativeDatabase.memory());
      final container = _createContainer(database);
      addTearDown(() async {
        container.dispose();
        await database.close();
      });
      final loaded = await container.read(appSettingsProvider.future);
      expect(loaded.uiTextScale, 1.0);

      await container.read(appSettingsProvider.notifier).setUiTextScale(1.3);
      expect(container.read(appSettingsProvider).requireValue.uiTextScale, 1.3);
      final saved = await database.appSettingsDao.get(
        AppearanceSettingsData.appSettingsKey,
      );
      expect(AppearanceSettingsData.decode(saved!).uiTextScale, 1.3);

      container.invalidate(appSettingsProvider);
      final reloaded = await container.read(appSettingsProvider.future);
      expect(reloaded.uiTextScale, 1.3);
    },
  );

  test('normalizes out-of-range ui text scale values', () {
    expect(
      AppearanceSettingsData.fromJson(const {'uiTextScale': 99}).uiTextScale,
      2.0,
    );
    expect(
      AppearanceSettingsData.fromJson(const {
        'uiTextScale': 'not-a-number',
      }).uiTextScale,
      AppearanceSettingsData.defaults.uiTextScale,
    );
  });
}

ProviderContainer _createContainer(AppDatabase database) {
  return ProviderContainer(
    overrides: [appSettingsDatabaseProvider.overrideWithValue(database)],
  );
}

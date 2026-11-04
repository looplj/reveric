// 职责: 验证备份设置区的自动备份计划与 WebDAV 配置交互。
// 关联文件:
//   lib/shared/widgets/settings/backup_settings_section.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/models/app_settings_aggregate_data.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/components/reveric_select.dart';
import 'package:reveric/shared/components/reveric_switch.dart';
import 'package:reveric/shared/components/reveric_text_field.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/webdav_backup_config.dart';
import 'package:reveric/shared/models/app_settings_aggregate_data.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/providers/webdav_backup_providers.dart';
import 'package:reveric/shared/services/webdav_backup_service.dart';
import 'package:reveric/shared/services/webdav_transport.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/settings/backup_settings_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  setUp(() => rootBundle.clear());

  for (final platform in [TargetPlatform.macOS, TargetPlatform.android]) {
    testWidgets('disabling WebDAV persists without Save on $platform', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final database = AppDatabase.forTest(NativeDatabase.memory());
      await database.appSettingsDao.set(
        key: StorageSettingsData.appSettingsKey,
        value: const StorageSettingsData(
          changeRecordRetentionDays: 30,
          backupDirectory: '/tmp/backups',
          backupFrequency: 'manual',
          backupWeekdays: [1],
          backupDayOfMonth: 1,
          backupHour: 2,
          backupMinute: 0,
          webDavEnabled: true,
          webDavServerUrl: 'https://dav.example.com/',
          webDavUsername: 'author',
          webDavPassword: 'test-password',
        ).encode(),
      );
      final container = ProviderContainer(
        overrides: [
          appSettingsDatabaseProvider.overrideWithValue(database),
          webDavBackupServiceProvider.overrideWithValue(_TestWebDavService()),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });
      await container.read(appSettingsProvider.future);
      await tester.pumpWidget(
        _wrap(container, compact: platform == TargetPlatform.android),
      );
      await tester.pumpAndSettle();
      final actions = find.byKey(const ValueKey('backup_action_buttons'));
      final fileRestore = find.byKey(const ValueKey('file_restore_button'));
      final remoteRestore = find.byKey(const ValueKey('webdav_restore_button'));
      expect(
        find.descendant(of: actions, matching: remoteRestore),
        findsOneWidget,
      );
      expect(find.text('Restore from File'), findsOneWidget);
      expect(
        tester.getTopLeft(fileRestore).dy,
        tester.getTopLeft(remoteRestore).dy,
      );
      expect(
        tester.getTopLeft(remoteRestore).dx,
        greaterThan(tester.getTopRight(fileRestore).dx),
      );
      if (platform == TargetPlatform.android) {
        tester.view.physicalSize = const Size(390, 844);
        await tester.pumpAndSettle();
        final backup = find.descendant(
          of: actions,
          matching: find.byType(FilledButton),
        );
        expect(
          tester.getTopLeft(fileRestore).dy,
          greaterThan(tester.getTopLeft(backup).dy),
        );
        expect(tester.takeException(), isNull);
        final localization = EasyLocalization.of(tester.element(actions))!;
        await tester.runAsync(
          () => localization.setLocale(const Locale('zh', 'CN')),
        );
        await tester.pumpAndSettle();
        expect(find.text('从文件恢复'), findsOneWidget);
        expect(
          tester.getTopLeft(fileRestore).dy,
          tester.getTopLeft(remoteRestore).dy,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.ensureVisible(remoteRestore);
      await tester.tap(remoteRestore);
      await tester.pumpAndSettle();
      final back = find.byKey(const ValueKey('webdav_restore_back_button'));
      expect(back, findsOneWidget);
      await tester.tap(back);
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(1200, 1000);
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('webdav_enabled_switch'));
      expect(tester.widget<RevericSwitch>(toggle).value, isTrue);
      final saveButton = find.byKey(const ValueKey('webdav_save_button'));
      expect(saveButton, findsOneWidget);
      // Closing must not save an unfinished connection edit.
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('webdav_server_url_field')),
          matching: find.byType(TextField),
        ),
        'unfinished-url',
      );
      await tester.ensureVisible(toggle);
      final toggleRow = find.ancestor(
        of: toggle,
        matching: find.byType(ListTile),
      );
      await tester.tap(toggleRow);
      await tester.pumpAndSettle();
      final config = container
          .read(appSettingsProvider)
          .requireValue
          .webDavBackupConfig;
      expect(config.enabled, isFalse);
      expect(saveButton, findsNothing);
      expect(config.serverUrl, 'https://dav.example.com/');
      final stored = await tester.runAsync(
        () async => StorageSettingsData.decode(
          (await database.appSettingsDao.get(
            StorageSettingsData.appSettingsKey,
          ))!,
        ),
      );
      expect(stored!.webDavEnabled, isFalse);
      expect(stored.webDavServerUrl, 'https://dav.example.com/');
      // Reopening the page must retain the disabled state.
      await tester.pumpWidget(
        _wrap(
          container,
          sectionKey: const ValueKey('reopened'),
          compact: platform == TargetPlatform.android,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<RevericSwitch>(toggle).value, isFalse);
      expect(saveButton, findsNothing);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(saveButton, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('schedule shows frequency-specific controls and backup time', (
    tester,
  ) async {
    // flutter_test 默认 defaultTargetPlatform = android，而目录选择与自动备份是桌面能力。
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = AppDatabase.forTest(NativeDatabase.memory());
    await database.appSettingsDao.set(
      key: StorageSettingsData.appSettingsKey,
      value: const StorageSettingsData(
        changeRecordRetentionDays: 30,
        backupDirectory: '/tmp/backups',
        backupFrequency: 'weekly',
        backupWeekdays: <int>[DateTime.tuesday, DateTime.saturday],
        backupDayOfMonth: 1,
        backupHour: 21,
        backupMinute: 30,
      ).encode(),
    );
    final container = ProviderContainer(
      overrides: [appSettingsDatabaseProvider.overrideWithValue(database)],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    await container.read(appSettingsProvider.future);

    await tester.pumpWidget(_wrap(container));
    await tester.pumpAndSettle();

    expect(find.text('Local Backup Folder'), findsOneWidget);

    final retentionField = find.byKey(
      const ValueKey('change_record_retention_days_field'),
    );
    expect(retentionField, findsOneWidget);
    final retentionInput = tester.widget<RevericTextField>(retentionField);
    expect(retentionInput.controller?.text, '30');
    expect(retentionInput.keyboardType, TextInputType.number);
    await tester.enterText(
      find.byKey(const ValueKey('change_record_retention_days_input')),
      '45',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      container
          .read(appSettingsProvider)
          .requireValue
          .changeRecordRetentionDays,
      45,
    );

    await tester.enterText(
      find.byKey(const ValueKey('change_record_retention_days_input')),
      '1',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(retentionInput.controller?.text, '7');
    // 再次输入相同的越界值也必须纠正文本，不能依赖设置值发生变化。
    await tester.enterText(
      find.byKey(const ValueKey('change_record_retention_days_input')),
      '1',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(retentionInput.controller?.text, '7');

    // 不按回车，点到输入框外失焦也要保存。
    await tester.enterText(
      find.byKey(const ValueKey('change_record_retention_days_input')),
      '20',
    );
    await tester.pump();
    await tester.tap(find.text('Local Backup Folder'));
    await tester.pumpAndSettle();
    expect(
      container
          .read(appSettingsProvider)
          .requireValue
          .changeRecordRetentionDays,
      20,
    );

    final frequencyField = find.byKey(const ValueKey('backup_frequency_field'));
    expect(frequencyField, findsOneWidget);
    expect(
      tester.widget(frequencyField),
      isA<RevericSelect<BackupFrequency>>(),
    );
    expect(find.byKey(const ValueKey('backup_weekdays_field')), findsOneWidget);
    expect(find.byType(FilterChip), findsNWidgets(7));
    final selectedChips = tester
        .widgetList<FilterChip>(find.byType(FilterChip))
        .where((chip) => chip.selected);
    expect(selectedChips, hasLength(2));
    final hourField = find.byKey(const ValueKey('backup_hour_field'));
    final minuteField = find.byKey(const ValueKey('backup_minute_field'));
    expect(hourField, findsOneWidget);
    expect(minuteField, findsOneWidget);
    expect(tester.widget(hourField), isA<RevericSelect<int>>());
    expect(tester.widget(minuteField), isA<RevericSelect<int>>());

    final notifier = container.read(appSettingsProvider.notifier);
    await notifier.setBackupFrequency(BackupFrequency.monthly);
    await notifier.setBackupDayOfMonth(28);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('backup_weekdays_field')), findsNothing);
    final dayField = find.byKey(const ValueKey('backup_day_of_month_field'));
    expect(dayField, findsOneWidget);
    final daySelector = tester.widget<RevericSelect<int>>(dayField);
    expect(daySelector.value, 28);
    expect(daySelector.items, hasLength(28));
    expect(daySelector.items.first.value, 1);
    expect(daySelector.items.last.value, 28);

    await container
        .read(appSettingsProvider.notifier)
        .setBackupFrequency(BackupFrequency.manual);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('backup_weekdays_field')), findsNothing);
    expect(
      find.byKey(const ValueKey('backup_day_of_month_field')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('backup_hour_field')), findsNothing);
    expect(find.byKey(const ValueKey('backup_minute_field')), findsNothing);

    final webDavSwitch = find.byKey(const ValueKey('webdav_enabled_switch'));
    expect(webDavSwitch, findsOneWidget);
    await tester.ensureVisible(webDavSwitch);
    await tester.tap(webDavSwitch);
    await tester.pumpAndSettle();

    expect(find.text('Upload a copy to WebDAV'), findsOneWidget);
    expect(
      find.text('After a local backup is created, upload a copy to WebDAV.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('webdav_server_url_field')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('webdav_username_field')), findsOneWidget);
    expect(find.byKey(const ValueKey('webdav_password_field')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('webdav_remote_directory_field')),
      findsOneWidget,
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('webdav_server_url_field')),
        matching: find.byType(TextField),
      ),
      'http://192.168.1.10/webdav',
    );
    await tester.pump();

    expect(
      find.text(
        'HTTP is not encrypted. Use it only on a trusted local network.',
      ),
      findsOneWidget,
    );
    final webDavSaveButton = find.byKey(const ValueKey('webdav_save_button'));
    final backupActions = find.byKey(const ValueKey('backup_action_buttons'));
    expect(webDavSaveButton, findsOneWidget);
    expect(backupActions, findsOneWidget);
    expect(
      tester.getTopLeft(backupActions).dy,
      greaterThan(tester.getBottomLeft(webDavSaveButton).dy),
    );
    expect(tester.takeException(), isNull);

    // 桌面端没选目录就不能备份。
    await container.read(appSettingsProvider.notifier).setBackupDirectory('');
    await tester.pumpAndSettle();
    expect(_backupNowButton(tester).onPressed, isNull);

    // 输入后未失焦就离开页面（如 Esc 关闭设置），卸载时也要保存。
    await tester.enterText(
      find.byKey(const ValueKey('change_record_retention_days_input')),
      '60',
    );
    await tester.pump();

    // 移动端 scoped storage 下写不了自选目录：目录选择器与自动备份计划必须隐藏，
    // 备份改由系统另存面板导出，因此不依赖目录也要能点。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(
      _wrap(container, sectionKey: const ValueKey('mobile_section')),
    );
    await tester.pumpAndSettle();
    expect(
      container
          .read(appSettingsProvider)
          .requireValue
          .changeRecordRetentionDays,
      60,
    );

    expect(find.text('Local Backup Folder'), findsNothing);
    expect(find.byKey(const ValueKey('backup_frequency_field')), findsNothing);
    expect(find.byKey(const ValueKey('backup_hour_field')), findsNothing);
    expect(find.byKey(const ValueKey('backup_minute_field')), findsNothing);
    expect(find.text('Where backups go'), findsOneWidget);
    expect(_backupNowButton(tester).onPressed, isNotNull);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final localization = EasyLocalization.of(
      tester.element(find.byType(BackupSettingsSection)),
    )!;
    await tester.runAsync(
      () => localization.setLocale(const Locale('zh', 'CN')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    // flutter_test 在 test body 结束时（早于 addTearDown）校验 foundation debug 变量已复位。
    debugDefaultTargetPlatformOverride = null;
  });
}

FilledButton _backupNowButton(WidgetTester tester) {
  return tester.widget<FilledButton>(
    find.descendant(
      of: find.byKey(const ValueKey('backup_action_buttons')),
      matching: find.byType(FilledButton),
    ),
  );
}

Widget _wrap(
  ProviderContainer container, {
  Key? sectionKey,
  bool compact = false,
}) {
  return EasyLocalization(
    supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
    saveLocale: false,
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('en'),
    startLocale: const Locale('en'),
    child: UncontrolledProviderScope(
      container: container,
      child: Builder(
        builder: (context) {
          return MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData(),
            home: RevericTheme(
              data: RevericThemeData.reveric,
              child: Scaffold(
                body: BackupSettingsSection(key: sectionKey, compact: compact),
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _TestWebDavService extends WebDavBackupService {
  _TestWebDavService() : super(transport: const WebDavTransport());

  @override
  Future<WebDavListResult> listBackups(WebDavBackupConfig config) async =>
      const WebDavListResult.success([]);
}

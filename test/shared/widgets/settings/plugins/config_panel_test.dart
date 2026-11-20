// 职责: 验证插件详情页在三平台保存凭据、隐藏原文、重新进入后恢复配置，并在桌面离开前确认未保存输入。
// 关联文件:
//   lib/shared/widgets/settings/plugins/config_panel.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/components/reveric_button.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/desktop/widgets/agent_management/plugins_page.dart';
import '../../../services/plugins/host_test.dart' show FakeExecutor;
import '../plugins_section_test.dart' show wrapPluginSettings;

Future<(AppDatabase, PluginHostService)> _pumpDeepSeek(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.macOS,
  Widget? child,
}) async {
  final db = AppDatabase.forTest(NativeDatabase.memory());
  final manifest = PluginManifest.fromJson(
    jsonDecode(File('plugins/deepseek/plugin.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final host = PluginHostService(
    dao: db.pluginDao,
    registry: PluginRegistry(hostToolNames: {}),
    packages: () async => [
      PluginPackage('assets/plugins/reveric.deepseek', manifest, ''),
    ],
    executorFactory: (call, stop) => FakeExecutor(),
    platform: platform == TargetPlatform.macOS ? 'macos' : platform.name,
  );
  await tester.runAsync(host.start);
  addTearDown(() async {
    await host.dispose();
    await db.close();
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(
    platform == TargetPlatform.android ? 360 : 1000,
    900,
  );
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    child == null
        ? wrapPluginSettings(host, platform: platform)
        : wrapPluginSettings(host, platform: platform, child: child),
  );
  await tester.pumpAndSettle();
  return (db, host);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 30)),
  );
  await tester.pumpAndSettle();
}

const _details = ValueKey('plugin-details-reveric.deepseek');
const _toggle = ValueKey('plugin-toggle-reveric.deepseek');

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.android,
  ]) {
    testWidgets(
      'config saves and reloads without revealing credentials (${platform.name})',
      (tester) async {
        final (db, host) = await _pumpDeepSeek(tester, platform: platform);
        final details = find.byKey(_details);
        await tester.tap(details);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpAndSettle();
        final field = find.byType(TextField);
        expect(field, findsOneWidget);
        final save = find.widgetWithText(RevericButton, 'Save');
        expect(tester.widget<RevericButton>(save).onPressed, null);
        await tester.enterText(field, 'fixture-secret');
        await tester.pumpAndSettle();
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Saved'), findsOneWidget);
        expect(tester.widget<TextField>(field).controller!.text, isEmpty);
        expect(
          await tester.runAsync(
            () => db.pluginDao.getSecret('reveric.deepseek', 'apiKey'),
          ),
          'fixture-secret',
        );
        // 返回列表后重新进入详情，凭据只显示为已设置。
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        await tester.tap(details);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Already set. Leave blank to keep it.'),
          findsOneWidget,
        );
        expect(tester.widget<TextField>(field).controller!.text, isEmpty);
        await tester.tap(find.byKey(_toggle));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpAndSettle();
        expect(host.statuses.single.state, 'available');
        expect(tester.takeException(), null);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets('turning on without the required key opens setup instead', (
    tester,
  ) async {
    final (_, host) = await _pumpDeepSeek(tester);
    expect(find.text('Needs setup'), findsOneWidget);

    await tester.tap(find.byKey(_toggle));
    await _settle(tester);

    expect(host.statuses.single.enabled, false);
    expect(find.byType(TextField), findsOneWidget);
    const hint = 'Fill in the required settings and save to turn it on.';
    expect(find.text(hint), findsOneWidget);
    expect(
      find.text('Could not save the switch setting. Try again.'),
      findsNothing,
    );

    await tester.enterText(find.byType(TextField), 'fixture-secret');
    await tester.pumpAndSettle();
    final save = find.widgetWithText(RevericButton, 'Save');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await _settle(tester);

    expect(find.text(hint), findsNothing);
    expect(find.text('Disabled'), findsOneWidget);
    await tester.tap(find.byKey(_toggle));
    await _settle(tester);
    expect(host.statuses.single.state, 'available');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('leaving desktop details with unsaved input asks first', (
    tester,
  ) async {
    await _pumpDeepSeek(tester, child: const PluginsRegion());
    await tester.tap(find.byKey(_details));
    await _settle(tester);
    await tester.enterText(find.byType(TextField), 'draft-key');
    await _settle(tester);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Discard'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'draft-key',
    );

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(_details), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

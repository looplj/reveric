// 职责: 验证插件列表进入详情页后能查看工具、切换实际可用工具，并展示失败原因。
// 关联文件:
//   lib/shared/widgets/settings/plugins/section.dart
//   lib/shared/providers/plugin_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/providers/plugin_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/components/reveric_button.dart';
import 'package:reveric/shared/widgets/settings/plugins/preview_page.dart';
import 'package:reveric/shared/widgets/settings/plugins/section.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/theme/theme.dart';
import '../../services/plugins/host_test.dart' show FakeExecutor, package;
import '../../services/plugins/installer_test.dart' show archive;

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
      'user can inspect and disable plugin tools on narrow and wide screens (${platform.name})',
      (tester) async {
        final db = AppDatabase.forTest(NativeDatabase.memory());
        final host = PluginHostService(
          dao: db.pluginDao,
          registry: PluginRegistry(hostToolNames: {}),
          packages: () async => [package()],
          executorFactory: (call, stop) => FakeExecutor(),
          platform: 'macos',
        );
        await tester.runAsync(host.start);
        addTearDown(() async {
          await host.dispose();
          await db.close();
        });
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 800);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(wrapPluginSettings(host, platform: platform));
        await tester.pumpAndSettle();
        expect(find.text('Test'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('plugin-details-test.web')));
        await tester.pumpAndSettle();
        // 工具描述写给模型看，详情里默认折叠，展开后才列出。
        expect(find.textContaining('WebSearch'), findsNothing);
        await tester.tap(find.text('Tools (2)'));
        await tester.pumpAndSettle();
        expect(find.textContaining('WebSearch'), findsOneWidget);
        expect(tester.takeException(), null);
        await tester.tap(find.byKey(const ValueKey('plugin-toggle-test.web')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpAndSettle();
        expect(host.registry.effectiveTools, isEmpty);
        expect(find.text('Disabled'), findsOneWidget);
        tester.view.physicalSize = const Size(1000, 800);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('plugin-toggle-test.web')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpAndSettle();
        expect(host.registry.effectiveTools, hasLength(2));
        expect(tester.takeException(), null);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
  testWidgets(
    'activation failure shows a useful reason without raw diagnostics',
    (tester) async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      final host = PluginHostService(
        dao: db.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        packages: () async => [package()],
        executorFactory: (call, stop) => _InvalidPluginExecutor(),
        platform: 'macos',
      );
      await tester.runAsync(host.start);
      addTearDown(() async {
        await host.dispose();
        await db.close();
      });
      await tester.pumpWidget(wrapPluginSettings(host));
      await tester.pumpAndSettle();
      expect(find.text('Failed'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('plugin-details-test.web')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'The plugin package is invalid. Check its manifest and entry file.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('private-token'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('a removed model is flagged in the list and the details', (
    tester,
  ) async {
    final db = AppDatabase.forTest(NativeDatabase.memory());
    final host = PluginHostService(
      dao: db.pluginDao,
      registry: PluginRegistry(hostToolNames: {}),
      packages: () async => [
        package(
          settings: {
            'model': {'type': 'model', 'title': 'Organizer model'},
          },
        ),
      ],
      executorFactory: (call, stop) => FakeExecutor(),
      platform: 'macos',
    );
    // 测试的 AI 设置没有任何模型，已保存的选择即视为被删除。
    await tester.runAsync(() async {
      await db.pluginDao.setStorage(
        'test.web',
        'settings.model',
        jsonEncode({'providerId': 'gone', 'model': 'retired'}),
      );
      await host.start();
    });
    addTearDown(() async {
      await host.dispose();
      await db.close();
    });
    const warning =
        'Organizer model: the selected model is no longer available. Choose another one.';
    await tester.pumpWidget(wrapPluginSettings(host));
    await tester.pumpAndSettle();
    expect(find.text(warning), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('plugin-details-test.web')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(find.text(warning), findsOneWidget);
    expect(find.text('retired (unavailable)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('install preview marks new permissions before installing', (
    tester,
  ) async {
    final db = AppDatabase.forTest(NativeDatabase.memory());
    final host = PluginHostService(
      dao: db.pluginDao,
      registry: PluginRegistry(hostToolNames: {}),
      packages: () async => [],
      executorFactory: (call, stop) => FakeExecutor(),
      platform: 'macos',
    );
    await tester.runAsync(host.start);
    addTearDown(() async {
      await host.dispose();
      await db.close();
    });
    final candidate = archive(
      '1.0.0',
      permissions: ['ai.generateText', 'files.delete'],
    );
    await tester.pumpWidget(
      wrapPluginSettings(
        host,
        child: PluginPreviewPage(
          archive: candidate,
          mobile: false,
          onClose: () {},
          onInstalled: (_) {},
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Use AI models'), findsOneWidget);
    expect(find.text('Unknown permission'), findsOneWidget);
    expect(find.text('New'), findsNWidgets(2));
    expect(
      find.text(
        'Local plugins are not reviewed by Reveric. Only install plugins from sources you trust.',
      ),
      findsOneWidget,
    );
    expect(find.text('Tools (2)'), findsOneWidget);
    final install = find.widgetWithText(RevericButton, 'Grant and install');
    expect(tester.widget<RevericButton>(install).onPressed, isNotNull);
    expect(host.registry.effectiveTools, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

Widget wrapPluginSettings(
  PluginHostService host, {
  TargetPlatform platform = TargetPlatform.macOS,
  Widget child = const PluginsSettingsSection(),
}) => ProviderScope(
  overrides: [
    pluginHostServiceProvider.overrideWithValue(host),
    // 列表据 AI 设置提示已失效的模型；测试不打开真实设置库。
    aiSettingsProvider.overrideWithValue(AiSettings.defaults()),
  ],
  child: EasyLocalization(
    supportedLocales: const [Locale('en')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('en'),
    startLocale: const Locale('en'),
    child: Builder(
      builder: (context) => MaterialApp(
        localizationsDelegates: context.localizationDelegates,
        supportedLocales: context.supportedLocales,
        locale: context.locale,
        theme: RevericThemeData.reveric.toThemeData().copyWith(
          platform: platform,
        ),
        home: RevericTheme(
          data: RevericThemeData.reveric,
          child: Scaffold(body: child),
        ),
      ),
    ),
  ),
);

class _InvalidPluginExecutor extends FakeExecutor {
  @override
  Future<List<Map<String, dynamic>>> activate(
    PluginManifest manifest,
    String code,
  ) async {
    throw const FormatException('Invalid schema private-token');
  }
}

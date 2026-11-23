// 职责: 验证跨平台设置导航、Android 入口归类，以及存储表单的保存和关闭。
// 关联文件:
//   lib/settings_navigation_host.dart
//   lib/shared/providers/settings_navigation.dart
//   lib/shared/widgets/settings/object_storage_form.dart
//   lib/desktop/widgets/agent_management/page_dialog.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
import 'dart:io';
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/settings_navigation_host.dart';
import 'package:reveric/desktop/widgets/settings/settings_dialog.dart';
import 'package:reveric/desktop/widgets/agent_management/ai_providers_page.dart';
import 'package:reveric/desktop/pages/settings/usage_page.dart';
import 'package:reveric/mobile/pages/chat_page.dart';
import 'package:reveric/mobile/pages/settings_page.dart';
import 'package:reveric/mobile/widgets/detail_scaffold.dart';
import 'package:reveric/shared/widgets/settings/ai_providers_section.dart';
import 'package:reveric/shared/widgets/settings/general_settings_section.dart';
import 'package:reveric/shared/widgets/settings/usage_view.dart';
import 'package:reveric/shared/components/reveric_segmented_control.dart';
import 'package:reveric/shared/database/app_database.dart' show AppDatabase;
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/object_storage_config.dart';
import 'package:reveric/shared/models/ai_provider.dart' show AiSettings;
import 'package:reveric/shared/models/tool_permission.dart';
import 'package:reveric/shared/providers/agent_skill_providers.dart';
import 'package:reveric/shared/providers/settings_navigation.dart';
import 'package:reveric/shared/providers/object_storage.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/providers/update_providers.dart';
import 'package:reveric/shared/services/object_storage/service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:reveric/shared/widgets/guide/trigger.dart';
import 'package:reveric/shared/widgets/settings/object_storage_form.dart';
import 'package:shared_preferences/shared_preferences.dart';

const config = ObjectStorageConfig(
  endpoint: 'https://s3.example.com',
  region: 'test',
  bucket: 'media',
  accessKeyId: 'key',
  secretAccessKey: 'secret',
);

void _expectChartModePlacement(WidgetTester tester, {required bool narrow}) {
  final title = tester.getRect(find.text('Daily Token Usage'));
  final date = tester.getRect(find.text('Last 30 days'));
  final control = tester.getRect(
    find.ancestor(
      of: find.text('By token type'),
      matching: find.byWidgetPredicate(
        (widget) => widget is RevericSegmentedControl<Object>,
      ),
    ),
  );
  if (narrow) {
    expect(control.top, greaterThan(date.bottom));
    expect(control.left, closeTo(title.left, 0.5));
  } else {
    final view = tester.getRect(find.byType(UsageView));
    expect(control.right, closeTo(view.right - (title.left - view.left), 0.5));
    expect(control.center.dy, closeTo((title.top + date.bottom) / 2, 0.5));
  }
}

class _Storage extends ObjectStorageService {
  _Storage(AppDatabase database) : super(database: database);
  bool saved = false;
  @override
  Future<ObjectStorageFailure?> test(ObjectStorageConfig config) async => null;
  @override
  Future<void> save(ObjectStorageConfig config) async {
    saved = true;
  }
}

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => AppSettings(
    theme: AppTheme.reveric,
    themeMode: AppThemeMode.light,
    language: 'en',
    aiSettings: AiSettings(providers: []),
  );
}

void main() {
  late Directory root;
  late AppDatabase db;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() async {
    rootBundle.clear();
    root = await Directory.systemTemp.createTemp('settings-navigation-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await RevericPaths.initialize();
    db = AppDatabase.forTest(NativeDatabase.memory());
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await db.close();
    await root.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
  });
  test(
    'normal settings are addressable and hidden sections remain excluded',
    () {
      const shared = {
        'general',
        'appearance',
        'editor',
        'reading',
        'ai_agents',
        'providers',
        'usage',
        'mcp',
        'plugins',
        'backup',
        'trash',
        'about',
      };
      expect(SettingsPage.navigableSections, shared);
      expect(SettingsNavigationHost.desktopNavigableSections, {
        ...shared,
        'storage',
        'remote',
      });
      // 首页独立入口仍可直达，但不出现在桌面设置分区列表中。
      expect(
        SettingsRegion.navigableSections.intersection({
          'ai_agents',
          'providers',
          'mcp',
          'usage',
        }),
        isEmpty,
      );
    },
  );
  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets(
      'respects storage visibility and opens without waiting on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final mobile = platform == TargetPlatform.android;
        tester.view.physicalSize = mobile
            ? const Size(412, 915)
            : const Size(1200, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final navigatorKey = GlobalKey<NavigatorState>();
        final navigation = SettingsNavigation();
        final storage = _Storage(db);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsNavigationProvider.overrideWithValue(navigation),
              appDatabaseProvider.overrideWithValue(db),
              agentSkillAppDatabaseProvider.overrideWithValue(db),
              availableUpdateProvider.overrideWith((_) => null),
              guideTourAutoTriggerProvider.overrideWithValue(false),
              appSettingsProvider.overrideWith(_Settings.new),
              objectStorageServiceProvider.overrideWithValue(storage),
              objectStorageConfigProvider.overrideWith(
                (ref) => Stream.value(config),
              ),
              appDebugModeProvider.overrideWith((ref) => false),
              appDebugPageUnlockedProvider.overrideWith((ref) => false),
            ],
            child: EasyLocalization(
              supportedLocales: const [Locale('en')],
              path: 'assets/translations',
              assetLoader: const MergingAssetLoader(),
              fallbackLocale: const Locale('en'),
              startLocale: const Locale('en'),
              child: Builder(
                builder: (context) => MaterialApp(
                  navigatorKey: navigatorKey,
                  localizationsDelegates: context.localizationDelegates,
                  supportedLocales: context.supportedLocales,
                  locale: context.locale,
                  theme: RevericThemeData.reveric.toThemeData(),
                  builder: (context, child) => RevericTheme(
                    data: RevericThemeData.reveric,
                    child: Stack(
                      children: [
                        child!,
                        SettingsNavigationHost(
                          navigatorKey: navigatorKey,
                          mobile: mobile,
                        ),
                      ],
                    ),
                  ),
                  home: mobile ? const SettingsPage() : const Scaffold(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final section in ['debug', 'unknown', if (mobile) 'remote']) {
          expect(
            () => navigation.open(section),
            throwsA(
              isA<ToolOperationException>().having(
                (error) => error.code,
                'code',
                'unsupported_section',
              ),
            ),
          );
        }
        navigation.open('general');
        await tester.pumpAndSettle();
        expect(find.byType(GeneralSettingsSection), findsOneWidget);
        if (!mobile) {
          // 桌面端只展示目标分区，不带整套设置导航。
          expect(find.byType(SettingsRegion), findsNothing);
        }
        navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        if (mobile) {
          expect(find.text('General'), findsOneWidget);
          expect(find.text('AI Providers'), findsNothing);
          expect(find.text('MCP'), findsNothing);
          await tester.scrollUntilVisible(find.text('AI Usage'), 160);
          double arrowRight(String label) {
            final row = find.ancestor(
              of: find.text(label),
              matching: find.byType(MobileDetailNavRow),
            );
            final arrow = find.descendant(
              of: row,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is RevericIcon &&
                    widget.assetPath == RevericIcons.chevron_right,
              ),
            );
            return tester.getRect(arrow).right;
          }

          expect(arrowRight('General'), closeTo(arrowRight('AI Usage'), 0.5));
          await tester.tap(find.text('AI Usage'));
          await tester.pumpAndSettle();
          expect(find.byType(UsageView), findsOneWidget);
          _expectChartModePlacement(tester, narrow: true);
          navigatorKey.currentState!.pop();
          await tester.pumpAndSettle();

          expect(
            () => navigation.open('storage'),
            throwsA(
              isA<ToolOperationException>().having(
                (error) => error.code,
                'code',
                'unsupported_section',
              ),
            ),
          );
          expect(find.byType(ObjectStorageForm), findsNothing);
          navigatorKey.currentState!.push(
            MaterialPageRoute<void>(builder: (_) => const MobileChatPage()),
          );
          await tester.pumpAndSettle();
          final aiTabScroll = find.descendant(
            of: find.byType(MobileChatPage),
            matching: find.byType(Scrollable),
          );
          await tester.scrollUntilVisible(
            find.text('AI Providers'),
            160,
            scrollable: aiTabScroll,
          );
          expect(find.text('Models'), findsOneWidget);
          expect(find.text('Model Settings'), findsOneWidget);
          await tester.tap(find.text('AI Providers'));
          await tester.pumpAndSettle();
          expect(find.byType(AiProvidersSection), findsOneWidget);
          expect(
            find.text('0 total · 0 configured and enabled'),
            findsOneWidget,
          );
          navigatorKey.currentState!.pop();
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text('MCP'),
            160,
            scrollable: aiTabScroll,
          );
          expect(find.text('Agents'), findsOneWidget);
          expect(find.text('AI Assistant'), findsOneWidget);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          debugDefaultTargetPlatformOverride = null;
          return;
        }
        navigation.open('usage');
        await tester.pumpAndSettle();
        expect(find.byType(UsagePage), findsOneWidget);
        expect(find.byType(UsageView), findsOneWidget);
        _expectChartModePlacement(tester, narrow: false);
        expect(find.byType(SettingsRegion), findsNothing);
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(UsagePage), findsNothing);

        navigation.open('providers');
        await tester.pumpAndSettle();
        expect(find.byType(AiProvidersPage), findsOneWidget);
        expect(find.byType(SettingsRegion), findsNothing);
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(AiProvidersPage), findsNothing);

        navigation.open('providers');
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Add Custom'));
        await tester.pumpAndSettle();
        // 类型选择器默认展示预设平台，OpenAI 兼容在「接入协议」分段。
        await tester.tap(find.text('API formats'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OpenAI Compatible'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        expect(find.text('Unsaved changes'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.byType(AiProvidersPage), findsOneWidget);
        expect(find.text('Unsaved'), findsNWidgets(2));
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Discard').last);
        await tester.pumpAndSettle();
        expect(find.byType(AiProvidersPage), findsNothing);
        navigation.open('storage');
        await tester.pumpAndSettle();
        expect(find.byType(ObjectStorageForm), findsOneWidget);
        navigation.open('storage');
        await tester.pumpAndSettle();
        expect(find.byType(ObjectStorageForm), findsOneWidget);
        navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        expect(storage.saved, false);
        navigation.open('storage');
        await tester.pumpAndSettle();
        final button = find.byKey(const ValueKey('object_storage_save_button'));
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(storage.saved, true);
        expect(find.byType(ObjectStorageForm), findsOneWidget);
        navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.byType(ObjectStorageForm), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = null;
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );
  }
}

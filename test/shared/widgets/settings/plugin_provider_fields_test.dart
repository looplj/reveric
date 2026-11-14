// 职责: 验证真实插件供应商包装层重建、保存与操作集合变化时保留字段草稿和最新凭据标记。
// 关联文件:
//   lib/shared/widgets/settings/plugin_provider_fields.dart
//   lib/shared/widgets/settings/plugins/config_form.dart
//   lib/shared/providers/settings_providers.dart
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/models/plugin/provider_registry.dart';
import 'package:reveric/shared/providers/plugin_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/files.dart';
import 'package:reveric/shared/services/plugins/media_files.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/widgets/settings/plugin_provider_fields.dart';
import 'package:reveric/shared/widgets/settings/provider_models_editor.dart';
import 'package:reveric/shared/widgets/settings/plugins/config_form.dart';
import 'package:reveric/shared/components/reveric_button.dart';
import 'package:reveric/shared/components/reveric_text_field.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/theme/theme.dart';
import '../../services/plugins/host_test.dart' show FakeExecutor;

class _Executor extends FakeExecutor {
  @override
  Future<List<Map<String, dynamic>>> activate(
    PluginManifest manifest,
    String code,
  ) async => [
    {
      'kind': 'provider',
      'methods': [
        'actions.queryCredits',
        'checkConnection',
        'image.submit',
        'listModels',
      ],
    },
  ];
}

class _Host extends PluginHostService {
  _Host({
    required super.dao,
    required super.registry,
    required super.packages,
    super.executorFactory,
    super.platform,
  });
  String? lastMethod;
  Map<String, String?>? lastSecrets;
  @override
  Future<Object?> callProvider(
    AiProvider provider,
    String method, {
    Map<String, dynamic> input = const {},
    Map<String, Object?> draftSettings = const {},
    Map<String, String?> draftSecrets = const {},
    String? taskId,
    PluginFileScope? files,
    PluginMediaFiles? mediaFiles,
    AgentCancellationToken? cancellation,
  }) async {
    lastMethod = method;
    lastSecrets = draftSecrets;
    return {
      'ok': true,
      'code': null,
      'text': {'en': 'Credits remaining: 123', 'zh-CN': '剩余积分：123'},
    };
  }
}

Finder field(String title) => find.descendant(
  of: find.widgetWithText(RevericTextField, title),
  matching: find.byType(TextField),
);
Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 30)),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());
  for (final platform in [TargetPlatform.macOS, TargetPlatform.android]) {
    testWidgets(
      'provider fields survive edit/save/rebuild on $platform',
      (tester) async {
        final database = AppDatabase.forTest(NativeDatabase.memory());
        final manifest = PluginManifest.fromJson({
          'id': 'test.fields',
          'name': 'Fields',
          'version': '1.0.0',
          'pluginApiVersion': '^1',
          'main': 'index.js',
          'provider': {
            'name': 'Images',
            'settings': {
              'actions': {
                'queryCredits': {
                  'title': 'Query credits',
                  'requires': ['token'],
                },
              },
              'fields': {
                'project': {
                  'type': 'string',
                  'title': 'Project',
                  'required': true,
                },
                'token': {'type': 'secret', 'title': 'Token', 'required': true},
              },
            },
          },
        });
        final host = (await tester.runAsync(
          () async => _Host(
            dao: database.pluginDao,
            registry: PluginRegistry(hostToolNames: {}),
            packages: () async => [PluginPackage('memory', manifest, '')],
            executorFactory: (_, _) => _Executor(),
            platform: platform == TargetPlatform.android ? 'android' : 'macos',
          ),
        ))!;
        final provider = aiProviderBuiltinById('openai')!.copyWith(
          id: 'fields-instance',
          type: 'plugin:test.fields',
          models: [],
          imageModels: [],
          videoModels: [],
          enabled: false,
          apiKey: '',
          baseUrl: '',
        );
        final container = (await tester.runAsync(() async {
          await host.start();
          await host.setEnabled(manifest.id, true);
          await database.aiProviderDao.upsert(provider);
          await host.saveProviderConfig(
            provider,
            settings: {'project': 'original'},
            secrets: {'token': 'original-token'},
          );
          final value = ProviderContainer(
            overrides: [
              appSettingsDatabaseProvider.overrideWithValue(database),
              pluginHostServiceProvider.overrideWithValue(host),
            ],
          );
          await value.read(appSettingsProvider.future);
          return value;
        }))!;
        addTearDown(() async {
          container.dispose();
          await host.dispose();
          await database.close();
        });
        final rebuild = ValueNotifier(0);
        addTearDown(rebuild.dispose);
        await tester.binding.setSurfaceSize(
          Size(platform == TargetPlatform.android ? 360 : 900, 900),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          _wrap(
            container,
            ValueListenableBuilder<int>(
              valueListenable: rebuild,
              builder: (_, value, _) => Consumer(
                builder: (context, ref, _) => PluginProviderFields(
                  config: ref
                      .watch(aiSettingsProvider)
                      .findConfigById(provider.id)!,
                  isDraft: false,
                ),
              ),
            ),
          ),
        );
        await settle(tester);
        expect(
          find.widgetWithText(RevericButton, 'Query credits'),
          findsOneWidget,
        );
        expect(find.byType(ProviderModelsEditor), findsOneWidget);
        expect(
          tester
              .widget<ProviderModelsEditor>(find.byType(ProviderModelsEditor))
              .allowManualAdd,
          isFalse,
        );
        await tester.enterText(field('Project'), 'draft-project');
        await tester.enterText(field('Token'), 'draft-token');
        await tester.pumpAndSettle();
        final query = find.widgetWithText(RevericButton, 'Query credits');
        await tester.ensureVisible(query);
        await tester.tap(query);
        await settle(tester);
        expect(host.lastMethod, 'actions.queryCredits');
        expect(host.lastSecrets, {'token': 'draft-token'});
        expect(
          find.text('Query credits: Credits remaining: 123'),
          findsOneWidget,
        );
        await tester.enterText(field('Token'), 'edited-token');
        await tester.pumpAndSettle();
        expect(find.textContaining('Credits remaining'), findsNothing);
        await tester.enterText(field('Token'), 'draft-token');
        await tester.pumpAndSettle();

        rebuild.value++;
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(field('Project')).controller!.text,
          'draft-project',
        );
        expect(
          tester.widget<TextField>(field('Token')).controller!.text,
          'draft-token',
        );
        final save = find.widgetWithText(RevericButton, 'Save');
        await tester.ensureVisible(save);
        await tester.tap(save);
        await settle(tester);
        expect(
          await tester.runAsync(
            () => database.pluginDao.getSecret(
              manifest.id,
              'provider.${provider.id}.token',
            ),
          ),
          'draft-token',
        );
        rebuild.value++;
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(field('Project')).controller!.text,
          'draft-project',
        );
        expect(
          tester.widget<TextField>(field('Token')).controller!.text,
          isEmpty,
        );
        expect(
          find.text('Already set. Leave blank to keep it.'),
          findsOneWidget,
        );
        pluginProviderModels.refreshFailed(provider, code: 'network');
        await tester.pumpAndSettle();
        expect(
          find.textContaining("Couldn't reach the service"),
          findsOneWidget,
        );
        expect(
          tester
              .widget<RevericButton>(
                find.widgetWithText(RevericButton, 'Retry'),
              )
              .onPressed,
          isNotNull,
        );
        pluginProviderModels.replace(provider, []);
        await tester.pumpAndSettle();
        expect(find.textContaining("Couldn't reach the service"), findsNothing);
        // Changing availability intentionally rebuilds the action declaration; use the last saved baseline.
        await tester.runAsync(() => host.setEnabled(manifest.id, false));
        await settle(tester);
        expect(
          tester.widget<TextField>(field('Project')).controller!.text,
          'draft-project',
        );
        expect(
          tester.widget<TextField>(field('Token')).controller!.text,
          isEmpty,
        );
        expect(
          find.text('Already set. Leave blank to keep it.'),
          findsOneWidget,
        );
        await tester.runAsync(() => host.setEnabled(manifest.id, true));
        final draftController = PluginConfigDraftController();
        final fresh = provider.copyWith(id: 'fresh-draft');
        await tester.pumpWidget(
          _wrap(
            container,
            PluginProviderFields(
              key: const ValueKey('fresh-draft'),
              config: fresh,
              isDraft: true,
              draftController: draftController,
            ),
          ),
        );
        await settle(tester);
        expect(field('Token'), findsOneWidget);
        expect(find.widgetWithText(RevericButton, 'Save'), findsNothing);
        await tester.enterText(field('Project'), 'fresh-project');
        await tester.enterText(field('Token'), 'fresh-key');
        await tester.pumpAndSettle();
        final draftQuery = find.widgetWithText(RevericButton, 'Query credits');
        await tester.ensureVisible(draftQuery);
        await tester.tap(draftQuery);
        await settle(tester);
        expect(host.lastSecrets, {'token': 'fresh-key'});
        expect(draftController.read().secrets, {'token': 'fresh-key'});
        expect(
          await tester.runAsync(() => database.aiProviderDao.getById(fresh.id)),
          isNull,
        );
        expect(
          await tester.runAsync(
            () => database.pluginDao.getSecret(
              manifest.id,
              'provider.${fresh.id}.token',
            ),
          ),
          isNull,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant.only(platform),
      timeout: const Timeout(Duration(minutes: 1)),
    );
  }
}

Widget _wrap(ProviderContainer container, Widget child) =>
    UncontrolledProviderScope(
      container: container,
      child: EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'assets/translations',
        assetLoader: const MergingAssetLoader(),
        startLocale: const Locale('en'),
        fallbackLocale: const Locale('en'),
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData(),
            home: RevericTheme(
              data: RevericThemeData.reveric,
              child: Scaffold(body: SingleChildScrollView(child: child)),
            ),
          ),
        ),
      ),
    );

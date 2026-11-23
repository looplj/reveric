// 职责: Patrol 验证桌面与移动端模型设置、专家团和专家编辑的模型选择与推理强度。
// 关联文件:
//   lib/desktop/widgets/agent_management/subagent_edit_panel.dart
//   lib/mobile/pages/agent_model_settings_page.dart
//   lib/mobile/pages/subagent_manage_page.dart
//   lib/shared/providers/subagent_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/subagent.json
//   assets/translations/zh-CN/subagent.json
//   assets/translations/en/agent_studio.json
//   assets/translations/zh-CN/agent_studio.json
//   assets/translations/en/account.json
//   assets/translations/zh-CN/account.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md
//   .agents/rules/state-management.md
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/desktop/widgets/agent_management/subagent_edit_panel.dart';
import 'package:reveric/mobile/pages/agent_model_settings_page.dart';
import 'package:reveric/mobile/pages/subagent_manage_page.dart';
import 'package:reveric/shared/database/app_database.dart'
    show notDeletedSentinel;
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/subagent.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/providers/subagent_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:patrol/patrol.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _desktopSettings = AiSettings(
  providers: [_alternateProvider, _thirdPartyProvider],
);

final _alternateProvider = AiProvider(
  id: 'alternate',
  name: 'Alternate',
  builtin: false,
  type: 'openai',
  enabled: true,
  apiKey: 'test-key',
  baseUrl: 'https://example.invalid/v1',
  models: const ['alternate-chat'],
  imageModels: const ['alternate-image'],
  audioModels: const [],
  videoModels: const [],
  asrModels: const [],
  embeddingModels: const [],
  temperature: 0.7,
  maxTurns: 8,
  proxyUrl: '',
  proxyUsername: '',
  proxyPassword: '',
  updatedAt: DateTime(2026, 1, 1),
  deletedAt: notDeletedSentinel,
);

final _thirdPartyProvider = AiProvider(
  id: 'third-party',
  name: 'Third Party',
  builtin: false,
  type: 'openai',
  enabled: true,
  apiKey: 'test-key',
  baseUrl: 'https://example.invalid/v1',
  models: const ['third-party-chat', 'third-party-reasoning'],
  imageModels: const ['third-party-image'],
  audioModels: const [],
  videoModels: const [],
  asrModels: const [],
  embeddingModels: const [],
  temperature: 0.7,
  maxTurns: 8,
  proxyUrl: '',
  proxyUsername: '',
  proxyPassword: '',
  updatedAt: DateTime(2026, 1, 1),
  deletedAt: notDeletedSentinel,
);

const _desktopExpert = SubAgent(
  id: 'desktop_expert',
  slug: 'desktop_expert',
  name: 'Desktop Expert',
  description: 'Desktop test expert.',
  prompt: 'Prompt.',
  scope: SubAgentScope.global,
  sortOrder: 0,
  useCustomPrompt: true,
);

const _mobileExpert = SubAgent(
  id: 'mobile_expert',
  slug: 'mobile_expert',
  name: 'Mobile Expert',
  description: 'Mobile test expert.',
  prompt: 'Prompt.',
  scope: SubAgentScope.global,
  sortOrder: 0,
  providerId: 'third-party',
  model: 'third-party-reasoning',
  reasoningEffort: 'high',
  useCustomPrompt: true,
);

const _mobileOfficialExpert = SubAgent(
  id: 'official_expert',
  slug: 'plot_architect',
  name: 'Official Expert',
  description: 'Official council role.',
  prompt: 'Prompt.',
  mode: 'council',
  scope: SubAgentScope.global,
  sortOrder: 1,
);

const _workflowExpert = SubAgent(
  id: 'writer_expert',
  slug: 'writer',
  name: 'Writer',
  description: 'Workflow writer.',
  prompt: 'Prompt.',
  scope: SubAgentScope.global,
  sortOrder: 2,
);

const _mobileModels = [
  AiModelOption(
    providerId: 'alternate',
    providerDisplayName: 'Alternate',
    model: 'alternate-chat',
    kind: AiModelKind.chat,
  ),
  AiModelOption(
    providerId: 'third-party',
    providerDisplayName: 'Third Party',
    model: 'third-party-reasoning',
    kind: AiModelKind.chat,
    reasoningEfforts: ['none', 'high', 'max'],
  ),
];

class _TestAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async {
    return AppSettings(
      theme: AppTheme.reveric,
      themeMode: AppThemeMode.light,
      language: 'en',
      aiSettings: _desktopSettings,
    );
  }

  @override
  Future<void> setDefaultAiModelForKind(
    AiModelKind kind,
    String? optionId,
  ) async {
    final current = state.value!;
    state = AsyncData(
      current.copyWith(
        aiSettings: current.aiSettings.setDefaultOptionId(kind, optionId),
      ),
    );
  }
}

class _TestGlobalSubAgents extends GlobalSubAgents {
  @override
  Future<List<SubAgent>> build() async => const [
    _mobileExpert,
    _mobileOfficialExpert,
    _workflowExpert,
  ];
}

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  patrolTest(
    'desktop expert editor selects configured models without signing in',
    ($) async {
      _setSurface($, const Size(1400, 900));

      await $.pumpWidgetAndSettle(_DesktopHarness());

      expect($(_desktopExpert.name), findsWidgets);
      expect($('Slug'), findsNothing);

      await $(#expert_edit_model_selector).tap();
      await $.pumpAndSettle();

      expect($('Sign in'), findsNothing);
      expect($('alternate-chat'), findsOneWidget);
      await $('third-party-chat').tap();
      await $.pumpAndSettle();
      expect($('third-party-chat'), findsOneWidget);
    },
  );

  patrolTest('mobile expert team separates official experts and keeps effort', (
    $,
  ) async {
    _setSurface($, const Size(390, 844));

    await $.pumpWidgetAndSettle(
      const _MobileHarness(child: MobileExpertTeamPage()),
    );

    expect($('Subagents'), findsOneWidget);
    expect($('My Subagents'), findsOneWidget);
    expect($('Built-in Subagents'), findsOneWidget);
    expect($('Mobile Expert'), findsOneWidget);

    await $('Built-in Subagents').tap();
    await $.pumpAndSettle();
    expect($('Official Expert'), findsOneWidget);
    await $(#mobile_expert_card_official_expert).tap();
    await $.pumpAndSettle();
    expect($('Delete'), findsNothing);
    await $(#mobile_agent_edit_back).tap();
    await $.pumpAndSettle();

    await $('My Subagents').tap();
    await $.pumpAndSettle();
    await $(#mobile_expert_card_mobile_expert).tap();
    await $.pumpAndSettle();

    expect($(_mobileExpert.name), findsWidgets);
    expect($('Reasoning effort'), findsOneWidget);

    await $(#mobile_expert_edit_model_field).tap();
    await $.pumpAndSettle();

    expect($('Sign in'), findsNothing);
    expect($('alternate-chat'), findsOneWidget);
    await $('third-party-reasoning').tap();
    await $.pumpAndSettle();
    expect($('Reasoning effort'), findsOneWidget);
  });

  patrolTest(
    'mobile model settings select configured models without signing in',
    ($) async {
      _setSurface($, const Size(390, 844));

      await $.pumpWidgetAndSettle(
        const _MobileHarness(child: MobileAgentModelSettingsPage()),
      );

      expect($('Model Settings'), findsOneWidget);
      expect($('Chat'), findsOneWidget);
      expect($('Image Generation'), findsOneWidget);
      expect($('Long-form Writing'), findsOneWidget);

      await $(#mobile_model_setting_chat).tap();
      await $.pumpAndSettle();

      expect($('Sign in'), findsNothing);
      expect($('alternate-chat'), findsOneWidget);
      await $('third-party-chat').tap();
      await $.pumpAndSettle();
      expect($('third-party-chat'), findsOneWidget);
    },
  );
}

void _setSurface(PatrolIntegrationTester $, Size size) {
  $.tester.view.devicePixelRatio = 1;
  $.tester.view.physicalSize = size;
  addTearDown(() {
    $.tester.view.resetPhysicalSize();
    $.tester.view.resetDevicePixelRatio();
  });
}

class _DesktopHarness extends StatelessWidget {
  const _DesktopHarness();

  @override
  Widget build(BuildContext context) {
    return EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'assets/translations',
      assetLoader: const MergingAssetLoader(),
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      child: Builder(
        builder: (context) => ProviderScope(
          overrides: [
            appSettingsProvider.overrideWith(_TestAppSettingsNotifier.new),
          ],
          child: MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData(),
            home: RevericTheme(
              data: RevericThemeData.reveric,
              child: Scaffold(
                body: SubAgentEditPanel(agent: _desktopExpert, onSaved: () {}),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileHarness extends StatelessWidget {
  const _MobileHarness({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'assets/translations',
      assetLoader: const MergingAssetLoader(),
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      child: Builder(
        builder: (context) => ProviderScope(
          overrides: [
            globalSubAgentsProvider.overrideWith(_TestGlobalSubAgents.new),
            availableAiModelsProvider.overrideWithValue(_mobileModels),
            appSettingsProvider.overrideWith(_TestAppSettingsNotifier.new),
          ],
          child: MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData(),
            home: child,
            builder: (context, child) =>
                RevericTheme(data: RevericThemeData.reveric, child: child!),
          ),
        ),
      ),
    );
  }
}

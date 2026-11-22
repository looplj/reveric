// 职责: 验证移动端模型设置可配置聊天与流程智能体的模型和推理强度。
// 关联文件:
//   lib/mobile/pages/agent_model_settings_page.dart
//   lib/mobile/pages/subagent_prompt_edit_page.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/providers/subagent_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_studio.json
//   assets/translations/zh-CN/agent_studio.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/state-management.md
//   .agents/rules/testing.md
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/mobile/pages/agent_model_settings_page.dart';
import 'package:reveric/mobile/pages/subagent_prompt_edit_page.dart';
import 'package:reveric/shared/database/app_database.dart'
    show notDeletedSentinel;
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/subagent.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/providers/subagent_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/guide/trigger.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _writer = SubAgent(
  id: 'writer-1',
  slug: 'writer',
  name: 'Long-form Writing',
  description: 'Writes delegated chapter batches.',
  prompt: 'Default writer prompt',
  scope: SubAgentScope.global,
  sortOrder: 0,
  providerId: 'test-provider',
  model: 'deepseek-v4-flash',
  reasoningEffort: 'high',
);

SubAgent? _updatedAgent;
AiSettings? _updatedAiSettings;

class _TestGlobalSubAgents extends GlobalSubAgents {
  @override
  Future<List<SubAgent>> build() async => const [_writer];

  @override
  Future<void> updateSubAgent(SubAgent agent) async {
    _updatedAgent = agent;
    state = AsyncData([agent]);
  }
}

class _TestAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async {
    return AppSettings(
      theme: AppTheme.reveric,
      themeMode: AppThemeMode.light,
      language: 'en',
      aiSettings: AiSettings(
        providers: [_testProvider],
        defaultChatModelId: 'test-provider::deepseek-v4-flash',
        defaultChatReasoningEffort: 'high',
      ),
    );
  }

  @override
  Future<void> setDefaultAiModelForKind(
    AiModelKind kind,
    String? optionId,
  ) async {
    final current = state.requireValue;
    final aiSettings = current.aiSettings.setDefaultOptionId(kind, optionId);
    _updatedAiSettings = aiSettings;
    state = AsyncData(current.copyWith(aiSettings: aiSettings));
  }

  @override
  Future<void> setDefaultChatModelWithEffort(
    AiModelOption option,
    String effort,
  ) async {
    final current = state.requireValue;
    final aiSettings = current.aiSettings.copyWith(
      defaultChatModelId: option.id,
      defaultChatReasoningEffort: effort,
    );
    _updatedAiSettings = aiSettings;
    state = AsyncData(current.copyWith(aiSettings: aiSettings));
  }
}

final _testProvider = AiProvider(
  asrModels: const [],
  audioModels: const [],
  videoModels: const [],
  id: 'test-provider',
  name: 'Test Provider',
  builtin: false,
  type: 'anthropic',
  enabled: true,
  apiKey: 'test-key',
  baseUrl: 'https://example.invalid',
  models: const ['deepseek-v4-flash'],
  imageModels: const [],
  embeddingModels: const [],
  temperature: 0.7,
  maxTurns: 8,
  proxyUrl: '',
  proxyUsername: '',
  proxyPassword: '',
  updatedAt: DateTime(2026),
  deletedAt: notDeletedSentinel,
);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('chat and built-in agent select effort and clear', (
    tester,
  ) async {
    _updatedAgent = null;
    _updatedAiSettings = null;
    tester.view.physicalSize = const Size(375, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'assets/translations',
        assetLoader: const MergingAssetLoader(),
        fallbackLocale: const Locale('en'),
        startLocale: const Locale('en'),
        child: Builder(
          builder: (context) => ProviderScope(
            overrides: [
              guideTourAutoTriggerProvider.overrideWithValue(false),
              appSettingsProvider.overrideWith(_TestAppSettingsNotifier.new),
              globalSubAgentsProvider.overrideWith(_TestGlobalSubAgents.new),
              availableAiModelsProvider.overrideWithValue(const []),
            ],
            child: MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              theme: RevericThemeData.reveric.toThemeData(),
              builder: (_, routeChild) => RevericTheme(
                data: RevericThemeData.reveric,
                child: routeChild!,
              ),
              home: const MobileAgentModelSettingsPage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final chatCard = find.byKey(const ValueKey('mobile_model_setting_chat'));
    await tester.tap(chatCard);
    await tester.pumpAndSettle();

    await tester.tap(find.text('High'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Max'));
    await tester.pumpAndSettle();

    expect(
      _updatedAiSettings?.defaultChatModelId,
      'test-provider::deepseek-v4-flash',
    );
    expect(_updatedAiSettings?.defaultChatReasoningEffort, 'max');

    await tester.tap(chatCard);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not selected').last);
    await tester.pumpAndSettle();

    expect(_updatedAiSettings?.defaultChatModelId, isNull);
    expect(_updatedAiSettings?.defaultChatReasoningEffort, isNull);

    final modelCard = find.byKey(const ValueKey('mobile_model_setting_writer'));
    await tester.tap(modelCard);
    await tester.pumpAndSettle();

    await tester.tap(find.text('High'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Max'));
    await tester.pumpAndSettle();

    expect(_updatedAgent?.providerId, 'test-provider');
    expect(_updatedAgent?.model, 'deepseek-v4-flash');
    expect(_updatedAgent?.reasoningEffort, 'max');

    await tester.tap(modelCard);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not selected').last);
    await tester.pumpAndSettle();

    expect(_updatedAgent?.providerId, isNull);
    expect(_updatedAgent?.model, isNull);
    expect(_updatedAgent?.reasoningEffort, isNull);

    await tester.longPress(modelCard);
    await tester.pumpAndSettle();

    final editAction = find.byKey(
      const ValueKey('mobile_model_prompt_edit_writer-1'),
    );
    expect(editAction, findsOneWidget);

    await tester.tap(editAction);
    await tester.pumpAndSettle();

    expect(find.byType(MobileSubAgentPromptEditPage), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mobile_agent_edit_back')),
      findsOneWidget,
    );
    expect(find.text('Name'), findsNothing);
    expect(find.text('Description'), findsNothing);
    expect(find.text('Subagent Type'), findsNothing);
    expect(find.text('Model'), findsNothing);
    expect(find.text('Reasoning Effort'), findsNothing);
    expect(find.text('Prompt'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(_updatedAgent?.useCustomPrompt, isFalse);
    expect(_updatedAgent?.prompt, isEmpty);
    expect(_updatedAgent?.name, _writer.name);
    expect(_updatedAgent?.description, _writer.description);
    expect(find.byType(MobileSubAgentPromptEditPage), findsNothing);
  });
}

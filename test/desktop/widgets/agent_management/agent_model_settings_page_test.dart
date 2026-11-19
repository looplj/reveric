// 职责: 验证桌面模型设置中的聊天与流程智能体可配置模型和推理强度。
// 关联文件:
//   lib/desktop/widgets/agent_management/agent_model_settings_page.dart
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
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/widgets/agent_management/agent_model_settings_page.dart';
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
  prompt: '',
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
  Future<List<SubAgent>> build() async => [_updatedAgent ?? _writer];

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
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SubAgent? editedAgent;
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
              home: Scaffold(
                body: AgentModelSettingsPage(
                  headerGestureExclusionKey: GlobalKey(),
                  onEditPrompt: (agent) => editedAgent = agent,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final chatSelector = find.byKey(
      const ValueKey('default_model_selector_chat'),
    );
    expect(chatSelector, findsOneWidget);

    await tester.tap(chatSelector);
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('High').last));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Max'));
    await tester.pumpAndSettle();

    expect(
      _updatedAiSettings?.defaultChatModelId,
      'test-provider::deepseek-v4-flash',
    );
    expect(_updatedAiSettings?.defaultChatReasoningEffort, 'max');

    await gesture.moveTo(Offset.zero);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(chatSelector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not selected').last);
    await tester.pumpAndSettle();

    expect(_updatedAiSettings?.defaultChatModelId, isNull);
    expect(_updatedAiSettings?.defaultChatReasoningEffort, isNull);

    final editButton = find.byKey(
      const ValueKey('agent_model_prompt_edit_writer-1'),
    );
    final modelSelector = find.byKey(
      const ValueKey('agent_model_selector_writer-1'),
    );
    expect(editButton, findsOneWidget);
    expect(modelSelector, findsOneWidget);
    expect(find.byTooltip('Edit prompt'), findsOneWidget);

    expect(
      tester.getRect(editButton).center.dy,
      closeTo(tester.getRect(modelSelector).center.dy, 0.01),
    );

    await tester.tap(modelSelector);
    await tester.pumpAndSettle();

    await gesture.moveTo(tester.getCenter(find.text('High').last));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Max'));
    await tester.pumpAndSettle();

    expect(_updatedAgent?.providerId, 'test-provider');
    expect(_updatedAgent?.model, 'deepseek-v4-flash');
    expect(_updatedAgent?.reasoningEffort, 'max');

    await gesture.moveTo(Offset.zero);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(modelSelector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not selected').last);
    await tester.pumpAndSettle();

    expect(_updatedAgent?.providerId, isNull);
    expect(_updatedAgent?.model, isNull);
    expect(_updatedAgent?.reasoningEffort, isNull);

    await tester.tap(editButton);
    await tester.pump();

    expect(editedAgent?.id, _writer.id);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(375, 900);
    await tester.pumpAndSettle();

    expect(editButton, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

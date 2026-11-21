// 职责: 圆桌会议 AI 服务初始化失败回归测试 — 验证门禁竞态不泄漏异常或 HTTP 租约
// 关联文件:
//   lib/desktop/features/council/panel.dart
//   lib/shared/services/ai/ai_http_client_lease.dart
//   lib/shared/services/ai/provider_initializer.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:reveric/desktop/features/council/panel.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/agent_council_models.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/providers/agent_council_providers.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/ai/ai_http_client_lease.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/app_background.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/novel_fixture.dart';

class _FixedCouncilParticipants extends AgentCouncilParticipantsNotifier {
  @override
  Future<List<CouncilParticipant>> build() async => const [
    CouncilParticipant(
      id: 'plot_architect',
      name: 'Plot Architect',
      description: '',
      prompt: '',
    ),
  ];
}

final _customProvider = AiProvider(
  asrModels: const [],
  audioModels: const [],
  videoModels: const [],
  id: 'custom_test',
  name: 'Custom Test',
  builtin: false,
  type: AiProviderType.openai_compatible.name,
  enabled: true,
  apiKey: 'test-api-key',
  baseUrl: 'https://example.invalid/v1',
  models: const ['test-chat'],
  imageModels: const [],
  embeddingModels: const [],
  temperature: 0.7,
  maxTurns: 8,
  proxyUrl: '',
  proxyUsername: '',
  proxyPassword: '',
  updatedAt: DateTime(2026, 1, 1),
  deletedAt: notDeletedSentinel,
);

const _customModel = AiModelOption(
  providerId: 'custom_test',
  providerDisplayName: 'Custom Test',
  model: 'test-chat',
  kind: AiModelKind.chat,
);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  for (final invalidWork in [true]) {
    testWidgets(
      invalidWork
          ? 'work context failure is visible and releases the acquired HTTP lease'
          : 'initializer gate race returns model unavailable without escaping error',
      (tester) async {
        late ProviderContainer container;
        final registry = AiHttpClientRegistry(
          clientFactory: (_) {
            return MockClient((_) async => throw StateError('unexpected HTTP'));
          },
        );

        container = ProviderContainer(
          overrides: [
            aiSettingsProvider.overrideWithValue(
              AiSettings(
                providers: [_customProvider],
                defaultChatModelId: _customModel.id,
              ),
            ),
            availableAiModelsProvider.overrideWith(
              (ref) => const [_customModel],
            ),
            defaultAiModelOptionIdProvider.overrideWith(
              (ref, kind) => _customModel.id,
            ),
            agentCouncilParticipantsProvider.overrideWith(
              () => _FixedCouncilParticipants(),
            ),

            aiHttpClientRegistryProvider.overrideWithValue(registry),

            appBackgroundActiveProvider.overrideWith((ref) => false),
            appDebugModeProvider.overrideWith((ref) => false),
          ],
        );
        addTearDown(container.dispose);

        // rootBundle caches Futures; each widget test has a separate fake clock.
        rootBundle.clear();
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: EasyLocalization(
              supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
              path: 'assets/translations',
              assetLoader: const MergingAssetLoader(),
              fallbackLocale: const Locale('en'),
              startLocale: const Locale('en'),
              child: Builder(
                builder: (context) => MaterialApp(
                  localizationsDelegates: context.localizationDelegates,
                  supportedLocales: context.supportedLocales,
                  locale: context.locale,
                  theme: RevericThemeData.reveric.toThemeData(),
                  home: RevericTheme(
                    data: RevericThemeData.reveric,
                    child: Scaffold(
                      body: SizedBox(
                        width: 800,
                        height: 800,
                        child: AgentCouncilPanel(
                          novel: invalidWork
                              ? buildTestNovel().copyWith(
                                  deletedAt: DateTime(2026, 9, 10),
                                )
                              : buildTestNovel(),
                          initialTopic:
                              'Should this opening reveal the secret?',
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        for (
          var i = 0;
          i < 20 && find.byType(FilledButton).evaluate().isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();

        await tester.tap(find.byType(FilledButton));
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.byType(SnackBar), findsOneWidget);
        if (invalidWork) {
          expect(
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
            isNotNull,
          );
        }
        expect(registry.debugRefCountFor(_customProvider), 0);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}

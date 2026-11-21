// 职责: 验证后台会话在无页面监听时执行、落库及即时处理 AskUser。
// 关联文件:
//   lib/shared/services/ai/headless_session_turn.dart
//   lib/shared/providers/ai_providers.dart
//   lib/shared/providers/novel_providers.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/fake_agent.dart';
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/database/app_database.dart' hide AppSettings;
import 'package:reveric/shared/models/agent_profile.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/ai_session_mode.dart';
import 'package:reveric/shared/models/ask_user_models.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/subagent.dart';
import 'package:reveric/shared/models/novel_agent_skill.dart';
import 'package:reveric/shared/providers/novel_agent_skill_providers.dart';
import 'package:reveric/shared/services/ai/prompt_template.dart';
import 'package:reveric/shared/providers/ai_mode_processing.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/prompt_template_provider.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/providers/subagent_providers.dart';
import 'package:reveric/shared/services/ai/headless_session_turn.dart';
import 'package:reveric/shared/services/ai/prompts/ai_prompt_service.dart';
import 'package:reveric/shared/services/novel_actions.dart';

class _EmptyGlobalSubAgents extends GlobalSubAgents {
  @override
  Future<List<SubAgent>> build() async => const [];
}

class _TestAppSettings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => AppSettings(
    theme: AppTheme.reveric,
    themeMode: AppThemeMode.light,
    language: 'zh_CN',
    aiSettings: AiSettings.defaults(),
  );
}

class _TestSkills extends InstalledAgentSkillsNotifier {
  @override
  Future<List<NovelAgentSkillModel>> build() async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(PromptTemplateService.loadAll);

  late Directory tempDir;
  late AppDatabase appDb;
  late ProviderContainer container;
  late List<Override> baseOverrides;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('reveric_headless_test_');
    appDb = AppDatabase.forTest(NativeDatabase.memory());
    baseOverrides = [
      appDatabaseProvider.overrideWithValue(appDb),
      novelActionsProvider.overrideWithValue(NovelActionsService(appDb)),

      // fake provider 是自定义 provider，Pro 门禁会在 AiClient.initialize 兜底拦下。
      aiPromptServiceProvider.overrideWithValue(AiPromptService()),
      globalSubAgentsProvider.overrideWith(_EmptyGlobalSubAgents.new),
      currentAiConfigProvider(
        providerId: _fakeProvider.id,
        model: _fakeModel,
      ).overrideWithValue(_fakeProvider),
      imageGenerationCallbackProvider.overrideWith((ref, workId) => null),
      imageEditCallbackProvider.overrideWith((ref, workId) => null),
      aiSettingsProvider.overrideWithValue(AiSettings.defaults()),
      appSettingsProvider.overrideWith(_TestAppSettings.new),
      installedAgentSkillsProvider.overrideWith(_TestSkills.new),
    ];
    container = ProviderContainer(overrides: baseOverrides);
  });

  tearDown(() async {
    container.dispose();
    await appDb.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'persists seed before chat panel restores the session from DB',
    () async {
      final databasePath = '${tempDir.path}/content.sqlite';
      const novelId = 'novel_1';
      const sessionId = 'ai_session_task_1';
      const seed = 'Run this task before the chat panel is opened.';

      final persistence = container.read(
        aiSessionPersistenceServiceProvider(
          novelId: novelId,
          databasePath: databasePath,
        ),
      );
      await persistence.createActiveSession(
        id: sessionId,
        title: 'Task',
        provider: 'provider_1',
        model: 'model_1',
        mode: AiSessionMode.chat.value,
        agentSlug: builtinAgentSlugOrchestrator,
      );
      container
          .read(aiChatSessionProvider(sessionId).notifier)
          .startNewSession(
            sessionId: sessionId,
            title: 'Task',
            providerId: 'provider_1',
            model: 'model_1',
            sessionMode: AiSessionMode.chat,
            agentSlug: builtinAgentSlugOrchestrator,
          );

      await prepareHeadlessSessionSeed(
        container,
        sessionId: sessionId,
        novelId: novelId,
        databasePath: databasePath,
        seed: seed,
      );

      final novelDb = container.read(
        novelContentDatabaseProvider(databasePath),
      );
      final persisted = await persistence.loadSessionMessages(
        sessionId: sessionId,
        novelDatabase: novelDb,
      );

      expect(persisted.messages, hasLength(1));
      expect(persisted.messages.single.role, AiMessageRole.user);
      expect(persisted.messages.single.content, seed);

      container
          .read(aiChatSessionProvider(sessionId).notifier)
          .loadSession(
            sessionId: sessionId,
            title: 'Task',
            messages: persisted.messages,
            providerId: 'provider_1',
            model: 'model_1',
            sessionMode: AiSessionMode.chat,
            agentSlug: builtinAgentSlugOrchestrator,
          );
      final restored = container.read(aiChatSessionProvider(sessionId));
      expect(restored.messages.single.content, seed);
    },
  );

  test(
    'restores persisted chat session and immediately auto-resolves headless AskUser',
    () async {
      final databasePath = '${tempDir.path}/headless_content.sqlite';
      const novelId = 'novel_1';
      const sessionId = 'ai_session_headless_1';
      const seed = 'Write first part';
      final now = DateTime(2026, 1, 1);
      final novel = Novel(
        id: novelId,
        title: 'Headless Novel',
        authorName: '',
        description: '',
        status: 'draft',
        type: 'novel',
        contentKind: contentKindNovel,
        contentDatabasePath: databasePath,
        wordCount: 0,
        category: '',
        tags: const [],
        draft: false,
        createdAt: now,
        updatedAt: now,
        deletedAt: notDeletedSentinel,
      );

      final persistence = container.read(
        aiSessionPersistenceServiceProvider(
          novelId: novelId,
          databasePath: databasePath,
        ),
      );
      await persistence.upsertSession(
        id: sessionId,
        title: 'Background chat',
        provider: _fakeProvider.id,
        model: _fakeModel,
        mode: AiSessionMode.chat.value,
        agentSlug: builtinAgentSlugOrchestrator,
      );
      final sessionLoaded = await ensureHeadlessSessionLoaded(
        container,
        sessionId: sessionId,
        novelId: novelId,
        databasePath: databasePath,
      );
      expect(sessionLoaded, isTrue);
      AskUserResult? askUserResult;
      container
          .read(aiChatRuntimeProvider(sessionId).notifier)
          .agent = FakeAgent.create(
        responder: (_) async {
          final runtime = container.read(
            aiChatRuntimeProvider(sessionId).notifier,
          );
          // 调用本次 headless runner 创建的真实回调，不能在测试中另造自动处理 handler。
          askUserResult = await runtime
              .activeAiService!
              .toolManager!
              .askUserCallback!(
                const AskUserRequest(
                  callId: 'headless_question',
                  questions: [
                    AskUserQuestion(
                      id: 'choice',
                      question: 'Choose a direction',
                      options: [
                        AskUserOption(label: 'Ordinary'),
                        AskUserOption(label: 'Recommended', recommended: true),
                      ],
                    ),
                    AskUserQuestion(
                      id: 'text',
                      question: 'Additional context?',
                    ),
                  ],
                ),
              )
              .timeout(const Duration(seconds: 2));
          expect(runtime.pendingAskUserRequests, isEmpty);
          return const FakeProviderClientResponse.text('done');
        },
      );
      container
          .read(aiModeProcessingTrackerProvider.notifier)
          .setForegroundSession(
            mode: AiSessionMode.chat,
            sessionId: sessionId,
            foreground: true,
          );

      final outcome = await runHeadlessSessionTurn(
        container,
        sessionId: sessionId,
        databasePath: databasePath,
        novel: novel,
        seed: seed,
      );

      expect(outcome.isCompleted, isTrue);
      expect(outcome.finalText, 'done');
      expect(askUserResult, isNotNull);
      expect(askUserResult!.ok, isTrue);
      expect(askUserResult!.cancelled, isFalse);
      expect(askUserResult!.resolution, AskUserResolution.timeout);
      expect(askUserResult!.answers!.single.questionId, 'choice');
      expect(askUserResult!.answers!.single.selectedOptions, ['Recommended']);
      expect(askUserResult!.unansweredQuestionIds, ['text']);
      final session = container.read(aiChatSessionProvider(sessionId));
      expect(session.providerId, _fakeProvider.id);
      expect(session.model, _fakeModel);
      expect(session.sessionMode, AiSessionMode.chat);

      final novelDb = container.read(
        novelContentDatabaseProvider(databasePath),
      );
      final persisted = await persistence.loadSessionMessages(
        sessionId: sessionId,
        novelDatabase: novelDb,
      );

      expect(persisted.messages.map((message) => message.role), [
        AiMessageRole.user,
        AiMessageRole.assistant,
      ]);
      expect(persisted.messages.first.content, seed);
      expect(persisted.messages.last.content, 'done');
    },
  );

  test(
    'pre-persisted seed still attributes tool writes to the seed turn',
    () async {
      final databasePath = '${tempDir.path}/task_content.sqlite';
      const novelId = 'novel_1';
      const sessionId = 'ai_session_task_turn';
      const seed = 'Run the task';
      final now = DateTime(2026, 1, 1);
      final novel = Novel(
        id: novelId,
        title: 'Task Novel',
        authorName: '',
        description: '',
        status: 'draft',
        type: 'novel',
        contentKind: contentKindNovel,
        contentDatabasePath: databasePath,
        wordCount: 0,
        category: '',
        tags: const [],
        draft: false,
        createdAt: now,
        updatedAt: now,
        deletedAt: notDeletedSentinel,
      );

      final persistence = container.read(
        aiSessionPersistenceServiceProvider(
          novelId: novelId,
          databasePath: databasePath,
        ),
      );
      await persistence.upsertSession(
        id: sessionId,
        title: 'Task',
        provider: _fakeProvider.id,
        model: _fakeModel,
        mode: AiSessionMode.chat.value,
        agentSlug: builtinAgentSlugOrchestrator,
      );
      // 与 startHeadlessRun 一致：seed 先落库，后台 turn 以 seedAlreadyAdded 运行。
      await prepareHeadlessSessionSeed(
        container,
        sessionId: sessionId,
        novelId: novelId,
        databasePath: databasePath,
        seed: seed,
      );
      final sessionLoaded = await ensureHeadlessSessionLoaded(
        container,
        sessionId: sessionId,
        novelId: novelId,
        databasePath: databasePath,
      );
      expect(sessionLoaded, isTrue);
      final toolDispatcher = FakeAgentToolDispatcher();
      container
          .read(aiChatRuntimeProvider(sessionId).notifier)
          .agent = FakeAgent.create(
        toolManager: toolDispatcher,
        responses: const [
          FakeProviderClientResponse.toolCalls([
            ToolCall(
              callId: 'call_write',
              toolName: 'Write',
              arguments: {'path': 'story_state', 'value': 'updated'},
            ),
          ]),
          FakeProviderClientResponse.text('done'),
        ],
      );

      final outcome = await runHeadlessSessionTurn(
        container,
        sessionId: sessionId,
        databasePath: databasePath,
        novel: novel,
        seed: seed,
        seedAlreadyAdded: true,
      );

      expect(outcome.isCompleted, isTrue);
      final context = toolDispatcher.capturedCalls.single.context!;
      expect(context.sourceSessionId, sessionId);
      expect(context.sourceTurnId, 'headless_seed_$sessionId');
      final seedMessage = container
          .read(aiChatSessionProvider(sessionId))
          .messages
          .singleWhere((message) => message.role == AiMessageRole.user);
      expect(seedMessage.id, context.sourceTurnId);
    },
  );

  test('drops cached agent before restoring an unloaded headless session', () {
    const sessionId = 'ai_session_stale_agent';
    final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
    runtime.agent = FakeAgent.create(
      responses: const [FakeProviderClientResponse.text('stale')],
    );

    invalidateStaleHeadlessAgent(container, sessionId: sessionId);

    expect(runtime.agent, isNull);
  });
}

const _fakeModel = 'fake-chat';

final _fakeProvider = AiProvider(
  asrModels: const [],
  audioModels: const [],
  videoModels: const [],
  id: 'fake_provider',
  name: 'Fake Provider',
  builtin: false,
  type: 'openai',
  enabled: true,
  apiKey: 'test-api-key',
  baseUrl: 'https://example.invalid/v1',
  models: [_fakeModel],
  imageModels: [],
  embeddingModels: [],
  temperature: 0.7,
  maxTurns: 8,
  proxyUrl: '',
  proxyUsername: '',
  proxyPassword: '',
  updatedAt: DateTime(2026, 1, 1),
  deletedAt: notDeletedSentinel,
);

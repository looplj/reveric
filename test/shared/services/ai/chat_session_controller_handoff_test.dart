// 职责: 验证引用接力的首次发送、来源隔离及失败重试使用同一目标会话。
// 关联文件:
//   lib/shared/services/ai/chat_session_controller.dart
//   lib/shared/services/ai/handoff_service.dart
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:reveric/shared/agent/agent.dart';
import 'package:reveric/shared/agent/fake_agent.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/ai_session_mode.dart';
import 'package:reveric/shared/models/subagent.dart';
import 'package:reveric/shared/providers/ai_mode_processing.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/providers/subagent_providers.dart';
import 'package:reveric/shared/providers/trace_providers.dart';
import 'package:reveric/shared/services/ai/chat_prompt_builder.dart';
import 'package:reveric/shared/services/ai/chat_session_controller.dart';
import 'package:reveric/shared/services/ai/handoff_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:reveric/shared/services/ai/prompts/ai_prompt_service.dart';
import 'package:reveric/shared/services/ai/trace_reporter_service.dart';
import 'package:reveric/shared/services/anonymous_outbox_service.dart';
import 'package:reveric/shared/services/device_id_service.dart';
import 'package:reveric/shared/services/novel_actions.dart';

import '../../../helpers/novel_fixture.dart';

class _EmptyGlobalSubAgents extends GlobalSubAgents {
  @override
  Future<List<SubAgent>> build() async => const [];
}

Future<void> _seedMaterializationWork(
  AppDatabase db,
  String id,
  String path,
) async {
  final now = DateTime(2026);
  await db
      .into(db.novels)
      .insert(
        Novel(
          id: id,
          title: 'Test Novel',
          authorName: '',
          description: '',
          status: 'draft',
          type: 'original',
          contentKind: 'novel',
          contentDatabasePath: path,
          wordCount: 0,
          category: '',
          tags: const [],
          draft: false,
          createdAt: now,
          updatedAt: now,
          deletedAt: notDeletedSentinel,
        ),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const novelId = 'novel_materialization';
  const signal = '__handoff_draft__controller_continuation';
  late AppDatabase appDb;
  late ProviderContainer container;
  late String databasePath;
  late DefaultChatComposerStore store;
  late String activeId;
  late FakeProviderClient client;
  late Agent agent;
  late String composer;
  late List<String> adopted;
  var rejectAdoption = false;
  setUp(() async {
    final tempDir = await Directory.systemTemp.createTemp(
      'reveric_chat_materialization_test_',
    );
    appDb = AppDatabase.forTest(NativeDatabase.memory());
    databasePath = '${tempDir.path}/content.sqlite';
    await _seedMaterializationWork(appDb, novelId, databasePath);
    final traceHttpClient = http.Client();
    final traceOutbox = AnonymousOutboxService(
      database: appDb,
      httpClient: traceHttpClient,
      getBaseUrl: () => null,
      getEnabled: () => false,
      autoFlush: false,
    );
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(appDb),
        novelActionsProvider.overrideWithValue(NovelActionsService(appDb)),

        // fake provider 是自定义 provider，Pro 门禁会在 AiClient.initialize 兜底拦下。
        aiSettingsProvider.overrideWithValue(
          AiSettings(
            providers: [_materializationProvider],
            defaultChatModelId:
                '${_materializationProvider.id}::$_materializationModel',
          ),
        ),
        imageGenerationCallbackProvider.overrideWith((ref, workId) => null),
        imageEditCallbackProvider.overrideWith((ref, workId) => null),
        globalSubAgentsProvider.overrideWith(_EmptyGlobalSubAgents.new),
        traceReporterServiceProvider.overrideWithValue(
          TraceReporterService(
            deviceIdService: _MaterializationDeviceIdService(),
            outbox: traceOutbox,
          ),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      traceOutbox.dispose();
      traceHttpClient.close();
      await appDb.close();
      await tempDir.delete(recursive: true);
    });

    activeId = signal;
    adopted = [];
    rejectAdoption = false;
    composer = 'Work on the next scene';
    client = FakeProviderClient(
      responses: const [FakeProviderClientResponse.text('done')],
    );
    agent = FakeAgent.create(
      client: client,
      toolManager: FakeAgentToolDispatcher(),
    );
    await appDb.aiChatSessionDao.upsert(
      id: 'source',
      novelId: novelId,
      title: 'Old topic',
    );
    final content = container.read(novelContentDatabaseProvider(databasePath));
    await content.aiChatMessageDao.upsertSessionMessages(
      messages: [
        AiChatMessagesCompanion.insert(
          id: 'old-message',
          sessionId: 'source',
          role: 'user',
          content: const Value('SECRET OLD HISTORY'),
        ),
      ],
    );
    final source = await loadSessionContinuationSource(
      database: appDb,
      contentDatabase: content,
      workId: novelId,
      sessionId: 'source',
    );
    store = DefaultChatComposerStore()
      ..pendingHandoff = buildSessionContinuation(
        source: source!,
        initialText: composer,
      );
    container
        .read(aiChatSessionProvider(signal).notifier)
        .startNewSession(
          sessionId: signal,
          providerId: _materializationProvider.id,
          model: _materializationModel,
          sessionMode: AiSessionMode.chat,
          agentSlug: 'orchestrator',
        );
  });

  ChatSessionController controller() => ChatSessionController(
    container: container,
    scope: ChatScope(
      activeSessionId: activeId,
      novel: buildTestNovel(id: novelId, databasePath: databasePath),
      databasePath: databasePath,
    ),
    host: ChatHost(
      clearComposer: () => composer = '',
      focusComposer: () {},
      openModelSelector: () {},
      resetScroll: () {},
      isMounted: () => true,
      restoreComposerText: (text) => composer = text,
      onActiveSessionIdChanged: (id) async {
        if (rejectAdoption) {
          throw StateError('adoption failed');
        }
        activeId = id!;
        adopted.add(id);
        container
            .read(aiModeProcessingTrackerProvider.notifier)
            .setForegroundSession(
              mode: AiSessionMode.chat,
              sessionId: id,
              foreground: true,
            );
        container.read(aiChatRuntimeProvider(id).notifier).agent = agent;
      },
    ),
    store: store,
    promptBuilder: ChatPromptBuilder(),
    availableSubAgents: const [],
    aiPromptService: AiPromptService(),
    promptContext: AiSessionContext(
      databasePath: databasePath,
      novelName: 'Test Novel',
    ),
  );
  test(
    'draft is read only; source-only first send creates an independent top-level chat',
    () async {
      expect(
        (await appDb.aiChatSessionDao.listForTools(
          workId: novelId,
        )).map((s) => s.id),
        ['source'],
      );
      final sourceBefore = await container
          .read(novelContentDatabaseProvider(databasePath))
          .aiChatMessageDao
          .getBySession('source');
      composer = '';
      await controller().send(composer);
      expect(adopted, hasLength(1));
      final target = await appDb.aiChatSessionDao.getById(activeId);
      expect(target!.parentId, isNull);
      expect(target.mode, 'chat');
      expect(target.reasoningEffort, isNull);
      expect(store.pendingHandoff, isNull);
      final inputs = client.capturedStreamRequests
          .expand((r) => r.messages)
          .map((m) => m.content)
          .join('\n');
      expect(inputs, contains(sessionContinuationInstruction));
      expect(inputs, contains('session_id="source"'));
      expect(inputs, isNot(contains('SECRET OLD HISTORY')));
      expect(inputs, isNot(contains('## Summary')));
      final sourceAfter = await container
          .read(novelContentDatabaseProvider(databasePath))
          .aiChatMessageDao
          .getBySession('source');
      expect(sourceAfter, sourceBefore);
      final saved = await container
          .read(novelContentDatabaseProvider(databasePath))
          .aiChatMessageDao
          .getBySession(activeId);
      expect(saved.any((m) => m.content.contains('ai-session:source')), true);
    },
  );
  test(
    'failed adoption retains draft and retry adopts the already materialized B',
    () async {
      rejectAdoption = true;
      await controller().send(composer);
      expect(composer, 'Work on the next scene');
      expect(store.pendingHandoff!.sourceSessionId, 'source');
      expect(
        await appDb.aiChatSessionDao.listForTools(workId: novelId),
        hasLength(2),
      );
      rejectAdoption = false;
      await controller().send(composer);
      expect(adopted, hasLength(1));
      expect(
        await appDb.aiChatSessionDao.listForTools(workId: novelId),
        hasLength(2),
      );
      expect(store.pendingHandoff, isNull);
    },
  );
  test(
    'failed model turn restores input and source; retry stays in B',
    () async {
      client = FakeProviderClient(
        responder: (_) => throw StateError('fake request failure'),
      );
      agent = FakeAgent.create(
        client: client,
        toolManager: FakeAgentToolDispatcher(),
      );
      await controller().send(composer);
      final targetId = activeId;
      expect(composer, 'Work on the next scene');
      expect(store.pendingHandoff!.sourceSessionId, 'source');
      expect(adopted, hasLength(1));
      store.sendGuardUntil = null;
      agent = FakeAgent.create(
        client: FakeProviderClient(),
        toolManager: FakeAgentToolDispatcher(),
      );
      container.read(aiChatRuntimeProvider(activeId).notifier).agent = agent;
      await controller().send(composer);
      expect(activeId, targetId);
      expect(adopted, hasLength(1));
      expect(
        await appDb.aiChatSessionDao.listForTools(workId: novelId),
        hasLength(2),
      );
      expect(store.pendingHandoff, isNull);
    },
  );
}

const _materializationModel = 'fake-chat';

final _materializationProvider = AiProvider(
  asrModels: const [],
  audioModels: const [],
  videoModels: const [],
  id: 'fake_provider_materialization',
  name: 'Fake Provider',
  builtin: false,
  type: 'openai',
  enabled: true,
  apiKey: 'test-api-key',
  baseUrl: 'https://example.invalid/v1',
  models: const [_materializationModel],
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

class _MaterializationDeviceIdService extends DeviceIdService {
  @override
  Future<String> getOrCreate() async => 'materialization-device';
}

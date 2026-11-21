// 职责: 验证聊天回滚、用户排队、子任务通知调度及普通交互在异步执行中的边界。
// 关联文件:
//   lib/shared/services/ai/chat_session_controller.dart
//   lib/shared/agent/agent.dart
//   lib/shared/agent/fake_agent.dart
//   lib/shared/agent/client/provider_history_preflight.dart
//   lib/shared/models/ai_chat_models.dart
//   lib/shared/providers/ai_providers.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
import '../../../helpers/plugin_host.dart';
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/agent/agent.dart';
import 'package:reveric/shared/agent/agent_hook.dart';
import 'package:reveric/shared/agent/agent_context_manager.dart';
import 'package:reveric/shared/services/ai/session_persistence.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/agent/client/provider_history_preflight.dart';
import 'package:reveric/shared/agent/fake_agent.dart';
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/daos/todo_dao.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/ai_session_mode.dart';
import 'package:reveric/shared/models/novel_workspace.dart';
import 'package:reveric/shared/models/subagent.dart';
import 'package:reveric/shared/providers/agent_skill_providers.dart';
import 'package:reveric/shared/providers/ai_mode_processing.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/providers/subagent_providers.dart';
import 'package:reveric/shared/providers/todo_providers.dart';
import 'package:reveric/shared/providers/trace_providers.dart';
import 'package:reveric/shared/services/ai/chat_prompt_builder.dart';
import 'package:reveric/shared/services/ai/chat_session_controller.dart';
import 'package:reveric/shared/services/ai/chat_turn_runner.dart';
import 'package:reveric/shared/services/ai/chat_agent_tool_dispatcher.dart';
import 'package:reveric/shared/services/ai/spawn_agent_handler.dart';
import 'package:reveric/shared/services/ai/tools.dart'
    show
        ToolExecutionContext,
        AskUserRequest,
        AskUserQuestion,
        AskUserResult,
        AskUserAnswer;
import 'package:reveric/shared/services/ai/prompts/ai_prompt_service.dart';
import 'package:reveric/shared/services/ai/trace_reporter_service.dart';
import 'package:reveric/shared/services/anonymous_outbox_service.dart';
import 'package:reveric/shared/services/device_id_service.dart';
import 'package:reveric/shared/services/novel_actions.dart';

import '../../../helpers/novel_fixture.dart';
import '../../../helpers/spawn_agent_runtime_fixture.dart';

class _CompletionEndHook extends AgentHook {
  _CompletionEndHook(this.callback, {this.start});
  final Future<void> Function() callback;
  final Future<void> Function()? start;

  @override
  Future<HookAction<String>> onStart(String task) async {
    await start?.call();
    return const HookAction.proceed();
  }

  @override
  Future<void> onEnd() => callback();
}

class _FailingHistoryPersistence extends AiSessionPersistenceService {
  _FailingHistoryPersistence(super.database, super.novelId);

  @override
  Future<void> saveMessages({
    required String sessionId,
    required List<AiMessage> messages,
    required NovelContentDatabase novelDatabase,
    AgentContextSnapshot? contextSnapshot,
  }) async {
    throw StateError('injected history persistence failure');
  }
}

class _EmptyGlobalSubAgents extends GlobalSubAgents {
  @override
  Future<List<SubAgent>> build() async => const [];
}

class _InFlightToolFixture {
  _InFlightToolFixture({
    required this.container,
    required this.sessionId,
    required this.client,
    required this.agent,
    required this.toolStarted,
    required this.releaseTool,
    required this.processFuture,
  });

  final ProviderContainer container;
  final String sessionId;
  final FakeProviderClient client;
  final Agent agent;
  final Completer<void> toolStarted;
  final Completer<void> releaseTool;
  final Future<void> processFuture;
}

Future<_InFlightToolFixture> _startInFlightToolTurn(
  ProviderContainer container, {
  required String sessionId,
}) async {
  final toolStarted = Completer<void>();
  final releaseTool = Completer<void>();
  final client = FakeProviderClient(
    responses: const [
      FakeProviderClientResponse.toolCalls([
        ToolCall(callId: 'ask_user_1', toolName: 'AskUser', arguments: {}),
      ]),
      FakeProviderClientResponse.text('done'),
    ],
    repeatLastResponse: false,
  );
  final agent = FakeAgent.create(
    client: client,
    toolManager: FakeAgentToolDispatcher(
      tools: {
        'AskUser': FakeAgentTool(
          def: ToolDef(
            name: 'AskUser',
            description: 'Waits for a simulated user answer.',
            inputSchema: const {'type': 'object'},
          ),
          handler: (_, _) async {
            toolStarted.complete();
            await releaseTool.future;
            return {'answer': 'received'};
          },
        ),
      },
    ),
  );

  // markLoaded 而非 loadSession：后者读取 aiSettings 会在单测环境异步打开真实
  // App DB，其错误会在测试完成后触发（"failed after it had already completed"），
  // 污染同文件后续用例。本 fixture 只需会话被标记为已加载。
  container.read(aiChatSessionProvider(sessionId).notifier).markLoaded();
  final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
  runtime.agent = agent;
  runtime.startRequest();

  final processFuture = agent.process('initial request').drain<void>();
  await toolStarted.future;
  expect(agent.isProcessing, isTrue);

  return _InFlightToolFixture(
    container: container,
    sessionId: sessionId,
    client: client,
    agent: agent,
    toolStarted: toolStarted,
    releaseTool: releaseTool,
    processFuture: processFuture,
  );
}

ChatSessionController _buildController(
  ProviderContainer container, {
  required String sessionId,
  required ChatComposerStore store,
  String? activeSessionId,
  void Function()? clearComposer,
  void Function(String text)? restoreComposerText,
  bool Function()? isMounted,
  String? databasePath,
  void Function(Agent agent)? onContextSettled,
  void Function(String)? onComposerWarning,
  AiPromptService? aiPromptService,
}) {
  return ChatSessionController(
    container: container,
    scope: ChatScope(
      activeSessionId: activeSessionId ?? sessionId,
      novel: buildTestNovel(),
      databasePath: databasePath,
      workspaceSection: NovelWorkspaceSection.novel_description,
    ),
    host: ChatHost(
      clearComposer: clearComposer ?? () {},
      focusComposer: () {},
      openModelSelector: () {},
      resetScroll: () {},
      isMounted: isMounted ?? () => true,
      restoreComposerText: restoreComposerText,

      onContextSettled: onContextSettled,
      onComposerWarning: onComposerWarning,
    ),
    store: store,
    promptBuilder: ChatPromptBuilder(),
    availableSubAgents: const [],
    aiPromptService: aiPromptService ?? AiPromptService(),
    promptContext: const AiSessionContext(
      databasePath: null,
      novelName: 'Test Novel',
    ),
  );
}

/// 模拟 hooks dispose 后仍可读、但任何 value setter 都会触发断言的 store。
class _DisposedChatComposerStore implements ChatComposerStore {
  @override
  List<AiContextReference> get attachedReferences => const [];
  @override
  set attachedReferences(List<AiContextReference> value) {
    throw StateError('disposed composer store was written');
  }

  @override
  PendingChatHandoff? get pendingHandoff => null;
  @override
  set pendingHandoff(PendingChatHandoff? value) {
    throw StateError('disposed composer store was written');
  }

  @override
  QueuedChatMessage? get queuedMessage => null;
  @override
  set queuedMessage(QueuedChatMessage? value) {
    throw StateError('disposed composer store was written');
  }

  @override
  QueuedChatMessage? queuedMessageForSession(String? sessionId) => null;

  @override
  void setQueuedMessageForSession(
    String? sessionId,
    QueuedChatMessage? message,
  ) {
    throw StateError('disposed composer store was written');
  }

  @override
  DateTime? get sendGuardUntil => null;
  @override
  set sendGuardUntil(DateTime? value) {
    throw StateError('disposed composer store was written');
  }
}

/// 模拟桌面面板：controller 可能仍绑定临时 session，但队列已经归属真实 session。
class _SessionScopedChatComposerStore extends DefaultChatComposerStore {
  _SessionScopedChatComposerStore(this.boundSessionId);

  final String? boundSessionId;
  final Map<String?, QueuedChatMessage> queues = {};

  @override
  QueuedChatMessage? get queuedMessage => queues[boundSessionId];

  @override
  set queuedMessage(QueuedChatMessage? value) =>
      setQueuedMessageForSession(boundSessionId, value);

  @override
  QueuedChatMessage? queuedMessageForSession(String? sessionId) =>
      queues[sessionId];

  @override
  void setQueuedMessageForSession(
    String? sessionId,
    QueuedChatMessage? message,
  ) {
    if (message == null) {
      queues.remove(sessionId);
    } else {
      queues[sessionId] = message;
    }
  }
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

  group('completion scheduling', () {
    late SpawnAgentRuntimeFixture fixture;
    late ProviderContainer container;
    late AiChatRuntime runtime;
    late ChatSessionController controller;
    late DefaultChatComposerStore store;
    late NovelContentService content;
    late WorkingOverlayService overlay;
    const completionPath = 'completion-writes';
    var callSequence = 0;

    setUp(() async {
      fixture = SpawnAgentRuntimeFixture();
      await fixture.initialize();
      content = NovelContentService(fixture.novelDb);
      overlay = WorkingOverlayService(
        fixture.novelDb,
        content,
        novelActionsService: NovelActionsService(fixture.appDb),
      );
      container = ProviderContainer(
        overrides: [
          aiSettingsProvider.overrideWithValue(AiSettings.defaults()),
          aiAgentAutoAcceptProvider.overrideWithValue(false),
          appDatabaseProvider.overrideWithValue(fixture.appDb),
          appSettingsDatabaseProvider.overrideWithValue(fixture.appDb),
          novelContentDatabaseProvider(
            completionPath,
          ).overrideWithValue(fixture.novelDb),
          novelContentServiceProvider(
            completionPath,
          ).overrideWithValue(content),
          workingOverlayServiceProvider(
            completionPath,
          ).overrideWithValue(overlay),
        ],
      );
      container
          .read(aiModeProcessingTrackerProvider.notifier)
          .setForegroundSession(
            mode: AiSessionMode.chat,
            sessionId: 'parent',
            foreground: true,
          );
      final session = container.read(aiChatSessionProvider('parent').notifier);
      session.markLoaded();
      session.addUserMessage('First delegation', id: 'origin');
      session.addUserMessage('Second delegation', id: 'other');
      runtime = container.read(aiChatRuntimeProvider('parent').notifier);
      store = DefaultChatComposerStore();
      controller = _buildController(
        container,
        sessionId: 'parent',
        store: store,
      );
      callSequence = 0;
    });

    tearDown(() async {
      container.dispose();
      await fixture.dispose();
    });

    SpawnAgentRun startChild(ControlledSubAgent child, String origin) =>
        runtime.startSubAgent(
          handler: child.handler,
          input: {'agent': 'Writer', 'name': 'writer', 'task': 'Write'},
          callId: 'completion_${callSequence++}',
          context: ToolExecutionContext(
            sourceSessionId: 'parent',
            sourceTurnId: origin,
          ),
          background: true,
        );

    Future<void> settle() async {
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        if (!runtime.hasActiveRequest &&
            container
                .read(aiChatRuntimeProvider('parent'))
                .subAgents
                .pending
                .isEmpty) {
          return;
        }
      }
      fail('Completion scheduling did not settle');
    }

    test(
      'rollback during a real background Spawn startup settles parent and preserves earlier initialization',
      () async {
        container.listen(aiChatRuntimeProvider('parent'), (_, _) {});
        container.listen(aiChatSessionProvider('parent'), (_, _) {});
        final earlier = fixture.child(blockInitialization: true);
        final affected = fixture.child(blockInitialization: true);
        final earlierRun = startChild(earlier, 'origin');
        await earlier.initializationEntered.future;
        final parent = FakeAgent.create(
          responses: const [
            FakeProviderClientResponse.toolCalls([
              ToolCall(
                callId: 'awaiting_start',
                toolName: 'SpawnAgent',
                arguments: {
                  'agent': 'Writer',
                  'name': 'Author',
                  'task': 'Write',
                  'background': true,
                },
              ),
            ]),
          ],
          toolManager: ChatAgentToolDispatcher(
            inner: FakeAgentToolDispatcher(),
            subAgents: runtime.subAgents,
            resumeSubAgent: (sessionId, message, callId, context) =>
                runtime.resumeSubAgent(
                  handler: affected.handler,
                  sessionId: sessionId,
                  message: message,
                  callId: callId,
                  context: context,
                ),
            startSubAgent: (input, callId, context, {required background}) =>
                runtime.startSubAgent(
                  handler: affected.handler,
                  input: input,
                  callId: callId,
                  context: context,
                  background: background,
                ),
          ),
          allowedTools: ['SpawnAgent'],
        );
        runtime.agent = parent;
        final request = runtime.startRequest();
        final parentWork =
            ChatTurnRunner(
                  container: container,
                  novel: buildTestNovel(),
                  databasePath: null,
                  aiPromptService: AiPromptService(),
                  promptContext: const AiSessionContext(),
                )
                .runTurn(
                  'Second delegation',
                  requestId: request,
                  sessionId: 'parent',
                  userMessageId: 'other',
                )
                .whenComplete(() => runtime.markRequestIdle(request));
        await affected.initializationEntered.future;
        final rollback = controller.rollbackTurnAndPrepareResend('other');
        expect(
          container
              .read(aiChatRuntimeProvider('parent'))
              .isSessionMutationInFlight,
          isTrue,
        );
        affected.initializationRelease.complete();
        earlier.initializationRelease.complete();
        try {
          expect(
            await rollback.timeout(const Duration(seconds: 1)),
            'Second delegation',
          );
          expect((await parentWork).isCancelled, isTrue);
          expect(affected.client.capturedStreamRequests, isEmpty);
          expect(affected.releases, 1);
          expect(
            container.read(aiChatRuntimeProvider('parent')).subAgents.pending,
            isEmpty,
          );
          await earlier.requestEntered.future;
          expect(earlierRun.status, SpawnAgentRunStatus.running);
          expect(earlier.client.cancelCallCount, 0);
          expect(
            container
                .read(aiChatSessionProvider('parent'))
                .messages
                .map((m) => m.id),
            ['origin'],
          );
        } finally {
          // Also cleans up the unfixed deadlock after the bounded red assertion.
          runtime.subAgents.cancelAll(source: 'test_cleanup');
          if (!earlier.response.isCompleted) {
            earlier.finish();
          }
          if (!affected.response.isCompleted) {
            affected.finish();
          }
          await parentWork;
          await rollback;
          await runtime.subAgents.stopAll(source: 'test_cleanup');
        }
      },
    );

    test(
      'background tool survives a new user turn, delivers once and rolls back by original ownership',
      () async {
        // Simulate the open chat; separate lifecycle regressions cover no watchers.
        container.listen(aiChatRuntimeProvider('parent'), (_, _) {});
        container.listen(aiChatSessionProvider('parent'), (_, _) {});
        final session = container.read(
          aiChatSessionProvider('parent').notifier,
        );
        session.replaceMessages([
          AiMessage.user(id: 'origin', content: 'Write chapter one'),
        ]);
        final firstChapter = await content.createChapter(
          siblingOrder: 1,
          title: 'First',
        );
        final secondChapter = await content.createChapter(
          siblingOrder: 2,
          title: 'Second',
        );
        final childEntered = Completer<void>();
        final releaseChild = Completer<void>();
        final writes = <(String, String?)>[];
        var resourcesReleased = 0;
        late FakeAgentToolDispatcher childTools;
        Future<void> write(
          String chapter,
          String before,
          String after,
          ToolExecutionContext context,
        ) async {
          writes.add((after, context.sourceTurnId));
          await overlay.stageTextChange(
            resourcePath: 'chapters/$chapter/content',
            resourceType: 'chapters',
            resourceId: chapter,
            field: 'content',
            oldText: before,
            newText: after,
            source: workingChangeSourceAi,
            sourceSessionId: context.sourceSessionId,
            sourceTurnId: context.sourceTurnId,
          );
        }

        childTools = FakeAgentToolDispatcher(
          tools: {
            'Write': FakeAgentTool(
              def: const ToolDef(
                name: 'Write',
                description: 'Controlled child write',
                inputSchema: {'type': 'object'},
              ),
              handler: (_, _) async {
                childEntered.complete();
                await releaseChild.future;
                await write(
                  firstChapter,
                  '',
                  'Child draft',
                  childTools.capturedCalls.last.context!,
                );
                return {'ok': true};
              },
            ),
          },
        );
        final template = fixture.child().handler;
        final childHandler = SpawnAgentHandler(
          pluginHost: emptyPluginHost(),
          codemodeScheduler: fixture.codemodeScheduler,
          workContext: template.workContext,
          availableSubAgents: template.availableSubAgents,
          agentConfig: template.agentConfig,
          defaultProviderId: 'provider',
          defaultModel: 'model',
          parentSessionId: 'parent',
          persistence: fixture.persistence,
          novelDatabase: fixture.novelDb,
          contextSupplementForSession: (_) async => [],
          defaultAllowedToolNames: () => ['Write'],
          resourcesResolver:
              ({
                required providerId,
                required model,
                required subSessionId,
                required sourceSessionId,
              }) async => SpawnAgentResources(
                client: FakeProviderClient(
                  responses: const [
                    FakeProviderClientResponse.toolCalls([
                      ToolCall(
                        callId: 'child_write',
                        toolName: 'Write',
                        arguments: {},
                      ),
                    ]),
                    FakeProviderClientResponse.text('Chapter one written'),
                  ],
                ),
                toolManager: childTools,
                release: () => resourcesReleased++,
              ),
        );
        late FakeAgentToolDispatcher parentTools;
        parentTools = FakeAgentToolDispatcher(
          tools: {
            'Write': FakeAgentTool(
              def: const ToolDef(
                name: 'Write',
                description: 'Controlled parent write',
                inputSchema: {'type': 'object'},
              ),
              handler: (input, _) async {
                final review = input['review'] == true;
                await write(
                  review ? firstChapter : secondChapter,
                  review ? 'Child draft' : '',
                  review ? 'Reviewed draft' : 'Second chapter plan',
                  parentTools.capturedCalls.last.context!,
                );
                return {'ok': true};
              },
            ),
          },
        );
        final client = FakeProviderClient(
          responses: const [
            FakeProviderClientResponse.toolCalls([
              ToolCall(
                callId: 'spawn_background',
                toolName: 'SpawnAgent',
                arguments: {
                  'agent': 'Writer',
                  'name': 'Author',
                  'task': 'Write chapter one',
                },
              ),
            ]),
            FakeProviderClientResponse.text('Chapter one is being written.'),
            FakeProviderClientResponse.toolCalls([
              ToolCall(
                callId: 'discuss_second',
                toolName: 'Write',
                arguments: {},
              ),
            ]),
            FakeProviderClientResponse.text('Here is the second chapter plan.'),
            FakeProviderClientResponse.toolCalls([
              ToolCall(
                callId: 'review_first',
                toolName: 'Write',
                arguments: {'review': true},
              ),
            ]),
            FakeProviderClientResponse.text('Chapter one has been reviewed.'),
          ],
          repeatLastResponse: false,
        );
        runtime.agent = FakeAgent.create(
          client: client,
          toolManager: ChatAgentToolDispatcher(
            inner: parentTools,
            subAgents: runtime.subAgents,
            resumeSubAgent: (sessionId, message, callId, context) =>
                runtime.resumeSubAgent(
                  handler: childHandler,
                  sessionId: sessionId,
                  message: message,
                  callId: callId,
                  context: context,
                ),
            startSubAgent: (input, callId, context, {required background}) =>
                runtime.startSubAgent(
                  handler: childHandler,
                  input: input,
                  callId: callId,
                  context: context,
                  background: background,
                ),
          ),
          allowedTools: ['SpawnAgent', 'Write'],
        );
        final integratedController = _buildController(
          container,
          sessionId: 'parent',
          store: store,
          databasePath: completionPath,
        );
        integratedController.enableCompletionDelivery('parent');
        final runner = ChatTurnRunner(
          container: container,
          novel: buildTestNovel(),
          databasePath: completionPath,
          aiPromptService: AiPromptService(),
          promptContext: const AiSessionContext(),
        );
        final initialRequest = runtime.startRequest();
        final initial = await runner.runTurn(
          'Write chapter one',
          requestId: initialRequest,
          sessionId: 'parent',
          userMessageId: 'origin',
        );
        runtime.markRequestIdle(initialRequest);
        await childEntered.future;
        expect(initial.isFailed, isFalse);
        expect(
          container.read(aiChatRuntimeProvider('parent')).backgroundAgentCount,
          1,
        );
        expect(
          container.read(aiChatRuntimeProvider('parent')).isRequestInFlight,
          isFalse,
        );
        expect(resourcesReleased, 0);

        session.addUserMessage('Discuss chapter two', id: 'other');
        final nextRequest = runtime.startRequest();
        await runner.runTurn(
          'Discuss chapter two',
          requestId: nextRequest,
          sessionId: 'parent',
          userMessageId: 'other',
        );
        runtime.markRequestIdle(nextRequest);
        expect(writes, [('Second chapter plan', 'other')]);
        expect(
          container.read(aiChatRuntimeProvider('parent')).backgroundAgentCount,
          1,
        );
        releaseChild.complete();
        final runId = container
            .read(aiChatRuntimeProvider('parent'))
            .subAgents
            .runs
            .single
            .runId;
        await runtime.subAgents.waitForRun(runId);
        await settle();
        expect(writes, [
          ('Second chapter plan', 'other'),
          ('Child draft', 'origin'),
          ('Reviewed draft', 'origin'),
        ]);
        expect(resourcesReleased, 1);
        expect(client.capturedStreamRequests, hasLength(6));
        final rawSpawnResults = runtime.agent!.contextManager.messages
            .expand((message) => message.blocks)
            .whereType<ToolResultBlock>()
            .where((block) => block.toolName == 'SpawnAgent')
            .toList();
        expect(rawSpawnResults, hasLength(1));
        expect(
          (rawSpawnResults.single.content.single as TextBlock).text,
          contains('"status":"running"'),
        );
        final history = container
            .read(aiChatSessionProvider('parent'))
            .messages;
        final notices = history
            .where(
              (message) =>
                  message.type == AiMessageType.system_remind &&
                  message.effectiveText.contains('subagent_completed'),
            )
            .toList();
        expect(notices, hasLength(1));
        expect(notices.single.id, isNot('origin'));
        expect(
          history
              .where(
                (message) =>
                    message.role == AiMessageRole.user &&
                    message.type != AiMessageType.system_remind,
              )
              .map((message) => message.id),
          ['origin', 'other'],
        );

        expect(
          await integratedController.rollbackTurnAndPrepareResend('other'),
          'Discuss chapter two',
        );
        expect((await content.getChapterById(secondChapter))!.content, '');
        expect(
          (await content.getChapterById(firstChapter))!.content,
          'Reviewed draft',
        );
        expect(
          await integratedController.rollbackTurnAndPrepareResend('origin'),
          'Write chapter one',
        );
        expect((await content.getChapterById(firstChapter))!.content, '');
        expect(
          container.read(aiChatSessionProvider('parent')).messages,
          isEmpty,
        );
        expect(
          container.read(aiChatRuntimeProvider('parent')).subAgents.pending,
          isEmpty,
        );
      },
    );

    test(
      'idle-parent rollback waits for an in-flight child write before restoring content',
      () async {
        final chapterId = await content.createChapter(
          siblingOrder: 1,
          title: 'Chapter',
        );
        final entered = Completer<void>();
        final release = Completer<void>();
        final template = fixture.child().handler;
        final writer = SpawnAgentHandler(
          pluginHost: emptyPluginHost(),
          codemodeScheduler: fixture.codemodeScheduler,
          workContext: template.workContext,
          availableSubAgents: template.availableSubAgents,
          agentConfig: template.agentConfig,
          defaultProviderId: 'provider',
          defaultModel: 'model',
          parentSessionId: 'parent',
          persistence: fixture.persistence,
          novelDatabase: fixture.novelDb,
          contextSupplementForSession: (_) async => [],
          defaultAllowedToolNames: () => ['Write'],
          resourcesResolver:
              ({
                required providerId,
                required model,
                required subSessionId,
                required sourceSessionId,
              }) async => SpawnAgentResources(
                client: FakeProviderClient(
                  responses: const [
                    FakeProviderClientResponse.toolCalls([
                      ToolCall(
                        callId: 'late_write',
                        toolName: 'Write',
                        arguments: {},
                      ),
                    ]),
                  ],
                ),
                toolManager: FakeAgentToolDispatcher(
                  tools: {
                    'Write': FakeAgentTool(
                      def: const ToolDef(
                        name: 'Write',
                        description: 'Controlled write',
                        inputSchema: {'type': 'object'},
                      ),
                      handler: (_, _) async {
                        entered.complete();
                        await release.future;
                        await overlay.stageTextChange(
                          resourcePath: 'chapters/$chapterId/content',
                          resourceType: 'chapters',
                          resourceId: chapterId,
                          field: 'content',
                          oldText: '',
                          newText: 'Late child draft',
                          source: workingChangeSourceAi,
                          sourceSessionId: 'parent',
                          sourceTurnId: 'other',
                        );
                        return {'ok': true};
                      },
                    ),
                  },
                ),
                release: () {},
              ),
        );
        final run = runtime.startSubAgent(
          handler: writer,
          input: {'agent': 'Writer', 'name': 'writer', 'task': 'Write'},
          callId: 'actual_write',
          background: true,
          context: ToolExecutionContext(
            sourceSessionId: 'parent',
            sourceTurnId: 'other',
          ),
        );
        await entered.future;
        final rollbackController = _buildController(
          container,
          sessionId: 'parent',
          store: store,
          databasePath: completionPath,
        );
        var returned = false;
        final rollback = rollbackController.rollbackTurnAndPrepareResend(
          'other',
        )..then((_) => returned = true);
        await Future<void>.delayed(Duration.zero);
        expect(returned, isFalse);
        expect(run.status, SpawnAgentRunStatus.stopping);
        release.complete();
        expect(await rollback, 'Second delegation');
        expect((await content.getChapterById(chapterId))!.content, '');
        expect(
          container.read(aiChatRuntimeProvider('parent')).subAgents.pending,
          isEmpty,
        );
      },
    );

    test(
      'idle-parent rollback waits for child persistence and retains earlier runs',
      () async {
        final earlier = fixture.child();
        final selected = fixture.child(blockSave: true);
        final earlierRun = startChild(earlier, 'origin');
        final selectedRun = startChild(selected, 'other');
        await Future.wait([
          earlier.requestEntered.future,
          selected.requestEntered.future,
        ]);
        var returned = false;
        final rollback = controller.rollbackTurnAndPrepareResend('other')
          ..then((_) => returned = true);
        await Future<void>.delayed(Duration.zero);
        expect(selectedRun.status, SpawnAgentRunStatus.stopping);
        expect(earlierRun.status, SpawnAgentRunStatus.running);
        selected.finish();
        await selected.saveEntered.future;
        expect(returned, isFalse);
        expect(
          container
              .read(aiChatSessionProvider('parent'))
              .messages
              .map((m) => m.id),
          ['origin', 'other'],
        );
        earlier.finish();
        await runtime.subAgents.waitForRun(earlierRun.runId);
        expect(
          container
              .read(aiChatRuntimeProvider('parent'))
              .subAgents
              .pending
              .single
              .run
              .runId,
          earlierRun.runId,
        );
        selected.saveRelease.complete();
        expect(await rollback, 'Second delegation');
        expect(selectedRun.status, SpawnAgentRunStatus.cancelled);
        expect(
          container
              .read(aiChatSessionProvider('parent'))
              .messages
              .map((m) => m.id),
          ['origin'],
        );
        expect(
          container
              .read(aiChatRuntimeProvider('parent'))
              .subAgents
              .pending
              .map((p) => p.run.runId),
          [earlierRun.runId],
        );
        runtime.subAgents.takeCompletion(earlierRun.runId);
      },
    );

    test(
      'rollback cancels initializing child and revokes a completed pending notice',
      () async {
        final initializing = fixture.child(blockInitialization: true);
        final completed = fixture.child();
        final initializingRun = startChild(initializing, 'other');
        final completedRun = startChild(completed, 'other');
        await initializing.initializationEntered.future;
        await completed.requestEntered.future;
        completed.finish();
        await runtime.subAgents.waitForRun(completedRun.runId);
        var returned = false;
        final rollback = controller.rollbackTurnAndPrepareResend('other')
          ..then((_) => returned = true);
        await Future<void>.delayed(Duration.zero);
        expect(returned, isFalse);
        expect(
          container.read(aiChatRuntimeProvider('parent')).subAgents.pending,
          isEmpty,
        );
        initializing.initializationRelease.complete();
        expect(await rollback, 'Second delegation');
        expect(initializingRun.status, SpawnAgentRunStatus.cancelled);
        expect(initializing.client.capturedStreamRequests, isEmpty);
        expect(
          container.read(aiChatRuntimeProvider('parent')).subAgents.pending,
          isEmpty,
        );
      },
    );

    test(
      'rollback derives truncated turns after all parent cleanup has finished',
      () async {
        final request = runtime.startRequest();
        var returned = false;
        final rollback = controller.rollbackTurnAndPrepareResend('other')
          ..then((_) => returned = true);
        await Future<void>.delayed(Duration.zero);
        expect(returned, isFalse);
        container
            .read(aiChatSessionProvider('parent').notifier)
            .addUserMessage('Accepted before cancellation settled', id: 'late');
        runtime.markRequestIdle(request, notifyOnComplete: false);
        expect(await rollback, 'Second delegation');
        expect(
          container
              .read(aiChatSessionProvider('parent'))
              .messages
              .map((m) => m.id),
          ['origin'],
        );
      },
    );

    test(
      'idle results coalesce by origin and serialize groups without UI watchers',
      () async {
        final children = [fixture.child(), fixture.child(), fixture.child()];
        final runs = [
          startChild(children[0], 'origin'),
          startChild(children[1], 'other'),
          startChild(children[2], 'origin'),
        ];
        await Future.wait(children.map((child) => child.requestEntered.future));
        expect(runtime.tryBeginSessionMutation(), isTrue);
        final turnIds = <String?>[];
        late FakeAgentToolDispatcher dispatcher;
        dispatcher = FakeAgentToolDispatcher(
          tools: {
            'Write': FakeAgentTool(
              def: const ToolDef(
                name: 'Write',
                description: 'Write',
                inputSchema: {'type': 'object'},
              ),
              handler: (_, _) async {
                turnIds.add(
                  dispatcher.capturedCalls.last.context!.sourceTurnId,
                );
                return {'ok': true};
              },
            ),
          },
        );
        final client = FakeProviderClient(
          responses: const [
            FakeProviderClientResponse.toolCalls([
              ToolCall(callId: 'w1', toolName: 'Write', arguments: {}),
            ]),
            FakeProviderClientResponse.text('First review'),
            FakeProviderClientResponse.toolCalls([
              ToolCall(callId: 'w2', toolName: 'Write', arguments: {}),
            ]),
            FakeProviderClientResponse.text('Second review'),
          ],
          repeatLastResponse: false,
        );
        runtime.agent = FakeAgent.create(
          client: client,
          toolManager: dispatcher,
        );
        var saved = <AiMessage>[];
        final settledRequests = <int>[];
        controller = _buildController(
          container,
          sessionId: 'parent',
          store: store,
          onContextSettled: (_) {
            saved = container.read(aiChatSessionProvider('parent')).messages;
            settledRequests.add(
              container.read(aiChatRuntimeProvider('parent')).requestSequence,
            );
          },
        );
        controller.enableCompletionDelivery('parent');
        for (var i = 0; i < children.length; i++) {
          children[i].finish('result $i');
          await runtime.subAgents.waitForRun(runs[i].runId);
        }
        final notices = container
            .read(aiChatRuntimeProvider('parent'))
            .subAgents
            .pending;
        expect(client.streamCallCount, 0);
        runtime.endSessionMutation();
        await settle();
        expect(turnIds, ['origin', 'other']);
        expect(client.streamCallCount, 4);
        expect(settledRequests, [1, 2]);
        final firstInput = client.capturedStreamRequests.first.messages;
        expect(
          firstInput.where((message) => message.id == notices[0].messageId),
          hasLength(1),
        );
        expect(
          firstInput.where((message) => message.id == notices[2].messageId),
          hasLength(1),
        );
        expect(
          firstInput.where((message) => message.id == notices[1].messageId),
          isEmpty,
        );
        expect(
          saved.where((message) => message.type == AiMessageType.system_remind),
          hasLength(3),
        );
        expect(
          saved.where(
            (message) =>
                message.role == AiMessageRole.user &&
                message.type != AiMessageType.system_remind,
          ),
          hasLength(2),
        );
        // 没有 watcher，任务与通知收尾后 runtime 可释放；重新加载不会重新唤醒。
        await container.pump();
        expect(container.exists(aiChatRuntimeProvider('parent')), isFalse);
        final freshRuntime = container.read(
          aiChatRuntimeProvider('parent').notifier,
        );
        expect(freshRuntime.hasActiveRequest, isFalse);
        expect(client.streamCallCount, 4);
      },
    );

    test(
      'notification arriving in Agent onEnd wakes only after the old request settles',
      () async {
        final child = fixture.child();
        final run = startChild(child, 'origin');
        await child.requestEntered.future;
        var endCount = 0;
        final inEnd = Completer<void>();
        final releaseEnd = Completer<void>();
        final client = FakeProviderClient(
          responses: const [
            FakeProviderClientResponse.text('Current reply'),
            FakeProviderClientResponse.text('Child review'),
          ],
          repeatLastResponse: false,
        );
        runtime.agent = FakeAgent.create(
          client: client,
          hooks: [
            _CompletionEndHook(() async {
              if (endCount++ == 0) {
                child.finish();
                await runtime.subAgents.waitForRun(run.runId);
                inEnd.complete();
                await releaseEnd.future;
              }
            }),
          ],
        );
        controller.enableCompletionDelivery('parent');
        final request = runtime.startRequest();
        final runner = ChatTurnRunner(
          container: container,
          novel: buildTestNovel(),
          databasePath: null,
          aiPromptService: AiPromptService(),
          promptContext: const AiSessionContext(),
        );
        final processing = runner.runTurn(
          'Second delegation',
          requestId: request,
          sessionId: 'parent',
          userMessageId: 'other',
        );
        await inEnd.future;
        expect(client.streamCallCount, 1);
        expect(
          container.read(aiChatRuntimeProvider('parent')).requestSequence,
          1,
        );
        releaseEnd.complete();
        await processing;
        expect(client.streamCallCount, 1);
        runtime.markRequestIdle(request, notifyOnComplete: false);
        await settle();
        expect(client.streamCallCount, 2);
      },
    );

    test(
      'Stop Reply waits for old execution cleanup before waking only for the child result',
      () async {
        container.listen(aiChatSessionProvider('parent'), (_, _) {});
        final child = fixture.child();
        final run = startChild(child, 'origin');
        await child.requestEntered.future;
        final parentEntered = Completer<void>();
        final releaseParent = Completer<void>();
        final oldClient = FakeProviderClient(
          responder: (_) async {
            parentEntered.complete();
            await releaseParent.future;
            return const FakeProviderClientResponse.text('Stopped work');
          },
        );
        runtime.agent = FakeAgent.create(client: oldClient);
        controller.enableCompletionDelivery('parent');
        final request = runtime.startRequest();
        final runner = ChatTurnRunner(
          container: container,
          novel: buildTestNovel(),
          databasePath: null,
          aiPromptService: AiPromptService(),
          promptContext: const AiSessionContext(),
        );
        final processing = runner.runTurn(
          'Second delegation',
          requestId: request,
          sessionId: 'parent',
          userMessageId: 'other',
        );
        await parentEntered.future;
        runtime.cancelRequest(request, source: AiChatCancelSource.stopButton);
        child.finish();
        await runtime.subAgents.waitForRun(run.runId);
        expect(
          container.read(aiChatRuntimeProvider('parent')).subAgents.pending,
          hasLength(1),
        );
        expect(runtime.hasActiveRequest, isTrue);
        expect(child.client.cancelCallCount, 0);
        releaseParent.complete();
        expect((await processing).isCancelled, isTrue);
        final resumedClient = FakeProviderClient();
        runtime.agent = FakeAgent.create(client: resumedClient);
        runtime.markRequestIdle(request, notifyOnComplete: false);
        await settle();
        final input = resumedClient.capturedStreamRequests.single.messages
            .where((message) => message.role == AgentMessageRole.user)
            .single;
        expect(input.content, contains('subagent_completed'));
        expect(input.content, isNot(contains('Second delegation')));
      },
    );

    test(
      'automatic review writes and completed child writes roll back with the original user message',
      () async {
        container.listen(aiChatSessionProvider('parent'), (_, _) {});
        final child = fixture.child();
        final run = startChild(child, 'origin');
        await child.requestEntered.future;
        final chapterId = await content.createChapter(
          siblingOrder: 1,
          title: 'Chapter',
        );
        await overlay.stageTextChange(
          resourcePath: 'chapters/$chapterId/content',
          resourceType: 'chapters',
          resourceId: chapterId,
          field: 'content',
          oldText: '',
          newText: 'Child draft',
          source: workingChangeSourceAi,
          sourceSessionId: 'parent',
          sourceTurnId: run.sourceTurnId,
        );
        late FakeAgentToolDispatcher dispatcher;
        dispatcher = FakeAgentToolDispatcher(
          tools: {
            'Write': FakeAgentTool(
              def: const ToolDef(
                name: 'Write',
                description: 'Write',
                inputSchema: {'type': 'object'},
              ),
              handler: (_, _) async {
                final context = dispatcher.capturedCalls.last.context!;
                await overlay.stageTextChange(
                  resourcePath: 'chapters/$chapterId/content',
                  resourceType: 'chapters',
                  resourceId: chapterId,
                  field: 'content',
                  oldText: 'Child draft',
                  newText: 'Reviewed draft',
                  source: workingChangeSourceAi,
                  sourceSessionId: context.sourceSessionId,
                  sourceTurnId: context.sourceTurnId,
                );
                return {'ok': true};
              },
            ),
          },
        );
        runtime.agent = FakeAgent.create(
          toolManager: dispatcher,
          responses: const [
            FakeProviderClientResponse.toolCalls([
              ToolCall(callId: 'review', toolName: 'Write', arguments: {}),
            ]),
            FakeProviderClientResponse.text('Reviewed'),
          ],
        );
        controller = _buildController(
          container,
          sessionId: 'parent',
          store: store,
          databasePath: completionPath,
        );
        controller.enableCompletionDelivery('parent');
        child.finish();
        await settle();
        expect(
          (await content.getChapterById(chapterId))!.content,
          'Reviewed draft',
        );
        final restored = await fixture.persistence.loadSessionMessages(
          sessionId: 'parent',
          novelDatabase: fixture.novelDb,
        );
        final reminderIndex = restored.messages.indexWhere(
          (message) => message.type == AiMessageType.system_remind,
        );
        final assistantIndex = restored.messages.indexWhere(
          (message) => message.role == AiMessageRole.assistant,
        );
        expect(reminderIndex, greaterThan(0));
        expect(assistantIndex, greaterThan(reminderIndex));
        expect(
          restored.messages.where((message) => message.id == 'origin'),
          hasLength(1),
        );
        expect(
          await controller.rollbackTurnAndPrepareResend('origin'),
          'First delegation',
        );
        expect((await content.getChapterById(chapterId))!.content, '');
        expect(
          container.read(aiChatSessionProvider('parent')).messages,
          isEmpty,
        );
      },
    );

    test(
      'mutation released during empty wake cleanup resumes its still eligible notification',
      () async {
        final child = fixture.child();
        startChild(child, 'origin');
        await child.requestEntered.future;
        var starts = 0;
        var ends = 0;
        final client = FakeProviderClient();
        runtime.agent = FakeAgent.create(
          client: client,
          hooks: [
            _CompletionEndHook(
              () async {
                if (ends++ == 0) {
                  runtime.endSessionMutation();
                }
              },
              start: () async {
                if (starts++ == 0) {
                  expect(runtime.tryBeginSessionMutation(), isTrue);
                }
              },
            ),
          ],
        );
        controller.enableCompletionDelivery('parent');
        child.finish();
        await settle();
        expect(starts, 2);
        expect(client.streamCallCount, 1);
        expect(
          client.capturedStreamRequests.single.messages.where(
            (message) => message.content.contains('subagent_completed'),
          ),
          hasLength(1),
        );
      },
    );

    for (final stopAll in [false, true]) {
      test(
        'scheduled wake rechecks mutation and revoked turns stopAll=$stopAll',
        () async {
          final child = fixture.child();
          final run = startChild(child, 'origin');
          await child.requestEntered.future;
          final client = FakeProviderClient();
          runtime.agent = FakeAgent.create(client: client);
          child.finish();
          await runtime.subAgents.waitForRun(run.runId);
          controller.enableCompletionDelivery('parent');
          // 调度已排入 microtask，消费前同步进入守卫。
          expect(runtime.tryBeginSessionMutation(), isTrue);
          if (stopAll) {
            await runtime.stopAll();
          } else {
            await runtime.subAgents.stopTurns({'origin'});
          }
          runtime.endSessionMutation();
          await settle();
          expect(client.streamCallCount, 0);
          expect(
            container.read(aiChatRuntimeProvider('parent')).requestSequence,
            0,
          );
        },
      );
    }

    test(
      'automatic AskUser waits for a live user answer and new queued input remains separate',
      () async {
        container.listen(aiChatSessionProvider('parent'), (_, _) {});
        final child = fixture.child();
        final run = startChild(child, 'origin');
        await child.requestEntered.future;
        final asked = Completer<void>();
        final turnIds = <String?>[];
        late FakeAgentToolDispatcher dispatcher;
        dispatcher = FakeAgentToolDispatcher(
          tools: {
            'AskUser': FakeAgentTool(
              def: const ToolDef(
                name: 'AskUser',
                description: 'Ask',
                inputSchema: {'type': 'object'},
              ),
              handler: (_, _) async {
                turnIds.add(
                  dispatcher.capturedCalls.last.context!.sourceTurnId,
                );
                final pending = runtime.registerAskUser(
                  const AskUserRequest(
                    callId: 'ask1',
                    questions: [
                      AskUserQuestion(id: 'q', question: 'Keep this ending?'),
                    ],
                  ),
                );
                asked.complete();
                return (await pending.future).toJson();
              },
            ),
          },
        );
        final client = FakeProviderClient(
          responses: const [
            FakeProviderClientResponse.toolCalls([
              ToolCall(callId: 'ask1', toolName: 'AskUser', arguments: {}),
            ]),
            FakeProviderClientResponse.text('Revised ending'),
          ],
          repeatLastResponse: false,
        );
        runtime.agent = FakeAgent.create(
          client: client,
          toolManager: dispatcher,
        );
        controller.enableCompletionDelivery('parent');
        child.finish();
        await asked.future;
        expect(runtime.pendingAskUserRequests['ask1'], isNotNull);
        expect(client.streamCallCount, 1);
        await controller.send('Use the confirmed ending');
        expect(store.queuedMessage?.text, 'Use the confirmed ending');
        expect(
          container
              .read(aiChatSessionProvider('parent'))
              .messages
              .where(
                (message) => message.content == 'Use the confirmed ending',
              ),
          isEmpty,
        );
        // 消费为下一轮用户输入，使用新的真实用户消息 ID。
        final queued = store.queuedMessage!.copyWith(sendOnNextTurn: true);
        runtime.stagePendingNextTurnMessage(queued);
        runtime.agent!.stageNextTurn(
          'queued_chat',
          AgentMessage.user(id: 'queued_chat', content: queued.agentText),
        );
        runtime.pendingAskUserRequests['ask1']!.complete(
          const AskUserResult(
            ok: true,
            answers: [AskUserAnswer(questionId: 'q', answer: 'Yes')],
          ),
        );
        await settle();
        expect(turnIds, ['origin']);
        expect(store.queuedMessage, isNull);
        expect(
          container
              .read(aiChatSessionProvider('parent'))
              .messages
              .where(
                (message) =>
                    message.content == 'Use the confirmed ending' &&
                    message.type == AiMessageType.text,
              ),
          hasLength(1),
        );
        expect(client.streamCallCount, 2);
        expect(runtime.pendingAskUserRequests, isEmpty);
        await runtime.subAgents.waitForRun(run.runId);
      },
    );
  });

  for (final (missing, persistenceFailure) in [
    (false, false),
    (true, false),
    (false, true),
  ]) {
    test(
      'rollback restores historical text and only truncates after success missing=$missing persistenceFailure=$persistenceFailure',
      () async {
        final db = NovelContentDatabase.forTest(NativeDatabase.memory());
        final appDb = AppDatabase.forTest(NativeDatabase.memory());
        final content = NovelContentService(db);
        final overlay = WorkingOverlayService(
          db,
          content,
          novelActionsService: NovelActionsService(appDb),
        );
        const path = 'controller-historical-rollback';
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(appDb),
            appSettingsDatabaseProvider.overrideWithValue(appDb),
            novelContentDatabaseProvider(path).overrideWithValue(db),
            novelContentServiceProvider(path).overrideWithValue(content),
            workingOverlayServiceProvider(path).overrideWithValue(overlay),
            if (persistenceFailure)
              aiSessionPersistenceServiceProvider(
                novelId: buildTestNovel().id,
                databasePath: path,
              ).overrideWithValue(
                _FailingHistoryPersistence(appDb, buildTestNovel().id),
              ),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await db.close();
          await appDb.close();
        });
        final id = await content.createChapter(
          siblingOrder: 1,
          title: 'Chapter',
        );
        final change = await overlay.stageTextChange(
          resourcePath: 'chapters/$id/content',
          resourceType: 'chapters',
          resourceId: id,
          field: 'content',
          oldText: '',
          newText: 'AI',
          source: workingChangeSourceAi,
          sourceTurnId: 'u1',
        );
        await overlay.commitWorkingChanges(
          [change.id],
          source: workingChangeSourceAi,
          message: 'accept',
        );
        // 写入次序与用户消息次序不同：u1 → u2 → u1。
        for (final (turn, before, after) in [
          ('u2', 'AI', 'second'),
          ('u1', 'second', 'late first'),
        ]) {
          await overlay.stageTextChange(
            resourcePath: 'chapters/$id/content',
            resourceType: 'chapters',
            resourceId: id,
            field: 'content',
            oldText: before,
            newText: after,
            source: workingChangeSourceAi,
            sourceTurnId: turn,
          );
        }
        if (missing) {
          await content.deleteChapter(id);
        } else {
          await content.updateChapterContent(
            chapterId: id,
            title: 'Chapter',
            outline: '',
            content: 'later manual',
          );
        }
        const sessionId = 'historical-rollback-session';
        final notifier = container.read(
          aiChatSessionProvider(sessionId).notifier,
        );
        notifier.markLoaded();
        notifier.replaceMessages([
          AiMessage.user(id: 'u0', content: 'keep'),
          AiMessage.user(id: 'u1', content: 'redraft'),
          AiMessage.assistant(id: 'a1', content: 'reply'),
          AiMessage.user(id: 'u2', content: 'second request'),
        ]);
        final warnings = <String>[];
        final controller = _buildController(
          container,
          sessionId: sessionId,
          store: DefaultChatComposerStore(),
          databasePath: path,
          onComposerWarning: missing ? warnings.add : null,
        );
        final prompt = await controller.rollbackTurnAndPrepareResend('u1');
        expect(prompt, persistenceFailure ? isNull : 'redraft');
        if (missing) {
          expect(warnings, hasLength(1));
        }
        expect(
          container
              .read(aiChatSessionProvider(sessionId))
              .messages
              .map((m) => m.id),
          persistenceFailure ? ['u0', 'u1', 'a1', 'u2'] : ['u0'],
        );
        expect(
          (await db.workingChangeDao.getById(change.id))!.status,
          missing ? workingChangeStatusCommitted : workingChangeStatusRejected,
        );
        if (!missing) {
          expect((await content.getChapterById(id))!.content, '');
        }
        expect(
          container
              .read(aiChatRuntimeProvider(sessionId))
              .isSessionMutationInFlight,
          false,
        );
      },
    );
  }

  group('rollbackTurnIdsForTruncatedMessages', () {
    test('collects selected and later user turns newest first', () {
      final messages = [
        AiMessage.user(id: 'u0', content: 'kept'),
        AiMessage.assistant(id: 'a0', content: 'kept response'),
        AiMessage.user(id: 'u1', content: 'rollback from here'),
        AiMessage.assistant(id: 'a1', content: 'response 1'),
        AiMessage.user(id: 'u2', content: 'later prompt'),
        AiMessage.assistant(id: 'a2', content: 'response 2'),
        AiMessage.system(id: 's1', content: 'ignored'),
        AiMessage.user(id: 'u3', content: 'latest prompt'),
      ];

      final turnIds = rollbackTurnIdsForTruncatedMessages(messages, 2);

      expect(
        turnIds,
        ['u3', 'u2', 'u1'],
        reason:
            '后续 user turn 的改动也会随聊天截断一起回退；'
            '逆序保证同一资源多轮改动时先撤最新轮次。',
      );
    });

    test('ignores non-user messages and duplicate ids', () {
      final messages = [
        AiMessage.user(id: 'u1', content: 'first'),
        AiMessage.assistant(id: 'a1', content: 'response'),
        AiMessage.user(id: 'u2', content: 'second'),
        AiMessage.user(id: 'u2', content: 'duplicate'),
      ];

      final turnIds = rollbackTurnIdsForTruncatedMessages(messages, 0);

      expect(turnIds, ['u2', 'u1']);
    });
  });

  test(
    'rollback on an idle cached agent drops it so resend rebuilds context',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const sessionId = 'sess_rollback_idle_agent';
      final controller = _buildController(
        container,
        sessionId: sessionId,
        store: DefaultChatComposerStore(),
      );

      final sessionNotifier = container.read(
        aiChatSessionProvider(sessionId).notifier,
      );
      sessionNotifier.markLoaded();
      sessionNotifier.replaceMessages([
        AiMessage.user(id: 'u0', content: 'kept'),
        AiMessage.assistant(id: 'a0', content: 'kept response'),
        AiMessage.user(id: 'u1', content: '开始下一章'),
        AiMessage.assistant(id: 'a1', content: 'rolled back reply'),
      ]);

      // 非在途：cached agent 存活且不会经过 cancel 销毁。
      final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
      runtime.agent = FakeAgent.create(
        client: FakeProviderClient(responses: const []),
        toolManager: FakeAgentToolDispatcher(),
      );

      final prompt = await controller.rollbackTurnAndPrepareResend('u1');

      expect(prompt, '开始下一章');
      expect(
        container
            .read(aiChatSessionProvider(sessionId))
            .messages
            .map((m) => m.id),
        ['u0', 'a0'],
      );
      expect(
        container.read(aiChatRuntimeProvider(sessionId).notifier).agent,
        isNull,
        reason: '回退后 cached agent 必须丢弃，否则模型仍能看到已回退的消息',
      );
      final runtimeState = container.read(aiChatRuntimeProvider(sessionId));
      expect(runtimeState.isSessionMutationInFlight, isFalse);
    },
  );

  test('runtime cancel preserves the session mutation guard', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    const sessionId = 'sess_cancel_preserves_mutation_guard';
    final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);

    expect(runtime.tryBeginSessionMutation(), isTrue);
    runtime.cancel(source: AiChatCancelSource.modelSwitch);

    final state = container.read(aiChatRuntimeProvider(sessionId));
    expect(state.isSessionMutationInFlight, isTrue);
    expect(
      runtime.tryBeginSessionMutation(),
      isFalse,
      reason: '取消请求不能在已有历史变更期间重新打开并发发送窗口',
    );

    runtime.endSessionMutation();
    expect(
      container
          .read(aiChatRuntimeProvider(sessionId))
          .isSessionMutationInFlight,
      isFalse,
    );
  });

  test('session history mutation guard blocks a concurrent send', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    const sessionId = 'sess_history_mutation_guard';
    final controller = _buildController(
      container,
      sessionId: sessionId,
      store: DefaultChatComposerStore(),
    );
    final sessionNotifier = container.read(
      aiChatSessionProvider(sessionId).notifier,
    );
    sessionNotifier.markLoaded();
    sessionNotifier.addUserMessage('kept');
    final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
    runtime.agent = FakeAgent.create(
      client: FakeProviderClient(responses: const []),
      toolManager: FakeAgentToolDispatcher(),
    );

    expect(runtime.tryBeginSessionMutation(), isTrue);
    await controller.send('must wait for rollback');

    expect(runtime.agent, isNotNull);
    expect(
      container
          .read(aiChatSessionProvider(sessionId))
          .messages
          .map((message) => message.effectiveText),
      ['kept'],
    );
    runtime.endSessionMutation();
  });

  test('clearing an accepted queued message is idempotent', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    const sessionId = 'sess_queue_clear_lifecycle';
    final fixture = await _startInFlightToolTurn(
      container,
      sessionId: sessionId,
    );
    final store = DefaultChatComposerStore();
    final controller = _buildController(
      container,
      sessionId: sessionId,
      store: store,
    );

    await controller.send('queued request');
    await controller.send('ignored replacement');
    expect(store.queuedMessage?.text, 'queued request');
    controller.clearQueuedMessage();
    controller.clearQueuedMessage();

    expect(store.queuedMessage, isNull);
    expect(
      container.read(aiChatRuntimeProvider(sessionId).notifier).queuedMessage,
      isNull,
    );
    fixture.releaseTool.complete();
    await fixture.processFuture;
  });

  test('in-flight queue: defer, clear, and staged remind', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // 1) 默认排队：消息与 workspace remind 都不得插入未完成的 tool turn。
    const queueSessionId = 'sess_queue_keeps_remind_out';
    final queueFixture = await _startInFlightToolTurn(
      container,
      sessionId: queueSessionId,
    );
    final composerStore = DefaultChatComposerStore();
    final queueController = _buildController(
      container,
      sessionId: queueSessionId,
      store: composerStore,
    );

    await queueController.send('queued request');
    queueFixture.releaseTool.complete();
    await queueFixture.processFuture;

    expect(queueFixture.client.capturedStreamRequests, hasLength(2));
    final queueSecondRequest =
        queueFixture.client.capturedStreamRequests[1].messages;
    expect(
      () => preflightProviderHistory(
        queueSecondRequest,
        ProviderHistoryPolicy.openAiChat,
      ),
      returnsNormally,
    );
    expect(
      queueSecondRequest.indexWhere(
        (message) => message.content.contains('current_workspace_context'),
      ),
      -1,
      reason: 'workspace system-remind 只随用户主动 send 一起投递，不单独插入 in-flight turn',
    );
    expect(
      queueSecondRequest.indexWhere((message) => message.id == 'queued_chat'),
      -1,
    );
    expect(composerStore.queuedMessage?.text, 'queued request');
    expect(
      container
          .read(aiChatSessionProvider(queueSessionId))
          .messages
          .where((message) => message.type == AiMessageType.system_remind),
      isEmpty,
      reason: '排队阶段不应落库 workspace system-remind',
    );

    // 1b) 已有队列时再次 send 不得覆盖。
    const occupiedSessionId = 'sess_queue_occupied';
    final occupiedFixture = await _startInFlightToolTurn(
      container,
      sessionId: occupiedSessionId,
    );
    final occupiedStore = DefaultChatComposerStore();
    final occupiedController = _buildController(
      container,
      sessionId: occupiedSessionId,
      store: occupiedStore,
    );
    await occupiedController.send('first queued');
    expect(occupiedStore.queuedMessage?.text, 'first queued');
    await occupiedController.send('should not overwrite');
    expect(occupiedStore.queuedMessage?.text, 'first queued');
    occupiedController.clearQueuedMessage();
    occupiedFixture.releaseTool.complete();
    await occupiedFixture.processFuture;

    // 2) da7e58ef：若处理中仍投递 system-remind，必须 stage 到 tool_result 之后。
    const stageSessionId = 'sess_stage_remind_after_tool';
    final stageFixture = await _startInFlightToolTurn(
      container,
      sessionId: stageSessionId,
    );
    final stageController = _buildController(
      container,
      sessionId: stageSessionId,
      store: DefaultChatComposerStore(),
    );

    stageController.debugDeliverSystemRemind(
      stageSessionId,
      "<system-remind type='current_workspace_context' "
      "section='novel_description' path='novel_description' "
      "title='Test Novel' />",
      kind: 'current_workspace_context',
    );
    stageFixture.releaseTool.complete();
    await stageFixture.processFuture;

    expect(stageFixture.client.capturedStreamRequests, hasLength(2));
    final stageSecondRequest =
        stageFixture.client.capturedStreamRequests[1].messages;
    expect(
      () => preflightProviderHistory(
        stageSecondRequest,
        ProviderHistoryPolicy.openAiChat,
      ),
      returnsNormally,
      reason: 'remind 必须 stage 到下一轮，不能插在 tool_call 与 tool_result 之间',
    );
    final stagedToolResultIndex = stageSecondRequest.indexWhere(
      (message) => message.blocks.whereType<ToolResultBlock>().isNotEmpty,
    );
    final stagedRemindIndex = stageSecondRequest.indexWhere(
      (message) => message.content.contains('current_workspace_context'),
    );
    expect(stagedToolResultIndex, isNonNegative);
    expect(stagedRemindIndex, greaterThan(stagedToolResultIndex));

    // 3) 取消排队：把文案 append 回输入框。
    const clearSessionId = 'sess_clear_queued';
    final clearFixture = await _startInFlightToolTurn(
      container,
      sessionId: clearSessionId,
    );
    final clearStore = DefaultChatComposerStore();
    final restored = <String>[];
    final clearController = _buildController(
      container,
      sessionId: clearSessionId,
      store: clearStore,
      restoreComposerText: restored.add,
    );

    await clearController.send('queued request');
    clearController.clearQueuedMessage(restoreToComposer: true);
    expect(clearStore.queuedMessage, isNull);
    expect(restored, ['queued request']);

    clearFixture.releaseTool.complete();
    await clearFixture.processFuture;

    final clearSecondRequest =
        clearFixture.client.capturedStreamRequests[1].messages;
    expect(
      clearSecondRequest.indexWhere((message) => message.id == 'queued_chat'),
      -1,
    );
  });

  test('cancelling the request restores a staged send-now message', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    const sessionId = 'sess_cancel_restores_send_now';
    final store = DefaultChatComposerStore();
    final restored = <String>[];
    final controller = _buildController(
      container,
      sessionId: sessionId,
      store: store,
      restoreComposerText: restored.add,
    );

    // 进入 in-flight，并模拟已点「立即发送」：staged 到 runtime 的下一轮 + UI 标记。
    final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
    runtime.startRequest();
    const queuedMessage = QueuedChatMessage(
      text: 'queued request',
      agentText: 'queued request',
      references: [],
      sessionId: sessionId,
      sendOnNextTurn: true,
    );
    runtime.stagePendingNextTurnMessage(queuedMessage);
    store.queuedMessage = queuedMessage;

    // 取消整次请求：用户以为「立即发送」的内容尚未送达，应恢复到输入框而非静默丢弃。
    controller.cancel(sessionId);

    expect(store.queuedMessage, isNull);
    expect(restored, ['queued request'], reason: '取消时 staged 的立即发送消息应恢复到输入框');
    expect(
      runtime.takePendingNextTurnMessage(),
      isNull,
      reason: '取消后清空 staged 文本，避免残留泄漏到后续轮',
    );
  });

  test('cancelling removes a signature-only assistant bubble', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    const sessionId = 'sess_cancel_signature_only';
    final sessionNotifier = container.read(
      aiChatSessionProvider(sessionId).notifier,
    );
    sessionNotifier.markLoaded();
    sessionNotifier.startStreamingMessage();
    sessionNotifier.setActiveThinkingSignature('sig123');

    final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
    runtime.startRequest();
    final controller = _buildController(
      container,
      sessionId: sessionId,
      store: DefaultChatComposerStore(),
    );

    controller.cancel(sessionId);

    expect(container.read(aiChatSessionProvider(sessionId)).messages, isEmpty);
  });

  test('cancelling the request restores an ordinary queued message', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    const sessionId = 'sess_cancel_restores_ordinary_queue';
    final store = DefaultChatComposerStore();
    final restored = <String>[];
    final controller = _buildController(
      container,
      sessionId: sessionId,
      store: store,
      restoreComposerText: restored.add,
    );

    // 进入 in-flight，并模拟用户在忙碌期排队（尚未点「立即发送」）的下一条消息。
    final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
    runtime.startRequest();
    const queuedMessage = QueuedChatMessage(
      text: 'queued request',
      agentText: 'queued request',
      references: [],
      sessionId: sessionId,
    );
    store.queuedMessage = queuedMessage;

    // 取消整次请求：普通排队消息同样应恢复到输入框，而不是随硬取消静默丢弃。
    controller.cancel(sessionId);

    expect(store.queuedMessage, isNull);
    expect(restored, ['queued request'], reason: '取消时普通排队消息应恢复到输入框');
  });

  test(
    'request completion clears the queue under its real session id',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      const temporarySessionId = '__new__temporary';
      const realSessionId = 'ai_session_real';
      final store = _SessionScopedChatComposerStore(temporarySessionId);
      const queued = QueuedChatMessage(
        text: 'send in the next turn',
        agentText: 'send in the next turn',
        references: [],
        sessionId: realSessionId,
        sendOnNextTurn: true,
      );
      store.setQueuedMessageForSession(realSessionId, queued);
      final runtime = container.read(
        aiChatRuntimeProvider(realSessionId).notifier,
      );
      final requestId = runtime.startRequest();
      final controller = _buildController(
        container,
        sessionId: realSessionId,
        activeSessionId: temporarySessionId,
        store: store,
      );

      await controller.flushQueuedMessageAfterRequestForTest(
        realSessionId,
        requestId,
      );

      expect(
        store.queuedMessageForSession(realSessionId),
        isNull,
        reason: '临时 session 创建真实会话后，完成回调必须清理真实会话的队列横幅',
      );
    },
  );

  test(
    'promoteQueuedMessageForSurvivingTurn stages ordinary queue when agent runs',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      const sessionId = 'sess_promote_on_dispose';
      final fixture = await _startInFlightToolTurn(
        container,
        sessionId: sessionId,
      );

      final queued = const QueuedChatMessage(
        text: 'queued after leave',
        agentText: 'queued after leave',
        references: [],
        userMessageId: 'saved_image_turn',
        modelBlocks: [
          TextBlock('before'),
          ImageBlock(data: 'AAA=', mimeType: 'image/png'),
          TextBlock('after'),
        ],
        sessionId: sessionId,
      );

      expect(
        promoteQueuedMessageForSurvivingTurn(
          container: container,
          queued: queued,
        ),
        isTrue,
        reason: 'UI 卸载时普通排队应 stage 到仍在跑的 agent',
      );
      expect(
        container
            .read(aiChatRuntimeProvider(sessionId))
            .hasPendingNextTurnMessage,
        isTrue,
        reason: '重建后的聊天面板需要可观察到 runtime 中已 stage 的下一轮消息',
      );
      final stagedMessage = container
          .read(aiChatRuntimeProvider(sessionId).notifier)
          .takePendingNextTurnMessage();
      expect(stagedMessage?.text, queued.text);
      expect(stagedMessage?.modelBlocks, queued.modelBlocks);
      expect(stagedMessage?.userMessageId, 'saved_image_turn');
      expect(stagedMessage?.sendOnNextTurn, isTrue);
      expect(
        container
            .read(aiChatRuntimeProvider(sessionId))
            .hasPendingNextTurnMessage,
        isFalse,
        reason: '消费后应通知重建的 panel 收起「下一轮发送」横幅',
      );

      // 已 sendOnNextTurn / agent 已停 → no-op
      expect(
        promoteQueuedMessageForSurvivingTurn(
          container: container,
          queued: queued.copyWith(sendOnNextTurn: true),
        ),
        isFalse,
      );

      fixture.releaseTool.complete();
      await fixture.processFuture;
      final applied = container
          .read(aiChatRuntimeProvider(sessionId).notifier)
          .agent!
          .contextManager
          .messages
          .where((m) => m.id == 'queued_chat')
          .single;
      expect(applied.content, isEmpty);
      expect(applied.blocks, queued.modelBlocks);

      expect(
        promoteQueuedMessageForSurvivingTurn(
          container: container,
          queued: queued,
        ),
        isFalse,
        reason: 'agent 停后不再 stage，避免把消息塞进已结束的 turn',
      );
    },
  );

  test(
    'unmounted host hands an unconsumed staged message to the detached sender',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      const sessionId = 'sess_unmounted_staged_queue';
      final reference = AiContextReference(
        section: NovelWorkspaceSection.chapters,
        itemId: 'chapter_a',
        label: 'Chapter A',
      );
      const handoff = PendingChatHandoff(
        label: 'cover',
        content: 'create cover',
      );
      final queued = QueuedChatMessage(
        text: 'queued after leave',
        agentText: '<handoff>queued after leave</handoff>',
        references: [reference],
        sessionId: sessionId,
        handoff: handoff,
        sendOnNextTurn: true,
      );
      final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
      final requestId = runtime.startRequest();
      runtime.stagePendingNextTurnMessage(queued);
      final controller = _buildController(
        container,
        sessionId: sessionId,
        store: DefaultChatComposerStore(),
        isMounted: () => false,
      );

      await controller.flushQueuedMessageAfterRequestForTest(
        sessionId,
        requestId,
      );

      expect(
        runtime.takePendingNextTurnMessage(),
        isNull,
        reason: '后台 detached sender 接管后必须取走 staged 消息，避免泄漏到后续请求',
      );
    },
  );

  test(
    'stale request flush does not consume a newer request staged message',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      const sessionId = 'sess_stale_flush_keeps_new_staged_message';
      final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
      final staleRequestId = runtime.startRequest();
      const queued = QueuedChatMessage(
        text: 'send with newer request',
        agentText: 'send with newer request',
        references: [],
        sessionId: sessionId,
        sendOnNextTurn: true,
      );
      runtime.stagePendingNextTurnMessage(queued);
      runtime.startRequest();

      final controller = _buildController(
        container,
        sessionId: sessionId,
        store: DefaultChatComposerStore(),
      );
      await controller.flushQueuedMessageAfterRequestForTest(
        sessionId,
        staleRequestId,
      );

      expect(
        runtime.takePendingNextTurnMessage(),
        queued,
        reason: '旧请求的 finally 不得取走新请求 staged 的立即发送消息',
      );
    },
  );

  test('unmounted flush does not write the disposed composer store', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    const sessionId = 'sess_unmounted_flush_uses_detached_store';
    const queued = QueuedChatMessage(
      text: 'queued after dispose',
      agentText: 'queued after dispose',
      references: [],
      sessionId: sessionId,
      sendOnNextTurn: true,
    );
    final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
    final requestId = runtime.startRequest();
    runtime.stagePendingNextTurnMessage(queued);
    final controller = _buildController(
      container,
      sessionId: sessionId,
      store: _DisposedChatComposerStore(),
      isMounted: () => false,
    );

    await controller.flushQueuedMessageAfterRequestForTest(
      sessionId,
      requestId,
    );

    expect(
      runtime.takePendingNextTurnMessage(),
      isNull,
      reason: '后台接力已接管 staged 消息，不能将其留给后续请求重复消费',
    );
  });

  test(
    'in-flight queue ignores the model selection retained by the active send',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      const sessionId = 'sess_queue_with_retained_model_selection';
      final fixture = await _startInFlightToolTurn(
        container,
        sessionId: sessionId,
      );
      final store = DefaultChatComposerStore();
      final controller = _buildController(
        container,
        sessionId: sessionId,
        store: store,
      );

      await controller.send(
        'queued while the first turn is running',
        pendingModelSelection: const PendingChatModelSelection(
          providerId: 'provider_already_selected',
          model: 'model_already_selected',
        ),
      );

      expect(
        store.queuedMessage?.text,
        'queued while the first turn is running',
      );
      expect(fixture.agent.isProcessing, isTrue);

      fixture.releaseTool.complete();
      await fixture.processFuture;
    },
  );

  test('cancelling queue restores the queued message original references', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    const sessionId = 'sess_queue_ref_restore';
    final store = DefaultChatComposerStore();
    final restored = <String>[];
    final controller = _buildController(
      container,
      sessionId: sessionId,
      store: store,
      restoreComposerText: restored.add,
    );

    const refA = AiContextReference.file(
      itemId: 'file_a',
      label: 'notes.md',
      content: 'attached context',
    );
    final refB = AiContextReference(
      section: NovelWorkspaceSection.chapters,
      itemId: 'chapter_b',
      label: 'Chapter B',
    );

    store.queuedMessage = QueuedChatMessage(
      text: 'queued with ref',
      agentText: 'queued with ref',
      references: [refA],
      sessionId: sessionId,
    );
    // 排队后用户又新增 refB。
    store.attachedReferences = [refB];

    // 取消排队恢复：文案 + 其原始引用 refA 回填，覆盖排队后新增的 refB。
    controller.clearQueuedMessage(restoreToComposer: true);

    expect(restored, ['queued with ref']);
    expect(store.attachedReferences, [
      refA,
    ], reason: '恢复出的文案应与其原始引用配对，不带排队后新增的引用');
  });

  test(
    'temporary session materializes before runner and tool execution',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'reveric_chat_materialization_test_',
      );
      final appDb = AppDatabase.forTest(NativeDatabase.memory());
      const novelId = 'novel_materialization';
      const signal = '__new__controller_materialization';
      final databasePath = '${tempDir.path}/content.sqlite';
      await _seedMaterializationWork(appDb, novelId, databasePath);
      final traceHttpClient = http.Client();
      final traceOutbox = AnonymousOutboxService(
        database: appDb,
        httpClient: traceHttpClient,
        getBaseUrl: () => null,
        getEnabled: () => false,
        autoFlush: false,
      );
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(appDb),
          appSettingsDatabaseProvider.overrideWithValue(appDb),
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

      container
          .read(aiChatSessionProvider(signal).notifier)
          .startNewSession(
            sessionId: signal,
            providerId: _materializationProvider.id,
            model: _materializationModel,
            sessionMode: AiSessionMode.chat,
            agentSlug: 'orchestrator',
          );
      final persistence = container.read(
        aiSessionPersistenceServiceProvider(
          novelId: novelId,
          databasePath: databasePath,
        ),
      );
      expect(
        await persistence.listSessions(),
        isEmpty,
        reason: 'a temporary draft must stay in memory until the first send',
      );

      final dispatcher = FakeAgentToolDispatcher(
        tools: {
          'TodoWrite': FakeAgentTool(
            def: const ToolDef(
              name: 'TodoWrite',
              description: 'capture execution context',
              inputSchema: {'type': 'object'},
            ),
            handler: (_, _) => {'ok': true, 'todos': const []},
          ),
        },
      );
      final fakeAgent = FakeAgent.create(
        client: FakeProviderClient(
          responses: const [
            FakeProviderClientResponse.toolCalls([
              ToolCall(
                callId: 'todo_real_session',
                toolName: 'TodoWrite',
                arguments: {'todos': []},
              ),
            ]),
            FakeProviderClientResponse.text('done'),
          ],
          repeatLastResponse: false,
        ),
        toolManager: dispatcher,
      );
      final activatedSessionIds = <String>[];
      var clearComposerCount = 0;
      final controller = ChatSessionController(
        container: container,
        scope: ChatScope(
          activeSessionId: signal,
          novel: buildTestNovel(id: novelId, databasePath: databasePath),
          databasePath: databasePath,
          workspaceSection: NovelWorkspaceSection.novel_description,
        ),
        host: ChatHost(
          clearComposer: () => clearComposerCount += 1,
          focusComposer: () {},
          openModelSelector: () {},
          resetScroll: () {},
          isMounted: () => true,
          onActiveSessionIdChanged: (sessionId) async {
            if (sessionId == null) {
              throw StateError('materialized session id must not be null');
            }
            // 模拟桌面 panel 因 active session 切换卸载并完成一轮 provider
            // disposal：真实 session 必须已被本轮请求监听，不能丢失模型。
            await container.pump();
            activatedSessionIds.add(sessionId);
            container.read(aiChatRuntimeProvider(sessionId).notifier).agent =
                fakeAgent;
            container
                .read(aiModeProcessingTrackerProvider.notifier)
                .setForegroundSession(
                  mode: AiSessionMode.chat,
                  sessionId: sessionId,
                  foreground: true,
                );
          },
        ),
        store: DefaultChatComposerStore(),
        promptBuilder: ChatPromptBuilder(),
        availableSubAgents: const [],
        aiPromptService: AiPromptService(),
        promptContext: AiSessionContext(
          databasePath: databasePath,
          novelName: 'Test Novel',
        ),
      );

      await controller.send('materialize then run');

      expect(activatedSessionIds, hasLength(1));
      final realSessionId = activatedSessionIds.single;
      expect(realSessionId, startsWith('ai_session_'));
      expect(realSessionId, isNot(signal));
      expect(
        resolveAiChatNewSessionId(novelId: novelId, activeId: signal),
        isNull,
        reason: 'the temporary mapping is released after the host adopts it',
      );
      expect(clearComposerCount, 1);
      expect(
        await appDb.aiChatSessionDao.getById(realSessionId, novelId: novelId),
        isNotNull,
      );
      expect(await appDb.aiChatSessionDao.getById(signal), isNull);
      expect(dispatcher.capturedCalls, hasLength(1));
      expect(dispatcher.capturedCalls.single.context?.sessionId, realSessionId);
      expect(
        dispatcher.capturedCalls.single.context?.sourceSessionId,
        realSessionId,
      );
    },
  );

  test(
    'send now starts a new request while the old transport is blocked',
    () async {
      final fixture = SpawnAgentRuntimeFixture();
      await fixture.initialize();
      const databasePath = 'send-now.sqlite';
      const sessionId = 'send-now';
      const novelId = 'test_work';
      final provider = _materializationProvider.copyWith(
        type: 'openai_compatible',
      );
      await _seedMaterializationWork(fixture.appDb, novelId, databasePath);
      await AiSessionPersistenceService(
        fixture.appDb,
        novelId,
        novelContentDatabase: fixture.novelDb,
      ).createActiveSession(
        id: sessionId,
        title: 'Send now',
        provider: provider.id,
        model: _materializationModel,
        mode: 'chat',
        agentSlug: 'orchestrator',
      );
      final outboxClient = MockClient((_) async => http.Response('', 200));
      final outbox = AnonymousOutboxService(
        database: fixture.appDb,
        httpClient: outboxClient,
        getBaseUrl: () => null,
        getEnabled: () => false,
        autoFlush: false,
      );
      final sentRequests = <String>[];
      http.Client createClient() => MockClient((request) async {
        if (!request.url.path.endsWith('/chat/completions')) {
          return http.Response('{"data":[]}', 200);
        }
        sentRequests.add(request.body);
        return http.Response(
          'data: {"choices":[{"index":0,"delta":{"content":"New reply"}}]}\n\n'
          'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n'
          'data: [DONE]\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(fixture.appDb),
          appSettingsDatabaseProvider.overrideWithValue(fixture.appDb),
          novelContentDatabaseProvider(
            databasePath,
          ).overrideWithValue(fixture.novelDb),
          agentSkillAppDatabaseProvider.overrideWithValue(fixture.appDb),
          todoDaoProvider.overrideWith((ref) => TodoDao(fixture.appDb)),
          aiSettingsProvider.overrideWithValue(
            AiSettings(providers: [provider]),
          ),
          globalSubAgentsProvider.overrideWith(_EmptyGlobalSubAgents.new),
          traceReporterServiceProvider.overrideWithValue(
            TraceReporterService(
              deviceIdService: _MaterializationDeviceIdService(),
              outbox: outbox,
            ),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        outbox.dispose();
        outboxClient.close();
        await fixture.dispose();
      });

      final session = aiChatSessionProvider(sessionId);
      container.listen(session, (_, _) {});
      container.read(session.notifier)
        ..startNewSession(
          sessionId: sessionId,
          providerId: provider.id,
          model: _materializationModel,
          sessionMode: AiSessionMode.chat,
          agentSlug: 'orchestrator',
        )
        ..addUserMessage('Previous turn');
      container
          .read(aiModeProcessingTrackerProvider.notifier)
          .setForegroundSession(
            mode: AiSessionMode.chat,
            sessionId: sessionId,
            foreground: true,
          );

      final oldRequestStarted = Completer<void>();
      final oldResponse = Completer<FakeProviderClientResponse>();
      final oldClient = FakeProviderClient(
        responder: (_) {
          if (!oldRequestStarted.isCompleted) {
            oldRequestStarted.complete();
            return oldResponse.future;
          }
          return const FakeProviderClientResponse.text('Late reply');
        },
      );
      final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
      runtime.agent = FakeAgent.create(client: oldClient);
      final store = DefaultChatComposerStore();
      var composerClears = 0;
      final controller = _buildController(
        container,
        sessionId: sessionId,
        store: store,
        clearComposer: () => composerClears++,
        databasePath: databasePath,
        aiPromptService: AiPromptService.fromInitializedTemplates(),
      );

      final initialTurn = http.runWithClient(
        () => controller.send('Initial request'),
        createClient,
      );
      try {
        await oldRequestStarted.future.timeout(const Duration(seconds: 5));
        await controller.send('Queued request');
        expect(store.queuedMessage?.text, 'Queued request');
        const draftHandoff = PendingChatHandoff(
          label: 'Draft handoff',
          content: 'Unsent draft context',
        );
        store.pendingHandoff = draftHandoff;

        await controller.sendQueuedMessageNow();
        expect(oldClient.cancelCallCount, 1);
        await initialTurn.timeout(const Duration(seconds: 5));

        expect(oldClient.streamCallCount, 1);
        expect(oldResponse.isCompleted, isFalse);
        expect(sentRequests.single, contains('Queued request'));
        expect(store.queuedMessage, isNull);
        expect(store.pendingHandoff, same(draftHandoff));
        expect(composerClears, 2);
        final messages = container.read(session).messages;
        expect(
          messages.where((m) => m.effectiveText == 'Queued request'),
          hasLength(1),
        );
        expect(messages.last.effectiveText, 'New reply');
      } finally {
        oldResponse.complete(
          const FakeProviderClientResponse.text('Late reply'),
        );
        await initialTurn;
      }
    },
  );

  test(
    'ordinary queue auto-sends after a temporary session request completes',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'reveric_chat_queue_materialization_test_',
      );
      final appDb = AppDatabase.forTest(NativeDatabase.memory());
      const novelId = 'novel_queue_materialization';
      const signal = '__new__controller_queue_materialization';
      final databasePath = '${tempDir.path}/content.sqlite';
      await _seedMaterializationWork(appDb, novelId, databasePath);
      final traceHttpClient = http.Client();
      final traceOutbox = AnonymousOutboxService(
        database: appDb,
        httpClient: traceHttpClient,
        getBaseUrl: () => null,
        getEnabled: () => false,
        autoFlush: false,
      );
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(appDb),
          appSettingsDatabaseProvider.overrideWithValue(appDb),
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

      container
          .read(aiChatSessionProvider(signal).notifier)
          .startNewSession(
            sessionId: signal,
            providerId: _materializationProvider.id,
            model: _materializationModel,
            sessionMode: AiSessionMode.chat,
            agentSlug: 'orchestrator',
          );

      final dispatcher = FakeAgentToolDispatcher(
        tools: {
          'TodoWrite': FakeAgentTool(
            def: const ToolDef(
              name: 'TodoWrite',
              description: 'capture execution context',
              inputSchema: {'type': 'object'},
            ),
            handler: (_, _) => {'ok': true, 'todos': const []},
          ),
        },
      );
      final fakeAgent = FakeAgent.create(
        client: FakeProviderClient(
          responses: const [
            FakeProviderClientResponse.toolCalls([
              ToolCall(
                callId: 'todo_initial',
                toolName: 'TodoWrite',
                arguments: {'todos': []},
              ),
            ]),
            FakeProviderClientResponse.text('initial done'),
            FakeProviderClientResponse.text('queued done'),
          ],
          repeatLastResponse: false,
        ),
        toolManager: dispatcher,
      );
      final store = DefaultChatComposerStore();
      final activatedSessionIds = <String>[];
      final controller = ChatSessionController(
        container: container,
        scope: ChatScope(
          activeSessionId: signal,
          novel: buildTestNovel(id: novelId, databasePath: databasePath),
          databasePath: databasePath,
        ),
        host: ChatHost(
          clearComposer: () {},
          focusComposer: () {},
          openModelSelector: () {},
          resetScroll: () {},
          isMounted: () => true,
          onActiveSessionIdChanged: (sessionId) async {
            if (sessionId == null) {
              throw StateError('materialized session id must not be null');
            }
            activatedSessionIds.add(sessionId);
            container.read(aiChatRuntimeProvider(sessionId).notifier).agent =
                fakeAgent;
            container
                .read(aiModeProcessingTrackerProvider.notifier)
                .setForegroundSession(
                  mode: AiSessionMode.chat,
                  sessionId: sessionId,
                  foreground: true,
                );
            if (activatedSessionIds.length == 1) {
              store.queuedMessage = QueuedChatMessage(
                text: 'queued request',
                agentText: 'queued request',
                references: [],
                sessionId: sessionId,
              );
            }
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

      await controller.send('initial request');

      expect(activatedSessionIds, hasLength(1));
      expect(store.queuedMessage, isNull);
      expect(
        container
            .read(aiChatSessionProvider(activatedSessionIds.single))
            .messages
            .where(
              (message) =>
                  message.role == AiMessageRole.user &&
                  message.content == 'queued request',
            ),
        hasLength(1),
      );
    },
  );

  // 回归：activeSessionId 为 null 时（canvas 页那种没有临时 signal 的调用方），
  // 首轮 send 会直接新建一个真实 session。旧代码只在 temporarySignal != null 时
  // 把 id 交还父级，于是新 session 无人认领：消息全写进
  // `aiChatSessionProvider(<新 id>)`，而 UI 仍订阅 `family(null)` —— 日志里 turn
  // 跑得完整，界面却一直停在空态。
  test(
    'null activeSessionId hands the newly created session id to the host',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'reveric_chat_null_session_test_',
      );
      final appDb = AppDatabase.forTest(NativeDatabase.memory());
      const novelId = 'novel_null_active_session';
      final databasePath = '${tempDir.path}/content.sqlite';
      await _seedMaterializationWork(appDb, novelId, databasePath);
      final traceHttpClient = http.Client();
      final traceOutbox = AnonymousOutboxService(
        database: appDb,
        httpClient: traceHttpClient,
        getBaseUrl: () => null,
        getEnabled: () => false,
        autoFlush: false,
      );
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(appDb),
          appSettingsDatabaseProvider.overrideWithValue(appDb),
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

      // 面板在 activeSessionId == null 时把草稿状态放在 family(null) 上。
      container
          .read(aiChatSessionProvider(null).notifier)
          .startNewSession(
            sessionId: null,
            providerId: _materializationProvider.id,
            model: _materializationModel,
            sessionMode: AiSessionMode.chat,
            agentSlug: 'orchestrator',
          );

      final fakeAgent = FakeAgent.create(
        client: FakeProviderClient(
          responses: const [FakeProviderClientResponse.text('done')],
          repeatLastResponse: false,
        ),
        toolManager: FakeAgentToolDispatcher(tools: {}),
      );
      final activatedSessionIds = <String>[];
      final controller = ChatSessionController(
        container: container,
        scope: ChatScope(
          activeSessionId: null,
          novel: buildTestNovel(id: novelId, databasePath: databasePath),
          databasePath: databasePath,
          workspaceSection: NovelWorkspaceSection.canvas,
        ),
        host: ChatHost(
          clearComposer: () {},
          focusComposer: () {},
          openModelSelector: () {},
          resetScroll: () {},
          isMounted: () => true,
          onActiveSessionIdChanged: (sessionId) async {
            if (sessionId == null) {
              throw StateError('adopted session id must not be null');
            }
            activatedSessionIds.add(sessionId);
            // 与桌面 panel 一致：拿到真实 id 后把该会话标记为前台。不标记的话
            // turn 结束会走「后台完成」通知，在测试环境抛 MissingPluginException，
            // 而且是 unawaited 的，会飘到相邻用例上。
            container
                .read(aiModeProcessingTrackerProvider.notifier)
                .setForegroundSession(
                  mode: AiSessionMode.chat,
                  sessionId: sessionId,
                  foreground: true,
                );
            container.read(aiChatRuntimeProvider(sessionId).notifier).agent =
                fakeAgent;
          },
        ),
        store: DefaultChatComposerStore(),
        promptBuilder: ChatPromptBuilder(),
        availableSubAgents: const [],
        aiPromptService: AiPromptService(),
        promptContext: AiSessionContext(
          databasePath: databasePath,
          novelName: 'Test Novel',
        ),
      );

      // 认领发生在构造 runner 之前。未认领时后续 turn 会因为拿不到 agent 一路失败，
      // 那些次生异常不是本用例要断言的东西 —— 只看 id 有没有交还父级。
      try {
        await controller.send('first message on a fresh canvas panel');
      } catch (_) {
        // ignored: 见上
      }

      expect(
        activatedSessionIds,
        hasLength(1),
        reason: '新建的 session 必须交还父级，否则 UI 订阅不到它',
      );
      final realSessionId = activatedSessionIds.single;
      expect(realSessionId, startsWith('ai_session_'));
      // 消息确实落在那个真实 session 上（父级拿到它才能订阅到）。
      expect(
        container.read(aiChatSessionProvider(realSessionId)).messages,
        isNotEmpty,
      );
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

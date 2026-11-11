// 职责: 验证子运行资源收尾、实时工具详情、持久化、复用和取消传播。
// 关联文件:
//   lib/shared/services/ai/spawn_agent_handler.dart
//   lib/shared/services/ai/chat_agent_tool_dispatcher.dart
//   lib/shared/providers/spawn_agent_run_providers.dart
//   lib/shared/services/ai/session_persistence.dart
//   lib/shared/agent/fake_agent.dart

import '../../../helpers/plugin_host.dart';
import 'package:reveric/shared/services/mcp/settings_service.dart';
import 'package:reveric/shared/services/mcp/settings_orchestrator.dart';
import 'package:reveric/shared/models/mcp/config.dart';
import '../mcp/execution_test.dart' show ExecutionConnection;
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/agent/agent.dart';
import 'package:reveric/shared/agent/agent_config.dart';
import 'package:reveric/shared/agent/agent_context_manager.dart';
import 'package:reveric/shared/agent/agent_event.dart';
import 'package:reveric/shared/agent/agent_hook.dart';
import 'package:reveric/shared/agent/hooks/trace_hook.dart';
import 'package:reveric/shared/agent/client.dart';
import 'package:reveric/shared/agent/fake_agent.dart';
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/daos/todo_dao.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/agent_skill.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/ai_session_mode.dart';
import 'package:reveric/shared/models/ai_run_failure.dart';
import 'package:reveric/shared/models/subagent.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/providers/spawn_agent_run_providers.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/services/ai/prompt_template.dart';
import 'package:reveric/shared/services/ai/chat_agent_tool_dispatcher.dart';
import 'package:reveric/shared/services/ai/session_persistence.dart';
import 'package:reveric/shared/services/ai/codemode/scheduler.dart';
import 'package:reveric/shared/services/ai/codemode/runtime.dart';
import 'package:reveric/shared/services/ai/spawn_agent_handler.dart';
import 'package:reveric/shared/services/ai/usage_service.dart';
import 'package:reveric/shared/services/ai/usage_hook.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/ai/trace_reporter_service.dart';
import 'package:reveric/shared/services/anonymous_outbox_service.dart';
import 'package:reveric/shared/services/device_id_service.dart';

typedef _ClientResolver =
    Future<ProviderClient?> Function({
      required String providerId,
      required String model,
      required String subSessionId,
    });

class _SaveGatePersistence extends AiSessionPersistenceService {
  _SaveGatePersistence(
    super.appDatabase,
    super.novelId, {
    required super.novelContentDatabase,
  });
  final entered = Completer<void>();
  final finish = Completer<void>();

  @override
  Future<void> saveMessages({
    required String sessionId,
    required List<AiMessage> messages,
    required NovelContentDatabase novelDatabase,
    AgentContextSnapshot? contextSnapshot,
  }) async {
    entered.complete();
    await finish.future;
    await super.saveMessages(
      sessionId: sessionId,
      messages: messages,
      novelDatabase: novelDatabase,
      contextSnapshot: contextSnapshot,
    );
  }
}

class _EndGateHook extends AgentHook {
  final entered = Completer<void>();
  final finish = Completer<void>();
  @override
  Future<void> onEnd() async {
    entered.complete();
    await finish.future;
  }
}

void main() {
  late CodemodeScheduler codemodeScheduler;
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(PromptTemplateService.loadAll);

  late AppDatabase appDb;
  late NovelContentDatabase novelDb;
  late AiSessionPersistenceService persistence;

  const parentSessionId = 'ai_session_parent';
  const novelId = 'novel_1';
  const reviewer = SubAgent(
    id: 'sub_1',
    slug: 'reviewer',
    name: '内容核验',
    description: 'review',
    prompt: 'You are a reviewer.',
    scope: SubAgentScope.global,
    sortOrder: 0,
  );

  setUp(() async {
    codemodeScheduler = CodemodeScheduler(maxActive: 1);
    appDb = AppDatabase.forTest(NativeDatabase.memory());
    novelDb = NovelContentDatabase.forTest(NativeDatabase.memory());
    persistence = AiSessionPersistenceService(
      appDb,
      novelId,
      novelContentDatabase: novelDb,
    );
    await persistence.createActiveSession(
      id: parentSessionId,
      title: 'Parent',
      provider: 'provider_parent',
      model: 'model_parent',
      mode: AiSessionMode.chat.value,
      agentSlug: 'orchestrator',
    );
  });

  tearDown(() async {
    codemodeScheduler.dispose();
    await novelDb.close();
    await appDb.close();
  });

  SpawnAgentHandler buildHandler(
    FakeProviderClient client, {
    FjsRuntime Function()? codemodeRuntimeFactory,
    AgentToolDispatcher? toolManager,
    McpSettingsService? mcpService,
    AiSessionContext? workContext,
    List<String> Function()? allowedToolNames,
    List<SubAgent> availableSubAgents = const [reviewer],
    List<AgentSkillSummary> availableSkills = const [],
    AgentConfig agentConfig = const AgentConfig(),
    String? defaultProviderId = 'provider_parent',
    String? defaultModel = 'model_parent',
    _ClientResolver? clientResolver,
    SpawnAgentResourcesResolver? resourcesResolver,
    void Function(SpawnAgentRun)? onRunFinished,
    SpawnAgentSessionStartedCallback? onSessionStarted,
    SpawnAgentEventCallback? onSubAgentEvent,
    Future<List<AgentMessage>> Function(String sessionId)?
    contextSupplementForSession,
    String resolvedParentSessionId = parentSessionId,
    List<AgentHook> hooks = const [],
  }) {
    return SpawnAgentHandler(
      pluginHost: emptyPluginHost(),
      mcpService: mcpService,
      codemodeRuntimeFactory: codemodeRuntimeFactory,
      codemodeScheduler: codemodeScheduler,
      workContext:
          workContext ??
          AiSessionContext(
            workId: novelId,
            contentKind: toolManager is AiToolManager
                ? toolManager.contentKind
                : contentKindNovel,
          ),
      defaultAllowedToolNames: allowedToolNames ?? defaultSubAgentToolNames,
      availableSubAgents: availableSubAgents,
      availableSkills: availableSkills,
      agentConfig: agentConfig,
      defaultProviderId: defaultProviderId,
      defaultModel: defaultModel,
      parentSessionId: resolvedParentSessionId,
      hooks: hooks,
      persistence: persistence,
      novelDatabase: novelDb,
      resourcesResolver:
          resourcesResolver ??
          ({
            required providerId,
            required model,
            required subSessionId,
            required sourceSessionId,
          }) async {
            final resolved = clientResolver == null
                ? client
                : await clientResolver(
                    providerId: providerId,
                    model: model,
                    subSessionId: subSessionId,
                  );
            if (resolved == null) {
              throw StateError('No child client');
            }
            return SpawnAgentResources(
              client: resolved,
              toolManager: toolManager ?? FakeAgentToolDispatcher(),
              release: () {},
            );
          },
      onRunFinished: onRunFinished,
      onSessionStarted: onSessionStarted,
      onSubAgentEvent: onSubAgentEvent,
      contextSupplementForSession:
          contextSupplementForSession ??
          (_) async => [
            AgentMessage.user(id: 'ctx_todos', content: '[当前结构化 Todo 真源]\n[]'),
          ],
    );
  }

  AiToolManager workTools(String kind) {
    final content = NovelContentService(novelDb);
    return AiToolManager(
      content,
      contentKind: kind,
      workId: novelId,
      workingOverlayService: WorkingOverlayService(
        novelDb,
        content,
        novelActionsService: NovelActionsService(appDb),
      ),
    )..registerAllTools();
  }

  TraceHook diagnosticHook({bool failReporting = false}) {
    SharedPreferences.setMockInitialValues({'device_id': 'test-device'});
    final outbox = AnonymousOutboxService(
      database: appDb,
      httpClient: MockClient((_) async => throw UnimplementedError()),
      getBaseUrl: () => null,
      getEnabled: () {
        if (failReporting) {
          throw StateError('diagnostic service unavailable');
        }
        return true;
      },
      autoFlush: false,
    );
    addTearDown(outbox.dispose);
    return TraceHook(
      reporter: TraceReporterService(
        deviceIdService: DeviceIdService(),
        outbox: outbox,
      ),
      sessionId: () => parentSessionId,
      model: () => 'model_parent',
      providerId: () => 'provider_parent',
      sessionMode: () => 'chat',
    );
  }

  Future<List<Map<String, dynamic>>> toolErrorPayloads() async {
    final events = await appDb.select(appDb.anonymousOutboxEvents).get();
    return events
        .map((event) => jsonDecode(event.payloadJson) as Map<String, dynamic>)
        .where((payload) => payload['tool_name'] == 'SpawnAgent')
        .toList();
  }

  test(
    'readable startup failure explains missing model configuration',
    () async {
      final result =
          await buildHandler(
            FakeProviderClient(responses: const []),
            defaultProviderId: null,
            defaultModel: null,
          ).run(
            input: {'agent': reviewer.name, 'name': 'review', 'task': 'review'},
          );
      expect(result['error_code'], 'unavailable');
      expect(result['failure_reason'], 'model_not_configured');
      expect(result['error'], contains('选择模型'));
    },
  );

  for (final (error, reason, expectedMessage) in [
    (
      const SpawnAgentInitializationException(
        reason: 'model_unavailable',
        message: '所选模型当前不可用，请在模型设置中重新选择模型。',
      ),
      'model_unavailable',
      '重新选择模型',
    ),
    (
      const SpawnAgentInitializationException(
        reason: 'model_unavailable',
        message: '模型不可用，请重新选择模型。',
      ),
      'model_unavailable',
      '模型不可用',
    ),
    (StateError('private token=secret'), 'internal_error', '诊断日志'),
  ]) {
    test(
      'readable startup failure reaches the parent model: $reason',
      () async {
        final trace = diagnosticHook();
        final result =
            await buildHandler(
              FakeProviderClient(responses: const []),
              hooks: [trace],
              clientResolver:
                  ({
                    required providerId,
                    required model,
                    required subSessionId,
                  }) async {
                    throw error;
                  },
            ).run(
              input: {
                'agent': reviewer.name,
                'name': 'review',
                'task': 'review',
              },
            );
        final parent = FakeAgent.create(
          responses: const [
            FakeProviderClientResponse.toolCalls([
              ToolCall(
                callId: 'spawn-call',
                toolName: 'SpawnAgent',
                arguments: {},
              ),
            ]),
            FakeProviderClientResponse.text('Failure understood'),
          ],
          toolManager: FakeAgentToolDispatcher.withResults(
            results: {'SpawnAgent': result},
          ),
        );
        await parent.processText('Review');
        final payload =
            jsonDecode(
                  parent.contextManager.messages
                      .where(
                        (message) =>
                            message.type == AgentMessageType.tool_result,
                      )
                      .single
                      .blocks
                      .whereType<ToolResultBlock>()
                      .single
                      .content
                      .whereType<TextBlock>()
                      .single
                      .text,
                )
                as Map<String, dynamic>;
        expect(payload['error_code'], 'unavailable');
        expect(payload['failure_reason'], reason);
        expect(payload['error'], contains(expectedMessage));
        expect(payload['model'], 'model_parent');
        expect(payload['provider_id'], 'provider_parent');
        expect(payload.toString(), isNot(contains('token=secret')));
        expect(payload.containsKey('stack_top'), isFalse);
        final diagnostic = (await toolErrorPayloads()).single;
        expect(diagnostic['exception_message'], contains(error.toString()));
        expect(diagnostic['stack_top'], isNotEmpty);
      },
    );
  }

  test(
    'readable startup failure explains both failed model attempts',
    () async {
      final result =
          await buildHandler(
            FakeProviderClient(responses: const []),
            availableSubAgents: [
              reviewer.copyWith(providerId: 'restricted', model: 'child-model'),
            ],
            clientResolver:
                ({
                  required providerId,
                  required model,
                  required subSessionId,
                }) async {
                  if (providerId == 'restricted') {
                    throw const SpawnAgentInitializationException(
                      reason: 'model_unavailable',
                      message: '模型不可用，请重新选择模型。',
                    );
                  }
                  throw StateError('private parent credential');
                },
          ).run(
            input: {'agent': reviewer.name, 'name': 'review', 'task': 'review'},
          );
      expect(result['failure_reason'], 'internal_error');
      expect(result['fallback_reason'], 'model_unavailable');
      expect(result['error'], contains('模型不可用'));
      expect(result['error'], contains('父会话'));
      expect(result['error'], contains('model_parent'));
      expect(result.toString(), isNot(contains('private parent credential')));
    },
  );

  test(
    'spawn diagnostics failure preserves the original safe outcome',
    () async {
      final result =
          await buildHandler(
            FakeProviderClient(responses: const []),
            hooks: [diagnosticHook(failReporting: true)],
            clientResolver:
                ({
                  required providerId,
                  required model,
                  required subSessionId,
                }) async {
                  throw StateError('original initialization cause');
                },
          ).run(
            input: {'agent': reviewer.name, 'name': 'review', 'task': 'review'},
          );
      expect(result['error_code'], 'unavailable');
      expect(result['_metadata'], isNull);
      expect(
        result.toString(),
        isNot(contains('diagnostic service unavailable')),
      );
      expect(
        result.toString(),
        isNot(contains('original initialization cause')),
      );
      expect(await toolErrorPayloads(), isEmpty);
    },
  );

  for (final stage in ['initialization', 'session_create', 'execution']) {
    test(
      'spawn diagnostics report $stage cause once without exposing it',
      () async {
        final trace = diagnosticHook();
        if (stage == 'session_create') {
          persistence = _FinalizationFailingPersistence(
            appDb,
            novelId,
            novelContentDatabase: novelDb,
            failSessionRead: true,
          );
        }
        const profiled = SubAgent(
          id: 'diagnostic_child',
          slug: 'reviewer',
          name: '内容核验',
          description: 'review',
          prompt: 'Review.',
          scope: SubAgentScope.global,
          sortOrder: 0,
          providerId: 'provider_child',
          model: 'child-model',
        );
        final handler = buildHandler(
          FakeProviderClient(responses: const []),
          availableSubAgents: const [profiled],
          defaultProviderId: 'provider_child',
          defaultModel: 'child-model',
          clientResolver: stage == 'initialization'
              ? ({
                  required providerId,
                  required model,
                  required subSessionId,
                }) async {
                  throw StateError('private initialization cause');
                }
              : null,
          hooks: [trace, if (stage == 'execution') _StartFailureHook()],
        );
        const input = {
          'agent': '内容核验',
          'name': 'review',
          'task': 'private task',
        };
        final run = handler.start(input: input, callId: 'spawn-call');
        final result = await run.result;
        expect(await run.started, stage == 'execution');
        expect(result['ok'], isFalse);
        expect(result.toString(), isNot(contains('private $stage cause')));
        expect(result.containsKey('exception_message'), isFalse);
        // Background failures must already be queued before a parent tool hook.
        expect(await toolErrorPayloads(), hasLength(1));
        final parent = FakeAgent.create(
          responses: const [
            FakeProviderClientResponse.toolCalls([
              ToolCall(
                callId: 'spawn-call',
                toolName: 'SpawnAgent',
                arguments: input,
              ),
            ]),
            FakeProviderClientResponse.text('Reported failure'),
          ],
          toolManager: FakeAgentToolDispatcher.withResults(
            results: {
              'SpawnAgent': {...result},
            },
          ),
          hooks: [trace],
        );
        await parent.processText('Review');
        final modelResult = parent.contextManager.messages
            .where((message) => message.type == AgentMessageType.tool_result)
            .single
            .blocks
            .whereType<ToolResultBlock>()
            .single
            .content
            .whereType<TextBlock>()
            .single
            .text;
        expect(modelResult, contains(result['error_code']));
        expect(modelResult, isNot(contains('private $stage cause')));
        expect(modelResult, isNot(contains('tool_error_reported')));
        final payload = (await toolErrorPayloads()).single;
        expect(payload['exception_type'], 'StateError');
        expect(payload['exception_message'], contains('private $stage cause'));
        expect(payload['exception_message'], contains('failure_stage=$stage'));
        expect(
          payload['stack_top'],
          contains('spawn_agent_handler_test.dart:'),
        );
        expect(payload['stack_top'], isNot(contains('/Users/')));
        expect(payload['model'], 'child-model');
        expect(payload['provider_kind'], 'custom');
        expect(payload['tool_input'], '{}');
        expect(payload.toString(), isNot(contains('private task')));
      },
    );
  }

  for (final messages in [true, false]) {
    test(
      'spawn diagnostics report ${messages ? 'messages' : 'status'} persistence failure after success',
      () async {
        final trace = diagnosticHook();
        persistence = _FinalizationFailingPersistence(
          appDb,
          novelId,
          novelContentDatabase: novelDb,
          failMessageSave: messages,
          hideSessionDuringFinalization: !messages,
        );
        final result =
            await buildHandler(
              FakeProviderClient(
                responses: const [FakeProviderClientResponse.text('done')],
              ),
              hooks: [trace],
            ).run(
              input: {
                'agent': reviewer.name,
                'name': 'review',
                'task': 'review',
              },
            );
        expect(result['ok'], isTrue);
        expect(result['output'], 'done');
        final payload = (await toolErrorPayloads()).single;
        expect(
          payload['error_code'],
          messages
              ? 'spawn_message_persistence_failed'
              : 'spawn_status_persistence_failed',
        );
        expect(payload['exception_type'], 'StateError');
        expect(
          payload['exception_message'],
          contains(
            messages
                ? 'message persistence failed'
                : 'Spawn session disappeared',
          ),
        );
        expect(payload['stack_top'], isNotEmpty);
      },
    );
  }

  const chronicler = SubAgent(
    id: 'builtin-chronicler',
    slug: 'chronicler',
    name: '编年史者',
    description: '事实整理',
    prompt: 'stale novel-only rendered prompt',
    scope: SubAgentScope.global,
    sortOrder: 0,
  );

  test(
    'independent run freezes attribution and consumes queued instructions after tools',
    () async {
      final entered = Completer<void>();
      final finish = Completer<void>();
      var released = 0;
      final dispatcher = FakeAgentToolDispatcher(
        tools: {
          'Write': FakeAgentTool(
            def: const ToolDef(name: 'Write', description: '', inputSchema: {}),
            handler: (_, _) async {
              entered.complete();
              await finish.future;
              return {'ok': true};
            },
          ),
        },
      );
      final child = FakeProviderClient(
        responses: const [
          FakeProviderClientResponse.toolCalls([
            ToolCall(callId: 'write', toolName: 'Write', arguments: {}),
          ]),
          FakeProviderClientResponse.text('updated'),
        ],
      );
      final parentCancellation = AgentCancellationController();
      final context = ToolExecutionContext(
        sourceSessionId: parentSessionId,
        sourceTurnId: 'original_turn',
        cancellationToken: parentCancellation.token,
      );
      final handler = buildHandler(
        child,
        resourcesResolver:
            ({
              required providerId,
              required model,
              required subSessionId,
              required sourceSessionId,
            }) async => SpawnAgentResources(
              client: child,
              toolManager: dispatcher,
              release: () => released++,
            ),
      );
      final run = handler.start(
        input: {'agent': reviewer.name, 'name': '鲁迅', 'task': 'write'},
        toolExecutionContext: context,
      );
      expect(run.sendMessage('initial additional instruction'), isTrue);
      context.sourceTurnId = 'later_turn';
      await entered.future;
      parentCancellation.cancel();
      expect(run.sendMessage('keep the character alive'), isTrue);
      expect(released, 0);
      expect(child.cancelCallCount, 0);
      finish.complete();
      expect((await run.result)['output'], 'updated');
      expect(released, 1);
      expect(
        dispatcher.capturedCalls.single.context?.sourceTurnId,
        'original_turn',
      );
      expect(
        dispatcher.capturedCalls.single.context?.sessionId,
        run.subSessionId,
      );
      expect(
        child.capturedStreamRequests.first.messages.map((m) => m.content),
        contains('initial additional instruction'),
      );
      expect(
        child.capturedStreamRequests.last.messages.map((m) => m.content),
        contains('keep the character alive'),
      );
      expect(run.sendMessage('too late'), isFalse);
      final persisted = await persistence.loadSessionMessages(
        sessionId: run.subSessionId,
        novelDatabase: novelDb,
      );
      expect(
        persisted.messages.map((m) => m.content),
        contains('keep the character alive'),
      );
    },
  );

  test(
    'cancel waits for the in-flight tool, onEnd and persistence before release',
    () async {
      final entered = Completer<void>();
      final finish = Completer<void>();
      final end = _EndGateHook();
      final save = _SaveGatePersistence(
        appDb,
        novelId,
        novelContentDatabase: novelDb,
      );
      persistence = save;
      var released = 0;
      var settled = false;
      final child = FakeProviderClient(
        responses: const [
          FakeProviderClientResponse.toolCalls([
            ToolCall(callId: 'write', toolName: 'Write', arguments: {}),
          ]),
        ],
      );
      final dispatcher = FakeAgentToolDispatcher(
        tools: {
          'Write': FakeAgentTool(
            def: const ToolDef(name: 'Write', description: '', inputSchema: {}),
            handler: (_, _) async {
              entered.complete();
              await finish.future;
              return {'ok': true};
            },
          ),
        },
      );
      final run = buildHandler(
        child,
        hooks: [end],
        resourcesResolver:
            ({
              required providerId,
              required model,
              required subSessionId,
              required sourceSessionId,
            }) async => SpawnAgentResources(
              client: child,
              toolManager: dispatcher,
              release: () => released++,
            ),
      ).start(input: {'agent': reviewer.name, 'name': '鲁迅', 'task': 'write'});
      final result = run.result.then((value) {
        settled = true;
        return value;
      });
      await entered.future;
      run.cancel();
      expect(run.status, SpawnAgentRunStatus.stopping);
      expect(run.sendMessage('late'), isFalse);
      expect(settled, isFalse);
      expect(released, 0);
      finish.complete();
      await end.entered.future;
      expect(settled, isFalse);
      expect(released, 0);
      end.finish.complete();
      await save.entered.future;
      expect(settled, isFalse);
      expect(released, 0);
      save.finish.complete();
      expect((await result)['cancelled'], isTrue);
      expect(run.status, SpawnAgentRunStatus.cancelled);
      expect(released, 1);
      final saved = await persistence.getSession(run.subSessionId);
      expect(saved?.metadata?['spawn_run_status'], 'cancelled');
      run.cancel();
      expect(released, 1);
    },
  );

  test(
    'cancellation during message persistence waits and saves a cancelled terminal status',
    () async {
      final save = _SaveGatePersistence(
        appDb,
        novelId,
        novelContentDatabase: novelDb,
      );
      persistence = save;
      var released = 0;
      final child = FakeProviderClient(
        responses: const [FakeProviderClientResponse.text('done')],
      );
      final run = buildHandler(
        child,
        resourcesResolver:
            ({
              required providerId,
              required model,
              required subSessionId,
              required sourceSessionId,
            }) async => SpawnAgentResources(
              client: child,
              toolManager: FakeAgentToolDispatcher(),
              release: () => released++,
            ),
      ).start(input: {'agent': reviewer.name, 'name': '鲁迅', 'task': 'write'});
      await save.entered.future;
      run.cancel();
      expect(run.status, SpawnAgentRunStatus.stopping);
      expect(released, 0);
      save.finish.complete();
      expect((await run.result)['cancelled'], isTrue);
      expect(released, 1);
      expect(
        (await persistence.getSession(
          run.subSessionId,
        ))?.metadata?['spawn_run_status'],
        'cancelled',
      );
    },
  );

  test(
    'initialization cancellation waits for acquisition and releases without a model call',
    () async {
      final entered = Completer<void>();
      final finish = Completer<void>();
      var released = 0;
      final child = FakeProviderClient(responses: const []);
      final run = buildHandler(
        child,
        resourcesResolver:
            ({
              required providerId,
              required model,
              required subSessionId,
              required sourceSessionId,
            }) async {
              entered.complete();
              await finish.future;
              return SpawnAgentResources(
                client: child,
                toolManager: FakeAgentToolDispatcher(),
                release: () => released++,
              );
            },
      ).start(input: {'agent': reviewer.name, 'name': '鲁迅', 'task': 'write'});
      await entered.future;
      run.cancel();
      expect(released, 0);
      finish.complete();
      expect((await run.result)['cancelled'], isTrue);
      expect(await run.started, isFalse);
      expect(child.capturedStreamRequests, isEmpty);
      expect(released, 1);
    },
  );

  test(
    'initialization failure after acquisition releases the owned resources',
    () async {
      var released = 0;
      final child = FakeProviderClient(responses: const []);
      final manager = workTools(contentKindScreenplay);
      final run = buildHandler(
        child,
        workContext: const AiSessionContext(
          workId: 'different',
          contentKind: contentKindNovel,
        ),
        resourcesResolver:
            ({
              required providerId,
              required model,
              required subSessionId,
              required sourceSessionId,
            }) async => SpawnAgentResources(
              client: child,
              toolManager: manager,
              release: () {
                released++;
                manager.dispose();
              },
            ),
      ).start(input: {'agent': reviewer.name, 'name': '鲁迅', 'task': 'write'});
      expect((await run.result)['error_code'], 'unavailable');
      expect(await run.started, isFalse);
      expect(released, 1);
      expect(child.capturedStreamRequests, isEmpty);
    },
  );

  test(
    'reused sessions get distinct runs and old cancellation cannot affect a new run',
    () async {
      final entered = Completer<void>();
      final finish = Completer<void>();
      var releaseCount = 0;
      final clients = <FakeProviderClient>[];
      final handler = buildHandler(
        FakeProviderClient(responses: const []),
        resourcesResolver:
            ({
              required providerId,
              required model,
              required subSessionId,
              required sourceSessionId,
            }) async {
              final index = clients.length;
              final client = FakeProviderClient(
                responder: (_) async {
                  if (index == 1) {
                    entered.complete();
                    await finish.future;
                  }
                  return const FakeProviderClientResponse.text('done');
                },
              );
              clients.add(client);
              return SpawnAgentResources(
                client: client,
                toolManager: FakeAgentToolDispatcher(),
                release: () => releaseCount++,
              );
            },
      );
      final first = handler.start(
        input: {'agent': reviewer.name, 'name': '鲁迅', 'task': 'first'},
      );
      await first.result;
      final second = handler.start(
        input: {'agent': reviewer.name, 'name': '鲁迅', 'task': 'second'},
        resumeSessionId: first.subSessionId,
      );
      await entered.future;
      first.cancel();
      expect(first.sendMessage('old'), isFalse);
      expect(second.runId, isNot(first.runId));
      expect(second.subSessionId, first.subSessionId);
      expect(clients.last.cancelCallCount, 0);
      expect(releaseCount, 1);
      finish.complete();
      expect((await second.result)['ok'], isTrue);
      expect(releaseCount, 2);
    },
  );

  for (final failAtStartup in [true, false]) {
    test(
      'releases owned resources after ${failAtStartup ? 'session startup' : 'model'} failure',
      () async {
        var released = 0;
        final client = FakeProviderClient(
          responder: (_) => throw StateError('injected provider failure'),
        );
        if (failAtStartup) {
          await appDb.close();
        }
        final run = buildHandler(
          client,
          hooks: [_FailureHook(const AiRunFailure.streamInterrupted())],
          resourcesResolver:
              ({
                required providerId,
                required model,
                required subSessionId,
                required sourceSessionId,
              }) async => SpawnAgentResources(
                client: client,
                toolManager: FakeAgentToolDispatcher(),
                release: () => released++,
              ),
        ).start(input: {'agent': reviewer.name, 'name': '鲁迅', 'task': 'write'});
        final result = await run.result;
        expect(result['ok'], isFalse);
        expect(
          result['error_code'],
          failAtStartup ? 'unavailable' : 'internal',
        );
        expect(released, 1);
        expect(run.status, SpawnAgentRunStatus.failed);
        expect(await run.started, !failAtStartup);
      },
    );
  }

  test(
    'malformed custom prompt still runs with its complete original text',
    () async {
      const original = '  专家：{{novel_title}}\n{{#screenplay_workspace}}未闭合条件  ';
      final custom = reviewer.copyWith(useCustomPrompt: true, prompt: original);
      final client = FakeProviderClient(
        responses: const [FakeProviderClientResponse.text('完成')],
      );
      final result = await buildHandler(
        client,
        availableSubAgents: [custom],
        toolManager: workTools(contentKindScreenplay),
      ).run(input: {'agent': custom.name, 'name': '鲁迅', 'task': '按原文核验'});
      expect(result['ok'], isTrue);
      final system =
          client.capturedStreamRequests.single.messages.first.content;
      expect(system, startsWith(original));
      expect(system, contains('当前作品工作路径：/works/$novelId'));
    },
  );

  test(
    'canvas subagent initializes with canvas tool scope and resource paths',
    () async {
      final client = FakeProviderClient(
        responses: const [FakeProviderClientResponse.text('Done')],
      );
      final expert = reviewer.copyWith(prompt: 'Review this work.');
      final handler = buildHandler(
        client,
        availableSubAgents: [expert],
        toolManager: workTools(contentKindCanvas),
        allowedToolNames: () => ['Read'],
        workContext: AiSessionContext(
          workId: novelId,
          contentKind: contentKindCanvas,
        ),
      );
      final result = await handler.run(
        input: {
          'agent': expert.name,
          'name': 'Reviewer',
          'task': 'Review the canvas',
        },
      );
      expect(result['ok'], true, reason: '$result');
      final system =
          client.capturedStreamRequests.single.messages.first.content;
      expect(system, contains('当前作品类型：画布'));
      expect(system, contains('production/clips/{clip_id}'));
      expect(system, isNot(contains('chapters/{chapter_id}')));
      expect(system, isNot(contains('scenes/{scene_id}')));
    },
  );

  for (final kind in [contentKindNovel, contentKindScreenplay]) {
    test(
      'chronicler loads skill with $kind paths on new and reused sessions',
      () async {
        const body = '# 当前故事状态\n主角持有钥匙';
        final client = FakeProviderClient(
          responses: const [
            FakeProviderClientResponse.toolCalls([
              ToolCall(
                callId: 'write-state',
                toolName: 'Write',
                arguments: {
                  'path': 'story_state',
                  'fields': {'content': body},
                },
              ),
            ]),
            FakeProviderClientResponse.text('已更新状态'),
            FakeProviderClientResponse.text('已核对后续状态'),
          ],
        );
        final handler = buildHandler(
          client,
          availableSubAgents: [
            chronicler.copyWith(
              prompt: PromptTemplateService.instance.renderAsset(
                'assets/prompts/agent/chronicler',
                const {},
              ),
            ),
          ],
          toolManager: workTools(kind),
        );
        final first = await handler.run(
          input: {'agent': '编年史者', 'name': '鲁迅', 'task': '整理已写正文的事实'},
        );
        expect(first['ok'], isTrue);
        expect(
          (await novelDb.novelStateSnapshotDao.getLatestActive())?.content,
          body,
        );
        final resumed = await handler.run(
          input: {'agent': '编年史者', 'name': '鲁迅', 'task': '继续核对'},
          resumeSessionId: first['session_id'] as String,
        );
        expect(resumed['ok'], isTrue);
        expect(resumed['session_id'], first['session_id']);
        for (final request in client.capturedStreamRequests) {
          final system = request.messages
              .firstWhere((m) => m.role == AgentMessageRole.system)
              .content;
          expect(system, contains('AgentSkill {"name":"故事连续性维护"}'));
          expect(system, isNot(contains('stale novel-only rendered prompt')));
          expect(system, isNot(contains('{chapter_path}/brief')));
          expect(system, isNot(contains('区分观众已知与角色已知')));
          if (kind == contentKindScreenplay) {
            expect(system, contains('scenes/{scene_id}'));
            expect(system, isNot(contains('chapters/{chapter_id}')));
          } else {
            expect(system, contains('chapters/{chapter_id}'));
          }
        }
      },
    );
  }

  for (final kind in [contentKindNovel, contentKindScreenplay]) {
    for (final slug in ['writer', 'review', 'style_polish']) {
      test('$kind starts and reuses builtin $slug', () async {
        final agent = reviewer.copyWith(slug: slug);
        const oldSession = 'previous-novel-session';
        await persistence.upsertSession(
          id: oldSession,
          title: agent.name,
          provider: 'provider_parent',
          model: 'model_parent',
          mode: AiSessionMode.chat.value,
          agentSlug: slug,
          parentId: parentSessionId,
        );
        final client = FakeProviderClient(
          responses: const [FakeProviderClientResponse.text('已完成')],
        );
        final handler = buildHandler(
          client,
          availableSubAgents: [agent, chronicler],
          toolManager: workTools(kind),
        );
        for (final session in [null, oldSession]) {
          final result = await handler.run(
            input: {'agent': agent.name, 'name': '鲁迅', 'task': '处理剧本'},
            resumeSessionId: session,
          );
          expect(result['ok'], isTrue);
          expect(result['output'], '已完成');
        }
        final unknown = await handler.run(
          input: {'agent': '不存在', 'name': '鲁迅', 'task': '处理剧本'},
        );
        expect(unknown['error'], contains('编年史者'));
        expect(unknown['error'], contains(agent.name));
        expect(client.capturedStreamRequests, hasLength(2));
        expect(
          (await persistence.getSession(
            oldSession,
          ))?.metadata?['spawn_started_at'],
          isNotNull,
        );
      });
    }
  }

  for (final slug in ['chronicler', 'writer']) {
    test('screenplay preserves custom $slug instructions', () async {
      final custom = chronicler.copyWith(
        slug: slug,
        useCustomPrompt: true,
        prompt: '我的自定义剧本流程',
      );
      final client = FakeProviderClient(
        responses: const [FakeProviderClientResponse.text('完成')],
      );
      final result = await buildHandler(
        client,
        availableSubAgents: [custom],
        toolManager: workTools(contentKindScreenplay),
      ).run(input: {'agent': custom.name, 'name': '鲁迅', 'task': '整理剧本'});
      expect(result['ok'], isTrue);
      final system = client.capturedStreamRequests.single.messages
          .firstWhere((m) => m.role == AgentMessageRole.system)
          .content;
      expect(system, contains('我的自定义剧本流程'));
      expect(system, isNot(contains('## 剧本事实提取')));
    });
  }

  for (final kind in [contentKindNovel, contentKindScreenplay]) {
    for (final custom in [false, true]) {
      for (final tools in [false, true]) {
        test(
          '$kind custom=$custom tools=$tools receives task and refreshed work identity on reuse',
          () async {
            const task = '只处理指定资源；使用技能「我的写法」；临时要求：保留长句；验收：事实不变；交付：路径与结果。';
            final client = FakeProviderClient(
              responses: const [FakeProviderClientResponse.text('完成')],
            );
            final expert = reviewer.copyWith(
              useCustomPrompt: custom,
              slug: 'template_expert',
              prompt:
                  '  专家：{{novel_title}}\n'
                  '{{#screenplay_workspace}}场次规则{{/screenplay_workspace}}'
                  '{{^screenplay_workspace}}章节规则{{/screenplay_workspace}}  ',
            );
            final context = AiSessionContext(
              workId: novelId,
              contentKind: kind,
              sourceNovelId: 'source_other_kind',
              novelName: '当前作品',
            );
            SpawnAgentHandler handler(AiSessionContext context) => buildHandler(
              client,
              availableSubAgents: [expert],
              workContext: context,
              toolManager: workTools(kind),
              allowedToolNames: () => tools ? ['Read'] : [],
              availableSkills: const [
                AgentSkillSummary(name: '我的写法', description: '用户选定方法'),
              ],
            );
            final first = await handler(
              context,
            ).run(input: {'agent': expert.name, 'name': '鲁迅', 'task': task});
            expect(first['ok'], isTrue);
            final next =
                await handler(context.copyWith(clearSourceNovelId: true)).run(
                  input: {
                    'agent': expert.name,
                    'name': '鲁迅',
                    'task': '继续按原要求核验',
                  },
                  resumeSessionId: first['session_id'] as String,
                );
            expect(next['ok'], isTrue);
            expect(next['session_id'], first['session_id']);
            final requests = client.capturedStreamRequests;
            final firstSystem = requests.first.messages.first.content;
            final nextSystem = requests.last.messages.first.content;
            for (final system in [firstSystem, nextSystem]) {
              expect(
                system,
                startsWith(
                  '专家：当前作品\n${kind == contentKindScreenplay ? '场次规则' : '章节规则'}',
                ),
              );
              expect(
                system,
                isNot(
                  contains(kind == contentKindScreenplay ? '章节规则' : '场次规则'),
                ),
              );
              expect(system, isNot(contains('{{')));
              expect(system, contains('当前作品工作路径：/works/$novelId'));
              expect(system, isNot(contains('<work_context>')));
              expect(system, contains('<name>我的写法</name>'));
              expect(system.contains('路径语法：'), tools);
              for (final rule in [
                'Read /_schema/{collection}',
                'not_found 后禁止原样重试',
                '从工具结果原样复制，不得自行构造或修改',
                'Create、Write、Edit、Replace、Remove 只能修改当前作品',
              ]) {
                expect(rule.allMatches(system), hasLength(tools ? 1 : 0));
              }
              expect(system, isNot(contains('canvas/{name}')));
              expect(system, isNot(contains('relations/{relation_id}')));
            }
            expect(firstSystem, contains('原作工作路径：/works/source_other_kind'));
            expect(nextSystem, isNot(contains('原作工作路径：')));
            expect(nextSystem, isNot(contains('source_other_kind')));
            expect(
              requests.first.messages.any((m) => m.content == task),
              isTrue,
            );
            expect(
              requests.last.messages.any((m) => m.content == task),
              isTrue,
            );
          },
        );
      }
    }
  }

  test('rejects a tool scope that differs from the injected work', () async {
    final client = FakeProviderClient(
      responses: const [FakeProviderClientResponse.text('unused')],
    );
    final handler = buildHandler(
      client,
      toolManager: workTools(contentKindScreenplay),
      workContext: const AiSessionContext(
        workId: 'other',
        contentKind: contentKindScreenplay,
      ),
    );
    final result = await handler.run(
      input: {'agent': reviewer.name, 'name': '鲁迅', 'task': '核验'},
    );
    expect(result['error_code'], 'unavailable');
    expect(result['failure_reason'], 'work_context_mismatch');
    expect(result['error'], contains('当前作品'));
    expect(client.capturedStreamRequests, isEmpty);
  });

  test(
    'failure after a successful model fallback does not blame the model',
    () async {
      final handler = buildHandler(
        FakeProviderClient(responses: const []),
        availableSubAgents: [
          reviewer.copyWith(providerId: 'restricted', model: 'child-model'),
        ],
        toolManager: workTools(contentKindScreenplay),
        workContext: const AiSessionContext(
          workId: 'other',
          contentKind: contentKindScreenplay,
        ),
        clientResolver:
            ({
              required providerId,
              required model,
              required subSessionId,
            }) async {
              if (providerId == 'restricted') {
                throw const SpawnAgentInitializationException(
                  reason: 'model_unavailable',
                  message: '模型不可用，请重新选择模型。',
                );
              }
              return FakeProviderClient(responses: const []);
            },
      );
      final result = await handler.run(
        input: {'agent': reviewer.name, 'name': '鲁迅', 'task': '核验'},
      );
      expect(result['failure_reason'], 'work_context_mismatch');
      expect(result.containsKey('fallback_reason'), isFalse);
      expect(result['error'], contains('当前作品'));
      expect(result['error'], isNot(contains('父会话')));
    },
  );

  test('requires agent selection and a nonblank instance name', () async {
    final client = FakeProviderClient(responses: const []);
    final handler = buildHandler(client);
    for (final input in [
      {'name': reviewer.name, 'task': '核验'},
      {'agent': reviewer.name, 'task': '核验'},
      {'agent': reviewer.name, 'name': '   ', 'task': '核验'},
    ]) {
      final result = await handler.run(input: input);
      expect(result['ok'], isFalse);
      expect(result['error'], 'agent, name and task are required');
    }
    expect(client.capturedStreamRequests, isEmpty);
  });

  test('creates a new spawn session when session_id is absent', () async {
    final client = FakeProviderClient(
      responses: const [FakeProviderClientResponse.text('review done')],
    );

    final result = await buildHandler(client).run(
      input: const {'agent': '内容核验', 'name': '鲁迅', 'task': 'review chapter 1'},
      callId: 'call_1',
    );

    expect(result['ok'], isTrue);
    expect(result['output'], 'review done');
    final subSessionId = result['session_id'] as String?;
    expect(subSessionId, isNotNull);
    expect(subSessionId, startsWith('sub_session_'));

    final session = await persistence.getSession(subSessionId!);
    expect(session, isNotNull);
    expect(session!.parentId, parentSessionId);
    expect(session.agentSlug, reviewer.slug);
    expect(session.title, '鲁迅');
    expect(session.provider, 'provider_parent');
    expect(session.model, 'model_parent');
    expect(session.metadata?['spawn_run_status'], 'completed');
    expect(session.metadata?['spawn_started_at'], isNotNull);
    expect(session.metadata?['spawn_finished_at'], isNotNull);

    final persisted = await persistence.loadSessionMessages(
      sessionId: subSessionId,
      novelDatabase: novelDb,
    );
    expect(persisted.messages.map((message) => message.content), [
      'review chapter 1',
      'review done',
    ]);
  });

  test('announces the sub-session before the subagent finishes', () async {
    final subagentStarted = Completer<void>();
    final releaseSubagent = Completer<void>();
    final client = FakeProviderClient(
      responder: (_) async {
        subagentStarted.complete();
        await releaseSubagent.future;
        return const FakeProviderClientResponse.text('done');
      },
    );
    String? announcedCallId;
    String? announcedSessionId;

    final run =
        buildHandler(
          client,
          onSessionStarted: (callId, subSessionId) {
            announcedCallId = callId;
            announcedSessionId = subSessionId;
          },
        ).run(
          input: const {
            'agent': '内容核验',
            'name': '鲁迅',
            'task': 'wait for completion',
          },
          callId: 'spawn_running',
        );

    await subagentStarted.future.timeout(const Duration(seconds: 1));
    expect(announcedCallId, 'spawn_running');
    expect(announcedSessionId, startsWith('sub_session_'));

    releaseSubagent.complete();
    final result = await run;
    expect(result['session_id'], announcedSessionId);
  });

  test('forwards sub-agent thinking and tool events to the observer', () async {
    final client = FakeProviderClient(
      responses: const [
        FakeProviderClientResponse.toolCalls([
          ToolCall(
            callId: 'call_nested_read',
            toolName: 'NestedRead',
            arguments: {'path': '/chapters/chapter_1/content'},
          ),
        ], thinking: 'checking chapter 1 first'),
        FakeProviderClientResponse.text('review done'),
      ],
    );
    final dispatcher = FakeAgentToolDispatcher(
      tools: {
        'NestedRead': FakeAgentTool(
          def: ToolDef(
            name: 'NestedRead',
            description: 'Reads a chapter.',
            inputSchema: const {'type': 'object'},
          ),
          handler: (_, _) => {'ok': true},
        ),
      },
    );
    final observed = <(String, AgentEvent)>[];

    final result =
        await buildHandler(
          client,
          toolManager: dispatcher,
          onSubAgentEvent: (callId, event) => observed.add((callId, event)),
        ).run(
          input: const {
            'agent': '内容核验',
            'name': '鲁迅',
            'task': 'review chapter 1',
          },
          callId: 'spawn_observed',
        );

    expect(result['ok'], isTrue);
    expect(observed.map((entry) => entry.$1).toSet(), {'spawn_observed'});
    final events = observed.map((entry) => entry.$2).toList();
    // 第二行动态依赖这三类事件：推理增量、工具开始、工具结束。
    expect(events.whereType<AgentThinkingDelta>(), isNotEmpty);
    final toolStart = events.whereType<AgentToolCallStart>().single;
    expect(toolStart.toolName, 'NestedRead');
    expect(toolStart.arguments['path'], '/chapters/chapter_1/content');
    expect(
      events.whereType<AgentToolCallResult>().single.toolName,
      'NestedRead',
    );
  });

  test(
    'new tasks always get independent sessions and legacy session arguments are rejected',
    () async {
      final client = FakeProviderClient(
        responses: const [FakeProviderClientResponse.text('done')],
      );
      final handler = buildHandler(client);
      final input = {
        'agent': reviewer.name,
        'name': 'Author',
        'task': 'First chapter',
      };
      final first = await handler.run(input: input);
      final second = await handler.run(
        input: {...input, 'task': 'Second chapter'},
      );
      expect(first['session_id'], isNot(second['session_id']));
      expect(
        client.capturedStreamRequests.last.messages.map((m) => m.content),
        isNot(contains('First chapter')),
      );
      for (final key in ['session_id', 'sessionId']) {
        final rejected = await handler.run(
          input: {...input, key: first['session_id']},
        );
        expect(rejected['error_code'], 'invalid_argument');
      }
      expect(client.capturedStreamRequests, hasLength(2));
      final context = second['context'] as Map;
      expect(context['tokens_estimate'], greaterThan(0));
      expect(context['window_tokens'], defaultContextTokenLimit);
      expect(context['window_source'], 'default');
    },
  );

  test(
    'continuation resolves the original identity and rejects inaccessible sessions',
    () async {
      final client = FakeProviderClient(
        responses: const [FakeProviderClientResponse.text('done')],
      );
      final handler = buildHandler(client);
      final first = await handler.run(
        input: {
          'agent': reviewer.name,
          'name': 'Original Author',
          'task': 'Review',
        },
      );
      final id = first['session_id'] as String;
      expect(await handler.prepareResume(id, 'Revise'), {
        'agent': reviewer.name,
        'name': 'Original Author',
        'task': 'Revise',
      });
      for (final other in [
        buildHandler(client, resolvedParentSessionId: 'other_parent'),
        buildHandler(client, availableSubAgents: []),
        buildHandler(
          client,
          availableSubAgents: [reviewer.copyWith(enabled: false)],
        ),
      ]) {
        await expectLater(
          other.prepareResume(id, 'Wrong'),
          throwsA(isA<SpawnAgentResumeException>()),
        );
      }
      await appDb.aiChatSessionDao.softDelete(id);
      await expectLater(
        handler.prepareResume(id, 'Deleted'),
        throwsA(isA<SpawnAgentResumeException>()),
      );
      expect(client.capturedStreamRequests, hasLength(1));
    },
  );

  test(
    'context reports latest occupancy, not cumulative billing, with model window provenance',
    () async {
      final client = FakeProviderClient(
        responses: const [
          FakeProviderClientResponse.toolCalls([
            ToolCall(callId: 'read_context', toolName: 'Read', arguments: {}),
          ], usage: AiUsage(inputTokens: 10000, outputTokens: 30)),
          FakeProviderClientResponse.text(
            'done',
            usage: AiUsage(inputTokens: 11000, outputTokens: 2),
          ),
        ],
      );
      final result =
          await buildHandler(
            client,
            defaultModel: 'deepseek-chat',
            toolManager: FakeAgentToolDispatcher.withResults(
              results: {
                'Read': {'ok': true},
              },
            ),
            allowedToolNames: () => ['Read'],
          ).run(
            input: {'agent': reviewer.name, 'name': 'Author', 'task': 'Review'},
          );
      expect(result['ok'], isTrue);
      final context = result['context'] as Map;
      expect(context['tokens_estimate'], inInclusiveRange(11000, 11100));
      expect(context['window_tokens'], 128000);
      expect(context['window_source'], 'catalog');
      expect(
        context['usage_ratio'],
        closeTo((context['tokens_estimate'] as int) / 128000, 0.000001),
      );
      expect(context['compactions'], 0);
      expect(client.capturedStreamRequests, hasLength(2));
    },
  );

  test(
    'compacted history survives continuation and compaction count belongs to each run',
    () async {
      const sessionId = 'compacted_child';
      await persistence.upsertSession(
        id: sessionId,
        title: 'Author',
        provider: 'provider_parent',
        model: 'deepseek-chat',
        mode: 'chat',
        agentSlug: reviewer.slug,
        parentId: parentSessionId,
      );
      await persistence.saveMessages(
        sessionId: sessionId,
        novelDatabase: novelDb,
        messages: [
          AiMessage.user(id: 'old_question', content: 'Review old context'),
          AiMessage.assistant(id: 'long_history', content: '旧' * 128000),
        ],
      );
      final client = FakeProviderClient(
        responses: const [
          FakeProviderClientResponse.text('The hero kept the brass key.'),
          FakeProviderClientResponse.text(
            'Review complete.',
            usage: AiUsage(inputTokens: 1500, outputTokens: 8),
          ),
        ],
        repeatLastResponse: false,
      );
      final handler = buildHandler(client, defaultModel: 'deepseek-chat');
      final result = await handler.run(
        input: await handler.prepareResume(sessionId, 'Check the ending.'),
        resumeSessionId: sessionId,
      );
      expect(result['ok'], isTrue, reason: '$result');
      expect((result['context'] as Map)['compactions'], 1);
      expect(client.capturedStreamRequests, hasLength(2));
      final next = FakeProviderClient(
        responses: const [FakeProviderClientResponse.text('Confirmed.')],
      );
      final nextHandler = buildHandler(next, defaultModel: 'deepseek-chat');
      final continued = await nextHandler.run(
        input: await nextHandler.prepareResume(
          sessionId,
          'Check the key again.',
        ),
        resumeSessionId: sessionId,
      );
      expect(continued['ok'], isTrue);
      expect(
        next.capturedStreamRequests.single.messages.any(
          (m) => m.content.contains('The hero kept the brass key.'),
        ),
        isTrue,
      );
      expect((continued['context'] as Map)['compactions'], 0);
    },
  );

  test('attributes usage to the subagent session and spawn run', () async {
    var parentModel = 'model_parent';
    var parentProvider = 'provider_parent';
    final client = FakeProviderClient(
      responder: (_) {
        parentModel = 'new_parent_model';
        parentProvider = 'new_parent_provider';
        return const FakeProviderClientResponse.text(
          'review done',
          usage: AiUsage(inputTokens: 120, outputTokens: 30),
        );
      },
    );
    final usageService = UsageService(appDatabase: appDb);
    final usageHook = UsageHook(
      service: usageService,
      providerId: () => parentProvider,
      model: () => parentModel,
      sessionId: () => parentSessionId,
      novelId: () => novelId,
    );

    final result = await buildHandler(client, hooks: [usageHook]).run(
      input: const {'agent': '内容核验', 'name': '鲁迅', 'task': 'review chapter 1'},
    );

    final subSessionId = result['session_id'] as String;
    final usages = await appDb.select(appDb.aiUsages).get();
    expect(usages, hasLength(1));
    expect(usages.single.sessionId, subSessionId);
    expect(usages.single.providerId, 'provider_parent');
    expect(usages.single.model, 'model_parent');
    expect(usages.single.runId, startsWith('sub_run_'));
    expect(usages.single.runLabel, 'review chapter 1');
    expect(usages.single.inputTokens, 120);
    expect(usages.single.outputTokens, 30);

    final subSession = await persistence.getSession(subSessionId);
    expect(subSession?.metadata?['spawn_run_id'], usages.single.runId);
  });

  test(
    'allows persisted parent ids outside known temporary patterns',
    () async {
      const persistedParentId = '__persisted_parent';
      await persistence.createActiveSession(
        id: persistedParentId,
        title: 'Persisted Parent',
        provider: 'provider_parent',
        model: 'model_parent',
        mode: AiSessionMode.chat.value,
        agentSlug: 'orchestrator',
      );
      final client = FakeProviderClient(
        responses: const [FakeProviderClientResponse.text('review done')],
      );

      final result =
          await buildHandler(
            client,
            resolvedParentSessionId: persistedParentId,
          ).run(
            input: const {
              'agent': '内容核验',
              'name': '鲁迅',
              'task': 'review chapter 1',
            },
          );

      expect(result['ok'], isTrue);
      final session = await persistence.getSession(
        result['session_id'] as String,
      );
      expect(session?.parentId, persistedParentId);
    },
  );

  test(
    'successful spawn keeps its output when message persistence fails',
    () async {
      persistence = _FinalizationFailingPersistence(
        appDb,
        novelId,
        novelContentDatabase: novelDb,
        failMessageSave: true,
      );
      final client = FakeProviderClient(
        responses: const [FakeProviderClientResponse.text('review done')],
      );

      final result = await buildHandler(client).run(
        input: const {
          'agent': '内容核验',
          'name': '鲁迅',
          'task': 'review chapter 1',
        },
      );

      expect(result['ok'], isTrue);
      expect(result['output'], 'review done');
      final inspector = AiSessionPersistenceService(appDb, novelId);
      final session = await inspector.getSession(
        result['session_id'] as String,
      );
      expect(session, isNotNull);
      expect(session!.metadata?['spawn_run_status'], 'completed');
      expect(
        session.metadata?['spawn_persistence_error_code'],
        'spawn_message_persistence_failed',
      );
    },
  );

  test(
    'successful spawn keeps its output when terminal status update fails',
    () async {
      persistence = _FinalizationFailingPersistence(
        appDb,
        novelId,
        novelContentDatabase: novelDb,
        hideSessionDuringFinalization: true,
      );
      final client = FakeProviderClient(
        responses: const [FakeProviderClientResponse.text('review done')],
      );

      final result = await buildHandler(client).run(
        input: const {
          'agent': '内容核验',
          'name': '鲁迅',
          'task': 'review chapter 1',
        },
      );

      expect(result['ok'], isTrue);
      expect(result['output'], 'review done');
    },
  );

  for (final (failure, reason) in [
    (const AiRunFailure.http(statusCode: 401), 'authentication failed'),
    (const AiRunFailure.http(statusCode: 429), 'rate limit reached'),
    (const AiRunFailure.network(), 'Network connection failed'),
    (const AiRunFailure.streamInterrupted(), 'response stream was interrupted'),
    (
      const AiRunFailure.contextWindowExhausted(),
      'context window was exhausted',
    ),
    (const AiRunFailure.incompleteResponse(), 'incomplete response'),
  ]) {
    test('describes sub-agent failure: $reason', () async {
      final client = FakeProviderClient(
        responder: (_) => throw StateError('private provider details'),
      );
      final result = await buildHandler(
        client,
        hooks: [_FailureHook(failure)],
      ).run(input: {'agent': reviewer.name, 'name': '鲁迅', 'task': '核验'});
      expect(result['ok'], isFalse);
      expect(result['error'], contains('Sub-agent "鲁迅" (内容核验)'));
      expect(result['error'], contains(reason));
      expect(result['failure_kind'], failure.kind.name);
      expect(result['provider_kind'], 'custom');
      expect(result['status_code'], failure.statusCode);
      expect(result.toString(), isNot(contains('private provider details')));
    });
  }

  test(
    'child failure reports the resolved provider instead of the parent',
    () async {
      final client = FakeProviderClient(
        responder: (_) => throw StateError('provider failure'),
      );
      final child = reviewer.copyWith(
        providerId: 'provider_child',
        model: 'child-model',
      );
      final result = await buildHandler(
        client,
        availableSubAgents: [child],
        clientResolver:
            ({
              required providerId,
              required model,
              required subSessionId,
            }) async => client,
        hooks: [_FailureHook(const AiRunFailure.streamInterrupted())],
      ).run(input: {'agent': child.name, 'name': '鲁迅', 'task': '核验'});
      expect(result['error_code'], 'internal');
      expect(result['provider_kind'], 'custom');
      final session = await persistence.getSession(
        result['session_id'] as String,
      );
      expect(session?.provider, child.providerId);
      expect(session?.model, 'child-model');
    },
  );

  test('AgentError stays structured when terminal persistence fails', () async {
    persistence = _FinalizationFailingPersistence(
      appDb,
      novelId,
      novelContentDatabase: novelDb,
      failMessageSave: true,
    );
    final client = FakeProviderClient(
      responder: (_) => throw StateError('sub-agent provider failed'),
    );

    final result = await buildHandler(client).run(
      input: const {'agent': '内容核验', 'name': '鲁迅', 'task': 'review chapter 1'},
    );

    expect(result['ok'], isFalse);
    expect(result['error_code'], 'internal');
    expect(result['error'], contains('Sub-agent "鲁迅" (内容核验)'));
    expect(result['error'], contains('The model request failed'));
    expect(result['failure_kind'], 'requestFailed');
    expect(result.toString(), isNot(contains('sub-agent provider failed')));
  });

  test(
    'cancelled spawn stays cancelled when terminal persistence fails',
    () async {
      persistence = _FinalizationFailingPersistence(
        appDb,
        novelId,
        novelContentDatabase: novelDb,
        failMessageSave: true,
      );
      final client = FakeProviderClient(
        responses: const [FakeProviderClientResponse.text('已完成')],
      );
      final cancellationController = AgentCancellationController()..cancel();

      final result = await buildHandler(client).run(
        input: const {
          'agent': '内容核验',
          'name': '鲁迅',
          'task': 'cancel immediately',
        },
        toolExecutionContext: ToolExecutionContext(
          cancellationToken: cancellationController.token,
        ),
      );

      expect(result['cancelled'], isTrue);
      expect(result['error_code'], 'user_cancelled');
      expect(client.capturedStreamRequests, isEmpty);
    },
  );

  test(
    'reuses an explicit spawn session and writes back to the same id',
    () async {
      const subSessionId = 'sub_session_existing';
      await persistence.upsertSession(
        id: subSessionId,
        title: '鲁迅',
        provider: 'provider_parent',
        model: 'model_parent',
        mode: AiSessionMode.chat.value,
        agentSlug: reviewer.slug,
        parentId: parentSessionId,
      );
      await persistence.saveMessages(
        sessionId: subSessionId,
        novelDatabase: novelDb,
        messages: [
          AiMessage.user(id: 'old_user', content: 'old context'),
          AiMessage.assistant(id: 'old_assistant', content: 'old answer'),
        ],
      );
      final client = FakeProviderClient(
        responses: const [FakeProviderClientResponse.text('next answer')],
      );

      final result = await buildHandler(client).run(
        input: const {'agent': '内容核验', 'name': '鲁迅', 'task': 'continue review'},
        resumeSessionId: subSessionId,
        callId: 'call_2',
      );

      expect(result['ok'], isTrue);
      expect(result['session_id'], subSessionId);
      expect((await persistence.getSession(subSessionId))!.title, '鲁迅');
      final requestMessages = client.capturedStreamRequests.single.messages;
      expect(
        requestMessages.map((message) => message.content),
        containsAllInOrder(['old context', 'old answer', 'continue review']),
      );

      final persisted = await persistence.loadSessionMessages(
        sessionId: subSessionId,
        novelDatabase: novelDb,
      );
      expect(persisted.messages.map((message) => message.content), [
        'old context',
        'old answer',
        'continue review',
        'next answer',
      ]);
    },
  );

  test(
    'rejects a spawn session from another parent without creating one',
    () async {
      const foreignSessionId = 'sub_session_foreign';
      await persistence.upsertSession(
        id: foreignSessionId,
        title: '内容核验',
        provider: 'provider_parent',
        model: 'model_parent',
        mode: AiSessionMode.chat.value,
        agentSlug: reviewer.slug,
        parentId: 'ai_session_other_parent',
      );
      final client = FakeProviderClient(
        responses: const [FakeProviderClientResponse.text('unused')],
      );

      final result = await buildHandler(client).run(
        input: const {'agent': '内容核验', 'name': '鲁迅', 'task': 'continue review'},
        resumeSessionId: foreignSessionId,
        callId: 'call_3',
      );

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'not_found');
      expect(result, isNot(contains('session_id')));
      expect(client.capturedStreamRequests, isEmpty);

      final countRow = await appDb
          .customSelect(
            'SELECT COUNT(*) AS c FROM ai_chat_sessions',
            readsFrom: {appDb.aiChatSessions},
          )
          .getSingle();
      expect(countRow.read<int>('c'), 2);
    },
  );

  test('continuation keeps the persisted agent when names collide', () async {
    final twin = reviewer.copyWith(slug: 'reviewer_twin');
    const twinSessionId = 'sub_session_twin';
    await persistence.upsertSession(
      id: twinSessionId,
      title: '鲁迅',
      provider: 'provider_parent',
      model: 'model_parent',
      mode: AiSessionMode.chat.value,
      agentSlug: twin.slug,
      parentId: parentSessionId,
    );
    final client = FakeProviderClient(
      responses: const [FakeProviderClientResponse.text('twin answer')],
    );

    final result =
        await buildHandler(client, availableSubAgents: [reviewer, twin]).run(
          input: {
            'agent': reviewer.name,
            'name': '鲁迅',
            'task': 'continue review',
          },
          resumeSessionId: twinSessionId,
          callId: 'call_twin',
        );

    expect(result['ok'], isTrue);
    expect(result['session_id'], twinSessionId);
    expect(client.capturedStreamRequests, hasLength(1));
  });

  test(
    'uses child session for state and parent session for mutations',
    () async {
      final client = FakeProviderClient(
        responses: const [
          FakeProviderClientResponse.toolCalls([
            ToolCall(
              callId: 'call_nested_write',
              toolName: 'NestedWrite',
              arguments: {'path': '/chapters/chapter_1/content'},
            ),
          ]),
          FakeProviderClientResponse.text('done'),
        ],
      );
      final dispatcher = FakeAgentToolDispatcher(
        tools: {
          'NestedWrite': FakeAgentTool(
            def: ToolDef(
              name: 'NestedWrite',
              description: 'Captures inherited execution context.',
              inputSchema: const {'type': 'object'},
            ),
            handler: (_, _) => {'ok': true},
          ),
        },
      );
      final context = ToolExecutionContext(
        sessionId: 'session_1',
        sourceSessionId: 'session_1',
        sourceTurnId: 'turn_1',
      );

      final result = await buildHandler(client, toolManager: dispatcher).run(
        input: const {
          'agent': '内容核验',
          'name': '鲁迅',
          'task': 'use nested write',
        },
        callId: 'call_spawn',
        toolExecutionContext: context,
      );

      expect(result['ok'], isTrue);
      final subSessionId = result['session_id'] as String?;
      expect(subSessionId, isNotNull);
      final captured = dispatcher.capturedCalls.single.context;
      expect(captured?.sourceSessionId, 'session_1');
      expect(captured?.sourceTurnId, 'turn_1');
      expect(captured?.sessionId, subSessionId);
      expect(identical(captured, context), isFalse);
    },
  );

  test(
    'prefers subagent profile model when resolver returns a client',
    () async {
      final parentClient = FakeProviderClient(
        responses: const [FakeProviderClientResponse.text('should not run')],
      );
      final subClient = FakeProviderClient(
        responses: const [FakeProviderClientResponse.text('sub model reply')],
      );
      const profiled = SubAgent(
        id: 'sub_profiled',
        slug: 'reviewer',
        name: '内容核验',
        description: 'review',
        prompt: 'You are a reviewer.',
        scope: SubAgentScope.global,
        sortOrder: 0,
        providerId: 'provider_sub',
        model: 'model_sub',
        reasoningEffort: 'high',
      );

      String? resolvedSubSessionId;
      final result =
          await buildHandler(
            parentClient,
            availableSubAgents: const [profiled],
            agentConfig: const AgentConfig(reasoningEffort: 'low'),
            clientResolver:
                ({
                  required String providerId,
                  required String model,
                  required String subSessionId,
                }) async {
                  expect(providerId, 'provider_sub');
                  expect(model, 'model_sub');
                  resolvedSubSessionId = subSessionId;
                  return subClient;
                },
          ).run(
            input: const {
              'agent': '内容核验',
              'name': '鲁迅',
              'task': 'review with profile model',
            },
            callId: 'call_model',
          );

      expect(result['ok'], isTrue);
      // client 必须按子会话解析，请求才会以子会话身份上报 trace。
      expect(resolvedSubSessionId, result['session_id']);
      expect(result['output'], 'sub model reply');
      expect(result['_metadata'], {
        'sub_agent_model': 'model_sub',
        'sub_agent_provider_id': 'provider_sub',
      });
      expect(parentClient.capturedStreamRequests, isEmpty);
      expect(subClient.capturedStreamRequests, hasLength(1));
      expect(
        subClient.capturedStreamRequests.single.options?.reasoningEffort,
        'high',
      );

      final session = await persistence.getSession(
        result['session_id'] as String,
      );
      expect(session?.provider, 'provider_sub');
      expect(session?.model, 'model_sub');
    },
  );

  test(
    'model fallback creates independent resources with parent configuration',
    () async {
      final parentClient = FakeProviderClient(
        responses: const [FakeProviderClientResponse.text('parent reply')],
      );
      const profiled = SubAgent(
        id: 'sub_unavailable',
        slug: 'reviewer',
        name: '内容核验',
        description: 'review',
        prompt: 'You are a reviewer.',
        scope: SubAgentScope.global,
        sortOrder: 0,
        providerId: 'provider_sub',
        model: 'model_sub',
        reasoningEffort: 'high',
      );

      final entered = Completer<void>();
      final finish = Completer<void>();
      final child = FakeProviderClient(
        responder: (_) async {
          entered.complete();
          await finish.future;
          return const FakeProviderClientResponse.text('fallback reply');
        },
      );
      final selections = <String>[];
      var releases = 0;
      final parentCancellation = AgentCancellationController();
      final trace = diagnosticHook();
      final run =
          buildHandler(
            parentClient,
            availableSubAgents: const [profiled],
            agentConfig: const AgentConfig(reasoningEffort: 'low'),
            hooks: [trace],
            resourcesResolver:
                ({
                  required String providerId,
                  required String model,
                  required String subSessionId,
                  required String sourceSessionId,
                }) async {
                  selections.add('$providerId::$model');
                  expect(sourceSessionId, parentSessionId);
                  if (providerId == 'provider_sub') {
                    throw StateError('configured model unavailable');
                  }
                  return SpawnAgentResources(
                    client: child,
                    toolManager: FakeAgentToolDispatcher(),
                    release: () => releases++,
                  );
                },
          ).start(
            input: const {'agent': '内容核验', 'name': '鲁迅', 'task': 'fallback'},
            callId: 'call_fallback',
            toolExecutionContext: ToolExecutionContext(
              sourceSessionId: parentSessionId,
              cancellationToken: parentCancellation.token,
            ),
          );
      expect(await run.started, isTrue);
      await entered.future;
      parentCancellation.cancel();
      parentClient.cancel();
      expect(child.cancelCallCount, 0);
      expect(releases, 0);
      finish.complete();
      final result = await run.result;
      expect(result['ok'], isTrue);
      expect(result['output'], 'fallback reply');
      expect(result.containsKey('warning'), isFalse);
      expect(result.containsKey('error'), isFalse);
      expect(
        result.toString(),
        isNot(contains('configured model unavailable')),
      );
      expect(result['_metadata'], {
        'sub_agent_model': 'model_parent',
        'sub_agent_provider_id': 'provider_parent',
      });
      expect(selections, [
        'provider_sub::model_sub',
        'provider_parent::model_parent',
      ]);
      expect(parentClient.capturedStreamRequests, isEmpty);
      expect(
        child.capturedStreamRequests.single.options?.reasoningEffort,
        'low',
      );
      expect(releases, 1);
      final persisted = await persistence.getSession(run.subSessionId);
      expect(persisted?.provider, 'provider_parent');
      expect(persisted?.model, 'model_parent');
      // 回退成功属于设计内降级，不上报匿名错误。
      expect(await toolErrorPayloads(), isEmpty);
    },
  );

  for (final sameModel in [true, false]) {
    test(
      'model fallback reports unavailable resources, same model=$sameModel',
      () async {
        final trace = diagnosticHook();
        final attempts = <String>[];
        final profiled = reviewer.copyWith(
          providerId: sameModel ? 'provider_parent' : 'provider_child',
          model: sameModel ? 'model_parent' : 'model_sub',
        );
        final result =
            await buildHandler(
              FakeProviderClient(responses: const []),
              defaultProviderId: 'provider_parent',
              availableSubAgents: [profiled],
              hooks: [trace],
              clientResolver:
                  ({
                    required providerId,
                    required model,
                    required subSessionId,
                  }) async {
                    attempts.add(providerId);
                    throw StateError('unavailable $providerId');
                  },
            ).run(
              input: {
                'agent': reviewer.name,
                'name': 'review',
                'task': 'review',
              },
            );
        expect(result['error_code'], 'unavailable');
        expect(
          attempts,
          sameModel
              ? ['provider_parent']
              : ['provider_child', 'provider_parent'],
        );
        final payloads = await toolErrorPayloads();
        expect(payloads, hasLength(1));
        expect(payloads.last['error_code'], 'unavailable');
        expect(payloads.last['provider_kind'], 'custom');
        expect(payloads.last['model'], 'model_parent');
        expect(
          payloads.last['exception_message'],
          contains('unavailable provider_parent'),
        );
      },
    );
  }

  test(
    'model fallback attributes subsequent execution failure to the parent model',
    () async {
      final trace = diagnosticHook();
      final result =
          await buildHandler(
            FakeProviderClient(responses: const []),
            defaultProviderId: 'provider_parent',
            availableSubAgents: [
              reviewer.copyWith(
                providerId: 'provider_child',
                model: 'model_sub',
              ),
            ],
            hooks: [trace, _StartFailureHook()],
            clientResolver:
                ({
                  required providerId,
                  required model,
                  required subSessionId,
                }) async {
                  if (providerId == 'provider_child') {
                    throw StateError('configured model unavailable');
                  }
                  return FakeProviderClient(responses: const []);
                },
          ).run(
            input: {'agent': reviewer.name, 'name': 'review', 'task': 'review'},
          );
      expect(result['error_code'], 'internal');
      final payloads = await toolErrorPayloads();
      expect(payloads, hasLength(1));
      expect(payloads.last['model'], 'model_parent');
      expect(payloads.last['provider_kind'], 'custom');
      expect(
        payloads.last['exception_message'],
        contains('private execution cause'),
      );
    },
  );

  test('resolves a sub session client with the parent model when the subagent '
      'has no profile model', () async {
    final parentClient = FakeProviderClient(
      responses: const [FakeProviderClientResponse.text('should not run')],
    );
    final subClient = FakeProviderClient(
      responses: const [FakeProviderClientResponse.text('sub session reply')],
    );
    final resolverCalls = <({String providerId, String model, String sid})>[];

    final result =
        await buildHandler(
          parentClient,
          agentConfig: const AgentConfig(reasoningEffort: 'low'),
          clientResolver:
              ({
                required String providerId,
                required String model,
                required String subSessionId,
              }) async {
                resolverCalls.add((
                  providerId: providerId,
                  model: model,
                  sid: subSessionId,
                ));
                return subClient;
              },
        ).run(
          input: const {'agent': '内容核验', 'name': '鲁迅', 'task': 'review'},
          callId: 'call_default_model',
        );

    expect(result['ok'], isTrue);
    expect(result['output'], 'sub session reply');
    // 沿用父模型，因此不上报 sub_agent_model，agentConfig 也保持父级。
    expect(result.containsKey('_metadata'), isFalse);
    expect(parentClient.capturedStreamRequests, isEmpty);
    expect(
      subClient.capturedStreamRequests.single.options?.reasoningEffort,
      'low',
    );
    expect(resolverCalls, hasLength(1));
    expect(resolverCalls.single.providerId, 'provider_parent');
    expect(resolverCalls.single.model, 'model_parent');
    expect(resolverCalls.single.sid, result['session_id']);
  });

  test('injects enabled user rules into subagent system prompt', () async {
    final now = DateTime.now();
    await novelDb.agentRuleDao.upsert(
      AgentRule(
        id: 'rule_1',
        name: '章节字数',
        content: '每章约 4000 字',
        enabled: true,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
        deletedAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
    await novelDb.agentRuleDao.upsert(
      AgentRule(
        id: 'rule_disabled',
        name: '禁用规则',
        content: '不应出现',
        enabled: false,
        sortOrder: 1,
        createdAt: now,
        updatedAt: now,
        deletedAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );

    final client = FakeProviderClient(
      responses: const [FakeProviderClientResponse.text('ok')],
    );

    final result = await buildHandler(client).run(
      input: const {'agent': '内容核验', 'name': '鲁迅', 'task': 'check rules'},
      callId: 'call_rules',
    );

    expect(result['ok'], isTrue);
    final system = client.capturedStreamRequests.single.messages
        .firstWhere((message) => message.role == AgentMessageRole.system)
        .content;
    expect(system, contains('You are a reviewer.'));
    // 有工具的 SubAgent 注入 pathSchema + 工具使用准则两段共享块
    // （准则 fragment 不带标题，标题由 chat use case 加）。
    expect(system, contains('路径语法：'));
    expect(system, contains('同一响应内的多个直接工具调用不能依赖彼此的结果'));
    expect(system, contains('工具返回失败、报错或 skipped 时，不要直接跳过原任务'));
    expect(system, contains('<user_rule>章节字数：每章约 4000 字</user_rule>'));
    expect(system, isNot(contains('不应出现')));
  });

  for (final allowWrite in [true, false]) {
    test(
      'Codemode uses child hooks, scope and tool permissions: write=$allowWrite',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final activity = container.read(
          spawnAgentActiveRunProvider('spawn_code').notifier,
        );
        AiToolCallBlock? liveBlock;
        final runtime = _SubAgentCodemodeRuntime();
        final hook = _CodemodeRecordingHook();
        final dispatcher = FakeAgentToolDispatcher.withResults(
          results: {
            'Read': {'ok': true, 'value': 'draft'},
            'Write': {'ok': true, 'updated': true},
          },
        );
        final client = FakeProviderClient(
          responses: const [
            FakeProviderClientResponse.toolCalls([
              ToolCall(
                callId: 'code',
                toolName: 'Codemode',
                arguments: {
                  'code':
                      'const r = await tools.Read({path: "profile/title"}); return await tools.Write({path: "profile/title", value: r.value});',
                },
              ),
            ]),
            FakeProviderClientResponse.text('done'),
          ],
        );
        final result =
            await buildHandler(
              client,
              toolManager: dispatcher,
              allowedToolNames: () => ['Read', if (allowWrite) 'Write'],
              codemodeRuntimeFactory: () => runtime,
              hooks: [hook],
              onSubAgentEvent: (_, event) {
                activity.apply(event);
                if (event is AgentToolCallResult &&
                    event.toolName == 'Codemode') {
                  // Capture before the child finishes and persists its messages.
                  liveBlock = container
                      .read(spawnAgentActiveRunProvider('spawn_code'))!
                      .toolCalls
                      .single;
                }
              },
            ).run(
              callId: 'spawn_code',
              input: {
                'agent': reviewer.name,
                'name': '鲁迅',
                'task': 'edit title',
              },
              toolExecutionContext: ToolExecutionContext(
                sessionId: parentSessionId,
                sourceSessionId: parentSessionId,
                sourceTurnId: 'source_turn',
              ),
            );
        expect(result['ok'], isTrue);
        expect(liveBlock, isNotNull);
        expect(liveBlock!.result?['completed_count'], allowWrite ? 2 : 1);
        expect(liveBlock!.nestedCalls.map((c) => c.toolName), [
          'Read',
          'Write',
        ]);
        expect(liveBlock!.arguments['code'], contains('tools.Read'));
        expect(
          liveBlock!.status,
          allowWrite ? AiToolCallStatus.success : AiToolCallStatus.error,
        );
        if (allowWrite) {
          expect(liveBlock!.result?['output'], [
            {'ok': true, 'updated': true},
          ]);
          expect(liveBlock!.nestedCalls.first.resultPreview, contains('draft'));
        } else {
          expect(liveBlock!.result?['error_code'], 'codemode_tool_forbidden');
          expect(
            liveBlock!.nestedCalls.last.errorCode,
            'codemode_tool_forbidden',
          );
        }
        expect(
          client.capturedStreamRequests.first.tools!.map((t) => t.name),
          contains('Codemode'),
        );
        expect(runtime.toolNames, ['Read', if (allowWrite) 'Write']);
        expect(dispatcher.capturedCalls.map((c) => c.name), [
          'Read',
          if (allowWrite) 'Write',
        ]);
        expect(hook.before, ['Codemode', 'Read', if (allowWrite) 'Write']);
        expect(hook.after, ['Read', if (allowWrite) 'Write', 'Codemode']);
        for (final call in dispatcher.capturedCalls) {
          expect(call.context!.sessionId, result['session_id']);
          expect(call.context!.sourceSessionId, parentSessionId);
          expect(call.context!.sourceTurnId, 'source_turn');
          expect(call.context!.parentToolCallId, 'code');
        }
        final saved = await persistence.loadSessionMessages(
          sessionId: result['session_id'] as String,
          novelDatabase: novelDb,
        );
        final block = saved.messages
            .expand((m) => m.blocks)
            .whereType<AiToolCallBlock>()
            .single;
        expect(block.toolName, 'Codemode');
        expect(block.nestedCalls.map((c) => c.toolName), ['Read', 'Write']);
        expect(block.result!['completed_count'], allowWrite ? 2 : 1);
        expect(liveBlock!.result, block.result);
        expect(
          liveBlock!.nestedCalls.map((call) => call.toJson()),
          block.nestedCalls.map((call) => call.toJson()),
        );
        if (!allowWrite) {
          expect(block.nestedCalls.last.errorCode, 'codemode_tool_forbidden');
        }
        expect(codemodeScheduler.activeCount, 0);
        final continued =
            await buildHandler(
              FakeProviderClient(
                responses: const [FakeProviderClientResponse.text('continued')],
              ),
            ).run(
              input: {'agent': reviewer.name, 'name': '鲁迅', 'task': 'continue'},
              resumeSessionId: result['session_id'] as String,
            );
        expect(continued['ok'], isTrue);
        final reloaded = await persistence.loadSessionMessages(
          sessionId: result['session_id'] as String,
          novelDatabase: novelDb,
        );
        final oldCall = reloaded.messages
            .expand((m) => m.blocks)
            .whereType<AiToolCallBlock>()
            .single;
        expect(
          oldCall.nestedCalls.map((call) => call.callId),
          block.nestedCalls.map((call) => call.callId),
        );
      },
    );
  }

  test(
    'Codemode cancellation waits for a child write and releases shared capacity',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final activity = container.read(
        spawnAgentActiveRunProvider('spawn_cancel').notifier,
      );
      AiToolCallBlock? liveBlock;
      final entered = Completer<void>();
      final finish = Completer<void>();
      var released = false;
      late FakeAgentToolDispatcher dispatcher;
      dispatcher = FakeAgentToolDispatcher(
        tools: {
          'Read': FakeAgentTool(
            def: const ToolDef(name: 'Read', description: '', inputSchema: {}),
            handler: (_, _) async => {'ok': true, 'value': 'draft'},
          ),
          'Write': FakeAgentTool(
            def: const ToolDef(name: 'Write', description: '', inputSchema: {}),
            handler: (_, _) async {
              final observer =
                  dispatcher.capturedCalls.last.context!.lifecycleObserver!;
              observer.onStarted!(null);
              entered.complete();
              await finish.future;
              final result = {'ok': true, 'updated': true};
              observer.onFinished!(result, null);
              return result;
            },
          ),
        },
      );
      final client = FakeProviderClient(
        responses: const [
          FakeProviderClientResponse.toolCalls([
            ToolCall(
              callId: 'code',
              toolName: 'Codemode',
              arguments: {'code': 'read and write'},
            ),
          ]),
        ],
      );
      final run =
          buildHandler(
            client,
            codemodeRuntimeFactory: _SubAgentCodemodeRuntime.new,
            resourcesResolver:
                ({
                  required providerId,
                  required model,
                  required subSessionId,
                  required sourceSessionId,
                }) async => SpawnAgentResources(
                  client: client,
                  toolManager: dispatcher,
                  release: () => released = true,
                ),
          ).start(
            callId: 'spawn_cancel',
            input: {'agent': reviewer.name, 'name': '鲁迅', 'task': 'edit title'},
            onEvent: (_, event) {
              activity.apply(event);
              if (event is AgentToolSkipped && event.toolName == 'Codemode') {
                liveBlock = container
                    .read(spawnAgentActiveRunProvider('spawn_cancel'))!
                    .toolCalls
                    .single;
              }
            },
          );
      await entered.future;
      run.cancel();
      expect(released, isFalse);
      expect(codemodeScheduler.activeCount, 1);
      finish.complete();
      expect((await run.result)['cancelled'], isTrue);
      expect(liveBlock, isNotNull);
      expect(liveBlock!.status, AiToolCallStatus.cancelled);
      expect(liveBlock!.result?['completed_operations'], hasLength(1));
      expect(liveBlock!.nestedCalls.map((call) => call.toolName), [
        'Read',
        'Write',
      ]);
      expect(released, isTrue);
      expect(codemodeScheduler.activeCount, 0);
      final saved = await persistence.loadSessionMessages(
        sessionId: run.subSessionId,
        novelDatabase: novelDb,
      );
      final block = saved.messages
          .expand((m) => m.blocks)
          .whereType<AiToolCallBlock>()
          .single;
      expect(block.result!['completed_operations'], hasLength(1));
      expect(block.nestedCalls.last.toolName, 'Write');
      expect(liveBlock!.result, block.result);
      expect(
        liveBlock!.nestedCalls.map((call) => call.toJson()),
        block.nestedCalls.map((call) => call.toJson()),
      );
    },
  );

  test(
    'explorer preserves MCP Run while rejecting ordinary Run and Write',
    () async {
      final connection = ExecutionConnection();
      await McpSettingsOrchestrator().save(
        database: appDb,
        create: true,
        config: McpServerConfig(
          name: 'notes',
          enabled: true,
          exposure: McpExposure.direct,
          connection: McpHttpConfig(url: 'https://example.test'),
        ),
      );
      final service = McpSettingsService(
        appDb,
        supportsStdio: true,
        connector: (_) async => connection,
      );
      addTearDown(service.close);
      await service.initialized;
      final content = NovelContentService(novelDb);
      final manager = AiToolManager(
        content,
        workId: novelId,
        workingOverlayService: WorkingOverlayService(
          novelDb,
          content,
          novelActionsService: NovelActionsService(appDb),
        ),
      )..registerAllTools();
      final client = FakeProviderClient(
        responses: const [
          FakeProviderClientResponse.toolCalls([
            ToolCall(
              callId: 'help',
              toolName: 'Run',
              arguments: {'command': 'help', 'subcommand': 'mcp'},
            ),
            ToolCall(
              callId: 'list',
              toolName: 'Run',
              arguments: {'command': 'mcp', 'subcommand': 'list'},
            ),
            ToolCall(
              callId: 'mcp-call',
              toolName: 'Run',
              arguments: {
                'command': 'mcp',
                'subcommand': 'call',
                'options': {
                  'name': 'mcp__notes__write',
                  'arguments': {'number': 1},
                },
              },
            ),
            ToolCall(
              callId: 'ordinary',
              toolName: 'Run',
              arguments: {'command': 'novel'},
            ),
            ToolCall(
              callId: 'write',
              toolName: 'Write',
              arguments: {
                'path': '/chapters/test/content',
                'value': 'forbidden',
              },
            ),
          ]),
          FakeProviderClientResponse.text('done'),
        ],
      );
      await buildHandler(
        client,
        toolManager: manager,
        mcpService: service,
        availableSubAgents: [reviewer.copyWith(slug: 'explorer')],
      ).run(
        input: const {'agent': '内容核验', 'name': '鲁迅', 'task': 'discover MCP'},
      );
      final names = client.capturedStreamRequests.first.tools!.map(
        (tool) => tool.name,
      );
      expect(names, contains('Run'));
      expect(names, isNot(contains('Write')));
      final results = {
        for (final block
            in client.capturedStreamRequests.last.messages
                .expand((m) => m.blocks)
                .whereType<ToolResultBlock>())
          block.toolCallId:
              jsonDecode(
                    block.content
                        .whereType<TextBlock>()
                        .map((b) => b.text)
                        .join(),
                  )
                  as Map<String, dynamic>,
      };
      for (final call in ['help', 'list', 'mcp-call']) {
        expect(results[call]?['ok'], true, reason: '$call: ${results[call]}');
      }
      expect(results['help'].toString(), contains('MCP commands:'));
      expect(connection.calls, 1);
      for (final call in ['ordinary', 'write']) {
        expect(results[call]?['error_code'], 'permission_denied');
      }
    },
  );

  test(
    'explorer rejects direct writes despite a model emitting an undeclared call',
    () async {
      var writes = 0;
      final dispatcher = FakeAgentToolDispatcher(
        tools: {
          for (final name in ['Read', 'Write', 'Run'])
            name: FakeAgentTool(
              def: ToolDef(
                name: name,
                description: name,
                inputSchema: const {'type': 'object'},
              ),
              handler: (_, _) async {
                if (name != 'Read') {
                  writes++;
                }
                return {'ok': true};
              },
            ),
        },
      );
      final client = FakeProviderClient(
        responses: const [
          FakeProviderClientResponse.toolCalls([
            ToolCall(
              callId: 'write',
              toolName: 'Write',
              arguments: {
                'path': '/chapters/test/content',
                'value': 'forbidden',
              },
            ),
            ToolCall(
              callId: 'run',
              toolName: 'Run',
              arguments: {'command': 'novel'},
            ),
          ]),
          FakeProviderClientResponse.text('done'),
        ],
      );
      final result =
          await buildHandler(
            client,
            toolManager: dispatcher,
            availableSubAgents: [reviewer.copyWith(slug: 'explorer')],
          ).run(
            input: const {'agent': '内容核验', 'name': '鲁迅', 'task': 'read only'},
            callId: 'explorer',
          );
      expect(result['ok'], true);
      expect(writes, 0);
      final names = client.capturedStreamRequests.first.tools!
          .map((tool) => tool.name)
          .toSet();
      expect(names, contains('Read'));
      expect(names, isNot(contains('Write')));
      expect(names, isNot(contains('Run')));
      final returned = client.capturedStreamRequests.last.messages
          .expand((message) => message.blocks)
          .whereType<ToolResultBlock>()
          .expand((block) => block.content)
          .whereType<TextBlock>()
          .map((block) => block.text)
          .join(' ');
      expect(returned, contains('permission_denied'));
    },
  );

  test('injects path schema when subagent has tools', () async {
    final client = FakeProviderClient(
      responses: const [FakeProviderClientResponse.text('ok')],
    );

    final result = await buildHandler(client).run(
      input: const {'agent': '内容核验', 'name': '鲁迅', 'task': 'check paths'},
      callId: 'call_path_schema',
    );

    expect(result['ok'], isTrue);
    final system = client.capturedStreamRequests.single.messages
        .firstWhere((message) => message.role == AgentMessageRole.system)
        .content;
    expect(system, contains('You are a reviewer.'));
    expect(system, contains('路径语法：'));
    expect(system, contains('story_state'));
  });

  test('skips path schema when subagent has no tools', () async {
    final client = FakeProviderClient(
      responses: const [FakeProviderClientResponse.text('ok')],
    );
    final handler = SpawnAgentHandler(
      pluginHost: emptyPluginHost(),
      codemodeScheduler: codemodeScheduler,
      workContext: const AiSessionContext(
        workId: novelId,
        contentKind: contentKindNovel,
      ),
      availableSubAgents: const [reviewer],
      availableSkills: const [],
      agentConfig: const AgentConfig(),
      defaultProviderId: 'provider_parent',
      defaultModel: 'model_parent',
      parentSessionId: parentSessionId,
      persistence: persistence,
      novelDatabase: novelDb,
      resourcesResolver:
          ({
            required providerId,
            required model,
            required subSessionId,
            required sourceSessionId,
          }) async => SpawnAgentResources(
            client: client,
            toolManager: FakeAgentToolDispatcher(),
            release: () {},
          ),
      defaultAllowedToolNames: () => const <String>[],
      contextSupplementForSession: (_) async => [
        AgentMessage.user(id: 'ctx_todos', content: '[当前结构化 Todo 真源]\n[]'),
      ],
    );

    final result = await handler.run(
      input: const {'agent': '内容核验', 'name': '鲁迅', 'task': 'no tools'},
      callId: 'call_no_tools',
    );

    expect(result['ok'], isTrue);
    final system = client.capturedStreamRequests.single.messages
        .firstWhere((message) => message.role == AgentMessageRole.system)
        .content;
    expect(system, contains('You are a reviewer.'));
    expect(system, isNot(contains('路径语法：')));
    expect(system, isNot(contains('工具返回失败、报错或 skipped 时')));
  });

  test(
    'injects available skill summaries into subagent system prompt',
    () async {
      final client = FakeProviderClient(
        responses: const [FakeProviderClientResponse.text('ok')],
      );

      final result =
          await buildHandler(
            client,
            availableSkills: const [
              AgentSkillSummary(
                name: '章节规划',
                whenToUse: '规划章节结构时',
                description: '将大纲拆解为可执行章节计划。',
              ),
            ],
          ).run(
            input: const {
              'agent': '内容核验',
              'name': '鲁迅',
              'task': 'plan chapter',
            },
            callId: 'call_skills',
          );

      expect(result['ok'], isTrue);
      final system = client.capturedStreamRequests.single.messages
          .firstWhere((message) => message.role == AgentMessageRole.system)
          .content;
      expect(system, contains('<available_agent_skills>'));
      expect(system, contains('<name>章节规划</name>'));
      expect(system, contains('<when_to_use>规划章节结构时</when_to_use>'));
      // 摘要只注入 when_to_use，不再重复 description（见 d987bf84）
      expect(system, isNot(contains('<description>')));
    },
  );

  test(
    'routes TodoWrite to sub_session while keeping mutation source on parent',
    () async {
      final toolManager = FakeAgentToolDispatcher.withResults(
        results: {
          'TodoWrite': {
            'ok': true,
            'todos': [
              {
                'id': 'todo_1',
                'content': '子会话待办',
                'status': 'pending',
                'priority': 'medium',
              },
            ],
            'summary': '1 pending todos',
          },
        },
      );
      final client = FakeProviderClient(
        responses: const [
          FakeProviderClientResponse.toolCalls([
            ToolCall(
              callId: 'todo_call',
              toolName: 'TodoWrite',
              arguments: {
                'todos': [
                  {
                    'id': 'todo_1',
                    'content': '子会话待办',
                    'status': 'pending',
                    'priority': 'medium',
                  },
                ],
              },
            ),
          ]),
          FakeProviderClientResponse.text('review done'),
        ],
      );

      final result = await buildHandler(client, toolManager: toolManager).run(
        input: const {
          'agent': '内容核验',
          'name': '鲁迅',
          'task': 'review with todos',
        },
        callId: 'call_todo_route',
        toolExecutionContext: ToolExecutionContext(
          sessionId: parentSessionId,
          sourceSessionId: parentSessionId,
          sourceTurnId: 'user_turn_1',
        ),
      );

      expect(result['ok'], isTrue);
      final subSessionId = result['session_id'] as String?;
      expect(subSessionId, isNotNull);
      expect(toolManager.capturedCalls, hasLength(1));
      final context = toolManager.capturedCalls.single.context;
      expect(context?.sourceSessionId, parentSessionId);
      expect(context?.sessionId, subSessionId);
      expect(context?.sourceTurnId, 'user_turn_1');
    },
  );

  test(
    'does not start a model when spawn persistence is unavailable',
    () async {
      final client = FakeProviderClient(
        responses: const [FakeProviderClientResponse.text('已完成')],
      );
      final handler = SpawnAgentHandler(
        pluginHost: emptyPluginHost(),
        codemodeScheduler: codemodeScheduler,
        workContext: const AiSessionContext(
          workId: novelId,
          contentKind: contentKindNovel,
        ),
        availableSubAgents: const [reviewer],
        agentConfig: const AgentConfig(),
        defaultProviderId: 'provider_parent',
        defaultModel: 'model_parent',
        parentSessionId: null,
        persistence: null,
        novelDatabase: null,
        resourcesResolver:
            ({
              required providerId,
              required model,
              required subSessionId,
              required sourceSessionId,
            }) async => SpawnAgentResources(
              client: client,
              toolManager: FakeAgentToolDispatcher(),
              release: () {},
            ),
        contextSupplementForSession: (_) async => const [],
      );

      final result = await handler.run(
        input: const {'agent': '内容核验', 'name': '鲁迅', 'task': 'review'},
      );

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'unavailable');
      expect(client.capturedStreamRequests, isEmpty);
    },
  );

  test(
    'TodoWrite followed by AgentError keeps a queryable failed session',
    () async {
      late FakeAgentToolDispatcher toolManager;
      var sessionExistedDuringTodoWrite = false;
      toolManager = FakeAgentToolDispatcher(
        tools: {
          'TodoWrite': FakeAgentTool(
            def: const ToolDef(
              name: 'TodoWrite',
              description: 'write todo',
              inputSchema: {'type': 'object'},
            ),
            handler: (_, _) async {
              final sessionId =
                  toolManager.capturedCalls.last.context!.sessionId!;
              sessionExistedDuringTodoWrite =
                  await persistence.getSession(sessionId) != null;
              final now = DateTime.now();
              final saved = await TodoDao(appDb).saveTodos(sessionId, [
                Todo(
                  id: 'todo_1',
                  content: 'persist before failure',
                  status: 'pending',
                  priority: 'medium',
                  sessionId: sessionId,
                  sortOrder: 0,
                  createdAt: now,
                  updatedAt: now,
                ),
              ]);
              return {
                'ok': true,
                'todos': saved.map((todo) => {'id': todo.id}).toList(),
              };
            },
          ),
        },
      );
      final client = FakeProviderClient(
        responder: (request) {
          if (request.callIndex == 0) {
            return const FakeProviderClientResponse.toolCalls([
              ToolCall(
                callId: 'todo_before_failure',
                toolName: 'TodoWrite',
                arguments: {'todos': []},
              ),
            ]);
          }
          throw StateError('sub-agent provider failed');
        },
      );

      final result = await buildHandler(client, toolManager: toolManager).run(
        input: const {
          'agent': '内容核验',
          'name': '鲁迅',
          'task': 'write todo then fail',
        },
        toolExecutionContext: ToolExecutionContext(
          sessionId: parentSessionId,
          sourceSessionId: parentSessionId,
        ),
      );

      final subSessionId = result['session_id'] as String;
      expect(result['ok'], isFalse);
      expect(result['error_code'], 'internal');
      expect(sessionExistedDuringTodoWrite, isTrue);
      expect(
        (await TodoDao(appDb).getTodosBySession(subSessionId)),
        hasLength(1),
      );
      final session = await persistence.getSession(subSessionId);
      expect(session, isNotNull);
      expect(session!.metadata?['spawn_run_status'], 'failed');
      expect(session.metadata?['spawn_error_code'], 'sub_agent_error');
    },
  );

  test('cancelled spawn persists a cancelled terminal session', () async {
    final client = FakeProviderClient(
      responses: const [FakeProviderClientResponse.text('已完成')],
    );
    final cancellationController = AgentCancellationController()..cancel();

    final result = await buildHandler(client).run(
      input: const {
        'agent': '内容核验',
        'name': '鲁迅',
        'task': 'cancel immediately',
      },
      toolExecutionContext: ToolExecutionContext(
        cancellationToken: cancellationController.token,
      ),
    );

    expect(result['cancelled'], isTrue);
    expect(result['error_code'], 'user_cancelled');
    expect(client.capturedStreamRequests, isEmpty);
    final session = await persistence.getSession(
      result['session_id'] as String,
    );
    expect(session, isNotNull);
    expect(session!.metadata?['spawn_run_status'], 'cancelled');
    expect(session.metadata?['spawn_error_code'], 'user_cancelled');
  });

  test(
    'cancelling the parent Agent cancels an independently modelled Chat Subagent',
    () async {
      late String createdSessionId;
      const profiledReviewer = SubAgent(
        id: 'sub_profiled_cancel',
        slug: 'profiled-reviewer',
        name: '独立模型核验',
        description: 'review with another model',
        prompt: 'You are a reviewer.',
        scope: SubAgentScope.global,
        sortOrder: 0,
        providerId: 'provider_child',
        model: 'model_child',
      );
      final childStarted = Completer<void>();
      final releaseChild = Completer<void>();
      final childClient = FakeProviderClient(
        responder: (_) async {
          if (!childStarted.isCompleted) {
            childStarted.complete();
          }
          await releaseChild.future;
          return const FakeProviderClientResponse.text('late child result');
        },
      );
      final parentClient = FakeProviderClient(
        responses: const [
          FakeProviderClientResponse.toolCalls([
            ToolCall(
              callId: 'spawn_blocked_child',
              toolName: spawnAgentToolName,
              arguments: {
                'agent': '独立模型核验',
                'name': '鲁迅',
                'task': 'wait until cancelled',
                'background': false,
              },
            ),
          ]),
        ],
      );
      final handler = buildHandler(
        parentClient,
        availableSubAgents: const [profiledReviewer],
        clientResolver:
            ({
              required String providerId,
              required String model,
              required String subSessionId,
            }) async {
              createdSessionId = subSessionId;
              return childClient;
            },
      );
      final runs = SpawnAgentSessionRuns(
        parentSessionId: parentSessionId,
        onChanged: (_) {},
        onActivityStarted: (_) {},
        onActivity: (_, _) {},
        onActivityFinished: (_) {},
      );
      addTearDown(runs.dispose);
      final dispatcher = ChatAgentToolDispatcher(
        inner: FakeAgentToolDispatcher(),
        subAgents: runs,
        resumeSubAgent: (sessionId, message, callId, context) => runs.resume(
          handler: handler,
          sessionId: sessionId,
          message: message,
          callId: callId,
          context: context,
        ),
        startSubAgent: (input, callId, context, {required background}) =>
            runs.start(
              handler: handler,
              input: input,
              callId: callId,
              context: context,
              background: background,
            ),
      );
      final parentAgent = Agent.custom(
        id: 'chat_orchestrator',
        systemPrompt: 'Delegate the task.',
        client: parentClient,
        config: const AgentConfig(),
        toolManager: dispatcher,
        allowedTools: const [spawnAgentToolName],
      );
      final processFuture = parentAgent
          .process(
            'delegate',
            toolExecutionContext: ToolExecutionContext(
              sessionId: parentSessionId,
              sourceSessionId: parentSessionId,
            ),
          )
          .toList();

      await childStarted.future.timeout(const Duration(seconds: 1));
      parentAgent.cancel();
      try {
        await Future<void>.delayed(Duration.zero);
        expect(
          childClient.cancelCallCount,
          1,
          reason: '父 Agent 取消必须主动中断使用独立 client 的 Chat Subagent',
        );
      } finally {
        if (!releaseChild.isCompleted) {
          releaseChild.complete();
        }
      }

      final events = await processFuture.timeout(const Duration(seconds: 1));
      expect(events.whereType<AgentCancelled>(), isNotEmpty);
      final session = await persistence.getSession(createdSessionId);
      expect(session, isNotNull);
      expect(session!.metadata?['spawn_run_status'], 'cancelled');
      expect(session.metadata?['spawn_error_code'], 'user_cancelled');
    },
  );
}

class _FinalizationFailingPersistence extends AiSessionPersistenceService {
  _FinalizationFailingPersistence(
    super.appDatabase,
    super.novelId, {
    required super.novelContentDatabase,
    this.failMessageSave = false,
    this.hideSessionDuringFinalization = false,
    this.failSessionRead = false,
  });

  final bool failMessageSave;
  final bool hideSessionDuringFinalization;
  final bool failSessionRead;
  int _getSessionCalls = 0;

  @override
  Future<AiChatSession?> getSession(String id) {
    if (failSessionRead) {
      throw StateError('private session_create cause');
    }
    _getSessionCalls += 1;
    if (hideSessionDuringFinalization && _getSessionCalls > 1) {
      return Future.value(null);
    }
    return super.getSession(id);
  }

  @override
  Future<void> saveMessages({
    required String sessionId,
    required List<AiMessage> messages,
    required NovelContentDatabase novelDatabase,
    AgentContextSnapshot? contextSnapshot,
  }) {
    if (failMessageSave) {
      throw StateError('message persistence failed');
    }
    return super.saveMessages(
      sessionId: sessionId,
      messages: messages,
      novelDatabase: novelDatabase,
      contextSnapshot: contextSnapshot,
    );
  }
}

class _StartFailureHook extends AgentHook {
  @override
  FutureOr<HookAction<String>> onStart(String task) {
    throw StateError('private execution cause');
  }
}

class _FailureHook extends AgentHook {
  _FailureHook(this.failure);

  final AiRunFailure failure;

  @override
  FutureOr<LLMErrorAction> onLLMError(
    Object error,
    int attempt, {
    bool isStreamError = false,
  }) => LLMErrorAction.abort(failure);
}

// 只替换 JS 宿主；真实 Spawn、Agent hooks、Codemode 排队和持久化均参与测试。
class _SubAgentCodemodeRuntime extends FjsRuntime {
  List<String> toolNames = [];
  String? cancelledCode;

  @override
  Future<void> get settled => Future.value();

  @override
  void cancel({String errorCode = 'user_cancelled'}) {
    cancelledCode = errorCode;
  }

  @override
  Future<CodemodeRuntimeResult> run({
    required String code,
    required List<ToolDef> tools,
    required Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
    executeTool,
    Future<Map<String, dynamic>> Function(
      String method,
      Map<String, dynamic> input,
    )?
    discover,
    bool Function(String name)? isDynamicTool,
    AgentCancellationToken? cancellationToken,
    String Function()? cancellationErrorCode,
    void Function(String?)? onTerminate,
    void Function(String, Map<String, dynamic>, String)? onRejectedTool,
    CodemodeRuntimeLimits limits = const CodemodeRuntimeLimits(),
  }) async {
    toolNames = tools.map((tool) => tool.name).toList();
    final read = await executeTool('Read', {'path': 'profile/title'});
    final write = await executeTool('Write', {
      'path': 'profile/title',
      'value': read['value'],
    });
    return CodemodeRuntimeResult(
      output: [write],
      callCount: 2,
      completedCount: 2,
      failedCount: 0,
      errorCode: cancellationToken?.isCancellationRequested == true
          ? cancellationErrorCode?.call() ?? 'user_cancelled'
          : cancelledCode,
    );
  }
}

class _CodemodeRecordingHook extends AgentHook {
  final before = <String>[];
  final after = <String>[];

  @override
  FutureOr<HookAction<BeforeToolCallContext>> beforeToolCall(
    BeforeToolCallContext context,
  ) {
    before.add(context.call.toolName);
    return const HookAction.proceed();
  }

  @override
  FutureOr<HookAction<AfterToolCallContext>> afterToolCall(
    AfterToolCallContext context,
  ) {
    after.add(context.call.toolName);
    return const HookAction.proceed();
  }
}

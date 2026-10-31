// 职责: 验证 MCP 请求摘要与 direct 声明、静态白名单边界和单次 hooks。
// 关联文件:
//   lib/shared/services/ai/mcp/agent_dispatcher.dart
//   lib/shared/services/ai/mcp/run_command_handler.dart
//   lib/shared/agent/agent.dart
import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:mcp_dart/mcp_dart.dart' as sdk;
import 'package:reveric/shared/agent/agent_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/agent.dart';
import 'package:reveric/shared/agent/agent_config.dart';
import 'package:reveric/shared/agent/agent_hook.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/agent/fake_agent.dart';
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/mcp/config.dart';
import 'package:reveric/shared/services/mcp/settings_orchestrator.dart';
import 'package:reveric/shared/services/mcp/settings_service.dart';
import 'package:reveric/shared/services/ai/mcp/agent_dispatcher.dart';
import 'package:reveric/shared/services/ai/codemode/orchestrator.dart';
import 'package:reveric/shared/services/ai/codemode/runtime.dart';
import 'package:reveric/shared/services/ai/codemode/scheduler.dart';
import 'package:reveric/shared/services/ai/mcp/run_command_handler.dart';
import '../../mcp/execution_test.dart' show ExecutionConnection;

class Host extends FakeAgentToolDispatcher implements McpRunCommandHost {
  Host()
    : super(
        tools: {
          'Run': FakeAgentTool(
            def: const ToolDef(
              name: 'Run',
              description: 'Run',
              inputSchema: {'type': 'object'},
            ),
            handler: (_, _) async => {},
          ),
        },
      );
  @override
  McpRunCommandHandler? mcpRunHandler;
  @override
  bool Function()? mcpAllowed;
  @override
  Future<Map<String, dynamic>> executeTool({
    required String name,
    required Map<String, dynamic> input,
    String? callId,
    bool emitEvents = true,
    ToolExecutionContext? context,
  }) => name == 'Run' && input['command'] == 'mcp'
      ? mcpRunHandler!.execute(
          input['subcommand'] as String,
          Map<String, dynamic>.from(input['options'] as Map? ?? {}),
          context,
        )
      : super.executeTool(
          name: name,
          input: input,
          callId: callId,
          emitEvents: emitEvents,
          context: context,
        );
}

class CountHook extends AgentHook {
  int before = 0;
  int after = 0;
  AgentToolSource? source;
  @override
  HookAction<BeforeToolCallContext> beforeToolCall(
    BeforeToolCallContext context,
  ) {
    before++;
    source = context.source;
    return const HookAction.proceed();
  }

  @override
  HookAction<AfterToolCallContext> afterToolCall(AfterToolCallContext context) {
    after++;
    source = context.source;
    return const HookAction.proceed();
  }
}

class SignalledConnection extends ExecutionConnection {
  final started = Completer<void>();
  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments, {
    sdk.AbortSignal? signal,
    void Function(sdk.Progress)? onProgress,
  }) {
    started.complete();
    return super.callTool(
      name,
      arguments,
      signal: signal,
      onProgress: onProgress,
    );
  }
}

class ProgressConnection extends ExecutionConnection {
  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments, {
    sdk.AbortSignal? signal,
    void Function(sdk.Progress)? onProgress,
  }) {
    for (var i = 0; i < 1000; i++) {
      onProgress?.call(
        sdk.Progress(
          progress: i,
          total: 1000,
          message: 'private-secret ${'x' * 1000}',
        ),
      );
    }
    return super.callTool(
      name,
      arguments,
      signal: signal,
      onProgress: onProgress,
    );
  }
}

class LargeResultConnection extends ExecutionConnection {
  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments, {
    sdk.AbortSignal? signal,
    void Function(sdk.Progress)? onProgress,
  }) async => {
    'content': [
      {'type': 'text', 'text': 'large result'},
    ],
    'structuredContent': {'data': 'x' * 600000},
  };
}

class McpCodemodeRuntime extends FjsRuntime {
  Map<String, dynamic>? result;
  @override
  Future<void> get settled => Future.value();
  @override
  Future<CodemodeRuntimeResult> run({
    required String code,
    required List<ToolDef> tools,
    required Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
    executeTool,
    Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
    discover,
    bool Function(String)? isDynamicTool,
    AgentCancellationToken? cancellationToken,
    String Function()? cancellationErrorCode,
    void Function(String?)? onTerminate,
    void Function(String, Map<String, dynamic>, String)? onRejectedTool,
    CodemodeRuntimeLimits limits = const CodemodeRuntimeLimits(),
  }) async {
    final listed = await discover!('listTools', {});
    expect(
      (listed['tools'] as List).where((t) => t['source'] == 'mcp'),
      isEmpty,
    );
    expect((listed['failedServers'] as List).single['name'], 'notes');
    result = await executeTool('mcp__notes__write', {'number': 1});
    onTerminate?.call(null);
    return const CodemodeRuntimeResult(
      output: [],
      callCount: 1,
      completedCount: 0,
      failedCount: 1,
    );
  }
}

class UpdatingConnection extends ExecutionConnection {
  int minimum = 1;
  bool removed = false;
  @override
  Future<List<Map<String, dynamic>>> listTools() async => [
    if (!removed)
      {
        'name': 'write',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'number': {'type': 'integer', 'minimum': minimum},
          },
          'required': ['number'],
        },
      },
  ];
}

class UpdatingCodemodeRuntime extends FjsRuntime {
  UpdatingCodemodeRuntime(this.connection);
  final UpdatingConnection connection;
  @override
  Future<void> get settled => Future.value();
  @override
  Future<CodemodeRuntimeResult> run({
    required String code,
    required List<ToolDef> tools,
    required Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
    executeTool,
    Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
    discover,
    bool Function(String)? isDynamicTool,
    AgentCancellationToken? cancellationToken,
    String Function()? cancellationErrorCode,
    void Function(String?)? onTerminate,
    void Function(String, Map<String, dynamic>, String)? onRejectedTool,
    CodemodeRuntimeLimits limits = const CodemodeRuntimeLimits(),
  }) async {
    final original = await discover!('describeTool', {
      'name': 'mcp__notes__write',
    });
    expect(
      (original['inputSchema'] as Map)['properties']['number']['minimum'],
      1,
    );
    connection.minimum = 2;
    await connection.onToolsChanged!();
    final invalid = await executeTool('mcp__notes__write', {'number': 1});
    expect(invalid['error_code'], 'mcp_invalid_arguments');
    final valid = await executeTool('mcp__notes__write', {'number': 4});
    expect(valid['ok'], true);
    final refreshed = await discover('describeTool', {
      'name': 'mcp__notes__write',
    });
    expect(
      (refreshed['inputSchema'] as Map)['properties']['number']['minimum'],
      2,
    );
    final run = await executeTool('Run', {
      'command': 'mcp',
      'subcommand': 'call',
      'options': {
        'name': 'mcp__notes__write',
        'arguments': {'number': 4},
      },
    });
    expect(run['ok'], true);
    connection.removed = true;
    await connection.onToolsChanged!();
    final removed = await executeTool('mcp__notes__write', {'number': 4});
    expect(removed['error_code'], 'mcp_tool_not_found');
    onTerminate?.call(null);
    return const CodemodeRuntimeResult(
      output: [],
      callCount: 4,
      completedCount: 2,
      failedCount: 2,
    );
  }
}

void main() {
  late AppDatabase db;
  late McpSettingsService service;
  late ExecutionConnection connection;
  late Host inner;
  setUp(() async {
    db = AppDatabase.forTest(NativeDatabase.memory());
    connection = ExecutionConnection();
    await McpSettingsOrchestrator().save(
      database: db,
      create: true,
      config: McpServerConfig(
        name: 'notes',
        description: '笔记',
        enabled: true,
        exposure: McpExposure.direct,
        connection: McpHttpConfig(
          url: 'https://example.test',
          bearerToken: 'private-secret',
        ),
      ),
    );
    service = McpSettingsService(
      db,
      supportsStdio: true,
      connector: (_) async => connection,
    );
    await service.initialized;
    inner = Host();
  });
  tearDown(() async {
    await service.close();
    await db.close();
  });
  test(
    'nested MCP calls receive full data while direct replies are bounded',
    () async {
      connection = LargeResultConnection();
      final dispatcher = McpAgentToolDispatcher(
        inner: inner,
        runTools: inner,
        service: service,
        isEnabled: () => true,
      );
      await dispatcher.prepareRequest(runStart: true);
      for (final run in [false, true]) {
        final name = run ? 'Run' : 'mcp__notes__write';
        final input = run
            ? <String, dynamic>{
                'command': 'mcp',
                'subcommand': 'call',
                'options': {
                  'name': 'mcp__notes__write',
                  'arguments': {'number': 1},
                },
              }
            : <String, dynamic>{'number': 1};
        final nested = await dispatcher.executeTool(
          name: name,
          input: input,
          context: ToolExecutionContext(parentToolCallId: 'codemode'),
        );
        expect(
          ((nested['structuredContent'] as Map)['data'] as String).length,
          600000,
        );
        final direct = await dispatcher.executeTool(name: name, input: input);
        expect(jsonEncode(direct['content']), contains('[truncated]'));
        expect(utf8.encode(jsonEncode(direct)).length, lessThan(34 * 1024));
      }
    },
  );
  test('Codemode uses refreshed schemas without version binding', () async {
    final updating = UpdatingConnection();
    connection = updating;
    final dispatcher = McpAgentToolDispatcher(
      inner: inner,
      runTools: inner,
      service: service,
      isEnabled: () => true,
    );
    await dispatcher.prepareRequest(runStart: true);
    final scheduler = CodemodeScheduler(maxActive: 1);
    addTearDown(scheduler.dispose);
    final result = await CodemodeOrchestrator().execute(
      input: {'code': 'fixture'},
      context: ToolExecutionContext(sessionId: 'refresh'),
      parentToolCallId: 'parent',
      tools: dispatcher,
      catalog: dispatcher.catalog,
      runTool: (call, context) => dispatcher.executeTool(
        name: call.toolName,
        input: call.arguments,
        context: context,
      ),
      onRecord: (_) {},
      scheduler: scheduler,
      isAllowed: () => true,
      allowedToolNames: () => ['Run'],
      runtimeFactory: () => UpdatingCodemodeRuntime(updating),
    );
    expect(result['ok'], true);
    expect(updating.calls, 2);
  });
  test(
    'failure is sticky in one session and another session can recover',
    () async {
      await service.close();
      var attempts = 0;
      var failing = true;
      service = McpSettingsService(
        db,
        supportsStdio: true,
        connector: (_) async {
          attempts++;
          if (failing) {
            throw StateError('connection refused');
          }
          return connection;
        },
      );
      McpAgentToolDispatcher dispatcher(String id) {
        final host = Host();
        return McpAgentToolDispatcher(
          inner: host,
          runTools: host,
          service: service,
          sourceSessionId: id,
          isEnabled: () => true,
        );
      }

      final first = dispatcher('a');
      await first.prepareRequest(runStart: true);
      expect(attempts, 1);
      expect(first.requestSystemPrompt, contains('connection refused'));
      await first.prepareRequest(runStart: true);
      final rebuilt = dispatcher('a');
      await rebuilt.prepareRequest(runStart: true);
      await expectLater(
        rebuilt.catalog.listTools(mcpServer: 'notes'),
        throwsA(predicate((e) => e.toString().contains('connection refused'))),
      );
      expect(attempts, 1);
      failing = false;
      await service.setForeground(false);
      await service.setForeground(true);
      expect(attempts, 1);
      final second = dispatcher('b');
      await second.prepareRequest(runStart: true);
      expect(attempts, 2);
      expect(
        second.allToolDefs().map((t) => t.name),
        contains('mcp__notes__write'),
      );
      await first.prepareRequest(runStart: true);
      expect(
        first.allToolDefs().map((t) => t.name),
        isNot(contains('mcp__notes__write')),
      );
      final direct = await first.executeTool(
        name: 'mcp__notes__write',
        input: {'number': 1},
      );
      final run = await rebuilt.executeTool(
        name: 'Run',
        input: {
          'command': 'mcp',
          'subcommand': 'call',
          'options': {
            'name': 'mcp__notes__write',
            'arguments': {'number': 1},
          },
        },
      );
      final js = McpCodemodeRuntime();
      final scheduler = CodemodeScheduler(maxActive: 1);
      addTearDown(scheduler.dispose);
      await CodemodeOrchestrator().execute(
        input: {'code': 'fixture'},
        context: ToolExecutionContext(sessionId: 'a'),
        parentToolCallId: 'parent',
        tools: first,
        catalog: first.catalog,
        runTool: (call, context) => first.executeTool(
          name: call.toolName,
          input: call.arguments,
          context: context,
        ),
        onRecord: (_) {},
        scheduler: scheduler,
        isAllowed: () => true,
        allowedToolNames: () => ['Run'],
        runtimeFactory: () => js,
      );
      expect(js.result, isNotNull);
      for (final result in [direct, run, js.result!]) {
        expect(result['error_code'], 'mcp_connection_failed');
        expect(result['error'], contains('connection refused'));
        expect(result['executionState'], 'not_started');
      }
      expect(connection.calls, 0);
      expect(attempts, 2);
    },
  );

  test(
    'invalid server is isolated and repaired configuration reaches new sessions',
    () async {
      await service.close();
      final good = McpServerConfig(
        name: 'notes',
        enabled: true,
        exposure: McpExposure.direct,
        connection: McpHttpConfig(
          url: 'https://example.test',
          authMode: McpAuthMode.oauth,
          oauth: {
            'accessToken': 'valid-token',
            'issuer': 'https://example.test',
            'resource': 'https://example.test',
            'expiresAt': '2099-01-01T00:00:00Z',
          },
        ),
      );
      final raw = jsonEncode({
        'formatVersion': 1,
        'servers': [
          good.toJson(),
          {...good.toJson(), 'name': 'bad', 'url': 'invalid'},
        ],
      });
      await db.appSettingsDao.set(key: McpSettings.key, value: raw);
      final connected = <String>[];
      service = McpSettingsService(
        db,
        supportsStdio: true,
        connector: (config) async {
          connected.add(config.name);
          return ExecutionConnection();
        },
      );
      final dispatcher = McpAgentToolDispatcher(
        inner: inner,
        runTools: inner,
        service: service,
        sourceSessionId: 'a',
        isEnabled: () => true,
      );
      await dispatcher.prepareRequest(runStart: true);
      expect(connected, ['notes']);
      expect((await service.oauth.tokens(good))!.accessToken, 'valid-token');
      expect(
        dispatcher.allToolDefs().map((t) => t.name),
        contains('mcp__notes__write'),
      );
      final bad = await dispatcher.executeTool(
        name: 'mcp__bad__write',
        input: {},
      );
      expect(bad['error_code'], 'mcp_configuration_error');
      expect(bad['error'], contains('Invalid MCP HTTP URL'));
      expect(
        (dispatcher.catalog.listMcpServers()['failedServers'] as List)
            .single['name'],
        'bad',
      );
      expect(await db.appSettingsDao.get(McpSettings.key), raw);
      final repaired = McpSettings([
        good,
        McpServerConfig(
          name: 'bad',
          enabled: true,
          exposure: McpExposure.direct,
          connection: McpHttpConfig(url: 'https://example.test'),
        ),
      ]);
      final changed = service.runtime.changes.firstWhere(
        (_) => service.runtime.configs.length == 2,
      );
      await db.appSettingsDao.set(
        key: McpSettings.key,
        value: repaired.encode(),
      );
      await changed;
      final host = Host();
      final next = McpAgentToolDispatcher(
        inner: host,
        runTools: host,
        service: service,
        sourceSessionId: 'b',
        isEnabled: () => true,
      );
      await next.prepareRequest(runStart: true);
      expect(
        next.allToolDefs().map((t) => t.name),
        contains('mcp__bad__write'),
      );
      await dispatcher.prepareRequest(runStart: true);
      expect(
        dispatcher.allToolDefs().map((t) => t.name),
        isNot(contains('mcp__bad__write')),
      );
    },
  );
  test(
    'invalid persisted configuration does not block ordinary chat',
    () async {
      await service.close();
      await db.appSettingsDao.set(key: McpSettings.key, value: 'broken');
      service = McpSettingsService(db, supportsStdio: true);
      final dispatcher = McpAgentToolDispatcher(
        inner: inner,
        runTools: inner,
        service: service,
        sourceSessionId: 'broken-config',
        isEnabled: () => true,
      );
      final agent = Agent.custom(
        id: 'scope',
        systemPrompt: 'base',
        client: FakeProviderClient(
          responses: [const FakeProviderClientResponse.text('done')],
        ),
        config: const AgentConfig(),
        toolManager: dispatcher,
      );
      final events = await agent.process('go').toList();
      expect(events.whereType<AgentError>(), isEmpty);
      expect(events.whereType<AgentDone>(), isNotEmpty);
      final result = await dispatcher.executeTool(
        name: 'Run',
        input: {
          'command': 'mcp',
          'subcommand': 'call',
          'options': {
            'name': 'mcp__notes__write',
            'arguments': <String, dynamic>{},
          },
        },
      );
      expect(result['ok'], false);
      expect(result['error_code'], 'mcp_configuration_error');
      expect(result['executionState'], 'not_started');
      expect(result['error'], contains('Invalid MCP configuration JSON'));
      expect(await db.appSettingsDao.get(McpSettings.key), 'broken');
    },
  );
  test(
    'cancelled top-level MCP events keep unknown results and child source identity',
    () async {
      final signalled = SignalledConnection();
      connection = signalled;
      final dispatcher = McpAgentToolDispatcher(
        inner: inner,
        runTools: inner,
        service: service,
        isEnabled: () => true,
      );
      final agent = Agent.custom(
        id: 'child',
        systemPrompt: 'base',
        client: FakeProviderClient(
          responses: [
            FakeProviderClientResponse.toolCalls([
              const ToolCall(
                callId: 'cancel',
                toolName: 'mcp__notes__write',
                arguments: {'number': 2},
              ),
            ]),
          ],
        ),
        config: const AgentConfig(),
        toolManager: dispatcher,
      );
      final events = agent
          .process(
            'go',
            toolExecutionContext: ToolExecutionContext(
              sessionId: 'child-session',
              sourceSessionId: 'parent-session',
            ),
          )
          .toList();
      await signalled.started.future;
      agent.cancel();
      final completed = await events;
      final start = completed.whereType<AgentToolCallStart>().single;
      expect(start.metadata?['source_session_id'], 'child-session');
      final skipped = completed.whereType<AgentToolSkipped>().single;
      expect(skipped.output?['executionState'], 'unknown');
      expect(skipped.metadata?['tool_source'], 'mcp');
      expect(skipped.metadata?['source_session_id'], 'child-session');
      expect(connection.calls, 1);
    },
  );
  test(
    'direct bypasses builtin whitelist and goes through hooks once',
    () async {
      connection = ProgressConnection();
      final dispatcher = McpAgentToolDispatcher(
        inner: inner,
        runTools: inner,
        service: service,
        isEnabled: () => true,
      );
      final client = FakeProviderClient(
        responses: [
          FakeProviderClientResponse.toolCalls([
            const ToolCall(
              callId: 'call',
              toolName: 'mcp__notes__write',
              arguments: {'number': 1},
            ),
          ]),
          const FakeProviderClientResponse.text('done'),
        ],
      );
      final hook = CountHook();
      final agent = Agent.custom(
        id: 'scope',
        systemPrompt: 'base',
        client: client,
        config: const AgentConfig(),
        toolManager: dispatcher,
        allowedTools: const [],
        hooks: [hook],
      );
      final events = await agent
          .process(
            'go',
            toolExecutionContext: ToolExecutionContext(
              sessionId: 's',
              sourceSessionId: 's',
            ),
          )
          .toList();
      final progress = events.whereType<AgentToolCallProgress>().toList();
      expect(progress, hasLength(1));
      expect(
        progress.single.progress['message'].toString().length,
        lessThanOrEqualTo(256),
      );
      expect(
        progress.single.progress['message'],
        startsWith('private-secret '),
      );
      expect(connection.calls, 1);
      expect(hook.before, 1);
      expect(hook.after, 1);
      expect(hook.source, AgentToolSource.mcp);
      final request = client.capturedStreamRequests.first;
      expect(request.tools!.map((t) => t.name), contains('mcp__notes__write'));
      final system = request.messages.first.content;
      expect(system, contains('<name>notes</name>'));
      expect(system, isNot(contains('private-secret')));
    },
  );
  test(
    'deferred search does not register tools and council rejects unrelated Run',
    () async {
      await service.save(
        service.runtime.configs.single.copyWith(exposure: McpExposure.deferred),
        create: false,
      );
      final dispatcher = McpAgentToolDispatcher(
        inner: inner,
        runTools: inner,
        service: service,
        isEnabled: () => true,
        mcpOnlyRun: true,
      );
      await dispatcher.prepareRequest(runStart: true);
      await service.runtime.ensureReady('notes');
      final before = dispatcher.allToolDefs().map((d) => d.name).toList();
      await dispatcher.catalog.searchTool('笔记');
      await dispatcher.prepareRequest(runStart: true);
      expect(dispatcher.allToolDefs().map((d) => d.name), before);
      expect(before, isNot(contains('mcp__notes__write')));
      final denied = await dispatcher.executeTool(
        name: 'Run',
        input: {'command': 'files', 'subcommand': 'list'},
      );
      expect(denied['error_code'], 'permission_denied');
      expect(dispatcher.isExternalCall('Run', {'command': ' MCP '}), true);
      await dispatcher.executeTool(name: 'Run', input: {'command': 'help'});
      expect(inner.capturedCalls.last.input['subcommand'], 'mcp');
      expect(connection.calls, 0);
    },
  );
  test('schema adapter diagnoses Gemini keyword loss', () {
    expect(
      geminiMcpSchemaIssue({'type': 'object', r'$defs': {}}),
      contains('mcp_schema_unsupported'),
    );
    expect(
      geminiMcpSchemaIssue({
        'type': 'object',
        'properties': {
          'q': {'type': 'string'},
        },
      }),
      isNull,
    );
  });
}

// 职责: 验证 Codemode 的 Run 子命令准入、审批、取消和后台任务回执。
// 关联文件:
//   lib/shared/services/ai/codemode/orchestrator.dart
//   lib/shared/services/ai/tools_run.dart
//   lib/shared/services/ai/tool_operations.dart
//   lib/shared/services/themes_orchestrator.dart
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/tool_approval.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/ai_nested_tool_call.dart';
import 'package:reveric/shared/models/tool_permission.dart';
import 'package:reveric/shared/services/ai/codemode/orchestrator.dart';
import 'package:reveric/shared/services/ai/codemode/runtime.dart';
import 'package:reveric/shared/services/ai/codemode/scheduler.dart';
import 'package:reveric/shared/services/ai/media/production.dart';
import 'package:reveric/shared/services/ai/tool_operations.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/tool_permission_gate.dart';
import 'package:reveric/shared/services/themes_orchestrator.dart';
import 'package:reveric/shared/services/tool_permissions.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

typedef _Run =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> input);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NovelContentDatabase db;
  late AppDatabase app;
  late AiToolManager tools;
  late Directory root;
  late ToolOperationManager operations;
  late ToolOperationRegistry registry;
  late AiToolApprovalController approvals;
  late ToolPermissionService permissions;
  late CodemodeScheduler scheduler;
  late Map<String, AiNestedToolCall> records;
  late Future<Map<String, dynamic>> Function(Map<String, dynamic>) themeHandler;
  var loginCalls = 0;
  final context = ToolExecutionContext(
    sessionId: 'owner',
    sourceSessionId: 'owner',
    sourceTurnId: 'turn',
  );
  final nested = ToolExecutionContext(
    sessionId: 'owner',
    sourceSessionId: 'owner',
    sourceTurnId: 'turn',
    parentToolCallId: 'parent',
    approvalHostCallId: 'parent',
  );

  setUp(() async {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    app = AppDatabase.forTest(NativeDatabase.memory());
    await app
        .into(app.novels)
        .insert(
          NovelsCompanion.insert(id: 'work', title: 'Work', description: ''),
        );
    await app
        .into(app.aiChatSessions)
        .insert(AiChatSessionsCompanion.insert(id: 'owner', novelId: 'work'));
    root = await Directory.systemTemp.createTemp('codemode-run-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await RevericPaths.initialize();
    final content = NovelContentService(db);
    approvals = AiToolApprovalController();
    permissions = ToolPermissionService(
      app,
      episodeExists: (_, _) async => false,
    );
    registry = ToolOperationRegistry();
    operations = ToolOperationManager(
      ownerSessionId: 'owner',
      registry: registry,
      gate: () => ToolPermissionGate(permissions, approvals, enabled: true),
      onChanged: (_) {},
      onRecord: (_) {},
    );
    themeHandler = (_) async => {'ok': true};
    loginCalls = 0;
    tools = AiToolManager(
      content,
      workingOverlayService: WorkingOverlayService(
        db,
        content,
        novelActionsService: NovelActionsService(app),
      ),
      workId: 'work',
      sessionId: 'owner',
      operationHost: ToolOperationHost(operations),

      themesCommandCallback: (input) => themeHandler(input),
    )..registerAllTools();
    scheduler = CodemodeScheduler(maxActive: 1);
    records = {};
  });
  tearDown(() async {
    tools.dispose();
    operations.dispose();
    registry.dispose();
    approvals.dispose();
    scheduler.dispose();
    await db.close();
    await app.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await root.delete(recursive: true);
  });

  Future<Map<String, dynamic>> run(
    Map<String, dynamic> input, {
    bool direct = false,
  }) => tools.executeTool(
    name: 'Run',
    input: input,
    callId: 'run',
    context: direct ? context : nested,
  );
  Future<Map<String, dynamic>> script(
    Future<void> Function(_Run run) body, {
    AgentCancellationToken? cancellation,
    void Function(AiNestedToolCall)? observe,
    CodemodeToolRunner? runTool,
  }) => CodemodeOrchestrator()
      .execute(
        input: {'code': 'fixture'},
        context: ToolExecutionContext(
          sessionId: 'owner',
          sourceSessionId: 'owner',
          sourceTurnId: 'turn',
          cancellationToken: cancellation,
        ),
        parentToolCallId: 'parent',
        tools: tools,
        runTool:
            runTool ??
            (call, ctx) => tools.executeTool(
              name: call.toolName,
              input: call.arguments,
              callId: call.callId,
              context: ctx,
            ),
        onRecord: (record) {
          records[record.callId] = record;
          observe?.call(record);
        },
        scheduler: scheduler,
        isAllowed: () => true,
        allowedToolNames: tools.allToolNames,
        runtimeFactory: () => _Runtime(body),
      )
      .then((result) {
        // 测试断言若从模拟脚本抛出，编排器会转为运行失败，不能让它被静默吞掉。
        expect(result['ok'], true, reason: '$result');
        return result;
      });

  test(
    'blocked actions and unknown actions never reach their handlers',
    () async {
      const blocked = {
        'files': ['view-image'],
        'assets': ['view-image'],
        'ffmpeg': ['frames'],
        'stagings': ['frames'],
        'editing': ['frames'],
        'map': ['draft'],
        'notify': ['progress', 'question', 'complete', 'error'],
      };
      for (final entry in blocked.entries) {
        for (final action in entry.value) {
          for (final input in [
            {'command': entry.key, 'subcommand': action},
            {
              'options': {'command': entry.key, 'subcommand': action},
            },
          ]) {
            final result = await run(input);
            expect(
              result['error_code'],
              'permission_denied',
              reason: '$input: $result',
            );
            expect(result['hint'], contains('directly'));
          }
        }
      }
      for (final command in ['notify', 'themes', 'agent-rules']) {
        final result = await run({
          'command': command,
          'subcommand': 'future-action',
        });
        expect(
          result['error_code'],
          'invalid_argument',
          reason: '$command: $result',
        );
        expect(result['hint'], isNot(contains('directly')));
      }
      expect(
        (await run({
          'command': 'agent-rules',
          'subcommand': 'future-action',
        }))['hint'],
        contains('agent-rules: '),
      );
      expect(loginCalls, 0);
      expect(
        (await run({
          'command': 'account',
          'subcommand': 'login',
        }, direct: true))['ok'],
        false,
      );
      expect(loginCalls, 0);
    },
  );

  test('help and error hints expose only permitted actions in scripts', () async {
    for (final alias in ['help', '--help']) {
      final help = (await run({'command': alias}))['output'] as String;
      for (final forbidden in [
        'account:',
        'notify:',
        'map:',
        'view-image',
        'frames',
      ]) {
        expect(help, isNot(contains(forbidden)));
      }
      expect(
        help,
        contains(
          'editing: list, read, create, duplicate, apply, undo, redo, preview, export, cleanup',
        ),
      );
      expect(help, contains('read-video-metadata'));
      expect(help, contains('capture-frame'));
      for (final group in [
        'files',
        'assets',
        'stagings',
        'editing',
        'ffmpeg',
        'account',
        'map',
        'notify',
      ]) {
        final text =
            (await run({'command': alias, 'subcommand': group}))['output']
                as String;
        expect(text, isNot(contains('view-image')));
        expect(text, isNot(contains('frames')));
        expect(text, isNot(contains('subcommand=login')));
      }
    }
    final help =
        (await run({'command': 'help'}, direct: true))['output'] as String;
    expect(help, isNot(contains('account')));
    final schema = tools
        .allToolDefs()
        .singleWhere((tool) => tool.name == 'Run')
        .inputSchema;
    await run({'command': 'help'});
    expect(
      tools.allToolDefs().singleWhere((tool) => tool.name == 'Run').inputSchema,
      schema,
    );
  });

  test(
    'Run writes are readable and summarized through the real dispatcher',
    () async {
      final result = await script((run) async {
        expect(
          (await run({
            'command': 'agent-rules',
            'subcommand': 'create',
            'options': {'name': 'Rule', 'content': 'Keep viewpoint stable.'},
          }))['ok'],
          true,
        );
        final listed = await run({
          'command': 'agent-rules',
          'subcommand': 'list',
        });
        expect((listed['rules'] as List).single['name'], 'Rule');
        expect(
          (await run({
            'command': 'notify',
            'subcommand': 'progress',
          }))['error_code'],
          'permission_denied',
        );
      });
      expect(result['completed_count'], 2);
      expect(result['failed_count'], 1);
      expect(
        (result['completed_operations'] as List).single['command'],
        'agent-rules create',
      );
      expect(result['uncertain_operations'], isEmpty);
      expect(records.values.map((r) => r.effectStatus), [
        AiToolEffectStatus.confirmed,
        AiToolEffectStatus.none,
        AiToolEffectStatus.none,
      ]);
    },
  );

  test(
    'cancellation waits for an entered Run mutation and preserves its result',
    () async {
      final started = Completer<void>();
      final committed = Completer<Map<String, dynamic>>();
      final cancel = AgentCancellationController();
      themeHandler = (_) {
        started.complete();
        return committed.future;
      };
      var finished = false;
      final pending =
          script((run) async {
            await run({
              'command': 'themes',
              'subcommand': 'create',
              'options': {'name': 'Theme'},
            });
          }, cancellation: cancel.token).then((value) {
            finished = true;
            return value;
          });
      await started.future;
      cancel.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(finished, false);
      expect(scheduler.activeCount, 1);
      committed.complete({'ok': true, 'id': 'theme'});
      final result = await pending;
      expect(
        (result['completed_operations'] as List).single['resource_id'],
        'theme',
      );
      expect(result['uncertain_operations'], isEmpty);
      expect(scheduler.activeCount, 0);
    },
  );

  test(
    'background receipts survive script completion and can be waited for',
    () async {
      final file = File('${root.path}/source.mp4');
      await file.writeAsString('snapshot');
      final waiting = approvals.stream.firstWhere((rows) => rows.isNotEmpty);
      String? runId;
      final result = await script((run) async {
        final receipt = await run(_ffmpegExecute(file.path));
        runId = receipt['run_id'] as String;
      });
      expect((result['pending_operations'] as List).single['run_id'], runId);
      expect(result['completed_operations'], isEmpty);
      final request = (await waiting).single;
      expect(request.displayCallId, 'parent');
      // 拒绝审批即可让后台 run 结束，不依赖测试环境里的原生 FFmpeg。
      await approvals.resolve(request, allow: false);
      final waited = await run({
        'command': 'operations',
        'subcommand': 'wait',
        'options': {'run_id': runId},
      });
      expect(waited['status'], 'failed');
      expect(waited['error_code'], 'permission_denied');
      expect(registry.records[runId]!.historyCallId, 'parent');
    },
  );

  test(
    'cancelling a wait keeps the independent background submission pending',
    () async {
      final running = Completer<Map<String, dynamic>>();
      final cancel = AgentCancellationController();
      String? runId;
      var waitEvents = 0;
      final waitStarted = Completer<void>();
      final pending = script(
        (run) async {
          final receipt = await run({
            'command': 'ffmpeg',
            'subcommand': 'execute',
            'options': const {
              'args': ['-i', 'in.mp4', 'videos/out.mp4'],
            },
          });
          runId = receipt['run_id'] as String;
          final cancelledWait = await run({
            'command': 'operations',
            'subcommand': 'wait',
            'options': {'run_id': runId},
          });
          expect(cancelledWait['cancelled'], true);
        },
        cancellation: cancel.token,
        runTool: (call, ctx) {
          if (call.arguments['command'] == 'ffmpeg') {
            return operations.start(
              context: ctx,
              callId: call.callId,
              workId: 'work',
              kind: 'ffmpeg.execute',
              targetPath: '/files/videos/out.mp4',
              toolName: 'Run',
              background: true,
              input: call.arguments,
              verifyTarget: () async {},
              execute: (_) => running.future,
            );
          }
          return tools.executeTool(
            name: call.toolName,
            input: call.arguments,
            callId: call.callId,
            context: ctx,
          );
        },
        observe: (record) {
          if (record.argumentsPreview.contains('"command":"operations"') &&
              record.argumentsPreview.contains('"subcommand":"wait"') &&
              ++waitEvents == 2) {
            waitStarted.complete();
          }
        },
      );
      await waitStarted.future;
      cancel.cancel();
      final result = await pending;
      expect(registry.records[runId]!.terminal, false);
      running.complete({'ok': true});
      await run({
        'command': 'operations',
        'subcommand': 'wait',
        'options': {'run_id': runId},
      }, direct: true);
      expect(
        (result['pending_operations'] as List).map((entry) => entry['run_id']),
        [runId],
        reason: 'wait cancellation must not settle the background run: $result',
      );
      expect(result['uncertain_operations'], isEmpty);
    },
  );

  test(
    'waiting for a background write replaces pending with its real outcome',
    () async {
      final file = File('${root.path}/source.mp4');
      await file.writeAsString('data');
      final waiting = approvals.stream.firstWhere((rows) => rows.isNotEmpty);
      final pending = script((run) async {
        final receipt = await run(_ffmpegExecute(file.path));
        var status = await run({
          'command': 'operations',
          'subcommand': 'wait',
          'options': {'run_id': receipt['run_id']},
        });
        while (status['status'] == 'waiting_approval') {
          await Future<void>.delayed(Duration.zero);
          status = await run({
            'command': 'operations',
            'subcommand': 'wait',
            'options': {'run_id': receipt['run_id']},
          });
        }
        expect(status['status'], 'failed');
      });
      await approvals.resolve((await waiting).single, allow: false);
      final result = await pending;
      expect(result['pending_operations'], isEmpty);
      expect(result['completed_operations'], isEmpty);
    },
  );

  test(
    'cancelling an already completed task does not report a new mutation',
    () async {
      final file = File('${root.path}/file_workspaces/work/file.txt');
      await file.parent.create(recursive: true);
      await file.writeAsString('data');
      final receipt = await run({
        'command': 'files',
        'subcommand': 'read-text',
        'options': {'path': 'file.txt'},
      }, direct: true);
      expect(receipt['status'], 'completed');
      final result = await script((run) async {
        final cancelled = await run({
          'command': 'operations',
          'subcommand': 'cancel',
          'options': {'run_id': receipt['run_id']},
        });
        expect(cancelled['accepted'], false);
      });
      expect(result['completed_operations'], isEmpty);
      expect(result['uncertain_operations'], isEmpty);
    },
  );

  for (final actualHandler in [false, true]) {
    test(
      'Run argument validation does not require verification: real=$actualHandler',
      () async {
        themeHandler = actualHandler
            ? (input) => ThemesOrchestrator().run(app, input)
            : (_) async => throw const FormatException('name is required.');
        final result = await script((run) async {
          final failed = await run({
            'command': 'themes',
            'subcommand': 'create',
          });
          expect(failed['ok'], false);
          expect(failed['error_code'], 'invalid_argument');
          expect(failed['error'], contains('name'));
        });
        expect(await app.select(app.customThemes).get(), isEmpty);
        expect(records.values.single.status, AiNestedToolStatus.error);
        expect(records.values.single.errorCode, 'invalid_argument');
        expect(records.values.single.effectStatus, AiToolEffectStatus.none);
        expect(result['completed_operations'], isEmpty);
        expect(result['uncertain_operations'], isEmpty);
        expect(result, isNot(contains('verification_required')));
      },
    );
  }

  test('Run routing validation is not an uncertain mutation', () async {
    final result = await script((run) async {
      final failed = await run({
        'command': 'files',
        'subcommand': 'remove',
        'options': {'path': 'file.txt', 'unsupported': true},
      });
      expect(failed['error_code'], 'invalid_argument');
    });
    expect(registry.records, isEmpty);
    expect(result['uncertain_operations'], isEmpty);
    expect(result, isNot(contains('verification_required')));
    expect(records.values.single.effectStatus, AiToolEffectStatus.none);
  });

  test(
    'Run failure after execution started still requires verification',
    () async {
      final result = await CodemodeOrchestrator().execute(
        input: {'code': 'fixture'},
        context: context,
        parentToolCallId: 'parent',
        tools: tools,
        runTool: (call, ctx) {
          ctx.lifecycleObserver!.onStarted!({
            'codemode_mutating': true,
            'run_command': 'themes create',
          });
          return operations.start(
            context: ctx,
            callId: call.callId,
            workId: 'work',
            kind: 'themes.create',
            targetPath: 'theme',
            toolName: 'Run',
            background: false,
            verifyTarget: () async {},
            execute: (_) async => throw const ToolOperationException(
              'invalid_argument',
              'Late validation failed after execution began.',
            ),
          );
        },
        onRecord: (record) => records[record.callId] = record,
        scheduler: scheduler,
        isAllowed: () => true,
        allowedToolNames: tools.allToolNames,
        runtimeFactory: () => _Runtime((run) async {
          await run({'command': 'themes', 'subcommand': 'create'});
        }),
      );
      expect(result['uncertain_operations'], hasLength(1));
      expect(result, contains('verification_required'));
      expect(records.values.single.effectStatus, AiToolEffectStatus.unknown);
    },
  );

  test(
    'failed Run writes preserve diagnostics and require verification',
    () async {
      themeHandler = (_) async => {
        'ok': false,
        'error_code': 'unavailable',
        'error': 'Remote write lost acknowledgement',
        'hint': 'Read the saved theme before retrying',
      };
      final result = await script((run) async {
        final failed = await run({'command': 'themes', 'subcommand': 'create'});
        expect(failed['error_code'], 'unavailable');
        expect(failed['error'], 'Remote write lost acknowledgement');
        expect(failed['hint'], 'Read the saved theme before retrying');
      });
      expect(result['completed_operations'], isEmpty);
      expect(result['uncertain_operations'], hasLength(1));
      expect(records.values.single.effectStatus, AiToolEffectStatus.unknown);
    },
  );

  for (final allow in [true, false]) {
    test(
      'foreground approval $allow preserves parent identity and outcome',
      () async {
        final file = File('${root.path}/file_workspaces/work/file.txt');
        await file.parent.create(recursive: true);
        await file.writeAsString('data');
        final waiting = approvals.stream.firstWhere((rows) => rows.isNotEmpty);
        final pending = script((run) async {
          await run({
            'command': 'files',
            'subcommand': 'remove',
            'options': {'path': 'file.txt'},
          });
        });
        final request = (await waiting).single;
        expect(request.displayCallId, 'parent');
        await approvals.resolve(request, allow: allow);
        final result = await pending;
        expect(await file.exists(), !allow);
        expect(result['completed_operations'], hasLength(allow ? 1 : 0));
        expect(result['uncertain_operations'], isEmpty);
      },
    );
  }

  test(
    'cancel while awaiting approval leaves the file and no uncertain write',
    () async {
      final file = File('${root.path}/file_workspaces/work/file.txt');
      await file.parent.create(recursive: true);
      await file.writeAsString('data');
      final waiting = approvals.stream.firstWhere((rows) => rows.isNotEmpty);
      final cancel = AgentCancellationController();
      final pending = script((run) async {
        await run({
          'command': 'files',
          'subcommand': 'remove',
          'options': {'path': 'file.txt'},
        });
      }, cancellation: cancel.token);
      await waiting;
      cancel.cancel();
      final result = await pending;
      expect(await file.exists(), true);
      expect(result['completed_operations'], isEmpty);
      expect(result['uncertain_operations'], isEmpty);
      expect(records.values.single.status, AiNestedToolStatus.cancelled);
    },
  );

  for (final allow in [false, true]) {
    test(
      'Run queue bookkeeping failure respects approval execution: allow=$allow',
      () async {
        final file = File('${root.path}/file_workspaces/work/file.txt');
        await file.parent.create(recursive: true);
        await file.writeAsString('data');
        final waiting = approvals.stream.firstWhere((rows) => rows.isNotEmpty);
        final cancel = AgentCancellationController();
        var publicationFailed = false;
        final pending = script(
          (run) async {
            await run({
              'command': 'files',
              'subcommand': 'remove',
              'options': {'path': 'file.txt'},
            });
          },
          cancellation: cancel.token,
          observe: (record) {
            final terminal = allow
                ? AiNestedToolStatus.success
                : AiNestedToolStatus.cancelled;
            if (!publicationFailed && record.status == terminal) {
              publicationFailed = true;
              // 在真实审批/执行收口后打断记录发布，强制进入队列 catchError。
              throw StateError('Nested result publication failed');
            }
          },
        );
        final request = (await waiting).single;
        expect(await file.exists(), true);
        expect(
          registry.records.values.single.status,
          ToolOperationStatus.waiting_approval,
        );
        if (allow) {
          await approvals.resolve(request, allow: true);
        } else {
          cancel.cancel();
        }
        final result = await pending;
        expect(publicationFailed, true);
        expect(await file.exists(), !allow);
        expect(records.values.single.status, AiNestedToolStatus.rejected);
        expect(records.values.single.errorCode, 'codemode_runtime_failed');
        expect(
          records.values.single.effectStatus,
          allow ? AiToolEffectStatus.unknown : AiToolEffectStatus.none,
        );
        expect(result['uncertain_operations'], hasLength(allow ? 1 : 0));
        expect(result.containsKey('verification_required'), allow);
        expect(approvals.pending, isEmpty);
        expect(registry.records.values.single.terminal, true);
        expect(scheduler.activeCount, 0);
      },
    );
  }

  test(
    'file reading commands reject unknown options before starting an operation',
    () async {
      for (final action in [
        'read-text',
        'view-image',
        'read-video-metadata',
        'read-audio-metadata',
      ]) {
        final result = await run({
          'command': 'files',
          'subcommand': action,
          'options': {'path': 'anything.txt', 'unexpected': true},
        }, direct: true);
        expect(result['error_code'], 'invalid_argument');
        expect(result['error'], 'Unsupported files option.');
      }
      expect(registry.records, isEmpty);
    },
  );

  test('each file action rejects mismatched media before reading', () async {
    await permissions.setRule(
      'files.read',
      const ToolPermissionScope.global(),
      ToolPermissionDecision.allow,
    );
    for (final sample in [
      ('read-text', 'png'),
      ('view-image', 'txt'),
      ('read-video-metadata', 'txt'),
      ('read-audio-metadata', 'mp4'),
    ]) {
      final file = File('${root.path}/sample.${sample.$2}');
      await file.writeAsString('not the requested media');
      final result = await run({
        'command': 'files',
        'subcommand': sample.$1,
        'options': {'path': file.path},
      }, direct: true);
      expect(result['ok'], false, reason: '$sample: $result');
      expect(result['error_code'], 'invalid_argument');
      expect(result['error'], contains('file type'));
    }
  });
}

// Replace only JS evaluation: admission, dispatch, permissions and operation management are real.
class _Runtime extends FjsRuntime {
  _Runtime(this.body);
  final Future<void> Function(_Run run) body;
  @override
  Future<void> get settled => Future.value();
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
    expect(tools.map((tool) => tool.name), contains('Run'));
    await body((input) => executeTool('Run', input));
    onTerminate?.call(null);
    return const CodemodeRuntimeResult(
      output: [],
      callCount: 0,
      completedCount: 0,
      failedCount: 0,
    );
  }
}

/// 固定后台执行且需 files.read 审批的命令，用来驱动后台回执。
Map<String, dynamic> _ffmpegExecute(String source) => {
  'command': 'ffmpeg',
  'subcommand': 'execute',
  'options': {
    'args': ['-i', source, 'videos/out.mp4'],
  },
};

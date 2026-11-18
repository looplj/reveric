// 职责: 验证会话操作的审批、取消、完成通知和原生媒体诊断在返回及历史中的保留。
// 关联文件:
//   lib/shared/services/ai/tool_operations.dart
//   lib/shared/services/tool_permission_gate.dart
//   lib/shared/services/production/ffmpeg_runner.dart
import 'dart:async';
import 'package:drift/native.dart';
import 'package:ffmpeg_kit_flutter_new/abstract_session.dart';
import 'package:ffmpeg_kit_flutter_new/log.dart';
import 'package:ffmpeg_kit_flutter_new/level.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/agent/tool_approval.dart';
import 'package:reveric/shared/models/tool_permission.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/services/tool_permissions.dart';
import 'package:reveric/shared/services/tool_permission_gate.dart';
import 'package:reveric/shared/services/ai/tool_operations.dart';

class _FailedMediaSession implements AbstractSession {
  _FailedMediaSession({this.code = 1, this.failure});
  final int? code;
  final String? failure;
  static const diagnostic = 'Error, both -y and -n supplied. Exiting.';
  @override
  int getSessionId() => 307;
  @override
  Future<ReturnCode?> getReturnCode() async =>
      code == null ? null : ReturnCode(code!);
  @override
  Future<String?> getFailStackTrace() async => failure;
  @override
  Future<List<Log>> getAllLogs([int? waitTimeout]) async => [
    Log(307, Level.avLogInfo, 'Input video: h264\n'),
    Log(
      307,
      Level.avLogWarning,
      'Request https://user:secret@example.test/video?token=private\n',
    ),
    Log(307, Level.avLogError, '$diagnostic\n'),
  ];
  @override
  Future<String?> getOutput() async =>
      (await getAllLogs()).map((log) => log.getMessage()).join();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AppDatabase db;
  late AiToolApprovalController broker;
  late ToolPermissionGate gate;
  late ToolOperationRegistry registry;
  late ToolOperationManager manager;
  final snapshots = <Map<String, dynamic>>[];
  final publishedReminders = <String>{};
  ToolExecutionContext owner({AgentCancellationToken? token}) =>
      ToolExecutionContext(
        sessionId: 'session',
        sourceSessionId: 'session',
        sourceTurnId: 'turn',
        cancellationToken: token,
      );
  setUp(() async {
    db = AppDatabase.forTest(NativeDatabase.memory());
    await db
        .into(db.novels)
        .insert(
          NovelsCompanion.insert(id: 'work', title: 'Work', description: ''),
        );
    await db
        .into(db.aiChatSessions)
        .insert(AiChatSessionsCompanion.insert(id: 'session', novelId: 'work'));
    broker = AiToolApprovalController();
    gate = ToolPermissionGate(
      ToolPermissionService(db, episodeExists: (_, _) async => false),
      broker,
      enabled: true,
    );
    registry = ToolOperationRegistry();
    snapshots.clear();
    publishedReminders.clear();
    manager = ToolOperationManager(
      ownerSessionId: 'session',
      registry: registry,
      gate: () => gate,
      onChanged: (state) => publishedReminders.addAll(
        state.pending.map((completion) => completion.record.runId),
      ),
      onRecord: (r) => snapshots.add(r.toJson()),
      cancelTimeout: const Duration(milliseconds: 1),
    );
  });
  tearDown(() async {
    manager.dispose();
    broker.dispose();
    await db.close();
  });
  Future<Map<String, dynamic>> start(
    Future<Map<String, dynamic>> Function(ToolOperationContext) execute, {
    bool background = true,
    ToolExecutionContext? context,
    ToolActionRequest? permission,
    Future<void> Function()? verify,
    Future<void> Function()? release,
    Map<String, dynamic> input = const {},
  }) => manager.start(
    context: context ?? owner(),
    callId: 'call',
    workId: 'work',
    kind: permission?.action ?? 'editing.preview',
    targetPath: '/editings/one',
    toolName: 'Run',
    background: background,
    execute: execute,
    verifyTarget: verify ?? () async {},
    permission: permission,
    release: release,
    input: input,
  );

  test(
    'separate submissions execute independently and remain queryable',
    () async {
      var calls = 0;
      Future<Map<String, dynamic>> execute(ToolOperationContext _) async => {
        'ok': true,
        'attempt': ++calls,
      };
      final first = await start(execute, background: false, input: {'a': 1});
      final second = await start(execute, background: false, input: {'a': 1});
      expect(second['run_id'], isNot(first['run_id']));
      expect(calls, 2);
      final original = await manager.wait(first['run_id'] as String, owner());
      expect(original['result'], {'ok': true, 'attempt': 1});
      expect(calls, 2);
    },
  );

  test(
    'terminal responses retain business hints without background guidance',
    () async {
      const recovery = 'Select a supported output format.';
      final result = await start(
        (_) async => {
          'ok': false,
          'error_code': 'invalid_argument',
          'hint': recovery,
        },
        background: false,
      );
      expect(result['hint'], recovery);
      final saved = await manager.wait(result['run_id'] as String, owner());
      expect(saved['hint'], contains(recovery));
      expect(saved['hint'], isNot(contains('Use Run operations')));
    },
  );

  test(
    'output conflict exceptions preserve recovery hints in results and saved history',
    () async {
      const hint =
          'Inspect with Run files list; use Run files remove for authorized cleanup.';
      final result = await start(
        (_) async => throw const ToolOperationException(
          'already_exists',
          'media/frame-001.png exists',
          hint: hint,
        ),
        background: false,
      );
      expect(result['result']['hint'], hint);
      expect(result['hint'], hint);
      expect(result['result']['error_code'], 'already_exists');
      expect(snapshots.last['result']['hint'], hint);
    },
  );

  for (final probe in [false, true]) {
    for (final background in [false, true]) {
      test(
        'native ${probe ? "probe" : "frames"} diagnostics survive '
        '${background ? "background completion" : "foreground response"} and history',
        () async {
          final first = await start((_) async {
            await readFfmpegSessionOutput(
              _FailedMediaSession(),
              probe: probe,
              cancellation: MediaCancellation(),
              arguments: [
                '-n',
                '-i',
                '/private/input.mp4',
                '/private/frame.png',
              ],
            );
            return {'ok': true};
          }, background: background);
          final runId = first['run_id'] as String;
          if (background) {
            while (manager.state.pending.isEmpty) {
              await Future<void>.delayed(Duration.zero);
            }
            expect(
              manager.takeCompletion(runId)!.reminder,
              contains(_FailedMediaSession.diagnostic),
            );
          }
          final saved = await manager.wait(runId, owner());
          final expectedCode = probe ? 'invalid_media' : 'encoding_failed';
          expect(saved['error_code'], expectedCode);
          expect(saved['error'], contains(_FailedMediaSession.diagnostic));
          final result = saved['result'] as Map;
          expect(result['exit_code'], 1);
          expect(result['native_session_id'], 307);
          expect(result['log'], contains('Input video: h264'));
          expect(result['log'], contains(_FailedMediaSession.diagnostic));
          expect(result['log'], contains('<url>'));
          expect(result['log'], isNot(contains('secret')));
          expect(result['log'], isNot(contains('token=private')));
          expect(snapshots.last['result'], result);
          final restored = ToolOperationRecord.fromJson(
            snapshots.last,
          ).response();
          expect(restored['result'], result);
          expect(restored['error'], saved['error']);
          if (!background) {
            expect(first['result'], result);
            expect(first['error'], saved['error']);
          }
        },
      );
    }
  }

  test(
    'native session failure retains missing exit code and failure trace',
    () async {
      const failure = 'Native session failed before returning an exit code.';
      final response = await start((_) async {
        await readFfmpegSessionOutput(
          _FailedMediaSession(code: null, failure: failure),
          probe: false,
          cancellation: MediaCancellation(),
          arguments: [],
        );
        return {'ok': true};
      }, background: false);
      expect(response['error'], contains(failure));
      expect(response['error'], contains(_FailedMediaSession.diagnostic));
      expect(response['result'], containsPair('exit_code', null));
      expect(response['result']['log'], contains('Input video: h264'));
    },
  );

  test(
    'failed runs remain queryable while a new submission executes again',
    () async {
      var calls = 0;
      Future<Map<String, dynamic>> fail(ToolOperationContext context) async {
        calls++;
        throw const MediaException(MediaFailure.encoding_failed);
      }

      final first = await start(fail, background: false);
      expect(first['error_code'], 'encoding_failed');
      final saved = await manager.wait(first['run_id'] as String, owner());
      expect(saved['error_code'], 'encoding_failed');
      expect(calls, 1);
      final retry = await start(fail, background: false);
      expect(retry['run_id'], isNot(first['run_id']));
      expect(calls, 2);
    },
  );

  test(
    'registers before awaiting, freezes input, and a waited result gets no reminder',
    () async {
      final entered = Completer<void>();
      final finish = Completer<Map<String, dynamic>>();
      final input = <String, dynamic>{
        'clips': ['one'],
      };
      final pending = start((ctx) {
        expect(ctx.input['clips'], ['one']);
        entered.complete();
        return finish.future;
      }, input: input);
      expect(manager.state.runs.single.status, ToolOperationStatus.queued);
      (input['clips'] as List).add('two');
      final receipt = await pending;
      final id = receipt['run_id'] as String;
      await entered.future;
      expect(
        (await manager.wait(id, owner(), timeoutMs: 1))['timed_out'],
        true,
      );
      expect(manager.read(id, owner())['status'], 'running');
      finish.complete({
        'ok': true,
        'files': ['media/done.mp4'],
      });
      expect((await manager.wait(id, owner()))['status'], 'completed');
      expect(publishedReminders, isNot(contains(id)));
      expect(manager.state.pending, isEmpty);
      expect(manager.takeCompletion(id), isNull);
      expect(manager.state.needsRetention, false);
    },
  );

  test('a timed-out wait still gets a completion reminder', () async {
    final finish = Completer<Map<String, dynamic>>();
    final receipt = await start((_) => finish.future);
    final id = receipt['run_id'] as String;
    expect((await manager.wait(id, owner(), timeoutMs: 1))['timed_out'], true);
    final terminal = registry.changes.firstWhere(
      (r) => r.runId == id && r.terminal,
    );
    finish.complete({'ok': true});
    await terminal;
    expect(manager.takeCompletion(id), isNotNull);
  });

  test(
    'waiting again on a finished run does not revive its reminder',
    () async {
      final receipt = await start((_) async => {'ok': true});
      final id = receipt['run_id'] as String;
      while (manager.state.pending.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      expect((await manager.wait(id, owner()))['status'], 'completed');
      expect(manager.state.pending, isEmpty);
      expect(manager.takeCompletion(id), isNull);
    },
  );

  test('wait returns at once while the run waits for user approval', () async {
    final permission = ToolActionRequest(
      action: 'generation.video',
      context: const ToolPermissionContext(
        workId: 'work',
        sessionId: 'session',
      ),
      targetPath: '/editings/one',
      summary: const {'model': 'frozen'},
    );
    final receipt = await start(
      (_) async => {'ok': true},
      permission: permission,
    );
    final id = receipt['run_id'] as String;
    final stopwatch = Stopwatch()..start();
    final midWait = await manager.wait(id, owner(), timeoutMs: 60000);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(midWait['status'], 'waiting_approval');
    expect(midWait['hint'], contains('approve'));
    expect(midWait.containsKey('timed_out'), false);

    final immediate = await manager.wait(id, owner(), timeoutMs: 60000);
    expect(immediate['status'], 'waiting_approval');
    expect(immediate['hint'], contains('approve'));
    expect(manager.cancel(id, owner())['accepted'], true);
    expect((await manager.wait(id, owner()))['status'], 'cancelled');
  });

  test(
    'ask cancellation never executes and foreground cancellation leaves background alive',
    () async {
      final permission = ToolActionRequest(
        action: 'generation.video',
        context: const ToolPermissionContext(
          workId: 'work',
          sessionId: 'session',
        ),
        targetPath: '/editings/one',
        summary: const {'model': 'frozen'},
      );
      final waiting = broker.stream.firstWhere((rows) => rows.isNotEmpty);
      var calls = 0;
      final receipt = await start((ctx) async {
        calls++;
        return {'ok': true};
      }, permission: permission);
      await waiting;
      final id = receipt['run_id'] as String;
      expect(manager.read(id, owner())['status'], 'waiting_approval');
      expect(manager.cancel(id, owner())['accepted'], true);
      expect((await manager.wait(id, owner()))['status'], 'cancelled');
      expect(calls, 0);
      expect(broker.pending, isEmpty);
      expect(manager.state.pending, isEmpty);

      final parent = AgentCancellationController();
      final entered = Completer<ToolOperationContext>();
      final finish = Completer<Map<String, dynamic>>();
      final second = await start((ctx) {
        entered.complete(ctx);
        return finish.future;
      }, context: owner(token: parent.token));
      final ctx = await entered.future;
      parent.cancel();
      expect(ctx.cancellation.isCancellationRequested, false);
      finish.complete({'ok': true});
      expect(
        (await manager.wait(second['run_id'] as String, owner()))['status'],
        'completed',
      );
    },
  );

  test(
    'cancel remains cancelling until cleanup confirms termination',
    () async {
      final entered = Completer<void>();
      final finish = Completer<Map<String, dynamic>>();
      final cleanup = Completer<void>();
      var released = false;
      final receipt = await start(
        (ctx) {
          entered.complete();
          return finish.future;
        },
        release: () async {
          await cleanup.future;
          released = true;
        },
      );
      final id = receipt['run_id'] as String;
      await entered.future;
      expect(manager.cancel(id, owner())['status'], 'cancelling');
      expect(manager.cancel(id, owner())['accepted'], true);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(manager.read(id, owner())['diagnostic'], 'cancel_timeout');
      finish.complete({'ok': false, 'cancelled': true});
      expect(
        (await manager.wait(id, owner(), timeoutMs: 1))['timed_out'],
        true,
      );
      expect(released, false);
      cleanup.complete();
      expect((await manager.wait(id, owner()))['status'], 'cancelled');
      expect(released, true);
      expect(manager.cancel(id, owner())['accepted'], false);
      expect(manager.state.pending, isEmpty);
    },
  );

  test(
    'cancel after committed result does not relabel it and rollback revokes notifications',
    () async {
      final releasing = Completer<void>();
      final cleanup = Completer<void>();
      final receipt = await start(
        (_) async => {'ok': true, 'id': 'committed'},
        release: () {
          releasing.complete();
          return cleanup.future;
        },
      );
      final id = receipt['run_id'] as String;
      await releasing.future;
      manager.cancel(id, owner());
      cleanup.complete();
      expect((await manager.wait(id, owner()))['status'], 'completed');
      expect(manager.state.pending, isEmpty);
      await start((_) async => {'ok': true});
      while (manager.state.pending.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(manager.state.pending, hasLength(1));
      await manager.stopTurns({'turn'});
      expect(manager.state.pending, isEmpty);
    },
  );

  test(
    'ownership, cancelled waiting and restart summaries stay isolated',
    () async {
      final entered = Completer<void>();
      final finish = Completer<Map<String, dynamic>>();
      final receipt = await start((_) {
        entered.complete();
        return finish.future;
      });
      final id = receipt['run_id'] as String;
      await entered.future;
      final other = ToolOperationManager(
        ownerSessionId: 'other',
        registry: registry,
        gate: () => gate,
        onChanged: (_) {},
        onRecord: (_) {},
      );
      addTearDown(other.dispose);
      expect(
        () => other.read(id, ToolExecutionContext(sessionId: 'other')),
        throwsA(
          isA<ToolOperationException>().having(
            (e) => e.code,
            'code',
            'permission_denied',
          ),
        ),
      );
      final token = AgentCancellationController();
      final wait = manager.wait(id, owner(token: token.token));
      token.cancel();
      expect((await wait)['cancelled'], true);
      expect(manager.read(id, owner())['status'], 'running');
      final snapshot = manager.state.runs.single.toJson();
      finish.complete({'ok': true});
      await manager.wait(id, owner());
      manager.dispose();
      final restored = ToolOperationManager(
        ownerSessionId: 'session',
        registry: registry,
        gate: () => gate,
        onChanged: (_) {},
        onRecord: (_) {},
      );
      addTearDown(restored.dispose);
      restored.restore([snapshot]);
      expect(restored.read(id, owner())['status'], 'interrupted');
      expect(restored.state.pending, isEmpty);
    },
  );

  test(
    'nested operation control requires host authority and isolates siblings',
    () async {
      final child = ToolExecutionContext(
        sessionId: 'child',
        sourceSessionId: 'session',
        sourceTurnId: 'turn',
        operationOwnerSessionId: 'session',
      );
      expect(
        () => start(
          (_) async => {'ok': true},
          context: ToolExecutionContext(
            sessionId: 'child',
            sourceSessionId: 'session',
            sourceTurnId: 'turn',
          ),
        ),
        throwsA(isA<ToolOperationException>()),
      );
      final receipt = await start(
        (_) async => {'ok': true},
        context: child,
        background: false,
      );
      final id = receipt['run_id'] as String;
      expect(
        () => manager.read(id, owner()),
        throwsA(isA<ToolOperationException>()),
      );
      expect(
        manager.read(
          id,
          ToolExecutionContext(
            sessionId: 'session',
            operationOwnerSessionId: 'session',
          ),
        )['status'],
        'completed',
      );
      expect(
        () => manager.read(
          id,
          ToolExecutionContext(
            sessionId: 'sibling',
            operationOwnerSessionId: 'session',
          ),
        ),
        throwsA(isA<ToolOperationException>()),
      );
      expect(
        manager.list(
          ToolExecutionContext(
            sessionId: 'sibling',
            operationOwnerSessionId: 'session',
          ),
        )['entries'],
        isEmpty,
      );
    },
  );

  test(
    'foreground follows its parent and failed preparation still produces a final notice',
    () async {
      final token = AgentCancellationController();
      final entered = Completer<void>();
      final cancelled = Completer<void>();
      final running = start(
        (ctx) async {
          ctx.cancellation.onCancel(cancelled.complete);
          entered.complete();
          await cancelled.future;
          ctx.checkCancelled();
          return {'ok': true};
        },
        background: false,
        context: owner(token: token.token),
      );
      await entered.future;
      token.cancel();
      expect((await running)['status'], 'cancelled');
      final failed = await start(
        (_) async => {'ok': true},
        verify: () async => throw StateError('injected preparation failure'),
      );
      while (manager.state.pending.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        manager.read(failed['run_id'] as String, owner())['status'],
        'failed',
      );
      expect(manager.state.pending, hasLength(1));
    },
  );
}

// 职责: 验证四层权限、归属校验、并发设置和排队审批的自动放行。
// 关联文件:
//   lib/shared/services/tool_permissions.dart
//   lib/shared/database/daos/tool_permission_dao.dart
import 'dart:async';

import 'package:drift/native.dart';
import 'package:reveric/shared/agent/tool_approval.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/services/tool_permission_gate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/tool_permission.dart';
import 'package:reveric/shared/services/tool_permissions.dart';

void main() {
  late AppDatabase db;
  late ToolPermissionService service;
  const global = ToolPermissionScope.global();
  const work = ToolPermissionScope(
    ToolPermissionScopeType.work,
    workId: 'work',
    id: 'work',
  );
  const episode = ToolPermissionScope(
    ToolPermissionScopeType.episode,
    workId: 'work',
    id: 'episode',
  );
  const session = ToolPermissionScope(
    ToolPermissionScopeType.session,
    workId: 'work',
    id: 'session',
  );
  const context = ToolPermissionContext(
    workId: 'work',
    episodeId: 'episode',
    sessionId: 'session',
  );
  const action = 'generation.video';
  setUp(() async {
    db = AppDatabase.forTest(NativeDatabase.memory());
    await db
        .into(db.novels)
        .insert(
          NovelsCompanion.insert(id: 'work', title: 'Work', description: ''),
        );
    await db
        .into(db.novels)
        .insert(
          NovelsCompanion.insert(id: 'other', title: 'Other', description: ''),
        );
    await db
        .into(db.aiChatSessions)
        .insert(AiChatSessionsCompanion.insert(id: 'session', novelId: 'work'));
    service = ToolPermissionService(
      db,
      episodeExists: (work, episode) async =>
          work == 'work' && episode == 'episode',
    );
  });
  tearDown(() => db.close());

  test(
    'most specific active rule wins and unrelated actions default to ask',
    () async {
      expect(
        (await service.resolve(action, context)).decision,
        ToolPermissionDecision.ask,
      );
      await service.setRule(action, global, ToolPermissionDecision.deny);
      await service.setRule(action, work, ToolPermissionDecision.allow);
      expect((await service.resolve(action, context)).source, work);
      await service.setRule(action, episode, ToolPermissionDecision.ask);
      expect(
        (await service.resolve(action, context)).decision,
        ToolPermissionDecision.ask,
      );
      await service.setRule(action, session, ToolPermissionDecision.allow);
      expect((await service.resolve(action, context)).source, session);
      expect(
        (await service.resolve('generation.audio', context)).decision,
        ToolPermissionDecision.ask,
      );
      await service.setRule(action, session, null);
      expect((await service.resolve(action, context)).source, episode);
      expect(
        (await service.resolve(
          action,
          const ToolPermissionContext(workId: 'other'),
        )).decision,
        ToolPermissionDecision.deny,
      );
    },
  );

  test(
    'inheritance and concurrent restore retain one identity and creation time',
    () async {
      await service.setRule(action, episode, ToolPermissionDecision.allow);
      final original = (await db.toolPermissionDao.rules(episode)).single;
      await service.setRule(action, episode, null);
      expect(await db.toolPermissionDao.rules(episode), isEmpty);
      await Future.wait([
        for (var i = 0; i < 8; i++)
          service.setRule(
            action,
            episode,
            i.isEven
                ? ToolPermissionDecision.deny
                : ToolPermissionDecision.allow,
          ),
      ]);
      final restored = (await db.toolPermissionDao.rules(episode)).single;
      expect(restored.id, original.id);
      expect(restored.createdAt, original.createdAt);
      expect(await db.select(db.toolPermissionRules).get(), hasLength(1));
    },
  );

  test(
    'foreign or missing scope and unknown action cannot be authorized',
    () async {
      await service.setRule(action, global, ToolPermissionDecision.allow);
      await expectLater(
        service.resolve(
          action,
          const ToolPermissionContext(workId: 'other', sessionId: 'session'),
        ),
        throwsA(isA<ToolOperationException>()),
      );
      await expectLater(
        service.resolve(
          action,
          const ToolPermissionContext(workId: 'other', episodeId: 'episode'),
        ),
        throwsA(isA<ToolOperationException>()),
      );
      await expectLater(
        service.setRule(
          action,
          const ToolPermissionScope(
            ToolPermissionScopeType.work,
            workId: 'missing',
            id: 'missing',
          ),
          ToolPermissionDecision.allow,
        ),
        throwsA(isA<ToolOperationException>()),
      );
      await expectLater(
        service.resolve('unknown', context),
        throwsFormatException,
      );
      expect(await db.select(db.toolPermissionRules).get(), hasLength(1));
    },
  );

  test('blank episode id is not an episode scope', () async {
    const canvas = ToolPermissionContext(
      workId: 'work',
      sessionId: 'session',
      episodeId: '',
    );
    expect(canvas.scopes.map((scope) => scope.type), [
      ToolPermissionScopeType.session,
      ToolPermissionScopeType.work,
      ToolPermissionScopeType.global,
    ]);
    await service.setRule(action, work, ToolPermissionDecision.allow);
    expect((await service.resolve(action, canvas)).source, work);
    const noSession = ToolPermissionContext(
      workId: 'work',
      sessionId: '',
      episodeId: '',
    );
    expect((await service.resolve(action, noSession)).source, work);
  });

  test(
    'approval binds frozen inputs, saves scope before execution and is single-use',
    () async {
      final broker = AiToolApprovalController();
      addTearDown(broker.dispose);
      final gate = ToolPermissionGate(service, broker, enabled: true);
      final mutable = <String, dynamic>{
        'files': ['one'],
      };
      final request = ToolActionRequest(
        action: action,
        context: context,
        targetPath: '/clips/one',
        summary: mutable,
      );
      (mutable['files'] as List).add('two');
      var executed = 0;
      final waiting = broker.stream.firstWhere((rows) => rows.isNotEmpty);
      final run = gate
          .authorize(
            request: request,
            ownerSessionId: 'session',
            approvalId: 'approval',
            callId: 'call',
            toolName: 'Create',
            cancellation: AgentCancellationController().token,
            verifyTarget: () async {},
          )
          .then((_) => executed++);
      final pending = (await waiting).single;
      expect(pending.arguments['files'], ['one']);
      expect(executed, 0);
      expect(await broker.resolve(pending, allow: true, scope: session), true);
      expect(await broker.resolve(pending, allow: true), false);
      await run;
      expect(executed, 1);
      expect((await service.resolve(action, context)).source, session);
      expect(broker.pending, isEmpty);
    },
  );

  test('latest deny and cancelled approval never execute', () async {
    final broker = AiToolApprovalController();
    addTearDown(broker.dispose);
    final gate = ToolPermissionGate(service, broker, enabled: true);
    final request = ToolActionRequest(
      action: action,
      context: context,
      targetPath: '/clips/one',
      summary: const {},
    );
    var executed = 0;
    final waiting = broker.stream.firstWhere((rows) => rows.isNotEmpty);
    final run = gate
        .authorize(
          request: request,
          ownerSessionId: 'session',
          approvalId: 'approval',
          callId: 'call',
          toolName: 'Create',
          cancellation: AgentCancellationController().token,
          verifyTarget: () async {},
        )
        .then((_) => executed++);
    final expectation = expectLater(
      run,
      throwsA(
        isA<ToolOperationException>().having(
          (e) => e.code,
          'code',
          'permission_denied',
        ),
      ),
    );
    final pending = (await waiting).single;
    await service.setRule(action, work, ToolPermissionDecision.deny);
    await broker.resolve(pending, allow: true);
    await expectation;
    expect(executed, 0);
    await service.setRule(action, work, null);
    final token = AgentCancellationController();
    final secondWait = broker.stream.firstWhere((rows) => rows.isNotEmpty);
    final second = gate.authorize(
      request: request,
      ownerSessionId: 'session',
      approvalId: 'approval2',
      callId: 'call2',
      toolName: 'Create',
      cancellation: token.token,
      verifyTarget: () async {},
    );
    final cancelled = expectLater(
      second,
      throwsA(
        isA<ToolOperationException>().having(
          (e) => e.code,
          'code',
          'cancelled',
        ),
      ),
    );
    await secondWait;
    token.cancel();
    await cancelled;
    expect(broker.pending, isEmpty);
  });

  for (final scope in [session, episode, work, global]) {
    test(
      'saved ${scope.type.name} allowance releases matching queue',
      () async {
        final broker = AiToolApprovalController();
        addTearDown(broker.dispose);
        final gate = ToolPermissionGate(service, broker, enabled: true);
        final executed = <String>[];
        final verified = <String>[];
        Future<void> authorize(
          String id, {
          String capability = action,
          String owner = 'session',
          ToolPermissionContext target = context,
        }) => gate
            .authorize(
              request: ToolActionRequest(
                action: capability,
                context: target,
                targetPath: '/clips/$id',
                summary: const {},
              ),
              ownerSessionId: owner,
              approvalId: id,
              callId: id,
              toolName: 'Run',
              cancellation: AgentCancellationController().token,
              verifyTarget: () async => verified.add(id),
            )
            .then((_) => executed.add(id));

        final waiting = broker.stream.firstWhere(
          (rows) => rows.length == (scope == global ? 7 : 8),
        );
        final batch = [for (var i = 0; i < 5; i++) authorize('batch-$i')];
        final unrelated = expectLater(
          authorize('audio', capability: 'generation.audio'),
          throwsA(isA<ToolPermissionException>()),
        );
        final otherChat = expectLater(
          authorize('other-chat', owner: 'other-chat'),
          throwsA(isA<ToolPermissionException>()),
        );
        final outsideScope = scope == global
            ? Future<void>.value()
            : expectLater(
                authorize(
                  'outside-scope',
                  target: const ToolPermissionContext(workId: 'other'),
                ),
                throwsA(isA<ToolPermissionException>()),
              );
        final pending = await waiting;
        await broker.resolve(
          pending.singleWhere((r) => r.approvalId == 'batch-0'),
          allow: true,
          scope: scope,
        );
        await Future.wait(batch);
        expect(
          executed,
          unorderedEquals([for (var i = 0; i < 5; i++) 'batch-$i']),
        );
        expect(verified, unorderedEquals(executed));
        expect(
          broker.pending.map((r) => r.approvalId),
          unorderedEquals([
            'audio',
            'other-chat',
            if (scope != global) 'outside-scope',
          ]),
        );
        await authorize('later');
        expect(executed, contains('later'));
        for (final request in broker.pending) {
          await broker.resolve(request, allow: false);
        }
        await Future.wait([unrelated, otherChat, outsideScope]);
      },
    );
  }

  test('saved broad allowance preserves more specific ask and deny', () async {
    final broker = AiToolApprovalController();
    addTearDown(broker.dispose);
    final gate = ToolPermissionGate(service, broker, enabled: true);
    const otherContext = ToolPermissionContext(workId: 'other');
    var executed = 0;
    Future<void> authorize(String id, ToolPermissionContext target) => gate
        .authorize(
          request: ToolActionRequest(
            action: action,
            context: target,
            targetPath: '/clips/$id',
            summary: const {},
          ),
          ownerSessionId: 'session',
          approvalId: id,
          callId: id,
          toolName: 'Run',
          cancellation: AgentCancellationController().token,
          verifyTarget: () async {},
        )
        .then((_) => executed++);
    final waiting = broker.stream.firstWhere((rows) => rows.length == 3);
    final first = authorize('first', context);
    final ask = expectLater(
      authorize('ask', context),
      throwsA(isA<ToolPermissionException>()),
    );
    final deny = expectLater(
      authorize('deny', otherContext),
      throwsA(isA<ToolPermissionException>()),
    );
    final pending = await waiting;
    await service.setRule(action, session, ToolPermissionDecision.ask);
    await service.setRule(
      action,
      const ToolPermissionScope(
        ToolPermissionScopeType.work,
        workId: 'other',
        id: 'other',
      ),
      ToolPermissionDecision.deny,
    );
    final asksAgain = broker.stream.firstWhere(
      (rows) => rows.any((r) => r.approvalId == 'ask' && !pending.contains(r)),
    );
    await broker.resolve(
      pending.singleWhere((r) => r.approvalId == 'first'),
      allow: true,
      scope: global,
    );
    await first;
    await deny;
    await asksAgain;
    expect(executed, 1);
    expect(broker.pending.single.approvalId, 'ask');
    await broker.resolve(broker.pending.single, allow: false);
    await ask;
  });

  test('allowance saved during lookup also releases a late enqueue', () async {
    final broker = AiToolApprovalController();
    addTearDown(broker.dispose);
    final paused = _PausedPermissionService(service);
    var verified = 0;
    Future<void> authorize(String id, ToolPermissionService permissions) =>
        ToolPermissionGate(permissions, broker, enabled: true).authorize(
          request: ToolActionRequest(
            action: action,
            context: context,
            targetPath: '/clips/$id',
            summary: const {},
          ),
          ownerSessionId: 'session',
          approvalId: id,
          callId: id,
          toolName: 'Run',
          cancellation: AgentCancellationController().token,
          verifyTarget: () async {
            verified++;
          },
        );
    final waiting = broker.stream.firstWhere((rows) => rows.isNotEmpty);
    final first = authorize('first', service);
    final pending = (await waiting).single;
    final late = authorize('late', paused);
    await paused.captured.future;
    await broker.resolve(pending, allow: true, scope: session);
    paused.resume.complete();
    await Future.wait([first, late]);
    expect(verified, 2);
    expect(broker.pending, isEmpty);
  });

  test(
    'failed persistent decision remains pending and cannot claim approval',
    () async {
      final broker = AiToolApprovalController();
      addTearDown(broker.dispose);
      final gate = ToolPermissionGate(service, broker, enabled: true);
      final token = AgentCancellationController();
      final waiting = broker.stream.firstWhere((rows) => rows.length == 2);
      Future<void> authorize(String id) => gate.authorize(
        request: ToolActionRequest(
          action: action,
          context: context,
          targetPath: '/clips/one',
          summary: const {},
        ),
        ownerSessionId: 'session',
        approvalId: id,
        callId: 'call',
        toolName: 'Create',
        cancellation: token.token,
        verifyTarget: () async {},
      );
      final stopped = expectLater(
        authorize('approval'),
        throwsA(isA<ToolOperationException>()),
      );
      final otherStopped = expectLater(
        authorize('other'),
        throwsA(isA<ToolOperationException>()),
      );
      final requests = await waiting;
      final pending = requests.first;
      await db.customStatement(
        "CREATE TRIGGER fail_rule BEFORE INSERT ON tool_permission_rules BEGIN SELECT RAISE(ABORT, 'injected'); END",
      );
      await expectLater(
        broker.resolve(pending, allow: true, scope: session),
        throwsA(anything),
      );
      expect(pending.isResolved, false);
      expect(pending.saveFailed, true);
      expect(broker.pending, requests);
      expect(requests.every((r) => !r.isResolved), true);
      expect(
        (await service.resolve(action, context)).decision,
        ToolPermissionDecision.ask,
      );
      token.cancel();
      await stopped;
      await otherStopped;
    },
  );

  test(
    'approvals from one tool call wait side by side and resolve independently',
    () async {
      final broker = AiToolApprovalController();
      addTearDown(broker.dispose);
      final gate = ToolPermissionGate(service, broker, enabled: true);
      final request = ToolActionRequest(
        action: action,
        context: context,
        targetPath: '/clips/one',
        summary: const {},
      );
      final executed = <String>[];
      Future<void> authorize(String approvalId) => gate
          .authorize(
            request: request,
            ownerSessionId: 'session',
            approvalId: approvalId,
            callId: 'call',
            toolName: 'Run',
            cancellation: AgentCancellationController().token,
            verifyTarget: () async {},
          )
          .then((_) => executed.add(approvalId));
      final both = broker.stream.firstWhere((rows) => rows.length == 3);
      final first = authorize('first');
      final third = authorize('third');
      final second = expectLater(
        authorize('second'),
        throwsA(
          isA<ToolPermissionException>()
              .having((e) => e.message, 'message', contains('user rejected'))
              .having((e) => e.hint, 'hint', contains('not a failure')),
        ),
      );
      final pending = await both;
      final firstRequest = pending.singleWhere((r) => r.approvalId == 'first');
      final secondRequest = pending.singleWhere(
        (r) => r.approvalId == 'second',
      );
      expect(await broker.resolve(secondRequest, allow: false), true);
      await second;
      expect(broker.pending, contains(firstRequest));
      expect(broker.pending, hasLength(2));
      expect(await broker.resolve(firstRequest, allow: true), true);
      await first;
      expect(executed, ['first']);
      expect(broker.pending.single.approvalId, 'third');
      await broker.resolve(broker.pending.single, allow: true);
      await third;
    },
  );

  test(
    'disabled approval runs without rules or cards but still verifies target',
    () async {
      final broker = AiToolApprovalController();
      addTearDown(broker.dispose);
      await service.setRule(action, work, ToolPermissionDecision.deny);
      var verified = 0;
      await ToolPermissionGate(service, broker, enabled: false).authorize(
        request: ToolActionRequest(
          action: action,
          context: context,
          targetPath: '/clips/one',
          summary: const {},
        ),
        ownerSessionId: 'session',
        approvalId: 'approval',
        callId: 'call',
        toolName: 'Run',
        cancellation: AgentCancellationController().token,
        verifyTarget: () async => verified++,
      );
      expect(verified, 1);
      expect(broker.pending, isEmpty);
    },
  );
}

class _PausedPermissionService extends ToolPermissionService {
  _PausedPermissionService(ToolPermissionService source)
    : super(source.database, episodeExists: source.episodeExists);

  final captured = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<EffectiveToolPermission> resolve(
    String action,
    ToolPermissionContext context,
  ) async {
    final result = await super.resolve(action, context);
    if (!captured.isCompleted) {
      captured.complete();
      await resume.future;
    }
    return result;
  }
}

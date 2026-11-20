// 职责: 验证工具取消 scope 在预览后阻止写入，并隔离子调用生命周期回调。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/agent/agent_tool_dispatcher.dart
//   lib/shared/services/novel_content.dart
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_content.dart';

void main() {
  late NovelContentDatabase db;
  late NovelContentService content;
  late AppDatabase app;
  late WorkingOverlayService overlay;
  setUp(() {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    content = NovelContentService(db);
    app = AppDatabase.forTest(NativeDatabase.memory());
    overlay = WorkingOverlayService(
      db,
      content,
      novelActionsService: NovelActionsService(app),
    );
  });
  tearDown(() async {
    await db.close();
    await app.close();
  });

  test('scene write reports working change identity once', () async {
    final service = ScreenplayService(db);
    final initial = await service.createInitialStructure();
    final root = (await db.screenplayDao.getRoot())!;
    final scene = await service.createScene(
      screenplayId: root.id,
      episodeId: initial.episodeId,
    );
    final changes = <ToolWorkingChange>[];
    final manager = AiToolManager(
      content,
      workingOverlayService: overlay,
      contentKind: contentKindScreenplay,
      workId: 'fixture',
    )..registerAllTools();
    addTearDown(manager.dispose);
    await manager.executeTool(
      name: 'Write',
      input: {
        'path': 'scenes/$scene',
        'fields': {'title': 'New title', 'synopsis': 'New synopsis'},
      },
      context: ToolExecutionContext(
        sourceSessionId: 'session',
        sourceTurnId: 'turn',
        parentToolCallId: 'parent',
        lifecycleObserver: ToolLifecycleObserver(onWorkingChange: changes.add),
      ),
    );
    final rows = await db.workingChangeDao.getAll();
    expect(rows.length, 2);
    expect(changes.length, 1);
    expect(rows.map((row) => row.id), contains(changes.single.id));
    expect(changes.single.multiple, isTrue);
    expect(changes.single.scope.resourcePath, 'scenes/$scene');
    expect(changes.single.scope.sourceSessionId, 'session');
    expect(changes.single.scope.sourceTurnId, 'turn');
  });

  test(
    'scope cancellation during mutation preview never enters write handler',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var writes = 0;
      final manager = AiToolManager(
        content,
        workingOverlayService: overlay,
        workId: 'current',
        novelReader: () async {
          if (!entered.isCompleted) {
            entered.complete();
          }
          await release.future;
          return {'title': 'test', 'description': 'before'};
        },
        novelWriter: (_) async {
          writes++;
        },
      )..registerAllTools();
      final scope = ToolExecutionScope();
      final future = manager.executeTool(
        name: 'Write',
        input: {
          'path': '/works/current',
          'fields': {'description': 'after'},
        },
        context: ToolExecutionContext(
          parentToolCallId: 'parent',
          cancellationToken: scope.token,
        ),
      );
      await entered.future;
      scope.cancel(code: 'codemode_timeout');
      release.complete();
      final result = await future;
      expect(result['cancelled'], isTrue);
      expect(writes, 0);
      scope.dispose();
      manager.dispose();
    },
  );

  test('nested lifecycle uses only the scoped observer', () async {
    var topEvents = 0;
    var starts = 0;
    var finishes = 0;
    final manager = AiToolManager(
      content,
      workingOverlayService: overlay,
      workId: 'current',
      novelReader: () async => {'title': 'test'},
      onToolCallRequested: (_, _, _) {
        topEvents++;
      },
      onToolStarted: (_, _, _, _, _) {
        topEvents++;
      },
      onToolFinished: (_, _, _, _, _) {
        topEvents++;
      },
    )..registerAllTools();
    final result = await manager.executeTool(
      name: 'Read',
      input: {'path': '/works/current'},
      callId: 'child',
      context: ToolExecutionContext(
        parentToolCallId: 'parent',
        lifecycleObserver: ToolLifecycleObserver(
          onStarted: (_) {
            starts++;
          },
          onFinished: (result, error) {
            finishes++;
            expect(error, isNull);
          },
        ),
      ),
    );
    expect(result['ok'], isTrue);
    expect(starts, 1);
    expect(finishes, 1);
    expect(topEvents, 0);
    manager.dispose();
  });

  test('pre-cancelled read never invokes the business reader', () async {
    var reads = 0;
    final manager = AiToolManager(
      content,
      workingOverlayService: overlay,
      workId: 'current',
      novelReader: () async {
        reads++;
        return {'title': 'test'};
      },
    )..registerAllTools();
    final scope = ToolExecutionScope()..cancel();
    final result = await manager.executeTool(
      name: 'Read',
      input: {'path': '/works/current'},
      context: ToolExecutionContext(
        parentToolCallId: 'parent',
        cancellationToken: scope.token,
      ),
    );
    expect(result['cancelled'], isTrue);
    expect(reads, 0);
    scope.dispose();
    manager.dispose();
  });
}
